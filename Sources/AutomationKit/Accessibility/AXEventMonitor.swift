import Foundation
import ApplicationServices

/// Listens for AX notifications on a dedicated run-loop thread and keeps a per-app change
/// counter. Snapshots are cached until the counter moves, and verification waits on it
/// instead of sleeping for fixed delays.
public final class AXEventMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [pid_t: UInt64] = [:]
    private var observers: [pid_t: (observer: AXObserver, box: Unmanaged<PIDBox>)] = [:]
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    static let notifications: [String] = [
        kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification, kAXValueChangedNotification,
        kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification,
        kAXLayoutChangedNotification, kAXSheetCreatedNotification, kAXCreatedNotification,
        kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXSelectedTextChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification, kAXRowCountChangedNotification,
    ]

    public init() {}

    private func ensureThread() -> CFRunLoop {
        lock.lock()
        if let rl = runLoop { lock.unlock(); return rl }
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var captured: CFRunLoop?
        let t = Thread {
            captured = CFRunLoopGetCurrent()
            // A port keeps the run loop alive before any observer is attached.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "dev.glide.ax-events"
        t.qualityOfService = .userInitiated
        t.start()
        ready.wait()
        thread = t
        runLoop = captured
        lock.unlock()
        return captured!
    }

    public func watch(pid: pid_t) {
        if lock.withLock({ observers[pid] != nil }) { return }
        let rl = ensureThread()
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let box = Unmanaged<PIDBox>.fromOpaque(refcon).takeUnretainedValue()
            box.monitor?.bump(pid: box.pid)
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let box = Unmanaged.passRetained(PIDBox(pid: pid, monitor: self))
        for n in Self.notifications {
            AXObserverAddNotification(observer, appEl, n as CFString, box.toOpaque())
        }
        CFRunLoopAddSource(rl, AXObserverGetRunLoopSource(observer), .defaultMode)
        lock.withLock { observers[pid] = (observer, box) }
    }

    public func unwatch(pid: pid_t) {
        guard let entry = lock.withLock({ observers.removeValue(forKey: pid) }) else { return }
        if let rl = lock.withLock({ runLoop }) {
            CFRunLoopRemoveSource(rl, AXObserverGetRunLoopSource(entry.observer), .defaultMode)
        }
        entry.box.release()
    }

    fileprivate func bump(pid: pid_t) {
        lock.withLock { generations[pid, default: 0] &+= 1 }
    }

    public func generation(for pid: pid_t) -> UInt64 {
        lock.withLock { generations[pid, default: 0] }
    }

    /// Marks an app as changed (used after injecting input whose effect AX might not report).
    public func invalidate(pid: pid_t) { bump(pid: pid) }

    /// Waits until the app reports a change after `since`, or the timeout elapses.
    public func waitForChange(pid: pid_t, since: UInt64, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if generation(for: pid) != since { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return generation(for: pid) != since
    }
}

final class PIDBox {
    let pid: pid_t
    weak var monitor: AXEventMonitor?
    init(pid: pid_t, monitor: AXEventMonitor) {
        self.pid = pid
        self.monitor = monitor
    }
}
