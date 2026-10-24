import Foundation
import Observation

/// UI-facing owner of long-running jobs: the list, live progress, controls and approvals.
/// The app and glidectl talk to jobs only through this type; `JobRunner` does the work.
///
/// CONTRACT: the public API below is what the UI is built against. The job engine fills in
/// the implementation without changing these signatures.
@MainActor
@Observable
public final class JobCenter {
    public static let shared = JobCenter()

    /// All known jobs, newest first.
    public private(set) var jobs: [JobRecord] = []
    /// Approval requests waiting for the user, keyed by job id.
    public private(set) var pendingApprovals: [String: ApprovalRequest] = [:]

    /// A job needs the user (approval, question, stuck, finished). Argument: job id.
    public var onAttentionNeeded: ((String) -> Void)?
    /// A job reached completed/failed/stopped.
    public var onJobFinished: ((JobRecord) -> Void)?

    /// Everything the center depends on. Production wires the shared store, settings, the
    /// planning model and the installed step router; tests inject their own.
    struct Environment {
        var store: JobStore
        var settings: @MainActor () -> AppSettings
        var planner: @Sendable (AppSettings) -> any JobPlanning
        var planningContext: @Sendable (String, AppSettings) async -> JobPlanningContext
        /// The step executor, or nil when the step-runner layer isn't installed.
        var executor: @Sendable (AppSettings) -> (any StepExecuting)?
        var lease: ScreenLease
        /// Actor and planner model names, for pricing.
        var models: @Sendable (AppSettings) -> (actor: String?, planner: String?)
        var keepAwake: (@MainActor (Bool) -> Void)?
        /// Moves a deleted job's folder out of the way (production: to the Trash).
        var removeFolder: @Sendable (URL) throws -> Void
        var now: @Sendable () -> Date = { Date() }
        var schedulerMaxSleep: Double = 60

        static func production() -> Environment {
            Environment(
                store: .shared,
                settings: { SettingsStore.shared.settings },
                planner: { JobPlanner(router: ModelRouter(settings: $0)) },
                planningContext: { request, settings in await JobPlanningContext.gather(request: request, settings: settings) },
                executor: { settings in
                    StepExecutorFactory.make.map { $0(settings, AutomationRuntime.shared, ToolRegistry.standard(settings: settings)) }
                },
                lease: .shared,
                models: { settings in
                    let router = ModelRouter(settings: settings)
                    return ((try? router.route(.actor))?.model, (try? router.route(.planner))?.model)
                },
                keepAwake: { PowerAssertion.shared.update(active: $0) },
                removeFolder: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        }
    }

    private struct RunnerHandle {
        let runner: JobRunner
        let task: Task<Void, Never>
    }

    @ObservationIgnored private var environment: Environment?
    @ObservationIgnored private var runners: [String: RunnerHandle] = [:]
    /// Jobs waiting for a free slot (`maxConcurrentJobs`), in order.
    @ObservationIgnored private var queue: [String] = []
    /// Approvals per job, oldest first; `pendingApprovals` shows the head of each.
    @ObservationIgnored private var approvalQueues: [String: [(request: ApprovalRequest, continuation: CheckedContinuation<ApprovalDecision, Never>)]] = [:]
    /// Jobs deleted while their runner was still unwinding; removed once it finishes.
    @ObservationIgnored private var pendingDeletion: Set<String> = []
    /// Running jobs asked to pause; they finish the items in flight first.
    @ObservationIgnored private var pausing: Set<String> = []
    @ObservationIgnored private var scheduler: JobScheduler?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var previewItems: [String: [JobItem]]?
    @ObservationIgnored private var previewEvents: [String: [ActivityEntry]]?

    public init() {}

    init(environment: Environment) {
        self.environment = environment
    }

    private var env: Environment {
        if let e = environment { return e }
        let e = Environment.production()
        environment = e
        return e
    }

    /// The job currently running in the foreground of attention (most recently updated running job).
    public var activeJob: JobRecord? {
        jobs.filter { $0.status == .running || $0.status == .planning }.max { $0.updatedAt < $1.updatedAt }
    }

    public func job(_ id: String) -> JobRecord? { jobs.first { $0.id == id } }

    /// Whether a runner is still attached to the job (it may be unwinding after its last update).
    func hasRunner(_ id: String) -> Bool { runners[id] != nil }

    /// Call once at app launch: loads jobs, resumes interrupted ones (per settings) and
    /// schedules waiting ones.
    public func launch() {
        guard !launched else { return }
        launched = true
        reload()
        let settings = env.settings()
        let actions = JobScheduler.launchActions(for: jobs, autoResume: settings.jobs.autoResume)
        // Oldest first, so queued jobs keep their order.
        for job in jobs.reversed() {
            guard let action = actions[job.id], var r = env.store.job(job.id) else { continue }
            switch action {
            case .resume:
                log(job.id, ActivityEntry(kind: .info, title: "Continuing after Glide restarted"))
                startOrQueue(job.id)
            case .markInterrupted:
                r.status = .paused
                r.statusLine = "Interrupted — resume to continue"
                r.lastError = "Glide quit while this job was running."
                save(r)
            case .markPlanningFailed:
                r.status = .failed
                r.statusLine = "Failed: planning was interrupted"
                r.lastError = "Planning was interrupted when Glide quit. Try the request again."
                save(r)
            }
        }
        reschedule()
    }

    /// Reloads the list from disk.
    public func reload() {
        jobs = env.store.allJobs().filter { !pendingDeletion.contains($0.id) }
    }

    /// Plans a job from a request. Small jobs (under the confirmation thresholds) start right
    /// away when `autoStartIfSmall`; others stop at `.awaitingConfirmation` with an estimate.
    @discardableResult
    public func create(instruction: String, autoStartIfSmall: Bool = true) async -> JobRecord {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = env.settings()
        let id = UUID().uuidString
        let folder = env.store.ensureFolder(for: id)
        var record = JobRecord(id: id, title: Self.shortTitle(text.isEmpty ? "Untitled job" : text), instruction: text, status: .planning,
                               folder: folder.path, budget: settings.jobs.defaultBudget)
        record.statusLine = "Planning…"
        guard !text.isEmpty else {
            record.status = .failed
            record.lastError = "The request is empty."
            record.statusLine = "Failed: empty request"
            save(record)
            return record
        }
        save(record)
        log(id, ActivityEntry(kind: .plan, title: "Planning the job", detail: text))

        let planner = env.planner(settings)
        let context = await env.planningContext(text, settings)
        let outcome: JobPlanOutcome
        do {
            outcome = try await planner.plan(text, context: context)
        } catch {
            // Stopped or deleted while planning: leave it as the user left it.
            guard var r = env.store.job(id), r.status == .planning else { return env.store.job(id) ?? record }
            r.status = .failed
            r.lastError = error.localizedDescription
            r.statusLine = "Couldn't plan this job"
            save(r)
            log(id, ActivityEntry(kind: .error, title: "Couldn't plan the job", detail: error.localizedDescription, success: false))
            onAttentionNeeded?(id)
            return r
        }
        guard var r = env.store.job(id), r.status == .planning else { return env.store.job(id) ?? record }
        let models = env.models(settings)
        r.usage.modelCalls += outcome.modelCalls
        r.usage.inputTokens += outcome.usage.inputTokens
        r.usage.outputTokens += outcome.usage.outputTokens
        if outcome.usage.inputTokens + outcome.usage.outputTokens > 0 {
            if let model = outcome.model ?? models.planner, let cost = ModelPricing.cost(model: model, usage: outcome.usage) {
                r.usage.costUSD += cost
            } else {
                r.usage.costKnown = false
            }
        }
        var plan = outcome.plan
        guard !plan.milestones.isEmpty else {
            let question = plan.clarification ?? "I couldn't turn this into a job. Could you say more about what you want done?"
            r.plan = plan
            r.status = .needsInput
            r.statusLine = question
            r.lastError = question
            save(r)
            log(id, ActivityEntry(kind: .info, title: "Needs you", detail: question))
            onAttentionNeeded?(id)
            return r
        }
        // Counting spreadsheet rows can take a moment for big files; keep it off the main thread.
        let planned = plan
        let counts = await Task.detached(priority: .userInitiated) { Self.itemCounts(planned) }.value
        guard env.store.job(id)?.status == .planning else { return env.store.job(id) ?? r }
        let estimate = JobPlanner.estimate(plan, items: counts, actorModel: models.actor, plannerModel: outcome.model ?? models.planner)
        plan.estimate = estimate
        r.plan = plan
        if !plan.goal.isEmpty { r.title = Self.shortTitle(plan.goal) }
        log(id, ActivityEntry(kind: .plan, title: "Planned \(plan.milestones.count) milestone\(plan.milestones.count == 1 ? "" : "s"), \(plan.stepCount) step\(plan.stepCount == 1 ? "" : "s")",
                              detail: Self.outline(plan)))
        // Unknown prices can't be compared with the cost threshold; the time estimate still applies.
        let small = (estimate.costUSD ?? 0) <= settings.jobs.confirmAboveCostUSD && estimate.minutes <= settings.jobs.confirmAboveMinutes
        if autoStartIfSmall && small {
            r.statusLine = "Starting…"
            save(r)
            startOrQueue(id)
        } else {
            r.status = .awaitingConfirmation
            r.statusLine = "Confirm to start: " + Self.describe(estimate)
            save(r)
            onAttentionNeeded?(id)
        }
        return env.store.job(id) ?? r
    }

    /// Starts a job that is awaiting confirmation.
    public func start(_ id: String) {
        guard let r = env.store.job(id), r.status == .awaitingConfirmation else { return }
        log(id, ActivityEntry(kind: .approval, title: "Confirmed by you", success: true))
        startOrQueue(id)
    }

    public func pause(_ id: String) {
        if let handle = runners[id] {
            handle.runner.pause()
            pausing.insert(id)
            if var r = job(id) {
                r.statusLine = "Pausing after the current step…"
                upsert(r)
            }
            return
        }
        guard var r = env.store.job(id) else { return }
        // A sleeping or queued job just stops being scheduled; its wake time is kept.
        guard r.status == .waiting else { return }
        queue.removeAll { $0 == id }
        r.status = .paused
        r.statusLine = "Paused"
        save(r)
        log(id, ActivityEntry(kind: .info, title: "Paused"))
        reschedule()
    }

    public func resume(_ id: String) {
        guard runners[id] == nil, !queue.contains(id), var r = env.store.job(id), r.status.isResumable else { return }
        let now = env.now()
        // Resuming a sleeping job means "go now".
        if r.status == .waiting, let wake = r.nextWakeAt, wake > now { r.nextWakeAt = now }
        if let kind = env.store.state(jobID: id, key: "budgetStop") {
            Self.extendBudget(&r, kind: kind)
            env.store.setState(jobID: id, key: "budgetStop", value: nil)
        }
        if r.status == .failed { env.store.clearState(jobID: id, prefix: "remedial:") }
        r.lastError = nil
        save(r)
        log(id, ActivityEntry(kind: .info, title: "Resumed by you"))
        startOrQueue(id)
    }

    public func stop(_ id: String) {
        resolveApprovals(id, with: .stop)
        if let handle = runners[id] {
            handle.runner.stop()
            handle.task.cancel()
            return
        }
        queue.removeAll { $0 == id }
        guard var r = env.store.job(id), !r.status.isFinished else { return }
        r.status = .stopped
        r.nextWakeAt = nil
        r.statusLine = "Stopped"
        save(r)
        log(id, ActivityEntry(kind: .info, title: "Stopped by you"))
        onJobFinished?(r)
        reschedule()
    }

    /// Re-queues failed items of a finished or paused job and resumes it.
    public func retryFailedItems(_ id: String) {
        if runners[id] != nil {
            // The running loop picks them up when it next looks for work.
            env.store.requeueFailedItems(jobID: id)
            return
        }
        guard var r = env.store.job(id), let plan = r.plan, r.status != .planning, r.status != .awaitingConfirmation else { return }
        let steps = env.store.requeueFailedItems(jobID: id)
        guard !steps.isEmpty else { return }
        for s in steps { env.store.setState(jobID: id, key: "failureBaseline:\(s)", value: nil) }
        // Move back to the earliest loop with re-queued items if the job is already past it.
        let positions = steps.compactMap { Self.position(ofStep: $0, in: plan) }.sorted { ($0.milestone, $0.step) < ($1.milestone, $1.step) }
        if let first = positions.first, (first.milestone, first.step) < (r.cursor.milestoneIndex, r.cursor.stepIndex) {
            r.cursor.milestoneIndex = first.milestone
            r.cursor.stepIndex = first.step
            // Keep the iteration the loop's items belong to, so they aren't rebuilt.
            r.cursor.waitIteration = Int(env.store.state(jobID: id, key: "materialized:\(first.stepID)") ?? "") ?? 0
            env.store.clearState(jobID: id, prefix: "remedial:")
        }
        let c = env.store.progressCounts(jobID: id, maxAttempts: max(1, r.budget.maxItemAttempts))
        r.usage.itemsTotal = c.total
        r.usage.itemsDone = c.done
        r.usage.itemsFailed = c.failed
        r.usage.itemsSkipped = c.skipped
        r.status = .paused
        r.nextWakeAt = nil
        r.lastError = nil
        r.statusLine = "Retrying failed items…"
        save(r)
        log(id, ActivityEntry(kind: .recovery, title: "Retrying failed items"))
        startOrQueue(id)
    }

    /// Deletes the job's record (its folder is moved to the Trash).
    public func delete(_ id: String) {
        resolveApprovals(id, with: .stop)
        queue.removeAll { $0 == id }
        jobs.removeAll { $0.id == id }
        pendingApprovals[id] = nil
        if let handle = runners[id] {
            // Delete once the runner has unwound, so its last writes don't resurrect the job.
            pendingDeletion.insert(id)
            handle.runner.stop()
            handle.task.cancel()
            return
        }
        performDeletion(id)
    }

    private func performDeletion(_ id: String) {
        pendingDeletion.remove(id)
        let folder = env.store.job(id).map { URL(fileURLWithPath: $0.folder, isDirectory: true) } ?? env.store.folder(for: id)
        env.store.deleteJob(id)
        jobs.removeAll { $0.id == id }
        // Only ever remove folders Glide created for jobs.
        let root = env.store.jobsRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let target = folder.standardizedFileURL.resolvingSymlinksInPath()
        if target.path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: target.path) {
            try? env.removeFolder(target)
        }
        reschedule()
    }

    /// Answers a pending approval for a job.
    public func respond(jobID: String, decision: ApprovalDecision) {
        guard var q = approvalQueues[jobID], !q.isEmpty else {
            pendingApprovals[jobID] = nil
            return
        }
        let head = q.removeFirst()
        approvalQueues[jobID] = q.isEmpty ? nil : q
        pendingApprovals[jobID] = q.first?.request
        head.continuation.resume(returning: decision)
        if decision == .stop {
            resolveApprovals(jobID, with: .stop)
        } else if !q.isEmpty {
            onAttentionNeeded?(jobID)
        }
    }

    public func items(_ jobID: String, limit: Int = 1000) -> [JobItem] {
        if let preview = previewItems { return Array((preview[jobID] ?? []).prefix(limit)) }
        return env.store.items(jobID: jobID, limit: limit)
    }

    public func events(_ jobID: String, limit: Int = 300) -> [ActivityEntry] {
        if let preview = previewEvents { return Array((preview[jobID] ?? []).suffix(limit)) }
        return env.store.events(jobID: jobID, limit: limit)
    }

    /// Writes the job's result table(s) as CSV to `url`. The main results (the first loop's
    /// table) go to `url`; any other tables go next to it as `<name>-<table>.csv`.
    public func exportResults(_ jobID: String, to url: URL) throws {
        guard let record = env.store.job(jobID) ?? job(jobID) else { throw JobCenterError.notFound }
        let existing = env.store.tableNames(jobID: jobID).filter { env.store.rowCount(jobID: jobID, table: $0) > 0 }
        let loops: [ForEachSpec] = record.plan?.milestones.flatMap(\.steps).compactMap {
            if case .forEach(let spec) = $0.kind { return spec }
            return nil
        } ?? []
        var ordered: [String] = []
        for spec in loops where existing.contains(spec.outputTable) && !ordered.contains(spec.outputTable) { ordered.append(spec.outputTable) }
        for t in existing where t != "steps" && !ordered.contains(t) { ordered.append(t) }
        if ordered.isEmpty, existing.contains("steps") { ordered = ["steps"] }
        guard !ordered.isEmpty else { throw JobCenterError.nothingToExport }
        let base = url.deletingPathExtension()
        for (i, table) in ordered.enumerated() {
            let dest = i == 0 ? url : base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)-\(Self.fileSafe(table)).csv")
            let spec = loops.first { $0.outputTable == table }
            let rows = env.store.rows(jobID: jobID, table: table)
            var columns: [String] = []
            func add(_ c: String) {
                if !columns.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) { columns.append(c) }
            }
            spec?.outputColumns.forEach(add)
            for key in Set(rows.flatMap(\.fields.keys)).sorted() { add(key) }
            let keyHeader = spec.map { $0.itemLabel.isEmpty ? "Item" : $0.itemLabel.prefix(1).uppercased() + $0.itemLabel.dropFirst() } ?? (table == "steps" ? "Step" : "Key")
            let data = TableData(columns: [keyHeader] + columns, rows: rows.map { row in
                [row.key] + columns.map { c in JobWriteBack.cell(row.fields[c] ?? JobWriteBack.field(c, in: row.fields) ?? .null) }
            })
            try TableIO.writeCSV(dest.path, data)
        }
    }

    /// Sets display state directly. Used only by UI snapshots and previews.
    public func previewState(jobs: [JobRecord], approvals: [String: ApprovalRequest] = [:], items: [String: [JobItem]] = [:],
                             events: [String: [ActivityEntry]] = [:]) {
        self.jobs = jobs.sorted { $0.createdAt > $1.createdAt }
        self.pendingApprovals = approvals
        self.previewItems = items
        self.previewEvents = events
    }

    // MARK: - Running

    private func startOrQueue(_ id: String) {
        guard runners[id] == nil, !pendingDeletion.contains(id), var record = env.store.job(id) else { return }
        let settings = env.settings()
        guard record.plan != nil else {
            record.status = .failed
            record.lastError = "This job has no plan."
            record.statusLine = "Failed: no plan"
            save(record)
            onJobFinished?(record)
            return
        }
        if runners.count >= max(1, settings.jobs.maxConcurrentJobs) {
            if !queue.contains(id) { queue.append(id) }
            record.status = .waiting
            record.nextWakeAt = nil
            record.statusLine = "Queued — waiting for another job to finish"
            save(record)
            return
        }
        queue.removeAll { $0 == id }
        guard let executor = env.executor(settings) else {
            record.status = .failed
            record.lastError = "Step runner not installed"
            record.statusLine = "Failed: step runner not installed"
            save(record)
            log(id, ActivityEntry(kind: .error, title: "Step runner not installed", success: false))
            onJobFinished?(record)
            onAttentionNeeded?(id)
            return
        }
        record.status = .running
        save(record)
        let models = env.models(settings)
        let configuration = JobRunner.Configuration(actorModel: models.actor, now: env.now, maxTurnsPerStep: settings.limits.maxActionsPerStep)
        let callbacks = JobRunner.Callbacks(
            update: { [weak self] r in Task { @MainActor in self?.runnerUpdated(r) } },
            log: { _ in },
            approve: { [weak self] request in
                guard let self else { return .stop }
                return await self.enqueueApproval(jobID: id, request)
            })
        let runner = JobRunner(record: record, store: env.store, executor: executor, lease: env.lease, settings: settings,
                               callbacks: callbacks, configuration: configuration)
        let task = Task { [weak self] in
            let final = await runner.run()
            self?.runnerFinished(id, final)
        }
        runners[id] = RunnerHandle(runner: runner, task: task)
        updateKeepAwake()
    }

    private func runnerUpdated(_ r: JobRecord) {
        // Late updates from a finished runner are superseded by its final record.
        guard runners[r.id] != nil, !pendingDeletion.contains(r.id) else { return }
        var r = r
        if pausing.contains(r.id), r.status == .running { r.statusLine = "Pausing after the current step…" }
        upsert(r)
    }

    private func runnerFinished(_ id: String, _ final: JobRecord) {
        runners[id] = nil
        pausing.remove(id)
        resolveApprovals(id, with: .stop)
        if pendingDeletion.contains(id) {
            performDeletion(id)
        } else {
            upsert(final, force: true)
            switch final.status {
            case .completed, .failed, .stopped:
                onJobFinished?(final)
                onAttentionNeeded?(id)
            case .needsInput:
                onAttentionNeeded?(id)
            default:
                break
            }
        }
        drainQueue()
        reschedule()
        updateKeepAwake()
    }

    private func drainQueue() {
        let max = Swift.max(1, env.settings().jobs.maxConcurrentJobs)
        while runners.count < max, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let r = env.store.job(id), r.status == .waiting, r.nextWakeAt == nil else { continue }
            startOrQueue(id)
        }
    }

    private func reschedule() {
        if scheduler == nil {
            let s = JobScheduler(maxSleepSeconds: env.schedulerMaxSleep, now: env.now) { [weak self] id in self?.wake(id) }
            s.currentJobs = { [weak self] in
                guard let self else { return [] }
                return self.jobs.filter { self.runners[$0.id] == nil }
            }
            scheduler = s
        }
        scheduler?.reschedule(jobs.filter { runners[$0.id] == nil })
    }

    private func wake(_ id: String) {
        guard runners[id] == nil, let r = env.store.job(id), r.status == .waiting, let wake = r.nextWakeAt, wake <= env.now() else { return }
        log(id, ActivityEntry(kind: .info, title: "Waking up"))
        startOrQueue(id)
    }

    private func updateKeepAwake() {
        env.keepAwake?(!runners.isEmpty && env.settings().jobs.keepAwake)
    }

    // MARK: - Approvals

    private func enqueueApproval(jobID: String, _ request: ApprovalRequest) async -> ApprovalDecision {
        guard runners[jobID] != nil, !pendingDeletion.contains(jobID) else { return .stop }
        return await withCheckedContinuation { (c: CheckedContinuation<ApprovalDecision, Never>) in
            approvalQueues[jobID, default: []].append((request, c))
            if pendingApprovals[jobID] == nil {
                pendingApprovals[jobID] = request
                onAttentionNeeded?(jobID)
            }
        }
    }

    private func resolveApprovals(_ jobID: String, with decision: ApprovalDecision) {
        let waiting = approvalQueues.removeValue(forKey: jobID) ?? []
        pendingApprovals[jobID] = nil
        for w in waiting { w.continuation.resume(returning: decision) }
    }

    // MARK: - Helpers

    private func save(_ r: JobRecord) {
        var r = r
        r.updatedAt = env.now()
        env.store.saveJob(r)
        upsert(r, force: true)
    }

    private func upsert(_ r: JobRecord, force: Bool = false) {
        guard !pendingDeletion.contains(r.id) else { return }
        if let i = jobs.firstIndex(where: { $0.id == r.id }) {
            if force || r.updatedAt >= jobs[i].updatedAt { jobs[i] = r }
        } else {
            jobs.append(r)
            jobs.sort { $0.createdAt > $1.createdAt }
        }
    }

    private func log(_ jobID: String, _ entry: ActivityEntry) {
        env.store.appendEvent(jobID: jobID, entry)
    }

    nonisolated static func extendBudget(_ r: inout JobRecord, kind: String) {
        switch kind {
        case "cost":
            if let max = r.budget.maxCostUSD { r.budget.maxCostUSD = r.usage.costUSD + Swift.max(max, 0.01) }
        case "duration":
            if let max = r.budget.maxDurationSeconds { r.budget.maxDurationSeconds = r.usage.activeSeconds + Swift.max(max, 60) }
        case "calls":
            if let max = r.budget.maxModelCalls { r.budget.maxModelCalls = r.usage.modelCalls + Swift.max(max, 1) }
        default:
            break
        }
    }

    /// Item counts per loop, where they can be known before running (lists and files).
    nonisolated static func itemCounts(_ plan: JobPlan) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for step in plan.milestones.flatMap(\.steps) {
            guard case .forEach(let spec) = step.kind else { continue }
            switch spec.source {
            case .list(let values): out[step.id] = values.count
            case .file(let path, let sheet, _, let hasHeader):
                if let t = try? TableIO.reader((path as NSString).expandingTildeInPath, sheet, hasHeader) { out[step.id] = t.rows.count }
            case .table, .stepOutput: break
            }
        }
        return out
    }

    nonisolated static func position(ofStep stepID: Int, in plan: JobPlan) -> (milestone: Int, step: Int, stepID: Int)? {
        for (mi, m) in plan.milestones.enumerated() {
            if let si = m.steps.firstIndex(where: { $0.id == stepID }) { return (mi, si, stepID) }
        }
        return nil
    }

    nonisolated static func shortTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? text
        guard line.count > 60 else { return line }
        let cut = line.prefix(60)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > 30 { return String(cut[..<space]) + "…" }
        return String(cut) + "…"
    }

    nonisolated static func outline(_ plan: JobPlan) -> String {
        plan.milestones.enumerated().map { mi, m in
            "\(mi + 1). \(m.title)\(m.requiresApproval ? " (asks first)" : "")\n" + m.steps.map { s -> String in
                switch s.kind {
                case .action(let r): return "   • \(s.title) [\(r.route.rawValue)]"
                case .forEach(let spec): return "   • \(s.title) — for each \(spec.itemLabel), \(spec.recipe.count) step\(spec.recipe.count == 1 ? "" : "s")"
                case .wait: return "   • \(s.title) (wait)"
                }
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    nonisolated static func describe(_ e: JobEstimate) -> String {
        var parts: [String] = []
        if e.items > 0 { parts.append("\(e.items) items") }
        parts.append(e.minutes < 1 ? "under a minute" : "about \(Int(e.minutes.rounded())) min")
        if let c = e.costUSD { parts.append(String(format: "~$%.2f", c)) }
        return parts.joined(separator: ", ")
    }

    nonisolated static func fileSafe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}

public enum JobCenterError: Error, LocalizedError, Sendable {
    case notFound
    case nothingToExport

    public var errorDescription: String? {
        switch self {
        case .notFound: return "That job doesn't exist anymore."
        case .nothingToExport: return "This job has no results to export yet."
        }
    }
}
