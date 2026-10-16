import SwiftUI
import AppKit
import AgentKit

struct IntegrationsSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        BKSectionHeader(title: "Integrations", subtitle: "Optional. When a connected integration can do a step directly, NotchBuddy uses it instead of driving the app's UI. Everything works without them.")
        ComposioSection(store: store)
        MCPSection(store: store)
    }
}

struct ComposioSection: View {
    @Bindable var store: SettingsStore
    @State private var keyInput = ""
    @State private var hasKey = CredentialStore.shared.has(.composio)
    @State private var toolkits: [ComposioClient.Toolkit] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var connecting: String?

    var body: some View {
        BKCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Composio").font(.system(size: 14, weight: .semibold))
                    Text("Gmail, Google Calendar, Drive, Slack, Notion, GitHub, HubSpot and more, using your own Composio project key. Sign-ins happen on Composio's hosted page; no OAuth secrets are stored in this app.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $store.settings.composio.enabled).labelsHidden().toggleStyle(.switch).disabled(!hasKey)
            }
            BKFormRow(title: "Project API key", detail: hasKey ? "Saved in Keychain" : "From dashboard.composio.dev › Project settings › API keys") {
                HStack(spacing: 6) {
                    BKSecretField(placeholder: "ak_…", text: $keyInput).frame(width: 220)
                    Button("Save") {
                        CredentialStore.shared.set(keyInput, for: .composio)
                        keyInput = ""
                        hasKey = CredentialStore.shared.has(.composio)
                        store.settings.composio.sessionID = nil
                        store.settings.composio.enabled = hasKey
                        Task { await load() }
                    }.buttonStyle(BKButtonStyle(kind: .primary, compact: true)).disabled(keyInput.isEmpty)
                    if hasKey {
                        Button("Remove") {
                            CredentialStore.shared.remove(.composio)
                            hasKey = false
                            store.settings.composio.enabled = false
                            store.settings.composio.sessionID = nil
                            toolkits = []
                        }.buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                    }
                }
            }
            if hasKey {
                HStack {
                    BKTextField(placeholder: "Search apps (gmail, slack, notion…)", text: $search).onSubmit { Task { await load() } }
                    Button { Task { await load() } } label: { if loading { ProgressView().controlSize(.small) } else { Text("Refresh") } }
                        .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
                }
                if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(BK.Tone.danger.color) }
                let connected = toolkits.filter { $0.connectedAccountID != nil }
                if !connected.isEmpty {
                    Text("Connected").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(connected) { kit in toolkitRow(kit) }
                }
                Text("Available").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(toolkits.filter { $0.connectedAccountID == nil }.prefix(30)) { kit in toolkitRow(kit) }
            }
        }
        .task { if hasKey { await load() } }
    }

    @ViewBuilder func toolkitRow(_ kit: ComposioClient.Toolkit) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: kit.logo.flatMap(URL.init(string:))) { img in img.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.15) }
                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(kit.name).font(.system(size: 12.5, weight: .medium))
                Text(kit.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if kit.isNoAuth {
                BKBadge(text: "No sign-in needed", tone: .info)
            } else if let account = kit.connectedAccountID {
                BKBadge(text: kit.connectionStatus?.capitalized ?? "Connected", tone: kit.connectionStatus == nil || kit.connectionStatus == "ACTIVE" ? .success : .warning)
                Button("Disconnect") { Task { await disconnect(account) } }.buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
            } else {
                Button(connecting == kit.slug ? "Waiting…" : "Connect") { Task { await connect(kit) } }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).disabled(connecting != nil)
            }
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let (client, session) = try await ComposioSessionStore.ensureSession(store: store)
            toolkits = try await client.toolkits(sessionID: session, search: search)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connect(_ kit: ComposioClient.Toolkit) async {
        connecting = kit.slug
        defer { connecting = nil }
        do {
            let (client, session) = try await ComposioSessionStore.ensureSession(store: store)
            let link = try await client.link(sessionID: session, toolkit: kit.slug, callbackURL: store.settings.composio.callbackURL)
            NSWorkspace.shared.open(link.redirectURL)
            // Poll until the hosted sign-in completes (up to 3 minutes).
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(3))
                let kits = try await client.toolkits(sessionID: session, search: kit.slug)
                if kits.contains(where: { $0.slug == kit.slug && $0.connectedAccountID != nil }) { break }
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func disconnect(_ account: String) async {
        do {
            let (client, _) = try await ComposioSessionStore.ensureSession(store: store)
            try await client.disconnect(connectedAccountID: account)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MCPSection: View {
    @Bindable var store: SettingsStore
    @State private var status: [String: (Bool, Int, String?)] = [:]
    @State private var editing: MCPServerConfig?

    var body: some View {
        BKCard {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP servers").font(.system(size: 14, weight: .semibold))
                    Text("Connect Model Context Protocol servers (local stdio commands or remote HTTP). Their tools become available to the planner.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { editing = MCPServerConfig(name: "New server", transport: .stdio) } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
            if store.settings.mcpServers.isEmpty {
                Text("No servers yet.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(store.settings.mcpServers) { server in
                HStack(spacing: 10) {
                    let s = status[server.id]
                    BKStatusDot(tone: !server.enabled ? .neutral : (s?.0 == true ? .success : (s?.2 != nil ? .danger : .warning)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.name).font(.system(size: 12.5, weight: .medium))
                        Text(server.transport == .stdio ? ([server.command] + server.arguments).joined(separator: " ") : server.url)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        if let e = s?.2 { Text(e).font(.system(size: 11)).foregroundStyle(BK.Tone.danger.color).lineLimit(2) }
                    }
                    Spacer()
                    if let s, s.0 { BKBadge(text: "\(s.1) tools", tone: .success) }
                    Button("Edit") { editing = server }.buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                }
            }
            HStack {
                Spacer()
                Button("Reconnect all") { Task { await sync() } }.buttonStyle(BKButtonStyle(kind: .secondary, compact: true))
            }
        }
        .task { await sync() }
        .sheet(item: $editing) { server in
            MCPServerEditor(server: server, onSave: { updated in
                if let i = store.settings.mcpServers.firstIndex(where: { $0.id == updated.id }) { store.settings.mcpServers[i] = updated }
                else { store.settings.mcpServers.append(updated) }
                editing = nil
                Task { await sync() }
            }, onDelete: {
                store.settings.mcpServers.removeAll { $0.id == server.id }
                editing = nil
                Task { await sync() }
            }, onCancel: { editing = nil })
        }
    }

    func sync() async {
        await MCPManager.shared.sync(with: store.settings.mcpServers)
        var out: [String: (Bool, Int, String?)] = [:]
        for s in await MCPManager.shared.status() { out[s.id] = (s.connected, s.toolCount, s.error) }
        status = out
    }
}

struct MCPServerEditor: View {
    @State var server: MCPServerConfig
    var onSave: (MCPServerConfig) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void
    @State private var argsText = ""
    @State private var envText = ""
    @State private var headerName = ""
    @State private var headerValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MCP server").font(.system(size: 16, weight: .semibold))
            BKFormRow(title: "Name") { BKTextField(placeholder: "filesystem", text: $server.name).frame(width: 300) }
            BKFormRow(title: "Transport") {
                Picker("", selection: $server.transport) {
                    Text("Local command (stdio)").tag(MCPServerConfig.Transport.stdio)
                    Text("Remote (HTTP)").tag(MCPServerConfig.Transport.http)
                }.labelsHidden().frame(width: 300)
            }
            if server.transport == .stdio {
                BKFormRow(title: "Command", detail: "Runs through your login shell, so npx/uvx work.") { BKTextField(placeholder: "npx", text: $server.command, monospaced: true).frame(width: 300) }
                BKFormRow(title: "Arguments", detail: "One per line.") {
                    TextEditor(text: $argsText).font(.system(size: 12, design: .monospaced)).frame(width: 300, height: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
                BKFormRow(title: "Environment", detail: "KEY=value per line. Stored in settings, not the Keychain — don't put secrets here.") {
                    TextEditor(text: $envText).font(.system(size: 12, design: .monospaced)).frame(width: 300, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
            } else {
                BKFormRow(title: "URL") { BKTextField(placeholder: "https://…/mcp", text: $server.url, monospaced: true).frame(width: 300) }
                BKFormRow(title: "Secret header", detail: server.secretHeaders.isEmpty ? "e.g. Authorization — the value is stored in the Keychain." : "Stored: \(server.secretHeaders.joined(separator: ", "))") {
                    HStack {
                        BKTextField(placeholder: "Authorization", text: $headerName).frame(width: 110)
                        BKSecretField(placeholder: "value", text: $headerValue).frame(width: 140)
                        Button("Add") {
                            CredentialStore.shared.set(headerValue, for: .mcpHeader(server: server.id, header: headerName))
                            if !server.secretHeaders.contains(headerName) { server.secretHeaders.append(headerName) }
                            headerName = ""; headerValue = ""
                        }.disabled(headerName.isEmpty || headerValue.isEmpty)
                    }
                }
            }
            Toggle("Enabled", isOn: $server.enabled)
            HStack {
                Button("Delete", role: .destructive, action: onDelete)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    server.arguments = argsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    var env: [String: String] = [:]
                    for line in envText.split(separator: "\n") {
                        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                        if parts.count == 2 { env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1] }
                    }
                    server.environment = env
                    onSave(server)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            argsText = server.arguments.joined(separator: "\n")
            envText = server.environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        }
    }
}
