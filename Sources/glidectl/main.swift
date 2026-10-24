import Foundation
import AppKit
import AutomationKit
import AgentKit

// glidectl — headless companion to Glide.
//   glidectl inspect [app] [--ocr]     print the indexed UI skeleton of an app's focused window
//   glidectl click "<label>" [--app X] click an element by label (real cursor)
//   glidectl type "<text>"             type into the focused element
//   glidectl key cmd+n                 press a key combination
//   glidectl menu "File > New"         choose a menu item in the frontmost app
//   glidectl workflow                  Finder + Notes deterministic workflow (Phase 2 acceptance)
//   glidectl bench [--only 1,2] [--json out.json]   run the 12-scenario benchmark
//   glidectl run "<task>" [--mock-url URL] [--yes]  run the full agent with configured providers
//   glidectl permissions               show permission status
//   glidectl tool list [--category browser]       list the agent's tools
//   glidectl tool run <name> '<json args>' [--yes] [--headless]   run one tool (safety-checked)
//   glidectl browser status                       which Chrome backend is available
//   glidectl job run "<task>" [--mock-url URL] [--yes]   plan and run a long-running job here
//   glidectl job list | job show <id> | job resume <id> [--yes]

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { args.contains(name) }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
var positional: [String] {
    var out: [String] = []
    var skip = false
    for a in args.dropFirst() {
        if skip { skip = false; continue }
        if ["--app", "--only", "--json", "--mock-url", "--model", "--provider", "--category"].contains(a) { skip = true; continue }
        if a.hasPrefix("--") { continue }
        out.append(a)
    }
    return out
}

let runtime = AutomationRuntime.shared
/// The throwaway headless Chrome started by `--headless` (shut down before exiting).
nonisolated(unsafe) var cliHeadless: (backend: GlideChromeBackend, profile: URL)?
let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("NBFixtureApp")

@MainActor
func main() async -> Int32 {
    guard let command = args.first else {
        print("usage: glidectl inspect|click|type|key|menu|workflow|bench|run|permissions …")
        return 2
    }
    // Tools, jobs and the browser don't need Accessibility; driving the UI does.
    let needsAccessibility = !["permissions", "tool", "job", "browser"].contains(command)
    if needsAccessibility && !AccessibilityEngine.isTrusted {
        print("✗ Accessibility permission is not granted to this process.")
        return 1
    }
    if flag("--headless") {
        // A throwaway headless Chrome profile, so CLI runs never touch Glide's real one.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glidectl-chrome-\(ProcessInfo.processInfo.processIdentifier)")
        let backend = GlideChromeBackend(configuration: .init(userDataDirectory: dir, headless: true))
        BrowserHub.shared.register(backend)
        cliHeadless = (backend, dir)
    }
    // The app owns the extension bridge's port, so the CLI uses Glide's own Chrome window.
    var cliSettings = SettingsStore.loadSnapshot()
    cliSettings.browser.backend = .glideChrome
    AgentSetup.installAll(settings: cliSettings, startBrowserBridge: false)
    let runner = ScriptRunner(runtime: runtime)
    func targetApp() throws -> AppInfo {
        if let name = option("--app") {
            guard let app = runtime.executor.apps.runningApp(named: name) else { throw AutomationError.appNotRunning(name) }
            return runtime.executor.apps.info(for: app)
        }
        return try runner.frontmost()
    }
    do {
        switch command {
        case "permissions":
            for k in PermissionKind.allCases { print("\(k.title): \(PermissionManager.status(k).rawValue)") }

        case "inspect":
            var app: AppInfo
            if let name = positional.first {
                app = try await runtime.executor.apps.activate(name)
                try await Task.sleep(for: .milliseconds(300))
            } else {
                app = try targetApp()
            }
            let t = Date()
            let obs = try await runtime.perception.observe(app, forceOCR: flag("--ocr"), useCache: false)
            print(obs.compact(maxElements: 400, maxTextChars: 4000))
            print("\n— \(obs.elements.count) elements (\(obs.interactiveCount) interactive) · AX \(String(format: "%.1f", obs.durationMs))ms · total \(Int(Date().timeIntervalSince(t) * 1000))ms")
            let t2 = Date()
            _ = try runtime.accessibility.observe(app, useCache: true)
            print("— cached lookup \(String(format: "%.2f", Date().timeIntervalSince(t2) * 1000))ms")

        case "click":
            guard let label = positional.first else { print("glidectl click \"<label>\""); return 2 }
            if let name = option("--app") { _ = try await runtime.executor.apps.activate(name) }
            try await runner.act(.click(.description(label)))

        case "type":
            guard let text = positional.first else { return 2 }
            try await runner.act(.typeText(text, into: nil, clearFirst: false, submit: flag("--submit")))

        case "key":
            guard let k = positional.first else { return 2 }
            try await runner.act(.keyPress(try KeyCombination(parsing: k)))

        case "menu":
            guard let p = positional.first else { return 2 }
            if let name = option("--app") { _ = try await runtime.executor.apps.activate(name) }
            try await runner.act(.menu(p.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }))

        case "workflow":
            try await finderNotesWorkflow(runner)

        case "bench":
            let only = option("--only").map { Set($0.split(separator: ",").compactMap { Int($0) }) }
            let suite = BenchmarkSuite(runtime: runtime, fixtureURL: fixtureURL)
            let results = await suite.run(only: only)
            printTable(results)
            if let path = option("--json") {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(results).write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            }
            return results.allSatisfy(\.success) ? 0 : 1

        case "run":
            guard let task = positional.first else { print("glidectl run \"<task>\""); return 2 }
            var settings = SettingsStore.loadSnapshot()
            if let mock = option("--mock-url") {
                var p = ProviderConfig(id: "mock", kind: .openaiCompatible, name: "Mock", baseURL: mock, requiresKey: false, models: [option("--model") ?? "mock"])
                p.enabled = true
                settings.providers = [p]
                settings.routing = RoutingSettings()
                settings.routing.preferredProviderID = "mock"
            }
            settings.safety.pauseOnUserInput = false
            let autoApprove = flag("--yes")
            let callbacks = AgentCallbacks(
                phase: { p, s in print("◆ [\(p.rawValue)] \(s)") },
                log: { e in
                    let mark = e.success.map { $0 ? "✓" : "✗" } ?? "·"
                    print("  \(mark) \(e.kind.rawValue): \(e.title)\(e.detail.map { " — " + $0.replacingOccurrences(of: "\n", with: " | ").prefix(220) } ?? "")")
                },
                plan: { _, _ in },
                approve: { req in
                    print("⚠︎ Approval needed (\(req.risk.rawValue)): \(req.title) — \(req.reasons.joined(separator: ", "))")
                    if autoApprove { print("  auto-approved (--yes)"); return .approve }
                    print("  approve? [y/N/s(top)] ", terminator: "")
                    let answer = await Task.detached { readLine() ?? "" }.value.lowercased()
                    return answer == "y" ? .approve : (answer == "s" ? .stop : .reject)
                })
            runtime.gate.reset()
            let orchestrator = ExecutionOrchestrator(instruction: task, settings: settings, runtime: runtime, callbacks: callbacks)
            signal(SIGINT, SIG_IGN)
            let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sig.setEventHandler { print("\n■ stop requested"); orchestrator.stop() }
            sig.resume()
            let result = await orchestrator.run()
            let m = result.metrics
            print("\n\(result.status.rawValue.uppercased()): \(result.summary)\(result.error.map { " — " + $0 } ?? "")")
            print("duration \(Int(result.durationMs))ms · actions \(m.actions) (\(m.deterministicActions) deterministic) · model calls \(m.modelCalls) · vision \(m.visionCalls) · tokens \(m.inputTokens)/\(m.outputTokens) · recoveries \(m.recoveries)" + (m.estimatedCost.map { String(format: " · ~$%.4f", $0) } ?? ""))
            return result.status == .completed ? 0 : 1

        case "tool":
            return try await toolCommand(settings: cliSettings)

        case "browser":
            let status = await BrowserHub.shared.status(settings: cliSettings.browser)
            print("backend: \(status.backend.title)\nconnected: \(status.connected)\nchrome installed: \(status.chromeInstalled)\n\(status.detail)")

        case "job":
            return await jobCommand(settings: cliSettings)

        default:
            print("unknown command \(command)")
            return 2
        }
    } catch {
        print("✗ \(error.localizedDescription)")
        return 1
    }
    return 0
}

/// Applies `--mock-url` (an OpenAI-compatible endpoint) to a settings copy.
func applyMock(_ settings: inout AppSettings) {
    guard let mock = option("--mock-url") else { return }
    var p = ProviderConfig(id: "mock", kind: .openaiCompatible, name: "Mock", baseURL: mock, requiresKey: false, models: [option("--model") ?? "mock"])
    p.enabled = true
    settings.providers = [p]
    settings.routing = RoutingSettings()
    settings.routing.preferredProviderID = "mock"
}

func askApproval(_ title: String, risk: RiskLevel, reasons: [String]) async -> ApprovalDecision {
    print("⚠︎ Approval needed (\(risk.rawValue)): \(title)\(reasons.isEmpty ? "" : " — " + reasons.joined(separator: ", "))")
    if flag("--yes") { print("  auto-approved (--yes)"); return .approve }
    print("  approve? [y/N/s(top)] ", terminator: "")
    let answer = await Task.detached { readLine() ?? "" }.value.lowercased()
    return answer == "y" ? .approve : (answer == "s" ? .stop : .reject)
}

@MainActor
func toolCommand(settings: AppSettings) async throws -> Int32 {
    let registry = ToolRegistry.standard(settings: settings)
    switch positional.first {
    case "list":
        let category = option("--category").flatMap(ToolCategory.init(rawValue:))
        for s in registry.specs(in: category.map { [$0] }) {
            print("\(s.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(s.category.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(s.readOnly ? "read-only " : "          ")\(s.summary)")
        }
        return 0
    case "run":
        let rest = Array(positional.dropFirst())
        guard let name = rest.first else { print("glidectl tool run <name> '<json args>'"); return 2 }
        guard let tool = registry.tool(named: name) else { throw ToolError.unknownTool(name) }
        let arguments = rest.count > 1 ? try JSONValue.parse(rest[1]) : [:]
        let gate = ExecutionGate()
        let context = ToolContext(settings: settings, gate: gate, log: { e in print("  · \(e.title)") })
        let verdict = tool.assess(arguments, context: context)
        print("◆ \(verdict.summary) — risk \(verdict.risk.rawValue)")
        if let blocked = verdict.blocked { print("✗ blocked: \(blocked)"); return 1 }
        if SafetyPolicy(settings: settings.safety).needsApproval(verdict.safetyVerdict) {
            guard await askApproval(verdict.summary, risk: verdict.risk, reasons: verdict.reasons) == .approve else { print("declined"); return 1 }
        }
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sig.setEventHandler { print("\n■ stop requested"); gate.stop() }
        sig.resume()
        let t = Date()
        let output = try await tool.run(arguments, context: context)
        print(output.text)
        if let data = output.data, flag("--json") { print(data.jsonString(pretty: true)) }
        print("\(output.ok ? "✓ ok" : "✗ failed") in \(Int(Date().timeIntervalSince(t) * 1000))ms")
        return output.ok ? 0 : 1
    default:
        print("glidectl tool list | tool run <name> '<json>'")
        return 2
    }
}

@MainActor
func jobCommand(settings base: AppSettings) async -> Int32 {
    var settings = base
    applyMock(&settings)
    settings.safety.pauseOnUserInput = false
    let center = JobCenter(settingsOverride: settings)
    center.reload()
    switch positional.first {
    case "list":
        for j in center.jobs.prefix(30) {
            print("\(j.id.prefix(8))  \(j.status.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) \(j.title)  · \(j.statusLine)")
        }
        return 0
    case "show":
        guard let prefix = positional.dropFirst().first, let j = center.jobs.first(where: { $0.id.hasPrefix(prefix) }) else { print("job not found"); return 1 }
        printJob(j, center: center)
        return 0
    case "run", "resume":
        let id: String
        if positional.first == "run" {
            guard let text = positional.dropFirst().first else { print("glidectl job run \"<task>\""); return 2 }
            print("◆ planning…")
            let job = await center.create(instruction: text, autoStartIfSmall: false)
            if let plan = job.plan { printPlan(plan) }
            guard job.status == .awaitingConfirmation || job.status == .running else {
                print("✗ \(job.statusLine) \(job.lastError ?? "")")
                return 1
            }
            if job.status == .awaitingConfirmation {
                if let e = job.plan?.estimate {
                    print("Estimate: \(e.items) items · ~\(e.modelCalls) model calls · ~\(Int(e.minutes.rounded())) min" + (e.costUSD.map { String(format: " · ~$%.2f", $0) } ?? ""))
                }
                if !flag("--yes") {
                    print("Start? [y/N] ", terminator: "")
                    guard (await Task.detached { readLine() ?? "" }.value.lowercased()) == "y" else { center.stop(job.id); return 1 }
                }
                center.start(job.id)
            }
            id = job.id
        } else {
            guard let prefix = positional.dropFirst().first, let j = center.jobs.first(where: { $0.id.hasPrefix(prefix) }) else { print("job not found"); return 1 }
            id = j.id
            guard j.status.isResumable else { print("✗ This job is \(j.status.rawValue) and can't be resumed."); return 1 }
            center.resume(id)
        }
        signal(SIGINT, SIG_IGN)
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        // Like the emergency stop: end the step in flight now, keep the job paused and resumable.
        sig.setEventHandler { print("\n■ halting — resume with: glidectl job resume \(id.prefix(8))"); center.haltAll() }
        sig.resume()
        // Follow the job: print new log lines, answer approvals, stop when it settles.
        var seen = Set<UUID>()
        var lastLine = ""
        while true {
            for e in center.events(id, limit: 50) where !seen.contains(e.id) {
                seen.insert(e.id)
                let mark = e.success.map { $0 ? "✓" : "✗" } ?? "·"
                print("  \(mark) \(e.kind.rawValue): \(e.title)\(e.detail.map { " — " + $0.replacingOccurrences(of: "\n", with: " | ").prefix(200) } ?? "")")
            }
            if let req = center.pendingApprovals[id] {
                center.respond(jobID: id, decision: await askApproval(req.title, risk: req.risk, reasons: req.reasons))
            }
            guard let j = center.job(id) else { break }
            if j.statusLine != lastLine { lastLine = j.statusLine; print("◆ [\(j.status.rawValue)] \(j.statusLine)") }
            if [.completed, .failed, .stopped, .needsInput, .paused, .waiting].contains(j.status), !center.isRunnerActive(id) {
                printJob(j, center: center)
                return j.status == .completed ? 0 : 1
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return 1
    default:
        print("glidectl job run \"<task>\" | job list | job show <id> | job resume <id>")
        return 2
    }
}

func printPlan(_ plan: JobPlan) {
    print("Plan: \(plan.goal)")
    for m in plan.milestones {
        print("  ▸ \(m.title)\(m.requiresApproval ? " (asks first)" : "")")
        for s in m.steps {
            switch s.kind {
            case .action(let r): print("      · \(s.title) [\(r.route.rawValue)]")
            case .forEach(let f): print("      · \(s.title) — for each \(f.itemLabel) ×\(f.parallelism) [\(f.recipe.map(\.route.rawValue).joined(separator: ","))] → \(f.outputTable)")
            case .wait(let w): print("      · \(s.title) — wait \(w)")
            }
        }
    }
}

@MainActor
func printJob(_ j: JobRecord, center: JobCenter) {
    let u = j.usage
    print("\n\(j.status.rawValue.uppercased()): \(j.title)\n\(j.statusLine)\(j.lastError.map { "\n" + $0 } ?? "")")
    print("items \(u.itemsDone)/\(u.itemsTotal) done, \(u.itemsFailed) failed · model calls \(u.modelCalls) · tool calls \(u.toolCalls) · tokens \(u.inputTokens)/\(u.outputTokens) · active \(Int(u.activeSeconds))s" + (u.costKnown ? String(format: " · ~$%.4f", u.costUSD) : ""))
    if let summary = j.summary { print("\n\(summary)") }
    print("folder: \(j.folder)")
}

@MainActor
func finderNotesWorkflow(_ r: ScriptRunner) async throws {
    let start = Date()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-workflow")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("quarterly-draft.txt")
    try "draft".write(to: file, atomically: true, encoding: .utf8)
    let newName = "quarterly-final-\(Int(Date().timeIntervalSince1970) % 10000).txt"
    print("1. Finder: rename \(file.lastPathComponent) → \(newName)")
    NSWorkspace.shared.activateFileViewerSelecting([file])
    let finder = try await runtime.executor.apps.activate("Finder", timeout: 6)
    try await Task.sleep(for: .milliseconds(700))
    try await r.act(.keyPress(try KeyCombination(parsing: "return")), in: finder)
    try await Task.sleep(for: .milliseconds(300))
    try await r.act(.keyPress(try KeyCombination(parsing: "cmd+a")), in: finder)
    try await r.act(.typeText(newName, into: nil, clearFirst: false, submit: true), in: finder,
                    expect: .fileExists(dir.appendingPathComponent(newName).path), timeout: 4, requireVerified: true)
    print("2. Notes: record the rename in a new note")
    try await r.act(.launchApp("Notes"), expect: .appFrontmost("Notes"), timeout: 8, requireVerified: true)
    try await r.act(.keyPress(try KeyCombination(parsing: "cmd+n")), expect: .uiChanged)
    try await Task.sleep(for: .milliseconds(400))
    let body = "Glide bench workflow\nRenamed quarterly-draft.txt to \(newName)"
    try await r.act(.typeText(body, into: nil, clearFirst: false, submit: false), expect: .focusedValueContains(newName), timeout: 3, requireVerified: true)
    print("3. Cleanup")
    try await BenchmarkSuite.deleteTestNote(r, title: "Glide bench workflow", log: { print($0) })
    try? FileManager.default.removeItem(at: dir)
    print("✓ workflow verified in \(Int(Date().timeIntervalSince(start) * 1000))ms · \(r.stats.actions) actions · avg observation \(Int(r.stats.observationMs / Double(max(1, r.stats.observations))))ms")
}

func printTable(_ results: [BenchmarkSuite.Result]) {
    print("\n#  Scenario                                   OK  Actions  Duration  Obs(ms)  Recov  OCR  Model  Vision  Cost")
    for r in results {
        let name = r.name.padding(toLength: 42, withPad: " ", startingAt: 0)
        print(String(format: "%-2d %@ %@  %7d  %7.1fs  %7.0f  %5d  %3d  %5d  %6d  $%.2f", r.id, name, r.success ? "✓ " : "✗ ", r.actions, r.durationMs / 1000, r.avgObservationMs, r.recoveries, r.ocrCalls, r.modelCalls, r.visionCalls, r.estimatedCost))
        if let e = r.error { print("   └ \(e)") }
    }
    print("passed \(results.filter(\.success).count)/\(results.count)")
}

let code = await main()
if let headless = cliHeadless {
    await headless.backend.shutdown()
    try? FileManager.default.removeItem(at: headless.profile)
}
exit(code)
