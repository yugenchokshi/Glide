import Foundation
import Synchronization

/// `BrowserBackend` over the Glide Chrome extension: the user's everyday Chrome, with their
/// logins. Each protocol method is one RPC to the extension (see `ExtensionBridge` for the wire
/// format); `cdp` is relayed through `chrome.debugger`, which the extension attaches (protocol
/// 1.3) the first time a tab is used. Tab ids are Chrome's tab ids as strings.
public final class ExtensionBackend: BrowserBackend {
    public let kind: BrowserBackendKind = .extensionBridge
    public let bridge: ExtensionBridge
    /// How long an operation waits for the extension to (re)connect before failing. The MV3
    /// service worker can restart at any time and reconnects within a second or two.
    let connectTimeout: TimeInterval
    /// Tabs opened through this backend (`BrowserTab.ownedByGlide`).
    private let ownedTabs = Mutex<Set<String>>([])
    /// Dialogs the extension answered, per tab, until the driver collects them.
    private let dialogs = Mutex<[String: [BrowserDialog]]>([:])

    public init(bridge: ExtensionBridge = .shared, connectTimeout: TimeInterval = 5) {
        self.bridge = bridge
        self.connectTimeout = connectTimeout
        bridge.addEventHandler { [weak self] event in
            if case .dialog(let tabID, let dialog) = event {
                self?.dialogs.withLock { all in
                    var list = all[tabID] ?? []
                    list.append(dialog)
                    all[tabID] = Array(list.suffix(20))
                }
            }
        }
    }

    public func isConnected() async -> Bool { bridge.isConnected }

    /// Waits up to `connectTimeout` for the extension, then throws a `notConnected` error that
    /// says what to do (pair it, open Chrome, free the port…).
    public func connect() async throws {
        if bridge.isConnected { return }
        if await bridge.waitForConnection(timeout: connectTimeout) { return }
        try Task.checkCancellation()
        throw bridge.connectionProblem()
    }

    public func tabs() async throws -> [BrowserTab] {
        let result = try await call("tabs.list")
        guard let list = result.arrayValue else { throw BrowserError.cdp("The Glide extension sent an unexpected tab list.") }
        let tabs = list.compactMap { parseTab($0) }
        // Forget tabs the user has closed since.
        let ids = Set(tabs.map(\.id))
        ownedTabs.withLock { $0.formIntersection(ids) }
        return tabs
    }

    public func openTab(url: String, background: Bool) async throws -> BrowserTab {
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if ExtensionURLPolicy.isRestricted(target) { throw BrowserError.restrictedPage(target) }
        let result = try await call("tabs.create", ["url": .string(target.isEmpty ? "about:blank" : target), "active": .bool(!background)])
        guard var tab = parseTab(result) else { throw BrowserError.cdp("Chrome didn't report the new tab.") }
        tab.ownedByGlide = true
        let id = tab.id
        ownedTabs.withLock { _ = $0.insert(id) }
        return tab
    }

    public func navigate(tabID: String, url: String) async throws {
        let target = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if ExtensionURLPolicy.isRestricted(target) { throw BrowserError.restrictedPage(target) }
        _ = try await call("tabs.update", ["tabId": try tabNumber(tabID), "url": .string(target)])
    }

    public func closeTab(_ tabID: String) async throws {
        _ = try await call("tabs.remove", ["tabId": try tabNumber(tabID)])
        ownedTabs.withLock { _ = $0.remove(tabID) }
    }

    public func activateTab(_ tabID: String) async throws {
        _ = try await call("tabs.update", ["tabId": try tabNumber(tabID), "active": true])
    }

    public func cdp(tabID: String, method: String, params: JSONValue?) async throws -> JSONValue {
        let result = try await call("cdp.send", ["tabId": try tabNumber(tabID), "method": .string(method), "params": params ?? .object([:])])
        return result.isNull ? .object([:]) : result
    }

    /// Detaches the debugger from a tab, which removes Chrome's "started debugging this browser"
    /// bar when no other tab is attached. The next `cdp` call re-attaches.
    public func detach(tabID: String) async throws {
        _ = try await call("cdp.detach", ["tabId": try tabNumber(tabID)])
    }

    // MARK: Helpers

    private func call(_ method: String, _ params: JSONValue? = nil) async throws -> JSONValue {
        if !bridge.isConnected { try await connect() }
        return try await bridge.call(method, params: params)
    }

    private func tabNumber(_ tabID: String) throws -> JSONValue {
        guard let number = Int(tabID.trimmingCharacters(in: .whitespaces)), number >= 0 else { throw BrowserError.tabNotFound(tabID) }
        return .number(Double(number))
    }

    private func parseTab(_ value: JSONValue) -> BrowserTab? {
        guard let number = value["id"]?.intValue, number >= 0 else { return nil }
        let id = String(number)
        let owned = ownedTabs.withLock { $0.contains(id) } || value["glide"]?.boolValue == true
        let opener = value["openerId"]?.intValue.flatMap { $0 >= 0 ? String($0) : nil }
        return BrowserTab(id: id, url: value["url"]?.stringValue ?? "", title: value["title"]?.stringValue ?? "",
                          active: value["active"]?.boolValue ?? false, ownedByGlide: owned, openerID: opener)
    }
}

/// Pages Chrome won't let an extension automate (its own UI, other extensions, the Web Store),
/// plus `javascript:` URLs, which would run script outside the page's normal flow. The
/// extension applies the same rules (Extensions/chrome/common.js); checking here too gives a
/// clear error without a round trip.
public enum ExtensionURLPolicy {
    static let restrictedSchemes: Set<String> = [
        "chrome", "chrome-extension", "chrome-untrusted", "chrome-search", "chrome-devtools", "devtools",
        "edge", "brave", "opera", "vivaldi", "view-source", "javascript",
    ]
    static let allowedAboutPages: Set<String> = ["about:blank", "about:srcdoc"]

    public static func isRestricted(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if let colon = trimmed.firstIndex(of: ":") {
            let scheme = String(trimmed[..<colon])
            if restrictedSchemes.contains(scheme) { return true }
            if scheme == "about" { return !allowedAboutPages.contains(String(trimmed.prefix { $0 != "?" && $0 != "#" })) }
        }
        guard let components = URLComponents(string: trimmed), let host = components.host else { return false }
        if host == "chromewebstore.google.com" { return true }
        if host == "chrome.google.com", components.path.hasPrefix("/webstore") { return true }
        return false
    }
}

// The driver uses these to report dialogs to the model and to describe the connection in
// Settings › Browser. The extension doesn't stream network events, so the driver falls back to
// watching the DOM settle.
extension ExtensionBackend: BrowserPageObserving, BrowserStatusDescribing {
    public func networkActivity(tabID: String) async -> BrowserNetworkActivity? { nil }

    public func takeHandledDialogs(tabID: String) async -> [BrowserDialog] {
        dialogs.withLock { $0.removeValue(forKey: tabID) ?? [] }
    }

    public func statusDetail() async -> String { bridge.status().detail }
}
