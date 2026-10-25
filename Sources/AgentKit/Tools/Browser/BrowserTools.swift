import Foundation
import AutomationKit

// DOM-level browser tools. They run in Chrome through whichever backend `BrowserHub` picks (the
// Glide extension in the user's own Chrome, or Glide's own Chrome window), in background tabs so
// the cursor and the user's front tab are never touched. Every action returns a fresh compact
// snapshot, so the model rarely needs a separate `browser.snapshot` call.

/// The browser tool family.
public enum BrowserTools {
    /// Registers the tools with `ToolRegistry` and makes sure Glide's own Chrome is available as
    /// a backend (it only launches when a task first needs it).
    public static func install(hub: BrowserHub = .shared, sessions: BrowserSessions = .shared) {
        if hub.registered(.glideChrome) == nil {
            // Open the history store first: it moves the pre-rename NotchBuddy folder to
            // Application Support/Glide only while that folder doesn't exist yet, and Glide's
            // Chrome profile lives inside it.
            _ = LocalStore.shared
            hub.register(GlideChromeBackend())
        }
        ToolRegistry.registerFactory("browser") { _ in make(hub: hub, sessions: sessions) }
    }

    /// The tools bound to a hub and session store (tests pass their own).
    public static func make(hub: BrowserHub = .shared, sessions: BrowserSessions = .shared) -> [any AgentTool] {
        let rt = BrowserRuntime(hub: hub, sessions: sessions)
        return [
            BrowserOpenTool(rt: rt), BrowserSnapshotTool(rt: rt), BrowserFindTool(rt: rt), BrowserClickTool(rt: rt), BrowserTypeTool(rt: rt),
            BrowserSelectTool(rt: rt), BrowserPressTool(rt: rt), BrowserScrollTool(rt: rt), BrowserReadTool(rt: rt),
            BrowserBackTool(rt: rt), BrowserTabsTool(rt: rt), BrowserSwitchTabTool(rt: rt), BrowserCloseTabTool(rt: rt),
            BrowserWaitTool(rt: rt),
        ]
    }
}

// MARK: - Shared plumbing

/// Resolves the backend and current tab for a call, runs it under the stop switch, and turns
/// browser failures into ordinary `ok: false` results the model can react to.
struct BrowserRuntime: Sendable {
    let hub: BrowserHub
    let sessions: BrowserSessions

    func key(_ context: ToolContext) -> String { BrowserSessions.key(jobID: context.jobID, itemID: context.itemID) }

    /// The latest snapshot of the caller's current tab, for `assess`.
    func currentSnapshot(_ context: ToolContext) -> PageSnapshot? { sessions.currentSnapshot(key(context)) }

    func perform(_ context: ToolContext, _ body: @escaping @Sendable (BrowserEnv) async throws -> ToolOutput) async throws -> ToolOutput {
        try await context.gate.checkpoint()
        let started = ContinuousClock.now
        func timed(_ output: ToolOutput) -> ToolOutput {
            var o = output
            let d = ContinuousClock.now - started
            o.durationMs = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            return o
        }
        do {
            let output = try await Self.stoppable(context.gate) {
                let env = try await self.environment(context)
                do {
                    return try await body(env)
                } catch BrowserError.tabNotFound(let id) {
                    env.sessions.forgetTab(backend: env.kind, tabID: id)
                    throw BrowserActionError("That browser tab was closed. Open the page again with browser.open.")
                }
            }
            return timed(output)
        } catch let e as ToolError {
            throw e
        } catch let e as AutomationError where e == .stopped {
            throw e
        } catch is CancellationError {
            if context.gate.isStopped { throw AutomationError.stopped }
            // Cancelled from elsewhere (Glide's Chrome shut down mid-launch, say) while this
            // call was neither stopped nor cancelled: a failure the model can retry, not a Stop.
            if !Task.isCancelled { return timed(.failure("The browser was interrupted before this finished. Try again.")) }
            throw CancellationError()
        } catch {
            return timed(.failure(error.localizedDescription))
        }
    }

    private func environment(_ context: ToolContext) async throws -> BrowserEnv {
        let settings = context.settings.browser
        let chrome = hub.registered(.glideChrome) as? GlideChromeBackend
        await chrome?.setChromePath(settings.chromePath)
        let key = self.key(context)
        var backend: (any BrowserBackend)?
        // Stay in the backend the current tab lives in while it's connected (switching would
        // lose the page and its login), even if the preferred backend has come online since.
        if let s = sessions.session(key), let b = hub.registered(s.backend), await b.isConnected() { backend = b }
        if backend == nil {
            let chromeWasRunning = await chrome?.isConnected() ?? false
            let resolved = try await hub.backend(for: settings)
            if resolved.kind == .glideChrome, !chromeWasRunning {
                context.log(ActivityEntry(kind: .info, title: "Started Glide's Chrome", route: .browser))
            }
            backend = resolved
        }
        guard let backend else { throw BrowserError.notConnected("No browser is available.") }
        return BrowserEnv(runtime: self, backend: backend, driver: sessions.driver(for: backend), key: key, jobID: context.jobID, settings: settings)
    }

    /// Runs `operation`, cancelling it as soon as the emergency stop is pressed.
    static func stoppable<T: Sendable>(_ gate: ExecutionGate, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                while !gate.isStopped { try await Task.sleep(for: .milliseconds(100)) }
                throw AutomationError.stopped
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

/// One call's view of the browser: the backend, its driver, and the caller's current tab.
struct BrowserEnv: Sendable {
    let runtime: BrowserRuntime
    let backend: any BrowserBackend
    let driver: BrowserDriver
    let key: String
    let jobID: String?
    let settings: BrowserSettings

    var kind: BrowserBackendKind { backend.kind }
    var sessions: BrowserSessions { runtime.sessions }

    /// The caller's current tab in this backend, if it has one.
    var currentTab: String? {
        guard let s = sessions.session(key), s.backend == kind else { return nil }
        return s.tabID
    }

    func requireTab() throws -> String {
        guard let tab = currentTab else {
            throw BrowserActionError("This task isn't working in a tab yet. Use browser.open, or browser.switch_tab to work in a tab that's already open.")
        }
        sessions.touch(key)
        return tab
    }

    /// The current tab, or — for reading only — the tab in front in the user's Chrome. Reading
    /// it doesn't make it this task's tab: acting there takes an explicit `browser.switch_tab`.
    func tabForReading() async throws -> (tabID: String, isUsersFrontTab: Bool) {
        if let tab = currentTab {
            sessions.touch(key)
            return (tab, false)
        }
        let tabs = try await driver.tabs()
        if let active = tabs.first(where: { $0.active && !BrowserDriver.isRestricted(url: $0.url) && $0.url != "about:blank" }) {
            return (active.id, true)
        }
        throw BrowserActionError("This task isn't working in a tab yet. Use browser.open first.")
    }

    func openNewTab(url: String) async throws -> String {
        try await sessions.openTab(key: key, jobID: jobID, url: url, background: settings.useBackgroundTabs, driver: driver)
    }

    func lastSnapshot(_ tab: String) -> PageSnapshot? { sessions.lastSnapshot(backend: kind, tabID: tab) }

    /// Takes a fresh snapshot and renders the model-visible result: what happened, what changed
    /// and the page.
    func pageOutput(tab: String, lead: String, notes: [String] = [], previous: PageSnapshot?, settled: Bool = true,
                    ok: Bool = true, maxChars: Int = 6000) async throws -> ToolOutput {
        let snap = try await driver.snapshot(tabID: tab)
        sessions.record(snap, backend: kind)
        return Self.render(snap, lead: lead, notes: notes, previous: previous, settled: settled, ok: ok, maxChars: maxChars)
    }

    /// The model-visible result for `snap`: the lead, what changed since `previous`, notes, then
    /// the page. `data` carries the snapshot's refs and `fingerprint` (plus `botCheck` on a
    /// CAPTCHA page) and any `extra` keys. Elements in `skip` were already shown in the notes.
    static func render(_ snap: PageSnapshot, lead: String, notes: [String] = [], previous: PageSnapshot?, settled: Bool = true,
                       ok: Bool = true, maxChars: Int = 6000, skip: Set<String> = [], extra: [String: JSONValue] = [:]) -> ToolOutput {
        var lines = [lead]
        let change = snap.changeSummary(since: previous)
        if !change.isEmpty { lines.append(change) }
        lines += notes
        if !settled { lines.append("(The page was still busy when this snapshot was taken; it may be incomplete.)") }
        lines.append("")
        lines.append(snap.compact(maxChars: maxChars, skip: skip))
        var data = snap.modelData
        if !extra.isEmpty, case .object(var o) = data {
            o.merge(extra) { $1 }
            data = .object(o)
        }
        return ToolOutput(ok: ok, text: toolTruncate(lines.joined(separator: "\n"), max: maxChars + 2000), data: data)
    }

    /// The element `ref` names in the tab's latest snapshot. Actions must use refs from the
    /// latest snapshot: that's the element the safety check judged, and the one the model meant.
    func element(_ ref: String, in tab: String) throws -> (PageSnapshot, PageSnapshot.Element) {
        guard let snap = lastSnapshot(tab) else {
            throw BrowserActionError("There's no snapshot of this tab yet. Take one with browser.snapshot, then use its refs.")
        }
        guard let element = snap.element(ref) else {
            throw BrowserActionError("\(ref) isn't in the latest snapshot of this page. Take a new snapshot (browser.snapshot) and use a ref from it.")
        }
        return (snap, element)
    }
}

/// Small JSON-schema builders for tool arguments (regular schemas, not strict ones: optional
/// arguments may be left out, and extra keys are allowed because the step runner adds `_label`).
enum BrowserArgs {
    static func object(_ properties: [(String, JSONValue)], required: [String] = []) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(Dictionary(properties, uniquingKeysWith: { $1 })),
            "required": .array(required.map { .string($0) }),
        ])
    }
    static func string(_ description: String, enum values: [String]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { o["enum"] = .array(values.map { .string($0) }) }
        return .object(o)
    }
    static func number(_ description: String) -> JSONValue { ["type": "number", "description": .string(description)] }
    static func integer(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
    static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
    static let refSchema = string("Element ref from the latest snapshot, e.g. \"b12\".")

    /// `_label` is filled by the step runner with the element's name from the snapshot it saw.
    static func label(_ args: JSONValue) -> String? { args.optionalString("_label") }

    /// A whole-number argument kept within `range`. Models send 1e9 or 2.5 at times, and
    /// `Int(Double)` traps on numbers that don't fit.
    static func int(_ args: JSONValue, _ key: String, default value: Int, in range: ClosedRange<Int>) -> Int {
        guard let d = args[key]?.doubleValue, d.isFinite else { return value }
        return Int(min(Double(range.upperBound), max(Double(range.lowerBound), d.rounded(.down))))
    }

    static func ref(_ args: JSONValue) throws -> String {
        let ref = try args.requiredString("ref").trimmingCharacters(in: .whitespaces)
        guard ref.count >= 2, ref.count <= 12, ref.first == "b", ref.dropFirst().allSatisfy({ ("0"..."9").contains($0) }) else {
            throw ToolError.invalidArguments("“ref” must be an element ref from the snapshot, like \"b12\"")
        }
        return ref
    }
}

private func clip(_ s: String, _ n: Int) -> String { PageSnapshot.clip(s, n) }

// MARK: - Tools

struct BrowserOpenTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.open",
        summary: "Open a web page in Chrome (a background tab; your logins in Glide's browser apply). Returns the page's interactive elements with refs (b1, b2…) and its text. Opening a search-results address with the query in it (e.g. https://www.amazon.com/s?k=usb+c+cable) is often faster and more reliable than filling in search forms and date pickers.",
        inputSchema: BrowserArgs.object([
            ("url", BrowserArgs.string("Address to open, e.g. https://example.com or example.com/page.")),
            ("new_tab", BrowserArgs.boolean("Open in another tab instead of reusing this task's tab (default false).")),
        ], required: ["url"]),
        category: .browser)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        BrowserRisk.open(arguments.optionalString("url") ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try arguments.requiredString("url")
        let newTab = arguments.optionalBool("new_tab") ?? false
        return try await rt.perform(context) { env in
            let url = try BrowserDriver.checkedURL(raw)
            if !newTab, let tab = env.currentTab, env.sessions.isGlideTab(backend: env.kind, tabID: tab) {
                env.sessions.touch(env.key)
                let previous = env.lastSnapshot(tab)
                let outcome = try await env.driver.navigate(tabID: tab, url: url)
                return try await env.pageOutput(tab: tab, lead: "Opened \(clip(url, 200)).", notes: outcome.notes, previous: previous, settled: outcome.settled)
            }
            var notes: [String] = []
            if !newTab, env.currentTab != nil { notes.append("Opened it in a new tab so the tab you were on stays as it was.") }
            let tab = try await env.openNewTab(url: url)
            let place = env.settings.useBackgroundTabs ? "a new background tab" : "a new tab"
            return try await env.pageOutput(tab: tab, lead: "Opened \(clip(url, 200)) in \(place) (tab \(tab)).", notes: notes, previous: nil)
        }
    }
}

struct BrowserSnapshotTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.snapshot",
        summary: "Describe the current tab: interactive elements with refs (b1, b2…), headings and readable text. Refs stay valid until the page changes. To look for something specific (a button, a filter, a field), use browser.find instead of taking more snapshots.",
        inputSchema: BrowserArgs.object([]),
        category: .browser, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        ToolVerdict(risk: .low, summary: "Look at the browser tab")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await rt.perform(context) { env in
            let (tab, front) = try await env.tabForReading()
            let lead = front
                ? "Your front Chrome tab (\(tab)). To click or type here, first call browser.switch_tab with tab_id \(tab)."
                : "Current tab (\(tab)):"
            return try await env.pageOutput(tab: tab, lead: lead, previous: nil, maxChars: 8000)
        }
    }
}

/// Jumps to an element by its text instead of scrolling and snapshotting until it shows up:
/// on long pages the snapshot is cut, and an element further down a dialog never appears in it.
struct BrowserFindTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.find",
        summary: "Find an element on the current tab by its text or label — anywhere on the page, including off-screen, further down a dialog or scrolled panel, and in frames — and scroll it into view. Returns its ref for browser.click or browser.type, and where the other matches are. Use it instead of repeated snapshots or scrolling.",
        inputSchema: BrowserArgs.object([
            ("text", BrowserArgs.string("What to look for: the element's visible text, label, placeholder or alt text, e.g. \"Add to Cart\" or \"Cabin\" (any case).")),
            ("role", BrowserArgs.string("Only elements of this kind, e.g. button, link, checkbox, option or textbox (optional).")),
            ("nth", BrowserArgs.integer("Which match to take when several fit: 1 is the best (default), 2 the next, and so on.")),
        ], required: ["text"]),
        category: .browser, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        BrowserRisk.find(text: arguments.optionalString("text") ?? "")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let text = try arguments.requiredString("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError.invalidArguments("missing “text”") }
        guard text.count <= 300 else { throw ToolError.invalidArguments("“text” is too long (at most 300 characters)") }
        let role = arguments.optionalString("role")?.trimmingCharacters(in: .whitespaces).lowercased()
        let nth = BrowserArgs.int(arguments, "nth", default: 1, in: 1...100)
        return try await rt.perform(context) { env in
            let tab = try env.requireTab()
            let previous = env.lastSnapshot(tab)
            let result = try await env.driver.find(tabID: tab, text: text, role: role?.isEmpty == false ? role : nil, nth: nth)
            let snap = result.snapshot
            env.sessions.record(snap, backend: env.kind)
            return Self.output(result, text: text, role: role, nth: nth, previous: previous)
        }
    }

    static func output(_ result: BrowserFindResult, text: String, role: String?, nth: Int, previous: PageSnapshot?) -> ToolOutput {
        let snap = result.snapshot
        let quoted = "“\(clip(text, 80))”"
        guard let match = result.match, let element = snap.element(match.ref) else {
            var lines: [String] = []
            if result.match != nil {
                lines.append("Found \(quoted), but the page changed while Glide scrolled to it. Try browser.find again.")
            } else if result.total > 0 {
                lines.append("There \(result.total == 1 ? "is only 1 match" : "are only \(result.total) matches") for \(quoted); nth \(nth) is beyond them.")
            } else if let role, !result.otherRoles.isEmpty {
                let kinds = result.otherRoles.map { $0 == "text" ? "plain text" : $0 == "clickable" ? "a clickable element" : "a \($0)" }
                let listed = kinds.count > 1 ? kinds.dropLast().joined(separator: ", ") + " and " + (kinds.last ?? "") : kinds.joined()
                lines.append("Nothing with role \(role) matches \(quoted); \(listed) \(kinds.count > 1 ? "do" : "does"). Leave out role, or use one of those.")
            } else {
                lines.append("Nothing on the page matches \(quoted).")
            }
            if !result.suggestions.isEmpty {
                lines.append("Similar labels: \(result.suggestions.map { "“\(clip($0, 60))”" }.joined(separator: ", ")).")
            }
            return BrowserEnv.render(snap, lead: lines.joined(separator: " "), previous: previous, ok: false, maxChars: 3000,
                                     extra: ["matches": .number(Double(result.total))])
        }
        var lead = "Found \(Self.line(element, at: match.location, in: snap))"
        if result.stillOutOfView {
            lead += ". It's \(match.location), and scrolling didn't bring it into view; browser.click can still try it."
        } else if result.scrolled {
            lead += ". It was \(match.location); now scrolled into view."
        } else {
            lead += ", \(match.location)."
        }
        var notes: [String] = []
        var skip: Set<String> = [match.ref]
        if !result.others.isEmpty {
            notes.append("Other matches (\(result.total) in all; nth picks one):")
            for other in result.others {
                if let e = snap.element(other.ref) {
                    notes.append("- \(Self.line(e, at: other.location, in: snap)) — \(other.location) (nth \(other.nth))")
                    skip.insert(other.ref)
                } else {
                    notes.append("- (nth \(other.nth)) \(other.role) \"\(clip(other.name, 60))\" — \(other.location)")
                }
            }
            if result.total > result.others.count + 1 { notes.append("- …and \(result.total - result.others.count - 1) more") }
        }
        let found: JSONValue = ["ref": .string(match.ref), "role": .string(match.role), "name": .string(clip(match.name, 80)), "where": .string(match.location)]
        return BrowserEnv.render(snap, lead: lead, notes: notes, previous: previous, skip: skip,
                                 extra: ["match": found, "matches": .number(Double(result.total))])
    }

    /// The element's snapshot line, without its `in "dialog …"` when the location says so already.
    static func line(_ element: PageSnapshot.Element, at location: String, in snap: PageSnapshot) -> String {
        var e = element
        if location.contains("dialog"), e.context?.hasPrefix("dialog") == true { e.context = nil }
        return snap.line(for: e)
    }
}

struct BrowserClickTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.click",
        summary: "Click an element by its ref from the latest snapshot (real mouse events; waits for the page to settle). Returns the updated page.",
        inputSchema: BrowserArgs.object([("ref", BrowserArgs.refSchema)], required: ["ref"]),
        category: .browser)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let ref = arguments.optionalString("ref") ?? ""
        let page = rt.currentSnapshot(context)
        return BrowserRisk.click(ref: ref, element: page?.element(ref), label: BrowserArgs.label(arguments), page: page)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let ref = try BrowserArgs.ref(arguments)
        return try await rt.perform(context) { env in
            let tab = try env.requireTab()
            let (previous, element) = try env.element(ref, in: tab)
            let before = Set((try? await env.driver.tabs())?.map(\.id) ?? [])
            let outcome = try await env.driver.click(tabID: tab, ref: ref)
            let lead = "Clicked \(ref) \(element.role)\(element.name.isEmpty ? "" : " “\(clip(element.name, 60))”")."
            // A link with target=_blank or a script popup opens a new tab: continue there. It's
            // Glide's only when the backend says so (it came from one of Glide's own tabs); one
            // from the user's tab is theirs, so it's never closed behind their back and closing
            // it needs their approval.
            var notes = outcome.notes
            if !before.isEmpty, let tabs = try? await env.driver.tabs() {
                let isTracked = { (id: String) in env.sessions.isTracked(backend: env.kind, tabID: id) }
                if let popup = Self.popup(openedFrom: tab, before: before, after: tabs, isTracked: isTracked) {
                    let victims = env.sessions.adopt(key: env.key, backend: env.kind, tabID: popup.id, jobID: env.jobID, openedByGlide: popup.ownedByGlide)
                    for v in victims { try? await env.driver.closeTab(v.tabID); env.sessions.forgetTab(backend: env.kind, tabID: v.tabID) }
                    _ = try? await env.driver.waitForSettle(tabID: popup.id)
                    return try await env.pageOutput(tab: popup.id, lead: lead, notes: notes + ["The click opened a new tab (\(popup.id)); now working there. The previous tab is \(tab)."],
                                                    previous: nil, settled: outcome.settled)
                }
                for other in Self.unexplainedNewTabs(before: before, after: tabs, isTracked: isTracked) {
                    notes.append("Tab \(other.id) opened meanwhile, but Chrome didn't say from where. If this click opened it, use browser.switch_tab with tab_id \(other.id) to work there.")
                }
            }
            return try await env.pageOutput(tab: tab, lead: lead, notes: notes, previous: previous, settled: outcome.settled)
        }
    }

    /// The tab a click on `tab` opened: new since the click and opened from `tab`. A tab that
    /// appeared at the same moment for another reason — the user opening one, another app
    /// opening a link, a parallel item's popup — has another opener (or none) and is left alone,
    /// as is any tab Glide already accounts for.
    static func popup(openedFrom tab: String, before: Set<String>, after tabs: [BrowserTab], isTracked: (String) -> Bool) -> BrowserTab? {
        tabs.first { $0.openerID == tab && isNewAndFree($0, before: before, isTracked: isTracked) }
    }

    /// New tabs whose opener the backend didn't report: maybe this click's, maybe not. They're
    /// only mentioned to the model, which can switch to one (as it would to any tab of the user's).
    static func unexplainedNewTabs(before: Set<String>, after tabs: [BrowserTab], isTracked: (String) -> Bool) -> [BrowserTab] {
        tabs.filter { $0.openerID == nil && $0.url != "about:blank" && isNewAndFree($0, before: before, isTracked: isTracked) }.prefix(3).map { $0 }
    }

    private static func isNewAndFree(_ t: BrowserTab, before: Set<String>, isTracked: (String) -> Bool) -> Bool {
        !before.contains(t.id) && !isTracked(t.id) && !BrowserDriver.isRestricted(url: t.url)
    }
}

struct BrowserTypeTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.type",
        summary: "Type text into a field by ref (never password fields). Replaces the field's text by default; submit presses Return afterwards. Returns the updated page.",
        inputSchema: BrowserArgs.object([
            ("ref", BrowserArgs.refSchema),
            ("text", BrowserArgs.string("Text to type.")),
            ("clear", BrowserArgs.boolean("Replace what's there (default: true for form fields, false for rich-text areas).")),
            ("submit", BrowserArgs.boolean("Press Return after typing (default false).")),
        ], required: ["ref", "text"]),
        category: .browser)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let ref = arguments.optionalString("ref") ?? ""
        let page = rt.currentSnapshot(context)
        return BrowserRisk.type(ref: ref, element: page?.element(ref), label: BrowserArgs.label(arguments),
                                text: arguments["text"]?.stringValue ?? "", submit: arguments.optionalBool("submit") ?? false, page: page)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let ref = try BrowserArgs.ref(arguments)
        guard let text = arguments["text"]?.stringValue else { throw ToolError.invalidArguments("missing “text”") }
        guard text.count <= 100_000 else { throw ToolError.invalidArguments("“text” is too long (at most 100,000 characters)") }
        let clear = arguments.optionalBool("clear")
        let submit = arguments.optionalBool("submit") ?? false
        if text.isEmpty, clear == false, !submit { throw ToolError.invalidArguments("nothing to type") }
        return try await rt.perform(context) { env in
            let tab = try env.requireTab()
            let (previous, element) = try env.element(ref, in: tab)
            if element.secure { throw BrowserActionError("\(ref) is a password field. Glide never types passwords; please enter it yourself.") }
            let outcome = try await env.driver.type(tabID: tab, ref: ref, text: text, clear: clear, submit: submit)
            var lead = "Typed into \(ref)\(element.name.isEmpty ? "" : " “\(clip(element.name, 60))”")\(submit ? " and pressed Return" : "")."
            if let value = outcome.value, !submit { lead += " It now contains “\(clip(value, 200))”." }
            return try await env.pageOutput(tab: tab, lead: lead, notes: outcome.notes, previous: previous, settled: outcome.settled)
        }
    }
}

struct BrowserSelectTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.select",
        summary: "Choose an option in a dropdown (<select>) by its value or visible label. Returns the updated page.",
        inputSchema: BrowserArgs.object([
            ("ref", BrowserArgs.refSchema),
            ("value", BrowserArgs.string("The option's visible label or value.")),
        ], required: ["ref", "value"]),
        category: .browser)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let ref = arguments.optionalString("ref") ?? ""
        let page = rt.currentSnapshot(context)
        return BrowserRisk.select(ref: ref, element: page?.element(ref), label: BrowserArgs.label(arguments),
                                  value: arguments["value"]?.stringValue ?? "", page: page)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let ref = try BrowserArgs.ref(arguments)
        guard let value = arguments["value"]?.stringValue, !value.isEmpty else { throw ToolError.invalidArguments("missing “value”") }
        return try await rt.perform(context) { env in
            let tab = try env.requireTab()
            let (previous, element) = try env.element(ref, in: tab)
            let outcome = try await env.driver.select(tabID: tab, ref: ref, value: value)
            let lead = "Chose “\(clip(outcome.value ?? value, 80))” in \(ref)\(element.name.isEmpty ? "" : " “\(clip(element.name, 60))”")."
            return try await env.pageOutput(tab: tab, lead: lead, notes: outcome.notes, previous: previous, settled: outcome.settled)
        }
    }
}

struct BrowserPressTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.press",
        summary: "Press keys in the current tab's focused element: \"Enter\", \"Escape\", \"Tab\", \"ArrowDown\", \"Control+A\", \"Meta+L\", or several separated by spaces.",
        inputSchema: BrowserArgs.object([("keys", BrowserArgs.string("Keys to press, e.g. \"Enter\" or \"Shift+Tab Enter\"."))], required: ["keys"]),
        category: .browser)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        BrowserRisk.press(keys: arguments.optionalString("keys") ?? "", page: rt.currentSnapshot(context))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let keys = try arguments.requiredString("keys")
        return try await rt.perform(context) { env in
            let tab = try env.requireTab()
            let previous = env.lastSnapshot(tab)
            let outcome = try await env.driver.press(tabID: tab, keys: keys)
            return try await env.pageOutput(tab: tab, lead: "Pressed \(clip(keys, 60)).", notes: outcome.notes, previous: previous, settled: outcome.settled)
        }
    }
}

struct BrowserScrollTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.scroll",
        summary: "Scroll the current tab to reveal more elements: an open dialog or popup scrolls first, else the panel you're in, else the page (or the scrollable panel around an element). Returns the updated page. To reach something specific, browser.find is faster.",
        inputSchema: BrowserArgs.object([
            ("direction", BrowserArgs.string("Which way to scroll.", enum: ["up", "down", "left", "right"])),
            ("amount", BrowserArgs.number("How far, in screens (default 1).")),
            ("ref", BrowserArgs.string("Optional element ref whose scrollable panel to scroll.")),
        ], required: ["direction"]),
        category: .browser)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        ToolVerdict(risk: .low, summary: "Scroll \(arguments.optionalString("direction") ?? "down") in the browser tab")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let raw = try arguments.requiredString("direction").lowercased()
        guard let direction = ScrollDirection(rawValue: raw) else { throw ToolError.invalidArguments("“direction” must be up, down, left or right") }
        let amount = arguments.optionalDouble("amount") ?? 1
        guard amount.isFinite, amount > 0 else { throw ToolError.invalidArguments("“amount” must be a positive number of screens") }
        let ref = try arguments.optionalString("ref").map { _ in try BrowserArgs.ref(arguments) }
        return try await rt.perform(context) { env in
            let tab = try env.requireTab()
            let previous = env.lastSnapshot(tab)
            if let ref { _ = try env.element(ref, in: tab) }
            let outcome = try await env.driver.scroll(tabID: tab, direction: direction, amount: amount, ref: ref)
            // Say what moved (or that nothing could) first, so a stuck scroll is obvious.
            let lead = outcome.moved ? "Scrolled \(outcome.scrolled ?? "the page") \(direction.rawValue)." : (outcome.notes.first ?? "Nothing scrolled.")
            let notes = (outcome.moved ? outcome.notes : Array(outcome.notes.dropFirst())) + ["To look for something specific, use browser.find."]
            return try await env.pageOutput(tab: tab, lead: lead, notes: notes, previous: previous, settled: outcome.settled)
        }
    }
}

struct BrowserReadTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.read",
        summary: "Read the current tab's text: the main content, or the text of every element matching a CSS selector. Use for long pages instead of scrolling.",
        inputSchema: BrowserArgs.object([
            ("max_chars", BrowserArgs.integer("Most characters to return (default 6000, up to 20000).")),
            ("selector", BrowserArgs.string("Optional CSS selector, e.g. \"table\" or \".result h3\".")),
        ]),
        category: .browser, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        ToolVerdict(risk: .low, summary: "Read the browser tab's text")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let maxChars = BrowserArgs.int(arguments, "max_chars", default: 6000, in: 200...20_000)
        let selector = arguments.optionalString("selector")
        return try await rt.perform(context) { env in
            let (tab, _) = try await env.tabForReading()
            let page = try await env.driver.readText(tabID: tab, maxChars: maxChars, selector: selector)
            var lines = ["“\(clip(page.title.isEmpty ? "(untitled)" : page.title, 100))” \(clip(page.url, 200))"]
            if page.total > page.text.count { lines.append("(showing the first \(page.text.count) of \(page.total) characters)") }
            lines.append("")
            lines.append(page.text.isEmpty ? "(no text)" : page.text)
            let data: JSONValue = ["url": .string(page.url), "title": .string(page.title), "text": .string(page.text), "total_chars": .number(Double(page.total))]
            return ToolOutput(ok: true, text: toolTruncate(lines.joined(separator: "\n"), max: maxChars + 500), data: data)
        }
    }
}

struct BrowserBackTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.back",
        summary: "Go back to the previous page in the current tab. Returns that page.",
        inputSchema: BrowserArgs.object([]),
        category: .browser)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        ToolVerdict(risk: .low, summary: "Go back in the browser tab")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await rt.perform(context) { env in
            let tab = try env.requireTab()
            let previous = env.lastSnapshot(tab)
            guard try await env.driver.back(tabID: tab) else {
                return ToolOutput(ok: false, text: "There's no previous page in this tab.")
            }
            return try await env.pageOutput(tab: tab, lead: "Went back.", previous: previous)
        }
    }
}

struct BrowserTabsTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.tabs",
        summary: "List the open Chrome tabs (id, title, address; which one this task is using).",
        inputSchema: BrowserArgs.object([]),
        category: .browser, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        ToolVerdict(risk: .low, summary: "List the browser tabs")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try await rt.perform(context) { env in
            let tabs = try await env.driver.tabs()
            return BrowserTabsTool.listing(tabs, env: env, lead: "\(tabs.count) tab\(tabs.count == 1 ? "" : "s") open:")
        }
    }

    static func listing(_ tabs: [BrowserTab], env: BrowserEnv, lead: String) -> ToolOutput {
        let current = env.currentTab
        var lines = [lead]
        for t in tabs {
            let mine = t.ownedByGlide || env.sessions.isGlideTab(backend: env.kind, tabID: t.id)
            var line = "\(t.id == current ? "*" : "-") \(t.id) “\(clip(t.title.isEmpty ? "(untitled)" : t.title, 70))” \(clip(t.url, 120))"
            line += mine ? " [opened by Glide]" : " [yours]"
            if t.active { line += " [front]" }
            lines.append(line)
        }
        if current != nil { lines.append("(* = this task's tab)") }
        let data = JSONValue.array(tabs.map { t in
            ["id": .string(t.id), "url": .string(t.url), "title": .string(t.title), "active": .bool(t.active), "current": .bool(t.id == current)]
        })
        return ToolOutput(ok: true, text: toolTruncate(lines.joined(separator: "\n")), data: data)
    }
}

struct BrowserSwitchTabTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.switch_tab",
        summary: "Make another open tab this task's tab (ids from browser.tabs). Returns its snapshot.",
        inputSchema: BrowserArgs.object([("tab_id", BrowserArgs.string("Tab id from browser.tabs."))], required: ["tab_id"]),
        category: .browser)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        ToolVerdict(risk: .low, summary: "Switch to browser tab \(clip(arguments.optionalString("tab_id") ?? "", 40))")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let id = try arguments.requiredString("tab_id").trimmingCharacters(in: .whitespaces)
        return try await rt.perform(context) { env in
            let tabs = try await env.driver.tabs()
            guard let tab = tabs.first(where: { $0.id == id }) else {
                return ToolOutput(ok: false, text: "There's no tab with id \(clip(id, 40)). Use browser.tabs to see the open tabs.")
            }
            if BrowserDriver.isRestricted(url: tab.url) { throw BrowserError.restrictedPage(tab.url) }
            let victims = env.sessions.adopt(key: env.key, backend: env.kind, tabID: tab.id, jobID: env.jobID, openedByGlide: tab.ownedByGlide)
            for v in victims { try? await env.driver.closeTab(v.tabID); env.sessions.forgetTab(backend: env.kind, tabID: v.tabID) }
            if !env.settings.useBackgroundTabs { try? await env.driver.activateTab(tab.id) }
            return try await env.pageOutput(tab: tab.id, lead: "Switched to tab \(tab.id).", previous: env.lastSnapshot(tab.id))
        }
    }
}

struct BrowserCloseTabTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.close_tab",
        summary: "Close a tab (default: this task's tab). Tabs you opened yourself need your approval.",
        inputSchema: BrowserArgs.object([("tab_id", BrowserArgs.string("Tab id from browser.tabs; omit for this task's tab."))]),
        category: .browser)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let session = rt.sessions.session(rt.key(context))
        // With nothing to close the call just fails, so there's no risk to judge.
        guard let id = arguments.optionalString("tab_id") ?? session?.tabID else { return BrowserRisk.closeTab(tabID: "", isGlideTab: true) }
        let glide = BrowserBackendKind.allCases.contains { rt.sessions.isGlideTab(backend: $0, tabID: id) }
        return BrowserRisk.closeTab(tabID: id, isGlideTab: glide)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let requested = arguments.optionalString("tab_id")?.trimmingCharacters(in: .whitespaces)
        return try await rt.perform(context) { env in
            guard let id = requested ?? env.currentTab else {
                return ToolOutput(ok: false, text: "This task has no tab open. Pass a tab_id from browser.tabs.")
            }
            let wasCurrent = id == env.currentTab
            try await env.driver.closeTab(id)
            env.sessions.forgetTab(backend: env.kind, tabID: id)
            if wasCurrent { env.sessions.clear(env.key) }
            let tabs = (try? await env.driver.tabs()) ?? []
            return BrowserTabsTool.listing(tabs, env: env, lead: "Closed tab \(clip(id, 40)).\(wasCurrent ? " Use browser.open or browser.switch_tab to continue." : "") \(tabs.count) tab\(tabs.count == 1 ? "" : "s") left:")
        }
    }
}

struct BrowserWaitTool: AgentTool {
    let rt: BrowserRuntime
    let spec = ToolSpec(
        name: "browser.wait",
        summary: "Wait until text appears, a CSS selector matches a visible element, or the page finishes loading. Returns the page.",
        inputSchema: BrowserArgs.object([
            ("for", BrowserArgs.string("What to wait for.", enum: ["text", "selector", "load"])),
            ("value", BrowserArgs.string("The text or CSS selector (not needed for load).")),
            ("timeout_s", BrowserArgs.number("Most seconds to wait (default 10, up to 60).")),
        ], required: ["for"]),
        category: .browser, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        ToolVerdict(risk: .low, summary: "Wait for the browser page")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let kind = try arguments.requiredString("for").lowercased()
        let timeout = min(60, max(0.5, arguments.optionalDouble("timeout_s") ?? 10))
        let condition: BrowserWaitCondition
        let what: String
        switch kind {
        case "load":
            condition = .load
            what = "the page to finish loading"
        case "text", "selector":
            guard let value = arguments.optionalString("value") else { throw ToolError.invalidArguments("“value” is required when waiting for \(kind)") }
            condition = kind == "text" ? .text(value) : .selector(value)
            what = kind == "text" ? "the text “\(clip(value, 80))”" : "an element matching “\(clip(value, 80))”"
        default:
            throw ToolError.invalidArguments("“for” must be text, selector or load")
        }
        return try await rt.perform(context) { env in
            let tab = try env.requireTab()
            let previous = env.lastSnapshot(tab)
            let met = try await env.driver.wait(tabID: tab, for: condition, timeout: timeout)
            let lead = met ? "Waited for \(what)." : "Gave up after \(Int(timeout.rounded())) s waiting for \(what)."
            return try await env.pageOutput(tab: tab, lead: lead, previous: previous, ok: met)
        }
    }
}
