import Foundation

// Tools are the fast path. Instead of driving an app's UI click by click, a step can call a
// tool that does the whole thing directly: a shell command, an AppleScript, a file operation,
// a DOM-level browser action, a web fetch, a spreadsheet read. Every tool:
//   • declares a JSON schema the action model fills in,
//   • assesses each concrete call deterministically (no model) for risk before it runs,
//   • returns a short model-visible text plus optional structured data.
// The step runners (ToolStepRunner) put tool calls through the same safety + approval path
// as UI actions.

public enum ToolCategory: String, Codable, Sendable, CaseIterable {
    /// Shell, AppleScript/JXA, Shortcuts.
    case command
    /// Reading, writing, moving files and folders.
    case files
    /// DOM-level control of Chrome (via the Glide extension or Glide's own Chrome).
    case browser
    /// Search and fetch over HTTP, no browser.
    case web
    /// Spreadsheets and tables (CSV, XLSX).
    case data
    /// The current job's memory: facts, result tables, files.
    case workspace
    /// Composio and MCP tools.
    case integration
    /// Notifications, clipboard, opening things.
    case system
}

public struct ToolSpec: Sendable, Hashable {
    /// Dotted name the model uses, e.g. "shell.run", "browser.click".
    public var name: String
    /// One line for prompts: what it does and when to prefer it.
    public var summary: String
    /// JSON schema (type object) for the arguments.
    public var inputSchema: JSONValue
    public var category: ToolCategory
    /// True when the tool moves the cursor or needs the foreground (must hold the screen lease).
    public var needsScreen: Bool
    /// True when the tool never changes anything (lets planners and safety relax).
    public var readOnly: Bool

    public init(name: String, summary: String, inputSchema: JSONValue, category: ToolCategory, needsScreen: Bool = false, readOnly: Bool = false) {
        self.name = name
        self.summary = summary
        self.inputSchema = inputSchema
        self.category = category
        self.needsScreen = needsScreen
        self.readOnly = readOnly
    }
}

public struct ToolCall: Codable, Sendable, Hashable {
    public var name: String
    public var arguments: JSONValue

    public init(name: String, arguments: JSONValue) {
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolOutput: Sendable {
    public var ok: Bool
    /// Concise, model-visible result. Tools truncate to roughly 8,000 characters.
    public var text: String
    /// Optional structured result (rows, fields) for the workspace or item results.
    public var data: JSONValue?
    /// Files the tool produced.
    public var artifacts: [URL]
    public var durationMs: Double

    public init(ok: Bool, text: String, data: JSONValue? = nil, artifacts: [URL] = [], durationMs: Double = 0) {
        self.ok = ok
        self.text = text
        self.data = data
        self.artifacts = artifacts
        self.durationMs = durationMs
    }

    public static func failure(_ message: String) -> ToolOutput { ToolOutput(ok: false, text: message) }
}

/// Deterministic safety verdict for one concrete call.
public struct ToolVerdict: Sendable, Hashable {
    public var risk: RiskLevel
    public var reasons: [String]
    /// Non-nil means the call must not run at all; the text is shown to the user.
    public var blocked: String?
    /// Human description for logs and approval cards, e.g. "Run `ls -la ~/Desktop`".
    public var summary: String

    public init(risk: RiskLevel, reasons: [String] = [], blocked: String? = nil, summary: String) {
        self.risk = risk
        self.reasons = reasons
        self.blocked = blocked
        self.summary = summary
    }

    /// Bridges to the existing approval policy.
    public var safetyVerdict: SafetyPolicy.Verdict { SafetyPolicy.Verdict(risk: risk, reasons: reasons, blocked: blocked) }
}

/// Everything a tool may need while running. Tools must check `gate` in long loops so the
/// emergency stop takes effect immediately.
public struct ToolContext: Sendable {
    public var settings: AppSettings
    public var gate: ExecutionGate
    public var workspace: (any JobWorkspace)?
    public var jobID: String?
    public var itemID: String?
    /// Job folder when running inside a job, otherwise the user's home folder.
    public var workingDirectory: URL
    public var log: @Sendable (ActivityEntry) -> Void

    public init(settings: AppSettings, gate: ExecutionGate, workspace: (any JobWorkspace)? = nil, jobID: String? = nil, itemID: String? = nil,
                workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, log: @escaping @Sendable (ActivityEntry) -> Void = { _ in }) {
        self.settings = settings
        self.gate = gate
        self.workspace = workspace
        self.jobID = jobID
        self.itemID = itemID
        self.workingDirectory = workingDirectory
        self.log = log
    }
}

public protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// Risk of this concrete call. Must be deterministic and fast; never calls a model.
    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict
    /// Runs the call. Throws `ToolError` for bad arguments; returns `ok: false` for ordinary failures
    /// the model should see and react to (non-zero exit, 404, element not found).
    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput
}

public enum ToolError: Error, LocalizedError, Sendable {
    case unknownTool(String)
    case invalidArguments(String)
    case unavailable(String)
    case blocked(String)
    case timeout(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let n): return "There's no tool named “\(n)”."
        case .invalidArguments(let m): return "Invalid arguments: \(m)"
        case .unavailable(let m): return m
        case .blocked(let m): return m
        case .timeout(let m): return "Timed out: \(m)"
        case .failed(let m): return m
        }
    }
}

/// The set of tools available to the agent. Thread-safe; the app assembles a standard
/// registry at launch (see `ToolRegistry.standard`), tests build their own.
public final class ToolRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tools: [String: any AgentTool] = [:]

    public init(_ tools: [any AgentTool] = []) {
        for t in tools { self.tools[t.spec.name] = t }
    }

    public func register(_ tool: any AgentTool) { lock.withLock { tools[tool.spec.name] = tool } }
    public func register(_ list: [any AgentTool]) { lock.withLock { for t in list { tools[t.spec.name] = t } } }
    public func unregister(_ name: String) { lock.withLock { _ = tools.removeValue(forKey: name) } }
    public func tool(named name: String) -> (any AgentTool)? { lock.withLock { tools[name] } }

    public var all: [any AgentTool] { lock.withLock { tools.values.sorted { $0.spec.name < $1.spec.name } } }

    public func specs(in categories: Set<ToolCategory>? = nil) -> [ToolSpec] {
        all.map(\.spec).filter { categories?.contains($0.category) ?? true }
    }

    /// Compact listing for prompts: name, summary and argument schema per tool.
    public func promptListing(categories: Set<ToolCategory>? = nil, maxChars: Int = 12_000) -> String {
        var out = ""
        for s in specs(in: categories) {
            let line = "- \(s.name)\(s.readOnly ? " (read-only)" : ""): \(s.summary)\n  args: \(s.inputSchema.jsonString())\n"
            if out.count + line.count > maxChars { out += "- …(more tools omitted)\n"; break }
            out += line
        }
        return out
    }

    /// Factories contributed by each tool family at launch. Keyed so re-registration replaces.
    nonisolated(unsafe) private static var factories: [String: @Sendable (AppSettings) -> [any AgentTool]] = [:]
    private static let factoryLock = NSLock()

    /// Tool families register a factory once (e.g. in an `install()` function called at launch).
    public static func registerFactory(_ key: String, _ make: @escaping @Sendable (AppSettings) -> [any AgentTool]) {
        factoryLock.withLock { factories[key] = make }
    }

    /// All tools from every registered family, configured for `settings`.
    public static func standard(settings: AppSettings) -> ToolRegistry {
        let makers = factoryLock.withLock { Array(factories.values) }
        let registry = ToolRegistry()
        for make in makers { registry.register(make(settings)) }
        return registry
    }
}

/// Argument helpers shared by tools.
public extension JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let s = self[key]?.stringValue, !s.isEmpty else { throw ToolError.invalidArguments("missing “\(key)”") }
        return s
    }
    func optionalString(_ key: String) -> String? {
        guard let v = self[key], !v.isNull, let s = v.stringValue, !s.isEmpty else { return nil }
        return s
    }
    func optionalInt(_ key: String) -> Int? { self[key]?.intValue }
    func optionalDouble(_ key: String) -> Double? { self[key]?.doubleValue }
    func optionalBool(_ key: String) -> Bool? { self[key]?.boolValue }
}

/// Truncates model-visible tool text, keeping the head and tail.
public func toolTruncate(_ s: String, max: Int = 8000) -> String {
    guard s.count > max else { return s }
    let head = s.prefix(max * 3 / 4), tail = s.suffix(max / 4)
    return "\(head)\n…[\(s.count - max) characters omitted]…\n\(tail)"
}
