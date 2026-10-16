import Foundation
import AutomationKit

public enum AgentPhase: String, Codable, Sendable {
    case idle, planning, executing, awaitingApproval, paused, completed, failed, stopped, needsInput
}

public struct ActivityEntry: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case plan, step, action, verify, model, tool, recovery, approval, error, info, result, vision
    }
    public var id = UUID()
    public var timestamp = Date()
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var route: ExecutionRoute?
    public var success: Bool?
    public var durationMs: Double?
    public var stepID: Int?

    public init(kind: Kind, title: String, detail: String? = nil, route: ExecutionRoute? = nil, success: Bool? = nil, durationMs: Double? = nil, stepID: Int? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.route = route
        self.success = success
        self.durationMs = durationMs
        self.stepID = stepID
    }
}

public struct ApprovalRequest: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case action, tool, screenshot }
    public var id = UUID()
    public var kind: Kind
    public var title: String
    public var detail: String
    public var appName: String?
    public var risk: RiskLevel
    public var reasons: [String]

    public init(kind: Kind, title: String, detail: String, appName: String?, risk: RiskLevel, reasons: [String]) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.appName = appName
        self.risk = risk
        self.reasons = reasons
    }
}

public enum ApprovalDecision: Sendable {
    case approve, reject, stop
}

public struct TaskResult: Sendable {
    public enum Status: String, Codable, Sendable { case completed, failed, stopped, needsInput }
    public var status: Status
    public var summary: String
    public var error: String?
    public var plan: Plan?
    public var metrics: TaskMetrics.Snapshot
    public var durationMs: Double
}

/// Callbacks from the orchestrator to whoever runs it (the notch UI or nbctl).
public struct AgentCallbacks: Sendable {
    public var phase: @Sendable (AgentPhase, String) -> Void
    public var log: @Sendable (ActivityEntry) -> Void
    public var plan: @Sendable (Plan, Int) -> Void
    public var approve: @Sendable (ApprovalRequest) async -> ApprovalDecision

    public init(phase: @escaping @Sendable (AgentPhase, String) -> Void = { _, _ in },
                log: @escaping @Sendable (ActivityEntry) -> Void = { _ in },
                plan: @escaping @Sendable (Plan, Int) -> Void = { _, _ in },
                approve: @escaping @Sendable (ApprovalRequest) async -> ApprovalDecision = { _ in .reject }) {
        self.phase = phase
        self.log = log
        self.plan = plan
        self.approve = approve
    }
}
