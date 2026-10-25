import Foundation
import AutomationKit

/// What the direct routes (command, browser, web, data) and the screen can do right now, so the
/// planner only plans steps that can actually run and prefers the fast ones.
public struct RouteAvailability: Sendable, Hashable {
    public var executionPreference: ExecutionPreference
    public var commandAccess: CommandAccess
    public var allowAppleScript: Bool
    public var allowShortcuts: Bool
    /// Tool families installed in this process.
    public var toolFamilies: Set<ToolCategory>
    /// Status of the preferred browser backend.
    public var browser: BrowserStatus?
    /// Glide's own Chrome window can be started on demand when the preferred backend isn't connected.
    public var browserOnDemand: Bool
    /// Accessibility permission (needed by gui and native steps).
    public var accessibilityGranted: Bool
    /// Something can host background jobs (the app's JobCenter); false in glidectl and tests.
    public var backgroundJobs: Bool

    public init(executionPreference: ExecutionPreference = .fastest, commandAccess: CommandAccess = .full, allowAppleScript: Bool = true,
                allowShortcuts: Bool = true, toolFamilies: Set<ToolCategory> = [], browser: BrowserStatus? = nil, browserOnDemand: Bool = false,
                accessibilityGranted: Bool = true, backgroundJobs: Bool = false) {
        self.executionPreference = executionPreference
        self.commandAccess = commandAccess
        self.allowAppleScript = allowAppleScript
        self.allowShortcuts = allowShortcuts
        self.toolFamilies = toolFamilies
        self.browser = browser
        self.browserOnDemand = browserOnDemand
        self.accessibilityGranted = accessibilityGranted
        self.backgroundJobs = backgroundJobs
    }

    /// Reads the current state: settings, the installed tool families, the browser hub and the
    /// Accessibility permission. Cheap (no model calls, no UI).
    public static func current(settings: AppSettings, tools: ToolRegistry, backgroundJobs: Bool, hub: BrowserHub = .shared) async -> RouteAvailability {
        let families = Set(tools.specs().map(\.category))
        var browser: BrowserStatus?
        var onDemand = false
        if families.contains(.browser) {
            let status = await hub.status(settings: settings.browser)
            browser = status
            let glideChrome = hub.registered(.glideChrome) != nil && status.chromeInstalled
            onDemand = glideChrome && (settings.browser.backend == .glideChrome || settings.browser.fallbackToGlideChrome)
        }
        return RouteAvailability(executionPreference: settings.tools.executionPreference, commandAccess: settings.tools.commandAccess,
                                 allowAppleScript: settings.tools.allowAppleScript, allowShortcuts: settings.tools.allowShortcuts,
                                 toolFamilies: families, browser: browser, browserOnDemand: onDemand,
                                 accessibilityGranted: AccessibilityEngine.isTrusted, backgroundJobs: backgroundJobs)
    }

    /// Whether a step on `route` can run now (integrations are reported separately).
    public func isAvailable(_ route: ExecutionRoute) -> Bool {
        unavailableReason(route) == nil
    }

    func unavailableReason(_ route: ExecutionRoute) -> String? {
        switch route {
        case .command:
            if toolFamilies.isDisjoint(with: [.command, .files]) { return "no command tools are installed" }
            if commandAccess == .off { return "command access is off in Settings" }
            return nil
        case .browser:
            if !toolFamilies.contains(.browser) { return "no browser tools are installed" }
            if browser?.connected == true || browserOnDemand { return nil }
            return browser?.chromeInstalled == false ? "Google Chrome isn't installed" : "no browser is connected"
        case .web: return toolFamilies.contains(.web) ? nil : "no web tools are installed"
        case .data: return toolFamilies.contains(.data) ? nil : "no spreadsheet tools are installed"
        case .gui, .native: return accessibilityGranted ? nil : "Accessibility permission isn't granted"
        case .composio, .mcp, .answer: return nil
        }
    }

    var rendered: [String] {
        var lines: [String] = []
        switch executionPreference {
        case .fastest: lines.append("Execution preference: Fastest — use command, browser, web or data whenever they can do the job; gui/native only for what truly needs the screen.")
        case .showMe: lines.append("Execution preference: Show me — prefer visible native/gui steps so the user can watch; tools are fine for things with no UI.")
        }
        lines.append("Routes available now:")
        func line(_ route: ExecutionRoute, _ detail: String) {
            if let why = unavailableReason(route) { lines.append("- \(route.rawValue): UNAVAILABLE (\(why))") }
            else { lines.append("- \(route.rawValue): available" + (detail.isEmpty ? "" : " (\(detail))")) }
        }
        let access = commandAccess == .readOnly ? "read-only commands only" : "full access, risky commands ask first"
        line(.command, "\(access); AppleScript \(allowAppleScript ? "allowed" : "off"); Shortcuts \(allowShortcuts ? "allowed" : "off")")
        let browserDetail: String
        if let b = browser, b.connected { browserDetail = "\(b.backend.title), connected" }
        else if browserOnDemand { browserDetail = "Glide's own Chrome window opens on demand" }
        else { browserDetail = "" }
        line(.browser, browserDetail)
        line(.web, "")
        line(.data, "CSV and XLSX")
        line(.gui, "")
        line(.native, "")
        lines.append(backgroundJobs ? "Background jobs: available (use mode job for long or repetitive work)."
                                    : "Background jobs: not available here — always use mode quick.")
        return lines
    }
}

public struct PlanningContext: Sendable {
    public var frontmostApp: String?
    public var windowTitle: String?
    public var runningApps: [String]
    public var browserPage: String?
    public var composioToolkits: [String]
    public var mcpTools: [MCPTool]
    public var skills: [Skill]
    public var date = Date()
    /// Which routes can run right now. Nil leaves the route section out of the prompt.
    public var routes: RouteAvailability?
    /// What the conversation so far established (the last task and its result, what an
    /// instant action just opened), so "now add two of them" can be planned.
    public var conversation: String?

    public init(frontmostApp: String? = nil, windowTitle: String? = nil, runningApps: [String] = [], browserPage: String? = nil,
                composioToolkits: [String] = [], mcpTools: [MCPTool] = [], skills: [Skill] = [], routes: RouteAvailability? = nil) {
        self.frontmostApp = frontmostApp
        self.windowTitle = windowTitle
        self.runningApps = runningApps
        self.browserPage = browserPage
        self.composioToolkits = composioToolkits
        self.mcpTools = mcpTools
        self.skills = skills
        self.routes = routes
    }

    var rendered: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var lines = ["Now: \(df.string(from: date)) (\(TimeZone.current.identifier))"]
        if let f = frontmostApp { lines.append("Frontmost app: \(f)" + (windowTitle.map { " — window “\($0)”" } ?? "")) }
        if let b = browserPage { lines.append("Current browser page: \(b)") }
        if !runningApps.isEmpty { lines.append("Running apps: " + runningApps.prefix(25).joined(separator: ", ")) }
        if let routes { lines += routes.rendered }
        lines.append("Connected Composio toolkits: " + (composioToolkits.isEmpty ? "none" : composioToolkits.joined(separator: ", ")))
        if mcpTools.isEmpty {
            lines.append("MCP tools: none")
        } else {
            lines.append("MCP tools:")
            for t in mcpTools.prefix(40) { lines.append("- \(t.qualifiedName): \(t.description.prefix(140))") }
        }
        if !skills.isEmpty {
            lines.append("Saved skills that may apply:")
            for s in skills.prefix(3) { lines.append(s.promptText) }
        }
        if let conversation, !conversation.isEmpty {
            lines.append("Context from the conversation (use it to resolve “it”, “them”, “there”):\n\(conversation.prefix(3000))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Creates and revises plans with the planning / recovery models.
public struct AgentPlanner: Sendable {
    let router: ModelRouter
    let metrics: TaskMetrics
    /// One provider and model for every role instead of the router (tests, scripted runs).
    let fixed: ToolStepRunner.ModelSource?

    public init(router: ModelRouter, metrics: TaskMetrics) {
        self.router = router
        self.metrics = metrics
        self.fixed = nil
    }

    init(provider: any LLMProvider, model: String, metrics: TaskMetrics) {
        self.router = ModelRouter(settings: AppSettings())
        self.metrics = metrics
        self.fixed = .fixed(provider: provider, model: model)
    }

    private func route(_ role: ModelRole) throws -> ModelRouter.Route {
        if let fixed { return try fixed.route() }
        return try router.route(role)
    }

    public func plan(_ instruction: String, context: PlanningContext) async throws -> Plan {
        let route = try route(.planner)
        let message = """
        \(context.rendered)

        User request: \(instruction)
        """
        let req = LLMRequest(model: route.model, system: Prompts.planner, messages: [.user(message)], schema: PlanSchema.schema,
                             schemaName: "plan", maxTokens: 8000, effort: route.effort, timeout: 120)
        let r = try await route.provider.complete(req)
        await metrics.recordModel(r, vision: false)
        guard let json = r.json else { throw LLMError.invalidJSON(r.text) }
        return try PlanSchema.decode(json)
    }

    /// - Parameters:
    ///   - alreadyDone: actions earlier steps took that changed something (`TaskSession.sideEffects`).
    ///   - page: a fresh look at the task's browser tab, when it used one.
    public func replan(_ instruction: String, plan: Plan, completed: [PlanStep], failedStep: PlanStep, failure: String,
                       notes: String, screen: String, context: PlanningContext, alreadyDone: [String] = [], page: String? = nil) async throws -> Plan {
        let route = try route(.recovery)
        let message = Self.recoveryMessage(instruction, plan: plan, completed: completed, failedStep: failedStep, failure: failure, notes: notes,
                                           screen: screen, context: context, alreadyDone: alreadyDone, page: page)
        let req = LLMRequest(model: route.model, system: Prompts.recovery, messages: [.user(message)], schema: PlanSchema.schema,
                             schemaName: "plan", maxTokens: 8000, effort: route.effort, timeout: 120)
        let r = try await route.provider.complete(req)
        await metrics.recordModel(r, vision: false)
        guard let json = r.json else { throw LLMError.invalidJSON(r.text) }
        return try PlanSchema.decode(json)
    }

    /// The recovery planner's message. What already took effect comes before the notes, so a
    /// long notes section can't push it out of view.
    static func recoveryMessage(_ instruction: String, plan: Plan, completed: [PlanStep], failedStep: PlanStep, failure: String, notes: String,
                                screen: String, context: PlanningContext, alreadyDone: [String], page: String?) -> String {
        var message = """
        \(context.rendered)

        Original request: \(instruction)
        Plan goal: \(plan.goal)
        Completed steps: \(completed.isEmpty ? "none" : completed.map { "\($0.id). \($0.title)" }.joined(separator: "; "))
        Failed step: \(failedStep.title) — \(failedStep.instruction)
        Failure: \(failure)
        """
        if let done = RetryNotes.render(alreadyDone) { message += "\n" + done }
        if let page, !page.isEmpty { message += "\nCurrent browser page:\n\(page.prefix(3000))" }
        message += """

        Notes gathered so far: \(notes.isEmpty ? "none" : notes)
        Current screen:
        \(screen.prefix(4000))
        """
        return message
    }
}

/// Asks the fast action-selection model for the next action given a compact UI skeleton.
public struct ActionSelector: Sendable {
    let router: ModelRouter
    let metrics: TaskMetrics

    public init(router: ModelRouter, metrics: TaskMetrics) {
        self.router = router
        self.metrics = metrics
    }

    public struct Input: Sendable {
        var instruction: String
        var plan: Plan
        var step: PlanStep
        var observation: ScreenObservation?
        var history: [String]
        var notes: String
        var extraContext: String?
        var tools: String?
        /// Fields the step must return with step_done (job steps); empty for quick tasks.
        var outputFields: [String] = []
        /// Follow-up actions the actor may batch after the main one (0 = batching off).
        var maxFollowUps: Int = 0
    }

    public func decide(_ input: Input) async throws -> ActorDecision {
        let route = try router.route(.actor)
        let planLines = input.plan.steps.map { ($0.id == input.step.id ? "→ " : "  ") + "\($0.id). \($0.title)" }.joined(separator: "\n")
        var message = """
        Task: \(input.instruction)
        Plan:
        \(planLines)

        CURRENT STEP \(input.step.id): \(input.step.instruction)
        Done when: \(input.step.doneWhen)
        """
        if !input.outputFields.isEmpty {
            message += "\nOutput fields (return with step_done in result_fields_json): " + input.outputFields.joined(separator: ", ")
        }
        message += input.maxFollowUps > 0 ? "\nFollow-up actions allowed this turn: up to \(input.maxFollowUps)."
                                          : "\nFollow-up actions: not allowed (set actions to null)."
        if !input.notes.isEmpty { message += "\n\nNotes so far:\n\(input.notes.suffix(5000))" }
        message += "\n\nActions so far in this step:\n" + (input.history.isEmpty ? "(none)" : input.history.suffix(10).joined(separator: "\n"))
        if let extra = input.extraContext { message += "\n\n\(extra)" }
        if let tools = input.tools { message += "\n\nAvailable tools (use action call_tool):\n\(tools)" }
        if let obs = input.observation {
            message += "\n\nSCREEN:\n" + obs.compact()
        } else {
            message += "\n\nSCREEN: (no accessible window in front)"
        }
        let req = LLMRequest(model: route.model, system: Prompts.actor, messages: [.user(message)], schema: ActorSchema.schema,
                             schemaName: "next_action", maxTokens: 4000, effort: route.effort, timeout: 60)
        let r = try await route.provider.complete(req)
        await metrics.recordModel(r, vision: false)
        guard let json = r.json else { throw LLMError.invalidJSON(r.text) }
        return ActorSchema.decode(json)
    }

    static let answerSchema: JSONValue = Schema.object([
        ("message", Schema.string("The answer for the user, concise and complete.")),
        ("spoken", Schema.nullableString("The answer said out loud: at most 25 words, plain and warm.")),
    ])

    /// Writes the final answer for `answer` steps from gathered notes, with a short version to
    /// say out loud.
    public func answer(instruction: String, step: PlanStep, notes: String) async throws -> (message: String, spoken: String?) {
        let route = try router.route(.planner)
        let req = LLMRequest(model: route.model, system: "You write the final answer for a macOS agent's task using only the notes gathered while operating the computer. Be concise. In spoken, say it as you would out loud, in at most 25 words.",
                             messages: [.user("Task: \(instruction)\nStep: \(step.instruction)\nNotes:\n\(notes.isEmpty ? "(none)" : notes)")],
                             schema: Self.answerSchema, schemaName: "answer", maxTokens: 3000, effort: "low", timeout: 60)
        let r = try await route.provider.complete(req)
        await metrics.recordModel(r, vision: false)
        let spoken = r.json?["spoken"]?.stringValue.flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        return (r.json?["message"]?.stringValue ?? r.text, spoken)
    }
}
