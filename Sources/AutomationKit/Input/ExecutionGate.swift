import Foundation
import Synchronization

/// Shared stop/pause switch checked before every injected input event. Stopping is
/// immediate: the next checkpoint throws and no further events are posted.
public final class ExecutionGate: Sendable {
    public enum State: Int, Sendable { case running, paused, stopped }
    private let state = Mutex<State>(.running)

    public init() {}

    public var current: State { state.withLock { $0 } }
    public var isStopped: Bool { current == .stopped }
    public var isPaused: Bool { current == .paused }

    public func stop() { state.withLock { $0 = .stopped } }
    public func pause() { state.withLock { if $0 == .running { $0 = .paused } } }
    public func resume() { state.withLock { if $0 == .paused { $0 = .running } } }
    public func reset() { state.withLock { $0 = .running } }

    /// Throws if stopped. Used inside synchronous event-posting loops.
    public func checkStopped() throws {
        if isStopped { throw AutomationError.stopped }
    }

    /// Throws if stopped; suspends while paused.
    public func checkpoint() async throws {
        while true {
            switch current {
            case .running: return
            case .stopped: throw AutomationError.stopped
            case .paused:
                try? await Task.sleep(for: .milliseconds(60))
                if Task.isCancelled { throw AutomationError.stopped }
            }
        }
    }
}
