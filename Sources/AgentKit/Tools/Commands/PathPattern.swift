import Foundation

/// A path the shell only settles at run time: a glob (`~/.ss?/id_*`), braces
/// (`~/.{ssh,aws}`), or a part filled in from a variable or command output (`~/.ssh/$key`).
/// The shell checker can't compare such a word's text with the folders it protects, so it
/// matches the pattern against them instead: could any name the shell might produce be that
/// folder, or inside it? Matching is case-insensitive, like the default APFS volume, and
/// purely textual: it never looks at the disk, so a file created later is covered too.
struct PathPattern: Sendable, Hashable {
    enum Token: Sendable, Hashable {
        /// A literal character (lowercased).
        case char(Character)
        /// `*`: any run of characters within one name.
        case star
        /// `?`: one character.
        case one
        /// `[…]`: one character from a set (the text between the brackets).
        case set(String)
        /// Text only known at run time (a variable, `$(…)`, a zsh `(…)` group). Like `*`, but
        /// it may also start with a dot, since nothing stops a value from doing so.
        case any
    }

    enum Component: Sendable, Hashable {
        case name([Token])
        /// zsh's `**/`: zero or more folders. Like `*`, it skips folders whose names start with a
        /// dot unless dot-globbing is on (zsh and bash's globstar both do).
        case anyDepth
        /// Zero or more folders of any name, hidden ones included: the fail-closed stand-in for a
        /// path too complex to work out ("could be anywhere"), never written by the user.
        case anywhere

        /// The name when it's all literal characters (`com.vendor.app`), else nil.
        var literalName: String? {
            guard case .name(let t) = self else { return nil }
            var s = ""
            for tok in t { guard case .char(let ch) = tok else { return nil }; s.append(ch) }
            return s
        }

        /// A name component with at least one wildcard (`*`, `?`, a set, or run-time text).
        var isWildcard: Bool {
            guard case .name(let t) = self else { return false }
            return t.contains { if case .char = $0 { return false }; return true }
        }
    }

    /// From the root folder down; never contains `.` or `..`.
    var components: [Component]
    /// Some part comes from a variable or command output rather than only from a glob.
    var dynamic: Bool
    /// Wildcards in this pattern match names starting with a dot, as zsh's `(D)` qualifier
    /// makes them do for one word (on top of the line-wide `dotGlob` the matchers take).
    var dots = false

    /// A path that could be anywhere, hidden folders included: what a check falls back to when
    /// the real paths are too many or too complex to work out.
    static let anywhere = PathPattern(components: [.anywhere], dynamic: true)

    /// Most brace alternatives `make` enumerates, and the deepest brace nesting it follows;
    /// beyond either it returns nil and the caller fails closed.
    static let braceLimit = 64
    static let maxBraceDepth = 16

    // MARK: Building

    /// Patterns for `text` (already free of the anchor: it starts with `/` or is empty)
    /// appended to `base`. With `glob`, unquoted `*`, `?`, `[…]`, `{a,b}` and zsh `(…)` are
    /// wildcards; `extendedGlob` adds zsh's `^`, `#` and `~`. Run-time parts (`$x`, `$(…)`,
    /// backticks) are wildcards either way. Nil when brace expansion would produce too many
    /// alternatives to check.
    static func make(base: [Component], text: String, glob: Bool, extendedGlob: Bool, dots: Bool = false) -> [PathPattern]? {
        guard let alternatives = glob ? expandBraces(text) : [text] else { return nil }
        return make(base: base, alternatives: alternatives, glob: glob, extendedGlob: extendedGlob, dots: dots)
    }

    /// `make` for alternatives already brace-expanded (`braceAlternatives`), so a caller that
    /// matches under several folders expands the text once.
    static func make(base: [Component], alternatives: [String], glob: Bool, extendedGlob: Bool, dots: Bool = false) -> [PathPattern] {
        alternatives.map { alt in
            var dynamic = base.contains(.anywhere)
            let tokens = tokenize(alt, glob: glob, extendedGlob: extendedGlob, dynamic: &dynamic)
            var comps = base
            var current: [Token] = []
            var pending = false
            func flush() {
                defer { current = []; pending = false }
                guard pending else { return }
                if current == [.char(".")] { return }
                if current == [.char("."), .char(".")] {
                    guard let last = comps.last else { return }
                    if last == .anywhere { return } // anywhere, one folder up, is still anywhere
                    var starStar = last == .anyDepth
                    if case .name(let t) = last, t.count >= 2, t.allSatisfy({ $0 == .star }) { starStar = true }
                    comps.removeLast()
                    if starStar {
                        // `**/..` may climb above where `**` started: anything under its parent.
                        if !comps.isEmpty { comps.removeLast() }
                        comps.append(.anywhere)
                    }
                    return
                }
                comps.append(.name(current))
            }
            for t in tokens {
                if t == .char("/") { flush(); continue }
                current.append(t)
                pending = true
            }
            flush()
            // `**` followed by another name means any number of folders in zsh; on its own
            // at the end it is just `*`.
            for i in comps.indices.dropLast() {
                if case .name(let t) = comps[i], t.count >= 2, t.allSatisfy({ $0 == .star }) { comps[i] = .anyDepth }
            }
            // `**/**/` is the same as one `**/`; collapsing runs keeps matching linear.
            var collapsed: [Component] = []
            collapsed.reserveCapacity(comps.count)
            for comp in comps {
                let deep = comp == .anyDepth || comp == .anywhere
                if deep, let last = collapsed.last, last == .anywhere || (last == .anyDepth && comp == .anyDepth) { continue }
                if comp == .anywhere, collapsed.last == .anyDepth { collapsed.removeLast() }
                collapsed.append(comp)
            }
            return PathPattern(components: collapsed, dynamic: dynamic, dots: dots)
        }
    }

    /// Components of a fixed absolute path.
    static func literalComponents(_ path: String) -> [Component] {
        path.split(separator: "/").map { .name($0.lowercased().map { .char($0) }) }
    }

    /// Expands `{a,b}` alternatives (zsh and bash brace expansion). `{1..9}` ranges become
    /// `*`; braces without a comma stay literal, as zsh leaves them. `${…}` is skipped.
    ///
    /// Linear in the text apart from the (bounded) output: brackets are matched once up front,
    /// nesting deeper than `maxBraceDepth` or more than `limit` alternatives returns nil, so a
    /// long run of `{1..2}` or `{a,{a,…}}` can neither recurse without bound nor take long.
    static func expandBraces(_ text: String, limit: Int = PathPattern.braceLimit) -> [String]? {
        if case .alternatives(let a) = braceAlternatives(text, limit: limit) { return a }
        return nil
    }

    /// What brace expansion of a word comes to.
    enum BraceExpansion: Equatable {
        case alternatives([String])
        /// More than `limit` alternatives, or nested deeper than `maxBraceDepth`.
        case tooMany
        /// The alternatives together would be longer than `maxLength` characters (a long word
        /// times a few dozen alternatives is megabytes).
        case tooLong
    }

    /// `expandBraces`, also bounded by the total length of what it builds, and saying which
    /// limit stopped it. The length is checked before each step builds anything.
    static func braceAlternatives(_ text: String, limit: Int = PathPattern.braceLimit, maxLength: Int = .max) -> BraceExpansion {
        let chars = Array(text)
        guard chars.contains("{") else { return .alternatives([text]) }
        // The `}` matching each `{` (an unmatched `{` is literal text).
        var close = [Int](repeating: -1, count: chars.count)
        var open: [Int] = []
        for (k, ch) in chars.enumerated() {
            if ch == "{" { open.append(k) } else if ch == "}", let o = open.popLast() { close[o] = k }
        }
        var tooLong = false

        /// Alternatives for chars[lo..<hi]; nil once over a limit or too deep.
        func expand(_ lo: Int, _ hi: Int, depth: Int) -> [String]? {
            if depth > maxBraceDepth { return nil }
            var results = [""]
            // Characters across all of `results`.
            var length = 0
            var literal = ""
            var i = lo
            func flush() -> Bool {
                guard !literal.isEmpty else { return true }
                length += results.count * literal.utf8.count
                guard length <= maxLength else { tooLong = true; return false }
                for k in results.indices { results[k] += literal }
                literal = ""
                return true
            }
            while i < hi {
                let ch = chars[i]
                // `${…}` is a parameter expansion, copied as written.
                if ch == "$", i + 1 < hi, chars[i + 1] == "{" {
                    let end = close[i + 1] >= 0 && close[i + 1] < hi ? close[i + 1] : hi - 1
                    literal += String(chars[i...end])
                    i = end + 1
                    continue
                }
                guard ch == "{", close[i] >= 0, close[i] < hi else { literal.append(ch); i += 1; continue }
                let end = close[i]
                // Split the inside at commas that aren't inside a nested group.
                var parts: [(Int, Int)] = []
                var start = i + 1
                var k = i + 1
                while k < end {
                    if chars[k] == "{", close[k] >= 0, close[k] < end { k = close[k] + 1; continue }
                    if chars[k] == "," { parts.append((start, k)); start = k + 1 }
                    k += 1
                }
                parts.append((start, end))
                if parts.count == 1 {
                    // `{1..9}` becomes `*`; other braces without a comma stay literal, inside too.
                    let inner = String(chars[(i + 1)..<end])
                    literal += inner.contains("..") ? "*" : "{" + inner + "}"
                    i = end + 1
                    continue
                }
                var alternatives: [String] = []
                var alternativesLength = 0
                for (a, b) in parts {
                    guard let more = expand(a, b, depth: depth + 1) else { return nil }
                    alternatives += more
                    alternativesLength += more.reduce(0) { $0 + $1.utf8.count }
                    if alternatives.count > limit { return nil }
                    guard alternativesLength <= maxLength else { tooLong = true; return nil }
                }
                guard flush() else { return nil }
                guard results.count * alternatives.count <= limit else { return nil }
                // Every result gets every alternative appended.
                let product = length * alternatives.count + alternativesLength * results.count
                guard product <= maxLength else { tooLong = true; return nil }
                results = results.flatMap { r in alternatives.map { r + $0 } }
                length = product
                i = end + 1
            }
            guard flush() else { return nil }
            return results
        }
        if let results = expand(0, chars.count, depth: 0) { return .alternatives(results) }
        return tooLong ? .tooLong : .tooMany
    }

    /// Index of the bracket closing the one at `from` (or `chars.count` when unbalanced).
    private static func matchingClose(_ chars: [Character], from: Int, open: Character, close: Character) -> Int {
        var depth = 0
        var j = from
        while j < chars.count {
            if chars[j] == open { depth += 1 } else if chars[j] == close { depth -= 1; if depth == 0 { return j } }
            j += 1
        }
        return chars.count
    }

    private static func tokenize(_ text: String, glob: Bool, extendedGlob: Bool, dynamic: inout Bool) -> [Token] {
        let c = Array(text)
        var out: [Token] = []
        var i = 0
        func any() { if out.last != .any { out.append(.any) }; dynamic = true }
        while i < c.count {
            let ch = c[i]
            if ch == "$", i + 1 < c.count {
                let n = c[i + 1]
                if n == "{" { i = matchingClose(c, from: i + 1, open: "{", close: "}") + 1; any(); continue }
                if n == "(" { i = matchingClose(c, from: i + 1, open: "(", close: ")") + 1; any(); continue }
                if n == "'" {
                    i += 2
                    while i < c.count, c[i] != "'" { i += c[i] == "\\" ? 2 : 1 }
                    i += 1; any(); continue
                }
                if n.isLetter || n == "_" {
                    i += 1
                    while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" { i += 1 }
                    any(); continue
                }
                if n.isNumber || "?#@*!$-".contains(n) { i += 2; any(); continue }
            }
            if ch == "`" {
                i += 1
                while i < c.count, c[i] != "`" { i += 1 }
                i += 1; any(); continue
            }
            if (ch == "<" || ch == ">" || ch == "="), i + 1 < c.count, c[i + 1] == "(" {
                i = matchingClose(c, from: i + 1, open: "(", close: ")") + 1; any(); continue
            }
            if glob {
                switch ch {
                case "*": out.append(.star); i += 1; continue
                case "?": out.append(.one); i += 1; continue
                case "[":
                    // `]` right after `[` (or `[!`) is part of the set.
                    var j = i + 1
                    if j < c.count, c[j] == "!" || c[j] == "^" { j += 1 }
                    if j < c.count, c[j] == "]" { j += 1 }
                    while j < c.count, c[j] != "]", c[j] != "/" { j += 1 }
                    if j < c.count, c[j] == "]" {
                        out.append(.set(String(c[(i + 1)..<j]).lowercased()))
                        i = j + 1
                        continue
                    }
                case "(":
                    // zsh alternatives or qualifiers; bash's @( !( +( drop their marker.
                    if case .char(let p)? = out.last, "@!+".contains(p) { out.removeLast() }
                    i = matchingClose(c, from: i, open: "(", close: ")") + 1
                    any()
                    continue
                case "^", "~":
                    // zsh's `^x` (anything but x) and `a~b` (a, except b): the rest of this
                    // name only narrows the match, so anything may follow.
                    if extendedGlob, ch == "^" || i > 0 {
                        any()
                        while i < c.count, c[i] != "/" { i += 1 }
                        continue
                    }
                case "#":
                    // zsh's `x#` / `x##`: any number of the previous character.
                    if extendedGlob { any(); i += 1; continue }
                default:
                    break
                }
            }
            out.append(.char(Character(ch.lowercased())))
            i += 1
        }
        return out
    }

    // MARK: Matching

    /// Lowercased components of an absolute path, the form the matchers compare against.
    static func splitPath(_ path: String) -> [String] {
        path.lowercased().split(separator: "/").map(String.init)
    }

    /// Could some name the shell produces be inside `root` (or `root` itself)?
    func mayReachInside(_ root: String, dotGlob: Bool) -> Bool {
        mayReachInside(Self.splitPath(root), dotGlob: dotGlob)
    }

    /// `mayReachInside` for a root already split by `splitPath`.
    ///
    /// Matching runs left to right over the components, keeping the set of target positions
    /// reached so far, so it takes components × target length steps however many `**/` the
    /// pattern has (a recursive search was exponential in them).
    func mayReachInside(_ target: [String], dotGlob: Bool) -> Bool {
        let dots = dotGlob || self.dots
        let m = target.count
        if m == 0 { return true }
        // Without `**/` every component names one folder: too few can't get inside.
        if !hasDeepComponent, components.count < m { return false }
        var cur = [Bool](repeating: false, count: m + 1)
        var next = cur
        cur[0] = true
        for comp in components {
            for k in next.indices { next[k] = false }
            switch comp {
            case .anyDepth, .anywhere:
                for ti in 0...m {
                    next[ti] = cur[ti] || (ti > 0 && next[ti - 1] && Self.deepStep(comp, target[ti - 1], dots: dots))
                }
            case .name(let t):
                for ti in 0..<m where cur[ti] && Self.matches(t, target[ti], dotGlob: dots) { next[ti + 1] = true }
            }
            // Every target folder matched: whatever follows is inside the root.
            if next[m] { return true }
            swap(&cur, &next)
            if !cur.contains(true) { return false }
        }
        return false
    }

    /// Could some name the shell produces be exactly `path`? A nil component in `path` stands
    /// for any name (`/Users/<anyone>`). Same left-to-right matching as `mayReachInside`.
    func mayBe(_ path: [String?], dotGlob: Bool) -> Bool {
        let dots = dotGlob || self.dots
        // Without `**/` the pattern names exactly as many folders as it has components.
        if !hasDeepComponent, components.count != path.count { return false }
        let target = path.map { $0?.lowercased() }
        let m = target.count
        var cur = [Bool](repeating: false, count: m + 1)
        var next = cur
        cur[0] = true
        for comp in components {
            for k in next.indices { next[k] = false }
            switch comp {
            case .anyDepth, .anywhere:
                for ti in 0...m {
                    next[ti] = cur[ti] || (ti > 0 && next[ti - 1] && Self.deepStep(comp, target[ti - 1], dots: dots))
                }
            case .name(let t):
                for ti in 0..<m where cur[ti] {
                    if let name = target[ti], !Self.matches(t, name, dotGlob: dots) { continue }
                    next[ti + 1] = true
                }
            }
            swap(&cur, &next)
            if !cur.contains(true) { return false }
        }
        return cur[m]
    }

    func mayBe(_ path: String, dotGlob: Bool) -> Bool {
        mayBe(path.split(separator: "/").map { String($0) }, dotGlob: dotGlob)
    }

    /// Some component is `**/` or the "anywhere" stand-in, which match any number of folders.
    var hasDeepComponent: Bool {
        components.contains { $0 == .anyDepth || $0 == .anywhere }
    }

    /// Whether `**/` (or the "anywhere" stand-in) can pass through a folder called `name`:
    /// `**/` skips hidden folders unless dots match, as zsh and bash's globstar do.
    static func deepStep(_ comp: Component, _ name: String?, dots: Bool) -> Bool {
        if comp == .anywhere || dots { return true }
        guard let name else { return true }
        return !name.hasPrefix(".")
    }

    /// The folder before the first wildcard, e.g. `/Users/me/Documents` for `~/Documents/*.txt`.
    var literalPrefix: String {
        var parts: [String] = []
        for comp in components {
            guard case .name(let t) = comp else { break }
            var name = ""
            for tok in t {
                guard case .char(let ch) = tok else { return "/" + parts.joined(separator: "/") }
                name.append(ch)
            }
            parts.append(name)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Ends in a literal `.pub`, so it only ever names public keys.
    var namesPublicKey: Bool {
        guard case .name(let t)? = components.last, t.count >= 4 else { return false }
        return Array(t.suffix(4)) == [.char("."), .char("p"), .char("u"), .char("b")]
    }

    /// Wildcard match of one name. Like the shell, `*` and `?` don't match a leading dot
    /// unless dot-globbing is on. (A set that lists `.` is allowed to: shells differ there,
    /// and matching too much is the safe side.)
    static func matches(_ tokens: [Token], _ name: String, dotGlob: Bool) -> Bool {
        let n = Array(name.lowercased())
        if n.first == ".", !dotGlob {
            switch tokens.first {
            case .char(".")?, .any?: break
            case .set(let s)? where setMatches(s, "."): break
            default: return false
            }
        }
        // Each character, `?` or set takes one character of the name, so more of them than the
        // name has can't match. Counted first, stopping as soon as that's clear, so a pattern
        // name thousands of characters long is turned down at once.
        var consuming = 0
        var allLiteral = true
        for tok in tokens {
            switch tok {
            case .star, .any: allLiteral = false
            case .char: consuming += 1
            case .one, .set: consuming += 1; allLiteral = false
            }
            if consuming > n.count { return false }
        }
        // All literal (the usual case): a plain comparison.
        if allLiteral {
            guard tokens.count == n.count else { return false }
            for (t, ch) in zip(tokens, n) { if case .char(let c) = t, c != ch { return false } }
            return true
        }
        // Left to right over the tokens, keeping which name positions can be reached: tokens ×
        // name length steps, no recursion (a long run of `*` once recursed once per token).
        var cur = [Bool](repeating: false, count: n.count + 1)
        var next = cur
        cur[0] = true
        var afterWildcard = false
        for tok in tokens {
            switch tok {
            case .star, .any:
                // Runs of `*` match like one.
                if afterWildcard { continue }
                afterWildcard = true
                var seen = false
                for k in cur.indices {
                    if cur[k] { seen = true }
                    cur[k] = seen
                }
            default:
                afterWildcard = false
                for k in next.indices { next[k] = false }
                for k in 0..<n.count where cur[k] {
                    let hit: Bool
                    switch tok {
                    case .one: hit = true
                    case .char(let ch): hit = n[k] == ch
                    case .set(let s): hit = setMatches(s, n[k])
                    case .star, .any: hit = true
                    }
                    if hit { next[k + 1] = true }
                }
                swap(&cur, &next)
                if !cur.contains(true) { return false }
            }
        }
        return cur[n.count]
    }

    /// `[abc]`, `[a-z]`, `[!x]`; character classes like `[[:alpha:]]` match anything.
    static func setMatches(_ set: String, _ ch: Character) -> Bool {
        var s = Array(set)
        var negate = false
        if let f = s.first, f == "!" || f == "^" { negate = true; s.removeFirst() }
        if String(s).contains("[:") { return true }
        var hit = false
        var i = 0
        while i < s.count {
            if i + 2 < s.count, s[i + 1] == "-" {
                if let lo = s[i].unicodeScalars.first?.value, let hi = s[i + 2].unicodeScalars.first?.value,
                   let v = ch.unicodeScalars.first?.value, lo <= v, v <= hi { hit = true }
                i += 3
            } else {
                if s[i] == ch { hit = true }
                i += 1
            }
        }
        return hit != negate
    }
}
