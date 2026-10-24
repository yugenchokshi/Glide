import AppKit
import os
import SwiftUI
import AgentKit
import AutomationKit

/// Where the notch is on a given display. On displays without a notch, a small pill is
/// placed in the empty center of the menu bar.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var hasNotch: Bool
    /// Notch (or pill) rect in AppKit screen coordinates (bottom-left origin).
    var notchRect: CGRect

    /// Nil while macOS reports no screens (mid display reconfiguration).
    static func best() -> NotchGeometry? {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first else { return nil }
        return make(for: screen)
    }

    static let fallback = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), hasNotch: false,
                                        notchRect: CGRect(x: 630, y: 876, width: 180, height: 24))

    static func make(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let h = screen.safeAreaInsets.top
            let rect = CGRect(x: left.maxX, y: frame.maxY - h, width: right.minX - left.maxX, height: h)
            return NotchGeometry(screenFrame: frame, hasNotch: true, notchRect: rect)
        }
        let menuBar = max(24, frame.maxY - screen.visibleFrame.maxY)
        let w: CGFloat = 180
        return NotchGeometry(screenFrame: frame, hasNotch: false, notchRect: CGRect(x: frame.midX - w / 2, y: frame.maxY - menuBar, width: w, height: menuBar))
    }
}

/// Borderless, non-activating panel above the menu bar. It only becomes key while the user
/// is typing a task, so the app they were using keeps focus otherwise.
final class NotchPanel: NSPanel {
    var allowsKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Edit shortcuts for the task field. The panel never activates the app, so these can't
    /// rely on the app's main menu being consulted.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        let action: Selector? = switch (mods, key) {
        case ([.command], "v"): #selector(NSText.paste(_:))
        case ([.command], "c"): #selector(NSText.copy(_:))
        case ([.command], "x"): #selector(NSText.cut(_:))
        case ([.command], "a"): #selector(NSText.selectAll(_:))
        case ([.command], "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

enum NotchPresentation: Equatable {
    /// `job`: a background job's confirmation or finished card.
    case idle, hover, input, running, detail, approval, result, job
}

/// An approval the notch is showing: the quick task's, or one a background job is waiting on.
struct NotchApproval {
    var request: ApprovalRequest
    /// Nil for the quick task.
    var jobID: String?
}

@MainActor
@Observable
final class NotchModel {
    var presentation: NotchPresentation = .idle
    var geometry = NotchGeometry.best() ?? .fallback
    var inputText = ""
    var hovering = false
    var inputOpen = false
    var detailOpen = false
    var resultVisible = false
    var historyOpen = false
    var focusToken = 0
    /// The detail view shows the background jobs list rather than the last quick task.
    var jobsDetailOpen = false
    /// Job whose card (confirmation or result) the notch shows, set when a job needs the user.
    var attentionJobID: String?

    let controller: TaskController
    let settings: SettingsStore
    let jobs: any JobsSource
    var openSettings: (String?) -> Void = { _ in }
    /// Opens Settings › Jobs on one job.
    var openJob: (String) -> Void = { _ in }
    private var dismissWork: DispatchWorkItem?
    private var jobDismissWork: DispatchWorkItem?
    /// Last copy of the attention job, so the card survives a reload that briefly drops it.
    private var attentionSnapshot: JobRecord?
    /// Jobs the user stopped from the notch: their "stopped" result card would only echo the click.
    private var stoppedFromNotch: Set<String> = []

    init(controller: TaskController, settings: SettingsStore, jobs: (any JobsSource)? = nil) {
        self.controller = controller
        self.settings = settings
        self.jobs = jobs ?? JobCenter.shared
    }

    func recompute() {
        let c = controller
        let p: NotchPresentation
        if activeApproval != nil {
            p = .approval
        } else if c.isRunning {
            p = detailOpen ? .detail : .running
        } else if inputOpen {
            p = historyOpen || detailOpen ? .detail : .input
        } else if attentionJob != nil {
            p = .job
        } else if resultVisible {
            p = detailOpen ? .detail : .result
        } else {
            p = hovering ? .hover : .idle
        }
        if p != presentation { presentation = p }
    }

    /// The quick task's approval first (it holds the screen), then the job that last asked for
    /// attention, then the oldest job's.
    var activeApproval: NotchApproval? {
        if let req = controller.pendingApproval { return NotchApproval(request: req, jobID: nil) }
        let pending = jobs.pendingApprovals
        guard !pending.isEmpty else { return nil }
        if let id = attentionJobID, let req = pending[id] { return NotchApproval(request: req, jobID: id) }
        let id = pending.keys.min { a, b in
            let da = jobs.job(a)?.createdAt ?? .distantPast, db = jobs.job(b)?.createdAt ?? .distantPast
            return da == db ? a < b : da < db
        }
        guard let id, let req = pending[id] else { return nil }
        return NotchApproval(request: req, jobID: id)
    }

    func respondToApproval(_ decision: ApprovalDecision) {
        guard let approval = activeApproval else { return }
        if let id = approval.jobID {
            if decision == .stop { stoppedFromNotch.insert(id) }
            jobs.respond(jobID: id, decision: decision)
        } else {
            controller.respondToApproval(decision)
        }
        recompute()
    }

    /// The job shown in the wing ring: one is running and the notch isn't busy with a quick task.
    var wingJob: JobRecord? { controller.isRunning ? nil : jobs.activeJob }

    /// The job in the running pill above the task field: the running one, else the most
    /// recently updated job that's paused, waiting, needs input or awaits confirmation.
    var pillJob: JobRecord? {
        if let active = jobs.activeJob { return active }
        return jobs.jobs.filter { [.paused, .waiting, .needsInput, .awaitingConfirmation].contains($0.status) }
            .max { $0.updatedAt < $1.updatedAt }
    }

    /// The job whose card is showing, while it still needs the user.
    var attentionJob: JobRecord? {
        guard let id = attentionJobID else { return nil }
        guard let job = jobs.job(id) ?? (attentionSnapshot?.id == id ? attentionSnapshot : nil) else { return nil }
        let wantsCard = job.status == .awaitingConfirmation || job.status == .needsInput || job.status.isFinished
        return wantsCard ? job : nil
    }

    /// Anything beyond the bare notch (or hover) is on screen.
    var isExpanded: Bool { presentation != .idle && presentation != .hover }

    /// Size of the visible notch shape for the current presentation.
    var size: CGSize {
        let n = geometry.notchRect.size
        let top = n.height
        // The wings must clear the physical notch for the job ring to be visible at all.
        let wing: CGFloat = wingJob == nil ? 0 : 64
        switch presentation {
        case .idle: return CGSize(width: n.width + wing, height: top)
        case .hover: return CGSize(width: n.width + max(24, wing + 8), height: top + 4)
        case .input: return CGSize(width: max(n.width + 240, 560), height: top + 148 + (pillJob == nil ? 0 : 50))
        case .running: return CGSize(width: max(n.width + 200, 500), height: top + 52)
        case .detail: return CGSize(width: max(n.width + 280, 600), height: top + 400)
        case .approval: return CGSize(width: max(n.width + 240, 560), height: top + 190)
        case .result: return CGSize(width: max(n.width + 240, 560), height: top + 116)
        case .job: return CGSize(width: max(n.width + 240, 560), height: top + (attentionJob?.status == .awaitingConfirmation ? 168 : 116))
        }
    }

    var wantsKey: Bool { presentation == .input || (presentation == .detail && !controller.isRunning) }

    /// Set when the user asks to open the notch; used to log open latency.
    var openRequestedAt: CFAbsoluteTime?

    func open() {
        openRequestedAt = CFAbsoluteTimeGetCurrent()
        guard !controller.isRunning else { detailOpen.toggle(); recompute(); return }
        inputOpen = true
        resultVisible = false
        detailOpen = false
        historyOpen = false
        jobsDetailOpen = false
        focusToken += 1
        recompute()
    }

    func close() {
        inputOpen = false
        detailOpen = false
        historyOpen = false
        jobsDetailOpen = false
        resultVisible = false
        clearJobAttention()
        recompute()
    }

    func toggle() {
        if inputOpen || detailOpen || resultVisible || attentionJob != nil { close() } else { open() }
    }

    func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputOpen = false
        historyOpen = false
        detailOpen = false
        resultVisible = false
        controller.start(text)
        inputText = ""
        recompute()
    }

    func taskFinished(_ result: TaskResult) {
        resultVisible = true
        detailOpen = false
        recompute()
        dismissWork?.cancel()
        guard result.status == .completed || result.status == .stopped else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.inputOpen, !self.detailOpen else { return }
            self.resultVisible = false
            self.recompute()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.settings.completedDismissSeconds, execute: work)
    }

    // MARK: Background jobs

    /// Whether a job event should surface at all (card or notification).
    func shouldAnnounce(_ job: JobRecord) -> Bool {
        !(job.status == .stopped && stoppedFromNotch.contains(job.id))
    }

    /// A job needs the user (approval, confirmation, question, finished): show its card.
    /// Approvals show through `activeApproval` on their own; marking the job also makes its
    /// approval win over another job's.
    func jobNeedsAttention(_ id: String) {
        guard let job = jobs.job(id), shouldAnnounce(job) else { return }
        showJobCard(job)
    }

    func jobFinished(_ job: JobRecord) {
        guard shouldAnnounce(job) else { return }
        showJobCard(job)
    }

    private func showJobCard(_ job: JobRecord) {
        attentionJobID = job.id
        attentionSnapshot = job
        recompute()
        jobDismissWork?.cancel()
        // Successful results fold away like quick-task results; failures and questions stay.
        guard job.status == .completed || job.status == .stopped else { return }
        let id = job.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.attentionJobID == id, !self.hovering else { return }
            self.clearJobAttention()
            self.recompute()
        }
        jobDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(4, settings.settings.completedDismissSeconds), execute: work)
    }

    private func clearJobAttention() {
        jobDismissWork?.cancel()
        jobDismissWork = nil
        attentionJobID = nil
        attentionSnapshot = nil
    }

    func dismissJobCard() {
        clearJobAttention()
        recompute()
    }

    func startJob(_ id: String) {
        jobs.start(id)
        // The quick task that handed off to this job left a "Started a background job" result.
        resultVisible = false
        dismissJobCard()
    }

    /// Cancel on the confirmation card: the job never started, so stopping it is final.
    func cancelJob(_ id: String) {
        stopJob(id)
        resultVisible = false
        dismissJobCard()
    }

    func stopJob(_ id: String) {
        stoppedFromNotch.insert(id)
        jobs.stop(id)
        recompute()
    }

    /// Opens the detail view on the "Background jobs" list (from the running pill).
    func showJobsDetail() {
        inputOpen = true
        historyOpen = false
        detailOpen = true
        jobsDetailOpen = true
        recompute()
    }
}

/// Owns the notch panel: positions it on the notch, resizes it per presentation, and keeps
/// it in place across display changes.
@MainActor
final class NotchWindowController {
    let panel = NotchPanel()
    let model: NotchModel
    private var shrinkWork: DispatchWorkItem?
    private var previousApp: NSRunningApplication?

    init(model: NotchModel) {
        self.model = model
        let root = NotchRootView(model: model)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        layout(animated: false)
        panel.orderFrontRegardless()
        observe()
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The user clicked into another app: don't grab focus back on the next relayout.
                self?.panel.allowsKey = false
                self?.previousApp = nil
            }
        }
        // While the agent is moving the pointer, the panel is click-through so it can never
        // intercept an agent click; it becomes interactive again ~1s after agent input stops.
        let panelRef = panel
        AutomationRuntime.shared.executor.input.willUsePointer = {
            DispatchQueue.main.async { panelRef.ignoresMouseEvents = true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.ignoresMouseEvents else { return }
                let idle = Date().timeIntervalSince(AutomationRuntime.shared.executor.input.lastPost) > 1.0
                if idle || AutomationRuntime.shared.gate.isPaused || self.model.activeApproval != nil {
                    self.panel.ignoresMouseEvents = false
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let g = NotchGeometry.best() else { return }
                self?.model.geometry = g
                self?.layout(animated: false)
            }
        }
    }

    private func observe() {
        withObservationTracking {
            _ = model.presentation
            _ = model.geometry
            _ = model.controller.phase
            _ = model.controller.pendingApproval
            _ = model.hovering
            _ = model.jobs.jobs
            _ = model.jobs.pendingApprovals
            _ = model.attentionJobID
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.recompute()
                self.layout(animated: true)
                self.observe()
            }
        }
    }

    /// Window frame big enough for the target shape (plus a margin for the flare and shadow).
    private func frame(for size: CGSize) -> CGRect {
        let g = model.geometry
        let w = size.width + 40
        let h = size.height + 20
        return CGRect(x: g.notchRect.midX - w / 2, y: g.screenFrame.maxY - h, width: w, height: h)
    }

    /// Frame the pending shrink will apply; relayouts toward the same frame leave it scheduled.
    private var shrinkTarget: CGRect?

    func layout(animated: Bool) {
        let target = frame(for: model.size)
        let current = panel.frame
        // Background jobs publish progress many times a minute. Those relayouts don't change
        // the size, so they must not cancel (and endlessly postpone) a pending shrink.
        if animated, current != .zero, target == current || target == shrinkTarget {
            updateKeyStatus()
            return
        }
        shrinkWork?.cancel()
        shrinkTarget = nil
        if !animated || current == .zero {
            panel.setFrame(target, display: true)
        } else if target.width >= current.width && target.height >= current.height {
            panel.setFrame(target, display: true)
        } else {
            // Grow-to-union now, shrink after the content's collapse animation finishes.
            panel.setFrame(current.union(target), display: true)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.shrinkTarget = nil
                self.panel.setFrame(self.frame(for: self.model.size), display: true)
            }
            shrinkTarget = target
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
        }
        updateKeyStatus()
        if let t = model.openRequestedAt, model.presentation == .input {
            model.openRequestedAt = nil
            panel.displayIfNeeded()
            let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
            Logger(subsystem: "dev.glide", category: "perf").notice("notch opened in \(ms, format: .fixed(precision: 1))ms")
            // Opt-in timing file for benchmarks: defaults write dev.notchbuddy.app NBPerfLog -bool YES
            if UserDefaults.standard.bool(forKey: "NBPerfLog") {
                let line = String(format: "notch_open_ms %.1f\n", ms)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("glide-perf.log")
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? line.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
    }

    private var wantedKey = false

    /// Takes keyboard focus only on the transition into a typing state, never on unrelated
    /// relayouts, and hands it back to the user's app on the way out.
    private func updateKeyStatus() {
        let wants = model.wantsKey
        defer { wantedKey = wants }
        if wants && !wantedKey {
            if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current { previousApp = front }
            panel.allowsKey = true
            panel.makeKey()
        } else if !wants && panel.allowsKey {
            panel.allowsKey = false
            panel.resignKey()
            // Give keyboard focus back to the app the user (and the agent) was working in.
            if let prev = previousApp, !prev.isTerminated {
                prev.activate()
            }
            previousApp = nil
        }
    }
}
