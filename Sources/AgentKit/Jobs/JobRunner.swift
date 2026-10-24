import Foundation
import Synchronization

/// Runs one job from its cursor until it finishes, sleeps (a wait step), pauses, needs the user
/// or is stopped. One actor per running job; it persists the record and items after every step
/// and item, so a new runner built from the stored record continues exactly where the last one
/// left off (after a pause, a wait, a crash or a relaunch).
///
/// The runner never decides how a step is done — that's the injected `StepExecuting` (the
/// standard step router in the app, a scripted executor in tests). It owns the job-level
/// loop: milestones, loops over items with retries and parallelism, waits, approvals,
/// verification, budgets, stuck detection and the final report.
public actor JobRunner {
    /// How the runner reports to its owner (`JobCenter`). Called from the runner's executor.
    public struct Callbacks: Sendable {
        /// The record changed (status, progress, status line). Already persisted.
        public var update: @Sendable (JobRecord) -> Void
        /// An activity entry (already stored in the job's log).
        public var log: @Sendable (ActivityEntry) -> Void
        /// Asks the user; waits for the answer.
        public var approve: @Sendable (ApprovalRequest) async -> ApprovalDecision

        public init(update: @escaping @Sendable (JobRecord) -> Void = { _ in },
                    log: @escaping @Sendable (ActivityEntry) -> Void = { _ in },
                    approve: @escaping @Sendable (ApprovalRequest) async -> ApprovalDecision = { _ in .reject }) {
            self.update = update
            self.log = log
            self.approve = approve
        }
    }

    public struct Configuration: Sendable {
        /// Model whose prices turn step token usage into cost (the actor model).
        public var actorModel: String?
        /// Wall clock for wake times (tests move it forward to simulate days passing).
        public var now: @Sendable () -> Date
        /// Spreadsheet reader for file item sources (default `TableIO.reader`).
        public var tableReader: TableIO.Reader?
        /// Spreadsheet updater for write-back (default `TableIO.updater`, else a CSV fallback).
        public var tableUpdater: TableIO.Updater?
        /// Write results back after this many finished items (and at the end of the loop).
        public var writeBackEvery: Int
        /// Turn cap passed to each step.
        public var maxTurnsPerStep: Int
        /// Most items a loop will take from its source.
        public var maxItems: Int

        public init(actorModel: String? = nil, now: @escaping @Sendable () -> Date = { Date() }, tableReader: TableIO.Reader? = nil,
                    tableUpdater: TableIO.Updater? = nil, writeBackEvery: Int = 10, maxTurnsPerStep: Int = 14, maxItems: Int = 10_000) {
            self.actorModel = actorModel
            self.now = now
            self.tableReader = tableReader
            self.tableUpdater = tableUpdater
            self.writeBackEvery = max(1, writeBackEvery)
            self.maxTurnsPerStep = max(1, maxTurnsPerStep)
            self.maxItems = max(1, maxItems)
        }
    }

    /// Why the run loop unwinds before the end of the plan.
    enum Interrupt: Error {
        case paused(String)
        case needsInput(String)
        /// Status is already `.waiting` with `nextWakeAt` set.
        case waiting
        case failed(String)
        case stopped
    }

    public nonisolated let jobID: String
    private var record: JobRecord
    private let store: JobStore
    private let executor: any StepExecuting
    private let lease: ScreenLease
    private let settings: AppSettings
    private let callbacks: Callbacks
    private let config: Configuration
    private let workspace: SQLiteJobWorkspace
    /// This job's own stop/pause switch, so controlling one job never affects another.
    private nonisolated let gate = ExecutionGate()
    private nonisolated let work = Mutex<Task<JobRecord, Never>?>(nil)
    private var leaseOwner: String { "job:\(jobID)" }

    // Per-run bookkeeping (a resumed job starts these fresh).
    private let clock = SuspendingClock()
    private var lastTick: SuspendingClock.Instant
    /// Waits for the user in progress (approvals and screen-lease waits, possibly several at
    /// once from parallel items); their time isn't work time.
    private var waitsInProgress = 0
    private var waitStart: SuspendingClock.Instant?
    private var excludedSeconds = 0.0
    /// Executor calls since the last measurable progress (an item finished or a step advanced).
    private var callsWithoutProgress = 0
    private var stuckOn = ""
    private var pendingWriteBack: [String: [String: String]] = [:]
    /// Whether the current loop may write into its spreadsheet (asked once per loop).
    private var writeBackEnabled = false
    /// Items finished during the current loop visit. One showing up as runnable again means
    /// progress isn't being saved, and the loop must stop instead of redoing work forever.
    private var finishedThisVisit: Set<String> = []

    public init(record: JobRecord, store: JobStore, executor: any StepExecuting, lease: ScreenLease = .shared, settings: AppSettings,
                callbacks: Callbacks = Callbacks(), configuration: Configuration = Configuration()) {
        self.jobID = record.id
        self.record = record
        self.store = store
        self.executor = executor
        self.lease = lease
        self.settings = settings
        self.callbacks = callbacks
        self.config = configuration
        self.workspace = SQLiteJobWorkspace(jobID: record.id, store: store, folder: URL(fileURLWithPath: record.folder, isDirectory: true))
        self.lastTick = SuspendingClock().now
    }

    /// The record as the runner currently sees it.
    public var current: JobRecord { record }

    /// Stops the job: the step in flight is cancelled and the job ends as `.stopped`.
    public nonisolated func stop() {
        gate.stop()
        work.withLock { $0?.cancel() }
    }

    /// Pauses at the next checkpoint (after the items in flight finish); the job ends this run
    /// as `.paused` and continues from there when resumed.
    public nonisolated func pause() { gate.pause() }

    public nonisolated var isStopRequested: Bool { gate.isStopped }

    /// Runs until the job finishes, waits, pauses, needs input or is stopped, and returns the
    /// final record (also persisted). Cancelling the calling task stops the job.
    public func run() async -> JobRecord {
        let task = Task { await self.runBody() }
        work.withLock { $0 = task }
        if gate.isStopped { task.cancel() }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            self.stop()
        }
    }

    // MARK: - Main loop

    private func runBody() async -> JobRecord {
        lastTick = clock.now
        guard let plan = record.plan, !plan.milestones.isEmpty else {
            record.status = .failed
            record.lastError = "This job has no plan to run."
            record.statusLine = "Failed: no plan"
            persist()
            return record
        }
        try? FileManager.default.createDirectory(atPath: record.folder, withIntermediateDirectories: true)
        let resumed = record.cursor.milestoneIndex > 0 || record.cursor.stepIndex > 0 || record.usage.itemsTotal > 0
        record.status = .running
        record.lastError = nil
        record.statusLine = resumed ? "Resuming…" : "Starting…"
        persist()
        log(ActivityEntry(kind: .info, title: resumed ? "Resumed" : "Started: \(plan.goal.isEmpty ? record.title : plan.goal)"))
        do {
            try await runMilestones()
            try await finishWithReport()
        } catch let interrupt as Interrupt {
            apply(interrupt)
        } catch {
            if gate.isStopped || Task.isCancelled || error is CancellationError {
                apply(.stopped)
            } else if let e = error as? AutomationError, e == .stopped {
                apply(.paused("Paused because Glide's Stop was pressed. Resume to continue."))
            } else {
                apply(.failed(error.localizedDescription))
            }
        }
        await lease.release(owner: leaseOwner)
        if record.status.isFinished { await BrowserSessions.shared.releaseJob(jobID) }
        persist()
        return record
    }

    private func apply(_ interrupt: Interrupt) {
        switch interrupt {
        case .waiting:
            record.status = .waiting
        case .paused(let message):
            record.status = .paused
            record.statusLine = message
            log(ActivityEntry(kind: .info, title: message))
        case .needsInput(let message):
            record.status = .needsInput
            record.statusLine = message
            record.lastError = message
            log(ActivityEntry(kind: .info, title: "Needs you", detail: message))
        case .failed(let message):
            record.status = .failed
            record.lastError = message
            record.statusLine = "Failed: \(message)"
            log(ActivityEntry(kind: .error, title: "Job failed", detail: message, success: false))
        case .stopped:
            record.status = .stopped
            record.nextWakeAt = nil
            record.statusLine = "Stopped"
            log(ActivityEntry(kind: .info, title: "Stopped"))
        }
    }

    private func runMilestones() async throws {
        milestones: while true {
            guard let plan = record.plan else { throw Interrupt.failed("The job's plan is missing.") }
            let mi = record.cursor.milestoneIndex
            guard plan.milestones.indices.contains(mi) else { return }
            let milestone = plan.milestones[mi]
            try checkpoint()
            if record.cursor.stepIndex == 0, record.cursor.waitIteration == 0 {
                if milestone.requiresApproval, store.state(jobID: jobID, key: "approved:\(milestone.id)") == nil {
                    try await askToStart(milestone, index: mi, of: plan.milestones.count)
                }
                log(ActivityEntry(kind: .plan, title: "Milestone \(mi + 1) of \(plan.milestones.count): \(milestone.title)", detail: milestone.description))
            }
            // Steps (re-read every turn: verification may append a remedial step).
            while let m = record.plan?.milestones[mi], record.cursor.stepIndex < m.steps.count {
                let si = record.cursor.stepIndex
                let step = m.steps[si]
                try checkpoint()
                switch step.kind {
                case .action(let r): try await runAction(step, r, milestoneIndex: mi)
                case .forEach(let spec): try await runForEach(step, spec, milestoneIndex: mi)
                case .wait(let w): try await runWait(step, w, milestone: m)
                }
                if continueRetry(after: (mi, si)) { continue milestones }
            }
            // A daily wait repeats the rest of the milestone.
            if let m = record.plan?.milestones[mi], let daily = Self.dailyWait(in: m) {
                record.cursor.waitIteration += 1
                if daily.times == nil || record.cursor.waitIteration < (daily.times ?? 0) {
                    record.cursor.stepIndex = daily.index
                    persist()
                    continue
                }
            }
            guard let m = record.plan?.milestones[mi] else { return }
            if try await verify(m, index: mi) {
                record.cursor.milestoneIndex = mi + 1
                record.cursor.stepIndex = 0
                record.cursor.waitIteration = 0
                callsWithoutProgress = 0
                persist()
            }
        }
    }

    static func dailyWait(in m: Milestone) -> (index: Int, times: Int?)? {
        for (i, s) in m.steps.enumerated() {
            if case .wait(.daily(_, _, let times)) = s.kind { return (i, times) }
        }
        return nil
    }

    private func advanceStep() {
        record.cursor.stepIndex += 1
        callsWithoutProgress = 0
        persist()
    }

    /// Where a job goes back to after "Retry failed items" sent it back to earlier loops (saved
    /// in the job's engine state, so it survives pauses and restarts). Without it the job would
    /// run on from the loop and redo every step it had already finished after it, including
    /// sends and writes, and skip the confirmation of milestones approved the first time.
    struct RetryReturn: Codable, Equatable, Sendable {
        /// How far the job had got.
        var cursor: JobCursor
        /// Step ids of the loops being redone (all before `cursor`).
        var loops: [Int]
        /// When the wait at `cursor` was due, if the job was sleeping there. Restored on the way
        /// back, so a 24-hour wait 22 hours in doesn't start over after the retry.
        var wakeAt: Date? = nil

        static let stateKey = "retryReturn"

        static func load(jobID: String, store: JobStore) -> RetryReturn? {
            store.state(jobID: jobID, key: stateKey).flatMap { try? JSONDecoder().decode(RetryReturn.self, from: Data($0.utf8)) }
        }

        func save(jobID: String, store: JobStore) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            store.setState(jobID: jobID, key: Self.stateKey, value: String(decoding: data, as: UTF8.self))
        }

        /// Whether `a` is an earlier position in the plan than `b`.
        static func precedes(_ a: JobCursor, _ b: JobCursor) -> Bool {
            (a.milestoneIndex, a.stepIndex) < (b.milestoneIndex, b.stepIndex)
        }
    }

    /// After the step at `position` finished during a retry of failed items: on to the next loop
    /// being redone, or straight back to where the job had got to. Returns whether it moved.
    private func continueRetry(after position: (milestone: Int, step: Int)) -> Bool {
        guard let back = RetryReturn.load(jobID: jobID, store: store), let plan = record.plan else { return false }
        let target = (back.cursor.milestoneIndex, back.cursor.stepIndex)
        // Never move backwards: a return the job has already passed is stale.
        guard (position.milestone, position.step) < target else {
            store.setState(jobID: jobID, key: RetryReturn.stateKey, value: nil)
            return false
        }
        let next = back.loops.compactMap { JobCenter.position(ofStep: $0, in: plan) }
            .filter { ($0.milestone, $0.step) > (position.milestone, position.step) && ($0.milestone, $0.step) < target }
            .min { ($0.milestone, $0.step) < ($1.milestone, $1.step) }
        if let next {
            record.cursor.milestoneIndex = next.milestone
            record.cursor.stepIndex = next.step
            // Keep the iteration the loop's items belong to, so they aren't rebuilt.
            record.cursor.waitIteration = Int(store.state(jobID: jobID, key: "materialized:\(next.stepID)") ?? "") ?? 0
        } else {
            record.cursor = back.cursor
            record.nextWakeAt = back.wakeAt
            store.setState(jobID: jobID, key: RetryReturn.stateKey, value: nil)
            log(ActivityEntry(kind: .recovery, title: "Retried the failed items; carrying on from where the job was"))
        }
        callsWithoutProgress = 0
        persist()
        return true
    }

    // MARK: - Checkpoints, budgets, stuck detection

    /// Throws when the job must stop here: stopped, paused, over budget or stuck.
    private func checkpoint() throws {
        if let i = interruption() { throw i }
    }

    private func interruption() -> Interrupt? {
        if gate.isStopped || Task.isCancelled { return .stopped }
        if gate.isPaused { return .paused("Paused") }
        if let b = budgetInterruption() { return b }
        let stuck = max(1, record.budget.stuckTurns)
        if callsWithoutProgress >= stuck {
            callsWithoutProgress = 0
            return .needsInput("I seem to be stuck on \(stuckOn.isEmpty ? "this step" : stuckOn): \(stuck) tries in a row made no progress. Check the activity log, then resume or stop the job.")
        }
        return nil
    }

    private func budgetInterruption() -> Interrupt? {
        tick()
        let b = record.budget, u = record.usage
        if let max = b.maxCostUSD, u.costUSD >= max {
            store.setState(jobID: jobID, key: "budgetStop", value: "cost")
            return .needsInput("This job reached its cost budget (\(Self.dollars(max)), spent \(Self.dollars(u.costUSD))). Resume to allow another \(Self.dollars(max)), or stop it.")
        }
        if let max = b.maxDurationSeconds, u.activeSeconds >= max {
            store.setState(jobID: jobID, key: "budgetStop", value: "duration")
            return .needsInput("This job reached its time budget (\(Self.duration(max)) of work). Resume to allow another \(Self.duration(max)), or stop it.")
        }
        if let max = b.maxModelCalls, u.modelCalls >= max {
            store.setState(jobID: jobID, key: "budgetStop", value: "calls")
            return .needsInput("This job reached its budget of \(max) model calls. Resume to allow another \(max), or stop it.")
        }
        return nil
    }

    static func dollars(_ v: Double) -> String { String(format: "$%.2f", v) }

    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .short
        return f.string(from: max(0, seconds)) ?? "\(Int(seconds)) s"
    }

    /// Adds running time to `activeSeconds`, leaving out time spent waiting for the user: for
    /// approvals, and for the screen (until they're idle, or behind another job's on-screen
    /// step). Uses a clock that stops while the Mac sleeps.
    private func tick() {
        let now = clock.now
        if waitsInProgress > 0, let start = waitStart {
            excludedSeconds += Self.seconds(now - max(start, lastTick))
            waitStart = now
        }
        let elapsed = Self.seconds(now - lastTick) - excludedSeconds
        excludedSeconds = 0
        lastTick = now
        if elapsed > 0 { record.usage.activeSeconds += elapsed }
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    // MARK: - Executing steps

    private func makeAgentCallbacks() -> AgentCallbacks {
        let store = self.store, jobID = self.jobID, sink = callbacks
        return AgentCallbacks(
            phase: { _, _ in },
            log: { entry in
                store.appendEvent(jobID: jobID, entry)
                sink.log(entry)
            },
            plan: { _, _ in },
            approve: { [weak self] request in
                guard let self else { return .stop }
                return await self.requestApproval(request)
            })
    }

    /// Runs one step through the executor: takes the screen lease for on-screen routes, counts
    /// usage, and turns errors into either a failed result (worth retrying) or an interrupt.
    private func execute(_ request: StepRequest) async throws -> StepResult {
        let needsScreen = request.step.route.needsScreen
        if needsScreen {
            let line = record.statusLine
            record.statusLine = settings.jobs.screenUse == .whenIdle ? "Waiting until you're idle to use the screen…" : "Waiting to use the screen…"
            callbacks.update(record)
            // Waiting for the user to step away (or for another job's on-screen step) can take
            // hours; it mustn't use up the job's time budget.
            waitBegan()
            do {
                try await acquireLease()
            } catch {
                waitEnded()
                throw error
            }
            waitEnded()
            record.statusLine = line
        }
        callsWithoutProgress += 1
        let result: StepResult
        do {
            result = try await executor.execute(request, callbacks: makeAgentCallbacks())
        } catch {
            if needsScreen { await lease.release(owner: leaseOwner) }
            if gate.isStopped || Task.isCancelled || error is CancellationError { throw Interrupt.stopped }
            if let e = error as? AutomationError, e == .stopped { throw Interrupt.paused("Paused because Glide's Stop was pressed. Resume to continue.") }
            if let i = error as? Interrupt { throw i }
            if let e = error as? LLMError {
                switch e {
                case .missingKey, .notConfigured: throw Interrupt.needsInput(e.localizedDescription)
                case .http(let code, _) where code == 401 || code == 403: throw Interrupt.needsInput(e.localizedDescription)
                default: break
                }
            }
            return StepResult(status: .failed(error.localizedDescription))
        }
        if needsScreen { await lease.release(owner: leaseOwner) }
        addUsage(result, route: request.step.route)
        return result
    }

    /// Waits for the screen lease, giving up promptly when the job is paused or stopped
    /// (waiting for the user to be idle can take a long time).
    private func acquireLease() async throws {
        let lease = self.lease, owner = leaseOwner, gate = self.gate
        let screenUse = settings.jobs.screenUse, idle = settings.jobs.idleSeconds
        let granted: Bool
        do {
            granted = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await lease.acquire(owner: owner, screenUse: screenUse, idleSeconds: idle)
                    return true
                }
                group.addTask {
                    while gate.current == .running { try await Task.sleep(for: .milliseconds(250)) }
                    return false
                }
                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }
        } catch let e as ScreenLease.LeaseError {
            throw Interrupt.needsInput(e.localizedDescription)
        } catch {
            await lease.release(owner: owner)
            throw Interrupt.stopped
        }
        if !granted {
            // The acquire may have succeeded just as the watcher fired; never keep the lease.
            await lease.release(owner: owner)
            throw gate.isStopped ? Interrupt.stopped : Interrupt.paused("Paused")
        }
    }

    private func addUsage(_ result: StepResult, route: ExecutionRoute) {
        var u = record.usage
        u.modelCalls += result.modelCalls
        u.inputTokens += result.usage.inputTokens
        u.outputTokens += result.usage.outputTokens
        if result.usage.inputTokens + result.usage.outputTokens > 0 {
            if let model = config.actorModel, let cost = ModelPricing.cost(model: model, usage: result.usage) {
                u.costUSD += cost
            } else {
                u.costKnown = false
            }
        }
        if route.needsScreen { u.actions += result.actions } else { u.toolCalls += result.actions }
        record.usage = u
    }

    private func requestApproval(_ request: ApprovalRequest) async -> ApprovalDecision {
        if gate.isStopped || Task.isCancelled { return .stop }
        waitBegan()
        let line = record.statusLine
        let waitingLine = "Waiting for your OK: \(request.title)"
        record.statusLine = waitingLine
        persist()
        let decision = await callbacks.approve(request)
        waitEnded()
        // Other items may have moved the progress line on meanwhile; only undo our own text.
        if record.statusLine == waitingLine { record.statusLine = line }
        switch decision {
        case .approve: log(ActivityEntry(kind: .approval, title: "Approved: \(request.title)", success: true))
        case .reject: log(ActivityEntry(kind: .approval, title: "Declined: \(request.title)", success: false))
        case .stop:
            log(ActivityEntry(kind: .approval, title: "Stopped at: \(request.title)", success: false))
            stop()
        }
        persist()
        return decision
    }

    private func waitBegan() {
        tick()
        waitsInProgress += 1
        if waitsInProgress == 1 { waitStart = clock.now }
    }

    private func waitEnded() {
        tick()
        waitsInProgress = max(0, waitsInProgress - 1)
        if waitsInProgress == 0 { waitStart = nil }
    }

    private func askToStart(_ m: Milestone, index: Int, of count: Int) async throws {
        var detail = m.description.isEmpty ? "" : m.description + "\n\n"
        detail += "Steps:\n" + m.steps.map { "• \($0.title)" }.joined(separator: "\n")
        if record.usage.itemsTotal > 0 {
            detail += "\n\nSo far: \(record.usage.itemsDone) of \(record.usage.itemsTotal) items done" + (record.usage.itemsFailed > 0 ? ", \(record.usage.itemsFailed) failed." : ".")
        }
        let request = ApprovalRequest(kind: .action, title: "Start “\(m.title)”?", detail: detail, appName: nil, risk: .high,
                                      reasons: ["Part \(index + 1) of \(count) of this job may act on your behalf"])
        switch await requestApproval(request) {
        case .approve:
            store.setState(jobID: jobID, key: "approved:\(m.id)", value: "1")
        case .reject:
            throw Interrupt.needsInput("You declined “\(m.title)”. Resume to be asked again, or stop the job.")
        case .stop:
            throw Interrupt.stopped
        }
    }

    // MARK: - Action steps

    private func runAction(_ step: JobStep, _ r: RecipeStep, milestoneIndex: Int) async throws {
        let attempts = max(1, record.budget.maxItemAttempts)
        var lastFailure = ""
        for attempt in 1...attempts {
            try checkpoint()
            record.statusLine = r.title.isEmpty ? step.title : r.title
            stuckOn = "“\(step.title)”"
            persist()
            log(ActivityEntry(kind: .step, title: step.title + (attempt > 1 ? " (try \(attempt))" : ""), detail: r.instruction, route: r.route, stepID: step.id))
            var context = await JobContextBuilder.build(record: record, milestoneIndex: milestoneIndex, step: r, parentTitle: nil, item: nil, workspace: workspace)
            if attempt > 1 { context += "\n\nThe previous try failed: \(lastFailure.prefix(400)). Try a different approach." }
            let request = StepRequest(goal: record.plan?.goal ?? record.instruction, step: r, context: context, allowedCategories: r.route.toolCategories,
                                      jobID: jobID, itemID: nil, workspace: workspace, maxTurns: config.maxTurnsPerStep)
            let started = clock.now
            let result = try await execute(request)
            let ms = Self.seconds(clock.now - started) * 1000
            switch result.status {
            case .done, .taskDone:
                var output = result.output
                if case .taskDone(let message) = result.status, !message.isEmpty { output = message }
                if !output.isEmpty {
                    await workspace.setFact("step:\(step.id)", output)
                    if record.cursor.waitIteration > 0 { await workspace.setFact("step:\(step.id):run\(record.cursor.waitIteration + 1)", output) }
                }
                var fields = result.fields
                if fields.isEmpty, !output.isEmpty { fields["output"] = .string(String(output.prefix(4000))) }
                fields["step"] = .string(step.title)
                store.upsertRow(jobID: jobID, table: "steps", key: "\(step.id)", fields: fields, order: Double(step.id))
                log(ActivityEntry(kind: .verify, title: "Finished: \(step.title)", detail: output.isEmpty ? nil : String(output.prefix(500)), route: r.route,
                                  success: true, durationMs: ms, stepID: step.id))
                advanceStep()
                return
            case .failed(let reason):
                lastFailure = reason
                log(ActivityEntry(kind: .error, title: "Step failed: \(step.title)", detail: reason, route: r.route, success: false, durationMs: ms, stepID: step.id))
            case .blocked(let reason):
                throw Interrupt.needsInput(reason.isEmpty ? "“\(step.title)” needs you." : reason)
            }
        }
        throw Interrupt.failed("Couldn't complete “\(step.title)”: \(lastFailure)")
    }

    // MARK: - Loops

    private func runForEach(_ step: JobStep, _ planned: ForEachSpec, milestoneIndex: Int) async throws {
        let spec = withSourceSheet(planned)
        let iteration = record.cursor.waitIteration
        try materializeIfNeeded(step, spec, iteration: iteration)
        if store.resetRunningItems(jobID: jobID, stepID: step.id) > 0 {
            log(ActivityEntry(kind: .info, title: "Re-queued items that were interrupted", stepID: step.id))
        }
        let maxAttempts = max(1, record.budget.maxItemAttempts)
        let needsScreen = spec.recipe.contains { $0.route.needsScreen }
        let width = needsScreen ? 1 : min(max(spec.parallelism, 1), 8)
        let total = store.itemCount(jobID: jobID, stepID: step.id)
        pendingWriteBack = [:]
        finishedThisVisit = []
        refreshCounts()
        updateLoopStatus(step, spec)
        persist()
        if total == 0 {
            log(ActivityEntry(kind: .info, title: "Nothing to do for “\(step.title)”: no items", stepID: step.id))
            advanceStep()
            return
        }
        writeBackEnabled = try await writeBackAllowed(step, spec)
        var interrupt: Interrupt?
        do {
            while interrupt == nil {
                let queue = store.runnableItems(jobID: jobID, stepID: step.id, maxAttempts: maxAttempts)
                if queue.isEmpty { break }
                if queue.contains(where: { finishedThisVisit.contains($0.id) }) {
                    throw Interrupt.failed("Couldn't save the job's progress (the disk may be full or the database read-only). Free some space, then resume.")
                }
                interrupt = try await process(queue, step: step, spec: spec, width: width, milestoneIndex: milestoneIndex, iteration: iteration, total: total)
            }
        } catch {
            flushWriteBack(spec)
            throw error
        }
        flushWriteBack(spec)
        if let interrupt { throw interrupt }
        if writeBackEnabled { try writeBackAll(step, spec) }
        let c = store.progressCounts(jobID: jobID, stepID: step.id, maxAttempts: maxAttempts)
        log(ActivityEntry(kind: .result, title: "Finished “\(step.title)”: \(c.done) of \(c.total) done" + (c.failed > 0 ? ", \(c.failed) failed" : ""),
                          success: c.failed == 0, stepID: step.id))
        advanceStep()
    }

    /// Runs `queue` with at most `width` items in flight. Returns the reason to stop early
    /// (after the items in flight finish), or nil when the queue is done.
    private func process(_ queue: [JobItem], step: JobStep, spec: ForEachSpec, width: Int, milestoneIndex: Int, iteration: Int, total: Int) async throws -> Interrupt? {
        var interrupt: Interrupt?
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = queue.makeIterator()
            var inFlight = 0
            while inFlight < width, interrupt == nil {
                interrupt = loopInterruption(step)
                guard interrupt == nil, let item = pending.next() else { break }
                group.addTask { try await self.processItem(item, step: step, spec: spec, milestoneIndex: milestoneIndex, iteration: iteration, total: total) }
                inFlight += 1
            }
            while inFlight > 0 {
                try await group.next()
                inFlight -= 1
                if interrupt == nil { interrupt = loopInterruption(step) }
                if interrupt == nil, let item = pending.next() {
                    group.addTask { try await self.processItem(item, step: step, spec: spec, milestoneIndex: milestoneIndex, iteration: iteration, total: total) }
                    inFlight += 1
                }
            }
        }
        return interrupt
    }

    /// Checkpoint between items: everything `checkpoint()` checks, plus the failure rate.
    private func loopInterruption(_ step: JobStep) -> Interrupt? {
        if let i = interruption() { return i }
        let maxAttempts = max(1, record.budget.maxItemAttempts)
        let c = store.progressCounts(jobID: jobID, stepID: step.id, maxAttempts: maxAttempts)
        let baseline = store.state(jobID: jobID, key: "failureBaseline:\(step.id)")?.split(separator: ",").compactMap { Int($0) } ?? []
        let doneBase = baseline.count == 2 ? baseline[0] : 0, failedBase = baseline.count == 2 ? baseline[1] : 0
        let done = max(0, c.done - doneBase), failed = max(0, c.failed - failedBase)
        let completed = done + failed
        if completed >= 5, failed > 0, Double(failed) / Double(completed) > record.budget.maxFailureRate {
            // Count from here next time, so resuming doesn't immediately stop again.
            store.setState(jobID: jobID, key: "failureBaseline:\(step.id)", value: "\(c.done),\(c.failed)")
            let latest = store.items(jobID: jobID, stepID: step.id, status: .failed).max { $0.updatedAt < $1.updatedAt }?.error
            return .needsInput("\(failed) of the last \(completed) items of “\(step.title)” failed" + (latest.map { " (latest: \($0.prefix(200)))" } ?? "")
                               + ". Check them, then resume to continue or retry the failed ones.")
        }
        return nil
    }

    private func processItem(_ original: JobItem, step: JobStep, spec: ForEachSpec, milestoneIndex: Int, iteration: Int, total: Int) async throws {
        let maxAttempts = max(1, record.budget.maxItemAttempts)
        var item = original
        item.status = .running
        item.attempts += 1
        item.error = nil
        item.updatedAt = config.now()
        store.saveItem(item)
        stuckOn = "\(spec.itemLabel) “\(item.title)” in “\(step.title)”"
        var partial: [String: JSONValue] = [:]
        var notes: [String] = []
        var failure: String?
        var blocked = false
        let started = clock.now
        do {
            for r in spec.recipe {
                if gate.isStopped || Task.isCancelled { throw Interrupt.stopped }
                // The prompt sees the previous attempt's error so a retry can try something else.
                var shown = item
                shown.error = original.error
                let ctx = JobContextBuilder.ItemContext(item: shown, label: spec.itemLabel, total: total, partial: partial)
                let context = await JobContextBuilder.build(record: record, milestoneIndex: milestoneIndex, step: r, parentTitle: step.title, item: ctx, workspace: workspace)
                let request = StepRequest(goal: record.plan?.goal ?? record.instruction, step: r, context: context, allowedCategories: r.route.toolCategories,
                                          jobID: jobID, itemID: item.id, workspace: workspace, maxTurns: config.maxTurnsPerStep)
                let result = try await execute(request)
                switch result.status {
                case .done:
                    partial.merge(result.fields) { $1 }
                    if !result.output.isEmpty { notes.append(result.output) }
                case .taskDone(let message):
                    partial.merge(result.fields) { $1 }
                    if !message.isEmpty { notes.append(message) } else if !result.output.isEmpty { notes.append(result.output) }
                case .failed(let reason):
                    failure = spec.recipe.count > 1 ? "\(r.title): \(reason)" : reason
                case .blocked(let reason):
                    failure = reason.isEmpty ? "Needs you: \(r.title)" : reason
                    blocked = true
                }
                if failure != nil { break }
            }
        } catch {
            // Stopped or interrupted mid-item: put it back as it was, so the interrupted
            // attempt doesn't count and the item runs again on resume.
            item.status = original.status == .failed ? .failed : .pending
            item.attempts = original.attempts
            item.error = original.error
            item.updatedAt = config.now()
            store.saveItem(item)
            throw error
        }
        let ms = Self.seconds(clock.now - started) * 1000
        // The item's browser tab (if it used one) is no longer needed.
        if spec.recipe.contains(where: { $0.route == .browser }) {
            await BrowserSessions.shared.release(jobID: jobID, itemID: item.id)
        }
        if let failure {
            item.status = .failed
            item.error = String(failure.prefix(1000))
            // Waiting on the user won't fix itself by retrying right away.
            if blocked { item.attempts = max(item.attempts, maxAttempts) }
            item.result = partial.isEmpty ? nil : .object(partial)
            item.updatedAt = config.now()
            store.saveItem(item)
            let final = item.attempts >= maxAttempts
            log(ActivityEntry(kind: .error, title: "\(final ? "Failed" : "Will retry"): \(item.title)", detail: failure, success: false, durationMs: ms, stepID: step.id))
        } else {
            if partial.isEmpty, !notes.isEmpty { partial["notes"] = .string(String(notes.joined(separator: "\n").prefix(4000))) }
            item.status = .done
            item.result = .object(partial)
            item.error = nil
            item.updatedAt = config.now()
            store.saveItem(item)
            let key = iteration > 0 ? "\(item.title) (run \(iteration + 1))" : item.title
            store.upsertRow(jobID: jobID, table: spec.outputTable, key: key, fields: partial, order: Double(iteration) * 1_000_000 + Double(item.index))
            callsWithoutProgress = 0
            finishedThisVisit.insert(item.id)
            if writeBackEnabled, let wb = spec.writeBack, let update = Self.writeBackUpdate(item, wb) {
                pendingWriteBack[update.key, default: [:]].merge(update.values) { $1 }
            }
            log(ActivityEntry(kind: .result, title: "Done: \(item.title)", detail: partial.isEmpty ? nil : String(JSONValue.object(partial).jsonString().prefix(400)),
                              success: true, durationMs: ms, stepID: step.id))
        }
        refreshCounts()
        updateLoopStatus(step, spec)
        persist()
        if pendingWriteBack.count >= config.writeBackEvery { flushWriteBack(spec) }
    }

    private func refreshCounts() {
        let c = store.progressCounts(jobID: jobID, maxAttempts: max(1, record.budget.maxItemAttempts))
        record.usage.itemsTotal = c.total
        record.usage.itemsDone = c.done
        record.usage.itemsFailed = c.failed
        record.usage.itemsSkipped = c.skipped
    }

    private func updateLoopStatus(_ step: JobStep, _ spec: ForEachSpec) {
        let c = store.progressCounts(jobID: jobID, stepID: step.id, maxAttempts: max(1, record.budget.maxItemAttempts))
        var line = "\(step.title) · \(c.done + c.failed + c.skipped)/\(c.total) \(JobPlanner.pluralize(spec.itemLabel, c.total))"
        if c.failed > 0 { line += " · \(c.failed) failed" }
        record.statusLine = line
    }

    // MARK: Items

    /// Reads the loop's items once per run of its milestone and stores them. Doing it once means
    /// a resumed job works through the same list even if the source changed meanwhile.
    private func materializeIfNeeded(_ step: JobStep, _ spec: ForEachSpec, iteration: Int) throws {
        let key = "materialized:\(step.id)"
        if store.state(jobID: jobID, key: key) == "\(iteration)" { return }
        // A new daily run (or a half-finished earlier attempt): start from a fresh list.
        store.deleteItems(jobID: jobID, stepID: step.id)
        store.setState(jobID: jobID, key: "failureBaseline:\(step.id)", value: nil)
        var entries = try loadItems(spec.source)
        if let limit = spec.limit, limit >= 0 { entries = Array(entries.prefix(limit)) }
        if entries.count > config.maxItems {
            log(ActivityEntry(kind: .info, title: "Using the first \(config.maxItems) of \(entries.count) items", stepID: step.id))
            entries = Array(entries.prefix(config.maxItems))
        }
        // Titles key the result table, so make them unique ("Acme", "Acme (2)").
        var seen: [String: Int] = [:]
        var items: [JobItem] = []
        for entry in entries {
            var title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { title = "\(spec.itemLabel.capitalized) \(entry.index + 1)" }
            title = String(title.prefix(200))
            let n = (seen[title.lowercased()] ?? 0) + 1
            seen[title.lowercased()] = n
            if n > 1 { title += " (\(n))" }
            items.append(JobItem(jobID: jobID, stepID: step.id, index: entry.index, title: title, input: entry.input))
        }
        store.insertItems(items)
        store.setState(jobID: jobID, key: key, value: "\(iteration)")
        log(ActivityEntry(kind: .info, title: "Found \(items.count) \(JobPlanner.pluralize(spec.itemLabel, items.count)) for “\(step.title)”", stepID: step.id))
    }

    struct SourceEntry {
        var index: Int
        var title: String
        var input: JSONValue
    }

    private func loadItems(_ source: ItemSource) throws -> [SourceEntry] {
        switch source {
        case .file(let path, let sheet, let column, let hasHeader):
            let resolved = resolvePath(path)
            let reader = config.tableReader ?? TableIO.reader
            let table: TableData
            do { table = try reader(resolved, sheet, hasHeader) } catch {
                throw Interrupt.failed("Couldn't read the items from \(resolved): \(error.localizedDescription)")
            }
            let labelIndex = column.flatMap { c in table.columns.firstIndex { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(c.trimmingCharacters(in: .whitespaces)) == .orderedSame } }
            var out: [SourceEntry] = []
            for (i, row) in table.rows.enumerated() {
                guard row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { continue }
                var obj: [String: JSONValue] = [:]
                for (ci, c) in table.columns.enumerated() { obj[c] = .string(ci < row.count ? row[ci] : "") }
                let title = labelIndex.flatMap { $0 < row.count ? row[$0] : nil } ?? row.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                out.append(SourceEntry(index: i, title: title, input: .object(obj)))
            }
            return out
        case .table(let name):
            return store.rows(jobID: jobID, table: name, limit: config.maxItems + 1).enumerated().map { i, row in
                var fields = row.fields
                if fields["key"] == nil { fields["key"] = .string(row.key) }
                return SourceEntry(index: i, title: row.key, input: .object(fields))
            }
        case .list(let values):
            return values.enumerated().map { SourceEntry(index: $0.offset, title: $0.element, input: .string($0.element)) }
        case .stepOutput(let stepID):
            guard let list = stepList(stepID) else {
                throw Interrupt.failed("Step \(stepID) didn't produce a list to work through.")
            }
            return list.enumerated().map { i, v in SourceEntry(index: i, title: Self.title(of: v), input: v) }
        }
    }

    /// The list an earlier action step produced: an array field of its result (preferring
    /// common names), a JSON array in its output, or its output's lines.
    private func stepList(_ stepID: Int) -> [JSONValue]? {
        let fields = store.row(jobID: jobID, table: "steps", key: "\(stepID)")?.fields ?? [:]
        let preferred = ["items", "list", "results", "data", "rows", "urls", "names", "entries"]
        for key in preferred + fields.keys.sorted() {
            guard let v = JobWriteBack.field(key, in: fields) else { continue }
            if let a = v.arrayValue, !a.isEmpty { return a }
            if let s = v.stringValue, let parsed = try? JSONValue.parse(s), let a = parsed.arrayValue, !a.isEmpty { return a }
        }
        let output = fields["output"]?.stringValue ?? store.facts(jobID: jobID, limit: 2000).first { $0.key == "step:\(stepID)" }?.value ?? ""
        if let parsed = try? JSONValue.parse(output), let a = parsed.arrayValue, !a.isEmpty { return a }
        let lines = output.split(whereSeparator: \.isNewline).map { line -> String in
            var s = line.trimmingCharacters(in: .whitespaces)
            if let r = s.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression) { s.removeSubrange(r) }
            return s
        }.filter { !$0.isEmpty }
        return lines.count > 1 ? lines.map { .string($0) } : nil
    }

    static func title(of v: JSONValue) -> String {
        if let o = v.objectValue {
            for k in ["title", "name", "label", "company", "url", "email", "id"] {
                let match = o[k] ?? o.first(where: { $0.key.lowercased() == k })?.value
                if let s = match?.stringValue, !s.isEmpty { return s }
            }
            return o.keys.sorted().compactMap { o[$0]?.stringValue }.first { !$0.isEmpty } ?? ""
        }
        return v.stringValue ?? v.jsonString()
    }

    private func resolvePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: record.folder).appendingPathComponent(expanded).path
    }

    // MARK: Write-back

    /// Writing results into a spreadsheet that already exists changes the user's file, so the
    /// job asks once per loop (the answer is remembered across pauses, restarts and daily
    /// runs). Declining keeps the results in the job's table, ready to export.
    private func writeBackAllowed(_ step: JobStep, _ spec: ForEachSpec) async throws -> Bool {
        guard let wb = spec.writeBack, !wb.columns.isEmpty else { return false }
        // The updaters read a file's first row as its column names. In the headerless file the
        // items came from, they'd write the new column names over the first item's row and put
        // every result one row too low.
        if case .file(let path, _, _, false) = spec.source, sameFile(path, wb.path) {
            let name = (wb.path as NSString).lastPathComponent
            log(ActivityEntry(kind: .info, title: "Results will stay in the job instead of \(name)",
                              detail: "\(name) has no header row, so results can't be matched to its rows safely. Export them as CSV when the job is done.",
                              stepID: step.id))
            return false
        }
        let key = "writeBack:\(step.id)"
        if let answer = store.state(jobID: jobID, key: key) { return answer == "approved" }
        let path = resolvePath(wb.path)
        let verdict = SafetyPolicy.Verdict(risk: .high, reasons: ["changes cells in a file you already have"], blocked: nil)
        // A file the job creates itself needs no OK.
        guard FileManager.default.fileExists(atPath: path), SafetyPolicy(settings: settings.safety).needsApproval(verdict) else {
            store.setState(jobID: jobID, key: key, value: "approved")
            return true
        }
        let name = (path as NSString).lastPathComponent
        let request = ApprovalRequest(kind: .tool, title: "Write results into \(name)?",
                                      detail: "“\(step.title)” will fill in \(wb.columns.joined(separator: ", ")) in \(path) as it goes. A backup copy of the file is kept next to it.",
                                      appName: nil, risk: .high, reasons: verdict.reasons)
        switch await requestApproval(request) {
        case .approve:
            store.setState(jobID: jobID, key: key, value: "approved")
            return true
        case .reject:
            store.setState(jobID: jobID, key: key, value: "declined")
            log(ActivityEntry(kind: .info, title: "Results will stay in the job instead of \(name)", detail: "Export them as CSV when the job is done."))
            return false
        case .stop:
            throw Interrupt.stopped
        }
    }

    /// Writing back into the file the items came from goes to the sheet they came from. The
    /// planner may leave the write-back's sheet out, and the updater would then pick the first
    /// sheet and write results by row number into the rows of a different table.
    private func withSourceSheet(_ spec: ForEachSpec) -> ForEachSpec {
        guard var wb = spec.writeBack, wb.sheet == nil, case .file(let path, let sheet?, _, _) = spec.source, sameFile(path, wb.path) else { return spec }
        var spec = spec
        wb.sheet = sheet
        spec.writeBack = wb
        return spec
    }

    private func sameFile(_ a: String, _ b: String) -> Bool {
        func canonical(_ p: String) -> String { URL(fileURLWithPath: resolvePath(p)).standardizedFileURL.resolvingSymlinksInPath().path }
        return canonical(a) == canonical(b)
    }

    static func writeBackUpdate(_ item: JobItem, _ wb: WriteBack) -> (key: String, values: [String: String])? {
        let fields = item.result?.objectValue ?? [:]
        var values: [String: String] = [:]
        for column in wb.columns {
            if let v = JobWriteBack.field(column, in: fields) { values[column] = JobWriteBack.cell(v) }
        }
        guard !values.isEmpty else { return nil }
        let key: String
        if let kc = wb.keyColumn {
            let input = item.input.objectValue ?? [:]
            key = (JobWriteBack.field(kc, in: input) ?? JobWriteBack.field(kc, in: fields)).map(JobWriteBack.cell) ?? item.title
        } else {
            key = String(item.index)
        }
        return (key, values)
    }

    /// Writes the batch collected so far. A failure is logged and left for the final write,
    /// which rewrites every finished item.
    private func flushWriteBack(_ spec: ForEachSpec) {
        guard writeBackEnabled, let wb = spec.writeBack, !pendingWriteBack.isEmpty else { return }
        let batch = pendingWriteBack
        pendingWriteBack = [:]
        do {
            try JobWriteBack.write(resolvePath(wb.path), wb, batch, injected: config.tableUpdater, owner: record.id)
            log(ActivityEntry(kind: .tool, title: "Wrote \(batch.count) result\(batch.count == 1 ? "" : "s") to \((wb.path as NSString).lastPathComponent)", route: .data, success: true))
        } catch {
            log(ActivityEntry(kind: .error, title: "Couldn't write results to \((wb.path as NSString).lastPathComponent) yet", detail: error.localizedDescription, route: .data, success: false))
        }
    }

    private func writeBackAll(_ step: JobStep, _ spec: ForEachSpec) throws {
        guard let wb = spec.writeBack else { return }
        var updates: [String: [String: String]] = [:]
        for item in store.items(jobID: jobID, stepID: step.id, status: .done) {
            if let u = Self.writeBackUpdate(item, wb) { updates[u.key, default: [:]].merge(u.values) { $1 } }
        }
        guard !updates.isEmpty else { return }
        let path = resolvePath(wb.path)
        do {
            try JobWriteBack.write(path, wb, updates, injected: config.tableUpdater, owner: record.id)
            log(ActivityEntry(kind: .tool, title: "Wrote results for \(updates.count) \(JobPlanner.pluralize(spec.itemLabel, updates.count)) to \((path as NSString).lastPathComponent)", route: .data, success: true))
        } catch {
            throw Interrupt.needsInput("Couldn't write the results back to \(path): \(error.localizedDescription). They're saved in the job; resume to try again.")
        }
    }

    // MARK: - Waits

    private func runWait(_ step: JobStep, _ wait: WaitSpec, milestone: Milestone) async throws {
        let now = config.now()
        switch wait {
        case .duration(let seconds):
            if let wake = record.nextWakeAt {
                if wake <= now { return finishWait(step, "Done waiting") }
                try sleepUntil( wake, "Waiting until \(Self.time(wake))")
            }
            guard seconds > 0 else { return finishWait(step, nil) }
            let wake = now.addingTimeInterval(seconds)
            try sleepUntil( wake, "Waiting until \(Self.time(wake))")
        case .until(let date):
            if date <= now || (record.nextWakeAt.map { $0 <= now } ?? false) { return finishWait(step, "Done waiting") }
            try sleepUntil( date, "Waiting until \(Self.time(date))")
        case .daily(let hour, let minute, let times):
            if let times, times <= 0 {
                record.cursor.stepIndex = milestone.steps.count
                persist()
                return
            }
            let runLabel = times.map { "run \(record.cursor.waitIteration + 1) of \($0)" } ?? "run \(record.cursor.waitIteration + 1)"
            if let wake = record.nextWakeAt {
                if wake <= now { return finishWait(step, "Starting the daily \(runLabel)") }
                try sleepUntil( wake, "Next \(runLabel) at \(Self.time(wake))")
            }
            let wake = Self.nextDaily(hour: hour, minute: minute, after: now)
            try sleepUntil( wake, "Next \(runLabel) at \(Self.time(wake))")
        case .condition(let check, let every, let maxTries):
            if let wake = record.nextWakeAt, wake > now { try sleepUntil( wake, "Checking again at \(Self.time(wake))") }
            record.nextWakeAt = nil
            let triesKey = "conditionTries:\(step.id)"
            let tries = Int(store.state(jobID: jobID, key: triesKey) ?? "") ?? 0
            if try await conditionMet(step, check) {
                store.setState(jobID: jobID, key: triesKey, value: nil)
                return finishWait(step, "Condition met: \(check)")
            }
            let n = tries + 1
            if n >= max(1, maxTries) {
                store.setState(jobID: jobID, key: triesKey, value: nil)
                throw Interrupt.needsInput("I checked “\(check)” \(n) time\(n == 1 ? "" : "s") and it isn't true yet. Resume to keep checking, or stop the job.")
            }
            store.setState(jobID: jobID, key: triesKey, value: "\(n)")
            let wake = config.now().addingTimeInterval(max(1, every))
            try sleepUntil( wake, "Not yet (check \(n) of \(maxTries)); checking again at \(Self.time(wake))")
        }
    }

    private func finishWait(_ step: JobStep, _ message: String?) {
        record.nextWakeAt = nil
        if let message { log(ActivityEntry(kind: .info, title: message, stepID: step.id)) }
        advanceStep()
    }

    /// Persists the job as waiting until `date` and unwinds; the scheduler starts a new runner then.
    private func sleepUntil(_ date: Date, _ line: String) throws -> Never {
        record.nextWakeAt = date
        record.status = .waiting
        record.statusLine = line
        persist()
        log(ActivityEntry(kind: .info, title: line))
        throw Interrupt.waiting
    }

    private func conditionMet(_ step: JobStep, _ check: String) async throws -> Bool {
        try checkpoint()
        let route = Self.conditionRoute(check)
        let r = RecipeStep(id: 30_000 + step.id, title: "Checking: \(String(check.prefix(60)))",
                           instruction: "Check whether this is true right now: \(check). Set met to true only if it clearly is, and say what you saw in details.",
                           route: route, doneWhen: "You know whether it's true", outputFields: ["met", "details"])
        stuckOn = "the check “\(check)”"
        record.statusLine = r.title
        persist()
        let context = await JobContextBuilder.build(record: record, milestoneIndex: record.cursor.milestoneIndex, step: r, parentTitle: nil, item: nil, workspace: workspace)
        let result = try await execute(StepRequest(goal: record.plan?.goal ?? record.instruction, step: r, context: context, allowedCategories: route.toolCategories,
                                                   jobID: jobID, workspace: workspace, maxTurns: config.maxTurnsPerStep))
        switch result.status {
        case .done, .taskDone:
            let met = result.fields["met"]?.truthy ?? false
            await workspace.setFact("check:\(step.id)", (met ? "met: " : "not yet: ") + (result.fields["details"]?.stringValue ?? result.output))
            callsWithoutProgress = 0
            return met
        case .failed(let reason), .blocked(let reason):
            log(ActivityEntry(kind: .error, title: "Couldn't check “\(check)”", detail: reason, route: route, success: false, stepID: step.id))
            return false
        }
    }

    /// Where a condition is best checked, from its wording.
    static func conditionRoute(_ check: String) -> ExecutionRoute {
        let t = " " + check.lowercased() + " "
        let local = [" file", " folder", " disk", " download", " process", " running", " app ", " installed", " directory", "~/", " /users/"]
        let personal = [" my ", " account", " inbox", " dashboard", " logged", " log in", " order", " cart", " portal"]
        if local.contains(where: t.contains) { return .command }
        if personal.contains(where: t.contains) { return .browser }
        return .web
    }

    static func nextDaily(hour: Int, minute: Int, after date: Date) -> Date {
        let cal = Calendar.current
        let comps = DateComponents(hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0)
        return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }

    static func time(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = Calendar.current.isDate(date, inSameDayAs: Date()) ? "HH:mm" : "EEE d MMM, HH:mm"
        return df.string(from: date)
    }

    // MARK: - Verification

    /// Checks a finished milestone against its done condition. Returns true to move on; false
    /// after adding a remedial step (at most 2 per milestone) that the loop runs next.
    private func verify(_ m: Milestone, index: Int) async throws -> Bool {
        guard !m.doneWhen.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        try checkpoint()
        record.statusLine = "Checking “\(m.title)”"
        stuckOn = "checking “\(m.title)”"
        persist()
        let summary = await workspace.summary(maxChars: 3000)
        let r = RecipeStep(id: 10_000 + m.id, title: "Checking “\(m.title)”",
                           instruction: "Decide whether this part of the job is complete. It is done when: \(m.doneWhen). Judge only from the job's saved results; set done to true or false and give a short reason.",
                           route: .answer, doneWhen: "You've decided", outputFields: ["done", "reason"])
        let context = "Milestone: \(m.title)\(m.description.isEmpty ? "" : " — \(m.description)")\nDone when: \(m.doneWhen)\n\nSaved results:\n\(summary)"
        let result = try await execute(StepRequest(goal: record.plan?.goal ?? record.instruction, step: r, context: context, allowedCategories: [.workspace],
                                                   jobID: jobID, workspace: workspace, maxTurns: 4))
        let reason: String
        switch result.status {
        case .failed(let why), .blocked(let why):
            // A verifier hiccup shouldn't fail work that's already done.
            log(ActivityEntry(kind: .verify, title: "Couldn't check “\(m.title)”; continuing", detail: why))
            return true
        case .done, .taskDone:
            if result.fields["done"]?.truthy ?? true {
                log(ActivityEntry(kind: .verify, title: "Milestone done: \(m.title)", detail: result.fields["reason"]?.stringValue, success: true))
                return true
            }
            reason = result.fields["reason"]?.stringValue ?? (result.output.isEmpty ? "it isn't complete yet" : result.output)
        }
        let key = "remedial:\(m.id)"
        let used = Int(store.state(jobID: jobID, key: key) ?? "") ?? 0
        guard used < 2, var plan = record.plan, plan.milestones.indices.contains(index) else {
            throw Interrupt.failed("Couldn't finish “\(m.title)”: \(reason)")
        }
        let newID = (plan.milestones.flatMap(\.steps).map(\.id).max() ?? 0) + 1
        let recipes = m.steps.flatMap { s -> [RecipeStep] in
            switch s.kind {
            case .action(let r): return [r]
            case .forEach(let spec): return spec.recipe
            case .wait: return []
            }
        }
        let route = recipes.last { $0.route != .answer }?.route ?? recipes.last?.route ?? .web
        let risk = recipes.map(\.risk).max() ?? .low
        let fix = RecipeStep(id: newID, title: "Finishing “\(m.title)”",
                             instruction: "This part of the job isn't complete yet: \(reason). Do what's missing so that: \(m.doneWhen). Save what you find in the job's memory.",
                             route: route, risk: risk, doneWhen: m.doneWhen)
        plan.milestones[index].steps.append(JobStep(id: newID, title: fix.title, kind: .action(fix)))
        record.plan = plan
        record.cursor.stepIndex = plan.milestones[index].steps.count - 1
        store.setState(jobID: jobID, key: key, value: "\(used + 1)")
        log(ActivityEntry(kind: .recovery, title: "Adding a step to finish “\(m.title)”", detail: reason))
        persist()
        return false
    }

    // MARK: - Finish

    private func finishWithReport() async throws {
        if gate.isStopped || Task.isCancelled { throw Interrupt.stopped }
        record.statusLine = "Writing the report"
        persist()
        let overview = await workspace.summary(maxChars: 4000)
        var text = ""
        // Over budget at the very end: write the report without another model call.
        if budgetInterruption() == nil {
            let r = RecipeStep(id: 20_000, title: "Writing the report",
                               instruction: "Write the final report for this job in Markdown: what was done, the key results (from the saved tables and facts), anything that failed and why, and where the outputs are. Put the whole report in the summary field.",
                               route: .answer, doneWhen: "The report is written", outputFields: ["summary"])
            let u = record.usage
            let context = "Usage: \(u.itemsDone) of \(u.itemsTotal) items done, \(u.itemsFailed) failed; \(u.modelCalls) model calls; \(Self.duration(u.activeSeconds)) of work.\n\nSaved results:\n\(overview)"
            let result = try await execute(StepRequest(goal: record.plan?.goal ?? record.instruction, step: r, context: context, allowedCategories: [.workspace],
                                                       jobID: jobID, workspace: workspace, maxTurns: 4))
            switch result.status {
            case .done: text = result.fields["summary"]?.stringValue ?? result.output
            case .taskDone(let message): text = result.fields["summary"]?.stringValue ?? (message.isEmpty ? result.output : message)
            case .failed(let why), .blocked(let why): log(ActivityEntry(kind: .error, title: "Couldn't write the report with the model", detail: why))
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = fallbackSummary() }
        writeReport(text)
        record.summary = text
        record.status = .completed
        record.nextWakeAt = nil
        let u = record.usage
        record.statusLine = u.itemsTotal > 0 ? "Done · \(u.itemsDone)/\(u.itemsTotal)" + (u.itemsFailed > 0 ? " · \(u.itemsFailed) failed" : "") : "Done"
        log(ActivityEntry(kind: .result, title: "Job finished", detail: String(text.prefix(500)), success: true))
        persist()
    }

    private func fallbackSummary() -> String {
        let u = record.usage
        var lines = ["Finished: \(record.plan?.goal ?? record.title)."]
        if u.itemsTotal > 0 { lines.append("\(u.itemsDone) of \(u.itemsTotal) items done" + (u.itemsFailed > 0 ? ", \(u.itemsFailed) failed." : ".")) }
        let tables = store.tableNames(jobID: jobID).filter { $0 != "steps" }
        if !tables.isEmpty { lines.append("Results: " + tables.map { "\($0) (\(store.rowCount(jobID: jobID, table: $0)) rows)" }.joined(separator: ", ") + ".") }
        return lines.joined(separator: " ")
    }

    private func writeReport(_ summary: String) {
        let u = record.usage
        var md = "# \(record.title)\n\n_Finished \(DateFormatter.localizedString(from: config.now(), dateStyle: .medium, timeStyle: .short))_\n\n\(summary)\n\n## Details\n\n"
        if u.itemsTotal > 0 { md += "- Items: \(u.itemsDone) done, \(u.itemsFailed) failed, \(u.itemsSkipped) skipped of \(u.itemsTotal)\n" }
        for t in store.tableNames(jobID: jobID) where t != "steps" { md += "- Table “\(t)”: \(store.rowCount(jobID: jobID, table: t)) rows\n" }
        md += "- Work time: \(Self.duration(u.activeSeconds))\n- Model calls: \(u.modelCalls) (\(u.inputTokens + u.outputTokens) tokens)\n"
        if u.costUSD > 0 || u.costKnown { md += "- Estimated cost: \(Self.dollars(u.costUSD))\(u.costKnown ? "" : " (partly unknown)")\n" }
        md += "- Request: \(record.instruction)\n"
        let url = URL(fileURLWithPath: record.folder, isDirectory: true).appendingPathComponent("report.md")
        do {
            try FileManager.default.createDirectory(atPath: record.folder, withIntermediateDirectories: true)
            try Data(md.utf8).write(to: url, options: .atomic)
        } catch {
            log(ActivityEntry(kind: .error, title: "Couldn't write report.md", detail: error.localizedDescription))
        }
    }

    // MARK: - Persistence

    private func persist() {
        tick()
        record.updatedAt = config.now()
        store.saveJob(record)
        callbacks.update(record)
    }

    private func log(_ entry: ActivityEntry) {
        store.appendEvent(jobID: jobID, entry)
        callbacks.log(entry)
    }
}
