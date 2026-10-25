import Foundation
import AppKit
import AutomationKit

/// Brings apps and web pages to the front. Behind a protocol so tests never launch anything.
public protocol InstantOpening: Sendable {
    /// Starts bringing the app to the front — activating it if it runs, launching it if not —
    /// and returns as soon as that is under way. False when it can't even start.
    func open(app: InstalledApp) async -> Bool
    /// Waits until the app is frontmost (nudging it once if it launched behind something).
    func waitUntilFront(bundleID: String, timeout: TimeInterval) async -> Bool
    /// Opens an http(s) page in the default browser.
    func open(url: URL) async -> Bool
}

/// Glide's own browser connection (the Chrome extension or Glide's Chrome), used for pages so
/// the tab is one later agent steps can keep working in.
public protocol InstantBrowsing: Sendable {
    /// True only when the preferred backend is connected right now; never launches anything.
    func isConnected() async -> Bool
    /// Opens `url` in a new foreground tab and makes it the quick task's current tab.
    func openForegroundTab(_ url: URL) async throws
}

/// NSWorkspace-backed opener.
public struct SystemInstantOpener: InstantOpening {
    public init() {}

    public func open(app: InstalledApp) async -> Bool {
        // `openApplication` on a running app activates it and, like a Dock click, gives a
        // windowless app (Notes, Finder) a window; on a closed app it launches it.
        guard let url = app.url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else { return false }
            return running.activate(options: [.activateAllWindows])
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        return true
    }

    public func waitUntilFront(bundleID: String, timeout: TimeInterval) async -> Bool {
        let start = Date()
        var nudged = false
        while Date().timeIntervalSince(start) < timeout {
            let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
            if front == bundleID { return true }
            if !nudged, Date().timeIntervalSince(start) > timeout / 2,
               let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, running.isFinishedLaunching {
                nudged = true
                _ = running.activate(options: [.activateAllWindows])
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    public func open(url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config) { _, _ in }
        return true
    }
}

/// Opens pages through `BrowserHub` when its preferred backend is already connected.
public struct HubInstantBrowser: InstantBrowsing {
    let hub: BrowserHub
    let sessions: BrowserSessions
    let settings: @Sendable () -> BrowserSettings

    public init(hub: BrowserHub = .shared, sessions: BrowserSessions = .shared, settings: @escaping @Sendable () -> BrowserSettings) {
        self.hub = hub
        self.sessions = sessions
        self.settings = settings
    }

    public func isConnected() async -> Bool {
        guard let backend = hub.registered(settings().backend) else { return false }
        return await backend.isConnected()
    }

    public func openForegroundTab(_ url: URL) async throws {
        let kind = settings().backend
        guard let backend = hub.registered(kind), await backend.isConnected() else {
            throw BrowserError.notConnected("Glide's browser isn't connected.")
        }
        let driver = sessions.driver(for: backend)
        _ = try await sessions.openTab(key: BrowserSessions.key(jobID: nil, itemID: nil), jobID: nil, url: url.absoluteString,
                                       background: false, driver: driver)
        // The extension drives the user's own Chrome; a foreground tab there should also put
        // Chrome in front of whatever the user was in.
        if kind == .extensionBridge, let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
            _ = chrome.activate(options: [.activateAllWindows])
        }
    }
}
