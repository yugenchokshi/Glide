import Foundation
import IOKit.pwr_mgt

/// Wakes waiting jobs when their time comes, and decides what happens on launch to jobs that
/// were running when Glide quit.
///
/// One timer for the earliest `nextWakeAt`; it re-checks at least every minute against the
/// wall clock, so sleeping the Mac or changing the clock can't make a wake-up get lost.
@MainActor
final class JobScheduler {
    /// Called with the id of each waiting job that is due.
    private let onDue: @MainActor (String) -> Void
    private let now: @Sendable () -> Date
    private let maxSleep: Double
    private var timer: Task<Void, Never>?
    private(set) var nextWake: Date?

    init(maxSleepSeconds: Double = 60, now: @escaping @Sendable () -> Date = { Date() }, onDue: @escaping @MainActor (String) -> Void) {
        self.onDue = onDue
        self.now = now
        self.maxSleep = max(0.05, maxSleepSeconds)
    }

    /// What to do with each job at launch.
    enum LaunchAction: Equatable {
        /// Continue it now (it was running and auto-resume is on, or it was queued).
        case resume
        /// It was running; mark it paused ("Interrupted").
        case markInterrupted
        /// It was being planned; planning can't continue.
        case markPlanningFailed
    }

    nonisolated static func launchActions(for jobs: [JobRecord], autoResume: Bool) -> [String: LaunchAction] {
        var out: [String: LaunchAction] = [:]
        for job in jobs {
            switch job.status {
            case .running:
                out[job.id] = autoResume ? .resume : .markInterrupted
            case .planning:
                out[job.id] = job.plan == nil ? .markPlanningFailed : (autoResume ? .resume : .markInterrupted)
            case .waiting where job.nextWakeAt == nil:
                // Queued behind other jobs when Glide quit.
                out[job.id] = .resume
            default:
                break
            }
        }
        return out
    }

    /// Waiting jobs whose wake time has passed.
    nonisolated static func dueJobs(_ jobs: [JobRecord], now: Date) -> [String] {
        jobs.filter { $0.status == .waiting && ($0.nextWakeAt.map { $0 <= now } ?? false) }
            .sorted { ($0.nextWakeAt ?? .distantPast) < ($1.nextWakeAt ?? .distantPast) }.map(\.id)
    }

    nonisolated static func earliestWake(_ jobs: [JobRecord]) -> Date? {
        jobs.filter { $0.status == .waiting }.compactMap(\.nextWakeAt).min()
    }

    /// Fires due jobs now and arms the timer for the next one.
    func reschedule(_ jobs: [JobRecord]) {
        timer?.cancel()
        timer = nil
        let current = now()
        let due = Self.dueJobs(jobs, now: current)
        for id in due { onDue(id) }
        // Waking can change a job: it starts, or turns out to have been put back to sleep until
        // later by another process. Look again, so that new wake time gets a timer too. Jobs
        // just fired are no longer waiting from our point of view.
        let latest = due.isEmpty ? jobs : (currentJobs?() ?? jobs)
        let remaining = latest.filter { $0.status == .waiting && ($0.nextWakeAt.map { $0 > current } ?? false) }
        guard let next = Self.earliestWake(remaining) else {
            nextWake = nil
            return
        }
        nextWake = next
        let delay = min(max(next.timeIntervalSince(current), 0.05), maxSleep)
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.timerFired()
        }
    }

    /// Set by the owner: returns the current list of jobs when the timer fires.
    var currentJobs: (@MainActor () -> [JobRecord])?

    private func timerFired() {
        timer = nil
        reschedule(currentJobs?() ?? [])
    }

    func stop() {
        timer?.cancel()
        timer = nil
        nextWake = nil
    }
}

/// Keeps the Mac from idle-sleeping while jobs run (the display may still sleep), released as
/// soon as no job is running.
public final class PowerAssertion: @unchecked Sendable {
    public static let shared = PowerAssertion()

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var held = false
    private let reason: String

    public init(reason: String = "Glide is running a background job") {
        self.reason = reason
    }

    public var isHeld: Bool { lock.withLock { held } }

    /// Takes or releases the assertion. Idempotent.
    public func update(active: Bool) {
        lock.withLock {
            if active, !held {
                var id: IOPMAssertionID = 0
                let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                         IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
                if result == kIOReturnSuccess {
                    assertionID = id
                    held = true
                }
            } else if !active, held {
                IOPMAssertionRelease(assertionID)
                assertionID = 0
                held = false
            }
        }
    }

    deinit {
        if held { IOPMAssertionRelease(assertionID) }
    }
}
