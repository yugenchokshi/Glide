import SwiftUI
import AgentKit

struct ProvidersSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        BKSectionHeader(title: "AI Providers", subtitle: "Bring your own keys. They're stored in your macOS Keychain, sent only to the provider you choose, and never logged or shown to models.")
        BKGroupHeader(title: "Providers") {
            Button {
                let id = "custom-" + UUID().uuidString.prefix(6).lowercased()
                store.settings.providers.append(ProviderConfig(id: id, kind: .openaiCompatible, name: "Custom endpoint", baseURL: "http://localhost:11434/v1", requiresKey: false))
            } label: { Label("OpenAI-compatible endpoint", systemImage: "plus") }
                .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
                .fixedSize()
        }
        ForEach($store.settings.providers) { $provider in
            ProviderCard(provider: $provider, onRemove: provider.kind == .openaiCompatible ? {
                CredentialStore.shared.remove(.provider(provider.id))
                store.settings.providers.removeAll { $0.id == provider.id }
            } : nil)
        }
        BKGroupHeader(title: "Selection model", subtitle: "Optional. A fast decision model used only to choose between ambiguous on-screen candidates.")
        JevCard(store: store)
    }
}

struct ProviderCard: View {
    @Binding var provider: ProviderConfig
    var onRemove: (() -> Void)?
    @State private var keyInput = ""
    @State private var testing = false
    @State private var message: String?
    @State private var hasKey = false

    var body: some View {
        BKGroup {
            HStack(spacing: 11) {
                BKTile(title: provider.name, color: tileColor, symbol: icon, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    if provider.kind == .openaiCompatible {
                        TextField("Name", text: $provider.name).textFieldStyle(.plain).font(BK.Font.headline)
                    } else {
                        Text(provider.name).font(BK.Font.headline)
                    }
                    Text(provider.kind == .anthropic ? "api.anthropic.com" : (URL(string: provider.baseURL)?.host ?? provider.kind.displayName)).font(BK.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
                BKSwitch(isOn: $provider.enabled, label: "Use \(provider.name)").help("Use this provider")
            }
            if provider.kind != .anthropic {
                BKFormRow(title: "Base URL") {
                    BKTextField(placeholder: "https://…/v1", text: $provider.baseURL, monospaced: true).frame(width: 320)
                }
            }
            if provider.kind == .openaiCompatible {
                BKFormRow(title: "Requires an API key") {
                    BKSwitch(isOn: $provider.requiresKey, label: "Requires an API key")
                }
            }
            BKFormRow(title: "API key", detail: hasKey ? "Saved in Keychain: \(CredentialStore.mask(CredentialStore.shared.get(.provider(provider.id)) ?? ""))" : "Not set") {
                HStack(spacing: 6) {
                    BKSecretField(placeholder: hasKey ? "Replace key…" : keyPlaceholder, text: $keyInput).frame(minWidth: 180, maxWidth: 240)
                    Button("Save") {
                        CredentialStore.shared.set(keyInput, for: .provider(provider.id))
                        keyInput = ""
                        refresh()
                        Task { await test() }
                    }
                    .buttonStyle(BKButtonStyle(kind: .primary, compact: true))
                    .fixedSize()
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button { Task { await test() } } label: {
                        HStack(spacing: 5) {
                            if testing { ProgressView().controlSize(.mini) }
                            Text("Test connection")
                        }
                    }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
                    .fixedSize()
                    .disabled(testing || (provider.requiresKey && !hasKey))
                    if hasKey {
                        Button("Remove key") {
                            CredentialStore.shared.remove(.provider(provider.id))
                            provider.lastTestOK = nil
                            refresh()
                        }
                        .buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                        .fixedSize()
                    }
                    if let onRemove {
                        Button("Remove endpoint", role: .destructive, action: onRemove).buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                            .fixedSize()
                    }
                    Spacer()
                    if !provider.models.isEmpty {
                        Text("\(provider.models.count) model\(provider.models.count == 1 ? "" : "s")").font(BK.Font.caption).foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Text(message).font(BK.Font.caption).foregroundStyle(provider.lastTestOK == true ? BK.Tone.success.color : BK.Tone.danger.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    var icon: String {
        switch provider.kind {
        case .anthropic: return "sparkle"
        case .openai: return "circle.hexagongrid.fill"
        case .openaiCompatible: return "server.rack"
        }
    }

    var tileColor: Color {
        switch provider.kind {
        case .anthropic: return Color(hex: 0xD97757)
        case .openai: return Color(hex: 0x10A37F)
        case .openaiCompatible: return BK.Palette.n600
        }
    }

    var keyPlaceholder: String {
        switch provider.kind {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .openaiCompatible: return "optional"
        }
    }

    @ViewBuilder var statusBadge: some View {
        if provider.lastTestOK == true { BKBadge(text: "Connected", tone: .success) }
        else if provider.lastTestOK == false { BKBadge(text: "Error", tone: .danger) }
        else if hasKey || !provider.requiresKey { BKBadge(text: "Untested", tone: .neutral) }
        else { BKBadge(text: "No key", tone: .warning) }
    }

    func refresh() { hasKey = CredentialStore.shared.has(.provider(provider.id)) }

    func test() async {
        testing = true
        defer { testing = false }
        let router = ModelRouter(settings: { var s = AppSettings(); s.providers = [provider]; return s }())
        let client = router.makeProvider(provider)
        do {
            let models = try await client.listModels()
            if !models.isEmpty {
                // Keep known-good defaults first for Anthropic; otherwise use the live list.
                provider.models = switch provider.kind {
                case .anthropic: Array(Set(models + ProviderConfig.anthropicDefault.models)).sorted()
                case .openai: Array(Set(models + [ProviderConfig.openAIDefaultModel])).sorted()
                case .openaiCompatible: models
                }
            }
            provider.lastTestOK = true
            provider.lastError = nil
            provider.lastTestedAt = Date()
            message = "Connected. \(models.count) models available."
            if provider.kind == .openai, !models.isEmpty, !models.contains(ProviderConfig.openAIDefaultModel) {
                message! += " Note: \(ProviderConfig.openAIDefaultModel) isn't listed for this key — pick another model in Settings › Models if tasks fail."
            }
        } catch {
            provider.lastTestOK = false
            provider.lastError = error.localizedDescription
            message = error.localizedDescription
        }
    }
}

struct JevCard: View {
    @Bindable var store: SettingsStore
    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var testing = false

    var provider: JevProvider { store.settings.routing.effectiveJevProvider }

    var body: some View {
        BKGroup {
            HStack(spacing: 11) {
                BKTile(title: "Jev", color: Color(hex: 0x6366F1), symbol: "bolt.fill", size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TypeSafe Jev").font(BK.Font.headline)
                    Text("Your planner and action models still do everything else.").font(BK.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                BKSwitch(isOn: $store.settings.routing.useJevForSelection, label: "Use Jev for selection").disabled(!hasKey)
            }
            BKFormRow(title: "Connect through", detail: provider == .vercelGateway
                      ? "Uses Vercel's TypeSafe-compatible endpoint, billed to your Vercel account (AI_GATEWAY_API_KEY)."
                      : "Calls api.typesafe.ai with your TypeSafe key.") {
                BKSegmented(options: JevProvider.allCases.map { ($0, $0.title) }, selection: Binding(get: { provider }, set: { new in
                    store.settings.routing.jevProvider = new
                    store.settings.routing.jevModel = new.defaultModel
                    message = nil
                    refresh()
                }))
            }
            BKFormRow(title: provider == .vercelGateway ? "AI Gateway key" : "API key",
                      detail: hasKey ? "Saved in Keychain: \(CredentialStore.mask(CredentialStore.shared.get(ModelRouter.jevKey(provider)) ?? ""))" : "Not set") {
                HStack(spacing: 6) {
                    BKSecretField(placeholder: provider.keyPlaceholder, text: $keyInput).frame(minWidth: 170, maxWidth: 220)
                    Button("Save") {
                        CredentialStore.shared.set(keyInput, for: ModelRouter.jevKey(provider))
                        keyInput = ""
                        refresh()
                        Task { await test() }
                    }
                    .buttonStyle(BKButtonStyle(kind: .primary, compact: true))
                    .fixedSize().disabled(keyInput.isEmpty)
                    if hasKey {
                        Button { Task { await test() } } label: {
                            HStack(spacing: 4) { if testing { ProgressView().controlSize(.mini) }; Text("Test") }
                        }
                        .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
                        .fixedSize().disabled(testing)
                        Button("Remove") {
                            CredentialStore.shared.remove(ModelRouter.jevKey(provider))
                            refresh()
                            store.settings.routing.useJevForSelection = false
                        }.buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                            .fixedSize()
                    }
                }
            }
            BKFormRow(title: "Model", detail: "Default: \(provider.defaultModel)") {
                BKTextField(placeholder: provider.defaultModel, text: $store.settings.routing.jevModel, monospaced: true).frame(width: 200)
            }
            if let message { Text(message).font(BK.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear(perform: refresh)
    }

    func refresh() { hasKey = CredentialStore.shared.has(ModelRouter.jevKey(provider)) }

    func test() async {
        testing = true
        defer { testing = false }
        let routing = store.settings.routing
        let client = JevClient(apiKey: CredentialStore.shared.get(ModelRouter.jevKey(provider)) ?? "", model: routing.effectiveJevModel, provider: provider)
        do {
            try await client.test()
            message = "Connected to Jev via \(provider.title) (\(routing.effectiveJevModel))."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Models

struct ModelsSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        BKSectionHeader(title: "Models", subtitle: "Automatic routing picks a capable model for planning and vision and a small, fast one for choosing each action.")
        BKGroup {
            BKFormRow(title: "Routing", detail: store.settings.routing.mode == .automatic ? "Glide chooses a model for each role." : "You choose the provider, model and effort for each role.") {
                BKSegmented(options: [(RoutingSettings.Mode.automatic, "Automatic"), (.manual, "Manual")], selection: $store.settings.routing.mode)
            }
            if store.settings.routing.mode == .automatic {
                BKFormRow(title: "Preferred provider") {
                    BKMenu(options: [("", "First available")] + store.settings.providers.map { ($0.id, $0.name) },
                           selection: Binding(get: { store.settings.routing.preferredProviderID ?? "" }, set: { store.settings.routing.preferredProviderID = $0.isEmpty ? nil : $0 }),
                           minWidth: 160)
                }
            }
        }
        BKGroupHeader(title: "Roles")
        BKGroup {
            ForEach(ModelRole.allCases) { role in
                RoleRow(store: store, role: role)
            }
        }
    }
}

struct RoleRow: View {
    @Bindable var store: SettingsStore
    let role: ModelRole

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.title).font(BK.Font.bodyMedium)
                    Text(role.hint).font(BK.Font.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.settings.routing.mode == .automatic {
                    Text(automaticLabel).font(BK.Font.mono).foregroundStyle(.secondary)
                }
            }
            if store.settings.routing.mode == .manual {
                HStack(spacing: 6) {
                    BKMenu(options: [("", "Provider…")] + store.settings.providers.filter(\.enabled).map { ($0.id, $0.name) }, selection: providerBinding, minWidth: 140)
                    modelField
                    BKMenu(options: [("", "Default effort"), ("low", "Low"), ("medium", "Medium"), ("high", "High")], selection: effortBinding, minWidth: 110)
                }
            }
        }
    }

    var automaticLabel: String {
        let router = ModelRouter(settings: store.settings)
        if let r = try? router.route(role) { return "\(r.provider.config.name) · \(r.model)" }
        return "needs a provider key"
    }

    var choice: ModelChoice { store.settings.routing.manual[role] ?? ModelChoice(providerID: "", model: "") }

    var providerBinding: Binding<String> {
        Binding(get: { choice.providerID }, set: { id in
            var c = choice
            c.providerID = id
            if let p = store.settings.provider(id) { c.model = ModelRouter.automaticModel(for: role, provider: p).0 }
            store.settings.routing.manual[role] = c
        })
    }

    var effortBinding: Binding<String> {
        Binding(get: { choice.effort ?? "" }, set: { e in
            var c = choice
            c.effort = e.isEmpty ? nil : e
            store.settings.routing.manual[role] = c
        })
    }

    var modelBinding: Binding<String> {
        Binding(get: { choice.model }, set: { m in
            var c = choice
            c.model = m
            store.settings.routing.manual[role] = c
        })
    }

    @ViewBuilder var modelField: some View {
        let models = store.settings.provider(choice.providerID)?.models ?? []
        if models.isEmpty {
            BKTextField(placeholder: "model id", text: modelBinding, monospaced: true).frame(width: 220)
        } else {
            BKMenu(options: (models.contains(choice.model) ? [] : [(choice.model, choice.model.isEmpty ? "Model…" : choice.model)]) + models.map { ($0, $0) },
                   selection: modelBinding, minWidth: 200)
        }
    }
}
