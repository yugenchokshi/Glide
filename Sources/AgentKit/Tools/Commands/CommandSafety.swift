import Foundation

/// Deterministic risk assessment for shell commands, run before every `shell.run` call.
///
/// The command is parsed (see `ShellParser`) into every simple command it could execute,
/// including ones hidden in substitutions, subshells, `sh -c` strings, `eval`, `find -exec`,
/// `xargs` and here-documents. Each one is judged by its program and flags, each write
/// redirection by where it lands, and pipelines as a whole (downloads piped into a shell).
/// Paths are matched the way the shell will expand them (globs, braces, variables set
/// earlier on the line), and environment variables that make a program run a command or
/// load code count like running it.
/// The highest risk wins:
/// - `.low`: can't change anything (ls, cat, grep, git status, curl that only fetches…)
/// - `.medium`: changes local files or settings in the home folder (mv, cp, git commit, installs…)
/// - `.high`: deletes, sends, uploads, kills, changes security, or writes outside home and /tmp
/// - `blocked`: never runs (sudo, wiping disks or the home folder, curl | sh, fork bombs…)
///
/// Anything the checker can't see through — a program name chosen at run time, `eval` of
/// built-up text — is treated as high, so being clever with the shell never lowers the risk.
public enum CommandSafety {
    /// Assesses `command` as if run from the home folder.
    public static func assess(_ command: String) -> ToolVerdict { assess(command, cwd: nil) }

    /// Assesses `command` run from `cwd` (relative paths resolve against it; nil = home).
    public static func assess(_ command: String, cwd: String?, home: String = PathRules.home) -> ToolVerdict {
        analyze(command, cwd: cwd, home: home).verdict
    }

    /// What `analyze` found besides the verdict.
    struct Analysis: Sendable {
        var verdict: ToolVerdict
        /// The (lowercased) names of every program the line runs, so callers can apply
        /// per-program settings (e.g. AppleScript turned off also covers `osascript`).
        var programs: Set<String>
        /// Some command may read the clipboard, so `shell.run` refuses it while a concealed item
        /// is there, the way `clipboard.read` does (that needs the pasteboard, which only the
        /// tool can look at).
        var readsClipboard: Bool
        /// A script interpreter runs code Glide can't fully see (inline code, a script file,
        /// standard input) and so could reach the clipboard through a name built at run time.
        var runsScript: Bool
        /// Work the check took, in `ShellRiskChecker.workLimit` units.
        var work = 0
    }

    /// Stack for the thread the checker runs on. The walk recurses through nested commands
    /// (bounded by `ShellRiskChecker.maxDepth`), and a debug build's frames are large enough to
    /// overflow the 512 KB of a Swift concurrency thread; a thread of its own can't.
    static let analysisStackSize = 32 << 20
    /// How long a caller waits for the checker before failing closed. Analysis is linear and
    /// budgeted, so this is a backstop no real command gets near.
    static let analysisTimeout: Double = 20

    /// Checks `command` on a thread with a large stack; fails closed to high if that thread
    /// doesn't answer in time.
    static func analyze(_ command: String, cwd: String?, home: String = PathRules.home) -> Analysis {
        let fallback = Analysis(verdict: ToolVerdict(risk: .high, reasons: ["too complex to check"], summary: summaryText(command)),
                                programs: [], readsClipboard: true, runsScript: true)
        return onLargeStack { analyzeHere(command, cwd: cwd, home: home) } ?? fallback
    }

    /// `analyze` on the calling thread.
    static func analyzeHere(_ command: String, cwd: String?, home: String) -> Analysis {
        let summary = summaryText(command)
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        func done(_ v: ToolVerdict) -> Analysis { Analysis(verdict: v, programs: [], readsClipboard: false, runsScript: false) }
        if trimmed.isEmpty { return done(ToolVerdict(risk: .low, summary: summary)) }
        if trimmed.unicodeScalars.count > 200_000 {
            return done(ToolVerdict(risk: .high, reasons: ["command too long to check"],
                                    blocked: "This command is too long for Glide to check safely. Put it in a script file instead.", summary: summary))
        }
        if trimmed.contains("\u{0}") {
            return done(ToolVerdict(risk: .high, reasons: ["contains a NUL character"], blocked: "This command contains invalid characters.", summary: summary))
        }
        let parse = ShellParser.parse(trimmed)
        var checker = ShellRiskChecker(home: PathRules.normalize(home), cwd: PathRules.normalize(cwd ?? home))
        // Shell options that widen what globs match, set anywhere on the line (zsh ignores case
        // and underscores in option names: GLOB_DOTS, globdots, glob_dots).
        let options = trimmed.lowercased().replacingOccurrences(of: "_", with: "")
        checker.dotGlob = options.contains("globdots") || options.contains("dotglob")
        checker.extendedGlob = options.contains("extendedglob") || options.contains("extglob")
        if parse.tooComplex { checker.acc.raise(.high, "nested too deeply to check") }
        checker.check(parse.list, depth: 0)
        checker.finish()
        let verdict = ToolVerdict(risk: checker.acc.risk, reasons: checker.acc.reasons, blocked: checker.acc.blocked, summary: summary)
        return Analysis(verdict: verdict, programs: checker.programs, readsClipboard: checker.readsClipboard, runsScript: checker.runsScriptCode,
                        work: checker.work)
    }

    /// Runs `body` on a thread with `analysisStackSize` of stack and waits for it; nil when it
    /// doesn't finish within `analysisTimeout`.
    static func onLargeStack<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T? {
        let box = AnalysisResultBox<T>()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.set(body())
            finished.signal()
        }
        thread.stackSize = analysisStackSize
        thread.qualityOfService = .userInitiated
        thread.start()
        guard finished.wait(timeout: .now() + analysisTimeout) == .success else { return nil }
        return box.get()
    }

    /// Applies the Settings › Speed & Commands access level to a verdict. `.off` blocks
    /// everything; `.readOnly` blocks anything above `.low`; `.full` keeps the verdict.
    public static func applying(_ access: CommandAccess, to verdict: ToolVerdict) -> ToolVerdict {
        var v = verdict
        switch access {
        case .full:
            break
        case .off:
            v.blocked = v.blocked ?? "Commands are turned off. You can allow them in Settings › Speed & Commands."
        case .readOnly:
            if v.blocked == nil, v.risk > .low {
                let why = v.reasons.isEmpty ? "it can change things" : v.reasons.joined(separator: ", ")
                v.blocked = "Glide is set to read-only commands, and this one can change things (\(why)). You can allow it in Settings › Speed & Commands."
            }
        }
        return v
    }

    /// "Run `ls -la ~/Desktop`", shortened to one line for approval cards and logs.
    public static func summaryText(_ command: String) -> String {
        var one = command.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ ")
        if one.count > 160 { one = String(one.prefix(157)) + "…" }
        return "Run `\(one)`"
    }

}

/// Hands a value from the checker's thread back to the caller.
private final class AnalysisResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    func set(_ value: T) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Collects the highest risk, its reasons and the first block message.
struct RiskAccumulator {
    var risk: RiskLevel = .low
    var reasons: [String] = []
    var blocked: String?
    /// Reasons already listed, so a line with thousands of operands stays linear.
    private var seen: Set<String> = []

    /// More reasons than an approval card can usefully show; the risk still counts the rest.
    static let maxReasons = 16

    mutating func raise(_ level: RiskLevel, _ reason: String? = nil) {
        if level > risk { risk = level }
        if let reason, reasons.count < Self.maxReasons, seen.insert(reason).inserted { reasons.append(reason) }
    }

    mutating func block(_ message: String, reason: String? = nil) {
        raise(.high, reason)
        if blocked == nil { blocked = message }
    }
}

/// Walks a parsed command line and applies the rules. Value type: one per assessment.
struct ShellRiskChecker {
    let home: String
    /// Current directory for relative paths; nil once a `cd` went somewhere unknowable.
    var cwd: String?
    var acc = RiskAccumulator()
    /// Files a download wrote earlier in the same line (`curl -o x.sh … && sh x.sh`).
    var downloadedFiles: Set<String> = []
    /// Every program the line runs, by lowercased base name.
    var programs: Set<String> = []
    /// Folder before the last `cd`, for `cd -` and zsh's `~-`.
    var oldCwd: String?
    /// Set when `cd` went to a glob or a partly run-time path: the folders it may be in.
    var cwdPatterns: [PathPattern]?
    /// Extra folders a relative path may be under because a `cd` might not have taken effect (a
    /// missing folder, a file, a `cd` in a pipeline) and nothing stopped the next command from
    /// running anyway: the folders the shell was in before the cd.
    var cwdAlternates: [PathPattern] = []
    /// Folders a `cd` joined by `&&` left behind: if it failed, the rest of the `&&` chain never
    /// runs, so they come back (into `cwdAlternates`) only once the chain ends (`;`, `||`, `&`…).
    var cwdIfChainFailed: [PathPattern] = []
    /// Folder tracking gave up (too many folders, or a path too deep to follow): relative paths
    /// could be anywhere from here on.
    var cwdLost = false
    /// Texts of words with unquoted glob characters (see `ShellWord.globbed`).
    var globbedTexts: Set<String> = []
    /// Texts of words with a zsh `(D)` qualifier, whose wildcards also match hidden names.
    var dotQualifiedTexts: Set<String> = []
    /// Variables the line set to fixed text (`d=~/.ssh`), so `$d/x` can be judged as a path.
    var vars: [String: String] = [:]
    /// The line turns on `GLOB_DOTS`/`dotglob` or extended globbing somewhere.
    var dotGlob = false
    var extendedGlob = false
    /// Command text written as quoted data (`'$(cmd)'`), and whether the line evaluates
    /// arithmetic, which runs such text through array subscripts (see `finish`).
    var literalCode: [String] = []
    static let maxLiteralCode = 32
    var arithmetic = false
    /// A command substitution feeds an arithmetic evaluation (`(( $(cmd) ))`), and whether that
    /// substitution downloads — zsh and bash run the substitution and then evaluate its output
    /// as an arithmetic expression, where `a[$(cmd2)]` runs another command.
    var arithmeticHasSubstitution = false
    var arithmeticSubDownloads = false
    /// Variables whose value came from command output (`x=$(cmd)`), `read`, or `printf -v` —
    /// only known at run time — and the subset filled from a download.
    var runtimeVars: Set<String> = []
    var downloadVars: Set<String> = []
    /// Names every arithmetic expression on the line reads (see `arithmeticNames`).
    var arithmeticReads: Set<String> = []
    /// The line re-evaluates a value as shell text (`${(e)x}`, `${x@P}`).
    var evaluatesStrings = false
    /// Some command may read the clipboard (`pbpaste`, `osascript -e 'the clipboard'`).
    var readsClipboard = false
    /// Some word or here-document mentions the clipboard; it counts once a script runs.
    var mentionsClipboard = false
    /// A script interpreter runs code that isn't all visible here (see `Analysis.runsScript`).
    var runsScriptCode = false
    /// How many loops (`while`, `for`, `repeat`, `watch`, `find -exec`…) the current command is
    /// inside, and whether a clipboard reader ran inside one or after a `sleep`.
    var loopDepth = 0
    var clipboardReaderRepeats = false
    /// `test`/`[` evaluate their operands as arithmetic: true in ksh (and shells like it), not
    /// in zsh or bash, so it's set once such a shell runs text from the line.
    var testIsArithmetic = false
    /// Function (and alias) names defined on the line, for spotting one that pipes into itself
    /// and a redefined `cd`.
    var functionNames: Set<String> = []
    /// A compound command (`if`, a loop, a function…) appeared: code after it may have skipped
    /// code before it, so `cd x || exit` no longer proves where later commands run.
    var sawStructure = false
    /// Work done so far, in units of about four characters read or one path comparison. Past
    /// `workLimit` the rest of the line isn't checked and the verdict is high ("too complex to
    /// check"), so even a line built to be slow (nesting that re-reads text, thousands of
    /// globs) is answered in about a second, deterministically.
    var work = 0

    static let maxDepth = 24
    static let workLimit = 500_000
    /// Most folders a relative path is matched under at once (after `cd` into globs, or
    /// `cd`s that may have failed); more means folder tracking gives up and fails closed.
    static let maxFolders = 16
    /// Most patterns one word is matched as; more is treated as "could be anywhere".
    static let maxPatterns = 128
    /// Deepest folder tracked after `cd` (macOS paths stop at 1024 bytes anyway).
    static let maxFolderLength = 4096

    static let downloadIntoShell = "Glide won't run downloaded content straight in a shell or interpreter. Download it, read it, then run it as a separate step."

    /// Protected folders, split once (`PathPattern.splitPath`) for the matchers.
    let secretRootParts: [(path: String, parts: [String])]
    let sensitiveRootParts: [(path: String, parts: [String])]
    let criticalTargets: [[String?]]
    let homeLibraryParts: [String?]
    let keychainParts: [[String]]

    init(home: String, cwd: String) {
        self.home = home
        self.cwd = cwd
        let secret = PathRules.secretRoots(home: home)
        secretRootParts = secret.map { ($0, PathPattern.splitPath($0)) }
        sensitiveRootParts = (secret + PathRules.persistenceRoots(home: home)).map { ($0, PathPattern.splitPath($0)) }
        let anyone: [[String?]] = [[], ["users", nil], ["volumes", nil]]
        let folders = ["/system", "/library", "/applications", "/users", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/private/var",
                       "/private/etc", "/opt", "/volumes", "/cores", "/dev", home]
        criticalTargets = anyone + folders.map { PathPattern.splitPath($0).map { Optional($0) } }
        homeLibraryParts = PathPattern.splitPath(home + "/Library").map { Optional($0) }
        keychainParts = [PathPattern.splitPath(home + "/Library/Keychains"), PathPattern.splitPath("/Library/Keychains")]
    }

    // MARK: Walking

    /// Counts work against `workLimit`; false (and high, "too complex to check") once spent.
    mutating func spend(_ amount: Int) -> Bool {
        work += amount
        guard work > Self.workLimit else { return true }
        acc.raise(.high, "too complex to check")
        return false
    }

    var outOfWork: Bool { work > Self.workLimit }

    /// The folders relative paths resolve against, saved around a subshell (`( … )`, `$( … )`):
    /// a `cd` inside one never moves the shell outside it.
    struct FolderState {
        var cwd: String?
        var cwdPatterns: [PathPattern]?
        var cwdAlternates: [PathPattern]
        var cwdIfChainFailed: [PathPattern]
        var oldCwd: String?
        var cwdLost: Bool
    }

    var folderState: FolderState {
        get { FolderState(cwd: cwd, cwdPatterns: cwdPatterns, cwdAlternates: cwdAlternates, cwdIfChainFailed: cwdIfChainFailed, oldCwd: oldCwd, cwdLost: cwdLost) }
        set {
            cwd = newValue.cwd
            cwdPatterns = newValue.cwdPatterns
            cwdAlternates = newValue.cwdAlternates
            cwdIfChainFailed = newValue.cwdIfChainFailed
            oldCwd = newValue.oldCwd
            cwdLost = newValue.cwdLost
        }
    }

    /// Checks a list run in a subshell: its `cd`s don't outlast it.
    mutating func checkSubshell(_ list: ShellList, depth: Int) {
        let saved = folderState
        check(list, depth: depth)
        folderState = saved
    }

    mutating func check(_ list: ShellList, depth: Int) {
        if depth > Self.maxDepth { acc.raise(.high, "nested too deeply to check"); return }
        var previousConnector = ""
        let pipelines = list.pipelines
        for (pi, pipeline) in pipelines.enumerated() {
            if outOfWork { return }
            // A lone `cd` followed by `&&` gates what comes next: if it failed, nothing later in
            // the chain runs. `cd x || exit` does so for the rest of the list. Neither holds when
            // an `||` before it may have skipped the `cd` (`a || cd x && …`).
            if pipeline.commands.contains(where: Self.startsStructure) { sawStructure = true }
            var gate = CDGate.none
            if pipeline.commands.count == 1, previousConnector != "||" {
                if pipeline.connector == "&&" { gate = .chain }
                // Only on the command line itself, before any branch, loop or function: a `cd x ||
                // exit` in code that may never run (`if false; then …`, a function body, a trap)
                // says nothing about where later commands run.
                if pipeline.connector == "||", depth == 0, !sawStructure, loopDepth == 0,
                   pi + 1 < pipelines.count, Self.exitsShell(pipelines[pi + 1]) { gate = .exits }
            }
            var sawDownload = false
            var pipedText: String?
            for (idx, cmd) in pipeline.commands.enumerated() {
                check(cmd, piped: idx > 0, pipedFromDownload: sawDownload, pipedText: pipedText, cdGate: gate, depth: depth)
                if isDownloadish(cmd) { sawDownload = true }
                if let t = literalOutput(cmd) { pipedText = t }
            }
            forkBombCheck(pipeline)
            // The `&&` chain ends here: a `cd` in it that failed leaves the shell where it was.
            if pipeline.connector != "&&" { endChain() }
            previousConnector = pipeline.connector
        }
        // So does the list (a `cd x &&` left dangling in `sh -c` text is no exception).
        endChain()
    }

    /// The folders a failed `cd` in the `&&` chain would have left the shell in are possible again.
    mutating func endChain() {
        guard !cwdIfChainFailed.isEmpty else { return }
        let failed = cwdIfChainFailed
        cwdIfChainFailed = []
        addAlternates(failed)
    }

    /// How a `cd`'s failure affects what runs after it.
    enum CDGate {
        /// Nothing stops the next command (`;`, a newline, `&`, a pipeline…).
        case none
        /// `cd x && …`: the rest of the `&&` chain runs only if it worked.
        case chain
        /// `cd x || exit`: nothing after it runs unless it worked.
        case exits
    }

    /// A command that opens or belongs to a compound command (`if`, a loop, `case`, a function,
    /// braces, a subshell), whose parts may run conditionally, repeatedly or never.
    static func startsStructure(_ cmd: ShellCommand) -> Bool {
        if cmd.definesFunction || !cmd.groups.isEmpty || cmd.arithmetic { return true }
        guard let first = cmd.words.first, !first.quoted else { return false }
        return structureKeywords.contains(first.text)
    }

    static let structureKeywords: Set<String> = ["if", "then", "else", "elif", "fi", "while", "until", "do", "done", "for", "foreach", "select",
                                                 "repeat", "case", "esac", "function", "{", "}", "coproc", "end"]

    /// `exit` or `return` (with an optional status) on its own: the shell stops there. Not when
    /// backgrounded or chained further, where it may not run or may only end a subshell.
    static func exitsShell(_ pipeline: ShellPipeline) -> Bool {
        guard pipeline.commands.count == 1, ["", ";", "\n"].contains(pipeline.connector),
              let cmd = pipeline.commands.first, cmd.redirects.isEmpty, cmd.groups.isEmpty else { return false }
        let words = cmd.words.filter { !$0.text.isEmpty }
        guard let first = words.first, !first.quoted, first.text == "exit" || first.text == "return", words.count <= 2 else { return false }
        return words.count == 1 || words[1].text.allSatisfy(\.isNumber)
    }

    /// `:(){ :|:& };:` and named variants: a function defined on the line whose name is piped
    /// into itself in the background. Read from the parsed pipeline, so it costs nothing extra
    /// however long the line (a regex over the raw text was quadratic).
    mutating func forkBombCheck(_ pipeline: ShellPipeline) {
        for cmd in pipeline.commands {
            if cmd.definesFunction, let name = cmd.words.last { functionNames.insert(Self.bareName(name.text)) }
            if let first = cmd.words.first, first.text == "function", !first.quoted, cmd.words.count > 1 {
                functionNames.insert(Self.bareName(cmd.words[1].text))
            }
        }
        guard pipeline.connector == "&", pipeline.commands.count >= 2, !functionNames.isEmpty,
              let last = pipeline.commands.last, last.words.count == 1 else { return }
        let name = Self.bareName(last.words[0].text)
        let left = pipeline.commands[pipeline.commands.count - 2]
        guard functionNames.contains(name), let feeder = left.words.last, Self.bareName(feeder.text) == name else { return }
        acc.block("Glide won't run a fork bomb; it would freeze your Mac.", reason: "fork bomb")
    }

    /// A word without the braces zsh lets touch it (`{bomb|bomb&}`).
    static func bareName(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    }

    /// Text a command writes that is visible in the command line itself (`echo …`,
    /// `printf …`, `cat <<EOF`), so `echo 'rm -rf ~' | sh` can be judged by what it pipes.
    func literalOutput(_ cmd: ShellCommand) -> String? {
        if let h = cmd.heredoc ?? cmd.hereString?.text { return h }
        let texts = cmd.words.map(\.text)
        guard let first = texts.first else { return nil }
        switch Self.programName(first) {
        case "echo", "printf": return texts.dropFirst().filter { !$0.hasPrefix("-") }.joined(separator: " ")
        default: return nil
        }
    }

    struct Context {
        var piped: Bool
        var pipedFromDownload: Bool
        /// Literal text piped in from an earlier `echo`/`printf`/here-document, if any.
        var pipedText: String? = nil
        var heredoc: String?
        var hereString: String?
        /// Some `$(…)`/`<(…)` in this command's words runs a download.
        var substitutionDownloads: Bool
        var depth: Int
        /// Whether this command's failure stops what follows (`cd x && …`, `cd x || exit`).
        var cdGate = CDGate.none
        /// Every substitution in this command's words prints only numbers (`$(wc -l < f)`).
        var substitutionsNumeric = false
    }

    mutating func check(_ cmd: ShellCommand, piped: Bool, pipedFromDownload: Bool, pipedText: String?, cdGate: CDGate = .none, depth: Int) {
        let allWords = cmd.words + cmd.redirects.map(\.target) + (cmd.hereString.map { [$0] } ?? [])
        guard spend(1 + allWords.reduce(0) { $0 + 1 + $1.text.utf8.count / 4 }) else { return }
        // Everything nested runs too, each in a subshell of its own.
        var subsDownload = false
        var subsNumeric = true
        var anySubstitution = false
        for w in allWords {
            var wordDownloads = false
            for s in w.substitutions {
                checkSubshell(s, depth: depth + 1)
                if listDownloads(s) { subsDownload = true; wordDownloads = true }
                anySubstitution = true
                if !numericOutput(s) { subsNumeric = false }
            }
            if w.globbed { globbedTexts.insert(w.text) }
            for q in w.qualifiers {
                globQualifier(q, depth: depth)
                if Self.qualifierMatchesDots(q) { dotQualifiedTexts.insert(w.text) }
            }
            if literalCode.count < Self.maxLiteralCode {
                literalCode += Self.literalCode(in: w.text).prefix(Self.maxLiteralCode - literalCode.count)
            }
            // `$(( … ))`, `$[ … ]` and subscripts evaluate arithmetic: note what they read, and
            // a substitution inside them (zsh runs it, then evaluates its output).
            let segments = Self.arithmeticSegments(w.text)
            if !segments.isEmpty {
                arithmetic = true
                for seg in segments { noteArithmetic(seg, downloads: wordDownloads) }
            }
            if Self.mentionsClipboard(w.text) { mentionsClipboard = true }
            expansionRules(w.text, depth: depth)
        }
        if cmd.arithmetic {
            arithmetic = true
            noteArithmetic(cmd.arithmeticText ?? "", downloads: subsDownload)
        }
        if let h = cmd.heredoc, Self.mentionsClipboard(h) { mentionsClipboard = true }
        for g in cmd.groups { checkSubshell(g, depth: depth + 1) }

        // Redirections.
        let downloads = isDownloadish(cmd)
        for r in cmd.redirects {
            if r.isWrite {
                write(r.target.text, what: "redirects output to")
                if downloads, let p = resolve(r.target.text) { downloadedFiles.insert(p.lowercased()) }
            } else if r.op == "<" || r.op == "<>" {
                readCheck(r.target.text)
            }
        }

        // Words: drop placeholders, assignments and grammar keywords.
        let words = cmd.words.filter { !($0.text.isEmpty && !$0.quoted) }
        // Assignments before a program apply to it alone; a line of only assignments sets
        // shell variables for the commands after it.
        let onlyAssignments = words.allSatisfy { Self.isAssignment($0.text) }
        var start = 0
        var negated = false
        stripping: while start < words.count {
            let first = words[start]
            // Assignment values that are command substitutions were already checked above.
            if Self.isAssignment(first.text) {
                assignment(first.text, persists: onlyAssignments, depth: depth,
                           valueIsCommandOutput: !first.substitutions.isEmpty && !numericAssignment(first),
                           valueSubDownloads: first.substitutions.contains(where: listDownloads))
                start += 1
                continue
            }
            if first.quoted { break }
            switch first.text {
            case _ where Self.prefixKeywords.contains(first.text):
                // `!` inverts the status, so a failed `cd` lets what follows `&&` run.
                if first.text == "!" { negated = true }
                // Everything from `while`/`until` to `done` runs again and again.
                if first.text == "while" || first.text == "until" { loopDepth += 1 }
                if first.text == "done" || first.text == "end" { loopDepth = max(0, loopDepth - 1) }
                start += 1
            case "[[", "[":
                // A condition; anything after its closing bracket (zsh short forms) still runs.
                let close = first.text == "[[" ? "]]" : "]"
                guard let end = words[start...].firstIndex(where: { $0.text == close && !$0.quoted }) else { return }
                conditionRules(words[(start + 1)..<end], doubleBracket: first.text == "[[")
                start = end + 1
            case "function", "repeat":
                // `function name { … }`, `repeat 3 cmd`: the body follows the name/count.
                if first.text == "repeat" { loopDepth += 1 }
                start = min(start + 2, words.count)
            case "for", "foreach", "select":
                // The loop variable takes each listed name. It's an assignment of run-time text,
                // so looping over a risky name (`for GIT_SSH_COMMAND in …; export …`) is judged
                // like one; and the list counts as paths read.
                loopDepth += 1
                if start + 1 < words.count {
                    envAssignment(words[start + 1].text, value: nil, appends: false, depth: depth)
                    vars[words[start + 1].text] = nil
                }
                for w in words.dropFirst(start + 2) where w.text != "in" && w.text != "do" { readCheck(w.text) }
                // A plain loop header has nothing else; zsh's short form `for f (*.txt) cmd`
                // puts the list in parentheses and the command right after.
                if cmd.groups.isEmpty { return }
                start = min(start + 2, words.count)
            case "case":
                // `case WORD in PATTERN) …`: a bash-style pattern is a word (its `)` ended this
                // command); zsh's `(pattern) command` puts the pattern in a group and the
                // command that runs right after it, so that command is still checked.
                start = min(start + 3, words.count)
                if cmd.groups.isEmpty, start < words.count { start += 1 }
            case "in", "esac":
                start += 1
            default:
                break stripping
            }
        }
        guard start < words.count else { return }

        var ctx = Context(piped: piped, pipedFromDownload: pipedFromDownload, pipedText: piped ? pipedText : nil, heredoc: cmd.heredoc,
                          hereString: cmd.hereString?.text, substitutionDownloads: subsDownload, depth: depth)
        ctx.cdGate = negated ? .none : cdGate
        ctx.substitutionsNumeric = anySubstitution && subsNumeric
        checkWords(words[start...].map(\.text), ctx: ctx)
    }

    /// The words between `[[`/`[` and the closing bracket. zsh's `[[ … ]]` evaluates the
    /// operands of `-eq`, `-lt`… as arithmetic; its `[`/`test` builtin compares them as plain
    /// integers ("integer expression expected") and never evaluates them, and so does bash's.
    /// `-v` names a variable, whose subscript is evaluated in either.
    mutating func conditionRules(_ inner: ArraySlice<ShellWord>, doubleBracket: Bool) {
        let operands = Array(inner)
        for (k, op) in operands.enumerated() where !op.quoted && Self.arithmeticTests.contains(op.text) {
            let evaluates = op.text == "-v" || doubleBracket || testIsArithmetic
            guard evaluates else { continue }
            arithmetic = true
            let sides = op.text == "-v" ? [k + 1] : [k - 1, k + 1]
            for j in sides where j >= 0 && j < operands.count {
                noteArithmetic(operands[j].text, downloads: operands[j].substitutions.contains(where: listDownloads))
            }
        }
    }

    /// Records an arithmetic expression: the names it reads (checked against run-time
    /// variables in `finish`) and whether a substitution feeds it.
    mutating func noteArithmetic<S: StringProtocol>(_ expr: S, downloads: Bool) {
        arithmeticReads.formUnion(Self.arithmeticNames(expr))
        if Self.hasSubstitutionMarker(expr) {
            arithmeticHasSubstitution = true
            if downloads { arithmeticSubDownloads = true }
        }
    }

    /// Checks a command given as words (also used for `find -exec`, `xargs`, `env -S`).
    mutating func checkWords(_ texts: [String], ctx: Context) {
        // `find -exec find -exec …` and `jobs -x jobs -x …` nest without a parser level.
        if ctx.depth > Self.maxDepth { acc.raise(.high, "nested too deeply to check"); return }
        guard spend(1 + texts.count) else { return }
        var how = Unwrapped()
        guard let args = unwrap(texts, ctx: ctx, how: &how), let rawProgram = args.first else { return }
        // `xargs cmd` runs cmd once per input line, like a loop body.
        if how.repeats { loopDepth += 1 }
        defer { if how.repeats { loopDepth -= 1 } }
        var ctx = ctx
        // `env cd x`, `nohup cd x`: a separate program can't move the shell, so whatever the
        // `&&` after it runs is still in the old folder.
        if how.separateProcess { ctx.cdGate = .none }
        let rest = Array(args.dropFirst())
        // `$x -rf ~`, `$(echo rm) …`, `$'\x72m' …`: the program is only known at run time.
        let expanded = rawProgram.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        if expanded.contains("$") || expanded.contains("`") || expanded.hasPrefix("<(") || expanded.hasPrefix(">(") || expanded.hasPrefix("=(")
            || globbedTexts.contains(rawProgram) {
            acc.raise(.high, "runs a program chosen at run time")
            // A variable set earlier on the line is known, so judge what it names as well.
            let known = substituteVariables(rawProgram)
            if known != rawProgram, !Self.hasRunTimeParts(known) {
                checkText(([known] + rest).joined(separator: " "), depth: ctx.depth + 1)
            }
            return
        }
        let prog = Self.programName(rawProgram)
        programs.insert(prog)

        if rawProgram.contains("/") {
            // Running something a download just wrote.
            if let p = resolve(rawProgram), downloadedFiles.contains(p.lowercased()) {
                acc.block(Self.downloadIntoShell, reason: "runs a file it just downloaded")
            }
            readCheck(rawProgram)
            // A program in a folder Glide can write to is whatever was put there, not the
            // system tool its name suggests (`cp /bin/rm ~/bin/cat; ~/bin/cat -rf ~/x`). System
            // and package folders are fine: changing what's there already needs approval.
            if resolve(rawProgram).map({ PathRules.writeZone($0, home: home) }) != .outside {
                acc.raise(.medium, "runs \(display(rawProgram))")
            }
        }
        // Any operand naming private keys or credentials. Listing programs print names, sizes
        // and dates, never contents, so a glob that merely could reach a key folder is fine for
        // them (`du -sh ~/Library/*` reads no more than `du -sh ~/Library`).
        let contents = !Self.metadataPrograms.contains(prog)
        for a in rest where !a.hasPrefix("-") { readCheck(a, contents: contents) }

        rules(prog, rest, ctx)
    }

    /// Programs that only report names and metadata (`wc` reads files but prints counts).
    static let metadataPrograms: Set<String> = ["ls", "du", "stat", "mdls", "wc"]

    // MARK: Wrappers

    /// How `unwrap` reached the command it returns.
    struct Unwrapped {
        /// Through `xargs`, which runs it once per input line.
        var repeats = false
        /// Through a separate program (`env`, `nohup`, `nice`…), so a builtin like `cd` there
        /// can't change the shell itself.
        var separateProcess = false
    }

    /// Strips wrappers that just run the rest of the line (`nohup`, `env`, `xargs`, `time`…).
    /// Returns nil when the wrapper was fully handled here. Every pass removes at least the
    /// wrapper's own word, so the loop ends; there's no count limit to hide a command behind.
    mutating func unwrap(_ input: [String], ctx: Context, how: inout Unwrapped) -> [String]? {
        var w = input[...]
        while true {
            guard let head = w.first else { return nil }
            let prog = Self.programName(head)
            if Self.programWrappers.contains(prog) { how.separateProcess = true }
            switch prog {
            case "command":
                w.removeFirst()
                if let f = w.first, f == "-v" || f == "-V" { return nil }
                if w.first == "-p" { w.removeFirst() }
            case "builtin", "nohup", "noglob", "nocorrect", "stdbuf", "unbuffer", "chronic":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") { w.removeFirst() }
            case "exec":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if f == "-a", !w.isEmpty { w.removeFirst() }
                }
            case "time":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") { w.removeFirst() }
            case "nice":
                w.removeFirst()
                if w.first == "-n" { w.removeFirst(); if !w.isEmpty { w.removeFirst() } }
                else if let f = w.first, f.hasPrefix("-") { w.removeFirst() }
            case "timeout", "gtimeout":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if (f == "-s" || f == "-k"), !w.isEmpty { w.removeFirst() }
                }
                if !w.isEmpty { w.removeFirst() } // duration
            case "caffeinate":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if (f == "-t" || f == "-w"), !w.isEmpty { w.removeFirst() }
                }
            case "arch":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if f == "-arch", !w.isEmpty { w.removeFirst() }
                }
            case "env":
                w.removeFirst()
                while let f = w.first {
                    if f == "-S" || f.hasPrefix("--split-string") {
                        w.removeFirst()
                        let s = f.contains("=") ? String(f.split(separator: "=", maxSplits: 1).last ?? "") : (w.isEmpty ? "" : w.removeFirst())
                        checkText(([s] + w).joined(separator: " "), depth: ctx.depth + 1)
                        return nil
                    }
                    if f == "-P" {
                        // `env -P dir cmd` runs cmd from `dir`, like putting it on PATH.
                        w.removeFirst()
                        if !w.isEmpty { envAssignment("PATH", value: w.removeFirst(), appends: false, depth: ctx.depth) }
                        continue
                    }
                    if f == "-u" || f == "-C" { w.removeFirst(); if !w.isEmpty { w.removeFirst() }; continue }
                    if Self.isAssignment(f) { assignment(f, persists: false, depth: ctx.depth) }
                    if f.hasPrefix("-") || Self.isAssignment(f) { w.removeFirst(); continue }
                    break
                }
            case "xargs":
                w.removeFirst()
                let withArg: Set<String> = ["-I", "-J", "-L", "-n", "-P", "-s", "-E", "-R", "-S", "-a", "-d"]
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if withArg.contains(f), !w.isEmpty { w.removeFirst() }
                }
                if w.isEmpty { return nil } // xargs alone runs echo
                how.repeats = true
            case "watch":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if (f == "-n" || f == "-d"), !w.isEmpty { w.removeFirst() }
                }
                if w.isEmpty { return nil }
                // `watch` runs its command every few seconds.
                loopDepth += 1
                checkText(w.joined(separator: " "), depth: ctx.depth + 1)
                loopDepth -= 1
                return nil
            case "setsid":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") { w.removeFirst() }
            case "taskpolicy":
                // `taskpolicy [opts] program args`: options, then the program and its arguments.
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if ["-t", "-l", "-g", "-d", "-c", "-p", "-e", "-s", "-a", "-i"].contains(f), !w.isEmpty { w.removeFirst() }
                }
                if w.isEmpty { return nil } // -p pid: acts on a process, runs nothing
            case "sandbox-exec":
                // `sandbox-exec -f profile|-n name|-p string [-D key=val] program args`.
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if ["-f", "-n", "-p"].contains(f), !w.isEmpty { w.removeFirst() }
                }
                if w.isEmpty { return nil }
            case "zpty":
                // zsh's zpty module: `zpty name command args` starts a program in a pty. The
                // read/write/list/delete forms (-r -w -t -d -L) run nothing.
                w.removeFirst()
                var runsCommand = true
                while let f = w.first, f.hasPrefix("-") {
                    if (Self.shortCluster(f)?.contains(where: { "rwtdL".contains($0) }) ?? false) { runsCommand = false }
                    w.removeFirst()
                }
                guard runsCommand, !w.isEmpty else { return nil }
                w.removeFirst() // the pty name
                if w.isEmpty { return nil }
            case "script":
                // BSD `script [opts] [file [command …]]`; util-linux `script -c command file`.
                w.removeFirst()
                var handled = false
                while let f = w.first, f.hasPrefix("-"), f != "-" {
                    w.removeFirst()
                    if f == "-c" {
                        checkText(w.first ?? "", depth: ctx.depth + 1)
                        handled = true
                        break
                    }
                    if ["-F", "-t", "-m", "-o", "-T", "-B", "-I", "-O"].contains(f), !w.isEmpty { w.removeFirst() }
                }
                if handled { return nil }
                if w.isEmpty { return nil }
                w.removeFirst() // the typescript file
                if w.isEmpty { return nil } // records an interactive shell; nothing to check
            default:
                return Array(w)
            }
        }
    }

    /// Wrappers that are programs of their own (not shell builtins or keywords like `builtin`,
    /// `command`, `noglob`, `time`): what they run is a separate process.
    static let programWrappers: Set<String> = ["nohup", "stdbuf", "unbuffer", "chronic", "exec", "nice", "timeout", "gtimeout", "caffeinate",
                                               "arch", "env", "xargs", "watch", "setsid", "taskpolicy", "sandbox-exec", "zpty", "script"]

    mutating func checkText(_ text: String, depth: Int) {
        if depth > Self.maxDepth { acc.raise(.high, "nested too deeply to check"); return }
        guard spend(1 + text.utf8.count / 4) else { return }
        let parse = ShellParser.parse(text)
        if parse.tooComplex { acc.raise(.high, "nested too deeply to check") }
        check(parse.list, depth: depth)
    }

    /// Text a shell evaluates (`eval`, `emulate -c`, `sh -c`): checked as written and, when it
    /// uses variables set earlier on the line, with their values filled in.
    mutating func evaluate(_ text: String, what: String, _ ctx: Context) {
        if ctx.substitutionDownloads { acc.block(Self.downloadIntoShell, reason: "evaluates downloaded content") }
        if Self.hasRunTimeParts(text) { acc.raise(.high, "evaluates text built at run time (\(what))") }
        checkText(text, depth: ctx.depth + 1)
        let known = substituteVariables(text)
        if known != text { checkText(known, depth: ctx.depth + 1) }
    }

    /// Runs once the whole line was walked, for rules that depend on more than one command.
    ///
    /// Quoted command text is inert on its own, but arithmetic evaluation runs it: bash and
    /// zsh expand `$(…)` inside an array subscript when a string such as `a[$(cmd)]` is
    /// evaluated (`x='a[$(cmd)]'; (( x ))`, `let`, `[[ $x -eq 1 ]]`, `read 'a[$(cmd)]'`). So
    /// both together are judged as running it.
    mutating func finish() {
        // A script that mentions the clipboard (`osascript -e 'the clipboard'`, `python3 -c
        // '…NSPasteboard…'`) reads it; a commit message or `swift test --filter ClipboardTests`
        // doesn't, because no script code runs.
        if mentionsClipboard, runsScriptCode { readsClipboard = true }
        // The concealed-clipboard guard runs once before launch. A command that sleeps, or reads
        // the clipboard inside a loop, could read a password the user copies while it runs, so
        // it needs approval. Only a read in the loop body repeats: `pbpaste | while read …`
        // reads once, and a loop keyword inside quotes or an awk program is just text.
        if readsClipboard, programs.contains("sleep") || clipboardReaderRepeats {
            acc.raise(.high, "reads the clipboard after a delay or in a loop")
        }
        // Arithmetic (or `${(e)…}`/`${…@P}`) that evaluates command text quoted on the line.
        if (arithmetic || evaluatesStrings), !literalCode.isEmpty {
            acc.raise(.high, "evaluates command text stored in a string\(arithmetic ? " (arithmetic)" : "")")
            for code in literalCode { checkText(code, depth: 1) }
        }
        // Arithmetic over run-time content: a command substitution feeding it, or a variable set
        // from command output / read and then read in an arithmetic expression. zsh (and bash,
        // once the variable is used) evaluate that text, so `a[$(cmd)]` in it runs `cmd`.
        guard arithmetic else { return }
        let runtimeRefs = runtimeVars.intersection(arithmeticReads)
        guard arithmeticHasSubstitution || !runtimeRefs.isEmpty else { return }
        if arithmeticSubDownloads || !runtimeRefs.isDisjoint(with: downloadVars) {
            acc.block(Self.downloadIntoShell, reason: "evaluates downloaded content as arithmetic")
        } else {
            acc.raise(.high, "evaluates run-time text as arithmetic (it can run embedded commands)")
        }
    }

    /// The variable names an arithmetic expression reads (bare, `$name` or `${name}`), found in
    /// one pass. `${#name}` and zsh's `$#name` are lengths: the value itself isn't evaluated.
    static func arithmeticNames<S: StringProtocol>(_ expr: S) -> Set<String> {
        let u = Array(expr.unicodeScalars)
        var out: Set<String> = []
        var i = 0
        while i < u.count {
            guard isWordScalar(u[i]) else { i += 1; continue }
            let s = i
            while i < u.count, isWordScalar(u[i]) { i += 1 }
            // A run starting with a digit is a number (`10`, `0x1f`), not a name.
            if ("0"..."9").contains(u[s]) { continue }
            let isLength = s >= 2 && u[s - 1] == "#" && (u[s - 2] == "$" || (u[s - 2] == "{" && s >= 3 && u[s - 3] == "$"))
            if !isLength {
                var name = ""
                name.unicodeScalars.append(contentsOf: u[s..<i])
                out.insert(name)
            }
        }
        return out
    }

    /// `[A-Za-z0-9_]`, the characters of a shell variable name.
    static func isWordScalar(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_"
    }

    /// A command substitution in arithmetic text, whose output zsh then evaluates: `$(…)` (not
    /// `$((`, which is arithmetic too) or backticks.
    static func hasSubstitutionMarker<S: StringProtocol>(_ s: S) -> Bool {
        var previous: Character = " "
        var afterDollarParen = false
        for ch in s {
            if afterDollarParen {
                if ch != "(" { return true }
                afterDollarParen = false
            }
            if ch == "`" { return true }
            if ch == "(", previous == "$" { afterDollarParen = true }
            previous = ch
        }
        return afterDollarParen
    }

    /// Parameter expansions that assign or evaluate: `${PATH:=/tmp/x}` and zsh's
    /// `${PATH::=/tmp/x}` set the variable; zsh's `${(e)x}` and bash's `${x@P}` run the
    /// value's `$(…)` as shell text, like `eval`. One pass over the word, with the next `}`
    /// and `)` precomputed (regexes over unclosed `${` were quadratic).
    mutating func expansionRules(_ text: String, depth: Int) {
        guard text.contains("${") else { return }
        let u = Array(text.unicodeScalars)
        var nextBrace = [Int](repeating: -1, count: u.count + 1)
        var nextParen = [Int](repeating: -1, count: u.count + 1)
        for k in stride(from: u.count - 1, through: 0, by: -1) {
            nextBrace[k] = u[k] == "}" ? k : nextBrace[k + 1]
            nextParen[k] = u[k] == ")" ? k : nextParen[k + 1]
        }
        func string(_ r: Range<Int>) -> String {
            var s = ""
            s.unicodeScalars.append(contentsOf: u[r])
            return s
        }
        var evaluates = false
        // Each `${`: an `(e)` flag or a `@P` before its first `}`. A flag group's `e` is counted
        // once per group, so overlapping groups stay linear.
        var flagsScannedTo = -1
        for i in 0..<max(0, u.count - 1) where u[i] == "$" && u[i + 1] == "{" {
            let j = i + 2
            let brace = nextBrace[j]
            if brace >= j + 2, u[brace - 2] == "@", u[brace - 1] == "P" { evaluates = true }
            if j < u.count, u[j] == "(", nextParen[j] >= 0, nextParen[j] > flagsScannedTo {
                if u[max(j + 1, flagsScannedTo + 1)..<nextParen[j]].contains("e") { evaluates = true }
                flagsScannedTo = nextParen[j]
            }
        }
        // `${NAME:=value}` and its kin, matched left to right without overlapping (a match
        // continues after its `}`), so the values handed on add up to the word's length.
        var i = 0
        while i + 1 < u.count {
            defer { i += 1 }
            guard u[i] == "$", u[i + 1] == "{" else { continue }
            var j = i + 2
            // An optional `(flags)` group precedes the name in zsh (`${(A)path::=/tmp}`).
            if j < u.count, u[j] == "(" {
                let close = nextParen[j]
                guard close >= 0 else { continue }
                j = close + 1
            }
            let nameStart = j
            while j < u.count, Self.isWordScalarStart(u[j], first: j == nameStart) { j += 1 }
            guard j > nameStart else { continue }
            let nameEnd = j
            var colons = 0
            while j < u.count, u[j] == ":", colons < 2 { colons += 1; j += 1 }
            guard j < u.count, u[j] == "=" else { continue }
            let end = nextBrace[j]
            guard end >= 0 else { continue }
            envAssignment(string(nameStart..<nameEnd), value: string((j + 1)..<end), appends: false, depth: depth)
            i = end
        }
        if evaluates {
            acc.raise(.high, "evaluates a value as shell text (${(e)…} or ${…@P})")
            evaluatesStrings = true
        }
    }

    /// A character of a variable name; the first can't be a digit.
    static func isWordScalarStart(_ c: Unicode.Scalar, first: Bool) -> Bool {
        isWordScalar(c) && !(first && ("0"..."9").contains(c))
    }

    /// A zsh qualifier with `D` (`*(D)`, `*(#qD)`) turns on GLOB_DOTS for its word, so `*` and
    /// `**/` match hidden names there. Read loosely: any unquoted `D` counts.
    static func qualifierMatchesDots(_ raw: String) -> Bool {
        var quote: Character?
        for ch in raw {
            if let open = quote { if ch == open { quote = nil }; continue }
            if ch == "'" || ch == "\"" { quote = ch; continue }
            if ch == "D" { return true }
        }
        return false
    }

    /// zsh glob qualifiers `e:code:` and `+function` run shell code for every matching file
    /// (`ls *(e:'rm -rf ~':)`); other qualifiers and `(a|b)` alternatives only match names.
    mutating func globQualifier(_ raw: String, depth: Int) {
        var q = raw
        // Quoted text is never special, so look for `|`, `(` and `~` outside quotes only.
        var unquoted = ""
        var quote: Character?
        for ch in q {
            if let open = quote { if ch == open { quote = nil }; continue }
            if ch == "'" || ch == "\"" { quote = ch; continue }
            unquoted.append(ch)
        }
        if q.hasPrefix("#q") { q.removeFirst(2) } else if unquoted.contains("|") || unquoted.contains("(") || unquoted.contains("~") { return }
        let chars = Array(q)
        var codes: [String] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "e", i + 1 < chars.count, !chars[i + 1].isLetter, !chars[i + 1].isNumber {
                let open = chars[i + 1]
                let close: Character = ["{": "}", "[": "]", "(": ")", "<": ">"][open] ?? open
                var j = i + 2
                while j < chars.count, chars[j] != close { j += 1 }
                codes.append(String(chars[min(i + 2, chars.count)..<j]))
                i = j + 1
                continue
            }
            if ch == "+", i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1] == "_" {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                codes.append(String(chars[(i + 1)..<j]))
                i = j
                continue
            }
            i += 1
        }
        guard !codes.isEmpty else { return }
        acc.raise(.high, "runs code from a zsh glob qualifier")
        for code in codes {
            // zsh removes the qualifier's quotes before running it; substitutions in it were
            // already found when the word was parsed.
            let unquoted = ShellParser.parse(code).list.pipelines.map { p in p.commands.map { $0.words.map(\.text).joined(separator: " ") }.joined(separator: " | ") }
            checkText(unquoted.joined(separator: "; "), depth: depth + 1)
        }
    }

    // MARK: Rules

    mutating func rules(_ prog: String, _ a: [String], _ ctx: Context) {
        switch prog {
        // Blocked outright.
        case "sudo", "su", "doas", "pkexec", "runas":
            acc.block("Glide never runs commands as an administrator (\(prog)). If you need it, run it yourself in Terminal.", reason: "runs as administrator")
        case "shutdown", "reboot", "halt", "poweroff":
            acc.block("Glide won't shut down or restart your Mac.", reason: "shuts down the Mac")
        case "csrutil":
            acc.block("Glide won't touch System Integrity Protection (csrutil).", reason: "changes System Integrity Protection")
        case "nvram":
            acc.block("Glide won't change firmware settings (nvram).", reason: "changes firmware settings")
        case "fdisk", "newfs", "mkfs":
            acc.block("Glide won't format or partition disks.", reason: "formats disks")
        case _ where prog.hasPrefix("mkfs.") || prog.hasPrefix("newfs_"):
            acc.block("Glide won't format or partition disks.", reason: "formats disks")
        case "dd":
            if a.contains(where: { $0.hasPrefix("of=") }) {
                acc.block("Glide won't run dd with an output (of=); it can overwrite whole disks.", reason: "dd writes raw data")
            } else { acc.raise(.medium) }
        case "diskutil":
            diskutilRules(a)
        case "spctl":
            if a.contains(where: { ["--master-disable", "--global-disable", "--disable"].contains($0) }) {
                acc.block("Glide won't turn off Gatekeeper.", reason: "turns off Gatekeeper")
            } else if a.contains(where: { ["--add", "--remove", "--enable", "--master-enable", "--global-enable", "--reset-default"].contains($0) }) {
                acc.raise(.high, "changes Gatekeeper settings")
            }

        // Deletion.
        case "rm", "srm", "shred", "unlink", "trash", "rmdir":
            let recursive = prog != "rmdir" && (Self.hasShort(a, "r") || Self.hasShort(a, "R") || a.contains("--recursive"))
            acc.raise(.high, "deletes files (\(prog))")
            for t in Self.operands(a) { deletes(t, recursive: recursive) }
        case "find":
            findRules(a, ctx)
        case "truncate":
            acc.raise(.high, "empties or shortens files (truncate)")
            for t in Self.operands(a, valueFlags: ["-s", "-r"]) { write(t, what: "truncates") }

        // Processes and services.
        case "kill":
            var rest = a
            if let f = rest.first, f == "-s" || f == "-n" { rest.removeFirst(); if !rest.isEmpty { rest.removeFirst() } }
            else if let f = rest.first, f.hasPrefix("-"), f != "--", rest.count > 1 { rest.removeFirst() }
            if rest.first == "--" { rest.removeFirst() }
            if rest.contains("-1") {
                acc.block("Glide won't signal every process you own (kill -1).", reason: "kills all processes")
            } else { acc.raise(.high, "stops processes (kill)") }
        case "pkill", "killall":
            acc.raise(.high, "stops processes (\(prog))")
        case "launchctl":
            let readOnly: Set<String> = ["list", "print", "print-disabled", "print-cache", "blame", "version", "help", "procinfo", "hostinfo",
                                         "examine", "managerpid", "manageruid", "managername", "error", "dumpstate", "dumpjpcategory"]
            if let sub = a.first?.lowercased(), readOnly.contains(sub) { break }
            acc.raise(.high, "changes background services (launchctl)")
        case "crontab":
            if a == ["-l"] || (a.count == 3 && a.contains("-l") && a.contains("-u")) { break }
            acc.raise(.high, "changes scheduled jobs (crontab)")
        case "at", "atrm", "batch":
            acc.raise(.high, "schedules a command to run later")

        // Permissions and ownership.
        case "chmod":
            let flagChars = Set("RHLPfhvECNiI")
            var opers: [String] = []
            var recursive = false
            var endOfFlags = false
            for x in a {
                if !endOfFlags, x == "--" { endOfFlags = true; continue }
                if !endOfFlags, x.hasPrefix("-"), x.count > 1, x.dropFirst().allSatisfy({ flagChars.contains($0) }) {
                    if x.contains("R") { recursive = true }
                    continue
                }
                opers.append(x)
            }
            let targets = Array(opers.dropFirst())
            if recursive {
                acc.raise(.high, "changes permissions recursively (chmod -R)")
                for t in targets where criticalTree(t) {
                    acc.block("Glide won't recursively change permissions on \(display(t)).", reason: "recursive chmod on a system folder")
                }
            } else { acc.raise(.medium) }
            for t in targets { write(t, what: "changes permissions of") }
        case "chown", "chgrp":
            acc.raise(.high, "changes file ownership (\(prog))")
            if Self.hasShort(a, "R") {
                for t in Self.operands(a).dropFirst() where criticalTree(t) {
                    acc.block("Glide won't recursively change ownership of \(display(t)).", reason: "recursive chown on a system folder")
                }
            }
        case "chflags":
            acc.raise(.high, "changes file flags (chflags)")
        case "xattr":
            if Self.hasShort(a, "d") || Self.hasShort(a, "c") || Self.hasShort(a, "w") {
                acc.raise(.high, "removes or changes file attributes such as quarantine (xattr)")
            }

        // Local changes.
        case "mv", "gmv":
            acc.raise(.medium)
            for t in Self.operands(a, valueFlags: ["-t", "-S"]) {
                if criticalTree(t) {
                    acc.raise(.high, "moves a system or account folder (\(display(t)))")
                }
                write(t, what: "moves")
            }
        case "cp", "gcp", "ditto", "install", "ln", "gln":
            acc.raise(.medium)
            let ops = Self.operands(a, valueFlags: ["-m", "-o", "-g", "-B", "-S", "-t"])
            if let dest = ops.last, ops.count >= 2 { write(dest, what: "writes") }
            else if prog.hasSuffix("ln") { write(".", what: "creates a link in") }
        case "mkdir":
            acc.raise(.medium)
            for t in Self.operands(a, valueFlags: ["-m"]) { write(t, what: "creates") }
        case "touch":
            acc.raise(.medium)
            for t in Self.operands(a, valueFlags: ["-t", "-r", "-d", "-A"]) { write(t, what: "touches") }
        case "rsync":
            acc.raise(.medium)
            let ops = Self.operands(a, valueFlags: ["-e", "--rsh"])
            if ops.contains(where: Self.isRemoteSpec) { acc.raise(.high, "copies files to or from another computer (rsync)") }
            if a.contains(where: { $0.hasPrefix("--delete") || $0 == "--remove-source-files" }) { acc.raise(.high, "deletes files (rsync --delete)") }
            if let dest = ops.last, ops.count >= 2, !Self.isRemoteSpec(dest) { write(dest, what: "writes") }
        case "zip":
            acc.raise(.medium)
            if let archive = Self.operands(a).first { write(archive, what: "writes") }
        case "unzip":
            if Self.hasShort(a, "l") || Self.hasShort(a, "v") || Self.hasShort(a, "t") || Self.hasShort(a, "Z") || Self.hasShort(a, "p") { break }
            acc.raise(.medium)
            if let i = a.firstIndex(of: "-d"), i + 1 < a.count { write(a[i + 1], what: "extracts into") } else { write(".", what: "extracts into") }
        case "tar", "bsdtar", "gtar":
            tarRules(a)
        case "gzip", "gunzip", "bzip2", "bunzip2", "xz", "unxz", "zstd", "unzstd", "lz4", "compress", "uncompress":
            if Self.hasShort(a, "c") || Self.hasShort(a, "l") || Self.hasShort(a, "t")
                || a.contains(where: { ["--stdout", "--to-stdout", "--list", "--test"].contains($0) }) { break }
            acc.raise(.medium)
            for t in Self.operands(a) { write(t, what: "replaces") }
        case "sort":
            if let o = Self.value(of: "-o", in: a) ?? Self.longValue("--output", in: a) { write(o, what: "writes") }
        case "uniq":
            let ops = Self.operands(a, valueFlags: ["-f", "-s"])
            if ops.count >= 2 { write(ops[1], what: "writes") }
        case "tee":
            for t in Self.operands(a) { write(t, what: "writes") }
        case "base64", "gbase64":
            if let o = Self.value(of: "-o", in: a) ?? Self.longValue("--output", in: a), o != "-" { write(o, what: "writes") }
        case "xxd":
            let ops = Self.operands(a, valueFlags: ["-c", "-g", "-l", "-o", "-s", "-n"])
            if ops.count >= 2 { write(ops[1], what: "writes") }
        case "patch":
            acc.raise(.medium)
        case "open":
            openRules(a)
        case "pbcopy":
            acc.raise(.medium, "replaces the clipboard")

        // Text tools with escape hatches.
        case "awk", "gawk", "nawk", "mawk":
            awkRules(a)
        case "sed", "gsed":
            sedRules(a)
        case "plutil":
            let writing = ["-convert", "-insert", "-replace", "-remove", "-create"]
            if let o = Self.value(of: "-o", in: a) {
                if o != "-" { write(o, what: "writes") }
            } else if a.contains(where: { writing.contains($0) }), let file = a.last, !file.hasPrefix("-") {
                // Without -o the file is edited in place.
                write(file, what: "edits")
            }
            if a.contains(where: { writing.contains($0) }) { acc.raise(.medium) }
        case "defaults":
            defaultsRules(a)

        // Network.
        case "curl":
            curlRules(a)
        case "wget":
            wgetRules(a)
        case "scp", "sftp", "ssh", "ftp", "telnet", "nc", "ncat", "netcat", "socat", "mosh", "rlogin", "rsh", "ssh-copy-id":
            acc.raise(.high, "connects to another computer (\(prog))")
        case "mail", "mailx", "sendmail", "msmtp", "mutt":
            acc.raise(.high, "sends email (\(prog))")
        case "networksetup":
            let readPrefixes = ["-get", "-list", "-print", "-version", "-help", "-show", "-isnetworkserviceenabled"]
            if let f = a.first?.lowercased(), readPrefixes.contains(where: { f.hasPrefix($0) }) { break }
            acc.raise(.high, "changes network settings (networksetup)")
        case "ifconfig":
            if Self.operands(a).count <= 1 { break }
            acc.raise(.high, "changes network interfaces (ifconfig)")
        case "route":
            if let sub = Self.operands(a).first?.lowercased(), ["get", "monitor", "show"].contains(sub) { break }
            acc.raise(.high, "changes network routes (route)")
        case "scutil":
            if a.contains("--set") { acc.raise(.high, "changes system names or network settings (scutil --set)") }
            else if !a.contains(where: { ["--get", "--dns", "--proxy", "--nwi", "-r"].contains($0) }) { acc.raise(.medium) }

        // System and security settings.
        case "sysctl":
            if a.contains("-w") || a.contains(where: { $0.contains("=") }) { acc.raise(.high, "changes kernel settings (sysctl)") }
        case "hostname", "scselect":
            if !Self.operands(a).isEmpty { acc.raise(.high, "changes the computer's name or network location") }
        case "pmset":
            if !a.contains("-g") { acc.raise(.medium, "changes power settings") }
        case "security":
            let readOnly: Set<String> = ["list-keychains", "show-keychain-info", "default-keychain", "login-keychain", "help"]
            if let sub = a.first, readOnly.contains(sub), !a.contains("-s") { break }
            acc.raise(.high, "accesses keychains or certificates (security)")
        case "tccutil", "systemsetup", "dscl", "dseditgroup", "sysadminctl", "passwd", "chpass", "profiles", "fdesetup", "pfctl",
             "socketfilterfw", "kextload", "kextunload", "kmutil", "bless", "installer", "dsenableroot", "createhomedir", "authorizationdb",
             "systemextensionsctl", "pkgutil", "codesign", "softwareupdate", "firmwarepasswd", "mdmclient":
            systemSettingRules(prog, a)
        case "mdutil":
            if a == ["-s"] || (a.first == "-s") { break }
            acc.raise(.high, "changes Spotlight indexing (mdutil)")
        case "tmutil":
            let readOnly: Set<String> = ["listbackups", "latestbackup", "status", "machinedirectory", "destinationinfo", "listlocalsnapshots",
                                         "listlocalsnapshotdates", "isexcluded", "version", "compare", "calculatedrift", "uniquesize", "verifychecksums", "help"]
            if let sub = a.first?.lowercased(), readOnly.contains(sub) { break }
            if let sub = a.first?.lowercased(), sub.hasPrefix("delete") || sub == "disable" || sub.hasPrefix("remove") || sub.hasPrefix("thin") {
                acc.raise(.high, "deletes or disables backups (tmutil)")
            } else { acc.raise(.medium) }
        case "log":
            if let sub = a.first?.lowercased(), ["show", "stream", "stats", "help"].contains(sub) { break }
            acc.raise(.high, "changes or erases system logs (log)")
        case "xcode-select":
            if a.contains(where: { ["-p", "--print-path", "-v", "--version", "-h", "--help"].contains($0) }) { break }
            acc.raise(.medium)

        // Interpreters.
        case "osascript":
            osascriptRules(a, ctx)
        case "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "mksh", "yash":
            shellRules(prog, a, ctx)
        case "python", "python2", "python3", "perl", "ruby", "node", "php", "lua", "rscript", "tclsh", "pwsh", "deno", "bun", "swift", "nodejs":
            interpreterRules(prog, a, ctx)
        case "eval":
            evaluate(a.joined(separator: " "), what: "eval", ctx)
        case "emulate":
            // `emulate zsh -c 'cmd'` runs cmd with that shell's options; without -c it only
            // switches options. ksh emulation may make `[` evaluate arithmetic.
            if a.contains(where: { Self.arithmeticTestShells.contains($0) || Self.hasRunTimeParts($0) }) { testIsArithmetic = true }
            var idx = 0
            while idx < a.count {
                let x = a[idx]
                idx += 1
                if x == "-o" || x == "+o" { idx += 1; continue }
                if x == "-c" || (Self.shortCluster(x)?.contains("c") ?? false) {
                    evaluate(idx < a.count ? a[idx] : "", what: "emulate -c", ctx)
                    break
                }
            }
        case "source", ".":
            if ctx.substitutionDownloads { acc.block(Self.downloadIntoShell, reason: "sources downloaded content") }
            if let f = a.first {
                if f == "/dev/stdin" || f == "-" {
                    if ctx.pipedFromDownload { acc.block(Self.downloadIntoShell, reason: "runs downloaded content") }
                    else if ctx.piped { acc.raise(.high, "runs commands piped from another command") }
                } else {
                    if let p = resolve(f), downloadedFiles.contains(p.lowercased()) { acc.block(Self.downloadIntoShell, reason: "runs a file it just downloaded") }
                    acc.raise(.medium, "runs a shell script in the current shell")
                }
            }
        case "trap":
            if let action = a.first, !action.hasPrefix("-") { checkText(action, depth: ctx.depth + 1) }
        case "alias":
            // Aliases expand on the next line in zsh, so their bodies count as commands, and the
            // names as redefined (an alias for `cd` may not change folder).
            for x in a {
                if let eq = x.firstIndex(of: "=") {
                    functionNames.insert(String(x[..<eq]))
                    checkText(String(x[x.index(after: eq)...]), depth: ctx.depth + 1)
                }
            }

        // Developer tools with destructive subcommands.
        case "git":
            gitRules(a, ctx)
        case "brew":
            subcommandRules(a, low: ["list", "ls", "info", "abv", "search", "--version", "-v", "config", "doctor", "deps", "uses", "leaves", "outdated",
                                     "desc", "--prefix", "--cellar", "--cache", "--repository", "commands", "help", "options", "missing", "log", "cat"],
                            high: ["uninstall", "remove", "rm", "cleanup", "autoremove", "untap", "zap"], highReason: "removes software (brew)")
        case "npm", "pnpm", "yarn":
            if a.first == "version" && Self.operands(Array(a.dropFirst())).isEmpty { break }
            subcommandRules(a, low: ["ls", "list", "ll", "la", "view", "v", "info", "show", "outdated", "search", "help", "why", "explain", "root",
                                     "prefix", "--version", "-v", "audit", "doctor", "config", "fund", "whoami", "ping", "query"],
                            high: ["uninstall", "remove", "rm", "r", "un", "unlink", "publish", "unpublish", "deprecate", "owner", "dist-tag", "access", "token"],
                            highReason: "removes or publishes packages (\(prog))")
            if a.first == "config", let s = a.dropFirst().first, ["set", "delete", "edit", "fix"].contains(s) { acc.raise(.medium) }
        case "pip", "pip3", "pipx":
            pipRules(a)
        case "uv":
            if a.first == "pip" { pipRules(Array(a.dropFirst())) }
            else { subcommandRules(a, low: ["--version", "version", "help", "tree"], high: ["remove", "publish"], highReason: "removes or publishes packages (uv)") }
        case "gem":
            subcommandRules(a, low: ["list", "search", "info", "env", "help", "--version", "-v", "contents", "specification", "query", "outdated", "which"],
                            high: ["uninstall", "cleanup", "push", "yank", "owner"], highReason: "removes or publishes gems")
        case "cargo":
            subcommandRules(a, low: ["--version", "-V", "version", "help", "tree", "metadata", "search", "check"],
                            high: ["publish", "yank", "owner", "uninstall"], highReason: "publishes or removes crates")
        case "twine":
            subcommandRules(a, low: ["--version", "check"], high: ["upload", "register"], highReason: "publishes packages")
        case "gh":
            ghRules(a)
        case "docker", "podman":
            subcommandRules(a, low: ["ps", "images", "logs", "inspect", "version", "info", "top", "history", "search", "--version", "help", "port", "diff"],
                            high: ["rm", "rmi", "prune", "kill", "push", "login", "logout"], highReason: "removes containers or publishes images (\(prog))")
            if a.contains("prune") || (a.count >= 2 && ["rm", "remove", "prune"].contains(a[1])) { acc.raise(.high, "removes containers, images or volumes (\(prog))") }
        case "shortcuts":
            if let sub = a.first?.lowercased(), sub == "list" || sub == "help" { break }
            acc.raise(.medium, "runs a shortcut")
            if a.first?.lowercased() == "run", let name = Self.operands(Array(a.dropFirst())).first,
               SafetyPolicy.matches(ElementMatcher.normalize(name), SafetyPolicy.highRiskWords) {
                acc.raise(.high, "runs the shortcut “\(name)”")
            }

        // Read-only programs (with the odd escape hatch).
        case "rg":
            if a.contains(where: { $0 == "--pre" || $0.hasPrefix("--pre=") }) { acc.raise(.high, "runs a preprocessor program (rg --pre)") }
        case "ag", "ack":
            if let i = a.firstIndex(where: { $0 == "--pager" || $0.hasPrefix("--pager=") }) {
                acc.raise(.high, "runs a pager program (\(prog) --pager)")
                let v = a[i].contains("=") ? String(a[i].drop { $0 != "=" }.dropFirst()) : (i + 1 < a.count ? a[i + 1] : "")
                checkText(v, depth: ctx.depth + 1)
            }
        case "tree":
            if let o = Self.value(of: "-o", in: a) { write(o, what: "writes") }
        case "less", "more":
            pagerRules(a, depth: ctx.depth)
        case "man":
            manRules(a, ctx)
        case "info":
            for (i, x) in a.enumerated() {
                if (x == "-o" || x == "--output" || x == "--dribble"), i + 1 < a.count { write(a[i + 1], what: "writes") }
                for opt in ["--output=", "--dribble="] where x.hasPrefix(opt) { write(String(x.dropFirst(opt.count)), what: "writes") }
            }
        case "pbpaste":
            // Read-only, but `shell.run` refuses it while the clipboard holds a concealed item.
            readsClipboard = true
            if loopDepth > 0 { clipboardReaderRepeats = true }
        case "hash":
            // `hash ls=/bin/rm` (zsh), `hash -p /bin/rm ls` (bash), `hash -d s=~/.ssh` (zsh named
            // folders): later names on the line run other programs or reach other folders.
            if a.contains(where: { (Self.shortCluster($0)?.contains("p") ?? false) || (!$0.hasPrefix("-") && $0.contains("=")) }) {
                acc.raise(.high, "makes a command or folder name point somewhere else (hash)")
            }
        case "history":
            let harmless = Set("nrdfEiDlm")
            if !a.allSatisfy({ $0.allSatisfy(\.isNumber) || (Self.shortCluster($0).map { c in c.allSatisfy { $0.isNumber || harmless.contains($0) } } ?? false) }) {
                acc.raise(.medium, "changes or replays shell history")
            }
        case "export", "typeset", "declare", "local", "readonly", "integer", "float", "private":
            declarationRules(prog, a, ctx)
        case "setenv":
            // csh/tcsh: setenv NAME value.
            acc.raise(.medium)
            if let name = a.first { envAssignment(name, value: a.count > 1 ? a[1] : "", appends: false, depth: ctx.depth) }
        case "read":
            readRules(a, ctx)
        case "printf":
            if let i = a.firstIndex(of: "-v"), i + 1 < a.count { assignsUnknown(a[i + 1], ctx) }
        case "set":
            if a.contains(where: { $0 == "-o" || $0 == "+o" }), a.contains(where: Self.hasRunTimeParts) { dotGlob = true; extendedGlob = true }
            // zsh `set -A name values…` assigns an array (`set -A path /tmp/x` changes PATH).
            if let i = a.firstIndex(where: { $0 == "-A" || $0 == "+A" }), i + 1 < a.count {
                envAssignment(a[i + 1], value: "(" + a[(i + 2)...].joined(separator: " ") + ")", appends: a[i] == "+A", depth: ctx.depth)
            }
        case "jobs":
            // bash `jobs -x cmd args` runs cmd.
            if let i = a.firstIndex(of: "-x"), i + 1 < a.count {
                checkWords(Array(a[(i + 1)...]), ctx: Context(piped: false, pipedFromDownload: false, heredoc: nil, hereString: nil,
                                                              substitutionDownloads: ctx.substitutionDownloads, depth: ctx.depth + 1))
            }
        case "let":
            // Every argument is an arithmetic expression, substitutions in it included.
            arithmetic = true
            for x in a { noteArithmetic(x, downloads: ctx.substitutionDownloads) }
        case "test":
            // Like `[`: only `-v` evaluates (a subscript), unless a ksh-like shell runs it.
            for (k, op) in a.enumerated() where Self.arithmeticTests.contains(op) && (op == "-v" || testIsArithmetic) {
                arithmetic = true
                for j in (op == "-v" ? [k + 1] : [k - 1, k + 1]) where j >= 0 && j < a.count {
                    noteArithmetic(a[j], downloads: ctx.substitutionDownloads)
                }
            }
        case "setopt", "unsetopt", "shopt":
            // An option name built at run time could be GLOB_DOTS or extended globbing.
            if a.contains(where: Self.hasRunTimeParts) { dotGlob = true; extendedGlob = true }
        case "unset":
            if a.contains(where: { $0.contains("[") }) { arithmetic = true }
        case "return", "exit", "shift", "break", "continue":
            // zsh evaluates these arguments as arithmetic.
            if a.contains(where: { !$0.allSatisfy(\.isNumber) }) { arithmetic = true }
        case "plistbuddy":
            plistBuddyRules(a)
        case _ where Self.readOnlyPrograms.contains(prog):
            break
        case "date":
            let ops = Self.operands(a, valueFlags: ["-r", "-f", "-v", "-z"])
            if !Self.hasShort(a, "j"), ops.contains(where: { !$0.hasPrefix("+") }) { acc.raise(.medium, "sets the clock") }
        case "top":
            if !(a.contains("-l") || a.contains(where: { $0.hasPrefix("-l") })) { acc.raise(.medium) }
        case "cd", "pushd":
            changeFolder(a, ctx)
        case "popd":
            // Back to a folder from the stack, which isn't tracked: anywhere it may have been.
            let before = currentFolderPatterns()
            cwd = nil
            cwdPatterns = oldCwd.map { [PathPattern(components: PathPattern.literalComponents($0), dynamic: false)] }
            addAlternates(before)

        default:
            acc.raise(.medium)
        }
    }

    // MARK: Rule groups

    mutating func findRules(_ a: [String], _ ctx: Context) {
        var starts: [String] = []
        var idx = 0
        // Leading options (-H -L -P -E -X -s -x -d -f path).
        while idx < a.count, ["-H", "-L", "-P", "-E", "-X", "-s", "-x", "-d"].contains(a[idx]) { idx += 1 }
        while idx < a.count, !a[idx].hasPrefix("-"), a[idx] != "(", a[idx] != "!", a[idx] != "\\(" { starts.append(a[idx]); idx += 1 }
        if starts.isEmpty { starts = ["."] }
        var hasDelete = false
        // Without any test (-name, -type, -mtime…) `-delete` removes the whole tree.
        var hasFilter = false
        let nonFilters: Set<String> = ["-delete", "-print", "-print0", "-depth", "-d", "-x", "-xdev", "-mount", "-follow", "-ls", "!", "(", ")", "-a", "-and", "-o", "-or", "-not"]
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x.hasPrefix("-"), !nonFilters.contains(x), !["-maxdepth", "-mindepth", "-exec", "-execdir", "-ok", "-okdir"].contains(x) { hasFilter = true }
            switch x {
            case "-delete":
                hasDelete = true
            case "-maxdepth", "-mindepth":
                idx += 1
            case "-exec", "-execdir", "-ok", "-okdir":
                var inner: [String] = []
                while idx < a.count, a[idx] != ";", a[idx] != "+" { inner.append(a[idx]); idx += 1 }
                idx += 1
                acc.raise(.medium, "runs a command for each file (find \(x))")
                if !inner.isEmpty {
                    loopDepth += 1
                    checkWords(inner, ctx: Context(piped: false, pipedFromDownload: false, heredoc: nil, hereString: nil, substitutionDownloads: ctx.substitutionDownloads, depth: ctx.depth + 1))
                    loopDepth -= 1
                }
            case "-fprint", "-fprint0", "-fprintf", "-fls":
                if idx < a.count { write(a[idx], what: "writes"); idx += 1 }
            default:
                break
            }
        }
        if hasDelete {
            acc.raise(.high, "deletes files (find -delete)")
            for s in starts { deletes(s, recursive: !hasFilter) }
        }
    }

    mutating func diskutilRules(_ a: [String]) {
        let ops = a.map { $0.lowercased() }
        let destructive = ["erase", "zero", "partition", "delete", "reformat", "randomdisk", "resize", "split", "merge", "destroy", "securerase", "secureerase"]
        if ops.contains(where: { op in destructive.contains { op.contains($0) } }) {
            acc.block("Glide won't erase, partition or resize disks.", reason: "erases or partitions disks")
            return
        }
        let readOnly: Set<String> = ["list", "info", "activity", "ls", "listfilesystems", "verifyvolume", "verifydisk"]
        if let sub = ops.first, readOnly.contains(sub) { return }
        if ops.first == "apfs" || ops.first == "cs" || ops.first == "corestorage", let s = ops.dropFirst().first, s.hasPrefix("list") { return }
        acc.raise(.medium, "changes disks or volumes (diskutil)")
    }

    mutating func tarRules(_ a: [String]) {
        guard let first = a.first else { return }
        // Mode letters can be bundled without a dash (tar xzf a.tgz).
        let modeCluster: String = first.hasPrefix("-") ? a.filter { $0.hasPrefix("-") && !$0.hasPrefix("--") }.map { String($0.dropFirst()) }.joined() : first
        let long = a.filter { $0.hasPrefix("--") }
        let extracting = modeCluster.contains("x") || long.contains("--extract") || long.contains("--get")
        let creating = modeCluster.contains("c") || modeCluster.contains("r") || modeCluster.contains("u") || long.contains("--create") || long.contains("--append")
        if !extracting && !creating { return } // -t lists
        acc.raise(.medium)
        if extracting {
            if let i = a.firstIndex(of: "-C"), i + 1 < a.count { write(a[i + 1], what: "extracts into") }
            else if let d = Self.longValue("--directory", in: a) { write(d, what: "extracts into") }
            else { write(".", what: "extracts into") }
        }
        if creating {
            // The archive is the word after the first cluster containing "f".
            if let i = a.firstIndex(where: { ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f")) || ($0 == first && !$0.hasPrefix("-") && $0.contains("f")) }),
               i + 1 < a.count, a[i + 1] != "-" {
                write(a[i + 1], what: "writes")
            }
        }
    }

    mutating func openRules(_ a: [String]) {
        acc.raise(.medium, "opens something on screen")
        var idx = 0
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x == "--args" { break }
            if ["-a", "-b", "-e", "-t", "-f", "-F", "-W", "-R", "-n", "-g", "-j", "-h", "-s", "-u"].contains(x) {
                if ["-a", "-b", "-s", "-u"].contains(x) { idx += 1 }
                continue
            }
            if x.hasPrefix("-") { continue }
            let lower = x.lowercased()
            if lower.hasPrefix("file:") || lower.hasPrefix("javascript:") { acc.raise(.high, "opens an unusual URL") }
            if Self.runsCode(path: x) { acc.raise(.high, "opens a file that runs code (\(x))") }
        }
    }

    mutating func awkRules(_ a: [String]) {
        var program: String?
        var progFile = false
        var idx = 0
        var endOfFlags = false
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if !endOfFlags, x == "--" { endOfFlags = true; continue }
            if !endOfFlags, x.hasPrefix("-"), x.count > 1 {
                if x == "-f" || x.hasPrefix("-f") { progFile = true; if x == "-f" { idx += 1 } }
                else if x == "-F" || x == "-v" { idx += 1 }
                else if x == "-i" { if idx < a.count, a[idx] == "inplace" { acc.raise(.medium, "edits files in place (awk -i inplace)") }; idx += 1 }
                continue
            }
            if program == nil && !progFile { program = x; continue }
        }
        if progFile { acc.raise(.medium, "runs an awk program file") }
        guard let p = program else { return }
        if p.range(of: #"\bsystem\s*\("#, options: .regularExpression) != nil {
            acc.raise(.high, "awk runs a shell command (system)")
        } else if p.range(of: #"(?<!\|)\|(?!\|)"#, options: .regularExpression) != nil {
            acc.raise(.high, "awk pipes to or from a shell command")
        } else if Self.awkPrintsToFile(p) {
            acc.raise(.medium, "awk writes to a file")
        }
    }

    /// An awk statement `print … > file` or `printf … > file`: a `print`/`printf` word with a
    /// `>` after it before the statement ends (`;`, `}` or a newline). One pass; a regex with an
    /// unbounded `[^;}]*` was quadratic over a long program of `print` and no `;`.
    static func awkPrintsToFile(_ program: String) -> Bool {
        var sawPrint = false
        var word = ""
        func endWord() {
            if word == "print" || word == "printf" { sawPrint = true }
            word = ""
        }
        for ch in program {
            if ch.isLetter || ch.isNumber || ch == "_" { word.append(ch); continue }
            endWord()
            if ch == ";" || ch == "}" || ch == "\n" { sawPrint = false; continue }
            if ch == ">", sawPrint { return true }
        }
        return false
    }

    mutating func sedRules(_ a: [String]) {
        var inPlace = false
        var scripts: [String] = []
        var scriptFile = false
        var operands: [String] = []
        var idx = 0
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x.hasPrefix("--in-place") { inPlace = true; continue }
            if x == "-e" || x == "--expression" { if idx < a.count { scripts.append(a[idx]); idx += 1 }; continue }
            if x.hasPrefix("--expression=") { scripts.append(String(x.dropFirst("--expression=".count))); continue }
            if x == "-f" || x == "--file" || x.hasPrefix("--file=") { scriptFile = true; if !x.contains("=") { idx += 1 }; continue }
            if x.hasPrefix("-"), !x.hasPrefix("--"), x.count > 1 {
                let cluster = x.dropFirst()
                if cluster.contains("i") || cluster.contains("I") {
                    inPlace = true
                    // BSD sed takes a (possibly empty) backup extension as the next word.
                    if (cluster == "i" || cluster == "I"), idx < a.count, a[idx].isEmpty || a[idx].hasPrefix(".") { idx += 1 }
                }
                if cluster.hasSuffix("e") && !cluster.contains("i") { if idx < a.count { scripts.append(a[idx]); idx += 1 } }
                if cluster.hasSuffix("f") { scriptFile = true; idx += 1 }
                continue
            }
            operands.append(x)
        }
        if scripts.isEmpty && !scriptFile, !operands.isEmpty { scripts.append(operands.removeFirst()) }
        if scriptFile { acc.raise(.medium, "runs a sed script file") }
        if inPlace {
            acc.raise(.medium, "edits files in place (sed -i)")
            for f in operands { write(f, what: "edits") }
        }
        for s in scripts {
            if s.range(of: #"(^|[;\n{}])\s*e(\s|$)"#, options: .regularExpression) != nil { acc.raise(.high, "sed runs a shell command") }
            if s.range(of: #"(^|[^A-Za-z0-9\\])w\s+\S"#, options: .regularExpression) != nil { acc.raise(.medium, "sed writes to a file") }
        }
    }

    mutating func defaultsRules(_ a: [String]) {
        var rest = a
        while let f = rest.first, f == "-currentHost" || f == "-host" {
            rest.removeFirst()
            if f == "-host", !rest.isEmpty { rest.removeFirst() }
        }
        let sub = rest.first?.lowercased() ?? ""
        let domain = rest.count > 1 ? substituteVariables(rest[1]) : ""
        switch sub {
        case "", "read", "read-type", "domains", "find", "help":
            return
        case "export":
            if rest.count >= 3, rest[2] != "-" { write(rest[2], what: "writes") }
            return
        case "delete":
            acc.raise(.high, "deletes preferences (defaults delete)")
        case "write", "import", "rename":
            acc.raise(.medium, "changes app preferences")
        default:
            acc.raise(.medium)
        }
        // Glide's settings, by bundle identifier, by app (`-app Glide`) or by plist path.
        if PathRules.isGlidePreferenceDomain(domain) { acc.raise(.high, "changes Glide's own settings") }
        if domain == "-app", rest.count > 2 {
            let app = rest[2].lowercased()
            if app.contains("glide") || app.contains("notchbuddy") { acc.raise(.high, "changes Glide's own settings") }
        }
        if domain.contains("/") || domain.hasPrefix("~") || domain.hasPrefix("$") {
            guard let p = resolve(domain) else {
                acc.raise(.high, "changes preferences in a file chosen at run time")
                return
            }
            // `defaults` adds .plist to a path that doesn't end in it.
            let file = p.lowercased().hasSuffix(".plist") ? p : p + ".plist"
            if PathRules.isGlidePreferenceDomain((p as NSString).lastPathComponent) || PathRules.isGlidePreferenceFile(file, home: home) {
                acc.raise(.high, "changes Glide's own settings")
            }
            switch PathRules.writeZone(file, home: home) {
            case .outside: acc.raise(.high, "changes system-wide preferences (\(display(p)))")
            case .sensitive: acc.raise(.high, "changes \(PathRules.display(file, home: home)), which affects security or startup")
            case .allowed, .discard: break
            }
        }
    }

    /// `less`/`more`: reading is fine, but `+!cmd` runs a shell command, `-o file` writes the
    /// input to a file, and a lesskey file can bind keys to commands.
    mutating func pagerRules(_ a: [String], depth: Int) {
        let takesValue = Set("bhjkoOpPtTxyz#")
        var idx = 0
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x == "--" { break }
            if x.hasPrefix("+") {
                if let bang = x.firstIndex(where: { $0 == "!" || $0 == "|" }) {
                    acc.raise(.high, "runs a shell command from the pager (\(x))")
                    checkText(String(x[x.index(after: bang)...]), depth: depth + 1)
                }
                continue
            }
            if x.hasPrefix("--") {
                let name = x.split(separator: "=", maxSplits: 1).first.map(String.init) ?? x
                let inline: String? = x.contains("=") ? String(x.drop { $0 != "=" }.dropFirst()) : nil
                if name.lowercased() == "--log-file" {
                    if let v = inline ?? (idx < a.count ? a[idx] : nil) { write(v, what: "writes") }
                    if inline == nil { idx += 1 }
                } else if name.hasPrefix("--lesskey") {
                    acc.raise(.medium, "reads pager key bindings from a file")
                    if inline == nil { idx += 1 }
                }
                continue
            }
            guard let cluster = Self.shortCluster(x) else { continue }
            let chars = Array(cluster)
            for (k, ch) in chars.enumerated() where takesValue.contains(ch) {
                let attached = String(chars[(k + 1)...])
                let v = attached.isEmpty ? (idx < a.count ? a[idx] : nil) : attached
                if attached.isEmpty { idx += 1 }
                if ch == "o" || ch == "O", let v { write(v, what: "writes") }
                if ch == "k" { acc.raise(.medium, "reads pager key bindings from a file") }
                break
            }
        }
    }

    /// macOS `man` is a shell script that runs its pager and its config file's tools through
    /// `eval`: `-P` names that command, `-C` a config file of commands.
    mutating func manRules(_ a: [String], _ ctx: Context) {
        let takesValue = Set("CMPSmp")
        var idx = 0
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x == "--" { break }
            guard let cluster = Self.shortCluster(x) else { continue }
            let chars = Array(cluster)
            for (k, ch) in chars.enumerated() where takesValue.contains(ch) {
                let attached = String(chars[(k + 1)...])
                let v = attached.isEmpty ? (idx < a.count ? a[idx] : "") : attached
                if attached.isEmpty { idx += 1 }
                switch ch {
                case "P":
                    acc.raise(.high, "runs a pager command (man -P)")
                    checkText(v, depth: ctx.depth + 1)
                case "C":
                    acc.raise(.high, "reads man settings that name programs to run (man -C)")
                case "M":
                    acc.raise(.medium, "reads manual pages from another folder (man -M)")
                default:
                    break
                }
                break
            }
        }
    }

    /// `export`, `typeset`, `declare`, `local`, `readonly`, `integer`, `float`: each
    /// `NAME=value` is an assignment that lasts for the rest of the line; `-i` (and zsh's
    /// floats) make values arithmetic.
    mutating func declarationRules(_ prog: String, _ a: [String], _ ctx: Context) {
        var flags = Set<Character>()
        for x in a {
            if (x.hasPrefix("-") || x.hasPrefix("+")) && x.count > 1 && !x.contains("=") { flags.formUnion(x.dropFirst()); continue }
            if Self.isAssignment(x) {
                // `local x=$(cmd)` takes command output like `x=$(cmd)` does; an integer or float
                // declaration (`typeset -i x=$(cmd)`) evaluates the value as arithmetic right away.
                let value = x.drop { $0 != "=" }.dropFirst()
                let fromOutput = Self.hasSubstitutionMarker(value) && !ctx.substitutionsNumeric
                assignment(x, persists: true, depth: ctx.depth, valueIsCommandOutput: fromOutput, valueSubDownloads: ctx.substitutionDownloads)
                if prog == "integer" || prog == "float" || flags.contains("i") || flags.contains("F") || flags.contains("E") {
                    arithmetic = true
                    if fromOutput { noteArithmetic(value, downloads: ctx.substitutionDownloads) }
                    else { arithmeticReads.formUnion(Self.arithmeticNames(value)) }
                }
                // bash `declare -n r=PATH`: assigning r later assigns PATH.
                if flags.contains("n"), let target = x.split(separator: "=", maxSplits: 1).last.map(String.init), Self.isRiskyVariable(target) {
                    acc.raise(.high, "makes another name for \(target), which programs use to find or run code")
                }
            } else if x.contains("[") {
                arithmetic = true
            } else if !x.hasPrefix("-") && !x.hasPrefix("+"), Self.commandVariables.contains(x) || Self.codeVariables.contains(x)
                        || Self.codeVariablePrefixes.contains(where: { x.hasPrefix($0) }) {
                // `export GIT_SSH_COMMAND` (value set elsewhere on the line, e.g. by a loop):
                // exporting a code-running variable is judged like assigning it, with the value
                // the line gave it when that's known (`PAGER=cat; export PAGER`). Every way of
                // giving it an unknown or risky value was judged when it happened and left
                // `vars` empty, so a stale inert value can't hide one.
                envAssignment(x, value: vars[x], appends: false, depth: ctx.depth)
            }
        }
        if prog == "integer" || prog == "float" || flags.contains("i") || flags.contains("F") || flags.contains("E") { arithmetic = true }
    }

    /// `read NAME…`: each name gets a value from input, so it's an assignment of unknown text
    /// (`read PATH <<< /tmp/x` changes where programs are found).
    mutating func readRules(_ a: [String], _ ctx: Context) {
        let withValue: Set<String> = ["-d", "-i", "-n", "-N", "-p", "-t", "-u", "-k"]
        var idx = 0
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x == "--" {
                for name in a[idx...] { assignsUnknown(name, ctx) }
                break
            }
            if x.hasPrefix("-"), x.count > 1 {
                if x == "-a", idx < a.count { assignsUnknown(a[idx], ctx); idx += 1 }
                else if withValue.contains(x) { idx += 1 }
                continue
            }
            assignsUnknown(x, ctx)
        }
    }

    /// `/usr/libexec/PlistBuddy -c 'Set :key value' file` edits the file; without `-c` it
    /// takes commands from standard input.
    mutating func plistBuddyRules(_ a: [String]) {
        var commands: [String] = []
        var file: String?
        var idx = 0
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x == "-c", idx < a.count { commands.append(a[idx].lowercased()); idx += 1; continue }
            if x.hasPrefix("-") { continue }
            file = x
        }
        let editing = ["set", "add", "delete", "merge", "import", "clear", "copy", "save"]
        guard commands.isEmpty || commands.contains(where: { c in editing.contains { c.trimmingCharacters(in: .whitespaces).hasPrefix($0) } }) else { return }
        acc.raise(.medium)
        if let file { write(file, what: "edits") }
    }

    mutating func curlRules(_ a: [String]) {
        let getForced = a.contains("--get") || a.contains { Self.shortCluster($0)?.contains("G") ?? false }
        var idx = 0
        func data(_ v: String?) {
            guard !getForced else { return }
            if let v, v.hasPrefix("@") { acc.raise(.high, "uploads a local file (curl)") } else { acc.raise(.high, "sends data to a server (curl)") }
        }
        func method(_ v: String?) {
            let m = (v ?? "").uppercased()
            if !["GET", "HEAD", "OPTIONS", ""].contains(m) { acc.raise(.high, "sends a \(m) request (curl)") }
        }
        func output(_ v: String?) {
            guard let v, v != "-" else { return }
            write(v, what: "downloads to")
            if let p = resolve(v) { downloadedFiles.insert(p.lowercased()) }
        }
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x == "--" { break }
            if x.hasPrefix("--") {
                let parts = x.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0]
                let inline: String? = parts.count > 1 ? parts[1] : nil
                func val() -> String? {
                    if let inline { return inline }
                    guard idx < a.count else { return nil }
                    idx += 1
                    return a[idx - 1]
                }
                switch name {
                case "--output": output(val())
                case "--output-dir": if let v = val() { write(v, what: "downloads into") }
                case "--remote-name", "--remote-name-all", "--remote-header-name": write(".", what: "downloads into")
                case "--upload-file": _ = val(); acc.raise(.high, "uploads a local file (curl)")
                case "--form", "--form-string": _ = val(); acc.raise(.high, "sends form data (curl)")
                case "--data", "--data-binary", "--data-raw", "--data-ascii", "--data-urlencode", "--json": data(val())
                case "--request": method(val())
                case "--config": _ = val(); acc.raise(.medium, "reads curl options from a file")
                case "--cookie-jar", "--dump-header", "--trace", "--trace-ascii", "--libcurl", "--stderr", "--etag-save", "--hsts", "--alt-svc":
                    if let v = val(), v != "-" { write(v, what: "writes") }
                default:
                    break
                }
                continue
            }
            guard let cluster = Self.shortCluster(x) else { continue }
            let chars = Array(cluster)
            for (k, ch) in chars.enumerated() {
                if Self.curlArgFlags.contains(ch) {
                    let v: String?
                    if k + 1 < chars.count { v = String(chars[(k + 1)...]) } else if idx < a.count { v = a[idx]; idx += 1 } else { v = nil }
                    switch ch {
                    case "o": output(v)
                    case "T": acc.raise(.high, "uploads a local file (curl)")
                    case "d": data(v)
                    case "F": acc.raise(.high, "sends form data (curl)")
                    case "X": method(v)
                    case "K": acc.raise(.medium, "reads curl options from a file")
                    case "c": if let v, v != "-" { write(v, what: "writes") }
                    case "D": if let v, v != "-" { write(v, what: "writes") }
                    default: break
                    }
                    break
                }
                if ch == "O" { write(".", what: "downloads into") }
            }
        }
    }

    mutating func wgetRules(_ a: [String]) {
        var toStdout = false
        var spider = false
        var outFile: String?
        var idx = 0
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x.hasPrefix("--") {
                let parts = x.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0]
                func val() -> String? {
                    if parts.count > 1 { return parts[1] }
                    guard idx < a.count else { return nil }
                    idx += 1
                    return a[idx - 1]
                }
                switch name {
                case "--output-document": if let v = val() { if v == "-" { toStdout = true } else { outFile = v } }
                case "--spider": spider = true
                case "--post-data", "--post-file", "--body-data", "--body-file": _ = val(); acc.raise(.high, "sends data to a server (wget)")
                case "--method":
                    let m = (val() ?? "").uppercased()
                    if !["GET", "HEAD", "OPTIONS", ""].contains(m) { acc.raise(.high, "sends a \(m) request (wget)") }
                case "--output-file", "--append-output", "--directory-prefix": if let v = val() { write(v, what: "writes") }
                default: break
                }
                continue
            }
            guard let cluster = Self.shortCluster(x) else { continue }
            let chars = Array(cluster)
            for (k, ch) in chars.enumerated() where Self.wgetArgFlags.contains(ch) {
                let v: String?
                if k + 1 < chars.count { v = String(chars[(k + 1)...]) } else if idx < a.count { v = a[idx]; idx += 1 } else { v = nil }
                if ch == "O", let v { if v == "-" { toStdout = true } else { outFile = v } }
                if (ch == "o" || ch == "a" || ch == "P"), let v { write(v, what: "writes") }
                break
            }
        }
        if spider || (toStdout && outFile == nil) { return }
        acc.raise(.medium, "downloads a file (wget)")
        write(outFile ?? ".", what: "downloads to")
        if let f = outFile, let p = resolve(f) { downloadedFiles.insert(p.lowercased()) }
    }

    mutating func osascriptRules(_ a: [String], _ ctx: Context) {
        var scripts: [String] = []
        var language = ScriptSafety.Language.appleScript
        var file: String?
        var idx = 0
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if file != nil { break } // the rest are arguments to the script
            switch x {
            case "-e": if idx < a.count { scripts.append(a[idx]); idx += 1 }
            case "-l": if idx < a.count { language = a[idx].lowercased().hasPrefix("javascript") ? .javaScript : .appleScript; idx += 1 }
            case "-s": idx += 1
            case "-i": break
            default: file = x
            }
        }
        func judge(_ source: String) {
            let v = ScriptSafety.assess(source, language: language)
            acc.raise(v.risk)
            for r in v.reasons { acc.raise(v.risk, r) }
            for cmd in ScriptSafety.embeddedShellCommands(source) { checkText(cmd, depth: ctx.depth + 1) }
            // `osascript -e "$script"`: the script itself is only known at run time.
            if language == .appleScript, Self.hasRunTimeParts(source) { acc.raise(.high, "runs AppleScript built at run time") }
            // Visible script text is read for ways to reach the clipboard (naming it, pasting,
            // the ObjC bridge, names built at run time); `return 1 + 1` has none.
            if Self.hasRunTimeParts(source) || ScriptSafety.mayReadClipboard(source, language: language) { scriptRuns() }
        }
        /// A script that may read the clipboard: the concealed-item guard applies, and doing so
        /// in a loop counts as reading it repeatedly.
        func scriptRuns() {
            runsScriptCode = true
            if loopDepth > 0 { clipboardReaderRepeats = true }
        }
        if !scripts.isEmpty {
            judge(scripts.joined(separator: "\n"))
            return
        }
        if let f = file, f != "-" {
            if let p = resolve(f), downloadedFiles.contains(p.lowercased()) { acc.block(Self.downloadIntoShell, reason: "runs a file it just downloaded") }
            if ctx.substitutionDownloads { acc.block(Self.downloadIntoShell, reason: "runs downloaded content") }
            acc.raise(.medium, "runs an AppleScript file")
            scriptRuns()
            return
        }
        if let body = ctx.heredoc ?? ctx.hereString {
            judge(body)
        } else if ctx.pipedFromDownload {
            acc.block(Self.downloadIntoShell, reason: "runs downloaded content")
            scriptRuns()
        } else if ctx.piped {
            acc.raise(.high, "runs a script piped from another command")
            scriptRuns()
        }
    }

    mutating func shellRules(_ prog: String, _ a: [String], _ ctx: Context) {
        // ksh's `test`/`[` evaluate `-eq` operands as arithmetic, unlike zsh's and bash's.
        if Self.arithmeticTestShells.contains(prog) { testIsArithmetic = true }
        var expectCommand = false
        var commandString: String?
        var scriptFile: String?
        var readsStdin = false
        var idx = 0
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if expectCommand { commandString = x; break }
            if x == "-" { readsStdin = true; break }
            if x == "--" { if idx < a.count { scriptFile = a[idx] }; break }
            if x.hasPrefix("--") { continue }
            if x == "-o" || x == "+o" || x == "-O" || x == "+O" { idx += 1; continue }
            if (x.hasPrefix("-") || x.hasPrefix("+")), x.count > 1 {
                if x.contains("c") { expectCommand = true }
                if x.contains("s") { readsStdin = true }
                continue
            }
            scriptFile = x
            break
        }
        if expectCommand {
            if ctx.substitutionDownloads { acc.block(Self.downloadIntoShell, reason: "runs downloaded content") }
            if let s = commandString {
                // Another shell process: its `cd`s don't move this one.
                let saved = folderState
                checkText(s, depth: ctx.depth + 1)
                folderState = saved
                let known = substituteVariables(s)
                if known != s {
                    checkText(known, depth: ctx.depth + 1)
                    folderState = saved
                }
            }
            return
        }
        if let f = scriptFile, !readsStdin {
            if ctx.substitutionDownloads { acc.block(Self.downloadIntoShell, reason: "runs downloaded content") }
            if let p = resolve(f), downloadedFiles.contains(p.lowercased()) { acc.block(Self.downloadIntoShell, reason: "runs a file it just downloaded") }
            acc.raise(.medium, "runs a shell script")
            return
        }
        // Commands come from standard input.
        if let body = ctx.heredoc { checkText(body, depth: ctx.depth + 1) }
        else if let s = ctx.hereString {
            if ctx.substitutionDownloads { acc.block(Self.downloadIntoShell, reason: "runs downloaded content") }
            checkText(s, depth: ctx.depth + 1)
        } else if ctx.pipedFromDownload {
            acc.block(Self.downloadIntoShell, reason: "pipes downloaded content into a shell")
        } else if ctx.piped {
            acc.raise(.high, "runs commands piped from another command")
            if let text = ctx.pipedText { checkText(text, depth: ctx.depth + 1) }
        }
    }

    mutating func interpreterRules(_ prog: String, _ a: [String], _ ctx: Context) {
        let codeFlags: Set<String>
        switch prog {
        case "python", "python2", "python3": codeFlags = ["-c"]
        case "perl": codeFlags = ["-e", "-E"]
        case "node", "nodejs", "bun", "deno": codeFlags = ["-e", "--eval", "-p", "--print", "eval"]
        case "php": codeFlags = ["-r"]
        case "pwsh": codeFlags = ["-c", "-Command", "-command"]
        default: codeFlags = ["-e"]
        }
        var code: String?
        var script: String?
        var idx = 0
        // `swift build`, `swift test`…: the package manager, not a script (like `make`).
        if prog == "swift", let sub = a.first(where: { !$0.hasPrefix("-") }), Self.swiftSubcommands.contains(sub), a.first == sub {
            if sub != "help" { acc.raise(.medium, "runs swift \(sub)") }
            return
        }
        /// Code runs that Glide can't fully see: the concealed-clipboard guard applies.
        func codeRuns() {
            runsScriptCode = true
            if loopDepth > 0 { clipboardReaderRepeats = true }
        }
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if codeFlags.contains(x) { code = idx < a.count ? a[idx] : ""; break }
            if let f = codeFlags.first(where: { $0.count == 2 && x.hasPrefix($0) && x.count > 2 }) { code = String(x.dropFirst(f.count)); break }
            if x == "-m", prog.hasPrefix("python") {
                let module = idx < a.count ? a[idx] : ""
                if module == "pip" { pipRules(Array(a.dropFirst(idx + 1))) } else { acc.raise(.medium, "runs the Python module \(module)") }
                return
            }
            if x.hasPrefix("-") { continue }
            script = x
            break
        }
        if ctx.substitutionDownloads { acc.block(Self.downloadIntoShell, reason: "runs downloaded content") }
        if let code { judgeInlineCode(code, prog: prog); codeRuns(); return }
        if let s = script {
            if let p = resolve(s), downloadedFiles.contains(p.lowercased()) { acc.block(Self.downloadIntoShell, reason: "runs a file it just downloaded") }
            acc.raise(.medium, "runs a \(prog) script")
            codeRuns()
            return
        }
        if let body = ctx.heredoc ?? ctx.hereString { judgeInlineCode(body, prog: prog); codeRuns() }
        else if ctx.pipedFromDownload { acc.block(Self.downloadIntoShell, reason: "pipes downloaded content into \(prog)"); codeRuns() }
        else if ctx.piped { acc.raise(.high, "runs \(prog) code piped from another command"); codeRuns() }
        // Otherwise only options (`--version`, `--help`): nothing runs.
    }

    /// `swift` subcommands of the toolchain (`swift build`, `swift test`…), as opposed to
    /// `swift script.swift`.
    static let swiftSubcommands: Set<String> = ["build", "test", "run", "package", "repl", "format", "sdk", "experimental-sdk", "help",
                                                "migrate", "demangle", "symbolgraph-extract", "api-digester"]
    /// Shells whose `test`/`[` evaluate their operands as arithmetic.
    static let arithmeticTestShells: Set<String> = ["ksh", "mksh", "ksh93", "pdksh", "oksh", "yash"]

    mutating func judgeInlineCode(_ code: String, prog: String) {
        let dangerous = #"\b(system|subprocess|popen|exec[a-z]*|spawn[a-z]*|rmtree|remove|unlink|rmdir|kill|child_process|eval|shell_exec|passthru|os\.rm|rm_rf|rm_r|truncate|chmod|chown)\b"#
        // `$(…)` in the code means the shell fills it in at run time (`python3 -c "$(cat x)"`).
        if code.range(of: dangerous, options: [.regularExpression, .caseInsensitive]) != nil || code.contains("`") || code.contains("$(…)") {
            acc.raise(.high, "runs inline \(prog) code that can delete files or run commands")
        } else {
            acc.raise(.medium, "runs inline \(prog) code")
        }
    }

    mutating func pipRules(_ a: [String]) {
        subcommandRules(a, low: ["list", "show", "freeze", "check", "help", "--version", "-V", "search", "inspect", "index", "debug"],
                        high: ["uninstall", "remove"], highReason: "removes Python packages")
    }

    mutating func systemSettingRules(_ prog: String, _ a: [String]) {
        switch prog {
        case "pkgutil":
            if a.contains(where: { ["--pkgs", "--packages", "--files", "--pkg-info", "--file-info", "--export-plist", "--payload-files", "--check-signature", "--pkg-groups", "--group-pkgs"].contains($0) }) { return }
        case "codesign":
            if a.contains(where: { ["-d", "--display", "-v", "--verify", "-dv", "-dvv", "-dvvv", "-vv", "-vvv", "-h", "--hosting"].contains($0) }) && !a.contains(where: { ["-s", "--sign", "--remove-signature"].contains($0) }) { return }
            acc.raise(.medium, "signs code")
            return
        case "softwareupdate":
            if a.contains(where: { ["-l", "--list", "--history", "--help", "-h"].contains($0) }) { return }
            acc.raise(.medium, "installs system updates")
            return
        case "systemextensionsctl":
            if a.first == "list" { return }
        case "profiles":
            if let s = a.first, ["list", "show", "status", "-p", "-P", "-L", "-C"].contains(s), !a.contains(where: { ["-R", "-I", "-D", "remove", "install"].contains($0) }) { return }
        default:
            break
        }
        acc.raise(.high, "changes system or security settings (\(prog))")
    }

    /// Shared shape of package managers and CLIs: a subcommand that is read-only, destructive,
    /// or (anything else) a local change.
    mutating func subcommandRules(_ a: [String], low: Set<String>, high: Set<String>, highReason: String) {
        guard let sub = a.first(where: { !$0.hasPrefix("-") || low.contains($0) }) else { return }
        if high.contains(sub) { acc.raise(.high, highReason); return }
        if low.contains(sub) { return }
        acc.raise(.medium)
    }

    mutating func ghRules(_ a: [String]) {
        let ops = a.filter { !$0.hasPrefix("-") }
        guard let group = ops.first else { return }
        if ["--version", "version", "help", "status", "browse", "search"].contains(group) { return }
        if group == "api" {
            let m = Self.value(of: "-X", in: a) ?? Self.value(of: "--method", in: a) ?? Self.longValue("--method", in: a)
            let hasFields = a.contains { ["-f", "-F", "--field", "--raw-field", "--input"].contains($0) }
            if (m.map { !["GET", "HEAD"].contains($0.uppercased()) } ?? false) || hasFields { acc.raise(.high, "changes things on GitHub (gh api)") }
            return
        }
        let verb = ops.dropFirst().first ?? ""
        let readVerbs: Set<String> = ["list", "view", "status", "diff", "checks", "ls", "download"]
        let writeVerbs: Set<String> = ["create", "delete", "merge", "close", "comment", "edit", "review", "reopen", "ready", "upload", "publish",
                                       "sync", "archive", "rename", "transfer", "lock", "unlock", "pin", "unpin", "remove", "set", "add", "cancel", "rerun", "run", "enable", "disable", "deploy"]
        if readVerbs.contains(verb) || (group == "auth" && verb == "status") { return }
        if writeVerbs.contains(verb) { acc.raise(.high, "changes things on GitHub (gh \(group) \(verb))"); return }
        acc.raise(.medium)
    }

    mutating func gitRules(_ a: [String], _ ctx: Context) {
        var idx = 0
        while idx < a.count, a[idx].hasPrefix("-") {
            let x = a[idx]
            idx += 1
            if x == "-c", idx < a.count { gitConfigOverride(a[idx], depth: ctx.depth) }
            if x.hasPrefix("--config-env") || x.hasPrefix("--exec-path=") || x.hasPrefix("--upload-pack") || x.hasPrefix("--receive-pack") {
                acc.raise(.high, "runs a program set on the command line (git \(x.split(separator: "=").first ?? ""))")
                if x.hasPrefix("--upload-pack=") || x.hasPrefix("--receive-pack=") { checkText(String(x.drop { $0 != "=" }.dropFirst()), depth: ctx.depth + 1) }
            }
            if x == "-C" || x == "-c" || x == "--git-dir" || x == "--work-tree" || x == "--namespace" { idx += 1 }
            if ["--version", "--help", "-h", "--exec-path", "--html-path", "--man-path", "--info-path"].contains(x) { return }
        }
        guard idx < a.count else { return }
        let sub = a[idx]
        let rest = Array(a[(idx + 1)...])
        func has(_ flags: String...) -> Bool { rest.contains { flags.contains($0) } }
        // Even read-only subcommands take options that name a program to run.
        gitSubcommandPrograms(sub, rest, ctx)
        let readOnly: Set<String> = ["status", "log", "diff", "show", "rev-parse", "ls-files", "ls-tree", "ls-remote", "blame", "describe", "shortlog", "grep",
                                     "cat-file", "rev-list", "name-rev", "whatchanged", "count-objects", "fsck", "help", "version", "check-ignore", "check-attr",
                                     "var", "merge-base", "cherry", "for-each-ref", "show-ref", "diff-tree", "diff-index", "diff-files", "show-branch",
                                     "annotate", "range-diff", "verify-commit", "verify-tag"]
        if readOnly.contains(sub) {
            if rest.contains(where: { $0.hasPrefix("--output") }) { acc.raise(.medium) }
            return
        }
        switch sub {
        case "branch":
            if has("-D") || (has("-d", "--delete") && has("-f", "--force")) { acc.raise(.high, "deletes a branch (git branch -D)") }
            else if has("-d", "--delete", "-m", "-M", "-c", "-C", "--move", "--copy", "-u", "--set-upstream-to", "--unset-upstream", "--edit-description", "-f", "--force") { acc.raise(.medium) }
            else if !has("--list", "-l"), rest.contains(where: { !$0.hasPrefix("-") }) { acc.raise(.medium) }
        case "remote":
            if rest.isEmpty || ["-v", "--verbose", "show", "get-url"].contains(rest[0]) { return }
            acc.raise(.medium)
        case "tag":
            if rest.isEmpty || has("-l", "--list", "-n", "--contains", "--points-at", "--merged", "--no-merged", "-v", "--verify") { return }
            acc.raise(.medium)
        case "config":
            if has("--get", "--get-all", "--get-regexp", "--list", "-l", "--get-urlmatch", "--get-color", "--get-colorbool") { return }
            var ops = Self.operands(rest, valueFlags: ["-f", "--file", "--blob", "--type", "--default", "--comment", "--value"])
            // git 2.46+ spells the action as a word: `git config set key value`.
            if let verb = ops.first, ["get", "list", "get-color", "get-colorbool"].contains(verb) { return }
            if let verb = ops.first, ["set", "unset", "edit", "rename-section", "remove-section"].contains(verb) { ops.removeFirst(); acc.raise(.medium) }
            // Saving a setting that names a program is the same as `git -c` with it, only lasting.
            if ops.count >= 2 { gitConfigOverride("\(ops[0])=\(ops[1])", depth: ctx.depth) }
            if rest.filter({ !$0.hasPrefix("-") }).count <= 1 && !has("--unset", "--unset-all", "--remove-section", "--rename-section", "--edit", "-e", "--add", "--replace-all") { return }
            acc.raise(.medium)
        case "stash":
            if let s = rest.first, ["list", "show"].contains(s) { return }
            if let s = rest.first, ["drop", "clear"].contains(s) { acc.raise(.high, "discards stashed changes (git stash \(s))"); return }
            acc.raise(.medium)
        case "reflog":
            if let s = rest.first, ["expire", "delete"].contains(s) { acc.raise(.high, "permanently removes history (git reflog \(s))") }
        case "worktree":
            if rest.first == "list" { return }
            if let s = rest.first, ["remove", "prune"].contains(s) { acc.raise(.high, "deletes a worktree (git worktree \(s))"); return }
            acc.raise(.medium)
        case "push":
            acc.raise(.high, has("-f", "--force", "--force-with-lease", "--mirror", "--delete", "-d") ? "force-pushes or deletes on a remote (git push)" : "pushes to a remote (git push)")
        case "reset":
            if has("--hard", "--merge", "--keep") { acc.raise(.high, "discards uncommitted changes (git reset --hard)") } else { acc.raise(.medium) }
        case "rebase":
            acc.raise(.high, "rewrites history (git rebase)")
        case "clean":
            if has("-n", "--dry-run") || rest.contains(where: { (Self.shortCluster($0)?.contains("n") ?? false) }) { return }
            acc.raise(.high, "deletes untracked files (git clean)")
        case "rm":
            if has("--cached") { acc.raise(.medium) } else { acc.raise(.high, "deletes files (git rm)") }
        case "checkout":
            if has("--", ".", "-f", "--force", "-p", "--patch", "--theirs", "--ours") { acc.raise(.high, "discards uncommitted changes (git checkout)") } else { acc.raise(.medium) }
        case "restore":
            if has("--staged", "-S") && !has("--worktree", "-W") { acc.raise(.medium) } else { acc.raise(.high, "discards uncommitted changes (git restore)") }
        case "switch":
            if has("--discard-changes", "-f", "--force") { acc.raise(.high, "discards uncommitted changes (git switch -f)") } else { acc.raise(.medium) }
        case "filter-branch", "filter-repo", "replace":
            acc.raise(.high, "rewrites history (git \(sub))")
        case "update-ref":
            if has("-d") { acc.raise(.high, "deletes a ref (git update-ref -d)") } else { acc.raise(.medium) }
        case "gc":
            if rest.contains(where: { $0.hasPrefix("--prune=now") || $0.hasPrefix("--prune=all") }) { acc.raise(.high, "permanently removes unreachable commits") } else { acc.raise(.medium) }
        case "prune":
            acc.raise(.high, "permanently removes unreachable commits (git prune)")
        case "send-email", "request-pull", "imap-send":
            acc.raise(.high, "sends email (git \(sub))")
        default:
            acc.raise(.medium)
        }
    }

    /// `git -c key=value` (or a saved `git config key value`): some settings name a program
    /// git will run, which makes an otherwise read-only `git log` arbitrary code execution.
    mutating func gitConfigOverride(_ kv: String, depth: Int) {
        let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return }
        let key = first.lowercased()
        let value = parts.count > 1 ? parts[1] : ""
        if key.hasPrefix("alias.") {
            if value.hasPrefix("!") {
                acc.raise(.high, "defines a git alias that runs a shell command")
                checkText(String(value.dropFirst()), depth: depth + 1)
            } else {
                // An alias for other git options (`ls-remote --upload-pack=…`) is judged as one.
                checkText("git " + value, depth: depth + 1)
            }
            return
        }
        let programKeys: Set<String> = ["core.pager", "core.editor", "core.sshcommand", "core.fsmonitor", "core.hookspath", "core.askpass",
                                        "diff.external", "sequence.editor", "credential.helper", "gpg.program", "gpg.ssh.program",
                                        "uploadpack.packobjectshook", "protocol.ext.allow", "protocol.allow", "core.gitproxy", "merge.tool", "diff.tool",
                                        "interactive.difffilter", "init.templatedir", "sendemail.smtpserver", "sendemail.tocmd", "sendemail.cccmd"]
        let programSuffixes = [".textconv", ".command", ".cmd", ".process", ".clean", ".smudge", ".path", ".helper", ".driver", ".program",
                               ".uploadpack", ".receivepack"]
        // A pager that only shows text (`core.pager=cat`, `pager.log=less -R`) is the same as
        // `GIT_PAGER=cat`, and `pager.<cmd>=true|false` is a switch, not a program.
        if key == "core.pager" || key.hasPrefix("pager.") {
            if !value.hasPrefix("!"), Self.isInertCommand(value) { return }
            if key.hasPrefix("pager."), ["true", "false", "yes", "no", "on", "off", "1", "0"].contains(value.lowercased()) { return }
        }
        if programKeys.contains(key) || programSuffixes.contains(where: { key.hasSuffix($0) }) || key.hasPrefix("pager.") || value.hasPrefix("!") {
            acc.raise(.high, "runs a program set on the command line (git -c \(key))")
            // Settings that hold a shell command line are judged as one too (paths and
            // program names, like include.path or gpg.program, aren't commands).
            let commandKeys: Set<String> = ["core.pager", "core.editor", "core.sshcommand", "core.fsmonitor", "core.askpass", "core.gitproxy",
                                            "diff.external", "sequence.editor", "uploadpack.packobjectshook", "interactive.difffilter",
                                            "sendemail.tocmd", "sendemail.cccmd"]
            let commandSuffixes = [".textconv", ".command", ".cmd", ".process", ".clean", ".smudge", ".driver"]
            if value.hasPrefix("!") {
                checkText(String(value.dropFirst()), depth: depth + 1)
            } else if !value.isEmpty, commandKeys.contains(key) || commandSuffixes.contains(where: { key.hasSuffix($0) }) || key.hasPrefix("pager.") {
                checkText(value, depth: depth + 1)
            }
        }
    }

    /// Options after the git subcommand that name a program git runs, most of them through
    /// the shell: `ls-remote --upload-pack=…`, `grep -O…`, `rebase --exec`, `bisect run`….
    mutating func gitSubcommandPrograms(_ sub: String, _ rest: [String], _ ctx: Context) {
        func runs(_ option: String, _ value: String?) {
            acc.raise(.high, "runs a program set on the command line (git \(sub) \(option))")
            if let value, !value.isEmpty { checkText(value, depth: ctx.depth + 1) }
        }
        // Git's parse-options accepts any unambiguous prefix of a long option, so `--upl` is
        // `--upload-pack`. Map an abbreviation back to the dangerous option it stands for.
        let dangerousLong = ["upload-pack", "receive-pack", "exec", "extcmd", "open-files-in-pager", "config", "template"]
        func canonicalLong(_ name: String) -> String? {
            guard name.hasPrefix("--"), name.count > 2 else { return nil }
            let bare = String(name.dropFirst(2))
            if dangerousLong.contains(bare) { return bare }
            // A prefix of at least three characters that begins one of them (git needs ≥1 but
            // may be ambiguous; over-matching only asks for approval it would otherwise skip).
            guard bare.count >= 3 else { return nil }
            let hits = dangerousLong.filter { $0.hasPrefix(bare) }
            return hits.first
        }
        var idx = 0
        while idx < rest.count {
            let x = rest[idx]
            idx += 1
            if x == "--" { break }
            let name = x.split(separator: "=", maxSplits: 1).first.map(String.init) ?? x
            let inline: String? = x.contains("=") && x.hasPrefix("--") ? String(x.drop { $0 != "=" }.dropFirst()) : nil
            func value() -> String? {
                if let inline { return inline }
                guard idx < rest.count else { return nil }
                idx += 1
                return rest[idx - 1]
            }
            let canonical = canonicalLong(name)
            if let canonical, ["upload-pack", "receive-pack", "exec", "extcmd"].contains(canonical) {
                runs("--\(canonical)", value())
            } else if x.hasPrefix("-u"), !x.hasPrefix("--"), sub == "ls-remote" || sub == "clone" {
                // `-u <path>` or attached `-u<path>` names the upload-pack program.
                runs("-u", x.count > 2 ? String(x.dropFirst(2)) : value())
            } else if x.hasPrefix("-x"), !x.hasPrefix("--"), sub == "rebase" || sub == "difftool" {
                runs("-x", x.count > 2 ? String(x.dropFirst(2)) : value())
            } else if canonical == "open-files-in-pager", sub == "grep" {
                runs("--open-files-in-pager", value())
            } else if sub == "grep", let cluster = Self.shortCluster(x),
                      let o = cluster.firstIndex(where: { $0 == "O" || "efABCm".contains($0) }), cluster[o] == "O" {
                // -O takes its pager attached, also inside a cluster (`-nOless`), unless an
                // option taking a value (`-e`, `-A`…) came first and the rest is that value.
                runs("-O", String(cluster[cluster.index(after: o)...]))
            } else if (x == "-c" || canonical == "config"), sub == "clone" {
                if let v = value() { gitConfigOverride(v, depth: ctx.depth) }
            } else if canonical == "template", sub == "clone" || sub == "init" {
                _ = value()
                acc.raise(.high, "installs git hooks from a template folder (git \(sub) --template)")
            }
        }
        if sub == "bisect", rest.first == "run", rest.count > 1 {
            checkWords(Array(rest.dropFirst()), ctx: Context(piped: false, pipedFromDownload: false, heredoc: nil, hereString: nil,
                                                             substitutionDownloads: ctx.substitutionDownloads, depth: ctx.depth + 1))
        }
        if sub == "submodule", let i = rest.firstIndex(of: "foreach") {
            let command = rest[(i + 1)...].filter { !["--recursive", "-q", "--quiet"].contains($0) }
            if !command.isEmpty {
                acc.raise(.medium, "runs a command in each submodule")
                checkText(command.joined(separator: " "), depth: ctx.depth + 1)
            }
        }
    }

    // MARK: Paths

    /// Absolute path for a word, or nil when it depends on run time.
    func resolve(_ raw: String) -> String? {
        if !raw.hasPrefix("/") && !raw.hasPrefix("~") && !raw.hasPrefix("$HOME") && !raw.hasPrefix("${HOME}") && cwd == nil { return nil }
        return PathRules.expand(raw, home: home, cwd: cwd)
    }

    func display(_ raw: String) -> String {
        if let p = resolve(PathRules.stripTrailingGlob(raw)) { return PathRules.display(p, home: home) }
        return raw
    }

    /// A system or account folder (or, for a glob, one it could match).
    mutating func criticalTree(_ raw: String) -> Bool {
        guard spend(1) else { return false }
        let stripped = PathRules.stripTrailingGlob(raw)
        switch pathForm(stripped, globbed: globbedTexts.contains(raw)) {
        case .literal(let s):
            guard let p = resolve(s) else { return false }
            return PathRules.isCriticalTree(p, home: home)
        case .patterns(let ps):
            guard spend(ps.count * criticalTargets.count) else { return false }
            return ps.contains { !$0.dynamic && mayBeCriticalTree($0) }
        case .unknown:
            return false
        }
    }

    mutating func write(_ raw: String, what: String) {
        guard spend(1) else { return }
        let ps: [PathPattern]
        switch pathForm(raw) {
        case .unknown:
            acc.raise(.medium, "\(what) a path set at run time")
            return
        case .literal(let s):
            guard let p = resolve(s) else {
                acc.raise(.medium, "\(what) a path set at run time")
                return
            }
            switch PathRules.writeZone(p, home: home) {
            case .discard: break
            case .allowed: acc.raise(.medium)
            case .outside: acc.raise(.high, "\(what) \(PathRules.display(p, home: home)), outside your home folder")
            case .sensitive: acc.raise(.high, "\(what) \(PathRules.display(p, home: home)), which affects security or startup")
            }
            return
        case .patterns(let found):
            ps = found
        }
        guard spend(ps.count * sensitiveRootParts.count) else { return }
        // A glob or a variable: judged by every protected file it could name.
        for p in ps {
            if let root = sensitiveRootParts.first(where: { p.mayReachInside($0.parts, dotGlob: dotGlob) }) {
                acc.raise(.high, "\(what) \(raw), which could be \(PathRules.display(root.path, home: home)) (security or startup)")
                return
            }
        }
        if ps.contains(where: \.dynamic) {
            acc.raise(.medium, "\(what) a path set at run time")
            return
        }
        for p in ps where PathRules.writeZone(p.literalPrefix, home: home) == .outside {
            acc.raise(.high, "\(what) \(raw), outside your home folder")
            return
        }
        acc.raise(.medium)
    }

    mutating func deletes(_ raw: String, recursive: Bool) {
        guard spend(1) else { return }
        let stripped = PathRules.stripTrailingGlob(raw)
        switch pathForm(stripped, globbed: globbedTexts.contains(raw)) {
        case .unknown:
            return
        case .literal(let s):
            guard let p = resolve(s) else { return }
            if PathRules.isProtectedFromDeletion(p, home: home) {
                acc.block("Glide won't delete your Library or keychain folders.", reason: "deletes \(PathRules.display(p, home: home))")
            } else if recursive, PathRules.isCriticalTree(p, home: home) {
                acc.block("Glide won't recursively delete \(PathRules.display(p, home: home)).", reason: "recursively deletes \(PathRules.display(p, home: home))")
            } else if PathRules.writeZone(p, home: home) == .outside {
                acc.raise(.high, "deletes \(PathRules.display(p, home: home)), outside your home folder")
            }
        case .patterns(let ps):
            guard spend(ps.count * (criticalTargets.count + 3)) else { return }
            // A variable could be anything, so it needs approval (rm is high) rather than a
            // block; a glob is matched against what it would really delete.
            for p in ps where !p.dynamic {
                if isLibraryUninstaller(p) {
                    // `rm -rf ~/Library/*/<bundle id>`: the usual uninstaller shape. The `*`
                    // could be Keychains, but the literal leaf means it isn't wiping that
                    // folder, so it needs approval rather than a block.
                    acc.raise(.high, "deletes items inside ~/Library (\(raw))")
                } else if mayBeProtectedFromDeletion(p) {
                    acc.block("Glide won't delete your Library or keychain folders.", reason: "deletes \(raw)")
                } else if recursive, mayBeCriticalTree(p) {
                    acc.block("Glide won't recursively delete \(raw); it could match a system or account folder.", reason: "recursively deletes \(raw)")
                } else if PathRules.writeZone(p.literalPrefix, home: home) == .outside {
                    acc.raise(.high, "deletes \(raw), outside your home folder")
                }
            }
        }
    }

    /// An operand that names private keys or credentials. With `contents: false` (a program
    /// that only lists names and sizes), a glob that merely could reach a key folder is fine;
    /// a literal key path still counts.
    mutating func readCheck(_ raw: String, contents: Bool = true) {
        guard spend(1) else { return }
        switch pathForm(raw) {
        case .unknown:
            return
        case .literal(let s):
            guard s.contains("/") || s.hasPrefix("~") || s.hasPrefix(".") || cwd.map({ PathRules.isSecret($0, home: home) }) == true,
                  let p = resolve(s), PathRules.isSecret(p, home: home) else { return }
            acc.raise(.high, "touches private keys or credentials (\(PathRules.display(p, home: home)))")
        case .patterns(let ps):
            guard contents, spend(ps.count * secretRootParts.count) else { return }
            for p in ps where !p.namesPublicKey {
                if let root = secretRootParts.first(where: { p.mayReachInside($0.parts, dotGlob: dotGlob) }) {
                    acc.raise(.high, "touches private keys or credentials (\(raw) could match \(PathRules.display(root.path, home: home)))")
                    return
                }
            }
        }
    }

    // MARK: Paths the shell expands

    enum PathForm {
        /// Plain text (after filling in variables set on the line): compare it directly.
        case literal(String)
        /// Globs or run-time parts under a known folder.
        case patterns([PathPattern])
        /// Starts with something only known at run time (`$dir/x`); nothing reliable to say.
        case unknown
    }

    /// How the shell will see `raw`: the text itself, or the patterns it could expand to.
    /// `globbed` overrides the word's own flag (for a word already cut down, like `~/L*/*`).
    func pathForm(_ raw: String, globbed: Bool? = nil) -> PathForm {
        // `$HOME`, `$PWD` and variables set on the line are filled in first.
        let (s, valueGlob) = substituteVariablesForPath(raw)
        let glob = globbed ?? globbedTexts.contains(raw) || valueGlob
        let special = PathRules.isDirectoryStackTilde(s)
        // A relative name after `cd` into a glob, or after a `cd` that might not have taken
        // effect, is under more than one folder, so it's matched as patterns rather than one path.
        let relative = !s.hasPrefix("/") && !s.hasPrefix("~") && !s.hasPrefix("$")
        let relativeToPatterns = relative && ((cwd == nil && cwdPatterns != nil) || !cwdAlternates.isEmpty)
        if !glob && !special && !Self.hasRunTimeParts(s) && !relativeToPatterns { return .literal(s) }

        var base: [[PathPattern.Component]]
        var text: String
        if s.hasPrefix("~") {
            let name = String(s.dropFirst().prefix { $0 != "/" })
            text = String(s.dropFirst(1 + name.count))
            switch name {
            case "": base = [PathPattern.literalComponents(home)]
            case "+":
                guard let anchors = currentFolders() else { return .unknown }
                base = anchors
            case "-":
                guard let o = oldCwd else { return .unknown }
                base = [PathPattern.literalComponents(o)]
            case _ where special:
                return .unknown
            default:
                // ~name is that user's home folder; a glob in the name could be anyone's.
                if name.contains(where: { "*?[{(".contains($0) }) || name.contains("$") {
                    base = [PathPattern.literalComponents("/Users")]
                    text = "/" + name + text
                } else {
                    base = [PathPattern.literalComponents("/Users/" + name)]
                }
            }
        } else if s.hasPrefix("/") {
            base = [[]]
            text = s
        } else if s.hasPrefix("$") || s.hasPrefix("`") || s.hasPrefix("<(") || s.hasPrefix(">(") || s.hasPrefix("=(") {
            return .unknown
        } else {
            guard let anchors = currentFolders() else { return .unknown }
            base = anchors
            text = "/" + s
        }
        let dots = dotQualifiedTexts.contains(raw)
        var out: [PathPattern] = []
        for b in base {
            // Too many brace alternatives (or folders times alternatives) to enumerate: fail
            // closed to a pattern that could be anywhere, so secret and persistence roots match.
            guard let ps = PathPattern.make(base: b, text: text, glob: glob, extendedGlob: extendedGlob, dots: dots),
                  out.count + ps.count <= Self.maxPatterns else {
                return .patterns([PathPattern.anywhere])
            }
            out += ps
        }
        return .patterns(out)
    }

    /// The folder (or folders, after `cd` into a glob or a `cd` that may have failed) relative
    /// paths start from.
    func currentFolders() -> [[PathPattern.Component]]? {
        let out = currentFolderPatterns().map(\.components)
        return out.isEmpty ? nil : out
    }

    /// Every folder the shell may be in now, as patterns.
    func currentFolderPatterns() -> [PathPattern] {
        var out: [PathPattern] = []
        if let cwd { out.append(PathPattern(components: PathPattern.literalComponents(cwd), dynamic: false)) }
        else if let cwdPatterns { out += cwdPatterns }
        out += cwdAlternates
        return out
    }

    /// Adds folders the shell may be in instead, keeping each once. Past `maxFolders`, tracking
    /// gives up: relative paths could be anywhere, and the line is too complex to check.
    mutating func addAlternates(_ folders: [PathPattern]) {
        var seen = Set(currentFolderPatterns())
        for f in folders where seen.insert(f).inserted { cwdAlternates.append(f) }
        if currentFolderPatterns().count > Self.maxFolders { loseFolders() }
    }

    /// Stops tracking the folder: from here a relative path could be anywhere.
    mutating func loseFolders() {
        if !cwdLost { acc.raise(.high, "too complex to check (too many possible folders)") }
        cwdLost = true
        cwd = nil
        cwdPatterns = [PathPattern.anywhere]
        cwdAlternates = []
        cwdIfChainFailed = []
    }

    /// `cd`/`pushd`: moves the folder relative paths resolve against.
    ///
    /// A `cd` can fail (the folder is missing, or is a file) and leave the shell where it was.
    /// Joined by `&&` to what follows, that doesn't matter: the rest of the chain never runs,
    /// so it's judged in the new folder only, and the old one comes back once the chain ends.
    /// Otherwise (`;`, `||`, a pipeline, `!`) a relative path after it is judged against the old
    /// folders as well. A target only known at run time, a glob, `cd -` and zsh's two-word
    /// `cd old new` are never trusted that way.
    mutating func changeFolder(_ a: [String], _ ctx: Context) {
        let ops = Self.operands(a)
        let before = currentFolderPatterns()
        let previous = cwd
        if cwdLost {
            oldCwd = nil
            return
        }
        var literalTarget = false
        if ops.count > 1 {
            // zsh's `cd old new` swaps text in the current path: somewhere unknowable.
            cwd = nil
            cwdPatterns = previous.map { [PathPattern(components: PathPattern.literalComponents($0), dynamic: false)] }
        } else if ops.first == "-" {
            // Without a known previous folder (a fresh shell's OLDPWD is where it started) it stays.
            if let o = oldCwd {
                cwd = o
                cwdPatterns = nil
            }
        } else if let t = ops.first {
            let (s, valueGlob) = substituteVariablesForPath(t)
            literalTarget = !globbedTexts.contains(t) && !valueGlob && !PathRules.isDirectoryStackTilde(s) && !Self.hasRunTimeParts(s)
            switch pathForm(t) {
            case .literal(let s):
                cwd = resolve(s)
                cwdPatterns = nil
                if cwd == nil { literalTarget = false }
            case .patterns(let ps):
                cwd = nil
                cwdPatterns = ps
            case .unknown:
                literalTarget = false
                cwd = nil
                cwdPatterns = previous.map { [PathPattern(components: PathPattern.literalComponents($0), dynamic: false)] }
            }
        } else {
            cwd = home
            cwdPatterns = nil
            literalTarget = true
        }
        oldCwd = previous
        // A `cd` the line redefined (`cd() { :; }`, `alias cd=true`) may not change folder at all.
        let gate = functionNames.contains("cd") || functionNames.contains("pushd") ? .none : ctx.cdGate
        cwdAlternates = []
        switch (literalTarget, gate) {
        case (true, .chain): cwdIfChainFailed += before.filter { !cwdIfChainFailed.contains($0) }
        case (true, .exits): break
        default: addAlternates(before)
        }
        // A folder deeper than any real path (`cd a && cd a && …` thousands of times).
        if let c = cwd, c.utf8.count > Self.maxFolderLength { loseFolders() }
        if let ps = cwdPatterns, ps.count > Self.maxFolders || ps.contains(where: { $0.components.count > Self.maxFolderLength / 2 }) { loseFolders() }
        if currentFolderPatterns().count + cwdIfChainFailed.count > Self.maxFolders * 2 { loseFolders() }
    }

    /// `/`, top-level system folders, any home folder or volume, `~/Library`.
    func mayBeCriticalTree(_ p: PathPattern) -> Bool {
        criticalTargets.contains { p.mayBe($0, dotGlob: dotGlob) } || mayBeProtectedFromDeletion(p)
    }

    func mayBeProtectedFromDeletion(_ p: PathPattern) -> Bool {
        p.mayBe(homeLibraryParts, dotGlob: dotGlob) || keychainParts.contains { p.mayReachInside($0, dotGlob: dotGlob) }
    }

    /// `~/Library/<wildcard>/<…literal…>`: a wildcard folder under `~/Library` narrowed by a
    /// later literal component (a vendor's bundle id), the shape an app uninstaller uses. It
    /// isn't wiping ~/Library or the keychains, so it's approval-gated rather than blocked.
    func isLibraryUninstaller(_ p: PathPattern) -> Bool {
        let homeComps = PathPattern.literalComponents(home)
        let comps = p.components
        guard comps.count >= homeComps.count + 2 else { return false }
        for i in homeComps.indices where comps[i] != homeComps[i] { return false }
        let libIdx = homeComps.count
        guard comps[libIdx].literalName == "library", comps[libIdx + 1].isWildcard else { return false }
        return comps[(libIdx + 2)...].contains { !($0.literalName ?? "").isEmpty }
    }

    // MARK: Output that is only numbers

    /// `x=$(cmd)` where cmd only ever prints numbers: arithmetic over `x` can't run anything,
    /// since running code needs a name and a subscript (`a[$(cmd)]`), and digits aren't one.
    func numericAssignment(_ word: ShellWord) -> Bool {
        guard word.substitutions.count == 1, let eq = word.text.firstIndex(of: "=") else { return false }
        let value = word.text[word.text.index(after: eq)...]
        guard value == "$(…)" || value == "`…`" else { return false }
        return numericOutput(word.substitutions[0])
    }

    /// Whether a substitution's output is only digits, spaces and punctuation: one pipeline
    /// whose output comes from a counting program (`wc -l`, `date +%s`, `git rev-list --count`,
    /// `stat -f %z`, `curl -o … -w '%{http_code}'`…), possibly through filters that only drop
    /// or reorder what they're given (`tr -d`, `head -n 1`, `sort -n`…). Error text folded in
    /// with `2>&1` could be anything, so that never counts.
    func numericOutput(_ list: ShellList) -> Bool {
        guard list.pipelines.count == 1, let pipeline = list.pipelines.first, !pipeline.commands.isEmpty else { return false }
        for cmd in pipeline.commands {
            if cmd.redirects.contains(where: { $0.op == ">&" || $0.op == "&>" || $0.op == "&>>" }) { return false }
            if !cmd.groups.isEmpty || cmd.words.contains(where: { !$0.substitutions.isEmpty }) { return false }
        }
        var k = pipeline.commands.count - 1
        while k > 0, Self.keepsNumbers(pipeline.commands[k].words.map(\.text)) { k -= 1 }
        return Self.printsOnlyNumbers(pipeline.commands[k].words.map(\.text))
    }

    /// Programs (as written: no wrappers, no assignments) whose standard output is numbers.
    static func printsOnlyNumbers(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        let a = Array(words.dropFirst())
        func all(_ pattern: String) -> Bool { a.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil } }
        switch programName(first) {
        case "wc":
            // Counts only: with no file operands it prints no names.
            return !a.isEmpty && all(#"^-[lcmw]+$"#)
        case "date":
            return a.contains { $0.hasPrefix("+") } && a.allSatisfy { $0 == "-u" || (Self.numericFormat($0.dropFirst(), letters: "sYmdHMSjuwyeNCGgVUWklIz") && $0.hasPrefix("+")) }
        case "git":
            return a.first == "rev-list" && a.contains("--count")
        case "stat":
            var formats: [String] = []
            var idx = 0
            while idx < a.count {
                let x = a[idx]
                idx += 1
                if x == "-f" || x == "-c" || x == "--format" || x == "--printf" { if idx < a.count { formats.append(a[idx]); idx += 1 }; continue }
                if x.hasPrefix("-f") || x.hasPrefix("-c") { formats.append(String(x.dropFirst(2))); continue }
                if x.hasPrefix("--format=") || x.hasPrefix("--printf=") { formats.append(String(x.drop { $0 != "=" }.dropFirst())); continue }
                if x.hasPrefix("-"), x != "-L" { return false }
            }
            return !formats.isEmpty && formats.allSatisfy { Self.numericFormat($0[...], letters: "zmacBpugilbkdrfvsYXZWhoD") }
        case "id":
            return !a.isEmpty && a.filter { $0.hasPrefix("-") }.allSatisfy { $0.range(of: #"^-[ugr]+$"#, options: .regularExpression) != nil }
                && a.contains { $0.contains("u") || $0.contains("g") } && a.filter { !$0.hasPrefix("-") }.count <= 1
        case "sw_vers":
            return a == ["-productVersion"] || a == ["--productVersion"]
        case "nproc":
            return a.allSatisfy { $0.hasPrefix("-") }
        case "seq":
            return (1...3).contains(a.count) && all(#"^-?[0-9]+(\.[0-9]+)?$"#)
        case "curl":
            return curlPrintsOnlyNumbers(a)
        default:
            return false
        }
    }

    /// Filters whose output is made of their input's characters and whitespace.
    static func keepsNumbers(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        let a = Array(words.dropFirst())
        switch programName(first) {
        case "tr":
            return a.count == 2 && (a[0] == "-d" || a[0] == "-s")
        case "xargs":
            return a.isEmpty
        case "head", "tail":
            var idx = 0
            while idx < a.count {
                let x = a[idx]
                idx += 1
                if x == "-n" || x == "-c" { guard idx < a.count, Int(a[idx]) != nil else { return false }; idx += 1; continue }
                if x.range(of: #"^-[nc]?[0-9]+$"#, options: .regularExpression) != nil { continue }
                return false
            }
            return true
        case "sort":
            return a.allSatisfy { $0.range(of: #"^-[nrug]+$"#, options: .regularExpression) != nil }
        case "uniq":
            return a.isEmpty
        case "cut":
            var idx = 0
            while idx < a.count {
                let x = a[idx]
                idx += 1
                if x == "-d" || x == "-f" || x == "-c" || x == "-b" { guard idx < a.count else { return false }; idx += 1; continue }
                if x.hasPrefix("-d") || x.hasPrefix("-f") || x.hasPrefix("-c") || x.hasPrefix("-b") { continue }
                return false
            }
            return true
        default:
            return false
        }
    }

    /// A `date +…`/`stat -f …` format that prints only numbers: `%` conversions from `letters`
    /// (with optional flags and width) and literal digits, spaces and punctuation, no letters.
    static func numericFormat(_ f: Substring, letters: String) -> Bool {
        var it = f.makeIterator()
        while let ch = it.next() {
            if ch == "%" {
                var spec = it.next()
                while let s = spec, s.isNumber || "-_0#.".contains(s) { spec = it.next() }
                guard let s = spec, letters.contains(s) else { return false }
                continue
            }
            if ch == "\\" {
                // `\n` and `\t` in the format are whitespace.
                guard let e = it.next(), e == "n" || e == "t" else { return false }
                continue
            }
            if ch.isLetter || ch == "$" || ch == "`" || ch == "[" || ch == "]" { return false }
        }
        return true
    }

    /// `curl … -o FILE -w FORMAT URL` that prints only curl's numeric write-out variables: the
    /// body goes to a file, one URL (no `[…]`/`{…}` globbing, which makes several transfers),
    /// and only options known not to print anything else.
    static func curlPrintsOnlyNumbers(_ a: [String]) -> Bool {
        let quietFlags = Set("sSfLkIq46v")
        let shortWithValue = Set("owXHmAebr")
        let longFlags: Set<String> = ["--silent", "--show-error", "--fail", "--fail-with-body", "--location", "--insecure", "--head", "--compressed",
                                      "--ipv4", "--ipv6", "--no-progress-meter", "--http1.1", "--http2", "--globoff", "--verbose"]
        let longWithValue: Set<String> = ["--output", "--write-out", "--request", "--header", "--max-time", "--connect-timeout", "--retry",
                                          "--retry-delay", "--retry-max-time", "--user-agent", "--referer", "--cookie", "--range", "--max-redirs"]
        var output: String?
        var format: String?
        var urls = 0
        var idx = 0
        func take(_ name: String, _ v: String) {
            if name == "o" || name == "--output" { output = v }
            if name == "w" || name == "--write-out" { format = v }
        }
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if x.hasPrefix("--") {
                let parts = x.split(separator: "=", maxSplits: 1).map(String.init)
                if longFlags.contains(parts[0]), parts.count == 1 { continue }
                guard longWithValue.contains(parts[0]) else { return false }
                if parts.count > 1 { take(parts[0], parts[1]) } else {
                    guard idx < a.count else { return false }
                    take(parts[0], a[idx])
                    idx += 1
                }
                continue
            }
            if let cluster = shortCluster(x) {
                let chars = Array(cluster)
                for (k, ch) in chars.enumerated() {
                    if quietFlags.contains(ch) { continue }
                    guard shortWithValue.contains(ch) else { return false }
                    if k + 1 < chars.count { take(String(ch), String(chars[(k + 1)...])) } else {
                        guard idx < a.count else { return false }
                        take(String(ch), a[idx])
                        idx += 1
                    }
                    break
                }
                continue
            }
            if x.contains("[") || x.contains("{") || x.contains("}") { return false }
            urls += 1
        }
        guard urls == 1, let out = output, out != "-", !out.isEmpty, let f = format else { return false }
        return curlNumericFormat(f)
    }

    /// curl write-out variables that print a number.
    static let curlNumericVariables: Set<String> = [
        "http_code", "response_code", "http_connect", "http_version", "time_total", "time_connect", "time_namelookup", "time_appconnect",
        "time_pretransfer", "time_starttransfer", "time_redirect", "time_queue", "size_download", "size_upload", "size_header", "size_request",
        "speed_download", "speed_upload", "num_connects", "num_redirects", "num_retries", "num_headers", "exitcode", "ssl_verify_result",
        "proxy_ssl_verify_result", "remote_port", "local_port",
    ]

    /// A `-w` format of only numeric `%{variables}`, digits, spaces, punctuation and `\n`.
    static func curlNumericFormat(_ f: String) -> Bool {
        if f.hasPrefix("@") { return false } // read from a file
        let c = Array(f)
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "%" {
                guard i + 1 < c.count, c[i + 1] == "{", let close = c[(i + 2)...].firstIndex(of: "}") else { return false }
                guard curlNumericVariables.contains(String(c[(i + 2)..<close])) else { return false }
                i = close + 1
                continue
            }
            if ch == "\\" {
                guard i + 1 < c.count, c[i + 1] == "n" || c[i + 1] == "t" || c[i + 1] == "r" else { return false }
                i += 2
                continue
            }
            if ch.isLetter || ch == "$" || ch == "`" || ch == "[" || ch == "]" { return false }
            i += 1
        }
        return true
    }

    // MARK: Variables

    /// Records a `NAME=value` word: risky environment variables raise the risk, and a fixed
    /// value is remembered when it lasts for the rest of the line (`persists`).
    mutating func assignment(_ word: String, persists: Bool, depth: Int, valueIsCommandOutput: Bool = false, valueSubDownloads: Bool = false) {
        guard let eq = word.firstIndex(of: "=") else { return }
        var name = String(word[..<eq])
        let value = String(word[word.index(after: eq)...])
        let appends = name.hasSuffix("+")
        if appends { name.removeLast() }
        if name.contains("[") { arithmetic = true }
        let base = String(name.prefix { $0 != "[" })
        envAssignment(base, value: value, appends: appends, depth: depth)
        // A value taken from command output (`x=$(cmd)`) is only known at run time; remember it
        // so arithmetic that later reads the variable is judged as evaluating that output.
        if valueIsCommandOutput {
            runtimeVars.insert(base)
            if valueSubDownloads { downloadVars.insert(base) }
        }
        guard persists else { return }
        // An assignment's value isn't globbed, so a `*` in it stays text (bash may glob it when
        // `$name` is used, which `substituteVariablesForPath` reports).
        if appends || name.contains("[") || Self.hasRunTimeParts(value) || value.hasPrefix("(") {
            vars[base] = nil
        } else {
            // zsh and bash expand a leading ~ in an assignment.
            vars[base] = value.hasPrefix("~") ? (PathRules.expand(value, home: home, cwd: cwd) ?? value) : value
        }
    }

    /// `read NAME`, `printf -v NAME`: the variable gets a value only known at run time.
    mutating func assignsUnknown(_ raw: String, _ ctx: Context) {
        if raw.contains("[") { arithmetic = true }
        let name = String(raw.prefix { $0 != "[" && $0 != "?" })
        envAssignment(name, value: nil, appends: false, depth: ctx.depth)
        vars[name] = nil
        // Input read from a file or standard input is run-time text, like command output.
        runtimeVars.insert(name)
    }

    /// Environment variables that make programs run a command line they hold.
    static let commandVariables: Set<String> = [
        "GIT_SSH_COMMAND", "GIT_SSH", "GIT_EXTERNAL_DIFF", "GIT_PAGER", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "GIT_ASKPASS", "SSH_ASKPASS",
        "SUDO_ASKPASS", "GIT_PROXY_COMMAND", "PAGER", "MANPAGER", "LESSOPEN", "LESSCLOSE", "LESSEDIT", "EDITOR", "VISUAL", "FCEDIT",
        "BROWSER", "PROMPT_COMMAND", "RSYNC_RSH", "RSYNC_CONNECT_PROG", "CVS_RSH", "SVN_SSH", "HOMEBREW_EDITOR",
    ]
    /// Environment variables that make programs load code, start-up files or settings from
    /// somewhere else (and HOME, which also moves `~`).
    static let codeVariables: Set<String> = [
        "BASH_ENV", "ENV", "ZDOTDIR", "HOME", "SHELL", "PS4", "LESSKEY", "LESSKEYIN", "MANPATH", "CDPATH", "cdpath", "OLDPWD", "PWD",
        "PERL5OPT", "PERL5LIB", "PERLLIB", "PERL5DB", "PYTHONSTARTUP", "PYTHONPATH", "PYTHONHOME", "NODE_OPTIONS", "NODE_PATH",
        "RUBYOPT", "RUBYLIB", "LUA_INIT", "LUA_PATH", "LUA_CPATH", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "PHPRC",
        "PHP_INI_SCAN_DIR", "GIT_EXEC_PATH", "GIT_TEMPLATE_DIR", "GIT_CONFIG", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_PARAMETERS",
        "GIT_DIR", "GIT_COMMON_DIR", "XDG_CONFIG_HOME",
    ]
    static let codeVariablePrefixes = ["DYLD_", "LD_", "GIT_CONFIG_", "LUA_INIT_"]

    /// A command value that does nothing or only shows text: `true`, `:`, `cat`, `less -R`,
    /// an editor (which just waits without a terminal), by name or from /bin and /usr/bin.
    static func isInertCommand(_ value: String) -> Bool {
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return true }
        let dir = (first as NSString).deletingLastPathComponent
        guard dir.isEmpty || dir == "/bin" || dir == "/usr/bin" else { return false }
        let name = (first as NSString).lastPathComponent
        if name == "less" || name == "more" {
            // Display options only (-R, -FRX…), none that take a file or command.
            return words.dropFirst().allSatisfy { $0.range(of: #"^-[RrFXSsiIJMNKe]+$"#, options: .regularExpression) != nil }
        }
        return ["true", ":", "cat", "vi", "vim", "nano"].contains(name) && words.count == 1
    }
    /// The program search path: `PATH`, and zsh's `path` array tied to it; `FPATH`/`fpath`
    /// for autoloaded functions.
    static let searchPathVariables: Set<String> = ["PATH", "path", "FPATH", "fpath"]

    static func isRiskyVariable(_ name: String) -> Bool {
        commandVariables.contains(name) || codeVariables.contains(name) || searchPathVariables.contains(name) || name == "LESS"
            || codeVariablePrefixes.contains { name.hasPrefix($0) }
    }

    /// Judges setting environment or shell variable `name` to `value` (nil: unknown).
    mutating func envAssignment(_ name: String, value: String?, appends: Bool, depth: Int) {
        if Self.commandVariables.contains(name) {
            // `GIT_EDITOR=true`, `PAGER=cat`: common ways to keep a program from waiting.
            if let value, Self.isInertCommand(value) { return }
            acc.raise(.high, "sets \(name), which makes programs run a command")
            if let value, !value.isEmpty { checkText(value, depth: depth + 1) }
        } else if name == "LESS" {
            // Options for every less run: judged like less's own (`+!cmd`, `-o file`).
            if let value { pagerRules(value.split(whereSeparator: \.isWhitespace).map(String.init), depth: depth) }
            else { acc.raise(.high, "sets LESS to a value only known at run time") }
        } else if Self.codeVariables.contains(name) || Self.codeVariablePrefixes.contains(where: { name.hasPrefix($0) }) {
            if (name == "PYTHONPATH" || name == "NODE_PATH"), let value, projectSearchPath(value) {
                // Modules from the project's own folders: no more than running its code
                // (`python3 ./x.py`), which is medium too.
                acc.raise(.medium, "sets \(name) to a project folder")
                return
            }
            if name == "NODE_OPTIONS", let value, Self.harmlessNodeOptions(value) { return }
            acc.raise(.high, "sets \(name), which changes what code or settings programs load")
            if name.hasPrefix("GIT_CONFIG_VALUE_"), let value, !value.isEmpty { checkText(value, depth: depth + 1) }
        } else if Self.searchPathVariables.contains(name) {
            guard let value else {
                acc.raise(.high, "sets \(name) to a value only known at run time")
                return
            }
            // `${PATH+:$PATH}` (what `brew shellenv` prints) is `:$PATH` when PATH is set and
            // nothing when it isn't: the old value with its separator, not an entry of its own.
            var joinsOldValue = false
            var text = value
            for v in Set([name, "PATH"]) {
                for form in ["${\(v)+:$\(v)}", "${\(v):+:$\(v)}", "${\(v)+:${\(v)}}", "${\(v):+:${\(v)}}"] where text.contains(form) {
                    if text.hasPrefix(form) { joinsOldValue = true }
                    text = text.replacingOccurrences(of: form, with: ":$\(v)")
                }
                for form in ["${\(v)+$\(v):}", "${\(v):+$\(v):}", "${\(v)+${\(v)}:}", "${\(v):+${\(v)}:}"] where text.contains(form) {
                    text = text.replacingOccurrences(of: form, with: "$\(v):")
                    if text.hasSuffix("$\(v):") { text.removeLast() }
                }
            }
            var entries = text.hasPrefix("(") ? text.dropFirst().dropLast(text.hasSuffix(")") ? 1 : 0).split(whereSeparator: \.isWhitespace).map(String.init)
                                             : text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            // `PATH+=:/dir` appends `:/dir`; the leading separator isn't an empty "current
            // folder" entry, just the join between the old value and the new one.
            if appends || joinsOldValue, entries.first == "" { entries.removeFirst() }
            for e in entries where !trustedSearchEntry(e, name: name) {
                let shown = e.isEmpty ? "the current folder" : PathRules.display(substituteVariables(e), home: home)
                acc.raise(.high, "puts \(shown) on \(name.uppercased()), so commands may run programs from there")
                return
            }
        }
    }

    /// A module path (`PYTHONPATH=src`, `NODE_PATH=.:lib`) of only the project's own folders:
    /// relative names without `..`, or folders inside the current one. Anything with `~`, a
    /// variable, a glob or another absolute folder (`/tmp/x`, `~/Downloads`) isn't.
    func projectSearchPath(_ value: String) -> Bool {
        value.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { piece in
            let e = String(piece)
            if e.hasPrefix("~") || Self.hasRunTimeParts(e) || e.contains(where: { "*?[{`".contains($0) }) { return false }
            if e.hasPrefix("/") {
                guard let cwd else { return false }
                return PathRules.isInside(PathRules.normalize(e), cwd)
            }
            return !e.split(separator: "/").contains("..")
        }
    }

    /// `NODE_OPTIONS` of only memory and diagnostics flags. Anything that loads code
    /// (`--require`, `--import`, `--loader`, `--inspect`, `--env-file`…) isn't.
    static func harmlessNodeOptions(_ value: String) -> Bool {
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        let pattern = #"^--(max-old-space-size=\d+|max-semi-space-size=\d+|stack-size=\d+|max-http-header-size=\d+|enable-source-maps|trace-warnings|no-warnings|no-deprecation|trace-deprecation|throw-deprecation|pending-deprecation|unhandled-rejections=(strict|warn|none|throw|warn-with-error-code))$"#
        return !words.isEmpty && words.allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    /// The existing search path, or a folder Glide can only change with approval (system and
    /// package folders). Home, temporary and relative folders can be filled by any step.
    func trustedSearchEntry(_ entry: String, name: String) -> Bool {
        let own = ["$\(name)", "${\(name)}", "$PATH", "${PATH}", "$path", "${path}", "$path[@]", "${path[@]}", "$fpath", "${fpath}", "$FPATH", "${FPATH}"]
        if own.contains(entry) { return true }
        let e = substituteVariables(entry)
        guard e.hasPrefix("/"), !Self.hasRunTimeParts(e), !e.contains(where: { "*?[{".contains($0) }) else { return false }
        return PathRules.writeZone(PathRules.normalize(e), home: home) == .outside
    }

    /// `$NAME`/`${NAME}` replaced by values set earlier on the line.
    func substituteVariables(_ text: String) -> String {
        substituteVariablesForPath(text).text
    }

    /// Like `substituteVariables`, also reporting whether a filled-in value has glob
    /// characters (bash expands those in an unquoted `$x`).
    func substituteVariablesForPath(_ text: String) -> (text: String, globbed: Bool) {
        guard text.contains("$") else { return (text, false) }
        var known = vars
        known["HOME"] = home
        if let cwd { known["PWD"] = cwd }
        if let oldCwd { known["OLDPWD"] = oldCwd }
        let c = Array(text)
        var out = ""
        var glob = false
        var i = 0
        func addValue(_ value: String) {
            out += value
            if value.contains(where: { "*?[".contains($0) }) { glob = true }
        }
        while i < c.count {
            if c[i] == "$", i + 1 < c.count {
                var j = i + 1
                let braced = c[j] == "{"
                if braced { j += 1 }
                let start = j
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                let name = String(c[start..<j])
                if !name.isEmpty, start < c.count, !(c[start].isNumber), let value = known[name] {
                    if braced {
                        // `${HOME}` plain, or `${HOME:-x}`, `${HOME:h}`, `${HOME%foo}`: the value
                        // is still HOME-derived, so substitute it and drop the modifier (the real
                        // folder may differ, but over-estimating which folder is the safe side).
                        var depth = 1
                        var k = j
                        while k < c.count, depth > 0 {
                            if c[k] == "{" { depth += 1 } else if c[k] == "}" { depth -= 1 }
                            k += 1
                        }
                        addValue(value)
                        i = k
                        continue
                    }
                    addValue(value)
                    i = j
                    // `$HOME[1,-1]` (substring) or `$HOME:h` (modifier): still HOME-derived.
                    if i < c.count, c[i] == "[" {
                        var depth = 0
                        while i < c.count { if c[i] == "[" { depth += 1 } else if c[i] == "]" { depth -= 1; i += 1; if depth == 0 { break }; continue }; i += 1 }
                    }
                    while i + 1 < c.count, c[i] == ":", c[i + 1].isLetter {
                        i += 1
                        while i < c.count, c[i].isLetter { i += 1 }
                    }
                    continue
                }
            }
            out.append(c[i])
            i += 1
        }
        return (out, glob)
    }

    // MARK: Pipeline helpers

    /// Commands that produce content from the network (or decode hidden content) — the left
    /// side of the `curl … | sh` pattern.
    func isDownloadish(_ cmd: ShellCommand) -> Bool {
        if cmd.groups.contains(where: listDownloads) { return true }
        // `cat <(curl …)` passes the download through.
        if cmd.words.contains(where: { w in w.text.hasPrefix("<(") && w.substitutions.contains(where: listDownloads) }) { return true }
        let texts = cmd.words.map(\.text).filter { !$0.isEmpty }
        var start = 0
        while start < texts.count, Self.isAssignment(texts[start]) || Self.prefixKeywords.contains(texts[start]) { start += 1 }
        // See through simple wrappers.
        let wrappers: Set<String> = ["nohup", "time", "command", "exec", "builtin", "env", "nice", "caffeinate"]
        while start < texts.count, wrappers.contains(Self.programName(texts[start])) { start += 1 }
        guard start < texts.count else { return false }
        let prog = Self.programName(texts[start])
        let args = Array(texts[(start + 1)...])
        switch prog {
        case "curl", "wget", "fetch", "http", "https", "aria2c", "lwp-request", "ftp", "nc", "ncat":
            return true
        case "base64", "gbase64":
            return args.contains { $0 == "-d" || $0 == "-D" || $0 == "--decode" || (Self.shortCluster($0)?.contains("d") ?? false) || (Self.shortCluster($0)?.contains("D") ?? false) }
        case "openssl":
            return args.contains("-d") || args.contains("-base64") || args.first == "base64"
        case "xxd":
            return args.contains { Self.shortCluster($0)?.contains("r") ?? false }
        case "uudecode", "gpg":
            return true
        default:
            return false
        }
    }

    func listDownloads(_ list: ShellList) -> Bool {
        list.pipelines.contains { p in p.commands.contains { c in isDownloadish(c) || c.words.contains { $0.substitutions.contains(where: listDownloads) } } }
    }

    // MARK: Word helpers

    static let prefixKeywords: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "fi", "done", "time", "coproc", "]]", "end"]

    /// Programs that only read. Builtins that assign variables, evaluate arithmetic or take a
    /// program to run (`export`, `read`, `let`, `hash`, `emulate`, `less`, `man`, `pbpaste`…)
    /// have their own rules above instead.
    static let readOnlyPrograms: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "mdfind", "mdls", "stat", "file", "du", "df", "pwd",
        "echo", "cal", "which", "whereis", "whoami", "id", "uname", "sw_vers", "uptime", "ps", "jq", "cut", "tr", "column",
        "shasum", "md5", "md5sum", "sha1sum", "sha256sum", "sha512sum", "cksum", "sum", "basename", "dirname", "realpath", "readlink", "nl",
        "diff", "cmp", "comm", "seq", "sleep", "strings", "od", "hexdump", "lsof", "ioreg", "system_profiler", "last",
        "w", "who", "groups", "locale", "tty", "getconf", "vm_stat", "iostat", "netstat", "dig", "nslookup", "host", "ping", "traceroute",
        "whois", "arp", "fold", "fmt", "expand", "unexpand", "paste", "join", "rev", "tac", "look", "printenv", "nproc", "otool", "nm",
        "apropos", "whatis", "jot", "bc", "expr", "envsubst", "iconv", "type", "whence", "where",
        "setopt", "unsetopt", "shopt", "wait", "fg", "bg", "rehash", "umask", "disown", "times", "ulimit", "unalias",
        "zstat", "zcat", "bzcat", "xzcat", "gzcat", "dwarfdump", "yes", "pgrep", "osalang", "getfacl", "true", "false", ":",
    ]

    /// `NAME=…`, `NAME+=…`, `NAME[sub]=…`.
    static func isAssignment(_ s: String) -> Bool {
        var it = s.unicodeScalars.makeIterator()
        guard let f = it.next(), isWordScalarStart(f, first: true) else { return false }
        var c = it.next()
        while let ch = c, isWordScalar(ch) { c = it.next() }
        if c == "[" {
            c = it.next()
            while let ch = c, ch != "]" { c = it.next() }
            guard c == "]" else { return false }
            c = it.next()
        }
        if c == "+" { c = it.next() }
        return c == "="
    }

    /// Lowercased base name, so `/bin/RM` and `\rm` are judged as `rm` (APFS is case-insensitive).
    /// A leading `=` is zsh's `=rm`, which expands to the program's full path.
    static func programName(_ word: String) -> String {
        let w = word.hasPrefix("=") && word.count > 1 ? String(word.dropFirst()) : word
        let base = w.split(separator: "/").last.map(String.init) ?? w
        return base.lowercased()
    }

    /// Text with parts the shell fills in at run time: `$x`, `${x}`, `$(…)`, backticks, or a
    /// process substitution.
    static func hasRunTimeParts(_ s: String) -> Bool {
        if s.contains("`") || s.hasPrefix("<(") || s.hasPrefix(">(") || s.hasPrefix("=(") || s.contains("<(…)") || s.contains(">(…)") { return true }
        var i = s.startIndex
        while let d = s[i...].firstIndex(of: "$") {
            let n = s.index(after: d)
            guard n < s.endIndex else { return false }
            let ch = s[n]
            if ch == "{" || ch == "(" || ch == "'" || ch == "[" || ch.isLetter || ch.isNumber || "_?#@*!$-".contains(ch) { return true }
            i = n
        }
        return false
    }

    /// Command text inside a word that the parser didn't treat as a substitution, because
    /// it was quoted: `'$(rm -rf ~)'`, `'`id`'`, bash 5.3's `'${ cmd; }'`. Inert unless
    /// something evaluates the string again (see `finish`).
    static func literalCode(in text: String) -> [String] {
        let c = Array(text)
        var out: [String] = []
        var i = 0
        while i < c.count {
            if c[i] == "$", i + 1 < c.count, c[i + 1] == "(" {
                // The parser writes a real substitution as `$(…)`; `$((…))` is arithmetic.
                if i + 3 < c.count, c[i + 2] == "…", c[i + 3] == ")" { i += 4; continue }
                if i + 2 < c.count, c[i + 2] == "(" { i += 3; continue }
                var depth = 0
                var j = i + 1
                while j < c.count {
                    if c[j] == "(" { depth += 1 } else if c[j] == ")" { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                out.append(String(c[min(i + 2, c.count)..<min(j, c.count)]))
                i = j + 1
                continue
            }
            if c[i] == "$", i + 2 < c.count, c[i + 1] == "{", c[i + 2] == " " || c[i + 2] == "|" || c[i + 2] == "\t" || c[i + 2] == "\n" {
                var j = i + 2
                while j < c.count, c[j] != "}" { j += 1 }
                out.append(String(c[(i + 3)..<max(i + 3, j)]))
                i = j + 1
                continue
            }
            if c[i] == "`" {
                if i + 2 < c.count, c[i + 1] == "…", c[i + 2] == "`" { i += 3; continue }
                var j = i + 1
                while j < c.count, c[j] != "`" { j += 1 }
                out.append(String(c[(i + 1)..<j]))
                i = j + 1
                continue
            }
            i += 1
        }
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The arithmetic parts of a word: the inside of each `$(( … ))` and `$[ … ]`, and of each
    /// subscript (`${a[…]}`, `${#a[…]}`, `$a[…]`). Only these are evaluated, so `$(date)` or a
    /// variable elsewhere in the word isn't (`echo "$(date): $((1 + 1))"`). One pass: a part
    /// is skipped whole once found, nested ones included; an unclosed one runs to the end.
    static func arithmeticSegments(_ s: String) -> [Substring] {
        guard s.contains("$") else { return [] }
        let c = Array(s)
        var out: [Substring] = []
        func slice(_ a: Int, _ b: Int) -> Substring {
            let lo = min(a, c.count), hi = min(max(lo, b), c.count)
            return Substring(String(c[lo..<hi]))
        }
        /// Index of the bracket closing the one at `from` (c.count when unclosed).
        func closing(_ from: Int, _ open: Character, _ close: Character) -> Int {
            var depth = 0
            var j = from
            while j < c.count {
                if c[j] == open { depth += 1 } else if c[j] == close { depth -= 1; if depth == 0 { return j } }
                j += 1
            }
            return c.count
        }
        var i = 0
        while i < c.count {
            guard c[i] == "$", i + 1 < c.count else { i += 1; continue }
            let n = c[i + 1]
            if n == "(", i + 2 < c.count, c[i + 2] == "(" {
                let end = closing(i + 1, "(", ")")
                out.append(slice(i + 3, end < c.count ? end - 1 : end))
                i = end + 1
            } else if n == "[" {
                let end = closing(i + 1, "[", "]")
                out.append(slice(i + 2, end))
                i = end + 1
            } else if n == "{" {
                let end = closing(i + 1, "{", "}")
                // `${#a[…]}`, `${(flags)a[…]}`, `${a[…]}`: the subscript after the name.
                var j = i + 2
                while j < end, "#!^=~+".contains(c[j]) { j += 1 }
                if j < end, c[j] == "(" { j = min(closing(j, "(", ")") + 1, end) }
                let nameStart = j
                while j < end, c[j].isASCII, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                if j > nameStart, j < end, c[j] == "[" {
                    out.append(slice(j + 1, min(closing(j, "[", "]"), end)))
                }
                i = end + 1
            } else if n.isASCII, n.isLetter || n == "_" {
                var j = i + 1
                while j < c.count, c[j].isASCII, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                if j < c.count, c[j] == "[" {
                    let end = closing(j, "[", "]")
                    out.append(slice(j + 1, end))
                    i = end + 1
                } else {
                    i = j
                }
            } else {
                i += 1
            }
        }
        return out
    }

    /// `test`/`[`/`[[` operators that evaluate their operands as arithmetic (`-v` evaluates a
    /// subscript).
    static let arithmeticTests: Set<String> = ["-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-v"]

    /// Words that read the clipboard through a scripting bridge (`osascript -e 'the clipboard'`,
    /// JXA's `theClipboard()`, `NSPasteboard` in inline code).
    static func mentionsClipboard(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("clipboard") || l.contains("pasteboard") || l.contains("pbpaste")
    }

    /// Letters of a short-option cluster (`-rf` → "rf"); nil for long options and operands.
    static func shortCluster(_ s: String) -> String? {
        guard s.hasPrefix("-"), !s.hasPrefix("--"), s.count > 1 else { return nil }
        return String(s.dropFirst())
    }

    static func hasShort(_ a: [String], _ ch: Character) -> Bool {
        for x in a {
            if x == "--" { return false }
            if let c = shortCluster(x), c.allSatisfy({ $0.isLetter || $0.isNumber }), c.contains(ch) { return true }
        }
        return false
    }

    /// Non-option words, skipping the values of `valueFlags`; everything after `--` counts.
    static func operands(_ a: [String], valueFlags: Set<String> = []) -> [String] {
        var out: [String] = []
        var idx = 0
        var endOfFlags = false
        while idx < a.count {
            let x = a[idx]
            idx += 1
            if endOfFlags { out.append(x); continue }
            if x == "--" { endOfFlags = true; continue }
            if valueFlags.contains(x) { idx += 1; continue }
            if x.hasPrefix("-"), x.count > 1 { continue }
            out.append(x)
        }
        return out
    }

    static func value(of flag: String, in a: [String]) -> String? {
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func longValue(_ name: String, in a: [String]) -> String? {
        for x in a where x.hasPrefix(name + "=") { return String(x.dropFirst(name.count + 1)) }
        return value(of: name, in: a)
    }

    /// `host:path`, `user@host:path` or `rsync://…`.
    static func isRemoteSpec(_ s: String) -> Bool {
        if s.hasPrefix("rsync://") { return true }
        guard let colon = s.firstIndex(of: ":") else { return false }
        return !s[..<colon].contains("/") && s[..<colon].count > 0
    }

    static let curlArgFlags = Set("AbcCdDeEFHKmoPQrtTuUwxXyYz")
    static let wgetArgFlags = Set("OoaPiUeDTtwlQARBIX")

    /// Documents that execute code when opened.
    static func runsCode(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["command", "sh", "tool", "pkg", "mpkg", "terminal", "workflow", "scpt", "scptd", "applescript", "jar", "zsh", "bash", "action", "shortcut"].contains(ext)
    }
}
