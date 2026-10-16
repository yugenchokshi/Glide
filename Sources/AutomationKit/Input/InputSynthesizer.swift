import Foundation
import AppKit
import CoreGraphics

public enum CursorMode: String, Codable, Sendable, CaseIterable {
    /// Jump to targets with minimal delay.
    case fast
    /// Animate the cursor briefly so the user can follow along.
    case visual
}

/// Posts real mouse and keyboard events through Quartz. Every event is tagged so the
/// user-interference monitor can tell agent input from human input.
public final class InputSynthesizer: @unchecked Sendable {
    public static let eventTag: Int64 = 0x4E42_4E42 // "NBNB"

    public var cursorMode: CursorMode = .fast
    public let gate: ExecutionGate
    private let source: CGEventSource?

    public init(gate: ExecutionGate) {
        self.gate = gate
        source = CGEventSource(stateID: .hidSystemState)
    }

    public var cursorPosition: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func post(_ event: CGEvent?) throws {
        try gate.checkStopped()
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event.post(tap: .cghidEventTap)
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    // MARK: Mouse

    public func move(to target: CGPoint) throws {
        let start = cursorPosition
        let distance = hypot(target.x - start.x, target.y - start.y)
        let steps: Int
        let total: Double
        switch cursorMode {
        case .fast:
            steps = distance < 4 ? 1 : 4
            total = distance < 4 ? 0 : 0.035
        case .visual:
            steps = max(8, min(36, Int(distance / 25)))
            total = min(0.45, 0.15 + distance / 4000)
        }
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let p = CGPoint(x: start.x + (target.x - start.x) * eased, y: start.y + (target.y - start.y) * eased)
            try post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
            if steps > 1 { pause(total / Double(steps)) }
        }
    }

    public func click(at point: CGPoint, button: MouseButton = .left, count: Int = 1) throws {
        try move(to: point)
        pause(cursorMode == .visual ? 0.06 : 0.02)
        let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) = button == .left
            ? (.leftMouseDown, .leftMouseUp, .left)
            : (.rightMouseDown, .rightMouseUp, .right)
        for n in 1...count {
            let d = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: point, mouseButton: cgButton)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            d?.flags = []
            try post(d)
            pause(0.012)
            let u = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: point, mouseButton: cgButton)
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            u?.flags = []
            try post(u)
            if n < count { pause(0.05) }
        }
    }

    public func drag(from a: CGPoint, to b: CGPoint) throws {
        try move(to: a)
        pause(0.05)
        try post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
        pause(0.08)
        let steps = 24
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            try post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
            pause(0.012)
        }
        pause(0.08)
        try post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
    }

    /// Scrolls by "lines"; positive amount scrolls content in the given direction.
    public func scroll(_ direction: ScrollDirection, lines: Int, at point: CGPoint?) throws {
        if let point { try move(to: point) }
        let perEvent: Int32 = 3
        var remaining = max(1, lines)
        while remaining > 0 {
            let n = Int32(min(remaining, Int(perEvent)))
            var dy: Int32 = 0, dx: Int32 = 0
            switch direction {
            case .down: dy = -n
            case .up: dy = n
            case .left: dx = n
            case .right: dx = -n
            }
            try post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            remaining -= Int(n)
            pause(0.016)
        }
    }

    // MARK: Keyboard

    public func press(_ combo: KeyCombination) throws {
        let flags = combo.modifiers.cgFlags
        let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true)
        down?.flags = flags
        try post(down)
        pause(0.012)
        let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false)
        up?.flags = flags
        try post(up)
        pause(0.02)
    }

    /// Types arbitrary Unicode text as keyboard events, in small chunks.
    public func type(_ text: String) throws {
        var buffer: [Character] = []
        func flush() throws {
            guard !buffer.isEmpty else { return }
            let utf16 = Array(String(buffer).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.flags = []
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            try post(down)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.flags = []
            up?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            try post(up)
            buffer.removeAll()
            pause(cursorMode == .visual ? 0.03 : 0.008)
        }
        for ch in text {
            if ch == "\n" || ch == "\r\n" {
                try flush()
                try press(KeyCombination(keyCode: CGKeyCode(KeyCodes.code(for: "return")!), key: "return", modifiers: []))
            } else if ch == "\t" {
                try flush()
                try press(KeyCombination(keyCode: CGKeyCode(KeyCodes.code(for: "tab")!), key: "tab", modifiers: []))
            } else {
                buffer.append(ch)
                // Some apps drop characters from long unicode strings; keep chunks short.
                if String(buffer).utf16.count >= 12 { try flush() }
            }
        }
        try flush()
    }

    /// Inserts long text through the clipboard (⌘V), restoring the previous clipboard after.
    public func paste(_ text: String) throws {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        defer {
            Thread.sleep(forTimeInterval: 0.25)
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        try press(KeyCombination(keyCode: CGKeyCode(KeyCodes.code(for: "v")!), key: "v", modifiers: .command))
        pause(0.08)
    }
}
