import Foundation
import AppKit

/// What should be true after an action.
public enum Expectation: Sendable, Hashable, CustomStringConvertible {
    case none
    case uiChanged
    case appFrontmost(String)
    case focusedValueContains(String)
    case elementValueContains(elementID: String, text: String)
    case elementAppears(String)
    case elementGone(fingerprint: String, label: String)
    case windowTitleContains(String)
    case fileExists(String)

    public var description: String {
        switch self {
        case .none: return "nothing"
        case .uiChanged: return "the window to change"
        case .appFrontmost(let a): return "\(a) to be in front"
        case .focusedValueContains(let t): return "the field to contain “\(t.prefix(40))”"
        case .elementValueContains(_, let t): return "the field to contain “\(t.prefix(40))”"
        case .elementAppears(let d): return "“\(d)” to appear"
        case .elementGone(_, let l): return "“\(l)” to disappear"
        case .windowTitleContains(let t): return "window title to contain “\(t)”"
        case .fileExists(let p): return "file \(p) to exist"
        }
    }
}

public struct VerificationResult: Sendable, Codable {
    public enum Status: String, Sendable, Codable {
        case passed
        /// Nothing contradicted the action but the effect couldn't be confirmed.
        case unconfirmed
        case failed
    }
    public var status: Status
    public var detail: String
    public var durationMs: Double

    public var passed: Bool { status == .passed }

    public init(status: Status, detail: String, durationMs: Double) {
        self.status = status
        self.detail = detail
        self.durationMs = durationMs
    }
}

/// Confirms action outcomes from structured state (AX values, focus, windows, files) rather
/// than screenshot diffs. Waits are event-driven via the AX change counter.
public final class VerificationEngine: @unchecked Sendable {
    let accessibility: AccessibilityEngine

    public init(accessibility: AccessibilityEngine) {
        self.accessibility = accessibility
    }

    public func verify(_ expectation: Expectation, app: AppInfo?, before: ScreenObservation?, sinceGeneration: UInt64?, timeout: TimeInterval = 2.0) async -> VerificationResult {
        let start = Date()
        func result(_ s: VerificationResult.Status, _ d: String) -> VerificationResult {
            VerificationResult(status: s, detail: d, durationMs: Date().timeIntervalSince(start) * 1000)
        }
        let deadline = start.addingTimeInterval(timeout)
        switch expectation {
        case .none:
            return result(.passed, "no check needed")

        case .appFrontmost(let name):
            let target = ElementMatcher.normalize(AppController.aliases[name.lowercased()] ?? name)
            while Date() < deadline {
                if let front = NSWorkspace.shared.frontmostApplication,
                   ElementMatcher.similarity(target, ElementMatcher.normalize(front.localizedName ?? "")) > 0.85 || front.bundleIdentifier == name {
                    return result(.passed, "\(front.localizedName ?? name) is frontmost")
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            return result(.failed, "\(name) did not come to the front")

        case .fileExists(let path):
            let expanded = (path as NSString).expandingTildeInPath
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: expanded) { return result(.passed, "file exists") }
                try? await Task.sleep(for: .milliseconds(80))
            }
            return result(.failed, "file not found at \(path)")

        case .uiChanged:
            guard let app = app else { return result(.unconfirmed, "no app to observe") }
            let since = sinceGeneration ?? accessibility.monitor.generation(for: app.pid)
            let changed = await accessibility.monitor.waitForChange(pid: app.pid, since: since, timeout: timeout)
            if changed {
                // Give the app a moment to finish the update before the next observation.
                try? await Task.sleep(for: .milliseconds(60))
                return result(.passed, "window updated")
            }
            if let before, let now = try? accessibility.observe(app, useCache: false), differs(before, now) {
                return result(.passed, "window content changed")
            }
            if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != app.pid {
                return result(.passed, "focus moved to \(front.localizedName ?? "another app")")
            }
            return result(.unconfirmed, "no visible change detected")

        case .focusedValueContains(let text):
            guard let app else { return result(.unconfirmed, "no app") }
            let needle = Self.normalizeForCompare(text)
            var lastValue: String?
            while Date() < deadline {
                accessibility.invalidateCache()
                if let obs = try? accessibility.observe(app, useCache: false) {
                    if let f = obs.focusedElement {
                        if f.isSecure { return result(.unconfirmed, "secure field") }
                        lastValue = f.value
                        if let v = f.value, Self.normalizeForCompare(v).contains(needle) { return result(.passed, "text entered") }
                    }
                    // Rich-text editors (Notes, web editors) often expose text on a child node.
                    if obs.elements.contains(where: { ($0.value.map(Self.normalizeForCompare) ?? "").contains(needle) || ($0.role == "text" && Self.normalizeForCompare($0.name).contains(needle)) }) {
                        return result(.passed, "text visible in window")
                    }
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            return result(lastValue == nil ? .unconfirmed : .failed, lastValue == nil ? "field value not readable" : "field doesn't contain the typed text")

        case .elementValueContains(let id, let text):
            guard let app else { return result(.unconfirmed, "no app") }
            let needle = Self.normalizeForCompare(text)
            while Date() < deadline {
                if let ref = before?.refs[id], let v = accessibility.value(of: ref), Self.normalizeForCompare(v).contains(needle) {
                    return result(.passed, "field contains text")
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            return await verify(.focusedValueContains(text), app: app, before: before, sinceGeneration: nil, timeout: 0.6)

        case .elementAppears(let description):
            guard let app else { return result(.unconfirmed, "no app") }
            while Date() < deadline {
                if let obs = try? accessibility.observe(app, useCache: false),
                   let best = ElementMatcher.rank(description, in: obs.elements, limit: 1).first, best.score >= 0.8 {
                    return result(.passed, "found \(best.node.role) “\(best.node.label)”")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return result(.failed, "“\(description)” did not appear")

        case .elementGone(let fingerprint, let label):
            guard let app else { return result(.unconfirmed, "no app") }
            while Date() < deadline {
                if let obs = try? accessibility.observe(app, useCache: false), !obs.elements.contains(where: { $0.fingerprint == fingerprint }) {
                    return result(.passed, "“\(label)” is gone")
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return result(.failed, "“\(label)” is still there")

        case .windowTitleContains(let text):
            guard let app else { return result(.unconfirmed, "no app") }
            let needle = text.lowercased()
            while Date() < deadline {
                if let w = accessibility.focusedWindow(pid: app.pid), let t = AX.string(w, kAXTitleAttribute), t.lowercased().contains(needle) {
                    return result(.passed, "window title is “\(t)”")
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            return result(.failed, "window title doesn't contain “\(text)”")
        }
    }

    func differs(_ a: ScreenObservation, _ b: ScreenObservation) -> Bool {
        if a.windowTitle != b.windowTitle || a.focusedElementID != b.focusedElementID { return true }
        let fa = Set(a.elements.map { $0.fingerprint + ($0.value ?? "") })
        let fb = Set(b.elements.map { $0.fingerprint + ($0.value ?? "") })
        return fa != fb
    }

    static func normalizeForCompare(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
