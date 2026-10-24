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
    public static let shared: ScreenLease = {
        // Read once, on first use (the main actor in the app and glidectl), so the runtime's
        // lazily made executor is never first created from the lease's own thread.
        let input = AutomationRuntime.shared.executor.input
        return ScreenLease(lastSyntheticInput: { input.lastPost })
    }()

    public enum LeaseError: Error, LocalizedError, Sendable, Equatable {
        /// Background jobs aren't allowed to use the screen (`ScreenUse.never`).
        case blocked(String)

        public var errorDescription: String? {
            switch self {
            case .blocked(let m): return m
            }
        }
    }

    /// Seconds since the last mouse or keyboard input (the user's or Glide's own).
    public typealias IdleProbe = @Sendable () -> Double
    /// When Glide last posted synthetic mouse or keyboard input (`InputSynthesizer.lastPost`).
    public typealias SyntheticInputProbe = @Sendable () -> Date

    private struct Waiter {
        let id: UUID
        let owner: String
        let priority: Bool
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// An input event this close to one of Glide's posts is taken to be that post.
    static let syntheticWindow: Double = 0.5

    private var holder: String?
    private var depth = 0
    private var waiters: [Waiter] = []
    /// The newest input seen that Glide didn't post. The system only reports when the very last
    /// event happened, so once one of Glide's own events is the latest, this is the evidence of
    /// when the user last did something.
    private var lastUserInput: Date?
    /// Samples the idle time while the lease is held, to catch the user between Glide's actions.
    private var sampler: Task<Void, Never>?
    private let idleProbe: IdleProbe
    private let lastSyntheticInput: SyntheticInputProbe
    private let pollInterval: Double

    /// - Parameters:
    ///   - idleProbe: seconds since the last input (defaults to the HID system state).
    ///   - lastSyntheticInput: when Glide last posted input itself; without it, all input counts
    ///     as the user's.
    ///   - pollInterval: how often `.whenIdle` re-checks the user's idle time.
    public init(idleProbe: IdleProbe? = nil, lastSyntheticInput: SyntheticInputProbe? = nil, pollInterval: Double = 1) {
        self.idleProbe = idleProbe ?? ScreenLease.systemIdleSeconds
        self.lastSyntheticInput = lastSyntheticInput ?? { .distantPast }
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
        sampler?.cancel()
        sampler = nil
        handOff()
    }

    /// The user's idle time as the lease judges it, with Glide's own input left out. A job step
    /// waiting for the user to leave the Mac alone goes by this too: by the raw idle time,
    /// another job's clicks and keystrokes would keep it waiting for as long as that job has
    /// on-screen work, while the lease kept handing that job the screen.
    func userIdleTime() -> Double { userIdleSeconds() }

    /// Input known to be the user's (a job step's input monitor saw it), so it counts even
    /// when one of Glide's own events landed right after it and hid it from the idle time.
    func noteUserInput(at date: Date) {
        lastUserInput = max(lastUserInput ?? date, date)
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
        startSampling()
    }

    /// While the lease is held, Glide's input keeps becoming the latest event and hides the
    /// user's, so the idle time is sampled between Glide's actions: a user who comes back
    /// mid-step is still noticed by the next step's idle check.
    private func startSampling() {
        sampler?.cancel()
        let interval = min(pollInterval, 0.5)
        sampler = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let lease = self else { return }
                await lease.sample()
            }
        }
    }

    private func sample() {
        _ = userIdleSeconds()
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

    /// The user's idle time. Only input Glide actually posted is discounted, not everything
    /// during a hold: quick tasks hold the lease for their whole run, tool-only ones included,
    /// and the user is free to keep working meanwhile. When the latest event is one of Glide's,
    /// the user has been idle since the last input seen that wasn't; if none was seen, Glide's
    /// own event counts, which errs on the side of waiting.
    private func userIdleSeconds() -> Double {
        let idle = idleProbe()
        guard idle.isFinite else { return idle }
        let now = Date()
        let lastEvent = now.addingTimeInterval(-idle)
        guard abs(lastEvent.timeIntervalSince(lastSyntheticInput())) <= Self.syntheticWindow else {
            lastUserInput = max(lastUserInput ?? lastEvent, lastEvent)
            return idle
        }
        guard let user = lastUserInput else { return idle }
        return max(idle, now.timeIntervalSince(user))
    }

    /// Seconds since the last mouse or keyboard event in the login session.
    public static let systemIdleSeconds: IdleProbe = {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                    .rightMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }
}
