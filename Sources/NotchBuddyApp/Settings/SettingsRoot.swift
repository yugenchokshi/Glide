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
        case .integrations: return "square.grid.2x2"
        case .permissions: return "lock.shield"
        case .safety: return "hand.raised"
        case .shortcuts: return "command"
        case .skills: return "wand.and.stars"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    /// Sidebar groups, as in BoardUI's settings modal.
    static let groups: [(String, [SettingsSection])] = [
        ("Settings", [.general, .providers, .models, .integrations]),
        ("Agent", [.permissions, .safety, .shortcuts, .skills]),
        ("Data", [.history, .about]),
    ]
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
        SettingsPageFrame(nav: nav) { page }
            .frame(minWidth: 820, minHeight: 560)
    }

    @ViewBuilder var page: some View {
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
}

/// Sidebar plus a scrolling page, as in BoardUI's settings modal.
struct SettingsPageFrame<Page: View>: View {
    @Bindable var nav: SettingsNavigation
    @ViewBuilder var page: Page
    var body: some View {
        BKThemeReader { t in
            HStack(spacing: 0) {
                SettingsSidebar(nav: nav)
                    .frame(width: 216)
                    .background(t.muted)
                    .overlay(alignment: .trailing) { Rectangle().fill(t.border).frame(width: 1) }
                ScrollView {
                    VStack(alignment: .leading, spacing: BK.Space.md) { page }
                        .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 32)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
                .background(t.canvas)
                .id(nav.selection)
            }
            .ignoresSafeArea()
        }
    }
}

struct SettingsSidebar: View {
    @Bindable var nav: SettingsNavigation

    var body: some View {
        BKThemeReader { t in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    BKAgentOrb(mode: .idle, size: 18)
                    Text("NotchBuddy").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(t.text)
                }
                .padding(.horizontal, 10)
                .padding(.top, 46).padding(.bottom, 14)
                ForEach(SettingsSection.groups, id: \.0) { title, sections in
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(t.secondary)
                        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                    ForEach(sections) { s in
                        SidebarItem(section: s, selected: nav.selection == s) { nav.selection = s }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
        }
    }
}

private struct SidebarItem: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        BKThemeReader { t in
            Button(action: action) {
                HStack(spacing: 9) {
                    Image(systemName: section.icon).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(selected ? t.text : t.secondary).frame(width: 18)
                    Text(section.title).font(.system(size: 13, weight: selected ? .medium : .regular)).foregroundStyle(t.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: BK.Radius.lg, style: .continuous).fill(t.raised).bkFloatShadow(t)
                    } else if hovering {
                        RoundedRectangle(cornerRadius: BK.Radius.lg, style: .continuous).fill(t.mutedHover.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .padding(.vertical, 1)
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        BKSectionHeader(title: "General", subtitle: "How NotchBuddy looks and moves while it works.")
        BKGroupHeader(title: "Appearance")
        BKGroup {
            BKFormRow(title: "Cursor movement", detail: "Fast jumps straight to targets. Visual animates the cursor so you can follow along.") {
                BKSegmented(options: [(CursorMode.fast, "Fast"), (.visual, "Visual")], selection: $store.settings.cursorMode)
            }
            BKFormRow(title: "Hide result after", detail: "Successful results collapse back into the notch after this many seconds.") {
                BKStepper(value: $store.settings.completedDismissSeconds, range: 2...30) { "\(Int($0)) s" }
            }
            BKFormRow(title: "Voice input", detail: "Show a microphone button for on-device dictation.") {
                BKSwitch(isOn: $store.settings.enableVoiceInput, label: "Voice input")
            }
        }
        BKGroupHeader(title: "System")
        BKGroup {
            BKFormRow(title: "Open at login", detail: loginError ?? "Start NotchBuddy when you log in to your Mac.") {
                BKSwitch(isOn: $launchAtLogin, label: "Open at login")
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
        BKGroup {
            BKFormRow(title: "Version") { Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev").font(BK.Font.body).foregroundStyle(.secondary) }
            BKFormRow(title: "License") { BKBadge(text: "MIT") }
            BKFormRow(title: "Your data", detail: "Task history is stored locally in SQLite. API keys live in the macOS Keychain. Nothing is sent anywhere except the AI providers and integrations you configure.") {
                Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: LocalStore.shared.path)]) }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
        }
        BKGroupHeader(title: "Design")
        BKGroup {
            Text("The interface follows the visual language of BoardUI (boardui.com), re-created natively in SwiftUI. No BoardUI source code or assets are included.")
                .font(BK.Font.small).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
