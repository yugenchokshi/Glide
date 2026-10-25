import Foundation

/// Deterministic risk for AppleScript and JavaScript for Automation (JXA) source.
///
/// A keyword scan, not a parser: scripts are normalized into lowercase words (camelCase JXA
/// identifiers are split, so `doShellScript` reads as "do shell script" and `emptyTrash` as
/// "empty trash") and matched against phrase lists. Words inside string literals count too,
/// which can only over-estimate risk, never hide it.
public enum ScriptSafety {
    public enum Language: String, Sendable {
        case appleScript
        case javaScript
    }

    public struct Assessment: Sendable, Hashable {
        public var risk: RiskLevel
        public var reasons: [String]
    }

    /// Phrases that send, delete, run shell commands, power off, pay, or type keystrokes.
    static let highPhrases: [(phrase: String, reason: String)] = [
        ("send", "sends something"),
        ("delete", "deletes something"),
        ("remove", "removes something"),
        ("empty trash", "empties the Trash"),
        ("empty the trash", "empties the Trash"),
        ("do shell script", "runs a shell command"),
        ("run script", "runs script text built at run time"),
        ("restart", "restarts the Mac or an app"),
        ("shut down", "shuts down the Mac"),
        ("shutdown", "shuts down the Mac"),
        ("log out", "logs out"),
        ("logout", "logs out"),
        ("erase", "erases something"),
        ("purchase", "makes a purchase"),
        ("buy", "makes a purchase"),
        ("keystroke", "types keystrokes into apps"),
        ("key code", "presses keys in apps"),
    ]

    /// Verbs that change something (documents, windows, apps, files, the clipboard).
    static let mutatingPhrases = [
        "make", "set", "save", "move", "duplicate", "close", "open", "activate", "quit", "launch", "run", "write", "display", "say",
        "print", "reveal", "select", "click", "copy", "paste", "create", "import", "export", "mount", "eject", "sleep", "reopen",
        "open location", "do javascript", "execute", "add", "store script", "load script", "perform", "push", "reply", "forward",
        "mark", "flag", "archive", "rename", "convert", "play", "pause", "next track", "previous track",
    ]

    public static func assess(_ source: String, language: Language) -> Assessment {
        let words = normalize(source)
        var reasons: [String] = []
        for (phrase, reason) in highPhrases where contains(words, phrase) {
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        if language == .javaScript {
            // The Objective-C bridge can call any Cocoa API, including file deletion and process launch.
            if source.contains("ObjC.") || source.range(of: #"\$\.[A-Za-z]"#, options: .regularExpression) != nil || source.contains("$(") {
                reasons.append("uses the Objective-C bridge")
            }
        }
        if !reasons.isEmpty { return Assessment(risk: .high, reasons: reasons) }

        if mutatingPhrases.contains(where: { contains(words, $0) }) { return Assessment(risk: .medium, reasons: []) }
        if language == .javaScript {
            // JXA changes properties by assignment: app.windows[0].name = "x".
            let stripped = source.replacingOccurrences(of: #"\.includeStandardAdditions\s*=\s*true"#, with: "", options: .regularExpression)
            if stripped.range(of: #"(\]|\)|\.[A-Za-z_$][A-Za-z0-9_$]*)\s*=(?!=)"#, options: .regularExpression) != nil {
                return Assessment(risk: .medium, reasons: [])
            }
        }
        return Assessment(risk: .low, reasons: [])
    }

    /// Whether a script could read the clipboard, so the concealed-item guard must run first.
    ///
    /// It can when it names it (`the clipboard`, `clipboard info`, `theClipboard()`,
    /// `NSPasteboard`, `pbpaste`), pastes it somewhere it can be read back (keystrokes, a
    /// Paste menu item), or reaches a name built at run time: a shell command, `run script`,
    /// another app's `do script`/`do JavaScript`, raw event codes (`«event JonsgClp»`), the
    /// Objective-C bridge, or (JXA) computed member access, `eval` and `Function`. A script
    /// with none of these (`return 1 + 1`, reading Finder windows) can't, so it runs even while
    /// a password manager's item is on the clipboard.
    public static func mayReadClipboard(_ source: String, language: Language) -> Bool {
        let lower = source.lowercased()
        let names = ["clipboard", "pasteboard", "pbpaste", "paste", "«", "<<event", "<<class", "nsclassfromstring"]
        if names.contains(where: { lower.contains($0) }) { return true }
        let words = normalize(source)
        let phrases = ["keystroke", "key code", "do shell script", "do script", "do javascript", "run script", "load script",
                       "use framework", "current application", "call method", "perform selector"]
        if phrases.contains(where: { contains(words, $0) }) { return true }
        guard language == .javaScript else { return false }
        if source.contains("ObjC") || source.contains("$.") || source.contains("$(") || source.contains("Library(") { return true }
        if source.range(of: #"\b(eval|Function|Reflect|globalThis|require|import)\b"#, options: .regularExpression) != nil { return true }
        return hasComputedMemberAccess(source)
    }

    /// JXA `obj[expr]` where `expr` isn't a number or a single quoted string: a property name
    /// that could be built at run time (`app['the' + 'Clipboard']()`). Array literals
    /// (`[1, 2]`) and plain indexes (`windows[0]`) don't count.
    static func hasComputedMemberAccess(_ source: String) -> Bool {
        let c = Array(source)
        var i = 0
        while i < c.count {
            guard c[i] == "[", i > 0 else { i += 1; continue }
            // Member access follows a name, `)` or `]`; otherwise it's an array literal.
            var p = i - 1
            while p >= 0, c[p] == " " || c[p] == "\t" { p -= 1 }
            guard p >= 0, c[p].isLetter || c[p].isNumber || c[p] == "_" || c[p] == "$" || c[p] == ")" || c[p] == "]" else { i += 1; continue }
            var j = i + 1
            var depth = 1
            while j < c.count, depth > 0 {
                if c[j] == "[" { depth += 1 } else if c[j] == "]" { depth -= 1 }
                if depth > 0 { j += 1 }
            }
            let inner = String(c[(i + 1)..<min(j, c.count)]).trimmingCharacters(in: .whitespaces)
            let literalIndex = inner.allSatisfy(\.isNumber) && !inner.isEmpty
            let quoted = inner.count >= 2 && (inner.first == "'" || inner.first == "\"") && inner.last == inner.first
                && !inner.dropFirst().dropLast().contains(inner.first ?? "'")
            if !literalIndex && !quoted { return true }
            i = j + 1
        }
        return false
    }

    /// Literal shell commands passed to `do shell script "…"` (AppleScript) or
    /// `doShellScript('…')` (JXA), so they can be checked with `CommandSafety` like any other
    /// command line. Commands built at run time aren't visible here; the keyword scan already
    /// rates any `do shell script` as high.
    public static func embeddedShellCommands(_ source: String) -> [String] {
        let patterns = [
            #"do\s+shell\s+script\s+"((?:[^"\\]|\\.)*)""#,
            #"doShellScript\(\s*"((?:[^"\\]|\\.)*)""#,
            #"doShellScript\(\s*'((?:[^'\\]|\\.)*)'"#,
            #"doShellScript\(\s*`((?:[^`\\]|\\.)*)`"#,
        ]
        var out: [String] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let ns = source as NSString
            for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let raw = ns.substring(with: m.range(at: 1))
                out.append(raw.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression))
            }
        }
        return out
    }

    /// " word word … " in lowercase with camelCase split and punctuation removed.
    static func normalize(_ source: String) -> String {
        var out = " "
        var prev: Character = " "
        for ch in source {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase, prev.isLowercase { out.append(" ") }
                out.append(Character(ch.lowercased()))
            } else if out.last != " " {
                out.append(" ")
            }
            prev = ch
        }
        if out.last != " " { out.append(" ") }
        return out
    }

    static func contains(_ normalized: String, _ phrase: String) -> Bool {
        normalized.contains(" \(phrase) ")
    }
}
