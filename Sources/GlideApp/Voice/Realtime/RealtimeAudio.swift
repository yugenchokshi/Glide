import AVFoundation
import os

/// Microphone in and speech out for a realtime conversation. The real one runs one
/// voice-processing `AVAudioEngine` for both, so echo cancellation removes Glide's own voice
/// from what the microphone hears; tests use a fake.
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
        guard let playFormat else { throw RealtimeError.badURL }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // Keep the user's other audio at its volume while the conversation is open.
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw RealtimeError.closed("no microphone") }
        let tap = try RealtimeMicTap(micFormat: micFormat, onAudio: onAudio, onLevel: onLevel)
        Self.install(tap, on: input, format: micFormat)
        engine.prepare()
        try engine.start()
        player.play()
        self.engine = engine
        self.player = player
        self.tap = tap
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
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            if let player { engine.detach(player) }
        }
        engine = nil
        player = nil
        tap = nil
    }
}
