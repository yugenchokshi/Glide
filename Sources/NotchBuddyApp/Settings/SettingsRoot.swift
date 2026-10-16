import SwiftUI
import AppKit
import AgentKit
import AutomationKit
import ServiceManagement

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, providers, models, integrations, permissions, safety, shortcuts, skills, history, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .providers: return "AI Providers"
        case .models: return "Models"
        case .integrations: return "Integrations"
        case .permissions: return "Permissions"
        case .safety: return "Safety"
        case .shortcuts: return "Shortcuts"
        case .skills: return "Skills"
        case .history: return "History"
        case .about: return "About"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "key"
        case .models: return "cpu"
        case .integrations: return "puzzlepiece.extension"
        case .permissions: return "lock.shield"
        case .safety: return "hand.raised"
        case .shortcuts: return "keyboard"
        case .skills: return "wand.and.stars"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var selection: SettingsSection = .general
}

struct SettingsRootView: View {
    @Bindable var nav: SettingsNavigation
    let store: SettingsStore
    var onHotkeysChanged: () -> Void
    var hotkeyConflicts: () -> [HotkeyManager.Action: String]

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $nav.selection) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: BK.Space.lg) {
                    switch nav.selection {
                    case .general: GeneralSettingsView(store: store)
                    case .providers: ProvidersSettingsView(store: store)
                    case .models: ModelsSettingsView(store: store)
                    case .integrations: IntegrationsSettingsView(store: store)
                    case .permissions: PermissionsSettingsView()
                    case .safety: SafetySettingsView(store: store)
                    case .shortcuts: ShortcutsSettingsView(store: store, onChange: onHotkeysChanged, conflicts: hotkeyConflicts)
                    case .skills: SkillsSettingsView()
                    case .history: HistorySettingsView(store: store)
                    case .about: AboutView()
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        BKSectionHeader(title: "General", subtitle: "How NotchBuddy looks and moves while it works.")
        BKCard {
            BKFormRow(title: "Cursor movement", detail: "Fast jumps straight to targets. Visual animates the cursor so you can follow along.") {
                Picker("", selection: $store.settings.cursorMode) {
                    Text("Fast").tag(CursorMode.fast)
                    Text("Visual").tag(CursorMode.visual)
                }
                .pickerStyle(.segmented).frame(width: 160).labelsHidden()
            }
            Divider()
            BKFormRow(title: "Hide result after", detail: "Successful results collapse back into the notch after this many seconds.") {
                Stepper("\(Int(store.settings.completedDismissSeconds))s", value: $store.settings.completedDismissSeconds, in: 2...30, step: 1)
            }
            Divider()
            BKFormRow(title: "Voice input", detail: "Show a microphone button for on-device dictation.") {
                Toggle("", isOn: $store.settings.enableVoiceInput).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            BKFormRow(title: "Open at login", detail: loginError) {
                Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        BKCard {
            BKFormRow(title: "Setup assistant", detail: "Run the first-launch walkthrough again.") {
                Button("Show") { NotificationCenter.default.post(name: .nbShowOnboarding, object: nil) }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
        }
    }
}

extension Notification.Name {
    static let nbShowOnboarding = Notification.Name("dev.notchbuddy.showOnboarding")
    static let nbSettingsChanged = Notification.Name("dev.notchbuddy.settingsChanged")
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        BKSectionHeader(title: "About NotchBuddy", subtitle: "An open-source macOS computer-use agent that lives in the notch.")
        BKCard {
            BKFormRow(title: "Version") { Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev").foregroundStyle(.secondary) }
            Divider()
            BKFormRow(title: "License") { Text("MIT").foregroundStyle(.secondary) }
            Divider()
            BKFormRow(title: "Your data", detail: "Task history is stored locally in SQLite. API keys live in the macOS Keychain. Nothing is sent anywhere except the AI providers and integrations you configure.") {
                Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: LocalStore.shared.path)]) }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
        }
        BKCard {
            Text("Design").font(.system(size: 13, weight: .semibold))
            Text("The interface follows the visual language of BoardUI (boardui.com), re-created natively in SwiftUI. No BoardUI source code or assets are included.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
