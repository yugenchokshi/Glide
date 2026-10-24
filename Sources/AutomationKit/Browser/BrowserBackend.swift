import Foundation

// DOM-level browser control ("like Playwright", without Node). Two interchangeable backends
// speak the Chrome DevTools Protocol (CDP) to a tab:
//   • extensionBridge — the Glide Chrome extension relays CDP through chrome.debugger in the
//     user's everyday Chrome (their logins, no separate profile). Tabs can run in the
//     background without moving the cursor.
//   • glideChrome — Glide launches its own Chrome window with a dedicated profile and a local
//     debugging port. Used when the extension isn't installed, and by tests (headless).
// `BrowserDriver` builds snapshots, clicks, typing and reading on top of either backend.

public enum BrowserBackendKind: String, Codable, Sendable, CaseIterable {
    case extensionBridge
    case glideChrome

    public var title: String {
        switch self {
        case .extensionBridge: return "Your Chrome (Glide extension)"
        case .glideChrome: return "Glide's own Chrome window"
        }
    }
}

public struct BrowserTab: Codable, Sendable, Hashable, Identifiable {
    /// Backend-specific id (extension: chrome tab id; glideChrome: CDP target id).
    public var id: String
    public var url: String
    public var title: String
    public var active: Bool
    /// Opened by Glide (only these are closed automatically).
    public var ownedByGlide: Bool
    /// The tab this one was opened from (a link with target=_blank, a script popup), when the
    /// backend knows it. It's how a click's popup is told apart from tabs that opened meanwhile.
    public var openerID: String?

    public init(id: String, url: String, title: String, active: Bool, ownedByGlide: Bool, openerID: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.active = active
        self.ownedByGlide = ownedByGlide
        self.openerID = openerID
    }
}

public enum BrowserError: Error, LocalizedError, Sendable, Equatable {
    case notConnected(String)
    case tabNotFound(String)
    case cdp(String)
    case timeout(String)
    /// chrome://, the Web Store and similar pages can't be automated.
    case restrictedPage(String)
    case elementNotFound(String)
    case chromeNotInstalled
    /// The page shows a dialog that's the user's to answer (see `BrowserDialogPolicy`). It's
    /// frozen until they do, so the driver stops waiting at once and says so.
    case dialogOpen(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected(let m): return m
        case .tabNotFound(let t): return "The browser tab \(t) is gone."
        case .cdp(let m): return "Browser error: \(m)"
        case .dialogOpen(let m): return m
        case .timeout(let m): return "The page took too long: \(m)"
        case .restrictedPage(let u): return "Chrome doesn't allow automating \(u)."
        case .elementNotFound(let r): return "Element \(r) isn't on the page anymore. Take a new snapshot."
        case .chromeNotInstalled: return "Google Chrome isn't installed."
        }
    }
}

/// A connection to Chrome that can manage tabs and send CDP commands to them.
public protocol BrowserBackend: AnyObject, Sendable {
    var kind: BrowserBackendKind { get }
    /// True when commands can be sent right now.
    func isConnected() async -> Bool
    /// Starts or reconnects (launch Chrome / wait for the extension). Throws with a user-facing reason.
    func connect() async throws
    func tabs() async throws -> [BrowserTab]
    /// Opens a tab. `background: true` keeps the user's current tab in front.
    func openTab(url: String, background: Bool) async throws -> BrowserTab
    func navigate(tabID: String, url: String) async throws
    func closeTab(_ tabID: String) async throws
    func activateTab(_ tabID: String) async throws
    /// Sends one CDP command to the tab, attaching the debugger first if needed, and returns
    /// the command's `result` object.
    func cdp(tabID: String, method: String, params: JSONValue?) async throws -> JSONValue
}

/// Connection state shown in Settings › Browser and the notch.
public struct BrowserStatus: Sendable, Hashable {
    public var backend: BrowserBackendKind
    public var connected: Bool
    /// Human line, e.g. "Connected to Chrome 141 via the Glide extension".
    public var detail: String
    public var chromeInstalled: Bool
    /// Extension backend only: whether it has paired with this Mac.
    public var extensionPaired: Bool

    public init(backend: BrowserBackendKind, connected: Bool, detail: String, chromeInstalled: Bool, extensionPaired: Bool) {
        self.backend = backend
        self.connected = connected
        self.detail = detail
        self.chromeInstalled = chromeInstalled
        self.extensionPaired = extensionPaired
    }
}

public enum ChromeLocator {
    public static let candidates = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        NSHomeDirectory() + "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ]

    public static func executable(override: String? = nil) -> String? {
        if let override, FileManager.default.isExecutableFile(atPath: override) { return override }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
