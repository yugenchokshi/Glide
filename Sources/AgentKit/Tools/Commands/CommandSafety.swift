import Foundation

/// Deterministic risk assessment for shell commands, run before every `shell.run` call.
///
/// The command is parsed (see `ShellParser`) into every simple command it could execute,
/// including ones hidden in substitutions, subshells, `sh -c` strings, `eval`, `find -exec`,
/// `xargs` and here-documents. Each one is judged by its program and flags, each write
/// redirection by where it lands, and pipelines as a whole (downloads piped into a shell).
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

    /// The verdict plus the (lowercased) names of every program the line runs, so callers can
    /// apply per-program settings (e.g. AppleScript turned off also covers `osascript`).
    static func analyze(_ command: String, cwd: String?, home: String = PathRules.home) -> (verdict: ToolVerdict, programs: Set<String>) {
        let summary = summaryText(command)
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (ToolVerdict(risk: .low, summary: summary), []) }
        if trimmed.unicodeScalars.count > 200_000 {
            return (ToolVerdict(risk: .high, reasons: ["command too long to check"],
                                blocked: "This command is too long for Glide to check safely. Put it in a script file instead.", summary: summary), [])
        }
        if trimmed.contains("\u{0}") {
            return (ToolVerdict(risk: .high, reasons: ["contains a NUL character"], blocked: "This command contains invalid characters.", summary: summary), [])
        }
        if isForkBomb(trimmed) {
            return (ToolVerdict(risk: .high, reasons: ["fork bomb"], blocked: "Glide won't run a fork bomb; it would freeze your Mac.", summary: summary), [])
        }
        let parse = ShellParser.parse(trimmed)
        var checker = ShellRiskChecker(home: PathRules.normalize(home), cwd: PathRules.normalize(cwd ?? home))
        if parse.tooComplex { checker.acc.raise(.high, "nested too deeply to check") }
        checker.check(parse.list, depth: 0)
        let verdict = ToolVerdict(risk: checker.acc.risk, reasons: checker.acc.reasons, blocked: checker.acc.blocked, summary: summary)
        return (verdict, checker.programs)
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

    /// `:(){ :|:& };:` and named variants: a function that pipes into itself in the background.
    static func isForkBomb(_ s: String) -> Bool {
        let patterns = [
            #"(?:^|[;&|\s{(])([^\s(){};|&]+)\s*\(\s*\)\s*\{[^}]*?\1\s*\|\s*&?\s*\1\s*&"#,
            #"function\s+([^\s(){};|&]+)\s*(?:\(\s*\))?\s*\{[^}]*?\1\s*\|\s*&?\s*\1\s*&"#,
        ]
        return patterns.contains { s.range(of: $0, options: .regularExpression) != nil }
    }
}

/// Collects the highest risk, its reasons and the first block message.
struct RiskAccumulator {
    var risk: RiskLevel = .low
    var reasons: [String] = []
    var blocked: String?

    mutating func raise(_ level: RiskLevel, _ reason: String? = nil) {
        if level > risk { risk = level }
        if let reason, !reasons.contains(reason) { reasons.append(reason) }
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

    static let maxDepth = 24

    static let downloadIntoShell = "Glide won't run downloaded content straight in a shell or interpreter. Download it, read it, then run it as a separate step."

    init(home: String, cwd: String) {
        self.home = home
        self.cwd = cwd
    }

    // MARK: Walking

    mutating func check(_ list: ShellList, depth: Int) {
        if depth > Self.maxDepth { acc.raise(.high, "nested too deeply to check"); return }
        for pipeline in list.pipelines {
            var sawDownload = false
            var pipedText: String?
            for (idx, cmd) in pipeline.commands.enumerated() {
                check(cmd, piped: idx > 0, pipedFromDownload: sawDownload, pipedText: pipedText, depth: depth)
                if isDownloadish(cmd) { sawDownload = true }
                if let t = literalOutput(cmd) { pipedText = t }
            }
        }
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
    }

    mutating func check(_ cmd: ShellCommand, piped: Bool, pipedFromDownload: Bool, pipedText: String?, depth: Int) {
        // Everything nested runs too.
        var subsDownload = false
        let allWords = cmd.words + cmd.redirects.map(\.target) + (cmd.hereString.map { [$0] } ?? [])
        for w in allWords {
            for s in w.substitutions {
                check(s, depth: depth + 1)
                if listDownloads(s) { subsDownload = true }
            }
        }
        for g in cmd.groups { check(g, depth: depth + 1) }

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
        var words = cmd.words.filter { !($0.text.isEmpty && !$0.quoted) }
        stripping: while let first = words.first {
            // Assignment values that are command substitutions were already checked above.
            if Self.isAssignment(first.text) { words.removeFirst(); continue }
            if first.quoted { break }
            switch first.text {
            case _ where Self.prefixKeywords.contains(first.text):
                words.removeFirst()
            case "[[", "[":
                // A condition; anything after its closing bracket (zsh short forms) still runs.
                let close = first.text == "[[" ? "]]" : "]"
                guard let end = words.firstIndex(where: { $0.text == close && !$0.quoted }) else { return }
                words.removeFirst(end + 1)
            case "function", "repeat":
                // `function name { … }`, `repeat 3 cmd`: the body follows the name/count.
                words.removeFirst(min(2, words.count))
            case "for", "foreach", "select":
                // A plain loop header has nothing else; zsh's short form `for f (*.txt) cmd`
                // puts the list in parentheses and the command right after.
                if cmd.groups.isEmpty { return }
                words.removeFirst(min(2, words.count))
            case "case", "in", ";;", "esac":
                return
            default:
                break stripping
            }
        }
        guard !words.isEmpty else { return }

        let ctx = Context(piped: piped, pipedFromDownload: pipedFromDownload, pipedText: piped ? pipedText : nil, heredoc: cmd.heredoc,
                          hereString: cmd.hereString?.text, substitutionDownloads: subsDownload, depth: depth)
        checkWords(words.map(\.text), ctx: ctx)
    }

    /// Checks a command given as words (also used for `find -exec`, `xargs`, `env -S`).
    mutating func checkWords(_ texts: [String], ctx: Context) {
        guard let args = unwrap(texts, ctx: ctx), let rawProgram = args.first else { return }
        // `$x -rf ~`, `$(echo rm) …`, `$'\x72m' …`: the program is only known at run time.
        let expanded = rawProgram.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        if expanded.contains("$") || expanded.contains("`") || expanded.hasPrefix("<(") || expanded.hasPrefix(">(") {
            acc.raise(.high, "runs a program chosen at run time")
            return
        }
        let prog = Self.programName(rawProgram)
        let rest = Array(args.dropFirst())
        programs.insert(prog)

        // Running something a download just wrote.
        if rawProgram.contains("/"), let p = resolve(rawProgram), downloadedFiles.contains(p.lowercased()) {
            acc.block(Self.downloadIntoShell, reason: "runs a file it just downloaded")
        }
        // Any operand naming private keys or credentials.
        for a in rest where !a.hasPrefix("-") { readCheck(a) }

        rules(prog, rest, ctx)
    }

    // MARK: Wrappers

    /// Strips wrappers that just run the rest of the line (`nohup`, `env`, `xargs`, `time`…).
    /// Returns nil when the wrapper was fully handled here.
    mutating func unwrap(_ input: [String], ctx: Context) -> [String]? {
        var w = input
        for _ in 0..<12 {
            guard let head = w.first else { return nil }
            let prog = Self.programName(head)
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
                    if f == "-u" || f == "-P" || f == "-C" { w.removeFirst(); if !w.isEmpty { w.removeFirst() }; continue }
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
            case "watch":
                w.removeFirst()
                while let f = w.first, f.hasPrefix("-") {
                    w.removeFirst()
                    if (f == "-n" || f == "-d"), !w.isEmpty { w.removeFirst() }
                }
                if w.isEmpty { return nil }
                checkText(w.joined(separator: " "), depth: ctx.depth + 1)
                return nil
            default:
                return w
            }
        }
        return w.isEmpty ? nil : w
    }

    mutating func checkText(_ text: String, depth: Int) {
        if depth > Self.maxDepth { acc.raise(.high, "nested too deeply to check"); return }
        if CommandSafety.isForkBomb(text) { acc.block("Glide won't run a fork bomb; it would freeze your Mac.", reason: "fork bomb") }
        let parse = ShellParser.parse(text)
        if parse.tooComplex { acc.raise(.high, "nested too deeply to check") }
        check(parse.list, depth: depth)
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
                if let p = resolve(PathRules.stripTrailingGlob(t)), PathRules.isCriticalTree(p, home: home) {
                    acc.raise(.high, "moves a system or account folder (\(display(p)))")
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
            if a.contains(where: { writing.contains($0) }) { acc.raise(.medium) }
            if let o = Self.value(of: "-o", in: a), o != "-" { write(o, what: "writes") }
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
            shellRules(a, ctx)
        case "python", "python2", "python3", "perl", "ruby", "node", "php", "lua", "rscript", "tclsh", "pwsh", "deno", "bun", "swift", "nodejs":
            interpreterRules(prog, a, ctx)
        case "eval":
            if ctx.substitutionDownloads { acc.block(Self.downloadIntoShell, reason: "evaluates downloaded content") }
            let text = a.joined(separator: " ")
            if text.contains("$") || text.contains("`") { acc.raise(.high, "evaluates text built at run time (eval)") }
            checkText(text, depth: ctx.depth + 1)
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
            // Aliases expand on the next line in zsh, so their bodies count as commands.
            for x in a { if let eq = x.firstIndex(of: "=") { checkText(String(x[x.index(after: eq)...]), depth: ctx.depth + 1) } }

        // Developer tools with destructive subcommands.
        case "git":
            gitRules(a)
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
        case "tree":
            if let o = Self.value(of: "-o", in: a) { write(o, what: "writes") }
        case _ where Self.readOnlyPrograms.contains(prog):
            break
        case "date":
            let ops = Self.operands(a, valueFlags: ["-r", "-f", "-v", "-z"])
            if !Self.hasShort(a, "j"), ops.contains(where: { !$0.hasPrefix("+") }) { acc.raise(.medium, "sets the clock") }
        case "top":
            if !(a.contains("-l") || a.contains(where: { $0.hasPrefix("-l") })) { acc.raise(.medium) }
        case "cd", "pushd":
            let target = Self.operands(a).first
            if target == nil { cwd = home }
            else if let t = target, t != "-", let p = resolve(t) { cwd = p }
            else { cwd = nil }
        case "popd":
            cwd = nil

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
                    checkWords(inner, ctx: Context(piped: false, pipedFromDownload: false, heredoc: nil, hereString: nil, substitutionDownloads: ctx.substitutionDownloads, depth: ctx.depth + 1))
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
        } else if p.range(of: #"\bprintf?\b[^;}\n]*>"#, options: .regularExpression) != nil {
            acc.raise(.medium, "awk writes to a file")
        }
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
        let domain = rest.count > 1 ? rest[1] : ""
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
        if domain.lowercased().hasPrefix("dev.notchbuddy") { acc.raise(.high, "changes Glide's own settings") }
        if domain.hasPrefix("/") {
            if let p = resolve(domain), PathRules.writeZone(p, home: home) != .allowed {
                acc.raise(.high, "changes system-wide preferences (\(display(p)))")
            }
        }
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
        }
        if !scripts.isEmpty {
            judge(scripts.joined(separator: "\n"))
            return
        }
        if let f = file, f != "-" {
            if let p = resolve(f), downloadedFiles.contains(p.lowercased()) { acc.block(Self.downloadIntoShell, reason: "runs a file it just downloaded") }
            if ctx.substitutionDownloads { acc.block(Self.downloadIntoShell, reason: "runs downloaded content") }
            acc.raise(.medium, "runs an AppleScript file")
            return
        }
        if let body = ctx.heredoc ?? ctx.hereString {
            judge(body)
        } else if ctx.pipedFromDownload {
            acc.block(Self.downloadIntoShell, reason: "runs downloaded content")
        } else if ctx.piped {
            acc.raise(.high, "runs a script piped from another command")
        }
    }

    mutating func shellRules(_ a: [String], _ ctx: Context) {
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
            if let s = commandString { checkText(s, depth: ctx.depth + 1) }
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
        if let code { judgeInlineCode(code, prog: prog); return }
        if let s = script {
            if let p = resolve(s), downloadedFiles.contains(p.lowercased()) { acc.block(Self.downloadIntoShell, reason: "runs a file it just downloaded") }
            acc.raise(.medium, "runs a \(prog) script")
            return
        }
        if let body = ctx.heredoc ?? ctx.hereString { judgeInlineCode(body, prog: prog) }
        else if ctx.pipedFromDownload { acc.block(Self.downloadIntoShell, reason: "pipes downloaded content into \(prog)") }
        else if ctx.piped { acc.raise(.high, "runs \(prog) code piped from another command") }
    }

    mutating func judgeInlineCode(_ code: String, prog: String) {
        let dangerous = #"\b(system|subprocess|popen|exec[a-z]*|spawn[a-z]*|rmtree|remove|unlink|rmdir|kill|child_process|eval|shell_exec|passthru|os\.rm|rm_rf|rm_r|truncate|chmod|chown)\b"#
        if code.range(of: dangerous, options: [.regularExpression, .caseInsensitive]) != nil || code.contains("`") {
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

    mutating func gitRules(_ a: [String]) {
        var idx = 0
        while idx < a.count, a[idx].hasPrefix("-") {
            let x = a[idx]
            idx += 1
            if x == "-c", idx < a.count { gitConfigOverride(a[idx]) }
            if x.hasPrefix("--config-env") || x.hasPrefix("--exec-path=") || x.hasPrefix("--upload-pack") || x.hasPrefix("--receive-pack") {
                acc.raise(.high, "runs a program set on the command line (git \(x.split(separator: "=").first ?? ""))")
            }
            if x == "-C" || x == "-c" || x == "--git-dir" || x == "--work-tree" || x == "--namespace" { idx += 1 }
            if ["--version", "--help", "-h", "--exec-path", "--html-path", "--man-path", "--info-path"].contains(x) { return }
        }
        guard idx < a.count else { return }
        let sub = a[idx]
        let rest = Array(a[(idx + 1)...])
        func has(_ flags: String...) -> Bool { rest.contains { flags.contains($0) } }
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

    /// `git -c key=value`: some settings name a program git will run, which makes an
    /// otherwise read-only `git log` arbitrary code execution.
    mutating func gitConfigOverride(_ kv: String) {
        let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
        let key = parts[0].lowercased()
        let value = parts.count > 1 ? parts[1] : ""
        if key.hasPrefix("alias."), value.hasPrefix("!") {
            acc.raise(.high, "defines a git alias that runs a shell command")
            checkText(String(value.dropFirst()), depth: 1)
            return
        }
        let programKeys: Set<String> = ["core.pager", "core.editor", "core.sshcommand", "core.fsmonitor", "core.hookspath", "core.askpass",
                                        "diff.external", "sequence.editor", "credential.helper", "gpg.program", "gpg.ssh.program",
                                        "uploadpack.packobjectshook", "protocol.ext.allow", "core.gitproxy", "merge.tool", "diff.tool"]
        if programKeys.contains(key) || key.hasSuffix(".textconv") || key.hasSuffix(".command") || key.hasSuffix(".cmd") || key.hasSuffix(".process") || key.hasSuffix(".clean") || key.hasSuffix(".smudge") {
            acc.raise(.high, "runs a program set on the command line (git -c \(key))")
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

    func criticalTree(_ raw: String) -> Bool {
        guard let p = resolve(PathRules.stripTrailingGlob(raw)) else { return false }
        return PathRules.isCriticalTree(p, home: home)
    }

    mutating func write(_ raw: String, what: String) {
        guard let p = resolve(raw) else {
            acc.raise(.medium, "\(what) a path set at run time")
            return
        }
        switch PathRules.writeZone(p, home: home) {
        case .discard: break
        case .allowed: acc.raise(.medium)
        case .outside: acc.raise(.high, "\(what) \(PathRules.display(p, home: home)), outside your home folder")
        case .sensitive: acc.raise(.high, "\(what) \(PathRules.display(p, home: home)), which affects security or startup")
        }
    }

    mutating func deletes(_ raw: String, recursive: Bool) {
        let stripped = PathRules.stripTrailingGlob(raw)
        guard let p = resolve(stripped) else { return }
        if PathRules.isProtectedFromDeletion(p, home: home) {
            acc.block("Glide won't delete your Library or keychain folders.", reason: "deletes \(PathRules.display(p, home: home))")
        } else if recursive, PathRules.isCriticalTree(p, home: home) {
            acc.block("Glide won't recursively delete \(PathRules.display(p, home: home)).", reason: "recursively deletes \(PathRules.display(p, home: home))")
        } else if PathRules.writeZone(p, home: home) == .outside {
            acc.raise(.high, "deletes \(PathRules.display(p, home: home)), outside your home folder")
        }
    }

    mutating func readCheck(_ raw: String) {
        guard raw.contains("/") || raw.hasPrefix("~") || raw.hasPrefix(".") || cwd.map({ PathRules.isSecret($0, home: home) }) == true,
              let p = resolve(raw), PathRules.isSecret(p, home: home) else { return }
        acc.raise(.high, "touches private keys or credentials (\(PathRules.display(p, home: home)))")
    }

    // MARK: Pipeline helpers

    /// Commands that produce content from the network (or decode hidden content) — the left
    /// side of the `curl … | sh` pattern.
    func isDownloadish(_ cmd: ShellCommand) -> Bool {
        if cmd.groups.contains(where: listDownloads) { return true }
        // `cat <(curl …)` passes the download through.
        if cmd.words.contains(where: { w in w.text.hasPrefix("<(") && w.substitutions.contains(where: listDownloads) }) { return true }
        var texts = cmd.words.map(\.text).filter { !$0.isEmpty }
        while let f = texts.first, Self.isAssignment(f) || Self.prefixKeywords.contains(f) { texts.removeFirst() }
        // See through simple wrappers.
        while let f = texts.first, ["nohup", "time", "command", "exec", "builtin", "env", "nice", "caffeinate"].contains(Self.programName(f)) { texts.removeFirst() }
        guard let first = texts.first else { return false }
        let prog = Self.programName(first)
        let args = Array(texts.dropFirst())
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

    static let readOnlyPrograms: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "ag", "ack", "mdfind", "mdls", "stat", "file", "du", "df", "pwd",
        "echo", "printf", "cal", "which", "whereis", "whoami", "id", "uname", "sw_vers", "uptime", "ps", "pbpaste", "jq", "cut", "tr", "column",
        "shasum", "md5", "md5sum", "sha1sum", "sha256sum", "sha512sum", "cksum", "sum", "basename", "dirname", "realpath", "readlink", "nl",
        "diff", "cmp", "comm", "seq", "sleep", "tree", "less", "more", "strings", "od", "hexdump", "lsof", "ioreg", "system_profiler", "last",
        "w", "who", "groups", "locale", "tty", "getconf", "vm_stat", "iostat", "netstat", "dig", "nslookup", "host", "ping", "traceroute",
        "whois", "arp", "fold", "fmt", "expand", "unexpand", "paste", "join", "rev", "tac", "look", "printenv", "nproc", "otool", "nm",
        "man", "apropos", "whatis", "info", "jot", "bc", "expr", "envsubst", "iconv", "type", "whence", "where", "export", "unset",
        "set", "setopt", "unsetopt", "shopt", "local", "declare", "typeset", "readonly", "shift", "return", "exit", "break", "continue",
        "wait", "jobs", "fg", "bg", "read", "hash", "rehash", "umask", "history", "let", "disown", "times", "ulimit", "unalias", "emulate",
        "zstat", "zcat", "bzcat", "xzcat", "gzcat", "dwarfdump", "yes", "pgrep", "osalang", "getfacl", "test", "true", "false", ":",
    ]

    static func isAssignment(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?="#, options: .regularExpression) != nil
    }

    /// Lowercased base name, so `/bin/RM` and `\rm` are judged as `rm` (APFS is case-insensitive).
    static func programName(_ word: String) -> String {
        let base = word.split(separator: "/").last.map(String.init) ?? word
        return base.lowercased()
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
