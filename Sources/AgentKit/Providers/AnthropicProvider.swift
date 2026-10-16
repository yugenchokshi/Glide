import Foundation

/// Claude via the Messages API over HTTPS. Structured replies use
/// `output_config.format` (json_schema); forced tool choice is avoided because current
/// models reject it.
public struct AnthropicProvider: LLMProvider {
    public let config: ProviderConfig
    let apiKey: String

    public init(config: ProviderConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
    }

    var base: String { config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }

    /// Models that accept `output_config.effort`.
    static func supportsEffort(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable", "claude-mythos", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6", "claude-opus-4-5"]
            .contains { model.hasPrefix($0) }
    }

    /// Models where server-side refusal fallback ("default" routing) is supported.
    static func supportsFallbacks(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains { model == $0 }
    }

    func body(_ req: LLMRequest, structured: Bool, fallbacks: Bool) -> JSONValue {
        var messages: [JSONValue] = []
        for m in req.messages {
            var content: [JSONValue] = m.images.map { img in
                ["type": "image", "source": ["type": "base64", "media_type": .string(img.mediaType), "data": .string(img.data.base64EncodedString())]]
            }
            content.append(["type": "text", "text": .string(m.text)])
            messages.append(["role": .string(m.role.rawValue), "content": .array(content)])
        }
        var system = req.system
        var outputConfig: [String: JSONValue] = [:]
        if let schema = req.schema {
            if structured {
                outputConfig["format"] = ["type": "json_schema", "schema": schema]
            } else {
                system += "\n\nReply with only a JSON object that matches this JSON schema, no prose:\n" + schema.jsonString()
            }
        }
        if let effort = req.effort, Self.supportsEffort(req.model) { outputConfig["effort"] = .string(effort) }
        var b: [String: JSONValue] = [
            "model": .string(req.model),
            "max_tokens": .number(Double(req.maxTokens)),
            "system": .string(system),
            "messages": .array(messages),
        ]
        if !outputConfig.isEmpty { b["output_config"] = .object(outputConfig) }
        if fallbacks { b["fallbacks"] = "default" }
        return .object(b)
    }

    public func complete(_ req: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.missingKey(config.name) }
        guard let url = URL(string: base + "/v1/messages") else { throw LLMError.notConfigured("Invalid Anthropic base URL") }
        let start = Date()
        var structured = req.schema != nil
        var fallbacks = Self.supportsFallbacks(req.model) && base.contains("api.anthropic.com")
        var attempt = 0
        while true {
            attempt += 1
            var h = headers
            if fallbacks { h["anthropic-beta"] = "server-side-fallback-2026-07-01" }
            let request = HTTP.jsonRequest(url: url, headers: h, body: body(req, structured: structured, fallbacks: fallbacks), timeout: req.timeout)
            do {
                let (data, _) = try await HTTP.send(request, secrets: [apiKey])
                return try parse(data, req: req, start: start)
            } catch LLMError.http(400, let message) where attempt < 3 {
                // Degrade gracefully on endpoints/models without these features.
                if fallbacks && message.lowercased().contains("fallback") { fallbacks = false; continue }
                if structured && (message.contains("output_config") || message.contains("format") || message.contains("schema")) { structured = false; continue }
                throw LLMError.http(400, message)
            }
        }
    }

    func parse(_ data: Data, req: LLMRequest, start: Date) throws -> LLMResponse {
        guard let v = try? JSONValue.parse(data) else { throw LLMError.decoding("invalid JSON from Anthropic") }
        let stop = v["stop_reason"]?.stringValue
        if stop == "refusal" {
            throw LLMError.refusal(v["stop_details"]?["explanation"]?.stringValue ?? "")
        }
        let text = (v["content"]?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
        let usage = LLMUsage(inputTokens: v["usage"]?["input_tokens"]?.intValue ?? 0, outputTokens: v["usage"]?["output_tokens"]?.intValue ?? 0)
        var json: JSONValue?
        if req.schema != nil {
            guard let parsed = JSONValue.extractObject(from: text) else {
                if stop == "max_tokens" { throw LLMError.invalidJSON("reply was cut off (max_tokens)") }
                throw LLMError.invalidJSON(text)
            }
            json = parsed
        }
        if text.isEmpty && json == nil { throw LLMError.emptyResponse }
        return LLMResponse(text: text, json: json, usage: usage, model: v["model"]?.stringValue ?? req.model,
                           latencyMs: Date().timeIntervalSince(start) * 1000, stopReason: stop)
    }

    public func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw LLMError.missingKey(config.name) }
        guard let url = URL(string: base + "/v1/models?limit=100") else { throw LLMError.notConfigured("Invalid base URL") }
        let (data, _) = try await HTTP.send(HTTP.jsonRequest(url: url, method: "GET", headers: headers, body: nil, timeout: 20), secrets: [apiKey])
        let v = try JSONValue.parse(data)
        return (v["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }
}
