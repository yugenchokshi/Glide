import SwiftUI
import AgentKit
import AutomationKit

/// First-run walkthrough: welcome → what it can do → permissions → provider + key → test →
/// model → a safe first task. Composio is not part of onboarding.
struct OnboardingView: View {
    @Bindable var store: SettingsStore
    var onFinish: (_ introTask: String?) -> Void
    @State private var step = 0
    @State private var providerID = "anthropic"
    @State private var key = ""
    @State private var testState: (ok: Bool, message: String)?
    @State private var testing = false
    @State private var axGranted = AccessibilityEngine.isTrusted
    @State private var screenGranted = ScreenCapture.hasPermission
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    static let introTask = "Open TextEdit, create a new document, and type “Hello from NotchBuddy!”"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<6) { i in
                    Capsule().fill(i <= step ? AnyShapeStyle(BK.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.2))).frame(height: 4)
                }
            }
            .padding(.horizontal, 28).padding(.top, 22)
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
            .padding(.horizontal, 28).padding(.bottom, 22)
        }
        .frame(width: 640, height: 520)
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
            Text("Meet NotchBuddy").font(.system(size: 28, weight: .bold))
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
            Text("How it works").font(.system(size: 22, weight: .semibold))
            feature("accessibility", "Reads apps the structured way", "It uses macOS accessibility data to find buttons and fields — fast, precise, and without screenshots.")
            feature("cursorarrow.click.2", "Drives the real cursor and keyboard", "Every click and keystroke happens on your Mac, in front of you.")
            feature("eye", "Looks only when it has to", "Screens are captured only for controls that accessibility can't see, after you allow it, with password fields blacked out.")
            feature("hand.raised", "You stay in control", "Sending, deleting, publishing and purchases wait for your approval. Stop anytime with \(store.settings.hotkeys.stop.display) or by moving the mouse.")
            feature("key", "Your keys, your Mac", "Bring your own OpenAI or Anthropic key. It stays in your Keychain. No account, no NotchBuddy server.")
        }
    }

    func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(BK.Tone.accent.color).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.system(size: 22, weight: .semibold))
            Text("macOS will show you where to switch these on. NotchBuddy asks only for what it uses.").font(.system(size: 13)).foregroundStyle(.secondary)
            BKCard {
                PermissionRow(kind: .accessibility, status: axGranted ? .granted : .denied) { Task { _ = await PermissionManager.request(.accessibility) } }
                Divider()
                PermissionRow(kind: .screenRecording, status: screenGranted ? .granted : .notDetermined) { Task { _ = await PermissionManager.request(.screenRecording) } }
            }
            Text("Automation and Microphone are requested later, only if you use browser reading or voice input.").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    var provider: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect an AI provider").font(.system(size: 22, weight: .semibold))
            Picker("", selection: $providerID) {
                Text("Anthropic").tag("anthropic")
                Text("OpenAI").tag("openai")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
            BKSecretField(placeholder: providerID == "anthropic" ? "Anthropic API key (sk-ant-…)" : "OpenAI API key (sk-…)", text: $key)
            HStack {
                Button { Task { await saveAndTest() } } label: {
                    HStack { if testing { ProgressView().controlSize(.small) }; Text("Save & test connection") }
                }
                .buttonStyle(BKButtonStyle(kind: .secondary)).disabled(key.isEmpty || testing)
                if CredentialStore.shared.has(.provider(providerID)) && key.isEmpty {
                    Button("Test saved key") { Task { await saveAndTest() } }.buttonStyle(BKButtonStyle(kind: .ghost))
                }
            }
            if let t = testState {
                Label(t.message, systemImage: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(t.ok ? BK.Tone.success.color : BK.Tone.danger.color).font(.system(size: 12.5))
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
            Text("Default models").font(.system(size: 22, weight: .semibold))
            Text("Automatic routing uses a capable model to plan and a small, fast one to pick each action. You can change any of these later in Settings › Models.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            BKCard {
                ForEach(ModelRole.allCases) { role in
                    HStack {
                        Text(role.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text((try? ModelRouter(settings: store.settings).route(role)).map { "\($0.provider.config.name) · \($0.model)" } ?? "—")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            BKFormRow(title: "Cursor movement", detail: "Visual is easier to follow at first; Fast is quicker.") {
                Picker("", selection: $store.settings.cursorMode) {
                    Text("Fast").tag(CursorMode.fast)
                    Text("Visual").tag(CursorMode.visual)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
        }
    }

    var firstTask: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try a safe first task").font(.system(size: 22, weight: .semibold))
            Text("This opens TextEdit and types one line into a new, unsaved document. Keep your hands off the mouse and watch the notch.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            BKCard { Text(Self.introTask).font(.system(size: 13.5, weight: .medium)) }
            Button {
                store.settings.onboardingComplete = true
                onFinish(Self.introTask)
            } label: { Label("Run it now", systemImage: "play.fill") }
                .buttonStyle(BKButtonStyle(kind: .primary))
            Text("Afterwards, press \(store.settings.hotkeys.open.display) anytime to give NotchBuddy a task.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
