import Testing
import Foundation
import Synchronization
@testable import AgentKit
@testable import AutomationKit

// The loop breaker, the on-screen try for stuck browser steps, and what retries are told.
// Everything runs on a scripted model and fake browser tools that report a page fingerprint
// the test moves; nothing here touches the screen, a real browser or the network.

// MARK: - Fakes

/// A page the fake browser tools show: its fingerprint changes only when the test says a
/// click changes it.
final class FakePage: @unchecked Sendable {
    private let lock = NSLock()
    private var _fingerprint = "page-1"
    var url = "https://shop.test/product/1"
    var clickChangesPage = true
    var findScrolls = true
    var botCheck = false

    var fingerprint: String { lock.withLock { _fingerprint } }
    func change(_ to: String) { lock.withLock { _fingerprint = to } }

    func output(_ lead: String) -> ToolOutput {
        let fp = fingerprint
        let text = "\(lead)\n\npage: \"Product\" \(url)\nb1 button \"ADD TO CART - $100\"\nb2 textbox \"Discount code\"\n(\(fp))"
        var data: [String: JSONValue] = [
            "url": .string(url), "title": "Product", "fingerprint": .string(fp),
            "elements": [["ref": "b1", "role": "button", "name": "ADD TO CART - $100"], ["ref": "b2", "role": "textbox", "name": "Discount code"]],
        ]
        if botCheck { data["botCheck"] = true }
        return ToolOutput(ok: true, text: text, data: .object(data))
    }

    /// The browser tools a step uses, each with the summary the real one logs.
    func tools() -> [FakeTool] {
        func tool(_ name: String, _ summary: String, _ run: @escaping @Sendable (JSONValue) -> ToolOutput) -> FakeTool {
            FakeTool(name, category: .browser, handler: { args, _ in run(args) }, verdict: { _ in ToolVerdict(risk: .low, summary: summary) })
        }
        return [
            tool("browser.snapshot", "Look at the browser tab") { _ in self.output("Current tab:") },
            tool("browser.open", "Open the page") { _ in self.output("Opened it.") },
            tool("browser.click", "Click the button") { _ in
                if self.clickChangesPage { self.change("page-after-click") }
                return self.output("Clicked.")
            },
            tool("browser.type", "Type into the field") { _ in self.output("Typed.") },
            tool("browser.press", "Press keys") { _ in self.output("Pressed.") },
            tool("browser.scroll", "Scroll down in the browser tab") { _ in self.output("Scrolled down.\nNothing scrolled — already at the bottom.") },
            tool("browser.read", "Read the browser tab's text") { _ in ToolOutput(ok: true, text: "Product page text") },
            tool("browser.find", "Find it on the page") { _ in
                if self.findScrolls { self.change("page-scrolled-to-match") }
                return self.output("Found it.")
            },
        ]
    }
}

func browserStep(_ title: String = "Adding to cart") -> RecipeStep {
    RecipeStep(id: 1, title: title, instruction: "Add the shoes to the cart", route: .browser, doneWhen: "the cart shows the shoes")
}

func look() -> JSONValue { toolReply(calls: [("browser.snapshot", [:])]) }
func clickBuy() -> JSONValue { toolReply(calls: [("browser.click", ["ref": "b1"])]) }

// MARK: - Loop breaker

@Suite("ToolStepRunner loop breaker")
struct LoopBreakerTests {
    @Test func nudgesAfterTwoIdleTurnsThenStallsAfterThree() async throws {
        let page = FakePage()
        let llm = ScriptedLLM(respond: { _, _ in look() })
        let result = try await makeRunner(page.tools(), llm: llm).execute(request(browserStep(), maxTurns: 14), callbacks: CallbackRecorder().callbacks)
        guard case .stalled(let reason) = result.status else { Issue.record("expected a stall, got \(result.status)"); return }
        #expect(reason == "No progress in 3 turns in a row: it only looked at the page 3 times, and the page didn't change.")
        #expect(llm.requests.count == 4, "one look that learns the page, then three that don't — far under the 14 turns")
        let prompts = llm.userMessages
        #expect(!prompts[2].contains("Warning:"))
        #expect(prompts[3].contains("Warning: the last 2 turns only looked at the page twice, and nothing on the page changed."))
        #expect(prompts[3].contains("Call browser.find with the visible label"), "browser.find is listed, so the warning points at it")
        #expect(result.output.contains("What it tried: Look at the browser tab ×4"))
        #expect(result.actions == 4)

        // Without browser.find the warning says to act on a ref instead.
        let noFind = page.tools().filter { $0.spec.name != "browser.find" }
        let llm2 = ScriptedLLM(respond: { _, _ in look() })
        _ = try await makeRunner(noFind, llm: llm2).execute(request(browserStep()), callbacks: CallbackRecorder().callbacks)
        #expect(llm2.userMessages[3].contains("Act on a ref you already have, or try another way.") && !llm2.userMessages[3].contains("browser.find"))
    }

    @Test func progressResetsTheCount() async throws {
        let page = FakePage()
        let script = [look(), look(), look(), clickBuy(), look(), look(), toolReply("step_done", message: "In the cart")]
        let llm = ScriptedLLM(script)
        let result = try await makeRunner(page.tools(), llm: llm).execute(request(browserStep()), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .done)
        let prompts = llm.userMessages
        #expect(prompts.count == 7)
        #expect(prompts[3].contains("Warning:"), "two idle turns")
        #expect(!prompts[4].contains("Warning:"), "the click changed the page, so the count started over")
        #expect(!prompts[5].contains("Warning:"))
        #expect(prompts[6].contains("Warning:"))
    }

    @Test func emptyScrollsAndRepeatedNoOpActionsCount() async throws {
        let page = FakePage()
        page.clickChangesPage = false
        let scroll = toolReply(calls: [("browser.scroll", ["direction": "down"])])
        let llm = ScriptedLLM([look(), scroll, clickBuy(), clickBuy(), clickBuy(), clickBuy(), toolReply("step_done")])
        let tools = page.tools()
        let result = try await makeRunner(tools, llm: llm).execute(request(browserStep()), callbacks: CallbackRecorder().callbacks)
        guard case .stalled(let reason) = result.status else { Issue.record("expected a stall, got \(result.status)"); return }
        // The first click that changed nothing gets the benefit of the doubt (it reset the
        // empty scroll's count); the same click again doesn't.
        #expect(reason.contains("repeated the same click without any change 3 times"))
        #expect(tools.first { $0.spec.name == "browser.click" }?.calls.count == 4)
        #expect(llm.requests.count == 6)
    }

    @Test func lookingForSomethingNewIsProgress() async throws {
        let page = FakePage()
        let reads: [JSONValue] = ["#price", "#reviews", "#shipping"].map { toolReply(calls: [("browser.read", ["selector": .string($0)])]) }
        let find = toolReply(calls: [("browser.find", ["text": "Cabin"])])
        let llm = ScriptedLLM([look()] + reads + [look(), look(), find, look(), toolReply("step_done", message: "Found it")])
        let result = try await makeRunner(page.tools(), llm: llm).execute(request(browserStep()), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .done, "different reads and a find that scrolls are progress")
        #expect(llm.userMessages[6].contains("Warning:"), "but two looks at the same page are not")
        #expect(!llm.userMessages[7].contains("Warning:"), "the find scrolled the page")
    }

    @Test func otherToolsNeverStall() async throws {
        let shell = FakeTool("shell.run")
        let llm = ScriptedLLM(respond: { _, _ in toolReply(calls: [("shell.run", ["command": "ls"])]) })
        let result = try await makeRunner([shell], llm: llm).execute(request(maxTurns: 5), callbacks: CallbackRecorder().callbacks)
        guard case .failed(let reason) = result.status else { Issue.record("expected the turn limit, got \(result.status)"); return }
        #expect(ToolStepRunner.isTurnLimit(reason))
        #expect(shell.calls.count == 5)
    }

    @Test func aBotCheckEndsTheStepAndAsksForTheUser() async throws {
        let page = FakePage()
        page.url = "https://www.amazon.com/dp/B088NRLMPV"
        page.botCheck = true
        let tools = page.tools()
        let llm = ScriptedLLM([toolReply(calls: [("browser.open", ["url": .string(page.url)]), ("browser.snapshot", [:])])])
        let result = try await makeRunner(tools, llm: llm).execute(request(browserStep()), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .blocked("www.amazon.com wants to check that you're a person. Please complete the check in Chrome, then run the task again."))
        #expect(tools.first { $0.spec.name == "browser.snapshot" }?.calls.isEmpty == true, "nothing else runs on the page")
        #expect(llm.requests.count == 1)
    }

    @Test func fingerprintsComeFromTheToolsOrThePage() {
        let given = ToolOutput(ok: true, text: "x", data: ["fingerprint": "abc", "url": "https://a.test"])
        #expect(ProgressWatch.fingerprint(of: given) == "abc")
        // Without one: the address and the elements' roles and names, not their refs.
        let a = ToolOutput(ok: true, text: "Clicked.", data: ["url": "https://a.test", "elements": [["ref": "b1", "role": "button", "name": "Buy"]]])
        let b = ToolOutput(ok: true, text: "Current tab:", data: ["url": "https://a.test", "elements": [["ref": "b7", "role": "button", "name": "Buy"]]])
        let c = ToolOutput(ok: true, text: "x", data: ["url": "https://a.test", "elements": [["ref": "b1", "role": "button", "name": "Sold out"]]])
        #expect(ProgressWatch.fingerprint(of: a) == ProgressWatch.fingerprint(of: b))
        #expect(ProgressWatch.fingerprint(of: a) != ProgressWatch.fingerprint(of: c))
        // Text only: the page part after the lead.
        let t1 = ToolOutput(ok: true, text: "Clicked b1.\nSame page.\n\npage: Shop\nb1 button \"Buy\"")
        let t2 = ToolOutput(ok: true, text: "Current tab (T1):\n\npage: Shop\nb1 button \"Buy\"")
        #expect(ProgressWatch.fingerprint(of: t1) == ProgressWatch.fingerprint(of: t2))
        #expect(ProgressWatch.fingerprint(of: ToolOutput(ok: false, text: "Browser error")) == nil)
    }
}

// MARK: - Side effects

@Suite("Side effects for retries")
struct SideEffectTests {
    @Test func theToolLoopRecordsWhatChangedThings() async throws {
        let page = FakePage()
        let llm = ScriptedLLM([
            toolReply(calls: [("browser.open", ["url": "https://shop.test/product/1"]), ("browser.click", ["ref": "b1"])]),
            toolReply(calls: [("browser.type", ["ref": "b2", "text": "SAVE10", "submit": true]), ("browser.press", ["keys": "Escape"]),
                              ("browser.press", ["keys": "Enter"]), ("browser.scroll", ["direction": "down"]), ("browser.snapshot", [:])]),
            toolReply("step_done", message: "Applied the code"),
        ])
        var runner = makeRunner(page.tools(), llm: llm)
        let session = TaskSession(limits: LimitSettings())
        runner.session = session
        let result = try await runner.execute(request(browserStep()), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .done)
        let expected = [
            "Opened https://shop.test/product/1",
            "Clicked “ADD TO CART - $100” on shop.test",
            "Typed “SAVE10” into “Discount code” on shop.test and pressed Return",
            "Pressed Enter on shop.test",
        ]
        #expect(result.sideEffects == expected)
        #expect(session.sideEffects == expected, "a quick task's session has them as they happen")
    }

    @Test func otherToolsCountWhenTheyChangeSomething() {
        func spec(_ name: String, _ category: ToolCategory, readOnly: Bool = false) -> ToolSpec {
            ToolSpec(name: name, summary: "", inputSchema: Schema.object([]), category: category, readOnly: readOnly)
        }
        let write = ToolVerdict(risk: .medium, summary: "Write ~/notes.txt")
        #expect(ToolStepRunner.sideEffect(tool: spec("fs.write", .files), arguments: [:], verdict: write, pageURL: nil) == "Write ~/notes.txt")
        #expect(ToolStepRunner.sideEffect(tool: spec("shell.run", .command), arguments: [:], verdict: ToolVerdict(risk: .low, summary: "Run `ls`"), pageURL: nil) == nil)
        #expect(ToolStepRunner.sideEffect(tool: spec("fs.read", .files, readOnly: true), arguments: [:], verdict: write, pageURL: nil) == nil)
        #expect(ToolStepRunner.sideEffect(tool: spec("workspace.set_fact", .workspace), arguments: [:], verdict: write, pageURL: nil) == nil)
        #expect(ToolStepRunner.sideEffect(tool: spec("browser.switch_tab", .browser), arguments: [:], verdict: write, pageURL: nil) == nil)
    }

    @Test func onScreenActionsCountToo() throws {
        #expect(GUIStepRunner.sideEffect(.click(.element("e1")), label: "Add to Cart", app: "Google Chrome") == "Clicked “Add to Cart” in Google Chrome")
        #expect(GUIStepRunner.sideEffect(.typeText("SAVE10", into: nil, clearFirst: false, submit: true), label: "Code", app: nil)
                == "Typed “SAVE10” into “Code” and pressed Return")
        #expect(GUIStepRunner.sideEffect(.keyPress(try KeyCombination(parsing: "return")), label: nil, app: nil) != nil)
        #expect(GUIStepRunner.sideEffect(.keyPress(try KeyCombination(parsing: "cmd+s")), label: nil, app: nil) != nil)
        #expect(GUIStepRunner.sideEffect(.keyPress(try KeyCombination(parsing: "cmd+c")), label: nil, app: nil) == nil)
        #expect(GUIStepRunner.sideEffect(.keyPress(try KeyCombination(parsing: "tab")), label: nil, app: nil) == nil)
        #expect(GUIStepRunner.sideEffect(.scroll(.down, amount: 3, at: nil), label: nil, app: nil) == nil)
    }

    @Test func retryNotesSayWhatTookEffectAndToCheck() throws {
        #expect(RetryNotes.render([]) == nil)
        let text = try #require(RetryNotes.render(["Clicked “ADD TO CART - $100” on www.allbirds.com"], page: "“Cart” https://www.allbirds.com/cart"))
        #expect(text.hasPrefix("Already done earlier in this task (these took effect):\n- Clicked “ADD TO CART - $100” on www.allbirds.com"))
        #expect(text.contains("Check the current state first") && text.contains("don't repeat these unless it shows they didn't happen"))
        #expect(text.contains("Current page:\n“Cart” https://www.allbirds.com/cart"))
        let many = try #require(RetryNotes.render((1...20).map { "Clicked \($0)" }))
        #expect(many.contains("- … 8 earlier actions") && many.contains("Clicked 20") && !many.contains("Clicked 8\n"))
    }

    @Test func theRecoveryPlannerHearsWhatAlreadyHappened() throws {
        let step = PlanStep(id: 2, title: "Applying the code", instruction: "Apply SAVE10", route: .browser, app: nil, risk: .low, doneWhen: "applied", hint: nil)
        let message = AgentPlanner.recoveryMessage("Buy shoes with SAVE10", plan: Plan(goal: "Buy shoes", steps: [step], clarification: nil), completed: [],
                                                   failedStep: step, failure: "No progress", notes: String(repeating: "n", count: 9000), screen: "(none)",
                                                   context: PlanningContext(), alreadyDone: ["Clicked “ADD TO CART - $100” on www.allbirds.com"],
                                                   page: "Current tab:\npage: \"Cart\" https://www.allbirds.com/cart")
        let done = try #require(message.range(of: "Already done earlier in this task (these took effect):"))
        let notes = try #require(message.range(of: "Notes gathered so far:"))
        #expect(done.lowerBound < notes.lowerBound, "it comes before the long notes")
        #expect(message.contains("Clicked “ADD TO CART - $100” on www.allbirds.com"))
        #expect(message.contains("Current browser page:\nCurrent tab:\npage: \"Cart\" https://www.allbirds.com/cart"))
    }
}

// MARK: - Prompts

@Suite("Search URL and retry guidance")
struct GuidancePromptTests {
    @Test func plannerToolAndRecoveryPromptsSayToUseSearchURLs() async throws {
        for prompt in [Prompts.planner, Prompts.toolStep, Prompts.recovery] {
            #expect(prompt.contains("open that URL directly instead of filling search boxes, autocomplete fields and date pickers"))
            #expect(prompt.contains("https://www.amazon.com/s?k="))
            #expect(prompt.contains("https://www.airbnb.com/s/Leavenworth--WA/homes?checkin=2026-12-12&checkout=2026-12-14&adults=2"))
            #expect(prompt.contains("https://www.google.com/travel/flights?q=Flights%20from%20SEA%20to%20SFO"))
            #expect(prompt.contains("check that the results page shows those parameters"))
        }
        #expect(Prompts.toolStep.contains("call browser.find with its visible label"))
        for prompt in [Prompts.toolStep, Prompts.recovery] {
            #expect(prompt.contains("Actions listed as already done took effect. Check the current state first"))
        }
        // The tool loop sends it.
        let llm = ScriptedLLM([toolReply("step_done")])
        _ = try await makeRunner(FakePage().tools(), llm: llm).execute(request(browserStep()), callbacks: CallbackRecorder().callbacks)
        #expect(llm.requests.first?.system == Prompts.toolStep)
    }
}

// MARK: - On-screen switch

@Suite("Browser steps moving on screen", .serialized)
struct OnScreenSwitchTests {
    @Test func onlyStuckBrowserStepsSwitch() {
        let s = AppSettings()
        #expect(OnScreenSwitch.applies(route: .browser, status: .stalled("No progress"), settings: s))
        #expect(OnScreenSwitch.applies(route: .browser, status: .failed("Reached the limit of 14 turns without finishing “x”."), settings: s))
        #expect(!OnScreenSwitch.applies(route: .browser, status: .failed("Too many errors in this step."), settings: s))
        #expect(!OnScreenSwitch.applies(route: .browser, status: .blocked("Log in first"), settings: s))
        #expect(!OnScreenSwitch.applies(route: .browser, status: .done, settings: s))
        #expect(!OnScreenSwitch.applies(route: .command, status: .stalled("No progress"), settings: s))
        var off = s
        off.browser.onScreenFallback = false
        #expect(!OnScreenSwitch.applies(route: .browser, status: .stalled("No progress"), settings: off))
        let screen = OnScreenSwitch.screenStep(browserStep(), briefing: "Brief")
        #expect(screen.route == .gui && screen.app == nil && screen.instruction == "Add the shoes to the cart\n\nBrief")
    }

    @Test func browserSettingsDecodeTolerantly() throws {
        let old = #"{"backend":"glideChrome","bridgePort":47900,"useBackgroundTabs":false,"fallbackToGlideChrome":false}"#
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: Data(old.utf8))
        #expect(decoded.backend == .glideChrome && decoded.bridgePort == 47900 && !decoded.useBackgroundTabs && !decoded.fallbackToGlideChrome)
        #expect(decoded.onScreenFallback, "settings saved before the option keep the default")
        var off = BrowserSettings()
        off.onScreenFallback = false
        off.chromePath = "/Applications/Chromium.app"
        #expect(try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(off)) == off)
        let app = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"browser":{"backend":"glideChrome","onScreenFallback":"yes"}}"#.utf8))
        #expect(app.browser.backend == .glideChrome && app.browser.onScreenFallback, "an unreadable value keeps the default and the rest")
    }

    // Quick tasks

    /// An orchestrator on a scripted model, with fake browser tools and a fake on-screen runner.
    final class Harness: @unchecked Sendable {
        let store: LocalStore
        let path: String
        let recorder = CallbackRecorder()
        let screenSteps = Mutex<[PlanStep]>([])
        let brought = Ledger()

        init() throws {
            path = FileManager.default.temporaryDirectory.appendingPathComponent("glide-onscreen-\(UUID().uuidString).sqlite").path
            store = try LocalStore(path: path)
        }

        deinit { try? FileManager.default.removeItem(atPath: path) }

        func orchestrator(settings: AppSettings = AppSettings(), tools: [any AgentTool], llm: ScriptedLLM,
                          onScreen: StepResult = StepResult(status: .done, output: "Added on screen")) -> ExecutionOrchestrator {
            var s = settings
            s.safety.pauseOnUserInput = false
            s.keepHistory = true
            let creds = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
            creds.useMemoryOnly()
            let o = ExecutionOrchestrator(instruction: "Add the shoes to the cart and apply SAVE10", settings: s, runtime: AutomationRuntime(),
                                          callbacks: recorder.callbacks, store: store, credentials: creds, tools: ToolRegistry(tools))
            o.screenContext = false
            o.testModel = (llm, "scripted")
            o.screenAvailable = { true }
            o.bringBrowserForward = { [self] key in brought.add(key) }
            o.onScreenRunner = { [self] step in
                screenSteps.withLock { $0.append(step) }
                return onScreen
            }
            return o
        }

        var screenRuns: [PlanStep] { screenSteps.withLock { $0 } }
    }

    static let plan = Plan(goal: "Buy shoes", steps: [PlanStep(id: 1, title: "Adding to cart", instruction: "Add the shoes to the cart", route: .browser,
                                                               app: nil, risk: .low, doneWhen: "the cart shows the shoes", hint: nil)],
                           clarification: nil)

    @Test func aStalledBrowserStepRunsOnceOnScreenWithWhatHappened() async throws {
        let h = try Harness()
        let page = FakePage()
        // Look, add to the cart (that works), then keep looking.
        let llm = ScriptedLLM(respond: { _, i in i == 1 ? clickBuy() : look() })
        let result = await h.orchestrator(tools: page.tools(), llm: llm).run(plan: Self.plan)
        #expect(result.status == .completed, "\(result.summary) \(result.error ?? "")")
        let runs = h.screenRuns
        #expect(runs.count == 1)
        let screen = try #require(runs.first)
        #expect(screen.route == .gui && screen.id == 1 && screen.doneWhen == "the cart shows the shoes" && screen.app == nil)
        #expect(screen.instruction.hasPrefix("Add the shoes to the cart\n\nThis step was first tried in the page's structure in the background and got stuck: No progress in 3 turns"))
        #expect(screen.instruction.contains("What it tried: Look at the browser tab; Click the button; Look at the browser tab ×3"))
        #expect(screen.instruction.contains("Already done earlier in this task (these took effect):\n- Clicked “ADD TO CART - $100” on shop.test"))
        #expect(h.brought.all == ["default"], "the task's tab comes to the front first")
        let switching = h.recorder.logs.filter { $0.title == OnScreenSwitch.title }
        #expect(switching.count == 1 && switching.first?.route == .gui)
        #expect(llm.requests.allSatisfy { $0.system == Prompts.toolStep }, "no replanning was needed")
        #expect(result.summary == "Done: Buy shoes", "what the stuck step tried isn't a note, so it never becomes the answer")
        #expect(ToolStepRunner.facts(in: "Price is $9\nWhat it tried: Look ×4") == "Price is $9")
    }

    @Test func turnedOffOrWithoutTheScreenItReplansAsBefore() async throws {
        for variant in ["setting off", "no Accessibility"] {
            let h = try Harness()
            var settings = AppSettings()
            settings.limits.maxReplans = 0
            if variant == "setting off" { settings.browser.onScreenFallback = false }
            let llm = ScriptedLLM(respond: { _, _ in look() })
            let o = h.orchestrator(settings: settings, tools: FakePage().tools(), llm: llm)
            if variant == "no Accessibility" { o.screenAvailable = { false } }
            let result = await o.run(plan: Self.plan)
            #expect(result.status == .failed, "\(variant)")
            #expect(result.error?.hasPrefix("No progress in 3 turns") == true, "\(variant): \(result.error ?? "")")
            #expect(h.screenRuns.isEmpty && h.brought.all.isEmpty, "\(variant)")
            #expect(!h.recorder.logs.contains { $0.title == OnScreenSwitch.title }, "\(variant)")
        }
    }

    @Test func aFailedOnScreenTryGoesOnToReplanning() async throws {
        let h = try Harness()
        var settings = AppSettings()
        settings.limits.maxReplans = 0
        let llm = ScriptedLLM(respond: { _, _ in look() })
        let result = await h.orchestrator(settings: settings, tools: FakePage().tools(), llm: llm,
                                          onScreen: StepResult(status: .failed("The last 4 actions had no visible effect."))).run(plan: Self.plan)
        #expect(result.status == .failed)
        #expect(h.screenRuns.count == 1)
        #expect(result.error?.contains("No progress in 3 turns") == true && result.error?.contains("On screen: The last 4 actions had no visible effect.") == true)
    }

    /// The coupon run: the shoes went into the cart, the step got lost, and the retry added
    /// them again. Now the recovery planner and the retried step both hear about the click.
    @Test func aRetriedStepIsToldWhatAlreadyTookEffect() async throws {
        let h = try Harness()
        var settings = AppSettings()
        settings.browser.onScreenFallback = false
        let page = FakePage()
        let revised: JSONValue = [
            "goal": "Buy shoes", "mode": "quick", "clarification": .null,
            "steps": [[
                "title": "Checking the cart", "instruction": "Open the cart and apply SAVE10", "route": "browser", "app": .null, "risk": "low",
                "done_when": "the code is applied", "hint_action": "none", "hint_target": .null, "hint_text": .null,
            ]],
        ]
        let llm = ScriptedLLM(respond: { req, i in
            if req.system == Prompts.recovery { return revised }
            if req.messages.last?.text.contains("STEP 1: Checking the cart") == true { return toolReply("step_done", message: "One pair in the cart; SAVE10 applied") }
            return i == 1 ? clickBuy() : look()
        })
        let result = await h.orchestrator(settings: settings, tools: page.tools(), llm: llm).run(plan: Self.plan)
        #expect(result.status == .completed, "\(result.summary) \(result.error ?? "")")
        let recovery = try #require(llm.requests.first { $0.system == Prompts.recovery }?.messages.last?.text)
        #expect(recovery.contains("Already done earlier in this task (these took effect):\n- Clicked “ADD TO CART - $100” on shop.test"))
        #expect(recovery.contains("Current browser page:\nCurrent tab:"), "a fresh snapshot of the page")
        let retried = try #require(llm.requests.first { $0.system == Prompts.toolStep && $0.messages.last?.text.contains("STEP 1: Checking the cart") == true })
        let prompt = retried.messages.last?.text ?? ""
        #expect(prompt.contains("Already done earlier in this task (these took effect):\n- Clicked “ADD TO CART - $100” on shop.test"))
        #expect(prompt.contains("don't repeat these unless it shows they didn't happen"))
        // Before the retry nothing had failed, so the first step wasn't told anything.
        let firstPrompt = llm.requests.first?.messages.last?.text ?? ""
        #expect(!firstPrompt.contains("Already done"))
    }

    // Jobs

    func stuckBrowser(_ status: StepResult.Status) -> StepResult {
        StepResult(status: status, output: "What it tried: Look at the browser tab ×4", sideEffects: ["Clicked “Add to cart” on shop.test"])
    }

    func jobRun(_ settings: AppSettings, stuck: StepResult.Status = .stalled("No progress in 3 turns in a row"),
                onScreen: StepResult = StepResult(status: .done, output: "Added on screen")) async throws
        -> (final: JobRecord, requests: [StepRequest], brought: [String], logs: [ActivityEntry], jobID: String) {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Adding to cart", route: .browser)])])
        let seen = Mutex<[StepRequest]>([])
        let executor = CallbackExecutor { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            seen.withLock { $0.append(req) }
            return req.step.route == .browser ? self.stuckBrowser(stuck) : onScreen
        }
        let brought = Mutex<[String]>([])
        let logs = Mutex<[ActivityEntry]>([])
        let config = JobRunner.Configuration(bringBrowserForward: { key in brought.withLock { $0.append(key) } }, screenAvailable: { true })
        let record = fx.record(plan)
        let final = await fx.runner(record, executor, settings: settings, callbacks: JobRunner.Callbacks(log: { e in logs.withLock { $0.append(e) } }),
                                    configuration: config).run()
        return (final, seen.withLock { $0 }, brought.withLock { $0 }, logs.withLock { $0 }, record.id)
    }

    @Test(arguments: ["stalled", "turn limit"])
    func aStuckJobStepRunsOnceOnScreenThroughTheLease(_ how: String) async throws {
        let stuck: StepResult.Status = how == "stalled" ? .stalled("No progress in 3 turns in a row") : .failed("Reached the limit of 14 turns without finishing “Adding to cart”.")
        let run = try await jobRun(testSettings(), stuck: stuck)
        #expect(run.final.status == .completed)
        #expect(run.requests.map(\.step.route) == [.browser, .gui])
        let screen = try #require(run.requests.last)
        #expect(screen.allowedCategories == ExecutionRoute.gui.toolCategories && screen.jobID == run.jobID && screen.step.app == nil)
        #expect(screen.step.instruction.contains("got stuck: " + OnScreenSwitch.reason(stuck)))
        #expect(screen.step.instruction.contains("Already done earlier in this step (these took effect):\n- Clicked “Add to cart” on shop.test"))
        #expect(run.brought == ["job:\(run.jobID)"])
        #expect(run.logs.contains { $0.title == OnScreenSwitch.title })
    }

    @Test(arguments: ["never", "setting off"])
    func aJobThatMayNotUseTheScreenKeepsTheOldBehavior(_ variant: String) async throws {
        var settings = testSettings()
        if variant == "never" { settings.jobs.screenUse = .never } else { settings.browser.onScreenFallback = false }
        let run = try await jobRun(settings)
        #expect(run.final.status == .failed)
        #expect(run.requests.map(\.step.route) == [.browser, .browser], "two tries, both in the browser")
        #expect(run.brought.isEmpty && !run.logs.contains { $0.title == OnScreenSwitch.title })
        // The second try is told what the first one changed.
        let retry = try #require(run.requests.last)
        #expect(retry.context.hasPrefix("Already done in an earlier try at this step (these took effect):\n- Clicked “Add to cart” on shop.test"))
    }

    @Test func aJobStepGetsOneOnScreenTryNotOnePerAttempt() async throws {
        let run = try await jobRun(testSettings(), onScreen: StepResult(status: .failed("The last 4 actions had no visible effect.")))
        #expect(run.final.status == .failed)
        #expect(run.requests.map(\.step.route) == [.browser, .gui, .browser], "the retry goes back to the browser and stays there")
        #expect(run.final.lastError?.contains("On screen: The last 4 actions had no visible effect.") == false, "the last try was the browser one")
        #expect(run.logs.filter { $0.title == OnScreenSwitch.title }.count == 1)

        // Items too, across their attempts (which can be a relaunch apart).
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let recipe = [RecipeStep(id: 1, title: "Buying", instruction: "Add the shoes", route: .browser, outputFields: ["answer"])]
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [listLoop(["Tree Runners"], recipe: recipe)])])
        let routes = Mutex<[ExecutionRoute]>([])
        let executor = CallbackExecutor { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            routes.withLock { $0.append(req.step.route) }
            return req.step.route == .browser ? self.stuckBrowser(.stalled("No progress")) : StepResult(status: .failed("Nothing happened on screen"))
        }
        let record = fx.record(plan)
        _ = await fx.runner(record, executor, configuration: JobRunner.Configuration(bringBrowserForward: { _ in }, screenAvailable: { true })).run()
        #expect(routes.withLock { $0 } == [.browser, .gui, .browser])
        let item = try #require(fx.store.items(jobID: record.id, stepID: 1, status: .failed).first)
        #expect(fx.store.state(jobID: record.id, key: "onScreen:\(item.id)") == "1")
    }

    @Test func aRetriedJobItemIsToldWhatItsEarlierTryChanged() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let recipe = [RecipeStep(id: 1, title: "Buying", instruction: "Add the shoes and apply SAVE10", route: .browser, outputFields: ["answer"])]
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [listLoop(["Tree Runners"], recipe: recipe)])])
        let contexts = Mutex<[String]>([])
        let executor = CallbackExecutor { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            let n = contexts.withLock { $0.append(req.context); return $0.count }
            if n == 1 {
                return StepResult(status: .failed("Couldn't find the discount field"), sideEffects: ["Clicked “ADD TO CART - $100” on www.allbirds.com"])
            }
            return StepResult(status: .done, fields: ["answer": "applied"])
        }
        let record = fx.record(plan)
        let final = await fx.runner(record, executor, configuration: JobRunner.Configuration(bringBrowserForward: { _ in }, screenAvailable: { true })).run()
        #expect(final.status == .completed)
        let seen = contexts.withLock { $0 }
        #expect(seen.count == 2)
        #expect(!seen[0].contains("Already done"))
        #expect(seen[1].hasPrefix("Already done in an earlier try at this item (these took effect):\n- Clicked “ADD TO CART - $100” on www.allbirds.com"))
        let item = try #require(fx.store.items(jobID: record.id, stepID: 1, status: .done).first)
        #expect(fx.store.state(jobID: record.id, key: "sideEffects:\(item.id)") == nil, "a finished item forgets them")
    }
}
