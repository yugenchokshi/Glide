import Foundation
import AgentKit

/// OpenAI text-to-speech: request building, model choice, and streaming raw PCM so playback
/// starts with the first packet instead of after the whole clip.
enum OpenAISpeech {
    /// `response_format: pcm` is 24 kHz, 16-bit signed little-endian, mono.
    static let pcmSampleRate = 24_000.0
    /// Used when the model list can't be read.
    static let fallbackModel = "gpt-4o-mini-tts"

    /// Voices for the picker. The gpt-*-tts models take all of them; tts-1 takes the classic set.
    static let voices = ["marin", "cedar", "coral", "sage", "alloy", "ash", "ballad", "echo", "fable", "nova", "onyx", "shimmer", "verse"]
    static let classicVoices: Set<String> = ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]

    /// A warm voice that every speech model has.
    static func defaultVoice(for model: String) -> String {
        isSteerable(model) ? "coral" : "nova"
    }

    /// The gpt-*-tts models follow speaking instructions; tts-1 doesn't take them.
    static func isSteerable(_ model: String) -> Bool { model.lowercased().hasPrefix("gpt-") }

    /// How Glide sounds: a friend helping out, not an announcer.
    static let instructions = "Speak naturally and warmly, like a helpful friend sitting next to the user. Relaxed, conversational pace; short and clear."

    /// The best speech model in a `/models` list: the newest gpt-*-tts, then tts-1-hd, then
    /// tts-1, then anything else with "tts" in its id. Nil when there is none.
    static func bestModel(from ids: [String]) -> String? {
        let candidates = ids.filter { id in
            let l = id.lowercased()
            return l.contains("tts") && !l.contains("realtime") && !l.contains("transcribe")
        }
        return candidates.max { rank($0).lexicographicallyPrecedes(rank($1)) }
    }

    /// Orders speech models: family first (gpt > tts-1-hd > tts-1 > other), then the gpt version
    /// (5 beats 4o), the full model over -mini, the plain alias over a dated snapshot, and a
    /// later snapshot over an earlier one.
    static func rank(_ id: String) -> [Double] {
        let l = id.lowercased()
        // A snapshot ends in a date (-2025-03-20) or a number (-1106); later ones sort higher.
        let parts = l.split(separator: "-")
        let dated = Double(parts.suffix(3).joined()).flatMap { $0 > 20_000_000 ? $0 : nil }
        let date = dated ?? parts.last.flatMap { $0.count >= 4 && $0.allSatisfy(\.isNumber) ? Double($0) : nil }
        if l.hasPrefix("gpt-") {
            let rest = l.dropFirst(4)
            let digits = rest.prefix { $0.isNumber || $0 == "." }
            let version = Double(digits) ?? 0
            let mini = l.contains("-mini") || l.contains("-nano") ? 0.0 : 1.0
            return [3, version, mini, date == nil ? 1 : 0, date ?? 0]
        }
        if l.hasPrefix("tts-1-hd") { return [2, 0, 0, date == nil ? 1 : 0, date ?? 0] }
        if l.hasPrefix("tts-1") { return [1, 0, 0, date == nil ? 1 : 0, date ?? 0] }
        return [0, 0, 0, 0, date ?? 0]
    }

    static func base(_ baseURL: String) -> String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// `POST {base}/audio/speech` for streamed PCM.
    static func speechRequest(baseURL: String, apiKey: String, model: String, voice: String, text: String,
                              format: String = "pcm", timeout: TimeInterval = 6) throws -> URLRequest {
        guard let url = URL(string: base(baseURL) + "/audio/speech"), url.scheme?.hasPrefix("http") == true else {
            throw SpeechClientError.badURL
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: String] = ["model": model, "input": text, "voice": voice, "response_format": format]
        if isSteerable(model) { body["instructions"] = instructions }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    static func modelsRequest(baseURL: String, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: base(baseURL) + "/models"), url.scheme?.hasPrefix("http") == true else { throw SpeechClientError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "GET"
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// The OpenAI provider to speak with: the built-in one first, then any other enabled OpenAI
    /// provider that has a key.
    static func route(_ settings: AppSettings, key: (String) -> String?) -> (baseURL: String, apiKey: String)? {
        let providers = settings.providers.filter { $0.kind == .openai && $0.enabled }
            .sorted { ($0.id == "openai" ? 0 : 1) < ($1.id == "openai" ? 0 : 1) }
        for p in providers {
            if let k = key(p.id)?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return (p.baseURL, k) }
        }
        return nil
    }

    /// Turns little-endian 16-bit samples into floats, carrying an odd trailing byte over.
    static func decodePCM16(_ bytes: [UInt8], carry: inout UInt8?) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(bytes.count / 2 + 1)
        var i = 0
        if let c = carry, let first = bytes.first {
            out.append(Float(Int16(bitPattern: UInt16(c) | UInt16(first) << 8)) / 32768)
            carry = nil
            i = 1
        }
        while i + 1 < bytes.count {
            out.append(Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768)
            i += 2
        }
        if i < bytes.count { carry = bytes[i] }
        return out
    }
}

enum SpeechClientError: Error, Equatable, CustomStringConvertible {
    case badURL
    case http(Int, String)
    case noSpeechModel

    var description: String {
        switch self {
        case .badURL: return "The OpenAI base URL isn't valid."
        case .http(let code, let message): return "OpenAI speech returned \(code): \(message)"
        case .noSpeechModel: return "This OpenAI account has no speech model."
        }
    }
}

/// Talks to the speech endpoint. Behind a protocol so tests can stand in for the network.
protocol OpenAISpeechStreaming: Sendable {
    func listModels(baseURL: String, apiKey: String) async throws -> [String]
    func stream(baseURL: String, apiKey: String, model: String, voice: String, text: String) -> AsyncThrowingStream<PCMChunk, any Error>
}

struct OpenAISpeechClient: OpenAISpeechStreaming {
    let session: URLSession

    /// Its own session (connections are reused between lines, which keeps first audio fast).
    static let sharedSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": "Glide/1.0 (macOS)"]
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    init(session: URLSession = OpenAISpeechClient.sharedSession) {
        self.session = session
    }

    func listModels(baseURL: String, apiKey: String) async throws -> [String] {
        let (data, response) = try await session.data(for: OpenAISpeech.modelsRequest(baseURL: baseURL, apiKey: apiKey))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SpeechClientError.http(code, Self.message(data, hiding: apiKey)) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }
    }

    /// Streams PCM as it arrives: ~50 ms for the first piece, ~100 ms after that.
    func stream(baseURL: String, apiKey: String, model: String, voice: String, text: String) -> AsyncThrowingStream<PCMChunk, any Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try OpenAISpeech.speechRequest(baseURL: baseURL, apiKey: apiKey, model: model, voice: voice, text: text)
                    let (bytes, response) = try await session.bytes(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(code) else {
                        var body: [UInt8] = []
                        for try await b in bytes {
                            body.append(b)
                            if body.count > 4096 { break }
                        }
                        throw SpeechClientError.http(code, Self.message(Data(body), hiding: apiKey))
                    }
                    var buffer: [UInt8] = []
                    buffer.reserveCapacity(4800)
                    var carry: UInt8?
                    var first = true
                    for try await b in bytes {
                        buffer.append(b)
                        // 2400 bytes = 50 ms; 4800 = 100 ms of 24 kHz 16-bit audio.
                        if buffer.count >= (first ? 2400 : 4800) {
                            continuation.yield(PCMChunk(samples: OpenAISpeech.decodePCM16(buffer, carry: &carry), sampleRate: OpenAISpeech.pcmSampleRate))
                            buffer.removeAll(keepingCapacity: true)
                            first = false
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(PCMChunk(samples: OpenAISpeech.decodePCM16(buffer, carry: &carry), sampleRate: OpenAISpeech.pcmSampleRate))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The error message from an OpenAI error body, short, and never containing the key.
    static func message(_ data: Data, hiding secret: String) -> String {
        var text: String
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            text = message
        } else {
            text = String(decoding: data.prefix(400), as: UTF8.self)
        }
        if !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "•••") }
        return String(text.prefix(200))
    }
}
