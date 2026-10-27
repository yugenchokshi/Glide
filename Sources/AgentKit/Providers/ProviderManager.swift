import Foundation

/// Per-task counters for observability and the benchmark report.
public actor TaskMetrics {
    public private(set) var modelCalls = 0
    public private(set) var visionCalls = 0
    public private(set) var jevCalls = 0
    public private(set) var usage = LLMUsage()
    public private(set) var estimatedCost: Double = 0
    public private(set) var costKnown = true
    public private(set) var modelLatencyMs: Double = 0
    public private(set) var actions = 0
    public private(set) var deterministicActions = 0
    public private(set) var recoveries = 0
    public private(set) var interventions = 0
    public private(set) var observations = 0
    public private(set) var observationMs: Double = 0

    public init() {}

    public func recordModel(_ r: LLMResponse, vision: Bool) {
        modelCalls += 1
        if vision { visionCalls += 1 }
        usage = usage + r.usage
        modelLatencyMs += r.latencyMs
        if let c = ModelPricing.cost(model: r.model, usage: r.usage) { estimatedCost += c } else { costKnown = false }
    }
    public func recordJev(_ usage: LLMUsage) { jevCalls += 1; self.usage = self.usage + usage }
    public func recordAction(deterministic: Bool) { actions += 1; if deterministic { deterministicActions += 1 } }
    public func recordRecovery() { recoveries += 1 }
    public func recordIntervention() { interventions += 1 }
    public func recordObservation(ms: Double) { observations += 1; observationMs += ms }

    public struct Snapshot: Sendable, Codable {
        public var modelCalls: Int
        public var visionCalls: Int
        public var jevCalls: Int
        public var inputTokens: Int
        public var outputTokens: Int
        public var estimatedCost: Double?
        public var modelLatencyMs: Double
        public var actions: Int
        public var deterministicActions: Int
        public var recoveries: Int
        public var interventions: Int
        public var observations: Int
        public var avgObservationMs: Double
    }

    public func snapshot() -> Snapshot {
        Snapshot(modelCalls: modelCalls, visionCalls: visionCalls, jevCalls: jevCalls, inputTokens: usage.inputTokens,
                 outputTokens: usage.outputTokens, estimatedCost: costKnown ? estimatedCost : (estimatedCost > 0 ? estimatedCost : nil),
                 modelLatencyMs: modelLatencyMs, actions: actions, deterministicActions: deterministicActions, recoveries: recoveries,
                 interventions: interventions, observations: observations, avgObservationMs: observations > 0 ? observationMs / Double(observations) : 0)
    }
}

/// Resolves which provider + model serves each role, from settings and stored keys.
public struct ModelRouter: Sendable {
    public struct Route: Sendable {
        public let provider: any LLMProvider
        public let model: String
        public let effort: String?
    }

    let settings: AppSettings
    let credentials: CredentialStore

    public init(settings: AppSettings, credentials: CredentialStore = .shared) {
        self.settings = settings
        self.credentials = credentials
    }

    public func makeProvider(_ config: ProviderConfig) -> any LLMProvider {
        let key = credentials.get(.provider(config.id)) ?? ""
        switch config.kind {
        case .anthropic: return AnthropicProvider(config: config, apiKey: key)
        case .openai, .openaiCompatible: return OpenAIProvider(config: config, apiKey: key)
        }
    }

    /// Providers that are enabled and usable (have a key when one is required).
    public var usableProviders: [ProviderConfig] {
        settings.providers.filter { $0.enabled && (!$0.requiresKey || credentials.has(.provider($0.id))) }
    }

    public var isConfigured: Bool { (try? route(.planner)) != nil }

    public func route(_ role: ModelRole) throws -> Route {
        if settings.routing.mode == .manual, let choice = settings.routing.manual[role] ?? (role == .recovery ? settings.routing.manual[.planner] : nil),
           let config = settings.provider(choice.providerID), config.enabled {
            return Route(provider: makeProvider(config), model: choice.model, effort: choice.effort)
        }
        let candidates = usableProviders
        guard let config = settings.routing.preferredProviderID.flatMap({ id in candidates.first { $0.id == id } }) ?? candidates.first else {
            throw LLMError.notConfigured("No AI provider is configured. Add an API key in Settings › AI Providers.")
        }
        let (model, effort) = Self.automaticModel(for: role, provider: config)
        guard !model.isEmpty else { throw LLMError.notConfigured("Pick a model for \(config.name) in Settings › Models.") }
        return Route(provider: makeProvider(config), model: model, effort: effort)
    }

    /// Automatic routing defaults: capable model for planning/vision/recovery, small fast
    /// model for action selection.
    public static func automaticModel(for role: ModelRole, provider: ProviderConfig) -> (String, String?) {
        switch provider.kind {
        case .anthropic:
            switch role {
            case .planner: return ("claude-opus-5-5", "low")
            case .actor: return ("claude-haiku-5-5", "low")
            case .vision: return ("claude-opus-5-5", "low")
            case .recovery: return ("claude-opus-5-5", "medium")
            }
        case .openai:
            // OpenAI uses gpt-6-luna for every role by default; pick others in Settings › Models.
            // Planning and each step's next move run at low effort: on real step prompts it picks
            // the same actions as the default about as often as the default agrees with itself,
            // about 20% faster.
            switch role {
            case .planner, .actor: return (ProviderConfig.openAIDefaultModel, "low")
            case .vision, .recovery: return (ProviderConfig.openAIDefaultModel, nil)
            }
        case .openaiCompatible:
            return (provider.models.first ?? "", nil)
        }
    }

    public func jevClient() -> JevClient? {
        let r = settings.routing
        guard r.useJevForSelection else { return nil }
        let provider = r.effectiveJevProvider
        guard let key = credentials.get(Self.jevKey(provider)), !key.isEmpty else { return nil }
        return JevClient(apiKey: key, model: r.effectiveJevModel, provider: provider)
    }

    public static func jevKey(_ provider: JevProvider) -> CredentialStore.Key {
        provider == .typesafe ? .jev : .vercelGateway
    }
}
