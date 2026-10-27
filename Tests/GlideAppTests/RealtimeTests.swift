import Testing
import Foundation
@testable import GlideApp
@testable import AgentKit

// Offline tests for the realtime voice (OpenAI Realtime API). No socket, microphone or audio:
// the transport, audio and Glide's controller are fakes, and server events are recorded JSON.

// MARK: - Fakes

final class FakeTransport: RealtimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [String] = []
    private(set) var connected = false
    private(set) var closed = false
    private var onClose: (@Sendable ((any Error)?) -> Void)?

    func connect(onMessage: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable ((any Error)?) -> Void) {
        connected = true
        self.onClose = onClose
    }

    func send(_ frame: String) { lock.withLock { _frames.append(frame) } }
    func close() { closed = true }

    var frames: [String] { lock.withLock { _frames } }
    var types: [String] { frames.compactMap(RealtimeClientEvent.type(of:)) }
    func sent(_ type: String) -> [[String: Any]] {
        frames.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }.filter { $0["type"] as? String == type }
    }
    func clear() { lock.withLock { _frames.removeAll() } }
    /// The server dropped the connection.
    func drop() { onClose?(RealtimeError.closed("test")) }
}

@MainActor
final class FakeRealtimeAudio: RealtimeAudioIO {
    var authorized = true
    private(set) var started = false
    private(set) var stops = 0
    private(set) var playbackStops = 0
    private(set) var playedBytes: [String: Int] = [:]
    var playedMs: [String: Int] = [:]
    var playing = false

    func authorize(mayPrompt: Bool) async -> Bool { authorized }
    func start(onAudio: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Float) -> Void,
               onPlaying: @escaping @Sendable (Bool) -> Void) throws { started = true }
    func play(_ pcm16: Data, itemID: String) {
        playedBytes[itemID, default: 0] += pcm16.count
        playing = true
    }
    func playedMilliseconds(itemID: String) -> Int { playedMs[itemID] ?? 0 }
    func stopPlayback() {
        playbackStops += 1
        playing = false
    }
    var isPlaying: Bool { playing }
    func stop() {
        stops += 1
        started = false
        playing = false
    }
}

@MainActor
final class FakeGlide: GlideControlling {
    var pendingQuestion: AgentQuestion?
    var phase: AgentPhase = .idle
    var status = ""
    var isRunning: Bool { [.planning, .executing, .awaitingApproval, .paused].contains(phase) }
    var lastFinished: TaskController.FinishedRequest?
    private(set) var utterances: [(String, UtteranceSource)] = []
    private(set) var answers: [(String, String)] = []
    private(set) var controls: [String] = []

    func handleUtterance(_ text: String, source: UtteranceSource) {
        utterances.append((text, source))
        phase = .planning
        status = "Planning…"
    }
    func answer(questionID: String, with text: String) {
        answers.append((questionID, text))
        pendingQuestion = nil
    }
    func pause() { controls.append("pause"); phase = .paused }
    func resume() { controls.append("resume"); phase = .executing }
    func stop() { controls.append("stop"); phase = .stopped }
}

@MainActor
struct RealtimeFixture {
    let transport = FakeTransport()
    let audio = FakeRealtimeAudio()
    let glide = FakeGlide()
    let conversation: RealtimeConversation
    final class Log { var events: [RealtimeConversation.Event] = [] }
    let log = Log()

    init(idleSeconds: Double = 60) {
        conversation = RealtimeConversation(transport: transport, audio: audio, glide: glide)
        conversation.timing.idleSeconds = idleSeconds
        let log = self.log
        conversation.onEvent = { log.events.append($0) }
    }

    /// Starts and confirms the session, then forgets the frames sent so far.
    func ready() async {
        conversation.start(mayPrompt: false)
        _ = await eventually { transport.connected }
        conversation.receive(#"{"type":"session.created","event_id":"e0","session":{"id":"sess_1","object":"realtime.session","type":"realtime"}}"#)
        transport.clear()
    }
}

// MARK: - Wire format

@Suite("Realtime: event encoding")
struct RealtimeEncodingTests {
    func object(_ e: RealtimeClientEvent) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(e.encoded().utf8))) as? [String: Any] ?? [:]
    }

    @Test func sessionUpdateSetsAudioVADTranscriptionAndTools() {
        let o = object(.sessionUpdate(RealtimeSessionConfig()))
        #expect(o["type"] as? String == "session.update")
        let session = o["session"] as? [String: Any] ?? [:]
        #expect(session["type"] as? String == "realtime")
        #expect(session["output_modalities"] as? [String] == ["audio"])
        #expect((session["instructions"] as? String)?.hasPrefix("You are Glide, a cool, quick assistant living in the Mac's notch") == true)
        let audio = session["audio"] as? [String: Any] ?? [:]
        let input = audio["input"] as? [String: Any] ?? [:]
        let format = input["format"] as? [String: Any] ?? [:]
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24000)
        let vad = input["turn_detection"] as? [String: Any] ?? [:]
        #expect(vad["type"] as? String == "server_vad")
        #expect(vad["silence_duration_ms"] as? Int == 350)
        #expect(vad["interrupt_response"] as? Bool == true)
        #expect(vad["create_response"] as? Bool == true)
        #expect((input["transcription"] as? [String: Any])?["model"] as? String == "gpt-4o-mini-transcribe")
        let output = audio["output"] as? [String: Any] ?? [:]
        #expect(output["voice"] as? String == "marin")
        let tools = session["tools"] as? [[String: Any]] ?? []
        #expect(tools.map { $0["name"] as? String } == ["run_task", "open_app_or_site", "answer_glide", "remember", "forget", "control"])
        #expect(tools.allSatisfy { $0["type"] as? String == "function" })
        let control = tools.last?["parameters"] as? [String: Any]
        let action = (control?["properties"] as? [String: Any])?["action"] as? [String: Any]
        #expect(action?["enum"] as? [String] == ["stop", "pause", "resume"])
        #expect(control?["required"] as? [String] == ["action"])
    }

    @Test func clientEvents() {
        let pcm = Data([1, 0, 255, 127])
        let append = object(.appendAudio(pcm))
        #expect(append["type"] as? String == "input_audio_buffer.append")
        #expect(Data(base64Encoded: append["audio"] as? String ?? "") == pcm)

        let truncate = object(.truncate(itemID: "item_9", contentIndex: 0, audioEndMs: 1500))
        #expect(truncate["type"] as? String == "conversation.item.truncate")
        #expect(truncate["item_id"] as? String == "item_9")
        #expect(truncate["content_index"] as? Int == 0)
        #expect(truncate["audio_end_ms"] as? Int == 1500)

        #expect(object(.cancelResponse(responseID: "resp_1"))["response_id"] as? String == "resp_1")
        #expect(object(.cancelResponse(responseID: nil)).keys.sorted() == ["type"])
        #expect(object(.createResponse)["type"] as? String == "response.create")

        let out = object(.functionOutput(callID: "call_1", output: "{\"result\":\"started\"}"))
        #expect(out["type"] as? String == "conversation.item.create")
        let item = out["item"] as? [String: Any]
        #expect(item?["type"] as? String == "function_call_output")
        #expect(item?["call_id"] as? String == "call_1")
        #expect(item?["output"] as? String == "{\"result\":\"started\"}")

        let sys = object(.systemMessage("Glide finished."))["item"] as? [String: Any]
        #expect(sys?["role"] as? String == "system")
        let content = sys?["content"] as? [[String: Any]]
        #expect(content?.first?["type"] as? String == "input_text")
        #expect(content?.first?["text"] as? String == "Glide finished.")
    }

    @Test func socketURLFromProviderBase() {
        #expect(RealtimeProtocol.socketURL(baseURL: "https://api.openai.com/v1", model: "gpt-realtime-2.1-mini")?.absoluteString
                == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        #expect(RealtimeProtocol.socketURL(baseURL: "https://api.openai.com/v1/ ", model: "gpt-realtime-2.1")?.absoluteString
                == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
        #expect(RealtimeProtocol.socketURL(baseURL: "http://localhost:8080/v1", model: "m")?.absoluteString == "ws://localhost:8080/v1/realtime?model=m")
        #expect(RealtimeProtocol.socketURL(baseURL: "ftp://x", model: "m") == nil)
        let req = RealtimeProtocol.socketRequest(baseURL: "https://api.openai.com/v1", apiKey: "sk-test", model: "m")
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(req?.value(forHTTPHeaderField: "OpenAI-Beta") == nil)
        #expect(RealtimeProtocol.defaultModel == "gpt-realtime-2.1-mini")
        #expect(RealtimeProtocol.voice(for: "Cedar") == "cedar")
        #expect(RealtimeProtocol.voice(for: "nova") == "marin")
    }
}

@Suite("Realtime: event decoding (recorded samples)")
struct RealtimeDecodingTests {
    static let audio = Data([0, 1, 2, 3]).base64EncodedString()

    static let samples: [(String, RealtimeServerEvent)] = [
        (#"{"type":"session.updated","event_id":"e1","session":{"id":"sess_1","type":"realtime"}}"#, .sessionUpdated),
        (#"{"type":"input_audio_buffer.speech_started","event_id":"e2","audio_start_ms":1000,"item_id":"item_u1"}"#,
         .speechStarted(itemID: "item_u1", audioStartMs: 1000)),
        (#"{"type":"input_audio_buffer.speech_stopped","event_id":"e3","audio_end_ms":2000,"item_id":"item_u1"}"#, .speechStopped(itemID: "item_u1")),
        (#"{"type":"conversation.item.input_audio_transcription.delta","event_id":"e4","item_id":"item_u1","content_index":0,"delta":"open sa"}"#,
         .inputTranscriptDelta(itemID: "item_u1", delta: "open sa")),
        (#"{"type":"conversation.item.input_audio_transcription.completed","event_id":"e5","item_id":"item_u1","content_index":0,"transcript":"open safari","usage":{"type":"duration","seconds":1}}"#,
         .inputTranscriptCompleted(itemID: "item_u1", transcript: "open safari")),
        (#"{"type":"response.created","event_id":"e6","response":{"id":"resp_1","object":"realtime.response","status":"in_progress","output":[]}}"#,
         .responseCreated(responseID: "resp_1")),
        (#"{"type":"response.output_item.added","event_id":"e7","response_id":"resp_1","output_index":0,"item":{"id":"item_a1","type":"message","role":"assistant"}}"#,
         .outputItemAdded(responseID: "resp_1", itemID: "item_a1", itemType: "message")),
        (#"{"type":"response.output_audio.delta","event_id":"e8","response_id":"resp_1","item_id":"item_a1","output_index":0,"content_index":0,"delta":"\#(audio)"}"#,
         .audioDelta(responseID: "resp_1", itemID: "item_a1", contentIndex: 0, audio: Data([0, 1, 2, 3]))),
        (#"{"type":"response.audio.delta","event_id":"e8b","response_id":"resp_1","item_id":"item_a1","output_index":0,"content_index":0,"delta":"\#(audio)"}"#,
         .audioDelta(responseID: "resp_1", itemID: "item_a1", contentIndex: 0, audio: Data([0, 1, 2, 3]))),
        (#"{"type":"response.output_audio_transcript.delta","event_id":"e9","response_id":"resp_1","item_id":"item_a1","output_index":0,"content_index":0,"delta":"On it"}"#,
         .transcriptDelta(itemID: "item_a1", delta: "On it")),
        (#"{"type":"response.output_audio_transcript.done","event_id":"e10","response_id":"resp_1","item_id":"item_a1","output_index":0,"content_index":0,"transcript":"On it."}"#,
         .transcriptDone(itemID: "item_a1", transcript: "On it.")),
        (#"{"type":"response.function_call_arguments.done","event_id":"e11","response_id":"resp_1","item_id":"item_f1","output_index":0,"call_id":"call_1","name":"run_task","arguments":"{\"instruction\":\"buy socks\"}"}"#,
         .functionCallDone(RealtimeFunctionCall(callID: "call_1", name: "run_task", arguments: #"{"instruction":"buy socks"}"#, itemID: "item_f1"))),
        (#"{"type":"response.done","event_id":"e12","response":{"id":"resp_1","status":"completed","output":[{"id":"item_f1","type":"function_call","status":"completed","name":"run_task","call_id":"call_1","arguments":"{}"}]}}"#,
         .responseDone(responseID: "resp_1", status: "completed", functionCalls: [RealtimeFunctionCall(callID: "call_1", name: "run_task", arguments: "{}", itemID: "item_f1")])),
        (#"{"type":"error","event_id":"e13","error":{"type":"invalid_request_error","code":"response_cancel_not_active","message":"No active response.","param":null}}"#,
         .error(type: "invalid_request_error", code: "response_cancel_not_active", message: "No active response.")),
        (#"{"type":"rate_limits.updated","event_id":"e14","rate_limits":[]}"#, .other("rate_limits.updated")),
    ]

    @Test func decodesRecordedEvents() {
        for (json, expected) in Self.samples {
            #expect(RealtimeServerEvent.decode(json) == expected, "\(json)")
        }
        #expect(RealtimeServerEvent.decode("not json") == nil)
        #expect(RealtimeServerEvent.decode(#"{"no_type":1}"#) == nil)
    }
}

// MARK: - Tools

@MainActor
@Suite("Realtime: Glide as tools")
struct RealtimeToolTests {
    func call(_ name: String, _ args: String) -> RealtimeFunctionCall { RealtimeFunctionCall(callID: "c", name: name, arguments: args) }
    func json(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }

    @Test func runTaskStartsAndReportsStatus() {
        let glide = FakeGlide()
        let out = json(RealtimeGlide.dispatch(call("run_task", #"{"instruction":"Add socks to my Amazon cart"}"#), to: glide))
        #expect(glide.utterances.map(\.0) == ["Add socks to my Amazon cart"])
        #expect(glide.utterances.first?.1 == .voice)
        #expect(out["result"] as? String == "started")
        let g = out["glide"] as? [String: Any]
        #expect(g?["phase"] as? String == "planning")
        #expect(g?["status"] as? String == "Planning…")
    }

    @Test func openGoesThroughTheInstantPath() {
        let glide = FakeGlide()
        _ = RealtimeGlide.dispatch(call("open_app_or_site", #"{"target":"youtube.com"}"#), to: glide)
        #expect(glide.utterances.map(\.0) == ["open youtube.com"])
    }

    @Test func answerGoesToThePendingQuestion() {
        let glide = FakeGlide()
        glide.pendingQuestion = AgentQuestion(id: "q1", text: "Which size?", options: ["M", "L"])
        _ = RealtimeGlide.dispatch(call("answer_glide", #"{"answer":"large"}"#), to: glide)
        #expect(glide.answers.map(\.0) == ["q1"])
        #expect(glide.answers.map(\.1) == ["large"])
        #expect(glide.utterances.isEmpty)
        // No question pending: the answer is just something the user said.
        _ = RealtimeGlide.dispatch(call("answer_glide", #"{"answer":"the blue ones"}"#), to: glide)
        #expect(glide.utterances.map(\.0) == ["the blue ones"])
    }

    @Test func controlActsOnlyWhenItApplies() {
        let glide = FakeGlide()
        #expect(json(RealtimeGlide.dispatch(call("control", #"{"action":"stop"}"#), to: glide))["result"] as? String == "nothing_running")
        glide.phase = .executing
        #expect(json(RealtimeGlide.dispatch(call("control", #"{"action":"pause"}"#), to: glide))["result"] as? String == "paused")
        #expect(json(RealtimeGlide.dispatch(call("control", #"{"action":"resume"}"#), to: glide))["result"] as? String == "resumed")
        #expect(json(RealtimeGlide.dispatch(call("control", #"{"action":"stop"}"#), to: glide))["result"] as? String == "stopped")
        #expect(glide.controls == ["pause", "resume", "stop"])
        #expect(json(RealtimeGlide.dispatch(call("run_task", #"{}"#), to: glide))["result"] as? String == "error")
        #expect(json(RealtimeGlide.dispatch(call("nope", #"{}"#), to: glide))["result"] as? String == "error")
    }

    @Test func toolCallsInTheConversationSendOutputsThenOneResponse() async {
        let f = RealtimeFixture()
        await f.ready()
        f.conversation.receive(#"{"type":"response.created","response":{"id":"resp_1"}}"#)
        f.conversation.receive(#"{"type":"response.function_call_arguments.done","response_id":"resp_1","item_id":"item_f1","call_id":"call_1","name":"run_task","arguments":"{\"instruction\":\"book a table\"}"}"#)
        #expect(f.glide.utterances.map(\.0) == ["book a table"])
        let outputs = f.transport.sent("conversation.item.create")
        #expect((outputs.first?["item"] as? [String: Any])?["call_id"] as? String == "call_1")
        #expect(f.transport.sent("response.create").isEmpty) // not while the response is still open
        // The same call again in response.done isn't run twice.
        f.conversation.receive(#"{"type":"response.done","response":{"id":"resp_1","status":"completed","output":[{"id":"item_f1","type":"function_call","call_id":"call_1","name":"run_task","arguments":"{\"instruction\":\"book a table\"}"}]}}"#)
        #expect(f.glide.utterances.count == 1)
        // Glide reports back when the task ends, so the model doesn't talk over it now.
        #expect(f.transport.types == ["conversation.item.create"])
    }

    @Test func controlCallsGetASpokenReply() async {
        let f = RealtimeFixture()
        await f.ready()
        f.glide.phase = .executing
        f.conversation.receive(#"{"type":"response.created","response":{"id":"resp_1"}}"#)
        f.conversation.receive(#"{"type":"response.done","response":{"id":"resp_1","status":"completed","output":[{"id":"item_f1","type":"function_call","call_id":"call_1","name":"control","arguments":"{\"action\":\"stop\"}"}]}}"#)
        #expect(f.transport.types == ["conversation.item.create", "response.create"])
    }

    @Test func resultsCarryTheFullAnswerForTheModelToWord() {
        let done = TaskController.FinishedRequest(instruction: "what's on Sam's LinkedIn profile?",
                                                  summary: "Sam Lee is a product manager at Acme in Seattle, previously at Initech.", status: .completed)
        let item = RealtimeGlide.conversationItem(for: .result("Sam's a PM at Acme."), finished: done)
        #expect(item?.respond == true)
        #expect(item?.text.contains("previously at Initech") == true)
        #expect(item?.text.contains("what's on Sam's LinkedIn profile?") == true)
    }

    @Test func rememberAndForgetUseTheMemoryStore() throws {
        let store = try LocalStore(path: NSTemporaryDirectory() + "glide-rt-memory-\(UUID().uuidString).sqlite")
        let glide = FakeGlide()
        func result(_ name: String, _ args: String, _ memory: LocalStore?) -> String? {
            (try? JSONSerialization.jsonObject(with: Data(RealtimeGlide.dispatch(call(name, args), to: glide, memory: memory).utf8)) as? [String: Any])?["result"] as? String
        }
        #expect(result("remember", #"{"fact":"My manager is Priya."}"#, store) == "remembered")
        #expect(store.memories().map(\.text) == ["My manager is Priya."])
        #expect(result("forget", #"{"about":"manager"}"#, store) == "forgot")
        #expect(store.memories().isEmpty)
        #expect(result("remember", #"{"fact":"x"}"#, nil) == "unavailable")
    }

    @Test func transcriptIsKeptForTheNextConversationWhileFresh() {
        let defaults = UserDefaults(suiteName: "glide.tests.transcript.\(UUID().uuidString)")!
        let log = RealtimeTranscriptLog(defaults: defaults)
        let then = Date()
        log.save(["User: open gmail", "Glide: Anything in Gmail?"], at: then)
        #expect(log.load(now: then.addingTimeInterval(60)) == "User: open gmail\nGlide: Anything in Gmail?")
        #expect(log.load(now: then.addingTimeInterval(3 * 3600)) == nil)
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().isEmpty ? "" : "glide.tests.transcript")
    }

    @Test func aTurnWithNoWordsCancelsTheReply() async {
        let f = RealtimeFixture()
        await f.ready()
        f.conversation.receive(#"{"type":"response.created","response":{"id":"resp_n"}}"#)
        f.conversation.receive(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","content_index":0,"transcript":" "}"#)
        #expect(f.transport.types.last == "response.cancel")
        #expect(f.conversation.transcript.isEmpty)
    }

    @Test func tasksGoToGlideInTheUsersOwnWords() async {
        let f = RealtimeFixture()
        await f.ready()
        f.conversation.receive(#"{"type":"input_audio_buffer.speech_started"}"#)
        f.conversation.receive(#"{"type":"input_audio_buffer.speech_stopped"}"#)
        f.conversation.receive(#"{"type":"response.created","response":{"id":"r1"}}"#)
        f.conversation.receive(#"{"type":"response.function_call_arguments.done","response_id":"r1","item_id":"f1","call_id":"c1","name":"run_task","arguments":"{\"instruction\":\"Show me what folders are on my desktop.\"}"}"#)
        #expect(f.glide.utterances.isEmpty) // held for the user's words
        f.conversation.receive(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","content_index":0,"transcript":"Can you open the folders on my desktop?"}"#)
        let sent = try? #require(f.glide.utterances.first?.0)
        #expect(sent?.hasPrefix("Can you open the folders on my desktop?") == true)
        #expect(sent?.contains("Show me what folders are on my desktop.") == true)
    }

    @Test func sameWordsAreSentOnce() {
        let args = RealtimeGlide.withUserWords("Search YouTube for jazz.", arguments: #"{"instruction":"search youtube for jazz"}"#)
        let json = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any]
        #expect(json?["instruction"] as? String == "Search YouTube for jazz.")
    }

    @Test func staysOpenWhileATaskRuns() async {
        let f = RealtimeFixture()
        await f.ready()
        f.glide.phase = .executing
        #expect(!f.conversation.canCloseForSilence)
        f.glide.phase = .idle
        #expect(f.conversation.canCloseForSilence)
    }
}

// MARK: - Conversation

@MainActor
@Suite("Realtime: conversation")
struct RealtimeConversationTests {
    @Test func startSendsSessionUpdateFirstAndOpensTheMic() async {
        let f = RealtimeFixture()
        f.conversation.start(mayPrompt: false)
        #expect(await eventually { f.transport.connected })
        #expect(f.transport.types.first == "session.update")
        #expect(f.audio.started)
        #expect(f.conversation.state == .connecting)
        f.conversation.receive(#"{"type":"session.created","session":{"id":"s"}}"#)
        #expect(f.conversation.state == .ready)
        #expect(f.log.events.contains(.ready))
    }

    @Test func cuesFeedTheConversation() async {
        let f = RealtimeFixture()
        await f.ready()
        f.conversation.feed(.progress("Still going."))
        f.conversation.feed(.ack("On it."))
        #expect(f.transport.frames.isEmpty)

        f.conversation.feed(.question(AgentQuestion(text: "Which size?", spoken: "Medium or large?", options: ["M", "L"])))
        let sys = f.transport.sent("conversation.item.create").first?["item"] as? [String: Any]
        #expect(sys?["role"] as? String == "system")
        let text = (sys?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(text.contains("Medium or large?"))
        #expect(text.contains("answer_glide"))
        #expect(f.transport.types == ["conversation.item.create", "response.create"])

        // A result while the model is talking waits for that response to finish.
        f.transport.clear()
        f.conversation.receive(#"{"type":"response.created","response":{"id":"resp_2"}}"#)
        f.conversation.feed(.result("Added Hanes socks, size L."))
        #expect(f.transport.types == ["conversation.item.create"])
        f.conversation.receive(#"{"type":"response.done","response":{"id":"resp_2","status":"completed","output":[]}}"#)
        #expect(f.transport.types == ["conversation.item.create", "response.create"])
    }

    @Test func bargeInStopsPlaybackTruncatesAndCancels() async {
        let f = RealtimeFixture()
        await f.ready()
        let audio = Data(repeating: 1, count: 4800).base64EncodedString()
        f.conversation.receive(#"{"type":"response.created","response":{"id":"resp_1"}}"#)
        f.conversation.receive(#"{"type":"response.output_audio.delta","response_id":"resp_1","item_id":"item_a1","output_index":0,"content_index":0,"delta":"\#(audio)"}"#)
        #expect(f.audio.playedBytes["item_a1"] == 4800)
        #expect(f.audio.isPlaying)
        f.audio.playedMs["item_a1"] = 640

        f.conversation.receive(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":3000,"item_id":"item_u2"}"#)
        #expect(f.audio.playbackStops == 1)
        #expect(!f.audio.isPlaying)
        let truncate = f.transport.sent("conversation.item.truncate").first
        #expect(truncate?["item_id"] as? String == "item_a1")
        #expect(truncate?["audio_end_ms"] as? Int == 640)
        #expect(truncate?["content_index"] as? Int == 0)
        #expect(f.transport.sent("response.cancel").first?["response_id"] as? String == "resp_1")
        #expect(f.log.events.contains(.speaking(false)))
        #expect(f.log.events.contains(.userSpeechStarted))

        // Audio still in flight from the cancelled response is dropped.
        f.conversation.receive(#"{"type":"input_audio_buffer.speech_stopped","item_id":"item_u2"}"#)
        f.conversation.receive(#"{"type":"response.output_audio.delta","response_id":"resp_1","item_id":"item_a1","output_index":0,"content_index":0,"delta":"\#(audio)"}"#)
        #expect(f.audio.playedBytes["item_a1"] == 4800)
        // The server's cancel race isn't an error.
        f.conversation.receive(#"{"type":"error","error":{"type":"invalid_request_error","code":"response_cancel_not_active","message":"x"}}"#)
        #expect(f.conversation.state == .ready)
    }

    @Test func speechStartWithNothingPlayingSendsNoTruncate() async {
        let f = RealtimeFixture()
        await f.ready()
        f.conversation.receive(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":10,"item_id":"u"}"#)
        #expect(f.transport.frames.isEmpty)
        #expect(f.audio.playbackStops == 0)
    }

    @Test func transcriptsAndCaptions() async {
        let f = RealtimeFixture()
        await f.ready()
        f.conversation.receive(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"u1","delta":"open "}"#)
        f.conversation.receive(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"u1","delta":"notes"}"#)
        f.conversation.receive(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":"open notes"}"#)
        f.conversation.receive(#"{"type":"response.output_audio_transcript.delta","item_id":"a1","delta":"Got "}"#)
        f.conversation.receive(#"{"type":"response.output_audio_transcript.delta","item_id":"a1","delta":"it."}"#)
        #expect(f.log.events.contains(.userTranscript("open notes")))
        #expect(f.log.events.contains(.userTurnEnded("open notes")))
        #expect(f.log.events.last == .assistantCaption("Got it."))
    }

    @Test func connectionFailuresEndWithFallback() async {
        let f = RealtimeFixture()
        f.conversation.start(mayPrompt: false)
        _ = await eventually { f.transport.connected }
        f.conversation.receive(#"{"type":"error","error":{"type":"invalid_request_error","code":"model_not_found","message":"No such model."}}"#)
        #expect(f.log.events.last == .ended(.failed("No such model.", fallback: true)))
        #expect(f.transport.closed)
        #expect(f.audio.stops == 1)

        let g = RealtimeFixture()
        g.conversation.timing.readySeconds = 0.05
        g.conversation.start(mayPrompt: false)
        #expect(await eventually { g.log.events.last == .ended(.failed(RealtimeError.timeout.description, fallback: true)) })

        let h = RealtimeFixture()
        h.audio.authorized = false
        h.conversation.start(mayPrompt: false)
        #expect(await eventually { h.log.events.last == .ended(.failed(OnDeviceRecognizer.micOffMessage, fallback: false)) })
        #expect(!h.transport.connected)
    }

    @Test func closesAfterSilenceUnlessAQuestionIsPending() async {
        let f = RealtimeFixture(idleSeconds: 0.05)
        f.glide.pendingQuestion = AgentQuestion(text: "Which one?")
        await f.ready()
        await settle(150)
        #expect(f.conversation.state == .ready)
        f.glide.pendingQuestion = nil
        #expect(await eventually { f.log.events.last == .ended(.idle) })
        #expect(f.audio.stops == 1)
        #expect(f.transport.closed)
    }
}

// MARK: - Engine choice and the voice session

@Suite("Realtime: engine choice")
struct RealtimeRoutingTests {
    @Test func choosesRealtimeOnlyWhenItCanRun() {
        let now = Date()
        #expect(RealtimeRouting.choose(preference: nil, hasKey: true, lastFailure: nil, now: now) == .realtime)
        #expect(RealtimeRouting.choose(preference: nil, hasKey: false, lastFailure: nil, now: now) == .onDevice(notice: nil))
        #expect(RealtimeRouting.choose(preference: .onDevice, hasKey: true, lastFailure: nil, now: now) == .onDevice(notice: nil))
        if case .onDevice(let notice) = RealtimeRouting.choose(preference: .realtime, hasKey: false, lastFailure: nil, now: now) {
            #expect(notice != nil)
        } else {
            Issue.record("no key must fall back")
        }
        #expect(RealtimeRouting.choose(preference: .realtime, hasKey: true, lastFailure: now.addingTimeInterval(-10), now: now) == .onDevice(notice: nil))
        #expect(RealtimeRouting.choose(preference: .realtime, hasKey: true, lastFailure: now.addingTimeInterval(-120), now: now) == .realtime)
    }

    @MainActor
    @Test func preferencesPersist() {
        let defaults = UserDefaults(suiteName: "glide.tests.realtime.\(UUID().uuidString)")!
        let p = RealtimePreferences(defaults: defaults)
        #expect(p.engine == nil)
        #expect(p.model == "gpt-realtime-2.1-mini")
        #expect(p.effectiveEngine(hasKey: true) == .realtime)
        #expect(p.effectiveEngine(hasKey: false) == .onDevice)
        p.engine = .onDevice
        p.model = "gpt-realtime-2.1"
        let q = RealtimePreferences(defaults: defaults)
        #expect(q.engine == .onDevice)
        #expect(q.model == "gpt-realtime-2.1")
    }
}

@MainActor
@Suite("Realtime: voice session")
struct RealtimeVoiceSessionTests {
    final class Hooks {
        var failures = 0
        var ended: [RealtimeConversation.EndReason] = []
        var turns = 0
        var running = false
    }

    func wire(_ v: VoiceFixture, _ f: RealtimeFixture?, notice: String? = nil) -> Hooks {
        let hooks = Hooks()
        v.session.makeRealtime = { (f?.conversation, f == nil ? notice : nil) }
        v.session.realtimeFailed = { hooks.failures += 1 }
        v.session.onConversationEnded = { hooks.ended.append($0) }
        v.session.onConversationTurn = { hooks.turns += 1 }
        v.session.isTaskRunning = { hooks.running }
        return hooks
    }

    @Test func hotkeyOpensAConversationAndEndsItAgain() async {
        let v = VoiceFixture()
        let f = RealtimeFixture()
        let hooks = wire(v, f)
        v.session.listen()
        #expect(v.session.realtimeActive)
        #expect(v.session.purpose == .request)
        #expect(v.recognizer.starts.isEmpty) // the on-device recognizer stays off
        #expect(await eventually { v.session.micLive })
        v.session.listen() // ⌥Space again
        #expect(!v.session.realtimeActive)
        #expect(v.session.purpose == nil)
        #expect(hooks.ended == [.user])
        #expect(f.transport.closed)
    }

    @Test func notchStatesFollowTheConversation() async {
        let v = VoiceFixture()
        let f = RealtimeFixture()
        let hooks = wire(v, f)
        v.session.listen()
        _ = await eventually { f.transport.connected }
        f.conversation.receive(#"{"type":"session.created","session":{}}"#)
        f.conversation.receive(#"{"type":"input_audio_buffer.speech_started","item_id":"u1"}"#)
        f.conversation.receive(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"u1","delta":"find flights"}"#)
        #expect(v.session.purpose == .request)
        #expect(v.session.partial == "find flights")
        f.conversation.receive(#"{"type":"input_audio_buffer.speech_stopped","item_id":"u1"}"#)
        #expect(hooks.turns == 1)
        #expect(v.session.awaitingReply)
        #expect(v.session.purpose == .bargeIn)
        f.conversation.receive(#"{"type":"response.output_audio_transcript.delta","item_id":"a1","delta":"On it."}"#)
        #expect(v.session.caption == "On it.")
        #expect(!v.session.awaitingReply)

        // Glide asks: the model says it, the speaker stays silent, the question card listens.
        let q = AgentQuestion(id: "q1", text: "Which airport?", options: ["SFO", "OAK"])
        v.session.hear(.question(q))
        #expect(v.session.activeQuestion == q)
        #expect(v.session.purpose == .answer)
        #expect(v.speaker.spoken.isEmpty)
        #expect(f.transport.types.suffix(2) == ["conversation.item.create", "response.create"])
        v.session.clearQuestion(id: "q1")
        hooks.running = true
        v.session.syncRealtimePurpose()
        #expect(v.session.purpose == .bargeIn)
        #expect(!v.session.userInitiated) // no keyboard focus while the agent works
        #expect(v.session.realtimeActive)
    }

    @Test func socketFailureFallsBackToOnDevice() async {
        let v = VoiceFixture()
        let f = RealtimeFixture()
        let hooks = wire(v, f)
        v.session.listen()
        _ = await eventually { f.transport.connected }
        f.transport.drop()
        #expect(await eventually { !v.session.realtimeActive })
        #expect(hooks.failures == 1)
        #expect(v.session.notice == RealtimeRouting.fallbackNotice)
        #expect(v.recognizer.starts.count == 1)
        #expect(v.session.purpose == .request)
    }

    @Test func noRealtimeUsesOnDeviceWithNotice() {
        let v = VoiceFixture()
        _ = wire(v, nil, notice: "Add an OpenAI key for real-time voice. Using on-device voice.")
        v.session.listen()
        #expect(!v.session.realtimeActive)
        #expect(v.recognizer.starts.count == 1)
        #expect(v.session.notice?.hasPrefix("Add an OpenAI key") == true)
        #expect(NotchListeningView.hint(v.session).hasPrefix("Add an OpenAI key"))
    }

    @Test func stopTalkingAndResetEndCleanly() async {
        let v = VoiceFixture()
        let f = RealtimeFixture()
        _ = wire(v, f)
        v.session.listen()
        _ = await eventually { f.transport.connected }
        f.conversation.receive(#"{"type":"session.created","session":{}}"#)
        f.conversation.receive(#"{"type":"response.created","response":{"id":"r1"}}"#)
        f.conversation.receive(#"{"type":"response.output_audio.delta","response_id":"r1","item_id":"a1","content_index":0,"output_index":0,"delta":"AAAA"}"#)
        v.session.stopSpeaking()
        #expect(f.audio.playbackStops == 1)
        #expect(f.transport.sent("response.cancel").count == 1)
        v.session.reset()
        #expect(!v.session.realtimeActive)
        #expect(f.audio.stops == 1)
    }
}
