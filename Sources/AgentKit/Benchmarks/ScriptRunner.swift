import Foundation
import AppKit
import AutomationKit

/// Runs a deterministic sequence of actions (targets resolved by description against fresh
/// observations) with verification. Used for the Phase 2 workflow, the benchmark suite and
/// live tests — no model involved.
public final class ScriptRunner: @unchecked Sendable {
    public struct Stats: Sendable, Codable {
        public var actions = 0
        public var observations = 0
        public var observationMs: Double = 0
        public var recoveries = 0
        public var verificationsPassed = 0
        public var verificationsUnconfirmed = 0
    }

    public let runtime: AutomationRuntime
    public private(set) var stats = Stats()
    public var log: @Sendable (String) -> Void = { print($0) }

    public init(runtime: AutomationRuntime = .shared) {
        self.runtime = runtime
    }

    public var ax: AccessibilityEngine { runtime.accessibility }

    public func frontmost() throws -> AppInfo {
        guard let app = ax.frontmostApp() else { throw AutomationError.noFocusedWindow("frontmost app") }
        return app
    }

    public func observe(_ app: AppInfo? = nil, forceOCR: Bool = false) async throws -> ScreenObservation {
        let target = try app ?? frontmost()
        let t = Date()
        let obs = try await runtime.perception.observe(target, forceOCR: forceOCR, useCache: false)
        stats.observations += 1
        stats.observationMs += Date().timeIntervalSince(t) * 1000
        return obs
    }

    /// Executes an action and verifies `expect` (or the action's default expectation).
    @discardableResult
    public func act(_ action: ComputerAction, in app: AppInfo? = nil, expect: Expectation? = nil, timeout: TimeInterval = 3,
                    requireVerified: Bool = false) async throws -> VerificationResult {
        let obs: ScreenObservation? = try? await observe(app)
        let outcome = try await runtime.executor.execute(action, observation: obs)
        stats.actions += 1
        let expectation = expect ?? outcome.expectation
        let r = await runtime.verification.verify(expectation, app: outcome.app ?? obs?.app, before: obs, sinceGeneration: outcome.generationBefore, timeout: timeout)
        if r.status == .passed { stats.verificationsPassed += 1 } else if r.status == .unconfirmed { stats.verificationsUnconfirmed += 1 }
        log("  • \(action.humanDescription) [\(outcome.method)] → \(r.status.rawValue): \(r.detail) (\(Int(outcome.durationMs))ms + \(Int(r.durationMs))ms verify)")
        if r.status == .failed || (requireVerified && r.status != .passed) {
            throw AutomationError.verificationFailed("\(action.humanDescription): expected \(expectation) — \(r.detail)")
        }
        return r
    }

    /// Clicks a target by description; if it's missing, runs `recover` and retries once.
    public func click(_ description: String, in app: AppInfo? = nil, expect: Expectation? = nil,
                      recover: (() async throws -> Void)? = nil) async throws {
        do {
            try await act(.click(.description(description)), in: app, expect: expect)
        } catch AutomationError.elementNotFound(let what) where recover != nil {
            log("  ↻ \(what) not found — recovering")
            stats.recoveries += 1
            try await recover?()
            try await act(.click(.description(description)), in: app, expect: expect)
        }
    }

    /// Waits until an element matching `description` is present.
    public func waitFor(_ description: String, in app: AppInfo? = nil, timeout: TimeInterval = 5) async throws -> UIElementNode {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await runtime.gate.checkpoint()
            if let obs = try? await observe(app), let best = ElementMatcher.rank(description, in: obs.elements, limit: 1).first, best.score >= 0.8 {
                return best.node
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        throw AutomationError.timeout("waiting for “\(description)”")
    }

    /// Reads the text of an element (by AX identifier or label).
    public func text(of description: String, in app: AppInfo? = nil) async throws -> String {
        let obs = try await observe(app)
        if let byID = obs.elements.first(where: { $0.identifier == description }) { return byID.value ?? byID.name }
        guard let best = ElementMatcher.rank(description, in: obs.elements, limit: 1).first else { throw AutomationError.elementNotFound(description) }
        return best.node.value ?? best.node.name
    }
}
