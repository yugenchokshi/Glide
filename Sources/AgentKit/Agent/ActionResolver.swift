import Foundation
import AutomationKit

/// Turns plan hints and actor decisions into concrete `ComputerAction`s against the current
/// observation. Unambiguous targets resolve deterministically (no model call); ambiguous
/// ones go to Jev (if configured) and finally to visual grounding.
public struct ActionResolver: Sendable {
    public enum Resolution: Sendable {
        case action(ComputerAction, target: UIElementNode?, deterministic: Bool)
        case needsGrounding(description: String, kind: String, decision: ActorDecision?)
        case tool(name: String, arguments: JSONValue)
        case invalid(String)
    }

    let jev: JevClient?
    let metrics: TaskMetrics

    public init(jev: JevClient?, metrics: TaskMetrics) {
        self.jev = jev
        self.metrics = metrics
    }

    static func menuPath(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: ">›→"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Deterministic fast path for a plan step's hint. Returns nil when the hint isn't
    /// unambiguous in the current UI.
    public func compileHint(_ hint: ActionHint, obs: ScreenObservation?) -> ComputerAction? {
        let target = hint.target?.trimmingCharacters(in: .whitespaces)
        switch hint.action {
        case "launch_app": return target.map { .launchApp($0) }
        case "activate_app": return target.map { .activateApp($0) }
        case "open_url": return (target ?? hint.text).map { .openURL($0, app: nil) }
        case "key": return (hint.text ?? target).flatMap { try? KeyCombination(parsing: $0) }.map { .keyPress($0) }
        case "menu":
            guard let target else { return nil }
            let path = Self.menuPath(target)
            return path.count >= 2 ? ComputerAction.menu(path) : nil
        case "click", "double_click", "right_click":
            guard let target, let obs else { return nil }
            let matches = ElementMatcher.rank(target, in: obs.elements.filter { $0.source == .accessibility })
            guard let node = ElementMatcher.unambiguousBest(matches) else { return nil }
            switch hint.action {
            case "double_click": return .doubleClick(.element(node.id))
            case "right_click": return .rightClick(.element(node.id))
            default: return .click(.element(node.id))
            }
        case "type":
            guard let text = hint.text, let obs else { return nil }
            if let target, !target.isEmpty {
                let fields = obs.elements.filter { ElementRoles.textInput.contains($0.role) }
                guard let node = ElementMatcher.unambiguousBest(ElementMatcher.rank(target, in: fields, roleHint: "textfield"), minScore: 0.75) else { return nil }
                return .typeText(text, into: .element(node.id), clearFirst: false, submit: false)
            }
            if let f = obs.focusedElement, ElementRoles.textInput.contains(f.role) {
                return .typeText(text, into: nil, clearFirst: false, submit: false)
            }
            return nil
        default:
            return nil
        }
    }

    /// Converts an actor decision into an action, resolving its target.
    public func resolve(_ d: ActorDecision, obs: ScreenObservation?, objective: String) async -> Resolution {
        guard let kind = d.action else { return .invalid("no action") }
        func target() async -> (ElementTarget, UIElementNode?)? {
            if let id = d.elementID, let node = obs?.element(id) { return (.element(id), node) }
            guard let description = d.targetDescription, let obs else { return nil }
            let matches = ElementMatcher.rank(description, in: obs.elements)
            if let node = ElementMatcher.unambiguousBest(matches, minScore: 0.8) { return (.element(node.id), node) }
            if let picked = await disambiguate(description, matches: matches, obs: obs, objective: objective) {
                return (.element(picked.id), picked)
            }
            return nil
        }
        switch kind {
        case "click", "double_click", "right_click", "focus", "select_text":
            guard let (t, node) = await target() else {
                return .needsGrounding(description: d.targetDescription ?? d.elementID ?? "the target", kind: kind, decision: d)
            }
            let action: ComputerAction = switch kind {
            case "double_click": .doubleClick(t)
            case "right_click": .rightClick(t)
            case "focus": .focus(t)
            case "select_text": .selectText(t)
            default: .click(t)
            }
            return .action(action, target: node, deterministic: false)
        case "type":
            let text = d.text ?? ""
            if d.elementID == nil && d.targetDescription == nil {
                return .action(.typeText(text, into: nil, clearFirst: d.clearFirst, submit: d.submit), target: obs?.focusedElement, deterministic: false)
            }
            guard let (t, node) = await target() else {
                return .needsGrounding(description: d.targetDescription ?? "the text field", kind: kind, decision: d)
            }
            return .action(.typeText(text, into: t, clearFirst: d.clearFirst, submit: d.submit), target: node, deterministic: false)
        case "set_value":
            guard let (t, node) = await target() else { return .invalid("set_value needs a target") }
            return .action(.setValue(t, d.text ?? ""), target: node, deterministic: false)
        case "key":
            guard let keys = d.keys ?? d.text, let combo = try? KeyCombination(parsing: keys) else { return .invalid("unknown key combination \(d.keys ?? "")") }
            return .action(.keyPress(combo), target: nil, deterministic: false)
        case "scroll":
            let dir = ScrollDirection(rawValue: d.direction ?? "down") ?? .down
            let at: ElementTarget? = d.elementID.flatMap { obs?.element($0) != nil ? .element($0) : nil }
            return .action(.scroll(dir, amount: d.amount ?? 5, at: at), target: nil, deterministic: false)
        case "drag":
            guard let (from, node) = await target(), let to = d.toElementID, obs?.element(to) != nil else { return .invalid("drag needs two element ids") }
            return .action(.drag(from, .element(to)), target: node, deterministic: false)
        case "menu":
            guard let path = d.menuPath, path.count >= 2 else { return .invalid("menu needs a path like [\"File\",\"Save…\"]") }
            return .action(.menu(path), target: nil, deterministic: false)
        case "launch_app":
            guard let app = d.app ?? d.text else { return .invalid("launch_app needs app") }
            return .action(.launchApp(app), target: nil, deterministic: false)
        case "activate_app":
            guard let app = d.app ?? d.text else { return .invalid("activate_app needs app") }
            return .action(.activateApp(app), target: nil, deterministic: false)
        case "open_url":
            guard let url = d.url ?? d.text else { return .invalid("open_url needs url") }
            return .action(.openURL(url, app: d.app), target: nil, deterministic: false)
        case "wait":
            return .action(.waitFor(.seconds(min(d.amount ?? 1, 10))), target: nil, deterministic: false)
        case "call_tool":
            guard let name = d.toolName else { return .invalid("call_tool needs tool_name") }
            return .tool(name: name, arguments: d.toolArguments ?? [:])
        default:
            return .invalid("unknown action \(kind)")
        }
    }

    /// Uses Jev (calibrated Choice over candidate ids) to pick between close matches.
    func disambiguate(_ description: String, matches: [ElementMatcher.Match], obs: ScreenObservation, objective: String) async -> UIElementNode? {
        let candidates = matches.prefix(12).filter { $0.score >= 0.4 }
        guard candidates.count >= 2, let jev else {
            return candidates.count == 1 && candidates[0].score >= 0.6 ? candidates[0].node : nil
        }
        var options: [String: String] = [:]
        for m in candidates {
            options[m.node.id] = ScreenObservation.jevLine(for: m.node)
        }
        options["none"] = "None of these elements matches the target."
        let state: JSONValue = ["objective": .string(objective), "target": .string(description), "app": .string(obs.app.name), "window": .string(obs.windowTitle ?? "")]
        guard let answer = try? await jev.choose(state: state, instructions: "Which UI element is `target` for the `objective`?", options: options) else { return nil }
        await metrics.recordJev(answer.usage)
        guard answer.choice != "none", answer.confidence >= 0.5 else { return nil }
        return obs.element(answer.choice)
    }
}

extension ScreenObservation {
    static func jevLine(for n: UIElementNode) -> String {
        var s = "\(n.role) \"\(n.label)\""
        if let v = n.value, !v.isEmpty, !n.isSecure { s += " value=\"\(v.prefix(60))\"" }
        if let c = n.context { s += " in \"\(c)\"" }
        return s
    }
}
