import SwiftUI
import Combine
import AVFoundation
import Speech
import AgentKit
import AutomationKit

/// Microphone and speech-recognition access, read only: Glide shows the status and opens the
/// right System Settings pane, and never changes anything itself.
enum VoicePermissions {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, speechRecognition
        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech Recognition"
            }
        }

        var detail: String {
            switch self {
            case .microphone: return "Needed to hear you. On only while Glide is listening."
            case .speechRecognition: return "Used by the older recognizer while the newer one installs. Everything stays on this Mac."
            }
        }

        var settingsURL: URL {
            let anchor = self == .microphone ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
        }
    }

    static func status(_ kind: Kind) -> PermissionStatus {
        switch kind {
        case .microphone: return PermissionManager.status(.microphone)
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .unknown
            }
        }
    }

    static var micAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
}

/// Settings › Voice: listening, what Glide says out loud and in which voice, and permissions.
struct VoiceSettingsView: View {
    @Bindable var store: SettingsStore
    /// "Hear it": says a sample line with the settings on screen.
    var preview: (String, VoiceSettings) -> Void = { text, voice in GlideSpeaker.shared.preview(text, voice: voice) }
    /// Snapshot hooks: fixed permissions, voices and key presence.
    var previewPermissions: [VoicePermissions.Kind: PermissionStatus]?
    var previewVoices: [AppleVoiceOption]?
    var previewHasOpenAIKey: Bool?
    var onOpenProviders: () -> Void = {}
    @Bindable var realtime: RealtimePreferences = .shared

    @State private var statuses: [VoicePermissions.Kind: PermissionStatus] = [:]
    @State private var voices: [AppleVoiceOption] = []
    @State private var hasOpenAIKey = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    static let sampleLine = "Hi! I'm Glide. Tell me what you need, and I'll take care of it."

    var body: some View {
        let voice = $store.settings.voice
        BKSectionHeader(title: "Voice",
                        subtitle: "Press \(store.settings.hotkeys.open.display) and just talk. Glide answers out loud, asks when something's unclear, and keeps working while it waits for you.")

        BKGroupHeader(title: "Conversation", subtitle: "Your voice is sent to OpenAI while you talk.")
        BKGroup {
            BKFormRow(title: "Conversation engine", detail: conversationDetail) {
                BKSegmented(options: [(ConversationEngine.realtime, "Realtime"), (.onDevice, "On-device")], selection: engineBinding)
            }
            if realtime.effectiveEngine(hasKey: hasKey) == .realtime {
                BKFormRow(title: "Realtime model", detail: "Mini answers fastest. Glide falls back to the on-device voice when OpenAI can't be reached.") {
                    BKMenu(options: [("gpt-realtime-2.1-mini", "GPT Realtime 2.1 mini"), ("gpt-realtime-2.1", "GPT Realtime 2.1")],
                           selection: $realtime.model, minWidth: 190)
                }
                .disabled(!hasKey)
            }
        }
        if realtime.effectiveEngine(hasKey: hasKey) == .realtime && !hasKey {
            BKCallout(tone: .info, icon: "key.fill", title: "Add an OpenAI key for Realtime",
                      message: "Until then Glide uses the on-device voice.") {
                Button("AI Providers", action: onOpenProviders)
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
        }

        BKGroupHeader(title: "Listening")
        BKGroup {
            BKFormRow(title: "Listen when the notch opens",
                      detail: "Opening Glide starts listening right away. Start typing any time to switch to the keyboard.") {
                BKSwitch(isOn: voice.listenOnOpen, label: "Listen when the notch opens")
            }
            BKFormRow(title: "Listen for an answer",
                      detail: "After Glide asks something, it listens this long for your reply, no tap needed.") {
                BKStepper(value: voice.listenForAnswerSeconds, range: 0...20) { $0 == 0 ? "Off" : "\(Int($0)) s" }
            }
        }

        BKGroupHeader(title: "Speaking", subtitle: "Everything Glide says also shows in the notch.")
        BKGroup {
            BKFormRow(title: "What Glide says out loud", detail: store.settings.voice.speakMode.detail) {
                BKMenu(options: SpeakMode.allCases.map { ($0, $0.title) }, selection: voice.speakMode, minWidth: 170)
            }
            BKFormRow(title: "Voice", detail: engineDetail) {
                BKSegmented(options: [(VoiceEngine.openAI, "Natural"), (.apple, "Apple")], selection: voice.engine)
            }
            if store.settings.voice.engine == .openAI {
                BKFormRow(title: "Natural voice", detail: "OpenAI's voices, with your OpenAI key.") {
                    HStack(spacing: 8) {
                        BKMenu(options: openAIVoiceOptions, selection: voice.openAIVoice, minWidth: 130)
                        hearIt(engine: .openAI)
                    }
                }
                .disabled(!hasKey)
            }
            BKFormRow(title: store.settings.voice.engine == .openAI ? "Offline voice" : "Apple voice",
                      detail: "Apple's on-device voice\(store.settings.voice.engine == .openAI ? ", used offline or when the natural voice isn't available" : ""). Premium and Enhanced voices sound best; add them in System Settings › Accessibility › Spoken Content.") {
                HStack(spacing: 8) {
                    BKMenu(options: appleVoiceOptions, selection: appleVoiceBinding, minWidth: 170)
                    hearIt(engine: .apple)
                }
            }
            BKFormRow(title: "Speaking rate") {
                BKStepper(value: voice.speakingRate, range: 0.8...1.4, step: 0.1) { String(format: "%.1f×", $0) }
            }
        }
        if store.settings.voice.engine == .openAI && !hasKey {
            BKCallout(tone: .info, icon: "key.fill", title: "Add an OpenAI key for the natural voice",
                      message: "Until then Glide speaks with Apple's voice.") {
                Button("AI Providers", action: onOpenProviders)
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
        }

        BKGroupHeader(title: "Privacy", subtitle: realtime.effectiveEngine(hasKey: hasKey) == .realtime && hasKey
            ? "With Realtime, your voice is streamed to OpenAI while a conversation is open, and only then. The microphone is on only while Glide is listening, with a red dot in the notch. Glide never stores audio."
            : "Speech recognition runs on this Mac. The microphone is on only while Glide is listening, with a red dot in the notch. Audio is never stored — only the words you said become the task.")
        BKGroup {
            ForEach(VoicePermissions.Kind.allCases) { kind in
                let status = (previewPermissions ?? statuses)[kind] ?? .unknown
                BKFormRow(title: kind.title, detail: kind.detail) {
                    HStack(spacing: 8) {
                        switch status {
                        case .granted: BKBadge(text: "Allowed", tone: .success, icon: "checkmark")
                        case .denied: BKBadge(text: "Off", tone: .warning)
                        case .notDetermined, .unknown: BKBadge(text: "Asked on first use", tone: .neutral)
                        }
                        Button("Open Settings") { NSWorkspace.shared.open(kind.settingsURL) }
                            .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
                            .fixedSize()
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in if previewPermissions == nil { refreshPermissions() } }
    }

    private var hasKey: Bool { previewHasOpenAIKey ?? hasOpenAIKey }

    private var engineBinding: Binding<ConversationEngine> {
        Binding(get: { realtime.effectiveEngine(hasKey: hasKey) }, set: { realtime.engine = $0 })
    }

    private var conversationDetail: String {
        realtime.effectiveEngine(hasKey: hasKey) == .realtime
            ? "Talk back and forth in real time and interrupt any time. \(store.settings.hotkeys.open.display) starts a conversation; it ends after 20 s of quiet, or press \(store.settings.hotkeys.open.display) or esc."
            : "Speech recognition on this Mac, then Glide's planner and voice. Slower, and nothing leaves the Mac until you send a request."
    }

    private var engineDetail: String {
        store.settings.voice.engine == .openAI
            ? "Natural sounds like a person, using your OpenAI key. Glide switches to Apple's voice when offline."
            : "Apple's on-device voice. Works offline and costs nothing."
    }

    private var openAIVoiceOptions: [(String, String)] {
        [("", "Automatic")] + OpenAISpeech.voices.map { ($0, $0.capitalized) }
    }

    private var appleVoiceOptions: [(String, String)] {
        let best = AppleVoices.best(for: AppleVoices.userLanguage, among: previewVoices ?? voices)
        let auto = best.map { "Automatic (\($0.name))" } ?? "Automatic"
        return [("", auto)] + AppleVoices.options(for: AppleVoices.userLanguage, among: previewVoices ?? voices).map { ($0.id, $0.label) }
    }

    private var appleVoiceBinding: Binding<String> {
        Binding(get: { store.settings.voice.appleVoiceID ?? "" },
                set: { store.settings.voice.appleVoiceID = $0.isEmpty ? nil : $0 })
    }

    private func hearIt(engine: VoiceEngine) -> some View {
        Button {
            var v = store.settings.voice
            v.engine = engine
            preview(Self.sampleLine, v)
        } label: {
            Label("Hear it", systemImage: "play.fill").labelStyle(.titleAndIcon)
        }
        .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
        .fixedSize()
    }

    private func refresh() {
        refreshPermissions()
        if previewVoices == nil { voices = AppleVoices.installed() }
        if previewHasOpenAIKey == nil {
            hasOpenAIKey = OpenAISpeech.route(store.settings, key: { CredentialStore.shared.get(.provider($0)) }) != nil
        }
    }

    private func refreshPermissions() {
        guard previewPermissions == nil else { return }
        for k in VoicePermissions.Kind.allCases { statuses[k] = VoicePermissions.status(k) }
    }
}
