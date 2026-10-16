import AppKit
import SwiftUI
import AgentKit
import AutomationKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        notchModel.openSettings = { [weak self] section in self?.showSettings(section) }
        notch = NotchWindowController(model: notchModel)
        statusItem = StatusItemController(controller: controller, onOpen: { [weak self] in self?.toggleNotch() },
                                          onSettings: { [weak self] in self?.showSettings(nil) },
                                          onHistory: { [weak self] in self?.showSettings("history") })
        controller.onAttentionNeeded = { [weak self] in self?.notchModel.recompute() }
        controller.onFinished = { [weak self] result in self?.notchModel.taskFinished(result) }

        hotkeys.handler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .open: self.toggleNotch()
            case .pauseResume: self.controller.togglePause()
            case .stop: self.controller.stop()
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

    func showSettings(_ section: String?) {
        if let section, let s = SettingsSection(rawValue: section) { settingsNav.selection = s }
        if settingsWindow == nil {
            let view = SettingsRootView(nav: settingsNav, store: store,
                                        onHotkeysChanged: { [weak self] in
                                            guard let self else { return }
                                            self.hotkeys.apply(self.store.settings.hotkeys)
                                        },
                                        hotkeyConflicts: { [weak self] in self?.hotkeys.conflicts ?? [:] })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "NotchBuddy Settings"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("NotchBuddySettings")
            settingsWindow = window
        }
        notchModel.close()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.title = "Welcome to NotchBuddy"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Menu-bar fallback (always present): open, pause/stop, settings, history, quit.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let controller: TaskController
    let onOpen: () -> Void
    let onSettings: () -> Void
    let onHistory: () -> Void

    init(controller: TaskController, onOpen: @escaping () -> Void, onSettings: @escaping () -> Void, onHistory: @escaping () -> Void) {
        self.controller = controller
        self.onOpen = onOpen
        self.onSettings = onSettings
        self.onHistory = onHistory
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "NotchBuddy")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: controller.isRunning ? "Working: \(controller.status)" : "NotchBuddy is ready", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("Open NotchBuddy", #selector(open)))
        if controller.isRunning {
            menu.addItem(item(controller.phase == .paused ? "Resume" : "Pause", #selector(togglePause)))
            menu.addItem(item("Stop Task", #selector(stop)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Task History…", #selector(history)))
        menu.addItem(item("Settings…", #selector(settings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit NotchBuddy", #selector(quit), key: "q"))
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
    @objc func quit() { controller.stop(); NSApp.terminate(nil) }
}
