import AVFoundation
import os

/// Microphone in and speech out for a realtime conversation. The real one mutes the mic while
/// Glide speaks, or (with `VoiceAudio.echoCancellationEnabled`) runs one voice-processing
/// `AVAudioEngine` for both so the user can talk over it; tests use a fake.
@MainActor
protocol RealtimeAudioIO: AnyObject {
    /// Asks for (or checks) microphone access.
    func authorize(mayPrompt: Bool) async -> Bool
    /// Opens the microphone and the speaker. `onAudio` gets PCM16 24 kHz mono, on the audio
    /// thread; `onLevel` gets 0…1; `onPlaying` says when playback starts or drains.
    func start(onAudio: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Float) -> Void,
               onPlaying: @escaping @Sendable (Bool) -> Void) throws
    /// Plays PCM16 24 kHz mono at once (queued after what is already playing).
    func play(_ pcm16: Data, itemID: String)
    /// How much of an item's audio has actually played, for truncation on barge-in.
    func playedMilliseconds(itemID: String) -> Int
    /// Drops everything queued and goes quiet immediately.
    func stopPlayback()
    var isPlaying: Bool { get }
    /// Closes the microphone and the speaker.
    func stop()
}

/// Played-frame bookkeeping, updated from the audio thread's buffer callbacks.
final class RealtimePlaybackLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var outstanding = 0
    private var played: [String: Int] = [:]
    private let onPlaying: @Sendable (Bool) -> Void

    init(onPlaying: @escaping @Sendable (Bool) -> Void) { self.onPlaying = onPlaying }

    /// A buffer was scheduled; returns the generation its completion must match.
    func scheduled() -> Int {
        let (gen, started) = lock.withLock { () -> (Int, Bool) in
            outstanding += 1
            return (generation, outstanding == 1)
        }
        if started { onPlaying(true) }
        return gen
    }

    func didPlay(frames: Int, itemID: String, generation gen: Int) {
        let drained: Bool = lock.withLock {
            guard gen == generation else { return false }
            played[itemID, default: 0] += frames
            outstanding = max(0, outstanding - 1)
            return outstanding == 0
        }
        if drained { onPlaying(false) }
    }

    func playedFrames(_ itemID: String) -> Int { lock.withLock { played[itemID] ?? 0 } }

    /// Playback was cut: later completions of the dropped buffers don't count.
    func reset() {
        let was: Bool = lock.withLock {
            generation += 1
            let was = outstanding > 0
            outstanding = 0
            return was
        }
        if was { onPlaying(false) }
    }

    var isPlaying: Bool { lock.withLock { outstanding > 0 } }
}

/// Converts the microphone tap to PCM16 24 kHz mono and reports levels.
final class RealtimeMicTap: @unchecked Sendable {
    private let monoFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let onAudio: @Sendable (Data) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private var tick = 0

    init(micFormat: AVAudioFormat, onAudio: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: micFormat.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: RealtimeProtocol.sampleRate, channels: 1, interleaved: true) else {
            throw RealtimeError.badURL
        }
        monoFormat = mono
        outFormat = out
        converter = AVAudioConverter(from: mono, to: out)
        self.onAudio = onAudio
        self.onLevel = onLevel
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let mono = MicTap.firstChannel(buffer, format: monoFormat) else { return }
        tick += 1
        if tick % 2 == 0 { onLevel(EndOfSpeechDetector.displayLevel(db: EndOfSpeechDetector.levelDB(mono))) }
        guard let converter, let out = MicTap.convert(mono, with: converter, to: outFormat),
              let samples = out.int16ChannelData?[0] else { return }
        onAudio(Data(bytes: samples, count: Int(out.frameLength) * 2))
    }
}

@MainActor
final class RealtimeAudioEngine: RealtimeAudioIO {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    /// The engine the player is attached to (the mic engine, or the app's output engine).
    private var playerEngine: AVAudioEngine?
    private var tap: RealtimeMicTap?
    private var ledger: RealtimePlaybackLedger?
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RealtimeProtocol.sampleRate, channels: 1, interleaved: false)

    func authorize(mayPrompt: Bool) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return mayPrompt ? await AVCaptureDevice.requestAccess(for: .audio) : false
        default: return false
        }
    }

    func start(onAudio: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Float) -> Void,
               onPlaying: @escaping @Sendable (Bool) -> Void) throws {
        stop()
        RealtimeDiagnostics.note("releasing other audio before opening the mic: \(VoiceAudio.shared.releaseAll())")
        if VoiceAudio.echoCancellationEnabled {
            do {
                try start(voiceProcessing: true, onAudio: onAudio, onLevel: onLevel, onPlaying: onPlaying)
                echoCancelled = true
                RealtimeDiagnostics.note("mic started with echo cancellation")
                return
            } catch {
                // A failed attempt leaves this process's mic unusable, so don't try again.
                UserDefaults.standard.set(false, forKey: "glide.voice.echoCancellation")
                RealtimeDiagnostics.note("mic with echo cancellation failed: \(Self.describe(error))")
                stop()
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        // Without echo cancellation the mic would hear Glide, so it's muted while Glide speaks.
        let muted = HalfDuplexGate()
        do {
            try start(voiceProcessing: false, onAudio: { pcm in if !muted.isMuted { onAudio(pcm) } }, onLevel: onLevel,
                      onPlaying: { playing in muted.set(playing); onPlaying(playing) })
            echoCancelled = false
            RealtimeDiagnostics.note("mic started")
        } catch {
            RealtimeDiagnostics.note("mic failed: \(Self.describe(error))")
            stop()
            let ns = error as NSError
            throw RealtimeError.closed("\(ns.localizedDescription) (\(ns.domain) \(ns.code))")
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? RealtimeError { return "RealtimeError.\(e) — \(e.description)" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription) \(ns.userInfo)"
    }

    /// False when the mic runs without echo cancellation (and so is muted while Glide speaks).
    private(set) var echoCancelled = false

    private func start(voiceProcessing: Bool, onAudio: @escaping @Sendable (Data) -> Void, onLevel: @escaping @Sendable (Float) -> Void,
                       onPlaying: @escaping @Sendable (Bool) -> Void) throws {
        guard let playFormat else { throw RealtimeError.badURL }
        // Open the mic the same way on-device listening does, which works on setups where
        // wiring playback into the engine before it starts fails (kAUInitialize / -10875).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Keep the user's other audio at its volume while the conversation is open.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            _ = engine.mainMixerNode
        }
        let micFormat = input.outputFormat(forBus: 0)
        RealtimeDiagnostics.note("mic format (voice processing \(voiceProcessing)): \(micFormat)")
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw RealtimeError.closed("no microphone") }
        let tap = try RealtimeMicTap(micFormat: micFormat, onAudio: onAudio, onLevel: onLevel)
        Self.install(tap, on: input, format: micFormat)
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        self.engine = engine
        self.tap = tap

        // Then Glide's voice: on the same engine when it's echo-cancelled (so the user can talk
        // over it), otherwise on the app's output-only engine.
        let player = AVAudioPlayerNode()
        let output: AVAudioEngine
        if voiceProcessing {
            output = engine
        } else {
            output = try VoiceAudio.shared.playbackEngine().engine
        }
        output.attach(player)
        output.connect(player, to: output.mainMixerNode, format: playFormat)
        if !output.isRunning { try output.start() }
        player.play()
        self.player = player
        self.playerEngine = output
        self.ledger = RealtimePlaybackLedger(onPlaying: onPlaying)
    }

    nonisolated private static func install(_ tap: RealtimeMicTap, on node: AVAudioInputNode, format: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in tap.process(buffer) }
    }

    func play(_ pcm16: Data, itemID: String) {
        guard let player, let ledger, let playFormat, !pcm16.isEmpty else { return }
        var carry: UInt8?
        let samples = OpenAISpeech.decodePCM16([UInt8](pcm16), carry: &carry)
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
        }
        Self.enqueue(buffer, on: player, ledger: ledger, itemID: itemID)
        if !player.isPlaying { player.play() }
    }

    nonisolated private static func enqueue(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode, ledger: RealtimePlaybackLedger, itemID: String) {
        let gen = ledger.scheduled()
        let frames = Int(buffer.frameLength)
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            ledger.didPlay(frames: frames, itemID: itemID, generation: gen)
        }
    }

    func playedMilliseconds(itemID: String) -> Int {
        Int(Double(ledger?.playedFrames(itemID) ?? 0) / RealtimeProtocol.sampleRate * 1000)
    }

    func stopPlayback() {
        ledger?.reset()
        player?.stop()
        player?.play()
    }

    var isPlaying: Bool { ledger?.isPlaying ?? false }

    func stop() {
        ledger?.reset()
        ledger = nil
        player?.stop()
        if let player, let playerEngine, playerEngine !== engine { playerEngine.detach(player) }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            if let player, playerEngine === engine { engine.detach(player) }
        }
        engine = nil
        playerEngine = nil
        player = nil
        tap = nil
    }
}


/// Mutes mic upload while Glide's voice plays (plus a short tail for the room's echo), for
/// setups without echo cancellation.
final class HalfDuplexGate: @unchecked Sendable {
    private let lock = NSLock()
    private var playing = false
    private var quietSince = Date.distantPast

    func set(_ isPlaying: Bool) {
        lock.withLock {
            if playing && !isPlaying { quietSince = Date() }
            playing = isPlaying
        }
    }

    var isMuted: Bool { lock.withLock { playing || Date().timeIntervalSince(quietSince) < 0.3 } }
}
