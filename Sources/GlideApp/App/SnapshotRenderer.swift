import AppKit
import SwiftUI
import AgentKit

/// `Glide --snapshot <dir>` renders every notch state to PNG (for docs and visual
/// regression checks) without running any automation.
@MainActor
enum SnapshotRenderer {
    /// True while rendering snapshots: views skip loading the user's local history.
    static var isRendering = false

    static func run(into dir: String) {
        isRendering = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Render as a configured install without touching the Keychain.
        CredentialStore.shared.useMemoryOnly([.provider("anthropic"): "sk-ant-demo-000000000000a1B2"])
        let suite = "dev.glide.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        let controller = TaskController(runtime: AutomationRuntime(), settingsStore: store)
        // Empty until the job shots, so the classic notch images stay unchanged.
        let jobs = PreviewJobs()
        let model = NotchModel(controller: controller, settings: store, jobs: jobs)
        model.geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true,
                                       notchRect: CGRect(x: 666, y: 950, width: 180, height: 32))
        let plan = Plan(goal: "Summarize Apple earnings into Notes", steps: [
            PlanStep(id: 1, title: "Opening Safari", instruction: "", route: .native, app: "Safari", risk: .low, doneWhen: "", hint: nil),
            PlanStep(id: 2, title: "Reading the results", instruction: "", route: .gui, app: "Safari", risk: .low, doneWhen: "", hint: nil),
            PlanStep(id: 3, title: "Creating a note", instruction: "", route: .gui, app: "Notes", risk: .low, doneWhen: "", hint: nil),
            PlanStep(id: 4, title: "Writing the summary", instruction: "", route: .gui, app: "Notes", risk: .medium, doneWhen: "", hint: nil),
        ], clarification: nil)
        let instruction = "Open Safari, search for the latest Apple earnings, summarize the results, and save the summary in Notes."
        let activity: [ActivityEntry] = [
            ActivityEntry(kind: .plan, title: "Planned 4 steps"),
            ActivityEntry(kind: .step, title: "Opening Safari", route: .native),
            ActivityEntry(kind: .action, title: "Opening https://www.google.com/search?q=apple+earnings", detail: "open-url · window updated", route: .native, success: true, durationMs: 412),
            ActivityEntry(kind: .step, title: "Reading the results", route: .gui),
            ActivityEntry(kind: .info, title: "Noted information", detail: "Q4 revenue $102.5B (+8% YoY); iPhone $49.0B; Services record $28.8B."),
            ActivityEntry(kind: .step, title: "Creating a note", route: .gui),
            ActivityEntry(kind: .action, title: "Pressing ⇧⌘N… Clicking “New Note”", detail: "mouse · window updated", route: .gui, success: true, durationMs: 96),
        ]
        func shot(_ name: String, _ setup: () -> Void) {
            setup()
            model.recompute()
            let size = model.size
            let view = NotchRootView(model: model)
                .frame(width: size.width + 40, height: size.height + 20)
                .background(Color(white: 0.16))
            // A real hosting view (not ImageRenderer) so AppKit-backed controls like the text field render.
            SettingsSnapshotRenderer.render(view, size: CGSize(width: size.width + 40, height: size.height + 20), dark: true, to: "\(dir)/notch-\(name).png")
        }
        shot("idle") { controller.previewState(phase: .idle, status: ""); model.inputOpen = false }
        shot("input") { model.inputOpen = true; model.inputText = instruction }
        shot("planning") { model.inputOpen = false; controller.previewState(phase: .planning, status: "Understanding your task…", instruction: instruction) }
        shot("executing") { controller.previewState(phase: .executing, status: "Clicking “New Note”", instruction: instruction, plan: plan, stepIndex: 2, activity: activity) }
        shot("detail") { model.detailOpen = true }
        shot("approval") {
            model.detailOpen = false
            controller.previewState(phase: .awaitingApproval, status: "Needs your approval", instruction: "Email the summary to my team", plan: plan, stepIndex: 3,
                                    approval: ApprovalRequest(kind: .action, title: "Clicking “Send”", detail: "Send the drafted summary email to the team list.",
                                                              appName: "Mail", risk: .high, reasons: ["clicking “Send”"]))
        }
        shot("completed") {
            controller.previewState(phase: .completed, status: "Saved a note “Apple Q4 earnings” with a 5-point summary.", instruction: instruction, plan: plan, stepIndex: 4)
            model.resultVisible = true
        }
        shot("error") {
            controller.previewState(phase: .failed, status: "Couldn't find the “New Note” button after 2 replans. Notes may be showing a sign-in sheet.", instruction: instruction, plan: plan, stepIndex: 2)
            model.resultVisible = true
        }

        // Background jobs.
        let demo = PreviewJobs.demo()
        shot("job-idle") {
            controller.previewState(phase: .idle, status: "")
            model.resultVisible = false
            jobs.jobs = [demo.research]
        }
        shot("job-pill") { model.inputOpen = true; model.inputText = "" }
        shot("job-detail") {
            jobs.jobs = [demo.research, demo.daily, demo.confirm]
            model.showJobsDetail()
        }
        shot("job-confirm") {
            model.close()
            model.jobNeedsAttention(demo.confirm.id)
        }
        shot("job-approval") {
            model.dismissJobCard()
            jobs.pendingApprovals = [demo.research.id: demo.approval]
        }
        shot("job-finished") {
            jobs.pendingApprovals = [:]
            jobs.jobs = [demo.finished]
            model.jobFinished(demo.finished)
        }

        // The Jobs settings detail, from the same demo data.
        let nav = SettingsNavigation()
        let all = PreviewJobs.demo().source
        for dark in [false, true] {
            nav.showJob(demo.research.id)
            let page = SettingsPageFrame(nav: nav) { JobsSettingsView(store: store, nav: nav, jobs: all) }
            SettingsSnapshotRenderer.render(page, size: CGSize(width: 920, height: 1900), dark: dark, to: "\(dir)/settings-jobs-detail\(dark ? "-dark" : "").png")
        }
    }
}

/// Jobs for snapshots: realistic records, items, events and a report, held in memory. The
/// controls change statuses locally so the views behave as they do with `JobCenter`.
@MainActor
@Observable
final class PreviewJobs: JobsSource {
    var jobs: [JobRecord] = []
    var pendingApprovals: [String: ApprovalRequest] = [:]
    var itemsByJob: [String: [JobItem]] = [:]
    var eventsByJob: [String: [ActivityEntry]] = [:]
    var reports: [String: String] = [:]

    var activeJob: JobRecord? { jobs.filter { $0.status.isActive }.max { $0.updatedAt < $1.updatedAt } }
    func job(_ id: String) -> JobRecord? { jobs.first { $0.id == id } }
    func items(_ jobID: String, limit: Int) -> [JobItem] { Array((itemsByJob[jobID] ?? []).prefix(limit)) }
    func events(_ jobID: String, limit: Int) -> [ActivityEntry] { Array((eventsByJob[jobID] ?? []).suffix(limit)) }
    func report(_ jobID: String) -> String? { reports[jobID] }

    private func set(_ id: String, _ status: JobStatus) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = status
        jobs[i].updatedAt = Date()
    }

    func start(_ id: String) { set(id, .running) }
    func pause(_ id: String) { set(id, .paused) }
    func resume(_ id: String) { set(id, .running) }
    func stop(_ id: String) { set(id, .stopped) }
    func retryFailedItems(_ id: String) { set(id, .running) }
    func delete(_ id: String) { jobs.removeAll { $0.id == id } }
    func respond(jobID: String, decision: ApprovalDecision) {
        pendingApprovals[jobID] = nil
        if decision == .stop { set(jobID, .stopped) }
    }
    func exportResults(_ jobID: String, to url: URL) throws {
        throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Export isn't available in previews."])
    }

    struct Demo {
        var source: PreviewJobs
        var research: JobRecord
        var confirm: JobRecord
        var daily: JobRecord
        var finished: JobRecord
        var approval: ApprovalRequest
    }

    /// A lead-research job in progress (with items and activity), one awaiting confirmation,
    /// a daily check that's waiting, and a finished job with a report.
    static func demo(now: Date = Date()) -> Demo {
        let folder = "/Users/you/Library/Application Support/NotchBuddy/Jobs/"
        var research = JobRecord(id: "job-leads", title: "Find the website and LinkedIn page for 120 leads",
                                 instruction: "For every company in ~/Documents/leads.xlsx, find its website, LinkedIn page and employee count, and fill in the empty columns.",
                                 status: .running, folder: folder + "job-leads")
        research.createdAt = now.addingTimeInterval(-26 * 60)
        research.updatedAt = now.addingTimeInterval(-8)
        let recipe = [
            RecipeStep(id: 21, title: "Searching the web", instruction: "Find the company's website", route: .web, outputFields: ["website"]),
            RecipeStep(id: 22, title: "Reading LinkedIn", instruction: "Open the LinkedIn page and read the size", route: .browser, outputFields: ["linkedin", "employees"]),
        ]
        research.plan = JobPlan(goal: "Fill in website, LinkedIn and size for every lead", milestones: [
            Milestone(id: 1, title: "Read the lead list", steps: [
                JobStep(id: 1, title: "Reading leads.xlsx", kind: .action(RecipeStep(id: 1, title: "Reading leads.xlsx", instruction: "", route: .data))),
            ]),
            Milestone(id: 2, title: "Research each company", description: "Web search first, then the company's LinkedIn page in a background tab.", steps: [
                JobStep(id: 2, title: "Researching companies", kind: .forEach(ForEachSpec(
                    source: .file(path: "~/Documents/leads.xlsx", sheet: nil, column: "Company", hasHeader: true), itemLabel: "company",
                    recipe: recipe, parallelism: 4, outputTable: "companies", outputColumns: ["website", "linkedin", "employees"],
                    writeBack: WriteBack(path: "~/Documents/leads.xlsx", keyColumn: "Company", columns: ["website", "linkedin", "employees"])))),
                JobStep(id: 3, title: "Saving results to leads.xlsx", kind: .action(RecipeStep(id: 3, title: "Saving results", instruction: "", route: .data))),
            ]),
            Milestone(id: 3, title: "Share the summary", steps: [
                JobStep(id: 4, title: "Writing the summary", kind: .action(RecipeStep(id: 4, title: "Writing the summary", instruction: "", route: .answer))),
                JobStep(id: 5, title: "Emailing it to the sales team", kind: .action(RecipeStep(id: 5, title: "Emailing the summary", instruction: "", route: .composio, risk: .high))),
            ], requiresApproval: true),
        ], outputs: "leads.xlsx with three new columns")
        research.cursor.milestoneIndex = 1
        research.cursor.stepIndex = 0
        research.usage.itemsTotal = 120
        research.usage.itemsDone = 37
        research.usage.itemsFailed = 2
        research.usage.modelCalls = 214
        research.usage.inputTokens = 412_300
        research.usage.outputTokens = 38_900
        research.usage.costUSD = 1.42
        research.usage.toolCalls = 318
        research.usage.activeSeconds = 24 * 60 + 40
        research.statusLine = "Researching companies · 39/120 · 2 failed"

        let companies: [(String, ItemStatus, [String: JSONValue]?, String?)] = [
            ("Northwind Traders", .done, ["website": "northwind.com", "linkedin": "linkedin.com/company/northwind", "employees": 480], nil),
            ("Contoso Pharmaceuticals", .done, ["website": "contoso-pharma.com", "linkedin": "linkedin.com/company/contoso", "employees": 2300], nil),
            ("Fabrikam Robotics", .done, ["website": "fabrikam.ai", "linkedin": "linkedin.com/company/fabrikam-robotics", "employees": 95], nil),
            ("Tailspin Toys", .failed, nil, "No official website found; two unrelated shops share the name."),
            ("Wide World Importers", .done, ["website": "wideworldimporters.com", "linkedin": "linkedin.com/company/wwi", "employees": 1200], nil),
            ("Adventure Works Cycles", .running, nil, nil),
            ("Lucerne Publishing", .running, nil, nil),
            ("Margie's Travel", .failed, nil, "LinkedIn asked to sign in again. Open Chrome and sign in, then retry."),
            ("Proseware", .pending, nil, nil),
            ("Woodgrove Bank", .pending, nil, nil),
        ]
        let items = companies.enumerated().map { i, c in
            var item = JobItem(jobID: research.id, stepID: 2, index: i, title: c.0, input: ["Company": .string(c.0)])
            item.status = c.1
            item.result = c.2.map { .object($0) }
            item.error = c.3
            item.attempts = c.1 == .failed ? 2 : (c.1 == .pending ? 0 : 1)
            return item
        }
        let events: [ActivityEntry] = [
            ActivityEntry(kind: .plan, title: "Planned 3 milestones · 120 companies"),
            ActivityEntry(kind: .step, title: "Reading leads.xlsx", route: .data),
            ActivityEntry(kind: .tool, title: "sheet.read leads.xlsx", detail: "120 rows · Company, Contact, Email, website, linkedin, employees", route: .data, success: true, durationMs: 84),
            ActivityEntry(kind: .step, title: "Researching companies", route: .web),
            ActivityEntry(kind: .tool, title: "web.search “Northwind Traders official site”", detail: "8 results", route: .web, success: true, durationMs: 910),
            ActivityEntry(kind: .tool, title: "browser.open linkedin.com/company/northwind", detail: "Background tab", route: .browser, success: true, durationMs: 1430),
            ActivityEntry(kind: .error, title: "Margie's Travel failed", detail: "LinkedIn asked to sign in again."),
            ActivityEntry(kind: .info, title: "Saved 10 results to leads.xlsx", route: .data, success: true),
        ]

        var confirm = JobRecord(id: "job-photos", title: "Rename 340 trip photos by the date they were taken",
                                instruction: "Rename every photo in ~/Pictures/Lisbon to YYYY-MM-DD-HHMM using the date taken.",
                                status: .awaitingConfirmation, folder: folder + "job-photos")
        confirm.updatedAt = now.addingTimeInterval(-3)
        confirm.plan = JobPlan(goal: "Rename the photos", milestones: [
            Milestone(id: 1, title: "Rename the photos", steps: [
                JobStep(id: 1, title: "Renaming photos", kind: .forEach(ForEachSpec(source: .list([]), itemLabel: "photo",
                    recipe: [RecipeStep(id: 11, title: "Renaming", instruction: "", route: .command)], parallelism: 4, outputTable: "photos"))),
            ]),
        ], estimate: JobEstimate(items: 340, modelCalls: 520, minutes: 22, costUSD: 0.64, notes: "Runs with commands only; your screen stays free."))

        var daily = JobRecord(id: "job-status", title: "Every morning, check the status page and post changes",
                              instruction: "Every day at 9:00, check status.acme.com and post any change to #ops.", status: .waiting, folder: folder + "job-status")
        daily.updatedAt = now.addingTimeInterval(-3 * 3600)
        let tomorrow9 = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now.addingTimeInterval(86_400)) ?? now.addingTimeInterval(86_400)
        daily.nextWakeAt = tomorrow9
        daily.statusLine = "Checked 4 times · next check tomorrow at 9:00"

        var finished = JobRecord(id: "job-prices", title: "Check 25 supplier sites for price changes",
                                 instruction: "Check the 25 supplier pages in suppliers.csv and note any price change.", status: .completed, folder: folder + "job-prices")
        finished.updatedAt = now.addingTimeInterval(-60)
        finished.usage.itemsTotal = 25
        finished.usage.itemsDone = 25
        finished.summary = "3 suppliers raised prices (largest: Fabrikam +6%). Results are in suppliers.csv and report.md."

        let source = PreviewJobs()
        source.jobs = [research, confirm, daily, finished]
        source.itemsByJob = [research.id: items]
        source.eventsByJob = [research.id: events]
        source.reports = [research.id: """
            # Lead research — progress so far
            Researched **39 of 120** companies. Results are written back to `leads.xlsx` every 10 companies.
            ## Notes
            - Two companies failed: one has no clear website, one needs a fresh LinkedIn sign-in.
            - Most companies have 100–2,500 employees.
            """]
        let approval = ApprovalRequest(kind: .tool, title: "Email the lead summary to sales@acme.com",
                                       detail: "Sends one email with the summary and leads.xlsx attached, through your Gmail.",
                                       appName: "Gmail", risk: .high, reasons: ["sends email"])
        return Demo(source: source, research: research, confirm: confirm, daily: daily, finished: finished, approval: approval)
    }
}

/// `Glide --snapshot-settings <dir>` renders the settings window and onboarding to PNG in
/// light and dark mode, using demo settings in memory: no Keychain access, no network, no
/// MCP servers launched, and the user's own settings are never read or written.
@MainActor
enum SettingsSnapshotRenderer {
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        CredentialStore.shared.useMemoryOnly([.provider("anthropic"): "sk-ant-demo-000000000000a1B2"])
        let suite = "dev.glide.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
        store.settings.providers[0].lastTestOK = true
        store.settings.providers[0].models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        var fs = MCPPreset.catalog[0].config
        var gh = MCPPreset.catalog.first { $0.name == "GitHub" }!.config
        gh.secretHeaders = ["Authorization"]
        var broken = MCPServerConfig(name: "Linear", transport: .http)
        broken.url = "https://mcp.linear.app/mcp"
        fs.id = "fs"; gh.id = "gh"; broken.id = "linear"
        store.settings.mcpServers = [fs, gh, broken]
        let mcpStatus: [String: (Bool, Int, String?)] = ["fs": (true, 14, nil), "gh": (true, 41, nil), "linear": (false, 0, "401 Unauthorized: add a bearer token")]
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let nav = SettingsNavigation()
        let jobs = PreviewJobs.demo().source
        let browser = BrowserSettingsPreview(
            status: BrowserStatus(backend: .extensionBridge, connected: false, detail: "Not connected", chromeInstalled: true, extensionPaired: false),
            pairing: BrowserPairingInfo(token: "demo", port: 47823, extensionFolder: URL(fileURLWithPath: "/Applications/Glide.app/Contents/Resources/ChromeExtension"),
                                        extensionID: "demo", pairingURL: URL(string: "chrome-extension://demo/pair.html")))
        func settings(_ section: SettingsSection, _ name: String, height: CGFloat = 640, dark: Bool = false, tab: IntegrationsSettingsView.Tab = .apps) {
            nav.select(section)
            let root = SettingsRootView(nav: nav, store: store, onHotkeysChanged: {}, hotkeyConflicts: { [:] }, jobs: jobs, browserPreview: browser)
            // Swap the integrations page for one with snapshot hooks.
            let view = Group {
                if section == .integrations {
                    SettingsPageFrame(nav: nav) { IntegrationsSettingsView(store: store, initialTab: tab, previewMCPStatus: mcpStatus) }
                } else {
                    root
                }
            }
            render(view, size: CGSize(width: 920, height: height), dark: dark, to: "\(dir)/settings-\(name)\(dark ? "-dark" : "").png")
        }
        settings(.general, "general")
        settings(.providers, "providers", height: 900)
        settings(.providers, "providers", height: 900, dark: true)
        settings(.models, "models")
        settings(.integrations, "integrations-apps", height: 1180)
        settings(.integrations, "integrations-apps", height: 1180, dark: true)
        settings(.integrations, "integrations-mcp", height: 1000, tab: .mcp)
        settings(.integrations, "integrations-mcp", height: 1000, dark: true, tab: .mcp)
        settings(.safety, "safety", height: 960)
        settings(.permissions, "permissions")
        settings(.speed, "speed", height: 900)
        settings(.speed, "speed", height: 900, dark: true)
        settings(.browser, "browser", height: 980)
        settings(.browser, "browser", height: 980, dark: true)
        settings(.jobs, "jobs", height: 1360)
        settings(.jobs, "jobs", height: 1360, dark: true)
        for (step, dark) in [(0, false), (1, false), (1, true), (2, false), (3, false)] {
            render(OnboardingView(store: store, initialStep: step) { _ in }, size: CGSize(width: 640, height: 540), dark: dark,
                   to: "\(dir)/onboarding-\(step)\(dark ? "-dark" : "").png")
        }
        render(ComposioKeySheet(app: AppIntegration.catalog[0], onSave: { _ in }, onCancel: {}), size: CGSize(width: 460, height: 330), dark: false,
               to: "\(dir)/sheet-composio-key.png")
    }

    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, to path: String) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("wrote \((path as NSString).lastPathComponent)")
        }
        window.contentView = nil
    }
}
