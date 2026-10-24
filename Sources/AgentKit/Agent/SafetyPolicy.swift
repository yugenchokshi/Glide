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
    /// `API-delete-a-block`, `deleteRecord`, `gmail.send`), so they're split into words first,
    /// and words that don't say what the tool does are left out (see `toolAction`).
    public func assessTool(name: String, risk modelRisk: RiskLevel) -> Verdict {
        let action = Self.toolAction(name)
        var risk = modelRisk
        var reasons: [String] = []
        if Self.matches(action.judged, Self.highRiskWords) || Self.matches(action.judged, Self.highRiskToolWords) {
            risk = .high
            reasons.append("tool \(name)")
        } else if Self.matches(action.judged, Self.mediumRiskWords) || action.httpWrite {
            risk = max(risk, .medium)
        }
        return Verdict(risk: risk, reasons: reasons, blocked: nil)
    }

    /// Integration tools (MCP servers, Composio) run code Glide knows nothing about, and their
    /// name is the only signal. One whose first verb is a read verb (`get_current_time`,
    /// `GMAIL_FETCH_EMAILS`, `notion-search`) stays low; any other rates at least medium. An
    /// HTTP DELETE passed to a generic request tool is high, and POST, PUT or PATCH medium,
    /// whatever the tool is called.
    public func assessIntegrationTool(name: String, arguments: JSONValue) -> Verdict {
        var v = assessTool(name: name, risk: Self.toolAction(name).reads ? .low : .medium)
        let method = Self.httpMethod(in: arguments)
        if v.risk < .high, method == "DELETE" {
            v.risk = .high
            v.reasons.append("HTTP DELETE")
        } else if v.risk < .medium, let method, ["POST", "PUT", "PATCH"].contains(method) {
            v.risk = .medium
        }
        return v
    }

    /// Risky verbs judged only in tool names: as button labels ("Forward", "Reply") they
    /// usually just navigate or open a draft. "Drop" counts only for data ("dropTable"), not
    /// for a browser tool's drag and drop.
    static let highRiskToolWords = ["destroy", "purge", "wipe", "terminate", "kill", "charge", "refund", "reply", "forward", "invite",
                                    "drop table", "drop database", "drop db", "drop collection", "drop schema", "drop index", "drop column"]

    /// Verbs that say a tool only reads.
    static let readVerbs: Set<String> = ["get", "list", "search", "find", "fetch", "read", "retrieve", "query", "lookup", "describe",
                                         "resolve", "count", "view", "show", "preview", "inspect"]
    /// Verbs that say a tool changes something although no risk list names them, so a read verb
    /// after them ("write_query", "run_query") doesn't make the tool a read.
    static let writeVerbs: Set<String> = ["write", "run", "execute", "exec", "eval", "add", "set", "insert", "append", "put", "patch",
                                          "modify", "change", "apply", "import", "sync", "mark", "toggle", "enable", "disable", "start",
                                          "stop", "restart", "cancel", "close", "commit", "push", "deploy", "upsert", "assign", "attach",
                                          "detach", "link", "unlink", "approve", "reject", "schedule", "book", "click", "type", "press",
                                          "fill", "select", "navigate", "drag", "call", "invoke", "trigger", "notify", "empty", "place"]
    /// Risky words that are also nouns. After a read verb they name what's read, not what's
    /// done: "getPost", "STRIPE_RETRIEVE_A_CHARGE", "get_merge_request", "get_invite".
    static let riskyNouns: Set<String> = ["post", "tweet", "share", "transfer", "purchase", "trash", "checkout", "merge", "reset", "format",
                                          "charge", "refund", "invite", "reply", "forward", "subscribe"]
    /// HTTP methods spelled into names generated from an OpenAPI spec ("API-post-search").
    static let httpVerbs: Set<String> = ["get", "post", "put", "patch", "delete", "head"]
    /// The one-word entries of the risk lists, which act as verbs when reading a tool name.
    static let singleRiskWords = Set((highRiskWords + mediumRiskWords + highRiskToolWords).filter { !$0.contains(" ") })

    /// What a tool name says about the tool, judged deterministically:
    /// - `judged`: the words to match against the risk lists. Left out are an HTTP method that
    ///   doesn't say what the call does (`API-post-search`: Notion searches with POST), and,
    ///   after a read verb, risky nouns and medium-risk words (`getPost`, `GMAIL_LIST_DRAFTS`).
    ///   Strong verbs always count, wherever they are (`get_and_delete`, `search_and_replace`).
    /// - `reads`: the name has a verb, and the first verb of each part ("and", "or" and "then"
    ///   split parts) is a read verb.
    /// - `httpWrite`: the name spells POST, PUT or PATCH and doesn't read (`API-patch-page`).
    static func toolAction(_ name: String) -> (judged: String, reads: Bool, httpWrite: Bool) {
        var words = toolNameWords(name).split(separator: " ").map(String.init)
        var httpWrite = false
        // "API-post-search", "API-patch-page": the word after "api" is an HTTP method. "post_search",
        // "postSearch": a write method followed by a read verb is a request that reads.
        if let i = words.indices.first(where: { words[$0] == "api" }), i + 1 < words.count, httpVerbs.contains(words[i + 1]) {
            if ["post", "put", "patch"].contains(words[i + 1]) {
                httpWrite = true
                words.remove(at: i + 1)
            }
        } else if let first = words.first, ["post", "put", "patch"].contains(first), words.count > 1, readVerbs.contains(words[1]) {
            words.removeFirst()
        }
        let conjunctions: Set<String> = ["and", "or", "then"]
        var judged: [String] = []
        var partReads: Bool?
        var reads = true
        var sawVerb = false
        for word in words {
            if conjunctions.contains(word) {
                partReads = nil
                judged.append(word)
                continue
            }
            if partReads == nil {
                if readVerbs.contains(word) {
                    partReads = true
                    sawVerb = true
                } else if writeVerbs.contains(word) || singleRiskWords.contains(word) {
                    partReads = false
                    sawVerb = true
                    reads = false
                }
            } else if partReads == true, riskyNouns.contains(word) || mediumRiskWords.contains(word) {
                continue
            }
            judged.append(word)
        }
        let readsOnly = reads && sawVerb
        return (judged.joined(separator: " "), readsOnly, httpWrite && !readsOnly)
    }

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
