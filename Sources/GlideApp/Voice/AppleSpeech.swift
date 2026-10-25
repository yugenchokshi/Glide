import AVFoundation

/// An installed Apple voice, as the picker and the voice choice see it.
struct AppleVoiceOption: Sendable, Hashable, Identifiable {
    enum Quality: Int, Sendable, Comparable {
        case standard = 1, enhanced = 2, premium = 3
        static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }
    var id: String
    var name: String
    var language: String
    var quality: Quality
    /// Novelty voices (Bells, Bubbles…) and the user's Personal Voice are never picked automatically.
    var isNovelty = false
    var isPersonal = false

    var label: String {
        switch quality {
        case .premium: return "\(name) (Premium)"
        case .enhanced: return "\(name) (Enhanced)"
        case .standard: return name
        }
    }
}

/// Apple's on-device voices: Glide's offline voice and the fallback for the natural one.
enum AppleVoices {
    static func installed() -> [AppleVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            let quality: AppleVoiceOption.Quality = switch v.quality {
            case .premium: .premium
            case .enhanced: .enhanced
            default: .standard
            }
            return AppleVoiceOption(id: v.identifier, name: v.name, language: v.language, quality: quality,
                                    isNovelty: v.voiceTraits.contains(.isNoveltyVoice), isPersonal: v.voiceTraits.contains(.isPersonalVoice))
        }
    }

    /// The user's language as a BCP-47 tag ("en-US").
    static var userLanguage: String {
        AVSpeechSynthesisVoice.currentLanguageCode()
    }

    /// Voices that speak `language` well enough to offer: the same language, any region.
    static func options(for language: String, among voices: [AppleVoiceOption]) -> [AppleVoiceOption] {
        let base = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()
        return voices.filter { !$0.isNovelty && !$0.isPersonal && ($0.language.split(separator: "-").first.map(String.init)?.lowercased() ?? "") == base }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality > b.quality }
                let ar = a.language.caseInsensitiveCompare(language) == .orderedSame, br = b.language.caseInsensitiveCompare(language) == .orderedSame
                if ar != br { return ar }
                return a.name < b.name
            }
    }

    /// The best installed voice for `language`: premium over enhanced over standard, the user's
    /// own region first among equals. Nil when nothing speaks the language.
    static func best(for language: String, among voices: [AppleVoiceOption]) -> AppleVoiceOption? {
        options(for: language, among: voices).first
    }

    /// `speakingRate` 1.0 is Apple's default pace; the setting scales it.
    static func utteranceRate(_ speakingRate: Double) -> Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(speakingRate)
        return min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
    }
}

/// Apple's voice as a PCM stream, so it plays through the same engine (and echo canceller) as
/// the natural voice.
@MainActor
protocol AppleSpeechStreaming: AnyObject {
    func stream(_ text: String, voiceID: String?, speakingRate: Double) -> AsyncThrowingStream<PCMChunk, any Error>
    func stop()
}

@MainActor
final class AppleSpeechSource: AppleSpeechStreaming {
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: SynthesisDelegate?

    func stream(_ text: String, voiceID: String?, speakingRate: Double) -> AsyncThrowingStream<PCMChunk, any Error> {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        let voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AppleVoices.best(for: AppleVoices.userLanguage, among: AppleVoices.installed()).flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
            ?? AVSpeechSynthesisVoice(language: AppleVoices.userLanguage)
        utterance.voice = voice
        utterance.rate = AppleVoices.utteranceRate(speakingRate)
        let synth = AVSpeechSynthesizer()
        let (stream, continuation) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let delegate = SynthesisDelegate(continuation: continuation)
        synth.delegate = delegate
        synthesizer = synth
        self.delegate = delegate
        Self.write(utterance, with: synth, to: continuation)
        return stream
    }

    func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        delegate?.continuation.finish()
        synthesizer = nil
        delegate = nil
    }

    /// Nonisolated so the buffer callback (on the synthesizer's queue) isn't tied to the main actor.
    nonisolated private static func write(_ utterance: AVSpeechUtterance, with synth: AVSpeechSynthesizer,
                                          to continuation: AsyncThrowingStream<PCMChunk, any Error>.Continuation) {
        synth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // A zero-length buffer marks the end.
            guard pcm.frameLength > 0 else {
                continuation.finish()
                return
            }
            continuation.yield(PCMChunk(samples: samples(pcm), sampleRate: pcm.format.sampleRate))
        }
    }

    nonisolated static func samples(_ pcm: AVAudioPCMBuffer) -> [Float] {
        let n = Int(pcm.frameLength)
        if let f = pcm.floatChannelData { return Array(UnsafeBufferPointer(start: f[0], count: n)) }
        if let s = pcm.int16ChannelData {
            let stride = pcm.format.isInterleaved ? Int(pcm.format.channelCount) : 1
            return (0..<n).map { Float(s[0][$0 * stride]) / 32768 }
        }
        return []
    }
}

/// Ends the stream if the synthesizer is cancelled, or finishes without the end marker.
private final class SynthesisDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<PCMChunk, any Error>.Continuation

    init(continuation: AsyncThrowingStream<PCMChunk, any Error>.Continuation) {
        self.continuation = continuation
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        continuation.finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // The last buffers may still be on their way; the end marker normally finishes first.
        let c = continuation
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { c.finish() }
    }
}
