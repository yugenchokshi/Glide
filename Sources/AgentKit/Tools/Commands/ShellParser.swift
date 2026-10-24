import Foundation

// A small, deliberately conservative zsh/bash parser used only for safety checks. It does not
// try to execute or fully understand shell grammar; it only needs to find every *simple
// command* the line could run — including ones hidden in `$(…)`, backticks, `<(…)`, subshells,
// `sh -c` strings and here-documents — together with its words and redirections. When the
// grammar gets ambiguous it errs toward producing extra commands (which can only raise risk),
// never toward hiding one.

/// One word after quote removal. Expansions the checker cannot resolve stay in `text` as
/// written (`$x`, `$(…)`), so a `$` in `text` means "depends on run time".
struct ShellWord: Sendable, Hashable {
    var text = ""
    /// Command lists nested in this word: `$(…)`, backticks, `<(…)`, `>(…)`, and any found
    /// inside `${…}`.
    var substitutions: [ShellList] = []
    /// True when any part of the word was quoted (so it can't be an operator or keyword).
    var quoted = false
    /// An unquoted glob character (`*`, `?`, `[`, `{`, zsh's `(…)`, `^`, `#`) is in the word,
    /// so the shell may turn it into other names at run time. The safety checks then match it
    /// as a pattern instead of comparing its text.
    var globbed = false
    /// Raw text of zsh `(…)` groups written right after a word (`*(e:'cmd':)`, `*.(a|b)`):
    /// glob qualifiers or alternatives, never a subshell. Qualifiers can run code.
    var qualifiers: [String] = []
}

struct ShellRedirect: Sendable, Hashable {
    /// The operator: `>`, `>>`, `>|`, `&>`, `&>>`, `<>`, `>&`, `<`, `<&`, `<<<`.
    var op: String
    var target: ShellWord

    /// True when the redirection opens a file for writing (dups like `2>&1` don't).
    var isWrite: Bool {
        switch op {
        case ">", ">>", ">|", "&>", "&>>", "<>": return true
        case ">&": return !(target.text == "-" || target.text.allSatisfy(\.isNumber))
        default: return false
        }
    }
}

struct ShellCommand: Sendable, Hashable {
    var id: Int
    var words: [ShellWord] = []
    var redirects: [ShellRedirect] = []
    /// Bodies of `( … )` subshells written where a command starts.
    var groups: [ShellList] = []
    /// Here-document body (`<<EOF … EOF`), if any.
    var heredoc: String?
    /// Here-string (`<<< text`), if any.
    var hereString: ShellWord?
    /// The command is `(( … ))`, which evaluates arithmetic (and, through array subscripts,
    /// can run command text stored in a variable).
    var arithmetic = false
    /// The raw expression text of a `(( … ))` command, so the checker can see which variables
    /// it reads (`(( x ))` reads `x`, whose value zsh re-evaluates as an arithmetic expression).
    var arithmeticText: String?

    var isEmpty: Bool { words.isEmpty && redirects.isEmpty && groups.isEmpty && hereString == nil && !arithmetic }
}

struct ShellPipeline: Sendable, Hashable {
    var commands: [ShellCommand] = []
}

struct ShellList: Sendable, Hashable {
    var pipelines: [ShellPipeline] = []
}

struct ShellParse: Sendable {
    var list: ShellList
    /// Nesting went deeper than the checker follows; the caller treats the line as high risk.
    var tooComplex: Bool
}

final class ShellParser {
    private let c: [Character]
    private var i = 0
    private var nextID: Int
    private var depth = 0
    private(set) var tooComplex = false
    private var heredocBodies: [Int: String] = [:]
    private var pendingHeredocs: [(id: Int, delimiter: String, stripTabs: Bool)] = []

    /// Deeper nesting than this is reported as `tooComplex` rather than followed.
    static let maxDepth = 16

    private init(_ text: String, depth: Int, firstID: Int) {
        self.c = Array(text)
        self.depth = depth
        self.nextID = firstID
    }

    static func parse(_ text: String) -> ShellParse {
        let p = ShellParser(text, depth: 0, firstID: 0)
        var list = p.parseList(until: nil)
        p.attachHeredocs(&list)
        return ShellParse(list: list, tooComplex: p.tooComplex)
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let j = i + offset
        return j < c.count ? c[j] : nil
    }

    private func newCommand() -> ShellCommand {
        nextID += 1
        return ShellCommand(id: nextID)
    }

    // MARK: Lists, pipelines, commands

    private struct WordBuffer {
        var word = ShellWord()
        var started = false
        mutating func append(_ ch: Character) { word.text.append(ch); started = true }
        mutating func append(_ s: String) { word.text += s; started = true }
    }

    private func parseList(until close: Character?) -> ShellList {
        var list = ShellList()
        var pipeline = ShellPipeline()
        var cmd = newCommand()
        var buf = WordBuffer()
        var pendingOp: String?

        func endWord() {
            guard buf.started else { return }
            let w = buf.word
            buf = WordBuffer()
            if let op = pendingOp {
                pendingOp = nil
                switch op {
                case "<<", "<<-":
                    pendingHeredocs.append((cmd.id, w.text, op == "<<-"))
                    // Keep any substitution written in the delimiter so nothing nested is lost.
                    if !w.substitutions.isEmpty { cmd.words.append(ShellWord(text: "", substitutions: w.substitutions)) }
                case "<<<":
                    cmd.hereString = w
                default:
                    cmd.redirects.append(ShellRedirect(op: op, target: w))
                }
            } else {
                cmd.words.append(w)
            }
        }
        func endCommand() {
            endWord()
            pendingOp = nil
            if !cmd.isEmpty { pipeline.commands.append(cmd) }
            cmd = newCommand()
        }
        func endPipeline() {
            endCommand()
            if !pipeline.commands.isEmpty { list.pipelines.append(pipeline) }
            pipeline = ShellPipeline()
        }

        while i < c.count {
            let ch = c[i]
            switch ch {
            case " ", "\t", "\r":
                endWord(); i += 1
            case "\n":
                endPipeline(); i += 1
                readHeredocBodies()
            case "#" where !buf.started:
                // Inside parentheses a `#` may be glob text (zsh's `ls (#x|*)`), not a
                // comment, so stop at `)` rather than hide what follows on the line.
                while i < c.count, c[i] != "\n", !(close == ")" && c[i] == ")") { i += 1 }
            case ";":
                endPipeline(); i += 1
                if let n = peek(), n == ";" || n == "&" || n == "|" { i += 1 } // ;; ;& ;| in case
            case "&":
                if peek(1) == "&" { endPipeline(); i += 2 }
                else if peek(1) == ">" {
                    endWord()
                    if peek(2) == ">" { pendingOp = "&>>"; i += 3 } else { pendingOp = "&>"; i += 2 }
                } else { endPipeline(); i += 1 }
            case "|":
                if peek(1) == "|" { endPipeline(); i += 2 }
                else { endCommand(); i += (peek(1) == "&" ? 2 : 1) }
            case "<", ">":
                // A word made only of digits right before the operator is a file descriptor (2>).
                if buf.started, !buf.word.quoted, buf.word.substitutions.isEmpty, !buf.word.text.isEmpty, buf.word.text.allSatisfy(\.isNumber) {
                    buf = WordBuffer()
                } else {
                    endWord()
                }
                readRedirect(&buf, &pendingOp)
            case "(":
                if buf.started {
                    if buf.word.text == "=" && !buf.word.quoted {
                        // zsh's =(list): runs the list and passes a temporary file of its output.
                        i += 1
                        let inner = nested { parseList(until: ")") }
                        buf.append("(…)")
                        if let inner { buf.word.substitutions.append(inner) }
                        continue
                    }
                    if buf.word.text.hasSuffix("=") {
                        // Array assignment a=( … ): keep as text, but still find substitutions.
                        // Step past "(" first, or the rest of the line would be swallowed.
                        i += 1
                        let inner = readBalanced(open: "(", close: ")")
                        buf.append("(" + inner + ")")
                        buf.word.substitutions += scanSubstitutions(inner)
                        continue
                    }
                    if peek(1) != ")", !cmd.words.isEmpty || buf.word.globbed {
                        // Parentheses glued to an argument are part of a zsh glob pattern
                        // (`*.(jpg|png)`, `*(.)`, `*(e:'cmd':)`), not a subshell; bash rejects
                        // them. Keep them in the word and let the checker read the qualifiers.
                        i += 1
                        let inner = readBalanced(open: "(", close: ")")
                        buf.append("(" + inner + ")")
                        buf.word.globbed = true
                        buf.word.qualifiers.append(inner)
                        buf.word.substitutions += scanSubstitutions(inner)
                        continue
                    }
                    endWord()
                    // name() function definition: the body that follows is its own command.
                    if peek(1) == ")" { i += 2; endPipeline(); continue }
                }
                if cmd.words.isEmpty && peek(1) == "(" {
                    // (( arithmetic )) — evaluates numbers; look only for substitutions inside.
                    i += 2
                    let inner = readBalanced(open: "(", close: ")")
                    if peek() == ")" { i += 1 }
                    cmd.arithmetic = true
                    cmd.arithmeticText = inner
                    let subs = scanSubstitutions(inner)
                    if !subs.isEmpty { cmd.words.append(ShellWord(text: "", substitutions: subs)) }
                    continue
                }
                i += 1
                if let inner = nested({ parseList(until: ")") }) { cmd.groups.append(inner) }
            case ")":
                if close == ")" { i += 1; endPipeline(); return list }
                // Stray ")" (e.g. a case pattern): treat as a separator, never as text.
                endPipeline(); i += 1
            case "'":
                buf.started = true; buf.word.quoted = true
                i += 1
                while i < c.count, c[i] != "'" { buf.append(c[i]); i += 1 }
                i += 1
            case "\"":
                readDoubleQuoted(&buf)
            case "\\":
                if peek(1) == "\n" { i += 2 }
                else if let n = peek(1) { buf.append(n); buf.word.quoted = true; i += 2 }
                else { i += 1 }
            case "`":
                readBacktick(&buf)
            case "$":
                readDollar(&buf)
            default:
                if "*?[{^#".contains(ch) { buf.word.globbed = true }
                buf.append(ch); i += 1
            }
        }
        endPipeline()
        return list
    }

    /// Runs a nested parse unless nesting is already too deep.
    private func nested<T>(_ body: () -> T) -> T? {
        if depth >= Self.maxDepth {
            tooComplex = true
            // Skip to the end so the outer parse doesn't misread the rest as commands it can see.
            i = c.count
            return nil
        }
        depth += 1
        defer { depth -= 1 }
        return body()
    }

    /// Reads a redirection operator at `c[i]` (the word before it was already ended). Process
    /// substitutions `<(…)`/`>(…)` start a new word in `buf` instead.
    private func readRedirect(_ buf: inout WordBuffer, _ pendingOp: inout String?) {
        let ch = c[i]
        if ch == "<" {
            if peek(1) == "(" { readProcessSubstitution(&buf, prefix: "<("); return }
            if peek(1) == "<" {
                if peek(2) == "<" { pendingOp = "<<<"; i += 3; return }
                if peek(2) == "-" { pendingOp = "<<-"; i += 3; return }
                pendingOp = "<<"; i += 2; return
            }
            if peek(1) == ">" { pendingOp = "<>"; i += 2; return }
            if peek(1) == "&" { pendingOp = "<&"; i += 2; return }
            pendingOp = "<"; i += 1; return
        }
        // ">"
        if peek(1) == "(" { readProcessSubstitution(&buf, prefix: ">("); return }
        if peek(1) == ">" { pendingOp = ">>"; i += 2; if peek() == "|" || peek() == "!" { i += 1 }; return }
        if peek(1) == "|" || peek(1) == "!" { pendingOp = ">|"; i += 2; return }
        if peek(1) == "&" { pendingOp = ">&"; i += 2; return }
        pendingOp = ">"; i += 1
    }

    private func readProcessSubstitution(_ buf: inout WordBuffer, prefix: String) {
        i += 2
        let inner = nested { parseList(until: ")") }
        buf.append(prefix + "…)")
        if let inner { buf.word.substitutions.append(inner) }
    }

    // MARK: Quotes and expansions

    private func readDoubleQuoted(_ buf: inout WordBuffer) {
        buf.started = true
        buf.word.quoted = true
        i += 1
        while i < c.count, c[i] != "\"" {
            let ch = c[i]
            if ch == "\\", let n = peek(1), "$`\"\\\n".contains(n) {
                if n != "\n" { buf.append(n) }
                i += 2
            } else if ch == "$" {
                readDollar(&buf)
            } else if ch == "`" {
                readBacktick(&buf)
            } else {
                buf.append(ch); i += 1
            }
        }
        i += 1
    }

    private func readBacktick(_ buf: inout WordBuffer) {
        i += 1
        var inner = ""
        while i < c.count, c[i] != "`" {
            if c[i] == "\\", let n = peek(1) { inner.append(n); i += 2 } else { inner.append(c[i]); i += 1 }
        }
        i += 1
        buf.append("`…`")
        if depth >= Self.maxDepth { tooComplex = true; return }
        let child = makeChild(inner)
        var sub = child.parseList(until: nil)
        child.attachHeredocs(&sub)
        adopt(child)
        buf.word.substitutions.append(sub)
    }

    private func readDollar(_ buf: inout WordBuffer) {
        let next = peek(1)
        if next == "(" && peek(2) == "(" {
            i += 3
            let inner = readBalanced(open: "(", close: ")")
            if peek() == ")" { i += 1 }
            buf.append("$((" + inner + "))")
            buf.word.substitutions += scanSubstitutions(inner)
        } else if next == "(" {
            i += 2
            let inner = nested { parseList(until: ")") }
            buf.append("$(…)")
            if let inner { buf.word.substitutions.append(inner) }
        } else if next == "{" {
            i += 2
            let inner = readBalanced(open: "{", close: "}")
            buf.append("${" + inner + "}")
            buf.word.substitutions += scanSubstitutions(inner)
        } else if next == "'" {
            // $'…' ANSI-C quoting can spell any program name with escapes; keep the `$` so the
            // word counts as run-time dependent.
            i += 2
            var raw = ""
            while i < c.count, c[i] != "'" {
                if c[i] == "\\", let n = peek(1) { raw.append(c[i]); raw.append(n); i += 2 } else { raw.append(c[i]); i += 1 }
            }
            i += 1
            buf.append("$'" + raw + "'")
        } else if let n = next, n.isLetter || n.isNumber || n == "_" || "?#@*!$-".contains(n) {
            i += 1
            var name = ""
            if n.isLetter || n == "_" {
                while let ch = peek(), ch.isLetter || ch.isNumber || ch == "_" { name.append(ch); i += 1 }
            } else {
                name.append(n); i += 1
            }
            buf.append("$" + name)
        } else {
            buf.append("$"); i += 1
        }
    }

    /// Reads up to the matching close character (the opener was already consumed), honoring
    /// quotes. Leaves `i` after the close character.
    private func readBalanced(open: Character, close: Character) -> String {
        var level = 1
        var out = ""
        var quote: Character?
        while i < c.count {
            let ch = c[i]
            if let q = quote {
                if ch == "\\" && q == "\"", let n = peek(1) { out.append(ch); out.append(n); i += 2; continue }
                if ch == q { quote = nil }
                out.append(ch); i += 1; continue
            }
            if ch == "'" || ch == "\"" { quote = ch; out.append(ch); i += 1; continue }
            if ch == "\\", let n = peek(1) { out.append(ch); out.append(n); i += 2; continue }
            if ch == open { level += 1 }
            if ch == close {
                level -= 1
                if level == 0 { i += 1; return out }
            }
            out.append(ch); i += 1
        }
        return out
    }

    /// Finds command substitutions inside text that is otherwise not a command (the inside of
    /// `${…}`, arithmetic, array literals) by reading it like a double-quoted string.
    private func scanSubstitutions(_ text: String) -> [ShellList] {
        guard text.contains("$(") || text.contains("`") || text.contains("<(") || text.contains(">(") || text.contains("=(") else { return [] }
        if depth >= Self.maxDepth { tooComplex = true; return [] }
        let p = makeChild(text)
        var buf = WordBuffer()
        while p.i < p.c.count {
            let ch = p.c[p.i]
            if ch == "$" { p.readDollar(&buf) }
            else if ch == "`" { p.readBacktick(&buf) }
            else if (ch == "<" || ch == ">") && p.peek(1) == "(" { p.readProcessSubstitution(&buf, prefix: String(ch) + "(") }
            // zsh's =(list) at the start of an array element runs the list too.
            else if ch == "=" && p.peek(1) == "(" && (p.i == 0 || " \t\n(".contains(p.c[p.i - 1])) { p.readProcessSubstitution(&buf, prefix: "=(") }
            else if ch == "\\" { p.i += 2 }
            else { p.i += 1 }
        }
        var subs = buf.word.substitutions
        for k in subs.indices { p.attachHeredocs(&subs[k]) }
        adopt(p)
        return subs
    }

    /// A parser for nested text (backticks, `${…}`) that continues this parser's command ids,
    /// so a here-document body can never attach to a command at another nesting level.
    private func makeChild(_ text: String) -> ShellParser {
        ShellParser(text, depth: depth + 1, firstID: nextID)
    }

    private func adopt(_ child: ShellParser) {
        nextID = max(nextID, child.nextID)
        if child.tooComplex { tooComplex = true }
    }

    // MARK: Here-documents

    private func readHeredocBodies() {
        guard !pendingHeredocs.isEmpty else { return }
        let pending = pendingHeredocs
        pendingHeredocs = []
        for h in pending {
            var lines: [String] = []
            while i < c.count {
                var line = ""
                while i < c.count, c[i] != "\n" { line.append(c[i]); i += 1 }
                if i < c.count { i += 1 } // newline
                let cmp = h.stripTabs ? String(line.drop { $0 == "\t" }) : line
                if cmp == h.delimiter { break }
                lines.append(line)
            }
            heredocBodies[h.id] = lines.joined(separator: "\n")
        }
    }

    private func attachHeredocs(_ list: inout ShellList) {
        guard !heredocBodies.isEmpty else { return }
        for p in list.pipelines.indices {
            for k in list.pipelines[p].commands.indices {
                var cmd = list.pipelines[p].commands[k]
                if let body = heredocBodies[cmd.id] { cmd.heredoc = body }
                for g in cmd.groups.indices { attachHeredocs(&cmd.groups[g]) }
                for w in cmd.words.indices {
                    for s in cmd.words[w].substitutions.indices { attachHeredocs(&cmd.words[w].substitutions[s]) }
                }
                for r in cmd.redirects.indices {
                    for s in cmd.redirects[r].target.substitutions.indices { attachHeredocs(&cmd.redirects[r].target.substitutions[s]) }
                }
                list.pipelines[p].commands[k] = cmd
            }
        }
    }
}
