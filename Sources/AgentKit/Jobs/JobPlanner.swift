import Foundation

// MARK: - Planning context

/// What the job planner knows about the user's setup when it plans: the files the request
/// mentions (with a peek at spreadsheets), what tools can reach, and the time. Planning
/// against real file headers is what makes "fill in the CEO column" plans come out right.
public struct JobPlanningContext: Sendable {
    public struct FileInfo: Sendable, Hashable {
        public var path: String
        public var isDirectory: Bool
        /// Spreadsheets: the header and up to 3 rows. Other files: nil.
        public var preview: TableData?
        public var rowCount: Int?

        public init(path: String, isDirectory: Bool, preview: TableData? = nil, rowCount: Int? = nil) {
            self.path = path
            self.isDirectory = isDirectory
            self.preview = preview
            self.rowCount = rowCount
        }
    }

    public var request: String
    public var date: Date
    public var files: [FileInfo]
    /// Connected integrations (Composio toolkits, MCP servers/tools).
    public var integrations: [String]
    /// One line about the browser ("connected via the Glide extension", "not connected").
    public var browser: String
    public var commandAccess: CommandAccess
    public var allowAppleScript: Bool
    public var allowShortcuts: Bool
    public var executionPreference: ExecutionPreference
    /// Tool families installed in this build.
    public var toolFamilies: [ToolCategory]
    public var screenUse: ScreenUse

    public init(request: String, date: Date = Date(), files: [FileInfo] = [], integrations: [String] = [], browser: String = "unknown",
                commandAccess: CommandAccess = .full, allowAppleScript: Bool = true, allowShortcuts: Bool = true,
                executionPreference: ExecutionPreference = .fastest, toolFamilies: [ToolCategory] = ToolCategory.allCases, screenUse: ScreenUse = .whenIdle) {
        self.request = request
        self.date = date
        self.files = files
        self.integrations = integrations
        self.browser = browser
        self.commandAccess = commandAccess
        self.allowAppleScript = allowAppleScript
        self.allowShortcuts = allowShortcuts
        self.executionPreference = executionPreference
        self.toolFamilies = toolFamilies
        self.screenUse = screenUse
    }

    /// Gathers the context for `request` from the live system (files on disk, browser status,
    /// MCP tools, installed tool families). Composio toolkits are included when a session is
    /// already set up; planning never creates one.
    public static func gather(request: String, settings: AppSettings, composioToolkits: [String] = []) async -> JobPlanningContext {
        var ctx = JobPlanningContext(request: request, settings: settings)
        ctx.files = mentionedFiles(in: request)
        let status = await BrowserHub.shared.status(settings: settings.browser)
        if status.connected {
            ctx.browser = "connected (\(status.backend.title))"
        } else if settings.browser.fallbackToGlideChrome || settings.browser.backend == .glideChrome {
            ctx.browser = status.chromeInstalled ? "not connected now; Glide can open its own Chrome window when needed" : "unavailable (Chrome isn't installed)"
        } else {
            ctx.browser = "not connected (the Glide Chrome extension isn't paired)"
        }
        var integrations = composioToolkits.map { "Composio: \($0)" }
        let mcp = await MCPManager.shared.allTools()
        for (server, tools) in Dictionary(grouping: mcp, by: \.server).sorted(by: { $0.key < $1.key }) {
            integrations.append("MCP \(server): " + tools.prefix(12).map(\.name).joined(separator: ", ") + (tools.count > 12 ? ", …" : ""))
        }
        ctx.integrations = integrations
        let families = Set(ToolRegistry.standard(settings: settings).specs().map(\.category))
        ctx.toolFamilies = ToolCategory.allCases.filter { families.contains($0) }
        return ctx
    }

    public init(request: String, settings: AppSettings, date: Date = Date()) {
        self.init(request: request, date: date, commandAccess: settings.tools.commandAccess, allowAppleScript: settings.tools.allowAppleScript,
                  allowShortcuts: settings.tools.allowShortcuts, executionPreference: settings.tools.executionPreference,
                  screenUse: settings.jobs.screenUse)
    }

    static let spreadsheetExtensions: Set<String> = ["csv", "tsv", "xlsx", "xlsm"]

    /// Existing files and folders the request mentions: absolute or `~/` paths (quoted or
    /// not), and bare file names found on the Desktop, in Documents or in Downloads.
    public static func mentionedFiles(in request: String, searchFolders: [URL]? = nil, maxFiles: Int = 6) -> [FileInfo] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = searchFolders ?? ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0) }
        var candidates: [String] = []
        // Quoted strings first: they can contain spaces.
        let quoted = try? NSRegularExpression(pattern: #"["“'‘]([^"”'’\n]{1,400})["”'’]"#)
        let ns = request as NSString
        quoted?.enumerateMatches(in: request, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let r = m?.range(at: 1), r.location != NSNotFound { candidates.append(ns.substring(with: r)) }
        }
        let bare = try? NSRegularExpression(pattern: #"(?:~|/)[^\s"“”'‘’]+|[A-Za-z0-9_\-.]+\.[A-Za-z0-9]{2,5}\b"#)
        bare?.enumerateMatches(in: request, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let r = m?.range { candidates.append(ns.substring(with: r)) }
        }
        var seen = Set<String>()
        var out: [FileInfo] = []
        let fm = FileManager.default
        for raw in candidates {
            guard out.count < maxFiles else { break }
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!?)(]["))
            guard !cleaned.isEmpty, !cleaned.contains("://") else { continue }
            var paths: [String] = []
            if cleaned.hasPrefix("/") || cleaned.hasPrefix("~") {
                paths = [(cleaned as NSString).expandingTildeInPath]
            } else if !cleaned.contains("/") {
                paths = folders.map { $0.appendingPathComponent(cleaned).path }
            }
            for p in paths {
                let std = (p as NSString).standardizingPath
                var isDir: ObjCBool = false
                guard !seen.contains(std), fm.fileExists(atPath: std, isDirectory: &isDir) else { continue }
                seen.insert(std)
                var info = FileInfo(path: std, isDirectory: isDir.boolValue)
                let ext = (std as NSString).pathExtension.lowercased()
                if !isDir.boolValue, spreadsheetExtensions.contains(ext), let table = try? TableIO.reader(std, nil, true) {
                    info.preview = TableData(columns: table.columns, rows: Array(table.rows.prefix(3)), sheet: table.sheet)
                    info.rowCount = table.rows.count
                }
                out.append(info)
                break
            }
        }
        return out
    }

    var rendered: String {
        let df = DateFormatter()
        df.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var lines = ["Now: \(df.string(from: date)) (\(TimeZone.current.identifier))"]
        switch executionPreference {
        case .fastest:
            lines.append("Execution preference: fastest — use command, web, data and browser routes wherever they can do the work; gui/native only when nothing else can.")
        case .showMe:
            lines.append("Execution preference: show me — the user likes to watch; on-screen gui steps are fine for app work, but keep web research and data work on fast routes.")
        }
        var access: String
        switch commandAccess {
        case .off: access = "off (no command route)"
        case .readOnly: access = "read-only (commands can read but not change anything)"
        case .full: access = "full (changes follow the user's approval settings)"
        }
        if commandAccess != .off {
            access += "; AppleScript \(allowAppleScript ? "allowed" : "off"); Shortcuts \(allowShortcuts ? "allowed" : "off")"
        }
        lines.append("Command access: \(access)")
        lines.append("Browser: \(browser)")
        lines.append("Screen use by background jobs: \(screenUse.title)")
        lines.append("Installed tool families: " + (toolFamilies.isEmpty ? "none" : toolFamilies.map(\.rawValue).joined(separator: ", ")))
        lines.append("Connected integrations: " + (integrations.isEmpty ? "none" : integrations.prefix(20).joined(separator: "; ")))
        if files.isEmpty {
            lines.append("Files mentioned: none found on disk")
        } else {
            lines.append("Files mentioned:")
            for f in files {
                var line = "- \(f.path)\(f.isDirectory ? " (folder)" : "")"
                if let rows = f.rowCount { line += " — \(rows) data rows" }
                lines.append(line)
                if let p = f.preview {
                    lines.append("  columns: " + p.columns.map { "“\($0)”" }.joined(separator: ", "))
                    for r in p.rows { lines.append("  row: " + r.map { String($0.prefix(60)) }.joined(separator: " | ")) }
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Planner

/// What a planner returns: the plan plus what planning cost (counted into the job's usage).
public struct JobPlanOutcome: Sendable {
    public var plan: JobPlan
    public var usage: LLMUsage
    public var modelCalls: Int
    /// Model that planned (for pricing), when known.
    public var model: String?

    public init(plan: JobPlan, usage: LLMUsage = LLMUsage(), modelCalls: Int = 0, model: String? = nil) {
        self.plan = plan
        self.usage = usage
        self.modelCalls = modelCalls
        self.model = model
    }
}

/// Turns a request into a `JobPlan`. The production planner asks the planning model; tests
/// inject a fixed plan.
public protocol JobPlanning: Sendable {
    func plan(_ instruction: String, context: JobPlanningContext) async throws -> JobPlanOutcome
}

public enum JobPlanError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let m): return "The job plan didn't make sense: \(m)"
        }
    }
}

/// Plans jobs with the planning model (`ModelRouter` role `.planner`) and a strict JSON schema.
public struct JobPlanner: JobPlanning {
    let router: ModelRouter

    public init(router: ModelRouter) {
        self.router = router
    }

    public func plan(_ instruction: String, context: JobPlanningContext) async throws -> JobPlanOutcome {
        let route = try router.route(.planner)
        let message = """
        \(context.rendered)

        User request: \(instruction)
        """
        let req = LLMRequest(model: route.model, system: JobPlanSchema.prompt, messages: [.user(message)], schema: JobPlanSchema.schema,
                             schemaName: "job_plan", maxTokens: 12_000, effort: route.effort, timeout: 180)
        let r = try await route.provider.complete(req)
        guard let json = r.json ?? JSONValue.extractObject(from: r.text) else { throw LLMError.invalidJSON(r.text) }
        let plan = try JobPlanSchema.decode(json)
        return JobPlanOutcome(plan: plan, usage: r.usage, modelCalls: 1, model: r.model.isEmpty ? route.model : r.model)
    }

    // MARK: Estimate

    /// Model turns of an action step.
    static let callsPerAction = 3.0
    static let secondsPerToolTurn = 8.0
    static let secondsPerGUITurn = 20.0
    /// Items assumed for a loop whose items aren't known before it runs.
    static let assumedItems = 10
    /// Runs assumed for a daily repeat with no end.
    static let assumedDailyRuns = 7
    /// Typical tokens per call, for the cost estimate.
    static let actorCallUsage = LLMUsage(inputTokens: 3500, outputTokens: 400)
    static let plannerCallUsage = LLMUsage(inputTokens: 6000, outputTokens: 2500)

    static func turnSeconds(_ route: ExecutionRoute) -> Double { route.needsScreen ? secondsPerGUITurn : secondsPerToolTurn }

    /// Estimates items, model calls, active minutes and cost.
    ///
    /// - Per item: ≈ 1.5 calls per recipe step + 1; per action step: 3 calls; one verification
    ///   call per milestone with a done condition, one for the report and one for planning.
    /// - Time: ≈ 8 s per tool turn and 20 s per on-screen turn; loops divide by their
    ///   parallelism (on-screen loops run one at a time). Waits aren't counted (they're idle).
    /// - Cost: actor-model calls and planner-model calls priced with `ModelPricing`; nil when
    ///   either price is unknown.
    ///
    /// - Parameter items: item counts per for-each step id, when known (others assume 10).
    public static func estimate(_ plan: JobPlan, items: [Int: Int] = [:], actorModel: String? = nil, plannerModel: String? = nil) -> JobEstimate {
        var actorCalls = 0.0, plannerCalls = 1.0, seconds = 0.0, totalItems = 0
        var notes: [String] = []
        for m in plan.milestones {
            var repeats = 1.0
            for step in m.steps {
                switch step.kind {
                case .action(let r):
                    actorCalls += callsPerAction * repeats
                    seconds += callsPerAction * turnSeconds(r.route) * repeats
                case .forEach(let spec):
                    var n = items[step.id] ?? assumedItems
                    if items[step.id] == nil { notes.append("“\(step.title)”: item count unknown until it runs (assumed \(assumedItems))") }
                    if let limit = spec.limit { n = min(n, max(0, limit)) }
                    let recipe = spec.recipe
                    let perItemCalls = 1.5 * Double(recipe.count) + 1
                    let perItemSeconds = recipe.reduce(0.0) { $0 + 1.5 * turnSeconds($1.route) } + secondsPerToolTurn
                    let needsScreen = recipe.contains { $0.route.needsScreen }
                    let width = needsScreen ? 1 : min(max(spec.parallelism, 1), max(n, 1))
                    actorCalls += Double(n) * perItemCalls * repeats
                    seconds += Double(n) * perItemSeconds / Double(width) * repeats
                    totalItems += Int(Double(n) * repeats)
                    notes.append("\(n) \(pluralize(spec.itemLabel, n)) × \(recipe.count) step\(recipe.count == 1 ? "" : "s")" + (width > 1 ? ", \(width) at a time" : ""))
                case .wait(let w):
                    switch w {
                    case .daily(_, _, let times):
                        repeats *= Double(max(0, times ?? assumedDailyRuns))
                        notes.append(times.map { "repeats \($0) times" } ?? "repeats daily until stopped (estimated for \(assumedDailyRuns) days)")
                    case .condition(_, _, let maxTries):
                        // One check is a short tool step; count a few tries.
                        let tries = Double(min(max(maxTries, 1), 3))
                        actorCalls += tries * repeats
                        seconds += tries * secondsPerToolTurn * repeats
                    case .duration, .until:
                        break
                    }
                }
            }
            if !m.doneWhen.trimmingCharacters(in: .whitespaces).isEmpty {
                actorCalls += 1
                seconds += secondsPerToolTurn
            }
        }
        actorCalls += 1 // the report
        seconds += secondsPerToolTurn
        var cost: Double? = nil
        if let actorModel, let plannerModel,
           let a = ModelPricing.cost(model: actorModel, usage: actorCallUsage), let p = ModelPricing.cost(model: plannerModel, usage: plannerCallUsage) {
            cost = actorCalls * a + plannerCalls * p
        }
        return JobEstimate(items: totalItems, modelCalls: Int((actorCalls + plannerCalls).rounded(.up)), minutes: seconds / 60, costUSD: cost,
                           notes: notes.joined(separator: "; "))
    }

    static func pluralize(_ noun: String, _ n: Int) -> String {
        let w = noun.trimmingCharacters(in: .whitespaces)
        guard n != 1, !w.isEmpty else { return w.isEmpty ? (n == 1 ? "item" : "items") : w }
        let lower = w.lowercased()
        if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("ch") || lower.hasSuffix("sh") { return w + "es" }
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) { return String(w.dropLast()) + "ies" }
        return w + "s"
    }
}

// MARK: - Schema and decoding

enum JobPlanSchema {
    static let prompt = """
    You plan long-running background jobs for Glide, a macOS agent. A job runs for minutes to hours \
    (or across days) while the user does other things; progress is saved after every step, so it can \
    pause, resume, retry and survive restarts. A fast executor model carries out each step with tools.

    Turn the request into a plan of milestones (usually 1–4), each made of steps. A step is one of:
    - action: one sub-goal carried out with tools (e.g. "Find the pricing page of example.com and save \
      the plan names and prices").
    - for_each: the same recipe run for every item of a list — rows of a spreadsheet (source file), a \
      table the job saved earlier (source table), a literal list (source list), or the list output of an \
      earlier step (source step_output). Use it for "for each…", "every…", "all N…" work and whenever more \
      than about 5 similar things must be done. Each item runs the recipe's steps in order with the item as \
      context; results go into output_table with output_columns, and can be written back into the \
      user's spreadsheet (write_back).
    - wait: sleep for a duration, until a moment, every day at a time (daily: the steps after it in the \
      same milestone repeat each day), or until a condition is true (re-checked every_seconds).

    Routes:
    - command: shell commands, AppleScript/JXA, Shortcuts and file operations. Fast and invisible.
    - browser: Chrome controlled at the DOM level in background tabs, with the user's own logins. Use it \
      for sites that need a login or interaction (forms, dashboards, web apps).
    - web: web search and page fetches over HTTP without a browser. Fastest for public information.
    - data: reading and writing spreadsheets (CSV, XLSX) directly.
    - gui: an app's on-screen UI with the real cursor. Only when nothing else can do it: it takes over \
      the screen and runs one item at a time.
    - native: launching apps and opening URLs on screen.
    - composio / mcp: a connected integration from the context.
    - answer: no tools; write text from what the job has gathered (summaries, drafts, decisions).
    Follow the execution preference in the context. Don't use the command route when command access is off.

    Rules:
    - Steps are numbered across the whole plan in order, starting at 1 (all of milestone 1's steps, then \
      milestone 2's…). A step_output source names an earlier step by that number; that step's \
      output_fields must include a field that holds the list (e.g. "items").
    - parallelism: up to 4 when the recipe only uses web, data or command; at most 2 with browser; 1 when \
      any recipe step uses gui or native.
    - output_fields: snake_case names of the results each step must produce. For for_each, output_columns \
      are the result columns, and the recipe steps' output_fields together must cover them.
    - write_back: only when the user asked to fill in or update their spreadsheet; columns lists the \
      result fields to write (missing columns are added). key_column matches rows by a column (null = row order).
    - Approvals: set requires_approval on a milestone whose steps send, post, publish, delete, purchase or \
      otherwise act on the user's behalf, so the user can check the results before it starts. risk: high \
      for those actions, medium for edits and writing files, low for reading.
    - Waits: use them for "every day…", "check back…", "wait until…", "tomorrow…". Put the repeated work \
      right after a daily wait in the same milestone. until is local time "YYYY-MM-DDTHH:MM".
    - The executor only sees the step, the current item and the job's memory: write specific instructions \
      (what to find, where, what to save) and mention files by absolute path.
    - Milestone done_when is checked against the job's saved results: make it concrete and checkable.
    - Use limit only when the user asks for a trial run or a maximum number of items.
    - Never plan to enter passwords, one-time codes or payment details.
    - If the request is impossible or dangerously ambiguous, set clarification to one question and return \
      no milestones.
    - outputs: one sentence on what the user gets at the end (files, a table, a summary).
    """

    static func nullableInteger(_ description: String) -> JSONValue {
        .object(["type": ["integer", "null"], "description": .string(description)])
    }

    static let recipeStep: JSONValue = Schema.object([
        ("title", Schema.string("2–5 word present-progressive label, e.g. 'Finding the website'.")),
        ("instruction", Schema.string("What to accomplish, specific enough to act on.")),
        ("route", Schema.string("How to do it.", enum: ExecutionRoute.allCases.map(\.rawValue))),
        ("app", Schema.nullableString("App this step happens in, for gui/native steps.")),
        ("risk", Schema.string("low, medium (edits, writing files) or high (send, delete, publish, purchase).", enum: RiskLevel.allCases.map(\.rawValue))),
        ("done_when", Schema.string("Condition proving the step is complete.")),
        ("output_fields", Schema.array(Schema.string(), description: "snake_case result fields this step produces.")),
    ])

    static let source: JSONValue = Schema.object([
        ("kind", Schema.string("Where the items come from.", enum: ["file", "table", "list", "step_output"])),
        ("path", Schema.nullableString("file: absolute path of the CSV/XLSX file.")),
        ("sheet", Schema.nullableString("file: sheet name for XLSX, else null.")),
        ("column", Schema.nullableString("file: column whose value labels each item (e.g. 'Company'), else null.")),
        ("has_header", Schema.boolean("file: whether the first row holds column names.")),
        ("table", Schema.nullableString("table: name of a table saved earlier in the job.")),
        ("items", Schema.array(Schema.string(), description: "list: the items.", nullable: true)),
        ("step_number", nullableInteger("step_output: number of the earlier step whose list output to use.")),
    ])

    static let forEach: JSONValue = Schema.object([
        ("source", source),
        ("item_label", Schema.string("Singular noun for one item, e.g. 'company'.")),
        ("parallelism", Schema.integer("Items processed at once (1–4; see rules).")),
        ("output_table", Schema.string("snake_case table that collects item results, e.g. 'companies'.")),
        ("output_columns", Schema.array(Schema.string(), description: "Result columns to collect per item.")),
        ("limit", nullableInteger("Process at most this many items (trial runs), else null.")),
        ("recipe", Schema.array(recipeStep, description: "Steps run for every item, in order.")),
        ("write_back", Schema.nullable(Schema.object([
            ("path", Schema.string("Spreadsheet to update (usually the source file).")),
            ("sheet", Schema.nullableString("Sheet name for XLSX, else null.")),
            ("key_column", Schema.nullableString("Column that matches rows, or null for row order.")),
            ("columns", Schema.array(Schema.string(), description: "Result fields to write, in order.")),
        ]))),
    ])

    static let wait: JSONValue = Schema.object([
        ("kind", Schema.string("duration, until (a moment), daily (repeat the rest of the milestone every day), condition (re-check until true).",
                               enum: ["duration", "until", "daily", "condition"])),
        ("seconds", Schema.number("duration: seconds to wait.", nullable: true)),
        ("until", Schema.nullableString("until: local time 'YYYY-MM-DDTHH:MM'.")),
        ("hour", nullableInteger("daily: hour 0–23.")),
        ("minute", nullableInteger("daily: minute 0–59.")),
        ("times", nullableInteger("daily: how many days to repeat, or null until stopped.")),
        ("check", Schema.nullableString("condition: the condition to check, e.g. 'the order page shows Shipped'.")),
        ("every_seconds", Schema.number("condition: seconds between checks.", nullable: true)),
        ("max_tries", nullableInteger("condition: give up after this many checks.")),
    ])

    static let schema: JSONValue = Schema.object([
        ("goal", Schema.string("One sentence restating the user's goal.")),
        ("clarification", Schema.nullableString("A question for the user if the job is impossible or ambiguous, else null.")),
        ("outputs", Schema.string("What the user gets at the end.")),
        ("milestones", Schema.array(Schema.object([
            ("title", Schema.string("Short milestone name, e.g. 'Research the companies'.")),
            ("description", Schema.string("One sentence on what this milestone achieves.")),
            ("done_when", Schema.string("Checkable condition on the saved results that proves the milestone is complete.")),
            ("requires_approval", Schema.boolean("Pause for the user's OK before starting (sending, publishing, deleting, buying).")),
            ("steps", Schema.array(Schema.object([
                ("kind", Schema.string("Step type.", enum: ["action", "for_each", "wait"])),
                ("title", Schema.string("2–5 word label shown in progress, e.g. 'Researching companies'.")),
                ("action", Schema.nullable(recipeStep)),
                ("for_each", Schema.nullable(forEach)),
                ("wait", Schema.nullable(wait)),
            ]))),
        ]))),
    ])

    static let maxSteps = 60
    static let maxItemsInList = 5000

    /// Decodes the planner's reply into a `JobPlan`, tolerating missing or odd optional fields
    /// but rejecting plans that can't run (a loop without steps, a wait without a time, a
    /// reference to a later step).
    static func decode(_ json: JSONValue) throws -> JobPlan {
        let clarification = str(json["clarification"])
        let milestonesJSON = json["milestones"]?.arrayValue ?? []
        if milestonesJSON.isEmpty {
            if let clarification {
                return JobPlan(goal: str(json["goal"]) ?? "", milestones: [], outputs: str(json["outputs"]) ?? "", clarification: clarification)
            }
            throw JobPlanError.invalid("it has no milestones.")
        }
        var milestones: [Milestone] = []
        var nextStepID = 1
        var actionSteps: Set<Int> = []
        for (mi, m) in milestonesJSON.enumerated() {
            var steps: [JobStep] = []
            for s in m["steps"]?.arrayValue ?? [] {
                let id = nextStepID
                nextStepID += 1
                let title = str(s["title"]) ?? "Step \(id)"
                let kind = str(s["kind"]) ?? (s["for_each"]?.objectValue != nil ? "for_each" : s["wait"]?.objectValue != nil ? "wait" : "action")
                switch kind {
                case "for_each":
                    guard let f = s["for_each"], f.objectValue != nil else { throw JobPlanError.invalid("step \(id) (“\(title)”) is a loop with no details.") }
                    let spec = try decodeForEach(f, stepID: id, title: title, earlierActions: actionSteps)
                    steps.append(JobStep(id: id, title: title, kind: .forEach(spec)))
                case "wait":
                    guard let w = s["wait"], w.objectValue != nil else { throw JobPlanError.invalid("step \(id) (“\(title)”) is a wait with no details.") }
                    steps.append(JobStep(id: id, title: title, kind: .wait(try decodeWait(w, stepID: id))))
                default:
                    guard let a = s["action"], a.objectValue != nil else { throw JobPlanError.invalid("step \(id) (“\(title)”) has no action.") }
                    var r = decodeRecipeStep(a, id: id)
                    if r.title.isEmpty || r.title == "Step \(id)" { r.title = title }
                    guard !r.instruction.isEmpty else { throw JobPlanError.invalid("step \(id) (“\(title)”) has no instruction.") }
                    actionSteps.insert(id)
                    steps.append(JobStep(id: id, title: title, kind: .action(r)))
                }
            }
            guard !steps.isEmpty else { continue }
            milestones.append(Milestone(id: mi + 1, title: str(m["title"]) ?? "Part \(mi + 1)", description: str(m["description"]) ?? "",
                                        doneWhen: str(m["done_when"]) ?? "", steps: steps, requiresApproval: m["requires_approval"]?.boolValue ?? false))
        }
        guard !milestones.isEmpty else { throw JobPlanError.invalid("none of its milestones has any steps.") }
        let count = milestones.reduce(0) { $0 + $1.steps.count }
        guard count <= maxSteps else { throw JobPlanError.invalid("it has \(count) steps; use for_each loops instead of listing similar steps one by one.") }
        // Renumber milestones so ids are dense even if empty ones were dropped.
        for i in milestones.indices { milestones[i].id = i + 1 }
        return JobPlan(goal: str(json["goal"]) ?? "", milestones: milestones, outputs: str(json["outputs"]) ?? "", clarification: clarification)
    }

    static func decodeRecipeStep(_ j: JSONValue, id: Int) -> RecipeStep {
        RecipeStep(id: id, title: str(j["title"]) ?? "Step \(id)", instruction: str(j["instruction"]) ?? "",
                   route: str(j["route"]).flatMap(ExecutionRoute.init(rawValue:)) ?? .gui, app: str(j["app"]),
                   risk: str(j["risk"]).flatMap(RiskLevel.init(rawValue:)) ?? .low, doneWhen: str(j["done_when"]) ?? "",
                   outputFields: (j["output_fields"]?.arrayValue ?? []).compactMap { str($0) })
    }

    static func decodeForEach(_ f: JSONValue, stepID: Int, title: String, earlierActions: Set<Int>) throws -> ForEachSpec {
        let recipeJSON = f["recipe"]?.arrayValue ?? []
        var recipe: [RecipeStep] = []
        for (i, r) in recipeJSON.enumerated() {
            let step = decodeRecipeStep(r, id: i + 1)
            guard !step.instruction.isEmpty else { throw JobPlanError.invalid("recipe step \(i + 1) of “\(title)” has no instruction.") }
            recipe.append(step)
        }
        guard !recipe.isEmpty else { throw JobPlanError.invalid("the loop “\(title)” has no recipe steps.") }
        let src = f["source"] ?? .null
        let source: ItemSource
        switch str(src["kind"]) ?? "" {
        case "file":
            guard let path = str(src["path"]) else { throw JobPlanError.invalid("the loop “\(title)” reads a file but names no path.") }
            source = .file(path: (path as NSString).expandingTildeInPath, sheet: str(src["sheet"]), column: str(src["column"]),
                           hasHeader: src["has_header"]?.boolValue ?? true)
        case "table":
            guard let name = str(src["table"]) else { throw JobPlanError.invalid("the loop “\(title)” reads a table but names none.") }
            source = .table(name: name)
        case "list":
            // Keep every non-empty entry as written (an item may legitimately be called "None").
            let items = (src["items"]?.arrayValue ?? []).compactMap { v -> String? in
                guard let s = v.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
                return s
            }
            guard !items.isEmpty else { throw JobPlanError.invalid("the loop “\(title)” has an empty list of items.") }
            source = .list(Array(items.prefix(maxItemsInList)))
        case "step_output":
            guard let n = src["step_number"]?.intValue else { throw JobPlanError.invalid("the loop “\(title)” uses an earlier step's output but doesn't say which.") }
            guard n < stepID else { throw JobPlanError.invalid("the loop “\(title)” (step \(stepID)) uses the output of step \(n), which doesn't come before it.") }
            guard earlierActions.contains(n) else {
                throw JobPlanError.invalid("the loop “\(title)” uses step \(n)'s output, but step \(n) isn't an action step.")
            }
            source = .stepOutput(stepID: n)
        default:
            throw JobPlanError.invalid("the loop “\(title)” has no item source.")
        }
        let needsScreen = recipe.contains { $0.route.needsScreen }
        let usesBrowser = recipe.contains { $0.route == .browser }
        let cap = needsScreen ? 1 : (usesBrowser ? 2 : 4)
        let parallelism = min(max(f["parallelism"]?.intValue ?? 1, 1), cap)
        let label = str(f["item_label"]) ?? "item"
        var outputColumns = (f["output_columns"]?.arrayValue ?? []).compactMap { str($0) }
        if outputColumns.isEmpty { outputColumns = Array(NSOrderedSet(array: recipe.flatMap(\.outputFields)).compactMap { $0 as? String }) }
        let table = str(f["output_table"]) ?? "results_\(stepID)"
        var writeBack: WriteBack?
        if let wb = f["write_back"], wb.objectValue != nil, let path = str(wb["path"]) {
            let cols = (wb["columns"]?.arrayValue ?? []).compactMap { str($0) }
            writeBack = WriteBack(path: (path as NSString).expandingTildeInPath, sheet: str(wb["sheet"]), keyColumn: str(wb["key_column"]),
                                  columns: cols.isEmpty ? outputColumns : cols)
            if writeBack?.columns.isEmpty == true { writeBack = nil }
        }
        let limit = f["limit"]?.intValue.flatMap { $0 > 0 ? $0 : nil }
        return ForEachSpec(source: source, itemLabel: label, recipe: recipe, parallelism: parallelism, outputTable: table,
                           outputColumns: outputColumns, writeBack: writeBack, limit: limit)
    }

    static func decodeWait(_ w: JSONValue, stepID: Int) throws -> WaitSpec {
        switch str(w["kind"]) ?? "" {
        case "duration":
            guard let s = w["seconds"]?.doubleValue, s.isFinite, s >= 0 else { throw JobPlanError.invalid("wait step \(stepID) has no duration.") }
            return .duration(seconds: min(s, 60 * 86_400))
        case "until":
            guard let text = str(w["until"]), let date = parseLocalDate(text) else {
                throw JobPlanError.invalid("wait step \(stepID) has no valid time (expected YYYY-MM-DDTHH:MM).")
            }
            return .until(date)
        case "daily":
            guard let h = w["hour"]?.intValue, (0...23).contains(h) else { throw JobPlanError.invalid("daily wait step \(stepID) has no valid hour.") }
            let m = min(max(w["minute"]?.intValue ?? 0, 0), 59)
            let times = w["times"]?.intValue.map { min(max($0, 1), 366) }
            return .daily(hour: h, minute: m, times: times)
        case "condition":
            guard let check = str(w["check"]) else { throw JobPlanError.invalid("condition wait step \(stepID) has nothing to check.") }
            let every = min(max(w["every_seconds"]?.doubleValue ?? 600, 30), 7 * 86_400)
            let tries = min(max(w["max_tries"]?.intValue ?? 24, 1), 1000)
            return .condition(check: check, everySeconds: every, maxTries: tries)
        default:
            throw JobPlanError.invalid("wait step \(stepID) has an unknown kind.")
        }
    }

    /// "YYYY-MM-DDTHH:MM[:SS]" in local time, or a full ISO 8601 timestamp with a zone.
    static func parseLocalDate(_ text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = .current
            df.dateFormat = format
            if let d = df.date(from: t) { return d }
        }
        return nil
    }

    /// Non-empty trimmed string, treating "null"/"none" as missing.
    static func str(_ v: JSONValue?) -> String? {
        guard let s = v?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s != "null", s.lowercased() != "none" else { return nil }
        return s
    }
}
