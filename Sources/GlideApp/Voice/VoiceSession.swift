import Foundation
import Observation
import AgentKit

/// One listen: how long to wait for speech, and whether Glide may be talking at the same time.
struct ListenRequest: Equatable, Sendable {
    /// Nothing said within this long ends listening (nil: listen until stopped).
    var noSpeechTimeout: Double?
    /// Use the voice-processing input (echo cancellation), because Glide may speak while the
    /// microphone is open. Off for a plain listen so the user's music isn't ducked.
    var echoCancellation: Bool
    var maxUtterance: Double = 30
    /// The user asked to listen (hotkey, mic button), so macOS may show its permission prompt.
    /// Listens Glide opens on its own (after a question, for barge-in) never prompt.
    var mayPrompt: Bool
}

/// What the recognizer reports while it listens.
enum ListenEvent: Equatable, Sendable {
    /// On-device speech assets are being installed (the first time only); fraction when known.
    case preparing(Double?)
    /// The microphone is open.
    case started
    /// Input level, 0…1, for the waveform.
    case level(Float)
    case speechStarted
    /// The live transcript so far.
    case partial(String)
    /// End of speech was detected; the final transcript.
    case finished(String)
    case noSpeech
    case failed(String)
}

/// Hears one utterance at a time. The real one is `OnDeviceRecognizer`; tests use a fake.
@MainActor
protocol VoiceRecognizer: AnyObject {
    /// Events for the current listen. Never called after `stop()`.
    var onEvent: ((ListenEvent) -> Void)? { get set }
    func start(_ request: ListenRequest)
    /// Closes the microphone at once and drops anything not yet delivered.
    func stop()
}

/// Says one line at a time. The real one is `GlideSpeaker`; tests use a fake.
@MainActor
protocol VoiceSpeaker: AnyObject {
    /// Speaks `text`, returning once it has been said or `stop()` was called. `onAudioStart`
    /// runs when the first audio plays, saying whether it plays through the echo-cancelled
    /// listening engine (so the microphone won't hear Glide itself).
    func speak(_ text: String, onAudioStart: @escaping @MainActor (Bool) -> Void) async
    func stop()
}

/// The voice conversation: listening, speaking and turn-taking, independent of any window.
///
/// - Listening: a listen ends on its own when the user stops talking; the transcript goes to
///   `onUtterance` (then `TaskController.handleUtterance`).
/// - Speaking: cues from `TaskController.onSpeech` are shown as a caption (or a question card)
///   and spoken per `VoiceSettings.speakMode`, one line at a time.
/// - Turn-taking: after a question it listens for the answer without a tap; in a voice
///   conversation it listens while speaking, through echo cancellation, and stops talking the
///   moment the user does (barge-in), taking what they say as the next utterance.
@MainActor
@Observable
final class VoiceSession {
    enum Purpose: Equatable, Sendable {
        /// The user asked to talk (hotkey, mic button).
        case request
        /// Waiting for the answer to the question Glide just asked.
        case answer
        /// Open while Glide speaks, so the user can interrupt.
        case bargeIn
    }

    /// Non-nil while the microphone is (being) opened.
    private(set) var purpose: Purpose?
    /// The recognizer reported the microphone open.
    private(set) var micLive = false
    /// The current listen was asked for by the user.
    private(set) var userInitiated = false
    /// Installing on-device speech assets (first use only).
    private(set) var preparing = false
    private(set) var preparingFraction: Double?
    /// Live transcript of the current listen.
    private(set) var partial = ""
    /// Typed text the dictation continues (mic button with text in the field).
    private(set) var prefix = ""
    private(set) var heardSpeech = false
    /// Recent input levels (0…1), oldest first.
    private(set) var levels = [Float](repeating: 0, count: VoiceSession.levelCount)
    /// The line on show: what Glide is saying, or just said.
    private(set) var caption: String?
    private(set) var captionKind: SpeechPolicy.Kind?
    private(set) var isSpeaking = false
    /// An utterance was handed over and nothing has come back yet ("thinking").
    private(set) var awaitingReply = false
    /// The last question cue. `TaskController.pendingQuestion` is the source of truth; this
    /// covers the moment before it is set and lets snapshots show a question.
    private(set) var activeQuestion: AgentQuestion?
    /// Why listening stopped early (no microphone access, no recognizer…), shown in the notch.
    private(set) var notice: String?
    /// The last utterance was spoken, so Glide keeps the conversation in voice.
    private(set) var conversationIsVoice = false

    static let levelCount = 28

    @ObservationIgnored var onUtterance: (String, UtteranceSource) -> Void = { _, _ in }
    /// Listening ended without a request (nothing said, or failed) after the user asked to talk:
    /// show the text field, prefilled.
    @ObservationIgnored var onTypingRequested: (String) -> Void = { _ in }
    /// Any change the notch should lay out again for.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored var settings: () -> VoiceSettings
    /// Microphone access is already granted (Glide never prompts for listens it opens itself).
    @ObservationIgnored var micAuthorized: () -> Bool

    /// Timings, shortened by tests.
    @ObservationIgnored var timing = Timing()
    struct Timing {
        /// A user-initiated listen with nothing said falls back to the text field after this.
        var userNoSpeechSeconds: Double = 8
        /// A spoken caption stays this long after it was said.
        var captionLinger: Double = 2.5
        /// A caption that wasn't spoken stays this long.
        var silentCaption: Double = 4
        /// "Thinking" gives up after this long without a cue.
        var replyTimeout: Double = 8
    }

    @ObservationIgnored let recognizer: any VoiceRecognizer
    @ObservationIgnored let speaker: any VoiceSpeaker

    private struct Line {
        var text: String
        var shown: String
        var kind: SpeechPolicy.Kind
    }

    @ObservationIgnored private var queue: [Line] = []
    @ObservationIgnored private var speakTask: Task<Void, Never>?
    /// The line playing goes through echo cancellation, so what the mic hears is the user.
    @ObservationIgnored private var bargeInArmed = false
    @ObservationIgnored private var interrupted = false
    /// A question that wasn't spoken waits for the current line before its answer window opens.
    @ObservationIgnored private var answerWindowPending = false
    @ObservationIgnored private var answerTimer: Task<Void, Never>?
    @ObservationIgnored private var captionTimer: Task<Void, Never>?
    @ObservationIgnored private var replyTimer: Task<Void, Never>?

    init(recognizer: any VoiceRecognizer, speaker: any VoiceSpeaker,
         settings: @escaping () -> VoiceSettings, micAuthorized: @escaping () -> Bool) {
        self.recognizer = recognizer
        self.speaker = speaker
        self.settings = settings
        self.micAuthorized = micAuthorized
    }

    /// A session that never opens the microphone or plays audio (tests, snapshots).
    static func inert() -> VoiceSession {
        VoiceSession(recognizer: SilentRecognizer(), speaker: SilentSpeaker(), settings: { VoiceSettings() }, micAuthorized: { false })
    }

    var isListening: Bool { purpose != nil }
    /// The text the user is saying, with any typed text it continues.
    var transcript: String { Self.join(prefix, partial) }

    // MARK: Listening

    /// The user wants to talk: stops Glide speaking and opens the microphone.
    func listen(prefix: String = "") {
        stopSpeaking()
        answerTimer?.cancel()
        notice = nil
        startListening(.request, userInitiated: true, prefix: prefix,
                       request: ListenRequest(noSpeechTimeout: timing.userNoSpeechSeconds, echoCancellation: false, mayPrompt: true))
        onChange()
    }

    /// Esc, or the notch closing.
    func cancelListening() {
        stopListening()
        onChange()
    }

    /// The user started typing: closes the microphone and returns what was heard so far, for
    /// the text field.
    func takeTranscriptForTyping() -> String {
        let text = transcript
        stopListening()
        onChange()
        return text
    }

    /// Return while listening: send what was heard so far without waiting for the pause.
    func finishNow() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening()
        if !text.isEmpty { deliver(text) }
        onChange()
    }

    private func startListening(_ purpose: Purpose, userInitiated: Bool, prefix: String = "", request: ListenRequest) {
        recognizer.stop()
        self.purpose = purpose
        self.userInitiated = userInitiated
        self.prefix = prefix
        micLive = false
        preparing = false
        preparingFraction = nil
        partial = ""
        heardSpeech = false
        levels = [Float](repeating: 0, count: Self.levelCount)
        recognizer.onEvent = { [weak self] event in self?.handle(event) }
        recognizer.start(request)
    }

    private func stopListening() {
        answerTimer?.cancel()
        answerTimer = nil
        guard purpose != nil else { return }
        recognizer.onEvent = nil
        recognizer.stop()
        purpose = nil
        micLive = false
        userInitiated = false
        preparing = false
        preparingFraction = nil
        partial = ""
        prefix = ""
        heardSpeech = false
        levels = [Float](repeating: 0, count: Self.levelCount)
    }

    func handle(_ event: ListenEvent) {
        guard purpose != nil else { return }
        switch event {
        case .preparing(let fraction):
            preparing = true
            preparingFraction = fraction
        case .started:
            preparing = false
            preparingFraction = nil
            micLive = true
        case .level(let level):
            levels.removeFirst()
            levels.append(level)
            return // Level changes only redraw the waveform; no relayout.
        case .speechStarted:
            heardSpeech = true
            answerTimer?.cancel()
        case .partial(let text):
            partial = text
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                heardSpeech = true
                answerTimer?.cancel()
                // The user is talking over Glide: stop at once and take what they say. Only
                // when what's playing is echo-cancelled, or Glide would interrupt itself.
                if speakTask != nil && (bargeInArmed || !isSpeaking) { bargeIn() }
            }
        case .finished(let text):
            let full = Self.join(prefix, text).trimmingCharacters(in: .whitespacesAndNewlines)
            let wasUser = userInitiated
            let typed = prefix
            stopListening()
            if full.isEmpty {
                if wasUser { onTypingRequested(typed) }
            } else {
                deliver(full)
            }
        case .noSpeech:
            let wasUser = userInitiated && purpose == .request
            let typed = prefix
            stopListening()
            if wasUser { onTypingRequested(typed) }
            pump()
        case .failed(let message):
            let wasUser = userInitiated
            let text = transcript
            stopListening()
            if wasUser {
                notice = message
                onTypingRequested(text)
            }
            pump()
        }
        onChange()
    }

    /// Hands a finished utterance to the conversation layer.
    private func deliver(_ text: String) {
        conversationIsVoice = true
        // The conversation layer decides whether this answered the question; while it is still
        // pending, `TaskController.pendingQuestion` keeps the card up.
        activeQuestion = nil
        answerWindowPending = false
        setAwaitingReply()
        clearCaption()
        onUtterance(text, .voice)
        pump()
    }

    /// The user typed a request or an answer: the conversation moves to the keyboard, so Glide
    /// stops opening the microphone on its own (it still speaks per the speak mode).
    func noteTyped() {
        conversationIsVoice = false
        activeQuestion = nil
        stopListening()
        setAwaitingReply()
        onChange()
    }

    /// An option chip answered the question.
    func noteAnswered(questionID: String) {
        if activeQuestion?.id == questionID { activeQuestion = nil }
        if purpose == .answer { stopListening() }
        setAwaitingReply()
        onChange()
    }

    /// The question went away without an answer from here (answered elsewhere, defaulted).
    func clearQuestion(id: String) {
        guard activeQuestion?.id == id else { return }
        activeQuestion = nil
        if purpose == .answer && !heardSpeech { stopListening() }
        onChange()
    }

    private func setAwaitingReply() {
        awaitingReply = true
        replyTimer?.cancel()
        let seconds = timing.replyTimeout
        replyTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.awaitingReply = false
            self.onChange()
        }
    }

    // MARK: Speaking

    /// A cue from `TaskController.onSpeech`: always shown, spoken per the speak mode.
    func hear(_ cue: SpeechCue) {
        awaitingReply = false
        replyTimer?.cancel()
        let kind = SpeechPolicy.kind(of: cue)
        let shown = SpeechPolicy.shownText(cue)
        if case .question(let q) = cue {
            activeQuestion = q
        } else {
            showCaption(shown, kind)
        }
        if SpeechPolicy.shouldSpeak(cue, mode: settings().speakMode) {
            // Progress is only worth saying when nothing else is waiting to be said.
            if kind == .progress && (speakTask != nil || !queue.isEmpty) {
                lingerCaption(timing.silentCaption)
            } else {
                queue.append(Line(text: SpeechPolicy.spokenText(cue), shown: shown, kind: kind))
                pump()
            }
        } else if kind == .question {
            if speakTask == nil { openAnswerWindow(spoken: false) } else { answerWindowPending = true }
        } else {
            lingerCaption(timing.silentCaption)
        }
        onChange()
    }

    /// Stops talking and forgets what was queued.
    func stopSpeaking() {
        queue.removeAll()
        answerWindowPending = false
        guard speakTask != nil else { return }
        // Nothing follows a line the user cut short (no answer window, no next line).
        interrupted = true
        speaker.stop()
    }

    /// The notch was closed: quiet, microphone off, no caption.
    func reset() {
        stopListening()
        stopSpeaking()
        clearCaption()
        awaitingReply = false
        replyTimer?.cancel()
        notice = nil
        onChange()
    }

    func clearNotice() { notice = nil }

    /// Glide doesn't talk over the user: lines wait while they are saying something.
    private var canSpeakNow: Bool {
        switch purpose {
        case nil, .bargeIn: return true
        case .answer: return !heardSpeech
        case .request: return false
        }
    }

    private func pump() {
        guard speakTask == nil, canSpeakNow, !queue.isEmpty else { return }
        let line = queue.removeFirst()
        if line.kind != .question { showCaption(line.shown, line.kind) }
        isSpeaking = false
        bargeInArmed = false
        interrupted = false
        // In a voice conversation the mic opens with the line so the user can cut in. It comes up
        // while the speech is fetched; the line only counts as interruptible once its audio
        // plays through the same (echo-cancelled) engine.
        if purpose == nil && conversationIsVoice && micAuthorized() {
            startListening(.bargeIn, userInitiated: false,
                           request: ListenRequest(noSpeechTimeout: nil, echoCancellation: true, maxUtterance: 30, mayPrompt: false))
        }
        speakTask = Task { [weak self] in
            guard let self else { return }
            await self.speaker.speak(line.text) { [weak self] echoCancelled in
                guard let self, self.speakTask != nil else { return }
                self.isSpeaking = true
                self.bargeInArmed = echoCancelled && self.micLive
                // Not echo-cancelled: the mic would hear Glide, so no barge-in for this line.
                if !self.bargeInArmed && self.purpose == .bargeIn && !self.heardSpeech { self.stopListening() }
                self.onChange()
            }
            self.lineFinished(line)
        }
    }

    private func lineFinished(_ line: Line) {
        speakTask = nil
        isSpeaking = false
        bargeInArmed = false
        if interrupted {
            interrupted = false
            onChange()
            return
        }
        if line.kind != .question { lingerCaption(timing.captionLinger) }
        if !queue.isEmpty {
            pump()
        } else if line.kind == .question || answerWindowPending {
            openAnswerWindow(spoken: line.kind == .question)
        } else if purpose == .bargeIn && !heardSpeech {
            stopListening()
        }
        onChange()
    }

    private func bargeIn() {
        interrupted = true
        queue.removeAll()
        answerWindowPending = false
        clearCaption()
        speaker.stop()
    }

    /// After a question, listen for the answer without a tap, for `listenForAnswerSeconds`.
    /// Only when the user heard the question or is talking to Glide, and the microphone is
    /// already allowed.
    private func openAnswerWindow(spoken: Bool) {
        answerWindowPending = false
        let seconds = settings().listenForAnswerSeconds
        guard seconds > 0, spoken || conversationIsVoice, micAuthorized(), activeQuestion != nil else {
            if purpose == .bargeIn && !heardSpeech { stopListening() }
            return
        }
        switch purpose {
        case .bargeIn: purpose = .answer
        case nil:
            startListening(.answer, userInitiated: false,
                           request: ListenRequest(noSpeechTimeout: nil, echoCancellation: true, maxUtterance: 30, mayPrompt: false))
        case .answer, .request: break
        }
        answerTimer?.cancel()
        answerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.purpose == .answer, !self.heardSpeech else { return }
            self.stopListening()
            self.onChange()
        }
    }

    // MARK: Caption

    private func showCaption(_ text: String, _ kind: SpeechPolicy.Kind) {
        captionTimer?.cancel()
        caption = text
        captionKind = kind
    }

    private func lingerCaption(_ seconds: Double) {
        captionTimer?.cancel()
        captionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.isSpeaking, self.speakTask == nil else { return }
            self.clearCaption()
            self.onChange()
        }
    }

    private func clearCaption() {
        captionTimer?.cancel()
        caption = nil
        captionKind = nil
    }

    nonisolated static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    // MARK: Snapshots

    /// Puts the session in a state for snapshot images, without audio.
    func previewState(purpose: Purpose? = nil, partial: String = "", levels: [Float]? = nil, caption: String? = nil,
                      speaking: Bool = false, question: AgentQuestion? = nil, awaitingReply: Bool = false,
                      preparing: Double? = nil, userInitiated: Bool = true) {
        self.purpose = purpose
        self.micLive = purpose != nil && preparing == nil
        self.userInitiated = userInitiated
        self.partial = partial
        self.heardSpeech = !partial.isEmpty
        if let levels { self.levels = levels } else { self.levels = [Float](repeating: 0, count: Self.levelCount) }
        self.caption = caption
        self.captionKind = caption == nil ? nil : .ack
        self.isSpeaking = speaking
        self.activeQuestion = question
        self.awaitingReply = awaitingReply
        self.preparing = preparing != nil
        self.preparingFraction = preparing
    }
}

/// Never opens the microphone.
@MainActor
final class SilentRecognizer: VoiceRecognizer {
    var onEvent: ((ListenEvent) -> Void)?
    func start(_ request: ListenRequest) {}
    func stop() {}
}

/// Never plays audio.
@MainActor
final class SilentSpeaker: VoiceSpeaker {
    func speak(_ text: String, onAudioStart: @escaping @MainActor (Bool) -> Void) async {}
    func stop() {}
}
