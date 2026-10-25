import Foundation

/// How Glide sounds: quiet, brief, casual and confident, like a sharp friend. Everything Glide
/// says goes through here before it leaves `TaskController.onSpeech`, so no URL, element ref,
/// markdown or long list ever reaches the speaker, whatever a model wrote. The notch can show
/// the details; the spoken line stays short.
public enum SpokenLine {
    /// Hard cap on any spoken line (questions excepted: cutting one loses its point).
    public static let maxWords = 14
    /// Cap on a result line made from a summary when no spoken line was given.
    public static let resultWords = 10
    /// Cap on an ack ("On it.").
    public static let ackWords = 4
    /// Said once when a task is still running after this long.
    public static let progressAfter: TimeInterval = 45
    public static let progressLine = "Still on it."
    /// Said when nothing better is left after cleaning a line up.
    public static let fallbackResult = "Done."
    /// A result that is really a list (search results, options): it's on screen.
    public static let listResult = "Here's what I found."

    // MARK: Cleaning

    /// Strips what never sounds right out loud — URLs, email addresses, element refs (e3045,
    /// b31), bracketed asides, markdown, "Done." boilerplate — and collapses the line to at most
    /// `maxWords` words, cut at a clause boundary.
    public static func tidy(_ text: String, maxWords: Int = SpokenLine.maxWords) -> String {
        var s = clean(text)
        s = stripBoilerplate(s)
        s = cap(s, words: maxWords)
        return s
    }

    /// The same cleanup for every cue on its way out. Questions are cleaned but never cut short.
    public static func tidy(_ cue: SpeechCue) -> SpeechCue {
        switch cue {
        case .ack(let s): return .ack(tidyOr(s, fallback: "On it."))
        case .progress(let s): return .progress(tidyOr(s, fallback: progressLine))
        case .result(let s): return .result(tidyOr(s, fallback: fallbackResult))
        case .needsYou(let s): return .needsYou(tidyOr(s, fallback: "I need you for a sec."))
        case .error(let s): return .error(tidyOr(s, fallback: "That didn't work."))
        case .question(var q):
            let spoken = finish(clean(q.spokenText))
            if !spoken.isEmpty, spoken != q.spokenText { q.spoken = spoken }
            return .question(q)
        }
    }

    private static func tidyOr(_ s: String, fallback: String) -> String {
        let t = tidy(s)
        return t.isEmpty ? fallback : t
    }

    /// Removes everything unspeakable and normalises spacing; doesn't shorten.
    static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // First non-empty line: what follows is detail for the screen.
        if let line = s.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty && !isListMarkerOnly($0) }) {
            s = line
        }
        // Markdown links keep their text.
        s = replace(s, #"\[([^\]]+)\]\((?:[^)]*)\)"#, with: "$1")
        // Bracketed asides: (…), […], {…}, <…> — with any link inside them.
        s = replace(s, #"\([^()]*\)|\[[^\[\]]*\]|\{[^{}]*\}|<[^<>]*>"#, with: "")
        // URLs (not the punctuation after them) and email addresses.
        s = replace(s, #"(?i)\b(?:https?://|www\.)[^\s()<>\[\]]*[^\s()<>\[\].,;:!?'"”’]"#, with: "")
        s = replace(s, #"(?i)\b[\w.+-]+@[\w-]+\.[\w.-]+\b"#, with: "")
        // Element refs and roles: "e3045", "b31", "ref=b12", "AXButton".
        s = replace(s, #"\b(?:ref|id|element)\s*[=:#]?\s*[a-z]{1,2}\d{1,6}\b"#, with: "")
        s = replace(s, #"\b[a-z]\d{1,6}\b"#, with: "")
        s = replace(s, #"\bAX[A-Z][A-Za-z]+\b"#, with: "")
        // Markdown emphasis, code, headings and bullets.
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        s = replace(s, #"^\s*(?:#+|[-*•]|\d+[.)])\s+"#, with: "")
        // Tidy the leftovers: empty quotes, doubled spaces, space before punctuation, stray joins.
        s = replace(s, #"[“"]\s*[”"]|‘\s*’"#, with: "")
        s = replace(s, #"\s+"#, with: " ")
        s = replace(s, #"\s+([.,;:!?…])"#, with: "$1")
        s = replace(s, #"([,;:])(?:\s*[,;:])+"#, with: "$1")
        s = replace(s, #"[,;:—–-]\s*([.!?])"#, with: "$1")
        s = replace(s, #"\s+(?:at|via)\s*([.!?]?)$"#, with: "$1")
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:—–-")))
        return s
    }

    private static func isListMarkerOnly(_ line: String) -> Bool {
        line.range(of: #"^(?:[-*•]|\d+[.)])$"#, options: .regularExpression) != nil
    }

    /// "Done. Added the socks." → "Added the socks."; "Added the socks. Done." → "Added the socks.";
    /// a bare "Done." stays.
    static func stripBoilerplate(_ s: String) -> String {
        var out = s
        let lead = #"^(?i:(?:all\s+)?done|finished|complete|task complete(?:d)?|success)[.!]\s+"#
        let trail = #"(?<=[.!?])\s+(?i:(?:all\s+)?done|finished|task complete(?:d)?)[.!]?$"#
        out = replace(out, lead, with: "")
        let trimmed = replace(out, trail, with: "")
        if !trimmed.isEmpty { out = trimmed }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// At most `words` words, cut at the last clause boundary inside the limit when there is
    /// one, and always ending in punctuation.
    static func cap(_ s: String, words limit: Int) -> String {
        let words = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return "" }
        guard words.count > limit else { return finish(s) }
        let head = Array(words.prefix(limit))
        // The last word inside the limit that ends a clause, or the word before a dash.
        var cut: Int?
        for i in stride(from: head.count - 1, through: 1, by: -1) {
            let w = head[i]
            if let last = w.last, ".!?,;:".contains(last) { cut = i + 1; break }
            if i + 1 < words.count, ["—", "–", "-"].contains(words[i + 1]) { cut = i + 1; break }
        }
        let kept = cut.map { Array(head.prefix($0)) } ?? head
        return finish(kept.joined(separator: " "))
    }

    /// Ends the line with ".", "!", "?" or "…" (dropping a trailing comma or dash).
    static func finish(_ s: String) -> String {
        var out = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:—–-")))
        guard let last = out.last else { return "" }
        if !".!?…".contains(last) { out += "." }
        return out
    }

    // MARK: Lines for each moment

    /// The plan's ack, or nil when there's nothing worth saying: the task is quick (the user
    /// sees it happen) or a question is coming right away (the question is the ack). Kept to
    /// "On it." style: the first clause when it's at most `ackWords` words, else "On it.".
    public static func ack(for plan: Plan) -> String? {
        guard plan.questions.isEmpty, expectedSlow(plan) else { return nil }
        return ack(plan.ack)
    }

    public static func ack(_ text: String?) -> String {
        guard let text else { return "On it." }
        let first = firstClause(clean(text))
        let n = wordCount(first)
        return n > 0 && n <= ackWords ? finish(first) : "On it."
    }

    /// Whether a plan is likely to take more than about two seconds after planning: anything
    /// beyond a single quick command or app launch.
    public static func expectedSlow(_ plan: Plan) -> Bool {
        if plan.mode == .job { return true }
        if plan.steps.count > 1 { return true }
        guard let step = plan.steps.first else { return false }
        switch step.route {
        case .native, .answer, .command: return false
        default: return true
        }
    }

    /// The spoken result. Prefers the step's own spoken line; otherwise shortens the summary
    /// deterministically. When the user asked a question, the answer itself is said (briefly).
    public static func result(summary: String, spoken: String?, instruction: String = "") -> String {
        if let spoken, !tidy(spoken).isEmpty { return tidy(spoken) }
        return shorten(summary, question: isQuestion(instruction))
    }

    /// First clause of a summary, without URLs, quotes or lists, at most `resultWords` words
    /// (a question's answer keeps its first sentence, up to `maxWords`). A summary that is a
    /// list becomes "Here's what I found."
    public static func shorten(_ summary: String, question: Bool = false) -> String {
        if isList(summary) { return listResult }
        var s = stripBoilerplate(clean(summary))
        s = dropQuoted(s)
        if !question { s = firstClause(s) } else { s = firstSentence(s) }
        let out = cap(s, words: question ? maxWords : resultWords)
        return out.isEmpty ? fallbackResult : out
    }

    /// Glide stopped and needs the user: a login becomes "I need you to log in to Gmail."
    public static func needsYou(_ summary: String) -> String {
        let s = clean(summary)
        let lower = s.lowercased()
        if let site = capture(s, #"\b(?i:log|sign)[ -]?(?i:in)(?:to| to| on| at)\s+((?i:your)\s+\p{L}+|\p{Lu}[\p{L}\d.&'-]*(?:\s+\p{Lu}[\p{L}\d.&'-]*)?|[\p{Ll}\d-]+\.\p{Ll}{2,})"#) {
            let name = site.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!? "))
            if !name.isEmpty { return "I need you to log in to \(name)." }
        }
        if lower.contains("captcha") || lower.contains("you're a person") || lower.contains("bot check") {
            return "I need you to prove you're human."
        }
        if lower.range(of: #"\b(?:log|sign)[ -]?in\b|\blogin\b"#, options: .regularExpression) != nil {
            // "Gmail needs you to sign in…", "Amazon is asking for a login".
            if let r = s.range(of: #"^(?:The\s+)?(\p{Lu}[\p{L}\d.&'-]*)\s+(?:needs|wants|requires|is asking|asks|shows)\b"#, options: .regularExpression) {
                let site = s[r].split(separator: " ").first { $0 != "The" }.map(String.init) ?? ""
                if !site.isEmpty, !["I", "You", "It", "Please", "This", "That"].contains(site) { return "I need you to log in to \(site)." }
            }
            return "I need you to log in."
        }
        if lower.contains("password") || lower.contains("verification code") || lower.contains("two-factor") || lower.contains("2fa") {
            return "I need you to enter that code."
        }
        if lower.contains("payment") || lower.contains("card number") { return "I need you to add the payment details." }
        if lower.contains("accessibility") || lower.contains("screen recording") || lower.contains("permission") {
            return "I need a permission — check Settings."
        }
        let out = cap(firstSentence(dropQuoted(s)), words: 12)
        return out.isEmpty ? "I need you for a sec." : out
    }

    /// A failure, said like a person would: "I got stuck adding to cart."
    public static func error(_ summary: String) -> String {
        let s = clean(summary)
        if let r = s.range(of: #"^Couldn't complete\s+[“"](.+)[”"]\.?$"#, options: .regularExpression) {
            let step = s[r].replacingOccurrences(of: #"^Couldn't complete\s+[“"]|[”"]\.?$"#, with: "", options: .regularExpression)
            return cap("I got stuck \(UtteranceInterpreter.lowerFirst(step))", words: resultWords)
        }
        switch s {
        case "Step limit reached": return "That took too many steps."
        case "Couldn't plan the task": return "I couldn't work out a plan."
        case "Accessibility permission needed": return "I need Accessibility access first."
        default: break
        }
        let out = cap(firstClause(dropQuoted(s)), words: resultWords)
        return out.isEmpty ? "That didn't work." : out
    }

    // MARK: Helpers

    static func wordCount(_ s: String) -> Int {
        s.split(separator: " ").filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    /// Up to the first ".", "!", "?", ";", ":", "—" or ", and"-style break.
    static func firstClause(_ s: String) -> String {
        let sentence = firstSentence(s)
        if let r = sentence.range(of: #"\s+[—–]\s+|\s+-\s+|[;:]\s|,\s+(?:and|but|so|which|with|then)\s"#, options: .regularExpression) {
            let head = String(sentence[..<r.lowerBound])
            if wordCount(head) >= 2 { return finish(head) }
        }
        return sentence
    }

    static func firstSentence(_ s: String) -> String {
        // A sentence ends at ". ", "! " or "? " — not inside "3.5" or "U.S.".
        if let r = s.range(of: #"(?<=[\p{Ll}\d)”"'])[.!?](?=\s|$)"#, options: .regularExpression) {
            return String(s[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Drops quoted titles ("with subject “Lunch Friday”") and keeps short quoted words.
    static func dropQuoted(_ s: String) -> String {
        var out = replace(s, #"(?i)\s*,?\s*(?:with\s+)?(?:the\s+)?(?:subject|title|titled|called|named|saying|that says)(?:\s+line)?:?\s*[“"][^”"]*[”"]"#, with: "")
        out = replace(out, #"[“"]([^”"\s]+(?:\s[^”"\s]+){0,2})[”"]"#, with: "$1")
        out = replace(out, #"\s*[“"][^”"]*[”"]"#, with: "")
        out = replace(out, #"\s+([.,;:!?])"#, with: "$1")
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Two or more list items (numbered, bulleted, or "1. … 2. …" inline).
    static func isList(_ s: String) -> Bool {
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let items = lines.filter { $0.range(of: #"^(?:[-*•]|\d+[.)])\s+"#, options: .regularExpression) != nil }
        if items.count >= 2 { return true }
        let inline = s.matches(of: #/(?:^|\s)\d+[.)]\s+\S/#).count
        return inline >= 2
    }

    /// Whether the request asks for information ("what's the weather", "how much is…").
    public static func isQuestion(_ instruction: String) -> Bool {
        let s = instruction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix("?") { return true }
        let starts = ["what", "what's", "whats", "when", "where", "who", "whose", "why", "how", "which", "is ", "are ", "do ", "does ", "did ",
                      "can ", "will ", "should ", "tell me", "find out", "check if", "check whether", "look up"]
        return starts.contains { s.hasPrefix($0) }
    }

    /// The first capture group of `pattern` in `s`.
    private static func capture(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func replace(_ s: String, _ pattern: String, with template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
