import Testing
import Foundation
import Synchronization
@testable import AgentKit
@testable import AutomationKit

// The conversation layer offline: a scripted model, fake tools and a fake instant handler.
// No UI, no input, no network beyond nothing at all.

// MARK: - Helpers

func questionJSON(_ id: String, _ text: String, options: [String] = [], default fallback: String? = nil, lowRisk: Bool = false) -> JSONValue {
    .object([
        "id": .string(id), "text": .string(text), "spoken": .null, "options": .array(options.map { .string($0) }),
        "default": fallback.map { .string($0) } ?? .null, "low_risk": .bool(lowRisk),
    ])
}

func planStepJSON(_ title: String, _ instruction: String, route: String = "command", risk: String = "low", needs: [String] = []) -> JSONValue {
    .object([
        "title": .string(title), "instruction": .string(instruction), "route": .string(route), "app": .null, "risk": .string(risk),
        "done_when": .string("\(instruction) is done"), "hint_action": .string("none"), "hint_target": .null, "hint_text": .null,
        "needs": .array(needs.map { .string($0) }),
    ])
}

func planJSON(ack: String? = "On it.", questions: [JSONValue] = [], steps: [JSONValue], clarification: String? = nil) -> JSONValue {
    .object([
        "goal": .string("Test goal"), "ack": ack.map { .string($0) } ?? .null, "mode": .string("quick"),
        "clarification": clarification.map { .string($0) } ?? .null, "questions": .array(questions), "steps": .array(steps),
    ])
}

func spokenDone(_ message: String, spoken: String) -> JSONValue {
    guard case .object(var o) = toolReply("task_done", message: message) else { return .null }
    o["spoken"] = .string(spoken)
    return .object(o)
}

/// Counts turns per key, so a scripted model can answer each step in order.
final class TurnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func next(_ key: String) -> Int { lock.withLock { defer { counts[key, default: 0] += 1 }; return counts[key, default: 0] } }
}

/// A scripted model for whole tasks: the plan, then each step's turns from `steps[step][turn]`.
func taskModel(plan: JSONValue, steps: [Int: [JSONValue]], fallback: JSONValue = toolReply("step_done", message: "done")) -> ScriptedLLM {
    let counter = TurnCounter()
    return ScriptedLLM(respond: { request, _ in
        if request.schemaName == "plan" { return plan }
        let text = request.messages.last?.text ?? ""
        for (id, replies) in steps where text.contains("STEP \(id):") {
            let turn = counter.next("\(id)")
            return turn < replies.count ? replies[turn] : fallback
        }
        return fallback
    })
}

/// A controller on a scripted model with fake tools, throwaway settings and history.
@MainActor
final class ConversationFixture {
    let suite = "dev.glide.tests.\(UUID().uuidString)"
    let runtime = AutomationRuntime()
    let lease = ScreenLease(idleProbe: { 1000 })
    let store: SettingsStore
    let controller: TaskController
    let historyPath: String
    let history: LocalStore
    var cues: [SpeechCue] = []
    var llm: ScriptedLLM

    init(llm: ScriptedLLM, tools: [any AgentTool] = [], defaultAfter: Double = 30, followUpMinutes: Double = 5,
         instant: (@Sendable (String) async -> InstantResult?)? = nil) throws {
        self.llm = llm
        store = SettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        var s = AppSettings()
        s.providers = [ProviderConfig(id: "mock", kind: .openaiCompatible, name: "Mock", baseURL: "http://127.0.0.1:9", requiresKey: false, models: ["mock"])]
        s.routing.preferredProviderID = "mock"
        s.composio.enabled = false
        s.safety.pauseOnUserInput = false
        s.keepHistory = true
        s.conversation.defaultAfterSeconds = defaultAfter
        s.conversation.followUpWindowMinutes = followUpMinutes
        store.settings = s
        historyPath = FileManager.default.temporaryDirectory.appendingPathComponent("glide-conv-\(UUID().uuidString).sqlite").path
        let history = try LocalStore(path: historyPath)
        self.history = history
        let credentials = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        credentials.useMemoryOnly()
        controller = TaskController(runtime: runtime, settingsStore: store, screenLease: lease, credentials: credentials)
        controller.backgroundJobsEnabled = false
        // Command steps need a command tool to be available at all.
        controller.toolsOverride = ToolRegistry(tools + [FakeTool("shell.idle")])
        controller.historyStore = { history }
        controller.instantHandler = { instant }
        controller.configureOrchestrator = { [unowned self] o in
            o.screenContext = false
            o.testModel = (self.llm, "scripted")
            o.screenAvailable = { true }
            o.progressAfter = 0
        }
        controller.onSpeech = { [unowned self] cue in self.cues.append(cue) }
    }

    func say(_ text: String, _ source: UtteranceSource = .voice) { controller.handleUtterance(text, source: source) }

    func finished() async -> Bool { await eventuallyOnMain { !self.controller.isBusy && self.controller.lastResult != nil } }

    var questionCues: [String] { cues.compactMap { if case .question(let q) = $0 { return q.text } else { return nil } } }

    func cleanUp() async {
        controller.stop()
        _ = await eventuallyOnMain { !self.controller.isBusy }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: historyPath)
    }
}

// MARK: - Reading utterances

@Suite("Reading what the user says")
struct UtteranceInterpreterTests {
    @Test func controlWordsOnlyCountAlone() {
        #expect(UtteranceInterpreter.control("Stop!") == .stop)
        #expect(UtteranceInterpreter.control("okay, cancel that") == .stop)
        #expect(UtteranceInterpreter.control("never mind") == .stop)
        #expect(UtteranceInterpreter.control("wait") == .pause)
        #expect(UtteranceInterpreter.control("Pause please") == .pause)
        #expect(UtteranceInterpreter.control("go on") == .resume)
        #expect(UtteranceInterpreter.control("continue") == .resume)
        #expect(UtteranceInterpreter.control("stop the music in Spotify") == nil)
        #expect(UtteranceInterpreter.control("wait for the page to load") == nil)
    }

    @Test func yesAndNo() {
        for yes in ["yes", "Yeah.", "sure", "go ahead", "do it", "yes please", "yeah, go ahead"] { #expect(UtteranceInterpreter.yesNo(yes) == true, "\(yes)") }
        for no in ["no", "nope", "don't", "cancel", "no, use the other card", "no thanks"] { #expect(UtteranceInterpreter.yesNo(no) == false, "\(no)") }
        #expect(UtteranceInterpreter.yesNo("the blue ones") == nil)
        #expect(UtteranceInterpreter.yesNo("right after lunch") == nil)
    }

    @Test func optionsMatchLoosely() {
        let options = ["Athletic crew", "No-show", "Wool"]
        #expect(UtteranceInterpreter.matchOption("wool", options: options) == "Wool")
        #expect(UtteranceInterpreter.matchOption("the wool ones", options: options) == "Wool")
        #expect(UtteranceInterpreter.matchOption("no show", options: options) == "No-show")
        #expect(UtteranceInterpreter.matchOption("the second one", options: options) == "No-show")
        #expect(UtteranceInterpreter.matchOption("the last one", options: options) == "Wool")
        #expect(UtteranceInterpreter.matchOption("athletic", options: options) == "Athletic crew")
        #expect(UtteranceInterpreter.matchOption("cotton", options: options) == nil)
    }

    @Test func whatCountsAsAnAnswer() {
        let q = AgentQuestion(id: "q1", text: "Which socks?", options: ["Athletic crew", "No-show", "Wool"])
        #expect(UtteranceInterpreter.answer("wool", to: q, source: .voice) == "Wool")
        #expect(UtteranceInterpreter.answer("the wool ones in size 10", to: q, source: .voice) == "the wool ones in size 10")
        #expect(UtteranceInterpreter.answer("cotton ones", to: q, source: .voice) == "cotton ones", "short replies answer it")
        #expect(UtteranceInterpreter.answer("open Spotify and play some jazz", to: q, source: .voice) == nil, "a new request isn't an answer")
        #expect(UtteranceInterpreter.answer("Anything", to: q, source: .option) == "Anything")
        let approval = AgentQuestion(text: "Okay to click Buy?", options: ["Yes", "No"], isApproval: true)
        #expect(UtteranceInterpreter.answer("yeah do it", to: approval, source: .voice) == "Yes")
        #expect(UtteranceInterpreter.answer("nope", to: approval, source: .voice) == "No")
        #expect(UtteranceInterpreter.answer("the blue ones", to: approval, source: .voice) == nil, "an approval takes only yes or no")
        // Replies to an open question count however they're phrased.
        let who = AgentQuestion(text: "Who should the email go to, and what should it say?")
        #expect(UtteranceInterpreter.answer("send it to Sneh and say hi, how is the job search going", to: who, source: .voice)
                == "send it to Sneh and say hi, how is the job search going")
        #expect(UtteranceInterpreter.answer("write to sneh shah saying hello from glide", to: who, source: .voice) != nil)
        #expect(UtteranceInterpreter.answer("open Spotify", to: who, source: .voice) == nil)
    }

    @Test func spokenSummariesAreShort() {
        #expect(UtteranceInterpreter.spokenSummary("Done. Added the socks.\nCart: 2 items") == "Added the socks.")
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        #expect(UtteranceInterpreter.spokenSummary(long).split(separator: " ").count == 25)
        #expect(UtteranceInterpreter.needsPerson("Please log in to Amazon first"))
        #expect(UtteranceInterpreter.needsPerson("Complete the CAPTCHA"))
        #expect(!UtteranceInterpreter.needsPerson("Which size do you want?"))
    }
}

// MARK: - Plans that ask

@Suite("Plan questions")
struct PlanQuestionTests {
    @Test func decodesQuestionsNeedsAndAck() throws {
        let json = planJSON(ack: "On it — opening Amazon.", questions: [
            questionJSON("q1", "Which socks?", options: ["A", "B", "C", "D", "E"], default: "A", lowRisk: true),
            questionJSON("q2", "Buy now?", options: ["Yes", "No"], default: "Yes", lowRisk: false),
        ], steps: [planStepJSON("Searching", "Search for socks"), planStepJSON("Adding", "Add them", needs: ["q1", "q9"])])
        let plan = try PlanSchema.decode(json)
        #expect(plan.ack == "On it — opening Amazon.")
        #expect(plan.questions.map(\.id) == ["q1", "q2"])
        #expect(plan.questions[0].options.count == 4, "at most four options")
        #expect(plan.questions[0].defaultOption == "A" && plan.questions[0].lowRisk)
        #expect(plan.questions[1].defaultOption == nil, "a default only on a low-risk question")
        #expect(plan.steps[0].needs.isEmpty)
        #expect(plan.steps[1].needs == ["q1"], "needs only names questions that exist")
        expectStrict(PlanSchema.schema)
    }

    @Test func oldPlansStillDecode() throws {
        let old = #"{"goal":"g","steps":[{"id":1,"title":"t","instruction":"i","route":"command","risk":"low","doneWhen":"d"}],"mode":"quick"}"#
        let plan = try JSONDecoder().decode(Plan.self, from: Data(old.utf8))
        #expect(plan.questions.isEmpty && plan.ack == nil && plan.steps[0].needs.isEmpty)
        let round = try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(Plan(goal: "g", steps: [], clarification: nil, ack: "Hi",
                                                                                                questions: [AgentQuestion(id: "q", text: "Q?")])))
        #expect(round.ack == "Hi" && round.questions.first?.id == "q")
    }

    @Test func plannerPromptAsksWhileWorking() {
        #expect(Prompts.planner.contains("ask while working, never instead of working"))
        #expect(Prompts.planner.contains("Never low_risk for"))
    }
}

// MARK: - The conversation object

@Suite("TaskConversation")
struct TaskConversationTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [TaskConversation.Event] = []
        func add(_ e: TaskConversation.Event) { lock.withLock { list.append(e) } }
        var all: [TaskConversation.Event] { lock.withLock { list } }
        var spokenQuestions: [String] { all.compactMap { if case .speech(.question(let q)) = $0 { return q.id } else { return nil } } }
        var acks: [String] { all.compactMap { if case .speech(.ack(let s)) = $0 { return s } else { return nil } } }
    }

    @Test func showsOneQuestionAtATimeInOrder() async {
        let events = Events()
        let c = TaskConversation(defaultAfter: 0, emit: events.add)
        c.post(AgentQuestion(id: "a", text: "A?"))
        c.post(AgentQuestion(id: "b", text: "B?"))
        #expect(c.current?.id == "a" && events.spokenQuestions == ["a"])
        #expect(c.answer("a", with: "yes"))
        #expect(c.current?.id == "b" && events.spokenQuestions == ["a", "b"])
        #expect(!c.answer("a", with: "again"), "an answered question is closed")
        #expect(c.takeNotes() == ["The user answered “A?”: yes"])
        let approval = AgentQuestion(id: "ok", text: "Okay to buy?", options: ["Yes", "No"], isApproval: true)
        c.post(approval, first: true)
        #expect(c.current?.id == "ok", "an approval jumps the queue")
        c.withdraw("ok")
        #expect(c.current?.id == "b" && events.spokenQuestions == ["a", "b", "ok", "b"])
    }

    @Test func waitersGetTheAnswerAndCloseReleasesThem() async {
        let c = TaskConversation(defaultAfter: 0, emit: { _ in })
        let q = AgentQuestion(id: "q", text: "Size?")
        c.post(q)
        async let answer = c.waitForAnswer("q")
        try? await Task.sleep(for: .milliseconds(50))
        c.answer("q", with: "10")
        #expect(await answer == "10")
        #expect(c.takeNotes().isEmpty, "a waited-for answer isn't also a note")
        c.post(AgentQuestion(id: "r", text: "Color?"))
        async let never = c.waitForAnswer("r")
        try? await Task.sleep(for: .milliseconds(50))
        c.close()
        #expect(await never == nil)
        #expect(await c.waitForAnswer("unknown") == nil)
    }

    @Test func lowRiskDefaultsKickInButApprovalsNever() async {
        let events = Events()
        let c = TaskConversation(defaultAfter: 0.1, emit: events.add)
        c.post(AgentQuestion(id: "approve", text: "Okay to send?", options: ["Yes", "No"], defaultOption: "Yes", lowRisk: true, isApproval: true))
        c.post(AgentQuestion(id: "risky", text: "Delete it?", options: ["Yes", "No"], defaultOption: "Yes", lowRisk: false))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(c.current?.id == "approve" && c.answer(for: "approve") == nil, "an approval is never answered by silence")
        c.answer("approve", with: "Yes")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(c.answer(for: "risky") == nil, "nor is anything that isn't low risk")
        c.answer("risky", with: "No")
        c.post(AgentQuestion(id: "size", text: "Which size?", options: ["M", "L"], defaultOption: "L", lowRisk: true))
        #expect(await eventually { c.answer(for: "size") == "L" })
        #expect(c.wasDefaulted("size"))
        #expect(events.acks == [TaskConversation.goingWith("L")])
        #expect(TaskConversation.goingWith("L") == "Going with L — say stop to change.")
    }

    @Test func aPauseHoldsTheDefaultBack() async {
        let paused = Mutex(true)
        let c = TaskConversation(defaultAfter: 0.05, emit: { _ in })
        c.isPaused = { paused.withLock { $0 } }
        c.post(AgentQuestion(id: "size", text: "Which size?", defaultOption: "L", lowRisk: true))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(c.answer(for: "size") == nil)
        paused.withLock { $0 = false }
        #expect(await eventually { c.answer(for: "size") == "L" })
    }
}

// MARK: - ask_user in tool steps

@Suite("Asking from tool steps")
struct AskUserToolTests {
    @Test func askWithoutWaitingAndHearTheAnswerAsANote() async throws {
        let c = TaskConversation(defaultAfter: 0, emit: { _ in })
        let looking = Latch()
        let look = FakeTool("shell.run") { _, _ in await looking.wait(); return ToolOutput(ok: true, text: "looked") }
        let llm = ScriptedLLM([
            toolReply(calls: [("ask_user", ["question": "Which size?", "options": .array(["M", "L"]), "wait": false, "low_risk": true, "default": "M"])]),
            toolReply(calls: [("shell.run", ["command": "look"])]),
            toolReply("step_done", message: "Picked size"),
        ])
        var runner = makeRunner([look], llm: llm)
        runner.conversation = c
        let rec = CallbackRecorder()
        let step = Task { try await runner.execute(request(), callbacks: rec.callbacks) }
        #expect(await eventually { c.current?.text == "Which size?" })
        #expect(c.current?.defaultOption == "M")
        // The step keeps working (looking) while the question is open; the answer comes meanwhile.
        #expect(await eventually { look.calls.count == 1 })
        c.answer(try #require(c.current?.id), with: "L")
        looking.open()
        let result = try await step.value
        #expect(result.status == .done)
        #expect(llm.userMessages.first?.contains("- ask_user:") == true, "the tool is listed")
        #expect(llm.userMessages[1].contains("ask_user “Which size?” → asked"))
        #expect(llm.userMessages.last?.contains("note from the user: The user answered “Which size?”: L") == true)
    }

    @Test func waitSuspendsOnlyThatStepUntilAnswered() async throws {
        let c = TaskConversation(defaultAfter: 0, emit: { _ in })
        let llm = ScriptedLLM([
            toolReply(calls: [("ask_user", ["question": "Which file?", "wait": true])]),
            toolReply("step_done", message: "ok"),
        ])
        var runner = makeRunner([FakeTool("shell.idle")], llm: llm)
        runner.conversation = c
        let step = Task { try await runner.execute(request(), callbacks: CallbackRecorder().callbacks) }
        #expect(await eventually { c.current != nil })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(llm.requests.count == 1, "the step waits for the answer")
        c.answer(try #require(c.current?.id), with: "report.pdf")
        #expect(try await step.value.status == .done)
        #expect(llm.userMessages.last?.contains("the user answered: report.pdf") == true)
    }

    @Test func aBlockedDecisionBecomesAQuestionButALoginDoesNot() async throws {
        let c = TaskConversation(defaultAfter: 0, emit: { _ in })
        let llm = ScriptedLLM([
            toolReply("blocked", message: "Which of the two calendars should I use?"),
            toolReply("blocked", message: "Please log in to Google Calendar first."),
        ])
        var runner = makeRunner([FakeTool("shell.idle")], llm: llm)
        runner.conversation = c
        let step = Task { try await runner.execute(request(), callbacks: CallbackRecorder().callbacks) }
        #expect(await eventually { c.current?.text == "Which of the two calendars should I use?" })
        c.answer(try #require(c.current?.id), with: "Work")
        let result = try await step.value
        #expect(result.status == .blocked("Please log in to Google Calendar first."))
        #expect(llm.userMessages.last?.contains("they answered: Work") == true)
    }

    @Test func jobStepsDontTalk() async throws {
        let c = TaskConversation(defaultAfter: 0, emit: { _ in })
        let llm = ScriptedLLM([toolReply("blocked", message: "Which one?")])
        var runner = makeRunner([FakeTool("shell.idle")], llm: llm)
        runner.conversation = c
        let result = try await runner.execute(request(jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .blocked("Which one?"))
        #expect(c.current == nil)
        #expect(llm.userMessages.first?.contains("- ask_user:") == false)
    }
}

// MARK: - The controller's conversation

@MainActor
@Suite("Conversation through the controller", .serialized)
struct ConversationControllerTests {
    static let socksPlan = planJSON(ack: "On it — opening Amazon.", questions: [
        questionJSON("q1", "Which socks — athletic crew, no-show or wool?", options: ["Athletic crew", "No-show", "Wool"],
                     default: "Athletic crew", lowRisk: true),
    ], steps: [
        planStepJSON("Searching for socks", "Search Amazon for socks"),
        planStepJSON("Adding to cart", "Add the chosen socks to the cart", risk: "medium", needs: ["q1"]),
    ])

    static func socksModel() -> ScriptedLLM {
        taskModel(plan: socksPlan, steps: [
            1: [toolReply(calls: [("shop.search", ["q": "socks"])]), toolReply("step_done", message: "Found athletic crew, no-show and wool socks")],
            2: [toolReply(calls: [("cart.add", [:])]), spokenDone("Added the socks to your cart.", spoken: "Added wool socks — your cart is $14.98.")],
        ])
    }

    @Test func theSocksFlowAsksWhileSearching() async throws {
        let searching = Latch()
        let search = FakeTool("shop.search") { _, _ in await searching.wait(); return ToolOutput(ok: true, text: "3 kinds of socks") }
        let add = FakeTool("cart.add") { _, _ in ToolOutput(ok: true, text: "added") }
        let fx = try ConversationFixture(llm: Self.socksModel(), tools: [search, add])
        defer { Task { await fx.cleanUp() } }
        fx.say("add socks to my cart on Amazon")
        // The question is up while the search runs.
        #expect(await eventuallyOnMain { fx.controller.pendingQuestion?.id == "q1" })
        #expect(await eventually { search.calls.count == 1 })
        #expect(add.calls.isEmpty)
        searching.open()
        // The add step waits for the answer.
        #expect(await eventuallyOnMain { fx.controller.status == ExecutionOrchestrator.waitingStatus })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(add.calls.isEmpty && fx.controller.isRunning)
        fx.say("the wool ones")
        #expect(await fx.finished())
        #expect(fx.controller.lastResult?.status == .completed)
        #expect(add.calls.count == 1)
        #expect(fx.controller.pendingQuestion == nil)
        let addPrompt = try #require(fx.llm.userMessages.last { $0.contains("STEP 2:") })
        #expect(addPrompt.contains("The user answered “Which socks — athletic crew, no-show or wool?”: Wool"))
        // Said in order: ack, the question, the result.
        #expect(fx.cues.first == .ack("On it — opening Amazon."))
        #expect(fx.questionCues == ["Which socks — athletic crew, no-show or wool?"])
        #expect(fx.cues.last == .result("Added wool socks — your cart is $14.98."))
    }

    @Test func aLowRiskDefaultKicksInAfterTheTimeout() async throws {
        let search = FakeTool("shop.search")
        let add = FakeTool("cart.add")
        let fx = try ConversationFixture(llm: Self.socksModel(), tools: [search, add], defaultAfter: 0.3)
        defer { Task { await fx.cleanUp() } }
        fx.say("add socks to my cart on Amazon")
        #expect(await fx.finished())
        #expect(fx.controller.lastResult?.status == .completed)
        #expect(add.calls.count == 1)
        #expect(fx.cues.contains(.ack("Going with Athletic crew — say stop to change.")))
        let addPrompt = try #require(fx.llm.userMessages.last { $0.contains("STEP 2:") })
        #expect(addPrompt.contains("going with the default: Athletic crew"))
    }

    @Test func anApprovalIsNeverDefaultedAndYesByVoiceApproves() async throws {
        let add = FakeTool("cart.add", handler: { _, _ in ToolOutput(ok: true, text: "bought") }, verdict: highRisk("Buy the socks"))
        let llm = taskModel(plan: planJSON(steps: [planStepJSON("Buying", "Buy the socks", risk: "high")]),
                            steps: [1: [toolReply(calls: [("cart.add", [:])]), spokenDone("Bought them.", spoken: "Bought them.")]])
        let fx = try ConversationFixture(llm: llm, tools: [add], defaultAfter: 0.1)
        defer { Task { await fx.cleanUp() } }
        fx.say("buy the socks")
        #expect(await eventuallyOnMain { fx.controller.pendingQuestion?.isApproval == true })
        let q = try #require(fx.controller.pendingQuestion)
        #expect(q.options == ["Yes", "No"] && q.text == "Should I buy the socks?")
        #expect(fx.controller.pendingApproval != nil)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(add.calls.isEmpty && fx.controller.phase == .awaitingApproval, "silence never approves")
        #expect(fx.questionCues == ["Should I buy the socks?"])
        fx.say("yeah, go ahead")
        #expect(await fx.finished())
        #expect(add.calls.count == 1)
        #expect(fx.controller.lastResult?.status == .completed)
    }

    @Test func noByVoiceDeclines() async throws {
        let add = FakeTool("cart.add", verdict: highRisk("Buy the socks"))
        let llm = taskModel(plan: planJSON(steps: [planStepJSON("Buying", "Buy the socks", risk: "high")]),
                            steps: [1: [toolReply(calls: [("cart.add", [:])]), toolReply("task_done", message: "Didn't buy anything.")]])
        let fx = try ConversationFixture(llm: llm, tools: [add])
        defer { Task { await fx.cleanUp() } }
        fx.say("buy the socks")
        #expect(await eventuallyOnMain { fx.controller.pendingQuestion?.isApproval == true })
        fx.say("nope")
        #expect(await fx.finished())
        #expect(add.calls.isEmpty)
        #expect(fx.controller.activity.contains { $0.title == "You said no" })
    }

    @Test func theNotchButtonsAlsoClearTheSpokenApproval() async throws {
        let add = FakeTool("cart.add", verdict: highRisk("Buy the socks"))
        let llm = taskModel(plan: planJSON(steps: [planStepJSON("Buying", "Buy the socks", risk: "high")]),
                            steps: [1: [toolReply(calls: [("cart.add", [:])]), toolReply("task_done", message: "Bought.")]])
        let fx = try ConversationFixture(llm: llm, tools: [add])
        defer { Task { await fx.cleanUp() } }
        fx.say("buy the socks")
        #expect(await eventuallyOnMain { fx.controller.pendingQuestion?.isApproval == true })
        fx.controller.respondToApproval(.approve)
        #expect(fx.controller.pendingQuestion == nil)
        #expect(await fx.finished())
        #expect(add.calls.count == 1)
    }

    @Test func aSteeringNoteReachesTheRunningStep() async throws {
        let looking = Latch()
        let look = FakeTool("shop.search") { _, _ in await looking.wait(); return ToolOutput(ok: true, text: "shoes") }
        let llm = taskModel(plan: planJSON(steps: [planStepJSON("Finding shoes", "Find running shoes")]),
                            steps: [1: [toolReply(calls: [("shop.search", [:])]), toolReply("task_done", message: "Found size 10 shoes.")]])
        let fx = try ConversationFixture(llm: llm, tools: [look])
        defer { Task { await fx.cleanUp() } }
        fx.say("find me running shoes")
        #expect(await eventually { look.calls.count == 1 })
        fx.say("make it size 10")
        #expect(await eventuallyOnMain { fx.cues.contains(.ack("Got it.")) })
        looking.open()
        #expect(await fx.finished())
        let second = try #require(fx.llm.userMessages.last { $0.contains("STEP 1:") })
        #expect(second.contains("note from the user: make it size 10"))
    }

    @Test func stopPauseAndResumeWords() async throws {
        let working = Latch()
        let work = FakeTool("shop.search") { _, _ in await working.wait(); return ToolOutput(ok: true, text: "ok") }
        let llm = taskModel(plan: planJSON(steps: [planStepJSON("Working", "Do the work")]), steps: [1: [toolReply(calls: [("shop.search", [:])])]])
        let fx = try ConversationFixture(llm: llm, tools: [work])
        defer { Task { working.open(); await fx.cleanUp() } }
        fx.say("do the work")
        #expect(await eventually { work.calls.count == 1 })
        #expect(await eventuallyOnMain { fx.controller.phase == .executing })
        fx.say("wait")
        #expect(fx.controller.phase == .paused && fx.runtime.gate.isPaused)
        fx.say("go on")
        #expect(fx.controller.phase == .executing && !fx.runtime.gate.isPaused)
        fx.say("stop")
        #expect(fx.controller.phase == .stopped && fx.runtime.gate.isStopped)
        #expect(await eventuallyOnMain { !fx.controller.isBusy })
        #expect(fx.controller.lastResult?.status == .stopped)
        #expect(fx.cues.contains(.ack("Okay, stopped.")))
    }

    @Test func instantActionsComeFirstAndTheirRemainderIsPlannedWithContext() async throws {
        let llm = taskModel(plan: planJSON(steps: [planStepJSON("Asking ChatGPT", "Ask it for a haiku")]),
                            steps: [1: [spokenDone("ChatGPT wrote a haiku.", spoken: "Here's your haiku.")]])
        let fx = try ConversationFixture(llm: llm, instant: { text in
            guard text.lowercased().hasPrefix("open chatgpt") else { return nil }
            return InstantResult(ack: "Opening ChatGPT.", summary: "Opened ChatGPT", remainder: "ask it to write a haiku",
                                 context: "ChatGPT (desktop app) is open and in front.")
        })
        defer { Task { await fx.cleanUp() } }
        fx.say("open ChatGPT and ask it to write a haiku")
        #expect(await fx.finished())
        #expect(fx.cues.first == .ack("Opening ChatGPT."))
        let planning = try #require(llm.requests.first { $0.schemaName == "plan" }?.messages.last?.text)
        #expect(planning.contains("User request: ask it to write a haiku"))
        #expect(planning.contains("ChatGPT (desktop app) is open and in front."))
        #expect(fx.cues.last == .result("Here's your haiku."))
    }

    @Test func anInstantFollowUpIsAskedAndItsAnswerStartsATask() async throws {
        let llm = taskModel(plan: planJSON(steps: [planStepJSON("Asking ChatGPT", "Ask for a haiku")]),
                            steps: [1: [toolReply("task_done", message: "Done.")]])
        let followUp = AgentQuestion(id: "next", text: "Want me to do anything in ChatGPT?")
        let fx = try ConversationFixture(llm: llm, instant: { text in
            text == "open ChatGPT" ? InstantResult(ack: "Opening ChatGPT.", summary: "Opened ChatGPT", followUp: followUp,
                                                   context: "ChatGPT is open.") : nil
        })
        defer { Task { await fx.cleanUp() } }
        fx.say("open ChatGPT")
        #expect(await eventuallyOnMain { fx.controller.pendingQuestion?.id == "next" })
        #expect(fx.controller.phase == .completed && fx.controller.status == "Opened ChatGPT")
        #expect(llm.requests.isEmpty, "no model for an instant action")
        #expect(fx.cues == [.ack("Opening ChatGPT."), .question(followUp)])
        fx.say("ask it to write a haiku")
        #expect(await eventuallyOnMain { fx.controller.lastResult?.summary == "Done." && !fx.controller.isBusy })
        let planning = try #require(llm.requests.first?.messages.last?.text)
        #expect(planning.contains("User request: ask it to write a haiku") && planning.contains("ChatGPT is open."))
        #expect(fx.controller.pendingQuestion == nil)
    }

    @Test func noClosesAnInstantFollowUp() async throws {
        let fx = try ConversationFixture(llm: ScriptedLLM([]), instant: { _ in
            InstantResult(ack: "Opening Notes.", summary: "Opened Notes", followUp: AgentQuestion(id: "n", text: "Anything in Notes?"))
        })
        defer { Task { await fx.cleanUp() } }
        fx.say("open Notes")
        #expect(await eventuallyOnMain { fx.controller.pendingQuestion?.id == "n" })
        fx.say("no thanks")
        #expect(fx.controller.pendingQuestion == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fx.controller.isBusy && fx.llm.requests.isEmpty)
    }

    @Test func theFollowUpWindowCarriesThePreviousTask() async throws {
        let llm = taskModel(plan: planJSON(steps: [planStepJSON("Adding", "Add socks")]),
                            steps: [1: [toolReply("task_done", message: "Added Hanes crew socks to the cart.")]])
        let fx = try ConversationFixture(llm: llm)
        defer { Task { await fx.cleanUp() } }
        fx.say("add socks to my cart")
        #expect(await fx.finished())
        fx.say("now add two of them")
        #expect(await eventuallyOnMain { fx.llm.requests.filter { $0.schemaName == "plan" }.count == 2 && !fx.controller.isBusy })
        let second = try #require(llm.requests.last { $0.schemaName == "plan" }?.messages.last?.text)
        #expect(second.contains("Previous request: add socks to my cart"))
        #expect(second.contains("Its result: Added Hanes crew socks to the cart."))

        let outside = try ConversationFixture(llm: taskModel(plan: planJSON(steps: [planStepJSON("Adding", "Add socks")]),
                                                             steps: [1: [toolReply("task_done", message: "Added.")]]), followUpMinutes: 0)
        defer { Task { await outside.cleanUp() } }
        outside.say("add socks to my cart")
        #expect(await outside.finished())
        outside.say("now add two of them")
        #expect(await eventuallyOnMain { outside.llm.requests.filter { $0.schemaName == "plan" }.count == 2 && !outside.controller.isBusy })
        let plain = try #require(outside.llm.requests.last { $0.schemaName == "plan" }?.messages.last?.text)
        #expect(!plain.contains("Previous request"))
    }

    @Test func questionsAreSpokenOneAtATimeInOrder() async throws {
        let llm = taskModel(plan: planJSON(ack: "Sure — planning the trip.", questions: [
            questionJSON("q1", "Which city?", options: ["Paris", "Rome"]),
            questionJSON("q2", "Which month?"),
        ], steps: [
            planStepJSON("Looking", "Look at options"),
            planStepJSON("Booking city", "Pick the city", needs: ["q1"]),
            planStepJSON("Booking month", "Pick the month", needs: ["q2"]),
        ]), steps: [3: [toolReply("task_done", message: "Planned.")]])
        let fx = try ConversationFixture(llm: llm)
        defer { Task { await fx.cleanUp() } }
        fx.say("plan a trip")
        #expect(await eventuallyOnMain { fx.controller.pendingQuestion?.id == "q1" })
        #expect(fx.questionCues == ["Which city?"])
        fx.say("Rome")
        #expect(await eventuallyOnMain { fx.controller.pendingQuestion?.id == "q2" })
        #expect(await eventuallyOnMain { fx.questionCues == ["Which city?", "Which month?"] })
        fx.say("May")
        #expect(await fx.finished())
        #expect(fx.cues.first == .ack("Sure — planning the trip."))
        #expect(fx.cues.last == .result("Planned."))
    }

    @Test func aClarificationIsAskedAndItsAnswerReRunsTheRequest() async throws {
        let counter = TurnCounter()
        let llm = ScriptedLLM(respond: { request, _ in
            if request.schemaName == "plan" {
                return counter.next("plan") == 0 ? planJSON(steps: [], clarification: "Which Sam do you mean?")
                                                 : planJSON(steps: [planStepJSON("Messaging", "Message Sam")])
            }
            return toolReply("task_done", message: "Sent.")
        })
        let fx = try ConversationFixture(llm: llm)
        defer { Task { await fx.cleanUp() } }
        fx.say("message Sam")
        #expect(await eventuallyOnMain { fx.controller.pendingQuestion?.text == "Which Sam do you mean?" })
        #expect(fx.questionCues == ["Which Sam do you mean?"])
        fx.say("Sam Lee")
        #expect(await eventuallyOnMain { fx.controller.lastResult?.status == .completed && !fx.controller.isBusy })
        let second = try #require(llm.requests.last { $0.schemaName == "plan" }?.messages.last?.text)
        #expect(second.contains("The user's answer to “Which Sam do you mean?”: Sam Lee"))
    }

    @Test func failuresAndBlocksAreSpoken() async throws {
        let llm = taskModel(plan: planJSON(steps: [planStepJSON("Opening", "Open the account page")]),
                            steps: [1: [toolReply("blocked", message: "Please log in to your bank first.")]])
        let fx = try ConversationFixture(llm: llm)
        defer { Task { await fx.cleanUp() } }
        fx.say("check my balance")
        #expect(await fx.finished())
        #expect(fx.controller.lastResult?.status == .needsInput)
        #expect(fx.cues.last == .needsYou("Please log in to your bank first."))
    }
}
