import Foundation
import CoreGraphics

/// A point-in-time view of one application window, normalized into the unified element graph.
public struct ScreenObservation: Sendable {
    public let id: UUID
    public let app: AppInfo
    public let windowTitle: String?
    public let windowFrame: CGRect?
    public var elements: [UIElementNode]
    public let focusedElementID: String?
    public let timestamp: Date
    public let durationMs: Double
    public let truncated: Bool
    /// Native references for each element id (AX elements); not sent to models.
    public var refs: [String: AXRef]
    /// Top-level menu bar titles of the app (for menu navigation).
    public let menuBarTitles: [String]

    public init(
        id: UUID = UUID(), app: AppInfo, windowTitle: String?, windowFrame: CGRect?,
        elements: [UIElementNode], focusedElementID: String?, timestamp: Date = Date(),
        durationMs: Double = 0, truncated: Bool = false, refs: [String: AXRef] = [:],
        menuBarTitles: [String] = []
    ) {
        self.id = id
        self.app = app
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.elements = elements
        self.focusedElementID = focusedElementID
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.truncated = truncated
        self.refs = refs
        self.menuBarTitles = menuBarTitles
    }

    public func element(_ id: String) -> UIElementNode? { elements.first { $0.id == id } }

    public var focusedElement: UIElementNode? { focusedElementID.flatMap(element) }

    public var interactiveCount: Int { elements.filter(\.isInteractive).count }

    /// Compact, indexed UI skeleton for models. Interactive and focused elements come first;
    /// readable text is included up to a budget so models can read content.
    public func compact(maxElements: Int = 220, maxTextChars: Int = 6000, includeText: Bool = true) -> String {
        var lines: [String] = []
        lines.append("app: \(app.name)" + (windowTitle.map { " | window: \"\($0)\"" } ?? ""))
        if let windowFrame {
            lines.append("window frame: x=\(Int(windowFrame.minX)) y=\(Int(windowFrame.minY)) w=\(Int(windowFrame.width)) h=\(Int(windowFrame.height))")
        }
        if !menuBarTitles.isEmpty { lines.append("menu bar: " + menuBarTitles.joined(separator: ", ")) }
        if let f = focusedElement { lines.append("focused: \(f.id) \(f.role) \"\(Self.clip(f.label, 60))\"") }
        let interactive = elements.filter { $0.isInteractive || ElementRoles.textInput.contains($0.role) }
        var count = 0
        for node in interactive where count < maxElements {
            lines.append(Self.line(for: node))
            count += 1
        }
        if includeText {
            var budget = maxTextChars
            for node in elements where !node.isInteractive && (node.role == "text" || node.role == "heading" || node.role == "webarea" || node.source == .ocr) {
                guard budget > 0, count < maxElements + 200 else { break }
                let l = Self.line(for: node)
                budget -= l.count
                lines.append(l)
                count += 1
            }
        }
        if truncated { lines.append("(tree truncated)") }
        return lines.joined(separator: "\n")
    }

    static func line(for n: UIElementNode) -> String {
        var s = "\(n.id) \(n.role)"
        let label = n.label
        if !label.isEmpty { s += " \"\(clip(label, 80))\"" }
        if let v = n.value, !v.isEmpty, v != label, !n.isSecure {
            s += " value=\"\(clip(v, n.role == "text" ? 300 : 120))\""
        }
        if n.isSecure { s += " [secure]" }
        if !n.enabled { s += " [disabled]" }
        if n.focused { s += " [focused]" }
        if n.selected { s += " [selected]" }
        if n.source != .accessibility { s += " [\(n.source.rawValue)]" }
        if let c = n.context, !c.isEmpty { s += " in \"\(clip(c, 40))\"" }
        return s
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }
}

/// Raw node from a perception source before ids are assigned.
public struct RawElement: Sendable {
    public var node: UIElementNode
    public var ref: AXRef?
    public var pathKey: String

    public init(node: UIElementNode, ref: AXRef?, pathKey: String) {
        self.node = node
        self.ref = ref
        self.pathKey = pathKey
    }
}

/// Assigns observation-scoped ids that stay stable across observations when an element's
/// identity (role, label, identifier, ancestry) is unchanged.
public final class ElementGraph: @unchecked Sendable {
    private let lock = NSLock()
    private var idByFingerprint: [String: String] = [:]
    private var nextID = 1

    public init() {}

    public func reset() {
        lock.withLock {
            idByFingerprint.removeAll()
            nextID = 1
        }
    }

    public func assignIDs(_ raws: [RawElement]) -> (nodes: [UIElementNode], refs: [String: AXRef]) {
        lock.withLock {
            var seen: [String: Int] = [:]
            var nodes: [UIElementNode] = []
            var refs: [String: AXRef] = [:]
            var parentMap: [String: String] = [:] // pathKey -> id
            nodes.reserveCapacity(raws.count)
            for raw in raws {
                var node = raw.node
                let base = Self.fingerprint(node, pathKey: raw.pathKey)
                let ordinal = seen[base, default: 0]
                seen[base] = ordinal + 1
                let fp = ordinal == 0 ? base : "\(base)#\(ordinal)"
                let id: String
                if let existing = idByFingerprint[fp] {
                    id = existing
                } else {
                    id = "e\(nextID)"
                    nextID += 1
                    idByFingerprint[fp] = id
                }
                node.id = id
                node.fingerprint = fp
                parentMap[raw.pathKey] = id
                if let parentKey = raw.pathKey.parentPathKey { node.parentID = parentMap[parentKey] }
                nodes.append(node)
                if let ref = raw.ref { refs[id] = ref }
            }
            return (nodes, refs)
        }
    }

    static func fingerprint(_ n: UIElementNode, pathKey: String) -> String {
        let label = n.label.prefix(60)
        let ancestry = pathKey.split(separator: "/").suffix(4).joined(separator: "/")
        return "\(n.source.rawValue)|\(n.role)|\(label)|\(n.identifier ?? "")|\(ancestry)"
    }
}

extension String {
    var parentPathKey: String? {
        guard let idx = lastIndex(of: "/") else { return nil }
        return String(self[..<idx])
    }
}

/// Fuzzy ranking of elements against a natural-language target description.
public enum ElementMatcher {
    public struct Match: Sendable {
        public let node: UIElementNode
        public let score: Double
    }

    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
        let allowed = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        return String(allowed).split(separator: " ").joined(separator: " ")
    }

    /// Words like "button" or "the" in a target description describe the role, not the label.
    static let roleWords: [String: String] = [
        "button": "button", "field": "textfield", "textfield": "textfield", "box": "textfield",
        "link": "link", "tab": "tab", "checkbox": "checkbox", "menu": "menuitem", "icon": "button",
        "search": "searchfield", "row": "row", "cell": "cell", "item": "menuitem", "switch": "switch",
    ]
    static let stopWords: Set<String> = ["the", "a", "an", "on", "in", "of", "to", "named", "called", "labeled", "labelled"]

    public static func rank(_ query: String, in nodes: [UIElementNode], roleHint: String? = nil, limit: Int = 10) -> [Match] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }
        var tokens = q.split(separator: " ").map(String.init).filter { !stopWords.contains($0) }
        var inferredRole = roleHint
        if tokens.count > 1, let last = tokens.last, let r = roleWords[last] {
            inferredRole = inferredRole ?? r
            tokens.removeLast()
        }
        let core = tokens.joined(separator: " ")
        var results: [Match] = []
        for node in nodes {
            var best = 0.0
            for (field, weight) in [(node.name, 1.0), (node.placeholder ?? "", 0.9), (node.identifier ?? "", 0.7), (node.value ?? "", 0.6), (node.context ?? "", 0.3)] {
                let f = normalize(field)
                guard !f.isEmpty else { continue }
                // Compare both the role/stop-word-stripped query and the literal one, so
                // "Go to page two" still matches its own label exactly.
                best = max(best, max(similarity(core, f), similarity(q, f)) * weight)
            }
            guard best > 0.25 else { continue }
            var score = best
            if node.isInteractive { score += 0.08 }
            if !node.enabled { score -= 0.25 }
            if let r = inferredRole {
                if node.role == r || (r == "textfield" && ElementRoles.textInput.contains(node.role)) { score += 0.12 }
            }
            if node.frame.width < 2 || node.frame.height < 2 { score -= 0.3 }
            results.append(Match(node: node, score: min(score, 1.2)))
        }
        return Array(results.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Similarity in [0, 1] combining exact, prefix, containment, token overlap and edit distance.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if b.hasPrefix(a) || a.hasPrefix(b) {
            let ratio = Double(min(a.count, b.count)) / Double(max(a.count, b.count))
            return 0.75 + 0.2 * ratio
        }
        if b.contains(a) { return 0.7 + 0.1 * Double(a.count) / Double(b.count) }
        if a.contains(b) && b.count >= 3 { return 0.55 + 0.2 * Double(b.count) / Double(a.count) }
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        let jaccard = Double(ta.intersection(tb).count) / Double(max(1, ta.union(tb).count))
        let edit = 1.0 - Double(levenshtein(a, b)) / Double(max(a.count, b.count, 1))
        return max(jaccard * 0.8, edit * 0.75)
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if a.count > 200 || b.count > 200 { return max(a.count, b.count) }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Picks a target only when the best match is strong and clearly ahead of the runner-up.
    public static func unambiguousBest(_ matches: [Match], minScore: Double = 0.85, margin: Double = 0.12) -> UIElementNode? {
        guard let first = matches.first, first.score >= minScore else { return nil }
        if matches.count > 1, first.score - matches[1].score < margin { return nil }
        return first.node
    }
}
