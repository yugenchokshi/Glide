import Foundation
import Synchronization

// DOM-level browser control on top of any `BrowserBackend` ("like Playwright", without Node).
//
// The model sees a page as a compact list of interactive elements, each with a short ref
// (`b12 button "Sign in"`), plus the readable text. Refs are stamped onto the DOM as
// `data-glide-ref` attributes, so an action finds exactly the element the model saw — or fails
// loudly with "take a new snapshot" when the page has changed under it. Clicks and typing are
// real CDP input events (focus, hover and framework handlers behave as for a person), with a
// script fallback only when another element covers the target.

// MARK: - Optional backend capabilities

/// Requests in flight in one tab, used to tell when a page has finished loading.
public struct BrowserNetworkActivity: Sendable, Hashable {
    public var inflight: Int
    /// When a request last started or finished.
    public var lastChange: Date

    public init(inflight: Int, lastChange: Date) {
        self.inflight = inflight
        self.lastChange = lastChange
    }
}

/// A JavaScript dialog (alert, confirm, prompt, beforeunload) the backend answered by itself.
public struct BrowserDialog: Sendable, Hashable {
    public var type: String
    public var message: String
    public var accepted: Bool

    public init(type: String, message: String, accepted: Bool) {
        self.type = type
        self.message = message
        self.accepted = accepted
    }
}

/// When a backend answers a page's JavaScript dialog by itself. Glide's own Chrome uses these
/// rules; the extension's service_worker.js has the same ones (keep them in step).
///
/// A dialog freezes the page until it's answered, so in a tab Glide is working in it's answered
/// at once, deterministically. Anywhere else it's the user's to answer, and commands sent to the
/// tab fail at once until they have.
enum BrowserDialogPolicy {
    /// Commands that act on the page the way a person would — input events, navigation, a
    /// script run with a user gesture (the driver's click and typing fallbacks) — rather than
    /// read it.
    static func isAction(method: String, params: JSONValue?) -> Bool {
        if method.hasPrefix("Input.") { return true }
        switch method {
        case "Page.navigate", "Page.navigateToHistoryEntry", "Page.reload": return true
        case "Runtime.evaluate", "Runtime.callFunctionOn": return params?["userGesture"]?.boolValue == true
        default: return false
        }
    }

    /// In Glide's own tabs every dialog is answered. In the user's tabs only while Glide is
    /// working there (`driving`: a command running or just finished), and "Leave site?" only
    /// when one of Glide's actions could have caused it (`acting`): while Glide merely reads
    /// the tab, it's the user closing it or leaving a half-filled form, and accepting would
    /// throw their input away.
    static func answers(type: String, ownedByGlide: Bool, driving: Bool, acting: Bool) -> Bool {
        if ownedByGlide { return true }
        return type == "beforeunload" ? acting : driving
    }

    /// Alerts are closed and leaving the page is allowed; confirm() and prompt() are declined,
    /// so a page never gets a "yes" to "Delete everything?" behind the user's back.
    static func accepts(type: String) -> Bool { type == "alert" || type == "beforeunload" }

    /// The error for a command sent to a tab whose dialog is waiting for the user.
    static func waitingMessage(_ dialog: BrowserDialog) -> String {
        let what: String
        switch dialog.type {
        case "alert": what = "an alert"
        case "confirm": what = "a confirmation dialog"
        case "prompt": what = "a prompt"
        case "beforeunload": what = "a “Leave site?” prompt"
        default: what = "a dialog"
        }
        let quote = dialog.message.isEmpty ? "" : " (“\(PageSnapshot.clip(dialog.message, 120))”)"
        return "This tab is showing \(what)\(quote). Answer it in Chrome, then try again."
    }
}

/// Backends that receive CDP events (Glide's own Chrome) adopt this so the driver can wait for a
/// quiet network instead of guessing, and report dialogs it answered. Backends without events
/// still work: the driver falls back to watching the DOM settle.
public protocol BrowserPageObserving: AnyObject, Sendable {
    func networkActivity(tabID: String) async -> BrowserNetworkActivity?
    /// Dialogs answered since the last call (then forgotten).
    func takeHandledDialogs(tabID: String) async -> [BrowserDialog]
}

/// Backends that can describe their own state for Settings › Browser.
public protocol BrowserStatusDescribing: AnyObject, Sendable {
    func statusDetail() async -> String
}

/// An action Glide refuses or can't do on this element, in words the model and user can act on.
public struct BrowserActionError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Snapshot model

/// What the model sees of a page: its interactive elements (with refs) and readable text.
public struct PageSnapshot: Codable, Sendable, Hashable {
    public struct Element: Codable, Sendable, Hashable {
        public var ref: String
        public var role: String
        /// Accessible name (aria-label, labels, alt, title, placeholder or text).
        public var name: String
        /// Current value; never set for password fields.
        public var value: String?
        /// `type` attribute for inputs other than plain text.
        public var inputType: String?
        public var checked: Bool?
        public var selected: Bool?
        public var expanded: Bool?
        public var disabled: Bool
        public var focused: Bool
        /// Password field (its value is never read).
        public var secure: Bool
        public var href: String?
        /// Visible option labels of a `<select>`.
        public var options: [String]?
        /// Enclosing dialog or form, e.g. `form Payment → /checkout/pay`.
        public var context: String?
        /// Bounding box in CSS pixels relative to the viewport.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// In the part of the page you can see: inside the viewport and not cut off by a
        /// scrolled panel or dialog it sits in.
        public var inViewport: Bool
        /// Inside the open dialog or popup (`PageSnapshot.modal`).
        public var inModal: Bool?
        /// Which way it lies when it isn't in view: "below", "above", "right" or "left".
        public var offscreen: String?
        /// Listed only because `find` asked for it (beyond the cap, or not a control at all).
        /// The fingerprint and change summaries leave such elements out, so a later snapshot
        /// without them doesn't look like a change.
        public var pinned: Bool?

        public init(ref: String, role: String, name: String, value: String? = nil, inputType: String? = nil, checked: Bool? = nil,
                    selected: Bool? = nil, expanded: Bool? = nil, disabled: Bool = false, focused: Bool = false, secure: Bool = false,
                    href: String? = nil, options: [String]? = nil, context: String? = nil,
                    x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0, inViewport: Bool = true,
                    inModal: Bool? = nil, offscreen: String? = nil, pinned: Bool? = nil) {
            self.ref = ref
            self.role = role
            self.name = name
            self.value = value
            self.inputType = inputType
            self.checked = checked
            self.selected = selected
            self.expanded = expanded
            self.disabled = disabled
            self.focused = focused
            self.secure = secure
            self.href = href
            self.options = options
            self.context = context
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.inViewport = inViewport
            self.inModal = inModal
            self.offscreen = offscreen
            self.pinned = pinned
        }
    }

    /// A dialog or popup open in front of the page: a `<dialog>` or role=dialog under the
    /// viewport center, a modal one anywhere, or a fixed overlay covering the center.
    public struct Modal: Codable, Sendable, Hashable {
        /// One of its interactive elements beyond its visible area, with the heading above it.
        public struct Hint: Codable, Sendable, Hashable {
            public var name: String
            public var group: String

            public init(name: String, group: String = "") {
                self.name = name
                self.group = group
            }
        }

        public var name: String
        /// "dialog", or "popup" for an overlay that doesn't say it's a dialog.
        public var kind: String
        /// Its main scrollable region: how far it's scrolled and how tall it is.
        public var scrollTop: Double
        public var scrollLeft: Double
        public var scrollHeight: Double
        public var clientHeight: Double
        /// The first of its interactive elements further down, and how many there are in all.
        public var below: [Hint]
        public var belowCount: Int
        /// Its interactive elements scrolled past (above or to the side of its visible area).
        public var aboveCount: Int
        /// Its readable text, without the lines that are just its controls' names (capped).
        public var text: String

        public init(name: String, kind: String = "dialog", scrollTop: Double = 0, scrollLeft: Double = 0, scrollHeight: Double = 0,
                    clientHeight: Double = 0, below: [Hint] = [], belowCount: Int? = nil, aboveCount: Int = 0, text: String = "") {
            self.name = name
            self.kind = kind
            self.scrollTop = scrollTop
            self.scrollLeft = scrollLeft
            self.scrollHeight = scrollHeight
            self.clientHeight = clientHeight
            self.below = below
            self.belowCount = belowCount ?? below.count
            self.aboveCount = aboveCount
            self.text = text
        }

        /// “the “Filters” dialog”, or “the popup” when it has no name.
        public var title: String { name.isEmpty ? "the \(kind)" : "the “\(PageSnapshot.clip(name, 60))” \(kind)" }
    }

    /// Interactive elements a snapshot or its rendering left out, by where they are.
    public struct Offscreen: Codable, Sendable, Hashable {
        public var below = 0
        public var above = 0
        public var right = 0
        public var left = 0
        public var onScreen = 0

        public init(below: Int = 0, above: Int = 0, right: Int = 0, left: Int = 0, onScreen: Int = 0) {
            self.below = below
            self.above = above
            self.right = right
            self.left = left
            self.onScreen = onScreen
        }

        public var total: Int { below + above + right + left + onScreen }

        mutating func add(_ direction: String?) {
            switch direction {
            case "below": below += 1
            case "above": above += 1
            case "right": right += 1
            case "left": left += 1
            default: onScreen += 1
            }
        }

        /// “120 below, 30 to the right”.
        var description: String {
            [(below, "below"), (right, "to the right"), (above, "above"), (left, "to the left"), (onScreen, "on screen")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        }
    }

    public struct Heading: Codable, Sendable, Hashable {
        public var level: Int
        public var text: String
        public init(level: Int, text: String) {
            self.level = level
            self.text = text
        }
    }

    public var tabID: String
    public var url: String
    public var title: String
    public var viewportWidth: Double
    public var viewportHeight: Double
    public var scrollX: Double
    public var scrollY: Double
    public var pageWidth: Double
    public var pageHeight: Double
    public var elements: [Element]
    public var headings: [Heading]
    /// Readable text of the main content (or the body when there's no main region).
    public var text: String
    /// Length of the full text before it was capped.
    public var textTotal: Int
    /// Interactive elements found before the cap.
    public var totalInteractive: Int
    /// Visible frames from other sites whose contents couldn't be included.
    public var skippedFrames: Int
    public var timestamp: Date
    /// The dialog or popup open in front of the page, if any.
    public var modal: Modal?
    /// Interactive elements beyond the element cap, by where they are (not counting the
    /// modal's own elements further down, which `modal` summarizes).
    public var cut: Offscreen?
    /// Why the page looks like a CAPTCHA or bot check, when it does.
    public var botCheck: String?

    public init(tabID: String, url: String, title: String, viewportWidth: Double = 0, viewportHeight: Double = 0, scrollX: Double = 0,
                scrollY: Double = 0, pageWidth: Double = 0, pageHeight: Double = 0, elements: [Element] = [], headings: [Heading] = [],
                text: String = "", textTotal: Int? = nil, totalInteractive: Int? = nil, skippedFrames: Int = 0, timestamp: Date = Date(),
                modal: Modal? = nil, cut: Offscreen? = nil, botCheck: String? = nil) {
        self.tabID = tabID
        self.url = url
        self.title = title
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.elements = elements
        self.headings = headings
        self.text = text
        self.textTotal = textTotal ?? text.count
        self.totalInteractive = totalInteractive ?? elements.count
        self.skippedFrames = skippedFrames
        self.timestamp = timestamp
        self.modal = modal
        self.cut = cut
        self.botCheck = botCheck
    }

    public func element(_ ref: String) -> Element? { elements.first { $0.ref == ref } }

    public var focusedElement: Element? { elements.first { $0.focused } }

    /// What `compact` says first on a page that looks like a CAPTCHA or bot check.
    public static let botCheckNotice = "The page is asking to verify you're human (a CAPTCHA or bot check). Glide can't do that; the person has to complete it in Chrome."

    /// Model-facing rendering, in the same style as the accessibility skeleton:
    /// `b12 button "Sign in" [disabled]`. Elements in the viewport come first — with a dialog
    /// open, its own elements before those behind it, and the ones further down inside it as a
    /// short list of names. The readable text fills whatever budget is left (at least ~1,000
    /// characters when there is text). Elements in `skip` are left out (the caller shows them).
    public func compact(maxChars: Int = 8000, skip: Set<String> = []) -> String {
        var lines: [String] = []
        lines.append("page: \"\(Self.clip(title.isEmpty ? "(untitled)" : title, 100))\" \(Self.clip(url, 200))")
        let maxScrollY = max(0, pageHeight - viewportHeight)
        var where_ = "viewport \(Self.whole(viewportWidth))×\(Self.whole(viewportHeight))"
        if maxScrollY > 1 {
            let position = scrollY <= 1 ? " (top)" : (scrollY >= maxScrollY - 1 ? " (bottom)" : "")
            where_ += ", scrolled \(Self.whole(scrollY)) of \(Self.whole(maxScrollY))\(position)"
        }
        lines.append(where_)
        if botCheck != nil { lines.append(Self.botCheckNotice) }
        if let m = modal {
            var l = "\(m.kind) open: \"\(Self.clip(m.name.isEmpty ? "(untitled)" : m.name, 60))\""
            let maxScroll = max(0, m.scrollHeight - m.clientHeight)
            if maxScroll > 1 {
                let position = m.scrollTop <= 1 ? " (top)" : (m.scrollTop >= maxScroll - 1 ? " (bottom)" : "")
                l += ", scrolled \(Self.whole(m.scrollTop)) of \(Self.whole(maxScroll))\(position)"
            }
            lines.append(l)
        }
        if let f = focusedElement { lines.append("focused: \(f.ref)") }

        let hint = modal.flatMap(Self.furtherDown)
        let textReserve = text.isEmpty ? 0 : min(text.count + 10, max(1000, maxChars / 4))
        let elementBudget = max(600, maxChars - textReserve - 300 - (hint?.count ?? 0))
        var used = lines.reduce(0) { $0 + $1.count + 1 }
        var printed = Set<String>()
        func add(_ group: [Element]) {
            for e in group {
                let l = line(for: e)
                guard used + l.count + 1 <= elementBudget else { return }
                lines.append(l)
                used += l.count + 1
                printed.insert(e.ref)
            }
        }
        let shown = elements.filter { !skip.contains($0.ref) }
        /// A modal's elements further down are named in the hint instead of listed.
        func inHint(_ e: Element) -> Bool { modal != nil && e.inModal == true && !e.inViewport && e.offscreen == "below" }
        if elements.isEmpty { lines.append("(no interactive elements)") }
        let outside: [Element]
        if let m = modal {
            add(shown.filter { $0.inModal == true && $0.inViewport })
            if let hint {
                lines.append(hint)
                used += hint.count + 1
            }
            let behind = shown.filter { $0.inModal != true && $0.inViewport }
            if !behind.isEmpty, used < elementBudget - 40 {
                lines.append("behind the \(m.kind):")
                used += 20
                add(behind)
            }
            let hidden = shown.filter { !$0.inViewport && !inHint($0) }
            outside = hidden.filter { $0.inModal == true } + hidden.filter { $0.inModal != true }
        } else {
            add(shown.filter(\.inViewport))
            outside = shown.filter { !$0.inViewport }
        }
        if !outside.isEmpty, used < elementBudget - 40 {
            lines.append("outside the viewport (scroll to reach):")
            used += 40
            add(outside)
        }
        var more = cut ?? Offscreen()
        for e in shown where !printed.contains(e.ref) && !inHint(e) {
            more.add(e.inViewport ? nil : e.offscreen ?? direction(of: e))
        }
        if more.total > 0 {
            lines.append("(\(more.total) more interactive element\(more.total == 1 ? "" : "s") not listed: \(more.description) — use browser.find to reach one, or scroll)")
        }
        if skippedFrames > 0 { lines.append("(\(skippedFrames) embedded frame(s) from other sites aren't included)") }
        used = lines.reduce(0) { $0 + $1.count + 1 }

        if !headings.isEmpty, used < maxChars - 200 {
            let h = headings.prefix(20).map { String(repeating: "#", count: max(1, min(6, $0.level))) + " " + Self.clip($0.text, 80) }
            let joined = "headings: " + h.joined(separator: " | ")
            let clipped = Self.clip(joined, max(80, min(900, maxChars - used - 100)))
            lines.append(clipped)
            used += clipped.count + 1
        }
        if let m = modal, !m.text.isEmpty {
            let room = min(1500, maxChars - used - 200)
            if room > 80 {
                let body = m.text.count > room ? String(m.text.prefix(room)) + "…" : m.text
                lines.append("\(m.kind) text:\n" + body)
                used += body.count + 14
            }
        }
        if !text.isEmpty {
            let room = maxChars - used - 8
            if room > 80 {
                var body = text.count > room ? String(text.prefix(room)) + "…" : text
                if textTotal > text.count, !body.hasSuffix("…") { body += "…" }
                lines.append("text:\n" + body)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Which way an element outside the viewport lies, from its box.
    func direction(of e: Element) -> String {
        if e.y >= viewportHeight { return "below" }
        if e.y + e.height <= 0 { return "above" }
        return e.x >= viewportWidth ? "right" : "left"
    }

    /// “Further down in this dialog (24): Property type: House, Cabin; Amenities: Wifi…”, so
    /// the model knows what scrolling the dialog would reveal without listing every element.
    static func furtherDown(_ m: Modal) -> String? {
        guard m.belowCount > 0 else { return nil }
        var groups: [(group: String, names: [String])] = []
        for h in m.below {
            let name = clip(h.name, 40)
            guard !name.isEmpty else { continue }
            if let last = groups.last, last.group == h.group {
                if !last.names.contains(name) { groups[groups.count - 1].names.append(name) }
            } else {
                groups.append((h.group, [name]))
            }
        }
        let listing = groups.map { ($0.group.isEmpty ? "" : clip($0.group, 40) + ": ") + $0.names.joined(separator: ", ") }.joined(separator: "; ")
        var summary = listing
        if summary.count > 420 {
            summary = String(summary.prefix(420))
            if let cut = summary.range(of: ", ", options: .backwards) ?? summary.range(of: "; ", options: .backwards) {
                summary = String(summary[..<cut.lowerBound])
            }
            summary += "…"
        }
        let count = m.belowCount == 1 ? "1 element" : "\(m.belowCount) elements"
        let place = m.kind == "dialog" ? "this dialog" : "this \(m.kind)"
        let body = summary.isEmpty ? "" : ": " + summary
        return "Further down in \(place) (\(count))\(body). Scroll it with browser.scroll, or use browser.find to reach one."
    }

    /// One element as the model sees it: `b12 button "Sign in" [disabled]`.
    public func line(for e: Element) -> String {
        var s = "\(e.ref) \(e.role)"
        if !e.name.isEmpty { s += " \"\(Self.clip(e.name, 80))\"" }
        if e.secure { s += " [secure]" }
        else if let v = e.value, !v.isEmpty, v != e.name { s += " value=\"\(Self.clip(v, 120))\"" }
        if let t = e.inputType, !["checkbox", "radio", "submit", "button", "password"].contains(t) { s += " type=\(t)" }
        if let c = e.checked { s += c ? " [checked]" : " [unchecked]" }
        if e.selected == true { s += " [selected]" }
        if let x = e.expanded { s += x ? " [expanded]" : " [collapsed]" }
        if e.disabled { s += " [disabled]" }
        if e.focused { s += " [focused]" }
        if let h = e.href, let short = shortHref(h) { s += " → \(short)" }
        if let o = e.options, !o.isEmpty { s += " options: " + Self.clip(o.joined(separator: " | "), 160) }
        if let c = e.context, !c.isEmpty { s += " in \"\(Self.clip(c, 60))\"" }
        return s
    }

    /// Same-site links show just the path; script and empty anchors are omitted.
    func shortHref(_ href: String) -> String? {
        let lower = href.lowercased()
        if lower.hasPrefix("javascript:") { return nil }
        guard let target = URL(string: href) else { return Self.clip(href, 80) }
        if let page = URL(string: url), page.host == target.host, page.scheme == target.scheme {
            var path = target.path.isEmpty ? "/" : target.path
            if let q = target.query { path += "?" + q }
            if path == page.path, target.fragment != nil, target.query == nil {
                return target.fragment.map { "#" + $0 }.flatMap { $0 == "#" ? nil : Self.clip($0, 60) }
            }
            return Self.clip(path, 80)
        }
        return Self.clip(href, 80)
    }

    /// One sentence on what changed since `old`, so the model can tell whether an action did
    /// anything (a click that changed nothing is worth noticing before repeating it).
    public func changeSummary(since old: PageSnapshot?) -> String {
        guard let old else { return "" }
        if Self.stripFragment(old.url) != Self.stripFragment(url) {
            return "Now on “\(Self.clip(title.isEmpty ? url : title, 80))” (\(Self.clip(url, 120)))."
        }
        var parts: [String] = []
        if old.title != title, !title.isEmpty { parts.append("title is now “\(Self.clip(title, 80))”") }
        let oldRefs = Set(old.elements.filter { $0.pinned != true }.map(\.ref)), newRefs = Set(elements.filter { $0.pinned != true }.map(\.ref))
        let added = newRefs.subtracting(oldRefs).count, removed = oldRefs.subtracting(newRefs).count
        if added > 0 { parts.append("\(added) new element\(added == 1 ? "" : "s")") }
        if removed > 0 { parts.append("\(removed) gone") }
        let oldByRef = Dictionary(old.elements.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        let changed = elements.filter { e in
            guard let o = oldByRef[e.ref] else { return false }
            return o.value != e.value || o.checked != e.checked || o.expanded != e.expanded || o.selected != e.selected || o.name != e.name || o.disabled != e.disabled
        }.count
        if changed > 0 { parts.append("\(changed) element\(changed == 1 ? "" : "s") changed") }
        if old.text != text { parts.append("the text changed") }
        if abs(old.scrollY - scrollY) >= 1 { parts.append("scrolled to \(Self.whole(scrollY))") }
        switch (old.modal, modal) {
        case (nil, let m?): parts.append("\(m.title) opened")
        case (let m?, nil): parts.append("\(m.title) closed")
        case (let a?, let b?):
            if a.name != b.name || a.kind != b.kind { parts.append("\(b.title) is open now") }
            else if abs(a.scrollTop - b.scrollTop) >= 1 { parts.append("\(b.title) scrolled to \(Self.whole(b.scrollTop))") }
        case (nil, nil): break
        }
        if parts.isEmpty { return "No visible change on the page." }
        return "Same page; " + parts.joined(separator: ", ") + "."
    }

    /// A short hash of what a person would notice changing: the address and title, the names
    /// and states of the interactive elements in view, the headings, whether a dialog is open,
    /// and how far the page and that dialog are scrolled. Focus, element refs, text that isn't
    /// a control's and timing don't count, so the same page looked at twice hashes the same and
    /// a runner can tell an action that changed nothing.
    public var fingerprint: String {
        var parts = [url, title, "\(Self.whole(scrollX)),\(Self.whole(scrollY))"]
        if let m = modal { parts.append("\(m.kind)|\(m.name)|\(Self.whole(m.scrollTop)),\(Self.whole(m.scrollLeft))") }
        if botCheck != nil { parts.append("bot-check") }
        parts += headings.map { "h\($0.level) \($0.text)" }
        parts += elements.filter { $0.inViewport && $0.pinned != true }.map { e in
            let flags = [e.checked.map { $0 ? "c" : "u" }, e.selected == true ? "s" : nil, e.expanded.map { $0 ? "x" : "z" }, e.disabled ? "d" : nil]
            return [e.role, e.name, e.value ?? "", flags.compactMap { $0 }.joined()].joined(separator: "\u{1F}")
        }.sorted()
        // FNV-1a: stable across launches, unlike Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{1E}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// Small structured form for step runners: refs with roles and names (no text), the page's
    /// `fingerprint`, and `botCheck: true` on a CAPTCHA or bot check.
    public var modelData: JSONValue {
        var o: [String: JSONValue] = [
            "tab_id": .string(tabID),
            "url": .string(url),
            "title": .string(title),
            "fingerprint": .string(fingerprint),
            "elements": .array(elements.map { e in
                var o: [String: JSONValue] = ["ref": .string(e.ref), "role": .string(e.role), "name": .string(Self.clip(e.name, 80))]
                if e.secure { o["secure"] = true }
                return .object(o)
            }),
        ]
        if botCheck != nil { o["botCheck"] = true }
        if let m = modal { o["dialog"] = .string(m.name) }
        return .object(o)
    }

    /// A page-supplied number as a whole number, without trapping on huge or non-finite values.
    static func whole(_ d: Double) -> Int {
        guard d.isFinite else { return 0 }
        return Int(max(-1e15, min(1e15, d.rounded())))
    }

    static func stripFragment(_ s: String) -> String {
        guard let i = s.firstIndex(of: "#") else { return s }
        return String(s[..<i])
    }

    /// One line, no double quotes, at most `n` characters (plus an ellipsis).
    public static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }
}

/// Readable text of a page or of the elements matching a selector.
public struct PageText: Sendable, Hashable {
    public var url: String
    public var title: String
    public var text: String
    /// Length before capping.
    public var total: Int
}

/// What an action did besides its main effect.
public struct BrowserActionOutcome: Sendable, Hashable {
    /// False when the page was still busy at the settle timeout.
    public var settled: Bool
    /// Notes for the model: script fallbacks, dialogs answered, disabled targets.
    public var notes: [String]
    /// The field's value after typing, or the option chosen.
    public var value: String?
    /// For a scroll: whether anything moved.
    public var moved: Bool
    /// For a scroll: what moved, or what Glide tried to move ("the page", "the “Filters” dialog").
    public var scrolled: String?

    public init(settled: Bool = true, notes: [String] = [], value: String? = nil, moved: Bool = true, scrolled: String? = nil) {
        self.settled = settled
        self.notes = notes
        self.value = value
        self.moved = moved
        self.scrolled = scrolled
    }
}

/// What `BrowserDriver.find` found: the best match, scrolled into view and listed in `snapshot`
/// with a ref, and where the other matches are.
public struct BrowserFindResult: Sendable {
    public struct Match: Sendable, Hashable {
        public var ref: String
        public var role: String
        public var name: String
        /// Where it was when Glide looked, e.g. "in dialog “Filters”, further down".
        public var location: String
        /// Its rank among the matches: the `nth` that picks it.
        public var nth: Int

        public init(ref: String, role: String, name: String, location: String, nth: Int) {
            self.ref = ref
            self.role = role
            self.name = name
            self.location = location
            self.nth = nth
        }
    }

    /// The page after scrolling; the match and the other matches are in it (refs Glide could
    /// keep: hidden ones may be missing).
    public var snapshot: PageSnapshot
    /// Nil when nothing matched (or `nth` was beyond the matches).
    public var match: Match?
    /// True when the match was out of view and Glide scrolled to it.
    public var scrolled: Bool
    /// True when it's still out of view after scrolling (hidden, or in a part of the page that
    /// doesn't scroll).
    public var stillOutOfView: Bool
    /// The next best matches (up to eight).
    public var others: [Match]
    /// Matches in all, for the role asked for.
    public var total: Int
    /// When nothing had the role asked for: the roles of the elements with that text.
    public var otherRoles: [String]
    /// When nothing matched at all: labels on the page that look close.
    public var suggestions: [String]
}

/// What `browser.wait` waits for.
public enum BrowserWaitCondition: Sendable, Hashable {
    case text(String)
    case selector(String)
    case load
}

// MARK: - Driver

/// Snapshots, clicks, typing and reading on top of any `BrowserBackend`.
///
/// Thread-safe: per-tab state (the ref counter and the last snapshot) sits behind a mutex and
/// every page operation is a self-contained CDP round trip, so several tabs can be driven at
/// once (parallel job items each get their own tab).
public final class BrowserDriver: Sendable {
    public let backend: any BrowserBackend
    /// Longest wait for a page to settle after navigation or an action.
    public let settleTimeout: TimeInterval

    private struct TabState {
        /// Highest ref number handed out in this tab. Kept across navigations so a ref from an
        /// old page can never silently name an element on the new one.
        var nextRef = 0
        var last: PageSnapshot?
        var touched = Date()
    }

    /// Tabs whose state is kept; beyond this the least recently snapshotted are dropped (tabs
    /// closed outside Glide never tell the driver).
    static let maxTrackedTabs = 64

    private let tabState = Mutex<[String: TabState]>([:])

    public init(backend: any BrowserBackend, settleTimeout: TimeInterval = 15) {
        self.backend = backend
        self.settleTimeout = settleTimeout
    }

    /// The most recent snapshot taken through this driver for `tabID`.
    public func lastSnapshot(tabID: String) -> PageSnapshot? { tabState.withLock { $0[tabID]?.last } }

    /// Drops state for a closed tab.
    public func forget(tabID: String) { _ = tabState.withLock { $0.removeValue(forKey: tabID) } }

    // MARK: Tabs

    // Tab management goes through the driver so every backend call has a deadline and stops
    // promptly when the task is cancelled, whatever the backend does.

    public func tabs() async throws -> [BrowserTab] {
        try await withDeadline(15, BrowserError.timeout("listing Chrome's tabs")) { [backend] in try await backend.tabs() }
    }

    /// Opens a tab (in the background unless `background` is false) and, for a real page,
    /// waits for it to settle.
    public func openTab(url: String, background: Bool) async throws -> BrowserTab {
        let target = url.isEmpty || url == "about:blank" ? "about:blank" : try Self.checkedURL(url)
        let tab = try await withDeadline(40, BrowserError.timeout("opening \(target)")) { [backend] in
            try await backend.openTab(url: target, background: background)
        }
        // A new tab starts on an empty page, which is "loaded" at once; wait for the real one.
        if target != "about:blank" { _ = try await settle(tabID: tab.id, timeout: nil, leaving: .blankPage) }
        return tab
    }

    public func closeTab(_ tabID: String) async throws {
        try await withDeadline(15, BrowserError.timeout("closing the tab")) { [backend] in try await backend.closeTab(tabID) }
        forget(tabID: tabID)
    }

    public func activateTab(_ tabID: String) async throws {
        try await withDeadline(15, BrowserError.timeout("switching tabs")) { [backend] in try await backend.activateTab(tabID) }
    }

    // MARK: Snapshot

    /// `pin` lists refs that must be in the snapshot even beyond `maxElements` or when they
    /// aren't ordinary controls (what `find` found).
    public func snapshot(tabID: String, maxElements: Int = 300, maxTextChars: Int = 6000, pin: [String] = []) async throws -> PageSnapshot {
        let seq = tabState.withLock { $0[tabID]?.nextRef ?? 0 }
        let args: JSONValue = ["seq": .number(Double(seq)), "max": .number(Double(max(1, maxElements))), "maxText": .number(Double(max(0, maxTextChars))),
                               "pin": .array(pin.prefix(20).map { .string($0) })]
        let v = try await evaluate(tabID: tabID, Self.call(Self.snapshotFunction, args), timeout: 25)
        guard v.objectValue != nil else { throw BrowserError.cdp("The page didn't return a snapshot.") }
        let snap = Self.decodeSnapshot(v, tabID: tabID)
        if Self.isRestricted(url: snap.url) { throw BrowserError.restrictedPage(snap.url) }
        let newSeq = Self.count(v["seq"]) ?? seq
        tabState.withLock { state in
            var s = state[tabID] ?? TabState()
            s.nextRef = max(s.nextRef, newSeq)
            s.last = snap
            s.touched = Date()
            state[tabID] = s
            if state.count > Self.maxTrackedTabs, let oldest = state.min(by: { $0.value.touched < $1.value.touched })?.key, oldest != tabID {
                state[oldest] = nil
            }
        }
        return snap
    }

    // MARK: Find

    /// Looks through the whole page — off-screen parts, scrolled panels and dialogs, open shadow
    /// roots, same-origin frames — for elements whose text, label, placeholder, title, alt text
    /// or (non-secret) value contains `text`, case-insensitively. Controls rank first, then
    /// visible before hidden, exact before partial, in view before out of view. The `nth` best
    /// is scrolled into view (nested panels too) and gets a ref in the same space as snapshots,
    /// so `click` and `type` accept it; the next few get refs as well.
    ///
    /// `role` keeps only elements of that role ("textbox" also takes search boxes and
    /// comboboxes, "checkbox" switches).
    public func find(tabID: String, text: String, role: String? = nil, nth: Int = 1) async throws -> BrowserFindResult {
        let seq = tabState.withLock { $0[tabID]?.nextRef ?? 0 }
        let args: JSONValue = ["seq": .number(Double(seq)), "text": .string(text), "role": role.map { .string($0) } ?? .null,
                               "nth": .number(Double(min(1000, max(1, nth))))]
        let r = try await evaluate(tabID: tabID, Self.call(Self.findFunction, args), timeout: 25)
        guard r.objectValue != nil else { throw BrowserError.cdp("The page didn't answer the search.") }
        if let url = r["url"]?.stringValue, Self.isRestricted(url: url) { throw BrowserError.restrictedPage(url) }
        if let newSeq = Self.count(r["seq"]) {
            tabState.withLock { state in
                var s = state[tabID] ?? TabState()
                s.nextRef = max(s.nextRef, newSeq)
                state[tabID] = s
            }
        }
        func decode(_ v: JSONValue?) -> BrowserFindResult.Match? {
            guard let v, let ref = v["ref"]?.stringValue, (try? Self.validate(ref: ref)) != nil else { return nil }
            return BrowserFindResult.Match(ref: ref, role: v["role"]?.stringValue ?? "element", name: v["name"]?.stringValue ?? "",
                                           location: v["where"]?.stringValue ?? "", nth: Self.count(v["nth"]) ?? 1)
        }
        let match = r["found"]?.boolValue == true ? decode(r["match"]) : nil
        let others = (r["others"]?.arrayValue ?? []).compactMap { decode($0) }
        let scrolled = match != nil && r["scrolled"]?.boolValue == true
        // Scrolling can load lazy content; give it a moment, but don't wait for a busy page.
        if scrolled { _ = try await waitForSettle(tabID: tabID, timeout: 1) }
        let pins = (match.map { [$0.ref] } ?? []) + others.map(\.ref)
        let snap = try await snapshot(tabID: tabID, pin: pins)
        let stillOut = match.map { m in snap.element(m.ref).map { !$0.inViewport } ?? true } ?? false
        return BrowserFindResult(snapshot: snap, match: match, scrolled: scrolled, stillOutOfView: stillOut, others: others,
                                 total: Self.count(r["total"]) ?? 0,
                                 otherRoles: (r["roles"]?.arrayValue ?? []).compactMap(\.stringValue),
                                 suggestions: (r["suggestions"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    // MARK: Actions

    /// Clicks the element: scrolls it to the center, then real mouse events at its center. When
    /// something else covers it, falls back to `element.click()`. Waits for the page to settle.
    public func click(tabID: String, ref: String) async throws -> BrowserActionOutcome {
        try Self.validate(ref: ref)
        let r = try await evaluate(tabID: tabID, Self.call(Self.clickFunction, ["ref": .string(ref), "expect": expectedName(tabID: tabID, ref: ref)]), userGesture: true)
        try Self.throwIfError(r, ref: ref)
        var notes: [String] = []
        if r["disabled"]?.boolValue == true { notes.append("\(ref) is disabled, so the click probably did nothing.") }
        if r["method"]?.stringValue == "mouse", let x = r["x"]?.doubleValue, let y = r["y"]?.doubleValue {
            try await mouseClick(tabID: tabID, x: x, y: y)
        } else {
            let covered = r["covered"]?.stringValue ?? ""
            notes.append(covered.isEmpty ? "Clicked \(ref) by script (it isn't on screen)." : "Clicked \(ref) by script because \(covered) covers it.")
        }
        let settled = try await waitForSettle(tabID: tabID)
        notes += await dialogNotes(tabID: tabID)
        return BrowserActionOutcome(settled: settled, notes: notes)
    }

    /// Types into a text field or rich-text area: focus, optionally clear (select all, then
    /// Backspace), insert the text, optionally press Enter. Refuses password fields.
    /// `clear: nil` clears form fields but appends to rich-text areas.
    public func type(tabID: String, ref: String, text: String, clear: Bool? = nil, submit: Bool = false) async throws -> BrowserActionOutcome {
        try Self.validate(ref: ref)
        let focusArgs: JSONValue = ["ref": .string(ref), "clear": clear.map { .bool($0) } ?? .null, "expect": expectedName(tabID: tabID, ref: ref)]
        var r = try await evaluate(tabID: tabID, Self.call(Self.focusFunction, focusArgs), userGesture: true)
        try Self.throwIfError(r, ref: ref)
        if r["focused"]?.boolValue != true, let x = r["x"]?.doubleValue, let y = r["y"]?.doubleValue {
            // Some widgets only take focus from a real click.
            try await mouseClick(tabID: tabID, x: x, y: y)
            r = try await evaluate(tabID: tabID, Self.call(Self.focusFunction, focusArgs), userGesture: true)
            try Self.throwIfError(r, ref: ref)
            guard r["focused"]?.boolValue == true else { throw BrowserActionError("Couldn't put the cursor in \(ref). Click it first, then type.") }
        }
        let clearing = r["clear"]?.boolValue ?? false
        if clearing, r["hadText"]?.boolValue == true {
            try await pressStrokes(tabID: tabID, try BrowserKeys.parse("Backspace"))
            if try await currentValue(tabID: tabID, ref: ref)?.isEmpty == false {
                try await pressStrokes(tabID: tabID, try BrowserKeys.parse("Meta+A Backspace"))
            }
            if try await currentValue(tabID: tabID, ref: ref)?.isEmpty == false {
                _ = try await evaluate(tabID: tabID, Self.call(Self.forceClearFunction, ["ref": .string(ref)]))
            }
        }
        if !text.isEmpty {
            _ = try await send(tabID: tabID, "Input.insertText", ["text": .string(text)])
        }
        let value = try await currentValue(tabID: tabID, ref: ref)
        var settled = true
        if submit {
            try await pressStrokes(tabID: tabID, try BrowserKeys.parse("Enter"))
            settled = try await waitForSettle(tabID: tabID)
        } else {
            settled = try await waitForSettle(tabID: tabID, timeout: 3)
        }
        let notes = await dialogNotes(tabID: tabID)
        return BrowserActionOutcome(settled: settled, notes: notes, value: value)
    }

    /// Chooses an option of a `<select>` by value or visible label, then fires `input` and
    /// `change` so frameworks notice.
    public func select(tabID: String, ref: String, value: String) async throws -> BrowserActionOutcome {
        try Self.validate(ref: ref)
        let args: JSONValue = ["ref": .string(ref), "value": .string(value), "expect": expectedName(tabID: tabID, ref: ref)]
        let r = try await evaluate(tabID: tabID, Self.call(Self.selectFunction, args), userGesture: true)
        try Self.throwIfError(r, ref: ref)
        let settled = try await waitForSettle(tabID: tabID)
        let notes = await dialogNotes(tabID: tabID)
        return BrowserActionOutcome(settled: settled, notes: notes, value: r["selected"]?.stringValue)
    }

    /// Presses keys in the focused element, e.g. "Enter", "Escape", "Control+A", "Meta+L", or
    /// several separated by spaces ("Tab Tab Enter").
    public func press(tabID: String, keys: String) async throws -> BrowserActionOutcome {
        let strokes = try BrowserKeys.parse(keys)
        _ = try? await evaluate(tabID: tabID, Self.armNavigationScript)
        try await pressStrokes(tabID: tabID, strokes, guardFields: true)
        let settled = try await waitForSettle(tabID: tabID)
        let notes = await dialogNotes(tabID: tabID)
        return BrowserActionOutcome(settled: settled, notes: notes)
    }

    /// Scrolls by `amount` screens: the scrollable panel around `ref` when given; otherwise the
    /// open dialog or popup when there is one (the page behind it is usually locked, and what
    /// the person is looking for is in the dialog), else the panel the focused element is in,
    /// else the panel under the viewport center, else the page. Uses script scrolling, which
    /// also works in background tabs; a dialog that only scrolls by script of its own gets a
    /// real mouse wheel over it.
    public func scroll(tabID: String, direction: ScrollDirection, amount: Double = 1, ref: String? = nil) async throws -> BrowserActionOutcome {
        if let ref { try Self.validate(ref: ref) }
        let amount = amount.isFinite ? min(20, max(0.1, amount)) : 1
        let args: JSONValue = ["dir": .string(direction.rawValue), "amount": .number(amount), "ref": ref.map { .string($0) } ?? .null]
        let r = try await evaluate(tabID: tabID, Self.call(Self.scrollFunction, args))
        try Self.throwIfError(r, ref: ref ?? "")
        var moved = r["moved"]?.boolValue == true
        let scope = r["scope"]?.stringValue ?? "the page"
        if !moved, let wheel = r["wheel"], let x = wheel["x"]?.doubleValue, let y = wheel["y"]?.doubleValue, x.isFinite, y.isFinite {
            let span = (wheel["span"]?.doubleValue).flatMap { $0.isFinite ? min(5000, max(50, $0)) : nil } ?? 400
            let delta = (direction == .up || direction == .left ? -1 : 1) * amount * span * 0.85
            let vertical = direction == .up || direction == .down
            moved = try await wheelScroll(tabID: tabID, x: x, y: y, dx: vertical ? 0 : delta, dy: vertical ? delta : 0)
        }
        let settled = try await waitForSettle(tabID: tabID, timeout: 3)
        var notes: [String] = []
        if !moved {
            let edge = direction == .up ? "top" : direction == .down ? "bottom" : "edge"
            if r["stuck"]?.boolValue == true {
                notes.append("Nothing scrolled — \(scope) doesn't scroll.")
            } else {
                notes.append(scope == "the page" ? "Nothing scrolled — already at the \(edge)." : "Nothing scrolled — \(scope) is already at the \(edge).")
            }
        }
        return BrowserActionOutcome(settled: settled, notes: notes, moved: moved, scrolled: scope)
    }

    /// A real mouse wheel at (x, y), for dialogs that scroll by script (wheel handlers moving
    /// their content) rather than by overflow. True when the dialog's content moved.
    private func wheelScroll(tabID: String, x: Double, y: Double, dx: Double, dy: Double) async throws -> Bool {
        let signature = Self.call(Self.modalSignatureFunction, .null)
        let before = try await evaluate(tabID: tabID, signature)
        let event: JSONValue = ["type": "mouseWheel", "x": .number(x), "y": .number(y), "deltaX": .number(dx), "deltaY": .number(dy)]
        _ = try await send(tabID: tabID, "Input.dispatchMouseEvent", event, timeout: 10)
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(60))
            if try await evaluate(tabID: tabID, signature) != before { return true }
        }
        return false
    }

    /// Loads `url` in the tab and waits for it to settle.
    ///
    /// Some backends return before the navigation commits (the extension's `chrome.tabs.update`
    /// replies as soon as it starts), so the page being left is marked first: until the probe
    /// sees a different document (or address), the old page doesn't count as loaded. Except
    /// when the address only adds or repeats a #fragment of the page that's showing: that's a
    /// same-page jump and the marked page stays (any change of address is noticed anyway).
    public func navigate(tabID: String, url: String) async throws -> BrowserActionOutcome {
        let target = try Self.checkedURL(url)
        let mark = UUID().uuidString
        let markedURL = try? await evaluate(tabID: tabID, Self.markDocumentScript(mark), timeout: 3).stringValue
        try await withDeadline(30, BrowserError.timeout("opening \(target)")) { [backend] in
            try await backend.navigate(tabID: tabID, url: target)
        }
        let leaving: PageBeingLeft? = markedURL.flatMap { current in
            Self.isFragmentJump(from: current, to: target) ? nil : .document(mark: mark, url: current)
        }
        let settled = try await settle(tabID: tabID, timeout: nil, leaving: leaving)
        let notes = await dialogNotes(tabID: tabID)
        return BrowserActionOutcome(settled: settled, notes: notes)
    }

    /// Goes back one entry in the tab's history. Returns false when there's no previous page.
    public func back(tabID: String) async throws -> Bool {
        let history = try await send(tabID: tabID, "Page.getNavigationHistory", nil)
        guard let index = history["currentIndex"]?.intValue, index > 0,
              let entry = history["entries"]?[index - 1], let entryID = entry["id"]?.intValue else { return false }
        _ = try? await evaluate(tabID: tabID, Self.armNavigationScript)
        _ = try await send(tabID: tabID, "Page.navigateToHistoryEntry", ["entryId": .number(Double(entryID))])
        _ = try await waitForSettle(tabID: tabID)
        return true
    }

    /// Main-content text (or the text of every element matching `selector`).
    public func readText(tabID: String, maxChars: Int = 8000, selector: String? = nil) async throws -> PageText {
        let args: JSONValue = ["max": .number(Double(max(100, maxChars))), "selector": selector.map { .string($0) } ?? .null]
        let r = try await evaluate(tabID: tabID, Self.call(Self.readFunction, args), timeout: 20)
        if let err = r["error"]?.stringValue {
            switch err {
            case "nomatch": throw BrowserActionError("Nothing on the page matches the selector “\(selector ?? "")”.")
            default: throw BrowserActionError("“\(selector ?? "")” isn't a valid CSS selector (\(r["message"]?.stringValue ?? "syntax error")).")
            }
        }
        let url = r["url"]?.stringValue ?? ""
        if Self.isRestricted(url: url) { throw BrowserError.restrictedPage(url) }
        let text = r["text"]?.stringValue ?? ""
        return PageText(url: url, title: r["title"]?.stringValue ?? "", text: text, total: r["total"]?.intValue ?? text.count)
    }

    /// PNG of the visible viewport, for the vision fallback.
    public func screenshot(tabID: String) async throws -> Data {
        let r = try await send(tabID: tabID, "Page.captureScreenshot", ["format": "png"], timeout: 20)
        guard let b64 = r["data"]?.stringValue, let data = Data(base64Encoded: b64) else {
            throw BrowserError.cdp("Chrome didn't return a screenshot.")
        }
        return data
    }

    /// Waits until text appears, a selector matches a visible element, or the page settles.
    /// Returns false on timeout.
    public func wait(tabID: String, for condition: BrowserWaitCondition, timeout: TimeInterval = 10) async throws -> Bool {
        let limit = min(120, max(0.2, timeout))
        switch condition {
        case .load:
            return try await waitForSettle(tabID: tabID, timeout: limit)
        case .text(let needle), .selector(let needle):
            let isText: Bool = { if case .text = condition { return true } else { return false } }()
            let args: JSONValue = ["kind": .string(isText ? "text" : "selector"), "value": .string(needle)]
            let script = Self.call(Self.waitFunction, args)
            let start = ContinuousClock.now
            while true {
                try Task.checkCancellation()
                do {
                    let r = try await evaluate(tabID: tabID, script, timeout: 5)
                    if r["error"]?.stringValue == "selector" {
                        throw BrowserActionError("“\(needle)” isn't a valid CSS selector (\(r["message"]?.stringValue ?? "syntax error")).")
                    }
                    if r["met"]?.boolValue == true { return true }
                } catch let e as BrowserError {
                    if Self.isFatal(e) { throw e }
                }
                if ContinuousClock.now - start >= .milliseconds(Int(limit * 1000)) { return false }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Waits for a page to be done: `readyState` complete, no navigation pending, the network
    /// quiet for 300 ms (when the backend reports requests) and the DOM no longer growing.
    /// Pages that never go fully quiet (polling, tickers) count as settled once they've been
    /// loaded for a few seconds. Never sleeps longer than one 100 ms poll at a time.
    public func waitForSettle(tabID: String, timeout: TimeInterval? = nil) async throws -> Bool {
        try await settle(tabID: tabID, timeout: timeout, leaving: nil)
    }

    /// The page a navigation is replacing, which must not be mistaken for the new one.
    enum PageBeingLeft {
        /// The document `markDocumentScript` stamped, while it still shows `url` (a change of
        /// address alone means a same-page navigation happened).
        case document(mark: String, url: String)
        /// A new tab's initial empty page.
        case blankPage
    }

    /// How long a page that never went away still counts as "not there yet". A navigation that
    /// doesn't replace the page (a download, an empty response) ends up settling on it.
    static let leftPageGrace: Duration = .seconds(10)

    /// True when loading `target` in a tab showing `current` keeps the document: `target` has a
    /// #fragment and is otherwise the same address (browsers scroll to the fragment instead of
    /// loading the page again, even when the whole address is unchanged).
    static func isFragmentJump(from current: String, to target: String) -> Bool {
        guard target.contains("#"), let a = URLComponents(string: current), let b = URLComponents(string: target) else { return false }
        func page(_ c: URLComponents) -> String {
            let path = c.percentEncodedPath.isEmpty && c.host != nil ? "/" : c.percentEncodedPath
            return [c.scheme?.lowercased() ?? "", c.host?.lowercased() ?? "", c.port.map(String.init) ?? "", path, c.percentEncodedQuery ?? ""].joined(separator: "|")
        }
        return page(a) == page(b)
    }

    private func settle(tabID: String, timeout: TimeInterval?, leaving: PageBeingLeft?) async throws -> Bool {
        let limit = Duration.milliseconds(Int((timeout ?? settleTimeout) * 1000))
        let observer = backend as? any BrowserPageObserving
        let start = ContinuousClock.now
        var lastCount = -1
        var lastURL = ""
        var countChangedAt = start
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            var ready = false
            do {
                let probe = try await evaluate(tabID: tabID, Self.probeScript, timeout: 3)
                let readyState = probe["rs"]?.stringValue ?? ""
                let count = probe["n"]?.intValue ?? 0
                let url = probe["u"]?.stringValue ?? ""
                let navAge = probe["nav"]?.doubleValue ?? -1
                if count != lastCount || url != lastURL {
                    lastCount = count
                    lastURL = url
                    countChangedAt = now
                }
                let navigating = navAge >= 0 && navAge < 10_000
                var stillOldPage = false
                switch leaving {
                case .document(let mark, let markedURL)?: stillOldPage = probe["m"]?.stringValue == mark && url == markedURL
                case .blankPage?: stillOldPage = url.isEmpty || url == "about:blank"
                case nil: break
                }
                if stillOldPage, now - start >= Self.leftPageGrace { stillOldPage = false }
                let complete = readyState == "complete" && !navigating && !stillOldPage
                var activity: BrowserNetworkActivity?
                if let observer { activity = await observer.networkActivity(tabID: tabID) }
                let stableFor = now - countChangedAt
                if let activity {
                    let quiet = activity.inflight == 0 && Date().timeIntervalSince(activity.lastChange) >= 0.3
                    ready = complete && ((quiet && stableFor >= .milliseconds(100)) || stableFor >= .milliseconds(1500))
                } else {
                    ready = complete && stableFor >= .milliseconds(300)
                }
                if complete, now - start >= .seconds(5) { ready = true }
            } catch let e as BrowserError {
                if Self.isFatal(e) { throw e }
                // The old document went away mid-navigation, or the page is busy: poll again.
                lastCount = -1
            }
            if ready { return true }
            if now - start >= limit { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Internals

    /// Runs a script in the tab's main frame and returns its value. Internal on purpose: models
    /// never get to run arbitrary JavaScript.
    func evaluate(tabID: String, _ expression: String, userGesture: Bool = false, timeout: TimeInterval = 15) async throws -> JSONValue {
        let params: JSONValue = ["expression": .string(expression), "returnByValue": true, "awaitPromise": false, "userGesture": .bool(userGesture)]
        let r = try await send(tabID: tabID, "Runtime.evaluate", params, timeout: timeout)
        if let ex = r["exceptionDetails"], !ex.isNull {
            let detail = ex["exception"]?["description"]?.stringValue ?? ex["text"]?.stringValue ?? "unknown error"
            throw BrowserError.cdp("The page's script failed: \(PageSnapshot.clip(detail, 200))")
        }
        return r["result"]?["value"] ?? .null
    }

    /// One CDP call with a deadline, so a hung page can't stall a tool forever.
    func send(tabID: String, _ method: String, _ params: JSONValue?, timeout: TimeInterval = 15) async throws -> JSONValue {
        let backend = self.backend
        return try await withDeadline(timeout, BrowserError.timeout("Chrome didn't finish \(method) within \(Int(timeout)) s")) {
            try await backend.cdp(tabID: tabID, method: method, params: params)
        }
    }

    private func mouseClick(tabID: String, x: Double, y: Double) async throws {
        let point: [String: JSONValue] = ["x": .number(x), "y": .number(y)]
        func event(_ type: String, _ extra: [String: JSONValue]) -> JSONValue {
            .object(point.merging(extra) { $1 }.merging(["type": .string(type)]) { $1 })
        }
        _ = try await send(tabID: tabID, "Input.dispatchMouseEvent", event("mouseMoved", ["button": "none"]), timeout: 10)
        _ = try await send(tabID: tabID, "Input.dispatchMouseEvent", event("mousePressed", ["button": "left", "buttons": 1, "clickCount": 1]), timeout: 10)
        _ = try await send(tabID: tabID, "Input.dispatchMouseEvent", event("mouseReleased", ["button": "left", "buttons": 0, "clickCount": 1]), timeout: 10)
    }

    /// With `guardFields`, every key that puts text in is preceded by a look at the field that
    /// has focus right then. The risk check judged the last snapshot, and focus moves: an earlier
    /// Tab in the same call, or the page itself (code fields that jump to the next box).
    private func pressStrokes(tabID: String, _ strokes: [BrowserKeys.Stroke], guardFields: Bool = false) async throws {
        for stroke in strokes {
            if guardFields, BrowserKeys.insertsText([stroke]) {
                let field = try await evaluate(tabID: tabID, Self.call(Self.focusedFieldFunction, .null))
                switch field["kind"]?.stringValue {
                case "password": throw BrowserActionError("The focused field is a password field. Glide never types passwords; please enter it yourself.")
                case "card": throw BrowserActionError("The focused field is a payment card field. Glide never enters card details; please enter them yourself.")
                default: break
                }
            }
            for event in stroke.events() {
                _ = try await send(tabID: tabID, "Input.dispatchKeyEvent", event, timeout: 10)
            }
        }
    }

    /// The element's name in this tab's last snapshot. Actions check it's unchanged before
    /// acting, so a page that re-labels or swaps elements after the snapshot (and after the
    /// safety check judged that name) can't redirect a click.
    private func expectedName(tabID: String, ref: String) -> JSONValue {
        lastSnapshot(tabID: tabID)?.element(ref).map { .string($0.name) } ?? .null
    }

    private func currentValue(tabID: String, ref: String) async throws -> String? {
        let r = try await evaluate(tabID: tabID, Self.call(Self.valueFunction, ["ref": .string(ref)]))
        if r["secure"]?.boolValue == true { return nil }
        return r["value"]?.stringValue
    }

    private func dialogNotes(tabID: String) async -> [String] {
        guard let observer = backend as? any BrowserPageObserving else { return [] }
        return await observer.takeHandledDialogs(tabID: tabID).map { d in
            let message = d.message.isEmpty ? "" : " “\(PageSnapshot.clip(d.message, 160))”"
            switch d.type {
            case "alert": return "The page showed an alert\(message); Glide closed it."
            case "beforeunload": return "The page asked to confirm leaving; Glide allowed it."
            case "confirm": return "The page asked\(message) — Glide answered Cancel (confirmation dialogs are declined automatically)."
            default: return "The page showed a \(d.type) dialog\(message); Glide \(d.accepted ? "accepted" : "dismissed") it."
            }
        }
    }

    /// Errors that polling again can't fix, so waits stop at once: the tab or connection is
    /// gone, or the page is frozen until the user answers its dialog.
    static func isFatal(_ e: BrowserError) -> Bool {
        switch e {
        case .tabNotFound, .notConnected, .restrictedPage, .chromeNotInstalled, .dialogOpen: return true
        default: return false
        }
    }

    static func validate(ref: String) throws {
        guard ref.count >= 2, ref.count <= 12, ref.first == "b", ref.dropFirst().allSatisfy(\.isASCIIDigit) else {
            throw BrowserError.elementNotFound(ref.isEmpty ? "(empty ref)" : ref)
        }
    }

    static func throwIfError(_ r: JSONValue, ref: String) throws {
        guard let err = r["error"]?.stringValue else { return }
        switch err {
        case "notfound", "ambiguous": throw BrowserError.elementNotFound(ref)
        case "changed":
            let now = r["now"]?.stringValue ?? ""
            throw BrowserActionError("\(ref) changed since the last snapshot\(now.isEmpty ? "" : " (it now reads “\(PageSnapshot.clip(now, 60))”)"). Take a new snapshot before acting on it.")
        case "password": throw BrowserActionError("\(ref) is a password field. Glide never types passwords; please enter it yourself.")
        case "file": throw BrowserActionError("\(ref) opens a file picker, which Glide can't use in Chrome.")
        case "select": throw BrowserActionError("\(ref) is a dropdown. Use browser.select with the option you want instead of clicking it.")
        case "noteditable": throw BrowserActionError("\(ref) (\(r["role"]?.stringValue ?? "element")) isn't a text field. Click it, or pick a text field from the snapshot.")
        case "readonly": throw BrowserActionError("\(ref) is read-only or disabled.")
        case "notselect": throw BrowserActionError("\(ref) (\(r["role"]?.stringValue ?? "element")) isn't a <select> dropdown. Click it and then click the option.")
        case "disabled": throw BrowserActionError("\(ref) is disabled.")
        case "optiondisabled": throw BrowserActionError("That option of \(ref) is disabled.")
        case "nooption":
            let options = r["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
            throw BrowserActionError("\(ref) has no option like that. Options: \(PageSnapshot.clip(options.joined(separator: " | "), 300)).")
        default: throw BrowserActionError("Couldn't act on \(ref): \(err).")
        }
    }

    /// Normalizes `raw` and checks it's something the browser tools may load.
    public static func checkedURL(_ raw: String) throws -> String {
        guard let target = normalizeURL(raw) else { throw BrowserActionError("“\(PageSnapshot.clip(raw, 120))” isn't a web address.") }
        if isRestricted(url: target) { throw BrowserError.restrictedPage(target) }
        guard let scheme = scheme(of: target), navigableSchemes.contains(scheme) else {
            throw BrowserActionError("Glide's browser only opens web pages; “\(PageSnapshot.clip(target, 120))” would open another app.")
        }
        return target
    }

    /// Pages Chrome (and Glide) won't automate: browser UI, extensions, devtools, the Web Store.
    public static func isRestricted(url: String) -> Bool {
        let u = url.lowercased().trimmingCharacters(in: .whitespaces)
        for scheme in ["chrome:", "chrome-extension:", "chrome-search:", "chrome-untrusted:", "devtools:", "edge:", "brave:", "view-source:"] where u.hasPrefix(scheme) {
            return true
        }
        guard let parsed = URL(string: u), let host = parsed.host else { return false }
        if host == "chromewebstore.google.com" { return true }
        if host == "chrome.google.com", parsed.path.hasPrefix("/webstore") { return true }
        return false
    }

    /// Schemes the browser tools load. Others (mailto:, tel:, app links) would hand off to
    /// another app, which is `system.open`'s job, not a background tab's.
    public static let navigableSchemes: Set<String> = ["http", "https", "file", "about", "data", "javascript"]

    /// Adds `https://` to bare domains ("example.com/x", or `http://` for "localhost:3000");
    /// nil for things that aren't addresses.
    public static func normalizeURL(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let scheme = scheme(of: s) {
            return scheme == "http" || scheme == "https" ? s.replacingOccurrences(of: " ", with: "%20") : s
        }
        let lower = s.lowercased()
        let isLocal = lower.hasPrefix("localhost") || lower.hasPrefix("127.") || lower.hasPrefix("[::1]")
        guard !s.contains(" "), s.contains(".") || isLocal else { return nil }
        return (isLocal ? "http://" : "https://") + s
    }

    /// The lowercased scheme of an address that has one; nil for bare hosts, including
    /// host:port forms like "localhost:3000" or "example.com:8080/x".
    public static func scheme(of s: String) -> String? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let candidate = s[..<colon]
        guard let first = candidate.first, first.isLetter, first.isASCII,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        let name = candidate.lowercased()
        if let next = s[s.index(after: colon)...].first, next.isASCIIDigit, !navigableSchemes.contains(name) { return nil }
        return name
    }

    static func call(_ function: String, _ args: JSONValue) -> String {
        "(() => {\n\(library)\nreturn (\(function))(\(args.jsonString()));\n})()"
    }

    /// A non-negative count from the page, or nil (never traps on huge or odd values the way
    /// `Int(Double)` would).
    static func count(_ v: JSONValue?) -> Int? {
        guard let d = v?.doubleValue, d.isFinite, d >= 0 else { return nil }
        return Int(min(d, 1e12))
    }

    static func decodeSnapshot(_ v: JSONValue, tabID: String) -> PageSnapshot {
        func num(_ value: JSONValue?) -> Double { value?.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        func d(_ key: String) -> Double { num(v[key]) }
        let elements: [PageSnapshot.Element] = (v["elements"]?.arrayValue ?? []).compactMap { e in
            guard let ref = e["ref"]?.stringValue else { return nil }
            let secure = e["secure"]?.boolValue ?? false
            return PageSnapshot.Element(
                ref: ref, role: e["role"]?.stringValue ?? "clickable", name: e["name"]?.stringValue ?? "",
                value: secure ? nil : e["value"]?.stringValue, inputType: e["type"]?.stringValue,
                checked: e["checked"]?.boolValue, selected: e["selected"]?.boolValue, expanded: e["expanded"]?.boolValue,
                disabled: e["disabled"]?.boolValue ?? false, focused: e["focused"]?.boolValue ?? false, secure: secure,
                href: e["href"]?.stringValue, options: e["options"]?.arrayValue?.compactMap(\.stringValue), context: e["context"]?.stringValue,
                x: num(e["x"]), y: num(e["y"]), width: num(e["w"]), height: num(e["h"]),
                inViewport: e["inView"]?.boolValue ?? true, inModal: e["inModal"]?.boolValue, offscreen: e["dir"]?.stringValue,
                pinned: e["pinned"]?.boolValue)
        }
        let headings: [PageSnapshot.Heading] = (v["headings"]?.arrayValue ?? []).compactMap { h in
            guard let t = h["text"]?.stringValue else { return nil }
            return PageSnapshot.Heading(level: min(6, max(1, count(h["level"]) ?? 2)), text: t)
        }
        var modal: PageSnapshot.Modal?
        if let m = v["modal"], m.objectValue != nil {
            let hints = (m["below"]?.arrayValue ?? []).compactMap { h -> PageSnapshot.Modal.Hint? in
                guard let name = h["name"]?.stringValue else { return nil }
                return PageSnapshot.Modal.Hint(name: name, group: h["group"]?.stringValue ?? "")
            }
            modal = PageSnapshot.Modal(name: m["name"]?.stringValue ?? "", kind: m["kind"]?.stringValue == "popup" ? "popup" : "dialog",
                                       scrollTop: num(m["st"]), scrollLeft: num(m["sl"]), scrollHeight: num(m["sh"]), clientHeight: num(m["ch"]),
                                       below: hints, belowCount: count(m["belowCount"]) ?? hints.count, aboveCount: count(m["aboveCount"]) ?? 0,
                                       text: m["text"]?.stringValue ?? "")
        }
        var cut: PageSnapshot.Offscreen?
        if let c = v["cut"], c.objectValue != nil {
            cut = PageSnapshot.Offscreen(below: count(c["below"]) ?? 0, above: count(c["above"]) ?? 0, right: count(c["right"]) ?? 0,
                                         left: count(c["left"]) ?? 0, onScreen: count(c["on"]) ?? 0)
        }
        let bot = v["bot"]?.stringValue ?? ""
        let text = v["text"]?.stringValue ?? ""
        return PageSnapshot(tabID: tabID, url: v["url"]?.stringValue ?? "", title: v["title"]?.stringValue ?? "",
                            viewportWidth: d("vw"), viewportHeight: d("vh"), scrollX: d("sx"), scrollY: d("sy"),
                            pageWidth: d("pw"), pageHeight: d("ph"), elements: elements, headings: headings, text: text,
                            textTotal: count(v["textTotal"]) ?? text.count, totalInteractive: count(v["total"]) ?? elements.count,
                            skippedFrames: count(v["skippedFrames"]) ?? 0, modal: modal, cut: cut, botCheck: bot.isEmpty ? nil : bot)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Keys

/// Parses key descriptions ("Enter", "Shift+Tab", "Meta+A") into CDP key events.
enum BrowserKeys {
    struct Stroke: Sendable, Hashable {
        var key: String
        var code: String
        var keyCode: Int
        /// Text the key types, when it types anything.
        var text: String?
        /// CDP modifier bits: Alt 1, Control 2, Meta 4, Shift 8.
        var modifiers: Int
        /// macOS editing commands (CDP synthesized keys don't trigger the native key bindings).
        var commands: [String]

        /// rawKeyDown (modifiers first), char when it types, keyUp — the sequence a real key
        /// press produces, so keydown/keypress/keyup handlers and default actions all run.
        func events() -> [JSONValue] {
            var out: [JSONValue] = []
            var held = 0
            let mods = BrowserKeys.modifierKeys.filter { modifiers & $0.bit != 0 }
            for m in mods {
                held |= m.bit
                out.append(["type": "rawKeyDown", "key": .string(m.key), "code": .string(m.code), "windowsVirtualKeyCode": .number(Double(m.keyCode)),
                            "nativeVirtualKeyCode": .number(Double(m.keyCode)), "modifiers": .number(Double(held)), "location": 1])
            }
            var down: [String: JSONValue] = ["type": "rawKeyDown", "key": .string(key), "code": .string(code),
                                             "windowsVirtualKeyCode": .number(Double(keyCode)), "nativeVirtualKeyCode": .number(Double(keyCode)),
                                             "modifiers": .number(Double(modifiers))]
            if !commands.isEmpty { down["commands"] = .array(commands.map { .string($0) }) }
            out.append(.object(down))
            if let text {
                out.append(["type": "char", "key": .string(key), "code": .string(code), "text": .string(text), "unmodifiedText": .string(text),
                            "windowsVirtualKeyCode": .number(Double(keyCode)), "modifiers": .number(Double(modifiers))])
            }
            out.append(["type": "keyUp", "key": .string(key), "code": .string(code), "windowsVirtualKeyCode": .number(Double(keyCode)),
                        "nativeVirtualKeyCode": .number(Double(keyCode)), "modifiers": .number(Double(modifiers))])
            for m in mods.reversed() {
                held &= ~m.bit
                out.append(["type": "keyUp", "key": .string(m.key), "code": .string(m.code), "windowsVirtualKeyCode": .number(Double(m.keyCode)),
                            "nativeVirtualKeyCode": .number(Double(m.keyCode)), "modifiers": .number(Double(held)), "location": 1])
            }
            return out
        }
    }

    struct Modifier {
        let names: [String]
        let bit: Int
        let key: String
        let code: String
        let keyCode: Int
    }

    static let modifierKeys = [
        Modifier(names: ["control", "ctrl"], bit: 2, key: "Control", code: "ControlLeft", keyCode: 17),
        Modifier(names: ["alt", "option", "opt"], bit: 1, key: "Alt", code: "AltLeft", keyCode: 18),
        Modifier(names: ["shift"], bit: 8, key: "Shift", code: "ShiftLeft", keyCode: 16),
        Modifier(names: ["meta", "cmd", "command", "super"], bit: 4, key: "Meta", code: "MetaLeft", keyCode: 91),
    ]

    /// key, code, Windows key code, text.
    static let named: [String: (String, String, Int, String?)] = [
        "enter": ("Enter", "Enter", 13, "\r"), "return": ("Enter", "Enter", 13, "\r"),
        "tab": ("Tab", "Tab", 9, nil), "escape": ("Escape", "Escape", 27, nil), "esc": ("Escape", "Escape", 27, nil),
        "backspace": ("Backspace", "Backspace", 8, nil), "delete": ("Delete", "Delete", 46, nil), "del": ("Delete", "Delete", 46, nil),
        "space": (" ", "Space", 32, " "), "spacebar": (" ", "Space", 32, " "),
        "arrowup": ("ArrowUp", "ArrowUp", 38, nil), "up": ("ArrowUp", "ArrowUp", 38, nil),
        "arrowdown": ("ArrowDown", "ArrowDown", 40, nil), "down": ("ArrowDown", "ArrowDown", 40, nil),
        "arrowleft": ("ArrowLeft", "ArrowLeft", 37, nil), "left": ("ArrowLeft", "ArrowLeft", 37, nil),
        "arrowright": ("ArrowRight", "ArrowRight", 39, nil), "right": ("ArrowRight", "ArrowRight", 39, nil),
        "home": ("Home", "Home", 36, nil), "end": ("End", "End", 35, nil),
        "pageup": ("PageUp", "PageUp", 33, nil), "pagedown": ("PageDown", "PageDown", 34, nil),
        "insert": ("Insert", "Insert", 45, nil), "plus": ("+", "Equal", 187, "+"),
    ]

    static let punctuation: [Character: (String, Int)] = [
        ",": ("Comma", 188), ".": ("Period", 190), "/": ("Slash", 191), ";": ("Semicolon", 186), "'": ("Quote", 222),
        "[": ("BracketLeft", 219), "]": ("BracketRight", 221), "\\": ("Backslash", 220), "-": ("Minus", 189), "=": ("Equal", 187), "`": ("Backquote", 192),
    ]

    /// Editing shortcuts on macOS, which need explicit commands.
    static let macCommands: [String: String] = [
        "a": "selectAll", "c": "copy", "x": "cut", "v": "paste", "z": "undo",
    ]

    /// Whether the strokes put text into the focused element: a printable character, or paste.
    /// Enter, Tab and plain navigation keys don't, so a login form can still be submitted.
    ///
    /// Paste is Meta+V (sent with the `paste` command) and Shift+Insert, which is Blink's own
    /// Paste key binding and works in Chrome on macOS even without a command. Any Insert with
    /// Shift held counts, as in `BrowserRisk.press`. Nothing else Glide sends pastes: Control+V,
    /// Control+Y (yank) and the other Cocoa bindings only work through commands, and Glide sends
    /// none that insert text.
    static func insertsText(_ strokes: [Stroke]) -> Bool {
        strokes.contains { s in
            if s.commands.contains("paste") { return true }
            if s.key == "Insert", s.modifiers & 8 != 0 { return true }
            guard let text = s.text else { return false }
            return text.unicodeScalars.contains { !CharacterSet.controlCharacters.contains($0) }
        }
    }

    static func parse(_ description: String) throws -> [Stroke] {
        let combos = description.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !combos.isEmpty, combos.count <= 30 else {
            throw BrowserActionError(combos.isEmpty ? "No keys given." : "Too many keys at once (at most 30).")
        }
        return try combos.map(parseCombo)
    }

    static func parseCombo(_ combo: String) throws -> Stroke {
        var parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "Control++" means Control and the plus key.
        if combo.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["plus"] }
        guard let main = parts.last, !main.isEmpty else { throw BrowserActionError("“\(combo)” isn't a key.") }
        var modifiers = 0
        for m in parts.dropLast() {
            guard let mod = modifierKeys.first(where: { $0.names.contains(m.lowercased()) }) else {
                throw BrowserActionError("“\(m)” in “\(combo)” isn't a modifier (use Control, Alt, Shift or Meta).")
            }
            modifiers |= mod.bit
        }
        let typing = modifiers & (1 | 2 | 4) == 0
        let shift = modifiers & 8 != 0
        var stroke: Stroke
        if let n = named[main.lowercased()] {
            stroke = Stroke(key: n.0, code: n.1, keyCode: n.2, text: typing ? n.3 : nil, modifiers: modifiers, commands: [])
        } else if let fn = main.uppercased().dropFirst().isEmpty ? nil : Int(main.uppercased().dropFirst()), main.uppercased().first == "F", (1...12).contains(fn) {
            stroke = Stroke(key: "F\(fn)", code: "F\(fn)", keyCode: 111 + fn, text: nil, modifiers: modifiers, commands: [])
        } else if main.count == 1, let ch = main.first {
            if ch.isLetter, ch.isASCII {
                let lower = String(ch).lowercased(), upper = lower.uppercased()
                let keyCode = Int(upper.unicodeScalars.first?.value ?? 65)
                let key = shift ? upper : lower
                stroke = Stroke(key: key, code: "Key\(upper)", keyCode: keyCode, text: typing ? key : nil, modifiers: modifiers, commands: [])
                if modifiers & 4 != 0, let command = macCommands[lower] {
                    stroke.commands = [shift && lower == "z" ? "redo" : command]
                }
            } else if ch.isASCIIDigit {
                let digit = Int(String(ch)) ?? 0
                stroke = Stroke(key: String(ch), code: "Digit\(digit)", keyCode: 48 + digit, text: typing ? String(ch) : nil, modifiers: modifiers, commands: [])
            } else if let p = punctuation[ch] {
                stroke = Stroke(key: String(ch), code: p.0, keyCode: p.1, text: typing ? String(ch) : nil, modifiers: modifiers, commands: [])
            } else {
                stroke = Stroke(key: String(ch), code: "", keyCode: 0, text: typing ? String(ch) : nil, modifiers: modifiers, commands: [])
            }
        } else {
            throw BrowserActionError("“\(main)” isn't a key Glide knows. Use names like Enter, Tab, Escape, ArrowDown, PageDown, F5, or single characters.")
        }
        return stroke
    }
}

// MARK: - Page scripts

extension BrowserDriver {
    /// Helpers shared by every page script. Scripts run in the page's main frame and walk open
    /// shadow roots and same-origin frames, because modern sites put their controls in both.
    static let library = #"""
    const G = {};
    G.clean = function (s) { return (s == null ? '' : String(s)).replace(/\s+/g, ' ').trim(); };
    G.text = function (el) { return G.clean(el.innerText !== undefined ? el.innerText : el.textContent); };
    G.win = function (el) { return (el && el.ownerDocument && el.ownerDocument.defaultView) || window; };
    G.style = function (el) { return G.win(el).getComputedStyle(el); };
    // gridcell: date pickers' days, which take focus one at a time (tabindex -1 on the rest).
    G.ROLES = new Set(['button', 'link', 'checkbox', 'radio', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'switch',
      'textbox', 'combobox', 'searchbox', 'slider', 'spinbutton', 'listbox', 'treeitem', 'gridcell']);
    G.FIELD_TYPES = new Set(['text', 'search', 'email', 'url', 'tel', 'number', 'password', 'date', 'datetime-local', 'month', 'time', 'week']);
    G.isField = function (el) { return el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && G.FIELD_TYPES.has(el.type)); };
    G.editable = function (el) { return G.isField(el) || el.isContentEditable === true; };
    G.isToggle = function (el) { return !!el && el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio'); };
    G.explicitRole = function (el) { return G.clean(el.getAttribute('role')).split(' ')[0].toLowerCase(); };
    G.walk = function (root, ox, oy, depth, visit, stats, clip) {
      const all = root.querySelectorAll('*');
      for (let i = 0; i < all.length; i++) {
        const el = all[i];
        if (visit(el, ox, oy, clip || null) === false) return false;
        if (el.shadowRoot && G.walk(el.shadowRoot, ox, oy, depth, visit, stats, clip) === false) return false;
        if ((el.tagName === 'IFRAME' || el.tagName === 'FRAME') && depth < 5) {
          let doc = null;
          try { doc = el.contentDocument; } catch (e) { doc = null; }
          const r = el.getBoundingClientRect();
          if (doc && doc.documentElement) {
            // Visit the frame's contents with its offset and the part of the page it shows.
            const fx = ox + r.left + el.clientLeft, fy = oy + r.top + el.clientTop;
            let fc = { l: fx, t: fy, r: fx + el.clientWidth, b: fy + el.clientHeight };
            if (clip) fc = G.meet(fc, clip);
            if (G.walk(doc, fx, fy, depth + 1, visit, stats, fc) === false) return false;
          } else if (stats && r.width > 20 && r.height > 20) {
            stats.skippedFrames += 1;
          }
        }
      }
      return true;
    };
    G.meet = function (a, b) { return { l: Math.max(a.l, b.l), t: Math.max(a.t, b.t), r: Math.min(a.r, b.r), b: Math.min(a.b, b.b) }; };
    G.up = function (n) {
      if (n.parentElement) return n.parentElement;
      const p = n.parentNode;
      return p && p.nodeType === 11 && p.host ? p.host : null;
    };
    G.upDeep = function (n) {
      const p = G.up(n);
      if (p) return p;
      const doc = n.ownerDocument;
      if (doc && doc !== document && n === doc.documentElement) {
        try { return doc.defaultView.frameElement; } catch (e) { return null; }
      }
      return null;
    };
    G.inside = function (root, el) {
      if (!root || !el) return false;
      if (root === el || root.contains(el)) return true;
      return (el.ownerDocument !== root.ownerDocument || el.getRootNode() !== el.ownerDocument) && G.containsDeep(root, el);
    };
    G.find = function (ref) {
      const matches = [];
      G.walk(document, 0, 0, 0, function (el) {
        if (el.getAttribute('data-glide-ref') === ref) { matches.push(el); if (matches.length > 1) return false; }
      }, null);
      if (matches.length === 0) return null;
      if (matches.length > 1) return { ambiguous: true };
      return { el: matches[0] };
    };
    G.containsDeep = function (root, node) {
      for (let i = 0; node && i < 1000; i++) {
        if (node === root) return true;
        if (node.parentNode) node = node.parentNode;
        else if (node.host) node = node.host;
        else if (node.nodeType === 9 && node.defaultView) { try { node = node.defaultView.frameElement; } catch (e) { node = null; } }
        else node = null;
      }
      return false;
    };
    G.deepActive = function () {
      let a = document.activeElement;
      for (let i = 0; a && i < 20; i++) {
        if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
        if (a.tagName === 'IFRAME' || a.tagName === 'FRAME') {
          let d = null;
          try { d = a.contentDocument; } catch (e) { d = null; }
          if (d && d.activeElement && d.activeElement !== d.body) { a = d.activeElement; continue; }
        }
        break;
      }
      return a;
    };
    G.frameOffset = function (el) {
      let x = 0, y = 0, win = G.win(el);
      for (let i = 0; win && win !== window && i < 10; i++) {
        let fe = null;
        try { fe = win.frameElement; } catch (e) { fe = null; }
        if (!fe) break;
        const r = fe.getBoundingClientRect();
        x += r.left + fe.clientLeft;
        y += r.top + fe.clientTop;
        win = G.win(fe);
      }
      return { x: x, y: y };
    };
    G.rect = function (el) {
      const w = G.win(el), vw = w.innerWidth, vh = w.innerHeight;
      const rects = el.getClientRects();
      let first = null;
      for (let i = 0; i < rects.length; i++) {
        const r = rects[i];
        if (r.width <= 0 || r.height <= 0) continue;
        if (!first) first = r;
        if (r.right > 0 && r.bottom > 0 && r.left < vw && r.top < vh) return r;
      }
      return first || el.getBoundingClientRect();
    };
    G.visible = function (el) {
      if (typeof el.checkVisibility === 'function') {
        if (!el.checkVisibility({ checkVisibilityCSS: true })) return false;
      } else {
        const s = G.style(el);
        if (s.display === 'none' || s.visibility === 'hidden') return false;
      }
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0;
    };
    G.drawnByLabel = function (input) {
      if (!G.visible(input)) return true;
      const r = input.getBoundingClientRect();
      if (r.width * r.height <= 4) return true;
      return parseFloat(G.style(input).opacity) < 0.05;
    };
    G.visibleLabel = function (input) {
      const labels = input.labels ? Array.from(input.labels) : [];
      return labels.find(function (l) { return G.visible(l); }) || null;
    };
    G.candidate = function (el) {
      switch (el.tagName) {
        case 'A': return el.hasAttribute('href');
        case 'BUTTON': case 'SELECT': case 'TEXTAREA': case 'SUMMARY': return true;
        case 'INPUT': return el.type !== 'hidden';
        case 'LABEL': return G.isToggle(el.control) && G.drawnByLabel(el.control);
        case 'HTML': case 'BODY': case 'IFRAME': case 'FRAME': case 'SCRIPT': case 'STYLE': case 'TEMPLATE': return false;
      }
      if (el.isContentEditable === true) return !(el.parentElement && el.parentElement.isContentEditable);
      const role = G.explicitRole(el);
      if (role && G.ROLES.has(role)) return true;
      if (el.hasAttribute('onclick')) return true;
      const ti = el.getAttribute('tabindex');
      return ti !== null && ti.trim() !== '' && parseInt(ti, 10) >= 0;
    };
    G.labelledBy = function (el) {
      const ids = G.clean(el.getAttribute('aria-labelledby'));
      if (!ids) return '';
      const root = el.getRootNode();
      return G.clean(ids.split(' ').map(function (id) {
        const n = (root && root.getElementById ? root.getElementById(id) : null) || el.ownerDocument.getElementById(id);
        return n ? G.text(n) : '';
      }).join(' '));
    };
    G.name = function (el) {
      const tag = el.tagName;
      const aria = G.clean(el.getAttribute('aria-label'));
      if (aria) return aria;
      const lb = G.labelledBy(el);
      if (lb) return lb;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
        if (el.labels && el.labels.length) {
          const t = G.clean(Array.from(el.labels).map(G.text).join(' '));
          if (t) return t;
        }
        if (tag === 'INPUT') {
          if (el.type === 'submit' || el.type === 'button' || el.type === 'reset') {
            return G.clean(el.value) || (el.type === 'reset' ? 'Reset' : el.type === 'submit' ? 'Submit' : '');
          }
          if (el.type === 'image') return G.clean(el.alt) || G.clean(el.value) || 'Submit';
        }
      } else if (tag === 'IMG') {
        const alt = G.clean(el.alt);
        if (alt) return alt;
      } else if (!G.editable(el)) {
        let t = G.text(el);
        if (!t) {
          const inner = el.querySelector('img[alt], [aria-label], svg title');
          if (inner) t = G.clean(inner.getAttribute('alt') || inner.getAttribute('aria-label') || inner.textContent);
        }
        if (t) return t.length > 200 ? t.slice(0, 200) : t;
      }
      return G.clean(el.getAttribute('title')) || G.clean(el.getAttribute('placeholder')) || G.clean(el.getAttribute('aria-placeholder')) ||
        G.clean(el.getAttribute('data-placeholder')) || G.clean(el.getAttribute('name')) || '';
    };
    G.role = function (el) {
      const explicit = G.explicitRole(el);
      if (explicit && explicit !== 'presentation' && explicit !== 'none' && explicit !== 'generic') return explicit;
      switch (el.tagName) {
        case 'A': return 'link';
        case 'BUTTON': case 'SUMMARY': return 'button';
        case 'SELECT': return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
        case 'TEXTAREA': return 'textbox';
        case 'LABEL': return el.control && el.control.type === 'radio' ? 'radio' : 'checkbox';
        case 'INPUT': {
          const map = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button', image: 'button',
            range: 'slider', number: 'spinbutton', search: 'searchbox', file: 'button', color: 'button' };
          return map[el.type] || 'textbox';
        }
      }
      if (el.isContentEditable === true) return 'textbox';
      return 'clickable';
    };
    G.dialogName = function (dlg) {
      let n = G.clean(dlg.getAttribute('aria-label')) || G.labelledBy(dlg);
      if (!n) { const h = dlg.querySelector('h1,h2,h3,[role="heading"]'); if (h) n = G.text(h); }
      return n.slice(0, 60);
    };
    G.context = function (el) {
      const dlg = el.closest('dialog,[role="dialog"],[role="alertdialog"]');
      if (dlg) {
        const n = G.dialogName(dlg);
        return 'dialog' + (n ? ' ' + n : '');
      }
      const form = el.form || el.closest('form');
      if (!form) return '';
      const n = G.clean(form.getAttribute('aria-label')) || G.labelledBy(form) || G.clean(form.getAttribute('name')) || G.clean(form.id);
      let action = '';
      try {
        const a = form.getAttribute('action');
        if (a) action = new URL(a, G.win(form).location.href).pathname;
      } catch (e) { action = ''; }
      let out = 'form';
      if (n) out += ' ' + n.slice(0, 40);
      if (action && action !== '/') out += ' → ' + action.slice(0, 60);
      return out;
    };
    G.short = function (el) {
      let s = el.tagName.toLowerCase();
      if (el.id) s += '#' + el.id;
      const t = G.text(el).slice(0, 40);
      if (t) s += ' "' + t + '"';
      return s;
    };
    G.hit = function (x, y) {
      let el = document.elementFromPoint(x, y), ox = 0, oy = 0;
      for (let i = 0; el && i < 20; i++) {
        if (el.shadowRoot) {
          const inner = el.shadowRoot.elementFromPoint(x - ox, y - oy);
          if (inner && inner !== el && !G.containsDeep(inner, el)) { el = inner; continue; }
        }
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          let d = null;
          try { d = el.contentDocument; } catch (e) { d = null; }
          if (d) {
            const r = el.getBoundingClientRect();
            const nx = ox + r.left + el.clientLeft, ny = oy + r.top + el.clientTop;
            const inner = d.elementFromPoint(x - nx, y - ny);
            if (inner) { el = inner; ox = nx; oy = ny; continue; }
          }
        }
        break;
      }
      return el;
    };
    G.scriptClick = function (el) {
      if (typeof el.click === 'function') { el.click(); return; }
      el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true, view: G.win(el) }));
    };
    G.armNav = function () {
      try {
        if (!window.__glideNavHook) {
          window.__glideNavHook = true;
          window.addEventListener('beforeunload', function () { window.__glideNavAt = Date.now(); }, true);
        }
        window.__glideNavAt = 0;
      } catch (e) {}
    };
    G.changed = function (el, expect) {
      if (typeof expect !== 'string') return null;
      const now = G.name(el);
      return now === expect ? null : { error: 'changed', now: now };
    };
    G.editTarget = function (el) {
      if (el.tagName === 'LABEL' && el.control) el = el.control;
      if (!G.editable(el)) {
        const inner = el.querySelector('input,textarea,[contenteditable]:not([contenteditable="false"])');
        if (inner && G.editable(inner)) el = inner;
      }
      return el;
    };
    G.placeCaret = function (el, field, selectAll) {
      if (field) {
        try {
          if (selectAll) el.select();
          else { const n = (el.value || '').length; el.setSelectionRange(n, n); }
        } catch (e) {}
        return;
      }
      const sel = G.win(el).getSelection();
      if (!sel) return;
      const range = el.ownerDocument.createRange();
      range.selectNodeContents(el);
      if (!selectAll) range.collapse(false);
      sel.removeAllRanges();
      sel.addRange(range);
    };
    G.norm = function (t) {
      return (t || '').replace(/ /g, ' ').replace(/[ \t\r\f\v]+/g, ' ').replace(/ ?\n ?/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    };
    G.mainRoot = function () {
      let root = document.querySelector('main,[role="main"]');
      if (!root) {
        const articles = document.querySelectorAll('article');
        if (articles.length === 1) root = articles[0];
      }
      return root;
    };
    G.isDialog = function (el) {
      if (!el || el.nodeType !== 1) return false;
      if (el.tagName === 'DIALOG') return el.open === true;
      const r = G.explicitRole(el);
      return r === 'dialog' || r === 'alertdialog' || el.getAttribute('aria-modal') === 'true';
    };
    G.closestDialog = function (el) {
      for (let n = el, i = 0; n && i < 400; n = G.upDeep(n), i++) { if (G.isDialog(n)) return n; }
      return null;
    };
    // The dialog or popup in front of the page: a dialog under the viewport center, else a
    // modal one anywhere on screen (big enough not to be a cookie strip), else a fixed overlay
    // with a z-index that covers the center (a drawer or lightbox that doesn't say it's a dialog).
    G.modal = function () {
      const vw = window.innerWidth, vh = window.innerHeight;
      const hit = G.hit(vw / 2, vh / 2);
      for (let n = hit, i = 0; n && i < 400; n = G.upDeep(n), i++) {
        if (G.isDialog(n) && G.visible(n)) return { el: n, kind: 'dialog' };
      }
      const list = document.querySelectorAll('dialog[open],[aria-modal="true"]');
      for (let i = list.length - 1; i >= 0; i--) {
        const d = list[i];
        if (!G.visible(d) || d.closest('[aria-hidden="true"],[inert]')) continue;
        const r = d.getBoundingClientRect();
        if (r.right <= 0 || r.bottom <= 0 || r.left >= vw || r.top >= vh) continue;
        let modal = false;
        try { modal = d.matches(':modal'); } catch (e) { modal = false; }
        if (modal || (d.getAttribute('aria-modal') === 'true' && r.width * r.height >= vw * vh * 0.2)) return { el: d, kind: 'dialog' };
      }
      for (let n = hit, i = 0; n && i < 400; n = G.up(n), i++) {
        const doc = n.ownerDocument;
        if (n === doc.body || n === doc.documentElement) break;
        const s = G.style(n);
        if (s.position === 'fixed') {
          const r = n.getBoundingClientRect(), z = parseInt(s.zIndex, 10);
          if (z > 0 && r.width * r.height >= vw * vh * 0.15) return { el: n, kind: 'popup' };
          break;
        }
      }
      return null;
    };
    G.modalTitle = function (m) {
      const n = G.dialogName(m.el);
      return n ? 'the “' + n + '” ' + m.kind : 'the ' + m.kind;
    };
    G.canScroll = function (el, vertical) {
      if (vertical ? el.scrollHeight <= el.clientHeight + 1 : el.scrollWidth <= el.clientWidth + 1) return false;
      const s = G.style(el);
      return /(auto|scroll|overlay)/.test(vertical ? s.overflowY : s.overflowX);
    };
    // Scrollable regions of a dialog, best first: the one under `hit`, the dialog itself, its largest.
    G.scrollersIn = function (root, vertical, hit) {
      const out = [];
      if (hit && G.inside(root, hit)) {
        for (let n = hit, i = 0; n && n !== root && i < 300; n = G.up(n), i++) {
          if (n.nodeType === 1 && G.canScroll(n, vertical)) { out.push(n); break; }
        }
      }
      if (G.canScroll(root, vertical) && out.indexOf(root) < 0) out.push(root);
      let best = null, area = 0;
      const all = root.querySelectorAll('*');
      for (let i = 0; i < all.length && i < 5000; i++) {
        const el = all[i];
        if (el.clientHeight < 20 || el.clientWidth < 20 || !G.canScroll(el, vertical)) continue;
        const size = el.clientWidth * el.clientHeight;
        if (size > area) { area = size; best = el; }
      }
      if (best && out.indexOf(best) < 0) out.push(best);
      return out;
    };
    // clip(el): the box (in el's frame) its scrollable ancestors let it show in, or null. Each
    // ancestor is measured once per call of G.clipper, so a whole snapshot stays linear.
    G.clipper = function () {
      const memo = new Map();
      const eff = function (el) {
        if (!el || el.nodeType !== 1) return null;
        if (memo.has(el)) return memo.get(el);
        const doc = el.ownerDocument, s = G.style(el);
        let c = s.position === 'fixed' ? null : eff(G.up(el));
        if (el !== doc.documentElement && el !== doc.body && (s.overflowX !== 'visible' || s.overflowY !== 'visible') &&
            (el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1)) {
          const r = el.getBoundingClientRect(), l = r.left + el.clientLeft, t = r.top + el.clientTop;
          const box = { l: l, t: t, r: l + el.clientWidth, b: t + el.clientHeight };
          c = c ? G.meet(c, box) : box;
        }
        memo.set(el, c);
        return c;
      };
      return function (el) { return G.style(el).position === 'fixed' ? null : eff(G.up(el)); };
    };
    // The part of the top viewport the frames around el show, or null outside frames.
    G.frameBox = function (el) {
      let box = null, win = G.win(el);
      for (let i = 0; win && win !== window && i < 10; i++) {
        let fe = null;
        try { fe = win.frameElement; } catch (e) { fe = null; }
        if (!fe) break;
        const r = fe.getBoundingClientRect(), o = G.frameOffset(fe);
        const l = o.x + r.left + fe.clientLeft, t = o.y + r.top + fe.clientTop;
        const b = { l: l, t: t, r: l + fe.clientWidth, b: t + fe.clientHeight };
        box = box ? G.meet(box, b) : b;
        win = G.win(fe);
      }
      return box;
    };
    // Where el is relative to what's visible: dir 'in', 'below', 'above', 'right' or 'left';
    // inner when a scrolled panel or frame cuts it off rather than the window's edge; dist how
    // far (in CSS pixels) it is from coming into view.
    G.placement = function (el, clipOf) {
      const vw = window.innerWidth, vh = window.innerHeight;
      const r = G.rect(el), o = G.frameOffset(el);
      const x = r.left + o.x, y = r.top + o.y, w = r.width, h = r.height;
      let inner = G.frameBox(el);
      const c = clipOf(el);
      if (c) {
        const cb = { l: c.l + o.x, t: c.t + o.y, r: c.r + o.x, b: c.b + o.y };
        inner = inner ? G.meet(inner, cb) : cb;
      }
      const box = inner ? G.meet({ l: 0, t: 0, r: vw, b: vh }, inner) : { l: 0, t: 0, r: vw, b: vh };
      if (x < box.r && y < box.b && x + w > box.l && y + h > box.t) return { dir: 'in', inner: false, screens: 0, dist: 0 };
      const dir = y >= box.b - 1 ? 'below' : y + h <= box.t + 1 ? 'above' : x >= box.r - 1 ? 'right' : 'left';
      const dist = dir === 'below' ? y - box.b : dir === 'above' ? box.t - (y + h) : dir === 'right' ? x - box.r : box.l - (x + w);
      const inWindow = x < vw && y < vh && x + w > 0 && y + h > 0;
      const cutByPanel = !!inner && (inWindow || (dir === 'below' ? y >= inner.b - 1 : dir === 'above' ? y + h <= inner.t + 1 :
        dir === 'right' ? x >= inner.r - 1 : x + w <= inner.l + 1));
      const screens = dir === 'below' ? Math.round((y - vh) / vh) + 1 : dir === 'above' ? Math.round(-(y + h) / vh) + 1 : 0;
      return { dir: dir, inner: cutByPanel, screens: screens, dist: Math.max(0, dist) };
    };
    // Scrolls el to the middle of every scrollable box around it, then makes sure the frames
    // it sits in are on screen too.
    G.reveal = function (el) {
      try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (e) {}
      let win = G.win(el);
      for (let i = 0; win && win !== window && i < 10; i++) {
        let fe = null;
        try { fe = win.frameElement; } catch (e) { fe = null; }
        if (!fe) break;
        const r = G.rect(el), o = G.frameOffset(el);
        const x = o.x + r.left + r.width / 2, y = o.y + r.top + r.height / 2;
        if (x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight) break;
        try { fe.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (e) {}
        win = G.win(fe);
      }
    };
    G.fold = function (s) {
      return G.clean(s).toLowerCase().replace(/[‘’ʼ′]/g, "'").replace(/[“”″]/g, '"');
    };
    // How well hay contains needle (already folded): 0 exactly, 1 as its first words, 2 as
    // whole words elsewhere, 3 inside a word, -1 not at all.
    G.quality = function (hay, needle) {
      if (hay == null) return -1;
      const h = G.fold(hay);
      if (!h) return -1;
      if (h === needle) return 0;
      const i = h.indexOf(needle);
      if (i < 0) return -1;
      const W = /[\p{L}\p{N}]/u;
      const start = i === 0 || !W.test(h.charAt(i - 1));
      const end = i + needle.length >= h.length || !W.test(h.charAt(i + needle.length));
      if (start && end) return i === 0 ? 1 : 2;
      return 3;
    };
    G.fieldValue = function (el) {
      const tag = el.tagName;
      if (tag === 'INPUT') {
        if (el.type === 'password' || el.type === 'hidden' || G.isToggle(el) || ['button', 'submit', 'reset', 'image', 'file'].indexOf(el.type) >= 0) return '';
        return el.value || '';
      }
      if (tag === 'TEXTAREA') return el.value || '';
      if (tag === 'SELECT') return Array.from(el.selectedOptions).map(function (op) { return G.clean(op.label || op.text); }).join(', ');
      return '';
    };
    // What acting on a piece of text means: the control it belongs to (a label's input), else
    // the element that shows a pointer over it, else the text's own element.
    G.target = function (el) {
      for (let n = el, i = 0; n && i < 8; n = G.up(n), i++) {
        const doc = n.ownerDocument;
        if (n === doc.body || n === doc.documentElement) break;
        if (n.tagName === 'LABEL' && n.control) return { el: G.candidate(n) ? n : n.control, kind: 'control' };
        if (G.candidate(n)) return { el: n, kind: 'control' };
      }
      for (let n = el, i = 0; n && i < 4; n = G.up(n), i++) {
        const doc = n.ownerDocument;
        if (n === doc.body || n === doc.documentElement) break;
        if (G.style(n).cursor === 'pointer') {
          let root = n;
          for (let j = 0; j < 6; j++) {
            const p = G.up(root);
            if (!p || p === p.ownerDocument.body || G.style(p).cursor !== 'pointer') break;
            root = p;
          }
          return { el: root, kind: 'clickable' };
        }
      }
      return { el: el, kind: 'text' };
    };
    // Edit distance of at most 2 (short words only).
    G.near = function (s, t) {
      if (s.length > 24 || t.length > 24 || Math.abs(s.length - t.length) > 2) return false;
      let prev = [];
      for (let j = 0; j <= t.length; j++) prev[j] = j;
      for (let i = 1; i <= s.length; i++) {
        const cur = [i];
        let low = i;
        for (let j = 1; j <= t.length; j++) {
          cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (s[i - 1] === t[j - 1] ? 0 : 1));
          if (cur[j] < low) low = cur[j];
        }
        if (low > 2) return false;
        prev = cur;
      }
      return prev[t.length] <= 2;
    };
    // Control names that look like what was asked for: shared words, prefixes, small typos.
    G.suggest = function (names, needle) {
      const split = function (s) { return s.split(/[^\p{L}\p{N}]+/u).filter(Boolean); };
      const words = split(needle).filter(function (w) { return w.length >= 3; });
      if (!words.length) return [];
      const seen = new Set(), scored = [];
      for (let k = 0; k < names.length; k++) {
        const name = G.clean(names[k]);
        if (!name || name.length > 80) continue;
        const key = G.fold(name);
        if (seen.has(key)) continue;
        seen.add(key);
        const own = split(key);
        let score = 0;
        for (const w of words) {
          let best = 0;
          for (const nw of own) {
            if (nw === w) { best = 3; break; }
            if (nw.length >= 3 && (nw.indexOf(w) === 0 || w.indexOf(nw) === 0)) best = Math.max(best, 2);
            else if (w.length >= 4 && G.near(nw, w)) best = Math.max(best, 2);
          }
          score += best;
        }
        if (score > 0) scored.push({ name: name, score: score });
      }
      scored.sort(function (p, q) { return (q.score - p.score) || (p.name.length - q.name.length); });
      return scored.slice(0, 5).map(function (s) { return s.name; });
    };
    // CAPTCHA and bot-check pages: a challenge frame, or their wording on a short page.
    G.captchaFrame = function (src) {
      const s = String(src || '').toLowerCase();
      if (/\/recaptcha\/(api2|enterprise)\/bframe/.test(s)) return { name: 'reCAPTCHA', strong: true };
      if (/\/recaptcha\/(api2|enterprise)\/anchor/.test(s)) return s.indexOf('size=invisible') >= 0 ? null : { name: 'reCAPTCHA', strong: false };
      if (s.indexOf('hcaptcha.com') >= 0) return s.indexOf('size=invisible') >= 0 ? null : { name: 'hCaptcha', strong: false };
      if (s.indexOf('challenges.cloudflare.com') >= 0) return { name: 'Cloudflare', strong: false };
      if (s.indexOf('captcha-delivery.com') >= 0) return { name: 'DataDome', strong: true };
      if (s.indexOf('arkoselabs.com') >= 0 || s.indexOf('funcaptcha.com') >= 0) return { name: 'Arkose', strong: true };
      return null;
    };
    G.BOT_PHRASES = ['verify you are human', "verify you're human", 'verify you are a human', 'verifying you are human',
      'confirm you are human', "confirm you're human", "prove you're human", 'prove you are human', 'are you a robot', 'not a robot',
      'press and hold', 'press & hold', 'unusual traffic from your computer', 'enter the characters you see',
      'type the characters you see', 'checking if the site connection is secure', 'checking your browser before accessing',
      'complete the security check', 'human verification', 'solve this puzzle'];
    G.BOT_TITLES = ['just a moment', 'attention required', 'robot check', 'are you a robot', 'security check', 'pardon our interruption',
      'human verification', 'verify you are human'];
    // A checkbox CAPTCHA on a sign-in form counts only when the page is little else; the
    // wording only on a short page with few controls (an article about robots isn't one).
    G.botCheck = function (title, text, total, frame) {
      if (frame && (frame.strong || total < 15)) return 'a ' + frame.name + ' challenge';
      if (text.length >= 6000 || total >= 80) return '';
      const t = G.fold(text.slice(0, 4000));
      for (const p of G.BOT_PHRASES) { if (t.indexOf(p) >= 0) return 'the page says “' + p + '”'; }
      const ti = G.fold(title);
      for (const p of G.BOT_TITLES) { if (total < 40 && ti.indexOf(p) === 0) return 'its title is “' + G.clean(title).slice(0, 60) + '”'; }
      return '';
    };
    """#

    static let snapshotFunction = #"""
    function (a) {
      const vw = window.innerWidth, vh = window.innerHeight;
      let seq = Math.max(a.seq | 0, window.__glideSeq | 0);
      const stats = { skippedFrames: 0 };
      const cands = [], headings = [];
      const active = G.deepActive();
      const pin = new Set(a.pin || []);
      const modal = G.modal(), M = modal ? modal.el : null;
      const clipOf = G.clipper();
      const below = [], controlNames = new Set();
      let group = '', belowCount = 0, aboveCount = 0, frame = null;
      G.walk(document, 0, 0, 0, function (el, ox, oy, fclip) {
        const tag = el.tagName;
        const heading = /^H[1-6]$/.test(tag) || G.explicitRole(el) === 'heading';
        if ((heading || tag === 'LEGEND') && (headings.length < 40 || M) && G.visible(el)) {
          const t = G.text(el);
          if (t && heading && headings.length < 40) {
            const level = parseInt(tag.slice(1), 10) || parseInt(el.getAttribute('aria-level'), 10) || 2;
            headings.push({ level: Math.min(6, Math.max(1, level)), text: t.slice(0, 150) });
          }
          // The heading over a dialog's elements, to group the ones further down by it.
          if (t && M && G.inside(M, el)) group = t.slice(0, 40);
        }
        if (tag === 'IFRAME' && !(frame && frame.strong)) {
          const f = G.captchaFrame(el.src);
          if (f) {
            const r = el.getBoundingClientRect();
            if (r.width >= 60 && r.height >= 40 && G.visible(el)) frame = f;
          }
        }
        const own = el.getAttribute('data-glide-ref');
        const pinned = !!own && pin.has(own);
        // An element a snapshot lists anyway; pinned ones that aren't are added at the end.
        const normal = cands.length < 4000 && G.candidate(el) && !el.closest('[aria-hidden="true"],[inert]') && G.visible(el) &&
          !(G.isToggle(el) && G.drawnByLabel(el) && G.visibleLabel(el));
        if (!normal && !pinned) return;
        const shown = normal || G.visible(el);
        const r = G.rect(el);
        const x = r.left + ox, y = r.top + oy;
        // What's visible of the page: the viewport, cut down by the frames and scrolled panels
        // (a dialog's list, a carousel) the element sits in.
        let box = { l: 0, t: 0, r: vw, b: vh };
        if (fclip) box = G.meet(box, fclip);
        const c = clipOf(el);
        if (c) box = G.meet(box, { l: c.l + ox, t: c.t + oy, r: c.r + ox, b: c.b + oy });
        const inView = shown && x < box.r && y < box.b && x + r.width > box.l && y + r.height > box.t;
        const dir = inView ? '' : y >= box.b - 1 ? 'below' : y + r.height <= box.t + 1 ? 'above' : x >= box.r - 1 ? 'right' : 'left';
        const inModal = !!M && G.inside(M, el);
        if (inModal && normal && controlNames.size < 2000) controlNames.add(G.fold(G.name(el)));
        if (inModal && !inView && normal) {
          if (dir === 'below') {
            belowCount += 1;
            if (below.length < 60) below.push({ name: G.name(el).slice(0, 60), group: group });
          } else {
            aboveCount += 1;
          }
        }
        cands.push({ el: el, x: x, y: y, w: r.width, h: r.height, inView: inView, dir: dir, inModal: inModal, pinned: pinned, normal: normal,
          idx: cands.length });
      }, stats);
      const distance = function (c) { return c.y + c.h <= 0 ? -(c.y + c.h) : Math.max(0, c.y - vh); };
      const near = function (p, q) { return distance(p) - distance(q); };
      const free = cands.filter(function (c) { return c.normal; });
      // With a dialog open, its elements come before the page behind it.
      const tiers = M ? [
        free.filter(function (c) { return c.inModal && c.inView; }),
        free.filter(function (c) { return c.inModal && !c.inView; }).sort(near),
        free.filter(function (c) { return !c.inModal && c.inView; }),
        free.filter(function (c) { return !c.inModal && !c.inView; }).sort(near),
      ] : [free.filter(function (c) { return c.inView; }), free.filter(function (c) { return !c.inView; }).sort(near)];
      let picked = [];
      const limit = Math.max(1, a.max);
      for (let t = 0; t < tiers.length && picked.length < limit; t++) {
        picked = picked.concat(tiers[t].slice(0, limit - picked.length));
      }
      const kept = new Set(picked);
      const cut = { below: 0, above: 0, right: 0, left: 0, on: 0 };
      for (let i = 0; i < free.length; i++) {
        const c = free[i];
        if (kept.has(c) || c.pinned || (c.inModal && c.dir === 'below')) continue;
        if (c.inView) cut.on += 1; else cut[c.dir] += 1;
      }
      // What find asked for, beyond what the snapshot would list anyway (marked, so the
      // fingerprint and change summaries ignore it).
      for (let i = 0; i < cands.length; i++) {
        const c = cands[i];
        if (c.pinned && !kept.has(c)) { c.extra = true; picked.push(c); }
      }
      picked.sort(function (p, q) { return p.idx - q.idx; });
      const used = new Set();
      const elements = [];
      for (let i = 0; i < picked.length; i++) {
        const c = picked[i], el = c.el, tag = el.tagName;
        let ref = el.getAttribute('data-glide-ref');
        if (ref && /^b\d{1,10}$/.test(ref) && !used.has(ref)) {
          const n = parseInt(ref.slice(1), 10);
          if (n > seq) seq = n;
        } else {
          seq += 1;
          ref = 'b' + seq;
          el.setAttribute('data-glide-ref', ref);
        }
        used.add(ref);
        const ctl = tag === 'LABEL' && el.control ? el.control : el;
        const role = G.candidate(el) ? G.role(el) : (G.style(el).cursor === 'pointer' ? 'clickable' : 'text');
        const o = { ref: ref, role: role, name: G.name(el), x: Math.round(c.x), y: Math.round(c.y), w: Math.round(c.w), h: Math.round(c.h), inView: c.inView };
        if (c.dir) o.dir = c.dir;
        if (c.inModal) o.inModal = true;
        if (c.extra) o.pinned = true;
        if (tag === 'INPUT' && el.type !== 'text') o.type = el.type;
        if (tag === 'INPUT' && el.type === 'password') {
          o.secure = true;
        } else {
          let v = '';
          if (tag === 'INPUT') {
            if (el.type === 'file') v = el.files && el.files.length ? Array.from(el.files).map(function (f) { return f.name; }).join(', ') : '';
            else if (!G.isToggle(el) && ['button', 'submit', 'reset', 'image'].indexOf(el.type) < 0) v = el.value || '';
          } else if (tag === 'TEXTAREA') {
            v = el.value || '';
          } else if (tag === 'SELECT') {
            v = Array.from(el.selectedOptions).map(function (op) { return G.clean(op.label || op.text); }).join(', ');
          } else if (el.isContentEditable === true) {
            v = G.text(el);
          } else {
            v = G.clean(el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow') || '');
          }
          if (v) o.value = v.length > 300 ? v.slice(0, 300) : v;
        }
        if (G.isToggle(ctl)) {
          o.checked = !!ctl.checked;
        } else {
          const ac = el.getAttribute('aria-checked') || el.getAttribute('aria-pressed');
          if (ac === 'true') o.checked = true; else if (ac === 'false') o.checked = false;
        }
        if (el.getAttribute('aria-selected') === 'true') o.selected = true;
        const ex = el.getAttribute('aria-expanded');
        if (ex === 'true') o.expanded = true; else if (ex === 'false') o.expanded = false;
        let disabled = false;
        try { disabled = el.matches(':disabled') || (ctl !== el && ctl.matches(':disabled')); } catch (e) { disabled = false; }
        if (disabled || el.getAttribute('aria-disabled') === 'true') o.disabled = true;
        if (active && (active === el || active === ctl)) o.focused = true;
        if (tag === 'A' && typeof el.href === 'string' && el.href) o.href = el.href.slice(0, 300);
        if (tag === 'SELECT') o.options = Array.from(el.options).slice(0, 30).map(function (op) { return G.clean(op.label || op.text).slice(0, 60); }).filter(Boolean);
        const ctx = G.context(el);
        if (ctx) o.context = ctx;
        elements.push(o);
      }
      window.__glideSeq = seq;
      let root = G.mainRoot(), source = 'main';
      let text = root ? G.norm(root.innerText) : '';
      if ((!root || text.length < 200) && document.body) { text = G.norm(document.body.innerText); source = 'body'; }
      const total = text.length;
      const bot = G.botCheck(document.title || '', text, free.length, frame);
      if (text.length > a.maxText) text = text.slice(0, a.maxText);
      let info = null;
      if (M) {
        const sc = G.scrollersIn(M, true, null)[0] || null;
        info = { name: G.dialogName(M), kind: modal.kind, st: sc ? sc.scrollTop : 0, sl: sc ? sc.scrollLeft : 0,
          sh: sc ? sc.scrollHeight : 0, ch: sc ? sc.clientHeight : 0, below: below, belowCount: belowCount, aboveCount: aboveCount,
          text: G.norm(M.innerText || '').split('\n').filter(function (l) { return l && !controlNames.has(G.fold(l)); }).join('\n').slice(0, 1500) };
      }
      const se = document.scrollingElement || document.documentElement;
      return { url: location.href, title: document.title || '', seq: seq, vw: vw, vh: vh, sx: window.scrollX, sy: window.scrollY,
        pw: se ? se.scrollWidth : vw, ph: se ? se.scrollHeight : vh, total: free.length, skippedFrames: stats.skippedFrames,
        elements: elements, headings: headings, text: text, textTotal: total, textSource: source, modal: info, cut: cut, bot: bot };
    }
    """#

    static let clickFunction = #"""
    function (a) {
      const f = G.find(a.ref);
      if (!f) return { error: 'notfound' };
      if (f.ambiguous) return { error: 'ambiguous' };
      const el = f.el;
      const changed = G.changed(el, a.expect);
      if (changed) return changed;
      if (el.tagName === 'INPUT' && el.type === 'file') return { error: 'file' };
      if (el.tagName === 'SELECT') return { error: 'select' };
      let disabled = false;
      try { disabled = el.matches(':disabled'); } catch (e) { disabled = false; }
      disabled = disabled || el.getAttribute('aria-disabled') === 'true';
      G.armNav();
      G.reveal(el);
      const r = G.rect(el), o = G.frameOffset(el);
      const x = o.x + r.left + r.width / 2, y = o.y + r.top + r.height / 2;
      const onScreen = r.width > 0 && r.height > 0 && x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight;
      const hit = onScreen ? G.hit(x, y) : null;
      if (hit && (hit === el || G.containsDeep(el, hit))) return { method: 'mouse', x: x, y: y, disabled: disabled };
      G.scriptClick(el);
      return { method: 'script', covered: hit ? G.short(hit) : '', disabled: disabled };
    }
    """#

    static let focusFunction = #"""
    function (a) {
      const f = G.find(a.ref);
      if (!f) return { error: 'notfound' };
      if (f.ambiguous) return { error: 'ambiguous' };
      const changed = G.changed(f.el, a.expect);
      if (changed) return changed;
      const el = G.editTarget(f.el);
      if (el.tagName === 'INPUT' && el.type === 'password') return { error: 'password' };
      if (el.tagName === 'INPUT' && el.type === 'file') return { error: 'file' };
      if (!G.editable(el)) return { error: 'noteditable', role: G.role(el) };
      let disabled = false;
      try { disabled = el.matches(':disabled'); } catch (e) { disabled = false; }
      if (disabled || el.readOnly) return { error: 'readonly' };
      G.armNav();
      G.reveal(el);
      try { el.focus({ preventScroll: true }); } catch (e) {}
      const active = G.deepActive();
      const focused = active === el || G.containsDeep(el, active);
      const field = G.isField(el);
      const before = field ? (el.value || '') : G.text(el);
      const clear = (a.clear === null || a.clear === undefined) ? field : !!a.clear;
      if (focused) G.placeCaret(el, field, clear);
      const r = G.rect(el), o = G.frameOffset(el);
      return { focused: focused, field: field, clear: clear, hadText: before.length > 0, x: o.x + r.left + r.width / 2, y: o.y + r.top + r.height / 2 };
    }
    """#

    static let valueFunction = #"""
    function (a) {
      const f = G.find(a.ref);
      if (!f || f.ambiguous) return { missing: true };
      const el = G.editTarget(f.el);
      if (el.tagName === 'INPUT' && el.type === 'password') return { secure: true };
      return { value: G.isField(el) ? (el.value || '') : G.text(el) };
    }
    """#

    static let forceClearFunction = #"""
    function (a) {
      const f = G.find(a.ref);
      if (!f || f.ambiguous) return { missing: true };
      const el = G.editTarget(f.el);
      const w = G.win(el);
      if (G.isField(el)) {
        const proto = el.tagName === 'TEXTAREA' ? w.HTMLTextAreaElement.prototype : w.HTMLInputElement.prototype;
        const d = Object.getOwnPropertyDescriptor(proto, 'value');
        if (d && d.set) d.set.call(el, ''); else el.value = '';
      } else {
        el.textContent = '';
      }
      el.dispatchEvent(new w.Event('input', { bubbles: true }));
      return { ok: true };
    }
    """#

    static let selectFunction = #"""
    function (a) {
      const f = G.find(a.ref);
      if (!f) return { error: 'notfound' };
      if (f.ambiguous) return { error: 'ambiguous' };
      const changed = G.changed(f.el, a.expect);
      if (changed) return changed;
      let el = f.el;
      if (el.tagName === 'LABEL' && el.control) el = el.control;
      if (el.tagName !== 'SELECT') return { error: 'notselect', role: G.role(el) };
      if (el.matches(':disabled')) return { error: 'disabled' };
      const want = String(a.value).trim(), lower = want.toLowerCase();
      const opts = Array.from(el.options);
      const label = function (o) { return G.clean(o.label || o.text); };
      const opt = opts.find(function (o) { return o.value === want; }) ||
        opts.find(function (o) { return label(o) === want; }) ||
        opts.find(function (o) { return label(o).toLowerCase() === lower; }) ||
        opts.find(function (o) { return lower && label(o).toLowerCase().indexOf(lower) >= 0; });
      if (!opt) return { error: 'nooption', options: opts.slice(0, 40).map(label) };
      if (opt.disabled) return { error: 'optiondisabled' };
      G.armNav();
      const w = G.win(el);
      try { el.focus({ preventScroll: true }); } catch (e) {}
      if (el.multiple) {
        opt.selected = true;
      } else {
        const d = Object.getOwnPropertyDescriptor(w.HTMLSelectElement.prototype, 'value');
        if (d && d.set) d.set.call(el, opt.value); else el.value = opt.value;
      }
      el.dispatchEvent(new w.Event('input', { bubbles: true }));
      el.dispatchEvent(new w.Event('change', { bubbles: true }));
      return { selected: label(opt), value: opt.value };
    }
    """#

    /// What kind of field has focus (walking open shadow roots and same-origin frames):
    /// "password", "card" (autocomplete cc-number, cc-csc or cc-exp*), "other" or "none".
    static let focusedFieldFunction = #"""
    function () {
      const el = G.deepActive();
      if (!el || el === el.ownerDocument.body) return { kind: 'none' };
      if (el.tagName === 'INPUT' && String(el.type).toLowerCase() === 'password') return { kind: 'password' };
      const ac = String((el.getAttribute && el.getAttribute('autocomplete')) || '').toLowerCase();
      if (/(^|\s)cc-(number|csc|exp|exp-month|exp-year)(\s|$)/.test(ac)) return { kind: 'card' };
      return { kind: 'other' };
    }
    """#

    static let scrollFunction = #"""
    function (a) {
      const vertical = a.dir === 'up' || a.dir === 'down';
      const sign = (a.dir === 'up' || a.dir === 'left') ? -1 : 1;
      const pos = function (el) { return vertical ? el.scrollTop : el.scrollLeft; };
      const step = function (el) {
        const before = pos(el);
        const d = sign * a.amount * (vertical ? el.clientHeight : el.clientWidth) * 0.85;
        el.scrollBy({ left: vertical ? 0 : d, top: vertical ? d : 0, behavior: 'instant' });
        return Math.abs(pos(el) - before) >= 1;
      };
      const scrollWindow = function (w) {
        const before = vertical ? w.scrollY : w.scrollX;
        const d = sign * a.amount * (vertical ? w.innerHeight : w.innerWidth) * 0.85;
        w.scrollBy({ left: vertical ? 0 : d, top: vertical ? d : 0, behavior: 'instant' });
        return Math.abs((vertical ? w.scrollY : w.scrollX) - before) >= 1;
      };
      // From `start` up to the top document: the first panel (or frame) that moves, or null.
      const climb = function (start) {
        let node = start;
        for (let i = 0; node && i < 500; i++) {
          if (node.nodeType === 1) {
            const doc = node.ownerDocument;
            if (node === doc.body || node === doc.documentElement) {
              const w = doc.defaultView;
              if (w === window) return null;
              if (scrollWindow(w)) return { moved: true, scope: 'an embedded frame' };
              let fe = null;
              try { fe = w.frameElement; } catch (e) { fe = null; }
              node = fe;
              continue;
            }
            if (G.canScroll(node, vertical) && step(node)) return { moved: true, scope: 'the ' + G.short(node) + ' panel' };
          }
          node = node.parentNode || node.host || null;
        }
        return null;
      };
      if (a.ref) {
        const f = G.find(a.ref);
        if (!f) return { error: 'notfound' };
        if (f.ambiguous) return { error: 'ambiguous' };
        return climb(f.el) || { moved: scrollWindow(window), scope: 'the page' };
      }
      const center = G.hit(window.innerWidth / 2, window.innerHeight / 2);
      // An open dialog first: the page behind it is usually locked, and what's wanted is in it.
      const m = G.modal();
      if (m) {
        const what = G.modalTitle(m);
        const regions = G.scrollersIn(m.el, vertical, center);
        for (let i = 0; i < regions.length; i++) { if (step(regions[i])) return { moved: true, scope: what }; }
        if (regions.length) return { moved: false, scope: what };
        // Nothing in it scrolls by overflow: it may scroll by script, so ask for a real wheel.
        const r = m.el.getBoundingClientRect(), o = G.frameOffset(m.el);
        const x = Math.min(window.innerWidth - 2, Math.max(1, o.x + r.left + r.width / 2));
        const y = Math.min(window.innerHeight - 2, Math.max(1, o.y + r.top + r.height / 2));
        return { moved: false, stuck: true, scope: what, wheel: { x: x, y: y, span: vertical ? r.height : r.width } };
      }
      // Then the panel the focused element is in, then the one under the viewport center.
      const f = G.deepActive();
      if (f && f.nodeType === 1 && f !== f.ownerDocument.body && f !== f.ownerDocument.documentElement) {
        const got = climb(f);
        if (got) return got;
      }
      return climb(center) || { moved: scrollWindow(window), scope: 'the page' };
    }
    """#

    /// What a dialog's content looks like right now (scroll offsets and where its first
    /// controls are), to tell whether a wheel moved it.
    static let modalSignatureFunction = #"""
    function () {
      const m = G.modal();
      if (!m) return '';
      let sum = 0;
      const parts = [];
      const all = m.el.querySelectorAll('*');
      for (let i = 0; i < all.length && i < 3000; i++) {
        const n = all[i];
        sum += n.scrollTop + n.scrollLeft;
        if (parts.length < 12 && G.candidate(n)) {
          const r = n.getBoundingClientRect();
          parts.push(Math.round(r.top) + ',' + Math.round(r.left));
        }
      }
      return Math.round(sum) + '|' + parts.join(';');
    }
    """#

    /// Finds elements by text across the page, scrolls the chosen one into view and gives it
    /// and the runners-up refs (see `BrowserDriver.find`).
    static let findFunction = #"""
    function (a) {
      let seq = Math.max(a.seq | 0, window.__glideSeq | 0);
      const needle = G.fold(a.text);
      if (!needle) return { found: false, total: 0, url: location.href, roles: [], suggestions: [] };
      const want = G.fold(a.role || '');
      const KIN = { textbox: ['searchbox', 'combobox'], checkbox: ['switch', 'menuitemcheckbox'], radio: ['menuitemradio'],
        menuitem: ['menuitemcheckbox', 'menuitemradio'] };
      const fits = function (role) { return !want || role === want || (KIN[want] || []).indexOf(role) >= 0; };
      const modal = G.modal(), M = modal ? modal.el : null;
      const clipOf = G.clipper();
      const found = new Map(), refs = new Map(), names = [];
      const SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, HEAD: 1, TITLE: 1, META: 1, LINK: 1 };
      const consider = function (el, kind, q, len) {
        if (!el || q < 0) return;
        const m = found.get(el);
        if (!m) { found.set(el, { el: el, kind: kind, q: q, len: len, idx: found.size }); return; }
        if (q < m.q || (q === m.q && len < m.len)) { m.q = q; m.len = len; }
      };
      const best = function (list) {
        let q = -1, len = 0;
        for (let i = 0; i < list.length; i++) {
          if (!list[i]) continue;
          const v = G.quality(list[i], needle), l = G.clean(list[i]).length;
          if (v >= 0 && (q < 0 || v < q || (v === q && l < len))) { q = v; len = l; }
        }
        return { q: q, len: len };
      };
      G.walk(document, 0, 0, 0, function (el) {
        if (SKIP[el.tagName]) return;
        const own = el.getAttribute('data-glide-ref');
        if (own) refs.set(own, (refs.get(own) || 0) + 1);
        if (found.size >= 2000) return;
        if (G.candidate(el)) {
          // Everything a control goes by; never a password's value.
          const name = G.name(el);
          if (name && names.length < 3000) names.push(name);
          const hay = [name, el.getAttribute('aria-label'), el.getAttribute('placeholder'), el.getAttribute('title'), G.fieldValue(el)];
          if (el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby')) hay.push(G.text(el));
          const b = best(hay);
          consider(el, 'control', b.q, b.len);
          return;
        }
        // Text straight in the body or root isn't something to point at.
        if (el === el.ownerDocument.body || el === el.ownerDocument.documentElement) return;
        let hit = best([el.getAttribute('aria-label'), el.getAttribute('title'), el.getAttribute('alt'), el.getAttribute('placeholder')]).q >= 0;
        for (let n = el.firstChild; n && !hit; n = n.nextSibling) {
          if (n.nodeType === 3 && n.data.length < 5000 && G.fold(n.data).indexOf(needle) >= 0) hit = true;
        }
        if (!hit) return;
        const t = G.target(el);
        // Judge by the visible text of short elements only (innerText of a big container is slow).
        const short = function (n) { return (n.textContent || '').length <= 600 ? G.text(n) : ''; };
        const shown = t.el === el ? '' : short(t.el), mine = short(el);
        let b = best([shown.length <= 300 ? shown : '', mine.length <= 300 ? mine : '', el.getAttribute('aria-label'),
          el.getAttribute('title'), el.getAttribute('alt'), el.getAttribute('placeholder')]);
        // Hidden text, or text too long to judge: a plain substring match.
        if (b.q < 0) b = { q: 3, len: mine.length || 1000 };
        consider(t.el, t.kind, b.q, b.len);
      }, null);
      let list = Array.from(found.values());
      // Text that only labels a control already found (a button's caption beside it) isn't another match.
      const controls = list.filter(function (m) { return m.kind === 'control'; }).slice(0, 300);
      list = list.filter(function (m) {
        if (m.kind === 'control') return true;
        const p = G.up(m.el);
        if (!p) return true;
        for (let i = 0; i < controls.length; i++) {
          if (controls[i].el !== m.el && p.contains(controls[i].el)) {
            return (p.textContent || '').length > 400 || G.text(p).length > 200;
          }
        }
        return true;
      });
      for (let i = 0; i < list.length; i++) {
        const m = list[i], el = m.el;
        m.visible = G.visible(el);
        m.inModal = !!M && G.inside(M, el);
        m.covered = (!!M && !m.inModal) || !!el.closest('[aria-hidden="true"],[inert]');
        m.role = m.kind === 'control' ? G.role(el) : m.kind;
        let off = false;
        try { off = el.matches(':disabled'); } catch (e) { off = false; }
        m.disabled = off || el.getAttribute('aria-disabled') === 'true';
        // Controls you can use first, then things that look clickable, then plain text; behind
        // an open dialog after those, hidden last.
        m.tier = !m.visible ? 4 : m.covered ? 3 : m.kind === 'control' ? 0 : m.kind === 'clickable' ? 1 : 2;
        m.place = m.visible ? G.placement(el, clipOf) : { dir: 'hidden', inner: false, screens: 0, dist: 0 };
      }
      // Among equally good matches, the one nearest to view wins: what's on screen, then what a
      // short scroll reaches (a product's own buy box before the "also bought" row far below).
      const ranked = list.filter(function (m) { return fits(m.role); }).sort(function (p, q) {
        return (p.tier - q.tier) || ((p.disabled ? 1 : 0) - (q.disabled ? 1 : 0)) || (p.q - q.q) ||
          (p.place.dist - q.place.dist) || (p.len - q.len) || (p.idx - q.idx);
      });
      if (!ranked.length) {
        const roles = [];
        if (want) {
          list.slice().sort(function (p, q) { return (p.tier - q.tier) || (p.idx - q.idx); })
            .forEach(function (m) { if (roles.indexOf(m.role) < 0 && roles.length < 5) roles.push(m.role); });
        }
        return { found: false, total: 0, url: location.href, roles: roles, suggestions: list.length ? [] : G.suggest(names, needle) };
      }
      const nth = Math.max(1, a.nth | 0);
      if (nth > ranked.length) return { found: false, total: ranked.length, url: location.href, roles: [], suggestions: [] };
      const refOf = function (el) {
        let ref = el.getAttribute('data-glide-ref');
        if (ref && /^b\d{1,10}$/.test(ref) && (refs.get(ref) || 0) <= 1) {
          const n = parseInt(ref.slice(1), 10);
          if (n > seq) seq = n;
          return ref;
        }
        seq += 1;
        ref = 'b' + seq;
        el.setAttribute('data-glide-ref', ref);
        return ref;
      };
      const where = function (m) {
        const el = m.el, parts = [];
        if (el.ownerDocument !== document) {
          let fe = null;
          try { fe = el.ownerDocument.defaultView.frameElement; } catch (e) { fe = null; }
          let label = fe ? (G.clean(fe.getAttribute('title')) || G.clean(fe.getAttribute('aria-label')) || G.clean(fe.getAttribute('name'))) : '';
          if (!label) { try { label = G.clean(el.ownerDocument.title) || el.ownerDocument.location.pathname; } catch (e) { label = ''; } }
          parts.push(label ? 'in frame “' + label.slice(0, 40) + '”' : 'in a frame');
        }
        const dlg = G.closestDialog(el);
        if (dlg) { const n = G.dialogName(dlg); parts.push(n ? 'in dialog “' + n + '”' : 'in a dialog'); }
        else if (M && !m.inModal) parts.push('behind the open ' + modal.kind);
        if (!m.visible) { parts.push('hidden'); return parts.join(', '); }
        const p = m.place;
        let s;
        if (p.dir === 'in') s = 'on screen';
        else if (p.dir === 'below') s = p.inner ? 'further down' : 'further down the page';
        else if (p.dir === 'above') s = p.inner ? 'further up' : 'further up the page';
        else s = 'off-screen to the ' + p.dir;
        if (p.inner && !dlg && el.ownerDocument === document && (p.dir === 'below' || p.dir === 'above')) s += ' in a scrolled panel';
        if (!p.inner && p.screens >= 2) s = 'about ' + p.screens + ' screens ' + s;
        parts.push(s);
        return parts.join(', ');
      };
      const describe = function (m, rank) {
        const raw = m.el.textContent || '';
        let name = m.kind === 'control' ? G.name(m.el) : raw.length <= 2000 ? G.text(m.el) : G.clean(raw);
        if (!name) name = G.clean(m.el.getAttribute('aria-label') || m.el.getAttribute('alt') || m.el.getAttribute('title') || '');
        return { ref: refOf(m.el), role: m.role, name: name.slice(0, 120), where: where(m), nth: rank };
      };
      const chosen = ranked[nth - 1];
      const match = describe(chosen, nth);
      const others = [];
      for (let i = 0; i < ranked.length && others.length < 8; i++) {
        if (i !== nth - 1) others.push(describe(ranked[i], i + 1));
      }
      const scrolled = chosen.visible && chosen.place.dir !== 'in';
      if (scrolled) G.reveal(chosen.el);
      window.__glideSeq = seq;
      return { found: true, url: location.href, seq: seq, total: ranked.length, match: match, scrolled: scrolled, others: others };
    }
    """#

    static let readFunction = #"""
    function (a) {
      let parts = [];
      if (a.selector) {
        let list = [];
        try { list = Array.from(document.querySelectorAll(a.selector)); } catch (e) { return { error: 'selector', message: String((e && e.message) || e) }; }
        if (!list.length) {
          G.walk(document, 0, 0, 0, function (el) {
            if (el.matches(a.selector)) list.push(el);
            if (list.length >= 200) return false;
          }, null);
        }
        if (!list.length) return { error: 'nomatch' };
        parts = list.slice(0, 200).map(function (el) { return G.norm(el.innerText !== undefined ? el.innerText : el.textContent); }).filter(Boolean);
      } else {
        const root = G.mainRoot();
        let t = root ? G.norm(root.innerText) : '';
        if ((!root || t.length < 200) && document.body) t = G.norm(document.body.innerText);
        parts = [t];
      }
      const text = parts.join('\n\n');
      return { text: text.slice(0, a.max), total: text.length, url: location.href, title: document.title || '' };
    }
    """#

    static let waitFunction = #"""
    function (a) {
      if (a.kind === 'text') {
        const needle = String(a.value).toLowerCase();
        const has = function (doc) { return !!doc.body && (doc.body.innerText || '').toLowerCase().indexOf(needle) >= 0; };
        if (has(document)) return { met: true };
        for (let i = 0; i < window.frames.length; i++) {
          try { if (has(window.frames[i].document)) return { met: true }; } catch (e) {}
        }
        return { met: false };
      }
      try {
        const el = document.querySelector(a.value);
        if (el && G.visible(el)) return { met: true };
      } catch (e) { return { error: 'selector', message: String((e && e.message) || e) }; }
      let met = false;
      G.walk(document, 0, 0, 0, function (el) { if (el.matches(a.value) && G.visible(el)) { met = true; return false; } }, null);
      return { met: met };
    }
    """#

    /// Cheap state probe for settle detection.
    static let probeScript = #"""
    (() => { let n = 0; try { n = document.getElementsByTagName('*').length; } catch (e) {}
      return { rs: document.readyState, n: n, nav: window.__glideNavAt ? Date.now() - window.__glideNavAt : -1, u: location.href,
        m: window.__glideDocMark || '' }; })()
    """#

    /// Marks the page so a navigation that starts after an action is noticed even before the
    /// new document arrives (see `waitForSettle`).
    static let armNavigationScript = "(() => {\n\(library)\nG.armNav(); return true;\n})()"

    /// Arms the navigation hook and stamps the current document with `mark` (a UUID, so it's
    /// safe inside the quotes). Returns the page's address.
    static func markDocumentScript(_ mark: String) -> String {
        "(() => {\n\(library)\nG.armNav(); window.__glideDocMark = '\(mark)'; return location.href;\n})()"
    }
}
