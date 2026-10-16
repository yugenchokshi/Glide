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
        if ["--app", "--only", "--json", "--mock-url", "--model", "--provider"].contains(a) { skip = true; continue }
        if a.hasPrefix("--") { continue }
        out.append(a)
    }
    return out
}

let runtime = AutomationRuntime.shared
let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("NBFixtureApp")

@MainActor
func main() async -> Int32 {
    guard let command = args.first else {
        print("usage: glidectl inspect|click|type|key|menu|workflow|bench|run|permissions …")
        return 2
    }
    if command != "permissions" && !AccessibilityEngine.isTrusted {
        print("✗ Accessibility permission is not granted to this process.")
        return 1
    }
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
exit(code)
