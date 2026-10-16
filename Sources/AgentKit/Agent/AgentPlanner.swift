import Foundation
import AutomationKit

public struct PlanningContext: Sendable {
    public var frontmostApp: String?
    public var windowTitle: String?
    public var runningApps: [String]
    public var browserPage: String?
    public var composioToolkits: [String]
    public var mcpTools: [MCPTool]
    public var skills: [Skill]
    public var date = Date()

    public init(frontmostApp: String? = nil, windowTitle: String? = nil, runningApps: [String] = [], browserPage: String? = nil,
                composioToolkits: [String] = [], mcpTools: [MCPTool] = [], skills: [Skill] = []) {
        self.frontmostApp = frontmostApp
        self.windowTitle = windowTitle
        self.runningApps = runningApps
        self.browserPage = browserPage
        self.composioToolkits = composioToolkits
        self.mcpTools = mcpTools
        self.skills = skills
    }

    var rendered: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var lines = ["Now: \(df.string(from: date)) (\(TimeZone.current.identifier))"]
        if let f = frontmostApp { lines.append("Frontmost app: \(f)" + (windowTitle.map { " — window “\($0)”" } ?? "")) }
        if let b = browserPage { lines.append("Current browser page: \(b)") }
        if !runningApps.isEmpty { lines.append("Running apps: " + runningApps.prefix(25).joined(separator: ", ")) }
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
        return lines.joined(separator: "\n")
    }
}

/// Creates and revises plans with the planning / recovery models.
public struct AgentPlanner: Sendable {
    let router: ModelRouter
    let metrics: TaskMetrics

    public init(router: ModelRouter, metrics: TaskMetrics) {
        self.router = router
        self.metrics = metrics
    }

    public func plan(_ instruction: String, context: PlanningContext) async throws -> Plan {
        let route = try router.route(.planner)
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

    public func replan(_ instruction: String, plan: Plan, completed: [PlanStep], failedStep: PlanStep, failure: String,
                       notes: String, screen: String, context: PlanningContext) async throws -> Plan {
        let route = try router.route(.recovery)
        let message = """
        \(context.rendered)

        Original request: \(instruction)
        Plan goal: \(plan.goal)
        Completed steps: \(completed.isEmpty ? "none" : completed.map { "\($0.id). \($0.title)" }.joined(separator: "; "))
        Failed step: \(failedStep.title) — \(failedStep.instruction)
        Failure: \(failure)
        Notes gathered so far: \(notes.isEmpty ? "none" : notes)
        Current screen:
        \(screen.prefix(4000))
        """
        let req = LLMRequest(model: route.model, system: Prompts.recovery, messages: [.user(message)], schema: PlanSchema.schema,
                             schemaName: "plan", maxTokens: 8000, effort: route.effort, timeout: 120)
        let r = try await route.provider.complete(req)
        await metrics.recordModel(r, vision: false)
        guard let json = r.json else { throw LLMError.invalidJSON(r.text) }
        return try PlanSchema.decode(json)
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

    static let answerSchema: JSONValue = Schema.object([("message", Schema.string("The answer for the user, concise and complete."))])

    /// Writes the final answer for `answer` steps from gathered notes.
    public func answer(instruction: String, step: PlanStep, notes: String) async throws -> String {
        let route = try router.route(.planner)
        let req = LLMRequest(model: route.model, system: "You write the final answer for a macOS agent's task using only the notes gathered while operating the computer. Be concise.",
                             messages: [.user("Task: \(instruction)\nStep: \(step.instruction)\nNotes:\n\(notes.isEmpty ? "(none)" : notes)")],
                             schema: Self.answerSchema, schemaName: "answer", maxTokens: 3000, effort: "low", timeout: 60)
        let r = try await route.provider.complete(req)
        await metrics.recordModel(r, vision: false)
        return r.json?["message"]?.stringValue ?? r.text
    }
}
