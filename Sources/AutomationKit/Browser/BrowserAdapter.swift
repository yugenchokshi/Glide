import Foundation

/// Optional browser context beyond the accessibility tree: current URL/title via Apple
/// Events, page text via JavaScript (when the user enabled "Allow JavaScript from Apple
/// Events"), and Chrome DevTools Protocol when Chrome runs with a debugging port.
public final class BrowserAdapter: @unchecked Sendable {
    public enum Browser: String, Sendable, CaseIterable {
        case safari = "com.apple.Safari"
        case chrome = "com.google.Chrome"
        case brave = "com.brave.Browser"
        case edge = "com.microsoft.edgemac"
        case arc = "company.thebrowser.Browser"

        var appName: String {
            switch self {
            case .safari: return "Safari"
            case .chrome: return "Google Chrome"
            case .brave: return "Brave Browser"
            case .edge: return "Microsoft Edge"
            case .arc: return "Arc"
            }
        }

        var isChromium: Bool { self != .safari }
    }

    public struct PageInfo: Sendable, Codable {
        public var url: String
        public var title: String
    }

    public var cdpPort: Int = 9222

    public init() {}

    public static func browser(forBundleID id: String?) -> Browser? {
        guard let id else { return nil }
        return Browser(rawValue: id)
    }

    public func currentPage(_ browser: Browser) -> PageInfo? {
        let script: String
        switch browser {
        case .safari:
            script = "tell application \"Safari\" to if (count of windows) > 0 then return (URL of current tab of front window) & \"\\n\" & (name of current tab of front window)"
        default:
            script = "tell application \"\(browser.appName)\" to if (count of windows) > 0 then return (URL of active tab of front window) & \"\\n\" & (title of active tab of front window)"
        }
        guard let out = try? Self.runAppleScript(script) else { return nil }
        let parts = out.components(separatedBy: "\n")
        guard let url = parts.first, !url.isEmpty else { return nil }
        return PageInfo(url: url, title: parts.dropFirst().joined(separator: " "))
    }

    /// Visible page text via JavaScript over Apple Events. Requires the browser's
    /// "Allow JavaScript from Apple Events" developer setting; returns nil otherwise.
    public func pageText(_ browser: Browser, maxChars: Int = 12000) -> String? {
        let js = "document.body ? document.body.innerText.slice(0, \(maxChars)) : ''"
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        switch browser {
        case .safari:
            script = "tell application \"Safari\" to do JavaScript \"\(escaped)\" in current tab of front window"
        default:
            script = "tell application \"\(browser.appName)\" to execute active tab of front window javascript \"\(escaped)\""
        }
        return try? Self.runAppleScript(script)
    }

    // MARK: Chrome DevTools Protocol (optional)

    public struct CDPTarget: Decodable, Sendable {
        public let id: String
        public let type: String
        public let title: String
        public let url: String
        public let webSocketDebuggerUrl: String?
    }

    public func cdpTargets() async -> [CDPTarget] {
        guard let url = URL(string: "http://127.0.0.1:\(cdpPort)/json") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        return ((try? JSONDecoder().decode([CDPTarget].self, from: data)) ?? []).filter { $0.type == "page" }
    }

    /// Evaluates JavaScript in the first page target through CDP and returns the string result.
    public func cdpEvaluate(_ expression: String) async throws -> String? {
        guard let target = await cdpTargets().first, let ws = target.webSocketDebuggerUrl, let url = URL(string: ws) else { return nil }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let payload: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": ["expression": expression, "returnByValue": true]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
        for _ in 0..<20 {
            let message = try await task.receive()
            guard case .string(let text) = message,
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  (obj["id"] as? Int) == 1 else { continue }
            let result = (obj["result"] as? [String: Any])?["result"] as? [String: Any]
            if let v = result?["value"] as? String { return v }
            return result?["value"].map { "\($0)" }
        }
        return nil
    }

    // MARK: AppleScript

    /// Runs AppleScript through osascript (thread-safe, attributable Automation prompts).
    @discardableResult
    public static func runAppleScript(_ source: String, timeout: TimeInterval = 8) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            throw AutomationError.timeout("AppleScript")
        }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AutomationError.appleScript(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
