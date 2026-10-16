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
}

enum NotchPresentation: Equatable {
    case idle, hover, input, running, detail, approval, result
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

    let controller: TaskController
    let settings: SettingsStore
    var openSettings: (String?) -> Void = { _ in }
    private var dismissWork: DispatchWorkItem?

    init(controller: TaskController, settings: SettingsStore) {
        self.controller = controller
        self.settings = settings
    }

    func recompute() {
        let c = controller
        let p: NotchPresentation
        if c.pendingApproval != nil {
            p = .approval
        } else if c.isRunning {
            p = detailOpen ? .detail : .running
        } else if inputOpen {
            p = historyOpen || detailOpen ? .detail : .input
        } else if resultVisible {
            p = detailOpen ? .detail : .result
        } else {
            p = hovering ? .hover : .idle
        }
        if p != presentation { presentation = p }
    }

    /// Size of the visible notch shape for the current presentation.
    var size: CGSize {
        let n = geometry.notchRect.size
        let top = n.height
        switch presentation {
        case .idle: return CGSize(width: n.width, height: top)
        case .hover: return CGSize(width: n.width + 24, height: top + 4)
        case .input: return CGSize(width: max(n.width + 240, 560), height: top + 148)
        case .running: return CGSize(width: max(n.width + 200, 500), height: top + 52)
        case .detail: return CGSize(width: max(n.width + 280, 600), height: top + 400)
        case .approval: return CGSize(width: max(n.width + 240, 560), height: top + 190)
        case .result: return CGSize(width: max(n.width + 240, 560), height: top + 116)
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
        focusToken += 1
        recompute()
    }

    func close() {
        inputOpen = false
        detailOpen = false
        historyOpen = false
        resultVisible = false
        recompute()
    }

    func toggle() {
        if inputOpen || detailOpen || resultVisible { close() } else { open() }
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
                if idle || AutomationRuntime.shared.gate.isPaused || self.model.controller.pendingApproval != nil {
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

    func layout(animated: Bool) {
        let target = frame(for: model.size)
        let current = panel.frame
        shrinkWork?.cancel()
        if !animated || current == .zero {
            panel.setFrame(target, display: true)
        } else if target.width >= current.width && target.height >= current.height {
            panel.setFrame(target, display: true)
        } else {
            // Grow-to-union now, shrink after the content's collapse animation finishes.
            panel.setFrame(current.union(target), display: true)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.panel.setFrame(self.frame(for: self.model.size), display: true)
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: work)
        }
        updateKeyStatus()
        if let t = model.openRequestedAt, model.presentation == .input {
            model.openRequestedAt = nil
            panel.displayIfNeeded()
            let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
            Logger(subsystem: "dev.notchbuddy", category: "perf").notice("notch opened in \(ms, format: .fixed(precision: 1))ms")
            // Opt-in timing file for benchmarks: defaults write dev.notchbuddy.app NBPerfLog -bool YES
            if UserDefaults.standard.bool(forKey: "NBPerfLog") {
                let line = String(format: "notch_open_ms %.1f\n", ms)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchbuddy-perf.log")
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
