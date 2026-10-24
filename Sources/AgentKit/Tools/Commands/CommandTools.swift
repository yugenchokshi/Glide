import Foundation

/// The "commands" tool family: shell, AppleScript/JXA, Shortcuts, files, and small system
/// helpers (open, notify, clipboard). These are the fastest way to get work done on the Mac
/// itself because nothing has to be clicked.
///
/// Access follows Settings › Speed & Commands (`ToolSettings`):
/// - `commandAccess == .off`: the family contributes no tools, and every call is blocked.
/// - `.readOnly`: only calls assessed `.low` run; tools that can only change things are left
///   out of the registry so the model doesn't plan around them.
/// - `.full`: calls follow their assessed risk and the user's approval level.
/// - `allowAppleScript` / `allowShortcuts` gate their tools the same way.
public enum CommandTools {
    public static let familyKey = "commands"

    /// Registers the family with `ToolRegistry`. Call once at launch (app and glidectl).
    public static func install() {
        ToolRegistry.registerFactory(familyKey) { settings in tools(for: settings) }
    }

    /// The tools this family offers under `settings`.
    public static func tools(for settings: AppSettings) -> [any AgentTool] {
        let t = settings.tools
        guard t.commandAccess != .off else { return [] }
        let readOnly = t.commandAccess == .readOnly
        var list: [any AgentTool] = [
            ShellRunTool(), FSListTool(), FSReadTool(), FSSearchTool(), ClipboardReadTool(), SystemNotifyTool(),
        ]
        if !readOnly {
            list += [FSWriteTool(), FSMoveTool(), FSCopyTool(), FSMkdirTool(), FSTrashTool(), SystemOpenTool(), ClipboardWriteTool()]
        }
        if t.allowAppleScript { list += [OSAScriptTool(language: .appleScript), OSAScriptTool(language: .javaScript)] }
        if t.allowShortcuts {
            list.append(ShortcutsListTool())
            if !readOnly { list.append(ShortcutsRunTool()) }
        }
        return list
    }

    /// Every tool in the family regardless of settings (tests, `glidectl tool list`).
    public static func allTools() -> [any AgentTool] {
        var s = AppSettings()
        s.tools.commandAccess = .full
        s.tools.allowAppleScript = true
        s.tools.allowShortcuts = true
        return tools(for: s)
    }
}

/// Which setting gates a tool, applied on top of its own risk verdict in `assess` (and again
/// in `run`, so a caller that skips `assess` still can't get around the settings).
enum CommandFamilyGate {
    case shell, appleScript, shortcuts, files, system

    func apply(_ verdict: ToolVerdict, _ settings: ToolSettings) -> ToolVerdict {
        var v = verdict
        switch self {
        case .appleScript where !settings.allowAppleScript:
            v.blocked = v.blocked ?? "AppleScript is turned off. You can allow it in Settings › Speed & Commands."
        case .shortcuts where !settings.allowShortcuts:
            v.blocked = v.blocked ?? "Shortcuts are turned off. You can allow them in Settings › Speed & Commands."
        default:
            break
        }
        return CommandSafety.applying(settings.commandAccess, to: v)
    }

    /// Throws `ToolError.blocked` when the verdict says the call must not run.
    static func enforce(_ verdict: ToolVerdict) throws {
        if let b = verdict.blocked { throw ToolError.blocked(b) }
    }
}

/// Builders for tool argument schemas. Unlike the strict planner schemas, these mark only
/// the truly required arguments as required, because the model passes arguments as a JSON
/// string and optional ones are simply left out.
enum ToolArgs {
    static func object(_ properties: [(String, JSONValue)], required: [String] = []) -> JSONValue {
        [
            "type": "object",
            "properties": .object(Dictionary(properties, uniquingKeysWith: { $1 })),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ]
    }

    /// Clamped number argument; non-finite or missing values fall back to `default`.
    static func seconds(_ args: JSONValue, _ key: String, default d: Double, max m: Double) -> Double {
        guard let v = args.optionalDouble(key), v.isFinite else { return d }
        return Swift.min(Swift.max(v, 1), m)
    }

    static func count(_ args: JSONValue, _ key: String, default d: Int, max m: Int) -> Int {
        guard let v = args.optionalDouble(key), v.isFinite else { return d }
        return Swift.min(Swift.max(Int(v), 1), m)
    }

    /// Resolves a user/model-supplied path: `~` expands, relative paths are relative to the
    /// tool context's working directory (the job folder, or home).
    static func path(_ raw: String, _ context: ToolContext) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.invalidArguments("the path is empty") }
        guard !trimmed.contains("\u{0}") else { throw ToolError.invalidArguments("the path contains invalid characters") }
        let base = context.workingDirectory.standardizedFileURL.path
        guard let expanded = PathRules.expand(trimmed, home: PathRules.home, cwd: base, literalDollar: true) else {
            throw ToolError.invalidArguments("“\(trimmed)” uses a variable; pass a plain path (~ is fine)")
        }
        return URL(fileURLWithPath: expanded)
    }

    /// Like `path`, but never throws (for `assess`, which must not fail).
    static func pathForAssessment(_ raw: String?, _ context: ToolContext) -> URL? {
        guard let raw, let url = try? path(raw, context) else { return nil }
        return url
    }
}

/// Risk of touching a file path, shared by the file tools. Symlinks are resolved first (the
/// existing part of the path), so `/tmp/link → /etc` can't launder a write outside home.
enum FileRisk {
    /// Resolves symlinks in the deepest part of the path that exists, then re-appends the
    /// rest. (`resolvingSymlinksInPath` alone leaves a path untouched when its leaf doesn't
    /// exist yet, which is exactly the case for a file about to be written.)
    static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        let fm = FileManager.default
        while !fm.itemExists(existing), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in tail { resolved.appendPathComponent(component) }
        return PathRules.normalize(resolved.path)
    }

    /// Risk for writing/creating/changing `url`.
    static func write(_ url: URL, reasons: inout [String]) -> RiskLevel {
        let p = resolved(url)
        switch PathRules.writeZone(p) {
        case .discard: return .low
        case .allowed: return .medium
        case .outside:
            reasons.append("changes \(PathRules.display(p)), outside your home folder")
            return .high
        case .sensitive:
            reasons.append("changes \(PathRules.display(p)), which affects security or startup")
            return .high
        }
    }

    /// Risk for reading `url`: low, except private keys and credentials.
    static func read(_ url: URL, reasons: inout [String]) -> RiskLevel {
        let p = resolved(url)
        if PathRules.isSecret(p) {
            reasons.append("reads private keys or credentials (\(PathRules.display(p)))")
            return .high
        }
        return .low
    }
}
