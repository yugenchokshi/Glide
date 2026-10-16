import AppKit
import SwiftUI
import AgentKit

/// `NotchBuddy --snapshot <dir>` renders every notch state to PNG (for docs and visual
/// regression checks) without running any automation.
@MainActor
enum SnapshotRenderer {
    /// True while rendering snapshots: views skip loading the user's local history.
    static var isRendering = false

    static func run(into dir: String) {
        isRendering = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Render as a configured install without touching the Keychain.
        CredentialStore.shared.useMemoryOnly([.provider("anthropic"): "sk-ant-demo-000000000000a1B2"])
        let suite = "dev.notchbuddy.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        let controller = TaskController(runtime: AutomationRuntime(), settingsStore: store)
        let model = NotchModel(controller: controller, settings: store)
        model.geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true,
                                       notchRect: CGRect(x: 666, y: 950, width: 180, height: 32))
        let plan = Plan(goal: "Summarize Apple earnings into Notes", steps: [
            PlanStep(id: 1, title: "Opening Safari", instruction: "", route: .native, app: "Safari", risk: .low, doneWhen: "", hint: nil),
            PlanStep(id: 2, title: "Reading the results", instruction: "", route: .gui, app: "Safari", risk: .low, doneWhen: "", hint: nil),
            PlanStep(id: 3, title: "Creating a note", instruction: "", route: .gui, app: "Notes", risk: .low, doneWhen: "", hint: nil),
            PlanStep(id: 4, title: "Writing the summary", instruction: "", route: .gui, app: "Notes", risk: .medium, doneWhen: "", hint: nil),
        ], clarification: nil)
        let instruction = "Open Safari, search for the latest Apple earnings, summarize the results, and save the summary in Notes."
        let activity: [ActivityEntry] = [
            ActivityEntry(kind: .plan, title: "Planned 4 steps"),
            ActivityEntry(kind: .step, title: "Opening Safari", route: .native),
            ActivityEntry(kind: .action, title: "Opening https://www.google.com/search?q=apple+earnings", detail: "open-url · window updated", route: .native, success: true, durationMs: 412),
            ActivityEntry(kind: .step, title: "Reading the results", route: .gui),
            ActivityEntry(kind: .info, title: "Noted information", detail: "Q4 revenue $102.5B (+8% YoY); iPhone $49.0B; Services record $28.8B."),
            ActivityEntry(kind: .step, title: "Creating a note", route: .gui),
            ActivityEntry(kind: .action, title: "Pressing ⇧⌘N… Clicking “New Note”", detail: "mouse · window updated", route: .gui, success: true, durationMs: 96),
        ]
        func shot(_ name: String, _ setup: () -> Void) {
            setup()
            model.recompute()
            let size = model.size
            let view = NotchRootView(model: model)
                .frame(width: size.width + 40, height: size.height + 20)
                .background(Color(white: 0.16))
            // A real hosting view (not ImageRenderer) so AppKit-backed controls like the text field render.
            SettingsSnapshotRenderer.render(view, size: CGSize(width: size.width + 40, height: size.height + 20), dark: true, to: "\(dir)/notch-\(name).png")
        }
        shot("idle") { controller.previewState(phase: .idle, status: ""); model.inputOpen = false }
        shot("input") { model.inputOpen = true; model.inputText = instruction }
        shot("planning") { model.inputOpen = false; controller.previewState(phase: .planning, status: "Understanding your task…", instruction: instruction) }
        shot("executing") { controller.previewState(phase: .executing, status: "Clicking “New Note”", instruction: instruction, plan: plan, stepIndex: 2, activity: activity) }
        shot("detail") { model.detailOpen = true }
        shot("approval") {
            model.detailOpen = false
            controller.previewState(phase: .awaitingApproval, status: "Needs your approval", instruction: "Email the summary to my team", plan: plan, stepIndex: 3,
                                    approval: ApprovalRequest(kind: .action, title: "Clicking “Send”", detail: "Send the drafted summary email to the team list.",
                                                              appName: "Mail", risk: .high, reasons: ["clicking “Send”"]))
        }
        shot("completed") {
            controller.previewState(phase: .completed, status: "Saved a note “Apple Q4 earnings” with a 5-point summary.", instruction: instruction, plan: plan, stepIndex: 4)
            model.resultVisible = true
        }
        shot("error") {
            controller.previewState(phase: .failed, status: "Couldn't find the “New Note” button after 2 replans. Notes may be showing a sign-in sheet.", instruction: instruction, plan: plan, stepIndex: 2)
            model.resultVisible = true
        }
    }
}

/// `NotchBuddy --snapshot-settings <dir>` renders the settings window and onboarding to PNG in
/// light and dark mode, using demo settings in memory: no Keychain access, no network, no
/// MCP servers launched, and the user's own settings are never read or written.
@MainActor
enum SettingsSnapshotRenderer {
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        CredentialStore.shared.useMemoryOnly([.provider("anthropic"): "sk-ant-demo-000000000000a1B2"])
        let suite = "dev.notchbuddy.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        store.settings.providers[0].lastTestOK = true
        store.settings.providers[0].models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        var fs = MCPPreset.catalog[0].config
        var gh = MCPPreset.catalog.first { $0.name == "GitHub" }!.config
        gh.secretHeaders = ["Authorization"]
        var broken = MCPServerConfig(name: "Linear", transport: .http)
        broken.url = "https://mcp.linear.app/mcp"
        fs.id = "fs"; gh.id = "gh"; broken.id = "linear"
        store.settings.mcpServers = [fs, gh, broken]
        let mcpStatus: [String: (Bool, Int, String?)] = ["fs": (true, 14, nil), "gh": (true, 41, nil), "linear": (false, 0, "401 Unauthorized: add a bearer token")]
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let nav = SettingsNavigation()
        func settings(_ section: SettingsSection, _ name: String, height: CGFloat = 640, dark: Bool = false, tab: IntegrationsSettingsView.Tab = .apps) {
            nav.selection = section
            let root = SettingsRootView(nav: nav, store: store, onHotkeysChanged: {}, hotkeyConflicts: { [:] })
            // Swap the integrations page for one with snapshot hooks.
            let view = Group {
                if section == .integrations {
                    SettingsPageFrame(nav: nav) { IntegrationsSettingsView(store: store, initialTab: tab, previewMCPStatus: mcpStatus) }
                } else {
                    root
                }
            }
            render(view, size: CGSize(width: 920, height: height), dark: dark, to: "\(dir)/settings-\(name)\(dark ? "-dark" : "").png")
        }
        settings(.general, "general")
        settings(.providers, "providers", height: 900)
        settings(.providers, "providers", height: 900, dark: true)
        settings(.models, "models")
        settings(.integrations, "integrations-apps", height: 1180)
        settings(.integrations, "integrations-apps", height: 1180, dark: true)
        settings(.integrations, "integrations-mcp", height: 1000, tab: .mcp)
        settings(.integrations, "integrations-mcp", height: 1000, dark: true, tab: .mcp)
        settings(.safety, "safety", height: 960)
        settings(.permissions, "permissions")
        for (step, dark) in [(0, false), (1, false), (1, true), (2, false), (3, false)] {
            render(OnboardingView(store: store, initialStep: step) { _ in }, size: CGSize(width: 640, height: 540), dark: dark,
                   to: "\(dir)/onboarding-\(step)\(dark ? "-dark" : "").png")
        }
        render(ComposioKeySheet(app: AppIntegration.catalog[0], onSave: { _ in }, onCancel: {}), size: CGSize(width: 460, height: 330), dark: false,
               to: "\(dir)/sheet-composio-key.png")
    }

    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, to path: String) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("wrote \((path as NSString).lastPathComponent)")
        }
        window.contentView = nil
    }
}
