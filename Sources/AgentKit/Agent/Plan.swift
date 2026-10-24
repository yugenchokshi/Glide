import Foundation
import AutomationKit

public enum RiskLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case low, medium, high
    static let order: [RiskLevel] = [.low, .medium, .high]
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { order.firstIndex(of: a)! < order.firstIndex(of: b)! }
}

/// How a step is carried out. Recorded in history for every step.
public enum ExecutionRoute: String, Codable, Sendable, CaseIterable {
    case gui        // accessibility-driven UI action (vision as fallback)
    case native     // OS operation: open URL, launch app
    case command    // shell, AppleScript/JXA, Shortcuts, file operations — no UI
    case browser    // DOM-level Chrome control via the Glide extension, in a background tab
    case web        // search and fetch over HTTP, no browser
    case data       // spreadsheets and tables (CSV/XLSX)
    case composio   // Composio tool call
    case mcp        // MCP tool call
    case answer     // no action: the agent writes the result/summary itself
}

public struct PlanStep: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// Short present-progressive label for the notch ("Opening Notes").
    public var title: String
    /// Full instruction for the action selector.
    public var instruction: String
    public var route: ExecutionRoute
    public var app: String?
    public var risk: RiskLevel
    /// Observable condition that means the step is done.
    public var doneWhen: String
    /// Optional deterministic hint (e.g. click "New Note") tried before asking a model.
    public var hint: ActionHint?

    public init(id: Int, title: String, instruction: String, route: ExecutionRoute, app: String?, risk: RiskLevel, doneWhen: String, hint: ActionHint?) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.route = route
        self.app = app
        self.risk = risk
        self.doneWhen = doneWhen
        self.hint = hint
    }
}

public struct ActionHint: Codable, Sendable, Hashable {
    public var action: String
    public var target: String?
    public var text: String?

    public init(action: String, target: String?, text: String?) {
        self.action = action
        self.target = target
        self.text = text
    }
}

public struct Plan: Codable, Sendable, Hashable {
    public var goal: String
    public var steps: [PlanStep]
    /// Set when the request can't be planned without more information.
    public var clarification: String?

    public init(goal: String, steps: [PlanStep], clarification: String?) {
        self.goal = goal
        self.steps = steps
        self.clarification = clarification
    }
}

enum PlanSchema {
    static let actionNames = ["click", "double_click", "right_click", "type", "key", "scroll", "launch_app", "activate_app", "open_url", "menu", "none"]

    static let schema: JSONValue = Schema.object([
        ("goal", Schema.string("One sentence restating the user's goal.")),
        ("clarification", Schema.nullableString("A question for the user if the task is impossible or ambiguous, else null.")),
        ("steps", Schema.array(Schema.object([
            ("title", Schema.string("2-5 word present-progressive label shown to the user, e.g. 'Opening Notes'.")),
            ("instruction", Schema.string("What to accomplish in this step, specific enough to act on.")),
            ("route", Schema.string("How to do it.", enum: ExecutionRoute.allCases.map(\.rawValue))),
            ("app", Schema.nullableString("App this step happens in, if any.")),
            ("risk", Schema.string("low, medium (edits/moves/drafts) or high (send, delete, publish, purchase, security).", enum: RiskLevel.allCases.map(\.rawValue))),
            ("done_when", Schema.string("Observable condition proving the step is complete.")),
            ("hint_action", Schema.string("Single obvious first action if known, else none.", enum: actionNames)),
            ("hint_target", Schema.nullableString("Visible label of the control for the hint action, app name, URL, or menu path like 'File > Save'.")),
            ("hint_text", Schema.nullableString("Text to type / key combo for the hint action.")),
        ]))),
    ])

    static func decode(_ json: JSONValue) throws -> Plan {
        guard let stepsJSON = json["steps"]?.arrayValue else { throw LLMError.invalidJSON("plan has no steps") }
        var steps: [PlanStep] = []
        for (i, s) in stepsJSON.enumerated() {
            let hintAction = s["hint_action"]?.stringValue ?? "none"
            let hint = hintAction == "none" ? nil : ActionHint(action: hintAction, target: s["hint_target"]?.stringValue, text: s["hint_text"]?.stringValue)
            steps.append(PlanStep(
                id: i + 1,
                title: s["title"]?.stringValue ?? "Step \(i + 1)",
                instruction: s["instruction"]?.stringValue ?? "",
                route: ExecutionRoute(rawValue: s["route"]?.stringValue ?? "gui") ?? .gui,
                app: s["app"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                risk: RiskLevel(rawValue: s["risk"]?.stringValue ?? "low") ?? .low,
                doneWhen: s["done_when"]?.stringValue ?? "",
                hint: hint))
        }
        let clarification = json["clarification"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return Plan(goal: json["goal"]?.stringValue ?? "", steps: steps, clarification: clarification)
    }
}

/// The action selector's reply for one turn of the execution loop.
public struct ActorDecision: Sendable, Hashable {
    public enum Status: String, Sendable, CaseIterable {
        case act, stepDone = "step_done", taskDone = "task_done", needVision = "need_vision", blocked
    }
    public var status: Status
    public var thought: String
    public var action: String?
    public var elementID: String?
    public var targetDescription: String?
    public var text: String?
    public var keys: String?
    public var direction: String?
    public var amount: Double?
    public var toElementID: String?
    public var app: String?
    public var url: String?
    public var menuPath: [String]?
    public var clearFirst: Bool
    public var submit: Bool
    public var expect: String?
    public var risk: RiskLevel
    public var remember: String?
    public var message: String?
    public var toolName: String?
    public var toolArguments: JSONValue?
}

enum ActorSchema {
    static let actions = ["click", "double_click", "right_click", "type", "key", "scroll", "drag", "focus", "set_value", "select_text",
                          "menu", "launch_app", "activate_app", "open_url", "wait", "call_tool", "none"]

    static let schema: JSONValue = Schema.object([
        ("thought", Schema.string("One short sentence: what you see and why this action.")),
        ("status", Schema.string("act = perform the action; step_done = this step is already complete (no action); task_done = whole task complete; need_vision = target is not in the element list and must be found visually; blocked = cannot proceed.", enum: ActorDecision.Status.allCases.map(\.rawValue))),
        ("action", Schema.string("Action to perform when status is act, else none.", enum: actions)),
        ("element_id", Schema.nullableString("Element id from the list (e.g. e12) the action targets.")),
        ("target_description", Schema.nullableString("Visible label/description of the target when no id fits (used for visual search).")),
        ("text", Schema.nullableString("Text to type or value to set.")),
        ("keys", Schema.nullableString("Key combination for key action, e.g. cmd+n, return, cmd+shift+s.")),
        ("direction", Schema.nullableString("Scroll direction.", enum: ScrollDirection.allCases.map(\.rawValue))),
        ("amount", Schema.number("Scroll lines or wait seconds.", nullable: true)),
        ("to_element_id", Schema.nullableString("Drag destination element id.")),
        ("app", Schema.nullableString("App name for launch_app / activate_app.")),
        ("url", Schema.nullableString("URL for open_url.")),
        ("menu_path", Schema.array(Schema.string(), description: "Menu path for menu action, e.g. [\"File\",\"Save…\"].", nullable: true)),
        ("clear_first", Schema.boolean("Replace existing field text when typing.", nullable: true)),
        ("submit", Schema.boolean("Press Return after typing.", nullable: true)),
        ("expect", Schema.nullableString("Visible label expected to appear after the action, if any.")),
        ("risk", Schema.string("Risk of this action.", enum: RiskLevel.allCases.map(\.rawValue))),
        ("remember", Schema.nullableString("Facts read from the screen worth keeping for later steps (e.g. extracted text), else null.")),
        ("message", Schema.nullableString("For task_done: the result summary for the user. For blocked: why.")),
        ("tool_name", Schema.nullableString("For call_tool: exact tool name.")),
        ("tool_arguments_json", Schema.nullableString("For call_tool: arguments as a JSON object string.")),
    ])

    static func decode(_ j: JSONValue) -> ActorDecision {
        func str(_ k: String) -> String? {
            guard let s = j[k]?.stringValue, !s.isEmpty, s != "null" else { return nil }
            return s
        }
        let toolArgs = str("tool_arguments_json").flatMap { JSONValue.extractObject(from: $0) }
        return ActorDecision(
            status: ActorDecision.Status(rawValue: str("status") ?? "act") ?? .act,
            thought: str("thought") ?? "",
            action: str("action").flatMap { $0 == "none" ? nil : $0 },
            elementID: str("element_id"),
            targetDescription: str("target_description"),
            text: j["text"]?.stringValue,
            keys: str("keys"),
            direction: str("direction"),
            amount: j["amount"]?.doubleValue,
            toElementID: str("to_element_id"),
            app: str("app"),
            url: str("url"),
            menuPath: j["menu_path"]?.arrayValue?.compactMap(\.stringValue),
            clearFirst: j["clear_first"]?.boolValue ?? false,
            submit: j["submit"]?.boolValue ?? false,
            expect: str("expect"),
            risk: RiskLevel(rawValue: str("risk") ?? "low") ?? .low,
            remember: str("remember"),
            message: str("message"),
            toolName: str("tool_name"),
            toolArguments: toolArgs)
    }
}
