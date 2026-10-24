import Foundation
import AppKit

/// Commands and scripts can read the clipboard without `clipboard.read`, so they follow its
/// rule: an item a password manager marked as concealed is never read. That needs the
/// pasteboard itself, so it's checked just before running rather than in `assess`.
enum ConcealedClipboardGuard {
    static let message = "The clipboard holds a concealed item (likely a password from a password manager), so Glide won't run something that reads it."

    static func check(_ pasteboardName: NSPasteboard.Name?) async throws {
        if await Clipboard.holdsConcealedItem(pasteboardName) { throw ToolError.blocked(message) }
    }
}

// MARK: shell.run

/// Runs a zsh command line. The fastest route for anything a command can do; every call is
/// assessed by `CommandSafety` before it runs.
struct ShellRunTool: AgentTool {
    static let defaultTimeout: Double = 60
    static let maxTimeout: Double = 600
    /// The pasteboard checked for concealed items before a command that reads the clipboard
    /// runs; nil is the general clipboard (tests pass a private one).
    let pasteboardName: NSPasteboard.Name?

    init(pasteboardName: NSPasteboard.Name? = nil) { self.pasteboardName = pasteboardName }

    let spec = ToolSpec(
        name: "shell.run",
        summary: "Run a zsh command line on this Mac and get its output and exit code. Prefer it for files, text processing, git, builds and system info. No sudo; stdin is empty.",
        inputSchema: ToolArgs.object([
            ("command", Schema.string("The command line, e.g. `ls -la ~/Desktop | head`.")),
            ("cwd", Schema.string("Folder to run in (default: the job folder, or home).")),
            ("timeout_s", Schema.number("Seconds before the command is stopped (default 60, max 600).")),
        ], required: ["command"]),
        category: .command)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        assessment(arguments, context: context).verdict
    }

    private func assessment(_ arguments: JSONValue, context: ToolContext) -> (verdict: ToolVerdict, readsClipboard: Bool, runsScript: Bool) {
        let command = arguments.optionalString("command") ?? ""
        let cwd = ToolArgs.pathForAssessment(arguments.optionalString("cwd"), context)?.path ?? context.workingDirectory.path
        let (verdict, programs, readsClipboard) = CommandSafety.analyze(command, cwd: cwd)
        // A script interpreter can read the clipboard through an obscured name built at run time,
        // so the concealed-item guard runs whenever one is used, not only on an obvious read.
        let runsScript = !programs.isDisjoint(with: ShellRiskChecker.scriptInterpreters)
        var v = verdict
        // Turning AppleScript or Shortcuts off also covers reaching them through the shell.
        let settings = context.settings.tools
        if !settings.allowAppleScript, programs.contains("osascript") {
            v.blocked = v.blocked ?? "AppleScript is turned off, including osascript in commands. You can allow it in Settings › Speed & Commands."
        }
        if !settings.allowShortcuts, programs.contains("shortcuts") || programs.contains("automator") {
            v.blocked = v.blocked ?? "Shortcuts are turned off, including the shortcuts command. You can allow them in Settings › Speed & Commands."
        }
        return (CommandFamilyGate.shell.apply(v, settings), readsClipboard, runsScript)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let command = try arguments.requiredString("command")
        let (verdict, readsClipboard, runsScript) = assessment(arguments, context: context)
        try CommandFamilyGate.enforce(verdict)
        if readsClipboard || runsScript { try await ConcealedClipboardGuard.check(pasteboardName) }
        try context.gate.checkStopped()
        let timeout = ToolArgs.seconds(arguments, "timeout_s", default: Self.defaultTimeout, max: Self.maxTimeout)
        let cwd = try arguments.optionalString("cwd").map { try ToolArgs.path($0, context) } ?? context.workingDirectory
        let result = try await ProcessRunner.run(executable: "/bin/zsh", arguments: ["-lc", command], cwd: cwd, timeout: timeout, gate: context.gate)
        if result.stopped { throw AutomationError.stopped }
        return CommandOutput.format(result, timeout: timeout, what: "The command")
    }
}

/// Turns a process result into model-visible text plus structured data.
enum CommandOutput {
    static func format(_ r: ProcessRunResult, timeout: Double, what: String) -> ToolOutput {
        let secs = String(format: "%.2f", r.durationMs / 1000)
        var parts: [String] = []
        if r.timedOut {
            parts.append("\(what) timed out after \(Int(timeout)) s and was stopped. Pass a larger timeout_s (max 600) if it needs longer.")
        } else if let sig = r.signal {
            parts.append("\(what) was ended by signal \(sig) after \(secs) s.")
        } else {
            parts.append("Exit code \(r.exitCode) · \(secs) s")
        }
        let out = r.stdoutText.trimmingCharacters(in: .newlines)
        let err = r.stderrText.trimmingCharacters(in: .newlines)
        if !out.isEmpty { parts.append(toolTruncate(out, max: err.isEmpty ? 7500 : 6000)) }
        if !err.isEmpty { parts.append("stderr:\n" + toolTruncate(err, max: out.isEmpty ? 6000 : 1500)) }
        if out.isEmpty && err.isEmpty && !r.timedOut { parts.append("(no output)") }
        if r.stdoutTruncated || r.stderrTruncated { parts.append("[output beyond 1 MB was discarded]") }
        if r.outputLeftOpen { parts.append("[a background process it started is still running and holding the output; Glide stopped reading]") }
        let data: JSONValue = [
            "exit_code": .number(Double(r.exitCode)),
            "stdout": .string(r.stdoutText),
            "stderr": .string(r.stderrText),
            "duration_ms": .number(r.durationMs.rounded()),
            "timed_out": .bool(r.timedOut),
            "truncated": .bool(r.stdoutTruncated || r.stderrTruncated),
        ]
        return ToolOutput(ok: !r.timedOut && r.signal == nil && r.exitCode == 0, text: parts.joined(separator: "\n"), data: data, durationMs: r.durationMs)
    }
}

// MARK: applescript.run / jxa.run

/// Runs AppleScript or JXA through `osascript`. Scripts are assessed with `ScriptSafety`.
struct OSAScriptTool: AgentTool {
    let language: ScriptSafety.Language
    let spec: ToolSpec
    /// Checked for concealed items before a script that reads the clipboard runs.
    let pasteboardName: NSPasteboard.Name?
    static let defaultTimeout: Double = 30

    init(language: ScriptSafety.Language, pasteboardName: NSPasteboard.Name? = nil) {
        self.language = language
        self.spec = Self.makeSpec(language)
        self.pasteboardName = pasteboardName
    }

    private static func makeSpec(_ language: ScriptSafety.Language) -> ToolSpec {
        switch language {
        case .appleScript:
            return ToolSpec(
                name: "applescript.run",
                summary: "Run AppleScript (osascript) and get the result. Good for scriptable apps: Finder, Mail, Calendar, Notes, Music, Safari.",
                inputSchema: ToolArgs.object([
                    ("script", Schema.string("AppleScript source; the value of the last statement (or `return x`) is the result.")),
                    ("timeout_s", Schema.number("Seconds before it is stopped (default 30, max 600).")),
                ], required: ["script"]),
                category: .command)
        case .javaScript:
            return ToolSpec(
                name: "jxa.run",
                summary: "Run JavaScript for Automation (osascript -l JavaScript) and get the result, e.g. `Application('Finder').selection().map(f => f.name())`.",
                inputSchema: ToolArgs.object([
                    ("script", Schema.string("JXA source; the value of the last expression is the result.")),
                    ("timeout_s", Schema.number("Seconds before it is stopped (default 30, max 600).")),
                ], required: ["script"]),
                category: .command)
        }
    }

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let script = arguments.optionalString("script") ?? ""
        let a = ScriptSafety.assess(script, language: language)
        let label = language == .appleScript ? "AppleScript" : "JavaScript for Automation"
        var one = script.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ ")
        if one.count > 140 { one = String(one.prefix(137)) + "…" }
        var v = ToolVerdict(risk: a.risk, reasons: a.reasons, summary: "Run \(label): \(one)")
        // A literal `do shell script "…"` is checked like shell.run, so the script route
        // can't be used to run something the shell route would block.
        for cmd in ScriptSafety.embeddedShellCommands(script) {
            let s = CommandSafety.assess(cmd, cwd: context.workingDirectory.path)
            if let b = s.blocked, v.blocked == nil { v.blocked = b }
            for r in s.reasons where !v.reasons.contains(r) { v.reasons.append(r) }
        }
        return CommandFamilyGate.appleScript.apply(v, context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let script = try arguments.requiredString("script")
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        // AppleScript and JXA can read the clipboard through a name built at run time (string
        // pieces, the ObjC bridge), so the concealed-item guard runs for every script, not only
        // when the source visibly mentions the clipboard.
        try await ConcealedClipboardGuard.check(pasteboardName)
        try context.gate.checkStopped()
        let timeout = ToolArgs.seconds(arguments, "timeout_s", default: Self.defaultTimeout, max: ShellRunTool.maxTimeout)
        let args = (language == .javaScript ? ["-l", "JavaScript"] : []) + ["-e", script]
        let r = try await ProcessRunner.run(executable: "/usr/bin/osascript", arguments: args, cwd: context.workingDirectory, timeout: timeout, gate: context.gate)
        if r.stopped { throw AutomationError.stopped }
        let label = language == .appleScript ? "The AppleScript" : "The script"
        if r.timedOut || r.signal != nil { return CommandOutput.format(r, timeout: timeout, what: label) }
        let out = r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.exitCode == 0 else {
            let err = r.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolOutput(ok: false, text: toolTruncate("\(label) failed: \(err.isEmpty ? "exit code \(r.exitCode)" : err)"),
                              data: ["exit_code": .number(Double(r.exitCode)), "stderr": .string(err)], durationMs: r.durationMs)
        }
        return ToolOutput(ok: true, text: out.isEmpty ? "(no result)" : toolTruncate(out), data: ["result": .string(out)], durationMs: r.durationMs)
    }
}

// MARK: shortcuts.list / shortcuts.run

struct ShortcutsListTool: AgentTool {
    let spec = ToolSpec(
        name: "shortcuts.list",
        summary: "List the user's Shortcuts by name.",
        inputSchema: ToolArgs.object([]),
        category: .command, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        CommandFamilyGate.shortcuts.apply(ToolVerdict(risk: .low, summary: "List your shortcuts"), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        try context.gate.checkStopped()
        let r = try await ProcessRunner.run(executable: "/usr/bin/shortcuts", arguments: ["list"], timeout: 30, gate: context.gate)
        if r.stopped { throw AutomationError.stopped }
        guard r.exitCode == 0, !r.timedOut else { return CommandOutput.format(r, timeout: 30, what: "Listing shortcuts") }
        let names = r.stdoutText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = names.isEmpty ? "No shortcuts found." : "\(names.count) shortcuts:\n" + toolTruncate(names.joined(separator: "\n"))
        return ToolOutput(ok: true, text: text, data: .array(names.map { .string($0) }), durationMs: r.durationMs)
    }
}

struct ShortcutsRunTool: AgentTool {
    static let defaultTimeout: Double = 120

    let spec = ToolSpec(
        name: "shortcuts.run",
        summary: "Run one of the user's Shortcuts by exact name, optionally with text input; returns its text output.",
        inputSchema: ToolArgs.object([
            ("name", Schema.string("Exact shortcut name (see shortcuts.list).")),
            ("input", Schema.string("Optional text passed to the shortcut as input.")),
            ("timeout_s", Schema.number("Seconds before it is stopped (default 120, max 600).")),
        ], required: ["name"]),
        category: .command)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let name = arguments.optionalString("name") ?? ""
        var risk = RiskLevel.medium
        var reasons = ["runs a shortcut (its actions can't be checked in advance)"]
        if SafetyPolicy.matches(ElementMatcher.normalize(name), SafetyPolicy.highRiskWords) {
            risk = .high
            reasons = ["runs the shortcut “\(name)”"]
        }
        return CommandFamilyGate.shortcuts.apply(ToolVerdict(risk: risk, reasons: reasons, summary: "Run the shortcut “\(name)”"), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let name = try arguments.requiredString("name")
        guard !name.hasPrefix("-") else { throw ToolError.invalidArguments("a shortcut name can't start with “-”") }
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        try context.gate.checkStopped()
        let timeout = ToolArgs.seconds(arguments, "timeout_s", default: Self.defaultTimeout, max: ShellRunTool.maxTimeout)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("glide-shortcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outURL = tmp.appendingPathComponent("output")
        var args = ["run", name, "--output-path", outURL.path]
        if let input = arguments.optionalString("input") {
            let inURL = tmp.appendingPathComponent("input.txt")
            try Data(input.utf8).write(to: inURL)
            args += ["--input-path", inURL.path]
        }
        let r = try await ProcessRunner.run(executable: "/usr/bin/shortcuts", arguments: args, timeout: timeout, gate: context.gate)
        if r.stopped { throw AutomationError.stopped }
        if r.timedOut || r.signal != nil || r.exitCode != 0 {
            var o = CommandOutput.format(r, timeout: timeout, what: "The shortcut")
            if r.exitCode != 0, !r.timedOut, r.stderrText.lowercased().contains("couldn’t find") || r.stderrText.lowercased().contains("couldn't find") {
                o.text = "There's no shortcut named “\(name)”. Use shortcuts.list to see the exact names."
            }
            return o
        }
        var output = ""
        if let data = try? Data(contentsOf: outURL, options: .mappedIfSafe) {
            if let s = String(data: data.prefix(ProcessRunner.defaultOutputCap), encoding: .utf8) { output = s }
            else { output = "(the shortcut returned \(data.count) bytes of non-text output)" }
        } else {
            output = r.stdoutText
        }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return ToolOutput(ok: true, text: output.isEmpty ? "The shortcut ran (no output)." : toolTruncate(output),
                          data: ["output": .string(output)], durationMs: r.durationMs)
    }
}
