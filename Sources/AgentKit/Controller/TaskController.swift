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
    private var task: Task<Void, Never>?
    private var orchestrator: ExecutionOrchestrator?
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?

    public init(runtime: AutomationRuntime = .shared, settingsStore: SettingsStore = .shared) {
        self.runtime = runtime
        self.settingsStore = settingsStore
    }

    public var isConfigured: Bool { ModelRouter(settings: settingsStore.settings).isConfigured }

    public func start(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
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
        guard ModelRouter(settings: settings).isConfigured else {
            phase = .failed
            status = "Add an AI provider key in Settings to get started."
            onAttentionNeeded?()
            return
        }
        let callbacks = AgentCallbacks(
            phase: { [weak self] p, s in Task { @MainActor in self?.update(phase: p, status: s) } },
            log: { [weak self] e in Task { @MainActor in self?.append(e) } },
            plan: { [weak self] p, i in Task { @MainActor in self?.plan = p; self?.currentStepIndex = i } },
            approve: { [weak self] req in
                guard let self else { return .stop }
                return await self.requestApproval(req)
            })
        task = Task { [weak self] in
            var composio: (ComposioClient, String)?
            if settings.composio.enabled {
                composio = try? await ComposioSessionStore.ensureSession()
            }
            let current = SettingsStore.shared.settings
            let orchestrator = ExecutionOrchestrator(instruction: trimmed, settings: current, runtime: AutomationRuntime.shared,
                                                     callbacks: callbacks, composio: composio)
            self?.orchestrator = orchestrator
            self?.lastTaskID = orchestrator.taskID
            let result = await Task.detached(priority: .userInitiated) { await orchestrator.run() }.value
            self?.finish(result)
        }
    }

    private func update(phase p: AgentPhase, status s: String) {
        // Late phase updates must not overwrite a terminal state.
        if [.completed, .failed, .stopped, .needsInput].contains(phase), task == nil { return }
        phase = p
        status = s
    }

    private func append(_ e: ActivityEntry) {
        activity.append(e)
        if activity.count > 400 { activity.removeFirst(activity.count - 400) }
    }

    private func finish(_ result: TaskResult) {
        lastResult = result
        task = nil
        orchestrator = nil
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

    private func requestApproval(_ req: ApprovalRequest) async -> ApprovalDecision {
        await withCheckedContinuation { (c: CheckedContinuation<ApprovalDecision, Never>) in
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
        if decision == .stop { stop() } else { phase = .executing }
    }

    public func pause() {
        guard phase == .executing || phase == .planning else { return }
        runtime.gate.pause()
        phase = .paused
        status = "Paused"
    }

    public func resume() {
        guard phase == .paused else { return }
        runtime.gate.resume()
        phase = .executing
        status = plan.map { currentStepIndex < $0.steps.count ? $0.steps[currentStepIndex].title + "…" : "Resuming…" } ?? "Resuming…"
    }

    public func togglePause() {
        if phase == .paused { resume() } else { pause() }
    }

    /// Emergency stop: no further input is injected after this returns.
    public func stop() {
        runtime.gate.stop()
        orchestrator?.stop()
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

    public func reset() {
        guard !isRunning else { return }
        phase = .idle
        status = ""
        pendingApproval = nil
    }
}

extension ApprovalDecision: Equatable {}
