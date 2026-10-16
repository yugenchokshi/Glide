import Foundation
import AppKit
import AutomationKit

/// The 12-scenario regression suite from the PRD (§14), run against disposable fixtures:
/// the NBFixture app, temp files, a local HTML form, and test notes that are removed after.
/// Deterministic (no model calls) so it measures the engine itself.
public final class BenchmarkSuite: @unchecked Sendable {
    public struct Result: Codable, Sendable {
        public var id: Int
        public var name: String
        public var success: Bool
        public var actions: Int
        public var durationMs: Double
        public var modelCalls: Int
        public var visionCalls: Int
        public var ocrCalls: Int
        public var userInterventions: Int
        public var recoveries: Int
        public var estimatedCost: Double
        public var avgObservationMs: Double
        public var error: String?
    }

    public let runtime: AutomationRuntime
    public let fixtureURL: URL?
    public var log: (String) -> Void = { print($0) }
    let workDir: URL
    var fixture: NSRunningApplication?

    public init(runtime: AutomationRuntime = .shared, fixtureURL: URL?) {
        self.runtime = runtime
        self.fixtureURL = fixtureURL
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("notchbuddy-bench-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    public static let scenarioNames = [
        "Open an application", "Create a new note", "Save a TextEdit document", "Rename a file in Finder",
        "Navigate a browser page", "Fill out a web form", "Switch between two applications", "Interact with a system dialog",
        "Recover from a missing element", "Stop a task mid-execution", "Request approval before a sensitive action",
        "Handle an inaccessible control",
    ]

    public func run(only: Set<Int>? = nil) async -> [Result] {
        var results: [Result] = []
        for (i, name) in Self.scenarioNames.enumerated() {
            let id = i + 1
            if let only, !only.contains(id) { continue }
            log("\n[\(id)] \(name)")
            runtime.gate.reset()
            let runner = ScriptRunner(runtime: runtime)
            runner.log = log
            let start = Date()
            var failure: String?
            var ocr = 0
            do {
                ocr = try await scenario(id, runner)
            } catch {
                failure = error.localizedDescription
                log("  ✗ \(error.localizedDescription)")
            }
            runtime.gate.reset()
            let s = runner.stats
            let r = Result(id: id, name: name, success: failure == nil, actions: s.actions, durationMs: Date().timeIntervalSince(start) * 1000,
                           modelCalls: 0, visionCalls: 0, ocrCalls: ocr, userInterventions: 0, recoveries: s.recoveries, estimatedCost: 0,
                           avgObservationMs: s.observations > 0 ? s.observationMs / Double(s.observations) : 0, error: failure)
            log(r.success ? "  ✓ passed in \(Int(r.durationMs))ms" : "  ✗ failed")
            results.append(r)
        }
        await cleanup()
        return results
    }

    // MARK: Fixtures

    func launchFixture() async throws -> AppInfo {
        if let f = fixture, !f.isTerminated {
            return try await runtime.executor.apps.activate(f, timeout: 6)
        }
        guard let url = fixtureURL, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw AutomationError.appNotFound("NBFixtureApp (build it with `swift build`)")
        }
        let p = Process()
        p.executableURL = url
        try p.run()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let app = NSRunningApplication(processIdentifier: p.processIdentifier), app.isFinishedLaunching {
                fixture = app
                return try await runtime.executor.apps.activate(app, timeout: 6)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AutomationError.timeout("fixture launch")
    }

    func writeHTML() throws -> URL {
        let form = """
        <!doctype html><html><head><meta charset="utf-8"><title>NB Form</title></head><body style="font:16px -apple-system;padding:24px">
        <h1>NotchBuddy Form</h1>
        <form onsubmit="event.preventDefault();document.getElementById('result').textContent='Thanks, '+document.getElementById('name').value+'!';document.title='NB Submitted';">
        <p><label for="name">Full name</label> <input id="name" name="name"></p>
        <p><label for="email">Email address</label> <input id="email" name="email" type="email"></p>
        <p><button type="submit">Submit form</button></p></form>
        <p id="result"></p>
        <p><a href="page2.html">Go to page two</a></p>
        </body></html>
        """
        let page2 = "<!doctype html><html><head><title>NB Page Two</title></head><body><h1>Page two reached</h1></body></html>"
        let url = workDir.appendingPathComponent("form.html")
        try form.write(to: url, atomically: true, encoding: .utf8)
        try page2.write(to: workDir.appendingPathComponent("page2.html"), atomically: true, encoding: .utf8)
        return url
    }

    func cleanup() async {
        if let f = fixture, !f.isTerminated { f.terminate() }
        try? FileManager.default.removeItem(at: workDir)
    }

    func statusText(_ r: ScriptRunner, _ app: AppInfo) async throws -> String {
        try await r.text(of: "status", in: app)
    }

    // MARK: Scenarios

    /// Returns the number of OCR passes used.
    func scenario(_ id: Int, _ r: ScriptRunner) async throws -> Int {
        let apps = runtime.executor.apps
        switch id {
        case 1:
            try await r.act(.launchApp("TextEdit"), expect: .appFrontmost("TextEdit"), timeout: 8, requireVerified: true)
            try await dismissOpenPanel(r)

        case 2:
            try await r.act(.launchApp("Notes"), expect: .appFrontmost("Notes"), timeout: 8, requireVerified: true)
            try await r.act(.keyPress(try KeyCombination(parsing: "cmd+n")), expect: .uiChanged)
            try await Task.sleep(for: .milliseconds(400))
            let title = "NotchBuddy bench note \(Int(Date().timeIntervalSince1970))"
            try await r.act(.typeText(title + "\nCreated by the NotchBuddy benchmark.", into: nil, clearFirst: false, submit: false),
                            expect: .focusedValueContains("Created by the NotchBuddy benchmark"), timeout: 3, requireVerified: true)

        case 3:
            try await r.act(.launchApp("TextEdit"), expect: .appFrontmost("TextEdit"), timeout: 8)
            try await dismissOpenPanel(r)
            try await r.act(.keyPress(try KeyCombination(parsing: "cmd+n")), expect: .uiChanged)
            try await Task.sleep(for: .milliseconds(300))
            try await r.act(.typeText("Saved by the NotchBuddy benchmark.", into: nil, clearFirst: false, submit: false),
                            expect: .focusedValueContains("Saved by the NotchBuddy benchmark"))
            try await r.act(.keyPress(try KeyCombination(parsing: "cmd+s")), expect: .uiChanged)
            _ = try await r.waitFor("Save As", timeout: 4)
            try await r.act(.typeText("nb-bench-doc", into: nil, clearFirst: true, submit: false))
            try await r.act(.keyPress(try KeyCombination(parsing: "cmd+shift+g")), expect: .uiChanged)
            try await Task.sleep(for: .milliseconds(400))
            try await r.act(.typeText(workDir.path, into: nil, clearFirst: true, submit: true))
            try await Task.sleep(for: .milliseconds(500))
            try await r.act(.keyPress(try KeyCombination(parsing: "return")))
            let rtf = workDir.appendingPathComponent("nb-bench-doc.rtf").path, txt = workDir.appendingPathComponent("nb-bench-doc.txt").path
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline && !FileManager.default.fileExists(atPath: rtf) && !FileManager.default.fileExists(atPath: txt) {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: rtf) || FileManager.default.fileExists(atPath: txt) else {
                throw AutomationError.verificationFailed("document wasn't saved to \(workDir.path)")
            }
            try await r.act(.keyPress(try KeyCombination(parsing: "cmd+w")))

        case 4:
            let file = workDir.appendingPathComponent("nb-rename-me.txt")
            try "rename me".write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([file])
            let finder = try await apps.activate("Finder", timeout: 6)
            try await Task.sleep(for: .milliseconds(600))
            try await r.act(.keyPress(try KeyCombination(parsing: "return")), in: finder, expect: .uiChanged)
            try await Task.sleep(for: .milliseconds(300))
            try await r.act(.keyPress(try KeyCombination(parsing: "cmd+a")), in: finder)
            try await r.act(.typeText("nb-renamed.txt", into: nil, clearFirst: false, submit: true), in: finder,
                            expect: .fileExists(workDir.appendingPathComponent("nb-renamed.txt").path), timeout: 4, requireVerified: true)

        case 5:
            let url = try writeHTML()
            try await apps.open(url: url, withApp: "Safari")
            let safari = try await apps.activate("Safari", timeout: 8)
            try await Task.sleep(for: .milliseconds(800))
            try await r.click("Go to page two", in: safari, expect: .windowTitleContains("NB Page Two"))

        case 6:
            let url = try writeHTML()
            try await apps.open(url: url, withApp: "Safari")
            let safari = try await apps.activate("Safari", timeout: 8)
            _ = try await r.waitFor("Full name", in: safari, timeout: 6)
            try await r.act(.typeText("Ada Lovelace", into: .description("Full name"), clearFirst: true, submit: false), in: safari)
            try await r.act(.typeText("ada@example.com", into: .description("Email address"), clearFirst: true, submit: false), in: safari)
            try await r.click("Submit form", in: safari, expect: .windowTitleContains("NB Submitted"))
            _ = try await r.waitFor("Thanks, Ada Lovelace!", in: safari, timeout: 3)
            try await r.act(.keyPress(try KeyCombination(parsing: "cmd+w")), in: safari)

        case 7:
            try await r.act(.activateApp("TextEdit"), expect: .appFrontmost("TextEdit"), timeout: 6, requireVerified: true)
            let f = try await launchFixture()
            try await r.act(.activateApp(f.name), expect: .appFrontmost(f.name), timeout: 6, requireVerified: true)
            try await r.act(.activateApp("TextEdit"), expect: .appFrontmost("TextEdit"), timeout: 6, requireVerified: true)

        case 8:
            let f = try await launchFixture()
            try await r.click("Open Dialog", in: f)
            _ = try await r.waitFor("Confirm", in: f, timeout: 3)
            try await r.click("Confirm", in: f)
            let s = try await statusText(r, f)
            guard s.contains("dialog confirmed") else { throw AutomationError.verificationFailed("status is “\(s)”") }

        case 9:
            let f = try await launchFixture()
            try await r.click("Secret Action", in: f, recover: {
                try await r.click("Reveal Secret", in: f)
                _ = try await r.waitFor("Secret Action", in: f, timeout: 3)
            })
            let s = try await statusText(r, f)
            guard s.contains("secret unlocked") else { throw AutomationError.verificationFailed("status is “\(s)”") }

        case 10:
            let f = try await launchFixture()
            try await r.click("Your name", in: f)
            let long = String(repeating: "stop me ", count: 60)
            let gate = runtime.gate
            let typing = Task.detached { () -> Error? in
                do { try self.runtime.executor.input.type(long); return nil } catch { return error }
            }
            try await Task.sleep(for: .milliseconds(250))
            let stopAt = Date()
            gate.stop()
            let err = await typing.value
            let stopLatency = Date().timeIntervalSince(stopAt) * 1000
            gate.reset()
            let typed = try await r.text(of: "Your name", in: f)
            log("  • stop latency \(Int(stopLatency))ms, typed \(typed.count)/\(long.count) chars, error: \(err?.localizedDescription ?? "none")")
            guard err != nil, typed.count < long.count else { throw AutomationError.verificationFailed("typing was not interrupted") }
            try await r.act(.typeText("", into: .description("Your name"), clearFirst: true, submit: false), in: f)

        case 11:
            let f = try await launchFixture()
            let obs = try await r.observe(f)
            guard let node = ElementMatcher.unambiguousBest(ElementMatcher.rank("Delete Everything", in: obs.elements)) else {
                throw AutomationError.elementNotFound("Delete Everything")
            }
            let policy = SafetyPolicy(settings: SafetySettings())
            let verdict = policy.assess(.click(.element(node.id)), target: node, app: f, modelRisk: .low, stepRisk: .low)
            guard verdict.risk == .high, policy.needsApproval(verdict) else { throw AutomationError.verificationFailed("delete was not flagged as high risk") }
            log("  • flagged high risk (\(verdict.reasons.joined(separator: ", "))); simulating rejection")
            let before = try await statusText(r, f)
            guard !before.contains("deleted") else { throw AutomationError.verificationFailed("acted before approval") }
            log("  • simulating approval")
            try await r.click("Delete Everything", in: f)
            let after = try await statusText(r, f)
            guard after.contains("everything deleted") else { throw AutomationError.verificationFailed("status is “\(after)”") }

        case 12:
            let f = try await launchFixture()
            let obs = try await r.observe(f)
            if ElementMatcher.rank("LAUNCH ROCKET", in: obs.elements.filter { $0.source == .accessibility }, limit: 1).first.map({ $0.score >= 0.8 }) == true {
                throw AutomationError.verificationFailed("canvas control is unexpectedly accessible")
            }
            guard ScreenCapture.hasPermission else { throw AutomationError.screenRecordingNotGranted }
            let hit = try await VisionGrounding(perception: runtime.perception).groundWithOCR("LAUNCH ROCKET", obs: obs)
            guard let hit else { throw AutomationError.elementNotFound("LAUNCH ROCKET via OCR") }
            log("  • OCR located the control at (\(Int(hit.point.x)), \(Int(hit.point.y)))")
            try await r.act(.click(.point(hit.point)), in: f)
            let s = try await statusText(r, f)
            guard s.contains("canvas clicked") else { throw AutomationError.verificationFailed("status is “\(s)”") }
            return 1

        default:
            break
        }
        return 0
    }

    /// TextEdit opens an Open panel on launch when iCloud Drive is enabled; dismiss it.
    func dismissOpenPanel(_ r: ScriptRunner) async throws {
        try await Task.sleep(for: .milliseconds(500))
        if let obs = try? await r.observe(), obs.elements.contains(where: { $0.role == "button" && $0.name == "New Document" }) {
            try await r.act(.click(.description("New Document")))
        }
    }
}
