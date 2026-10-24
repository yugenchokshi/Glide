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
    /// Default OpenAI model for all roles.
    public static let openAIDefaultModel = "gpt-6-luna"

    public static let openAIDefault = ProviderConfig(
        id: "openai", kind: .openai, name: "OpenAI", baseURL: "https://api.openai.com/v1", models: [openAIDefaultModel])
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
    /// Where Jev is called. Optional so settings saved before this option still decode.
    public var jevProvider: JevProvider?
    public init() {}

    public var effectiveJevProvider: JevProvider { jevProvider ?? .typesafe }

    /// The model id for the selected provider (the gateway names Jev `typesafe-ai/jev`).
    public var effectiveJevModel: String {
        let m = jevModel.trimmingCharacters(in: .whitespaces)
        switch effectiveJevProvider {
        case .typesafe: return m.isEmpty || m.hasPrefix("typesafe-ai/") ? "jev-latest" : m
        case .vercelGateway: return m.isEmpty || !m.hasPrefix("typesafe-ai/") ? "typesafe-ai/jev" : m
        }
    }
}

/// Jev can be reached directly at TypeSafe or through Vercel AI Gateway, which exposes a
/// TypeSafe-compatible endpoint billed to your Vercel account.
public enum JevProvider: String, Codable, Sendable, CaseIterable {
    case typesafe
    case vercelGateway

    public var title: String {
        switch self {
        case .typesafe: return "TypeSafe (direct)"
        case .vercelGateway: return "Vercel AI Gateway"
        }
    }

    public var endpoint: URL {
        switch self {
        case .typesafe: return URL(string: "https://api.typesafe.ai/v1/systemone")!
        case .vercelGateway: return URL(string: "https://ai-gateway.vercel.sh/typesafe/v1/systemone")!
        }
    }

    public var defaultModel: String {
        switch self {
        case .typesafe: return "jev-latest"
        case .vercelGateway: return "typesafe-ai/jev"
        }
    }

    public var keyPlaceholder: String {
        switch self {
        case .typesafe: return "TypeSafe API key"
        case .vercelGateway: return "AI Gateway API key"
        }
    }
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
    public var userID = "glide-" + UUID().uuidString.prefix(8).lowercased()
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

/// Whether the planner prefers direct tools (commands, DOM-level browser) or visible UI work.
public enum ExecutionPreference: String, Codable, Sendable, CaseIterable {
    /// Use commands, files, the browser extension and web fetches wherever possible.
    case fastest
    /// Prefer driving apps on screen so you can watch every step.
    case showMe

    public var title: String {
        switch self {
        case .fastest: return "Fastest"
        case .showMe: return "Show me"
        }
    }
}

public enum CommandAccess: String, Codable, Sendable, CaseIterable {
    case off
    /// Only commands that can't change anything (ls, cat, mdfind, git status…).
    case readOnly
    /// Any command; changes follow your approval settings, dangerous ones are blocked.
    case full

    public var title: String {
        switch self {
        case .off: return "Off"
        case .readOnly: return "Read-only"
        case .full: return "Full (with approvals)"
        }
    }
}

public struct ToolSettings: Codable, Sendable, Hashable {
    public var executionPreference: ExecutionPreference = .fastest
    public var commandAccess: CommandAccess = .full
    public var allowAppleScript = true
    public var allowShortcuts = true
    /// Let the action model return several actions per call.
    public var batchActions = true
    public var maxBatch = 6
    public init() {}
}

public struct BrowserSettings: Codable, Sendable, Hashable {
    public var backend: BrowserBackendKind = .extensionBridge
    /// Localhost port the Glide extension connects to.
    public var bridgePort = 47823
    /// Optional custom Chrome executable.
    public var chromePath: String?
    /// Work in background tabs so the browser doesn't jump to the front.
    public var useBackgroundTabs = true
    /// Fall back to Glide's own Chrome window when the extension isn't connected.
    public var fallbackToGlideChrome = true
    public init() {}
}

public enum ScreenUse: String, Codable, Sendable, CaseIterable {
    /// Background jobs may take over the cursor any time.
    case always
    /// Only after you've been idle for `idleSeconds`.
    case whenIdle
    /// Never; on-screen steps pause the job and ask.
    case never

    public var title: String {
        switch self {
        case .always: return "Any time"
        case .whenIdle: return "Only when I'm idle"
        case .never: return "Never — ask me"
        }
    }
}

public struct JobSettings: Codable, Sendable, Hashable {
    public var maxConcurrentJobs = 2
    public var screenUse: ScreenUse = .whenIdle
    public var idleSeconds: Double = 30
    /// Continue interrupted jobs automatically when Glide starts.
    public var autoResume = true
    /// Ask before starting jobs estimated above these.
    public var confirmAboveCostUSD: Double = 1
    public var confirmAboveMinutes: Double = 15
    public var defaultBudget = JobBudget()
    /// Prevent idle sleep while a job runs.
    public var keepAwake = true
    public var notifications = true
    public init() {}
}

public struct AppSettings: Codable, Sendable, Hashable {
    public var providers: [ProviderConfig] = [.anthropicDefault, .openAIDefault]
    public var routing = RoutingSettings()
    public var safety = SafetySettings()
    public var limits = LimitSettings()
    public var hotkeys = HotkeySettings()
    public var composio = ComposioSettings()
    public var mcpServers: [MCPServerConfig] = []
    public var cursorMode: CursorMode = .fast
    public var completedDismissSeconds: Double = 6
    public var keepHistory = true
    public var debugScreenshots = false
    public var onboardingComplete = false
    public var enableVoiceInput = false
    public var tools = ToolSettings()
    public var browser = BrowserSettings()
    public var jobs = JobSettings()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case providers, routing, safety, limits, hotkeys, composio, mcpServers, cursorMode, completedDismissSeconds
        case keepHistory, debugScreenshots, onboardingComplete, enableVoiceInput, tools, browser, jobs
    }

    /// Tolerant decoding: any missing or unreadable field keeps its default, so settings saved
    /// by older builds load instead of resetting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        let d = AppSettings()
        providers = v(.providers, d.providers)
        routing = v(.routing, d.routing)
        safety = v(.safety, d.safety)
        limits = v(.limits, d.limits)
        hotkeys = v(.hotkeys, d.hotkeys)
        composio = v(.composio, d.composio)
        mcpServers = v(.mcpServers, d.mcpServers)
        cursorMode = v(.cursorMode, d.cursorMode)
        completedDismissSeconds = v(.completedDismissSeconds, d.completedDismissSeconds)
        keepHistory = v(.keepHistory, d.keepHistory)
        debugScreenshots = v(.debugScreenshots, d.debugScreenshots)
        onboardingComplete = v(.onboardingComplete, d.onboardingComplete)
        enableVoiceInput = v(.enableVoiceInput, d.enableVoiceInput)
        tools = v(.tools, d.tools)
        browser = v(.browser, d.browser)
        jobs = v(.jobs, d.jobs)
    }

    public func provider(_ id: String) -> ProviderConfig? { providers.first { $0.id == id } }
}

/// Persists settings (never secrets) to UserDefaults as JSON.
@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore()
    // Identifiers from the app's earlier name (NotchBuddy), kept so existing settings,
    // Keychain entries and macOS permissions carry over to Glide unchanged.
    nonisolated static let defaultsKey = "dev.notchbuddy.settings.v1"
    private let defaults: UserDefaults

    public var settings: AppSettings {
        didSet { save() }
    }

    /// The app and glidectl share one settings domain.
    nonisolated public static func sharedDefaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == "dev.notchbuddy.app" { return .standard }
        return UserDefaults(suiteName: "dev.notchbuddy.app") ?? .standard
    }

    public init(defaults: UserDefaults = SettingsStore.sharedDefaults()) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey), var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            // An earlier build listed a non-existent "gpt-luna-6" model; drop it.
            var migrated = false
            for i in decoded.providers.indices where decoded.providers[i].models.contains("gpt-luna-6") {
                decoded.providers[i].models.removeAll { $0 == "gpt-luna-6" }
                migrated = true
            }
            settings = decoded
            if migrated { save() }
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
