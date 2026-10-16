import SwiftUI
import AppKit
import AgentKit

// MARK: - Catalogs

/// Popular apps reachable through Composio. Always shown, so you can see what Glide can
/// connect to before adding a key. Tiles use initials on brand colors; real logos appear once
/// Composio is connected (nothing is fetched before you configure it).
struct AppIntegration: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case all = "All", mail = "Email & calendar", chat = "Chat", docs = "Docs & files", dev = "Developer", crm = "CRM & sales", projects = "Projects"
        /// Short label for the filter pills.
        var short: String {
            switch self {
            case .mail: return "Email"
            case .docs: return "Docs"
            case .crm: return "CRM"
            default: return rawValue
            }
        }
        var id: String { rawValue }
    }
    var id: String { slug }
    let slug: String
    let name: String
    let category: Category
    let blurb: String
    let color: UInt32

    static let catalog: [AppIntegration] = [
        .init(slug: "gmail", name: "Gmail", category: .mail, blurb: "Read, search, draft and send email.", color: 0xEA4335),
        .init(slug: "googlecalendar", name: "Google Calendar", category: .mail, blurb: "Find free time, create and update events.", color: 0x4285F4),
        .init(slug: "outlook", name: "Outlook", category: .mail, blurb: "Microsoft mail and calendar.", color: 0x0078D4),
        .init(slug: "calendly", name: "Calendly", category: .mail, blurb: "Scheduling links and booked meetings.", color: 0x006BFF),
        .init(slug: "slack", name: "Slack", category: .chat, blurb: "Post messages and read channels.", color: 0x4A154B),
        .init(slug: "discord", name: "Discord", category: .chat, blurb: "Send messages to servers and channels.", color: 0x5865F2),
        .init(slug: "zoom", name: "Zoom", category: .chat, blurb: "Schedule meetings and get recordings.", color: 0x2D8CFF),
        .init(slug: "notion", name: "Notion", category: .docs, blurb: "Pages, databases and comments.", color: 0x191919),
        .init(slug: "googledrive", name: "Google Drive", category: .docs, blurb: "Find, upload and share files.", color: 0x1FA463),
        .init(slug: "googledocs", name: "Google Docs", category: .docs, blurb: "Create and edit documents.", color: 0x2684FC),
        .init(slug: "googlesheets", name: "Google Sheets", category: .docs, blurb: "Read and update spreadsheets.", color: 0x0F9D58),
        .init(slug: "dropbox", name: "Dropbox", category: .docs, blurb: "Files and shared folders.", color: 0x0061FF),
        .init(slug: "airtable", name: "Airtable", category: .docs, blurb: "Bases, tables and records.", color: 0x18BFFF),
        .init(slug: "github", name: "GitHub", category: .dev, blurb: "Issues, pull requests and repos.", color: 0x24292F),
        .init(slug: "linear", name: "Linear", category: .dev, blurb: "Issues, projects and cycles.", color: 0x5E6AD2),
        .init(slug: "jira", name: "Jira", category: .dev, blurb: "Tickets, sprints and boards.", color: 0x0052CC),
        .init(slug: "figma", name: "Figma", category: .dev, blurb: "Files, comments and components.", color: 0xA259FF),
        .init(slug: "hubspot", name: "HubSpot", category: .crm, blurb: "Contacts, companies and deals.", color: 0xFF7A59),
        .init(slug: "salesforce", name: "Salesforce", category: .crm, blurb: "Leads, accounts and opportunities.", color: 0x00A1E0),
        .init(slug: "shopify", name: "Shopify", category: .crm, blurb: "Orders, products and customers.", color: 0x5E8E3E),
        .init(slug: "asana", name: "Asana", category: .projects, blurb: "Tasks, projects and assignees.", color: 0xF06A6A),
        .init(slug: "trello", name: "Trello", category: .projects, blurb: "Boards, lists and cards.", color: 0x0079BF),
    ]
}

/// Well-known MCP servers you can add in one step (you review the command before saving).
struct MCPPreset: Identifiable {
    var id: String { name }
    let name: String
    let blurb: String
    let color: UInt32
    let symbol: String
    let transport: MCPServerConfig.Transport
    var command = ""
    var arguments: [String] = []
    var url = ""
    /// For HTTP servers that take a token: header name and value hint.
    var header: (name: String, hint: String)? = nil

    var config: MCPServerConfig {
        var c = MCPServerConfig(name: name, transport: transport)
        c.command = command
        c.arguments = arguments
        c.url = url
        return c
    }

    static let catalog: [MCPPreset] = [
        .init(name: "Filesystem", blurb: "Read and write files in a folder you choose.", color: 0x3B82F6, symbol: "folder.fill", transport: .stdio,
              command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", NSHomeDirectory() + "/Documents"]),
        .init(name: "Playwright", blurb: "Drive a headless browser: navigate, click, extract.", color: 0x2EAD33, symbol: "theatermasks.fill", transport: .stdio,
              command: "npx", arguments: ["-y", "@playwright/mcp@latest"]),
        .init(name: "Fetch", blurb: "Fetch web pages and convert them to Markdown.", color: 0x0EA5E9, symbol: "arrow.down.doc.fill", transport: .stdio,
              command: "uvx", arguments: ["mcp-server-fetch"]),
        .init(name: "Memory", blurb: "A local knowledge graph the agent can remember with.", color: 0x8B5CF6, symbol: "brain.head.profile", transport: .stdio,
              command: "npx", arguments: ["-y", "@modelcontextprotocol/server-memory"]),
        .init(name: "Sequential Thinking", blurb: "Structured step-by-step reasoning tool.", color: 0xF59E0B, symbol: "list.number", transport: .stdio,
              command: "npx", arguments: ["-y", "@modelcontextprotocol/server-sequential-thinking"]),
        .init(name: "Time", blurb: "Current time and time-zone conversion.", color: 0x14B8A6, symbol: "clock.fill", transport: .stdio,
              command: "uvx", arguments: ["mcp-server-time"]),
        .init(name: "Context7", blurb: "Up-to-date library and API documentation.", color: 0x10B981, symbol: "books.vertical.fill", transport: .stdio,
              command: "npx", arguments: ["-y", "@upstash/context7-mcp"]),
        .init(name: "GitHub", blurb: "GitHub's remote server. Needs a personal access token.", color: 0x24292F, symbol: "chevron.left.forwardslash.chevron.right", transport: .http,
              url: "https://api.githubcopilot.com/mcp/", header: ("Authorization", "Bearer ghp_…")),
        .init(name: "Stripe", blurb: "Stripe's remote server. Needs a restricted API key.", color: 0x635BFF, symbol: "creditcard.fill", transport: .http,
              url: "https://mcp.stripe.com", header: ("Authorization", "Bearer rk_…")),
    ]
}

// MARK: - Page

struct IntegrationsSettingsView: View {
    enum Tab: Hashable { case apps, mcp }
    @Bindable var store: SettingsStore
    @State private var tab: Tab
    /// Snapshot hook: fixed MCP connection states instead of launching servers.
    var previewMCPStatus: [String: (Bool, Int, String?)]? = nil

    init(store: SettingsStore, initialTab: Tab = .apps, previewMCPStatus: [String: (Bool, Int, String?)]? = nil) {
        self.store = store
        _tab = State(initialValue: initialTab)
        self.previewMCPStatus = previewMCPStatus
    }

    var body: some View {
        BKSectionHeader(title: "Integrations", subtitle: "Optional. When a connected integration can do a step directly, Glide uses it instead of driving the app's UI. Everything works without them.")
        BKSegmented(options: [(Tab.apps, "Apps"), (.mcp, "MCP servers")], selection: $tab)
            .padding(.bottom, 2)
        switch tab {
        case .apps: AppsIntegrationsView(store: store)
        case .mcp: MCPSection(store: store, previewStatus: previewMCPStatus)
        }
    }
}

// MARK: - Apps (Composio)

struct AppsIntegrationsView: View {
    @Bindable var store: SettingsStore
    @State private var keyInput = ""
    @State private var hasKey = CredentialStore.shared.has(.composio)
    @State private var live: [String: ComposioClient.Toolkit] = [:]
    @State private var searchResults: [ComposioClient.Toolkit] = []
    @State private var search = ""
    @State private var category: AppIntegration.Category = .all
    @State private var loading = false
    @State private var error: String?
    @State private var connecting: String?
    @State private var keySheetFor: AppIntegration?

    var body: some View {
        composioGroup
        BKGroupHeader(title: "Apps", subtitle: hasKey ? "\(connectedCount) connected · sign-ins open on Composio's hosted page" : "Add a Composio key to connect any of these") {
            if hasKey {
                Button { Task { await load() } } label: {
                    HStack(spacing: 4) { if loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }; Text("Refresh") }
                }
                .buttonStyle(BKButtonStyle(kind: .ghost, compact: true)).fixedSize().disabled(loading)
            }
        }
        BKSearchField(placeholder: hasKey ? "Search 500+ apps…" : "Search apps…", text: $search)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(AppIntegration.Category.allCases) { c in
                    BKPill(title: c.short, count: c == .all ? nil : AppIntegration.catalog.filter { $0.category == c }.count, selected: category == c) {
                        withAnimation(.snappy(duration: 0.2)) { category = c }
                    }
                }
            }
        }
        if let error { BKCallout(tone: .danger, icon: "exclamationmark.triangle.fill", title: "Composio", message: error) }
        let items = filtered
        if items.isEmpty && extraResults.isEmpty {
            BKEmptyState(icon: "magnifyingglass", title: "No matching apps", message: hasKey ? "Nothing on Composio matches “\(search)”." : "Add a Composio key to search every app Composio supports.")
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
            ForEach(items) { app in
                AppIntegrationCard(name: app.name, blurb: app.blurb, category: app.category.rawValue, color: Color(hex: app.color),
                                   toolkit: live[app.slug], connecting: connecting == app.slug,
                                   onConnect: { connectTapped(app) }, onDisconnect: { account in Task { await disconnect(account) } })
            }
        }
        if !extraResults.isEmpty {
            BKGroupHeader(title: "More on Composio")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(extraResults) { kit in
                    AppIntegrationCard(name: kit.name, blurb: kit.description, category: nil, color: BK.Palette.n500, toolkit: kit,
                                       connecting: connecting == kit.slug,
                                       onConnect: { Task { await connect(slug: kit.slug, name: kit.name) } },
                                       onDisconnect: { account in Task { await disconnect(account) } })
                }
            }
        }
        Color.clear.frame(height: 0)
            .task { if hasKey { await load() } }
            .task(id: search) {
                guard hasKey else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await runSearch()
            }
            .sheet(item: $keySheetFor) { app in
                ComposioKeySheet(app: app, onSave: { key in
                    saveKey(key)
                    keySheetFor = nil
                    Task {
                        await load()
                        await connect(slug: app.slug, name: app.name)
                    }
                }, onCancel: { keySheetFor = nil })
            }
    }

    @ViewBuilder var composioGroup: some View {
        BKGroup {
            HStack(spacing: 11) {
                BKTile(title: "Composio", color: Color(hex: 0x111111), symbol: "square.stack.3d.up.fill", size: 32, status: hasKey ? (error == nil ? .success : .danger) : nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Composio").font(BK.Font.headline)
                    Text("Gmail, Slack, Notion, GitHub, HubSpot and 500+ more, with your own Composio project key. No OAuth secrets are stored in this app.")
                        .font(BK.Font.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                BKSwitch(isOn: $store.settings.composio.enabled, label: "Use Composio").disabled(!hasKey)
            }
            BKFormRow(title: "Project API key", detail: hasKey ? "Saved in Keychain" : "From dashboard.composio.dev › Project settings › API keys") {
                HStack(spacing: 6) {
                    BKSecretField(placeholder: hasKey ? "Replace key…" : "ak_…", text: $keyInput).frame(width: 210)
                    Button("Save") {
                        saveKey(keyInput)
                        keyInput = ""
                        Task { await load() }
                    }
                    .buttonStyle(BKButtonStyle(kind: .primary, compact: true))
                    .fixedSize().disabled(keyInput.isEmpty)
                    if hasKey {
                        Button("Remove") {
                            CredentialStore.shared.remove(.composio)
                            hasKey = false
                            store.settings.composio.enabled = false
                            store.settings.composio.sessionID = nil
                            live = [:]
                            searchResults = []
                            error = nil
                        }
                        .buttonStyle(BKButtonStyle(kind: .ghost, compact: true))
                        .fixedSize()
                    }
                }
            }
        }
    }

    var connectedCount: Int { live.values.filter { $0.connectedAccountID != nil }.count }

    var filtered: [AppIntegration] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return AppIntegration.catalog.filter { app in
            (category == .all || app.category == category)
                && (q.isEmpty || app.name.lowercased().contains(q) || app.blurb.lowercased().contains(q) || app.slug.contains(q))
        }
        // Connected apps first.
        .sorted { (live[$0.slug]?.connectedAccountID != nil ? 0 : 1) < (live[$1.slug]?.connectedAccountID != nil ? 0 : 1) }
    }

    /// Live search hits that aren't already in the catalog.
    var extraResults: [ComposioClient.Toolkit] {
        guard !search.isEmpty else { return [] }
        let known = Set(AppIntegration.catalog.map(\.slug))
        return searchResults.filter { !known.contains($0.slug) }
    }

    func saveKey(_ key: String) {
        CredentialStore.shared.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: .composio)
        hasKey = CredentialStore.shared.has(.composio)
        store.settings.composio.sessionID = nil
        store.settings.composio.enabled = hasKey
    }

    func connectTapped(_ app: AppIntegration) {
        if hasKey { Task { await connect(slug: app.slug, name: app.name) } } else { keySheetFor = app }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let (client, session) = try await ComposioSessionStore.ensureSession(store: store)
            var map: [String: ComposioClient.Toolkit] = [:]
            for kit in try await client.toolkits(sessionID: session) { map[kit.slug] = kit }
            // Connected accounts may be outside the first page; fetch them explicitly.
            for kit in try await client.toolkits(sessionID: session, connectedOnly: true) { map[kit.slug] = kit }
            live = map
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runSearch() async {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchResults = []; return }
        do {
            let (client, session) = try await ComposioSessionStore.ensureSession(store: store)
            let kits = try await client.toolkits(sessionID: session, search: q)
            searchResults = kits
            for kit in kits where live[kit.slug] == nil { live[kit.slug] = kit }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connect(slug: String, name: String) async {
        connecting = slug
        defer { connecting = nil }
        do {
            let (client, session) = try await ComposioSessionStore.ensureSession(store: store)
            // Resolve the toolkit's real slug if the catalog guess isn't known to Composio.
            var target = slug
            if live[slug] == nil {
                let hits = try await client.toolkits(sessionID: session, search: name)
                if let hit = hits.first(where: { $0.slug == slug }) ?? hits.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) ?? hits.first {
                    target = hit.slug
                    live[slug] = hit
                }
            }
            let link = try await client.link(sessionID: session, toolkit: target, callbackURL: store.settings.composio.callbackURL)
            NSWorkspace.shared.open(link.redirectURL)
            // Poll until the hosted sign-in completes (up to 3 minutes).
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(3))
                let kits = try await client.toolkits(sessionID: session, search: target)
                if let kit = kits.first(where: { $0.slug == target && $0.connectedAccountID != nil }) {
                    live[slug] = kit
                    live[target] = kit
                    break
                }
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

struct AppIntegrationCard: View {
    let name: String
    let blurb: String
    let category: String?
    let color: Color
    let toolkit: ComposioClient.Toolkit?
    let connecting: Bool
    let onConnect: () -> Void
    let onDisconnect: (String) -> Void
    @State private var hovering = false

    @ViewBuilder var action: some View {
        if let kit = toolkit, kit.isNoAuth {
            EmptyView()
        } else if let account = toolkit?.connectedAccountID {
            Menu {
                Button("Disconnect", role: .destructive) { onDisconnect(account) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions for \(name)")
        } else {
            Button(action: onConnect) {
                if connecting { ProgressView().controlSize(.mini) } else { Text("Connect") }
            }
            .buttonStyle(BKButtonStyle(kind: hovering ? .primary : .secondary, compact: true))
            .fixedSize()
            .disabled(connecting)
        }
    }

    var body: some View {
        BKCard(padding: 12, selected: hovering) {
            HStack(alignment: .center, spacing: 10) {
                BKTile(title: name, color: color, logoURL: toolkit?.logo.flatMap(URL.init(string:)), size: 34,
                       status: toolkit?.connectedAccountID != nil ? .success : nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(BK.Font.bodyMedium).lineLimit(1)
                    if let kit = toolkit, kit.isNoAuth {
                        Text("No sign-in needed").font(BK.Font.caption).foregroundStyle(BK.Tone.info.color).lineLimit(1)
                    } else if let kit = toolkit, kit.connectedAccountID != nil {
                        Text(kit.connectionStatus.map { $0 == "ACTIVE" ? "Connected" : $0.capitalized } ?? "Connected")
                            .font(BK.Font.captionMedium)
                            .foregroundStyle(kit.connectionStatus == nil || kit.connectionStatus == "ACTIVE" ? BK.Tone.success.color : BK.Tone.warning.color).lineLimit(1)
                    } else if let category {
                        Text(category).font(BK.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                action
            }
            Text(blurb.isEmpty ? " " : blurb).font(BK.Font.caption).foregroundStyle(.secondary).lineLimit(category == nil ? 2 : 1, reservesSpace: true)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Shown when you click Connect before adding a Composio key.
struct ComposioKeySheet: View {
    let app: AppIntegration
    var onSave: (String) -> Void
    var onCancel: () -> Void
    @State private var key = ""

    var body: some View {
        BKThemeReader { t in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: -6) {
                    BKTile(title: app.name, color: Color(hex: app.color), size: 40)
                    BKTile(title: "Composio", color: Color(hex: 0x111111), symbol: "square.stack.3d.up.fill", size: 40)
                        .overlay(RoundedRectangle(cornerRadius: 11.2, style: .continuous).strokeBorder(t.canvas, lineWidth: 2))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect \(app.name)").font(BK.Font.title2)
                    Text("Glide connects to \(app.name) through Composio using your own Composio project key. After you save it, \(app.name)'s sign-in opens in your browser on Composio's hosted page.")
                        .font(BK.Font.body).foregroundStyle(t.secondary).fixedSize(horizontal: false, vertical: true)
                }
                BKGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Composio project API key").font(BK.Font.bodyMedium)
                        BKSecretField(placeholder: "ak_…", text: $key)
                        Text("Find it at dashboard.composio.dev › Project settings › API keys. It's stored in your Keychain.")
                            .font(BK.Font.caption).foregroundStyle(t.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button("Get a key") { NSWorkspace.shared.open(URL(string: "https://dashboard.composio.dev")!) }
                        .buttonStyle(BKButtonStyle(kind: .tinted))
                    Spacer()
                    Button("Cancel", action: onCancel).buttonStyle(BKButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                    Button("Save & connect") { onSave(key) }.buttonStyle(BKButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(22).frame(width: 460)
            .background(t.canvas)
        }
    }
}

// MARK: - MCP servers

struct MCPSection: View {
    @Bindable var store: SettingsStore
    var previewStatus: [String: (Bool, Int, String?)]? = nil
    @State private var status: [String: (Bool, Int, String?)] = [:]
    @State private var editing: EditTarget?
    @State private var syncing = false

    struct EditTarget: Identifiable {
        var server: MCPServerConfig
        var header: (name: String, hint: String)?
        var id: String { server.id }
    }

    var body: some View {
        BKGroupHeader(title: "Your servers", subtitle: "Their tools become available to the planner. Local servers run through your login shell.") {
            Button { Task { await sync() } } label: {
                HStack(spacing: 4) { if syncing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }; Text("Reconnect") }
            }
            .buttonStyle(BKButtonStyle(kind: .ghost, compact: true)).fixedSize().disabled(syncing || store.settings.mcpServers.isEmpty)
        }
        BKGroup {
            ForEach(store.settings.mcpServers) { server in serverRow(server) }
            Button { editing = EditTarget(server: MCPServerConfig(name: "New server", transport: .stdio)) } label: {
                HStack(spacing: 11) {
                    BKThemeReader { t in
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(t.secondary)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8.4, style: .continuous).fill(t.raised))
                            .overlay(RoundedRectangle(cornerRadius: 8.4, style: .continuous).strokeBorder(t.border, lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("New MCP server").font(BK.Font.bodyMedium)
                        Text("Add a local command or a remote URL").font(BK.Font.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        BKGroupHeader(title: "Popular servers", subtitle: "Adds a ready-made configuration you can review before saving.")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
            ForEach(MCPPreset.catalog) { preset in
                let added = store.settings.mcpServers.contains { $0.name == preset.name }
                BKCard(padding: 12) {
                    HStack(alignment: .center, spacing: 10) {
                        BKTile(title: preset.name, color: Color(hex: preset.color), symbol: preset.symbol, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name).font(BK.Font.bodyMedium).lineLimit(1)
                            if added {
                                Text("Added").font(BK.Font.captionMedium).foregroundStyle(BK.Tone.success.color)
                            } else {
                                Text(preset.transport == .stdio ? "Local · \(preset.command)" : "Remote · HTTP").font(BK.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Button(added ? "Add again" : "Add") { editing = EditTarget(server: preset.config, header: preset.header) }
                            .buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
                    }
                    Text(preset.blurb).font(BK.Font.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                }
            }
        }
        Color.clear.frame(height: 0)
            .task { await sync() }
            .sheet(item: $editing) { target in
                MCPServerEditor(server: target.server, headerHint: target.header, isNew: !store.settings.mcpServers.contains { $0.id == target.server.id },
                                onSave: { updated in
                    if let i = store.settings.mcpServers.firstIndex(where: { $0.id == updated.id }) { store.settings.mcpServers[i] = updated }
                    else { store.settings.mcpServers.append(updated) }
                    editing = nil
                    Task { await sync() }
                }, onDelete: {
                    store.settings.mcpServers.removeAll { $0.id == target.server.id }
                    editing = nil
                    Task { await sync() }
                }, onCancel: { editing = nil })
            }
    }

    @ViewBuilder func serverRow(_ server: MCPServerConfig) -> some View {
        let s = status[server.id]
        let tone: BK.Tone = !server.enabled ? .neutral : (s?.0 == true ? .success : (s?.2 != nil ? .danger : .warning))
        HStack(spacing: 11) {
            BKTile(title: server.name, color: Color(hex: MCPPreset.catalog.first { $0.name == server.name }?.color ?? 0x737373),
                   symbol: MCPPreset.catalog.first { $0.name == server.name }?.symbol, size: 30, status: tone)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.name).font(BK.Font.bodyMedium)
                    Text(server.transport == .stdio ? "Local" : "Remote").font(BK.Font.caption).foregroundStyle(.tertiary)
                }
                if let e = s?.2, server.enabled {
                    Text("Error — \(e)").font(BK.Font.caption).foregroundStyle(BK.Tone.danger.color).lineLimit(1).help(e)
                } else if let s, s.0 {
                    Text("\(s.1) tool\(s.1 == 1 ? "" : "s") enabled").font(BK.Font.caption).foregroundStyle(.secondary)
                } else {
                    Text(server.transport == .stdio ? ([server.command] + server.arguments).joined(separator: " ") : server.url)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            BKSwitch(isOn: Binding(get: { server.enabled }, set: { on in
                if let i = store.settings.mcpServers.firstIndex(where: { $0.id == server.id }) { store.settings.mcpServers[i].enabled = on }
                Task { await sync() }
            }), label: "Enable \(server.name)")
            Menu {
                Button("Edit…") { editing = EditTarget(server: server) }
                Button("Delete", role: .destructive) {
                    store.settings.mcpServers.removeAll { $0.id == server.id }
                    Task { await sync() }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions for \(server.name)")
        }
    }

    func sync() async {
        if let previewStatus { status = previewStatus; return }
        syncing = true
        defer { syncing = false }
        await MCPManager.shared.sync(with: store.settings.mcpServers)
        var out: [String: (Bool, Int, String?)] = [:]
        for s in await MCPManager.shared.status() { out[s.id] = (s.connected, s.toolCount, s.error) }
        status = out
    }
}

struct MCPServerEditor: View {
    @State var server: MCPServerConfig
    var headerHint: (name: String, hint: String)? = nil
    var isNew = false
    var onSave: (MCPServerConfig) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void
    @State private var argsText = ""
    @State private var envText = ""
    @State private var headerName = ""
    @State private var headerValue = ""

    var body: some View {
        BKThemeReader { t in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    BKTile(title: server.name, color: Color(hex: MCPPreset.catalog.first { $0.name == server.name }?.color ?? 0x737373),
                           symbol: MCPPreset.catalog.first { $0.name == server.name }?.symbol ?? "server.rack", size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isNew ? "Add MCP server" : "Edit MCP server").font(BK.Font.title2)
                        Text("Review the command before saving. Servers run with your user's permissions.").font(BK.Font.caption).foregroundStyle(t.secondary)
                    }
                }
                BKGroup {
                    BKFormRow(title: "Name") { BKTextField(placeholder: "filesystem", text: $server.name).frame(width: 300) }
                    BKFormRow(title: "Transport") {
                        BKSegmented(options: [(MCPServerConfig.Transport.stdio, "Local command"), (.http, "Remote (HTTP)")], selection: $server.transport)
                    }
                    if server.transport == .stdio {
                        BKFormRow(title: "Command", detail: "Runs through your login shell, so npx/uvx work.") { BKTextField(placeholder: "npx", text: $server.command, monospaced: true).frame(width: 300) }
                        BKFormRow(title: "Arguments", detail: "One per line.") { BKTextEditor(text: $argsText, monospaced: true, height: 64).frame(width: 300) }
                        BKFormRow(title: "Environment", detail: "KEY=value per line. Stored in settings, not the Keychain — don't put secrets here.") {
                            BKTextEditor(text: $envText, monospaced: true, height: 48).frame(width: 300)
                        }
                    } else {
                        BKFormRow(title: "URL") { BKTextField(placeholder: "https://…/mcp", text: $server.url, monospaced: true).frame(width: 300) }
                        BKFormRow(title: "Secret header", detail: server.secretHeaders.isEmpty ? "e.g. Authorization — the value is stored in the Keychain." : "Stored: \(server.secretHeaders.joined(separator: ", "))") {
                            HStack(spacing: 6) {
                                BKTextField(placeholder: "Authorization", text: $headerName).frame(width: 110)
                                BKSecretField(placeholder: headerHint?.hint ?? "value", text: $headerValue).frame(width: 140)
                                Button("Add") {
                                    CredentialStore.shared.set(headerValue, for: .mcpHeader(server: server.id, header: headerName))
                                    if !server.secretHeaders.contains(headerName) { server.secretHeaders.append(headerName) }
                                    headerValue = ""
                                }
                                .buttonStyle(BKButtonStyle(kind: .secondary, compact: true)).fixedSize()
                                .disabled(headerName.isEmpty || headerValue.isEmpty)
                            }
                        }
                    }
                    BKFormRow(title: "Enabled") { BKSwitch(isOn: $server.enabled, label: "Enabled") }
                }
                HStack {
                    if !isNew { Button("Delete", role: .destructive, action: onDelete).buttonStyle(BKButtonStyle(kind: .ghost)) }
                    Spacer()
                    Button("Cancel", action: onCancel).buttonStyle(BKButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                    Button(isNew ? "Add server" : "Save") {
                        server.arguments = argsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        var env: [String: String] = [:]
                        for line in envText.split(separator: "\n") {
                            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                            if parts.count == 2 { env[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1] }
                        }
                        server.environment = env
                        onSave(server)
                    }
                    .buttonStyle(BKButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 600)
            .background(t.canvas)
        }
        .onAppear {
            argsText = server.arguments.joined(separator: "\n")
            envText = server.environment.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
            if let headerHint, headerName.isEmpty { headerName = headerHint.name }
        }
    }
}
