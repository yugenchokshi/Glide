import Foundation
import AppKit

/// Finds, launches and activates applications, waiting for real readiness (a window exists
/// and the app is frontmost) instead of fixed delays.
public final class AppController: @unchecked Sendable {
    let accessibility: AccessibilityEngine

    public init(accessibility: AccessibilityEngine) {
        self.accessibility = accessibility
    }

    static let searchDirectories: [String] = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities",
        "/Applications/Utilities", NSHomeDirectory() + "/Applications", "/System/Library/CoreServices",
    ]

    static let aliases: [String: String] = [
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "vscode": "Visual Studio Code",
        "vs code": "Visual Studio Code", "code": "Visual Studio Code", "word": "Microsoft Word",
        "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint", "outlook": "Microsoft Outlook",
        "system preferences": "System Settings", "settings": "System Settings", "notes": "Notes",
        "apple notes": "Notes", "textedit": "TextEdit", "text edit": "TextEdit", "mail": "Mail",
        "terminal": "Terminal", "finder": "Finder", "calendar": "Calendar", "safari": "Safari",
        "messages": "Messages", "reminders": "Reminders", "preview": "Preview",
    ]

    /// Resolves an app name, alias or bundle id to an application bundle URL.
    public func appURL(named query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) { return url }
        let name = Self.aliases[trimmed.lowercased()] ?? trimmed
        let fm = FileManager.default
        for dir in Self.searchDirectories {
            let path = "\(dir)/\(name).app"
            if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // Case-insensitive / fuzzy scan of the standard folders.
        let target = ElementMatcher.normalize(name)
        var best: (URL, Double)?
        for dir in Self.searchDirectories {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let base = ElementMatcher.normalize(String(item.dropLast(4)))
                let s = ElementMatcher.similarity(target, base)
                if s > (best?.1 ?? 0.82) { best = (URL(fileURLWithPath: "\(dir)/\(item)"), s) }
            }
        }
        return best?.0
    }

    public func runningApp(named query: String) -> NSRunningApplication? {
        let name = Self.aliases[query.lowercased()] ?? query
        let target = ElementMatcher.normalize(name)
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == query || ElementMatcher.normalize($0.localizedName ?? "") == target
        } ?? NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && ElementMatcher.similarity(target, ElementMatcher.normalize($0.localizedName ?? "")) > 0.85
        }
    }

    public func info(for app: NSRunningApplication) -> AppInfo {
        AppInfo(name: app.localizedName ?? "App", bundleID: app.bundleIdentifier, pid: app.processIdentifier)
    }

    /// Launches (or activates) an app and waits until it is frontmost with a window.
    @discardableResult
    public func launch(_ query: String, timeout: TimeInterval = 12) async throws -> AppInfo {
        if let running = runningApp(named: query) {
            return try await activate(running, timeout: timeout)
        }
        guard let url = appURL(named: query) else { throw AutomationError.appNotFound(query) }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        return try await activate(app, timeout: timeout)
    }

    @discardableResult
    public func activate(_ query: String, timeout: TimeInterval = 8) async throws -> AppInfo {
        guard let running = runningApp(named: query) else {
            return try await launch(query, timeout: timeout)
        }
        return try await activate(running, timeout: timeout)
    }

    @discardableResult
    public func activate(_ app: NSRunningApplication, timeout: TimeInterval) async throws -> AppInfo {
        let deadline = Date().addingTimeInterval(timeout)
        var reopened = false
        while Date() < deadline {
            try Task.checkCancellation()
            if app.isFinishedLaunching {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
                    _ = app.activate()
                }
                let hasWindow = accessibility.focusedWindow(pid: app.processIdentifier) != nil
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier && hasWindow {
                    accessibility.raiseWindow(pid: app.processIdentifier)
                    return info(for: app)
                }
                // Apps like Notes/Finder may be running with no window: reopen to get one.
                if !hasWindow && !reopened, let url = app.bundleURL {
                    reopened = true
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                }
            }
            try await Task.sleep(for: .milliseconds(60))
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return info(for: app) // frontmost but windowless (e.g. Finder desktop)
        }
        throw AutomationError.timeout("waiting for \(app.localizedName ?? "app") to come to the front")
    }

    public func open(url: URL, withApp appName: String? = nil) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let appName, let appURL = appURL(named: appName) {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            _ = try await NSWorkspace.shared.open(url, configuration: config)
        }
    }
}
