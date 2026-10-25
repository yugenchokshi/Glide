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
    /// Ids of the plan's questions this step can't start without. Only these steps wait for
    /// the user; the steps before them (searching, looking) run while the question is open.
    public var needs: [String]

    public init(id: Int, title: String, instruction: String, route: ExecutionRoute, app: String?, risk: RiskLevel, doneWhen: String, hint: ActionHint?,
                needs: [String] = []) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.route = route
        self.app = app
        self.risk = risk
        self.doneWhen = doneWhen
        self.hint = hint
        self.needs = needs
    }

    enum CodingKeys: String, CodingKey { case id, title, instruction, route, app, risk, doneWhen, hint, needs }

    /// Tolerant decoding so steps stored in task history before `needs` existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        instruction = try c.decode(String.self, forKey: .instruction)
        route = try c.decode(ExecutionRoute.self, forKey: .route)
        app = try c.decodeIfPresent(String.self, forKey: .app)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        doneWhen = try c.decode(String.self, forKey: .doneWhen)
        hint = try c.decodeIfPresent(ActionHint.self, forKey: .hint)
        needs = ((try? c.decodeIfPresent([String].self, forKey: .needs)) ?? nil) ?? []
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

/// Whether a request runs now as a quick task or becomes a persisted background job.
public enum PlanMode: String, Codable, Sendable, CaseIterable {
    /// Run the steps now, in the foreground task.
    case quick
    /// Long or repetitive work (many items, waits, schedules, more than ~10 minutes): hand it
    /// to the job engine, which plans milestones and survives restarts.
    case job
}

public struct Plan: Codable, Sendable, Hashable {
    public var goal: String
    public var steps: [PlanStep]
    /// Set when the request can't be planned without more information.
    public var clarification: String?
    /// How the request should run. Plans saved before this existed decode as `.quick`.
    public var mode: PlanMode
    /// Said the moment work starts ("On it — opening Amazon."), at most about 8 words.
    public var ack: String?
    /// Questions asked while the task works ("Which socks?"). They're posted at once; only the
    /// steps that list a question in `needs` wait for its answer.
    public var questions: [AgentQuestion]

    public init(goal: String, steps: [PlanStep], clarification: String?, mode: PlanMode = .quick, ack: String? = nil, questions: [AgentQuestion] = []) {
        self.goal = goal
        self.steps = steps
        self.clarification = clarification
        self.mode = mode
        self.ack = ack
        self.questions = questions
    }

    enum CodingKeys: String, CodingKey { case goal, steps, clarification, mode, ack, questions }

    /// Tolerant decoding so plans stored in task history by older builds (no `mode`, `ack` or
    /// `questions`) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decode(String.self, forKey: .goal)
        steps = try c.decode([PlanStep].self, forKey: .steps)
        clarification = try c.decodeIfPresent(String.self, forKey: .clarification)
        mode = ((try? c.decodeIfPresent(PlanMode.self, forKey: .mode)) ?? nil) ?? .quick
        ack = (try? c.decodeIfPresent(String.self, forKey: .ack)) ?? nil
        questions = ((try? c.decodeIfPresent([AgentQuestion].self, forKey: .questions)) ?? nil) ?? []
    }
}

enum PlanSchema {
    static let actionNames = ["click", "double_click", "right_click", "type", "key", "scroll", "launch_app", "activate_app", "open_url", "menu", "none"]

    /// Most options one question offers (they're shown as chips and read out).
    static let maxOptions = 4

    static let schema: JSONValue = Schema.object([
        ("goal", Schema.string("One sentence restating the user's goal.")),
        ("ack", Schema.string("What Glide says the moment it starts, at most 8 words, warm and plain, e.g. 'On it — opening Amazon.'")),
        ("mode", Schema.string("quick = do it now step by step; job = long or repetitive work that runs in the background (many items, more than ~15 steps, waits or schedules, or more than ~10 minutes).",
                               enum: PlanMode.allCases.map(\.rawValue))),
        ("clarification", Schema.nullableString("Only when NOTHING can be started without an answer, or the task is impossible: one question, with no steps. Else null.")),
        ("questions", Schema.array(Schema.object([
            ("id", Schema.string("Short id steps refer to in needs, e.g. q1.")),
            ("text", Schema.string("The question as shown, short and friendly, e.g. 'Which socks — athletic crew, no-show or wool?'")),
            ("spoken", Schema.nullableString("Shorter version to say out loud, or null to say text.")),
            ("options", Schema.array(Schema.string(), description: "Up to \(maxOptions) short concrete options, or empty for a free answer.")),
            ("default", Schema.nullableString("The option to use if the user doesn't answer (only for low_risk questions), else null.")),
            ("low_risk", Schema.boolean("True only for preferences (size, color, which result). False for anything that buys, sends, deletes or can't be undone.")),
        ]), description: "Questions to ask while working; empty when the request is clear.")),
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
            ("needs", Schema.array(Schema.string(), description: "Ids of questions this step can't start without; empty for steps that can run before the answer.")),
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
                hint: hint,
                needs: (s["needs"]?.arrayValue ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
        }
        let clarification = json["clarification"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        // Unknown or missing modes run as quick tasks: the safe default that needs no job host.
        let mode = json["mode"]?.stringValue.flatMap { PlanMode(rawValue: $0.lowercased()) } ?? .quick
        let questions = decodeQuestions(json["questions"])
        // A step can only wait for a question that exists; anything else would wait forever.
        let known = Set(questions.map(\.id))
        for i in steps.indices { steps[i].needs = steps[i].needs.filter(known.contains) }
        let ack = json["ack"]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty || $0 == "null" ? nil : $0 }
        return Plan(goal: json["goal"]?.stringValue ?? "", steps: steps, clarification: clarification, mode: mode, ack: ack, questions: questions)
    }

    /// The plan's questions. Duplicates and empty questions are dropped, options are capped,
    /// and a default is kept only on a low-risk question, so nothing risky is ever decided by
    /// silence.
    static func decodeQuestions(_ value: JSONValue?) -> [AgentQuestion] {
        func text(_ v: JSONValue?) -> String? {
            guard let s = v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s != "null" else { return nil }
            return s
        }
        var out: [AgentQuestion] = []
        var seen = Set<String>()
        for (i, q) in (value?.arrayValue ?? []).enumerated() {
            guard let question = text(q["text"]) else { continue }
            var id = text(q["id"]) ?? "q\(i + 1)"
            if seen.contains(id) { id = "q\(i + 1)-\(UUID().uuidString.prefix(4))" }
            seen.insert(id)
            let options = (q["options"]?.arrayValue ?? []).compactMap { text($0) }.prefix(maxOptions)
            let lowRisk = q["low_risk"]?.boolValue ?? false
            out.append(AgentQuestion(id: id, text: question, spoken: text(q["spoken"]), options: Array(options),
                                     defaultOption: lowRisk ? text(q["default"]) : nil, lowRisk: lowRisk))
        }
        return out
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
    /// GUI batching: further actions to perform in order after this one, against the same
    /// screen. The runner stops at the first error, unresolved target or unexpected change.
    public var followUps: [ActorDecision] = []
    /// The step's output fields (jobs), returned with `step_done`.
    public var resultFields: [String: JSONValue]? = nil
    /// With `task_done`: the result to say out loud (at most about 25 words).
    public var spoken: String? = nil
}

enum ActorSchema {
    static let actions = ["click", "double_click", "right_click", "type", "key", "scroll", "drag", "focus", "set_value", "select_text",
                          "menu", "launch_app", "activate_app", "open_url", "wait", "call_tool", "none"]

    /// Most follow-up actions one reply may carry (GUI batching).
    static let maxFollowUps = 5

    /// Fields that describe one concrete action; shared by the main action and follow-ups.
    static let actionFields: [(String, JSONValue)] = [
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
    ]

    /// One follow-up action. Tool calls and `none` aren't allowed in a batch.
    static let followUpSchema: JSONValue = Schema.object(
        [("action", Schema.string("Action to perform.", enum: actions.filter { $0 != "call_tool" && $0 != "none" }))] + actionFields)

    static let schema: JSONValue = Schema.object([
        ("thought", Schema.string("One short sentence: what you see and why this action.")),
        ("status", Schema.string("act = perform the action; step_done = this step is already complete (no action); task_done = whole task complete; need_vision = target is not in the element list and must be found visually; blocked = cannot proceed.", enum: ActorDecision.Status.allCases.map(\.rawValue))),
        ("action", Schema.string("Action to perform when status is act, else none.", enum: actions)),
    ] + actionFields + [
        ("actions", Schema.array(followUpSchema, description: "Optional follow-up actions (up to \(maxFollowUps)) performed in order AFTER the main action, on this same screen (e.g. fill the next field, then click Save). Only targets from the current list. Null when none.", nullable: true)),
        ("remember", Schema.nullableString("Facts read from the screen worth keeping for later steps (e.g. extracted text), else null.")),
        ("message", Schema.nullableString("For task_done: the result summary for the user. For blocked: why, or the one question to ask the user.")),
        ("spoken", Schema.nullableString("For task_done: the result said out loud, at most 25 words, plain and warm. Else null.")),
        ("tool_name", Schema.nullableString("For call_tool: exact tool name.")),
        ("tool_arguments_json", Schema.nullableString("For call_tool: arguments as a JSON object string.")),
        ("result_fields_json", Schema.nullableString("With step_done, when the step lists output fields: a JSON object string with exactly those fields, else null.")),
    ])

    static func decode(_ j: JSONValue) -> ActorDecision {
        func str(_ k: String) -> String? { nonEmpty(j[k]) }
        var d = action(from: j, status: ActorDecision.Status(rawValue: str("status") ?? "act") ?? .act)
        d.thought = str("thought") ?? ""
        d.remember = str("remember")
        d.message = str("message")
        d.spoken = str("spoken")
        d.toolName = str("tool_name")
        // Both JSON-string fields also accept the object itself, which models send when the
        // schema isn't enforced (prompt-only fallbacks).
        if case .object? = j["tool_arguments_json"] {
            d.toolArguments = j["tool_arguments_json"]
        } else {
            d.toolArguments = str("tool_arguments_json").flatMap { JSONValue.extractObject(from: $0) }
        }
        d.resultFields = StepResult.decodeResultFields(j["result_fields_json"]).fields
        // Capped here so a model can't queue an unbounded batch; items without an action are dropped.
        d.followUps = (j["actions"]?.arrayValue ?? []).prefix(maxFollowUps).compactMap { item in
            guard item.objectValue != nil else { return nil }
            let f = action(from: item, status: .act)
            return f.action == nil || f.action == "call_tool" ? nil : f
        }
        return d
    }

    private static func nonEmpty(_ v: JSONValue?) -> String? {
        guard let s = v?.stringValue, !s.isEmpty, s != "null" else { return nil }
        return s
    }

    /// Decodes the action fields of the top-level reply or of one follow-up item.
    private static func action(from j: JSONValue, status: ActorDecision.Status) -> ActorDecision {
        func str(_ k: String) -> String? { nonEmpty(j[k]) }
        return ActorDecision(
            status: status,
            thought: "",
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
            remember: nil,
            message: nil,
            toolName: nil,
            toolArguments: nil)
    }

    /// True when two decisions describe the same concrete action (used to drop a follow-up
    /// that repeats the main action, which would otherwise type or click twice).
    static func sameAction(_ a: ActorDecision, _ b: ActorDecision) -> Bool {
        a.action == b.action && a.elementID == b.elementID && a.targetDescription == b.targetDescription && a.text == b.text
            && a.keys == b.keys && a.menuPath == b.menuPath && a.url == b.url && a.app == b.app && a.toElementID == b.toElementID
            && a.direction == b.direction
    }
}
