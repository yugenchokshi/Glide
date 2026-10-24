import Foundation
import UserNotifications
import AgentKit

/// macOS notifications for background jobs that need you while the notch is collapsed
/// (approvals, confirmations, questions, finished jobs). Clicking one opens the job in
/// Settings › Jobs.
///
/// Authorization is requested lazily, the first time a job actually has something to say,
/// so people who never run jobs never see the permission prompt.
@MainActor
final class JobNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = JobNotifier()

    /// Opens a job's detail (set by the app delegate).
    var onOpenJob: ((String) -> Void)?

    private var authorization: Task<Bool, Never>?
    /// What was last announced per job, so repeated attention callbacks for the same state
    /// (e.g. `onAttentionNeeded` and `onJobFinished` for one finish) notify once.
    private var lastAnnounced: [String: String] = [:]

    /// `UNUserNotificationCenter.current()` raises an exception in a process without an app
    /// bundle (`swift run Glide`), so notifications are only used from Glide.app.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// Becomes the notification delegate so banners show while Glide is frontmost and clicks
    /// route back here. Doesn't ask for permission.
    func install() {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Posts a notification for a job's current state, once per distinct state.
    func notify(_ job: JobRecord, approval: ApprovalRequest?) {
        guard Self.isAvailable else { return }
        let signature = [job.status.rawValue, approval?.id.uuidString ?? "", job.lastError ?? "", job.summary ?? ""].joined(separator: "|")
        guard lastAnnounced[job.id] != signature else { return }
        if lastAnnounced.count > 500 { lastAnnounced.removeAll() }
        lastAnnounced[job.id] = signature

        let (title, body) = Self.text(for: job, approval: approval)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = approval != nil || job.status == .needsInput ? .default : nil
        content.userInfo = ["jobID": job.id]
        content.threadIdentifier = "glide.job.\(job.id)"
        // One live notification per job: a newer state replaces the older banner.
        let request = UNNotificationRequest(identifier: "glide.job.\(job.id)", content: content, trigger: nil)
        Task {
            guard await self.ensureAuthorized() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    static func text(for job: JobRecord, approval: ApprovalRequest?) -> (String, String) {
        func clip(_ s: String) -> String { s.count > 220 ? String(s.prefix(219)) + "…" : s }
        if let approval { return ("Glide needs your OK", clip("\(job.title): \(approval.title)")) }
        switch job.status {
        case .awaitingConfirmation:
            let estimate = job.plan?.estimate.map(JobFormat.estimate) ?? "Review the plan to start it."
            return ("Ready to start: \(job.title)", clip(estimate))
        case .completed: return ("Job finished", clip("\(job.title). \(job.summary ?? job.displayLine)"))
        case .failed: return ("Job failed", clip("\(job.title). \(job.lastError ?? job.displayLine)"))
        case .stopped: return ("Job stopped", clip(job.title))
        case .needsInput: return ("A job needs you", clip("\(job.title). \(job.lastError ?? job.displayLine)"))
        default: return (job.title, clip(job.displayLine))
        }
    }

    /// Asks once; later calls reuse the answer (or the in-flight request).
    private func ensureAuthorized() async -> Bool {
        if let authorization { return await authorization.value }
        let task = Task<Bool, Never> {
            let center = UNUserNotificationCenter.current()
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return true
            case .denied: return false
            case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            @unknown default: return false
            }
        }
        authorization = task
        let granted = await task.value
        // If the user later enables notifications in System Settings, ask the system again.
        if !granted { authorization = nil }
        return granted
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["jobID"] as? String else { return }
        await MainActor.run { JobNotifier.shared.onOpenJob?(id) }
    }
}
