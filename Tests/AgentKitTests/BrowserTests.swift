import Testing
import Foundation
import Network
@testable import AgentKit
@testable import AutomationKit

// Browser driver tests. The CDP client runs against a fake WebSocket server; the driver, Glide's
// Chrome backend and the browser tools run against real headless Chrome with a temporary profile
// and a local fixture site (skipped when Chrome isn't installed). Nothing leaves the Mac.

// MARK: - Local servers

/// Starts a loopback-only NWListener and waits until it has a port.
private func startLoopbackListener(_ params: NWParameters, _ onConnection: @escaping @Sendable (NWConnection) -> Void) async throws -> (NWListener, UInt16) {
    params.requiredInterfaceType = .loopback
    let listener = try NWListener(using: params, on: .any)
    listener.newConnectionHandler = onConnection
    let port: UInt16 = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
        let once = OnceFlag()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: if once.take() { c.resume(returning: listener.port?.rawValue ?? 0) }
            case .failed(let e): if once.take() { c.resume(throwing: e) }
            default: break
            }
        }
        listener.start(queue: .global())
    }
    return (listener, port)
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// A tiny HTTP/1.1 server for fixture pages (GET only, one request per connection).
final class FixtureServer: Sendable {
    let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }
    func stop() { listener.cancel() }

    static func start(_ route: @escaping @Sendable (_ path: String, _ query: [String: String]) -> (Int, String)) async throws -> FixtureServer {
        let (listener, port) = try await startLoopbackListener(.tcp) { conn in
            conn.start(queue: .global())
            receive(conn, Data(), route)
        }
        return FixtureServer(listener: listener, port: port)
    }

    private static func receive(_ conn: NWConnection, _ buffer: Data, _ route: @escaping @Sendable (String, [String: String]) -> (Int, String)) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let comps = URLComponents(string: target)
                var query: [String: String] = [:]
                for item in comps?.queryItems ?? [] { query[item.name] = (item.value ?? "").replacingOccurrences(of: "+", with: " ") }
                let (status, body) = route(comps?.path ?? "/", query)
                let bytes = Data(body.utf8)
                let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            if done || error != nil { conn.cancel(); return }
            receive(conn, buf, route)
        }
    }
}

/// A fake CDP endpoint: answers `Echo`, `Fail`, `Delay`, `Emit`, ignores `Never`, drops the
/// connection on `Close`.
final class FakeCDPServer: Sendable {
    let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(port)/devtools/browser/test")! }
    func stop() { listener.cancel() }

    static func start() async throws -> FakeCDPServer {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let (listener, port) = try await startLoopbackListener(params) { conn in
            conn.start(queue: .global())
            receive(conn)
        }
        return FakeCDPServer(listener: listener, port: port)
    }

    private static func send(_ conn: NWConnection, _ value: JSONValue) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "cdp", metadata: [meta])
        conn.send(content: value.data(), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private static func receive(_ conn: NWConnection) {
        conn.receiveMessage { data, _, _, error in
            guard error == nil, let data, let msg = try? JSONValue.parse(data), let id = msg["id"] else {
                if error != nil { conn.cancel() } else { receive(conn) }
                return
            }
            let params = msg["params"] ?? .object([:])
            switch msg["method"]?.stringValue ?? "" {
            case "Echo":
                send(conn, ["id": id, "result": params])
            case "Fail":
                send(conn, ["id": id, "error": ["code": -32000, "message": "nope"]])
            case "Delay":
                let ms = params["ms"]?.intValue ?? 100
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(ms)) { send(conn, ["id": id, "result": ["waited": .number(Double(ms))]]) }
            case "Emit":
                send(conn, ["method": "Test.event", "params": ["n": 1], "sessionId": "S1"])
                send(conn, ["id": id, "result": [:]])
            case "Close":
                conn.cancel()
                return
            default:
                break // "Never": no reply
            }
            receive(conn)
        }
    }
}

// MARK: - Fixture site

enum Fixtures {
    static let home = """
    <!doctype html><html><head><title>Glide Fixture</title>
    <style>body{font-family:sans-serif} .wrap{position:relative;display:inline-block} .cover{position:absolute;left:0;top:0;right:0;bottom:0}</style></head>
    <body><main>
    <h1>Fixture Home</h1>
    <p id="status">Status: idle</p>
    <button id="go" onclick="document.getElementById('status').textContent='Status: clicked'">Press me</button>
    <button disabled>Disabled one</button>
    <button id="del" onclick="document.getElementById('status').textContent='Status: deleted'">Delete account</button>
    <a href="/second">Second page</a>
    <a href="/popup" target="_blank">Open popup</a>
    <form action="/result" method="get" aria-label="Search">
      <label for="q">Query</label> <input id="q" name="q" type="text" value="old">
      <label>Password <input type="password" name="pw" value="hunter2"></label>
      <button type="submit">Search</button>
    </form>
    <form aria-label="Payment" action="/checkout/pay" onsubmit="return false"><button type="submit">Continue</button></form>
    <label><input type="checkbox" id="agree"> I agree</label>
    <select id="color" aria-label="Color" onchange="document.getElementById('status').textContent='Color: '+this.value">
      <option value="r">Red</option><option value="g">Green</option><option value="b">Blue</option></select>
    <div role="button" tabindex="0" onclick="this.textContent='Fancy done'">Fancy button</div>
    <button id="ask" onclick="document.getElementById('status').textContent = confirm('Delete everything?') ? 'Status: confirmed' : 'Status: declined'">Ask</button>
    <button id="later" onclick="setTimeout(function(){document.getElementById('status').textContent='Status: later'}, 600)">Later</button>
    <div id="host"></div>
    <iframe id="frame" src="/frame" style="width:320px;height:90px"></iframe>
    <div class="wrap"><button id="covered" onclick="document.getElementById('status').textContent='Status: covered clicked'">Covered</button><div class="cover"></div></div>
    <div style="height:2500px"></div>
    <button id="far" onclick="document.getElementById('status').textContent='Status: far clicked'">Far below</button>
    <p>Readable closing paragraph for the reader.</p>
    </main>
    <script>
      const root = document.getElementById('host').attachShadow({ mode: 'open' });
      root.innerHTML = '<button onclick="this.textContent=\\'Shadow clicked\\'">Shadow button</button>';
    </script>
    </body></html>
    """

    static func route(_ path: String, _ query: [String: String]) -> (Int, String) {
        switch path {
        case "/": return (200, home)
        case "/second": return (200, "<!doctype html><title>Second</title><h1>Second page</h1><a href=\"/\">Home</a>")
        case "/popup": return (200, "<!doctype html><title>Popup</title><h1>Popup page</h1>")
        case "/frame": return (200, "<!doctype html><body><button onclick=\"this.textContent='Frame clicked'\">Frame button</button></body>")
        case "/result":
            let q = (query["q"] ?? "").replacingOccurrences(of: "<", with: "&lt;")
            return (200, "<!doctype html><title>Results</title><h1>Results for <span id=\"q\">\(q)</span></h1>")
        default: return (404, "<!doctype html><title>Not found</title>Not found")
        }
    }
}

/// Launches headless Glide Chrome on a throwaway profile, serves the fixture site, runs `body`,
/// and always quits Chrome and removes the profile afterwards.
enum ChromeHarness {
    static var installed: Bool { ChromeLocator.executable() != nil }

    static func run(_ body: (GlideChromeBackend, BrowserDriver, FixtureServer) async throws -> Void) async throws {
        let server = try await FixtureServer.start(Fixtures.route)
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("glide-chrome-test-\(UUID().uuidString)", isDirectory: true)
        let backend = GlideChromeBackend(configuration: .init(userDataDirectory: profile, headless: true, extraArguments: GlideChromeBackend.quietArguments))
        func cleanUp() async {
            await backend.shutdown()
            server.stop()
            // Chrome can still be finishing writes to the profile right after it quits; keep
            // removing until the folder has stayed gone for a few checks in a row.
            var goneChecks = 0
            for _ in 0..<40 where goneChecks < 4 {
                try? FileManager.default.removeItem(at: profile)
                goneChecks = FileManager.default.fileExists(atPath: profile.path) ? 0 : goneChecks + 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        do {
            try await backend.connect()
            try await body(backend, BrowserDriver(backend: backend), server)
        } catch {
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    /// Opens the fixture home page in a background tab and snapshots it.
    static func openHome(_ driver: BrowserDriver, _ server: FixtureServer, path: String = "/") async throws -> (String, PageSnapshot) {
        let tab = try await driver.openTab(url: server.url(path), background: true)
        let snap = try await driver.snapshot(tabID: tab.id)
        return (tab.id, snap)
    }
}

extension PageSnapshot {
    func named(_ name: String) -> Element? { elements.first { $0.name == name } }
}

// MARK: - CDP client

@Suite("CDPWebSocket")
struct CDPWebSocketTests {
    @Test func matchesRepliesByIDUnderConcurrency() async throws {
        let server = try await FakeCDPServer.start()
        defer { server.stop() }
        let socket = CDPWebSocket(url: server.url)
        try await socket.open(timeout: 5)
        async let slow = socket.send("Delay", params: ["ms": 300])
        async let fast = socket.send("Echo", params: ["x": "hi"])
        let (s, f) = try await (slow, fast)
        #expect(f["x"]?.stringValue == "hi")
        #expect(s["waited"]?.intValue == 300)
        await socket.close()
    }

    @Test func surfacesErrorsAndTimeouts() async throws {
        let server = try await FakeCDPServer.start()
        defer { server.stop() }
        let socket = CDPWebSocket(url: server.url)
        try await socket.open(timeout: 5)
        await #expect(throws: CDPError.self) { _ = try await socket.send("Fail") }
        let started = Date()
        do {
            _ = try await socket.send("Never", timeout: 0.3)
            Issue.record("expected a timeout")
        } catch let e as BrowserError {
            guard case .timeout = e else { Issue.record("expected timeout, got \(e)"); return }
        }
        #expect(Date().timeIntervalSince(started) < 3)
        // The connection still works after a timeout.
        #expect(try await socket.send("Echo", params: ["ok": true])["ok"]?.boolValue == true)
        await socket.close()
    }

    @Test func deliversEventsWithSessionIDs() async throws {
        let server = try await FakeCDPServer.start()
        defer { server.stop() }
        let socket = CDPWebSocket(url: server.url)
        try await socket.open(timeout: 5)
        let events = await socket.events()
        _ = try await socket.send("Emit")
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.method == "Test.event")
        #expect(event?.sessionID == "S1")
        #expect(event?.params["n"]?.intValue == 1)
        await socket.close()
        let end = await iterator.next()
        #expect(end == nil)
    }

    @Test func droppedConnectionFailsPendingCalls() async throws {
        let server = try await FakeCDPServer.start()
        defer { server.stop() }
        let socket = CDPWebSocket(url: server.url)
        try await socket.open(timeout: 5)
        let pending = Task { try await socket.send("Never", timeout: 20) }
        try await Task.sleep(for: .milliseconds(100))
        _ = try? await socket.send("Close", timeout: 2)
        let started = Date()
        await #expect(throws: BrowserError.self) { _ = try await pending.value }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await socket.isOpen == false)
        await #expect(throws: BrowserError.self) { _ = try await socket.send("Echo") }
    }

    @Test func cancellationStopsAWaitingCall() async throws {
        let server = try await FakeCDPServer.start()
        defer { server.stop() }
        let socket = CDPWebSocket(url: server.url)
        try await socket.open(timeout: 5)
        let task = Task { try await socket.send("Never", timeout: 30) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let started = Date()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 2)
        await socket.close()
    }

    @Test func refusedConnectionsThrowNotConnected() async throws {
        // Nothing listens on this port (bind, read the port, close).
        let server = try await FakeCDPServer.start()
        let dead = server.url
        server.stop()
        try await Task.sleep(for: .milliseconds(50))
        let socket = CDPWebSocket(url: dead)
        await #expect(throws: BrowserError.self) { try await socket.open(timeout: 3) }
    }
}

// MARK: - Pure logic

@Suite("Browser keys, URLs and snapshots")
struct BrowserLogicTests {
    @Test func parsesKeyCombos() throws {
        let enter = try BrowserKeys.parse("Enter")
        #expect(enter.count == 1)
        #expect(enter[0].keyCode == 13 && enter[0].text == "\r")
        let ctrlA = try BrowserKeys.parseCombo("Control+A")
        #expect(ctrlA.modifiers == 2 && ctrlA.key == "a" && ctrlA.text == nil)
        let metaA = try BrowserKeys.parseCombo("Meta+a")
        #expect(metaA.commands == ["selectAll"])
        let redo = try BrowserKeys.parseCombo("Meta+Shift+Z")
        #expect(redo.commands == ["redo"] && redo.modifiers == 12)
        let shiftTab = try BrowserKeys.parseCombo("Shift+Tab")
        #expect(shiftTab.key == "Tab" && shiftTab.modifiers == 8)
        #expect(try BrowserKeys.parseCombo("F5").keyCode == 116)
        #expect(try BrowserKeys.parse("Tab Tab Enter").count == 3)
        #expect(try BrowserKeys.parseCombo("Control++").key == "+")
        #expect(throws: BrowserActionError.self) { try BrowserKeys.parse("Hyper+X") }
        #expect(throws: BrowserActionError.self) { try BrowserKeys.parse("Florp") }
        #expect(throws: BrowserActionError.self) { try BrowserKeys.parse("   ") }
        // Modifiers wrap the key: down in order, up in reverse.
        let events = ctrlA.events()
        #expect(events.first?["key"]?.stringValue == "Control")
        #expect(events.last?["key"]?.stringValue == "Control")
        #expect(events.last?["type"]?.stringValue == "keyUp")
        #expect(enter[0].events().map { $0["type"]?.stringValue ?? "" } == ["rawKeyDown", "char", "keyUp"])
    }

    @Test func normalizesAndRestrictsURLs() throws {
        #expect(BrowserDriver.normalizeURL("example.com/a") == "https://example.com/a")
        #expect(BrowserDriver.normalizeURL("localhost:3000") == "http://localhost:3000")
        #expect(BrowserDriver.normalizeURL("127.0.0.1:8080/x") == "http://127.0.0.1:8080/x")
        #expect(BrowserDriver.normalizeURL("https://example.com/a b") == "https://example.com/a%20b")
        #expect(BrowserDriver.normalizeURL("about:blank") == "about:blank")
        #expect(BrowserDriver.normalizeURL("not a url") == nil)
        #expect(BrowserDriver.normalizeURL("") == nil)
        #expect(BrowserDriver.scheme(of: "example.com:8080/x") == nil)
        #expect(BrowserDriver.scheme(of: "mailto:a@b.c") == "mailto")
        #expect(BrowserDriver.isRestricted(url: "chrome://settings"))
        #expect(BrowserDriver.isRestricted(url: "chrome-extension://abc/popup.html"))
        #expect(BrowserDriver.isRestricted(url: "https://chromewebstore.google.com/detail/x"))
        #expect(BrowserDriver.isRestricted(url: "https://chrome.google.com/webstore/category"))
        #expect(!BrowserDriver.isRestricted(url: "https://chrome.google.com/other"))
        #expect(!BrowserDriver.isRestricted(url: "https://example.com"))
        #expect(throws: BrowserError.self) { try BrowserDriver.checkedURL("chrome://flags") }
        #expect(throws: BrowserActionError.self) { try BrowserDriver.checkedURL("mailto:a@b.c") }
        #expect(throws: BrowserActionError.self) { try BrowserDriver.checkedURL("nonsense") }
        #expect(try BrowserDriver.checkedURL("example.com") == "https://example.com")
    }

    static func sample() -> PageSnapshot {
        PageSnapshot(tabID: "T1", url: "https://shop.example.com/cart", title: "Your cart", viewportWidth: 1200, viewportHeight: 800,
                     scrollY: 0, pageHeight: 2400, elements: [
                        .init(ref: "b1", role: "link", name: "Home", href: "https://shop.example.com/"),
                        .init(ref: "b2", role: "textbox", name: "Email", value: "a@b.c", inputType: "email", focused: true),
                        .init(ref: "b3", role: "textbox", name: "Password", inputType: "password", secure: true),
                        .init(ref: "b4", role: "button", name: "Place order", disabled: true, context: "form Payment → /checkout/pay"),
                        .init(ref: "b5", role: "checkbox", name: "Gift wrap", checked: false),
                        .init(ref: "b6", role: "button", name: "Below the fold", inViewport: false),
                     ], headings: [.init(level: 1, text: "Your cart")], text: "Cart total: $42")
    }

    @Test func compactRendersLikeTheAXSkeleton() {
        let text = Self.sample().compact()
        #expect(text.contains("page: \"Your cart\" https://shop.example.com/cart"))
        #expect(text.contains("b1 link \"Home\" → /"))
        #expect(text.contains("b2 textbox \"Email\" value=\"a@b.c\" type=email [focused]"))
        #expect(text.contains("b3 textbox \"Password\" [secure]"))
        #expect(text.contains("b4 button \"Place order\" [disabled] in \"form Payment → /checkout/pay\""))
        #expect(text.contains("b5 checkbox \"Gift wrap\" [unchecked]"))
        #expect(text.contains("outside the viewport"))
        #expect(text.contains("Cart total: $42"))
        #expect(text.contains("scrolled 0 of 1600 (top)"))
        // A tight budget still lists elements and stays near the budget.
        let tight = Self.sample().compact(maxChars: 700)
        #expect(tight.contains("b1 link"))
        #expect(tight.count < 1400)
    }

    @Test func summarizesChanges() {
        let old = Self.sample()
        var same = old
        #expect(same.changeSummary(since: old) == "No visible change on the page.")
        same.elements[1].value = "x@y.z"
        same.elements.append(.init(ref: "b7", role: "button", name: "New"))
        let s = same.changeSummary(since: old)
        #expect(s.contains("1 new element") && s.contains("1 element changed"))
        var moved = old
        moved.url = "https://shop.example.com/done"
        moved.title = "Done"
        #expect(moved.changeSummary(since: old).hasPrefix("Now on “Done”"))
        #expect(old.changeSummary(since: nil) == "")
    }
}

// MARK: - Risk

@Suite("Browser tool risk")
struct BrowserRiskTests {
    let page = BrowserLogicTests.sample()

    @Test func openRisk() {
        #expect(BrowserRisk.open("https://example.com").risk == .low)
        #expect(BrowserRisk.open("file:///etc/hosts").risk == .high)
        #expect(BrowserRisk.open("javascript:alert(1)").risk == .high)
        #expect(BrowserRisk.open("chrome://settings").blocked != nil)
        #expect(BrowserRisk.open("mailto:a@b.c").blocked != nil)
    }

    @Test func clickRiskFollowsElementAndPage() {
        func click(_ name: String, context: String? = nil, url: String = "https://example.com/", role: String = "button", type: String? = nil) -> ToolVerdict {
            let e = PageSnapshot.Element(ref: "b1", role: role, name: name, inputType: type, context: context)
            return BrowserRisk.click(ref: "b1", element: e, label: nil, page: PageSnapshot(tabID: "t", url: url, title: "Page", elements: [e]))
        }
        for name in ["Send", "Delete", "Buy now", "Place order", "Publish", "Post"] { #expect(click(name).risk == .high, "\(name)") }
        #expect(click("Learn more", role: "link").risk == .low)
        #expect(click("Save").risk == .medium)
        #expect(click("Continue", context: "form Payment → /checkout/pay").risk == .high)
        #expect(click("Continue", url: "https://shop.example.com/checkout").risk == .high)
        #expect(click("Continue", url: "https://example.com/blog").risk == .low)
        // Without a snapshot the runner's _label decides; with neither it's medium.
        #expect(BrowserRisk.click(ref: "b9", element: nil, label: "Send now", page: nil).risk == .high)
        #expect(BrowserRisk.click(ref: "b9", element: nil, label: nil, page: nil).risk == .medium)
        // If the runner's label and the snapshot disagree, the riskier name wins.
        let cancel = PageSnapshot.Element(ref: "b1", role: "button", name: "Cancel")
        #expect(BrowserRisk.click(ref: "b1", element: cancel, label: "Send", page: nil).risk == .high)
        #expect(BrowserRisk.click(ref: "b1", element: cancel, label: "Cancel", page: nil).risk == .low)
    }

    @Test func typingRisk() {
        let pw = page.element("b3")
        #expect(BrowserRisk.type(ref: "b3", element: pw, label: nil, text: "x", submit: false, page: page).blocked != nil)
        #expect(BrowserRisk.type(ref: "b2", element: page.element("b2"), label: nil, text: "4242 4242 4242 4242", submit: false, page: page).blocked != nil)
        let card = PageSnapshot.Element(ref: "b8", role: "textbox", name: "Security code (CVV)")
        #expect(BrowserRisk.type(ref: "b8", element: card, label: nil, text: "123", submit: false, page: page).blocked != nil)
        let search = PageSnapshot.Element(ref: "b1", role: "searchbox", name: "Search")
        let plain = PageSnapshot(tabID: "t", url: "https://example.com/", title: "Example", elements: [search])
        #expect(BrowserRisk.type(ref: "b1", element: search, label: nil, text: "shoes", submit: false, page: plain).risk == .low)
        #expect(BrowserRisk.type(ref: "b1", element: search, label: nil, text: "shoes", submit: true, page: plain).risk == .medium)
        let chat = PageSnapshot(tabID: "t", url: "https://app.slack.com/client/T1", title: "Slack", elements: [search])
        #expect(BrowserRisk.type(ref: "b1", element: search, label: nil, text: "hi", submit: true, page: chat).risk == .high)
    }

    @Test func pressAndCloseRisk() {
        let plain = PageSnapshot(tabID: "t", url: "https://example.com/", title: "Example")
        #expect(BrowserRisk.press(keys: "Escape", page: plain).risk == .low)
        #expect(BrowserRisk.press(keys: "Enter", page: plain).risk == .medium)
        #expect(BrowserRisk.press(keys: "Meta+Enter", page: plain).risk == .high)
        #expect(BrowserRisk.press(keys: "Meta+Backspace", page: plain).risk == .high)
        #expect(BrowserRisk.press(keys: "Delete", page: plain).risk == .medium)
        #expect(BrowserRisk.press(keys: "Enter", page: PageSnapshot(tabID: "t", url: "https://web.whatsapp.com/", title: "WhatsApp")).risk == .high)
        #expect(BrowserRisk.closeTab(tabID: "1", isGlideTab: true).risk == .low)
        #expect(BrowserRisk.closeTab(tabID: "1", isGlideTab: false).risk == .high)
    }
}

// MARK: - Sessions and hub

@Suite("Browser sessions and hub")
struct BrowserSessionTests {
    @Test func keysSeparateItemsJobsAndQuickTasks() {
        #expect(BrowserSessions.key(jobID: "j", itemID: "i") == "job:j/item:i")
        #expect(BrowserSessions.key(jobID: "j", itemID: nil) == "job:j")
        #expect(BrowserSessions.key(jobID: nil, itemID: nil) == "default")
    }

    @Test func recyclesLeastRecentlyUsedGlideTabsPerJob() {
        let s = BrowserSessions(maxTabsPerJob: 2, maxTabs: 10)
        #expect(s.adopt(key: "job:j/item:1", backend: .glideChrome, tabID: "t1", jobID: "j", openedByGlide: true).isEmpty)
        #expect(s.adopt(key: "job:j/item:2", backend: .glideChrome, tabID: "t2", jobID: "j", openedByGlide: true).isEmpty)
        s.touch("job:j/item:1")
        let evicted = s.adopt(key: "job:j/item:3", backend: .glideChrome, tabID: "t3", jobID: "j", openedByGlide: true)
        #expect(evicted.map(\.tabID) == ["t2"])
        #expect(s.session("job:j/item:2") == nil)
        #expect(s.session("job:j/item:1")?.tabID == "t1")
        // The user's own tabs are never recycled.
        #expect(s.adopt(key: "job:j/item:4", backend: .glideChrome, tabID: "mine", jobID: "j", openedByGlide: false).isEmpty)
        #expect(!s.isGlideTab(backend: .glideChrome, tabID: "mine"))
        // Another job has its own budget.
        #expect(s.adopt(key: "job:k/item:1", backend: .glideChrome, tabID: "k1", jobID: "k", openedByGlide: true).isEmpty)
    }

    @Test func statusExplainsTheFallback() async {
        let hub = BrowserHub()
        var settings = BrowserSettings()
        settings.backend = .extensionBridge
        hub.register(GlideChromeBackend(configuration: .init(userDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString)"))))
        let status = await hub.status(settings: settings)
        #expect(!status.connected)
        if ChromeLocator.executable() != nil { #expect(status.detail.contains("Glide's own Chrome")) }
        settings.backend = .glideChrome
        let own = await hub.status(settings: settings)
        #expect(!own.connected)
        #expect(own.detail.contains("Chrome"))
    }
}

// MARK: - Headless Chrome

@Suite("Browser driver (headless Chrome)", .serialized, .enabled(if: ChromeHarness.installed, "Google Chrome isn't installed; skipping the live browser tests."))
struct BrowserDriverChromeTests {
    @Test func snapshotFindsInteractiveElementsWithStableRefs() async throws {
        try await ChromeHarness.run { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server)
            #expect(snap.title == "Glide Fixture")
            #expect(snap.elements.allSatisfy { $0.ref.hasPrefix("b") && Int($0.ref.dropFirst()) != nil })
            #expect(Set(snap.elements.map(\.ref)).count == snap.elements.count)
            let press = try #require(snap.named("Press me"))
            #expect(press.role == "button" && press.inViewport)
            #expect(snap.named("Disabled one")?.disabled == true)
            #expect(snap.named("Second page")?.role == "link")
            #expect(snap.named("Query")?.value == "old")
            let password = try #require(snap.elements.first { $0.secure })
            #expect(password.value == nil)
            #expect(snap.named("I agree")?.checked == false)
            let color = try #require(snap.named("Color"))
            #expect(color.role == "combobox" && color.options == ["Red", "Green", "Blue"] && color.value == "Red")
            #expect(snap.named("Fancy button")?.role == "button")
            #expect(snap.named("Shadow button") != nil, "open shadow roots are included")
            #expect(snap.named("Frame button") != nil, "same-origin frames are included")
            #expect(snap.named("Far below")?.inViewport == false)
            #expect(snap.named("Search")?.context?.contains("form Search") == true)
            #expect(snap.headings.contains { $0.text == "Fixture Home" && $0.level == 1 })
            #expect(snap.text.contains("Status: idle"))
            let compact = snap.compact()
            #expect(compact.contains("\(press.ref) button \"Press me\""))
            #expect(compact.contains("[secure]") && !compact.contains("hunter2"))
            // Taking another snapshot keeps every ref.
            let again = try await driver.snapshot(tabID: tab)
            #expect(again.named("Press me")?.ref == press.ref)
            #expect(again.named("Query")?.ref == snap.named("Query")?.ref)
        }
    }

    @Test func clicksUseRealEventsAndFallBackWhenCovered() async throws {
        try await ChromeHarness.run { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server)
            let outcome = try await driver.click(tabID: tab, ref: try #require(snap.named("Press me")).ref)
            #expect(outcome.settled)
            #expect(try await driver.snapshot(tabID: tab).text.contains("Status: clicked"))

            _ = try await driver.click(tabID: tab, ref: try #require(snap.named("Shadow button")).ref)
            _ = try await driver.click(tabID: tab, ref: try #require(snap.named("Frame button")).ref)
            _ = try await driver.click(tabID: tab, ref: try #require(snap.named("Fancy button")).ref)
            let after = try await driver.snapshot(tabID: tab)
            #expect(after.named("Shadow clicked") != nil)
            #expect(after.named("Frame clicked") != nil)
            #expect(after.named("Fancy done") != nil)

            let covered = try await driver.click(tabID: tab, ref: try #require(snap.named("Covered")).ref)
            #expect(covered.notes.contains { $0.contains("by script") })
            #expect(try await driver.readText(tabID: tab, selector: "#status").text == "Status: covered clicked")

            _ = try await driver.click(tabID: tab, ref: try #require(snap.named("Far below")).ref)
            #expect(try await driver.readText(tabID: tab, selector: "#status").text == "Status: far clicked")
        }
    }

    @Test func typesSubmitsAndSelects() async throws {
        try await ChromeHarness.run { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server)
            let query = try #require(snap.named("Query")).ref
            let typed = try await driver.type(tabID: tab, ref: query, text: "hello world")
            #expect(typed.value == "hello world", "clear defaults to replacing a form field's text")
            let appended = try await driver.type(tabID: tab, ref: query, text: "!", clear: false)
            #expect(appended.value == "hello world!")

            let color = try #require(snap.named("Color")).ref
            let chosen = try await driver.select(tabID: tab, ref: color, value: "green")
            #expect(chosen.value == "Green")
            #expect(try await driver.readText(tabID: tab, selector: "#status").text == "Color: g")
            await #expect(throws: BrowserActionError.self) { _ = try await driver.select(tabID: tab, ref: color, value: "Purple") }

            let password = try #require(snap.elements.first { $0.secure }).ref
            await #expect(throws: BrowserActionError.self) { _ = try await driver.type(tabID: tab, ref: password, text: "secret") }

            _ = try await driver.type(tabID: tab, ref: query, text: "glide rocks", submit: true)
            let result = try await driver.snapshot(tabID: tab)
            #expect(result.title == "Results")
            #expect(result.url.contains("/result?q=glide+rocks"))
            #expect(result.text.contains("Results for glide rocks"))
        }
    }

    @Test func staleRefsAskForANewSnapshot() async throws {
        try await ChromeHarness.run { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server)
            let press = try #require(snap.named("Press me")).ref
            _ = try await driver.navigate(tabID: tab, url: server.url("/second"))
            let second = try await driver.snapshot(tabID: tab)
            #expect(second.title == "Second")
            #expect(!second.elements.contains { $0.ref == press }, "refs never repeat across pages in a tab")
            await #expect(throws: BrowserError.elementNotFound(press)) { _ = try await driver.click(tabID: tab, ref: press) }
            #expect(try await driver.back(tabID: tab))
            #expect(try await driver.snapshot(tabID: tab).title == "Glide Fixture")
        }
    }

    @Test func refusesElementsThatChangedSinceTheSnapshot() async throws {
        try await ChromeHarness.run { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server)
            let press = try #require(snap.named("Press me")).ref
            // The page relabels the button after the snapshot (and after any safety check).
            _ = try await driver.evaluate(tabID: tab, "document.getElementById('go').textContent = 'Delete everything'; true")
            await #expect(throws: BrowserActionError.self) { _ = try await driver.click(tabID: tab, ref: press) }
            #expect(try await driver.readText(tabID: tab, selector: "#status").text == "Status: idle")
            // A fresh snapshot shows the new name, and then the click goes through.
            let fresh = try await driver.snapshot(tabID: tab)
            #expect(fresh.element(press)?.name == "Delete everything")
            _ = try await driver.click(tabID: tab, ref: press)
            #expect(try await driver.readText(tabID: tab, selector: "#status").text == "Status: clicked")
        }
    }

    @Test func readsTextWaitsPressesAndScrolls() async throws {
        try await ChromeHarness.run { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server)
            let page = try await driver.readText(tabID: tab)
            #expect(page.text.contains("Fixture Home") && page.text.contains("Readable closing paragraph"))
            await #expect(throws: BrowserActionError.self) { _ = try await driver.readText(tabID: tab, selector: "#nope") }
            await #expect(throws: BrowserActionError.self) { _ = try await driver.readText(tabID: tab, selector: "[[[") }

            _ = try await driver.click(tabID: tab, ref: try #require(snap.named("Later")).ref)
            #expect(try await driver.wait(tabID: tab, for: .text("Status: later"), timeout: 5))
            #expect(try await driver.wait(tabID: tab, for: .selector("#frame"), timeout: 2))
            #expect(try await driver.wait(tabID: tab, for: .text("never appears"), timeout: 0.5) == false)

            let scrolled = try await driver.scroll(tabID: tab, direction: .down, amount: 1)
            #expect(scrolled.notes.isEmpty)
            #expect(try await driver.snapshot(tabID: tab).scrollY > 100)

            _ = try await driver.type(tabID: tab, ref: try #require(snap.named("Query")).ref, text: "pressed")
            _ = try await driver.press(tabID: tab, keys: "Enter")
            #expect(try await driver.snapshot(tabID: tab).text.contains("Results for pressed"))

            let png = try await driver.screenshot(tabID: tab)
            #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }
    }

    @Test func answersDialogsSafely() async throws {
        try await ChromeHarness.run { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server)
            let outcome = try await driver.click(tabID: tab, ref: try #require(snap.named("Ask")).ref)
            #expect(outcome.notes.contains { $0.contains("Cancel") })
            #expect(try await driver.readText(tabID: tab, selector: "#status").text == "Status: declined")
        }
    }

    @Test func managesTwoTabsIncludingBackgroundOnes() async throws {
        try await ChromeHarness.run { backend, driver, server in
            let first = try await driver.openTab(url: server.url("/"), background: true)
            let second = try await driver.openTab(url: server.url("/second"), background: true)
            #expect(!first.active && !second.active)
            let tabs = try await driver.tabs()
            #expect(tabs.contains { $0.id == first.id && $0.ownedByGlide })
            #expect(tabs.contains { $0.id == second.id && $0.ownedByGlide && $0.url.hasSuffix("/second") })
            #expect(tabs.contains { !$0.ownedByGlide }, "Chrome's own start tab isn't Glide's")
            // Both background tabs work independently.
            let a = try await driver.snapshot(tabID: first.id)
            let b = try await driver.snapshot(tabID: second.id)
            #expect(a.title == "Glide Fixture" && b.title == "Second")
            _ = try await driver.click(tabID: first.id, ref: try #require(a.named("Press me")).ref)
            #expect(try await driver.readText(tabID: first.id, selector: "#status").text == "Status: clicked")
            try await driver.activateTab(second.id)
            #expect(try await driver.tabs().first { $0.id == second.id }?.active == true)
            try await driver.closeTab(second.id)
            #expect(try await driver.tabs().contains { $0.id == second.id } == false)
            await #expect(throws: BrowserError.self) { _ = try await driver.snapshot(tabID: second.id) }
            await #expect(throws: BrowserError.self) { _ = try await backend.openTab(url: "http://127.0.0.1:1/", background: true) }
        }
    }

    @Test func cancellingALaunchLeavesNoChromeBehind() async throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("glide-chrome-test-\(UUID().uuidString)", isDirectory: true)
        let backend = GlideChromeBackend(configuration: .init(userDataDirectory: profile, headless: true, extraArguments: GlideChromeBackend.quietArguments))
        let launch = Task { try await backend.connect() }
        try await Task.sleep(for: .milliseconds(40))
        launch.cancel()
        let started = Date()
        _ = try? await launch.value // cancelled, or already connected on a fast machine
        #expect(Date().timeIntervalSince(started) < 6)
        await backend.shutdown()
        #expect(await backend.isConnected() == false)
        #expect(await backend.launchedProcessID == nil)
        #expect(Self.processes(using: profile) == 0, "no Chrome keeps running on the profile")
        try? FileManager.default.removeItem(at: profile)
    }

    /// Processes whose command line mentions `profile` (Chrome and its helpers).
    static func processes(using profile: URL) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", profile.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).count
    }

    @Test func reconnectsAfterChromeQuits() async throws {
        try await ChromeHarness.run { backend, driver, server in
            #expect(await backend.isConnected())
            let pid = try #require(await backend.launchedProcessID)
            let helpers = GlideChromeBackend.childProcesses(of: pid)
            let bundle = GlideChromeBackend.bundlePrefix(of: try #require(ChromeLocator.executable()))
            #expect(helpers.contains { GlideChromeBackend.isProcess($0, under: bundle) }, "Chrome's helpers are its children")
            await backend.shutdown()
            #expect(await backend.isConnected() == false)
            #expect(!GlideChromeBackend.isProcess(pid, under: bundle))
            #expect(helpers.allSatisfy { !GlideChromeBackend.isProcess($0, under: bundle) }, "no helper outlives shutdown")
            #expect(Self.processes(using: await backend.currentConfiguration.userDataDirectory) == 0)
            try await backend.connect()
            #expect(await backend.isConnected())
            let (_, snap) = try await ChromeHarness.openHome(driver, server)
            #expect(snap.named("Press me") != nil)
            let detail = await backend.statusDetail()
            #expect(detail.contains("running"))
        }
    }
}

@Suite("Browser tools (headless Chrome)", .serialized, .enabled(if: ChromeHarness.installed, "Google Chrome isn't installed; skipping the live browser tests."))
struct BrowserToolChromeTests {
    func setUp(_ backend: GlideChromeBackend) -> (ToolRegistry, ToolContext, BrowserSessions) {
        let hub = BrowserHub()
        hub.register(backend)
        var settings = AppSettings()
        settings.browser.backend = .glideChrome
        let sessions = BrowserSessions()
        return (ToolRegistry(BrowserTools.make(hub: hub, sessions: sessions)), ToolContext(settings: settings, gate: ExecutionGate()), sessions)
    }

    func ref(_ output: ToolOutput, named name: String) -> String? {
        output.data?["elements"]?.arrayValue?.first { $0["name"]?.stringValue == name }?["ref"]?.stringValue
    }

    @Test func openClickTypeAndAssessThroughTheRegistry() async throws {
        try await ChromeHarness.run { backend, _, server in
            let (tools, ctx, _) = setUp(backend)
            #expect(tools.specs(in: [.browser]).count == 13)
            let open = try #require(tools.tool(named: "browser.open"))
            #expect(open.assess(["url": .string(server.url("/"))], context: ctx).risk == .low)
            let opened = try await open.run(["url": .string(server.url("/"))], context: ctx)
            #expect(opened.ok, "\(opened.text)")
            #expect(opened.text.contains("Press me") && opened.text.contains("background tab"))

            let click = try #require(tools.tool(named: "browser.click"))
            let press = try #require(ref(opened, named: "Press me"))
            #expect(click.assess(["ref": .string(press)], context: ctx).risk == .low)
            let delete = try #require(ref(opened, named: "Delete account"))
            #expect(click.assess(["ref": .string(delete)], context: ctx).risk == .high, "judged from the element in the snapshot")
            let pay = try #require(ref(opened, named: "Continue"))
            #expect(click.assess(["ref": .string(pay)], context: ctx).risk == .high, "a Continue button in a payment form")
            let clicked = try await click.run(["ref": .string(press)], context: ctx)
            #expect(clicked.ok)
            #expect(clicked.text.contains("Clicked \(press) button “Press me”"))
            #expect(clicked.text.contains("Status: clicked"))

            let missing = try await click.run(["ref": "b99999"], context: ctx)
            #expect(!missing.ok && missing.text.contains("new snapshot"))
            await #expect(throws: ToolError.self) { _ = try await click.run(["ref": "#go"], context: ctx) }

            let type = try #require(tools.tool(named: "browser.type"))
            let password = try #require(opened.data?["elements"]?.arrayValue?.first { $0["secure"]?.boolValue == true }?["ref"]?.stringValue)
            #expect(type.assess(["ref": .string(password), "text": "x"], context: ctx).blocked != nil)
            let refused = try await type.run(["ref": .string(password), "text": "x"], context: ctx)
            #expect(!refused.ok)
            let query = try #require(ref(opened, named: "Query"))
            #expect(type.assess(["ref": .string(query), "text": "cats", "submit": true], context: ctx).risk == .medium)
            let submitted = try await type.run(["ref": .string(query), "text": "cats", "submit": true], context: ctx)
            #expect(submitted.ok)
            #expect(submitted.text.contains("Results for cats") && submitted.text.contains("Now on"))

            let back = try await tools.tool(named: "browser.back")!.run([:], context: ctx)
            #expect(back.ok && back.text.contains("Glide Fixture"))
            let read = try await tools.tool(named: "browser.read")!.run(["selector": "#status"], context: ctx)
            #expect(read.ok && read.text.contains("Status:"))
        }
    }

    @Test func popupsTabsAndClosing() async throws {
        try await ChromeHarness.run { backend, _, server in
            let (tools, ctx, sessions) = setUp(backend)
            let opened = try await tools.tool(named: "browser.open")!.run(["url": .string(server.url("/"))], context: ctx)
            let popup = try #require(ref(opened, named: "Open popup"))
            let clicked = try await tools.tool(named: "browser.click")!.run(["ref": .string(popup)], context: ctx)
            #expect(clicked.ok)
            #expect(clicked.text.contains("opened a new tab") && clicked.text.contains("Popup page"))

            let list = try await tools.tool(named: "browser.tabs")!.run([:], context: ctx)
            #expect(list.ok && list.text.contains("[opened by Glide]") && list.text.contains("* "))
            let current = try #require(sessions.session("default")?.tabID)
            let close = try #require(tools.tool(named: "browser.close_tab"))
            #expect(close.assess([:], context: ctx).risk == .low, "Glide opened this tab")
            let closed = try await close.run([:], context: ctx)
            #expect(closed.ok)
            #expect(sessions.session("default") == nil)
            #expect(!(try await backend.tabs().contains { $0.id == current }))

            // Chrome's start tab isn't Glide's, so closing it needs approval.
            let userTab = try #require(try await backend.tabs().first { !$0.ownedByGlide })
            #expect(close.assess(["tab_id": .string(userTab.id)], context: ctx).risk == .high)

            let switched = try await tools.tool(named: "browser.switch_tab")!.run(["tab_id": .string(userTab.id)], context: ctx)
            #expect(switched.ok)
            let reopened = try await tools.tool(named: "browser.open")!.run(["url": .string(server.url("/second"))], context: ctx)
            #expect(reopened.ok && reopened.text.contains("new tab so the tab you were on stays"))
            let wait = try await tools.tool(named: "browser.wait")!.run(["for": "text", "value": "Second page", "timeout_s": 3], context: ctx)
            #expect(wait.ok)
        }
    }

    @Test func separateItemsGetSeparateTabsAndStopIsImmediate() async throws {
        try await ChromeHarness.run { backend, _, server in
            let (tools, ctx, sessions) = setUp(backend)
            var item1 = ctx
            item1.jobID = "job1"
            item1.itemID = "1"
            var item2 = item1
            item2.itemID = "2"
            let open = try #require(tools.tool(named: "browser.open"))
            async let a = open.run(["url": .string(server.url("/"))], context: item1)
            async let b = open.run(["url": .string(server.url("/second"))], context: item2)
            let (ra, rb) = try await (a, b)
            #expect(ra.ok && rb.ok)
            let t1 = try #require(sessions.session("job:job1/item:1")?.tabID)
            let t2 = try #require(sessions.session("job:job1/item:2")?.tabID)
            #expect(t1 != t2)
            await sessions.releaseJob("job1", hub: { let h = BrowserHub(); h.register(backend); return h }())
            let remaining = try await backend.tabs().map(\.id)
            #expect(!remaining.contains(t1) && !remaining.contains(t2))

            // The emergency stop interrupts a long wait right away.
            _ = try await open.run(["url": .string(server.url("/"))], context: ctx)
            let gate = ExecutionGate()
            var stoppableContext = ctx
            stoppableContext.gate = gate
            let stoppable = stoppableContext
            let waitTool = try #require(tools.tool(named: "browser.wait"))
            let waiting = Task { try await waitTool.run(["for": "text", "value": "never", "timeout_s": 30], context: stoppable) }
            try await Task.sleep(for: .milliseconds(300))
            let started = Date()
            gate.stop()
            await #expect(throws: AutomationError.stopped) { _ = try await waiting.value }
            #expect(Date().timeIntervalSince(started) < 2)
            await #expect(throws: AutomationError.stopped) { _ = try await open.run(["url": .string(server.url("/"))], context: stoppable) }
        }
    }
}
