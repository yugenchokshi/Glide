import Foundation
import AppKit
import os

public struct ActionOutcome: Sendable {
    public var method: String
    public var detail: String
    public var target: UIElementNode?
    public var point: CGPoint?
    public var app: AppInfo?
    public var expectation: Expectation
    public var durationMs: Double
    public var generationBefore: UInt64?

    public init(method: String, detail: String, target: UIElementNode? = nil, point: CGPoint? = nil, app: AppInfo? = nil, expectation: Expectation = .none, durationMs: Double = 0, generationBefore: UInt64? = nil) {
        self.method = method
        self.detail = detail
        self.target = target
        self.point = point
        self.app = app
        self.expectation = expectation
        self.durationMs = durationMs
        self.generationBefore = generationBefore
    }
}

/// Executes `ComputerAction`s with real input. Targets are revalidated against live AX state
/// immediately before input is injected; a click goes through the real cursor when the hit
/// test confirms the target is under the point, and through the AX press action otherwise.
public final class NativeActionExecutor: @unchecked Sendable {
    public let accessibility: AccessibilityEngine
    public let input: InputSynthesizer
    public let apps: AppController
    public let gate: ExecutionGate
    private let log = Logger(subsystem: "dev.notchbuddy", category: "executor")

    /// Text longer than this is pasted (clipboard restored afterwards) instead of typed.
    public var pasteThreshold = 160

    public init(accessibility: AccessibilityEngine, gate: ExecutionGate) {
        self.accessibility = accessibility
        self.gate = gate
        self.input = InputSynthesizer(gate: gate)
        self.apps = AppController(accessibility: accessibility)
    }

    struct Resolved {
        var node: UIElementNode?
        var ref: AXRef?
        var point: CGPoint
    }

    /// Resolves a target against an observation and revalidates it against live AX state.
    func resolve(_ target: ElementTarget, in obs: ScreenObservation?) throws -> Resolved {
        switch target {
        case .point(let p):
            guard Self.isOnScreen(p) else { throw AutomationError.targetOffscreen("point \(target)") }
            return Resolved(node: nil, ref: nil, point: p)
        case .element(let id):
            guard let obs, let node = obs.element(id) else { throw AutomationError.elementNotFound("element \(id)") }
            return try revalidate(node, ref: obs.refs[id], obs: obs)
        case .description(let text):
            guard let obs else { throw AutomationError.elementNotFound("“\(text)”") }
            let matches = ElementMatcher.rank(text, in: obs.elements)
            guard let node = ElementMatcher.unambiguousBest(matches, minScore: 0.7, margin: 0.05) ?? matches.first.flatMap({ $0.score >= 0.95 ? $0.node : nil })
            else { throw AutomationError.elementNotFound("“\(text)”") }
            return try revalidate(node, ref: obs.refs[node.id], obs: obs)
        }
    }

    private func revalidate(_ node: UIElementNode, ref: AXRef?, obs: ScreenObservation) throws -> Resolved {
        guard let ref else {
            // OCR / vision nodes have no native reference: use their observed frame.
            guard Self.isOnScreen(node.center) else { throw AutomationError.targetOffscreen("“\(node.label)”") }
            return Resolved(node: node, ref: nil, point: node.center)
        }
        var live = accessibility.refresh(ref)
        // A reused cell/row (after scrolling) is alive but shows different content: treat as stale.
        if live != nil, !accessibility.matchesIdentity(ref, node: node) { live = nil }
        if live == nil {
            // Element was destroyed: find the same identity in a fresh observation.
            accessibility.invalidateCache()
            if let fresh = try? accessibility.observe(obs.app, useCache: false),
               let same = fresh.elements.first(where: { $0.fingerprint == node.fingerprint }), let r = fresh.refs[same.id] {
                live = accessibility.refresh(r)
                if let live { return try finish(same, ref: r, frame: live.frame, enabled: live.enabled, focused: live.focused) }
            }
            throw AutomationError.elementStale("“\(node.label.isEmpty ? node.role : node.label)”")
        }
        return try finish(node, ref: ref, frame: live!.frame, enabled: live!.enabled, focused: live!.focused)
    }

    private func finish(_ node: UIElementNode, ref: AXRef, frame: CGRect, enabled: Bool, focused: Bool) throws -> Resolved {
        guard enabled else { throw AutomationError.elementDisabled("“\(node.label.isEmpty ? node.role : node.label)”") }
        var updated = node
        updated.frame = frame
        updated.focused = focused
        var point = CGPoint(x: frame.midX, y: frame.midY)
        if !Self.isOnScreen(point) {
            accessibility.scrollToVisible(ref)
            if let again = accessibility.refresh(ref) {
                updated.frame = again.frame
                point = CGPoint(x: again.frame.midX, y: again.frame.midY)
            }
            if !Self.isOnScreen(point) {
                throw AutomationError.targetOffscreen("“\(node.label.isEmpty ? node.role : node.label)”")
            }
        }
        return Resolved(node: updated, ref: ref, point: point)
    }

    static func isOnScreen(_ p: CGPoint) -> Bool {
        // NSScreen frames are bottom-left based; convert to top-left using the primary screen.
        guard let primary = NSScreen.screens.first else { return true }
        let h = primary.frame.height
        return NSScreen.screens.contains { s in
            let f = s.frame
            return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height).contains(p)
        }
    }

    // MARK: - Execute

    /// Set by the runtime so verification knows which app was in front when an action began.
    public var onActionStart: (@Sendable () -> Void)?

    public func execute(_ action: ComputerAction, observation obs: ScreenObservation?) async throws -> ActionOutcome {
        try await gate.checkpoint()
        try Task.checkCancellation()
        onActionStart?()
        let start = Date()
        let app = obs?.app
        let genBefore = app.map { accessibility.monitor.generation(for: $0.pid) }
        var outcome = try await perform(action, obs: obs)
        outcome.durationMs = Date().timeIntervalSince(start) * 1000
        outcome.generationBefore = outcome.generationBefore ?? genBefore
        if let pid = (outcome.app ?? app)?.pid {
            accessibility.invalidateCache()
            _ = pid
        }
        log.info("\(action.humanDescription, privacy: .public) via \(outcome.method, privacy: .public) in \(outcome.durationMs, format: .fixed(precision: 0))ms")
        return outcome
    }

    private func perform(_ action: ComputerAction, obs: ScreenObservation?) async throws -> ActionOutcome {
        switch action {
        case .click(let target):
            return try clickTarget(target, obs: obs, button: .left, count: 1)
        case .doubleClick(let target):
            return try clickTarget(target, obs: obs, button: .left, count: 2)
        case .rightClick(let target):
            return try clickTarget(target, obs: obs, button: .right, count: 1)

        case .typeText(let text, let into, let clearFirst, let submit):
            var method = "keyboard"
            var targetNode: UIElementNode?
            if let into {
                let r = try resolve(into, in: obs)
                targetNode = r.node
                if let ref = r.ref, accessibility.isSecureField(ref) {
                    throw AutomationError.blockedBySafety("NotchBuddy never types into password fields. Please enter it yourself.")
                }
                if !(r.node?.focused ?? false) {
                    try clickPoint(r, button: .left, count: 1)
                    try await Task.sleep(for: .milliseconds(90))
                }
            }
            // Whatever ends up focused (including after a click on a visual point) must not be a password field.
            if let pid = obs?.app.pid ?? accessibility.frontmostApp()?.pid,
               let focused = AX.element(accessibility.appElement(pid), kAXFocusedUIElementAttribute),
               AX.string(focused, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
                throw AutomationError.blockedBySafety("The focused field is a password field. NotchBuddy won't type into it.")
            }
            if clearFirst {
                try input.press(try KeyCombination(parsing: "cmd+a"))
                if text.isEmpty { try input.press(try KeyCombination(parsing: "delete")) }
            }
            if text.count > pasteThreshold {
                try input.paste(text)
                method = "paste"
            } else if !text.isEmpty {
                try input.type(text)
            }
            if submit { try input.press(try KeyCombination(parsing: "return")) }
            let probe = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(40))
            let expectation: Expectation = submit || probe.isEmpty ? .uiChanged : .focusedValueContains(probe)
            return ActionOutcome(method: method, detail: "typed \(text.count) characters", target: targetNode, app: obs?.app, expectation: expectation)

        case .keyPress(let combo):
            try input.press(combo)
            return ActionOutcome(method: "keyboard", detail: combo.displayString, app: obs?.app, expectation: .uiChanged)

        case .scroll(let direction, let amount, let at):
            var point: CGPoint?
            if let at { point = try resolve(at, in: obs).point }
            else if let f = obs?.windowFrame { point = CGPoint(x: f.midX, y: f.midY) }
            try input.scroll(direction, lines: Int(max(1, amount.rounded())), at: point)
            return ActionOutcome(method: "scroll-wheel", detail: "\(direction.rawValue) \(Int(amount))", point: point, app: obs?.app, expectation: .uiChanged)

        case .drag(let from, let to):
            let a = try resolve(from, in: obs), b = try resolve(to, in: obs)
            try input.drag(from: a.point, to: b.point)
            return ActionOutcome(method: "mouse-drag", detail: "dragged", target: a.node, point: b.point, app: obs?.app, expectation: .uiChanged)

        case .focus(let target):
            let r = try resolve(target, in: obs)
            if let ref = r.ref, accessibility.focus(ref) {
                try input.move(to: r.point)
                return ActionOutcome(method: "ax-focus", detail: "focused", target: r.node, point: r.point, app: obs?.app, expectation: .uiChanged)
            }
            try clickPoint(r, button: .left, count: 1)
            return ActionOutcome(method: "click-focus", detail: "focused by click", target: r.node, point: r.point, app: obs?.app, expectation: .uiChanged)

        case .setValue(let target, let value):
            let r = try resolve(target, in: obs)
            if let ref = r.ref {
                if accessibility.isSecureField(ref) { throw AutomationError.blockedBySafety("NotchBuddy never fills password fields.") }
                try input.move(to: r.point)
                if accessibility.setValue(ref, value) {
                    return ActionOutcome(method: "ax-set-value", detail: "set value", target: r.node, point: r.point, app: obs?.app,
                                         expectation: .elementValueContains(elementID: r.node?.id ?? "", text: String(value.suffix(40))))
                }
            }
            return try await perform(.typeText(value, into: target, clearFirst: true, submit: false), obs: obs)

        case .selectText(let target):
            let r = try resolve(target, in: obs)
            try clickPoint(r, button: .left, count: 1)
            if let ref = r.ref, accessibility.selectAllText(ref) {
                return ActionOutcome(method: "ax-select", detail: "selected text", target: r.node, point: r.point, app: obs?.app, expectation: .none)
            }
            try input.press(try KeyCombination(parsing: "cmd+a"))
            return ActionOutcome(method: "keyboard-select", detail: "selected all", target: r.node, point: r.point, app: obs?.app, expectation: .none)

        case .menu(let path):
            guard let app = obs?.app ?? accessibility.frontmostApp() else { throw AutomationError.noFocusedWindow("menu") }
            return try await chooseMenu(path, app: app)

        case .launchApp(let name):
            let info = try await apps.launch(name)
            return ActionOutcome(method: "launch-services", detail: "opened \(info.name)", app: info, expectation: .appFrontmost(info.name))

        case .activateApp(let name):
            let info = try await apps.activate(name)
            return ActionOutcome(method: "activate", detail: "switched to \(info.name)", app: info, expectation: .appFrontmost(info.name))

        case .openURL(let raw, let appName):
            var s = raw.trimmingCharacters(in: .whitespaces)
            if !s.contains("://") { s = "https://" + s }
            guard let url = URL(string: s) else { throw AutomationError.elementNotFound("URL \(raw)") }
            try gate.checkStopped()
            try await apps.open(url: url, withApp: appName)
            try await Task.sleep(for: .milliseconds(300))
            let front = accessibility.frontmostApp()
            return ActionOutcome(method: "open-url", detail: url.absoluteString, app: front, expectation: .uiChanged)

        case .waitFor(let condition):
            return try await wait(condition, obs: obs)
        }
    }

    private func clickTarget(_ target: ElementTarget, obs: ScreenObservation?, button: MouseButton, count: Int) throws -> ActionOutcome {
        let r = try resolve(target, in: obs)
        let alreadyFocusedField = r.node.map { ElementRoles.textInput.contains($0.role) && $0.focused } ?? false
        let method = try clickPoint(r, button: button, count: count)
        return ActionOutcome(method: method, detail: "\(button.rawValue) click ×\(count)", target: r.node, point: r.point, app: obs?.app,
                             expectation: alreadyFocusedField ? .none : .uiChanged)
    }

    /// Clicks through the real cursor when the target is actually under the point; otherwise
    /// moves the cursor there (so the user sees it) and uses the AX action.
    @discardableResult
    func clickPoint(_ r: Resolved, button: MouseButton, count: Int) throws -> String {
        guard let ref = r.ref else {
            try input.click(at: r.point, button: button, count: count)
            return "mouse"
        }
        let hit = accessibility.element(at: r.point)
        let ownUI = hit.flatMap { accessibility.pid(of: $0) } == ProcessInfo.processInfo.processIdentifier
        // NotchBuddy's own panel turns click-through before pointer input, so a hit on it means
        // the click will reach whatever is underneath.
        let onTarget = hit.map { accessibility.hitTestMatches($0, target: ref) } ?? false || (ownUI && input.willUsePointer != nil)
        if onTarget {
            try input.click(at: r.point, button: button, count: count)
            return "mouse"
        }
        let actions = accessibility.actions(of: ref)
        try input.move(to: r.point)
        try gate.checkStopped()
        if button == .right, actions.contains(kAXShowMenuAction), accessibility.showMenu(ref) { return "ax-show-menu" }
        if button == .left, count == 1, actions.contains(kAXPressAction), accessibility.press(ref) { return "ax-press" }
        // Occluded and no AX action: click anyway; verification will catch a miss.
        try input.click(at: r.point, button: button, count: count)
        return "mouse-occluded"
    }

    private func chooseMenu(_ path: [String], app: AppInfo) async throws -> ActionOutcome {
        guard !path.isEmpty else { throw AutomationError.menuItemNotFound("") }
        let refs = try accessibility.menuItems(pid: app.pid, path: path)
        let gen = accessibility.monitor.generation(for: app.pid)
        for (i, ref) in refs.enumerated() {
            try await gate.checkpoint()
            if i > 0 { try await Task.sleep(for: .milliseconds(120)) }
            guard accessibility.menuItemEnabled(ref) else {
                if i > 0 { try? input.press(try KeyCombination(parsing: "escape")) }
                throw AutomationError.elementDisabled("menu item “\(path.prefix(i + 1).joined(separator: " › "))”")
            }
            if let live = accessibility.refresh(ref), live.frame.width > 2, Self.isOnScreen(CGPoint(x: live.frame.midX, y: live.frame.midY)) {
                let p = CGPoint(x: live.frame.midX, y: live.frame.midY)
                // Submenu parents open on hover; only the leaf and top-level item need a click.
                if i == 0 || i == refs.count - 1 {
                    try input.click(at: p)
                } else {
                    try input.move(to: p)
                    try await Task.sleep(for: .milliseconds(150))
                }
            } else {
                accessibility.press(ref)
            }
        }
        return ActionOutcome(method: "menu", detail: path.joined(separator: " › "), app: app, expectation: .uiChanged, generationBefore: gen)
    }

    private func wait(_ condition: WaitCondition, obs: ScreenObservation?) async throws -> ActionOutcome {
        switch condition {
        case .seconds(let s):
            let end = Date().addingTimeInterval(min(s, 30))
            while Date() < end {
                try await gate.checkpoint()
                try await Task.sleep(for: .milliseconds(100))
            }
            return ActionOutcome(method: "wait", detail: "waited \(s)s", app: obs?.app, expectation: .none)
        case .appFrontmost(let name):
            return ActionOutcome(method: "wait", detail: "app \(name)", app: obs?.app, expectation: .appFrontmost(name))
        case .elementExists(let d):
            return ActionOutcome(method: "wait", detail: d, app: obs?.app, expectation: .elementAppears(d))
        case .elementGone(let d):
            if let obs, let node = ElementMatcher.rank(d, in: obs.elements, limit: 1).first?.node {
                return ActionOutcome(method: "wait", detail: d, app: obs.app, expectation: .elementGone(fingerprint: node.fingerprint, label: node.label))
            }
            return ActionOutcome(method: "wait", detail: d, app: obs?.app, expectation: .none)
        case .windowTitleContains(let t):
            return ActionOutcome(method: "wait", detail: t, app: obs?.app, expectation: .windowTitleContains(t))
        }
    }
}
