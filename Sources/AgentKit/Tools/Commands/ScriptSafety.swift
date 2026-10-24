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
