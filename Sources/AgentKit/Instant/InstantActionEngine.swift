import Foundation

/// What an instant action will do, decided before doing anything — so the same plan serves
/// both the real handler and `glidectl say --dry-run`.
public struct InstantPlan: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case openApp, openSite, search, play
    }

    public enum Target: Sendable, Hashable {
        case app(InstalledApp)
        case page(URL)
    }

    public var kind: Kind
    public var target: Target
    /// What Glide calls it out loud: "ChatGPT", "Amazon", "example.com".
    public var name: String
    /// The search query, for `.search` and `.play`.
    public var query: String?
    public var ack: String
    public var summary: String
    /// Left for the planner, in the user's own casing where it could be recovered.
    public var remainder: String?
    /// True when Jev picked the reading (no rule matched).
    public var viaAssist: Bool

    public var url: URL? {
        if case .page(let u) = target { return u }
        return nil
    }

    public var bundleID: String? {
        if case .app(let a) = target { return a.bundleID }
        return nil
    }
}

/// Handles "open ChatGPT", "search Amazon for socks", "play lo-fi on YouTube" and their
/// compound forms with no model: read the phrasing, resolve it against this Mac's apps and a
/// catalog of sites, start opening, and hand back what to say. Typical cost is well under a
/// millisecond to resolve; opening is started, not awaited, unless the planner continues
/// after it and needs the app or tab in front first.
public final class InstantActionEngine: Sendable {
    public let resolver: AppResolver
    let opener: any InstantOpening
    let browser: any InstantBrowsing
    let settings: @Sendable () -> AppSettings
    let classifier: @Sendable (AppSettings) -> (any InstantIntentClassifying)?
    /// Await the opening even when nothing follows it (tests, so fakes see every call).
    let waitForOpen: Bool
    let assistTimeout: TimeInterval

    /// Jev must be at least this sure before Glide acts on its reading.
    public static let assistConfidence = 0.9
    /// Longer phrasing is a task, not an unclear name; Jev isn't asked.
    public static let assistMaxWords = 8

    public init(index: any AppIndexing, opener: any InstantOpening, browser: any InstantBrowsing,
                settings: @escaping @Sendable () -> AppSettings,
                classifier: @escaping @Sendable (AppSettings) -> (any InstantIntentClassifying)? = { _ in nil },
                waitForOpen: Bool = false, assistTimeout: TimeInterval = 1.2) {
        self.resolver = AppResolver(index: index)
        self.opener = opener
        self.browser = browser
        self.settings = settings
        self.classifier = classifier
        self.waitForOpen = waitForOpen
        self.assistTimeout = assistTimeout
    }

    /// The engine the app installs: this Mac's apps, NSWorkspace, Glide's browser, saved settings.
    public static func live() -> InstantActionEngine {
        InstantActionEngine(index: SystemAppIndex.shared, opener: SystemInstantOpener(),
                            browser: HubInstantBrowser(settings: { SettingsStore.loadSnapshot().browser }),
                            settings: { SettingsStore.loadSnapshot() },
                            classifier: { JevInstantClassifier.configured(settings: $0) })
    }

    // MARK: Handling

    public func handle(_ utterance: String) async -> InstantResult? {
        let s = settings()
        guard let plan = await plan(utterance, settings: s, useAssist: true) else { return nil }
        return await perform(plan, settings: s)
    }

    /// What `utterance` would do, without doing it or asking Jev. For `glidectl say --dry-run`.
    public func describe(_ utterance: String) async -> String {
        let start = DispatchTime.now()
        let p = await plan(utterance, settings: settings(), useAssist: false)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        guard let p else {
            return "Not instant — the planner would handle this. (decided in \(String(format: "%.1f", ms)) ms; Jev not asked in a dry run)"
        }
        var lines: [String] = []
        switch p.target {
        case .app(let a): lines.append("\(p.kind.rawValue): \(p.name) (\(a.bundleID)\(a.isRunning ? ", running" : ""))")
        case .page(let u): lines.append("\(p.kind.rawValue): \(u.absoluteString)")
        }
        lines.append("say: \(p.ack)")
        if let r = p.remainder { lines.append("then the planner does: \(r)") }
        lines.append("resolved in \(String(format: "%.1f", ms)) ms")
        return lines.joined(separator: "\n")
    }

    // MARK: Planning

    public func plan(_ utterance: String, useAssist: Bool = true) async -> InstantPlan? {
        await plan(utterance, settings: settings(), useAssist: useAssist)
    }

    func plan(_ utterance: String, settings: AppSettings, useAssist: Bool) async -> InstantPlan? {
        let readings = InstantIntentRouter.parse(utterance)
        for r in readings {
            if let p = resolve(r, original: utterance) { return p }
        }
        guard useAssist, readings.isEmpty, let classifier = classifier(settings) else { return nil }
        let s = InstantIntentRouter.normalize(utterance)
        let words = s.split(separator: " ").map(String.init)
        guard (1...Self.assistMaxWords).contains(words.count), !words.contains(where: { InstantIntentRouter.workWords.contains($0) })
        else { return nil }
        guard let guess = await InstantAssist.guess(classifier, s, timeout: assistTimeout), guess.confidence >= Self.assistConfidence
        else { return nil }
        let intent: InstantIntent
        switch guess.kind {
        case .openApp: intent = .open(target: s, prefer: .app)
        case .openWebsite: intent = .open(target: s, prefer: .web)
        case .searchSite:
            guard let (site, q) = InstantIntentRouter.leadingSite(s), !q.isEmpty else { return nil }
            intent = .search(query: q.hasPrefix("for ") ? String(q.dropFirst(4)) : q, site: site)
        case .other: return nil
        }
        guard var p = resolve(InstantParse(intent: intent, remainder: nil), original: utterance) else { return nil }
        p.viaAssist = true
        return p
    }

    enum OpenTarget {
        case app(InstalledApp)
        case site(KnownSite)
        case url(URL)
    }

    /// "ChatGPT" → the desktop app when installed, else chatgpt.com. Exact names and aliases
    /// beat the site catalog ("open Notes" is the app); the catalog beats fuzzy app matches
    /// ("open Google" is google.com, not Google Chrome); an ambiguous name resolves to nothing.
    func resolveOpen(_ target: String, prefer: OpenPreference) -> OpenTarget? {
        if let url = SiteCatalog.webURL(from: target) { return .url(url) }
        let site = SiteCatalog.site(named: target)
        switch prefer {
        case .web:
            return site.map { .site($0) }
        case .app:
            if case .found(let app, _) = resolver.resolve(target) { return .app(app) }
            return nil
        case .any:
            let resolution = resolver.resolve(target)
            if case .found(let app, let confidence) = resolution, confidence >= 0.95 { return .app(app) }
            if let site {
                for id in site.appBundleIDs {
                    if let app = resolver.index.apps().first(where: { $0.bundleID == id }) { return .app(app) }
                }
                return .site(site)
            }
            if case .found(let app, _) = resolution { return .app(app) }
            return nil
        }
    }

    func resolve(_ reading: InstantParse, original: String) -> InstantPlan? {
        switch reading.intent {
        case .search(let query, let siteName):
            guard let site = SiteCatalog.site(named: siteName) else { return nil }
            return searchPlan(site: site, query: query, remainder: reading.remainder, original: original)
        case .play(let query):
            return playPlan(query: query, remainder: reading.remainder, original: original)
        case .open(let target, let prefer):
            guard let resolved = resolveOpen(target, prefer: prefer) else { return nil }
            switch resolved {
            case .app(let app):
                let name = Self.spokenName(app)
                let verb = app.isRunning ? "Switching to" : "Opening"
                return InstantPlan(kind: .openApp, target: .app(app), name: name, query: nil, ack: "\(verb) \(name).",
                                   summary: "Opened \(name).", remainder: casing(reading.remainder, in: original), viaAssist: false)
            case .site(let site):
                // "Open Amazon and search for socks" is one search, not an open plus a model call.
                if let rest = reading.remainder {
                    let (head, after) = Self.firstStep(rest)
                    if site.name == "YouTube", let q = InstantIntentRouter.playQuery(inTail: head) {
                        return playPlan(query: q, remainder: after, original: original)
                    }
                    if site.searchTemplate != nil, let q = InstantIntentRouter.searchQuery(inTail: head) {
                        return searchPlan(site: site, query: q, remainder: after, original: original)
                    }
                }
                return InstantPlan(kind: .openSite, target: .page(site.url), name: site.name, query: nil, ack: "Opening \(site.name).",
                                   summary: "Opened \(site.name) (\(site.host)).", remainder: casing(reading.remainder, in: original), viaAssist: false)
            case .url(let url):
                let host = (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "")
                let name = SiteCatalog.site(forHost: host)?.name ?? host
                return InstantPlan(kind: .openSite, target: .page(url), name: name, query: nil, ack: "Opening \(name).",
                                   summary: "Opened \(url.absoluteString).", remainder: casing(reading.remainder, in: original), viaAssist: false)
            }
        }
    }

    func searchPlan(site: KnownSite, query: String, remainder: String?, original: String) -> InstantPlan? {
        let q = casing(query, in: original) ?? query
        guard let url = site.searchURL(q) else { return nil }
        return InstantPlan(kind: .search, target: .page(url), name: site.name, query: q, ack: "Searching \(site.name) for \(q).",
                           summary: "Searched \(site.name) for “\(q)”.", remainder: casing(remainder, in: original), viaAssist: false)
    }

    /// YouTube search results open instantly; picking the video is the planner's (one click).
    func playPlan(query: String, remainder: String?, original: String) -> InstantPlan? {
        let q = casing(query, in: original) ?? query
        guard let youtube = SiteCatalog.site(named: "youtube"), let url = youtube.searchURL(q) else { return nil }
        var rest = "Play the top YouTube result for “\(q)”."
        if let more = casing(remainder, in: original) { rest += " Then: \(more)" }
        return InstantPlan(kind: .play, target: .page(url), name: "YouTube", query: q, ack: "Finding \(q) on YouTube.",
                           summary: "Searched YouTube for “\(q)” to play it.", remainder: rest, viaAssist: false)
    }

    /// The first step of a compound tail and what follows it.
    static func firstStep(_ tail: String) -> (String, String?) {
        if let (head, rest) = InstantIntentRouter.splits(tail).first { return (head, InstantIntentRouter.normalizeTail(rest)) }
        return (tail, nil)
    }

    /// `text` as the user typed or said it (capitals, symbols), when it can be found again in
    /// the original; the normalized form otherwise.
    func casing(_ text: String?, in original: String) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if let r = original.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) { return String(original[r]) }
        return text
    }

    /// Names some bundles carry that nobody says ("zoom.us").
    static let friendlyNames: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.VSCode": "VS Code", "com.microsoft.teams2": "Teams", "com.hnc.Discord": "Discord",
    ]

    static func spokenName(_ app: InstalledApp) -> String {
        friendlyNames[app.bundleID] ?? app.name
    }

    // MARK: Doing

    func perform(_ plan: InstantPlan, settings: AppSettings) async -> InstantResult? {
        let continues = plan.remainder != nil
        var context: String
        switch plan.target {
        case .app(let app):
            guard await opener.open(app: app) else { return nil }
            if continues || waitForOpen {
                let front = await opener.waitUntilFront(bundleID: app.bundleID, timeout: continues ? 8 : 3)
                context = front ? "\(plan.name) (desktop app) is open and in front."
                    : "\(plan.name) (desktop app) was opened but isn't in front yet."
            } else {
                // Confirm (and nudge once) in the background; the user already heard the ack.
                let opener = opener
                Task { _ = await opener.waitUntilFront(bundleID: app.bundleID, timeout: 5) }
                context = "\(plan.name) (desktop app) is open and in front."
            }
        case .page(let url):
            var where_ = "the default browser"
            if await browser.isConnected() {
                if continues || waitForOpen {
                    do {
                        try await browser.openForegroundTab(url)
                        where_ = "Glide's browser, as this task's current tab"
                    } catch {
                        guard await opener.open(url: url) else { return nil }
                    }
                } else {
                    let browser = browser, opener = opener
                    Task {
                        do { try await browser.openForegroundTab(url) } catch { _ = await opener.open(url: url) }
                    }
                    where_ = "Glide's browser, as this task's current tab"
                }
            } else {
                guard await opener.open(url: url) else { return nil }
            }
            switch plan.kind {
            case .search, .play:
                context = "\(plan.name) search results for “\(plan.query ?? "")” are open in \(where_) (\(url.absoluteString))."
            default:
                context = "\(plan.name) (\(url.absoluteString)) is open in \(where_)."
            }
        }
        var followUp: AgentQuestion?
        if !continues, settings.conversation.offerNextStep, plan.kind == .openApp || plan.kind == .openSite {
            let prep = plan.kind == .openApp ? "in" : "on"
            followUp = AgentQuestion(text: "Want me to do anything \(prep) \(plan.name)?", lowRisk: true)
        }
        return InstantResult(ack: plan.ack, summary: plan.summary, followUp: followUp, remainder: plan.remainder,
                             context: continues ? context : nil)
    }
}
