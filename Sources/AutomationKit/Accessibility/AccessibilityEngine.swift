import Foundation
import AppKit
import ApplicationServices
import os

/// Reads macOS accessibility trees into the unified element graph, with snapshot caching
/// invalidated by AX notifications.
public final class AccessibilityEngine: @unchecked Sendable {
    public struct Limits: Sendable {
        public var maxNodes = 1800
        public var maxDepth = 45
        public var timeBudget: TimeInterval = 0.6
        public var messagingTimeout: Float = 1.5
        public init() {}
    }

    public let graph = ElementGraph()
    public var limits = Limits()
    public let monitor = AXEventMonitor()
    private let lock = NSLock()
    private var cache: (pid: pid_t, generation: UInt64, observation: ScreenObservation)?
    private var enhancedPIDs: Set<pid_t> = []
    private let log = Logger(subsystem: "dev.glide", category: "accessibility")

    /// Apps that should never be observed or acted on (e.g. Glide itself).
    public var excludedPIDs: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]

    public init() {}

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public func appElement(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, limits.messagingTimeout)
        return el
    }

    /// The frontmost regular app other than Glide.
    public func frontmostApp() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if excludedPIDs.contains(app.processIdentifier) { return nil }
        return AppInfo(name: app.localizedName ?? "App", bundleID: app.bundleIdentifier, pid: app.processIdentifier)
    }

    public func runningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !excludedPIDs.contains($0.processIdentifier) }
            .map { AppInfo(name: $0.localizedName ?? "App", bundleID: $0.bundleIdentifier, pid: $0.processIdentifier) }
    }

    /// Chromium and Electron only build their accessibility tree when asked to.
    func enableEnhancedAccessibility(_ pid: pid_t, appEl: AXUIElement) {
        let needs = lock.withLock { !enhancedPIDs.contains(pid) }
        guard needs else { return }
        AX.set(appEl, "AXManualAccessibility", kCFBooleanTrue)
        if let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           bundle.contains("chrome") || bundle.contains("Chrome") || bundle.contains("electron") || bundle.contains("brave") || bundle.contains("edgemac") || bundle.contains("company.thebrowser") {
            AX.set(appEl, "AXEnhancedUserInterface", kCFBooleanTrue)
        }
        lock.withLock { _ = enhancedPIDs.insert(pid) }
    }

    public func focusedWindow(pid: pid_t) -> AXUIElement? {
        let appEl = appElement(pid)
        if let w = AX.element(appEl, kAXFocusedWindowAttribute) { return w }
        if let w = AX.element(appEl, kAXMainWindowAttribute) { return w }
        return AX.elements(appEl, kAXWindowsAttribute).first
    }

    public func windows(pid: pid_t) -> [(title: String?, frame: CGRect?, ref: AXRef)] {
        AX.elements(appElement(pid), kAXWindowsAttribute).map {
            (AX.string($0, kAXTitleAttribute), AX.frame($0), AXRef($0))
        }
    }

    /// Snapshot the focused window (plus any sheet/dialog) of an app. Returns a cached snapshot
    /// when no AX notification has arrived since it was taken.
    public func observe(_ app: AppInfo, useCache: Bool = true) throws -> ScreenObservation {
        guard Self.isTrusted else { throw AutomationError.accessibilityNotTrusted }
        guard !excludedPIDs.contains(app.pid) else { throw AutomationError.blockedBySafety("Glide doesn't operate on its own windows.") }
        monitor.watch(pid: app.pid)
        let generation = monitor.generation(for: app.pid)
        if useCache, let c = lock.withLock({ cache }), c.pid == app.pid, c.generation == generation,
           Date().timeIntervalSince(c.observation.timestamp) < 3 {
            return c.observation
        }
        let start = CFAbsoluteTimeGetCurrent()
        let appEl = appElement(app.pid)
        enableEnhancedAccessibility(app.pid, appEl: appEl)

        var raws: [RawElement] = []
        var truncated = false
        let window = focusedWindow(pid: app.pid)
        let windowTitle = window.flatMap { AX.string($0, kAXTitleAttribute) }
        let windowFrame = window.flatMap { AX.frame($0) }
        let deadline = start + limits.timeBudget

        if let window {
            truncated = walk(window, pathKey: "w", depth: 0, context: nil, clip: windowFrame, deadline: deadline, into: &raws)
        }
        // Floating panels / dialogs that aren't the focused window (e.g. save sheets in separate windows).
        for extra in AX.elements(appEl, kAXWindowsAttribute) where window == nil || !CFEqual(extra, window!) {
            let sub = AX.string(extra, kAXSubroleAttribute)
            if sub == kAXDialogSubrole || sub == kAXFloatingWindowSubrole || sub == "AXSystemDialog" {
                truncated = walk(extra, pathKey: "d", depth: 0, context: AX.string(extra, kAXTitleAttribute), clip: AX.frame(extra), deadline: deadline, into: &raws) || truncated
            }
        }
        let menuTitles = menuBarTitles(appEl)
        let (nodes, refs) = graph.assignIDs(raws)
        let focusedID: String? = {
            guard let focused = AX.element(appEl, kAXFocusedUIElementAttribute) else { return nil }
            return refs.first(where: { CFEqual($0.value.element, focused) })?.key
        }()
        let obs = ScreenObservation(
            app: app, windowTitle: windowTitle, windowFrame: windowFrame, elements: nodes,
            focusedElementID: focusedID, durationMs: (CFAbsoluteTimeGetCurrent() - start) * 1000,
            truncated: truncated, refs: refs, menuBarTitles: menuTitles)
        lock.withLock { cache = (app.pid, generation, obs) }
        log.debug("observed \(app.name, privacy: .public): \(nodes.count) nodes in \(obs.durationMs, format: .fixed(precision: 1))ms")
        return obs
    }

    public func invalidateCache() { lock.withLock { cache = nil } }

    /// Depth-first walk collecting meaningful nodes. Returns true if limits truncated the walk.
    private func walk(_ element: AXUIElement, pathKey: String, depth: Int, context: String?, clip: CGRect?, deadline: CFAbsoluteTime, into out: inout [RawElement]) -> Bool {
        if out.count >= limits.maxNodes || depth > limits.maxDepth || CFAbsoluteTimeGetCurrent() > deadline { return true }
        guard let a = AX.attributes(of: element) else { return false }
        let frame: CGRect = {
            guard let p = a.position, let s = a.size else { return .zero }
            return CGRect(origin: p, size: s)
        }()
        // Skip subtrees entirely outside the window (scrolled-away content).
        if let clip, frame != .zero, frame.width > 0, frame.height > 0, !frame.intersects(clip.insetBy(dx: -4, dy: -4)) {
            return false
        }
        let actions = keepActions(for: a.role) ? AX.actions(element) : []
        let role = AX.normalizedRole(role: a.role, subrole: a.subrole, actions: actions)
        let isSecure = a.subrole == kAXSecureTextFieldSubrole
        var name = [a.title, a.label, a.desc].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        var value: String? = isSecure ? nil : a.value
        if role == "text", name.isEmpty, let v = value { name = v; value = nil }
        if name.isEmpty, ElementRoles.interactive.contains(role) {
            switch a.subrole {
            case "AXCloseButton": name = "Close window"
            case "AXMinimizeButton": name = "Minimize window"
            case "AXZoomButton": name = "Zoom window"
            case "AXFullScreenButton": name = "Full screen"
            default: break
            }
        }
        if (role == "button" || role == "link" || role == "cell" || role == "row" || role == "outline-row" || role == "menuitem"), name.isEmpty {
            name = childText(a.children)
        }
        let meaningful = isMeaningful(role: role, name: name, value: value, actions: actions, frame: frame)
        var truncated = false
        let myKey = "\(pathKey)/\(role):\(name.prefix(24))"
        if meaningful {
            let node = UIElementNode(
                role: role, axRole: a.role, subrole: a.subrole, name: name,
                value: value.map { String($0.prefix(4000)) }, placeholder: a.placeholder,
                identifier: a.identifier, frame: frame, actions: actions, enabled: a.enabled,
                focused: a.focused, selected: a.selected, isSecure: isSecure, context: context,
                depth: depth, source: .accessibility, confidence: 1)
            out.append(RawElement(node: node, ref: AXRef(element), pathKey: myKey))
        }
        // Containers with a title give context to their descendants ("in Toolbar").
        let childContext: String? = {
            if ["group", "toolbar", "sheet", "tabgroup", "list", "scrollarea", "window"].contains(role), !name.isEmpty { return name }
            return context
        }()
        // Don't descend into controls whose children are just their own label.
        if ["button", "checkbox", "radio", "textfield", "popup", "slider", "menubutton", "switch", "searchfield", "image"].contains(role) {
            return false
        }
        for (i, child) in a.children.enumerated() {
            if walk(child, pathKey: meaningful ? myKey : "\(pathKey)/\(i)", depth: depth + 1, context: childContext, clip: clip, deadline: deadline, into: &out) {
                truncated = true
                break
            }
        }
        return truncated
    }

    private func keepActions(for role: String) -> Bool {
        ![kAXStaticTextRole, kAXScrollAreaRole, kAXSplitGroupRole, kAXLayoutAreaRole, kAXScrollBarRole, kAXSplitterRole].contains(role)
    }

    private func isMeaningful(role: String, name: String, value: String?, actions: [String], frame: CGRect) -> Bool {
        if frame.width < 1 || frame.height < 1 { return false }
        if ElementRoles.interactive.contains(role) || ElementRoles.textInput.contains(role) { return true }
        switch role {
        case "text", "heading": return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "image": return !name.isEmpty
        case "sheet", "webarea": return true
        case "group", "toolbar", "scrollarea", "list", "window", "splitgroup", "tabgroup", "segmented", "layoutarea", "unknown":
            return actions.contains(kAXPressAction)
        default: return actions.contains(kAXPressAction) || actions.contains(kAXConfirmAction)
        }
    }

    private func childText(_ children: [AXUIElement]) -> String {
        for child in children.prefix(6) {
            if let a = AX.attributes(of: child) {
                if let t = [a.title, a.value, a.desc].compactMap({ $0 }).first(where: { !$0.isEmpty }) { return t }
                if let deeper = Optional(childText(a.children)), !deeper.isEmpty { return deeper }
            }
        }
        return ""
    }

    private func menuBarTitles(_ appEl: AXUIElement) -> [String] {
        guard let bar = AX.element(appEl, kAXMenuBarAttribute) else { return [] }
        return AX.elements(bar, kAXChildrenAttribute).compactMap { AX.string($0, kAXTitleAttribute) }.filter { !$0.isEmpty && $0 != "Apple" }
    }

    // MARK: - Element operations

    /// Re-reads an element's live frame and state. Returns nil if the element no longer exists.
    public func refresh(_ ref: AXRef) -> (frame: CGRect, enabled: Bool, value: String?, focused: Bool)? {
        guard let a = AX.attributes(of: ref.element), let p = a.position, let s = a.size else { return nil }
        return (CGRect(origin: p, size: s), a.enabled, a.subrole == kAXSecureTextFieldSubrole ? nil : a.value, a.focused)
    }

    /// Whether a live element still has the role and label it had when observed.
    public func matchesIdentity(_ ref: AXRef, node: UIElementNode) -> Bool {
        guard node.source == .accessibility, let a = AX.attributes(of: ref.element) else { return true }
        if !a.role.isEmpty, a.role != node.axRole { return false }
        let live = [a.title, a.label, a.desc].compactMap { $0 }.first(where: { !$0.isEmpty }) ?? ""
        // Labels derived from children or values (text nodes) aren't re-derived here; only compare direct labels.
        if !live.isEmpty, !node.name.isEmpty, live != node.name, node.role != "text" { return false }
        return true
    }

    public func value(of ref: AXRef) -> String? { AX.string(ref.element, kAXValueAttribute) }

    public func actions(of ref: AXRef) -> [String] { AX.actions(ref.element) }

    @discardableResult
    public func press(_ ref: AXRef) -> Bool { AX.perform(ref.element, kAXPressAction) == .success }

    @discardableResult
    public func showMenu(_ ref: AXRef) -> Bool { AX.perform(ref.element, kAXShowMenuAction) == .success }

    @discardableResult
    public func focus(_ ref: AXRef) -> Bool { AX.set(ref.element, kAXFocusedAttribute, kCFBooleanTrue) == .success }

    @discardableResult
    public func setValue(_ ref: AXRef, _ value: String) -> Bool {
        AX.set(ref.element, kAXValueAttribute, value as CFString) == .success
    }

    @discardableResult
    public func scrollToVisible(_ ref: AXRef) -> Bool { AX.perform(ref.element, "AXScrollToVisible") == .success }

    @discardableResult
    public func raiseWindow(pid: pid_t) -> Bool {
        guard let w = focusedWindow(pid: pid) else { return false }
        return AX.perform(w, kAXRaiseAction) == .success
    }

    /// Selects all text in an editable element through AX (falls back to caller using ⌘A).
    @discardableResult
    public func selectAllText(_ ref: AXRef) -> Bool {
        guard let v = value(of: ref) else { return false }
        var range = CFRange(location: 0, length: (v as NSString).length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return false }
        return AX.set(ref.element, kAXSelectedTextRangeAttribute, axRange) == .success
    }

    public func isSecureField(_ ref: AXRef) -> Bool {
        AX.string(ref.element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    /// The element under a screen point (global top-left coordinates).
    public func element(at point: CGPoint) -> AXRef? {
        let system = AXUIElementCreateSystemWide()
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &found) == .success, let found else { return nil }
        return AXRef(found)
    }

    public func pid(of ref: AXRef) -> pid_t? { AX.pid(ref.element) }

    /// True when `candidate` is `target` or one of its ancestors/descendants (i.e. a click at
    /// the point will land on the target).
    public func hitTestMatches(_ candidate: AXRef, target: AXRef) -> Bool {
        if candidate == target { return true }
        var cur: AXUIElement? = candidate.element
        for _ in 0..<12 {
            guard let c = cur else { break }
            if CFEqual(c, target.element) { return true }
            cur = AX.element(c, kAXParentAttribute)
        }
        cur = target.element
        for _ in 0..<4 {
            guard let c = cur else { break }
            cur = AX.element(c, kAXParentAttribute)
            if let p = cur, CFEqual(p, candidate.element) {
                // The point hits a container of the target: acceptable only for small containers.
                if let f = AX.frame(p), f.width * f.height < 250_000 { return true }
                return false
            }
        }
        return false
    }

    // MARK: - Menus

    /// Resolves a menu path like ["File", "Save…"] into the menu-bar item and the final item.
    public func menuItems(pid: pid_t, path: [String]) throws -> [AXRef] {
        let appEl = appElement(pid)
        guard let bar = AX.element(appEl, kAXMenuBarAttribute) else { throw AutomationError.menuItemNotFound(path.joined(separator: " › ")) }
        var refs: [AXRef] = []
        var container = bar
        for (i, title) in path.enumerated() {
            let items: [AXUIElement]
            if i == 0 {
                items = AX.elements(container, kAXChildrenAttribute)
            } else {
                // Children of a menu bar item / menu item is a single AXMenu holding the items.
                let menus = AX.elements(container, kAXChildrenAttribute)
                items = menus.flatMap { AX.elements($0, kAXChildrenAttribute) }
            }
            let target = ElementMatcher.normalize(title)
            let match = items.first(where: { ElementMatcher.normalize(AX.string($0, kAXTitleAttribute) ?? "") == target })
                ?? items.first(where: { ElementMatcher.similarity(target, ElementMatcher.normalize(AX.string($0, kAXTitleAttribute) ?? "")) > 0.85 })
            guard let match else { throw AutomationError.menuItemNotFound(path.prefix(i + 1).joined(separator: " › ")) }
            refs.append(AXRef(match))
            container = match
        }
        return refs
    }

    public func menuItemEnabled(_ ref: AXRef) -> Bool { AX.bool(ref.element, kAXEnabledAttribute) ?? true }
}
