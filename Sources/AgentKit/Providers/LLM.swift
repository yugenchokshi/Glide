import Foundation

public struct LLMImage: Sendable {
    public var data: Data
    public var mediaType: String
    public var width: Int
    public var height: Int

    public init(pngData: Data, width: Int, height: Int) {
        self.data = pngData
        self.mediaType = "image/png"
        self.width = width
        self.height = height
    }
}

public struct LLMMessage: Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var text: String
    public var images: [LLMImage]

    public init(role: Role, text: String, images: [LLMImage] = []) {
        self.role = role
        self.text = text
        self.images = images
    }

    public static func user(_ text: String, images: [LLMImage] = []) -> LLMMessage { .init(role: .user, text: text, images: images) }
    public static func assistant(_ text: String) -> LLMMessage { .init(role: .assistant, text: text) }
}

public struct LLMRequest: Sendable {
    public var model: String
    public var system: String
    public var messages: [LLMMessage]
    /// Strict JSON schema for the reply. When set, the response's `json` is populated.
    public var schema: JSONValue?
    public var schemaName: String
    public var maxTokens: Int
    public var effort: String?
    public var timeout: TimeInterval

    public init(model: String, system: String, messages: [LLMMessage], schema: JSONValue? = nil, schemaName: String = "response",
                maxTokens: Int = 4000, effort: String? = nil, timeout: TimeInterval = 120) {
        self.model = model
        self.system = system
        self.messages = messages
        self.schema = schema
        self.schemaName = schemaName
        self.maxTokens = maxTokens
        self.effort = effort
        self.timeout = timeout
    }
}

public struct LLMUsage: Sendable, Codable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
    public static func + (a: LLMUsage, b: LLMUsage) -> LLMUsage {
        LLMUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens)
    }
}

public struct LLMResponse: Sendable {
    public var text: String
    public var json: JSONValue?
    public var usage: LLMUsage
    public var model: String
    public var latencyMs: Double
    public var stopReason: String?
}

public enum LLMError: Error, LocalizedError, Sendable {
    case missingKey(String)
    case notConfigured(String)
    case http(Int, String)
    case decoding(String)
    case refusal(String)
    case emptyResponse
    case invalidJSON(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "No API key for \(p). Add one in Settings › AI Providers."
        case .notConfigured(let s): return s
        case .http(let code, let msg):
            switch code {
            case 401: return "The API key was rejected (401). Check it in Settings › AI Providers."
            case 403: return "The provider refused access (403): \(msg)"
            case 404: return "Model or endpoint not found (404): \(msg)"
            case 429: return "Rate limited by the provider (429). Try again shortly."
            default: return "Provider error \(code): \(msg)"
            }
        case .decoding(let s): return "Couldn't read the provider response: \(s)"
        case .refusal(let s): return "The model declined this request\(s.isEmpty ? "" : ": \(s)")."
        case .emptyResponse: return "The model returned an empty response."
        case .invalidJSON(let s): return "The model returned malformed output: \(s.prefix(160))"
        case .network(let s): return "Network error: \(s)"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .http(let code, _): return code == 429 || code == 408 || code >= 500
        case .network: return true
        default: return false
        }
    }
}

public protocol LLMProvider: Sendable {
    var config: ProviderConfig { get }
    func complete(_ request: LLMRequest) async throws -> LLMResponse
    func listModels() async throws -> [String]
}

/// Shared HTTP plumbing: JSON POST/GET with retries on 429/5xx and secret-free error text.
enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 300
        c.httpAdditionalHeaders = ["User-Agent": "NotchBuddy/1.0 (macOS)"]
        return URLSession(configuration: c)
    }()

    static func send(_ request: URLRequest, retries: Int = 2, secrets: [String] = []) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw LLMError.network("no HTTP response") }
                if (200..<300).contains(http.statusCode) { return (data, http) }
                let message = errorMessage(data, secrets: secrets)
                let error = LLMError.http(http.statusCode, message)
                if error.isRetryable && attempt < retries {
                    attempt += 1
                    let retryAfter = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init) ?? pow(2, Double(attempt)) * 0.6
                    try await Task.sleep(for: .seconds(min(retryAfter, 12)))
                    continue
                }
                throw error
            } catch let error as LLMError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                if attempt < retries {
                    attempt += 1
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt)) * 0.5))
                    continue
                }
                throw LLMError.network(SecretScrubber.scrub(error.localizedDescription, knownSecrets: secrets))
            }
        }
    }

    static func errorMessage(_ data: Data, secrets: [String]) -> String {
        if let v = try? JSONValue.parse(data) {
            if let m = v["error"]?["message"]?.stringValue { return SecretScrubber.scrub(m, knownSecrets: secrets) }
            if let m = v["error"]?.stringValue { return SecretScrubber.scrub(m, knownSecrets: secrets) }
            if let m = v["message"]?.stringValue { return SecretScrubber.scrub(m, knownSecrets: secrets) }
        }
        return SecretScrubber.scrub(String(decoding: data.prefix(400), as: UTF8.self), knownSecrets: secrets)
    }

    static func jsonRequest(url: URL, method: String = "POST", headers: [String: String], body: JSONValue?, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body.data()
        }
        return r
    }
}

/// Approximate list prices (USD per million tokens) for cost estimates in task history.
public enum ModelPricing {
    static let table: [(prefix: String, input: Double, output: Double)] = [
        ("claude-fable-5-1", 10, 50), ("claude-fable-5", 10, 50), ("claude-opus-5-5", 4, 20),
        ("claude-opus-5", 5, 25), ("claude-opus-4", 5, 25), ("claude-sonnet-5-5", 2, 10),
        ("claude-sonnet-5", 2, 10), ("claude-sonnet-4", 3, 15), ("claude-haiku-5-5", 0.10, 0.50),
        ("claude-haiku-4-5", 1, 5),
    ]

    public static func cost(model: String, usage: LLMUsage) -> Double? {
        guard let row = table.first(where: { model.hasPrefix($0.prefix) }) else { return nil }
        return Double(usage.inputTokens) / 1_000_000 * row.input + Double(usage.outputTokens) / 1_000_000 * row.output
    }
}
