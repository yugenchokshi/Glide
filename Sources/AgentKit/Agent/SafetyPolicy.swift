import Foundation
import AutomationKit

/// Deterministic risk rules layered over the model's own risk labels. The highest risk wins.
public struct SafetyPolicy: Sendable {
    public struct Verdict: Sendable, Hashable {
        public var risk: RiskLevel
        public var reasons: [String]
        public var blocked: String?
    }

    public let settings: SafetySettings

    public init(settings: SafetySettings) {
        self.settings = settings
    }

    static let highRiskWords = [
        "send", "delete", "remove", "trash", "erase", "empty trash", "publish", "post", "tweet", "buy", "purchase",
        "pay", "place order", "checkout", "check out", "confirm order", "transfer", "submit payment", "subscribe",
        "uninstall", "format", "reset", "sign out", "log out", "revoke", "deactivate", "unsubscribe", "share",
        "move to bin", "permanently", "discard", "overwrite", "replace", "don't save", "do not save", "merge",
    ]
    static let mediumRiskWords = ["save", "rename", "move", "edit", "update", "create", "archive", "draft", "upload", "install", "duplicate"]
    static let messagingApps = ["Messages", "Mail", "Slack", "WhatsApp", "Telegram", "Discord", "Microsoft Teams", "Signal", "Outlook", "Microsoft Outlook"]
    static let destructiveShell = [#"rm\s+-[a-z]*r"#, #"\bsudo\b"#, #"\bmkfs\b"#, #"\bdd\s+if="#, #"\bshutdown\b"#, #"\breboot\b"#, #"chmod\s+-R"#, #"\bkillall\b"#, #"git\s+push\s+.*--force"#, #"diskutil\s+erase"#]

    public func isExcluded(app: AppInfo?) -> Bool {
        guard let app else { return false }
        return settings.excludedApps.contains { ex in
            ex.caseInsensitiveCompare(app.name) == .orderedSame || ex == app.bundleID
        }
    }

    /// Assesses one concrete action about to run in `app`, against the element it targets.
    public func assess(_ action: ComputerAction, target: UIElementNode?, app: AppInfo?, modelRisk: RiskLevel, stepRisk: RiskLevel) -> Verdict {
        var risk = max(modelRisk, .low)
        var reasons: [String] = []
        if isExcluded(app: app) {
            return Verdict(risk: .high, reasons: ["\(app?.name ?? "This app") is on your excluded list"], blocked: "Glide is set not to operate \(app?.name ?? "this app").")
        }
        if let target, target.isSecure {
            return Verdict(risk: .high, reasons: ["password field"], blocked: "Glide never types into password fields. Please enter it yourself.")
        }
        let label = ElementMatcher.normalize(target?.label ?? "")
        switch action {
        case .click, .doubleClick:
            if Self.matches(label, Self.highRiskWords) { risk = max(risk, .high); reasons.append("clicking “\(target?.label ?? "")”") }
            else if Self.matches(label, Self.mediumRiskWords) { risk = max(risk, .medium) }
        case .keyPress(let combo):
            let mods = combo.modifiers
            if mods.contains(.command) && (combo.key == "delete" || combo.key == "backspace") { risk = .high; reasons.append("⌘⌫ deletes") }
            if (combo.key == "return" || combo.key == "enter") && mods.isEmpty, let app, Self.messagingApps.contains(app.name) {
                risk = .high; reasons.append("Return sends in \(app.name)")
            }
            if mods.contains(.command) && mods.contains(.shift) && combo.key == "d", app?.name == "Mail" { risk = .high; reasons.append("⌘⇧D sends mail") }
            if mods.contains(.command) && combo.key == "s" { risk = max(risk, .medium) }
        case .typeText(let text, _, _, let submit):
            if submit, let app, Self.messagingApps.contains(app.name) { risk = .high; reasons.append("typing then Return sends in \(app.name)") }
            if let app, ["Terminal", "iTerm2", "iTerm", "Warp", "Ghostty"].contains(app.name) {
                if Self.destructiveShell.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
                    risk = .high; reasons.append("destructive shell command")
                } else if submit || text.contains("\n") {
                    risk = max(risk, .medium); reasons.append("runs a shell command")
                }
            }
            if Self.looksLikePaymentCard(text) {
                return Verdict(risk: .high, reasons: ["payment card number"], blocked: "Glide won't enter payment card numbers. Please enter it yourself.")
            }
        case .menu(let path):
            let joined = ElementMatcher.normalize(path.joined(separator: " "))
            if Self.matches(joined, Self.highRiskWords) { risk = max(risk, .high); reasons.append("menu “\(path.joined(separator: " › "))”") }
            else if Self.matches(joined, Self.mediumRiskWords) { risk = max(risk, .medium) }
        case .openURL(let url, _):
            if url.lowercased().hasPrefix("file:") || url.lowercased().hasPrefix("javascript:") { risk = .high; reasons.append("unusual URL scheme") }
        default:
            break
        }
        if stepRisk == .high, risk == .medium { reasons.append("part of a high-risk step") }
        return Verdict(risk: risk, reasons: reasons, blocked: nil)
    }

    /// Judges a tool by the words in its name. Names come in every style (`delete_file`,
    /// `API-delete-a-block`, `deleteRecord`, `gmail.send`), so they're split into words first.
    public func assessTool(name: String, risk modelRisk: RiskLevel) -> Verdict {
        let n = Self.toolNameWords(name)
        var risk = modelRisk
        var reasons: [String] = []
        if Self.matches(n, Self.highRiskWords) || Self.matches(n, Self.highRiskToolWords) { risk = .high; reasons.append("tool \(name)") }
        else if Self.matches(n, Self.mediumRiskWords) { risk = max(risk, .medium) }
        return Verdict(risk: risk, reasons: reasons, blocked: nil)
    }

    /// Integration tools (MCP servers, Composio) run code Glide knows nothing about, and their
    /// name is the only signal, so they never rate below medium. An HTTP DELETE passed to a
    /// generic request tool is high, whatever the tool is called.
    public func assessIntegrationTool(name: String, arguments: JSONValue) -> Verdict {
        var v = assessTool(name: name, risk: .medium)
        if v.risk < .high, Self.httpMethod(in: arguments) == "DELETE" {
            v.risk = .high
            v.reasons.append("HTTP DELETE")
        }
        return v
    }

    /// Risky verbs judged only in tool names: as button labels ("Forward", "Reply", "Drop")
    /// they usually just navigate or open a draft.
    static let highRiskToolWords = ["destroy", "drop", "purge", "wipe", "terminate", "kill", "charge", "refund", "reply", "forward", "invite"]

    /// A tool name as lowercase words: camelCase is split, and `_ - . / :` are separators.
    /// "API-delete-a-block" → "api delete a block", "sendHTTPRequest" → "send http request".
    static func toolNameWords(_ name: String) -> String {
        let chars = Array(name)
        var out = ""
        for (i, c) in chars.enumerated() {
            if c == "_" || c == "-" || c == "." || c == "/" || c == ":" || c.isWhitespace {
                out.append(" ")
                continue
            }
            if c.isUppercase, i > 0 {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                // deleteRecord → delete Record; HTTPRequest → HTTP Request.
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) { out.append(" ") }
            }
            out.append(c)
        }
        return out.lowercased().split(separator: " ").joined(separator: " ")
    }

    /// The HTTP method an integration call asks for, upper-cased, when its arguments name one.
    static func httpMethod(in arguments: JSONValue) -> String? {
        guard let object = arguments.objectValue else { return nil }
        for (key, value) in object where ["method", "httpmethod", "http_method"].contains(key.lowercased()) {
            if let method = value.stringValue?.trimmingCharacters(in: .whitespaces).uppercased(), !method.isEmpty { return method }
        }
        return nil
    }

    public func needsApproval(_ verdict: Verdict) -> Bool {
        switch settings.approvalLevel {
        case .highRiskOnly: return verdict.risk == .high
        case .mediumAndHigh: return verdict.risk >= .medium
        case .everyAction: return true
        }
    }

    static func matches(_ text: String, _ words: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        let padded = " \(text) "
        return words.contains { padded.contains(" \($0) ") }
    }

    /// Luhn-valid 13–19 digit sequences.
    static func looksLikePaymentCard(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        let compact = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        guard (13...19).contains(digits.count), compact.count == digits.count else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue ?? 0
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}
