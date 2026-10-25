import Testing
import Foundation
import AVFoundation
@testable import GlideApp
@testable import AgentKit
import AutomationKit

// Offline tests for Glide's voice layer. No microphone, no audio output, no network beyond an
// in-process URLProtocol stub, and no paid API: recognizers, speakers and players are fakes.

// MARK: - Fakes

@MainActor
final class FakeRecognizer: VoiceRecognizer {
    var onEvent: ((ListenEvent) -> Void)?
    private(set) var starts: [ListenRequest] = []
    private(set) var stops = 0
    var isOpen = false

    func start(_ request: ListenRequest) {
        starts.append(request)
        isOpen = true
    }

    func stop() {
        stops += 1
        isOpen = false
    }

    func emit(_ event: ListenEvent) { onEvent?(event) }
}

@MainActor
final class FakeSpeaker: VoiceSpeaker {
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var onStart: (@MainActor (Bool) -> Void)?

    var isSpeaking: Bool { waiter != nil }

    func speak(_ text: String, onAudioStart: @escaping @MainActor (Bool) -> Void) async {
        spoken.append(text)
        onStart = onAudioStart
        await withCheckedContinuation { waiter = $0 }
    }

    /// The first audio plays.
    func startAudio(echoCancelled: Bool) { onStart?(echoCancelled) }

    /// The line has been said.
    func finish() {
        waiter?.resume()
        waiter = nil
    }

    func stop() {
        stops += 1
        finish()
    }
}

/// Lets queued main-actor tasks (the speaker's) run.
@MainActor
func settle(_ ms: Int = 20) async {
    try? await Task.sleep(for: .milliseconds(ms))
}

/// Waits (up to 3 s, for a loaded machine) until `condition` holds.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
struct VoiceFixture {
    let recognizer = FakeRecognizer()
    let speaker = FakeSpeaker()
    let session: VoiceSession
    final class Log {
        var utterances: [(String, UtteranceSource)] = []
        var typing: [String] = []
        var settings = VoiceSettings()
        var mic = true
    }
    let log = Log()

    init() {
        let log = self.log
        session = VoiceSession(recognizer: recognizer, speaker: speaker, settings: { log.settings }, micAuthorized: { log.mic })
        session.onUtterance = { log.utterances.append(($0, $1)) }
        session.onTypingRequested = { log.typing.append($0) }
        session.timing.captionLinger = 0.05
        session.timing.silentCaption = 0.05
    }

    /// The user says something by voice (so the conversation is in voice).
    func say(_ text: String) {
        session.listen()
        recognizer.emit(.started)
        recognizer.emit(.partial(text))
        recognizer.emit(.finished(text))
    }
}

// MARK: - Speak modes

@Suite("Glide voice: what is spoken")
struct GlideSpeakModeTests {
    static let cues: [SpeechCue] = [.ack("On it."), .progress("Still going."), .question(AgentQuestion(text: "Which?")),
                                    .result("Done."), .needsYou("Please sign in."), .error("That didn't work.")]

    func spoken(_ mode: SpeakMode) -> [SpeechPolicy.Kind] {
        Self.cues.filter { SpeechPolicy.shouldSpeak($0, mode: mode) }.map(SpeechPolicy.kind(of:))
    }

    @Test func everythingSpeaksAll() {
        #expect(spoken(.everything) == [.ack, .progress, .question, .result, .needsYou, .error])
    }

    @Test func questionsAndResultsSkipsProgress() {
        #expect(spoken(.questionsAndResults) == [.ack, .question, .result, .needsYou, .error])
    }

    @Test func questionsOnly() {
        #expect(spoken(.questionsOnly) == [.question, .needsYou])
    }

    @Test func neverSpeaks() {
        #expect(spoken(.never).isEmpty)
    }

    @Test func questionsUseTheirShortSpokenForm() {
        let q = AgentQuestion(text: "Which socks would you like: athletic crew, no-show, wool or dress?", spoken: "Which socks?")
        #expect(SpeechPolicy.spokenText(.question(q)) == "Which socks?")
        #expect(SpeechPolicy.shownText(.question(q)) == q.text)
    }

    @Test @MainActor func unspokenCuesStillShow() async {
        let f = VoiceFixture()
        f.log.settings.speakMode = .questionsOnly
        f.session.hear(.ack("Opening ChatGPT."))
        await settle()
        #expect(f.speaker.spoken.isEmpty)
        #expect(f.session.caption == "Opening ChatGPT.")
        f.session.hear(.question(AgentQuestion(text: "Anything there?")))
        await settle()
        #expect(f.speaker.spoken == ["Anything there?"])
    }
}

// MARK: - End of speech

@Suite("Glide voice: end of speech")
struct GlideEndOfSpeechTests {
    static let rate = 16_000.0

    /// Synthetic microphone audio: low noise, then a voiced tone, then noise again.
    static func buffer(seconds: Double, amplitude: Float, tone: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let n = AVAudioFrameCount(seconds * rate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        b.frameLength = n
        let p = b.floatChannelData![0]
        var seed: UInt32 = 12345
        for i in 0..<Int(n) {
            seed = seed &* 1_103_515_245 &+ 12345
            let noise = (Float(seed >> 16 & 0x7FFF) / 32768 - 0.5) * 0.002
            p[i] = noise + (tone ? amplitude * sin(Float(i) * 2 * .pi * 220 / Float(rate)) : 0)
        }
        return b
    }

    /// Feeds 20 ms frames; returns each event with the time it fired.
    static func run(_ detector: inout EndOfSpeechDetector, _ segments: [(Double, Bool)], settleAfterSpeech: Bool) -> [(EndOfSpeechDetector.Event, Double)] {
        var events: [(EndOfSpeechDetector.Event, Double)] = []
        var t = 0.0
        for (seconds, voiced) in segments {
            let frames = Int((seconds / 0.02).rounded())
            for _ in 0..<frames {
                let frame = buffer(seconds: 0.02, amplitude: 0.2, tone: voiced)
                t += 0.02
                if let e = detector.process(levelDB: EndOfSpeechDetector.levelDB(frame), duration: 0.02) { events.append((e, t)) }
                if settleAfterSpeech && detector.heardSpeech && !voiced { detector.transcriptSettled = true }
            }
        }
        return events
    }

    @Test func endsAboutPointEightSecondsAfterSpeechOnceSettled() {
        var d = EndOfSpeechDetector()
        let events = Self.run(&d, [(0.5, false), (1.0, true), (2.0, false)], settleAfterSpeech: true)
        #expect(events.map(\.0) == [.speechStarted, .endOfSpeech])
        let start = events[0].1, end = events[1].1
        #expect(start > 0.5 && start < 0.8)
        #expect(abs(end - (1.5 + 0.8)) < 0.07)
    }

    @Test func waitsLongerWhileTheTranscriptIsUnsettled() {
        var d = EndOfSpeechDetector()
        let events = Self.run(&d, [(0.4, false), (0.8, true), (3.0, false)], settleAfterSpeech: false)
        #expect(events.map(\.0) == [.speechStarted, .endOfSpeech])
        #expect(abs(events[1].1 - (1.2 + 0.8 + 0.9)) < 0.07)
    }

    @Test func briefPausesDoNotEndTheUtterance() {
        var d = EndOfSpeechDetector()
        let events = Self.run(&d, [(0.3, false), (0.6, true), (0.4, false), (0.6, true), (1.2, false)], settleAfterSpeech: true)
        #expect(events.map(\.0) == [.speechStarted, .endOfSpeech])
        #expect(events[1].1 > 1.9 + 0.75)
    }

    @Test func silenceTimesOut() {
        var config = EndOfSpeechDetector.Config()
        config.noSpeechTimeout = 1.0
        var d = EndOfSpeechDetector(config: config)
        let events = Self.run(&d, [(2.0, false)], settleAfterSpeech: false)
        #expect(events.map(\.0) == [.noSpeech])
        #expect(abs(events[0].1 - 1.0) < 0.03)
    }

    @Test func aClickIsNotSpeech() {
        var config = EndOfSpeechDetector.Config()
        config.noSpeechTimeout = 1.0
        var d = EndOfSpeechDetector(config: config)
        let events = Self.run(&d, [(0.3, false), (0.04, true), (1.0, false)], settleAfterSpeech: false)
        #expect(events.map(\.0) == [.noSpeech])
    }

    @Test func utterancesAreCapped() {
        var config = EndOfSpeechDetector.Config()
        config.maxUtterance = 2
        var d = EndOfSpeechDetector(config: config)
        let events = Self.run(&d, [(3.0, true)], settleAfterSpeech: false)
        #expect(events.map(\.0) == [.speechStarted, .maxLength])
        #expect(abs(events[1].1 - 2.0) < 0.03)
    }

    @Test func levelsOfSyntheticBuffers() {
        let quiet = EndOfSpeechDetector.levelDB(Self.buffer(seconds: 0.02, amplitude: 0, tone: false))
        let loud = EndOfSpeechDetector.levelDB(Self.buffer(seconds: 0.02, amplitude: 0.2, tone: true))
        #expect(quiet < -60)
        #expect(loud > -20 && loud < -15) // 0.2 sine ≈ -17 dBFS
        #expect(EndOfSpeechDetector.displayLevel(db: -80) == 0)
        #expect(EndOfSpeechDetector.displayLevel(db: 0) == 1)
    }
}

// MARK: - Listening and speaking

@Suite("Glide voice: turn-taking")
@MainActor
struct GlideTurnTakingTests {
    @Test func aFinishedUtteranceGoesToTheController() {
        let f = VoiceFixture()
        f.session.listen()
        #expect(f.recognizer.starts.last == ListenRequest(noSpeechTimeout: 8, echoCancellation: false, mayPrompt: true))
        #expect(f.session.purpose == .request)
        f.recognizer.emit(.started)
        f.recognizer.emit(.partial("open chat"))
        #expect(f.session.transcript == "open chat")
        f.recognizer.emit(.finished("open chat gpt"))
        #expect(f.log.utterances.map(\.0) == ["open chat gpt"])
        #expect(f.log.utterances.first?.1 == .voice)
        #expect(f.session.purpose == nil)
        #expect(!f.recognizer.isOpen)
        #expect(f.session.awaitingReply)
        #expect(f.session.conversationIsVoice)
    }

    @Test func dictationContinuesTypedText() {
        let f = VoiceFixture()
        f.session.listen(prefix: "add socks")
        f.recognizer.emit(.finished("to my amazon cart"))
        #expect(f.log.utterances.map(\.0) == ["add socks to my amazon cart"])
    }

    @Test func nothingSaidFallsBackToTyping() {
        let f = VoiceFixture()
        f.session.listen()
        f.recognizer.emit(.noSpeech)
        #expect(f.log.typing == [""])
        #expect(f.log.utterances.isEmpty)
        #expect(f.session.purpose == nil)
    }

    @Test func noMicrophoneShowsWhyAndOffersTyping() {
        let f = VoiceFixture()
        f.session.listen()
        f.recognizer.emit(.failed(OnDeviceRecognizer.micOffMessage))
        #expect(f.session.notice == OnDeviceRecognizer.micOffMessage)
        #expect(f.log.typing == [""])
    }

    @Test func returnSendsWhatWasHeardSoFar() {
        let f = VoiceFixture()
        f.session.listen()
        f.recognizer.emit(.partial("open notes"))
        f.session.finishNow()
        #expect(f.log.utterances.map(\.0) == ["open notes"])
        #expect(!f.recognizer.isOpen)
    }

    @Test func listensForTheAnswerAfterAQuestion() async {
        let f = VoiceFixture()
        let q = AgentQuestion(text: "Which socks would you like?", spoken: "Which socks?", options: ["Crew", "Wool"])
        f.session.hear(.question(q))
        await settle()
        #expect(f.speaker.spoken == ["Which socks?"])
        #expect(f.session.activeQuestion == q)
        // Typed conversation: the mic stays closed while the question is spoken.
        #expect(f.recognizer.starts.isEmpty)
        f.speaker.finish()
        await settle()
        // The answer window opens without a tap, echo-cancelled, never prompting.
        #expect(f.session.purpose == .answer)
        #expect(f.recognizer.starts.last == ListenRequest(noSpeechTimeout: nil, echoCancellation: true, mayPrompt: false))
        f.recognizer.emit(.started)
        f.recognizer.emit(.partial("the wool ones"))
        f.recognizer.emit(.finished("the wool ones"))
        #expect(f.log.utterances.map(\.0) == ["the wool ones"])
        #expect(f.session.activeQuestion == nil)
    }

    @Test func theAnswerWindowCloses() async {
        let f = VoiceFixture()
        f.log.settings.listenForAnswerSeconds = 0.05
        f.session.hear(.question(AgentQuestion(text: "Anything else?")))
        await settle()
        f.speaker.finish()
        await settle(5)
        #expect(f.session.purpose == .answer)
        #expect(await eventually { f.session.purpose == nil })
        #expect(!f.recognizer.isOpen)
        // The question stays on show for a chip or a typed answer.
        #expect(f.session.activeQuestion != nil)
    }

    @Test func noAnswerWindowWithoutMicrophoneAccessOrWhenOff() async {
        let f = VoiceFixture()
        f.log.mic = false
        f.session.hear(.question(AgentQuestion(text: "Anything else?")))
        await settle()
        f.speaker.finish()
        await settle()
        #expect(f.recognizer.starts.isEmpty)

        let g = VoiceFixture()
        g.log.settings.listenForAnswerSeconds = 0
        g.session.hear(.question(AgentQuestion(text: "Anything else?")))
        await settle()
        g.speaker.finish()
        await settle()
        #expect(g.recognizer.starts.isEmpty)
    }

    @Test func bargeInStopsSpeakingAndTakesTheUtterance() async {
        let f = VoiceFixture()
        f.say("add socks on amazon")
        f.session.hear(.ack("On it — opening Amazon."))
        f.session.hear(.result("Added Hanes crew socks to your cart."))
        await settle()
        // In a voice conversation the mic opens with the line, echo-cancelled.
        #expect(f.recognizer.starts.last == ListenRequest(noSpeechTimeout: nil, echoCancellation: true, mayPrompt: false))
        #expect(f.session.purpose == .bargeIn)
        f.recognizer.emit(.started)
        f.speaker.startAudio(echoCancelled: true)
        #expect(f.session.isSpeaking)
        f.recognizer.emit(.partial("wait"))
        #expect(f.speaker.stops == 1)
        await settle()
        // The queued result was dropped; Glide is quiet and listening.
        #expect(f.speaker.spoken == ["On it — opening Amazon."])
        #expect(!f.session.isSpeaking)
        #expect(f.session.purpose == .bargeIn)
        f.recognizer.emit(.finished("wait, make it wool"))
        #expect(f.log.utterances.map(\.0) == ["add socks on amazon", "wait, make it wool"])
        await settle()
        #expect(f.speaker.spoken.count == 1)
    }

    @Test func noBargeInWhenPlaybackIsNotEchoCancelled() async {
        let f = VoiceFixture()
        f.say("open chat gpt")
        f.session.hear(.ack("Opening ChatGPT."))
        await settle()
        #expect(f.session.purpose == .bargeIn)
        f.speaker.startAudio(echoCancelled: false)
        // The microphone would hear Glide itself, so it closes for this line.
        #expect(f.session.purpose == nil)
        #expect(!f.recognizer.isOpen)
        f.speaker.finish()
        await settle()
        #expect(f.speaker.spoken == ["Opening ChatGPT."])
    }

    @Test func micClosesAfterALineNobodyInterrupted() async {
        let f = VoiceFixture()
        f.say("open chat gpt")
        f.session.hear(.ack("Opening ChatGPT."))
        await settle()
        f.recognizer.emit(.started)
        f.speaker.startAudio(echoCancelled: true)
        f.speaker.finish()
        await settle()
        #expect(f.session.purpose == nil)
        #expect(!f.recognizer.isOpen)
    }

    @Test func linesWaitWhileTheUserIsTalking() async {
        let f = VoiceFixture()
        f.session.listen()
        f.recognizer.emit(.partial("add"))
        f.session.hear(.progress("Still checking out."))
        f.session.hear(.result("Done."))
        await settle()
        #expect(f.speaker.spoken.isEmpty)
        f.recognizer.emit(.finished("add two more"))
        await settle()
        #expect(f.speaker.spoken == ["Done."])
    }

    @Test func typingMovesTheConversationToTheKeyboard() async {
        let f = VoiceFixture()
        f.say("open notes")
        f.session.noteTyped()
        #expect(!f.session.conversationIsVoice)
        f.session.hear(.ack("Opening Notes."))
        await settle()
        #expect(f.speaker.spoken == ["Opening Notes."])
        #expect(f.recognizer.starts.count == 1) // only the spoken request
    }

    @Test func closingStopsEverythingAndNoAnswerWindowFollows() async {
        let f = VoiceFixture()
        f.session.hear(.question(AgentQuestion(text: "Which one?")))
        await settle()
        f.session.reset()
        await settle()
        #expect(f.speaker.stops == 1)
        #expect(f.recognizer.starts.isEmpty)
        #expect(f.session.purpose == nil)
    }
}

// MARK: - The notch

@Suite("Glide voice: notch states")
@MainActor
struct GlideVoiceNotchTests {
    @MainActor struct Fixture {
        let voice: VoiceFixture
        let notch: NotchFixture
        let model: NotchModel

        init() throws {
            voice = VoiceFixture()
            let base = try NotchFixture()
            notch = base
            model = NotchModel(controller: base.controller, settings: base.store, jobs: base.jobs, voice: voice.session)
            model.currentEventIsAgent = { false }
            model.agentPointerIdleSeconds = { .infinity }
        }
    }

    @Test func openingListensAndTypingSwitchesToTheField() throws {
        let f = try Fixture()
        defer { f.notch.cleanup() }
        f.model.open()
        #expect(f.model.presentation == .listening)
        #expect(f.model.wantsKey)
        f.voice.recognizer.emit(.started)
        f.voice.recognizer.emit(.partial("add socks"))
        f.model.switchToTyping(typed: "x")
        #expect(f.model.presentation == .input)
        #expect(f.model.inputText == "add socks x")
        #expect(!f.voice.recognizer.isOpen)
        f.model.close()
        #expect(f.model.presentation == .idle)
    }

    @Test func openingWithListeningOffShowsTheField() throws {
        let f = try Fixture()
        defer { f.notch.cleanup() }
        f.notch.store.settings.voice.listenOnOpen = false
        f.model.open()
        #expect(f.model.presentation == .input)
        #expect(f.voice.recognizer.starts.isEmpty)
    }

    @Test func hotkeyAgainCancelsListening() throws {
        let f = try Fixture()
        defer { f.notch.cleanup() }
        f.model.toggle()
        #expect(f.model.presentation == .listening)
        f.model.toggle()
        #expect(f.model.presentation == .idle)
        #expect(!f.voice.recognizer.isOpen)
    }

    @Test func aQuestionShowsWithoutTakingFocus() async throws {
        let f = try Fixture()
        defer { f.notch.cleanup() }
        let q = AgentQuestion(text: "Want me to do anything in ChatGPT?", options: ["Ask it something", "No thanks"])
        f.model.hear(.question(q))
        #expect(f.model.presentation == .question)
        #expect(f.model.shownQuestion == q)
        // The agent may be typing into the app underneath.
        #expect(!f.model.wantsKey)
        f.voice.speaker.finish()
        await settle()
        #expect(f.model.presentation == .question) // the answer shows in the card
        f.model.answerQuestion(q, with: "No thanks")
        #expect(f.model.shownQuestion == nil)
        #expect(f.voice.session.purpose == nil)
    }

    @Test func agentClicksOnChipsAreDropped() throws {
        let f = try Fixture()
        defer { f.notch.cleanup() }
        let q = AgentQuestion(text: "Which?", options: ["A", "B"])
        f.model.hear(.question(q))
        f.model.currentEventIsAgent = { true }
        f.model.answerQuestion(q, with: "A")
        #expect(f.model.shownQuestion == q)
    }

    @Test func spokenLinesShowAsACaption() async throws {
        let f = try Fixture()
        defer { f.notch.cleanup() }
        f.model.hear(.ack("Opening ChatGPT."))
        #expect(f.model.presentation == .speaking)
        await settle()
        f.voice.speaker.startAudio(echoCancelled: false)
        #expect(f.voice.session.isSpeaking)
        f.voice.speaker.finish()
        #expect(await eventually { f.model.presentation == .idle })
    }

    @Test func closingHidesTheQuestionUntilAsked() throws {
        let f = try Fixture()
        defer { f.notch.cleanup() }
        let q = AgentQuestion(text: "Which?")
        f.model.hear(.question(q))
        f.model.close()
        #expect(f.model.presentation == .idle)
        f.model.hear(.question(q))
        #expect(f.model.presentation == .question)
    }
}

// MARK: - OpenAI speech

/// Serves canned responses in-process; nothing reaches the network.
final class SpeechStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: [Data]
    }
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func reset(_ replies: [String: Reply]) {
        lock.withLock {
            Self.replies = replies
            Self.requests = []
        }
    }

    static var seen: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            req.httpBody = data
        }
        let path = request.url?.path ?? ""
        let reply = Self.lock.withLock {
            Self.requests.append(req)
            return Self.replies[path]
        } ?? Reply(status: 404, body: [Data("{\"error\":{\"message\":\"not found\"}}".utf8)])
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for part in reply.body { client?.urlProtocol(self, didLoad: part) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [SpeechStubProtocol.self]
        return URLSession(configuration: c)
    }
}

@Suite("Glide voice: OpenAI speech", .serialized)
struct GlideOpenAISpeechTests {
    static let base = "http://localhost:9/v1"
    static let models = ["gpt-6-luna", "tts-1", "tts-1-hd", "gpt-4o-mini-tts", "gpt-4o-mini-tts-2025-03-20", "whisper-1",
                         "gpt-4o-transcribe", "gpt-realtime", "text-embedding-3-small"]

    @Test func picksTheBestSpeechModel() {
        #expect(OpenAISpeech.bestModel(from: Self.models) == "gpt-4o-mini-tts")
        #expect(OpenAISpeech.bestModel(from: Self.models + ["gpt-5-mini-tts", "gpt-5-tts"]) == "gpt-5-tts")
        #expect(OpenAISpeech.bestModel(from: ["tts-1", "tts-1-hd", "tts-1-1106"]) == "tts-1-hd")
        #expect(OpenAISpeech.bestModel(from: ["tts-1-1106", "tts-1"]) == "tts-1")
        #expect(OpenAISpeech.bestModel(from: ["gpt-4o-mini-tts-2025-03-20", "gpt-4o-mini-tts-2025-12-15"]) == "gpt-4o-mini-tts-2025-12-15")
        #expect(OpenAISpeech.bestModel(from: ["gpt-6-luna", "whisper-1"]) == nil)
    }

    @Test func buildsAStreamingPCMRequest() throws {
        let req = try OpenAISpeech.speechRequest(baseURL: Self.base + "/", apiKey: "sk-test", model: "gpt-4o-mini-tts", voice: "coral", text: "Opening ChatGPT.")
        #expect(req.url?.absoluteString == "http://localhost:9/v1/audio/speech")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String])
        #expect(body["model"] == "gpt-4o-mini-tts")
        #expect(body["input"] == "Opening ChatGPT.")
        #expect(body["voice"] == "coral")
        #expect(body["response_format"] == "pcm")
        #expect(body["instructions"] != nil)
        // tts-1 doesn't take speaking instructions.
        let classic = try OpenAISpeech.speechRequest(baseURL: Self.base, apiKey: "k", model: "tts-1", voice: "nova", text: "Hi")
        let classicBody = try #require(try JSONSerialization.jsonObject(with: classic.httpBody ?? Data()) as? [String: String])
        #expect(classicBody["instructions"] == nil)
        #expect(throws: SpeechClientError.badURL) { try OpenAISpeech.speechRequest(baseURL: "not a url", apiKey: "", model: "m", voice: "v", text: "t") }
    }

    @Test func routesThroughTheUsersOpenAIProvider() {
        var s = AppSettings()
        #expect(OpenAISpeech.route(s, key: { _ in nil }) == nil)
        let r = OpenAISpeech.route(s, key: { $0 == "openai" ? "sk-live" : nil })
        #expect(r?.baseURL == "https://api.openai.com/v1")
        #expect(r?.apiKey == "sk-live")
        s.providers[1].enabled = false
        #expect(OpenAISpeech.route(s, key: { _ in "sk" }) == nil)
    }

    @Test func decodesLittleEndianPCMAcrossSplitPackets() {
        var carry: UInt8?
        // 0x4000 = 16384 → 0.5; 0xC000 = -16384 → -0.5, split mid-sample.
        let a = OpenAISpeech.decodePCM16([0x00, 0x40, 0x00], carry: &carry)
        #expect(a == [0.5])
        #expect(carry == 0x00)
        let b = OpenAISpeech.decodePCM16([0xC0], carry: &carry)
        #expect(b == [-0.5])
        #expect(carry == nil)
    }

    @Test func listsModelsAndStreamsAudioFromALocalStub() async throws {
        let models = try JSONSerialization.data(withJSONObject: ["data": Self.models.map { ["id": $0] }])
        // 0.1 s of 24 kHz audio in uneven packets.
        let pcm = Data((0..<2400).flatMap { i -> [UInt8] in
            let v = Int16(truncatingIfNeeded: (i % 100) * 300)
            return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]
        })
        SpeechStubProtocol.reset([
            "/v1/models": .init(status: 200, body: [models]),
            "/v1/audio/speech": .init(status: 200, body: [pcm.prefix(1001), pcm.dropFirst(1001)]),
        ])
        let client = OpenAISpeechClient(session: SpeechStubProtocol.session())
        let ids = try await client.listModels(baseURL: Self.base, apiKey: "sk-test")
        #expect(OpenAISpeech.bestModel(from: ids) == "gpt-4o-mini-tts")
        var samples: [Float] = []
        var chunks = 0
        for try await chunk in client.stream(baseURL: Self.base, apiKey: "sk-test", model: "gpt-4o-mini-tts", voice: "coral", text: "Hi there") {
            #expect(chunk.sampleRate == 24_000)
            samples += chunk.samples
            chunks += 1
        }
        #expect(samples.count == 2400)
        #expect(chunks >= 2) // the first piece goes out early
        #expect(samples[1] == Float(300) / 32768)
        let speech = try #require(SpeechStubProtocol.seen.last)
        #expect(speech.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test func errorsNeverEchoTheKey() async throws {
        SpeechStubProtocol.reset(["/v1/audio/speech": .init(status: 401, body: [Data("{\"error\":{\"message\":\"Incorrect API key provided: sk-secret-123.\"}}".utf8)])])
        let client = OpenAISpeechClient(session: SpeechStubProtocol.session())
        do {
            for try await _ in client.stream(baseURL: Self.base, apiKey: "sk-secret-123", model: "tts-1", voice: "nova", text: "Hi") {}
            Issue.record("expected an error")
        } catch let SpeechClientError.http(code, message) {
            #expect(code == 401)
            #expect(!message.contains("sk-secret-123"))
        }
    }
}

// MARK: - Choosing a voice

@MainActor
final class FakeOpenAI: OpenAISpeechStreaming, @unchecked Sendable {
    var models = GlideOpenAISpeechTests.models
    var fail = false
    private(set) var listCalls = 0
    private(set) var streamed: [(model: String, voice: String, text: String)] = []

    nonisolated func listModels(baseURL: String, apiKey: String) async throws -> [String] {
        await MainActor.run {
            listCalls += 1
            return models
        }
    }

    nonisolated func stream(baseURL: String, apiKey: String, model: String, voice: String, text: String) -> AsyncThrowingStream<PCMChunk, any Error> {
        let (s, c) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        MainActor.assumeIsolated {
            streamed.append((model, voice, text))
            if fail {
                c.finish(throwing: URLError(.notConnectedToInternet))
            } else {
                c.yield(PCMChunk(samples: [0.1, 0.2], sampleRate: 24_000))
                c.finish()
            }
        }
        return s
    }
}

@MainActor
final class FakeApple: AppleSpeechStreaming {
    private(set) var spoken: [(String, String?, Double)] = []
    func stream(_ text: String, voiceID: String?, speakingRate: Double) -> AsyncThrowingStream<PCMChunk, any Error> {
        spoken.append((text, voiceID, speakingRate))
        let (s, c) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        c.yield(PCMChunk(samples: [0.3], sampleRate: 22_050))
        c.finish()
        return s
    }
    func stop() {}
}

/// Drains streams instead of playing them.
@MainActor
final class FakePlayer: PCMPlaying {
    private(set) var played: [[PCMChunk]] = []
    private(set) var rates: [Double] = []
    func play(_ chunks: AsyncThrowingStream<PCMChunk, any Error>, rate: Double, onStart: @escaping @MainActor (Bool) -> Void) async throws {
        var got: [PCMChunk] = []
        do {
            for try await c in chunks { got.append(c) }
        } catch {
            if got.isEmpty { throw PlaybackError.noAudio(String(describing: error)) }
        }
        guard !got.isEmpty else { throw PlaybackError.noAudio("empty") }
        onStart(false)
        played.append(got)
        rates.append(rate)
    }
    func stop() {}
}

@Suite("Glide voice: speaker and fallback")
@MainActor
struct GlideSpeakerTests {
    @MainActor struct Fixture {
        let openAI = FakeOpenAI()
        let apple = FakeApple()
        let player = FakePlayer()
        let speaker: GlideSpeaker
        final class Box { var settings = AppSettings(); var key: String? = "sk-test" }
        let box = Box()

        init() {
            let box = self.box
            speaker = GlideSpeaker(settings: { box.settings }, key: { $0 == "openai" ? box.key : nil }, openAI: openAI, apple: apple, player: player)
        }
    }

    @Test func naturalVoiceWithTheBestModelListedOnce() async {
        let f = Fixture()
        f.box.settings.voice.speakingRate = 1.2
        await f.speaker.speak("Opening ChatGPT.") { _ in }
        await f.speaker.speak("Which socks?") { _ in }
        #expect(f.openAI.listCalls == 1)
        #expect(f.openAI.streamed.map(\.model) == ["gpt-4o-mini-tts", "gpt-4o-mini-tts"])
        #expect(f.openAI.streamed.first?.voice == "coral")
        #expect(f.speaker.lastEngine == .openAI)
        #expect(f.apple.spoken.isEmpty)
        #expect(f.player.rates == [1.2, 1.2])
    }

    @Test func aConfiguredModelAndVoiceSkipTheList() async {
        let f = Fixture()
        f.box.settings.voice.openAIModel = "tts-1-hd"
        f.box.settings.voice.openAIVoice = "marin" // not a tts-1 voice
        await f.speaker.speak("Hi") { _ in }
        #expect(f.openAI.listCalls == 0)
        #expect(f.openAI.streamed.first?.model == "tts-1-hd")
        #expect(f.openAI.streamed.first?.voice == "nova")
    }

    @Test func repeatedShortPhrasesComeFromMemory() async {
        let f = Fixture()
        await f.speaker.speak("On it.") { _ in }
        await settle()
        await f.speaker.speak("On it.") { _ in }
        #expect(f.openAI.streamed.count == 1)
        #expect(f.player.played.count == 2)
        #expect(f.speaker.cache.count == 1)
    }

    @Test func fallsBackToAppleOnErrorAndRests() async {
        let f = Fixture()
        f.openAI.fail = true
        f.box.settings.voice.appleVoiceID = "com.apple.voice.premium.en-US.Zoe"
        await f.speaker.speak("Opening Amazon.") { _ in }
        #expect(f.speaker.lastEngine == .apple)
        #expect(f.apple.spoken.first?.0 == "Opening Amazon.")
        #expect(f.apple.spoken.first?.1 == "com.apple.voice.premium.en-US.Zoe")
        // Offline: the next line goes straight to Apple's voice.
        await f.speaker.speak("Still here.") { _ in }
        #expect(f.openAI.streamed.count == 1)
        #expect(f.apple.spoken.count == 2)
    }

    @Test func appleWithoutAKeyOrWhenChosen() async {
        let f = Fixture()
        f.box.key = nil
        await f.speaker.speak("Hello") { _ in }
        #expect(f.openAI.streamed.isEmpty)
        #expect(f.speaker.lastEngine == .apple)

        let g = Fixture()
        g.box.settings.voice.engine = .apple
        await g.speaker.speak("Hello") { _ in }
        #expect(g.openAI.streamed.isEmpty)
        #expect(g.apple.spoken.count == 1)
    }

    @Test func bestAppleVoice() {
        let voices = [
            AppleVoiceOption(id: "a", name: "Albert", language: "en-US", quality: .standard, isNovelty: true),
            AppleVoiceOption(id: "s", name: "Samantha", language: "en-US", quality: .standard),
            AppleVoiceOption(id: "d", name: "Daniel", language: "en-GB", quality: .enhanced),
            AppleVoiceOption(id: "z", name: "Zoe", language: "en-US", quality: .enhanced),
            AppleVoiceOption(id: "p", name: "Me", language: "en-US", quality: .premium, isPersonal: true),
            AppleVoiceOption(id: "t", name: "Thomas", language: "fr-FR", quality: .premium),
        ]
        #expect(AppleVoices.best(for: "en-US", among: voices)?.id == "z")
        #expect(AppleVoices.best(for: "en-GB", among: voices)?.id == "d")
        #expect(AppleVoices.best(for: "fr-CA", among: voices)?.id == "t")
        #expect(AppleVoices.best(for: "de-DE", among: voices) == nil)
        #expect(AppleVoices.options(for: "en-US", among: voices).map(\.id) == ["z", "d", "s"])
    }
}

// MARK: - On-device transcription

@Suite("Glide voice: on-device transcription")
struct GlideTranscriptionTests {
    /// Speaks "open chat gpt" into an AIFF with `say` and transcribes it on device. Skipped
    /// (passes without checking) when the transcriber's English assets aren't installed;
    /// nothing is downloaded.
    @Test func transcribesSpeechFromAFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glide-voice-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "open chat gpt"]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { return }
        guard let text = try await OnDeviceRecognizer.transcribe(file: url) else {
            print("skipped: on-device transcriber assets for en-US aren't installed")
            return
        }
        let normalized = text.lowercased().filter { $0.isLetter || $0 == " " }
        #expect(normalized.contains("open"))
        #expect(normalized.replacingOccurrences(of: " ", with: "").contains("chatgpt"))
    }
}
