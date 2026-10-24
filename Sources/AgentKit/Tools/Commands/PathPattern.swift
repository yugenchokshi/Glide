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
        /// zsh's `**/`: zero or more folders.
        case anyDepth
    }

    /// From the root folder down; never contains `.` or `..`.
    var components: [Component]
    /// Some part comes from a variable or command output rather than only from a glob.
    var dynamic: Bool

    // MARK: Building

    /// Patterns for `text` (already free of the anchor: it starts with `/` or is empty)
    /// appended to `base`. With `glob`, unquoted `*`, `?`, `[…]`, `{a,b}` and zsh `(…)` are
    /// wildcards; `extendedGlob` adds zsh's `^`, `#` and `~`. Run-time parts (`$x`, `$(…)`,
    /// backticks) are wildcards either way. Nil when brace expansion would produce too many
    /// alternatives to check.
    static func make(base: [Component], text: String, glob: Bool, extendedGlob: Bool) -> [PathPattern]? {
        guard let alternatives = glob ? expandBraces(text) : [text] else { return nil }
        return alternatives.map { alt in
            var dynamic = false
            let tokens = tokenize(alt, glob: glob, extendedGlob: extendedGlob, dynamic: &dynamic)
            var comps = base
            var current: [Token] = []
            var pending = false
            func flush() {
                defer { current = []; pending = false }
                guard pending else { return }
                if current == [.char(".")] { return }
                if current == [.char("."), .char(".")] {
                    if !comps.isEmpty { comps.removeLast() }
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
            return PathPattern(components: comps, dynamic: dynamic)
        }
    }

    /// Components of a fixed absolute path.
    static func literalComponents(_ path: String) -> [Component] {
        path.split(separator: "/").map { .name($0.lowercased().map { .char($0) }) }
    }

    /// Expands `{a,b}` alternatives (zsh and bash brace expansion). `{1..9}` ranges become
    /// `*`; braces without a comma stay literal, as zsh leaves them. `${…}` is skipped.
    static func expandBraces(_ text: String, limit: Int = 64) -> [String]? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "{" {
                i = matchingClose(chars, from: i + 1, open: "{", close: "}") + 1
                continue
            }
            guard chars[i] == "{" else { i += 1; continue }
            let end = matchingClose(chars, from: i, open: "{", close: "}")
            guard end < chars.count else { return [text] }
            let inner = Array(chars[(i + 1)..<end])
            var parts: [String] = []
            var depth = 0
            var piece = ""
            for ch in inner {
                if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
                if ch == ",", depth == 0 { parts.append(piece); piece = ""; continue }
                piece.append(ch)
            }
            parts.append(piece)
            let prefix = String(chars[..<i]), suffix = String(chars[(end + 1)...])
            if parts.count == 1 {
                if String(inner).contains("..") {
                    return expandBraces(prefix + "*" + suffix, limit: limit)
                }
                // Literal braces: keep them and look further on.
                i = end + 1
                continue
            }
            var out: [String] = []
            for p in parts {
                guard let more = expandBraces(prefix + p + suffix, limit: limit) else { return nil }
                out += more
                if out.count > limit { return nil }
            }
            return out
        }
        return [text]
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

    /// Could some name the shell produces be inside `root` (or `root` itself)?
    func mayReachInside(_ root: String, dotGlob: Bool) -> Bool {
        let target = root.lowercased().split(separator: "/").map(String.init)
        func reach(_ pi: Int, _ ti: Int) -> Bool {
            if ti == target.count { return true }
            guard pi < components.count else { return false }
            switch components[pi] {
            case .anyDepth: return reach(pi + 1, ti) || reach(pi, ti + 1)
            case .name(let t): return Self.matches(t, target[ti], dotGlob: dotGlob) && reach(pi + 1, ti + 1)
            }
        }
        return reach(0, 0)
    }

    /// Could some name the shell produces be exactly `path`? A nil component in `path` stands
    /// for any name (`/Users/<anyone>`).
    func mayBe(_ path: [String?], dotGlob: Bool) -> Bool {
        let target = path.map { $0?.lowercased() }
        func exact(_ pi: Int, _ ti: Int) -> Bool {
            guard pi < components.count else { return ti == target.count }
            switch components[pi] {
            case .anyDepth: return exact(pi + 1, ti) || (ti < target.count && exact(pi, ti + 1))
            case .name(let t):
                guard ti < target.count else { return false }
                if let name = target[ti], !Self.matches(t, name, dotGlob: dotGlob) { return false }
                return exact(pi + 1, ti + 1)
            }
        }
        return exact(0, 0)
    }

    func mayBe(_ path: String, dotGlob: Bool) -> Bool {
        mayBe(path.split(separator: "/").map { String($0) }, dotGlob: dotGlob)
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
        // memo[ti][ni]: tokens[ti...] can match n[ni...]
        var memo = [[Bool?]](repeating: [Bool?](repeating: nil, count: n.count + 1), count: tokens.count + 1)
        func go(_ ti: Int, _ ni: Int) -> Bool {
            if let m = memo[ti][ni] { return m }
            let r: Bool
            if ti == tokens.count {
                r = ni == n.count
            } else {
                switch tokens[ti] {
                case .star, .any:
                    r = go(ti + 1, ni) || (ni < n.count && go(ti, ni + 1))
                case .one:
                    r = ni < n.count && go(ti + 1, ni + 1)
                case .char(let ch):
                    r = ni < n.count && n[ni] == ch && go(ti + 1, ni + 1)
                case .set(let s):
                    r = ni < n.count && setMatches(s, n[ni]) && go(ti + 1, ni + 1)
                }
            }
            memo[ti][ni] = r
            return r
        }
        return go(0, 0)
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
