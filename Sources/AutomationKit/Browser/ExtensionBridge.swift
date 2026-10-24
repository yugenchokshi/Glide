import CryptoKit
import Foundation
import Network
import os
import Synchronization

// The Glide Chrome extension (Extensions/chrome) runs in the user's everyday Chrome and
// connects *out* to this localhost WebSocket server. Glide then sends it JSON-RPC requests
// (`tabs.*`, `cdp.send`) that it carries out with chrome.tabs and chrome.debugger — so Glide
// can work in background tabs with the user's own logins, without moving the cursor.
//
// Wire protocol (v1), one JSON object per WebSocket text message:
//
//   extension → GET ws://127.0.0.1:<port>/glide?v=1&nonce=<ts>.<hex>&proof=<hmac>
//   Glide     → {id, method: "hello", params: {proof, app, protocol}}
//   extension ← {id, result: {version, chromeVersion, extensionId, protocol}}
//   Glide     → {id, method: "tabs.list" | "tabs.create" | "tabs.update" | "tabs.remove" |
//                    "cdp.send" | "cdp.detach", params}
//   extension ← {id, result} | {id, error: {message, code?, url?, tabId?}}
//   extension ← {event: "detached", tabId, reason} | {event: "keepalive"}
//
// Security model. Any local process can open a socket to 127.0.0.1, and anything can listen
// on a port while Glide isn't running, so both ends prove they know the pairing token
// (32 random bytes, kept in the Keychain) without ever sending it:
//   • The extension's request carries proof = HMAC-SHA256(token, "glide-bridge/v1 client " + nonce),
//     with a timestamped one-time nonce, plus Chrome's unforgeable `Origin:
//     chrome-extension://<id>` header. Anything else is refused before the upgrade.
//   • Glide's first message (`hello`) carries HMAC(token, "glide-bridge/v1 server " + nonce);
//     the extension obeys nothing until it has checked it. An impostor listening on the port
//     learns only a single-use proof and can't command the browser.
//
// Why not NWProtocolWebSocket: its server side never exposes the request path, so the proof in
// the query can't be checked, and it can't answer the plain-HTTP `/glide/ping` probe the
// extension uses to tell "Glide isn't running" from "pairing was refused". So the upgrade is
// parsed here on a raw TCP NWListener and RFC 6455 framing is done by `WebSocketCodec` below.

// MARK: - Public types

/// Persistence for the bridge's pairing secret. The app keeps it in the Keychain next to its
/// other credentials (`CredentialStore`, account `browser.bridge-token`); tests and tools that
/// must not touch the Keychain use `InMemoryExtensionBridgeStore`.
public protocol ExtensionBridgeStore: Sendable {
    /// The saved token, if any.
    func loadToken() -> String?
    /// Saves a newly minted token. Returns false when it couldn't be persisted (pairing then
    /// only lasts until Glide quits).
    func saveToken(_ token: String) -> Bool
    /// Whether an extension has completed pairing with the saved token.
    func loadPaired() -> Bool
    func savePaired(_ paired: Bool)
}

/// Keeps the pairing token in memory only (tests, previews, tools without Keychain access).
public final class InMemoryExtensionBridgeStore: ExtensionBridgeStore {
    private struct Values { var token: String?; var paired: Bool }
    private let values: Mutex<Values>

    public init(token: String? = nil, paired: Bool = false) {
        values = Mutex(Values(token: token, paired: paired))
    }

    public func loadToken() -> String? { values.withLock { $0.token } }
    public func saveToken(_ token: String) -> Bool { values.withLock { $0.token = token }; return true }
    public func loadPaired() -> Bool { values.withLock { $0.paired } }
    public func savePaired(_ paired: Bool) { values.withLock { $0.paired = paired } }
}

/// What the extension reported about itself when it connected.
public struct ExtensionHello: Sendable, Hashable {
    public var extensionVersion: String
    public var chromeVersion: String
    public var extensionID: String
    public var protocolVersion: Int

    public init(extensionVersion: String, chromeVersion: String, extensionID: String, protocolVersion: Int) {
        self.extensionVersion = extensionVersion
        self.chromeVersion = chromeVersion
        self.extensionID = extensionID
        self.protocolVersion = protocolVersion
    }

    init(json: JSONValue) {
        func text(_ key: String) -> String? { json[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        extensionVersion = text("version") ?? "unknown"
        chromeVersion = text("chromeVersion") ?? "unknown"
        extensionID = text("extensionId") ?? ""
        protocolVersion = json["protocol"]?.intValue ?? ExtensionBridge.protocolVersion
    }
}

/// Things the bridge tells interested parties about (the extension backend, status UI).
public enum ExtensionBridgeEvent: Sendable, Hashable {
    /// An extension finished pairing on a new connection.
    case connected(ExtensionHello)
    /// The connected extension went away (Chrome quit, it was replaced, pairing was reset…).
    case disconnected(String)
    /// Chrome detached the debugger from a tab. `canceled_by_user` means the user dismissed
    /// Chrome's "started debugging this browser" bar; `target_closed` that the tab closed.
    case detached(tabID: String, reason: String)
    /// The extension answered a JavaScript dialog on a tab (alerts dismissed, confirm/prompt
    /// declined, leaving the page allowed).
    case dialog(tabID: String, dialog: BrowserDialog)
}

/// The bridge's state for Settings › Browser and the notch.
public struct ExtensionBridgeStatus: Sendable, Hashable {
    public enum Listener: Sendable, Hashable {
        case stopped
        case starting(port: Int)
        case listening(port: Int)
        /// Couldn't open the port (with a plain-language reason). The bridge keeps retrying.
        case failed(String)
    }

    public var listener: Listener
    public var connected: Bool
    public var paired: Bool
    public var hello: ExtensionHello?
    /// The pairing token couldn't be saved to the Keychain, so pairing won't survive a restart.
    public var tokenPersisted: Bool

    public init(listener: Listener, connected: Bool, paired: Bool, hello: ExtensionHello?, tokenPersisted: Bool = true) {
        self.listener = listener
        self.connected = connected
        self.paired = paired
        self.hello = hello
        self.tokenPersisted = tokenPersisted
    }

    /// One line for the UI, e.g. "Connected to Chrome 141 via the Glide extension".
    public var detail: String {
        switch listener {
        case .stopped: return "The browser bridge is off."
        case .starting: return "Starting the browser bridge…"
        case .failed(let message): return message
        case .listening:
            let note = tokenPersisted ? "" : " Glide couldn't save the pairing to the Keychain, so you'll need to pair again after it restarts."
            if connected {
                let version = hello?.chromeVersion ?? "unknown"
                return (version == "unknown" ? "Connected to Chrome via the Glide extension" : "Connected to Chrome \(version) via the Glide extension") + (note.isEmpty ? "" : "." + note)
            }
            if paired { return "Paired, but Chrome isn't connected right now. Open Chrome; the extension reconnects within 30 seconds." + note }
            return "Waiting for the Glide extension. Install it in Chrome, then click Pair." + note
        }
    }
}

/// Everything needed to pair the extension with this Mac.
public struct ExtensionPairing: Sendable, Hashable {
    /// The shared secret (never shown in full in the UI).
    public var token: String
    public var port: Int
    /// The folder to "Load unpacked" in chrome://extensions, when it could be found.
    public var extensionFolder: URL?
    public var extensionID: String
    /// Opening this in Chrome (with the extension installed) pairs automatically.
    public var pairingURL: URL?
    /// What to paste into the extension's popup when the link can't be opened: `port:token`.
    public var pairingCode: String { "\(port):\(token)" }

    public init(token: String, port: Int, extensionFolder: URL?, extensionID: String, pairingURL: URL?) {
        self.token = token
        self.port = port
        self.extensionFolder = extensionFolder
        self.extensionID = extensionID
        self.pairingURL = pairingURL
    }
}

// MARK: - Bridge

/// Localhost WebSocket server the Glide Chrome extension connects to, plus request/response
/// plumbing (ids, per-call timeouts, keepalive) and pairing. One extension connection is active
/// at a time; the newest authenticated one wins.
///
/// Thread safety: all mutable state lives in one `Mutex`; Network.framework callbacks arrive on
/// a private serial queue. Continuations are always resumed outside the lock.
public final class ExtensionBridge: Sendable {
    public static let shared = ExtensionBridge()

    /// Id of the unpacked extension, fixed by the public key in Extensions/chrome/manifest.json
    /// (first 32 hex chars of SHA-256 of the DER key, mapped 0-f → a-p). Recompute with
    /// `swift scripts/extension_id.swift` if the key ever changes.
    public static let extensionID = "ijondegifnhgojpklbepjoeocacalghd"
    public static var extensionOrigin: String { "chrome-extension://\(extensionID)" }
    public static let defaultPort = 47823
    public static let protocolVersion = 1
    /// WebSocket endpoint; `/glide/ping` answers plain HTTP probes.
    public static let path = "/glide"

    public struct Configuration: Sendable {
        /// `Origin` values allowed to connect. Chrome always sends the extension's own origin.
        public var allowedOrigins: Set<String>
        /// Default time to wait for the extension to answer a request.
        public var requestTimeout: TimeInterval = 30
        /// Time the extension has to answer `hello` (and prove nothing is wrong) after connecting.
        public var helloTimeout: TimeInterval = 10
        /// Time a client has to send its HTTP upgrade request.
        public var handshakeTimeout: TimeInterval = 5
        /// Drop a connection that sent nothing (not even a pong) for this long. The extension
        /// sends a keepalive every 20 s and the bridge pings every `pingInterval`.
        public var idleTimeout: TimeInterval = 65
        public var pingInterval: TimeInterval = 20
        /// Largest message accepted from the extension (full-page screenshots are big).
        public var maxMessageBytes = 64 << 20
        /// Connections still in the HTTP handshake at once; more are dropped immediately.
        public var maxPendingHandshakes = 8
        /// Test hook: send a wrong server proof in `hello`, to exercise the extension's check.
        var sendsInvalidServerProof = false

        public init(allowedOrigins: Set<String> = [ExtensionBridge.extensionOrigin]) {
            self.allowedOrigins = allowedOrigins
        }
    }

    let config: Configuration
    let queue = DispatchQueue(label: "dev.glide.extension-bridge")
    private let state = Mutex(State())
    /// Serializes token minting and saving so concurrent start/reset calls can't interleave.
    private let tokenLock = Mutex(())
    private let log = Logger(subsystem: "dev.glide", category: "extension-bridge")

    public init(configuration: Configuration = Configuration()) {
        config = configuration
    }

    // MARK: Lifecycle

    /// Opens the localhost listener on `port` (0 picks a free port) and loads or mints the
    /// pairing token. Calling it again with the same port is a no-op; a different port moves
    /// the listener. Bind failures (e.g. the port is taken) are reported in `status()` and
    /// retried with backoff, since the port is often only briefly busy after a relaunch.
    public func start(port: Int, store: any ExtensionBridgeStore) {
        guard (0...65535).contains(port) else {
            state.withLock { $0.listenerStatus = .failed("Port \(port) isn't a valid port. Choose one between 1024 and 65535 in Settings › Browser.") }
            return
        }
        let (toClose, generation, oldListener): ([BridgeConnection], Int?, NWListener?) = tokenLock.withLock { _ in
            // Keychain I/O happens outside the state lock: a Keychain prompt must never block
            // status reads from the UI.
            let loaded = Self.loadOrMintToken(store)
            return state.withLock { s in
                var toClose: [BridgeConnection] = []
                if let old = s.token, old != loaded.token {
                    toClose = s.liveConnections
                    s.active = nil
                    s.candidate = nil
                    s.hello = nil
                }
                s.store = store
                s.token = loaded.token
                s.paired = loaded.paired
                s.tokenPersisted = loaded.persisted
                if s.running, s.requestedPort == port { return (toClose, nil, nil) }
                s.generation += 1
                let old = s.listener
                s.listener = nil
                s.running = true
                s.requestedPort = port
                s.boundPort = nil
                s.bindRetryDelay = 1
                s.listenerStatus = .starting(port: port)
                return (toClose, s.generation, old)
            }
        }
        oldListener?.cancel()
        for connection in toClose { closeConnection(connection, code: 4002, reason: "Pairing changed") }
        guard let generation else { return }
        openListener(port: port, generation: generation)
        scheduleWatchdog(generation: generation)
    }

    /// Closes the listener and every connection, failing pending requests.
    public func stop() {
        let (listener, connections, calls, waiters, hadActive) = state.withLock { s in
            s.generation += 1
            s.running = false
            let listener = s.listener
            s.listener = nil
            s.requestedPort = nil
            s.boundPort = nil
            s.listenerStatus = .stopped
            let connections = s.liveConnections + Array(s.handshaking.values)
            let hadActive = s.active != nil
            s.handshaking = [:]
            s.active = nil
            s.candidate = nil
            s.hello = nil
            return (listener, connections, s.takeAllCalls(), s.takeAllWaiters(), hadActive)
        }
        listener?.cancel()
        for connection in connections { closeConnection(connection, code: 1001, reason: "Glide stopped the browser bridge") }
        let error = BrowserError.notConnected("Glide stopped its browser bridge.")
        for call in calls { call.continuation.resume(throwing: error) }
        for waiter in waiters { waiter.resume(returning: false) }
        if hadActive { emit(.disconnected("Glide stopped the browser bridge")) }
    }

    /// Waits until the listener is bound and returns its port (useful with port 0). Throws the
    /// bind failure, or when it isn't listening within `timeout`.
    public func waitUntilListening(timeout: TimeInterval = 5) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch status().listener {
            case .listening(let port): return port
            case .failed(let message): throw BrowserError.notConnected(message)
            case .stopped: throw BrowserError.notConnected("Glide's browser bridge isn't running.")
            case .starting: break
            }
            if Date() >= deadline { throw BrowserError.notConnected("Glide's browser bridge didn't start within \(Self.seconds(timeout)).") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: State

    /// True when an extension is connected and has completed `hello`.
    public var isConnected: Bool { state.withLock { $0.active != nil && $0.hello != nil } }

    /// Whether an extension has paired with the current token (connected at least once).
    public var isPaired: Bool { state.withLock { $0.paired } }

    /// The connected extension's details.
    public var hello: ExtensionHello? { state.withLock { $0.hello } }

    /// The port actually bound, once listening.
    public var boundPort: Int? { state.withLock { $0.boundPort } }

    public func status() -> ExtensionBridgeStatus {
        state.withLock { s in
            ExtensionBridgeStatus(listener: s.listenerStatus, connected: s.active != nil && s.hello != nil,
                                  paired: s.paired, hello: s.hello, tokenPersisted: s.tokenPersisted)
        }
    }

    /// Pairing details for Settings › Browser; nil until `start` has loaded the token.
    public func pairing() -> ExtensionPairing? {
        let values: (String, Int)? = state.withLock { s in
            guard let token = s.token else { return nil }
            return (token, s.boundPort ?? s.requestedPort.flatMap { $0 == 0 ? nil : $0 } ?? Self.defaultPort)
        }
        guard let (token, port) = values else { return nil }
        return ExtensionPairing(token: token, port: port, extensionFolder: Self.extensionFolder(),
                                extensionID: Self.extensionID, pairingURL: Self.pairingURL(token: token, port: port))
    }

    /// `chrome-extension://<id>/pair.html#token=…&port=…`. The secret travels in the fragment,
    /// which is never sent anywhere; the pairing page reads it and wipes it from the address bar.
    public static func pairingURL(token: String, port: Int) -> URL? {
        URL(string: "chrome-extension://\(extensionID)/pair.html#token=\(token)&port=\(port)")
    }

    /// Forgets the paired extension: mints a new token and disconnects the current extension
    /// (which then shows "not paired" until it is paired again).
    public func resetPairing() {
        let connections: [BridgeConnection] = tokenLock.withLock { _ in
            let token = BridgeAuth.mintToken()
            let (store, connections) = state.withLock { s -> ((any ExtensionBridgeStore)?, [BridgeConnection]) in
                s.token = token
                s.paired = false
                s.seenNonces = [:]
                let connections = s.liveConnections
                return (s.store, connections)
            }
            let persisted = store?.saveToken(token) ?? false
            store?.savePaired(false)
            state.withLock { $0.tokenPersisted = persisted }
            return connections
        }
        for connection in connections { closeConnection(connection, code: 4002, reason: "Pairing was reset in Glide") }
    }

    /// Waits up to `timeout` for an extension to connect and finish `hello`.
    public func waitForConnection(timeout: TimeInterval) async -> Bool {
        let key = UUID()
        let registered = state.withLock { s -> Bool in
            if s.active != nil, s.hello != nil { return false }
            s.waiters[key] = .starting
            return true
        }
        guard registered else { return true }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let immediate: Bool? = state.withLock { s in
                    guard case .starting? = s.waiters[key] else { s.waiters[key] = nil; return false }
                    if s.active != nil, s.hello != nil { s.waiters[key] = nil; return true }
                    s.waiters[key] = .waiting(continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }
                queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in self?.resolveWaiter(key, false) }
            }
        } onCancel: {
            resolveWaiter(key, false)
        }
    }

    /// A plain-language reason the extension can't be used right now.
    public func connectionProblem() -> BrowserError {
        state.withLock { Self.notConnectedError($0) }
    }

    // MARK: Requests

    /// Sends one request to the connected extension and returns its `result`. Errors the
    /// extension reports are mapped to `BrowserError` (restricted page, closed tab…).
    public func call(_ method: String, params: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await request(method, params: params, timeout: timeout ?? config.requestTimeout, on: nil)
    }

    // MARK: Events

    /// Registers a handler for bridge events. It runs on the bridge's queue; keep it short.
    @discardableResult
    public func addEventHandler(_ handler: @escaping @Sendable (ExtensionBridgeEvent) -> Void) -> UUID {
        let id = UUID()
        state.withLock { $0.handlers[id] = handler }
        return id
    }

    public func removeEventHandler(_ id: UUID) {
        _ = state.withLock { $0.handlers.removeValue(forKey: id) }
    }

    // MARK: Extension folder

    /// The unpacked extension to load in chrome://extensions: inside the app bundle
    /// (`Contents/Resources/ChromeExtension`, copied by scripts/build_app.sh), else the repo's
    /// `Extensions/chrome` when running unbundled (`swift run`, glidectl).
    public static func extensionFolder(bundle: Bundle = .main) -> URL? {
        let fm = FileManager.default
        func isExtension(_ url: URL) -> Bool { fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) }
        if let bundled = bundle.resourceURL?.appendingPathComponent("ChromeExtension", isDirectory: true), isExtension(bundled) {
            return bundled
        }
        // .build/<config>/Glide → walk up to the checkout.
        var directory = bundle.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let current = directory else { break }
            let candidate = current.appendingPathComponent("Extensions/chrome", isDirectory: true)
            if isExtension(candidate) { return candidate.standardizedFileURL }
            directory = current.deletingLastPathComponent()
        }
        #if DEBUG
        // The checkout this file was compiled from (debug builds only, so release binaries
        // don't carry the build machine's paths).
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fromSource = checkout.appendingPathComponent("Extensions/chrome", isDirectory: true)
        if isExtension(fromSource) { return fromSource.standardizedFileURL }
        #endif
        return nil
    }
}

// MARK: - Internals

extension ExtensionBridge {
    struct PendingCall: Sendable {
        let connection: ObjectIdentifier
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
    }

    /// A request id's lifecycle. `starting` → `waiting` once registered; `cancelled` covers a
    /// task cancelled before registration, so the continuation is never leaked or resumed twice.
    enum CallSlot: Sendable {
        case starting
        case cancelled
        case waiting(PendingCall)
    }

    enum WaiterSlot: Sendable {
        case starting
        case waiting(CheckedContinuation<Bool, Never>)
    }

    struct State {
        var running = false
        var generation = 0
        var listener: NWListener?
        var requestedPort: Int?
        var boundPort: Int?
        var listenerStatus: ExtensionBridgeStatus.Listener = .stopped
        var bindRetryDelay: TimeInterval = 1

        var store: (any ExtensionBridgeStore)?
        var token: String?
        var paired = false
        var tokenPersisted = true

        var handshaking: [ObjectIdentifier: BridgeConnection] = [:]
        /// Authenticated, waiting for its `hello` reply.
        var candidate: BridgeConnection?
        /// Completed `hello`; requests go here.
        var active: BridgeConnection?
        var hello: ExtensionHello?

        var nextID = 0
        var calls: [Int: CallSlot] = [:]
        var waiters: [UUID: WaiterSlot] = [:]
        var handlers: [UUID: @Sendable (ExtensionBridgeEvent) -> Void] = [:]
        /// One-time nonces already used, with when they were seen.
        var seenNonces: [String: Date] = [:]

        var liveConnections: [BridgeConnection] { [candidate, active].compactMap { $0 } }

        mutating func takeAllCalls() -> [PendingCall] {
            var taken: [PendingCall] = []
            for (_, slot) in calls { if case .waiting(let call) = slot { taken.append(call) } }
            calls = [:]
            return taken
        }

        mutating func takeAllWaiters() -> [CheckedContinuation<Bool, Never>] {
            var taken: [CheckedContinuation<Bool, Never>] = []
            for (_, slot) in waiters { if case .waiting(let c) = slot { taken.append(c) } }
            waiters = waiters.filter { if case .starting = $0.value { return true } else { return false } }
            return taken
        }
    }

    static func loadOrMintToken(_ store: any ExtensionBridgeStore) -> (token: String, paired: Bool, persisted: Bool) {
        if let saved = store.loadToken()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), BridgeAuth.isValidToken(saved) {
            return (saved, store.loadPaired(), true)
        }
        let token = BridgeAuth.mintToken()
        let persisted = store.saveToken(token)
        store.savePaired(false)
        return (token, false, persisted)
    }

    static func notConnectedError(_ s: State) -> BrowserError {
        switch s.listenerStatus {
        case .failed(let message): return .notConnected(message)
        case .stopped: return .notConnected("Glide's browser bridge isn't running, so it can't reach the Chrome extension.")
        case .starting, .listening: break
        }
        if !s.paired {
            return .notConnected("The Glide Chrome extension isn't paired yet. In Glide, open Settings › Browser, install the extension and click Pair.")
        }
        return .notConnected("Chrome isn't connected to Glide right now. Make sure Chrome is open with the Glide extension turned on (click its toolbar icon, then Reconnect).")
    }

    static func seconds(_ interval: TimeInterval) -> String {
        let rounded = (interval * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        return rounded == 1 ? "1 second" : "\(text) seconds"
    }

    static func bindFailureMessage(port: Int, error: Error) -> String {
        if case NWError.posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is in use by another app, so the Glide extension can't connect. Glide keeps retrying; you can also pick another port in Settings › Browser."
        }
        return "Glide couldn't open its browser bridge on port \(port) (\(error.localizedDescription)). It keeps retrying."
    }

    // MARK: Listener

    private func openListener(port: Int, generation: Int) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Loopback only: the bridge must never be reachable from the network.
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            listenerFailed(generation: generation, port: port, error: error)
            return
        }
        let installed = state.withLock { s -> Bool in
            guard s.generation == generation, s.running else { return false }
            s.listener = listener
            return true
        }
        guard installed else { return }
        listener.stateUpdateHandler = { [weak self] newState in
            self?.listenerStateChanged(newState, port: port, generation: generation)
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func listenerStateChanged(_ newState: NWListener.State, port: Int, generation: Int) {
        switch newState {
        case .ready:
            let bound: Int? = state.withLock { s in
                guard s.generation == generation, let raw = s.listener?.port?.rawValue else { return nil }
                s.boundPort = Int(raw)
                s.listenerStatus = .listening(port: Int(raw))
                s.bindRetryDelay = 1
                return Int(raw)
            }
            if let bound { log.notice("Extension bridge listening on 127.0.0.1:\(bound, privacy: .public)") }
        case .failed(let error), .waiting(let error):
            listenerFailed(generation: generation, port: port, error: error)
        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func listenerFailed(generation: Int, port: Int, error: Error) {
        let message = Self.bindFailureMessage(port: port, error: error)
        let (listener, retry): (NWListener?, TimeInterval?) = state.withLock { s in
            guard s.generation == generation, s.running else { return (nil, nil) }
            let listener = s.listener
            s.listener = nil
            s.boundPort = nil
            s.listenerStatus = .failed(message)
            let delay = s.bindRetryDelay
            s.bindRetryDelay = min(delay * 2, 30)
            return (listener, delay)
        }
        if let listener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        guard let retry else { return }
        log.error("Extension bridge couldn't listen on port \(port, privacy: .public): \(error.localizedDescription, privacy: .public); retrying in \(retry, privacy: .public) s")
        queue.asyncAfter(deadline: .now() + retry) { [weak self] in
            guard let self else { return }
            let stillWanted = self.state.withLock { $0.generation == generation && $0.running && $0.listener == nil }
            if stillWanted { self.openListener(port: port, generation: generation) }
        }
    }

    // MARK: Connections

    private func accept(_ nw: NWConnection) {
        let connection = BridgeConnection(nw, maxMessage: config.maxMessageBytes)
        let admitted = state.withLock { s -> Bool in
            guard s.running, s.handshaking.count < config.maxPendingHandshakes else { return false }
            s.handshaking[connection.key] = connection
            return true
        }
        guard admitted else { nw.cancel(); return }
        nw.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed(let error):
                self?.connectionEnded(connection, reason: "Connection failed: \(error.localizedDescription)")
            case .cancelled:
                // Break the connection ↔ handler cycle once Network.framework is done with it.
                connection.nw.stateUpdateHandler = nil
                self?.connectionEnded(connection, reason: "Connection closed")
            default:
                break
            }
        }
        nw.start(queue: queue)
        queue.asyncAfter(deadline: .now() + config.handshakeTimeout) { [weak self] in
            guard let self, connection.phase == .handshake else { return }
            self.reject(connection, status: 408, message: "Timed out waiting for the WebSocket request.")
        }
        readHead(connection)
    }

    private func readHead(_ connection: BridgeConnection) {
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, connection.phase == .handshake else { return }
            if let data, !data.isEmpty {
                switch connection.appendHead(data, limit: BridgeHTTP.maxHeadBytes) {
                case .tooLarge:
                    self.reject(connection, status: 431, message: "The request headers are too large.")
                    return
                case .complete(let head, let rest):
                    self.handleHead(connection, head: head, rest: rest)
                    return
                case .incomplete:
                    break
                }
            }
            if isComplete || error != nil {
                self.connectionEnded(connection, reason: "Closed during the handshake")
                return
            }
            self.readHead(connection)
        }
    }

    private func handleHead(_ connection: BridgeConnection, head: [UInt8], rest: [UInt8]) {
        guard let request = BridgeHTTP.parseRequest(head) else {
            reject(connection, status: 400, message: "That isn't a valid HTTP request.")
            return
        }
        let token = state.withLock { $0.token }
        switch BridgeHandshake.evaluate(request, token: token, allowedOrigins: config.allowedOrigins, now: Date()) {
        case .ping:
            guard connection.beginClose() == .handshake else { return }
            let body = #"{"app":"Glide","protocol":\#(Self.protocolVersion)}"#
            respondHTTP(connection, status: 200, contentType: "application/json", body: body)
            cleanup(connection, reason: "Answered a status probe")
        case .reject(let status, let message, let headers):
            log.info("Refused a browser-bridge request (\(status, privacy: .public)): \(message, privacy: .public)")
            reject(connection, status: status, message: message, headers: headers)
        case .upgrade(let accept, let nonce):
            upgrade(connection, accept: accept, nonce: nonce, rest: rest)
        }
    }

    private enum UpgradeOutcome {
        case gone
        case replay
        case busy
        case adopted(replaced: [BridgeConnection], hadActive: Bool)
    }

    private func upgrade(_ connection: BridgeConnection, accept: String, nonce: String, rest: [UInt8]) {
        let now = Date()
        let outcome: UpgradeOutcome = state.withLock { s in
            guard s.handshaking[connection.key] != nil else { return .gone }
            s.seenNonces = s.seenNonces.filter { now.timeIntervalSince($0.value) < BridgeAuth.nonceWindow * 2 }
            if s.seenNonces[nonce] != nil { return .replay }
            if s.seenNonces.count >= 1024 { return .busy }
            s.seenNonces[nonce] = now
            s.handshaking[connection.key] = nil
            // Newest wins: an extension that reconnects (service worker restart, Chrome relaunch)
            // may leave a half-open socket behind.
            let replaced = s.liveConnections
            let hadActive = s.active != nil
            s.active = nil
            s.hello = nil
            s.candidate = connection
            return .adopted(replaced: replaced, hadActive: hadActive)
        }
        switch outcome {
        case .gone:
            return
        case .replay:
            reject(connection, status: 401, message: "This connection attempt was already used. Reconnect from the extension.")
        case .busy:
            reject(connection, status: 503, message: "Too many connection attempts. Try again in a minute.")
        case .adopted(let replaced, let hadActive):
            connection.open(nonce: nonce)
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            connection.nw.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
            for old in replaced { closeConnection(old, code: 4001, reason: "Another Chrome connected to Glide") }
            if hadActive { emit(.disconnected("Replaced by a newer extension connection")) }
            if !rest.isEmpty, !processInbound(connection, Data(rest)) { return }
            readFrames(connection)
            startHello(connection)
        }
    }

    private func startHello(_ connection: BridgeConnection) {
        let token = state.withLock { $0.token }
        guard let token else {
            closeConnection(connection, code: 1011, reason: "Glide isn't ready")
            return
        }
        var proof = BridgeAuth.serverProof(token: token, nonce: connection.nonce)
        if config.sendsInvalidServerProof { proof = String(repeating: "0", count: proof.count) }
        let params: JSONValue = ["proof": .string(proof), "app": "Glide", "protocol": .number(Double(Self.protocolVersion))]
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.request("hello", params: params, timeout: self.config.helloTimeout, on: connection)
                self.helloSucceeded(connection, reply: reply)
            } catch {
                self.log.error("The Glide extension didn't complete hello: \(error.localizedDescription, privacy: .public)")
                self.closeConnection(connection, code: 1008, reason: "Hello failed")
            }
        }
    }

    private func helloSucceeded(_ connection: BridgeConnection, reply: JSONValue) {
        let hello = ExtensionHello(json: reply)
        let outcome: (waiters: [CheckedContinuation<Bool, Never>], newlyPaired: Bool, store: (any ExtensionBridgeStore)?)? = state.withLock { s in
            guard s.candidate === connection, connection.isOpen else { return nil }
            s.candidate = nil
            s.active = connection
            s.hello = hello
            let newlyPaired = !s.paired
            s.paired = true
            return (s.takeAllWaiters(), newlyPaired, s.store)
        }
        guard let outcome else { return }
        if outcome.newlyPaired { outcome.store?.savePaired(true) }
        log.notice("Glide extension \(hello.extensionVersion, privacy: .public) connected from Chrome \(hello.chromeVersion, privacy: .public)")
        for waiter in outcome.waiters { waiter.resume(returning: true) }
        emit(.connected(hello))
    }

    private func readFrames(_ connection: BridgeConnection) {
        connection.nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, connection.phase == .open else { return }
            if let data, !data.isEmpty, !self.processInbound(connection, data) { return }
            if let error {
                self.connectionEnded(connection, reason: "Connection error: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.connectionEnded(connection, reason: "Chrome closed the connection")
                return
            }
            self.readFrames(connection)
        }
    }

    /// Feeds bytes to the connection's frame parser and handles complete messages. Returns
    /// false once the connection is closed.
    private func processInbound(_ connection: BridgeConnection, _ data: Data) -> Bool {
        switch connection.consume(data, maxFrame: config.maxMessageBytes) {
        case .failure(let failure):
            log.error("Closing the extension connection: \(failure.reason, privacy: .public)")
            closeConnection(connection, code: failure.code, reason: failure.reason)
            return false
        case .success(let messages):
            for message in messages {
                handleMessage(connection, message)
                if connection.phase != .open { return false }
            }
            return true
        }
    }

    private func handleMessage(_ connection: BridgeConnection, _ message: WebSocketAssembler.Message) {
        connection.touch()
        switch message {
        case .text(let text):
            handleText(connection, text)
        case .binary, .pong:
            break
        case .ping(let payload):
            sendFrame(.pong, payload, on: connection)
        case .close(let code, _):
            // Echo the peer's code (RFC 6455 §5.5.1), then hang up.
            if connection.beginClose() == .open {
                let echoed = code.flatMap { WebSocketCodec.isSendableCloseCode($0) ? WebSocketCodec.closePayload(code: $0, reason: "") : nil }
                let echo = WebSocketCodec.encode(.close, payload: echoed ?? [])
                connection.nw.send(content: Data(echo), completion: .contentProcessed { _ in connection.nw.cancel() })
            } else {
                connection.nw.cancel()
            }
            cleanup(connection, reason: code.map { "Chrome closed the connection (\($0))" } ?? "Chrome closed the connection")
        }
    }

    private func handleText(_ connection: BridgeConnection, _ text: String) {
        guard let object = (try? JSONValue.parse(text))?.objectValue else { return }
        if let event = object["event"]?.stringValue {
            let isActive = state.withLock { $0.active === connection }
            guard isActive else { return }
            switch event {
            case "detached":
                emit(.detached(tabID: object["tabId"]?.stringValue ?? "", reason: object["reason"]?.stringValue ?? "unknown"))
            case "dialog":
                let dialog = BrowserDialog(type: object["type"]?.stringValue ?? "alert",
                                           message: String((object["message"]?.stringValue ?? "").prefix(500)),
                                           accepted: object["accepted"]?.boolValue ?? false)
                emit(.dialog(tabID: object["tabId"]?.stringValue ?? "", dialog: dialog))
            default:
                break // "keepalive" (already counted by touch()) and future events.
            }
            return
        }
        // Requests from the extension aren't part of protocol v1.
        guard object["method"] == nil, let id = object["id"]?.intValue else { return }
        let pending: PendingCall? = state.withLock { s in
            guard case .waiting(let call)? = s.calls[id], call.connection == connection.key else { return nil }
            s.calls[id] = nil
            return call
        }
        guard let pending else { return } // Late reply after a timeout, or not ours.
        if let error = object["error"], !error.isNull {
            pending.continuation.resume(throwing: Self.mapExtensionError(error, method: pending.method))
        } else {
            pending.continuation.resume(returning: object["result"] ?? .null)
        }
    }

    /// Turns the extension's `{message, code}` into the matching `BrowserError`.
    static func mapExtensionError(_ error: JSONValue, method: String) -> BrowserError {
        func text(_ value: JSONValue?) -> String? { value?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        guard error.objectValue != nil else {
            return .cdp(text(error) ?? "Chrome couldn't run “\(method)”.")
        }
        let message = text(error["message"]) ?? "Chrome couldn't run “\(method)”."
        switch text(error["code"]) {
        case "restricted": return .restrictedPage(text(error["url"]) ?? "this page")
        case "tab_not_found": return .tabNotFound(text(error["tabId"]) ?? "")
        case "canceled_by_user", "not_authenticated", "not_paired": return .notConnected(message)
        case "timeout": return .timeout(message)
        case "dialog_open": return .dialogOpen(message)
        default: return .cdp(message)
        }
    }

    // MARK: Request plumbing

    private func request(_ method: String, params: JSONValue?, timeout: TimeInterval, on target: BridgeConnection?) async throws -> JSONValue {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            s.calls[s.nextID] = .starting
            return s.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                let registered: Result<BridgeConnection, BrowserError>? = state.withLock { s in
                    guard case .starting? = s.calls[id] else {
                        s.calls[id] = nil
                        return nil // Cancelled before we got here.
                    }
                    let connection: BridgeConnection?
                    if let target {
                        connection = (s.candidate === target || s.active === target) ? target : nil
                    } else {
                        connection = s.hello == nil ? nil : s.active
                    }
                    guard let connection, connection.isOpen else {
                        s.calls[id] = nil
                        return .failure(Self.notConnectedError(s))
                    }
                    s.calls[id] = .waiting(PendingCall(connection: connection.key, method: method, continuation: continuation))
                    return .success(connection)
                }
                switch registered {
                case nil:
                    continuation.resume(throwing: CancellationError())
                case .failure(let error)?:
                    continuation.resume(throwing: error)
                case .success(let connection)?:
                    var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method)]
                    if let params { message["params"] = params }
                    let payload = Array(JSONValue.object(message).jsonString().utf8)
                    sendFrame(.text, payload, on: connection) { [weak self] error in
                        guard let error else { return }
                        self?.finishCall(id, .failure(BrowserError.notConnected("Glide couldn't send “\(method)” to Chrome (\(error.localizedDescription)).")))
                    }
                    queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
                        self?.finishCall(id, .failure(BrowserError.timeout("Chrome didn't answer “\(method)” within \(Self.seconds(timeout)).")))
                    }
                }
            }
        } onCancel: {
            let pending: PendingCall? = state.withLock { s in
                switch s.calls[id] {
                case .starting?:
                    s.calls[id] = .cancelled
                    return nil
                case .waiting(let call)?:
                    s.calls[id] = nil
                    return call
                default:
                    return nil
                }
            }
            pending?.continuation.resume(throwing: CancellationError())
        }
    }

    private func finishCall(_ id: Int, _ result: Result<JSONValue, Error>) {
        let pending: PendingCall? = state.withLock { s in
            guard case .waiting(let call)? = s.calls[id] else { return nil }
            s.calls[id] = nil
            return call
        }
        pending?.continuation.resume(with: result)
    }

    private func resolveWaiter(_ key: UUID, _ value: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = state.withLock { s in
            switch s.waiters[key] {
            case .waiting(let c)?:
                s.waiters[key] = nil
                return c
            case .starting?:
                // Cancelled before the continuation was stored: drop the slot; the registering
                // code sees it gone and returns false.
                s.waiters[key] = nil
                return nil
            case nil:
                return nil
            }
        }
        continuation?.resume(returning: value)
    }

    private func sendFrame(_ opcode: WebSocketOpcode, _ payload: [UInt8], on connection: BridgeConnection,
                           completion: (@Sendable (NWError?) -> Void)? = nil) {
        let frame = WebSocketCodec.encode(opcode, payload: payload)
        connection.nw.send(content: Data(frame), completion: .contentProcessed { error in completion?(error) })
    }

    private func emit(_ event: ExtensionBridgeEvent) {
        let handlers = state.withLock { Array($0.handlers.values) }
        for handler in handlers { handler(event) }
    }

    // MARK: Closing

    /// Closes a connection with a WebSocket close frame (or just hangs up during the handshake)
    /// and fails its pending requests right away.
    func closeConnection(_ connection: BridgeConnection, code: UInt16, reason: String) {
        switch connection.beginClose() {
        case .closed:
            return
        case .open:
            let frame = WebSocketCodec.encode(.close, payload: WebSocketCodec.closePayload(code: code, reason: reason))
            connection.nw.send(content: Data(frame), completion: .contentProcessed { _ in })
            // Give the peer a moment to read the close frame (so Chrome sees our code) before
            // tearing down the socket.
            queue.asyncAfter(deadline: .now() + 1) { connection.nw.cancel() }
        case .handshake:
            connection.nw.cancel()
        }
        cleanup(connection, reason: reason)
    }

    private func connectionEnded(_ connection: BridgeConnection, reason: String) {
        if connection.beginClose() != .closed { connection.nw.cancel() }
        cleanup(connection, reason: reason)
    }

    /// Removes the connection from the bridge's state. Safe to call more than once.
    private func cleanup(_ connection: BridgeConnection, reason: String) {
        let (wasActive, failed): (Bool, [PendingCall]) = state.withLock { s in
            s.handshaking[connection.key] = nil
            var wasActive = false
            if s.active === connection {
                s.active = nil
                s.hello = nil
                wasActive = true
            }
            if s.candidate === connection { s.candidate = nil }
            var failed: [PendingCall] = []
            let ids = s.calls.compactMap { id, slot -> Int? in
                if case .waiting(let call) = slot, call.connection == connection.key { return id }
                return nil
            }
            for id in ids {
                if case .waiting(let call)? = s.calls.removeValue(forKey: id) { failed.append(call) }
            }
            return (wasActive, failed)
        }
        if !failed.isEmpty {
            let error = BrowserError.notConnected("Chrome disconnected from Glide before it answered (\(reason)). Try again in a moment.")
            for call in failed { call.continuation.resume(throwing: error) }
        }
        if wasActive {
            log.notice("Glide extension disconnected: \(reason, privacy: .public)")
            emit(.disconnected(reason))
        }
    }

    private func reject(_ connection: BridgeConnection, status: Int, message: String, headers: [String: String] = [:]) {
        guard connection.beginClose() == .handshake else { return }
        respondHTTP(connection, status: status, contentType: "text/plain; charset=utf-8", body: message + "\n", headers: headers)
        cleanup(connection, reason: "Refused (\(status))")
    }

    private func respondHTTP(_ connection: BridgeConnection, status: Int, contentType: String, body: String, headers: [String: String] = [:]) {
        let data = BridgeHTTP.response(status: status, contentType: contentType, body: body, headers: headers)
        connection.nw.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.nw.cancel()
        })
    }

    // MARK: Watchdog

    private var watchdogInterval: TimeInterval { max(0.1, min(10, config.idleTimeout / 3, config.pingInterval / 2)) }

    private func scheduleWatchdog(generation: Int) {
        queue.asyncAfter(deadline: .now() + watchdogInterval) { [weak self] in
            guard let self, self.state.withLock({ $0.generation == generation && $0.running }) else { return }
            self.runWatchdog()
            self.scheduleWatchdog(generation: generation)
        }
    }

    private func runWatchdog() {
        let now = Date()
        let connections = state.withLock { s in
            s.seenNonces = s.seenNonces.filter { now.timeIntervalSince($0.value) < BridgeAuth.nonceWindow * 2 }
            return s.liveConnections
        }
        for connection in connections where connection.isOpen {
            let (lastSeen, lastPing) = connection.timestamps
            if now.timeIntervalSince(lastSeen) > config.idleTimeout {
                closeConnection(connection, code: 4000, reason: "Chrome stopped responding")
            } else if now.timeIntervalSince(lastPing) >= config.pingInterval {
                connection.markPinged(now)
                sendFrame(.ping, [], on: connection)
            }
        }
    }
}

// MARK: - Connection

/// One TCP connection: HTTP handshake buffer, then WebSocket frame buffer and assembler.
final class BridgeConnection: Sendable {
    enum Phase: Sendable, Equatable { case handshake, open, closed }

    enum HeadOutcome: Sendable {
        case incomplete
        case tooLarge
        case complete(head: [UInt8], rest: [UInt8])
    }

    private struct State {
        var phase: Phase = .handshake
        var head: [UInt8] = []
        var inbox: [UInt8] = []
        var assembler: WebSocketAssembler
        var nonce = ""
        var lastSeen: Date
        var lastPing: Date
    }

    let nw: NWConnection
    let key: ObjectIdentifier
    private let state: Mutex<State>

    init(_ nw: NWConnection, maxMessage: Int) {
        self.nw = nw
        key = ObjectIdentifier(nw)
        let now = Date()
        state = Mutex(State(assembler: WebSocketAssembler(maxMessage: maxMessage), lastSeen: now, lastPing: now))
    }

    var phase: Phase { state.withLock { $0.phase } }
    var isOpen: Bool { phase == .open }
    var nonce: String { state.withLock { $0.nonce } }
    var timestamps: (lastSeen: Date, lastPing: Date) { state.withLock { ($0.lastSeen, $0.lastPing) } }

    func appendHead(_ data: Data, limit: Int) -> HeadOutcome {
        state.withLock { s in
            s.head.append(contentsOf: data)
            if let end = BridgeHTTP.headEnd(in: s.head) {
                guard end <= limit else { return .tooLarge }
                let head = Array(s.head[..<end])
                let rest = Array(s.head[end...])
                s.head = []
                return .complete(head: head, rest: rest)
            }
            return s.head.count > limit ? .tooLarge : .incomplete
        }
    }

    func open(nonce: String) {
        state.withLock { s in
            guard s.phase == .handshake else { return }
            s.phase = .open
            s.nonce = nonce
            s.lastSeen = Date()
            s.lastPing = Date()
        }
    }

    /// Moves to `.closed` and returns the previous phase; only the first caller sees anything
    /// other than `.closed`, which makes closing idempotent.
    func beginClose() -> Phase {
        state.withLock { s in
            let previous = s.phase
            s.phase = .closed
            s.head = []
            s.inbox = []
            return previous
        }
    }

    func touch() { state.withLock { $0.lastSeen = Date() } }
    func markPinged(_ date: Date) { state.withLock { $0.lastPing = date } }

    func consume(_ data: Data, maxFrame: Int) -> Result<[WebSocketAssembler.Message], WebSocketFailure> {
        state.withLock { s in
            guard s.phase == .open else { return .success([]) }
            s.inbox.append(contentsOf: data)
            var messages: [WebSocketAssembler.Message] = []
            var offset = 0
            do throws(WebSocketFailure) {
                parsing: while true {
                    switch try WebSocketCodec.parse(s.inbox, from: offset, maxPayload: maxFrame) {
                    case .needMore:
                        break parsing
                    case .frame(let frame, let consumed):
                        offset += consumed
                        if let message = try s.assembler.push(frame) { messages.append(message) }
                    }
                }
            } catch {
                return .failure(error)
            }
            if offset > 0 { s.inbox.removeFirst(offset) }
            return .success(messages)
        }
    }
}

// MARK: - Authentication

enum BridgeAuth {
    static let clientLabel = "glide-bridge/v1 client "
    static let serverLabel = "glide-bridge/v1 server "
    /// How far a nonce's timestamp may be from now. Both ends share this Mac's clock.
    static let nonceWindow: TimeInterval = 120

    /// 32 random bytes as lowercase hex.
    static func mintToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return hex((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy(isLowerHex)
    }

    static func clientProof(token: String, nonce: String) -> String { proof(token: token, label: clientLabel, nonce: nonce) }
    static func serverProof(token: String, nonce: String) -> String { proof(token: token, label: serverLabel, nonce: nonce) }

    static func proof(token: String, label: String, nonce: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data((label + nonce).utf8), using: SymmetricKey(data: Data(token.utf8)))
        return hex(Array(code))
    }

    /// `<unix seconds>.<32 hex chars>`, the same format the extension generates.
    static func makeNonce(now: Date = Date()) -> String {
        var generator = SystemRandomNumberGenerator()
        let random = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return "\(Int(now.timeIntervalSince1970)).\(hex(random))"
    }

    /// The nonce's timestamp, or nil when it isn't well formed.
    static func nonceTimestamp(_ nonce: String) -> TimeInterval? {
        let parts = nonce.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...12).contains(parts[0].utf8.count), parts[0].utf8.allSatisfy({ (48...57).contains($0) }),
              parts[1].utf8.count == 32, parts[1].utf8.allSatisfy(isLowerHex), let seconds = Int(parts[0]) else { return nil }
        return TimeInterval(seconds)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }

    private static func isLowerHex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (97...102).contains(byte) }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    static func hex(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - HTTP handshake

enum BridgeHTTP {
    static let maxHeadBytes = 8 * 1024
    static let maxHeaders = 64

    struct Request: Sendable, Equatable {
        var method: String
        var target: String
        var path: String
        var query: [String: String]
        /// Lowercased names; repeated headers are joined with ", ".
        var headers: [String: String]

        func header(_ name: String) -> String? { headers[name.lowercased()] }

        /// Comma-separated tokens of a header, lowercased (e.g. `Connection: keep-alive, Upgrade`).
        func headerTokens(_ name: String) -> Set<String> {
            Set((header(name) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        }
    }

    /// Index just past the blank line ending the request head, if it has arrived.
    static func headEnd(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i + 4
        }
        return nil
    }

    static func parseRequest(_ head: [UInt8]) -> Request? {
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty, lines.count - 1 <= maxHeaders else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        guard target.hasPrefix("/"), let components = URLComponents(string: "http://127.0.0.1" + target) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            if let existing = headers[name] { headers[name] = existing + ", " + value } else { headers[name] = value }
        }
        return Request(method: method, target: target, path: components.percentEncodedPath, query: query, headers: headers)
    }

    static func response(status: Int, contentType: String, body: String, headers: [String: String] = [:]) -> Data {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + bodyData
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 426: return "Upgrade Required"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}

enum BridgeHandshake {
    enum Decision: Sendable, Equatable {
        case upgrade(accept: String, nonce: String)
        case ping
        case reject(status: Int, message: String, headers: [String: String])
    }

    static let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Decides what to do with a request. Pure, so every rule is unit-tested.
    static func evaluate(_ request: BridgeHTTP.Request, token: String?, allowedOrigins: Set<String>, now: Date) -> Decision {
        func reject(_ status: Int, _ message: String, _ headers: [String: String] = [:]) -> Decision {
            .reject(status: status, message: message, headers: headers)
        }
        guard request.method == "GET" else { return reject(405, "Only GET requests are supported.", ["Allow": "GET"]) }
        // Reject anything not addressed to loopback (defense in depth against DNS rebinding).
        guard isLoopbackHost(request.header("host")) else { return reject(403, "Glide only accepts connections addressed to 127.0.0.1.") }
        if request.path == ExtensionBridge.path + "/ping" { return .ping }
        guard request.path == ExtensionBridge.path else { return reject(404, "Not found.") }
        guard request.header("upgrade")?.lowercased() == "websocket", request.headerTokens("connection").contains("upgrade") else {
            return reject(400, "Expected a WebSocket upgrade request.")
        }
        guard request.header("sec-websocket-version") == "13" else {
            return reject(426, "Only WebSocket version 13 is supported.", ["Sec-WebSocket-Version": "13"])
        }
        guard let key = request.header("sec-websocket-key"), Data(base64Encoded: key)?.count == 16 else {
            return reject(400, "Missing or invalid Sec-WebSocket-Key.")
        }
        guard let origin = request.header("origin"), allowedOrigins.contains(origin) else {
            return reject(403, "Only the Glide Chrome extension may connect.")
        }
        guard request.query["v"] == String(ExtensionBridge.protocolVersion) else {
            return reject(400, "This Glide extension doesn't match the app. Reload it from Settings › Browser.")
        }
        guard let token else { return reject(503, "Glide isn't ready for the extension yet.") }
        guard let nonce = request.query["nonce"], let proof = request.query["proof"], let timestamp = BridgeAuth.nonceTimestamp(nonce) else {
            return reject(401, "Pairing is required. Pair the extension from Glide's Settings › Browser.")
        }
        guard abs(now.timeIntervalSince1970 - timestamp) <= BridgeAuth.nonceWindow else {
            return reject(401, "The connection attempt expired. Reconnect from the extension.")
        }
        guard BridgeAuth.constantTimeEquals(proof.lowercased(), BridgeAuth.clientProof(token: token, nonce: nonce)) else {
            return reject(401, "The pairing doesn't match. Pair again from Glide's Settings › Browser.")
        }
        return .upgrade(accept: acceptValue(forKey: key), nonce: nonce)
    }

    /// `Sec-WebSocket-Accept` for a client key (RFC 6455 §4.2.2).
    static func acceptValue(forKey key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + websocketGUID).utf8))).base64EncodedString()
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard var host = host?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            host = String(host[host.index(after: host.startIndex)..<close])
            return host == "::1"
        }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        return host == "127.0.0.1" || host == "localhost"
    }
}

// MARK: - WebSocket framing (RFC 6455)

enum WebSocketOpcode: UInt8, Sendable {
    case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    var isControl: Bool { rawValue >= 0x8 }
}

struct WebSocketFrame: Sendable, Equatable {
    var fin: Bool
    var opcode: WebSocketOpcode
    var payload: [UInt8]
}

/// A protocol violation, with the close code to send (1002 protocol error, 1007 bad UTF-8,
/// 1009 too big).
struct WebSocketFailure: Error, Sendable, Equatable {
    var code: UInt16
    var reason: String
}

enum WebSocketCodec {
    enum Parsed: Sendable, Equatable {
        case frame(WebSocketFrame, consumed: Int)
        case needMore
    }

    /// Parses one frame starting at `start`. Client→server frames must be masked.
    static func parse(_ bytes: [UInt8], from start: Int = 0, maxPayload: Int, requireMask: Bool = true) throws(WebSocketFailure) -> Parsed {
        guard bytes.count - start >= 2 else { return .needMore }
        let first = bytes[start], second = bytes[start + 1]
        guard first & 0x70 == 0 else { throw WebSocketFailure(code: 1002, reason: "Reserved bits are set") }
        guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else { throw WebSocketFailure(code: 1002, reason: "Unknown opcode") }
        let fin = first & 0x80 != 0
        let masked = second & 0x80 != 0
        if requireMask, !masked { throw WebSocketFailure(code: 1002, reason: "Client frames must be masked") }
        var length = UInt64(second & 0x7F)
        var offset = start + 2
        if length == 126 {
            guard bytes.count >= offset + 2 else { return .needMore }
            length = UInt64(bytes[offset]) << 8 | UInt64(bytes[offset + 1])
            offset += 2
        } else if length == 127 {
            guard bytes.count >= offset + 8 else { return .needMore }
            length = 0
            for i in 0..<8 { length = length << 8 | UInt64(bytes[offset + i]) }
            offset += 8
            guard length >> 63 == 0 else { throw WebSocketFailure(code: 1002, reason: "Invalid frame length") }
        }
        if opcode.isControl, !fin || length > 125 { throw WebSocketFailure(code: 1002, reason: "Invalid control frame") }
        guard length <= UInt64(max(0, maxPayload)) else { throw WebSocketFailure(code: 1009, reason: "Message too big") }
        let payloadLength = Int(length)
        var mask: (UInt8, UInt8, UInt8, UInt8)?
        if masked {
            guard bytes.count >= offset + 4 else { return .needMore }
            mask = (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
            offset += 4
        }
        guard bytes.count - offset >= payloadLength else { return .needMore }
        var payload = Array(bytes[offset..<(offset + payloadLength)])
        if let mask {
            let key = [mask.0, mask.1, mask.2, mask.3]
            payload.withUnsafeMutableBufferPointer { buffer in
                for i in buffer.indices { buffer[i] ^= key[i & 3] }
            }
        }
        return .frame(WebSocketFrame(fin: fin, opcode: opcode, payload: payload), consumed: offset + payloadLength - start)
    }

    /// Encodes one frame. Server frames are unmasked; tests pass `mask` to play the client.
    static func encode(_ opcode: WebSocketOpcode, payload: [UInt8], fin: Bool = true, mask: [UInt8]? = nil) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(payload.count + 14)
        out.append((fin ? 0x80 : 0) | opcode.rawValue)
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        if payload.count < 126 {
            out.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8(payload.count >> 8))
            out.append(UInt8(payload.count & 0xFF))
        } else {
            out.append(maskBit | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((length >> UInt64(shift)) & 0xFF)) }
        }
        if let mask, mask.count == 4 {
            out.append(contentsOf: mask)
            for (i, byte) in payload.enumerated() { out.append(byte ^ mask[i & 3]) }
        } else {
            out.append(contentsOf: payload)
        }
        return out
    }

    /// Codes that may appear in a close frame (1005, 1006 and 1015 are reserved for local use).
    static func isSendableCloseCode(_ code: UInt16) -> Bool {
        (1000...1003).contains(code) || (1007...1014).contains(code) || (3000...4999).contains(code)
    }

    /// Close frame payload: 2-byte code plus a UTF-8 reason trimmed to fit 125 bytes.
    static func closePayload(code: UInt16, reason: String) -> [UInt8] {
        var trimmed = reason
        while trimmed.utf8.count > 123 { trimmed.removeLast() }
        return [UInt8(code >> 8), UInt8(code & 0xFF)] + Array(trimmed.utf8)
    }
}

/// Reassembles fragmented messages and decodes control frames.
struct WebSocketAssembler: Sendable {
    enum Message: Sendable, Equatable {
        case text(String)
        case binary([UInt8])
        case ping([UInt8])
        case pong([UInt8])
        case close(code: UInt16?, reason: String)
    }

    let maxMessage: Int
    private var partial: [UInt8] = []
    private var partialOpcode: WebSocketOpcode?

    init(maxMessage: Int) { self.maxMessage = maxMessage }

    mutating func push(_ frame: WebSocketFrame) throws(WebSocketFailure) -> Message? {
        switch frame.opcode {
        case .ping:
            return .ping(frame.payload)
        case .pong:
            return .pong(frame.payload)
        case .close:
            guard !frame.payload.isEmpty else { return .close(code: nil, reason: "") }
            guard frame.payload.count >= 2 else { throw WebSocketFailure(code: 1002, reason: "Malformed close frame") }
            let code = UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
            guard let reason = String(validating: frame.payload[2...], as: UTF8.self) else {
                throw WebSocketFailure(code: 1007, reason: "Close reason wasn't valid UTF-8")
            }
            return .close(code: code, reason: reason)
        case .text, .binary:
            guard partialOpcode == nil else { throw WebSocketFailure(code: 1002, reason: "Expected a continuation frame") }
            if frame.fin { return try Self.complete(frame.opcode, frame.payload) }
            partialOpcode = frame.opcode
            partial = frame.payload
            return nil
        case .continuation:
            guard let opcode = partialOpcode else { throw WebSocketFailure(code: 1002, reason: "Unexpected continuation frame") }
            guard partial.count + frame.payload.count <= maxMessage else { throw WebSocketFailure(code: 1009, reason: "Message too big") }
            partial.append(contentsOf: frame.payload)
            guard frame.fin else { return nil }
            let payload = partial
            partial = []
            partialOpcode = nil
            return try Self.complete(opcode, payload)
        }
    }

    private static func complete(_ opcode: WebSocketOpcode, _ payload: [UInt8]) throws(WebSocketFailure) -> Message {
        if opcode == .binary { return .binary(payload) }
        guard let text = String(validating: payload, as: UTF8.self) else {
            throw WebSocketFailure(code: 1007, reason: "Text message wasn't valid UTF-8")
        }
        return .text(text)
    }
}
