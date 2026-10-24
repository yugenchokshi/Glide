import Foundation
import Observation

/// UI-facing owner of long-running jobs: the list, live progress, controls and approvals.
/// The app and glidectl talk to jobs only through this type; `JobRunner` does the work.
///
/// CONTRACT: the public API below is what the UI is built against. The job engine fills in
/// the implementation without changing these signatures.
@MainActor
@Observable
public final class JobCenter {
    public static let shared = JobCenter()

    /// All known jobs, newest first.
    public private(set) var jobs: [JobRecord] = []
    /// Approval requests waiting for the user, keyed by job id.
    public private(set) var pendingApprovals: [String: ApprovalRequest] = [:]

    /// A job needs the user (approval, question, stuck, finished). Argument: job id.
    public var onAttentionNeeded: ((String) -> Void)?
    /// A job reached completed/failed/stopped.
    public var onJobFinished: ((JobRecord) -> Void)?

    public init() {}

    /// The job currently running in the foreground of attention (most recently updated running job).
    public var activeJob: JobRecord? {
        jobs.filter { $0.status == .running || $0.status == .planning }.max { $0.updatedAt < $1.updatedAt }
    }

    public func job(_ id: String) -> JobRecord? { jobs.first { $0.id == id } }

    /// Call once at app launch: loads jobs, resumes interrupted ones (per settings) and
    /// schedules waiting ones.
    public func launch() {}

    /// Reloads the list from disk.
    public func reload() {}

    /// Plans a job from a request. Small jobs (under the confirmation thresholds) start right
    /// away when `autoStartIfSmall`; others stop at `.awaitingConfirmation` with an estimate.
    @discardableResult
    public func create(instruction: String, autoStartIfSmall: Bool = true) async -> JobRecord {
        JobRecord(title: instruction, instruction: instruction, status: .failed, folder: NSTemporaryDirectory())
    }

    /// Starts a job that is awaiting confirmation.
    public func start(_ id: String) {}
    public func pause(_ id: String) {}
    public func resume(_ id: String) {}
    public func stop(_ id: String) {}
    /// Re-queues failed items of a finished or paused job and resumes it.
    public func retryFailedItems(_ id: String) {}
    /// Deletes the job's record (its folder is moved to the Trash).
    public func delete(_ id: String) {}

    /// Answers a pending approval for a job.
    public func respond(jobID: String, decision: ApprovalDecision) {}

    public func items(_ jobID: String, limit: Int = 1000) -> [JobItem] { [] }
    public func events(_ jobID: String, limit: Int = 300) -> [ActivityEntry] { [] }

    /// Writes the job's result table(s) as CSV to `url`.
    public func exportResults(_ jobID: String, to url: URL) throws {}
}
