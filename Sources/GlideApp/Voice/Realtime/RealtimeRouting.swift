import Foundation
import Observation
import AgentKit

/// Which voice runs a conversation.
enum ConversationEngine: String, CaseIterable, Sendable {
    /// OpenAI Realtime: speech in, speech out, Glide as tools. Near real time.
    case realtime
    /// On-device recognition → Glide's planner → text-to-speech.
    case onDevice
}

/// Settings › Voice › Conversation engine and realtime model. Kept by the app (UserDefaults),
/// not in Glide's shared settings file.
@MainActor
@Observable
final class RealtimePreferences {
    static let shared = RealtimePreferences()

    @ObservationIgnored private let defaults: UserDefaults
    static let engineKey = "glide.voice.conversationEngine"
    static let modelKey = "glide.voice.realtimeModel"

    /// Nil: Realtime when an OpenAI key exists, else on-device.
    var engine: ConversationEngine? {
        didSet { defaults.set(engine?.rawValue, forKey: Self.engineKey) }
    }
    var model: String {
        didSet { defaults.set(model, forKey: Self.modelKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        engine = defaults.string(forKey: Self.engineKey).flatMap(ConversationEngine.init(rawValue:))
        let m = defaults.string(forKey: Self.modelKey) ?? ""
        model = m.isEmpty ? RealtimeProtocol.defaultModel : m
    }

    func effectiveEngine(hasKey: Bool) -> ConversationEngine { engine ?? (hasKey ? .realtime : .onDevice) }
}

/// Picks the engine for a new conversation, falling back to on-device when Realtime can't run.
enum RealtimeRouting {
    enum Choice: Equatable {
        case realtime
        /// `notice`: a short line for the notch saying why Realtime isn't used.
        case onDevice(notice: String?)
    }

    /// After a failed connection, Realtime isn't tried again for this long.
    static let failureBackoff: TimeInterval = 60

    static func choose(preference: ConversationEngine?, hasKey: Bool, lastFailure: Date?, now: Date = Date()) -> Choice {
        let engine = preference ?? (hasKey ? .realtime : .onDevice)
        guard engine == .realtime else { return .onDevice(notice: nil) }
        guard hasKey else { return .onDevice(notice: "Add an OpenAI key for real-time voice. Using on-device voice.") }
        if let lastFailure, now.timeIntervalSince(lastFailure) < failureBackoff {
            return .onDevice(notice: nil)
        }
        return .realtime
    }

    static let fallbackNotice = "Real-time voice isn't reachable. Using on-device voice."
}

/// Builds live realtime conversations from the user's OpenAI provider.
@MainActor
final class RealtimeLauncher {
    let settings: SettingsStore
    let preferences: RealtimePreferences
    let glide: any GlideControlling
    var key: (String) -> String? = { CredentialStore.shared.get(.provider($0)) }
    var lastFailure: Date?

    init(settings: SettingsStore, preferences: RealtimePreferences = .shared, glide: any GlideControlling) {
        self.settings = settings
        self.preferences = preferences
        self.glide = glide
    }

    private var route: (baseURL: String, apiKey: String)? { OpenAISpeech.route(settings.settings, key: key) }

    /// A conversation to start, or why the on-device voice is used instead.
    func make() -> (RealtimeConversation?, notice: String?) {
        let route = self.route
        switch RealtimeRouting.choose(preference: preferences.engine, hasKey: route != nil, lastFailure: lastFailure) {
        case .onDevice(let notice):
            return (nil, notice)
        case .realtime:
            guard let route, let request = RealtimeProtocol.socketRequest(baseURL: route.baseURL, apiKey: route.apiKey, model: preferences.model) else {
                return (nil, RealtimeRouting.fallbackNotice)
            }
            var config = RealtimeSessionConfig()
            config.voice = RealtimeProtocol.voice(for: settings.settings.voice.openAIVoice)
            config.speed = min(1.5, max(0.25, settings.settings.voice.speakingRate))
            let conversation = RealtimeConversation(transport: WebSocketTransport(request: request), audio: RealtimeAudioEngine(),
                                                    glide: glide, config: config)
            return (conversation, nil)
        }
    }

    func noteFailure() { lastFailure = Date() }

    /// A new conversation would use Realtime.
    var wouldUseRealtime: Bool {
        RealtimeRouting.choose(preference: preferences.engine, hasKey: route != nil, lastFailure: lastFailure) == .realtime
    }
}
