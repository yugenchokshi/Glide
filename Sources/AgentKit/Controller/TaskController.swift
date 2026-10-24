import Foundation
import Observation
import AutomationKit

/// UI-facing state machine for the current task. The notch and menu bar observe this; the
/// automation itself runs off the main actor in `ExecutionOrchestrator`.
@MainActor
@Observable
public final class TaskController {
    public static let shared = TaskController()

    public private(set) var phase: AgentPhase = .idle
    public private(set) var status = ""
    public private(set) var instruction = ""
    public private(set) var plan: Plan?
    public private(set) var currentStepIndex = 0
    public private(set) var activity: [ActivityEntry] = []
    public private(set) var pendingApproval: ApprovalRequest?
    public private(set) var lastResult: TaskResult?
    public private(set) var lastTaskID: String?
    public private(set) var startedAt: Date?

    public var isRunning: Bool { [.planning, .executing, .awaitingApproval, .paused].contains(phase) }

    /// Called when a task needs attention (approval, completion, error) so the UI can expand.
    public var onAttentionNeeded: (() -> Void)?
    /// Called when a task finishes (any outcome).
    public var onFinished: ((TaskResult) -> Void)?

    let runtime: AutomationRuntime
    let settingsStore: SettingsStore
    /// Receives requests the planner marks as long-running jobs. Resolved only when a job is
    /// handed off (nil = `JobCenter.shared`), so creating a controller doesn't start the job engine.
    private let jobCenterOverride: JobCenter?
    private var jobCenter: JobCenter { jobCenterOverride ?? .shared }
    private let screenLease: ScreenLease
    private var task: Task<Void, Never>?
    private var runTask: Task<TaskResult, Never>?
    private var orchestrator: ExecutionOrchestrator?
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var runID = 0
    /// True while this run holds the screen lease. Until then the shared input gate belongs to
    /// whoever does hold it — possibly a background job's on-screen step — so Stop and Pause
    /// must leave the gate alone and only act on this run.
    private var holdsLease = false
    /// Pause pressed before the lease was granted; applied to the gate once this run holds it.
    private var pendingPause = false
    /// What the notch showed before a pause pressed while waiting for the lease.
    private var statusBeforePause = ""

    static let waitingForScreenStatus = "Waiting for a background job to finish its on-screen step…"

    private let credentials: CredentialStore

    public init(runtime: AutomationRuntime = .shared, settingsStore: SettingsStore = .shared, jobCenter: JobCenter? = nil,
                screenLease: ScreenLease = .shared, credentials: CredentialStore = .shared) {
        self.runtime = runtime
        self.settingsStore = settingsStore
        self.jobCenterOverride = jobCenter
        self.screenLease = screenLease
        self.credentials = credentials
    }

    /// True while this run holds the screen lease, so the shared input gate is its own.
    public var holdsScreen: Bool { holdsLease }

    /// Paused as far as this run is concerned: the gate once this run holds the lease, the
    /// pending pause before that.
    private var isPaused: Bool { holdsLease ? runtime.gate.isPaused : pendingPause }

    public var isConfigured: Bool { ModelRouter(settings: settingsStore.settings, credentials: credentials).isConfigured }

    /// True while a previous run is still unwinding after Stop.
    public var isWindingDown: Bool { task != nil && !isRunning }

    public func start(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Refuse while a stopped run is still unwinding: it shares the input gate.
        guard !trimmed.isEmpty, !isRunning else { return }
        if task != nil {
            status = "Still stopping the previous task — try again in a moment."
            return
        }
        runID &+= 1
        let id = runID
        instruction = trimmed
        plan = nil
        currentStepIndex = 0
        activity = []
        lastResult = nil
        pendingApproval = nil
        startedAt = Date()
        phase = .planning
        status = "Understanding your task…"
        let settings = settingsStore.settings
        guard ModelRouter(settings: settings, credentials: credentials).isConfigured else {
            phase = .failed
            status = "Add an AI provider key in Settings to get started."
            onAttentionNeeded?()
            return
        }
        // The gate is reset once this run holds the screen lease (`takeInputGate`), not here: a
        // background job's on-screen step may be using it until then.
        holdsLease = false
        pendingPause = false
        // Every callback carries the run id; anything from an older run is dropped.
        let callbacks = AgentCallbacks(
            phase: { [weak self] p, s in Task { @MainActor in self?.update(phase: p, status: s, run: id) } },
            log: { [weak self] e in Task { @MainActor in if self?.runID == id { self?.append(e) } } },
            plan: { [weak self] p, i in Task { @MainActor in if self?.runID == id { self?.plan = p; self?.currentStepIndex = i } } },
            approve: { [weak self] req in
                guard let self else { return .stop }
                return await self.requestApproval(req, run: id)
            })
        // Long or repetitive requests (plan mode `job`) become background jobs; this quick task
        // then finishes with a short "Started a background job" summary and the job's id.
        let handoff: ExecutionOrchestrator.JobHandoff = { [weak self] instruction, _ in
            guard let self else { return nil }
            return await self.startBackgroundJob(instruction, run: id)
        }
        task = Task { [weak self] in
            var composio: (ComposioClient, String)?
            if settings.composio.enabled {
                composio = try? await ComposioSessionStore.ensureSession()
            }
            // Before this run holds the lease, Stop cancels this task (the gate isn't its yet).
            guard let self, !Task.isCancelled, self.runID == id else {
                await self?.endStopped(run: id)
                return
            }
            // Quick tasks are interactive: they take the screen ahead of background jobs. A job's
            // on-screen step that is already running finishes first; jobs' other work continues.
            let leaseOwner = "task:\(id)"
            let lease = self.screenLease
            if await lease.currentHolder != nil {
                self.update(phase: .planning, status: Self.waitingForScreenStatus, run: id)
            }
            do {
                try await lease.acquire(owner: leaseOwner, priority: true)
            } catch {
                await self.endStopped(run: id)
                return
            }
            guard !Task.isCancelled, self.runID == id else {
                await lease.release(owner: leaseOwner)
                await self.endStopped(run: id)
                return
            }
            self.takeInputGate()
            let orchestrator = ExecutionOrchestrator(instruction: trimmed, settings: SettingsStore.shared.settings, runtime: self.runtime,
                                                     callbacks: callbacks, credentials: self.credentials, composio: composio, jobHandoff: handoff)
            self.orchestrator = orchestrator
            self.lastTaskID = orchestrator.taskID
            let run = Task.detached(priority: .userInitiated) { await orchestrator.run() }
            self.runTask = run
            let result = await run.value
            // Let go of the gate before the lease: once released, a job's on-screen step may
            // start, and a Stop pressed after that must not reach it.
            self.holdsLease = false
            self.runTask = nil
            self.orchestrator = nil
            await lease.release(owner: leaseOwner)
            self.task = nil
            self.finish(result, run: id)
        }
    }

    /// Called once this run holds the screen lease: from here the shared input gate is this
    /// run's. Clears a Stop or pause an earlier task or job left on it, then applies a pause
    /// pressed while waiting.
    func takeInputGate() {
        holdsLease = true
        runtime.gate.reset()
        if pendingPause {
            pendingPause = false
            runtime.gate.pause()
        }
    }

    /// Ends a run that was stopped before it started working.
    private func endStopped(run: Int) async {
        task = nil
        finish(TaskResult(status: .stopped, summary: "Stopped", error: nil, plan: nil, metrics: await TaskMetrics().snapshot(), durationMs: 0), run: run)
    }

    /// Plans the request as a background job. Nil when this run was stopped or replaced while
    /// planning, so nothing is started on its behalf.
    private func startBackgroundJob(_ instruction: String, run: Int) async -> JobRecord? {
        guard run == runID, !runtime.gate.isStopped else { return nil }
        status = "Setting up a background job…"
        let job = await jobCenter.create(instruction: instruction)
        // A stop pressed while the job was being planned also stops the new job.
        if run != runID || runtime.gate.isStopped {
            if !job.status.isFinished { jobCenter.stop(job.id) }
            return nil
        }
        return job
    }

    private func update(phase p: AgentPhase, status s: String, run: Int) {
        guard run == runID, isRunning else { return }
        // While paused, progress messages from in-flight work mustn't un-pause the UI.
        if isPaused && p != .paused && p != .awaitingApproval {
            // Still waiting for the screen: show the latest of these again on resume.
            if !holdsLease { statusBeforePause = s }
            return
        }
        phase = p
        status = s
    }

    private func append(_ e: ActivityEntry) {
        activity.append(e)
        if activity.count > 400 { activity.removeFirst(activity.count - 400) }
    }

    private func finish(_ result: TaskResult, run: Int) {
        // Release anything still waiting on this run's approval.
        approvalContinuation?.resume(returning: .stop)
        approvalContinuation = nil
        guard run == runID else { return }
        lastResult = result
        switch result.status {
        case .completed: phase = .completed; status = result.summary
        case .failed: phase = .failed; status = result.error ?? result.summary
        case .stopped: phase = .stopped; status = "Stopped"
        case .needsInput: phase = .needsInput; status = result.summary
        }
        pendingApproval = nil
        onFinished?(result)
        onAttentionNeeded?()
    }

    private func requestApproval(_ req: ApprovalRequest, run: Int) async -> ApprovalDecision {
        guard run == runID, !runtime.gate.isStopped else { return .stop }
        return await withCheckedContinuation { (c: CheckedContinuation<ApprovalDecision, Never>) in
            approvalContinuation?.resume(returning: .reject)
            approvalContinuation = c
            pendingApproval = req
            phase = .awaitingApproval
            onAttentionNeeded?()
        }
    }

    public func respondToApproval(_ decision: ApprovalDecision) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
        if decision == .stop { stop() } else if isPaused { phase = .paused } else { phase = .executing }
    }

    public func pause() {
        guard phase == .executing || phase == .planning else { return }
        if holdsLease {
            runtime.gate.pause()
        } else {
            // Still waiting for the screen: the gate may be driving a job's on-screen step.
            pendingPause = true
            statusBeforePause = status
        }
        phase = .paused
        status = "Paused"
    }

    public func resume() {
        guard phase == .paused else { return }
        guard holdsLease else {
            pendingPause = false
            phase = .planning
            status = statusBeforePause.isEmpty ? "Understanding your task…" : statusBeforePause
            return
        }
        runtime.gate.resume()
        phase = .executing
        status = plan.map { currentStepIndex < $0.steps.count ? $0.steps[currentStepIndex].title + "…" : "Resuming…" } ?? "Resuming…"
    }

    public func togglePause() {
        if phase == .paused { resume() } else { pause() }
    }

    /// Stops the quick task; once it holds the screen, no further input is injected after this
    /// returns. While it's still waiting for the screen, cancelling the wait is all it takes:
    /// the shared gate then belongs to whoever holds the lease, and stopping it would stop a
    /// background job's on-screen step instead (the emergency stop halts jobs separately,
    /// through `JobCenter.haltAll`).
    public func stop() {
        if holdsLease {
            runtime.gate.stop()
            orchestrator?.stop()
        }
        pendingPause = false
        runTask?.cancel()
        task?.cancel()
        approvalContinuation?.resume(returning: .stop)
        approvalContinuation = nil
        pendingApproval = nil
        if isRunning {
            phase = .stopped
            status = "Stopped"
        }
    }

    public func retry() {
        guard !isRunning, !instruction.isEmpty else { return }
        start(instruction)
    }

    /// Runs again, telling the planner what went wrong last time.
    public func replan() {
        guard !isRunning, !instruction.isEmpty else { return }
        let previous = lastResult?.error ?? lastResult?.summary ?? ""
        let base = instruction.components(separatedBy: "\n\n(Previous attempt").first ?? instruction
        start(previous.isEmpty ? base : base + "\n\n(Previous attempt failed: \(previous). Try a different approach.)")
    }

    /// Sets display state directly. Used only by the UI snapshot renderer (`--snapshot`).
    public func previewState(phase: AgentPhase, status: String, instruction: String = "", plan: Plan? = nil, stepIndex: Int = 0,
                             activity: [ActivityEntry] = [], approval: ApprovalRequest? = nil, holdsScreen: Bool = false) {
        self.holdsLease = holdsScreen
        self.phase = phase
        self.status = status
        self.instruction = instruction
        self.plan = plan
        self.currentStepIndex = stepIndex
        self.activity = activity
        self.pendingApproval = approval
    }

    public func reset() {
        guard !isRunning else { return }
        phase = .idle
        status = ""
        pendingApproval = nil
    }
}

extension ApprovalDecision: Equatable {}
