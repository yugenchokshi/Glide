import AppKit
import SwiftUI
import AgentKit
import AutomationKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = SettingsStore.shared
    let controller = TaskController.shared
    lazy var notchModel = NotchModel(controller: controller, settings: store)
    var notch: NotchWindowController?
    var statusItem: StatusItemController?
    let hotkeys = HotkeyManager()
    let settingsNav = SettingsNavigation()
    var settingsWindow: NSWindow?
    var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()
        installAgentSubsystems()
        notchModel.openSettings = { [weak self] section in self?.showSettings(section) }
        notchModel.openJob = { [weak self] id in self?.showJob(id) }
        notch = NotchWindowController(model: notchModel)
        statusItem = StatusItemController(controller: controller, jobs: JobCenter.shared, onOpen: { [weak self] in self?.toggleNotch() },
                                          onSettings: { [weak self] in self?.showSettings(nil) },
                                          onHistory: { [weak self] in self?.showSettings("history") },
                                          onJobs: { [weak self] in self?.showSettings("jobs") })
        controller.onAttentionNeeded = { [weak self] in self?.notchModel.recompute() }
        controller.onFinished = { [weak self] result in self?.notchModel.taskFinished(result) }
        startJobs()

        hotkeys.handler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .open: self.toggleNotch()
            case .pauseResume: self.controller.togglePause()
            case .stop:
                // The emergency stop halts everything: the quick task and every background job.
                self.controller.stop()
                JobCenter.shared.haltAll()
            }
        }
        hotkeys.apply(store.settings.hotkeys)

        Task { await MCPManager.shared.sync(with: store.settings.mcpServers) }
        NotificationCenter.default.addObserver(forName: .nbShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboarding() }
        }
        if !store.settings.onboardingComplete || !AccessibilityEngine.isTrusted {
            showOnboarding()
        }
        // `--settings [section]` opens Settings at launch (e.g. `--settings integrations`).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--settings") {
            showSettings(args.indices.contains(i + 1) ? args[i + 1] : nil)
        }
    }

    /// Installs the agent's subsystems before any UI or job runs, so the first task already sees
    /// every tool: the tool families, the step router jobs execute with, Glide's own Chrome, and
    /// the Chrome extension bridge (which registers the pairing hooks Settings › Browser shows).
    private func installAgentSubsystems() {
        AgentSetup.installAll(settings: store.settings, startBrowserBridge: true)
        watchBridgePort()
    }

    /// Restarts the extension bridge when its port setting changes. (Observation fires on any
    /// settings change, so compare against the port the bridge was started with.)
    private func watchBridgePort() {
        let startedPort = store.settings.browser.bridgePort
        withObservationTracking {
            _ = store.settings.browser.bridgePort
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.store.settings.browser.bridgePort != startedPort {
                    ExtensionBridge.shared.start(settings: self.store.settings.browser)
                }
                self.watchBridgePort()
            }
        }
    }

    /// Background jobs: route their attention requests to the notch (and to a notification
    /// when the notch is collapsed), then load and resume them. Callbacks are set before
    /// `launch()` so jobs resumed at launch can already ask for approval.
    private func startJobs() {
        let jobs = JobCenter.shared
        jobs.onAttentionNeeded = { [weak self] id in
            guard let self, let job = JobCenter.shared.job(id) else { return }
            self.announce(job) { self.notchModel.jobNeedsAttention(id) }
        }
        jobs.onJobFinished = { [weak self] job in
            guard let self else { return }
            self.announce(job) { self.notchModel.jobFinished(job) }
        }
        JobNotifier.shared.onOpenJob = { [weak self] id in self?.showJob(id) }
        JobNotifier.shared.install()
        jobs.launch()
    }

    /// Shows a job event in the notch, and also as a notification if the notch was collapsed
    /// when it happened (you're probably looking elsewhere), or if the notch is busy with
    /// something else and doesn't show this job (a running task, the task field, another
    /// job's card): its card then waits its turn, and the notification says it's there.
    private func announce(_ job: JobRecord, show: () -> Void) {
        guard notchModel.shouldAnnounce(job) else { return }
        let wasExpanded = notchModel.isExpanded
        show()
        if (!wasExpanded || !notchModel.isShowing(job: job.id)) && store.settings.jobs.notifications {
            JobNotifier.shared.notify(job, approval: JobCenter.shared.pendingApprovals[job.id])
        }
    }

    /// Menu-bar (accessory) apps get no default main menu, and without an Edit menu macOS has
    /// nowhere to route ⌘V/⌘C/⌘X/⌘A/⌘Z, so text fields can't paste. This menu is never shown
    /// (the app has no menu bar of its own) but supplies those key equivalents.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Glide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Glide", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggleNotch()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    func toggleNotch() {
        notchModel.toggle()
    }

    /// Opens Settings › Jobs on one job (notch "View report", notifications).
    func showJob(_ id: String) {
        showSettings(nil)
        settingsNav.showJob(id)
    }

    func showSettings(_ section: String?) {
        if let section, let s = SettingsSection(rawValue: section) { settingsNav.select(s) }
        if settingsWindow == nil {
            let view = SettingsRootView(nav: settingsNav, store: store,
                                        onHotkeysChanged: { [weak self] in
                                            guard let self else { return }
                                            self.hotkeys.apply(self.store.settings.hotkeys)
                                        },
                                        hotkeyConflicts: { [weak self] in self?.hotkeys.conflicts ?? [:] })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Glide Settings"
            // BoardUI-style chrome: no title bar strip; the traffic lights sit over the sidebar.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("GlideSettings")
            window.delegate = self
            settingsWindow = window
        }
        notchModel.close()
        NSApp.activate()
        if let w = settingsWindow, !w.isVisible { Self.centerOnMouseScreen(w) }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens windows on the display the user is looking at (where the pointer is), not
    /// whichever display macOS considers main.
    static func centerOnMouseScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }

    /// Closed windows are torn down so their SwiftUI views (and animations) stop costing CPU.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self] in
            window.contentView = nil
            if window === self?.settingsWindow { self?.settingsWindow = nil }
            if window === self?.onboardingWindow { self?.onboardingWindow = nil }
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(store: store) { [weak self] intro in
                guard let self else { return }
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                if let intro {
                    NSApp.hide(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.controller.start(intro) }
                }
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.title = "Welcome to Glide"
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            onboardingWindow = window
        }
        NSApp.activate()
        if let w = onboardingWindow, !w.isVisible { Self.centerOnMouseScreen(w) }
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Menu-bar fallback (always present): open, pause/stop, settings, history, quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let controller: TaskController
    let jobs: JobCenter
    let onOpen: () -> Void
    let onSettings: () -> Void
    let onHistory: () -> Void
    let onJobs: () -> Void

    init(controller: TaskController, jobs: JobCenter, onOpen: @escaping () -> Void, onSettings: @escaping () -> Void,
         onHistory: @escaping () -> Void, onJobs: @escaping () -> Void) {
        self.controller = controller
        self.jobs = jobs
        self.onOpen = onOpen
        self.onSettings = onSettings
        self.onHistory = onHistory
        self.onJobs = onJobs
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "Glide")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: controller.isRunning ? "Working: \(controller.status)" : "Glide is ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("Open Glide", #selector(open)))
        if controller.isRunning {
            menu.addItem(item(controller.phase == .paused ? "Resume" : "Pause", #selector(togglePause)))
            menu.addItem(item("Stop Task", #selector(stop)))
        }
        if let job = jobs.activeJob {
            let line = NSMenuItem(title: "Job: \(NotchApprovalView.short(job.title, max: 40)) — \(job.displayLine)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(.separator())
            menu.addItem(line)
        }
        menu.addItem(.separator())
        let unfinished = jobs.unfinishedJobs.count
        menu.addItem(item(unfinished > 0 ? "Background Jobs (\(unfinished))…" : "Background Jobs…", #selector(showJobs)))
        menu.addItem(item("Task History…", #selector(history)))
        menu.addItem(item("Settings…", #selector(settings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Glide", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc func open() { onOpen() }
    @objc func togglePause() { controller.togglePause() }
    @objc func stop() { controller.stop() }
    @objc func settings() { onSettings() }
    @objc func history() { onHistory() }
    @objc func showJobs() { onJobs() }
    @objc func quit() { controller.stop(); NSApp.terminate(nil) }
}
