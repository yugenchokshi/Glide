import Foundation

/// The OpenAI Realtime API (GA) wire format, as JSON text frames over a WebSocket.
///
/// Client → server: `session.update`, `input_audio_buffer.append`, `conversation.item.create`
/// (system messages, `function_call_output`), `conversation.item.truncate`, `response.create`,
/// `response.cancel`. Server → client: see `RealtimeServerEvent`. Audio both ways is PCM16,
/// 24 kHz, mono, base64 in the JSON. The beta event names (`response.audio.delta`,
/// `response.audio_transcript.delta`) are accepted too.
enum RealtimeProtocol {
    static let defaultModel = "gpt-realtime-2.1-mini"
    static let models = ["gpt-realtime-2.1-mini", "gpt-realtime-2.1"]
    static let sampleRate = 24_000.0
    /// Fast transcription of what the user says, for the live caption only (the realtime model
    /// hears the audio itself).
    static let transcriptionModel = "gpt-4o-mini-transcribe"
    /// Voices the realtime models take.
    static let voices: Set<String> = ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse", "marin", "cedar"]
    static let defaultVoice = "marin"

    static func voice(for preferred: String) -> String {
        let v = preferred.lowercased()
        return voices.contains(v) ? v : defaultVoice
    }

    /// `https://api.openai.com/v1` → `wss://api.openai.com/v1/realtime?model=…`.
    static func socketURL(baseURL: String, model: String) -> URL? {
        let base = OpenAISpeech.base(baseURL)
        guard var c = URLComponents(string: base + "/realtime") else { return nil }
        switch c.scheme?.lowercased() {
        case "https": c.scheme = "wss"
        case "http": c.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "model", value: model)]
        return c.url
    }

    static func socketRequest(baseURL: String, apiKey: String, model: String) -> URLRequest? {
        guard let url = socketURL(baseURL: baseURL, model: model) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("Glide/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        return req
    }
}

/// How the realtime session is set up.
struct RealtimeSessionConfig: Equatable, Sendable {
    var instructions: String = RealtimeGlide.instructions
    var voice: String = RealtimeProtocol.defaultVoice
    var tools: [RealtimeTool] = RealtimeGlide.tools
    /// Server VAD: this much silence ends the user's turn.
    var silenceMs = 350
    var prefixPaddingMs = 300
    var vadThreshold = 0.5
    var transcriptionModel = RealtimeProtocol.transcriptionModel
    var speed = 1.0
}

struct RealtimeTool: Equatable, Sendable {
    var name: String
    var description: String
    /// Parameter name → (description, allowed values or nil).
    var parameters: [(name: String, description: String, choices: [String]?)]

    static func == (a: RealtimeTool, b: RealtimeTool) -> Bool {
        a.name == b.name && a.description == b.description
            && a.parameters.map(\.name) == b.parameters.map(\.name)
            && a.parameters.map(\.description) == b.parameters.map(\.description)
            && a.parameters.map(\.choices) == b.parameters.map(\.choices)
    }

    var json: [String: Any] {
        var props: [String: Any] = [:]
        for p in parameters {
            var d: [String: Any] = ["type": "string", "description": p.description]
            if let choices = p.choices { d["enum"] = choices }
            props[p.name] = d
        }
        return ["type": "function", "name": name, "description": description,
                "parameters": ["type": "object", "properties": props, "required": parameters.map(\.name)]]
    }
}

/// Events Glide sends.
enum RealtimeClientEvent: Equatable, Sendable {
    case sessionUpdate(RealtimeSessionConfig)
    case appendAudio(Data)
    case systemMessage(String)
    case functionOutput(callID: String, output: String)
    case truncate(itemID: String, contentIndex: Int, audioEndMs: Int)
    case createResponse
    case cancelResponse(responseID: String?)

    var json: [String: Any] {
        switch self {
        case .sessionUpdate(let c):
            let session: [String: Any] = [
                "type": "realtime",
                "instructions": c.instructions,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": Int(RealtimeProtocol.sampleRate)],
                        "noise_reduction": ["type": "near_field"],
                        "transcription": ["model": c.transcriptionModel],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": c.vadThreshold,
                            "prefix_padding_ms": c.prefixPaddingMs,
                            "silence_duration_ms": c.silenceMs,
                            "create_response": true,
                            "interrupt_response": true,
                        ] as [String: Any],
                    ] as [String: Any],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": Int(RealtimeProtocol.sampleRate)],
                        "voice": c.voice,
                        "speed": c.speed,
                    ] as [String: Any],
                ],
                "tools": c.tools.map(\.json),
                "tool_choice": "auto",
            ]
            return ["type": "session.update", "session": session]
        case .appendAudio(let pcm):
            return ["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()]
        case .systemMessage(let text):
            return ["type": "conversation.item.create",
                    "item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": text]]] as [String: Any]]
        case .functionOutput(let callID, let output):
            return ["type": "conversation.item.create",
                    "item": ["type": "function_call_output", "call_id": callID, "output": output]]
        case .truncate(let itemID, let contentIndex, let audioEndMs):
            return ["type": "conversation.item.truncate", "item_id": itemID, "content_index": contentIndex, "audio_end_ms": audioEndMs]
        case .createResponse:
            return ["type": "response.create"]
        case .cancelResponse(let id):
            var d: [String: Any] = ["type": "response.cancel"]
            if let id { d["response_id"] = id }
            return d
        }
    }

    /// One JSON text frame.
    func encoded() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The `type` of an encoded frame (tests, logs).
    static func type(of frame: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])?["type"] as? String
    }
}

struct RealtimeFunctionCall: Equatable, Sendable {
    var callID: String
    var name: String
    var arguments: String
    var itemID: String?
}

/// Events the server sends that Glide acts on.
enum RealtimeServerEvent: Equatable, Sendable {
    case sessionCreated
    case sessionUpdated
    case speechStarted(itemID: String?, audioStartMs: Int?)
    case speechStopped(itemID: String?)
    case inputTranscriptDelta(itemID: String, delta: String)
    case inputTranscriptCompleted(itemID: String, transcript: String)
    case responseCreated(responseID: String?)
    case outputItemAdded(responseID: String?, itemID: String?, itemType: String?)
    case audioDelta(responseID: String?, itemID: String, contentIndex: Int, audio: Data)
    case audioDone(itemID: String?)
    case transcriptDelta(itemID: String, delta: String)
    case transcriptDone(itemID: String, transcript: String)
    case functionCallDone(RealtimeFunctionCall)
    case responseDone(responseID: String?, status: String?, functionCalls: [RealtimeFunctionCall])
    case error(type: String?, code: String?, message: String)
    case other(String)

    static func decode(_ text: String) -> RealtimeServerEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        func s(_ k: String, _ o: [String: Any] = obj) -> String? { o[k] as? String }
        func i(_ k: String, _ o: [String: Any] = obj) -> Int? { (o[k] as? NSNumber)?.intValue }
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "input_audio_buffer.speech_started": return .speechStarted(itemID: s("item_id"), audioStartMs: i("audio_start_ms"))
        case "input_audio_buffer.speech_stopped": return .speechStopped(itemID: s("item_id"))
        case "conversation.item.input_audio_transcription.delta":
            return .inputTranscriptDelta(itemID: s("item_id") ?? "", delta: s("delta") ?? "")
        case "conversation.item.input_audio_transcription.completed":
            return .inputTranscriptCompleted(itemID: s("item_id") ?? "", transcript: s("transcript") ?? "")
        case "response.created":
            return .responseCreated(responseID: (obj["response"] as? [String: Any]).flatMap { s("id", $0) })
        case "response.output_item.added":
            let item = obj["item"] as? [String: Any]
            return .outputItemAdded(responseID: s("response_id"), itemID: item.flatMap { s("id", $0) }, itemType: item.flatMap { s("type", $0) })
        case "response.output_audio.delta", "response.audio.delta":
            guard let itemID = s("item_id"), let b64 = s("delta"), let data = Data(base64Encoded: b64) else { return .other(type) }
            return .audioDelta(responseID: s("response_id"), itemID: itemID, contentIndex: i("content_index") ?? 0, audio: data)
        case "response.output_audio.done", "response.audio.done": return .audioDone(itemID: s("item_id"))
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.output_text.delta":
            return .transcriptDelta(itemID: s("item_id") ?? "", delta: s("delta") ?? "")
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            return .transcriptDone(itemID: s("item_id") ?? "", transcript: s("transcript") ?? "")
        case "response.function_call_arguments.done":
            guard let callID = s("call_id"), let name = s("name") else { return .other(type) }
            return .functionCallDone(RealtimeFunctionCall(callID: callID, name: name, arguments: s("arguments") ?? "{}", itemID: s("item_id")))
        case "response.done":
            let response = obj["response"] as? [String: Any] ?? [:]
            let output = response["output"] as? [[String: Any]] ?? []
            let calls = output.compactMap { item -> RealtimeFunctionCall? in
                guard s("type", item) == "function_call", let callID = s("call_id", item), let name = s("name", item) else { return nil }
                return RealtimeFunctionCall(callID: callID, name: name, arguments: s("arguments", item) ?? "{}", itemID: s("id", item))
            }
            return .responseDone(responseID: s("id", response), status: s("status", response), functionCalls: calls)
        case "error":
            let e = obj["error"] as? [String: Any] ?? obj
            return .error(type: s("type", e), code: s("code", e), message: s("message", e) ?? "Unknown error")
        default:
            return .other(type)
        }
    }
}
