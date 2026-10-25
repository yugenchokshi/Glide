import AVFoundation

/// Decides when the user has finished speaking, so they never press a button to send.
///
/// An energy-based voice-activity detector tracks the room's noise floor and calls a frame
/// speech when it is clearly louder. An utterance ends after ~0.8 s of trailing silence once the
/// transcriber has finalized what was said; if the transcriber is slow to finalize, a little more
/// silence ends it anyway. Utterances are capped at 30 s. Pure value type: tests feed it
/// synthetic buffers, the recognizer feeds it the microphone on the audio thread.
struct EndOfSpeechDetector: Sendable {
    struct Config: Sendable, Equatable {
        /// Silence after speech that ends the utterance (with a finalized transcript).
        var trailingSilence: Double = 0.8
        /// Extra silence that ends it even when the transcript hasn't been finalized yet.
        var unsettledGrace: Double = 0.9
        var maxUtterance: Double = 30
        /// Nothing said within this long ends listening (nil: listen until stopped).
        var noSpeechTimeout: Double? = 8
        /// Speech this long (in total, allowing short gaps) counts as the user starting to talk,
        /// so a click or a cough doesn't.
        var minSpeech: Double = 0.15
        /// How far above the noise floor a frame must be to count as speech.
        var speechMarginDB: Float = 10
        /// Frames quieter than this are never speech, however quiet the room.
        var absoluteFloorDB: Float = -52
    }

    enum Event: Equatable, Sendable {
        case speechStarted
        case endOfSpeech
        case noSpeech
        case maxLength
    }

    var config: Config
    /// Set by the recognizer: everything heard so far has a finalized transcript.
    var transcriptSettled = false
    private(set) var elapsed: Double = 0
    private(set) var heardSpeech = false
    private(set) var silenceRun: Double = 0
    private(set) var noiseFloorDB: Float = -60
    private var speechRun: Double = 0
    private(set) var finished = false

    init(config: Config = Config()) {
        self.config = config
    }

    /// Feeds one frame of audio (its RMS level in dBFS and its length). Returns at most one
    /// event per call; after a terminal event (end, no speech, max length) it returns nil.
    mutating func process(levelDB: Float, duration: Double) -> Event? {
        guard !finished, duration > 0 else { return nil }
        elapsed += duration
        let isSpeech = levelDB > max(noiseFloorDB + config.speechMarginDB, config.absoluteFloorDB)
        if isSpeech {
            speechRun += duration
            silenceRun = 0
        } else {
            silenceRun += duration
            // Short gaps between syllables don't reset the run; longer ones wear it down.
            speechRun = max(0, speechRun - duration * 0.5)
            // The floor follows the room down quickly and up slowly, and only between words.
            let rate: Float = levelDB < noiseFloorDB ? 0.3 : 0.02
            noiseFloorDB += (levelDB - noiseFloorDB) * rate
        }
        if !heardSpeech {
            if speechRun >= config.minSpeech {
                heardSpeech = true
                return .speechStarted
            }
            if let timeout = config.noSpeechTimeout, elapsed >= timeout {
                finished = true
                return .noSpeech
            }
            return nil
        }
        if elapsed >= config.maxUtterance {
            finished = true
            return .maxLength
        }
        if silenceRun >= config.trailingSilence && (transcriptSettled || silenceRun >= config.trailingSilence + config.unsettledGrace) {
            finished = true
            return .endOfSpeech
        }
        return nil
    }

    /// The transcriber heard words the level detector missed (quiet speech): count it as speech.
    mutating func noteSpeech() {
        heardSpeech = true
    }

    // MARK: Levels

    /// RMS level of the first channel in dBFS (-160 for silence).
    static func levelDB(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return -160 }
        var sum: Float = 0
        if let f = buffer.floatChannelData {
            let p = f[0]
            for i in 0..<n { sum += p[i] * p[i] }
        } else if let s = buffer.int16ChannelData {
            let p = s[0]
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for i in 0..<n {
                let v = Float(p[i * stride]) / 32768
                sum += v * v
            }
        } else {
            return -160
        }
        return levelDB(meanSquare: sum / Float(n))
    }

    static func levelDB(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -160 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return levelDB(meanSquare: sum / Float(samples.count))
    }

    static func levelDB(meanSquare: Float) -> Float {
        meanSquare > 1e-16 ? 10 * log10(meanSquare) : -160
    }

    /// 0…1 for the waveform: -60 dBFS and below is flat, -12 dBFS is full height.
    static func displayLevel(db: Float) -> Float {
        min(1, max(0, (db + 60) / 48))
    }
}
