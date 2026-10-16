import SwiftUI
import AgentKit
import AutomationKit

/// First-run walkthrough: welcome → what it can do → permissions → provider + key → test →
/// model → a safe first task. Composio is not part of onboarding.
struct OnboardingView: View {
    @Bindable var store: SettingsStore
    var onFinish: (_ introTask: String?) -> Void
    @State private var step: Int
    @State private var providerID = "anthropic"
    @State private var key = ""
    @State private var testState: (ok: Bool, message: String)?
    @State private var testing = false
    @State private var axGranted = AccessibilityEngine.isTrusted
    @State private var screenGranted = ScreenCapture.hasPermission
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(store: SettingsStore, initialStep: Int = 0, onFinish: @escaping (_ introTask: String?) -> Void) {
        self.store = store
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    static let introTask = "Open TextEdit, create a new document, and type “Hello from NotchBuddy!”"

    var body: some View {
        BKThemeReader { t in
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(0..<6) { i in
                        Capsule().fill(i <= step ? AnyShapeStyle(BK.accentGradient) : AnyShapeStyle(t.dark ? BK.Palette.n800 : BK.Palette.n200))
                            .frame(width: i == step ? 22 : 8, height: 6)
                    }
                }
                Spacer()
                Text("Step \(step + 1) of 6").font(BK.Font.caption).foregroundStyle(t.secondary)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
            .padding(.horizontal, 28).padding(.top, 38)
            Group {
                switch step {
                case 0: welcome
                case 1: capabilities
                case 2: permissions
                case 3: provider
                case 4: model
                default: firstTask
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            HStack {
                if step > 0 { Button("Back") { withAnimation { step -= 1 } }.buttonStyle(BKButtonStyle(kind: .ghost)) }
                Spacer()
                if step == 2 && !axGranted { Text("Accessibility is required to continue.").font(.system(size: 12)).foregroundStyle(.secondary) }
                Button(step == 5 ? "Done" : "Continue") { next() }
                    .buttonStyle(BKButtonStyle(kind: .primary))
                    .disabled(!canContinue)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            .background(t.muted)
            .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
        }
        .background(t.canvas)
        }
        .frame(width: 640, height: 540)
        .onReceive(timer) { _ in
            axGranted = AccessibilityEngine.isTrusted
            screenGranted = ScreenCapture.hasPermission
        }
    }

    var canContinue: Bool {
        switch step {
        case 2: return axGranted
        case 3: return testState?.ok == true
        default: return true
        }
    }

    func next() {
        if step == 5 {
            store.settings.onboardingComplete = true
            onFinish(nil)
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { step += 1 }
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            BKAgentOrb(mode: .thinking, size: 56)
                .shadow(color: Color(hex: 0x8B6BFF).opacity(0.35), radius: 16, y: 4)
            BKBadge(text: "Computer-use agent for macOS", tone: .info, icon: "sparkles")
            Text("Meet NotchBuddy").font(.system(size: 30, weight: .semibold))
            Text("Tell it what you want done. It plans the steps and operates your Mac for you — moving the real cursor, clicking, typing and switching apps — while you watch from the notch.")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                BKKeyCap(text: store.settings.hotkeys.open.display)
                Text("opens it from anywhere.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text("If another app (for example ChatGPT) already uses this shortcut, change it in Settings › Shortcuts. You can always click the notch or the menu-bar icon.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var capabilities: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How it works").font(BK.Font.title1)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                feature("accessibility", 0x2673FE, "Reads apps the structured way", "Uses macOS accessibility data to find buttons and fields, fast and without screenshots.")
                feature("cursorarrow.click.2", 0x8B5CF6, "Drives the real cursor", "Every click and keystroke happens on your Mac, in front of you.")
                feature("eye.fill", 0x0EA5E9, "Looks only when it has to", "Screenshots only for controls accessibility can't see, after you allow it, with passwords blacked out.")
                feature("hand.raised.fill", 0xF59E0B, "You stay in control", "Sending, deleting and purchases wait for approval. Stop with \(store.settings.hotkeys.stop.display) or by moving the mouse.")
            }
            BKCallout(tone: .success, icon: "key.fill", title: "Your keys, your Mac", message: "Bring your own OpenAI or Anthropic key. It stays in your Keychain. No account, no NotchBuddy server.")
        }
    }

    func feature(_ icon: String, _ color: UInt32, _ title: String, _ text: String) -> some View {
        BKCard(padding: 12) {
            HStack(alignment: .top, spacing: 10) {
                BKTile(title: title, color: Color(hex: color), symbol: icon, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(BK.Font.bodyMedium)
                    Text(text).font(BK.Font.caption).foregroundStyle(.secondary).lineLimit(3, reservesSpace: true)
                }
            }
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(BK.Font.title1)
            Text("macOS will show you where to switch these on. NotchBuddy asks only for what it uses.").font(.system(size: 13)).foregroundStyle(.secondary)
            BKGroup {
                PermissionRow(kind: .accessibility, status: axGranted ? .granted : .denied) { Task { _ = await PermissionManager.request(.accessibility) } }
                PermissionRow(kind: .screenRecording, status: screenGranted ? .granted : .notDetermined) { Task { _ = await PermissionManager.request(.screenRecording) } }
            }
            Text("Automation and Microphone are requested later, only if you use browser reading or voice input.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    var provider: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an AI provider").font(BK.Font.title1)
            BKSegmented(options: [("anthropic", "Anthropic"), ("openai", "OpenAI")], selection: $providerID)
            BKSecretField(placeholder: providerID == "anthropic" ? "Anthropic API key (sk-ant-…)" : "OpenAI API key (sk-…)", text: $key)
            HStack {
                Button { Task { await saveAndTest() } } label: {
                    HStack { if testing { ProgressView().controlSize(.mini) }; Text("Save & test connection") }
                }
                .buttonStyle(BKButtonStyle(kind: .primary)).disabled(key.isEmpty || testing)
                if CredentialStore.shared.has(.provider(providerID)) && key.isEmpty {
                    Button("Test saved key") { Task { await saveAndTest() } }.buttonStyle(BKButtonStyle(kind: .ghost))
                }
            }
            if let t = testState {
                BKCallout(tone: t.ok ? .success : .danger, icon: t.ok ? "checkmark" : "xmark", title: t.ok ? "Connected" : "Couldn't connect", message: t.message)
            }
            Text("Keys are stored in the macOS Keychain and sent only to \(providerID == "anthropic" ? "Anthropic" : "OpenAI"). You can add a custom OpenAI-compatible endpoint later in Settings.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func saveAndTest() async {
        testing = true
        defer { testing = false }
        if !key.isEmpty { CredentialStore.shared.set(key, for: .provider(providerID)) }
        key = ""
        guard let idx = store.settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        store.settings.providers[idx].enabled = true
        let config = store.settings.providers[idx]
        let client = ModelRouter(settings: store.settings).makeProvider(config)
        do {
            let models = try await client.listModels()
            if !models.isEmpty {
                store.settings.providers[idx].models = providerID == "anthropic"
                    ? Array(Set(models + ProviderConfig.anthropicDefault.models)).sorted()
                    : Array(Set(models + [ProviderConfig.openAIDefaultModel])).sorted()
            }
            store.settings.providers[idx].lastTestOK = true
            store.settings.routing.preferredProviderID = providerID
            var note = "Connected — \(models.count) models available."
            if providerID == "openai", !models.isEmpty, !models.contains(ProviderConfig.openAIDefaultModel) {
                note += " \(ProviderConfig.openAIDefaultModel) isn't listed for this key; you can choose another model in Settings › Models."
            }
            testState = (true, note)
        } catch {
            store.settings.providers[idx].lastTestOK = false
            testState = (false, error.localizedDescription)
        }
    }

    var model: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Default models").font(BK.Font.title1)
            Text("Automatic routing uses a capable model to plan and a small, fast one to pick each action. You can change any of these later in Settings › Models.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            BKGroup {
                ForEach(ModelRole.allCases) { role in
                    HStack {
                        Text(role.title).font(BK.Font.bodyMedium)
                        Spacer()
                        Text((try? ModelRouter(settings: store.settings).route(role)).map { "\($0.provider.config.name) · \($0.model)" } ?? "—")
                            .font(BK.Font.mono).foregroundStyle(.secondary)
                    }
                }
            }
            BKGroup {
                BKFormRow(title: "Cursor movement", detail: "Visual is easier to follow at first; Fast is quicker.") {
                    BKSegmented(options: [(CursorMode.fast, "Fast"), (.visual, "Visual")], selection: $store.settings.cursorMode)
                }
            }
        }
    }

    var firstTask: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try a safe first task").font(BK.Font.title1)
            Text("This opens TextEdit and types one line into a new, unsaved document. Keep your hands off the mouse and watch the notch.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            BKCard {
                HStack(spacing: 11) {
                    BKTile(title: "TextEdit", color: BK.Palette.n600, symbol: "doc.text.fill", size: 30)
                    Text(Self.introTask).font(BK.Font.bodyMedium).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                store.settings.onboardingComplete = true
                onFinish(Self.introTask)
            } label: { Label("Run it now", systemImage: "play.fill") }
                .buttonStyle(BKButtonStyle(kind: .primary))
            Text("Afterwards, press \(store.settings.hotkeys.open.display) anytime to give NotchBuddy a task.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
