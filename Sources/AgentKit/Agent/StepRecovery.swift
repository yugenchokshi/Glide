import Foundation
import AppKit
import AutomationKit

/// What a retried step (or the recovery planner) is told about the attempt before it: what
/// already took effect, and what the page looks like now. In the baseline runs a retried step
/// added the same shoes to the cart a second time because nothing told it the first click had
/// worked.
enum RetryNotes {
    /// Most side effects listed; the newest are kept.
    static let maxShown = 12

    /// The block for a prompt, or nil when there's nothing to say. `scope` says where the
    /// actions happened ("earlier in this task", "in an earlier try at this item").
    static func render(_ sideEffects: [String], scope: String = "earlier in this task", page: String? = nil) -> String? {
        let effects = sideEffects.filter { !$0.isEmpty }
        let page = page.flatMap { $0.isEmpty ? nil : $0 }
        guard !effects.isEmpty || page != nil else { return nil }
        var lines: [String] = []
        if !effects.isEmpty {
            lines.append("Already done \(scope) (these took effect):")
            if effects.count > maxShown { lines.append("- … \(effects.count - maxShown) earlier actions") }
            lines += effects.suffix(maxShown).map { "- \($0)" }
            lines.append("Check the current state first (for example the cart count, or what a form already contains) and don't repeat these unless it shows they didn't happen.")
        }
        if let page { lines.append("Current page:\n\(page)") }
        return lines.joined(separator: "\n")
    }

    /// Title and address of a page snapshot, plus its first lines (`maxChars` in all).
    static func page(_ snapshot: PageSnapshot?, maxChars: Int = 0) -> String? {
        guard let snapshot else { return nil }
        var text = "“\(PageSnapshot.clip(snapshot.title.isEmpty ? "(untitled)" : snapshot.title, 100))” \(PageSnapshot.clip(snapshot.url, 200))"
        if maxChars > 0 { text += "\n" + ToolStepRunner.clip(snapshot.compact(maxChars: maxChars), maxChars) }
        return text
    }
}

/// Moving a browser step that got stuck in the page structure onto the screen: the same step,
/// once, driven with the mouse and keyboard in the Chrome window that shows its tab. In the
/// baseline runs the recovery planner reached this fix by itself (Google Flights' date picker
/// took a handful of on-screen actions) but only after two failed replans; switching at once
/// saves those, and pages whose widgets don't respond to scripted input still get done.
enum OnScreenSwitch {
    /// The activity entry that tells the user why the cursor is about to move.
    static let title = "Switching to on-screen control"
    static let detail = "The browser step got stuck in the background, so Glide is doing it with the mouse and keyboard in Chrome."

    /// Whether a step on `route` that ended with `status` gets its on-screen try: a browser
    /// step that stalled or ran out of turns, with the setting on. Callers check the screen
    /// itself (Accessibility, the job's screen setting).
    static func applies(route: ExecutionRoute, status: StepResult.Status, settings: AppSettings) -> Bool {
        guard route == .browser, settings.browser.onScreenFallback else { return false }
        switch status {
        case .stalled: return true
        case .failed(let reason): return ToolStepRunner.isTurnLimit(reason)
        case .done, .taskDone, .blocked: return false
        }
    }

    /// The reason a stalled or failed status carries (empty for the others).
    static func reason(_ status: StepResult.Status) -> String {
        switch status {
        case .stalled(let r), .failed(let r), .blocked(let r): return r
        case .taskDone, .done: return ""
        }
    }

    /// What the on-screen run is told: that the browser route got stuck and how, what it
    /// tried, and what already took effect.
    static func briefing(reason: String, tried: String, alreadyDone: [String], scope: String = "earlier in this task") -> String {
        var lines = ["This step was first tried in the page's structure in the background and got stuck: \(ToolStepRunner.clip(reason, 400))"]
        let tried = tried.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tried.isEmpty { lines.append(ToolStepRunner.clip(tried, 800)) }
        lines.append("Do it on screen now with the mouse and keyboard: the Chrome window with the page is in front. Look at the page first and carry on from where it is.")
        if let done = RetryNotes.render(alreadyDone, scope: scope) { lines.append(done) }
        return lines.joined(separator: "\n")
    }

    /// The step to run on screen. No app is named: the right Chrome window is brought forward
    /// first, and activating "Google Chrome" by name could pick the other Chrome (the user's
    /// or Glide's own) when both run.
    static func screenStep(_ step: RecipeStep, briefing: String) -> RecipeStep {
        var s = step
        s.route = .gui
        s.app = nil
        s.instruction = step.instruction + "\n\n" + briefing
        return s
    }

    static func screenStep(_ step: PlanStep, briefing: String) -> PlanStep {
        var s = step
        s.route = .gui
        s.app = nil
        s.hint = nil
        s.instruction = step.instruction + "\n\n" + briefing
        return s
    }

    /// Bundle ids of the Chromes the extension may live in.
    static let chromeBundleIDs = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "org.chromium.Chromium"]

    /// Brings the session's tab to the front of its window, then that Chrome to the front of
    /// the screen, and waits briefly for it to get there (the on-screen run observes whatever
    /// is frontmost). Does nothing when the session has no tab, its browser isn't connected, or
    /// it's a headless Chrome (tests).
    static func bringForward(sessionKey: String, hub: BrowserHub = .shared, sessions: BrowserSessions = .shared) async {
        guard let session = sessions.session(sessionKey), let backend = hub.registered(session.backend), await backend.isConnected() else { return }
        try? await backend.activateTab(session.tabID)
        let glideChrome = hub.registered(.glideChrome) as? GlideChromeBackend
        var pid: pid_t?
        if session.backend == .glideChrome, let chrome = backend as? GlideChromeBackend {
            guard !(await chrome.currentConfiguration.headless) else { return }
            pid = await chrome.launchedProcessID
            guard pid != nil else { return }
        }
        let skip = await glideChrome?.launchedProcessID
        let target = pid
        let activated: pid_t? = await MainActor.run {
            let app: NSRunningApplication?
            if let target {
                app = NSRunningApplication(processIdentifier: target)
            } else {
                app = chromeBundleIDs.lazy.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
                    .first { $0.processIdentifier != skip }
            }
            guard let app, app.activate() else { return nil }
            return app.processIdentifier
        }
        guard let activated else { return }
        for _ in 0..<20 {
            let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            if front == activated { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
