import Foundation
import CoreGraphics

/// Detects the human grabbing the mouse while the agent is driving it. Agent events carry
/// `InputSynthesizer.eventTag`; anything else that moves the pointer meaningfully counts as
/// the user taking over, and the orchestrator pauses.
public final class UserInterferenceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var handler: (@Sendable () -> Void)?
    private var accumulated: Double = 0
    private var lastEvent = Date.distantPast
    public var threshold: Double = 40

    public init() {}

    public var isRunning: Bool { lock.withLock { tap != nil } }

    public func start(onUserInput: @escaping @Sendable () -> Void) {
        stop()
        lock.withLock {
            handler = onUserInput
            accumulated = 0
        }
        let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.leftMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<UserInterferenceMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback, userInfo: refcon) else { return }
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loop: CFRunLoop?
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            let src = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "dev.glide.interference"
        thread.start()
        ready.wait()
        lock.withLock {
            tap = port
            runLoop = loop
        }
    }

    public func stop() {
        let (port, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { tap = nil; runLoop = nil; handler = nil }
            return (tap, runLoop)
        }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let loop { CFRunLoopStop(loop) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ tap }) { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        guard event.getIntegerValueField(.eventSourceUserData) != InputSynthesizer.eventTag else { return }
        var fire = false
        lock.withLock {
            if type == .leftMouseDown || type == .rightMouseDown {
                fire = true
            } else {
                let now = Date()
                if now.timeIntervalSince(lastEvent) > 0.4 { accumulated = 0 }
                lastEvent = now
                let dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
                accumulated += hypot(dx, dy)
                if accumulated > threshold { fire = true; accumulated = 0 }
            }
        }
        if fire, let h = lock.withLock({ handler }) { h() }
    }
}
