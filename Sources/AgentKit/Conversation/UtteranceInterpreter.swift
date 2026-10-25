import Foundation

/// Reads what the user said in the context of what Glide is doing: a control word ("stop",
/// "wait"), an answer to the open question, or something new. Deterministic and instant — no
/// model — because it runs on every utterance and must never delay "stop".
public enum UtteranceInterpreter {
    public enum Control: Sendable, Equatable {
        case stop, pause, resume
    }

    /// Lowercased, punctuation stripped, filler ("please", "okay", "Glide") removed, spaces
    /// collapsed: "Okay, stop please!" → "stop".
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" ? Character($0) : " " }
        var words = String(kept).split(separator: " ").map(String.init)
        while let first = words.first, leadingFiller.contains(first), words.count > 1 { words.removeFirst() }
        var changed = true
        while changed && words.count > 1 {
            changed = false
            if let last = words.last, trailingFiller.contains(last) {
                words.removeLast()
                changed = true
            }
            // "wait a sec", "hold on for a moment".
            for tail in trailingPhrases where words.count > tail.count && Array(words.suffix(tail.count)) == tail {
                words.removeLast(tail.count)
                changed = true
                break
            }
        }
        return words.joined(separator: " ")
    }

    private static let leadingFiller: Set<String> = ["ok", "okay", "hey", "glide", "please", "uh", "um", "oh", "so", "and", "just"]
    private static let trailingFiller: Set<String> = ["please", "glide", "now", "thanks", "thank", "you"]
    private static let trailingPhrases: [[String]] = [["for", "a", "sec"], ["for", "a", "second"], ["for", "a", "moment"], ["for", "a", "minute"],
                                                      ["a", "sec"], ["a", "second"], ["a", "moment"], ["a", "minute"]]

    static let stopPhrases: Set<String> = ["stop", "cancel", "never mind", "nevermind", "stop stop", "cancel that", "stop that", "forget it",
                                           "abort", "quit", "stop it", "cancel it", "stop everything", "that's enough"]
    static let pausePhrases: Set<String> = ["pause", "wait", "hold on", "hang on", "hold", "wait wait", "one sec", "pause it"]
    static let resumePhrases: Set<String> = ["continue", "resume", "go on", "keep going", "carry on", "go ahead and continue", "unpause"]

    /// A control word for the running task. Only the whole utterance counts: "stop the music"
    /// is a request, not a stop.
    public static func control(_ text: String) -> Control? {
        let n = normalize(text)
        if stopPhrases.contains(n) { return .stop }
        if pausePhrases.contains(n) { return .pause }
        if resumePhrases.contains(n) { return .resume }
        return nil
    }

    static let yesWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead", "do it", "please do", "approve", "confirm",
                                        "yes please", "of course", "absolutely", "sounds good", "go for it", "correct", "right", "affirmative"]
    static let noWords: Set<String> = ["no", "nope", "nah", "don't", "do not", "cancel", "no thanks", "no thank you", "not now", "never mind",
                                       "nevermind", "decline", "skip", "don't do it", "stop", "negative"]

    /// "yes" or "no" when the utterance is (or starts with) a plain yes or no: "yeah, go ahead"
    /// is yes, "no, use the other card" is no.
    public static func yesNo(_ text: String) -> Bool? {
        let n = normalize(text)
        if yesWords.contains(n) { return true }
        if noWords.contains(n) { return false }
        let words = n.split(separator: " ").map(String.init)
        for count in stride(from: min(3, words.count), through: 1, by: -1) {
            let lead = words.prefix(count).joined(separator: " ")
            if noWords.contains(lead) && lead != "stop" { return false }
            if yesWords.contains(lead) && !["right", "ok", "okay", "correct"].contains(lead) { return true }
        }
        return nil
    }

    /// Words that start a new request rather than answer a question.
    static let requestVerbs: Set<String> = ["open", "launch", "start", "go", "search", "find", "look", "play", "send", "email", "message", "text",
                                            "call", "buy", "order", "book", "create", "make", "write", "show", "tell", "schedule", "remind",
                                            "set", "turn", "close", "quit", "add", "remove", "delete", "check", "read", "summarize", "draft",
                                            "reply", "post", "download", "install", "translate", "what", "what's", "whats", "who", "when",
                                            "where", "how", "why", "can", "could", "would", "will"]

    /// True when the utterance reads as a request of its own ("open Spotify", "what's the
    /// weather") rather than a reply.
    public static func looksLikeRequest(_ text: String) -> Bool {
        let n = normalize(text)
        guard let first = n.split(separator: " ").first.map(String.init) else { return false }
        return requestVerbs.contains(first) && n.split(separator: " ").count >= 2
    }

    static let ordinals: [(words: [String], index: Int)] = [
        (["first", "1st", "one", "number one", "top"], 0), (["second", "2nd", "two", "number two"], 1),
        (["third", "3rd", "three", "number three"], 2), (["fourth", "4th", "four", "number four"], 3),
    ]

    /// The option the utterance picks: an exact or near match ("wool" → "Wool socks"), or an
    /// ordinal ("the second one", "the last one").
    public static func matchOption(_ text: String, options: [String]) -> String? {
        guard !options.isEmpty else { return nil }
        let n = normalize(text)
        guard !n.isEmpty else { return nil }
        let normalized = options.map(normalize)
        if let i = normalized.firstIndex(of: n) { return options[i] }
        if let i = ordinalPick(n, count: options.count) { return options[i] }
        // Containment either way, preferring the longest option that fits ("no-show" vs "show").
        let contained = normalized.enumerated().filter { _, o in (o.count >= 3 && n.contains(o)) || (n.count >= 3 && o.contains(n)) }
        if let best = contained.max(by: { $0.element.count < $1.element.count }) { return options[best.offset] }
        // Most shared meaningful words.
        let said = significantWords(n)
        guard !said.isEmpty else { return nil }
        let scored = normalized.enumerated().map { i, o -> (Int, Int) in (i, significantWords(o).intersection(said).count) }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0, scored.filter({ $0.1 == best.1 }).count == 1 { return options[best.0] }
        return nil
    }

    /// The option index an ordinal picks: "the second one", "number two", "the last one".
    private static func ordinalPick(_ n: String, count: Int) -> Int? {
        var words = n.split(separator: " ").map(String.init).filter { $0 != "the" }
        if words.last == "one" || words.last == "option", words.count > 1 { words.removeLast() }
        let stripped = words.joined(separator: " ")
        if stripped == "last" { return count - 1 }
        return ordinals.first { $0.index < count && $0.words.contains(stripped) }?.index
    }

    private static let stopWords: Set<String> = ["the", "a", "an", "one", "ones", "please", "i", "want", "like", "would", "of", "with", "for", "some", "those", "these", "that"]

    private static func significantWords(_ n: String) -> Set<String> {
        Set(n.split(separator: " ").map { w -> String in
            let s = String(w)
            return s.count > 3 && s.hasSuffix("s") ? String(s.dropLast()) : s
        }.filter { !stopWords.contains($0) })
    }

    /// What the utterance means for `question`: the answer text to record, or nil when it
    /// isn't an answer (a new request, or a long remark the running task should get as a note).
    /// Options tapped (`source == .option`) are always answers.
    public static func answer(_ text: String, to question: AgentQuestion, source: UtteranceSource) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if source == .option { return trimmed }
        if question.isApproval {
            guard let yes = yesNo(trimmed) else { return nil }
            return yes ? "Yes" : "No"
        }
        if let option = matchOption(trimmed, options: question.options) {
            // Said exactly (or by number): record the option itself; said with more ("the blue
            // ones, size 10"), keep every word.
            let n = normalize(trimmed)
            let saysOnlyTheOption = ordinalPick(n, count: question.options.count) != nil
                || significantWords(n).isSubset(of: significantWords(normalize(option)))
            return saysOnlyTheOption ? option : trimmed
        }
        if yesNo(trimmed) != nil { return trimmed }
        let words = normalize(trimmed).split(separator: " ").count
        if words <= 6 && !looksLikeRequest(trimmed) { return trimmed }
        return nil
    }


    // MARK: Spoken text

    /// A result short enough to say: the first sentence, at most `maxWords` words.
    public static func spokenSummary(_ text: String, maxWords: Int = 25) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("Done. ") { s.removeFirst(6) }
        // First line, then first sentence.
        s = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? s
        if let end = s.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            s = String(s[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let words = s.split(separator: " ")
        guard words.count > maxWords else { return s }
        return words.prefix(maxWords).joined(separator: " ") + "…"
    }

    /// True when a blocked step needs the person themselves — a login, a CAPTCHA, a password,
    /// a locked screen or a permission — rather than an answer Glide can just ask for.
    public static func needsPerson(_ message: String) -> Bool {
        let m = message.lowercased()
        let signs = ["log in", "login", "log-in", "sign in", "signin", "sign-in", "password", "captcha", "you're a person", "you are a person",
                     "human", "bot check", "two-factor", "2fa", "verification code", "one-time", "passcode", "locked", "permission",
                     "accessibility", "screen recording", "payment details", "card number", "touch id", "face id"]
        return signs.contains { m.contains($0) }
    }

    /// "Adding to cart" → "adding to cart" (keeps "ChatGPT" and other capitalised words).
    static func lowerFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        let second = s.dropFirst().first
        if second.map({ $0.isUppercase }) == true { return s }
        return first.lowercased() + s.dropFirst()
    }
}

/// Optional dry run for instant actions, used by `glidectl say --dry-run`: describes what the
/// instant handler would do with an utterance, without doing it (nil = it wouldn't handle it).
/// The instant-actions module may install it next to `InstantActions.handler`.
public enum InstantPreview {
    nonisolated(unsafe) public static var describe: (@Sendable (_ utterance: String) async -> String?)?
}
