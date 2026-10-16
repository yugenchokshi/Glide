import Foundation

/// OpenAI and any OpenAI-compatible endpoint (Ollama, LM Studio, OpenRouter, vLLM, …) via
/// Chat Completions. Structured replies use `response_format: json_schema` with graceful
/// degradation to `json_object` and then to prompt-only JSON for endpoints without it.
public struct OpenAIProvider: LLMProvider {
    public let config: ProviderConfig
    let apiKey: String

    public init(config: ProviderConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
    }

    var base: String { config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    var headers: [String: String] {
        apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
    }

    enum JSONMode: Int { case schema, object, prompt }

    func body(_ req: LLMRequest, mode: JSONMode, effort: Bool) -> JSONValue {
        var system = req.system
        if req.schema != nil, mode != .schema {
            system += "\n\nReply with only a JSON object that matches this JSON schema, no prose:\n" + (req.schema?.jsonString() ?? "{}")
        }
        var messages: [JSONValue] = [["role": "system", "content": .string(system)]]
        for m in req.messages {
            if m.images.isEmpty {
                messages.append(["role": .string(m.role.rawValue), "content": .string(m.text)])
            } else {
                var parts: [JSONValue] = [["type": "text", "text": .string(m.text)]]
                for img in m.images {
                    parts.append(["type": "image_url", "image_url": ["url": .string("data:\(img.mediaType);base64,\(img.data.base64EncodedString())"), "detail": "high"]])
                }
                messages.append(["role": .string(m.role.rawValue), "content": .array(parts)])
            }
        }
        var b: [String: JSONValue] = ["model": .string(req.model), "messages": .array(messages)]
        if config.kind == .openai {
            b["max_completion_tokens"] = .number(Double(req.maxTokens))
        } else {
            b["max_tokens"] = .number(Double(req.maxTokens))
        }
        if let schema = req.schema {
            switch mode {
            case .schema:
                b["response_format"] = ["type": "json_schema", "json_schema": ["name": .string(req.schemaName), "schema": schema, "strict": true]]
            case .object:
                b["response_format"] = ["type": "json_object"]
            case .prompt:
                break
            }
        }
        if effort, let e = req.effort { b["reasoning_effort"] = .string(e) }
        return .object(b)
    }

    static func likelyReasoningModel(_ model: String) -> Bool {
        model.hasPrefix("gpt-5") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") || model.hasPrefix("gpt-6")
    }

    public func complete(_ req: LLMRequest) async throws -> LLMResponse {
        if config.requiresKey && apiKey.isEmpty { throw LLMError.missingKey(config.name) }
        guard let url = URL(string: base + "/chat/completions") else { throw LLMError.notConfigured("Invalid base URL for \(config.name)") }
        let start = Date()
        var mode: JSONMode = .schema
        var effort = req.effort != nil && config.kind == .openai && Self.likelyReasoningModel(req.model)
        for _ in 0..<4 {
            let request = HTTP.jsonRequest(url: url, headers: headers, body: body(req, mode: mode, effort: effort), timeout: req.timeout)
            do {
                let (data, _) = try await HTTP.send(request, secrets: [apiKey])
                return try parse(data, req: req, start: start)
            } catch LLMError.http(let code, let message) where code == 400 || code == 422 {
                let m = message.lowercased()
                if effort && m.contains("reasoning") { effort = false; continue }
                if req.schema != nil, mode != .prompt, m.contains("response_format") || m.contains("json_schema") || m.contains("schema") || m.contains("json") {
                    mode = JSONMode(rawValue: mode.rawValue + 1) ?? .prompt
                    continue
                }
                throw LLMError.http(code, message)
            }
        }
        throw LLMError.notConfigured("\(config.name) rejected every request format.")
    }

    func parse(_ data: Data, req: LLMRequest, start: Date) throws -> LLMResponse {
        guard let v = try? JSONValue.parse(data) else { throw LLMError.decoding("invalid JSON from \(config.name)") }
        guard let choice = v["choices"]?[0] else { throw LLMError.emptyResponse }
        let message = choice["message"]
        if let refusal = message?["refusal"]?.stringValue, !refusal.isEmpty { throw LLMError.refusal(refusal) }
        var text = message?["content"]?.stringValue ?? ""
        if text.isEmpty, let parts = message?["content"]?.arrayValue {
            text = parts.compactMap { $0["text"]?.stringValue }.joined()
        }
        let usage = LLMUsage(inputTokens: v["usage"]?["prompt_tokens"]?.intValue ?? 0, outputTokens: v["usage"]?["completion_tokens"]?.intValue ?? 0)
        var json: JSONValue?
        if req.schema != nil {
            guard let parsed = JSONValue.extractObject(from: text) else { throw LLMError.invalidJSON(text) }
            json = parsed
        }
        if text.isEmpty { throw LLMError.emptyResponse }
        return LLMResponse(text: text, json: json, usage: usage, model: v["model"]?.stringValue ?? req.model,
                           latencyMs: Date().timeIntervalSince(start) * 1000, stopReason: choice["finish_reason"]?.stringValue)
    }

    public func listModels() async throws -> [String] {
        if config.requiresKey && apiKey.isEmpty { throw LLMError.missingKey(config.name) }
        guard let url = URL(string: base + "/models") else { throw LLMError.notConfigured("Invalid base URL") }
        let (data, _) = try await HTTP.send(HTTP.jsonRequest(url: url, method: "GET", headers: headers, body: nil, timeout: 20), secrets: [apiKey])
        let v = try JSONValue.parse(data)
        return (v["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }.sorted()
    }
}

/// TypeSafe's System One API (Jev). Used for fast, calibrated choices between candidate UI
/// elements; never for planning or free text.
public struct JevClient: Sendable {
    let apiKey: String
    let model: String
    let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    public init(apiKey: String, model: String = "jev-latest") {
        self.apiKey = apiKey
        self.model = model
    }

    public struct ChoiceAnswer: Sendable {
        public let choice: String
        public let confidence: Double
        public let probabilities: [String: Double]
        public let usage: LLMUsage
        public let latencyMs: Double
    }

    /// Asks a single Choice question. `options` maps option keys (≤255) to descriptions.
    public func choose(state: JSONValue, instructions: String, options: [String: String]) async throws -> ChoiceAnswer {
        let start = Date()
        let criteria = JSONValue.object(Dictionary(uniqueKeysWithValues: options.prefix(255).map { ($0.key, JSONValue.string($0.value)) }))
        let body: JSONValue = [
            "state": state, "model": .string(model),
            "questions": ["pick": ["type": "choice", "instructions": .string(instructions), "criteria": criteria]],
        ]
        let req = HTTP.jsonRequest(url: endpoint, headers: ["Authorization": "Bearer \(apiKey)"], body: body, timeout: 20)
        let (data, _) = try await HTTP.send(req, retries: 1, secrets: [apiKey])
        let v = try JSONValue.parse(data)
        guard let answer = v["answers"]?["pick"], let choice = answer["choice"]?.stringValue else { throw LLMError.decoding("Jev answer missing") }
        var probs: [String: Double] = [:]
        for (k, p) in answer["probabilities"]?.objectValue ?? [:] { probs[k] = p.doubleValue ?? 0 }
        return ChoiceAnswer(choice: choice, confidence: answer["confidence"]?.doubleValue ?? 0, probabilities: probs,
                            usage: LLMUsage(inputTokens: v["usage"]?["input_tokens"]?.intValue ?? 0, outputTokens: v["usage"]?["output_tokens"]?.intValue ?? 0),
                            latencyMs: Date().timeIntervalSince(start) * 1000)
    }

    public func test() async throws {
        _ = try await choose(state: "The user wants to open a new note.", instructions: "Which button should be pressed?",
                             options: ["new_note": "A button labeled New Note", "delete": "A button labeled Delete"])
    }
}
