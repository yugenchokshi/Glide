import Foundation

/// Optional Composio integration over its v3.1 REST API (sessions / tool router). The user's
/// own project API key is stored in the Keychain; OAuth for third-party apps runs on
/// Composio's hosted connect flow in the browser, so no client secret ever ships in the app.
public struct ComposioClient: Sendable {
    public struct Toolkit: Sendable, Identifiable, Hashable {
        public var id: String { slug }
        public var slug: String
        public var name: String
        public var description: String
        public var logo: String?
        public var isNoAuth: Bool
        public var connectedAccountID: String?
        public var connectionStatus: String?
        public var isConnected: Bool { isNoAuth || connectedAccountID != nil }
    }

    public struct ToolSchema: Sendable, Hashable {
        public var slug: String
        public var toolkit: String
        public var description: String
        public var inputSchema: JSONValue?
    }

    public struct SearchResult: Sendable {
        public var tools: [ToolSchema]
        public var guidance: [String]
        public var missingConnections: [String]
    }

    public struct ExecuteResult: Sendable {
        public var successful: Bool
        public var data: JSONValue
        public var error: String?
        public var needsInput: Bool
    }

    let apiKey: String
    let baseURL: String
    let userID: String

    public init(apiKey: String, settings: ComposioSettings) {
        self.apiKey = apiKey
        self.baseURL = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.userID = settings.userID
    }

    private func request(_ path: String, method: String = "POST", body: JSONValue? = nil, query: [URLQueryItem] = [], timeout: TimeInterval = 60) async throws -> JSONValue {
        guard var comps = URLComponents(string: baseURL + path) else { throw LLMError.notConfigured("Invalid Composio URL") }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw LLMError.notConfigured("Invalid Composio URL") }
        let req = HTTP.jsonRequest(url: url, method: method, headers: ["x-api-key": apiKey], body: body, timeout: timeout)
        let (data, _) = try await HTTP.send(req, retries: 1, secrets: [apiKey])
        if data.isEmpty { return .null }
        return (try? JSONValue.parse(data)) ?? .null
    }

    /// Creates a session for this user with connection management and the remote workbench
    /// disabled: Glide's own planner decides what runs.
    public func createSession() async throws -> String {
        let body: JSONValue = [
            "user_id": .string(userID),
            "manage_connections": ["enable": false],
            "workbench": ["enable": false],
        ]
        let r = try await request("/tool_router/session", body: body)
        guard let id = r["session_id"]?.stringValue else { throw LLMError.decoding("Composio session id missing") }
        return id
    }

    public func toolkits(sessionID: String, search: String? = nil, connectedOnly: Bool = false, limit: Int = 50) async throws -> [Toolkit] {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let search, !search.isEmpty { q.append(URLQueryItem(name: "search", value: search)) }
        if connectedOnly { q.append(URLQueryItem(name: "is_connected", value: "true")) }
        let r = try await request("/tool_router/session/\(sessionID)/toolkits", method: "GET", query: q)
        return (r["items"]?.arrayValue ?? []).compactMap { t in
            guard let slug = t["slug"]?.stringValue else { return nil }
            let account = t["connected_account"]
            return Toolkit(slug: slug, name: t["name"]?.stringValue ?? slug, description: t["meta"]?["description"]?.stringValue ?? "",
                           logo: t["meta"]?["logo"]?.stringValue, isNoAuth: t["is_no_auth"]?.boolValue ?? false,
                           connectedAccountID: (account?.isNull ?? true) ? nil : account?["id"]?.stringValue,
                           connectionStatus: account?["status"]?.stringValue)
        }
    }

    /// Starts Composio's hosted auth flow for a toolkit; open the returned URL in the browser.
    public func link(sessionID: String, toolkit: String, callbackURL: String?) async throws -> (redirectURL: URL, connectedAccountID: String) {
        var body: [String: JSONValue] = ["toolkit": .string(toolkit)]
        if let callbackURL, !callbackURL.isEmpty { body["callback_url"] = .string(callbackURL) }
        let r = try await request("/tool_router/session/\(sessionID)/link", body: .object(body))
        guard let s = r["redirect_url"]?.stringValue, let url = URL(string: s) else { throw LLMError.decoding("Composio redirect URL missing") }
        return (url, r["connected_account_id"]?.stringValue ?? "")
    }

    public func disconnect(connectedAccountID: String) async throws {
        _ = try await request("/connected_accounts/\(connectedAccountID)", method: "DELETE")
    }

    /// Finds tools for a use case; returns schemas and which toolkits still need connecting.
    public func search(sessionID: String, useCase: String) async throws -> SearchResult {
        let r = try await request("/tool_router/session/\(sessionID)/search", body: ["queries": [["use_case": .string(String(useCase.prefix(1000)))]]])
        var slugs: [String] = []
        var guidance: [String] = []
        for res in r["results"]?.arrayValue ?? [] {
            slugs += (res["primary_tool_slugs"]?.arrayValue ?? []).compactMap(\.stringValue)
            slugs += (res["related_tool_slugs"]?.arrayValue ?? []).compactMap(\.stringValue).prefix(3)
            if let g = res["execution_guidance"]?.stringValue { guidance.append(g) }
            guidance += (res["known_pitfalls"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        let schemas = r["tool_schemas"]?.objectValue ?? [:]
        var seen = Set<String>()
        let tools: [ToolSchema] = slugs.compactMap { slug in
            guard seen.insert(slug).inserted else { return nil }
            let s = schemas[slug]
            return ToolSchema(slug: slug, toolkit: s?["toolkit"]?.stringValue ?? s?["toolkit_slug"]?.stringValue ?? "",
                              description: s?["description"]?.stringValue ?? "", inputSchema: s?["input_schema"])
        }
        let missing = (r["toolkit_connection_statuses"]?.arrayValue ?? [])
            .filter { $0["has_active_connection"]?.boolValue == false && $0["instant_account"] == nil }
            .compactMap { $0["toolkit"]?.stringValue }
        return SearchResult(tools: Array(tools.prefix(8)), guidance: Array(guidance.prefix(4)), missingConnections: missing)
    }

    public func execute(sessionID: String, tool: String, arguments: JSONValue) async throws -> ExecuteResult {
        let r = try await request("/tool_router/session/\(sessionID)/execute", body: ["tool_slug": .string(tool), "arguments": arguments], timeout: 120)
        let type = r["result_type"]?.stringValue ?? (r["error"]?.isNull == false ? "failed" : "completed")
        return ExecuteResult(successful: type == "completed", data: r["data"] ?? .null,
                             error: r["error"]?.stringValue, needsInput: type == "input_required")
    }
}

/// Keeps the Composio session id in settings so it is created once per install.
public enum ComposioSessionStore {
    @MainActor
    public static func ensureSession(store: SettingsStore = .shared, credentials: CredentialStore = .shared) async throws -> (ComposioClient, String) {
        guard let key = credentials.get(.composio), !key.isEmpty else { throw LLMError.missingKey("Composio") }
        let client = ComposioClient(apiKey: key, settings: store.settings.composio)
        if let id = store.settings.composio.sessionID { return (client, id) }
        let id = try await client.createSession()
        store.settings.composio.sessionID = id
        return (client, id)
    }
}
