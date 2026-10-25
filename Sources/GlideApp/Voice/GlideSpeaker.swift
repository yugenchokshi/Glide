import Foundation
import os
import AgentKit

/// Glide's voice. The natural OpenAI voice with the user's own key when the engine is
/// `.openAI`; Apple's best installed voice offline, without a key, after any error, or with
/// `.apple`. Short phrases Glide says often ("On it.", "Opening ChatGPT.") are kept in memory
/// so they start instantly the next time; nothing is written to disk.
@MainActor
final class GlideSpeaker: VoiceSpeaker {
    static let shared = GlideSpeaker(settings: { SettingsStore.shared.settings },
                                     key: { CredentialStore.shared.get(.provider($0)) },
                                     openAI: OpenAISpeechClient(), apple: AppleSpeechSource(), player: PCMPlayer())

    private let settings: () -> AppSettings
    private let key: (String) -> String?
    private let openAI: any OpenAISpeechStreaming
    private let apple: any AppleSpeechStreaming
    private let player: any PCMPlaying
    private var current: Task<Void, Never>?
    private var currentID = 0

    /// Speech model picked from `/models`, per base URL, when the setting is empty. Listed once.
    private(set) var resolvedModels: [String: String] = [:]
    /// After a failure the natural voice rests a while, so an offline Mac doesn't wait on the
    /// network before every line.
    private(set) var openAIFailedAt: Date?
    var cooldownSeconds: Double = 60
    var clock: () -> Date = { Date() }
    /// Which voice said the last line (for tests and logs).
    private(set) var lastEngine: VoiceEngine?
    let cache = PhraseCache()

    init(settings: @escaping () -> AppSettings, key: @escaping (String) -> String?, openAI: any OpenAISpeechStreaming,
         apple: any AppleSpeechStreaming, player: any PCMPlaying) {
        self.settings = settings
        self.key = key
        self.openAI = openAI
        self.apple = apple
        self.player = player
    }

    func speak(_ text: String, onAudioStart: @escaping @MainActor (Bool) -> Void) async {
        await speak(text, voice: settings().voice, onAudioStart: onAudioStart)
    }

    /// Settings › Voice "Hear it": the given voice settings rather than the saved ones.
    func preview(_ text: String, voice: VoiceSettings) {
        Task { await speak(text, voice: voice, onAudioStart: { _ in }) }
    }

    func speak(_ text: String, voice: VoiceSettings, onAudioStart: @escaping @MainActor (Bool) -> Void) async {
        stop()
        currentID += 1
        let id = currentID
        let task = Task { await self.run(text, voice: voice, onAudioStart: onAudioStart) }
        current = task
        await task.value
        if currentID == id { current = nil }
    }

    func stop() {
        current?.cancel()
        current = nil
        player.stop()
        apple.stop()
    }

    private var log: Logger { Logger(subsystem: "dev.glide", category: "voice") }

    private func run(_ text: String, voice: VoiceSettings, onAudioStart: @escaping @MainActor (Bool) -> Void) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if voice.engine == .openAI, !coolingDown, let route = OpenAISpeech.route(settings(), key: key) {
            do {
                try await speakOpenAI(text, voice: voice, route: route, onAudioStart: onAudioStart)
                lastEngine = .openAI
                return
            } catch {
                if Task.isCancelled { return }
                openAIFailedAt = clock()
                log.error("natural voice unavailable, using Apple's: \(String(describing: error), privacy: .public)")
            }
        }
        guard !Task.isCancelled else { return }
        lastEngine = .apple
        do {
            try await player.play(apple.stream(text, voiceID: voice.appleVoiceID, speakingRate: voice.speakingRate), rate: 1, onStart: onAudioStart)
        } catch {
            log.error("Apple voice failed: \(String(describing: error), privacy: .public)")
        }
    }

    private var coolingDown: Bool {
        guard let failed = openAIFailedAt else { return false }
        return clock().timeIntervalSince(failed) < cooldownSeconds
    }

    private func speakOpenAI(_ text: String, voice: VoiceSettings, route: (baseURL: String, apiKey: String),
                             onAudioStart: @escaping @MainActor (Bool) -> Void) async throws {
        let model = try await model(for: voice, route: route)
        let voiceName = voice.openAIVoice.isEmpty || (!OpenAISpeech.isSteerable(model) && !OpenAISpeech.classicVoices.contains(voice.openAIVoice))
            ? OpenAISpeech.defaultVoice(for: model) : voice.openAIVoice
        let cacheKey = PhraseCache.key(base: route.baseURL, model: model, voice: voiceName, text: text)
        let rate = voice.speakingRate
        if let cached = cache.get(cacheKey) {
            let (stream, c) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
            c.yield(cached)
            c.finish()
            try await player.play(stream, rate: rate, onStart: onAudioStart)
            return
        }
        let source = openAI.stream(baseURL: route.baseURL, apiKey: route.apiKey, model: model, voice: voiceName, text: text)
        let stream = PhraseCache.isCacheable(text) ? cache.recording(source, key: cacheKey) : source
        try await player.play(stream, rate: rate, onStart: onAudioStart)
    }

    /// The configured speech model, or the best one the account offers (listed once).
    private func model(for voice: VoiceSettings, route: (baseURL: String, apiKey: String)) async throws -> String {
        let configured = voice.openAIModel.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty { return configured }
        let base = OpenAISpeech.base(route.baseURL)
        if let known = resolvedModels[base] { return known }
        let chosen: String
        do {
            let ids = try await openAI.listModels(baseURL: route.baseURL, apiKey: route.apiKey)
            guard let best = OpenAISpeech.bestModel(from: ids) else { throw SpeechClientError.noSpeechModel }
            chosen = best
        } catch SpeechClientError.noSpeechModel {
            throw SpeechClientError.noSpeechModel
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // The list isn't essential: the default model is on every OpenAI account.
            chosen = OpenAISpeech.fallbackModel
        }
        resolvedModels[base] = chosen
        return chosen
    }
}

/// Recently spoken short phrases, in memory only.
@MainActor
final class PhraseCache {
    static let maxEntries = 24
    static let maxCharacters = 80

    private var entries: [String: PCMChunk] = [:]
    private var order: [String] = []

    static func key(base: String, model: String, voice: String, text: String) -> String {
        "\(OpenAISpeech.base(base))|\(model)|\(voice)|\(text.lowercased())"
    }

    static func isCacheable(_ text: String) -> Bool { text.count <= maxCharacters }

    var count: Int { entries.count }

    func get(_ key: String) -> PCMChunk? {
        guard let hit = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return hit
    }

    func insert(_ chunk: PCMChunk, for key: String) {
        guard !chunk.samples.isEmpty else { return }
        if entries[key] == nil, entries.count >= Self.maxEntries, let oldest = order.first {
            entries[oldest] = nil
            order.removeFirst()
        }
        entries[key] = chunk
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Passes `source` through, keeping the whole clip once it has arrived in full.
    func recording(_ source: AsyncThrowingStream<PCMChunk, any Error>, key: String) -> AsyncThrowingStream<PCMChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                var all: [Float] = []
                var rate = OpenAISpeech.pcmSampleRate
                do {
                    for try await chunk in source {
                        all += chunk.samples
                        rate = chunk.sampleRate
                        continuation.yield(chunk)
                    }
                    // Kept before finishing: finishing ends the consumer, which cancels this task.
                    if !Task.isCancelled { self?.insert(PCMChunk(samples: all, sampleRate: rate), for: key) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
