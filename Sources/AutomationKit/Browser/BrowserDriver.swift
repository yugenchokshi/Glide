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
        public var inViewport: Bool

        public init(ref: String, role: String, name: String, value: String? = nil, inputType: String? = nil, checked: Bool? = nil,
                    selected: Bool? = nil, expanded: Bool? = nil, disabled: Bool = false, focused: Bool = false, secure: Bool = false,
                    href: String? = nil, options: [String]? = nil, context: String? = nil,
                    x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0, inViewport: Bool = true) {
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

    public init(tabID: String, url: String, title: String, viewportWidth: Double = 0, viewportHeight: Double = 0, scrollX: Double = 0,
                scrollY: Double = 0, pageWidth: Double = 0, pageHeight: Double = 0, elements: [Element] = [], headings: [Heading] = [],
                text: String = "", textTotal: Int? = nil, totalInteractive: Int? = nil, skippedFrames: Int = 0, timestamp: Date = Date()) {
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
    }

    public func element(_ ref: String) -> Element? { elements.first { $0.ref == ref } }

    public var focusedElement: Element? { elements.first { $0.focused } }

    /// Model-facing rendering, in the same style as the accessibility skeleton:
    /// `b12 button "Sign in" [disabled]`. Elements in the viewport come first; the readable text
    /// fills whatever budget is left (at least ~1,000 characters when there is text).
    public func compact(maxChars: Int = 8000) -> String {
        var lines: [String] = []
        lines.append("page: \"\(Self.clip(title.isEmpty ? "(untitled)" : title, 100))\" \(Self.clip(url, 200))")
        let maxScrollY = max(0, pageHeight - viewportHeight)
        var where_ = "viewport \(Int(viewportWidth))×\(Int(viewportHeight))"
        if maxScrollY > 1 {
            let position = scrollY <= 1 ? " (top)" : (scrollY >= maxScrollY - 1 ? " (bottom)" : "")
            where_ += ", scrolled \(Int(scrollY)) of \(Int(maxScrollY))\(position)"
        }
        lines.append(where_)
        if let f = focusedElement { lines.append("focused: \(f.ref)") }

        let textReserve = text.isEmpty ? 0 : min(text.count + 10, max(1000, maxChars / 4))
        let elementBudget = max(600, maxChars - textReserve - 300)
        var used = lines.reduce(0) { $0 + $1.count + 1 }
        var listed = 0
        let inView = elements.filter(\.inViewport), outside = elements.filter { !$0.inViewport }
        func add(_ group: [Element]) {
            for e in group {
                let l = line(for: e)
                guard used + l.count + 1 <= elementBudget else { return }
                lines.append(l)
                used += l.count + 1
                listed += 1
            }
        }
        if elements.isEmpty { lines.append("(no interactive elements)") }
        add(inView)
        if !outside.isEmpty, used < elementBudget - 40 {
            lines.append("outside the viewport (scroll to reach):")
            used += 40
            add(outside)
        }
        let unlisted = totalInteractive - listed
        if unlisted > 0 { lines.append("(\(unlisted) more elements not listed — scroll, or use browser.read for text)") }
        if skippedFrames > 0 { lines.append("(\(skippedFrames) embedded frame(s) from other sites aren't included)") }
        used = lines.reduce(0) { $0 + $1.count + 1 }

        if !headings.isEmpty, used < maxChars - 200 {
            let h = headings.prefix(20).map { String(repeating: "#", count: max(1, min(6, $0.level))) + " " + Self.clip($0.text, 80) }
            let joined = "headings: " + h.joined(separator: " | ")
            let clipped = Self.clip(joined, max(80, min(900, maxChars - used - 100)))
            lines.append(clipped)
            used += clipped.count + 1
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

    func line(for e: Element) -> String {
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
        let oldRefs = Set(old.elements.map(\.ref)), newRefs = Set(elements.map(\.ref))
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
        if abs(old.scrollY - scrollY) >= 1 { parts.append("scrolled to \(Int(scrollY))") }
        if parts.isEmpty { return "No visible change on the page." }
        return "Same page; " + parts.joined(separator: ", ") + "."
    }

    /// Small structured form for step runners: refs with roles and names (no text).
    public var modelData: JSONValue {
        .object([
            "tab_id": .string(tabID),
            "url": .string(url),
            "title": .string(title),
            "elements": .array(elements.map { e in
                var o: [String: JSONValue] = ["ref": .string(e.ref), "role": .string(e.role), "name": .string(Self.clip(e.name, 80))]
                if e.secure { o["secure"] = true }
                return .object(o)
            }),
        ])
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

    public init(settled: Bool = true, notes: [String] = [], value: String? = nil) {
        self.settled = settled
        self.notes = notes
        self.value = value
    }
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

    public func snapshot(tabID: String, maxElements: Int = 300, maxTextChars: Int = 6000) async throws -> PageSnapshot {
        let seq = tabState.withLock { $0[tabID]?.nextRef ?? 0 }
        let args: JSONValue = ["seq": .number(Double(seq)), "max": .number(Double(max(1, maxElements))), "maxText": .number(Double(max(0, maxTextChars)))]
        let v = try await evaluate(tabID: tabID, Self.call(Self.snapshotFunction, args), timeout: 25)
        guard v.objectValue != nil else { throw BrowserError.cdp("The page didn't return a snapshot.") }
        let snap = Self.decodeSnapshot(v, tabID: tabID)
        if Self.isRestricted(url: snap.url) { throw BrowserError.restrictedPage(snap.url) }
        let newSeq = v["seq"]?.intValue ?? seq
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
        try await pressStrokes(tabID: tabID, strokes)
        let settled = try await waitForSettle(tabID: tabID)
        let notes = await dialogNotes(tabID: tabID)
        return BrowserActionOutcome(settled: settled, notes: notes)
    }

    /// Scrolls the scrollable area under the viewport center (or under `ref`) by `amount`
    /// screens. Uses script scrolling, which also works in background tabs.
    public func scroll(tabID: String, direction: ScrollDirection, amount: Double = 1, ref: String? = nil) async throws -> BrowserActionOutcome {
        if let ref { try Self.validate(ref: ref) }
        let args: JSONValue = ["dir": .string(direction.rawValue), "amount": .number(min(20, max(0.1, amount))), "ref": ref.map { .string($0) } ?? .null]
        let r = try await evaluate(tabID: tabID, Self.call(Self.scrollFunction, args))
        try Self.throwIfError(r, ref: ref ?? "")
        let settled = try await waitForSettle(tabID: tabID, timeout: 3)
        var notes: [String] = []
        if r["moved"]?.boolValue != true {
            notes.append("Nothing scrolled — already at the \(direction == .up ? "top" : direction == .down ? "bottom" : "edge").")
        } else if let scope = r["scope"]?.stringValue, scope != "page" {
            notes.append("Scrolled \(scope).")
        }
        return BrowserActionOutcome(settled: settled, notes: notes)
    }

    /// Loads `url` in the tab and waits for it to settle.
    ///
    /// Some backends return before the navigation commits (the extension's `chrome.tabs.update`
    /// replies as soon as it starts), so the page being left is marked first: until the probe
    /// sees a different document (or address), the old page doesn't count as loaded.
    public func navigate(tabID: String, url: String) async throws -> BrowserActionOutcome {
        let target = try Self.checkedURL(url)
        let mark = UUID().uuidString
        let markedURL = try? await evaluate(tabID: tabID, Self.markDocumentScript(mark), timeout: 3).stringValue
        try await withDeadline(30, BrowserError.timeout("opening \(target)")) { [backend] in
            try await backend.navigate(tabID: tabID, url: target)
        }
        let leaving: PageBeingLeft? = markedURL.map { .document(mark: mark, url: $0) }
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

    private func pressStrokes(tabID: String, _ strokes: [BrowserKeys.Stroke]) async throws {
        for stroke in strokes {
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

    static func isFatal(_ e: BrowserError) -> Bool {
        switch e {
        case .tabNotFound, .notConnected, .restrictedPage, .chromeNotInstalled: return true
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

    static func decodeSnapshot(_ v: JSONValue, tabID: String) -> PageSnapshot {
        func d(_ key: String) -> Double { v[key]?.doubleValue ?? 0 }
        let elements: [PageSnapshot.Element] = (v["elements"]?.arrayValue ?? []).compactMap { e in
            guard let ref = e["ref"]?.stringValue else { return nil }
            let secure = e["secure"]?.boolValue ?? false
            return PageSnapshot.Element(
                ref: ref, role: e["role"]?.stringValue ?? "clickable", name: e["name"]?.stringValue ?? "",
                value: secure ? nil : e["value"]?.stringValue, inputType: e["type"]?.stringValue,
                checked: e["checked"]?.boolValue, selected: e["selected"]?.boolValue, expanded: e["expanded"]?.boolValue,
                disabled: e["disabled"]?.boolValue ?? false, focused: e["focused"]?.boolValue ?? false, secure: secure,
                href: e["href"]?.stringValue, options: e["options"]?.arrayValue?.compactMap(\.stringValue), context: e["context"]?.stringValue,
                x: e["x"]?.doubleValue ?? 0, y: e["y"]?.doubleValue ?? 0, width: e["w"]?.doubleValue ?? 0, height: e["h"]?.doubleValue ?? 0,
                inViewport: e["inView"]?.boolValue ?? true)
        }
        let headings: [PageSnapshot.Heading] = (v["headings"]?.arrayValue ?? []).compactMap { h in
            guard let t = h["text"]?.stringValue else { return nil }
            return PageSnapshot.Heading(level: h["level"]?.intValue ?? 2, text: t)
        }
        let text = v["text"]?.stringValue ?? ""
        return PageSnapshot(tabID: tabID, url: v["url"]?.stringValue ?? "", title: v["title"]?.stringValue ?? "",
                            viewportWidth: d("vw"), viewportHeight: d("vh"), scrollX: d("sx"), scrollY: d("sy"),
                            pageWidth: d("pw"), pageHeight: d("ph"), elements: elements, headings: headings, text: text,
                            textTotal: v["textTotal"]?.intValue ?? text.count, totalInteractive: v["total"]?.intValue ?? elements.count,
                            skippedFrames: v["skippedFrames"]?.intValue ?? 0)
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
    G.ROLES = new Set(['button', 'link', 'checkbox', 'radio', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'switch',
      'textbox', 'combobox', 'searchbox', 'slider', 'spinbutton', 'listbox', 'treeitem']);
    G.FIELD_TYPES = new Set(['text', 'search', 'email', 'url', 'tel', 'number', 'password', 'date', 'datetime-local', 'month', 'time', 'week']);
    G.isField = function (el) { return el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && G.FIELD_TYPES.has(el.type)); };
    G.editable = function (el) { return G.isField(el) || el.isContentEditable === true; };
    G.isToggle = function (el) { return !!el && el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio'); };
    G.explicitRole = function (el) { return G.clean(el.getAttribute('role')).split(' ')[0].toLowerCase(); };
    G.walk = function (root, ox, oy, depth, visit, stats) {
      const all = root.querySelectorAll('*');
      for (let i = 0; i < all.length; i++) {
        const el = all[i];
        if (visit(el, ox, oy) === false) return false;
        if (el.shadowRoot && G.walk(el.shadowRoot, ox, oy, depth, visit, stats) === false) return false;
        if ((el.tagName === 'IFRAME' || el.tagName === 'FRAME') && depth < 5) {
          let doc = null;
          try { doc = el.contentDocument; } catch (e) { doc = null; }
          const r = el.getBoundingClientRect();
          if (doc && doc.documentElement) {
            if (G.walk(doc, ox + r.left + el.clientLeft, oy + r.top + el.clientTop, depth + 1, visit, stats) === false) return false;
          } else if (stats && r.width > 20 && r.height > 20) {
            stats.skippedFrames += 1;
          }
        }
      }
      return true;
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
    G.context = function (el) {
      const dlg = el.closest('dialog,[role="dialog"],[role="alertdialog"]');
      if (dlg) {
        let n = G.clean(dlg.getAttribute('aria-label')) || G.labelledBy(dlg);
        if (!n) { const h = dlg.querySelector('h1,h2,h3,[role="heading"]'); if (h) n = G.text(h); }
        return 'dialog' + (n ? ' ' + n.slice(0, 60) : '');
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
    """#

    static let snapshotFunction = #"""
    function (a) {
      const vw = window.innerWidth, vh = window.innerHeight;
      let seq = Math.max(a.seq | 0, window.__glideSeq | 0);
      const stats = { skippedFrames: 0 };
      const cands = [], headings = [];
      const active = G.deepActive();
      G.walk(document, 0, 0, 0, function (el, ox, oy) {
        const tag = el.tagName;
        if (headings.length < 40 && (/^H[1-6]$/.test(tag) || G.explicitRole(el) === 'heading') && G.visible(el)) {
          const t = G.text(el);
          if (t) headings.push({ level: parseInt(tag.slice(1), 10) || parseInt(el.getAttribute('aria-level'), 10) || 2, text: t.slice(0, 150) });
        }
        if (cands.length >= 4000 || !G.candidate(el)) return;
        if (el.closest('[aria-hidden="true"],[inert]')) return;
        if (!G.visible(el)) return;
        if (G.isToggle(el) && G.drawnByLabel(el) && G.visibleLabel(el)) return;
        const r = G.rect(el);
        const x = r.left + ox, y = r.top + oy;
        const inView = x < vw && y < vh && x + r.width > 0 && y + r.height > 0;
        cands.push({ el: el, x: x, y: y, w: r.width, h: r.height, inView: inView, idx: cands.length });
      }, stats);
      const distance = function (c) { return c.y + c.h <= 0 ? -(c.y + c.h) : Math.max(0, c.y - vh); };
      let picked = cands.filter(function (c) { return c.inView; });
      if (picked.length >= a.max) {
        picked = picked.slice(0, a.max);
      } else {
        const outside = cands.filter(function (c) { return !c.inView; }).sort(function (p, q) { return distance(p) - distance(q); });
        picked = picked.concat(outside.slice(0, a.max - picked.length));
      }
      picked.sort(function (p, q) { return p.idx - q.idx; });
      const used = new Set();
      const elements = [];
      for (let i = 0; i < picked.length; i++) {
        const c = picked[i], el = c.el, tag = el.tagName;
        let ref = el.getAttribute('data-glide-ref');
        if (ref && /^b\d+$/.test(ref) && !used.has(ref)) {
          const n = parseInt(ref.slice(1), 10);
          if (n > seq) seq = n;
        } else {
          seq += 1;
          ref = 'b' + seq;
          el.setAttribute('data-glide-ref', ref);
        }
        used.add(ref);
        const ctl = tag === 'LABEL' && el.control ? el.control : el;
        const o = { ref: ref, role: G.role(el), name: G.name(el), x: Math.round(c.x), y: Math.round(c.y), w: Math.round(c.w), h: Math.round(c.h), inView: c.inView };
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
      if (text.length > a.maxText) text = text.slice(0, a.maxText);
      const se = document.scrollingElement || document.documentElement;
      return { url: location.href, title: document.title || '', seq: seq, vw: vw, vh: vh, sx: window.scrollX, sy: window.scrollY,
        pw: se ? se.scrollWidth : vw, ph: se ? se.scrollHeight : vh, total: cands.length, skippedFrames: stats.skippedFrames,
        elements: elements, headings: headings, text: text, textTotal: total, textSource: source };
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
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
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
      el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
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

    static let scrollFunction = #"""
    function (a) {
      const vertical = a.dir === 'up' || a.dir === 'down';
      const sign = (a.dir === 'up' || a.dir === 'left') ? -1 : 1;
      let target = null;
      if (a.ref) {
        const f = G.find(a.ref);
        if (!f) return { error: 'notfound' };
        if (f.ambiguous) return { error: 'ambiguous' };
        target = f.el;
      } else {
        target = G.hit(window.innerWidth / 2, window.innerHeight / 2);
      }
      const pos = function (el) { return vertical ? el.scrollTop : el.scrollLeft; };
      const scrollable = function (el) {
        const s = G.style(el);
        if (!/(auto|scroll|overlay)/.test(vertical ? s.overflowY : s.overflowX)) return false;
        return vertical ? el.scrollHeight > el.clientHeight + 1 : el.scrollWidth > el.clientWidth + 1;
      };
      const scrollWindow = function (w) {
        const before = vertical ? w.scrollY : w.scrollX;
        const d = sign * a.amount * (vertical ? w.innerHeight : w.innerWidth) * 0.85;
        w.scrollBy({ left: vertical ? 0 : d, top: vertical ? d : 0, behavior: 'instant' });
        return Math.abs((vertical ? w.scrollY : w.scrollX) - before) >= 1;
      };
      let node = target;
      for (let i = 0; node && i < 500; i++) {
        if (node.nodeType === 1) {
          const doc = node.ownerDocument;
          if (node === doc.body || node === doc.documentElement) {
            const w = doc.defaultView;
            if (w !== window && scrollWindow(w)) return { moved: true, scope: 'an embedded frame' };
            if (w === window) break;
            let fe = null;
            try { fe = w.frameElement; } catch (e) { fe = null; }
            node = fe;
            continue;
          }
          if (scrollable(node)) {
            const before = pos(node);
            const d = sign * a.amount * (vertical ? node.clientHeight : node.clientWidth) * 0.85;
            node.scrollBy({ left: vertical ? 0 : d, top: vertical ? d : 0, behavior: 'instant' });
            if (Math.abs(pos(node) - before) >= 1) return { moved: true, scope: 'the ' + G.short(node) + ' panel' };
          }
        }
        node = node.parentNode || node.host || null;
      }
      return { moved: scrollWindow(window), scope: 'page' };
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
