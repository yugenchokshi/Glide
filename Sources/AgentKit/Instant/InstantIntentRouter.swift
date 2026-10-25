import Foundation

/// Whether the user asked for the app, the website, or didn't say.
public enum OpenPreference: String, Sendable, Hashable {
    case any, app, web
}

/// A request instant actions understand, before anything is resolved against this Mac.
public enum InstantIntent: Sendable, Hashable {
    /// "open ChatGPT", "go to chatgpt.com", "switch to Slack".
    case open(target: String, prefer: OpenPreference)
    /// "search Amazon for socks" — `site` is the spoken site name.
    case search(query: String, site: String)
    /// "play lo-fi beats on YouTube".
    case play(query: String)
}

/// One way to read an utterance: the instant part, and what's left for the planner.
public struct InstantParse: Sendable, Hashable {
    public var intent: InstantIntent
    /// Lowercased, filler-free rest of a compound request ("ask it about the weather").
    public var remainder: String?
}

/// Reads spoken or typed phrasing into instant intents with plain string rules — no model,
/// microseconds. It only recognizes the shape of a request; whether "X" is an installed app or
/// a known site is decided later against this Mac. Anything it doesn't recognize returns no
/// readings, so the planner takes it.
public enum InstantIntentRouter {
    // MARK: Normalizing

    /// Openers people say before the request ("hey", "can you", "I want to").
    static let leadingFillers: [String] = [
        "hey glide", "hi glide", "ok glide", "okay glide", "yo glide", "glide",
        "could you please", "can you please", "would you please", "will you please", "would you mind",
        "i want you to", "i need you to", "i'd like you to", "i would like you to", "i want to", "i wanna", "i'd like to",
        "i would like to", "i need to", "go ahead and", "can you", "could you", "would you", "will you", "can u", "pls", "please",
        "hey", "hi", "hello", "okay", "ok", "alright", "all right", "so", "now", "and", "just", "quickly", "real quick",
        "quick", "let's", "lets", "yo",
    ]

    /// Closers after the request ("for me", "real quick", "thanks").
    static let trailingFillers: [String] = [
        "for me please", "for me", "please", "pls", "real quick", "quickly", "quick", "right now", "now", "thanks", "thank you",
        "thx", "asap", "if you can", "if you could", "will you", "would you", "okay", "ok", "for a sec", "for a second",
    ]

    /// Hesitations dropped wherever they appear.
    static let hesitations: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "mm"]

    /// Lowercases, drops punctuation that speech recognizers add (but keeps the dots inside
    /// "chatgpt.com"), collapses spaces and strips filler words from both ends.
    public static func normalize(_ text: String) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: " ")
            .replacingOccurrences(of: "\u{201D}", with: " ")
        // Punctuation the recognizer adds sits at the ends of words; inside a word ("chatgpt.com",
        // "?x=1", "AT&T") it is part of what was said.
        let edge = CharacterSet(charactersIn: ".,!?;:\"'()")
        let words = s.split(whereSeparator: { $0.isWhitespace }).map { w -> String in
            var w = String(w)
            while let f = w.unicodeScalars.first, edge.contains(f), f != "'" { w.removeFirst() }
            while let l = w.unicodeScalars.last, edge.contains(l) { w.removeLast() }
            return w
        }.filter { !$0.isEmpty && !hesitations.contains($0) }
        s = words.joined(separator: " ")
        var changed = true
        while changed {
            changed = false
            for f in leadingFillers where s == f || s.hasPrefix(f + " ") {
                s = String(s.dropFirst(f.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
            for f in trailingFillers where s.hasSuffix(" " + f) {
                s = String(s.dropLast(f.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return s
    }

    // MARK: Reading

    /// Verbs that mean "put this in front of me". Longest first so "open up" beats "open".
    static let openVerbs: [String] = [
        "open up", "open", "launch", "start up", "start", "switch over to", "switch to", "go over to", "go to", "goto",
        "bring up", "pull up", "show me", "take me to", "navigate to", "head over to", "head to", "jump to", "jump over to",
        "fire up", "visit", "load up", "load",
    ]

    /// Words that make a phrase a task, not a name. An open target containing one of them
    /// ("open notes and write…" read whole, "start a new email") is never instant.
    static let workWords: Set<String> = [
        "add", "buy", "order", "send", "delete", "remove", "email", "message", "reply", "book", "pay", "purchase",
        "checkout", "post", "tweet", "write", "type", "and", "then", "fill", "sign", "subscribe", "unsubscribe", "cancel", "schedule", "move",
        "rename", "install", "uninstall", "download", "upload", "share", "call", "close", "quit", "ask", "tell", "create",
        "make", "edit", "change", "turn", "set", "compose", "draft", "save", "print", "copy", "paste", "record", "new",
        "transfer", "reserve", "submit", "apply", "invite", "forward", "archive", "empty", "clear", "reset", "update",
        "log", "logout", "login", "find", "where", "what", "how", "why", "when", "who", "if", "with", "about", "from",
    ]

    /// First words that make the rest of a compound request a task of its own.
    static var taskStarts: Set<String> {
        workWords.union(["open", "go", "play", "search", "look", "then", "also", "click", "pick", "choose", "select", "show", "read", "check"])
    }

    /// Tail phrases that say "the app" or "the website".
    static let appMarkers = [" desktop app", " mac app", " application", " app", " for mac"]
    static let webMarkers = [
        " in the browser", " in my browser", " in browser", " in a new tab", " in a tab", " in new tab", " on the web",
        " web site", " website", " webpage", " web page", " homepage", " home page", " site", " page", " online",
    ]
    /// "open ChatGPT in Safari" names a browser instant actions don't pick; the planner does.
    static let namedBrowsers = [" in chrome", " in safari", " in firefox", " in arc", " in edge", " in brave", " in google chrome"]

    /// Every reading of `utterance`, most literal first: the whole request as one instant
    /// action, then splits at each "and"/"then" (instant part first, the rest for the planner).
    public static func parse(_ utterance: String) -> [InstantParse] {
        let s = normalize(utterance)
        guard !s.isEmpty else { return [] }
        var compound: [InstantParse] = []
        for (head, tail) in splits(s) {
            guard let intent = parseSingle(head) else { continue }
            let rest = normalizeTail(tail)
            guard !rest.isEmpty else { continue }
            compound.append(InstantParse(intent: intent, remainder: rest))
        }
        guard let whole = parseSingle(s) else { return compound }
        // "search Amazon for socks and buy the cheapest" is a search plus a task, not a search
        // for "socks and buy the cheapest"; "search for salt and pepper on Amazon" stays whole.
        let splitIsTask = compound.contains { c in
            c.remainder.flatMap { $0.split(separator: " ").first }.map { taskStarts.contains(String($0)) } ?? false
        }
        let single = InstantParse(intent: whole, remainder: nil)
        return splitIsTask ? compound + [single] : [single] + compound
    }

    /// (head, tail) pairs at each conjunction, left to right.
    static func splits(_ s: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for sep in [" and then ", " and also ", " and ", " then ", " & "] {
            var searchStart = s.startIndex
            while let r = s.range(of: sep, range: searchStart..<s.endIndex) {
                let head = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let tail = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, !tail.isEmpty, !out.contains(where: { $0.0 == head }) { out.append((head, tail)) }
                searchStart = r.upperBound
            }
        }
        return out.sorted { $0.0.count < $1.0.count }
    }

    static func normalizeTail(_ tail: String) -> String {
        var t = tail
        for lead in ["then ", "also ", "please ", "and "] where t.hasPrefix(lead) { t = String(t.dropFirst(lead.count)) }
        return normalize(t)
    }

    /// One request with no conjunction left in it.
    public static func parseSingle(_ s: String) -> InstantIntent? {
        if let play = parsePlay(s) { return play }
        if let search = parseSearch(s) { return search }
        return parseOpen(s)
    }

    static func parsePlay(_ s: String) -> InstantIntent? {
        guard s.hasPrefix("play ") else { return nil }
        let rest = String(s.dropFirst(5))
        for site in [" on youtube", " on you tube", " from youtube", " in youtube", " on yt"] where rest.hasSuffix(site) {
            let q = String(rest.dropLast(site.count)).trimmingCharacters(in: .whitespaces)
            return q.isEmpty ? nil : .play(query: q)
        }
        return nil
    }

    static func parseSearch(_ s: String) -> InstantIntent? {
        // "search for Q on S", "search Q in S", "look up Q on S", "look Q up on S".
        var rest: String?
        for verb in ["search for", "search up", "search", "look up", "lookup", "look for"] where s.hasPrefix(verb + " ") {
            rest = String(s.dropFirst(verb.count + 1))
            break
        }
        if rest == nil, s.hasPrefix("look "), let up = s.range(of: " up ") {
            rest = String(s[s.index(s.startIndex, offsetBy: 5)..<up.lowerBound]) + " " + String(s[up.upperBound...])
        }
        if let rest {
            // "… on/in/at S" with S a searchable site: the last such split wins ("search for
            // things to do in paris on google" searches Google).
            for prep in [" on ", " in ", " at ", " using ", " via "] {
                var r = rest.startIndex
                var found: (String, String)?
                while let m = rest.range(of: prep, range: r..<rest.endIndex) {
                    let q = String(rest[..<m.lowerBound]), site = String(rest[m.upperBound...])
                    if isSearchable(site), !q.isEmpty { found = (q, site) }
                    r = m.upperBound
                }
                if let (q, site) = found { return .search(query: q, site: cleanSite(site)) }
            }
            // "search S for Q" / "search S Q".
            if let (site, q) = leadingSite(rest) {
                let query = q.hasPrefix("for ") ? String(q.dropFirst(4)) : q
                if !query.isEmpty { return .search(query: query, site: site) }
            }
            return nil
        }
        // "S search Q", "S search for Q".
        if let m = s.range(of: " search ") {
            let site = String(s[..<m.lowerBound])
            var q = String(s[m.upperBound...])
            if q.hasPrefix("for ") { q = String(q.dropFirst(4)) }
            if isSearchable(site), !q.isEmpty { return .search(query: q, site: cleanSite(site)) }
        }
        // "google Q" (but not "google maps" said alone, which names a site).
        if s.hasPrefix("google "), SiteCatalog.site(named: s) == nil {
            let q = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if !q.isEmpty { return .search(query: q, site: "google") }
        }
        return nil
    }

    static func cleanSite(_ site: String) -> String {
        var s = site
        for lead in ["the ", "my "] where s.hasPrefix(lead) { s = String(s.dropFirst(lead.count)) }
        for tail in [" website", " site", " app"] where s.hasSuffix(tail) { s = String(s.dropLast(tail.count)) }
        return s
    }

    static func isSearchable(_ site: String) -> Bool {
        SiteCatalog.site(named: cleanSite(site))?.searchTemplate != nil
    }

    /// The longest leading run of 1–3 words that names a searchable site, and what follows.
    static func leadingSite(_ s: String) -> (String, String)? {
        let words = s.split(separator: " ").map(String.init)
        for n in stride(from: min(3, words.count - 1), through: 1, by: -1) {
            let site = words[0..<n].joined(separator: " ")
            if isSearchable(site) { return (cleanSite(site), words[n...].joined(separator: " ")) }
        }
        return nil
    }

    static func parseOpen(_ s: String) -> InstantIntent? {
        guard let verb = openVerbs.first(where: { s.hasPrefix($0 + " ") }) else { return nil }
        var t = String(s.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
        if namedBrowsers.contains(where: { t.hasSuffix($0) }) { return nil }
        var prefer = OpenPreference.any
        var stripped = true
        while stripped {
            stripped = false
            for lead in ["up ", "the ", "my ", "a ", "an ", "our ", "over to "] where t.hasPrefix(lead) {
                t = String(t.dropFirst(lead.count))
                stripped = true
            }
            if let m = webMarkers.first(where: { t.hasSuffix($0) }) {
                t = String(t.dropLast(m.count))
                prefer = .web
                stripped = true
            } else if let m = appMarkers.first(where: { t.hasSuffix($0) }) {
                t = String(t.dropLast(m.count))
                if prefer == .any { prefer = .app }
                stripped = true
            }
            for lead in ["website ", "site ", "app "] where t.hasPrefix(lead) {
                t = String(t.dropFirst(lead.count))
                prefer = lead == "app " ? .app : .web
                stripped = true
            }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if SiteCatalog.webURL(from: t) != nil { return .open(target: t, prefer: .web) }
        let words = t.split(separator: " ").map(String.init)
        guard words.count <= 4 else { return nil }
        // A work word makes it a task ("start a new document") unless the whole phrase is a
        // name Glide knows ("text edit").
        if words.contains(where: { workWords.contains($0) }),
           AppResolver.aliases[AppResolver.compact(t)] == nil, SiteCatalog.site(named: t) == nil { return nil }
        return .open(target: t, prefer: prefer)
    }

    // MARK: Compound tails

    /// "search for socks" / "look up socks" / "find socks" after opening a searchable site:
    /// the query, so "open Amazon and search for socks" becomes one search.
    static func searchQuery(inTail tail: String) -> String? {
        for verb in ["search for", "search", "look up", "look for", "find me", "find"] where tail.hasPrefix(verb + " ") {
            let q = String(tail.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
            return q.isEmpty ? nil : q
        }
        return nil
    }

    /// "play Q" after opening YouTube.
    static func playQuery(inTail tail: String) -> String? {
        guard tail.hasPrefix("play ") else { return nil }
        let q = String(tail.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : q
    }
}
