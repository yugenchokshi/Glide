import Foundation

// Long-running jobs. A job is a persisted, resumable task: a plan of milestones, each made of
// steps; a step is a single action, a loop over items ("for each row…"), or a wait. Progress,
// item results and memory are saved after every step, so a job survives quitting Glide,
// crashes and sleep, and can run in the background for hours.

public enum JobStatus: String, Codable, Sendable, CaseIterable {
    /// Being planned.
    case planning
    /// Planned; waiting for the user to confirm the estimate before starting.
    case awaitingConfirmation
    case running
    case paused
    /// Sleeping until `nextWakeAt` (a wait step or a schedule).
    case waiting
    /// Stopped to ask the user something (approval, clarification, stuck).
    case needsInput
    case completed
    case failed
    case stopped

    public var isActive: Bool { self == .running || self == .planning }
    public var isFinished: Bool { self == .completed || self == .failed || self == .stopped }
    /// Can be continued by `resume`.
    public var isResumable: Bool { self == .paused || self == .needsInput || self == .waiting || self == .failed }
}

public enum ItemStatus: String, Codable, Sendable, CaseIterable {
    case pending, running, done, failed, skipped
}

/// One unit of work inside a step: an action route plus what "done" means.
public struct RecipeStep: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var instruction: String
    public var route: ExecutionRoute
    public var app: String?
    public var risk: RiskLevel
    public var doneWhen: String
    /// Named result fields this step should produce (become item result columns).
    public var outputFields: [String]

    public init(id: Int, title: String, instruction: String, route: ExecutionRoute, app: String? = nil, risk: RiskLevel = .low,
                doneWhen: String = "", outputFields: [String] = []) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.route = route
        self.app = app
        self.risk = risk
        self.doneWhen = doneWhen
        self.outputFields = outputFields
    }

    /// Bridges to the classic plan step (used by the GUI step runner).
    public var asPlanStep: PlanStep {
        PlanStep(id: id, title: title, instruction: instruction, route: route, app: app, risk: risk, doneWhen: doneWhen, hint: nil)
    }
}

/// Where a loop's items come from.
public enum ItemSource: Codable, Sendable, Hashable {
    /// Rows of a CSV/XLSX file (one item per row; `column` picks the label column).
    case file(path: String, sheet: String?, column: String?, hasHeader: Bool)
    /// Rows of a workspace table produced earlier in the job.
    case table(name: String)
    /// A literal list.
    case list([String])
    /// The structured list output of an earlier step (its `data` must be an array).
    case stepOutput(stepID: Int)
}

/// Write item results back into a spreadsheet (e.g. fill columns of the input file).
public struct WriteBack: Codable, Sendable, Hashable {
    public var path: String
    public var sheet: String?
    /// Column used to match rows; nil means row order.
    public var keyColumn: String?
    /// Result fields to write, in order (missing columns are added).
    public var columns: [String]

    public init(path: String, sheet: String? = nil, keyColumn: String? = nil, columns: [String]) {
        self.path = path
        self.sheet = sheet
        self.keyColumn = keyColumn
        self.columns = columns
    }
}

public struct ForEachSpec: Codable, Sendable, Hashable {
    public var source: ItemSource
    /// Singular noun shown in progress ("company" → "37/100 companies").
    public var itemLabel: String
    /// Steps run for every item, in order, with the item as context.
    public var recipe: [RecipeStep]
    /// Items processed at once when the recipe doesn't need the screen (1 = sequential).
    public var parallelism: Int
    /// Workspace table that collects item results.
    public var outputTable: String
    public var outputColumns: [String]
    public var writeBack: WriteBack?
    /// Optional cap (process at most N items, e.g. for a trial run).
    public var limit: Int?

    public init(source: ItemSource, itemLabel: String, recipe: [RecipeStep], parallelism: Int = 1, outputTable: String,
                outputColumns: [String] = [], writeBack: WriteBack? = nil, limit: Int? = nil) {
        self.source = source
        self.itemLabel = itemLabel
        self.recipe = recipe
        self.parallelism = parallelism
        self.outputTable = outputTable
        self.outputColumns = outputColumns
        self.writeBack = writeBack
        self.limit = limit
    }
}

public enum WaitSpec: Codable, Sendable, Hashable {
    /// Sleep for a fixed time, then continue.
    case duration(seconds: Double)
    /// Sleep until a moment, then continue.
    case until(Date)
    /// Repeat the rest of the milestone every day at hour:minute, `times` times (nil = until stopped).
    case daily(hour: Int, minute: Int, times: Int?)
    /// Re-check `check` (a natural-language condition, verified by a step) every `everySeconds`
    /// until true or `maxTries` is reached.
    case condition(check: String, everySeconds: Double, maxTries: Int)
}

public enum JobStepKind: Codable, Sendable, Hashable {
    case action(RecipeStep)
    case forEach(ForEachSpec)
    case wait(WaitSpec)
}

public struct JobStep: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var kind: JobStepKind

    public init(id: Int, title: String, kind: JobStepKind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

public struct Milestone: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var title: String
    public var description: String
    /// Verified by a model against the workspace when the milestone's steps finish.
    public var doneWhen: String
    public var steps: [JobStep]
    /// Pause for the user's OK before starting this milestone.
    public var requiresApproval: Bool

    public init(id: Int, title: String, description: String = "", doneWhen: String = "", steps: [JobStep], requiresApproval: Bool = false) {
        self.id = id
        self.title = title
        self.description = description
        self.doneWhen = doneWhen
        self.steps = steps
        self.requiresApproval = requiresApproval
    }
}

public struct JobEstimate: Codable, Sendable, Hashable {
    public var items: Int
    public var modelCalls: Int
    public var minutes: Double
    /// Nil when the model's price isn't known.
    public var costUSD: Double?
    public var notes: String

    public init(items: Int = 0, modelCalls: Int = 0, minutes: Double = 0, costUSD: Double? = nil, notes: String = "") {
        self.items = items
        self.modelCalls = modelCalls
        self.minutes = minutes
        self.costUSD = costUSD
        self.notes = notes
    }
}

public struct JobPlan: Codable, Sendable, Hashable {
    public var goal: String
    public var milestones: [Milestone]
    /// What the user gets at the end (files, a table, a summary).
    public var outputs: String
    public var estimate: JobEstimate?
    /// Set when the job can't be planned without more information.
    public var clarification: String?

    public init(goal: String, milestones: [Milestone], outputs: String = "", estimate: JobEstimate? = nil, clarification: String? = nil) {
        self.goal = goal
        self.milestones = milestones
        self.outputs = outputs
        self.estimate = estimate
        self.clarification = clarification
    }

    public var stepCount: Int { milestones.reduce(0) { $0 + $1.steps.count } }
}

public struct JobBudget: Codable, Sendable, Hashable {
    public var maxCostUSD: Double?
    public var maxDurationSeconds: Double?
    public var maxModelCalls: Int?
    /// Attempts per item before it is marked failed.
    public var maxItemAttempts: Int
    /// Model turns without measurable progress before the job pauses and asks.
    public var stuckTurns: Int
    /// Fraction of failed items (after at least 5) that pauses the job to ask.
    public var maxFailureRate: Double

    public init(maxCostUSD: Double? = 5, maxDurationSeconds: Double? = 4 * 3600, maxModelCalls: Int? = 2000,
                maxItemAttempts: Int = 2, stuckTurns: Int = 12, maxFailureRate: Double = 0.3) {
        self.maxCostUSD = maxCostUSD
        self.maxDurationSeconds = maxDurationSeconds
        self.maxModelCalls = maxModelCalls
        self.maxItemAttempts = maxItemAttempts
        self.stuckTurns = stuckTurns
        self.maxFailureRate = maxFailureRate
    }
}

public struct JobUsage: Codable, Sendable, Hashable {
    public var modelCalls = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var costUSD: Double = 0
    public var costKnown = true
    public var actions = 0
    public var toolCalls = 0
    /// Seconds actually spent running (excludes waits and pauses).
    public var activeSeconds: Double = 0
    public var itemsTotal = 0
    public var itemsDone = 0
    public var itemsFailed = 0
    public var itemsSkipped = 0

    public init() {}
}

/// Where a job is in its plan. Persisted after every step and item.
public struct JobCursor: Codable, Sendable, Hashable {
    public var milestoneIndex = 0
    public var stepIndex = 0
    /// Completed iterations of a repeating wait (daily/condition).
    public var waitIteration = 0

    public init() {}
}

public struct JobRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var instruction: String
    public var status: JobStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var plan: JobPlan?
    public var cursor: JobCursor
    public var budget: JobBudget
    public var usage: JobUsage
    public var nextWakeAt: Date?
    /// Short line for the UI ("Researching 37/100 companies").
    public var statusLine: String
    public var lastError: String?
    /// Final summary written by the model.
    public var summary: String?
    /// Absolute path of the job's folder (workspace files, outputs, report.md).
    public var folder: String

    public init(id: String = UUID().uuidString, title: String, instruction: String, status: JobStatus = .planning, folder: String,
                budget: JobBudget = JobBudget()) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.status = status
        self.createdAt = Date()
        self.updatedAt = Date()
        self.plan = nil
        self.cursor = JobCursor()
        self.budget = budget
        self.usage = JobUsage()
        self.nextWakeAt = nil
        self.statusLine = ""
        self.lastError = nil
        self.summary = nil
        self.folder = folder
    }

    public var progressFraction: Double? {
        guard usage.itemsTotal > 0 else { return nil }
        return Double(usage.itemsDone + usage.itemsFailed + usage.itemsSkipped) / Double(usage.itemsTotal)
    }
}

public struct JobItem: Codable, Sendable, Hashable, Identifiable {
    /// "<jobID>/<stepID>/<index>"
    public var id: String
    public var jobID: String
    public var stepID: Int
    public var index: Int
    /// Short label (e.g. the company name).
    public var title: String
    /// The source row / value.
    public var input: JSONValue
    public var status: ItemStatus
    public var attempts: Int
    /// Fields produced by the recipe.
    public var result: JSONValue?
    public var error: String?
    public var updatedAt: Date

    public init(jobID: String, stepID: Int, index: Int, title: String, input: JSONValue) {
        self.id = "\(jobID)/\(stepID)/\(index)"
        self.jobID = jobID
        self.stepID = stepID
        self.index = index
        self.title = title
        self.input = input
        self.status = .pending
        self.attempts = 0
        self.result = nil
        self.error = nil
        self.updatedAt = Date()
    }
}

// MARK: - Workspace (job memory)

public struct WorkspaceFact: Codable, Sendable, Hashable {
    public var key: String
    public var value: String
    public var updatedAt: Date

    public init(key: String, value: String, updatedAt: Date = Date()) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}

public struct WorkspaceRow: Codable, Sendable, Hashable {
    public var key: String
    public var fields: [String: JSONValue]

    public init(key: String, fields: [String: JSONValue]) {
        self.key = key
        self.fields = fields
    }
}

/// A job's memory. Model calls get a small relevant slice instead of the whole history, so
/// hour-long jobs don't overflow the context or forget early results.
public protocol JobWorkspace: Sendable {
    var jobID: String { get }
    /// Folder for files the job reads and writes.
    var folder: URL { get }
    func setFact(_ key: String, _ value: String) async
    /// Facts relevant to `query` (keyword match), most recent first; nil query = most recent.
    func facts(matching query: String?, limit: Int) async -> [WorkspaceFact]
    func upsertRow(table: String, key: String, fields: [String: JSONValue]) async
    func rows(table: String, limit: Int?) async -> [WorkspaceRow]
    func tableNames() async -> [String]
    /// Compact overview for prompts: tables with row counts, recent facts, files.
    func summary(maxChars: Int) async -> String
}

// MARK: - Step execution contract

/// One step to execute, from either a quick task or a job. The step runners own the
/// observe → decide → act → verify loop (GUI) or the decide → call tools loop (everything else).
public struct StepRequest: Sendable {
    public var goal: String
    public var step: RecipeStep
    /// Compact context the runner adds to its prompt: milestone, current item, relevant facts,
    /// progress so far.
    public var context: String
    /// Tool families this step may use (derived from its route).
    public var allowedCategories: Set<ToolCategory>
    public var jobID: String?
    public var itemID: String?
    public var workspace: (any JobWorkspace)?
    /// Hard cap on model turns for this step.
    public var maxTurns: Int

    public init(goal: String, step: RecipeStep, context: String = "", allowedCategories: Set<ToolCategory> = Set(ToolCategory.allCases),
                jobID: String? = nil, itemID: String? = nil, workspace: (any JobWorkspace)? = nil, maxTurns: Int = 14) {
        self.goal = goal
        self.step = step
        self.context = context
        self.allowedCategories = allowedCategories
        self.jobID = jobID
        self.itemID = itemID
        self.workspace = workspace
        self.maxTurns = maxTurns
    }
}

public struct StepResult: Sendable {
    public enum Status: Sendable, Equatable {
        case done
        /// The whole task is finished (quick tasks only).
        case taskDone(String)
        case failed(String)
        /// Ended early because turns kept passing without the page changing (the tool loop's
        /// loop breaker). Handled like `failed`, except that a browser step gets one more try
        /// on the screen first.
        case stalled(String)
        /// Needs the user (approval declined, login, missing permission).
        case blocked(String)
    }
    public var status: Status
    /// What the step learned or produced, in a sentence or two (goes to memory/notes).
    public var output: String
    /// The step's `outputFields`, filled in.
    public var fields: [String: JSONValue]
    public var actions: Int
    public var modelCalls: Int
    public var usage: LLMUsage
    /// Actions that changed something outside Glide (clicked "Add to cart", typed into a form,
    /// opened a page, wrote a file), oldest first, so a retry can check them instead of
    /// doing them again.
    public var sideEffects: [String]

    public init(status: Status, output: String = "", fields: [String: JSONValue] = [:], actions: Int = 0, modelCalls: Int = 0, usage: LLMUsage = LLMUsage(),
                sideEffects: [String] = []) {
        self.status = status
        self.output = output
        self.fields = fields
        self.actions = actions
        self.modelCalls = modelCalls
        self.usage = usage
        self.sideEffects = sideEffects
    }
}

/// Implemented by the step runners; used by both the quick-task orchestrator and the job runner.
public protocol StepExecuting: Sendable {
    func execute(_ request: StepRequest, callbacks: AgentCallbacks) async throws -> StepResult
}

extension ExecutionRoute {
    /// Tool families a route may use.
    public var toolCategories: Set<ToolCategory> {
        switch self {
        case .command: return [.command, .files, .system, .workspace]
        case .browser: return [.browser, .workspace, .system]
        case .web: return [.web, .workspace]
        case .data: return [.data, .files, .workspace]
        case .composio, .mcp: return [.integration, .workspace]
        case .answer: return [.workspace]
        case .gui, .native: return [.system]
        }
    }

    /// Routes that drive the real cursor and keyboard.
    public var needsScreen: Bool { self == .gui || self == .native }
}
