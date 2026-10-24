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

    /// Which jobs a center looks after on its own: wakes them when they're due, continues them
    /// when it finds them interrupted or another process lets go of them, and pauses them on
    /// the emergency stop.
    public enum Scope: Sendable {
        /// Every job in the store (the app).
        case allJobs
        /// Only the jobs it was asked to create, start, resume or retry. glidectl shares the
        /// app's store; looking after everything there would take the app's jobs over (with
        /// glidectl's settings and nobody answering their approvals) and leave them half done
        /// when glidectl exits.
        case ownJobs
    }

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
        /// Closes the browser tabs a job opened (when it ends without its runner doing so).
        var releaseBrowser: @Sendable (String) async -> Void = { await BrowserSessions.shared.releaseJob($0) }
        /// How often jobs another process is running are re-checked.
        var elsewherePollSeconds: Double = 2
        /// Which jobs the center looks after on its own (glidectl: only its own).
        var scope: Scope = .allJobs

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
    /// Jobs waiting for a free slot (`maxConcurrentJobs`), in order. Observed: the UI shows
    /// queued jobs differently (`isQueued`), and a job can leave the queue without a save.
    private var queue: [String] = []
    /// Approvals per job, oldest first; `pendingApprovals` shows the head of each.
    @ObservationIgnored private var approvalQueues: [String: [(request: ApprovalRequest, continuation: CheckedContinuation<ApprovalDecision, Never>)]] = [:]
    /// Jobs deleted while their runner was still unwinding; removed once it finishes.
    @ObservationIgnored private var pendingDeletion: Set<String> = []
    /// Running jobs asked to pause; they finish the items in flight first.
    @ObservationIgnored private var pausing: Set<String> = []
    /// Jobs interrupted by the emergency stop; they end as `.paused` (resumable), not `.stopped`.
    @ObservationIgnored private var halting: Set<String> = []
    /// Jobs `saveHaltedForExit` saved while their runner was still unwinding. That runner no
    /// longer saves, so if the process is still here when it finishes, this center saves its end.
    @ObservationIgnored private var savedForExit: Set<String> = []
    @ObservationIgnored private var scheduler: JobScheduler?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var previewItems: [String: [JobItem]]?
    @ObservationIgnored private var previewEvents: [String: [ActivityEntry]]?
    /// Cross-process locks this center holds (see `JobRunLock`): the jobs it is running or
    /// planning, and briefly a job it is changing, so another process can't take it meanwhile.
    @ObservationIgnored private var locks: [String: JobRunLock] = [:]
    /// Jobs `create` is planning.
    @ObservationIgnored private var planningIDs: Set<String> = []
    @ObservationIgnored private var elsewhereWatch: Task<Void, Never>?
    @ObservationIgnored private var watchingKeepAwake = false
    /// Jobs this center was asked to create, start, resume or retry (what `.ownJobs` looks after).
    @ObservationIgnored private var owned: Set<String> = []

    /// Jobs another process (glidectl, or a second copy of Glide) is running right now. They
    /// share the job store, so this center leaves them alone and only shows what that process
    /// saves; once it lets go, they're handled like jobs found after a restart.
    public private(set) var runningElsewhere: Set<String> = []

    public init() {}

    init(environment: Environment) {
        self.environment = environment
    }

    /// A center that uses `settings` instead of the saved settings (glidectl uses this to run
    /// with a different model provider without touching what the app has saved). glidectl
    /// passes `.ownJobs`, so it leaves the app's jobs to the app.
    public convenience init(settingsOverride settings: AppSettings, scope: Scope = .allJobs) {
        var env = Environment.production()
        env.settings = { settings }
        env.scope = scope
        self.init(environment: env)
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

    /// Whether a runner is still working on the job in this process (it may finish its last
    /// update a moment after the status changes).
    public func isRunnerActive(_ id: String) -> Bool { runners[id] != nil }

    /// Whether another process (glidectl, or a second copy of Glide) is running the job.
    public func isRunningElsewhere(_ id: String) -> Bool { runningElsewhere.contains(id) }

    /// Whether the job is waiting for a free slot (Settings › Jobs limits how many run at once)
    /// rather than sleeping until a time. It starts by itself when another job finishes, and
    /// `resume` can't move it ahead. Its record can't tell: a wait that came due keeps its wake
    /// time while it's queued.
    public func isQueued(_ id: String) -> Bool { queue.contains(id) }

    /// Whether this center looks after the job on its own (see `Scope`).
    private func looksAfter(_ id: String) -> Bool { env.scope == .allJobs || owned.contains(id) }

    /// Call once at app launch: loads jobs, resumes interrupted ones (per settings) and
    /// schedules waiting ones.
    public func launch() {
        guard !launched else { return }
        launched = true
        loadJobs()
        recover(jobs, afterRestart: true)
        reschedule()
    }

    /// Handles each of `records` that was left running, planning or queued with nobody working
    /// on it, oldest first so queued jobs keep their order.
    private func recover(_ records: [JobRecord], afterRestart: Bool) {
        let actions = JobScheduler.launchActions(for: records, autoResume: env.settings().jobs.autoResume)
        for r in records.reversed() where actions[r.id] != nil {
            recover(r.id, afterRestart: afterRestart)
        }
    }

    /// Handles a job left running, planning or queued with nobody working on it: found at
    /// launch, or let go by another process before it finished.
    private func recover(_ id: String, afterRestart: Bool) {
        // Another process is working on it: leave it alone until that process lets go. A job
        // this center doesn't look after is left alone too.
        guard looksAfter(id), claim(id) else { return }
        defer { releaseIfIdle(id) }
        guard var r = env.store.job(id) else {
            jobs.removeAll { $0.id == id }
            return
        }
        // Decided from what's saved now: the other process may have finished the job, or put it
        // to sleep, between the list being read and its lock being let go.
        guard let action = JobScheduler.launchActions(for: [r], autoResume: env.settings().jobs.autoResume)[id] else {
            upsert(r, force: true)
            return
        }
        switch action {
        case .resume:
            log(id, ActivityEntry(kind: .info, title: afterRestart ? "Continuing after Glide restarted" : "Continuing here after the other Glide process quit"))
            startOrQueue(id)
        case .markInterrupted:
            r.status = .paused
            r.statusLine = "Interrupted — resume to continue"
            r.lastError = afterRestart ? "Glide quit while this job was running." : "The other Glide process running this job quit before it finished."
            save(r)
        case .markPlanningFailed:
            r.status = .failed
            r.statusLine = "Failed: planning was interrupted"
            r.lastError = afterRestart ? "Planning was interrupted when Glide quit. Try the request again."
                : "Planning was interrupted when the other Glide process quit. Try the request again."
            save(r)
        }
    }

    /// Reloads the list from disk, picking up what glidectl or another copy of Glide changed
    /// (the notch and Settings › Jobs call this when they open). Jobs this center is running
    /// keep their live state. Once launched, jobs another process left running, planning or
    /// queued and has let go of (it quit or crashed) are handled the way `launch` handles jobs
    /// found after a quit, and waiting jobs that turned up get their wake-ups.
    public func reload() {
        let letGo = loadJobs()
        // glidectl never launches: it leaves the app's jobs to the app.
        guard launched else { return }
        recover(letGo, afterRestart: false)
        reschedule()
    }

    /// Reads the jobs from the store and marks the ones another process is running. Returns the
    /// ones that say they're running, planning or queued although nobody is working on them:
    /// whoever was let go of them.
    @discardableResult
    private func loadJobs() -> [JobRecord] {
        let watched = runningElsewhere
        // A runner's latest update can hold lines it never saves (waiting for the screen or for
        // the user, "Pausing…"); while it runs, it's the job's only writer.
        let live = Dictionary(jobs.filter { runners[$0.id] != nil }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        jobs = env.store.allJobs().filter { !pendingDeletion.contains($0.id) }.map { stored in
            guard let mine = live[stored.id] else { return stored }
            var r = mine.updatedAt >= stored.updatedAt ? mine : stored
            if pausing.contains(r.id), r.status == .running { r.statusLine = "Pausing after the current step…" }
            return r
        }
        runningElsewhere = []
        var letGo: [JobRecord] = []
        for r in jobs where runners[r.id] == nil && locks[r.id] == nil && !planningIDs.contains(r.id) && !queue.contains(r.id) {
            // Whoever runs or plans a job holds its lock. A queued job holds none, so one queued
            // by another process only counts once this center was watching that process run it.
            let queuedElsewhere = r.status == .waiting && r.nextWakeAt == nil && watched.contains(r.id)
            guard r.status.isActive || queuedElsewhere else { continue }
            if JobRunLock.isHeld(folder: lockFolder(r.id)) { markElsewhere(r.id) } else { letGo.append(r) }
        }
        return letGo
    }

    /// Plans a job from a request. Small jobs (under the confirmation thresholds) start right
    /// away when `autoStartIfSmall`; others stop at `.awaitingConfirmation` with an estimate.
    @discardableResult
    public func create(instruction: String, autoStartIfSmall: Bool = true) async -> JobRecord {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = env.settings()
        let id = UUID().uuidString
        let folder = env.store.ensureFolder(for: id)
        // Held while planning, so another process starting meanwhile doesn't take the half-made
        // job for one interrupted by a quit.
        planningIDs.insert(id)
        _ = claim(id)
        owned.insert(id)
        defer {
            planningIDs.remove(id)
            releaseIfIdle(id)
        }
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
        guard claim(id) else { return }
        defer { releaseIfIdle(id) }
        guard let r = env.store.job(id), r.status == .awaitingConfirmation else {
            // Started, stopped or deleted elsewhere meanwhile (glidectl at its prompt while the
            // user acts in the app): show that, rather than a confirmation nothing will answer.
            refresh(id)
            return
        }
        owned.insert(id)
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
        // Changes to a job another process is running would be overwritten by (or overwrite) its own saves.
        guard claim(id) else { return }
        defer { releaseIfIdle(id) }
        // A sleeping or queued job just stops being scheduled; its wake time is kept.
        guard var r = env.store.job(id), r.status == .waiting else {
            refresh(id)
            return
        }
        queue.removeAll { $0 == id }
        r.status = .paused
        r.statusLine = "Paused"
        save(r)
        log(id, ActivityEntry(kind: .info, title: "Paused"))
        reschedule()
    }

    public func resume(_ id: String) {
        guard runners[id] == nil, !queue.contains(id), claim(id) else { return }
        defer { releaseIfIdle(id) }
        guard var r = env.store.job(id), r.status.isResumable else {
            refresh(id)
            return
        }
        owned.insert(id)
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
        guard claim(id) else { return }
        defer { releaseIfIdle(id) }
        guard var r = env.store.job(id), !r.status.isFinished else {
            refresh(id)
            return
        }
        r.status = .stopped
        r.nextWakeAt = nil
        r.statusLine = "Stopped"
        save(r)
        log(id, ActivityEntry(kind: .info, title: "Stopped by you"))
        // A run that ended paused, waiting or needing input kept the job's browser tab.
        releaseBrowserTabs(id)
        onJobFinished?(r)
        reschedule()
    }

    /// Emergency stop: cancels every running job's step in flight immediately (the same way
    /// Stop does, so commands and browser actions end now), but leaves the jobs paused so they
    /// can be resumed. Waiting and queued jobs this center looks after are paused too; glidectl's
    /// Ctrl-C must not pause the app's sleeping jobs, which would then never wake.
    public func haltAll() {
        for (id, handle) in runners { halt(id, handle) }
        for id in queue { pause(id) }
        for job in jobs where job.status == .waiting && runners[job.id] == nil && looksAfter(job.id) { pause(job.id) }
    }

    /// For a process about to exit while jobs it runs haven't finished unwinding from a halt
    /// (glidectl's Ctrl-C pressed again while a command is being ended or a browser call
    /// returns). Until their runners finish, those jobs are saved as running, or briefly as
    /// stopped, and the exit drops their locks: another Glide process would then continue them
    /// as jobs whose process quit, or couldn't resume them. This halts what still runs here and
    /// saves it as paused now; its runners save nothing more. The locks stay held until the
    /// process exits, so nothing takes the jobs over while their steps still unwind.
    public func saveHaltedForExit() {
        for (id, handle) in runners {
            halt(id, handle)
            handle.runner.detachFromStore()
            savedForExit.insert(id)
            // Deleted while its runner unwinds. The deletion waits for the runner to finish, which
            // the exit skips, so the record goes now rather than staying behind as running.
            if pendingDeletion.contains(id) {
                env.store.deleteJob(id)
                continue
            }
            // A run that already ended waiting, paused, needing input or finished saved that.
            guard var r = env.store.job(id), r.status == .running || r.status == .stopped else { continue }
            Self.markHalted(&r)
            save(r)
            log(id, ActivityEntry(kind: .info, title: "Halted by the emergency stop"))
        }
    }

    /// Ends the job's step in flight now (the way Stop does); the job ends as `.paused`.
    private func halt(_ id: String, _ handle: RunnerHandle) {
        halting.insert(id)
        resolveApprovals(id, with: .stop)
        handle.runner.stop()
        handle.task.cancel()
    }

    /// How a job the emergency stop interrupted is left: paused, so it can be resumed.
    nonisolated static func markHalted(_ r: inout JobRecord) {
        r.status = .paused
        r.statusLine = "Halted by the emergency stop — resume to continue"
    }

    /// Re-queues failed items of a finished or paused job and resumes it.
    public func retryFailedItems(_ id: String) {
        if runners[id] != nil {
            // The running loop picks them up when it next looks for work.
            env.store.requeueFailedItems(jobID: id)
            return
        }
        guard claim(id) else { return }
        defer { releaseIfIdle(id) }
        guard var r = env.store.job(id), let plan = r.plan, r.status != .planning, r.status != .awaitingConfirmation else { return }
        let steps = env.store.requeueFailedItems(jobID: id)
        guard !steps.isEmpty else { return }
        owned.insert(id)
        for s in steps { env.store.setState(jobID: id, key: "failureBaseline:\(s)", value: nil) }
        let positions = steps.compactMap { Self.position(ofStep: $0, in: plan) }.sorted { ($0.milestone, $0.step) < ($1.milestone, $1.step) }
        // Remember how far the job had got. Once the loops behind that point are redone it goes
        // straight back there, so the steps it already finished after them (sends, writes,
        // approval-gated milestones) don't run again. A return still pending from an earlier
        // retry keeps its place and gains the new loops.
        let earlier = JobRunner.RetryReturn.load(jobID: id, store: env.store).flatMap { JobRunner.RetryReturn.precedes(r.cursor, $0.cursor) ? $0 : nil }
        let reached = earlier?.cursor ?? r.cursor
        let behind = positions.filter { ($0.milestone, $0.step) < (reached.milestoneIndex, reached.stepIndex) }.map(\.stepID)
        if !behind.isEmpty {
            // A wait the job was sleeping in keeps its due time for when the job gets back to it.
            JobRunner.RetryReturn(cursor: reached, loops: Array(Set((earlier?.loops ?? []) + behind)).sorted(),
                                  wakeAt: earlier.map(\.wakeAt) ?? r.nextWakeAt).save(jobID: id, store: env.store)
        }
        // Move back to the earliest loop with re-queued items if the job is already past it.
        if let first = positions.first, (first.milestone, first.step) < (r.cursor.milestoneIndex, r.cursor.stepIndex) {
            r.cursor.milestoneIndex = first.milestone
            r.cursor.stepIndex = first.step
            // Keep the iteration the loop's items belong to, so they aren't rebuilt.
            r.cursor.waitIteration = Int(env.store.state(jobID: id, key: "materialized:\(first.stepID)") ?? "") ?? 0
            // The loops run first. The wait the job was sleeping in, if any, gets its due time
            // back with the return above instead of starting over.
            r.nextWakeAt = nil
            env.store.clearState(jobID: id, prefix: "remedial:")
        }
        let c = env.store.progressCounts(jobID: id, maxAttempts: max(1, r.budget.maxItemAttempts))
        r.usage.itemsTotal = c.total
        r.usage.itemsDone = c.done
        r.usage.itemsFailed = c.failed
        r.usage.itemsSkipped = c.skipped
        // A job that stays where it is (sleeping in a wait before the loops) keeps its wake time.
        r.status = .paused
        r.lastError = nil
        r.statusLine = "Retrying failed items…"
        save(r)
        log(id, ActivityEntry(kind: .recovery, title: "Retrying failed items"))
        startOrQueue(id)
    }

    /// Deletes the job's record (its folder is moved to the Trash).
    public func delete(_ id: String) {
        // Another process is running it; deleting would pull its records out from under it.
        guard runners[id] != nil || claim(id) else { return }
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
        // The lock file lives in the folder that's about to go.
        locks.removeValue(forKey: id)?.release()
        releaseBrowserTabs(id)
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

    /// Writes the job's result table(s) as CSV. The main results (the first loop's table) go to
    /// `url`, the file the user picked; any other tables go next to it as `<name>-<table>.csv`.
    /// The user never saw those names, so an existing file is never replaced: " 2", " 3"… is
    /// added instead.
    public func exportResults(_ jobID: String, to url: URL) throws {
        try exportResultFiles(jobID, to: url)
    }

    /// `exportResults`, returning every file written (`url` first), so callers can show them all.
    @discardableResult
    public func exportResultFiles(_ jobID: String, to url: URL) throws -> [URL] {
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
        var written: [URL] = []
        for (i, table) in ordered.enumerated() {
            let dest = i == 0 ? url : Self.unusedExportURL(in: base.deletingLastPathComponent(), name: "\(base.lastPathComponent)-\(Self.fileSafe(table))", besides: written)
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
            written.append(dest)
        }
        return written
    }

    /// `<name>.csv` in `folder`, or `<name> 2.csv`, `<name> 3.csv`… when that file exists or this
    /// export already wrote it (two table names can map to the same file name).
    nonisolated static func unusedExportURL(in folder: URL, name: String, besides written: [URL]) -> URL {
        let taken = Set(written.map { $0.standardizedFileURL.path.lowercased() })
        var n = 1
        while true {
            let candidate = folder.appendingPathComponent(n == 1 ? "\(name).csv" : "\(name) \(n).csv")
            if !taken.contains(candidate.standardizedFileURL.path.lowercased()), !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
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
        guard runners[id] == nil, !pendingDeletion.contains(id), env.store.job(id) != nil else { return }
        // Another process is running it: leave it to that process.
        guard claim(id) else { return }
        // Only a started runner keeps the lock.
        defer { releaseIfIdle(id) }
        guard var record = env.store.job(id) else { return }
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
            // The wake time stays: a wait that came due finishes when the job gets its turn,
            // instead of starting over (a daily run would otherwise slip to the next day).
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
            releaseBrowserTabs(id)
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
        // Also catches a "Keep my Mac awake" change the settings observation can't see.
        updateKeepAwake()
    }

    private func runnerFinished(_ id: String, _ final: JobRecord) {
        runners[id] = nil
        pausing.remove(id)
        resolveApprovals(id, with: .stop)
        let saved = savedForExit.remove(id) != nil
        var final = final
        if halting.remove(id) != nil, final.status == .stopped {
            Self.markHalted(&final)
            save(final)
            if !saved { log(id, ActivityEntry(kind: .info, title: "Halted by the emergency stop")) }
        } else if saved {
            // Its runner stopped saving for an exit that hasn't come; what it ended with stands.
            save(final)
        }
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
        // Its final record is saved; another process may take the job from here.
        releaseIfIdle(id)
        drainQueue()
        reschedule()
        updateKeepAwake()
    }

    private func drainQueue() {
        let max = Swift.max(1, env.settings().jobs.maxConcurrentJobs)
        while runners.count < max, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let r = env.store.job(id) else { continue }
            // Queued jobs keep a wake time that already came due; one still in the future is
            // the scheduler's to start.
            guard r.status == .waiting, r.nextWakeAt.map({ $0 <= env.now() }) ?? true else {
                // Another process changed it meanwhile (ran it, or put it to sleep until later):
                // show what it saved, so the scheduler arms for its real wake time.
                if r.status.isActive, JobRunLock.isHeld(folder: lockFolder(id)) { markElsewhere(id) } else { upsert(r, force: true) }
                continue
            }
            startOrQueue(id)
        }
    }

    /// Jobs the scheduler may wake: ones this center looks after, not running here or elsewhere,
    /// and not already queued.
    private var schedulable: [JobRecord] {
        jobs.filter { looksAfter($0.id) && runners[$0.id] == nil && !queue.contains($0.id) && !runningElsewhere.contains($0.id) }
    }

    private func reschedule() {
        if scheduler == nil {
            let s = JobScheduler(maxSleepSeconds: env.schedulerMaxSleep, now: env.now) { [weak self] id in self?.wake(id) }
            s.currentJobs = { [weak self] in self?.schedulable ?? [] }
            scheduler = s
        }
        scheduler?.reschedule(schedulable)
    }

    private func wake(_ id: String) {
        guard runners[id] == nil, looksAfter(id), let r = env.store.job(id) else { return }
        guard r.status == .waiting, let wake = r.nextWakeAt, wake <= env.now() else {
            // Another process changed it meanwhile (ran it, or put it back to sleep until later):
            // show what it saved, so it isn't woken again and the scheduler arms for its new time.
            if r.status.isActive, JobRunLock.isHeld(folder: lockFolder(id)) { markElsewhere(id) } else { upsert(r, force: true) }
            return
        }
        log(id, ActivityEntry(kind: .info, title: "Waking up"))
        startOrQueue(id)
    }

    private func updateKeepAwake() {
        guard let keepAwake = env.keepAwake else { return }
        keepAwake(!runners.isEmpty && env.settings().jobs.keepAwake)
        watchKeepAwakeSetting()
    }

    /// Follows "Keep my Mac awake" while jobs run: switching it off releases the assertion right
    /// away and switching it on takes it, instead of waiting for a job to start or finish.
    private func watchKeepAwakeSetting() {
        guard !watchingKeepAwake else { return }
        watchingKeepAwake = true
        let settings = env.settings
        withObservationTracking {
            _ = settings().jobs.keepAwake
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchingKeepAwake = false
                self.updateKeepAwake()
            }
        }
    }

    // MARK: - Other processes

    /// The job's lock lives in its folder (derived from the id, so every process agrees on it).
    private func lockFolder(_ id: String) -> URL { env.store.folder(for: id) }

    /// Takes the job's cross-process lock unless this center already holds it. False when another
    /// process is working on the job; it's then shown as running elsewhere until that ends.
    private func claim(_ id: String) -> Bool {
        if locks[id] != nil { return true }
        // Nothing to protect (and no folder to make) for a job that doesn't exist.
        guard planningIDs.contains(id) || env.store.job(id) != nil else { return true }
        guard let lock = JobRunLock.tryAcquire(folder: lockFolder(id)) else {
            markElsewhere(id)
            return false
        }
        locks[id] = lock
        runningElsewhere.remove(id)
        return true
    }

    /// Lets go of the job's lock unless this center is running or planning it.
    private func releaseIfIdle(_ id: String) {
        guard runners[id] == nil, !planningIDs.contains(id) else { return }
        locks.removeValue(forKey: id)?.release()
    }

    private func markElsewhere(_ id: String) {
        runningElsewhere.insert(id)
        queue.removeAll { $0 == id }
        if let r = env.store.job(id) { upsert(Self.shownAsElsewhere(r), force: true) }
        watchElsewhere()
    }

    /// Polls while other processes run jobs: shows their saved progress, and handles each job
    /// like one found after a restart once its process lets go (a crashed process drops its
    /// lock too).
    private func watchElsewhere() {
        guard elsewhereWatch == nil else { return }
        let interval = max(0.01, env.elsewherePollSeconds)
        elsewhereWatch = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                if !self.checkElsewhere() {
                    self.elsewhereWatch = nil
                    return
                }
            }
        }
    }

    /// One look at the jobs other processes are running. Returns whether any still are.
    private func checkElsewhere() -> Bool {
        for id in runningElsewhere.sorted() {
            guard let r = env.store.job(id) else {
                // Deleted by the other process.
                runningElsewhere.remove(id)
                jobs.removeAll { $0.id == id }
                continue
            }
            if JobRunLock.isHeld(folder: lockFolder(id)) {
                upsert(Self.shownAsElsewhere(r), force: true)
                continue
            }
            runningElsewhere.remove(id)
            upsert(r, force: true)
            // Only taken over when this center looks after it; glidectl just shows the app's.
            recover([r], afterRestart: false)
        }
        reschedule()
        return !runningElsewhere.isEmpty
    }

    /// The record as shown while another process runs it (only in memory; never saved).
    nonisolated static func shownAsElsewhere(_ r: JobRecord) -> JobRecord {
        var r = r
        r.statusLine = "Running in another Glide process" + (r.statusLine.isEmpty ? "" : " · " + r.statusLine)
        return r
    }

    /// Closes the browser tabs the job opened. Its runner does this when a run finishes the
    /// job; this covers jobs that end, or go away, without a runner.
    private func releaseBrowserTabs(_ id: String) {
        let release = env.releaseBrowser
        Task { await release(id) }
    }

    // MARK: - Approvals

    func enqueueApproval(jobID: String, _ request: ApprovalRequest) async -> ApprovalDecision {
        // A Stop (or the emergency stop) can land after the runner checked for one and before
        // this call. Queuing then would leave the stopped runner waiting on a card for a job the
        // user already stopped, holding its slot and keeping the Mac awake.
        guard let handle = runners[jobID], !handle.runner.isStopRequested, !pendingDeletion.contains(jobID) else { return .stop }
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

    /// Shows what the store holds for the job, or drops it when it's gone. For controls that
    /// find the job isn't as this center last saw it: another process changed it meanwhile.
    private func refresh(_ id: String) {
        if let r = env.store.job(id) { upsert(r, force: true) } else { jobs.removeAll { $0.id == id } }
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
