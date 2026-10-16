import SwiftUI
import AgentKit

struct ProvidersSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        BKSectionHeader(title: "AI Providers", subtitle: "Bring your own keys. They're stored in your macOS Keychain, sent only to the provider you choose, and never logged or shown to models.")
        ForEach($store.settings.providers) { $provider in
            ProviderCard(provider: $provider, onRemove: provider.kind == .openaiCompatible ? {
                CredentialStore.shared.remove(.provider(provider.id))
                store.settings.providers.removeAll { $0.id == provider.id }
            } : nil)
        }
        HStack {
            Button {
                let id = "custom-" + UUID().uuidString.prefix(6).lowercased()
                store.settings.providers.append(ProviderConfig(id: id, kind: .openaiCompatible, name: "Custom endpoint", baseURL: "http://localhost:11434/v1", requiresKey: false))
            } label: { Label("Add OpenAI-compatible endpoint", systemImage: "plus") }
                .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            Spacer()
        }
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
        BKCard {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(BK.Tone.accent.color)
                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(BK.Tone.accent.color.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    if provider.kind == .openaiCompatible {
                        TextField("Name", text: $provider.name).textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                    } else {
                        Text(provider.name).font(.system(size: 14, weight: .semibold))
                    }
                    Text(provider.kind.displayName).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
                Toggle("", isOn: $provider.enabled).labelsHidden().toggleStyle(.switch).help("Use this provider")
            }
            if provider.kind != .anthropic {
                BKFormRow(title: "Base URL") {
                    BKTextField(placeholder: "https://…/v1", text: $provider.baseURL, monospaced: true).frame(width: 340)
                }
            }
            if provider.kind == .openaiCompatible {
                BKFormRow(title: "Requires an API key") {
                    Toggle("", isOn: $provider.requiresKey).labelsHidden().toggleStyle(.switch)
                }
            }
            BKFormRow(title: "API key", detail: hasKey ? "Saved in Keychain: \(CredentialStore.mask(CredentialStore.shared.get(.provider(provider.id)) ?? ""))" : "Not set") {
                HStack(spacing: 6) {
                    BKSecretField(placeholder: hasKey ? "Replace key…" : keyPlaceholder, text: $keyInput).frame(width: 250)
                    Button("Save") {
                        CredentialStore.shared.set(keyInput, for: .provider(provider.id))
                        keyInput = ""
                        refresh()
                        Task { await test() }
                    }
                    .buttonStyle(BKButtonStyle(kind: .primary, compact: true))
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack(spacing: 8) {
                Button { Task { await test() } } label: {
                    HStack(spacing: 5) {
                        if testing { ProgressView().controlSize(.small) }
                        Text("Test connection")
                    }
                }
                .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
                .disabled(testing || (provider.requiresKey && !hasKey))
                if hasKey {
                    Button("Remove key") {
                        CredentialStore.shared.remove(.provider(provider.id))
                        provider.lastTestOK = nil
                        refresh()
                    }
                    .buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                }
                if let onRemove {
                    Button("Remove endpoint", role: .destructive, action: onRemove).buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                }
                Spacer()
                if !provider.models.isEmpty {
                    Text("\(provider.models.count) models available").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).font(.system(size: 11.5)).foregroundStyle(provider.lastTestOK == true ? BK.Tone.success.color : BK.Tone.danger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refresh)
    }

    var icon: String {
        switch provider.kind {
        case .anthropic: return "sparkle"
        case .openai: return "circle.hexagongrid"
        case .openaiCompatible: return "server.rack"
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
    @State private var hasKey = CredentialStore.shared.has(.jev)
    @State private var message: String?

    var body: some View {
        BKCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TypeSafe Jev (optional)").font(.system(size: 14, weight: .semibold))
                    Text("A fast decision model used only to choose between ambiguous on-screen candidates. Your planner and action models still do everything else.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $store.settings.routing.useJevForSelection).labelsHidden().toggleStyle(.switch).disabled(!hasKey)
            }
            BKFormRow(title: "API key", detail: hasKey ? "Saved in Keychain" : "Not set") {
                HStack(spacing: 6) {
                    BKSecretField(placeholder: "TypeSafe key", text: $keyInput).frame(width: 220)
                    Button("Save") {
                        CredentialStore.shared.set(keyInput, for: .jev)
                        keyInput = ""
                        hasKey = CredentialStore.shared.has(.jev)
                    }
                    .buttonStyle(BKButtonStyle(kind: .primary, compact: true)).disabled(keyInput.isEmpty)
                    if hasKey {
                        Button("Test") {
                            Task {
                                do { try await JevClient(apiKey: CredentialStore.shared.get(.jev) ?? "", model: store.settings.routing.jevModel).test(); message = "Connected." }
                                catch { message = error.localizedDescription }
                            }
                        }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
                        Button("Remove") {
                            CredentialStore.shared.remove(.jev)
                            hasKey = false
                            store.settings.routing.useJevForSelection = false
                        }.buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                    }
                }
            }
            BKFormRow(title: "Model") { BKTextField(placeholder: "jev-latest", text: $store.settings.routing.jevModel, monospaced: true).frame(width: 160) }
            if let message { Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Models

struct ModelsSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        BKSectionHeader(title: "Models", subtitle: "Automatic routing picks a capable model for planning and vision and a small, fast one for choosing each action.")
        BKCard {
            BKFormRow(title: "Routing") {
                Picker("", selection: $store.settings.routing.mode) {
                    Text("Automatic").tag(RoutingSettings.Mode.automatic)
                    Text("Manual").tag(RoutingSettings.Mode.manual)
                }.pickerStyle(.segmented).frame(width: 200).labelsHidden()
            }
            if store.settings.routing.mode == .automatic {
                Divider()
                BKFormRow(title: "Preferred provider") {
                    Picker("", selection: Binding(get: { store.settings.routing.preferredProviderID ?? "" }, set: { store.settings.routing.preferredProviderID = $0.isEmpty ? nil : $0 })) {
                        Text("First available").tag("")
                        ForEach(store.settings.providers) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(width: 220)
                }
            }
        }
        ForEach(ModelRole.allCases) { role in
            RoleRow(store: store, role: role)
        }
    }
}

struct RoleRow: View {
    @Bindable var store: SettingsStore
    let role: ModelRole

    var body: some View {
        BKCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.title).font(.system(size: 13, weight: .semibold))
                    Text(role.hint).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.settings.routing.mode == .automatic {
                    Text(automaticLabel).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if store.settings.routing.mode == .manual {
                HStack(spacing: 8) {
                    Picker("Provider", selection: providerBinding) {
                        Text("—").tag("")
                        ForEach(store.settings.providers.filter(\.enabled)) { Text($0.name).tag($0.id) }
                    }.frame(width: 200)
                    modelField
                    Picker("Effort", selection: effortBinding) {
                        Text("default").tag("")
                        Text("low").tag("low")
                        Text("medium").tag("medium")
                        Text("high").tag("high")
                    }.frame(width: 150)
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
            Picker("Model", selection: modelBinding) {
                if !models.contains(choice.model) { Text(choice.model.isEmpty ? "—" : choice.model).tag(choice.model) }
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }.frame(width: 260)
        }
    }
}
