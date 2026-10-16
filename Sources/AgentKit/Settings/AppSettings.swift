import Foundation
import Observation
import AutomationKit

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai
    case openaiCompatible

    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .openaiCompatible: return "OpenAI-compatible"
        }
    }
}

public struct ProviderConfig: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: ProviderKind
    public var name: String
    public var baseURL: String
    public var enabled: Bool
    public var requiresKey: Bool
    public var models: [String]
    public var lastTestOK: Bool?
    public var lastTestedAt: Date?
    public var lastError: String?

    public init(id: String, kind: ProviderKind, name: String, baseURL: String, enabled: Bool = true, requiresKey: Bool = true, models: [String] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.baseURL = baseURL
        self.enabled = enabled
        self.requiresKey = requiresKey
        self.models = models
    }

    public static let anthropicDefault = ProviderConfig(
        id: "anthropic", kind: .anthropic, name: "Anthropic", baseURL: "https://api.anthropic.com",
        models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"])
    public static let openAIDefault = ProviderConfig(
        id: "openai", kind: .openai, name: "OpenAI", baseURL: "https://api.openai.com/v1", models: [])
}

public struct ModelChoice: Codable, Sendable, Hashable {
    public var providerID: String
    public var model: String
    /// Reasoning effort hint ("low", "medium", "high") for providers that support it.
    public var effort: String?

    public init(providerID: String, model: String, effort: String? = nil) {
        self.providerID = providerID
        self.model = model
        self.effort = effort
    }
}

public enum ModelRole: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable, Identifiable {
    case planner, actor, vision, recovery
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .planner: return "Planning"
        case .actor: return "Fast action selection"
        case .vision: return "Vision grounding"
        case .recovery: return "Recovery / replanning"
        }
    }
    public var hint: String {
        switch self {
        case .planner: return "Breaks your request into steps. Use a capable model."
        case .actor: return "Picks the next control each step. Use a small, low-latency model."
        case .vision: return "Finds controls in screenshots when accessibility data is missing. Must accept images."
        case .recovery: return "Replans after failures. Defaults to the planning model."
        }
    }
}

public struct RoutingSettings: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable { case automatic, manual }
    public var mode: Mode = .automatic
    public var preferredProviderID: String?
    public var manual: [ModelRole: ModelChoice] = [:]
    /// Use TypeSafe Jev Choice questions to pick between ambiguous candidate elements.
    public var useJevForSelection = false
    public var jevModel = "jev-latest"
    public init() {}
}

public enum ApprovalLevel: String, Codable, Sendable, CaseIterable {
    case highRiskOnly, mediumAndHigh, everyAction
    public var title: String {
        switch self {
        case .highRiskOnly: return "High-risk actions (send, delete, purchase, publish)"
        case .mediumAndHigh: return "Medium and high-risk actions (also edits and file moves)"
        case .everyAction: return "Every action"
        }
    }
}

public enum ScreenshotConsent: String, Codable, Sendable, CaseIterable {
    case ask, always, never
    public var title: String {
        switch self {
        case .ask: return "Ask each task"
        case .always: return "Always allow"
        case .never: return "Never send screenshots"
        }
    }
}

public struct SafetySettings: Codable, Sendable, Hashable {
    public var approvalLevel: ApprovalLevel = .highRiskOnly
    public var excludedApps: [String] = ["1Password", "Keychain Access", "com.1password.1password", "Bitwarden"]
    public var screenshotConsent: ScreenshotConsent = .ask
    public var pauseOnUserInput = true
    public init() {}
}

public struct LimitSettings: Codable, Sendable, Hashable {
    public var maxSteps = 25
    public var maxActionsPerStep = 14
    public var maxTotalActions = 90
    public var taskTimeoutSeconds: Double = 900
    public var retryLimit = 3
    public var maxReplans = 2
    public init() {}
}

public struct HotkeySetting: Codable, Sendable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt8 // KeyCombination.Modifiers raw value
    public var display: String
    public var enabled = true

    public init(keyCode: UInt32, modifiers: KeyCombination.Modifiers, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
        self.display = display
    }

    public var modifierSet: KeyCombination.Modifiers { .init(rawValue: modifiers) }
}

public struct HotkeySettings: Codable, Sendable, Hashable {
    // ⌥Space opens; ⌥⇧Space pauses/resumes; ⌃⌥⌘. stops (works with the UI hidden).
    public var open = HotkeySetting(keyCode: 49, modifiers: [.option], display: "⌥Space")
    public var pauseResume = HotkeySetting(keyCode: 49, modifiers: [.option, .shift], display: "⌥⇧Space")
    public var stop = HotkeySetting(keyCode: 47, modifiers: [.control, .option, .command], display: "⌃⌥⌘.")
    public init() {}
}

public struct ComposioSettings: Codable, Sendable, Hashable {
    public var enabled = false
    public var baseURL = "https://backend.composio.dev/api/v3.1"
    /// Stable local user identifier sent to Composio (not personal data).
    public var userID = "notchbuddy-" + UUID().uuidString.prefix(8).lowercased()
    public var sessionID: String?
    public var callbackURL: String?
    public init() {}
}

public struct MCPServerConfig: Codable, Sendable, Hashable, Identifiable {
    public enum Transport: String, Codable, Sendable, CaseIterable { case stdio, http }
    public var id: String = UUID().uuidString
    public var name: String
    public var transport: Transport
    public var command: String = ""
    public var arguments: [String] = []
    public var environment: [String: String] = [:]
    public var url: String = ""
    /// Header names whose values are stored in the Keychain.
    public var secretHeaders: [String] = []
    public var enabled = true

    public init(name: String, transport: Transport) {
        self.name = name
        self.transport = transport
    }
}

public struct AppSettings: Codable, Sendable, Hashable {
    public var providers: [ProviderConfig] = [.anthropicDefault, .openAIDefault]
    public var routing = RoutingSettings()
    public var safety = SafetySettings()
    public var limits = LimitSettings()
    public var hotkeys = HotkeySettings()
    public var composio = ComposioSettings()
    public var mcpServers: [MCPServerConfig] = []
    public var cursorMode: CursorMode = .visual
    public var completedDismissSeconds: Double = 6
    public var keepHistory = true
    public var debugScreenshots = false
    public var onboardingComplete = false
    public var enableVoiceInput = false

    public init() {}

    public func provider(_ id: String) -> ProviderConfig? { providers.first { $0.id == id } }
}

/// Persists settings (never secrets) to UserDefaults as JSON.
@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore()
    nonisolated static let defaultsKey = "dev.notchbuddy.settings.v1"
    private let defaults: UserDefaults

    public var settings: AppSettings {
        didSet { save() }
    }

    /// The app and nbctl share one settings domain.
    nonisolated public static func sharedDefaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == "dev.notchbuddy.app" { return .standard }
        return UserDefaults(suiteName: "dev.notchbuddy.app") ?? .standard
    }

    public init(defaults: UserDefaults = SettingsStore.sharedDefaults()) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Read-only snapshot for background work.
    nonisolated public static func loadSnapshot(defaults: UserDefaults = sharedDefaults()) -> AppSettings {
        guard let data = defaults.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }
}
