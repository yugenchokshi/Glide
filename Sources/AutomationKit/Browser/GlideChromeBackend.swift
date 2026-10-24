import Foundation
import Darwin

/// Glide's own Chrome: a separate Chrome instance with a dedicated profile and a local
/// debugging port, driven over one browser-level CDP connection.
///
/// It's the fallback when the Glide extension isn't installed, and what tests use (headless,
/// temporary profile). Logins made in it persist in its profile, apart from the user's everyday
/// Chrome. If Glide quits while this Chrome keeps running, the next `connect()` adopts it again
/// through the `DevToolsActivePort` file Chrome leaves in the profile.
public actor GlideChromeBackend: BrowserBackend, BrowserPageObserving, BrowserStatusDescribing {
    public struct Configuration: Sendable, Hashable {
        /// Chrome executable to use instead of the standard install locations.
        public var chromePath: String?
        public var userDataDirectory: URL
        /// No window (tests and fully background use).
        public var headless: Bool
        /// Keeps Chrome away from the login Keychain (tests); defaults to `headless`.
        public var useMockKeychain: Bool
        public var extraArguments: [String]
        public var launchTimeout: TimeInterval
        public var commandTimeout: TimeInterval

        public init(chromePath: String? = nil, userDataDirectory: URL = GlideChromeBackend.defaultProfileDirectory, headless: Bool = false,
                    useMockKeychain: Bool? = nil, extraArguments: [String] = [], launchTimeout: TimeInterval = 20, commandTimeout: TimeInterval = 30) {
            self.chromePath = chromePath
            self.userDataDirectory = userDataDirectory
            self.headless = headless
            self.useMockKeychain = useMockKeychain ?? headless
            self.extraArguments = extraArguments
            self.launchTimeout = launchTimeout
            self.commandTimeout = commandTimeout
        }
    }

    /// `~/Library/Application Support/Glide/GlideChrome` (next to Glide's other data).
    public static let defaultProfileDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Glide/GlideChrome", isDirectory: true)
    }()

    /// Flags that stop Chrome's own background traffic (updates, sync, safe-browsing lists,
    /// metrics). For tests and offline runs; the everyday Glide window keeps Chrome's defaults
    /// so its security features stay up to date.
    public static let quietArguments = [
        "--disable-background-networking", "--disable-component-update", "--disable-sync", "--disable-default-apps",
        "--disable-extensions", "--disable-client-side-phishing-detection", "--disable-domain-reliability", "--no-pings",
        "--metrics-recording-only", "--safebrowsing-disable-auto-update", "--disable-search-engine-choice-screen",
        "--disable-features=Translate,OptimizationHints,MediaRouter,AutofillServerCommunication,CertificateTransparencyComponentUpdater",
    ]

    public nonisolated let kind: BrowserBackendKind = .glideChrome

    private struct Endpoint {
        let port: Int
        let path: String
        var webSocketURL: URL? { URL(string: "ws://127.0.0.1:\(port)\(path)") }
    }

    private struct NetworkState {
        var inflight: [String: Date] = [:]
        var lastChange = Date.distantPast
    }

    private var configuration: Configuration
    private var socket: CDPWebSocket?
    private var generation = 0
    private var eventTask: Task<Void, Never>?
    private var connecting: Task<Void, Error>?
    /// The Chrome process when Glide launched it (nil when adopting a running one).
    private var process: Process?
    private var version: String?
    private var sessions: [String: String] = [:]        // tab (target) id → CDP session id
    private var sessionTabs: [String: String] = [:]     // session id → tab id
    private var attaching: [String: Task<String, Error>] = [:]
    private var network: [String: NetworkState] = [:]   // by session id
    private var dialogs: [String: [BrowserDialog]] = [:] // by tab id
    private var owned: Set<String> = []
    private var activeTabID: String?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Settings › Browser can point at a custom Chrome; takes effect on the next launch.
    public func setChromePath(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.chromePath = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    public var currentConfiguration: Configuration { configuration }

    /// The Chrome product string once connected, e.g. "Chrome/141.0.7390.54".
    public var chromeVersion: String? { version }

    /// The browser process Glide launched (nil when it adopted a running Chrome).
    public var launchedProcessID: pid_t? { process?.processIdentifier }

    // MARK: Connection

    public func isConnected() async -> Bool {
        guard let socket, await socket.isOpen else { return false }
        if let process, !process.isRunning { return false }
        return true
    }

    /// Launches Chrome (or adopts the one already running on Glide's profile) and connects to
    /// it. Safe to call concurrently: callers share one attempt. Cancelling a caller (the stop
    /// button) cancels the launch too, rather than waiting for Chrome to come up.
    public func connect() async throws {
        if await isConnected() { return }
        let attempt: Task<Void, Error>
        if let pending = connecting {
            attempt = pending
        } else {
            attempt = Task { try await self.establish() }
            connecting = attempt
        }
        defer { if connecting == attempt { connecting = nil } }
        try await withTaskCancellationHandler {
            try await attempt.value
        } onCancel: {
            attempt.cancel()
        }
    }

    /// Closes Chrome: politely over CDP, then SIGTERM, then SIGKILL if it still hasn't quit.
    public func shutdown() async {
        // Let a launch in progress stop first, so it can't leave a Chrome running behind us.
        if let attempt = connecting {
            attempt.cancel()
            _ = try? await attempt.value
        }
        // List Chrome's helpers while they're still its children (they're reparented once it exits).
        let helpers = process.map { Self.childProcesses(of: $0.processIdentifier) } ?? []
        let adoptedPort = process == nil ? socket?.url.port : nil
        if let socket, await socket.isOpen {
            _ = try? await socket.send("Browser.close", timeout: 3)
        }
        await socket?.close()
        resetConnectionState()
        if let p = process {
            await terminate(p, helpers: helpers)
        } else if let port = adoptedPort, port > 0 {
            // A Chrome Glide didn't launch has no process handle: wait until its port stops
            // answering, so an immediate reconnect doesn't adopt a browser that's on its way out.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline, await Self.fetchVersion(port: port, timeout: 0.3) != nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        process = nil
    }

    private func establish() async throws {
        await socket?.close()
        resetConnectionState()
        let fm = FileManager.default
        let profile = configuration.userDataDirectory
        do {
            try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        } catch {
            throw BrowserError.notConnected("Glide couldn't create its Chrome profile folder: \(error.localizedDescription)")
        }
        let portFile = profile.appendingPathComponent("DevToolsActivePort")
        if let endpoint = await liveEndpoint(portFile: portFile) {
            try await attach(endpoint)
            return
        }
        if let p = process, p.isRunning { await terminate(p) }
        process = nil
        try? fm.removeItem(at: portFile)
        let endpoint = try await launch(portFile: portFile)
        do {
            try await attach(endpoint)
        } catch {
            if let p = process { await terminate(p) }
            process = nil
            throw error
        }
    }

    /// The endpoint of a Chrome already running on this profile, if the port file is current:
    /// its browser id must match what the port answers, so a stale file pointing at a port
    /// something else now uses is never trusted.
    private func liveEndpoint(portFile: URL) async -> Endpoint? {
        guard let (port, path) = Self.readActivePort(portFile) else { return nil }
        guard let info = await Self.fetchVersion(port: port, timeout: 1.5),
              let ws = info["webSocketDebuggerUrl"]?.stringValue, let wsURL = URL(string: ws), wsURL.path == path else { return nil }
        return Endpoint(port: port, path: path)
    }

    private func launch(portFile: URL) async throws -> Endpoint {
        guard let executable = ChromeLocator.executable(override: configuration.chromePath) else { throw BrowserError.chromeNotInstalled }
        let profile = configuration.userDataDirectory
        var args = [
            "--remote-debugging-port=0", "--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
            // Background tabs must keep running timers and rendering while Glide works in them.
            "--disable-background-timer-throttling", "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
        ]
        if configuration.headless { args.append("--headless=new") }
        if configuration.useMockKeychain { args.append("--use-mock-keychain") }
        args += configuration.extraArguments
        args.append("about:blank")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        // Chrome's stderr goes to a small log in the profile (truncated each launch) so a failed
        // start can be explained; an undrained pipe could block Chrome.
        let logURL = profile.appendingPathComponent("glide-launch.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        p.standardError = log ?? FileHandle.nullDevice
        p.terminationHandler = { [weak self] finished in
            let pid = finished.processIdentifier
            Task { await self?.processDidExit(pid: pid) }
        }
        do {
            try p.run()
        } catch {
            try? log?.close()
            throw BrowserError.notConnected("Glide couldn't start Chrome: \(error.localizedDescription)")
        }
        try? log?.close()
        process = p

        let deadline = Date().addingTimeInterval(configuration.launchTimeout)
        while Date() < deadline {
            if Task.isCancelled {
                await terminate(p)
                throw CancellationError()
            }
            if let (port, path) = Self.readActivePort(portFile) { return Endpoint(port: port, path: path) }
            if !p.isRunning {
                let status = p.terminationStatus
                let tail = Self.logTail(logURL)
                if status == 0 {
                    throw BrowserError.notConnected("Chrome handed off to another Chrome window that's already using Glide's profile. Quit that window and try again.")
                }
                throw BrowserError.notConnected("Chrome quit while starting (exit status \(status)).\(tail.isEmpty ? "" : " " + tail)")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await terminate(p)
        throw BrowserError.timeout("Chrome didn't open its debugging port within \(Int(configuration.launchTimeout)) s.")
    }

    private func attach(_ endpoint: Endpoint) async throws {
        // Prefer the browser endpoint Chrome advertises, but only ever connect to loopback.
        var path = endpoint.path
        if let info = await Self.fetchVersion(port: endpoint.port, timeout: 2),
           let ws = info["webSocketDebuggerUrl"]?.stringValue, let u = URL(string: ws), u.path.hasPrefix("/devtools/browser/") {
            path = u.path
        }
        guard let url = Endpoint(port: endpoint.port, path: path).webSocketURL else {
            throw BrowserError.notConnected("Chrome reported an invalid debugging address.")
        }
        let s = CDPWebSocket(url: url)
        try await s.open(timeout: 10)
        let stream = await s.events()
        generation += 1
        let gen = generation
        socket = s
        eventTask = Task { [weak self] in
            for await event in stream { await self?.handle(event) }
            await self?.streamEnded(generation: gen)
        }
        do {
            let v = try await s.send("Browser.getVersion", timeout: 10)
            version = v["product"]?.stringValue
            _ = try? await s.send("Target.setDiscoverTargets", params: ["discover": true], timeout: 10)
            if let targets = try? await s.send("Target.getTargets", timeout: 10) {
                activeTabID = Self.pageInfos(targets).first?["targetId"]?.stringValue
            }
        } catch {
            await s.close()
            resetConnectionState()
            throw error
        }
    }

    // MARK: Tabs

    public func tabs() async throws -> [BrowserTab] {
        let r = try await browserCommand("Target.getTargets")
        let infos = Self.pageInfos(r)
        let ids = Set(infos.compactMap { $0["targetId"]?.stringValue })
        owned.formIntersection(ids)
        if let a = activeTabID, !ids.contains(a) { activeTabID = nil }
        return infos.compactMap { info in
            guard let id = info["targetId"]?.stringValue else { return nil }
            return BrowserTab(id: id, url: info["url"]?.stringValue ?? "", title: info["title"]?.stringValue ?? "",
                              active: id == activeTabID, ownedByGlide: owned.contains(id))
        }
    }

    /// Opens a tab on about:blank, attaches to it (so network tracking sees the very first
    /// request), then navigates. A tab whose page fails to load is closed again.
    public func openTab(url: String, background: Bool) async throws -> BrowserTab {
        let created = try await browserCommand("Target.createTarget", ["url": "about:blank", "background": .bool(background), "newWindow": false])
        guard let id = created["targetId"]?.stringValue else { throw BrowserError.cdp("Chrome didn't open a tab.") }
        owned.insert(id)
        if !background { activeTabID = id }
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await ensureSession(id)
            if !target.isEmpty, target != "about:blank" { try await navigate(tabID: id, url: target) }
        } catch {
            _ = try? await browserCommand("Target.closeTarget", ["targetId": .string(id)])
            forget(tabID: id)
            throw error
        }
        return BrowserTab(id: id, url: target.isEmpty ? "about:blank" : target, title: "", active: !background, ownedByGlide: true)
    }

    public func navigate(tabID: String, url: String) async throws {
        let r = try await cdp(tabID: tabID, method: "Page.navigate", params: ["url": .string(url)])
        if let error = r["errorText"]?.stringValue, !error.isEmpty {
            throw BrowserError.cdp("Couldn't open \(url) (\(error)).")
        }
    }

    /// Closes the tab and returns once Chrome no longer lists it (`Target.closeTarget` answers
    /// before the tab is actually gone, and callers usually list the tabs right after).
    public func closeTab(_ tabID: String) async throws {
        do {
            _ = try await browserCommand("Target.closeTarget", ["targetId": .string(tabID)])
        } catch BrowserError.cdp(let message) where message.localizedCaseInsensitiveContains("no target") {
            forget(tabID: tabID)
            throw BrowserError.tabNotFound(tabID)
        }
        forget(tabID: tabID)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            guard let r = try? await browserCommand("Target.getTargets"),
                  Self.pageInfos(r).contains(where: { $0["targetId"]?.stringValue == tabID }) else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    public func activateTab(_ tabID: String) async throws {
        do {
            _ = try await browserCommand("Target.activateTarget", ["targetId": .string(tabID)])
        } catch BrowserError.cdp(let message) where message.localizedCaseInsensitiveContains("no target") {
            forget(tabID: tabID)
            throw BrowserError.tabNotFound(tabID)
        }
        activeTabID = tabID
    }

    public func cdp(tabID: String, method: String, params: JSONValue?) async throws -> JSONValue {
        let s = try requireSocket()
        var session = try await ensureSession(tabID)
        var retried = false
        while true {
            do {
                return try await s.send(method, params: params, sessionID: session, timeout: configuration.commandTimeout)
            } catch let e as CDPError {
                if e.isSessionGone, !retried {
                    // The debugger detached (e.g. the tab crashed and reloaded): attach again once.
                    retried = true
                    dropSession(tabID: tabID)
                    session = try await ensureSession(tabID)
                    continue
                }
                if e.isTargetGone || e.isSessionGone {
                    forget(tabID: tabID)
                    throw BrowserError.tabNotFound(tabID)
                }
                throw BrowserError.cdp(e.message)
            }
        }
    }

    // MARK: Page observation

    public func networkActivity(tabID: String) async -> BrowserNetworkActivity? {
        guard let session = sessions[tabID], let state = network[session] else { return nil }
        // Requests open for more than 8 s (long polls, streams) don't hold up "loaded".
        let now = Date()
        let active = state.inflight.values.filter { now.timeIntervalSince($0) < 8 }.count
        return BrowserNetworkActivity(inflight: active, lastChange: state.lastChange)
    }

    public func takeHandledDialogs(tabID: String) async -> [BrowserDialog] {
        dialogs.removeValue(forKey: tabID) ?? []
    }

    public func statusDetail() async -> String {
        if await isConnected() {
            let count = (try? await tabs().count) ?? 0
            let product = version.map(Self.displayVersion) ?? "Chrome"
            return "Glide's Chrome is running (\(product), \(count) tab\(count == 1 ? "" : "s"))."
        }
        if ChromeLocator.executable(override: configuration.chromePath) == nil { return "Google Chrome isn't installed." }
        return "Glide's Chrome window opens when a task needs it."
    }

    // MARK: - Internals

    private func requireSocket() throws -> CDPWebSocket {
        guard let socket else { throw BrowserError.notConnected("Glide's Chrome isn't running.") }
        return socket
    }

    private func browserCommand(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        let s = try requireSocket()
        do {
            return try await s.send(method, params: params, timeout: configuration.commandTimeout)
        } catch let e as CDPError {
            throw BrowserError.cdp(e.message)
        }
    }

    /// Attaches to a tab once (concurrent callers share the attempt) and enables the domains
    /// the driver relies on: Page (dialogs), Network (idle detection), and focus emulation so
    /// focus and typing behave in background tabs as in the front one.
    private func ensureSession(_ tabID: String) async throws -> String {
        if let s = sessions[tabID] { return s }
        if let pending = attaching[tabID] { return try await pending.value }
        let s = try requireSocket()
        let timeout = configuration.commandTimeout
        let attempt = Task { () throws -> String in
            let r: JSONValue
            do {
                r = try await s.send("Target.attachToTarget", params: ["targetId": .string(tabID), "flatten": true], timeout: timeout)
            } catch let e as CDPError {
                if e.isTargetGone || e.code == -32602 { throw BrowserError.tabNotFound(tabID) }
                throw BrowserError.cdp(e.message)
            }
            guard let session = r["sessionId"]?.stringValue else { throw BrowserError.cdp("Chrome didn't attach to the tab.") }
            _ = try? await s.send("Page.enable", sessionID: session, timeout: 10)
            _ = try? await s.send("Network.enable", sessionID: session, timeout: 10)
            _ = try? await s.send("Emulation.setFocusEmulationEnabled", params: ["enabled": true], sessionID: session, timeout: 10)
            return session
        }
        attaching[tabID] = attempt
        defer { if attaching[tabID] == attempt { attaching[tabID] = nil } }
        let session = try await attempt.value
        sessions[tabID] = session
        sessionTabs[session] = tabID
        if network[session] == nil { network[session] = NetworkState() }
        return session
    }

    private func dropSession(tabID: String) {
        if let s = sessions.removeValue(forKey: tabID) {
            sessionTabs[s] = nil
            network[s] = nil
        }
    }

    private func forget(tabID: String) {
        dropSession(tabID: tabID)
        owned.remove(tabID)
        dialogs[tabID] = nil
        if activeTabID == tabID { activeTabID = nil }
    }

    private func resetConnectionState() {
        eventTask?.cancel()
        eventTask = nil
        socket = nil
        sessions.removeAll()
        sessionTabs.removeAll()
        attaching.removeAll()
        network.removeAll()
        dialogs.removeAll()
    }

    private func streamEnded(generation gen: Int) {
        guard gen == generation else { return }
        resetConnectionState()
    }

    private func processDidExit(pid: Int32) async {
        guard let p = process, p.processIdentifier == pid else { return }
        process = nil
        await socket?.close()
        resetConnectionState()
    }

    private func handle(_ event: CDPEvent) {
        let p = event.params
        switch event.method {
        case "Target.detachedFromTarget":
            if let session = p["sessionId"]?.stringValue, let tab = sessionTabs[session] { dropSession(tabID: tab) }
        case "Target.targetDestroyed":
            if let tab = p["targetId"]?.stringValue { forget(tabID: tab) }
        case "Target.targetCrashed":
            if let tab = p["targetId"]?.stringValue { dropSession(tabID: tab) }
        case "Network.requestWillBeSent":
            guard let session = event.sessionID, let id = p["requestId"]?.stringValue else { return }
            // Streams never finish; they'd keep the page "loading" forever.
            let type = p["type"]?.stringValue ?? ""
            guard type != "EventSource", type != "WebSocket" else { return }
            var state = network[session] ?? NetworkState()
            if state.inflight[id] == nil { state.inflight[id] = Date() }
            state.lastChange = Date()
            if state.inflight.count > 500 {
                let cutoff = Date().addingTimeInterval(-60)
                state.inflight = state.inflight.filter { $0.value > cutoff }
            }
            network[session] = state
        case "Network.loadingFinished", "Network.loadingFailed":
            guard let session = event.sessionID, let id = p["requestId"]?.stringValue, var state = network[session] else { return }
            if state.inflight.removeValue(forKey: id) != nil { state.lastChange = Date() }
            network[session] = state
        case "Page.javascriptDialogOpening":
            guard let session = event.sessionID, let s = socket else { return }
            let type = p["type"]?.stringValue ?? "alert"
            // Deterministic and safe: confirmations and prompts are declined, so a page can't
            // get a "yes" to "Delete everything?" behind the user's back. Alerts are just closed,
            // and leaving a page Glide is navigating away from is allowed.
            let accept = type == "alert" || type == "beforeunload"
            if let tab = sessionTabs[session] {
                var list = dialogs[tab] ?? []
                if list.count < 20 { list.append(BrowserDialog(type: type, message: p["message"]?.stringValue ?? "", accepted: accept)) }
                dialogs[tab] = list
            }
            Task { _ = try? await s.send("Page.handleJavaScriptDialog", params: ["accept": .bool(accept)], sessionID: session, timeout: 10) }
        default:
            break
        }
    }

    /// Stops Chrome: SIGTERM, then SIGKILL after 3 s. Then waits for its helper processes
    /// (renderers, GPU, network, crash handler), which exit on their own once the browser is
    /// gone but can still be writing to the profile for a moment; stragglers are killed.
    private func terminate(_ p: Process, helpers known: [pid_t]? = nil) async {
        let helpers = known ?? Self.childProcesses(of: p.processIdentifier)
        if p.isRunning {
            p.terminate()
            if !(await waitForExit(p, timeout: 3)) {
                kill(p.processIdentifier, SIGKILL)
                _ = await waitForExit(p, timeout: 2)
            }
        }
        guard !helpers.isEmpty, let executable = p.executableURL?.path else { return }
        let bundle = Self.bundlePrefix(of: executable)
        var remaining = helpers.filter { Self.isProcess($0, under: bundle) }
        let deadline = Date().addingTimeInterval(3)
        while !remaining.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            remaining = remaining.filter { Self.isProcess($0, under: bundle) }
        }
        for pid in remaining { kill(pid, SIGKILL) }
    }

    /// Direct child processes of `pid`.
    static func childProcesses(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: 1024)
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
    }

    /// The app bundle (or folder) Chrome's executable lives in; its helpers live inside it.
    static func bundlePrefix(of executable: String) -> String {
        if let r = executable.range(of: ".app/") { return String(executable[..<r.upperBound]) }
        return (executable as NSString).deletingLastPathComponent + "/"
    }

    /// True while `pid` is alive and runs a binary inside `bundle`, so a recycled pid that now
    /// belongs to something else is never signalled.
    static func isProcess(_ pid: pid_t, under bundle: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.hasPrefix(bundle)
    }

    private func waitForExit(_ p: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return !p.isRunning
    }

    // MARK: Helpers

    static func pageInfos(_ getTargetsResult: JSONValue) -> [JSONValue] {
        (getTargetsResult["targetInfos"]?.arrayValue ?? []).filter { $0["type"]?.stringValue == "page" }
    }

    /// Parses Chrome's `DevToolsActivePort` file: the port on line one, the browser path on two.
    static func readActivePort(_ url: URL) -> (Int, String)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let port = Int(lines[0]), (1...65535).contains(port), lines[1].hasPrefix("/devtools/browser/") else { return nil }
        return (port, lines[1])
    }

    private static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    static func fetchVersion(port: Int, timeout: TimeInterval) async -> JSONValue? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await http.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONValue.parse(data)
    }

    static func logTail(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let text = String(decoding: data.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : "Chrome said: \(text)"
    }

    /// "HeadlessChrome/141.0.7390.54" → "Chrome 141".
    static func displayVersion(_ product: String) -> String {
        let parts = product.split(separator: "/")
        guard parts.count == 2, let major = parts[1].split(separator: ".").first else { return product }
        return "Chrome \(major)"
    }
}
