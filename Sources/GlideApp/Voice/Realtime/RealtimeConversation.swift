import Foundation
import AgentKit
import os

/// One open voice conversation with the OpenAI Realtime API: the microphone streams to the
/// server, server VAD decides when the user's turn ends, the model's audio plays as it arrives,
/// and Glide is a set of tools the model calls (`RealtimeGlide`). Glide's own speech cues are
/// fed back in as system messages, so the model says them in its own words.
///
/// Barge-in: when the server hears the user start talking, playback stops at once, the
/// assistant item is truncated to what was actually heard, and the response is cancelled.
@MainActor
final class RealtimeConversation {
    enum EndReason: Equatable, Sendable {
        /// The user ended it (hotkey, Esc, closing the notch).
        case user
        /// Nothing was said for a while and Glide isn't waiting for an answer.
        case idle
        /// The connection or the microphone failed. `fallback`: the on-device voice can take over.
        case failed(String, fallback: Bool)
    }

    enum Event: Equatable, Sendable {
        case micLive
        case ready
        case level(Float)
        case userSpeechStarted
        /// The live transcript of what the user is saying.
        case userTranscript(String)
        case userSpeechStopped
        case userTurnEnded(String)
        /// What Glide is saying, so far.
        case assistantCaption(String)
        case speaking(Bool)
        case ended(EndReason)
    }

    enum State: Equatable { case idle, connecting, ready, ended }

    struct Timing {
        /// The conversation closes after this long with nothing said (and no question pending).
        var idleSeconds: Double = 20
        /// The session must be confirmed within this long, or the on-device voice takes over.
        var readySeconds: Double = 6
    }

    var onEvent: (Event) -> Void = { _ in }
    var timing = Timing()
    private(set) var state: State = .idle
    private(set) var responseActive = false
    private(set) var userSpeaking = false
    /// The assistant item whose audio is playing (or last played).
    private(set) var currentAudioItem: String?

    let transport: any RealtimeTransport
    let audio: any RealtimeAudioIO
    let glide: any GlideControlling
    let config: RealtimeSessionConfig

    private var responseID: String?
    /// Responses cut off by barge-in: their late audio and captions are dropped.
    private var cancelledResponses: Set<String> = []
    private var wantResponse = false
    private var toolOutputsSent = false
    private var handledCalls: Set<String> = []
    private var userText: [String: String] = [:]
    private var assistantText: [String: String] = [:]
    private var idleTimer: Task<Void, Never>?
    private var readyTimer: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.glide", category: "realtime")

    init(transport: any RealtimeTransport, audio: any RealtimeAudioIO, glide: any GlideControlling, config: RealtimeSessionConfig = RealtimeSessionConfig()) {
        self.transport = transport
        self.audio = audio
        self.glide = glide
        self.config = config
    }

    var isOpen: Bool { state == .connecting || state == .ready }

    // MARK: Lifecycle

    func start(mayPrompt: Bool) {
        guard state == .idle else { return }
        state = .connecting
        Task { [weak self] in
            guard let self else { return }
            guard await self.audio.authorize(mayPrompt: mayPrompt) else {
                self.finish(.failed(OnDeviceRecognizer.micOffMessage, fallback: false))
                return
            }
            self.open()
        }
    }

    /// Connects and opens the microphone (after access was checked).
    func open() {
        guard state == .connecting else { return }
        transport.connect(onMessage: { [weak self] text in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(text) } }
        }, onClose: { [weak self] error in
            let message = error.map { String(describing: $0) } ?? "closed"
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.socketClosed(message) } }
        })
        send(.sessionUpdate(config))
        let transport = self.transport
        do {
            try audio.start(onAudio: { pcm in transport.send(RealtimeClientEvent.appendAudio(pcm).encoded()) },
                            onLevel: { [weak self] level in
                                DispatchQueue.main.async { MainActor.assumeIsolated { self?.emit(.level(level)) } }
                            },
                            onPlaying: { [weak self] playing in
                                DispatchQueue.main.async { MainActor.assumeIsolated { self?.playbackChanged(playing) } }
                            })
        } catch {
            RealtimeDiagnostics.note("audio start threw: \(RealtimeAudioEngine.describe(error))")
            finish(.failed("Couldn't start voice: \((error as? RealtimeError)?.description ?? error.localizedDescription)", fallback: false))
            return
        }
        emit(.micLive)
        let seconds = timing.readySeconds
        readyTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.state == .connecting else { return }
            self.finish(.failed(RealtimeError.timeout.description, fallback: true))
        }
    }

    /// The user ended the conversation.
    func end() { finish(.user) }

    private func finish(_ reason: EndReason) {
        guard state != .ended else { return }
        state = .ended
        idleTimer?.cancel()
        readyTimer?.cancel()
        audio.stop()
        transport.close()
        responseActive = false
        userSpeaking = false
        if case .failed(let why, _) = reason {
            log.error("realtime ended: \(why, privacy: .public)")
            RealtimeDiagnostics.note("ended: \(why)")
        } else {
            RealtimeDiagnostics.note("ended: \(reason)")
        }
        onEvent(.ended(reason))
    }

    private func socketClosed(_ message: String) {
        guard isOpen else { return }
        finish(.failed(message, fallback: true))
    }

    private func emit(_ event: Event) {
        guard isOpen else { return }
        onEvent(event)
    }

    private func send(_ event: RealtimeClientEvent) {
        transport.send(event.encoded())
    }

    // MARK: Glide → conversation

    /// A cue from `TaskController.onSpeech`: questions, results and problems go into the
    /// conversation and get a spoken response; acks and progress are dropped.
    func feed(_ cue: SpeechCue) {
        guard isOpen, let item = RealtimeGlide.conversationItem(for: cue) else { return }
        send(.systemMessage(item.text))
        if item.respond { requestResponse() }
        armIdle()
    }

    private func requestResponse() {
        // The user is talking: the server answers when they finish, and sees the new item then.
        guard !userSpeaking else { return }
        if responseActive {
            wantResponse = true
        } else {
            send(.createResponse)
            responseActive = true
        }
    }

    // MARK: Server → Glide

    func receive(_ frame: String) {
        RealtimeDiagnostics.event(frame)
        guard isOpen, let event = RealtimeServerEvent.decode(frame) else { return }
        handle(event)
    }

    func handle(_ event: RealtimeServerEvent) {
        guard isOpen else { return }
        switch event {
        case .sessionCreated, .sessionUpdated:
            if state == .connecting {
                state = .ready
                readyTimer?.cancel()
                emit(.ready)
                armIdle()
            }
        case .speechStarted:
            userSpeaking = true
            idleTimer?.cancel()
            bargeIn()
            emit(.userSpeechStarted)
        case .speechStopped:
            userSpeaking = false
            emit(.userSpeechStopped)
            armIdle()
        case .inputTranscriptDelta(let item, let delta):
            let text = (userText[item] ?? "") + delta
            userText[item] = text
            emit(.userTranscript(text))
        case .inputTranscriptCompleted(let item, let transcript):
            userText[item] = nil
            emit(.userTurnEnded(transcript.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .responseCreated(let id):
            responseID = id
            responseActive = true
        case .outputItemAdded:
            break
        case .audioDelta(let response, let item, _, let data):
            // A response cancelled by barge-in can still have deltas in flight: drop them.
            guard !userSpeaking, !(response.map(cancelledResponses.contains) ?? false) else { return }
            currentAudioItem = item
            audio.play(data, itemID: item)
        case .audioDone:
            break
        case .transcriptDelta(let item, let delta):
            guard !userSpeaking else { return }
            let text = (assistantText[item] ?? "") + delta
            assistantText[item] = text
            emit(.assistantCaption(text))
        case .transcriptDone(let item, let transcript):
            assistantText[item] = nil
            if !transcript.isEmpty && !userSpeaking { emit(.assistantCaption(transcript)) }
        case .functionCallDone(let call):
            run(call)
        case .responseDone(_, _, let calls):
            for call in calls { run(call) }
            responseActive = false
            responseID = nil
            if toolOutputsSent {
                toolOutputsSent = false
                wantResponse = true
            }
            if wantResponse && !userSpeaking {
                wantResponse = false
                send(.createResponse)
                responseActive = true
            }
            armIdle()
        case .error(let type, let code, let message):
            if code == "response_cancel_not_active" { return }
            if code == "conversation_already_has_active_response" {
                wantResponse = true
                return
            }
            log.error("realtime error \(type ?? "", privacy: .public) \(code ?? "", privacy: .public): \(message, privacy: .public)")
            RealtimeDiagnostics.note("server error \(type ?? "") \(code ?? ""): \(message)")
            if state == .connecting { finish(.failed(message, fallback: true)) }
        case .other:
            break
        }
    }

    private func run(_ call: RealtimeFunctionCall) {
        guard handledCalls.insert(call.callID).inserted else { return }
        let output = RealtimeGlide.dispatch(call, to: glide)
        send(.functionOutput(callID: call.callID, output: output))
        // An opened app speaks for itself (and Glide may ask a follow-up), and an answer is
        // Glide's to act on, so only the other tools get a spoken reply to their output.
        if !["open_app_or_site", "answer_glide"].contains(call.name) { toolOutputsSent = true }
        armIdle()
    }

    /// "Stop talking": the same as being interrupted, without the user saying anything.
    func silence() {
        guard isOpen else { return }
        bargeIn()
    }

    /// The user started talking over Glide: quiet at once, and tell the server what was heard.
    private func bargeIn() {
        if audio.isPlaying, let item = currentAudioItem {
            let played = audio.playedMilliseconds(itemID: item)
            audio.stopPlayback()
            send(.truncate(itemID: item, contentIndex: 0, audioEndMs: played))
            emit(.speaking(false))
        }
        if responseActive {
            if let responseID { cancelledResponses.insert(responseID) }
            send(.cancelResponse(responseID: responseID))
            responseActive = false
            responseID = nil
        }
        wantResponse = false
    }

    private func playbackChanged(_ playing: Bool) {
        RealtimeDiagnostics.note(playing ? "playback started" : "playback drained")
        emit(.speaking(playing))
        if !playing { armIdle() }
    }

    // MARK: Idle

    private func armIdle() {
        idleTimer?.cancel()
        guard state == .ready else { return }
        let seconds = timing.idleSeconds
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.state == .ready else { return }
            if self.canCloseForSilence {
                self.finish(.idle)
            } else {
                self.armIdle()
            }
        }
    }

    /// Nothing is happening and Glide isn't waiting on the user.
    var canCloseForSilence: Bool {
        !userSpeaking && !responseActive && !audio.isPlaying && glide.pendingQuestion == nil
    }
}
