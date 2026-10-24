import Foundation
import AutomationKit

/// The standard step executor: on-screen routes (gui, native) go to the GUI loop, everything
/// else (command, browser, web, data, composio, mcp, answer) to the tool loop. Quick tasks and
/// background jobs both execute steps through this one type, so a step behaves the same
/// wherever it runs.
public struct StepRouter: StepExecuting {
    let gui: any StepExecuting
    let tools: any StepExecuting

    /// Routes to explicit executors (tests, or custom runners).
    public init(gui: any StepExecuting, tools: any StepExecuting) {
        self.gui = gui
        self.tools = tools
    }

    /// The production router: the GUI loop on `runtime`, the tool loop over `tools`, models
    /// from settings and the Keychain, Composio and MCP from the app's configuration.
    public init(settings: AppSettings, runtime: AutomationRuntime = .shared, tools: ToolRegistry, credentials: CredentialStore = .shared) {
        let router = ModelRouter(settings: settings, credentials: credentials)
        self.gui = GUIStepRunner(settings: settings, runtime: runtime, router: router)
        self.tools = ToolStepRunner(settings: settings, runtime: runtime, tools: tools, models: .router(router),
                                    integrations: .standard(settings: settings))
    }

    public func execute(_ request: StepRequest, callbacks: AgentCallbacks) async throws -> StepResult {
        if request.step.route.needsScreen {
            return try await gui.execute(request, callbacks: callbacks)
        }
        return try await tools.execute(request, callbacks: callbacks)
    }

    /// Makes this router the job engine's step executor (`StepExecutorFactory.make`). Call
    /// once at launch, before jobs resume.
    public static func install() {
        StepExecutorFactory.make = { settings, runtime, tools in
            StepRouter(settings: settings, runtime: runtime, tools: tools)
        }
    }
}

/// Mutable state shared by the steps of one quick task (or by one job step): the notes the
/// executors read, the task-wide action count and deadline, screenshot consent, and the app
/// last acted in. One task's steps run one at a time; the lock makes the type safe to hand
/// across the runners' `async` boundaries anyway.
final class TaskSession: @unchecked Sendable {
    private let lock = NSLock()
    private var _notes: [String] = []
    private var _actions = 0
    private var _screenshotConsent = false
    private var _currentApp: AppInfo?

    let deadline: Date
    let maxTotalActions: Int
    private let timeoutMinutes: Int

    init(deadline: Date, maxTotalActions: Int) {
        self.deadline = deadline
        self.maxTotalActions = maxTotalActions
        self.timeoutMinutes = max(1, Int((deadline.timeIntervalSinceNow / 60).rounded()))
    }

    /// A session bounded by the task limits in settings, starting now.
    convenience init(limits: LimitSettings, start: Date = Date()) {
        self.init(deadline: start.addingTimeInterval(limits.taskTimeoutSeconds), maxTotalActions: limits.maxTotalActions)
    }

    var notes: [String] { lock.withLock { _notes } }
    var notesText: String { notes.joined(separator: "\n") }

    func appendNote(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock { _notes.append(trimmed) }
    }

    var totalActions: Int { lock.withLock { _actions } }
    func addActions(_ n: Int = 1) { lock.withLock { _actions += n } }

    var screenshotConsentGiven: Bool {
        get { lock.withLock { _screenshotConsent } }
        set { lock.withLock { _screenshotConsent = newValue } }
    }

    var currentApp: AppInfo? {
        get { lock.withLock { _currentApp } }
        set { lock.withLock { _currentApp = newValue } }
    }

    /// Throws when the run must end: stopped (or cancelled), past the deadline, or out of actions.
    func checkLimits(gate: ExecutionGate?) throws {
        if Task.isCancelled || gate?.isStopped == true { throw AutomationError.stopped }
        if Date() > deadline { throw AutomationError.timeout("the task took longer than \(timeoutMinutes) minutes") }
        if totalActions >= maxTotalActions { throw AutomationError.timeout("reached the limit of \(maxTotalActions) actions") }
    }
}

extension RecipeStep {
    /// A quick-task plan step as a recipe step (hints only matter to the GUI loop, which
    /// receives the plan step itself).
    init(_ step: PlanStep, outputFields: [String] = []) {
        self.init(id: step.id, title: step.title, instruction: step.instruction, route: step.route, app: step.app,
                  risk: step.risk, doneWhen: step.doneWhen, outputFields: outputFields)
    }
}

extension StepResult {
    /// Fills in every required field so item results have a stable set of columns: a field
    /// the model didn't return becomes null instead of disappearing.
    static func completeFields(_ fields: [String: JSONValue], required: [String]) -> [String: JSONValue] {
        var out = fields
        for key in required where out[key] == nil { out[key] = .null }
        return out
    }

    /// Output fields missing from `fields`.
    static func missingFields(_ fields: [String: JSONValue]?, required: [String]) -> [String] {
        required.filter { fields?[$0] == nil }
    }
}

/// Short, single-purpose key for a note a step stored in the job workspace. Retrying the same
/// item reuses the same keys, so retries replace their notes instead of piling up.
func workspaceNoteKey(stepID: Int, itemID: String?, index: Int) -> String {
    let item = itemID.flatMap { $0.split(separator: "/").last.map(String.init) }.map { ":item\($0)" } ?? ""
    return "note:step\(stepID)\(item):\(index)"
}
