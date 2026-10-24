import Foundation
import CoreGraphics

/// The one real cursor and keyboard, shared by every job and quick task. Only the holder of
/// the lease may run on-screen (gui/native) steps; everything else (commands, web, browser
/// tabs, data) runs without it, so several jobs can work at once while at most one of them is
/// moving the pointer.
///
/// Quick tasks take the lease with `priority: true` because the user is waiting on them: they
/// go ahead of queued jobs (a job holding the lease finishes its current step first) and skip
/// the idle check.
public actor ScreenLease {
    public static let shared = ScreenLease()

    public enum LeaseError: Error, LocalizedError, Sendable, Equatable {
        /// Background jobs aren't allowed to use the screen (`ScreenUse.never`).
        case blocked(String)

        public var errorDescription: String? {
            switch self {
            case .blocked(let m): return m
            }
        }
    }

    /// Seconds since the user's last mouse or keyboard input.
    public typealias IdleProbe = @Sendable () -> Double

    private struct Waiter {
        let id: UUID
        let owner: String
        let priority: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var holder: String?
    private var depth = 0
    private var waiters: [Waiter] = []
    /// When the current/last hold started and ended; Glide's own synthetic input during a hold
    /// mustn't count as the user being active.
    private var heldSince: Date?
    private var lastHeld: (start: Date, end: Date)?
    private let idleProbe: IdleProbe
    private let pollInterval: Double

    /// - Parameters:
    ///   - idleProbe: seconds since the user's last input (defaults to the HID system state).
    ///   - pollInterval: how often `.whenIdle` re-checks the user's idle time.
    public init(idleProbe: IdleProbe? = nil, pollInterval: Double = 1) {
        self.idleProbe = idleProbe ?? ScreenLease.systemIdleSeconds
        self.pollInterval = max(0.01, pollInterval)
    }

    /// Who holds the lease now (nil when free).
    public var currentHolder: String? { holder }
    public var queueLength: Int { waiters.count }

    /// Waits for the lease. In `.whenIdle` mode it also waits until the user has been idle for
    /// at least `idleSeconds`; in `.never` mode it throws `LeaseError.blocked`. Cancellation
    /// (stopping the job) throws `CancellationError` and leaves the queue.
    ///
    /// The same owner may acquire again while holding it (calls nest; release each).
    public func acquire(owner: String, screenUse: ScreenUse = .always, idleSeconds: Double = 0, priority: Bool = false) async throws {
        if !priority, screenUse == .never {
            throw LeaseError.blocked("This step needs the screen, but background jobs aren't allowed to use it (Settings › Jobs › Screen use). Change that setting or do this part yourself.")
        }
        if holder == owner {
            depth += 1
            return
        }
        let mustBeIdle = !priority && screenUse == .whenIdle && idleSeconds > 0
        while true {
            if mustBeIdle { try await waitForIdle(idleSeconds) }
            try await take(owner: owner, priority: priority)
            // The user may have come back while we queued; give the screen back and wait again.
            if mustBeIdle, userIdleSeconds() < idleSeconds {
                release(owner: owner)
                continue
            }
            return
        }
    }

    /// Releases one hold. Releasing a lease you don't hold does nothing.
    public func release(owner: String) {
        guard holder == owner else { return }
        if depth > 1 { depth -= 1; return }
        depth = 0
        holder = nil
        if let start = heldSince { lastHeld = (start, Date()) }
        heldSince = nil
        handOff()
    }

    /// Runs `body` while holding the lease.
    public func withLease<T: Sendable>(owner: String, screenUse: ScreenUse = .always, idleSeconds: Double = 0, priority: Bool = false,
                                       _ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire(owner: owner, screenUse: screenUse, idleSeconds: idleSeconds, priority: priority)
        do {
            let value = try await body()
            release(owner: owner)
            return value
        } catch {
            release(owner: owner)
            throw error
        }
    }

    // MARK: - Internals

    private func take(owner: String, priority: Bool) async throws {
        if holder == nil, waiters.isEmpty || priority && !waiters.contains(where: \.priority) {
            grant(owner)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(id: id, owner: owner, priority: priority, continuation: c)
                if priority, let firstNormal = waiters.firstIndex(where: { !$0.priority }) {
                    waiters.insert(waiter, at: firstNormal)
                } else {
                    waiters.append(waiter)
                }
                // A release may have happened between the check above and now.
                if holder == nil { handOff() }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func grant(_ owner: String) {
        holder = owner
        depth = 1
        heldSince = Date()
    }

    private func handOff() {
        guard holder == nil, !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        grant(next.owner)
        next.continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: i)
        w.continuation.resume(throwing: CancellationError())
    }

    private func waitForIdle(_ seconds: Double) async throws {
        while userIdleSeconds() < seconds {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(pollInterval))
        }
    }

    /// The user's idle time, ignoring input Glide itself synthesized while it held the lease:
    /// if the last input event happened during a hold, the user has been idle at least since
    /// that hold began (they had to be idle for the lease to be granted).
    private func userIdleSeconds() -> Double {
        let idle = idleProbe()
        let now = Date()
        let lastEvent = now.addingTimeInterval(-idle)
        if let start = heldSince, lastEvent >= start.addingTimeInterval(-0.25) {
            return max(idle, now.timeIntervalSince(start))
        }
        if let held = lastHeld, lastEvent >= held.start.addingTimeInterval(-0.25), lastEvent <= held.end.addingTimeInterval(0.5) {
            return max(idle, now.timeIntervalSince(held.start))
        }
        return idle
    }

    /// Seconds since the last mouse or keyboard event in the login session.
    public static let systemIdleSeconds: IdleProbe = {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                    .rightMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }
}
