import Foundation
import AppKit

// Small system helpers: opening things, notifications and the clipboard.

// MARK: system.open

struct SystemOpenTool: AgentTool {
    enum Target: Equatable {
        case url(String)
        case path(URL)
        case app(String)
    }

    let spec = ToolSpec(
        name: "system.open",
        summary: "Open a URL (in the default browser or app), a file or folder (in its default app / Finder), or an app by name.",
        inputSchema: ToolArgs.object([
            ("target", Schema.string("A URL (https://…, mailto:…), a file or folder path, or an app name like “Calendar”.")),
        ], required: ["target"]),
        category: .system)

    /// URL when it has a scheme; a path when it looks like one or exists; otherwise an app name.
    static func classify(_ raw: String, _ context: ToolContext) -> Target? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\u{0}") else { return nil }
        if t.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil, !t.hasPrefix("/") { return .url(t) }
        if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix(".") || t.contains("/") {
            return (try? ToolArgs.path(t, context)).map { .path($0) }
        }
        if let url = try? ToolArgs.path(t, context), FileManager.default.itemExists(url) { return .path(url) }
        return .app(t)
    }

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let raw = arguments.optionalString("target") ?? ""
        var risk = RiskLevel.medium
        var reasons: [String] = []
        let summary: String
        switch Self.classify(raw, context) {
        case .url(let u):
            let lower = u.lowercased()
            if lower.hasPrefix("file:") || lower.hasPrefix("javascript:") || lower.hasPrefix("data:") {
                risk = .high; reasons.append("unusual URL scheme")
            }
            summary = "Open \(u.prefix(120))"
        case .path(let url):
            if ShellRiskChecker.runsCode(path: url.path) { risk = .high; reasons.append("opens a file that runs code (\(url.lastPathComponent))") }
            summary = "Open \(FileFormat.display(url))"
        case .app(let name):
            summary = "Open the app \(name)"
        case nil:
            summary = "Open something"
        }
        return CommandFamilyGate.system.apply(ToolVerdict(risk: risk, reasons: reasons, summary: summary), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try arguments.requiredString("target")
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        try context.gate.checkStopped()
        guard let target = Self.classify(raw, context) else { throw ToolError.invalidArguments("“target” is empty") }
        let args: [String]
        let label: String
        switch target {
        case .url(let u):
            args = [u]; label = u
        case .path(let url):
            guard FileManager.default.itemExists(url) else { return .failure("There's nothing at \(FileFormat.display(url)) to open.") }
            args = [url.path]; label = FileFormat.display(url)
        case .app(let name):
            guard !name.hasPrefix("-") else { throw ToolError.invalidArguments("an app name can't start with “-”") }
            args = ["-a", name]; label = name
        }
        let r = try await ProcessRunner.run(executable: "/usr/bin/open", arguments: args, timeout: 20, gate: context.gate)
        if r.stopped { throw AutomationError.stopped }
        guard r.exitCode == 0, !r.timedOut else {
            let err = r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .app = target, err.lowercased().contains("unable to find application") {
                return .failure("There's no app named “\(label)”.")
            }
            return .failure("Couldn't open \(label)\(err.isEmpty ? "" : ": \(err)")")
        }
        return ToolOutput(ok: true, text: "Opened \(label).", durationMs: r.durationMs)
    }
}

// MARK: system.notify

struct SystemNotifyTool: AgentTool {
    let spec = ToolSpec(
        name: "system.notify",
        summary: "Show a macOS notification with a title and body (e.g. when a long step finishes).",
        inputSchema: ToolArgs.object([
            ("title", Schema.string("Short title.")),
            ("body", Schema.string("The message.")),
        ], required: ["title", "body"]),
        category: .system)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let title = arguments.optionalString("title") ?? ""
        return CommandFamilyGate.system.apply(ToolVerdict(risk: .low, summary: "Show a notification: \(title.prefix(80))"), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let title = String(try arguments.requiredString("title").prefix(200))
        let body = String((arguments.optionalString("body") ?? "").prefix(1000))
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        // Text goes in as run-handler arguments, never spliced into the script, so quotes
        // or backslashes in it can't change what the script does. The leading "glide"
        // argument ends osascript's option parsing even if the title starts with "-".
        let script = ["on run argv", "display notification (item 3 of argv) with title (item 2 of argv)", "end run"]
        let args = script.flatMap { ["-e", $0] } + ["glide", title, body]
        let r = try await ProcessRunner.run(executable: "/usr/bin/osascript", arguments: args, timeout: 10, gate: context.gate)
        if r.stopped { throw AutomationError.stopped }
        guard r.exitCode == 0, !r.timedOut else {
            return .failure("Couldn't show the notification: \(r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return ToolOutput(ok: true, text: "Showed the notification “\(title)”.", durationMs: r.durationMs)
    }
}

// MARK: clipboard.read / clipboard.write

/// Pasteboard access on the main actor (AppKit's pasteboard isn't documented as thread-safe).
/// `name` nil means the general (system) clipboard; tests pass a private pasteboard name so
/// they never touch the user's clipboard.
enum Clipboard {
    /// Password managers mark copied secrets with this type (nspasteboard.org convention).
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    enum ReadResult: Sendable {
        case text(String)
        case concealed
        case noText(types: [String])
    }

    @MainActor static func pasteboard(_ name: NSPasteboard.Name?) -> NSPasteboard {
        name.map { NSPasteboard(name: $0) } ?? .general
    }

    static func read(_ name: NSPasteboard.Name?) async -> ReadResult {
        await MainActor.run {
            let pb = pasteboard(name)
            let types = pb.types ?? []
            if types.contains(concealedType) { return .concealed }
            if let s = pb.string(forType: .string) { return .text(s) }
            return .noText(types: types.map(\.rawValue))
        }
    }

    /// Whether the clipboard holds a concealed item. Looks only at the item's types, never its
    /// contents, so checking doesn't read the user's clipboard (or trigger macOS's paste prompt).
    static func holdsConcealedItem(_ name: NSPasteboard.Name?) async -> Bool {
        await MainActor.run { pasteboard(name).types?.contains(concealedType) ?? false }
    }

    static func write(_ text: String, _ name: NSPasteboard.Name?) async -> Bool {
        await MainActor.run {
            let pb = pasteboard(name)
            pb.clearContents()
            return pb.setString(text, forType: .string)
        }
    }
}

struct ClipboardReadTool: AgentTool {
    let pasteboardName: NSPasteboard.Name?

    init(pasteboardName: NSPasteboard.Name? = nil) { self.pasteboardName = pasteboardName }

    let spec = ToolSpec(
        name: "clipboard.read",
        summary: "Read the text currently on the clipboard. Items a password manager marked as concealed are never read.",
        inputSchema: ToolArgs.object([]),
        category: .system, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        CommandFamilyGate.system.apply(ToolVerdict(risk: .low, summary: "Read the clipboard"), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        switch await Clipboard.read(pasteboardName) {
        case .concealed:
            return .failure("The clipboard holds a concealed item (likely a password from a password manager), so Glide won't read it.")
        case .noText(let types):
            return .failure(types.isEmpty ? "The clipboard is empty." : "The clipboard holds no text (it has: \(types.prefix(5).joined(separator: ", "))).")
        case .text(let s):
            return ToolOutput(ok: true, text: s.isEmpty ? "(the clipboard text is empty)" : toolTruncate(s), data: ["text": .string(s)])
        }
    }
}

struct ClipboardWriteTool: AgentTool {
    let pasteboardName: NSPasteboard.Name?

    init(pasteboardName: NSPasteboard.Name? = nil) { self.pasteboardName = pasteboardName }

    let spec = ToolSpec(
        name: "clipboard.write",
        summary: "Put text on the clipboard (replacing what's there).",
        inputSchema: ToolArgs.object([("text", Schema.string("Text to copy."))], required: ["text"]),
        category: .system)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let n = arguments["text"]?.stringValue?.count ?? 0
        return CommandFamilyGate.system.apply(ToolVerdict(risk: .medium, reasons: ["replaces the clipboard"], summary: "Copy \(n) characters to the clipboard"), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let text = arguments["text"]?.stringValue else { throw ToolError.invalidArguments("missing “text”") }
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        guard await Clipboard.write(text, pasteboardName) else { return .failure("Couldn't write to the clipboard.") }
        return ToolOutput(ok: true, text: "Copied \(text.count) characters to the clipboard.")
    }
}
