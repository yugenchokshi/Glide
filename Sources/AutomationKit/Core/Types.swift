import Foundation
import CoreGraphics

/// Where an element in the unified graph came from.
public enum ElementSource: String, Codable, Sendable {
    case accessibility
    case dom
    case ocr
    case vision
}

/// A running application the engine can observe or act on.
public struct AppInfo: Codable, Sendable, Hashable {
    public var name: String
    public var bundleID: String?
    public var pid: pid_t

    public init(name: String, bundleID: String?, pid: pid_t) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
    }
}

/// One normalized interactive (or readable) element. Coordinates are global screen
/// points with a top-left origin, the same space AX and CGEvent use.
public struct UIElementNode: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var role: String
    public var axRole: String
    public var subrole: String?
    public var name: String
    public var value: String?
    public var placeholder: String?
    public var identifier: String?
    public var frame: CGRect
    public var actions: [String]
    public var enabled: Bool
    public var focused: Bool
    public var selected: Bool
    public var isSecure: Bool
    public var parentID: String?
    public var context: String?
    public var depth: Int
    public var source: ElementSource
    public var confidence: Double
    public var fingerprint: String

    public init(
        id: String = "", role: String, axRole: String, subrole: String? = nil, name: String,
        value: String? = nil, placeholder: String? = nil, identifier: String? = nil,
        frame: CGRect, actions: [String] = [], enabled: Bool = true, focused: Bool = false,
        selected: Bool = false, isSecure: Bool = false, parentID: String? = nil,
        context: String? = nil, depth: Int = 0, source: ElementSource = .accessibility,
        confidence: Double = 1, fingerprint: String = ""
    ) {
        self.id = id
        self.role = role
        self.axRole = axRole
        self.subrole = subrole
        self.name = name
        self.value = value
        self.placeholder = placeholder
        self.identifier = identifier
        self.frame = frame
        self.actions = actions
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.isSecure = isSecure
        self.parentID = parentID
        self.context = context
        self.depth = depth
        self.source = source
        self.confidence = confidence
        self.fingerprint = fingerprint
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    public var isInteractive: Bool { ElementRoles.interactive.contains(role) }

    /// Best human label: name, then placeholder, then identifier.
    public var label: String {
        if !name.isEmpty { return name }
        if let placeholder, !placeholder.isEmpty { return placeholder }
        return identifier ?? ""
    }
}

public enum ElementRoles {
    public static let interactive: Set<String> = [
        "button", "checkbox", "radio", "textfield", "textarea", "searchfield", "combobox",
        "popup", "menubutton", "link", "tab", "slider", "menuitem", "menubaritem", "cell",
        "row", "disclosure", "stepper", "switch", "segment", "image-button", "outline-row",
        "colorwell", "incrementor", "dockitem",
    ]
    public static let textInput: Set<String> = ["textfield", "textarea", "searchfield", "combobox"]
}

/// How an action identifies what it acts on.
public enum ElementTarget: Codable, Sendable, Hashable, CustomStringConvertible {
    /// An element id from the current observation.
    case element(String)
    /// A natural-language description to resolve against the graph (and OCR/vision as fallback).
    case description(String)
    /// A verified global screen coordinate.
    case point(CGPoint)

    public var description: String {
        switch self {
        case .element(let id): return "element \(id)"
        case .description(let text): return "\"\(text)\""
        case .point(let p): return "(\(Int(p.x)), \(Int(p.y)))"
        }
    }
}

public enum ScrollDirection: String, Codable, Sendable, CaseIterable {
    case up, down, left, right
}

public enum WaitCondition: Codable, Sendable, Hashable {
    case seconds(Double)
    case appFrontmost(String)
    case elementExists(String)
    case elementGone(String)
    case windowTitleContains(String)
}

public enum MouseButton: String, Codable, Sendable {
    case left, right
}

/// The single action vocabulary every route (deterministic, model, skill) compiles to.
public enum ComputerAction: Codable, Sendable, Hashable {
    case click(ElementTarget)
    case doubleClick(ElementTarget)
    case rightClick(ElementTarget)
    case typeText(String, into: ElementTarget?, clearFirst: Bool, submit: Bool)
    case keyPress(KeyCombination)
    case scroll(ScrollDirection, amount: Double, at: ElementTarget?)
    case drag(ElementTarget, ElementTarget)
    case focus(ElementTarget)
    case setValue(ElementTarget, String)
    case selectText(ElementTarget)
    case menu([String])
    case launchApp(String)
    case activateApp(String)
    case openURL(String, app: String?)
    case waitFor(WaitCondition)

    /// Present-progressive phrase for the notch ("Clicking “New Note”").
    public var humanDescription: String {
        switch self {
        case .click(let t): return "Clicking \(t.humanName)"
        case .doubleClick(let t): return "Double-clicking \(t.humanName)"
        case .rightClick(let t): return "Right-clicking \(t.humanName)"
        case .typeText(let text, _, _, _):
            let preview = text.count > 32 ? String(text.prefix(32)) + "…" : text
            return "Typing “\(preview.replacingOccurrences(of: "\n", with: " "))”"
        case .keyPress(let k): return "Pressing \(k.displayString)"
        case .scroll(let d, _, _): return "Scrolling \(d.rawValue)"
        case .drag(let a, let b): return "Dragging \(a.humanName) to \(b.humanName)"
        case .focus(let t): return "Focusing \(t.humanName)"
        case .setValue(let t, _): return "Setting \(t.humanName)"
        case .selectText(let t): return "Selecting text in \(t.humanName)"
        case .menu(let path): return "Choosing \(path.joined(separator: " › "))"
        case .launchApp(let app): return "Opening \(app)"
        case .activateApp(let app): return "Switching to \(app)"
        case .openURL(let url, _): return "Opening \(url)"
        case .waitFor: return "Waiting"
        }
    }

    public var injectsInput: Bool {
        switch self {
        case .waitFor: return false
        default: return true
        }
    }
}

extension ElementTarget {
    var humanName: String {
        switch self {
        case .element(let id): return id
        case .description(let d): return "“\(d)”"
        case .point(let p): return "(\(Int(p.x)), \(Int(p.y)))"
        }
    }
}

public enum AutomationError: Error, LocalizedError, Sendable, Equatable {
    case accessibilityNotTrusted
    case screenRecordingNotGranted
    case appNotFound(String)
    case appNotRunning(String)
    case noFocusedWindow(String)
    case elementNotFound(String)
    case elementStale(String)
    case elementDisabled(String)
    case targetOffscreen(String)
    case invalidKeyCombination(String)
    case menuItemNotFound(String)
    case stopped
    case blockedBySafety(String)
    case verificationFailed(String)
    case captureFailed(String)
    case timeout(String)
    case appleScript(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Glide needs Accessibility permission (System Settings › Privacy & Security › Accessibility)."
        case .screenRecordingNotGranted:
            return "Screen Recording permission is needed to see this window."
        case .appNotFound(let n): return "Couldn't find an app named “\(n)”."
        case .appNotRunning(let n): return "“\(n)” isn't running."
        case .noFocusedWindow(let n): return "“\(n)” has no open window."
        case .elementNotFound(let d): return "Couldn't find \(d) on screen."
        case .elementStale(let d): return "\(d) changed before it could be used."
        case .elementDisabled(let d): return "\(d) is disabled."
        case .targetOffscreen(let d): return "\(d) is outside the visible screen."
        case .invalidKeyCombination(let k): return "Unknown key combination “\(k)”."
        case .menuItemNotFound(let p): return "Menu item “\(p)” not found."
        case .stopped: return "Stopped."
        case .blockedBySafety(let r): return r
        case .verificationFailed(let r): return "Couldn't confirm the result: \(r)"
        case .captureFailed(let r): return "Screen capture failed: \(r)"
        case .timeout(let r): return "Timed out: \(r)"
        case .appleScript(let r): return "Automation script failed: \(r)"
        }
    }
}
