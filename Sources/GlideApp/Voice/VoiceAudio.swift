import AVFoundation
import os

/// Mono speech audio as plain samples, so it can cross from the network or the synthesizer to
/// the player without sharing audio buffers between threads.
struct PCMChunk: Sendable, Equatable {
    var samples: [Float]
    var sampleRate: Double
}

enum PlaybackError: Error, Equatable {
    /// The source failed (or ended) before any audio played, so a fallback voice can take over.
    case noAudio(String)
}

/// The audio engines Glide's voice uses.
///
/// While the microphone is open, the listening engine runs with voice processing (echo
/// cancellation), and speech plays through that same engine: the canceller only removes what
/// it plays itself, which is what lets the user interrupt Glide. Otherwise speech plays through
/// an output-only engine that never touches the microphone.
@MainActor
final class VoiceAudio {
    static let shared = VoiceAudio()

    /// The listening engine, only while the microphone is open.
    private(set) var inputEngine: AVAudioEngine?
    /// The listening engine uses voice processing.
    private(set) var inputEchoCancelled = false
    private var outputEngine: AVAudioEngine?
    /// Told when the listening engine is about to stop, so playback on it ends cleanly.
    weak var player: PCMPlayer?

    func registerInput(_ engine: AVAudioEngine, echoCancelled: Bool) {
        inputEngine = engine
        inputEchoCancelled = echoCancelled
    }

    /// Stops the listening engine: the microphone (and its indicator) turn off at once.
    func closeInput(_ engine: AVAudioEngine) {
        guard inputEngine === engine else {
            engine.stop()
            return
        }
        player?.engineWillStop(engine)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputEngine = nil
        inputEchoCancelled = false
    }

    /// The engine new speech plays through, started.
    func playbackEngine() throws -> (engine: AVAudioEngine, echoCancelled: Bool) {
        if let input = inputEngine, input.isRunning { return (input, inputEchoCancelled) }
        let engine = outputEngine ?? AVAudioEngine()
        outputEngine = engine
        // Touching the mixer builds the output chain; the input node is never touched here.
        _ = engine.mainMixerNode
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        return (engine, false)
    }

    /// Whether Glide turns on the system's voice processing (echo cancellation). Off unless
    /// `glide.voice.echoCancellation` is set: on some Macs it fails at kAUInitialize (-10875),
    /// and one failed attempt leaves the process's microphone unusable until relaunch. Without
    /// it the mic is muted while Glide speaks, so the user can't talk over it.
    static var echoCancellationEnabled: Bool { UserDefaults.standard.bool(forKey: "glide.voice.echoCancellation") }

    /// Frees the microphone and speakers for another owner (the realtime conversation): the
    /// on-device listener and the output-only engine stop, and voice processing is released.
    /// Returns what was holding them, for diagnostics.
    @discardableResult
    func releaseAll() -> String {
        var held: [String] = []
        if let input = inputEngine {
            held.append("on-device mic (running: \(input.isRunning), echo-cancelled: \(inputEchoCancelled))")
            player?.engineWillStop(input)
            input.inputNode.removeTap(onBus: 0)
            input.stop()
            try? input.inputNode.setVoiceProcessingEnabled(false)
            inputEngine = nil
            inputEchoCancelled = false
        }
        if let output = outputEngine {
            held.append("output engine (running: \(output.isRunning))")
            output.stop()
            outputEngine = nil
        }
        return held.isEmpty ? "nothing" : held.joined(separator: ", ")
    }

    /// Stops the output-only engine when nothing plays, so the audio device can sleep.
    func releaseOutput(_ engine: AVAudioEngine) {
        guard engine === outputEngine else { return }
        engine.stop()
    }
}

/// Counts scheduled and played buffers on the audio thread; `drained` resumes once everything
/// scheduled has played (or playback stopped).
final class PlaybackTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = 0
    private var played = 0
    private var closed = false
    private var waiter: CheckedContinuation<Void, Never>?

    func didSchedule() { lock.withLock { scheduled += 1 } }

    func didPlay() {
        let w: CheckedContinuation<Void, Never>? = lock.withLock {
            played += 1
            guard played >= scheduled, let w = waiter else { return nil }
            waiter = nil
            return w
        }
        w?.resume()
    }

    /// Wakes the waiter now (playback stopped).
    func close() {
        let w: CheckedContinuation<Void, Never>? = lock.withLock {
            closed = true
            let w = waiter
            waiter = nil
            return w
        }
        w?.resume()
    }

    func drained() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if closed || played >= scheduled { return true }
                waiter = c
                return false
            }
            if resumeNow { c.resume() }
        }
    }
}

/// Plays speech as it arrives. A little audio is gathered before starting (so a slow first
/// packet doesn't stutter), then each piece is scheduled the moment it comes in.
@MainActor
protocol PCMPlaying: AnyObject {
    /// Plays `chunks`, returning when they have played or `stop()` was called. Throws
    /// `PlaybackError.noAudio` when the source fails before any audio played. `rate` speeds
    /// playback up or down without changing pitch.
    func play(_ chunks: AsyncThrowingStream<PCMChunk, any Error>, rate: Double, onStart: @escaping @MainActor (Bool) -> Void) async throws
    func stop()
}

@MainActor
final class PCMPlayer: PCMPlaying {
    private let audio: VoiceAudio
    private var node: AVAudioPlayerNode?
    private var pitch: AVAudioUnitTimePitch?
    private var engine: AVAudioEngine?
    private var tracker: PlaybackTracker?
    private var generation = 0

    /// Audio gathered before playback starts, and the smallest piece scheduled after that.
    static let startSeconds = 0.12
    static let pieceSeconds = 0.06

    init(audio: VoiceAudio = .shared) {
        self.audio = audio
        audio.player = self
    }

    func play(_ chunks: AsyncThrowingStream<PCMChunk, any Error>, rate: Double, onStart: @escaping @MainActor (Bool) -> Void) async throws {
        stop()
        generation += 1
        let gen = generation
        var pending: [Float] = []
        var sampleRate: Double = 0
        var started = false
        var failure: (any Error)?
        do {
            for try await chunk in chunks {
                guard gen == generation, !Task.isCancelled else { return }
                if sampleRate == 0 { sampleRate = chunk.sampleRate }
                pending += chunk.samples
                let need = (started ? Self.pieceSeconds : Self.startSeconds) * sampleRate
                if Double(pending.count) >= need {
                    try schedule(pending, sampleRate: sampleRate, rate: rate, started: &started, onStart: onStart)
                    pending.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            failure = error
        }
        guard gen == generation, !Task.isCancelled else { return }
        if !pending.isEmpty && sampleRate > 0 {
            try schedule(pending, sampleRate: sampleRate, rate: rate, started: &started, onStart: onStart)
        }
        guard started else {
            teardown()
            throw PlaybackError.noAudio(failure.map { String(describing: $0) } ?? "no audio")
        }
        if let failure { Logger(subsystem: "dev.glide", category: "voice").error("speech stream ended early: \(String(describing: failure), privacy: .public)") }
        await tracker?.drained()
        if gen == generation { teardown() }
    }

    func stop() {
        generation += 1
        teardown()
    }

    /// The listening engine is stopping under the player (the microphone closed).
    func engineWillStop(_ stopping: AVAudioEngine) {
        if engine === stopping { stop() }
    }

    private func schedule(_ samples: [Float], sampleRate: Double, rate: Double, started: inout Bool,
                          onStart: @MainActor (Bool) -> Void) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        if !started {
            let (engine, echoCancelled) = try audio.playbackEngine()
            let node = AVAudioPlayerNode()
            let pitch = AVAudioUnitTimePitch()
            pitch.rate = Float(min(2, max(0.5, rate)))
            engine.attach(node)
            engine.attach(pitch)
            engine.connect(node, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
            let tracker = PlaybackTracker()
            self.engine = engine
            self.node = node
            self.pitch = pitch
            self.tracker = tracker
            Self.enqueue(buffer, on: node, tracker: tracker)
            node.play()
            started = true
            onStart(echoCancelled)
            return
        }
        if let node, let tracker { Self.enqueue(buffer, on: node, tracker: tracker) }
    }

    /// Nonisolated so the completion handler (run on the audio thread) isn't tied to the main actor.
    nonisolated private static func enqueue(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode, tracker: PlaybackTracker) {
        tracker.didSchedule()
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in tracker.didPlay() }
    }

    private func teardown() {
        tracker?.close()
        tracker = nil
        if let node {
            node.stop()
            if let engine {
                engine.detach(node)
                if let pitch { engine.detach(pitch) }
                audio.releaseOutput(engine)
            }
        }
        node = nil
        pitch = nil
        engine = nil
    }
}
