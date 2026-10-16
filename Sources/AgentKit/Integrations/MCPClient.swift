import Foundation

public struct MCPTool: Sendable, Hashable, Codable {
    public var server: String
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    /// Name exposed to models: "server__tool".
    public var qualifiedName: String { "\(server)__\(name)" }
}

public enum MCPError: Error, LocalizedError, Sendable {
    case notConnected(String)
    case rpc(Int, String)
    case transport(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected(let s): return "MCP server \(s) isn't connected."
        case .rpc(let c, let m): return "MCP error \(c): \(m)"
        case .transport(let m): return "MCP transport error: \(m)"
        case .timeout(let m): return "MCP request timed out: \(m)"
        }
    }
}

protocol MCPTransport: Sendable {
    func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue
    func notify(_ method: String, params: JSONValue?) async throws
    func close() async
}

/// A Model Context Protocol client over stdio or Streamable HTTP.
public actor MCPClient {
    public nonisolated let config: MCPServerConfig
    private var transport: (any MCPTransport)?
    public private(set) var tools: [MCPTool] = []
    public private(set) var serverName: String?

    public init(config: MCPServerConfig) {
        self.config = config
    }

    public static let protocolVersion = "2025-06-18"

    public func connect(credentials: CredentialStore = .shared) async throws {
        let t: any MCPTransport
        switch config.transport {
        case .stdio:
            t = try StdioTransport(command: config.command, arguments: config.arguments, environment: config.environment)
        case .http:
            guard let url = URL(string: config.url) else { throw MCPError.transport("invalid URL") }
            var headers: [String: String] = [:]
            for h in config.secretHeaders {
                if let v = credentials.get(.mcpHeader(server: config.id, header: h)) { headers[h] = v }
            }
            t = HTTPTransport(url: url, headers: headers)
        }
        transport = t
        let result = try await t.request("initialize", params: [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": [:],
            "clientInfo": ["name": "NotchBuddy", "version": "1.0.0"],
        ], timeout: 30)
        serverName = result["serverInfo"]?["name"]?.stringValue
        try await t.notify("notifications/initialized", params: nil)
        try await refreshTools()
    }

    public func refreshTools() async throws {
        guard let transport else { throw MCPError.notConnected(config.name) }
        var all: [MCPTool] = []
        var cursor: String?
        repeat {
            let params: JSONValue? = cursor.map { ["cursor": .string($0)] }
            let r = try await transport.request("tools/list", params: params, timeout: 30)
            for t in r["tools"]?.arrayValue ?? [] {
                guard let name = t["name"]?.stringValue else { continue }
                all.append(MCPTool(server: Self.slug(config.name), name: name, description: t["description"]?.stringValue ?? "",
                                   inputSchema: t["inputSchema"] ?? ["type": "object"]))
            }
            cursor = r["nextCursor"]?.stringValue
        } while cursor != nil && all.count < 500
        tools = all
    }

    /// Calls a tool and returns its text content (and whether the server flagged an error).
    public func call(_ name: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        guard let transport else { throw MCPError.notConnected(config.name) }
        let r = try await transport.request("tools/call", params: ["name": .string(name), "arguments": arguments], timeout: 120)
        let text = (r["content"]?.arrayValue ?? []).compactMap { c -> String? in
            if c["type"]?.stringValue == "text" { return c["text"]?.stringValue }
            if let res = c["resource"], let t = res["text"]?.stringValue { return t }
            return nil
        }.joined(separator: "\n")
        let structured = r["structuredContent"].map { $0.jsonString() }
        return (text.isEmpty ? (structured ?? "") : text, r["isError"]?.boolValue ?? false)
    }

    public func disconnect() async {
        await transport?.close()
        transport = nil
        tools = []
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(lowered).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

// MARK: - stdio transport

final class StdioTransport: MCPTransport, @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var buffer = Data()

    init(command: String, arguments: [String], environment: [String: String]) throws {
        // Run through a login shell so user-installed tools (npx, uvx, node) are on PATH.
        let quoted = ([command] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec " + quoted]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { self.failAll(MCPError.transport("server exited")); handle.readabilityHandler = nil; return }
            self.consume(chunk)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] _ in self?.failAll(MCPError.transport("server process exited")) }
        try process.run()
    }

    private func consume(_ chunk: Data) {
        var messages: [JSONValue] = []
        lock.withLock {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let v = try? JSONValue.parse(Data(line)) { messages.append(v) }
            }
        }
        for m in messages { handle(m) }
    }

    private func handle(_ message: JSONValue) {
        guard let id = message["id"]?.intValue else { return } // notifications / server requests ignored
        if message["method"] != nil {
            // Server-to-client request (e.g. ping): answer with an empty result.
            try? write(["jsonrpc": "2.0", "id": .number(Double(id)), "result": [:]])
            return
        }
        let cont = lock.withLock { pending.removeValue(forKey: id) }
        if let err = message["error"] {
            cont?.resume(throwing: MCPError.rpc(err["code"]?.intValue ?? -1, err["message"]?.stringValue ?? "error"))
        } else {
            cont?.resume(returning: message["result"] ?? .null)
        }
    }

    private func failAll(_ error: Error) {
        let all = lock.withLock { () -> [CheckedContinuation<JSONValue, Error>] in
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        all.forEach { $0.resume(throwing: error) }
    }

    private func write(_ message: JSONValue) throws {
        var data = message.data()
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        let id = lock.withLock { () -> Int in defer { nextID += 1 }; return nextID }
        var msg: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { msg["params"] = params }
        let message = JSONValue.object(msg)
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
                    self.lock.withLock { self.pending[id] = c }
                    do { try self.write(message) } catch {
                        if let c = self.lock.withLock({ self.pending.removeValue(forKey: id) }) { c.resume(throwing: error) }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                if let c = self.lock.withLock({ self.pending.removeValue(forKey: id) }) { c.resume(throwing: MCPError.timeout(method)) }
                throw MCPError.timeout(method)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    func notify(_ method: String, params: JSONValue?) async throws {
        var msg: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { msg["params"] = params }
        try write(.object(msg))
    }

    func close() async {
        stdout.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        failAll(MCPError.transport("closed"))
    }
}

// MARK: - Streamable HTTP transport

actor HTTPTransport: MCPTransport {
    let url: URL
    let headers: [String: String]
    var sessionID: String?
    var nextID = 1

    init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    private func post(_ message: JSONValue, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { r.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = message.data()
        let (data, response) = try await HTTP.session.data(for: r)
        guard let http = response as? HTTPURLResponse else { throw MCPError.transport("no response") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.transport("HTTP \(http.statusCode): \(HTTP.errorMessage(data, secrets: Array(headers.values)))")
        }
        return (data, http)
    }

    func request(_ method: String, params: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        var msg: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let params { msg["params"] = params }
        let (data, http) = try await post(.object(msg), timeout: timeout)
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        var candidates: [JSONValue] = []
        if contentType.contains("text/event-stream") {
            let text = String(decoding: data, as: UTF8.self)
            for event in text.components(separatedBy: "\n\n") {
                let payload = event.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }.joined()
                if let v = try? JSONValue.parse(payload) { candidates.append(v) }
            }
        } else if let v = try? JSONValue.parse(data) {
            candidates = v.arrayValue ?? [v]
        }
        guard let reply = candidates.first(where: { $0["id"]?.intValue == id }) else { throw MCPError.transport("no reply for \(method)") }
        if let err = reply["error"] { throw MCPError.rpc(err["code"]?.intValue ?? -1, err["message"]?.stringValue ?? "error") }
        return reply["result"] ?? .null
    }

    func notify(_ method: String, params: JSONValue?) async throws {
        var msg: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { msg["params"] = params }
        _ = try await post(.object(msg), timeout: 15)
    }

    func close() async {
        guard let sessionID else { return }
        var r = URLRequest(url: url)
        r.httpMethod = "DELETE"
        r.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await HTTP.session.data(for: r)
    }
}

/// Owns connections to the configured MCP servers.
public actor MCPManager {
    public static let shared = MCPManager()
    private var clients: [String: MCPClient] = [:]
    public private(set) var errors: [String: String] = [:]

    public init() {}

    public func sync(with configs: [MCPServerConfig]) async {
        let wanted = Dictionary(uniqueKeysWithValues: configs.filter(\.enabled).map { ($0.id, $0) })
        for (id, client) in clients where wanted[id] == nil || wanted[id] != client.config {
            await client.disconnect()
            clients[id] = nil
        }
        for (id, config) in wanted where clients[id] == nil {
            let client = MCPClient(config: config)
            do {
                try await client.connect()
                clients[id] = client
                errors[id] = nil
            } catch {
                errors[id] = error.localizedDescription
            }
        }
    }

    public func allTools() async -> [MCPTool] {
        var out: [MCPTool] = []
        for c in clients.values { out += await c.tools }
        return out
    }

    public func status() async -> [(id: String, connected: Bool, toolCount: Int, error: String?)] {
        var out: [(String, Bool, Int, String?)] = []
        for (id, c) in clients { out.append((id, true, await c.tools.count, nil)) }
        for (id, e) in errors where clients[id] == nil { out.append((id, false, 0, e)) }
        return out
    }

    public func call(qualifiedName: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        for c in clients.values {
            for t in await c.tools where t.qualifiedName == qualifiedName || t.name == qualifiedName {
                return try await c.call(t.name, arguments: arguments)
            }
        }
        throw MCPError.notConnected(qualifiedName)
    }

    public func disconnectAll() async {
        for c in clients.values { await c.disconnect() }
        clients.removeAll()
    }
}
