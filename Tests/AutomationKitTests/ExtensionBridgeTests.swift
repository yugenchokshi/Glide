import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
@testable import AutomationKit

// Tests for the Chrome extension bridge: framing and handshake rules (pure), the live localhost
// server driven by two independent WebSocket clients (a raw RFC 6455 client and Apple's
// URLSessionWebSocketTask), the extension's files, and — when Node 22+ is installed — the real
// service_worker.js running in Node against the bridge with a mocked `chrome` API.
// Everything stays on 127.0.0.1; no browser is launched and the Keychain is never touched.

// MARK: - Fixtures

enum ExtensionFixtures {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let folder = repo.appendingPathComponent("Extensions/chrome", isDirectory: true)
    /// Fixed vector checked against `openssl dgst -sha256 -hmac`.
    static let vectorToken = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    static let vectorNonce = "1700000000.0123456789abcdef0123456789abcdef"
    static let vectorClientProof = "3b008156a6efd1474751f97b3c77e825b689486546377f3ea539dbf4e842e003"
    static let vectorServerProof = "0195cb1a17e7808e1a25f47ebbd139cbff9b452324aada36b5893aa5f27b51a2"

    static func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

struct TestTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

/// Polls `condition` every 10 ms until it holds or `timeout` passes.
func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Runs `body` and returns the `BrowserError` it threw, if any.
func browserError(_ body: () async throws -> Void) async -> BrowserError? {
    do {
        try await body()
        return nil
    } catch let error as BrowserError {
        return error
    } catch {
        return nil
    }
}

extension BrowserError {
    var isTimeout: Bool { if case .timeout = self { return true } else { return false } }
    var isNotConnected: Bool { if case .notConnected = self { return true } else { return false } }
    var message: String { errorDescription ?? "" }
}

/// A bridge on a free port with an in-memory token.
func startTestBridge(token: String = BridgeAuth.mintToken(), paired: Bool = false,
                     configure: (inout ExtensionBridge.Configuration) -> Void = { _ in }) async throws
    -> (bridge: ExtensionBridge, port: Int, token: String, store: InMemoryExtensionBridgeStore) {
    var configuration = ExtensionBridge.Configuration()
    configure(&configuration)
    let bridge = ExtensionBridge(configuration: configuration)
    let store = InMemoryExtensionBridgeStore(token: token, paired: paired)
    bridge.start(port: 0, store: store)
    let port = try await bridge.waitUntilListening(timeout: 5)
    return (bridge, port, token, store)
}

final class EventRecorder: Sendable {
    private let events = Mutex<[ExtensionBridgeEvent]>([])
    func append(_ event: ExtensionBridgeEvent) { events.withLock { $0.append(event) } }
    var all: [ExtensionBridgeEvent] { events.withLock { $0 } }
    func waitFor(timeout: TimeInterval = 5, _ match: (ExtensionBridgeEvent) -> Bool) async -> Bool {
        await eventually(timeout) { all.contains(where: match) }
    }
}

/// A plain TCP client with a polled receive buffer.
final class RawClient: Sendable {
    private struct Buffer {
        var bytes: [UInt8] = []
        var ended = false
    }

    let connection: NWConnection
    private let buffer = Mutex(Buffer())

    init(port: Int) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
    }

    func start() async throws {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            // .waiting is how a refused TCP connection shows up; don't wait for a retry.
            case .failed, .cancelled, .waiting: self?.buffer.withLock { $0.ended = true }
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "raw-client"))
        receive()
        let ready = await eventually(5) {
            if case .ready = connection.state { return true }
            return ended
        }
        guard ready, !ended else { throw TestTimeout(what: "a TCP connection") }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.withLock { $0.bytes.append(contentsOf: data) } }
            if isComplete || error != nil {
                self.buffer.withLock { $0.ended = true }
            } else {
                self.receive()
            }
        }
    }

    var ended: Bool { buffer.withLock { $0.ended } }

    func send(_ bytes: [UInt8]) { connection.send(content: Data(bytes), completion: .contentProcessed { _ in }) }
    func send(_ text: String) { send(Array(text.utf8)) }
    func close() { connection.cancel() }

    /// Polls the buffer until `extract` takes a value off its front (returning it and the bytes
    /// used), the connection ends, or the timeout passes.
    func poll<T: Sendable>(timeout: TimeInterval = 5, _ extract: @Sendable ([UInt8]) -> (T, Int)?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let (value, ended): (T?, Bool) = buffer.withLock { b in
                if let (value, used) = extract(b.bytes) {
                    b.bytes.removeFirst(used)
                    return (value, false)
                }
                return (nil, b.ended)
            }
            if let value { return value }
            if ended || Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func readHead(timeout: TimeInterval = 5) async -> String? {
        await poll(timeout: timeout) { bytes in
            BridgeHTTP.headEnd(in: bytes).map { (String(decoding: bytes[..<$0], as: UTF8.self), $0) }
        }
    }

    func readFrame(timeout: TimeInterval = 5) async -> WebSocketFrame? {
        await poll(timeout: timeout) { bytes in
            guard case .frame(let frame, let used)? = try? WebSocketCodec.parse(bytes, maxPayload: 1 << 27, requireMask: false) else { return nil }
            return (frame, used)
        }
    }

    /// Everything received until the peer hung up.
    func readToEnd(timeout: TimeInterval = 5) async -> String {
        _ = await eventually(timeout) { ended }
        return buffer.withLock { String(decoding: $0.bytes, as: UTF8.self) }
    }
}

/// Plays the extension over a raw socket: precise control of frames, masks and close codes.
final class WSClient: Sendable {
    let raw: RawClient
    let nonce: String
    let token: String
    let head: String
    private let closeCode = Mutex<UInt16?>(nil)

    static let defaultHello: JSONValue = ["version": "9.9.9", "chromeVersion": "141.0.7390.1", "extensionId": .string(ExtensionBridge.extensionID), "protocol": 1]

    private init(raw: RawClient, nonce: String, token: String, head: String) {
        self.raw = raw
        self.nonce = nonce
        self.token = token
        self.head = head
    }

    static func connect(port: Int, token: String, origin: String = ExtensionBridge.extensionOrigin, nonce: String = BridgeAuth.makeNonce(),
                        proofToken: String? = nil, host: String? = nil, version: Int = 1) async throws -> WSClient {
        let raw = RawClient(port: port)
        try await raw.start()
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let proof = BridgeAuth.clientProof(token: proofToken ?? token, nonce: nonce)
        raw.send("GET /glide?v=\(version)&nonce=\(nonce)&proof=\(proof) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\nUpgrade: websocket\r\n"
            + "Connection: keep-alive, Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nOrigin: \(origin)\r\n\r\n")
        guard let head = await raw.readHead() else { throw TestTimeout(what: "the upgrade response") }
        if head.hasPrefix("HTTP/1.1 101") {
            #expect(head.contains("Sec-WebSocket-Accept: \(BridgeHandshake.acceptValue(forKey: key))"))
        }
        return WSClient(raw: raw, nonce: nonce, token: token, head: head)
    }

    /// Connects and completes hello; fails the test if either doesn't work.
    static func paired(port: Int, token: String, hello: JSONValue = defaultHello) async throws -> WSClient {
        let client = try await connect(port: port, token: token)
        #expect(client.upgraded, "upgrade refused: \(client.head)")
        try await client.completeHello(result: hello)
        return client
    }

    var upgraded: Bool { head.hasPrefix("HTTP/1.1 101") }
    var status: Int { Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0 }
    var receivedClose: UInt16? { closeCode.withLock { $0 } }

    func sendFrame(_ opcode: WebSocketOpcode, _ payload: [UInt8], masked: Bool = true, fin: Bool = true) {
        let mask = masked ? (0..<4).map { _ in UInt8.random(in: 0...255) } : nil
        raw.send(WebSocketCodec.encode(opcode, payload: payload, fin: fin, mask: mask))
    }

    func sendJSON(_ value: JSONValue) { sendFrame(.text, Array(value.jsonString().utf8)) }

    /// The next text message as JSON, answering pings on the way; nil once the server closes.
    func readJSON(timeout: TimeInterval = 5) async -> JSONValue? {
        while let frame = await raw.readFrame(timeout: timeout) {
            switch frame.opcode {
            case .text:
                return try? JSONValue.parse(String(decoding: frame.payload, as: UTF8.self))
            case .ping:
                sendFrame(.pong, frame.payload)
            case .close:
                let code = frame.payload.count >= 2 ? UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1]) : 1005
                closeCode.withLock { $0 = code }
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// Reads until the server's close frame and returns its code.
    func waitForClose(timeout: TimeInterval = 5) async -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while receivedClose == nil, Date() < deadline {
            if await readJSON(timeout: max(0.05, deadline.timeIntervalSinceNow)) == nil, receivedClose == nil, raw.ended { break }
        }
        return receivedClose
    }

    /// The extension's side of hello: checks Glide's proof before answering.
    @discardableResult
    func completeHello(result: JSONValue = defaultHello) async throws -> JSONValue {
        let request = try #require(await readJSON(), "no hello from Glide")
        #expect(request["method"] == "hello")
        #expect(request["params"]?["proof"]?.stringValue == BridgeAuth.serverProof(token: token, nonce: nonce), "Glide's proof is wrong")
        sendJSON(["id": request["id"] ?? .null, "result": result])
        return request
    }

    /// Reads one request and answers it with `respond`'s reply body (`{"result": …}` or `{"error": …}`).
    @discardableResult
    func serveOne(timeout: TimeInterval = 5, _ respond: (String, JSONValue) -> JSONValue) async throws -> (method: String, params: JSONValue) {
        guard let request = await readJSON(timeout: timeout) else { throw TestTimeout(what: "a request from Glide") }
        let method = request["method"]?.stringValue ?? ""
        let params = request["params"] ?? .null
        var reply = respond(method, params).objectValue ?? [:]
        reply["id"] = request["id"] ?? .null
        sendJSON(.object(reply))
        return (method, params)
    }

    func close() { raw.close() }
}

/// Plays the extension with Apple's WebSocket client, for interoperability with a real
/// third-party implementation (masking, handshake validation, pings).
final class URLSessionExtension: Sendable {
    let session: URLSession
    let task: URLSessionWebSocketTask
    let nonce: String
    let token: String

    init(port: Int, token: String, origin: String = ExtensionBridge.extensionOrigin) {
        let nonce = BridgeAuth.makeNonce()
        self.nonce = nonce
        self.token = token
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/glide?v=1&nonce=\(nonce)&proof=\(BridgeAuth.clientProof(token: token, nonce: nonce))")!)
        request.setValue(origin, forHTTPHeaderField: "Origin")
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func receiveJSON(timeout: TimeInterval = 5) async throws -> JSONValue {
        let task = self.task
        let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                task.cancel(with: .goingAway, reason: nil)
                throw TestTimeout(what: "a message")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        switch message {
        case .string(let text): return try JSONValue.parse(text)
        case .data(let data): return try JSONValue.parse(data)
        @unknown default: throw TestTimeout(what: "a text message")
        }
    }

    func send(_ value: JSONValue) async throws { try await task.send(.string(value.jsonString())) }

    func completeHello() async throws {
        let hello = try await receiveJSON()
        #expect(hello["params"]?["proof"]?.stringValue == BridgeAuth.serverProof(token: token, nonce: nonce))
        try await send(["id": hello["id"] ?? .null, "result": WSClient.defaultHello])
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

/// Sends one raw HTTP request and returns the whole response.
func rawHTTP(port: Int, _ request: String) async throws -> String {
    let client = RawClient(port: port)
    try await client.start()
    defer { client.close() }
    client.send(request)
    return await client.readToEnd()
}

// MARK: - Framing

@Suite("Extension bridge: WebSocket framing")
struct ExtensionBridgeFramingTests {
    let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]

    @Test func decodesMaskedClientFrames() throws {
        let bytes = WebSocketCodec.encode(.text, payload: Array("Hello".utf8), mask: mask)
        // RFC 6455 §5.7 example: a masked "Hello".
        #expect(bytes == [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58])
        let parsed = try WebSocketCodec.parse(bytes, maxPayload: 1024)
        #expect(parsed == .frame(WebSocketFrame(fin: true, opcode: .text, payload: Array("Hello".utf8)), consumed: bytes.count))
    }

    @Test(arguments: [0, 1, 125, 126, 127, 65535, 65536, 200_000])
    func roundTripsEveryLengthEncoding(length: Int) throws {
        let payload = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let bytes = WebSocketCodec.encode(.binary, payload: payload, mask: mask)
        let parsed = try WebSocketCodec.parse(bytes, maxPayload: 1 << 20)
        #expect(parsed == .frame(WebSocketFrame(fin: true, opcode: .binary, payload: payload), consumed: bytes.count))
        // Every strict prefix is incomplete, never an error.
        for cut in [1, 2, 3, 5, 9, bytes.count - 1] where cut < bytes.count && cut >= 0 {
            #expect(try WebSocketCodec.parse(Array(bytes[..<cut]), maxPayload: 1 << 20) == .needMore)
        }
    }

    @Test func parsesFromAnOffsetAndBackToBackFrames() throws {
        let one = WebSocketCodec.encode(.text, payload: Array("a".utf8), mask: mask)
        let two = WebSocketCodec.encode(.ping, payload: [1, 2], mask: mask)
        let stream = one + two
        guard case .frame(let first, let used)? = try? WebSocketCodec.parse(stream, maxPayload: 100) else {
            Issue.record("first frame didn't parse")
            return
        }
        #expect(first.payload == Array("a".utf8))
        #expect(try WebSocketCodec.parse(stream, from: used, maxPayload: 100) == .frame(WebSocketFrame(fin: true, opcode: .ping, payload: [1, 2]), consumed: two.count))
    }

    @Test func serverFramesAreUnmasked() {
        let bytes = WebSocketCodec.encode(.text, payload: Array("hi".utf8))
        #expect(bytes == [0x81, 0x02, 0x68, 0x69])
    }

    @Test func rejectsProtocolViolations() {
        func failure(_ bytes: [UInt8], max: Int = 1024) -> UInt16? {
            do throws(WebSocketFailure) {
                _ = try WebSocketCodec.parse(bytes, maxPayload: max)
                return nil
            } catch {
                return error.code
            }
        }
        #expect(failure(WebSocketCodec.encode(.text, payload: [1])) == 1002, "unmasked client frame")
        var reserved = WebSocketCodec.encode(.text, payload: [1], mask: mask)
        reserved[0] |= 0x40
        #expect(failure(reserved) == 1002, "reserved bit")
        #expect(failure([0x83, 0x80, 0, 0, 0, 0]) == 1002, "unknown opcode 3")
        #expect(failure(WebSocketCodec.encode(.ping, payload: [UInt8](repeating: 0, count: 126), mask: mask)) == 1002, "control frame over 125 bytes")
        #expect(failure(WebSocketCodec.encode(.ping, payload: [1], fin: false, mask: mask)) == 1002, "fragmented control frame")
        #expect(failure(WebSocketCodec.encode(.text, payload: [UInt8](repeating: 0, count: 2000), mask: mask)) == 1009, "too big")
        #expect(failure([0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0]) == 1002, "64-bit length with the top bit set")
    }

    @Test func assemblesFragmentsAroundControlFrames() throws {
        var assembler = WebSocketAssembler(maxMessage: 100)
        #expect(try assembler.push(WebSocketFrame(fin: false, opcode: .text, payload: Array("hel".utf8))) == nil)
        #expect(try assembler.push(WebSocketFrame(fin: true, opcode: .ping, payload: [9])) == .ping([9]))
        #expect(try assembler.push(WebSocketFrame(fin: false, opcode: .continuation, payload: Array("l".utf8))) == nil)
        #expect(try assembler.push(WebSocketFrame(fin: true, opcode: .continuation, payload: Array("o ✓".utf8))) == .text("hello ✓"))
        #expect(try assembler.push(WebSocketFrame(fin: true, opcode: .binary, payload: [0xFF])) == .binary([0xFF]))
    }

    @Test func assemblerRejectsBadSequencesAndText() {
        func failure(_ frames: [WebSocketFrame], max: Int = 10) -> UInt16? {
            var assembler = WebSocketAssembler(maxMessage: max)
            do throws(WebSocketFailure) {
                for frame in frames { _ = try assembler.push(frame) }
                return nil
            } catch {
                return error.code
            }
        }
        #expect(failure([WebSocketFrame(fin: true, opcode: .continuation, payload: [])]) == 1002)
        #expect(failure([WebSocketFrame(fin: false, opcode: .text, payload: []), WebSocketFrame(fin: true, opcode: .text, payload: [])]) == 1002)
        #expect(failure([WebSocketFrame(fin: true, opcode: .text, payload: [0xC3, 0x28])]) == 1007)
        #expect(failure([WebSocketFrame(fin: true, opcode: .close, payload: [0x03])]) == 1002)
        #expect(failure([WebSocketFrame(fin: false, opcode: .text, payload: [UInt8](repeating: 65, count: 8)),
                         WebSocketFrame(fin: true, opcode: .continuation, payload: [UInt8](repeating: 65, count: 8))]) == 1009)
    }

    @Test func closeFrames() throws {
        var assembler = WebSocketAssembler(maxMessage: 100)
        #expect(try assembler.push(WebSocketFrame(fin: true, opcode: .close, payload: [])) == .close(code: nil, reason: ""))
        let payload = WebSocketCodec.closePayload(code: 4001, reason: "Replaced")
        #expect(try assembler.push(WebSocketFrame(fin: true, opcode: .close, payload: payload)) == .close(code: 4001, reason: "Replaced"))
        let long = WebSocketCodec.closePayload(code: 1000, reason: String(repeating: "é", count: 200))
        #expect(long.count <= 125)
        #expect(String(validating: long[2...], as: UTF8.self) != nil, "trimmed on a character boundary")
    }
}

// MARK: - Handshake and authentication

@Suite("Extension bridge: handshake and pairing rules")
struct ExtensionBridgeHandshakeTests {
    let token = ExtensionFixtures.vectorToken
    let origin = ExtensionBridge.extensionOrigin
    let key = "dGhlIHNhbXBsZSBub25jZQ=="

    func request(path: String = "/glide", query: [String: String]? = nil, method: String = "GET", headers: [String: String] = [:]) -> BridgeHTTP.Request {
        let nonce = BridgeAuth.makeNonce()
        let q = query ?? ["v": "1", "nonce": nonce, "proof": BridgeAuth.clientProof(token: token, nonce: nonce)]
        var h = ["host": "127.0.0.1:47823", "upgrade": "websocket", "connection": "Upgrade", "sec-websocket-version": "13",
                 "sec-websocket-key": key, "origin": origin]
        for (name, value) in headers { h[name] = value }
        return BridgeHTTP.Request(method: method, target: path, path: path, query: q, headers: h.filter { !$0.value.isEmpty })
    }

    func status(_ decision: BridgeHandshake.Decision) -> Int? {
        if case .reject(let status, _, _) = decision { return status }
        return nil
    }

    @Test func acceptValueMatchesTheRFCExample() {
        #expect(BridgeHandshake.acceptValue(forKey: key) == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func proofsMatchAnIndependentHMAC() {
        #expect(BridgeAuth.clientProof(token: token, nonce: ExtensionFixtures.vectorNonce) == ExtensionFixtures.vectorClientProof)
        #expect(BridgeAuth.serverProof(token: token, nonce: ExtensionFixtures.vectorNonce) == ExtensionFixtures.vectorServerProof)
    }

    @Test func parsesRequestHeads() throws {
        let head = "GET /glide?v=1&nonce=12.ab&proof=a%2Fb HTTP/1.1\r\nHost: 127.0.0.1:1\r\nX-Thing: one\r\nx-thing: two\r\nConnection:keep-alive, Upgrade\r\n\r\n"
        let request = try #require(BridgeHTTP.parseRequest(Array(head.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/glide")
        #expect(request.query == ["v": "1", "nonce": "12.ab", "proof": "a/b"])
        #expect(request.header("X-THING") == "one, two")
        #expect(request.headerTokens("connection") == ["keep-alive", "upgrade"])
        #expect(BridgeHTTP.headEnd(in: Array(head.utf8)) == head.utf8.count)
        #expect(BridgeHTTP.headEnd(in: Array("GET / HTTP/1.1\r\n".utf8)) == nil)
    }

    @Test(arguments: ["", "GET\r\n\r\n", "GET /glide\r\n\r\n", "GET glide HTTP/1.1\r\n\r\n", "GET /glide HTTP/1.1\r\nno colon here\r\n\r\n",
                      "GET /glide SPDY/3\r\n\r\n"])
    func rejectsMalformedHeads(head: String) {
        #expect(BridgeHTTP.parseRequest(Array(head.utf8)) == nil)
    }

    @Test func acceptsAValidUpgrade() {
        let nonce = BridgeAuth.makeNonce()
        let valid = request(query: ["v": "1", "nonce": nonce, "proof": BridgeAuth.clientProof(token: token, nonce: nonce).uppercased()])
        #expect(BridgeHandshake.evaluate(valid, token: token, allowedOrigins: [origin], now: Date())
            == .upgrade(accept: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", nonce: nonce))
    }

    @Test func enforcesEveryRule() {
        func check(_ r: BridgeHTTP.Request, token: String? = ExtensionFixtures.vectorToken, now: Date = Date()) -> Int? {
            status(BridgeHandshake.evaluate(r, token: token, allowedOrigins: [origin], now: now))
        }
        #expect(check(request(method: "POST")) == 405)
        #expect(check(request(headers: ["host": "evil.example:47823"])) == 403, "DNS rebinding")
        #expect(check(request(headers: ["host": ""])) == 403)
        #expect(check(request(path: "/other")) == 404)
        #expect(check(request(headers: ["upgrade": ""])) == 400)
        #expect(check(request(headers: ["connection": "keep-alive"])) == 400)
        #expect(check(request(headers: ["sec-websocket-version": "8"])) == 426)
        #expect(check(request(headers: ["sec-websocket-key": "short"])) == 400)
        #expect(check(request(headers: ["origin": "https://evil.example"])) == 403)
        #expect(check(request(headers: ["origin": "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])) == 403, "another extension")
        #expect(check(request(headers: ["origin": ""])) == 403)
        #expect(check(request(query: ["v": "2", "nonce": "1.a", "proof": "x"])) == 400)
        #expect(check(request(), token: nil) == 503)
        #expect(check(request(query: ["v": "1"])) == 401, "no proof")
        #expect(check(request(query: ["v": "1", "nonce": "not-a-nonce", "proof": "00"])) == 401)
        let old = BridgeAuth.makeNonce(now: Date().addingTimeInterval(-600))
        #expect(check(request(query: ["v": "1", "nonce": old, "proof": BridgeAuth.clientProof(token: token, nonce: old)])) == 401, "stale")
        let nonce = BridgeAuth.makeNonce()
        let wrong = BridgeAuth.clientProof(token: BridgeAuth.mintToken(), nonce: nonce)
        #expect(check(request(query: ["v": "1", "nonce": nonce, "proof": wrong])) == 401, "wrong token")
        #expect(BridgeHandshake.evaluate(request(path: "/glide/ping"), token: nil, allowedOrigins: [], now: Date()) == .ping)
    }

    @Test func tokensAndNonces() {
        let a = BridgeAuth.mintToken(), b = BridgeAuth.mintToken()
        #expect(a != b)
        #expect(BridgeAuth.isValidToken(a) && BridgeAuth.isValidToken(b))
        #expect(!BridgeAuth.isValidToken(a.uppercased()))
        #expect(!BridgeAuth.isValidToken(String(a.dropLast())))
        #expect(!BridgeAuth.isValidToken(String(a.dropLast()) + "ａ"), "fullwidth letters aren't hex")
        let nonce = BridgeAuth.makeNonce(now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(nonce.hasPrefix("1700000000."))
        #expect(BridgeAuth.nonceTimestamp(nonce) == 1_700_000_000)
        for bad in ["", ".", "1.", "x.0123456789abcdef0123456789abcdef", "1.0123456789ABCDEF0123456789abcdef", "1.0123", "1.2.3"] {
            #expect(BridgeAuth.nonceTimestamp(bad) == nil, "\(bad)")
        }
        #expect(BridgeAuth.constantTimeEquals("abc", "abc"))
        #expect(!BridgeAuth.constantTimeEquals("abc", "abd"))
        #expect(!BridgeAuth.constantTimeEquals("abc", "abcd"))
    }

    @Test func loopbackHosts() {
        for host in ["127.0.0.1", "127.0.0.1:47823", "localhost:1", "LOCALHOST", "[::1]:47823"] {
            #expect(BridgeHandshake.isLoopbackHost(host), "\(host)")
        }
        for host in ["", "evil.example", "127.0.0.1.evil.example", "10.0.0.1:47823", "[::2]:1", "[::1"] {
            #expect(!BridgeHandshake.isLoopbackHost(host), "\(host)")
        }
    }

    @Test func restrictedPages() {
        for url in ["chrome://settings", "CHROME://extensions", "chrome-extension://abc/popup.html", "devtools://devtools/bundled/x.html",
                    "view-source:https://example.com", "javascript:alert(1)", "about:settings", "edge://flags",
                    "https://chromewebstore.google.com/detail/x", "https://chrome.google.com/webstore/category/extensions"] {
            #expect(ExtensionURLPolicy.isRestricted(url), "\(url)")
        }
        for url in ["", "about:blank", "about:blank#x", "https://example.com", "https://chrome.google.com/search", "file:///tmp/a.html",
                    "data:text/html,hi", "http://127.0.0.1:8080/"] {
            #expect(!ExtensionURLPolicy.isRestricted(url), "\(url)")
        }
    }

    @Test func extensionErrorsMapToBrowserErrors() {
        #expect(ExtensionBridge.mapExtensionError(["code": "restricted", "message": "m", "url": "chrome://x"], method: "tabs.create") == .restrictedPage("chrome://x"))
        #expect(ExtensionBridge.mapExtensionError(["code": "tab_not_found", "message": "m", "tabId": "7"], method: "cdp.send") == .tabNotFound("7"))
        #expect(ExtensionBridge.mapExtensionError(["code": "canceled_by_user", "message": "Stopped"], method: "cdp.send") == .notConnected("Stopped"))
        #expect(ExtensionBridge.mapExtensionError(["code": "cdp", "message": "Boom"], method: "cdp.send") == .cdp("Boom"))
        #expect(ExtensionBridge.mapExtensionError(["message": ""], method: "tabs.list") == .cdp("Chrome couldn't run “tabs.list”."))
        #expect(ExtensionBridge.mapExtensionError("plain", method: "x") == .cdp("plain"))
    }

    @Test func statusLines() {
        let hello = ExtensionHello(extensionVersion: "1.0.0", chromeVersion: "141", extensionID: "x", protocolVersion: 1)
        #expect(ExtensionBridgeStatus(listener: .listening(port: 1), connected: true, paired: true, hello: hello).detail == "Connected to Chrome 141 via the Glide extension")
        #expect(ExtensionBridgeStatus(listener: .listening(port: 1), connected: false, paired: false, hello: nil).detail.contains("click Pair"))
        #expect(ExtensionBridgeStatus(listener: .listening(port: 1), connected: false, paired: true, hello: nil).detail.contains("isn't connected"))
        #expect(ExtensionBridgeStatus(listener: .failed("Port busy"), connected: false, paired: true, hello: nil).detail == "Port busy")
    }

    @Test func pairingURLKeepsTheSecretInTheFragment() throws {
        let url = try #require(ExtensionBridge.pairingURL(token: token, port: 4242))
        #expect(url.scheme == "chrome-extension")
        #expect(url.host == ExtensionBridge.extensionID)
        #expect(url.path == "/pair.html")
        #expect(url.query == nil)
        #expect(url.fragment == "token=\(token)&port=4242")
    }
}

// MARK: - Live server

@Suite("Extension bridge: live server")
struct ExtensionBridgeLiveTests {
    @Test func refusesWrongOriginTokenAndVersion() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let wrongOrigin = try await WSClient.connect(port: port, token: token, origin: "https://evil.example")
        #expect(wrongOrigin.status == 403)
        let wrongToken = try await WSClient.connect(port: port, token: token, proofToken: BridgeAuth.mintToken())
        #expect(wrongToken.status == 401)
        let otherExtension = try await WSClient.connect(port: port, token: token, origin: "chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        #expect(otherExtension.status == 403)
        let wrongVersion = try await WSClient.connect(port: port, token: token, version: 7)
        #expect(wrongVersion.status == 400)
        let rebinding = try await WSClient.connect(port: port, token: token, host: "attacker.example")
        #expect(rebinding.status == 403)
        for client in [wrongOrigin, wrongToken, otherExtension, wrongVersion, rebinding] {
            #expect(await eventually(2) { client.raw.ended }, "refused connections are closed")
        }
        #expect(!bridge.isConnected)
        #expect(!bridge.isPaired)
    }

    @Test func appleWebSocketClientInteroperates() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let client = URLSessionExtension(port: port, token: token)
        defer { client.close() }
        try await client.completeHello()
        #expect(await bridge.waitForConnection(timeout: 5))
        #expect(bridge.hello?.chromeVersion == "141.0.7390.1")
        #expect(bridge.status().detail == "Connected to Chrome 141.0.7390.1 via the Glide extension")

        async let tabs = bridge.call("tabs.list")
        let request = try await client.receiveJSON()
        #expect(request["method"] == "tabs.list")
        try await client.send(["id": request["id"] ?? .null, "result": [["id": 5, "url": "https://a.test/", "title": "A", "active": true, "windowId": 1]]])
        let list = try await tabs
        #expect(list[0]?["id"]?.intValue == 5)

        let failing = Task { try await bridge.call("tabs.create", params: ["url": "chrome://settings"]) }
        let second = try await client.receiveJSON()
        try await client.send(["id": second["id"] ?? .null, "error": ["message": "Chrome doesn't allow automating this page.", "code": "restricted", "url": "chrome://settings"]])
        let error = await browserError { _ = try await failing.value }
        #expect(error == .restrictedPage("chrome://settings"))
    }

    @Test func appleWebSocketClientWithWrongOriginIsRefused() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let client = URLSessionExtension(port: port, token: token, origin: "https://evil.example")
        defer { client.close() }
        await #expect(throws: (any Error).self) { _ = try await client.receiveJSON(timeout: 3) }
        #expect((client.task.response as? HTTPURLResponse)?.statusCode == 403)
        #expect(!(await bridge.waitForConnection(timeout: 0.2)))
    }

    @Test func requestsTimeOutAndLateRepliesAreIgnored() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        let started = Date()
        let slow = Task { try await bridge.call("tabs.list", timeout: 0.3) }
        let request = try #require(await client.readJSON())
        let error = await browserError { _ = try await slow.value }
        #expect(error?.isTimeout == true, "\(String(describing: error))")
        #expect(error?.message.contains("tabs.list") == true)
        #expect(Date().timeIntervalSince(started) < 3)
        // A late answer is dropped, and the connection keeps working.
        client.sendJSON(["id": request["id"] ?? .null, "result": "late"])
        async let next = bridge.call("tabs.list")
        try await client.serveOne { _, _ in ["result": "fresh"] }
        let fresh = try await next
        #expect(fresh == "fresh")
    }

    @Test func newestConnectionReplacesTheOldOne() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let events = EventRecorder()
        bridge.addEventHandler { events.append($0) }
        let first = try await WSClient.paired(port: port, token: token)
        defer { first.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        let pending = Task { try await bridge.call("tabs.list") }
        _ = try #require(await first.readJSON(), "request reached the first client")

        let second = try await WSClient.paired(port: port, token: token, hello: ["version": "2.0.0", "chromeVersion": "142", "extensionId": "x", "protocol": 1])
        defer { second.close() }
        #expect(await first.waitForClose() == 4001)
        let error = await browserError { _ = try await pending.value }
        #expect(error?.isNotConnected == true, "\(String(describing: error))")
        #expect(await eventually { bridge.hello?.extensionVersion == "2.0.0" })

        async let routed = bridge.call("tabs.list")
        try await second.serveOne { _, _ in ["result": "from second"] }
        let answer = try await routed
        #expect(answer == "from second")
        #expect(events.all.contains(.disconnected("Replaced by a newer extension connection")))
    }

    @Test func disconnectFailsPendingCallsAndIsReported() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let events = EventRecorder()
        bridge.addEventHandler { events.append($0) }
        let client = try await WSClient.paired(port: port, token: token)
        #expect(await bridge.waitForConnection(timeout: 5))
        #expect(await events.waitFor { if case .connected = $0 { return true } else { return false } })
        let pending = Task { try await bridge.call("cdp.send", params: ["tabId": 1, "method": "Runtime.evaluate"]) }
        _ = try #require(await client.readJSON())
        client.close()
        let error = await browserError { _ = try await pending.value }
        #expect(error?.isNotConnected == true)
        #expect(await eventually { !bridge.isConnected })
        #expect(await events.waitFor { if case .disconnected = $0 { return true } else { return false } })
    }

    @Test func detachedEventsReachHandlers() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let events = EventRecorder()
        let id = bridge.addEventHandler { events.append($0) }
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        client.sendJSON(["event": "keepalive"])
        client.sendJSON(["event": "detached", "tabId": 7, "reason": "canceled_by_user"])
        #expect(await events.waitFor { $0 == .detached(tabID: "7", reason: "canceled_by_user") })
        bridge.removeEventHandler(id)
        client.sendJSON(["event": "detached", "tabId": 8, "reason": "target_closed"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(!events.all.contains(.detached(tabID: "8", reason: "target_closed")), "removed handlers aren't called")
    }

    @Test func resetPairingDisconnectsAndMintsANewToken() async throws {
        let (bridge, port, token, store) = try await startTestBridge()
        defer { bridge.stop() }
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        #expect(bridge.isPaired && store.loadPaired())

        bridge.resetPairing()
        #expect(await client.waitForClose() == 4002)
        #expect(!bridge.isConnected)
        #expect(!bridge.isPaired && !store.loadPaired())
        let newToken = try #require(bridge.pairing()?.token)
        #expect(newToken != token && BridgeAuth.isValidToken(newToken))
        #expect(store.loadToken() == newToken)
        #expect(try await WSClient.connect(port: port, token: token).status == 401, "the old token no longer works")
        let fresh = try await WSClient.paired(port: port, token: newToken)
        defer { fresh.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
    }

    @Test func pairingIsRememberedAndBadTokensAreReplaced() async throws {
        let store = InMemoryExtensionBridgeStore(token: "not a token", paired: true)
        let bridge = ExtensionBridge()
        defer { bridge.stop() }
        bridge.start(port: 0, store: store)
        let port = try await bridge.waitUntilListening()
        let minted = try #require(store.loadToken())
        #expect(minted != "not a token" && BridgeAuth.isValidToken(minted))
        #expect(!bridge.isPaired && !store.loadPaired(), "a new token starts unpaired")
        let pairing = try #require(bridge.pairing())
        #expect(pairing.port == port)
        #expect(pairing.pairingCode == "\(port):\(minted)")
        #expect(pairing.extensionID == ExtensionBridge.extensionID)

        let client = try await WSClient.paired(port: port, token: minted)
        defer { client.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        #expect(store.loadPaired(), "first hello marks the store paired")

        // Starting again on the same port with the same store keeps the connection and token.
        bridge.start(port: 0, store: store)
        #expect(bridge.isConnected)
        #expect(store.loadToken() == minted)
        let restarted = ExtensionBridge()
        defer { restarted.stop() }
        restarted.start(port: 0, store: store)
        #expect(restarted.isPaired, "pairing survives a relaunch")
        #expect(restarted.pairing()?.token == minted)
    }

    @Test func answersProbesAndRefusesOtherRequests() async throws {
        let (bridge, port, _, _) = try await startTestBridge()
        defer { bridge.stop() }
        let ping = try await rawHTTP(port: port, "GET /glide/ping HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        #expect(ping.hasPrefix("HTTP/1.1 200 OK"))
        #expect(ping.hasSuffix(#"{"app":"Glide","protocol":1}"#))
        #expect(!ping.contains("Access-Control-Allow-Origin"), "web pages can't read it")
        #expect(try await rawHTTP(port: port, "GET /glide/ping HTTP/1.1\r\nHost: evil.example\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        #expect(try await rawHTTP(port: port, "GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").hasPrefix("HTTP/1.1 404"))
        #expect(try await rawHTTP(port: port, "POST /glide HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").hasPrefix("HTTP/1.1 405"))
        #expect(try await rawHTTP(port: port, "GET /glide HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").hasPrefix("HTTP/1.1 400"))
        #expect(try await rawHTTP(port: port, "nonsense\r\n\r\n").hasPrefix("HTTP/1.1 400"))
        let huge = "GET /glide HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Big: \(String(repeating: "a", count: 9000))\r\n\r\n"
        #expect(try await rawHTTP(port: port, huge).hasPrefix("HTTP/1.1 431"))
    }

    @Test func silentHandshakesTimeOut() async throws {
        let (bridge, port, _, _) = try await startTestBridge { $0.handshakeTimeout = 0.3 }
        defer { bridge.stop() }
        let client = RawClient(port: port)
        try await client.start()
        defer { client.close() }
        client.send("GET /glide HTTP/1.1\r\n") // never finishes the head
        #expect(await client.readToEnd(timeout: 3).hasPrefix("HTTP/1.1 408"))
    }

    @Test func replayedNoncesAreRefused() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let nonce = BridgeAuth.makeNonce()
        let first = try await WSClient.connect(port: port, token: token, nonce: nonce)
        #expect(first.upgraded)
        first.close()
        #expect(try await WSClient.connect(port: port, token: token, nonce: nonce).status == 401)
    }

    @Test func idleConnectionsAreDropped() async throws {
        let (bridge, port, token, _) = try await startTestBridge {
            $0.idleTimeout = 0.6
            $0.pingInterval = 60
        }
        defer { bridge.stop() }
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        #expect(await client.waitForClose(timeout: 5) == 4000)
        #expect(!bridge.isConnected)
    }

    @Test func pingsFlowBothWays() async throws {
        let (bridge, port, token, _) = try await startTestBridge { $0.pingInterval = 0.2 }
        defer { bridge.stop() }
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        let ping = await client.raw.readFrame(timeout: 3)
        #expect(ping?.opcode == .ping, "the bridge pings to detect dead peers")
        client.sendFrame(.ping, Array("hi".utf8))
        var pong: WebSocketFrame?
        for _ in 0..<10 {
            guard let frame = await client.raw.readFrame(timeout: 3) else { break }
            if frame.opcode == .pong { pong = frame; break }
        }
        #expect(pong?.payload == Array("hi".utf8))
    }

    @Test func protocolViolationsCloseTheConnection() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        client.sendFrame(.text, Array("{}".utf8), masked: false)
        #expect(await client.waitForClose() == 1002)
        #expect(await eventually { !bridge.isConnected })
    }

    @Test func largeFragmentedRepliesArriveIntact() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        async let reply = bridge.call("cdp.send", params: ["tabId": 1, "method": "Page.captureScreenshot"])
        let request = try #require(await client.readJSON())
        let big = String(repeating: "iVBORw0KGgo", count: 300_000) // ~3.3 MB, like a screenshot
        let bytes = Array(JSONValue.object(["id": request["id"] ?? .null, "result": ["data": .string(big)]]).jsonString().utf8)
        let chunk = 1 << 20
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            client.sendFrame(offset == 0 ? .text : .continuation, Array(bytes[offset..<end]), fin: end == bytes.count)
            offset = end
        }
        let result = try await reply
        #expect(result["data"]?.stringValue == big)
    }

    @Test func helloFailuresCloseTheConnection() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let client = try await WSClient.connect(port: port, token: token)
        defer { client.close() }
        let hello = try #require(await client.readJSON())
        client.sendJSON(["id": hello["id"] ?? .null, "error": ["message": "nope", "code": "untrusted"]])
        #expect(await client.waitForClose() == 1008)
        #expect(!bridge.isConnected)
        #expect(!bridge.isPaired)
    }

    @Test func explainsWhyItIsNotConnected() async throws {
        let unpaired = try await startTestBridge()
        defer { unpaired.bridge.stop() }
        #expect(!(await unpaired.bridge.waitForConnection(timeout: 0.2)))
        let first = await browserError { _ = try await unpaired.bridge.call("tabs.list") }
        #expect(first?.message.contains("isn't paired") == true, "\(String(describing: first))")

        let paired = try await startTestBridge(paired: true)
        defer { paired.bridge.stop() }
        let second = await browserError { _ = try await paired.bridge.call("tabs.list") }
        #expect(second?.message.contains("isn't connected to Glide right now") == true, "\(String(describing: second))")

        let stopped = ExtensionBridge()
        let third = await browserError { _ = try await stopped.call("tabs.list") }
        #expect(third?.message.contains("isn't running") == true)
    }

    @Test func cancellingACallFailsItRightAway() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        let task = Task { try await bridge.call("tabs.list") }
        let request = try #require(await client.readJSON())
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        client.sendJSON(["id": request["id"] ?? .null, "result": "ignored"])
        async let next = bridge.call("tabs.list")
        try await client.serveOne { _, _ in ["result": "ok"] }
        let answer = try await next
        #expect(answer == "ok")
    }

    @Test func stopFailsPendingCallsAndClosesConnections() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        #expect(await bridge.waitForConnection(timeout: 5))
        let pending = Task { try await bridge.call("tabs.list") }
        _ = try #require(await client.readJSON())
        bridge.stop()
        let error = await browserError { _ = try await pending.value }
        #expect(error?.isNotConnected == true)
        #expect(await client.waitForClose() == 1001)
        #expect(bridge.status().listener == .stopped)
        let afterStop = try? await rawHTTP(port: port, "GET /glide/ping HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(afterStop == nil || afterStop?.isEmpty == true, "nothing answers once stopped")
    }

    @Test func busyPortsAreRetried() async throws {
        let holder = try await startTestBridge()
        defer { holder.bridge.stop() }
        let second = ExtensionBridge()
        defer { second.stop() }
        second.start(port: holder.port, store: InMemoryExtensionBridgeStore())
        #expect(await eventually(3) { if case .failed = second.status().listener { return true } else { return false } })
        #expect(second.status().detail.contains("in use"))
        holder.bridge.stop()
        #expect(try await second.waitUntilListeningAfterRetry(timeout: 8) == holder.port)
    }

    @Test func rejectsInvalidPorts() {
        let bridge = ExtensionBridge()
        bridge.start(port: 70000, store: InMemoryExtensionBridgeStore())
        #expect(bridge.status().detail.contains("isn't a valid port"))
    }
}

extension ExtensionBridge {
    /// Like `waitUntilListening`, but keeps waiting through bind failures (which are retried).
    func waitUntilListeningAfterRetry(timeout: TimeInterval) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .listening(let port) = status().listener { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestTimeout(what: "the retried listener")
    }
}

// MARK: - Backend

@Suite("Extension bridge: browser backend")
struct ExtensionBridgeBackendTests {
    @Test func mapsBrowserCallsToExtensionRequests() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let client = try await WSClient.paired(port: port, token: token)
        defer { client.close() }
        let backend = ExtensionBackend(bridge: bridge, connectTimeout: 2)
        #expect(backend.kind == .extensionBridge)
        try await backend.connect()
        #expect(await backend.isConnected())

        let server = Task { () -> [String] in
            var seen: [String] = []
            while true {
                guard let served = try? await client.serveOne(timeout: 5, { method, params in
                    switch method {
                    case "tabs.list":
                        return ["result": [["id": 1, "url": "https://a.test/", "title": "A", "active": true, "windowId": 3, "glide": false],
                                           ["id": 2, "url": "https://b.test/", "title": "B", "active": false, "windowId": 3, "glide": true]]]
                    case "tabs.create":
                        return ["result": ["id": 42, "url": params["url"] ?? "", "title": "", "active": params["active"] ?? false, "windowId": 3]]
                    case "tabs.update":
                        return ["result": ["id": params["tabId"] ?? 0, "url": params["url"] ?? "", "title": "", "active": true, "windowId": 3]]
                    case "tabs.remove", "cdp.detach":
                        return ["result": .null]
                    case "cdp.send":
                        if params["tabId"] == 77 { return ["error": ["code": "tab_not_found", "tabId": "77", "message": "The tab 77 is closed."]] }
                        if params["method"] == "Page.enable" { return ["result": .null] }
                        return ["result": ["echo": params]]
                    default:
                        return ["error": ["message": "unknown"]]
                    }
                }) else { return seen }
                seen.append("\(served.method) \(served.params.jsonString())")
            }
        }

        let tabs = try await backend.tabs()
        #expect(tabs == [BrowserTab(id: "1", url: "https://a.test/", title: "A", active: true, ownedByGlide: false),
                         BrowserTab(id: "2", url: "https://b.test/", title: "B", active: false, ownedByGlide: true)])
        let opened = try await backend.openTab(url: " https://c.test/ ", background: true)
        #expect(opened == BrowserTab(id: "42", url: "https://c.test/", title: "", active: false, ownedByGlide: true))
        try await backend.navigate(tabID: "42", url: "https://d.test/")
        try await backend.activateTab("42")
        let echoed = try await backend.cdp(tabID: "42", method: "Runtime.evaluate", params: ["expression": "1+1", "returnByValue": true])
        #expect(echoed["echo"]?["method"] == "Runtime.evaluate")
        #expect(echoed["echo"]?["params"]?["expression"] == "1+1")
        #expect(try await backend.cdp(tabID: "42", method: "Page.enable", params: nil) == .object([:]), "null results become {}")
        #expect(await browserError { _ = try await backend.cdp(tabID: "77", method: "Page.enable", params: nil) } == .tabNotFound("77"))
        try await backend.detach(tabID: "42")
        try await backend.closeTab("42")

        // Refused locally, without bothering the extension.
        #expect(await browserError { _ = try await backend.openTab(url: "chrome://settings", background: true) } == .restrictedPage("chrome://settings"))
        #expect(await browserError { try await backend.navigate(tabID: "42", url: "javascript:alert(1)") } == .restrictedPage("javascript:alert(1)"))
        #expect(await browserError { _ = try await backend.cdp(tabID: "tab-x", method: "Page.enable", params: nil) } == .tabNotFound("tab-x"))

        client.close()
        let seen = await server.value
        #expect(seen == [
            #"tabs.list null"#,
            #"tabs.create {"active":false,"url":"https:\/\/c.test\/"}"#,
            #"tabs.update {"tabId":42,"url":"https:\/\/d.test\/"}"#,
            #"tabs.update {"active":true,"tabId":42}"#,
            #"cdp.send {"method":"Runtime.evaluate","params":{"expression":"1+1","returnByValue":true},"tabId":42}"#,
            #"cdp.send {"method":"Page.enable","params":{},"tabId":42}"#,
            #"cdp.send {"method":"Page.enable","params":{},"tabId":77}"#,
            #"cdp.detach {"tabId":42}"#,
            #"tabs.remove {"tabId":42}"#,
        ])
    }

    @Test func connectWaitsForTheExtensionThenExplains() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let quick = ExtensionBackend(bridge: bridge, connectTimeout: 0.3)
        let started = Date()
        let error = await browserError { try await quick.connect() }
        #expect(error?.message.contains("isn't paired") == true)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(await browserError { _ = try await quick.tabs() }?.isNotConnected == true, "operations wait, then fail clearly")

        let patient = ExtensionBackend(bridge: bridge, connectTimeout: 5)
        let late = Task {
            try await Task.sleep(for: .milliseconds(300))
            return try await WSClient.paired(port: port, token: token)
        }
        try await patient.connect()
        #expect(await patient.isConnected())
        let lateClient = try await late.value
        lateClient.close()
    }
}

// MARK: - Extension files

@Suite("Extension bridge: Chrome extension files")
struct ExtensionBridgeFilesTests {
    @Test func manifestIsAValidMV3Manifest() throws {
        let manifest = try ExtensionFixtures.manifest()
        #expect(manifest["manifest_version"] as? Int == 3)
        #expect(manifest["name"] as? String == "Glide")
        #expect(Set(manifest["permissions"] as? [String] ?? []) == ["debugger", "tabs", "webNavigation", "storage", "alarms", "scripting"])
        #expect(manifest["host_permissions"] as? [String] == ["<all_urls>"])
        #expect(manifest["web_accessible_resources"] == nil, "pair.html must not be openable by web pages")
        #expect(manifest["externally_connectable"] == nil)
        let worker = try #require((manifest["background"] as? [String: Any])?["service_worker"] as? String)
        let popup = try #require((manifest["action"] as? [String: Any])?["default_popup"] as? String)
        for file in [worker, popup, "pair.html", "pair.js", "popup.js", "common.js"] {
            #expect(FileManager.default.fileExists(atPath: ExtensionFixtures.folder.appendingPathComponent(file).path), "\(file)")
        }
        #expect(!FileManager.default.fileExists(atPath: ExtensionFixtures.folder.appendingPathComponent("key.pem").path), "no private key in the repo")
    }

    @Test func extensionIDMatchesTheManifestKey() throws {
        let manifest = try ExtensionFixtures.manifest()
        let key = try #require(manifest["key"] as? String)
        let der = try #require(Data(base64Encoded: key))
        #expect(der.count > 250, "an RSA-2048 public key")
        let letters = Array("abcdefghijklmnop")
        let id = String(SHA256.hash(data: der).prefix(16).flatMap { [letters[Int($0 >> 4)], letters[Int($0 & 0x0F)]] })
        #expect(id == ExtensionBridge.extensionID)
        #expect(ExtensionBridge.extensionOrigin == "chrome-extension://\(id)")
    }

    @Test func iconsArePNGsOfTheDeclaredSizes() throws {
        let icons = try #require(try ExtensionFixtures.manifest()["icons"] as? [String: String])
        #expect(Set(icons.keys) == ["16", "32", "48", "128"])
        for (size, path) in icons {
            let data = try Data(contentsOf: ExtensionFixtures.folder.appendingPathComponent(path))
            #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "\(path) is a PNG")
            let width = data[16..<20].reduce(0) { $0 << 8 | Int($1) }
            let height = data[20..<24].reduce(0) { $0 << 8 | Int($1) }
            #expect(width == Int(size) && height == Int(size), "\(path) is \(width)x\(height)")
        }
    }

    @Test(arguments: ["popup.html", "pair.html"])
    func pagesLoadOnlyBundledScripts(page: String) throws {
        let html = try String(contentsOf: ExtensionFixtures.folder.appendingPathComponent(page), encoding: .utf8)
        let scripts = try Regex(#"<script([^>]*)>([\s\S]*?)</script>"#)
        for match in html.matches(of: scripts) {
            let attributes = String(match.output[1].substring ?? "")
            let body = String(match.output[2].substring ?? "")
            #expect(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "MV3 forbids inline scripts")
            let src = try #require(attributes.firstMatch(of: try Regex(#"src="([^"]+)""#))?.output[1].substring)
            #expect(!src.contains(":"), "no remote scripts: \(src)")
            #expect(FileManager.default.fileExists(atPath: ExtensionFixtures.folder.appendingPathComponent(String(src)).path), "\(src)")
        }
        #expect(html.contains("common.js"))
    }

    @Test func extensionFolderIsFound() throws {
        let folder = try #require(ExtensionBridge.extensionFolder())
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        #expect(folder.standardizedFileURL.path == ExtensionFixtures.folder.standardizedFileURL.path)
    }

    @Test(.enabled(if: NodeTool.path != nil, "node isn't installed"))
    func scriptsPassNodeCheck() throws {
        let scripts = try FileManager.default.contentsOfDirectory(atPath: ExtensionFixtures.folder.path).filter { $0.hasSuffix(".js") }
        #expect(scripts.count >= 4)
        for script in scripts {
            let result = try NodeTool.run(["--check", ExtensionFixtures.folder.appendingPathComponent(script).path])
            #expect(result.status == 0, "\(script): \(result.error)")
        }
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func sharedHelpersAgreeWithSwift() throws {
        let urls = ["chrome://settings", "about:blank", "about:config", "https://chromewebstore.google.com/x", "https://example.com",
                    "javascript:void(0)", "view-source:x", "file:///tmp/a", "https://chrome.google.com/webstore/x", "https://chrome.google.com/a"]
        let script = """
        const vm = require("vm"), fs = require("fs");
        vm.runInThisContext(fs.readFileSync(process.argv[1], "utf8"));
        const G = globalThis.GlideCommon;
        (async () => {
          const urls = JSON.parse(process.argv[4]);
          console.log(JSON.stringify({
            client: await G.clientProof(process.argv[2], process.argv[3]),
            server: await G.serverProof(process.argv[2], process.argv[3]),
            nonce: G.makeNonce(1700000000123),
            restricted: urls.map(G.isRestrictedURL),
            code: G.parsePairingCode(" 47823 : " + process.argv[2].toUpperCase() + " "),
            badCode: G.parsePairingCode("99999:" + process.argv[2]),
            hash: G.parsePairingHash("#token=" + process.argv[2] + "&port=4242"),
            url: G.bridgeURL(4242, "1.ab", "cd"),
          }));
        })();
        """
        let result = try NodeTool.run(["-e", script, ExtensionFixtures.folder.appendingPathComponent("common.js").path,
                                       ExtensionFixtures.vectorToken, ExtensionFixtures.vectorNonce, JSONValue.array(urls.map { .string($0) }).jsonString()])
        #expect(result.status == 0, "\(result.error)")
        let json = try JSONValue.parse(result.output)
        #expect(json["client"]?.stringValue == ExtensionFixtures.vectorClientProof)
        #expect(json["server"]?.stringValue == ExtensionFixtures.vectorServerProof)
        let nonce = try #require(json["nonce"]?.stringValue)
        #expect(BridgeAuth.nonceTimestamp(nonce) == 1_700_000_000, "the extension's nonces pass Glide's format check: \(nonce)")
        #expect(json["restricted"]?.arrayValue?.map { $0.boolValue ?? false } == urls.map(ExtensionURLPolicy.isRestricted))
        #expect(json["code"] == ["port": 47823, "token": .string(ExtensionFixtures.vectorToken)])
        #expect(json["badCode"] == .null)
        #expect(json["hash"] == ["port": 4242, "token": .string(ExtensionFixtures.vectorToken)])
        #expect(json["url"]?.stringValue == "ws://127.0.0.1:4242\(ExtensionBridge.path)?v=\(ExtensionBridge.protocolVersion)&nonce=1.ab&proof=cd")
    }

    /// Runs pair.js in Node with a small fake page and `chrome.runtime`, clicks the given
    /// buttons, and reports what the page showed and which messages it sent the service worker.
    func runPairingPage(hash: String, clicks: [String], alreadyPaired: Bool = false) throws -> JSONValue {
        let script = #"""
        const vm = require("vm"), fs = require("fs");
        const [commonPath, pairPath, hash, clicks, paired] = process.argv.slice(1);
        const startsHidden = new Set(["confirm", "portWarning", "replaceNote", "state", "error"]);
        const elements = {};
        const el = (id) => elements[id] || (elements[id] = {
          id, textContent: "", className: "", hidden: startsHidden.has(id), listeners: [],
          addEventListener(type, f) { if (type === "click") this.listeners.push(f); },
          click() { this.listeners.forEach((f) => f({})); },
        });
        globalThis.document = { getElementById: el };
        globalThis.location = { hash, pathname: "/pair.html" };
        let address = "pair.html" + hash;
        globalThis.history = { replaceState: (state, title, url) => { address = url; } };
        const sent = [];
        globalThis.chrome = {
          runtime: {
            sendMessage: async (m) => {
              sent.push(m);
              return { ok: true, result: m.type === "pair" ? { state: "connected", port: m.port, paired: true } : { state: "not_paired", port: 47823, paired: paired === "yes" } };
            },
          },
          storage: { onChanged: { addListener() {} } },
        };
        vm.runInThisContext(fs.readFileSync(commonPath, "utf8"));
        vm.runInThisContext(fs.readFileSync(pairPath, "utf8"));
        const pause = () => new Promise((resolve) => setTimeout(resolve, 20));
        const view = () => ({
          confirm: !el("confirm").hidden, target: el("target").textContent,
          portWarning: el("portWarning").hidden ? null : el("portWarning").textContent,
          replaceNote: !el("replaceNote").hidden, detail: el("detail").textContent,
          error: el("error").hidden ? null : el("error").textContent,
        });
        (async () => {
          await pause();
          const shown = view();
          const sentBeforeClicking = sent.map((m) => m.type);
          for (const id of clicks.split(",").filter(Boolean)) { el(id).click(); await pause(); }
          console.log(JSON.stringify({ shown, sentBeforeClicking, after: view(), pairs: sent.filter((m) => m.type === "pair"), address }));
        })();
        """#
        let result = try NodeTool.run(["-e", script, ExtensionFixtures.folder.appendingPathComponent("common.js").path,
                                       ExtensionFixtures.folder.appendingPathComponent("pair.js").path, hash, clicks.joined(separator: ","),
                                       alreadyPaired ? "yes" : "no"])
        #expect(result.status == 0, "\(result.error)")
        return try JSONValue.parse(result.output)
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func pairingPageSavesNothingUntilTheUserClicksPair() throws {
        let token = ExtensionFixtures.vectorToken
        // Opening the link (anything on the Mac can) only shows what would be paired.
        let opened = try runPairingPage(hash: "#token=\(token)&port=47823", clicks: [])
        #expect(opened["sentBeforeClicking"] == ["status"], "\(opened)")
        #expect(opened["pairs"] == [])
        #expect(opened["shown"]?["confirm"] == true)
        #expect(opened["shown"]?["target"]?.stringValue?.contains("Glide on this Mac, port 47823") == true)
        #expect(opened["shown"]?["portWarning"] == .null)
        #expect(opened["shown"]?["replaceNote"] == false)
        #expect(opened["address"] == "/pair.html", "the secret leaves the address bar at once")

        // Clicking Pair (even twice) saves it once.
        let paired = try runPairingPage(hash: "#token=\(token)&port=47823", clicks: ["pair", "pair"])
        #expect(paired["pairs"] == [["type": "pair", "port": 47823, "token": .string(token)]], "\(paired)")
        #expect(paired["after"]?["confirm"] == false)
        #expect(paired["after"]?["detail"]?.stringValue?.hasPrefix("Paired.") == true)

        // An unusual port is called out, so is replacing a pairing, and Cancel saves nothing.
        let odd = try runPairingPage(hash: "#token=\(token)&port=9999", clicks: ["cancel", "pair"], alreadyPaired: true)
        #expect(odd["shown"]?["portWarning"]?.stringValue?.contains("normally uses port 47823") == true, "\(odd)")
        #expect(odd["shown"]?["replaceNote"] == true)
        #expect(odd["pairs"] == [])
        #expect(odd["after"]?["detail"]?.stringValue?.contains("Not paired") == true)

        let broken = try runPairingPage(hash: "#token=nope", clicks: ["pair"])
        #expect(broken["pairs"] == [] && broken["shown"]?["confirm"] == false)
        #expect(broken["shown"]?["error"]?.stringValue?.contains("incomplete") == true)
    }
}

// MARK: - The real service worker, in Node

/// Locates and runs `node` (only for checks; nothing here needs network access).
enum NodeTool {
    static let path: String? = {
        let fm = FileManager.default
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/node" }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let nvm = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted(by: >).map { "\(nvm)/\($0)/bin/node" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }()

    /// Node 22+ (built-in WebSocket that accepts headers, fetch, WebCrypto).
    static let supportsHarness: Bool = {
        guard path != nil, let result = try? run(["-e", "process.exit(typeof WebSocket === 'function' && typeof fetch === 'function' && globalThis.crypto && crypto.subtle ? 0 : 1)"]) else {
            return false
        }
        return result.status == 0
    }()

    static func run(_ arguments: [String], timeout: TimeInterval = 30) throws -> (status: Int32, output: String, error: String) {
        guard let path else { throw TestTimeout(what: "node (not installed)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // A hung node must not hang the test run. (Process isn't Sendable; the pid is.)
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

/// Runs Extensions/chrome/service_worker.js in Node with an in-memory `chrome` API: storage,
/// alarms, a few fake tabs and a fake debugger. It prints what the extension does (STATUS …,
/// CREATE …, ATTACH …) and takes commands on stdin:
///   cancel <tabId>          the user dismisses Chrome's debugging bar
///   dialog <tabId> <type>   the page opens alert()/confirm()/prompt() on its own
///   close_dialog <tabId>    the user answers that dialog
///   load <tabId>            a held navigation (any address containing "/slow") commits
///   popup <tabId> <url>     the page in that tab opens a tab (target=_blank, window.open). As in
///                           Chrome, the new tab comes to the front and its openerTabId is the
///                           tab that was in front; only webNavigation names the real source
///   open <url>              another app opens a link in Chrome (no opener at all)
///   dirty <tabId>           the page has unsaved input: closing it asks "Leave site?"
/// A command whose params include `testDialog: "<type>"` opens that dialog while it's still
/// running (a click whose handler calls confirm(), the user closing the tab during a read); the
/// CDP method `Test.openDialog` does the same with `type`. `idleDetachMs` shortens the
/// extension's idle detach delay.
final class NodeHarness {
    let process = Process()
    private let input = Pipe()
    private let directory: URL
    private let outputURL: URL
    private let errorURL: URL

    init(port: Int, token: String?, origin: String = ExtensionBridge.extensionOrigin, idleDetachMs: Int? = nil) throws {
        // Writing to a pipe whose reader has exited must not kill the test runner.
        signal(SIGPIPE, SIG_IGN)
        let fm = FileManager.default
        directory = fm.temporaryDirectory.appendingPathComponent("glide-extension-harness-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("harness.js")
        try Self.source.write(to: script, atomically: true, encoding: .utf8)
        outputURL = directory.appendingPathComponent("stdout.txt")
        errorURL = directory.appendingPathComponent("stderr.txt")
        fm.createFile(atPath: outputURL.path, contents: nil)
        fm.createFile(atPath: errorURL.path, contents: nil)
        guard let node = NodeTool.path else { throw TestTimeout(what: "node (not installed)") }
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path, ExtensionFixtures.folder.path, String(port), token ?? "-", origin, idleDetachMs.map(String.init) ?? "-"]
        process.standardOutput = try FileHandle(forWritingTo: outputURL)
        process.standardError = try FileHandle(forWritingTo: errorURL)
        process.standardInput = input
        try process.run()
    }

    var output: String { (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "" }
    var log: String { output + ((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "") }

    func count(_ line: String) -> Int { output.components(separatedBy: "\n").filter { $0 == line }.count }

    /// What follows `prefix ` on each output line that starts with it ("POPUP 101" → "101").
    func values(of prefix: String) -> [String] {
        output.components(separatedBy: "\n").filter { $0.hasPrefix(prefix + " ") }.map { String($0.dropFirst(prefix.count + 1)) }
    }

    func waitFor(_ line: String, timeout: TimeInterval = 10) async -> Bool {
        await eventually(timeout) { output.components(separatedBy: "\n").contains(line) }
    }

    func send(_ command: String) {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    func stop() {
        if process.isRunning {
            try? input.fileHandleForWriting.close()
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }

    static let source = #"""
    "use strict";
    const fs = require("fs");
    const path = require("path");
    const vm = require("vm");
    const readline = require("readline");

    const [extDir, port, token, origin, idleDetachMs] = process.argv.slice(2);
    const out = (line) => process.stdout.write(line + "\n");

    // The extension waits IDLE_DETACH_MS (45 s) before letting go of the user's tabs; tests
    // shorten exactly that delay.
    const realSetTimeout = globalThis.setTimeout;
    if (idleDetachMs !== "-") {
      globalThis.setTimeout = (fn, ms, ...rest) => realSetTimeout(fn, ms === 45000 ? Number(idleDetachMs) : ms, ...rest);
    }

    function makeEvent() {
      const listeners = [];
      return {
        addListener: (f) => listeners.push(f),
        removeListener: (f) => { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
        hasListener: (f) => listeners.includes(f),
        emit: (...args) => listeners.forEach((f) => f(...args)),
      };
    }
    const storageChanged = makeEvent();
    function makeArea(name) {
      const data = {};
      const keysOf = (keys) => keys == null ? Object.keys(data) : Array.isArray(keys) ? keys : typeof keys === "string" ? [keys] : Object.keys(keys);
      return {
        async get(keys) { const r = {}; for (const k of keysOf(keys)) if (k in data) r[k] = structuredClone(data[k]); return r; },
        async set(items) {
          const changes = {};
          for (const [k, v] of Object.entries(items)) {
            changes[k] = { oldValue: data[k], newValue: v };
            data[k] = structuredClone(v);
            if (name === "session" && k === "glideStatus") out("STATUS " + v.state);
          }
          storageChanged.emit(changes, name);
        },
        async remove(keys) {
          const changes = {};
          for (const k of keysOf(keys)) if (k in data) {
            changes[k] = { oldValue: data[k] };
            delete data[k];
            if (name === "local" && k === "glideToken") out("TOKEN_REMOVED");
          }
          if (Object.keys(changes).length) storageChanged.emit(changes, name);
        },
      };
    }

    const tabs = new Map([[1, { id: 1, url: "https://example.com/", title: "Example", active: true, windowId: 10, status: "complete" }]]);
    let nextTabId = 100;
    const attachedTabs = new Set();
    let attachCount = 0;
    const onDetach = makeEvent();
    const onEvent = makeEvent();
    const onRemoved = makeEvent();
    const onCreated = makeEvent();
    const onUpdated = makeEvent();
    const onCreatedNavigationTarget = makeEvent();
    const noTab = (id) => new Error(`No tab with id: ${id}.`);
    const heldLoads = new Map(); // tab id → commit to run on "load <tabId>"
    const dirtyTabs = new Set(); // tabs whose page asks "Leave site?" when closed
    const leavePrompts = new Map(); // tab id → finishes a close once the prompt is accepted

    // A navigation commits like Chrome's: "loading", then the new address, then "complete".
    // Addresses containing "/slow" wait for "load <tabId>".
    function startNavigation(tab, url) {
      tab.pendingUrl = url;
      tab.status = "loading";
      const commit = () => {
        if (!tabs.has(tab.id)) return;
        tab.url = url;
        delete tab.pendingUrl;
        onUpdated.emit(tab.id, { url }, { ...tab });
        tab.status = "complete";
        onUpdated.emit(tab.id, { status: "complete" }, { ...tab });
        out(`COMMITTED ${tab.id} ${url}`);
      };
      realSetTimeout(() => {
        if (!tabs.has(tab.id)) return;
        onUpdated.emit(tab.id, { status: "loading" }, { ...tab });
        if (url.includes("/slow")) heldLoads.set(tab.id, commit);
        else realSetTimeout(commit, 5);
      }, 5);
    }

    function activate(tab) {
      for (const other of tabs.values()) if (other.windowId === tab.windowId) other.active = false;
      tab.active = true;
    }

    function createTab({ url, active, openerTabId }) {
      const tab = { id: nextTabId++, url: "", title: "", active: false, windowId: 10, status: "loading" };
      if (typeof openerTabId === "number") tab.openerTabId = openerTabId;
      tabs.set(tab.id, tab);
      if (active) activate(tab);
      onCreated.emit({ ...tab, pendingUrl: url });
      startNavigation(tab, url);
      return tab;
    }

    globalThis.self = globalThis;
    globalThis.chrome = {
      runtime: {
        id: origin.replace("chrome-extension://", ""),
        getManifest: () => JSON.parse(fs.readFileSync(path.join(extDir, "manifest.json"), "utf8")),
        onInstalled: makeEvent(), onStartup: makeEvent(), onMessage: makeEvent(),
      },
      storage: { local: makeArea("local"), session: makeArea("session"), onChanged: storageChanged },
      alarms: { async get() { return undefined; }, async create() {}, onAlarm: makeEvent() },
      tabs: {
        async query() { return [...tabs.values()].map((t) => ({ ...t })); },
        async get(id) { if (!tabs.has(id)) throw noTab(id); return { ...tabs.get(id) }; },
        async create({ url, active }) {
          const tab = createTab({ url, active });
          out(`CREATE ${url} ${!!active}`);
          return { ...tab };
        },
        async update(id, props) {
          const tab = tabs.get(id); if (!tab) throw noTab(id);
          const { url, active, ...rest } = props;
          Object.assign(tab, rest);
          if (active === true) activate(tab);
          if (url !== undefined) startNavigation(tab, url);
          out(`UPDATE ${id} ${JSON.stringify(props)}`);
          return { ...tab };
        },
        async remove(id) {
          if (!tabs.has(id)) throw noTab(id);
          if (dirtyTabs.has(id)) {
            // Chrome asks the page first: through the debugger when it's attached (the
            // extension answers), otherwise with its own prompt to the user.
            if (!attachedTabs.has(id)) { out(`LEAVE_PROMPT ${id}`); return new Promise(() => {}); }
            await new Promise((resolve) => {
              leavePrompts.set(id, resolve);
              onEvent.emit({ tabId: id }, "Page.javascriptDialogOpening", { type: "beforeunload", message: "" });
            });
          }
          tabs.delete(id);
          attachedTabs.delete(id);
          out(`REMOVE ${id}`);
          onRemoved.emit(id, {});
        },
        onRemoved, onCreated, onUpdated,
      },
      webNavigation: { onCreatedNavigationTarget },
      windows: {
        async create({ url }) { const tab = await chrome.tabs.create({ url, active: false }); return { id: 11, tabs: [tab] }; },
        async update(id, props) { out(`FOCUS ${id}`); return {}; },
      },
      debugger: {
        async attach({ tabId }, version) {
          if (!tabs.has(tabId)) throw noTab(tabId);
          if (attachedTabs.has(tabId)) throw new Error(`Another debugger is already attached to the tab with id: ${tabId}.`);
          attachedTabs.add(tabId); attachCount++;
          out(`ATTACH ${tabId} ${version}`);
        },
        async detach({ tabId }) {
          if (!attachedTabs.delete(tabId)) throw new Error(`Debugger is not attached to the tab with id: ${tabId}.`);
          out(`DETACH ${tabId}`);
        },
        async sendCommand({ tabId }, method, params) {
          if (!attachedTabs.has(tabId)) throw new Error(`Debugger is not attached to the tab with id: ${tabId}.`);
          const testDialog = method === "Test.openDialog" ? params && params.type : params && params.testDialog;
          if (testDialog) {
            onEvent.emit({ tabId }, "Page.javascriptDialogOpening", { type: testDialog, message: `Sure (${testDialog})?` });
            await new Promise((resolve) => realSetTimeout(resolve, 50));
          }
          if (method === "Runtime.evaluate" && params && params.expression === "1+1") return { result: { type: "number", value: 2 } };
          if (method === "Page.handleJavaScriptDialog") {
            out(`DIALOG_ANSWERED ${tabId} ${params.accept}`);
            const finishClose = leavePrompts.get(tabId);
            leavePrompts.delete(tabId);
            realSetTimeout(() => {
              onEvent.emit({ tabId }, "Page.javascriptDialogClosed", { result: !!params.accept });
              if (finishClose && params.accept) finishClose();
            }, 0);
          }
          return { echo: { method, params: params || {} }, attachCount };
        },
        async getTargets() { return [...tabs.keys()].map((id) => ({ tabId: id, attached: attachedTabs.has(id) })); },
        onDetach,
        onEvent,
      },
      action: { async setBadgeText() {}, async setBadgeBackgroundColor() {}, async setTitle() {} },
    };

    // Chrome adds the extension's Origin header itself; Node's WebSocket has to be told.
    const NodeWebSocket = globalThis.WebSocket;
    globalThis.WebSocket = class extends NodeWebSocket {
      constructor(url) { super(url, { headers: { Origin: origin } }); }
    };
    globalThis.importScripts = (...files) => {
      for (const file of files) vm.runInThisContext(fs.readFileSync(path.join(extDir, file), "utf8"), { filename: file });
    };

    readline.createInterface({ input: process.stdin }).on("line", (line) => {
      const [command, arg, extra] = line.trim().split(/\s+/);
      const tabId = Number(arg);
      if (command === "cancel") {
        attachedTabs.delete(tabId);
        onDetach.emit({ tabId }, "canceled_by_user");
        out(`CANCELED ${tabId}`);
      } else if (command === "dialog") {
        onEvent.emit({ tabId }, "Page.javascriptDialogOpening", { type: extra, message: `Sure (${extra})?` });
      } else if (command === "close_dialog") {
        onEvent.emit({ tabId }, "Page.javascriptDialogClosed", { result: false });
      } else if (command === "load") {
        const commit = heldLoads.get(tabId);
        heldLoads.delete(tabId);
        if (commit) commit();
      } else if (command === "popup") {
        const front = [...tabs.values()].find((t) => t.active && t.windowId === 10);
        const tab = createTab({ url: extra, active: true, openerTabId: front ? front.id : undefined });
        onCreatedNavigationTarget.emit({ sourceTabId: tabId, sourceFrameId: 0, tabId: tab.id, url: extra, timeStamp: Date.now() });
        out(`POPUP ${tab.id}`);
      } else if (command === "open") {
        const tab = createTab({ url: arg, active: false });
        out(`OPENED ${tab.id}`);
      } else if (command === "dirty") {
        dirtyTabs.add(tabId);
      }
    });
    process.stdin.on("end", () => process.exit(0));

    (async () => {
      if (token !== "-") await chrome.storage.local.set({ glidePort: Number(port), glideToken: token });
      importScripts("service_worker.js");
      out("READY");
    })();
    """#
}

@Suite("Extension bridge: service worker end to end")
struct ExtensionBridgeEndToEndTests {
    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func serviceWorkerDrivesTabsThroughTheBridge() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let events = EventRecorder()
        bridge.addEventHandler { events.append($0) }
        let harness = try NodeHarness(port: port, token: token)
        defer { harness.stop() }

        #expect(await bridge.waitForConnection(timeout: 15), "\(harness.log)")
        #expect(await harness.waitFor("STATUS connected"), "\(harness.log)")
        let manifest = try ExtensionFixtures.manifest()
        #expect(bridge.hello?.extensionID == ExtensionBridge.extensionID)
        #expect(bridge.hello?.extensionVersion == manifest["version"] as? String)
        #expect(bridge.isPaired)

        let backend = ExtensionBackend(bridge: bridge, connectTimeout: 3)
        let tabs = try await backend.tabs()
        #expect(tabs == [BrowserTab(id: "1", url: "https://example.com/", title: "Example", active: true, ownedByGlide: false)])

        let tab = try await backend.openTab(url: "https://example.org/", background: true)
        #expect(tab.ownedByGlide && !tab.active)
        #expect(await harness.waitFor("CREATE https://example.org/ false"))
        #expect(try await backend.tabs().first { $0.id == tab.id }?.ownedByGlide == true)

        let value = try await backend.cdp(tabID: tab.id, method: "Runtime.evaluate", params: ["expression": "1+1"])
        #expect(value["result"]?["value"]?.intValue == 2)
        let echo = try await backend.cdp(tabID: tab.id, method: "Page.navigate", params: ["url": "https://example.org/a"])
        #expect(echo["echo"]?["method"] == "Page.navigate")
        #expect(harness.count("ATTACH \(tab.id) 1.3") == 1, "the debugger attaches once per tab: \(harness.log)")

        try await backend.navigate(tabID: tab.id, url: "https://example.org/b")
        #expect(await harness.waitFor(#"UPDATE \#(tab.id) {"url":"https://example.org/b"}"#))
        try await backend.activateTab(tab.id)
        #expect(await harness.waitFor(#"UPDATE \#(tab.id) {"active":true}"#))
        #expect(await harness.waitFor("FOCUS 10"))

        // The extension enforces its own rules, not just the Swift pre-checks.
        #expect(await browserError { _ = try await bridge.call("tabs.create", params: ["url": "chrome://settings", "active": false]) } == .restrictedPage("chrome://settings"))
        let blocked = await browserError { _ = try await backend.cdp(tabID: tab.id, method: "Network.getAllCookies", params: nil) }
        #expect(blocked?.message.contains("doesn't allow") == true, "\(String(describing: blocked))")
        #expect(await browserError { _ = try await backend.cdp(tabID: "999", method: "Runtime.evaluate", params: nil) } == .tabNotFound("999"))
        let unknown = await browserError { _ = try await bridge.call("history.clear") }
        #expect(unknown?.message.contains("doesn't support") == true)

        // Page dialogs are answered at once (alerts accepted, confirm() declined) so they can't
        // freeze the tab, and Glide is told what was answered.
        harness.send("dialog \(tab.id) confirm")
        #expect(await harness.waitFor("DIALOG_ANSWERED \(tab.id) false"), "\(harness.log)")
        #expect(await events.waitFor { $0 == .dialog(tabID: tab.id, dialog: BrowserDialog(type: "confirm", message: "Sure (confirm)?", accepted: false)) }, "\(harness.log)")
        harness.send("dialog \(tab.id) alert")
        #expect(await harness.waitFor("DIALOG_ANSWERED \(tab.id) true"), "\(harness.log)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await backend.takeHandledDialogs(tabID: tab.id).map(\.type) == ["confirm", "alert"])
        #expect(await backend.takeHandledDialogs(tabID: tab.id).isEmpty)

        // The user dismisses Chrome's debugging bar: Glide hears about it, and the extension
        // refuses further debugging until the user allows it again.
        harness.send("cancel \(tab.id)")
        #expect(await events.waitFor { $0 == .detached(tabID: tab.id, reason: "canceled_by_user") }, "\(harness.log)")
        let refused = await browserError { _ = try await backend.cdp(tabID: tab.id, method: "Runtime.evaluate", params: ["expression": "1+1"]) }
        #expect(refused?.isNotConnected == true && refused?.message.contains("Allow again") == true, "\(String(describing: refused))")
        #expect(harness.count("ATTACH \(tab.id) 1.3") == 1, "no re-attach after the user said stop")

        try await backend.closeTab(tab.id)
        #expect(await harness.waitFor("REMOVE \(tab.id)"))

        // Resetting pairing in Glide makes the extension forget the token and stop reconnecting.
        bridge.resetPairing()
        #expect(await harness.waitFor("TOKEN_REMOVED"), "\(harness.log)")
        #expect(await harness.waitFor("STATUS not_paired"), "\(harness.log)")
        #expect(!bridge.isConnected)
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func serviceWorkerDetachesEverythingWhenGlideGoesAway() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        let harness = try NodeHarness(port: port, token: token)
        defer { harness.stop() }
        #expect(await bridge.waitForConnection(timeout: 15), "\(harness.log)")
        let backend = ExtensionBackend(bridge: bridge, connectTimeout: 3)
        _ = try await backend.cdp(tabID: "1", method: "Page.enable", params: nil)
        #expect(await harness.waitFor("ATTACH 1 1.3"))
        bridge.stop()
        #expect(await harness.waitFor("DETACH 1"), "Chrome's debugging bar goes away with Glide: \(harness.log)")
        #expect(await harness.waitFor("STATUS glide_not_running"), "\(harness.log)")
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func serviceWorkerIgnoresAnImpostorServer() async throws {
        // Something listening on the port that can't prove it knows the token gets nothing.
        let (bridge, port, token, _) = try await startTestBridge { $0.sendsInvalidServerProof = true }
        defer { bridge.stop() }
        let harness = try NodeHarness(port: port, token: token)
        defer { harness.stop() }
        #expect(await harness.waitFor("STATUS untrusted"), "\(harness.log)")
        #expect(!(await bridge.waitForConnection(timeout: 0.5)))
        #expect(!bridge.isPaired)
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func serviceWorkerReportsRefusedPairing() async throws {
        let (bridge, port, _, _) = try await startTestBridge()
        defer { bridge.stop() }
        let harness = try NodeHarness(port: port, token: BridgeAuth.mintToken())
        defer { harness.stop() }
        #expect(await harness.waitFor("STATUS rejected"), "\(harness.log)")
        #expect(!bridge.isConnected)
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func serviceWorkerWithoutPairingWaits() async throws {
        let (bridge, port, _, _) = try await startTestBridge()
        defer { bridge.stop() }
        let harness = try NodeHarness(port: port, token: nil)
        defer { harness.stop() }
        #expect(await harness.waitFor("STATUS not_paired"), "\(harness.log)")
        #expect(!(await bridge.waitForConnection(timeout: 0.5)))
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func replacedProfileWaitsInsteadOfFighting() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let first = try NodeHarness(port: port, token: token)
        defer { first.stop() }
        #expect(await first.waitFor("STATUS connected"), "\(first.log)")
        let second = try NodeHarness(port: port, token: token)
        defer { second.stop() }
        #expect(await second.waitFor("STATUS connected"), "\(second.log)")
        #expect(await first.waitFor("STATUS replaced"), "\(first.log)")
        // The replaced one stays put rather than taking the connection back.
        try await Task.sleep(for: .seconds(2))
        #expect(first.count("STATUS connected") == 1, "\(first.log)")
        #expect(bridge.isConnected)
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func dialogsInTabsGlideIsNotWorkingInAreLeftToTheUser() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let events = EventRecorder()
        bridge.addEventHandler { events.append($0) }
        let harness = try NodeHarness(port: port, token: token, idleDetachMs: 3000)
        defer { harness.stop() }
        #expect(await bridge.waitForConnection(timeout: 15), "\(harness.log)")
        let backend = ExtensionBackend(bridge: bridge, connectTimeout: 3)
        let mine = try await backend.openTab(url: "https://example.org/", background: true)

        // A dialog that opens while Glide's command runs in the user's tab (its click opened a
        // confirm()) is Glide's doing: it's answered, and Glide hears about it.
        _ = try await backend.cdp(tabID: "1", method: "Test.openDialog", params: ["type": "confirm"])
        #expect(await harness.waitFor("DIALOG_ANSWERED 1 false"), "\(harness.log)")
        #expect(await events.waitFor { $0 == .dialog(tabID: "1", dialog: BrowserDialog(type: "confirm", message: "Sure (confirm)?", accepted: false)) })

        // A tab opened from Glide's tab while Glide works there is Glide's too.
        _ = try await backend.cdp(tabID: mine.id, method: "Runtime.evaluate", params: ["expression": "1+1"])
        harness.send("popup \(mine.id) https://example.org/pop")
        #expect(await eventually(3) { harness.values(of: "POPUP").count == 1 }, "\(harness.log)")

        // Once Glide has moved on, the page's own dialogs are the user's: "Leave site?" isn't
        // accepted behind their back, nor is Glide told it was.
        try await Task.sleep(for: .milliseconds(2300))
        harness.send("popup 1 https://example.org/theirs")
        harness.send("dialog 1 beforeunload")
        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.count("DIALOG_ANSWERED 1 true") == 0, "\(harness.log)")
        #expect(!events.all.contains { if case .dialog(_, let d) = $0 { return d.type == "beforeunload" } else { return false } })
        // While it's open, Glide's commands there fail at once instead of hanging on the frozen page.
        let blocked = await browserError { _ = try await backend.cdp(tabID: "1", method: "Runtime.evaluate", params: ["expression": "1+1"]) }
        #expect(blocked?.message.contains("Answer it in Chrome") == true, "\(String(describing: blocked))")
        harness.send("close_dialog 1")
        var works = false
        for _ in 0..<30 where !works {
            works = (try? await backend.cdp(tabID: "1", method: "Runtime.evaluate", params: ["expression": "1+1"]))?["result"]?["value"]?.intValue == 2
            if !works { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(works, "commands work again once the user has answered")

        let popups = harness.values(of: "POPUP")
        #expect(popups.count == 2, "\(harness.log)")
        let tabs = try await backend.tabs()
        let fromGlide = try #require(tabs.first { $0.id == popups.first })
        #expect(fromGlide.openerID == mine.id && fromGlide.ownedByGlide)
        let fromUser = try #require(tabs.first { $0.id == popups.last })
        #expect(fromUser.openerID == "1" && !fromUser.ownedByGlide)

        // The debugger lets go of the user's tab after a while without commands; Glide's own
        // tab stays attached.
        #expect(await harness.waitFor("DETACH 1", timeout: 10), "\(harness.log)")
        #expect(harness.count("DETACH \(mine.id)") == 0, "\(harness.log)")
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func popupsAreKnownByTheTabWhosePageOpenedThem() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let harness = try NodeHarness(port: port, token: token)
        defer { harness.stop() }
        #expect(await bridge.waitForConnection(timeout: 15), "\(harness.log)")
        let backend = ExtensionBackend(bridge: bridge, connectTimeout: 3)
        let mine = try await backend.openTab(url: "https://example.org/", background: true)
        func tabs(until done: ([BrowserTab]) -> Bool) async throws -> [BrowserTab] {
            var tabs: [BrowserTab] = []
            for _ in 0..<100 {
                tabs = try await backend.tabs()
                if done(tabs) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            return tabs
        }

        // Glide clicks a target=_blank link in its background tab. Chrome opens the link in front
        // and gives it the user's tab (the one in front) as openerTabId; webNavigation says
        // which page opened it.
        _ = try await backend.cdp(tabID: mine.id, method: "Input.dispatchMouseEvent", params: ["type": "mouseReleased"])
        harness.send("popup \(mine.id) https://example.org/pop")
        #expect(await eventually(3) { harness.values(of: "POPUP").count == 1 }, "\(harness.log)")
        let ours = try #require(harness.values(of: "POPUP").first)
        var list = try await tabs { $0.first { $0.id == ours }?.ownedByGlide == true && $0.first { $0.id == "1" }?.active == true }
        let popup = try #require(list.first { $0.id == ours })
        #expect(popup.openerID == mine.id && popup.ownedByGlide, "\(popup)")
        // The user's tab is back in front; Glide carries on in the background.
        #expect(!popup.active && list.first { $0.id == "1" }?.active == true, "\(list)")
        #expect(harness.count(#"UPDATE 1 {"active":true}"#) == 1, "\(harness.log)")

        // A link the user opens from their own tab is theirs, and stays in front.
        harness.send("popup 1 https://example.org/theirs")
        // A link another app opens has no opener at all.
        harness.send("open https://example.org/elsewhere")
        #expect(await eventually(3) { harness.values(of: "POPUP").count == 2 && harness.values(of: "OPENED").count == 1 }, "\(harness.log)")
        let theirs = try #require(harness.values(of: "POPUP").last)
        let elsewhere = try #require(harness.values(of: "OPENED").first)
        list = try await backend.tabs()
        let fromUser = try #require(list.first { $0.id == theirs })
        #expect(fromUser.openerID == "1" && !fromUser.ownedByGlide && fromUser.active, "\(fromUser)")
        let fromApp = try #require(list.first { $0.id == elsewhere })
        #expect(fromApp.openerID == nil && !fromApp.ownedByGlide, "\(fromApp)")

        // A popup the page in Glide's tab opens by itself, while Glide isn't working there, isn't
        // Glide's doing; it still says where it came from.
        try await Task.sleep(for: .milliseconds(2300))
        harness.send("popup \(mine.id) https://example.org/timer")
        #expect(await eventually(3) { harness.values(of: "POPUP").count == 3 }, "\(harness.log)")
        let timer = try #require(harness.values(of: "POPUP").last)
        try await Task.sleep(for: .milliseconds(200))
        let byPage = try #require(try await backend.tabs().first { $0.id == timer })
        #expect(byPage.openerID == mine.id && !byPage.ownedByGlide, "\(byPage)")
        #expect(harness.count(#"UPDATE 1 {"active":true}"#) == 1, "\(harness.log)")
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func leavePromptsInTheUsersTabsAreAcceptedOnlyForGlidesActions() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let events = EventRecorder()
        bridge.addEventHandler { events.append($0) }
        let harness = try NodeHarness(port: port, token: token)
        defer { harness.stop() }
        #expect(await bridge.waitForConnection(timeout: 15), "\(harness.log)")
        let backend = ExtensionBackend(bridge: bridge, connectTimeout: 3)
        func accepted() -> Int { harness.count("DIALOG_ANSWERED 1 true") }

        // Glide is only reading the user's tab when they close it (or leave a half-filled form):
        // "Leave site?" is theirs to answer, and Glide's next command says so at once.
        _ = try await backend.cdp(tabID: "1", method: "Runtime.evaluate", params: ["expression": "document.title", "testDialog": "beforeunload"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(accepted() == 0, "\(harness.log)")
        let blocked = await browserError { _ = try await backend.cdp(tabID: "1", method: "Runtime.evaluate", params: ["expression": "1+1"]) }
        #expect(blocked?.message.contains("“Leave site?” prompt") == true && blocked?.message.contains("Answer it in Chrome") == true,
                "\(String(describing: blocked))")
        harness.send("close_dialog 1")
        var works = false
        for _ in 0..<30 where !works {
            works = (try? await backend.cdp(tabID: "1", method: "Runtime.evaluate", params: ["expression": "1+1"]))?["result"]?["value"]?.intValue == 2
            if !works { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(works, "commands work again once the user has answered")
        // Other dialogs that open during a read are answered as before (confirm() declined).
        _ = try await backend.cdp(tabID: "1", method: "Runtime.evaluate", params: ["expression": "x", "testDialog": "confirm"])
        #expect(await harness.waitFor("DIALOG_ANSWERED 1 false"), "\(harness.log)")

        // Glide's own click, or its script click, leaves the page: that's allowed.
        _ = try await backend.cdp(tabID: "1", method: "Input.dispatchMouseEvent", params: ["type": "mouseReleased", "testDialog": "beforeunload"])
        #expect(await eventually(3) { accepted() == 1 }, "\(harness.log)")
        _ = try await backend.cdp(tabID: "1", method: "Runtime.evaluate", params: ["expression": "x", "userGesture": true, "testDialog": "beforeunload"])
        #expect(await eventually(3) { accepted() == 2 }, "\(harness.log)")
        // So is a prompt that comes a moment after the action (the click's navigation starts later).
        harness.send("dialog 1 beforeunload")
        #expect(await eventually(3) { accepted() == 3 }, "\(harness.log)")
        #expect(await events.waitFor { if case .dialog(let tab, let d) = $0 { return tab == "1" && d.type == "beforeunload" && d.accepted } else { return false } })
        // Once Glide has moved on, the prompt is the user's again.
        try await Task.sleep(for: .milliseconds(2300))
        harness.send("dialog 1 beforeunload")
        try await Task.sleep(for: .milliseconds(300))
        #expect(accepted() == 3, "\(harness.log)")
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func navigationsAndNewTabsAnswerOnceTheNewPageCommits() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let harness = try NodeHarness(port: port, token: token)
        defer { harness.stop() }
        #expect(await bridge.waitForConnection(timeout: 15), "\(harness.log)")
        let backend = ExtensionBackend(bridge: bridge, connectTimeout: 3)

        let done = Mutex(0)
        let opening = Task {
            let tab = try await backend.openTab(url: "https://example.org/slow/a", background: true)
            done.withLock { $0 += 1 }
            return tab
        }
        #expect(await harness.waitFor("CREATE https://example.org/slow/a false"), "\(harness.log)")
        try await Task.sleep(for: .milliseconds(300))
        #expect(done.withLock { $0 } == 0, "a new tab isn't reported while it still shows its empty first page")
        harness.send("load 100") // the harness numbers new tabs from 100
        let tab = try await opening.value
        #expect(tab.id == "100" && tab.url == "https://example.org/slow/a")

        for url in ["https://example.org/slow/b", "https://example.org/slow/b"] { // a new address, then a reload
            let before = done.withLock { $0 }
            let navigating = Task {
                try await backend.navigate(tabID: tab.id, url: url)
                done.withLock { $0 += 1 }
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(done.withLock { $0 } == before, "the call waits while the old page is still showing")
            harness.send("load \(tab.id)")
            try await navigating.value
        }
        #expect(harness.count("COMMITTED 100 https://example.org/slow/b") == 2, "\(harness.log)")
        // Pages that commit at once answer right away.
        try await backend.navigate(tabID: tab.id, url: "https://example.org/fast")
        #expect(harness.count("COMMITTED 100 https://example.org/fast") == 1, "\(harness.log)")
    }

    @Test(.enabled(if: NodeTool.supportsHarness, "Node 22+ isn't installed"))
    func closingGlidesTabAnswersItsLeavePromptButNotTheUsers() async throws {
        let (bridge, port, token, _) = try await startTestBridge()
        defer { bridge.stop() }
        let harness = try NodeHarness(port: port, token: token)
        defer { harness.stop() }
        #expect(await bridge.waitForConnection(timeout: 15), "\(harness.log)")
        let backend = ExtensionBackend(bridge: bridge, connectTimeout: 3)

        // Glide typed into its own tab, so the page asks "Leave site?" when it's closed.
        let mine = try await backend.openTab(url: "https://example.org/form", background: true)
        _ = try await backend.cdp(tabID: mine.id, method: "Runtime.evaluate", params: ["expression": "1+1"])
        harness.send("dirty \(mine.id)")
        try await Task.sleep(for: .milliseconds(100))
        try await backend.closeTab(mine.id)
        #expect(harness.count("DIALOG_ANSWERED \(mine.id) true") == 1, "\(harness.log)")
        #expect(harness.count("REMOVE \(mine.id)") == 1, "the tab really closes: \(harness.log)")

        // In the user's own tab Chrome's prompt is theirs to answer.
        _ = try await backend.cdp(tabID: "1", method: "Runtime.evaluate", params: ["expression": "1+1"])
        harness.send("dirty 1")
        try await Task.sleep(for: .milliseconds(100))
        let pending = await browserError { _ = try await bridge.call("tabs.remove", params: ["tabId": 1], timeout: 1) }
        #expect(pending?.isTimeout == true, "\(String(describing: pending))")
        #expect(await harness.waitFor("LEAVE_PROMPT 1"), "\(harness.log)")
        #expect(harness.count("DIALOG_ANSWERED 1 true") == 0, "\(harness.log)")
    }
}
