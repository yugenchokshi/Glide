import Testing
import Foundation
@testable import AgentKit

// Instant actions, offline: the phrasing rules, the app resolver against a fixed app list, the
// site catalog's URLs, and the engine with fake opener, browser and Jev — nothing is launched,
// opened or sent anywhere.

// MARK: - Fakes

struct InstantFakeIndex: AppIndexing {
    var list: [InstalledApp]
    func apps() -> [InstalledApp] { list }

    static let standard = InstantFakeIndex(list: [
        InstalledApp(name: "ChatGPT", bundleID: "com.openai.chat"),
        InstalledApp(name: "Claude", bundleID: "com.anthropic.claudefordesktop"),
        InstalledApp(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", otherNames: ["Code"]),
        InstalledApp(name: "Google Chrome", bundleID: "com.google.Chrome"),
        InstalledApp(name: "System Settings", bundleID: "com.apple.systempreferences"),
        InstalledApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp"),
        InstalledApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", isRunning: true),
        InstalledApp(name: "Notion", bundleID: "notion.id"),
        InstalledApp(name: "Notion Calendar", bundleID: "com.cron.electron"),
        InstalledApp(name: "Spotify", bundleID: "com.spotify.client"),
        InstalledApp(name: "zoom.us", bundleID: "us.zoom.xos"),
        InstalledApp(name: "Microsoft Teams", bundleID: "com.microsoft.teams2"),
        InstalledApp(name: "Mail", bundleID: "com.apple.mail"),
        InstalledApp(name: "Messages", bundleID: "com.apple.MobileSMS"),
        InstalledApp(name: "Calendar", bundleID: "com.apple.iCal"),
        InstalledApp(name: "Notes", bundleID: "com.apple.Notes"),
        InstalledApp(name: "Finder", bundleID: "com.apple.finder", isRunning: true),
        InstalledApp(name: "Terminal", bundleID: "com.apple.Terminal"),
        InstalledApp(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        InstalledApp(name: "Safari", bundleID: "com.apple.Safari"),
        InstalledApp(name: "Photos", bundleID: "com.apple.Photos"),
        InstalledApp(name: "Photo Booth", bundleID: "com.apple.PhotoBooth"),
        InstalledApp(name: "Android Studio", bundleID: "com.google.android.studio"),
        InstalledApp(name: "Maps", bundleID: "com.apple.Maps"),
        InstalledApp(name: "Weather", bundleID: "com.apple.weather"),
        InstalledApp(name: "Microsoft Word", bundleID: "com.microsoft.Word"),
        InstalledApp(name: "TextEdit", bundleID: "com.apple.TextEdit"),
    ])
}

final class InstantFakeOpener: InstantOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _apps: [String] = []
    private var _urls: [URL] = []
    var front = true

    var apps: [String] { lock.withLock { _apps } }
    var urls: [URL] { lock.withLock { _urls } }

    func open(app: InstalledApp) async -> Bool {
        lock.withLock { _apps.append(app.bundleID) }
        return true
    }
    func waitUntilFront(bundleID: String, timeout: TimeInterval) async -> Bool { front }
    func open(url: URL) async -> Bool {
        lock.withLock { _urls.append(url) }
        return true
    }
}

final class InstantFakeBrowser: InstantBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var _tabs: [URL] = []
    let connected: Bool
    let fails: Bool
    var tabs: [URL] { lock.withLock { _tabs } }

    init(connected: Bool, fails: Bool = false) {
        self.connected = connected
        self.fails = fails
    }

    func isConnected() async -> Bool { connected }
    func openForegroundTab(_ url: URL) async throws {
        if fails { throw URLError(.cannotConnectToHost) }
        lock.withLock { _tabs.append(url) }
    }
}

final class InstantFakeClassifier: InstantIntentClassifying, @unchecked Sendable {
    let guess: InstantGuess
    let delay: Duration
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }

    init(_ kind: InstantGuessKind, _ confidence: Double, delay: Duration = .zero) {
        guess = InstantGuess(kind: kind, confidence: confidence)
        self.delay = delay
    }

    func classify(_ utterance: String) async throws -> InstantGuess {
        lock.withLock { _calls += 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        return guess
    }
}

struct InstantRig {
    let opener = InstantFakeOpener()
    let browser: InstantFakeBrowser
    let engine: InstantActionEngine

    init(index: InstantFakeIndex = .standard, browserConnected: Bool = false, browserFails: Bool = false,
         settings: AppSettings = AppSettings(), classifier: InstantFakeClassifier? = nil, assistTimeout: TimeInterval = 1.2) {
        let browser = InstantFakeBrowser(connected: browserConnected, fails: browserFails)
        self.browser = browser
        engine = InstantActionEngine(index: index, opener: opener, browser: browser, settings: { settings },
                                     classifier: { _ in classifier }, waitForOpen: true, assistTimeout: assistTimeout)
    }
}

// MARK: - The utterance table

enum InstantExpect: Sendable, CustomStringConvertible {
    case app(String, remainder: String? = nil)
    case url(String, remainder: String? = nil)
    /// A URL plus a remainder that starts with this text.
    case urlThen(String, remainderPrefix: String)
    case planner

    var description: String {
        switch self {
        case .app(let id, let r): return "app \(id) rest \(r ?? "-")"
        case .url(let u, let r): return "url \(u) rest \(r ?? "-")"
        case .urlThen(let u, let r): return "url \(u) then \(r)…"
        case .planner: return "planner"
        }
    }
}

let instantTable: [(String, InstantExpect)] = [
    // Apps, voice-style.
    ("open chatgpt", .app("com.openai.chat")),
    ("Hey Glide, can you open up chat gpt for me please?", .app("com.openai.chat")),
    ("  Open   ChatGPT.  ", .app("com.openai.chat")),
    ("um open uh chatgpt", .app("com.openai.chat")),
    ("open chat gtp", .app("com.openai.chat")),
    ("open claude", .app("com.anthropic.claudefordesktop")),
    ("could you launch vs code", .app("com.microsoft.VSCode")),
    ("open vscode real quick", .app("com.microsoft.VSCode")),
    ("switch to slack", .app("com.tinyspeck.slackmacgap")),
    ("bring up system settings", .app("com.apple.systempreferences")),
    ("open settings", .app("com.apple.systempreferences")),
    ("start spotify", .app("com.spotify.client")),
    ("open zoom", .app("us.zoom.xos")),
    ("open teams", .app("com.microsoft.teams2")),
    ("show me my calendar", .app("com.apple.iCal")),
    ("open the notes app", .app("com.apple.Notes")),
    ("go to finder", .app("com.apple.finder")),
    ("open terminal real quick", .app("com.apple.Terminal")),
    ("please open xcode", .app("com.apple.dt.Xcode")),
    ("open chrome", .app("com.google.Chrome")),
    ("open whatsapp", .app("net.whatsapp.WhatsApp")),
    ("open notion", .app("notion.id")),
    ("open notion calendar", .app("com.cron.electron")),
    ("open mesages", .app("com.apple.MobileSMS")),
    ("open text edit", .app("com.apple.TextEdit")),
    ("open microsoft word", .app("com.microsoft.Word")),
    ("pull up maps", .app("com.apple.Maps")),
    ("Open ChatGPT app", .app("com.openai.chat")),
    // Websites.
    ("open chatgpt.com", .url("https://chatgpt.com")),
    ("open the chatgpt website", .url("https://chatgpt.com/")),
    ("go to github dot com", .url("https://github.com")),
    ("open https://example.org/path?x=1", .url("https://example.org/path?x=1")),
    ("visit www.apple.com", .url("https://www.apple.com")),
    ("open youtube", .url("https://www.youtube.com/")),
    ("go to amazon", .url("https://www.amazon.com/")),
    ("open gmail", .url("https://mail.google.com/")),
    ("open google maps", .url("https://www.google.com/maps")),
    ("take me to google flights", .url("https://www.google.com/travel/flights")),
    ("open linkedin", .url("https://www.linkedin.com/")),
    ("open airbnb please", .url("https://www.airbnb.com/")),
    ("go to reddit", .url("https://www.reddit.com/")),
    ("open netflix", .url("https://www.netflix.com/")),
    ("open twitter", .url("https://x.com/")),
    ("open google", .url("https://www.google.com/")),
    ("visit wikipedia", .url("https://en.wikipedia.org/")),
    // Searches.
    ("search amazon for socks", .url("https://www.amazon.com/s?k=socks")),
    ("can you search for wireless headphones on amazon", .url("https://www.amazon.com/s?k=wireless%20headphones")),
    ("youtube search lofi beats", .url("https://www.youtube.com/results?search_query=lofi%20beats")),
    ("look up quantum computing on wikipedia", .url("https://en.wikipedia.org/w/index.php?search=quantum%20computing")),
    ("look tacos up on yelp", .url("https://www.yelp.com/search?find_desc=tacos")),
    ("google best pizza near me", .url("https://www.google.com/search?q=best%20pizza%20near%20me")),
    ("search github for swift concurrency", .url("https://github.com/search?q=swift%20concurrency")),
    ("search for flights to tokyo on google flights", .url("https://www.google.com/travel/flights?q=flights%20to%20tokyo")),
    ("search for AT&T on google", .url("https://www.google.com/search?q=AT%26T")),
    ("play lofi hip hop on youtube", .urlThen("https://www.youtube.com/results?search_query=lofi%20hip%20hop", remainderPrefix: "Play the top YouTube result")),
    // Compound requests.
    ("open chatgpt and ask it about the weather", .app("com.openai.chat", remainder: "ask it about the weather")),
    ("Open Slack, then message John that I'm late", .app("com.tinyspeck.slackmacgap", remainder: "message John that I'm late")),
    ("open notes and write a shopping list", .app("com.apple.Notes", remainder: "write a shopping list")),
    ("open amazon and search for socks", .url("https://www.amazon.com/s?k=socks")),
    ("go to amazon and search for socks and add the cheapest pair to my cart",
     .url("https://www.amazon.com/s?k=socks", remainder: "add the cheapest pair to my cart")),
    ("open youtube and play taylor swift", .urlThen("https://www.youtube.com/results?search_query=taylor%20swift", remainderPrefix: "Play the top YouTube result")),
    ("search amazon for socks and buy the cheapest", .url("https://www.amazon.com/s?k=socks", remainder: "buy the cheapest")),
    // Real work, questions and unsafe targets: the planner's.
    ("add socks on amazon", .planner),
    ("buy socks on amazon", .planner),
    ("send an email to mom", .planner),
    ("delete my downloads folder", .planner),
    ("what's the weather today", .planner),
    ("open my last email", .planner),
    ("open the file report.pdf", .planner),
    ("open file:///etc/passwd", .planner),
    ("open javascript:alert(1)", .planner),
    ("go to slack://open", .planner),
    ("open studio", .planner),
    ("open photo", .planner),
    ("start a new document", .planner),
    ("search for socks", .planner),
    ("play some music", .planner),
    ("open something", .planner),
    ("close slack", .planner),
    ("tell me a joke", .planner),
    ("reply to the last message", .planner),
    ("open chatgpt in safari", .planner),
    ("schedule a meeting with sarah tomorrow", .planner),
    ("open the settings for wifi", .planner),
    ("", .planner),
]

@Suite struct InstantActionsTableTests {
    @Test func tableIsBigEnough() {
        #expect(instantTable.count >= 50)
    }

    @Test(arguments: instantTable.indices)
    func utterance(_ i: Int) async {
        let (text, expect) = instantTable[i]
        let rig = InstantRig()
        let plan = await rig.engine.plan(text, useAssist: false)
        switch expect {
        case .planner:
            #expect(plan == nil, "“\(text)” should go to the planner, got \(String(describing: plan))")
        case .app(let id, let remainder):
            #expect(plan?.bundleID == id, "“\(text)” → \(String(describing: plan?.bundleID)) / \(String(describing: plan?.url))")
            #expect(plan?.remainder == remainder, "“\(text)” remainder \(String(describing: plan?.remainder))")
        case .url(let url, let remainder):
            #expect(plan?.url?.absoluteString == url, "“\(text)” → \(String(describing: plan?.url)) / \(String(describing: plan?.bundleID))")
            #expect(plan?.remainder == remainder, "“\(text)” remainder \(String(describing: plan?.remainder))")
        case .urlThen(let url, let prefix):
            #expect(plan?.url?.absoluteString == url, "“\(text)” → \(String(describing: plan?.url))")
            #expect(plan?.remainder?.hasPrefix(prefix) == true, "“\(text)” remainder \(String(describing: plan?.remainder))")
        }
    }
}

// MARK: - Router and catalog details

@Suite struct InstantRouterTests {
    @Test func normalizeStripsFillersAndPunctuation() {
        #expect(InstantIntentRouter.normalize("Hey Glide, could you please open ChatGPT for me, thanks!") == "open chatgpt")
        #expect(InstantIntentRouter.normalize("um, so, uh, open   chatgpt.com.") == "open chatgpt.com")
        #expect(InstantIntentRouter.normalize("I want to buy socks") == "buy socks")
    }

    @Test func webURLsAreHTTPOnly() {
        #expect(SiteCatalog.webURL(from: "chatgpt.com")?.absoluteString == "https://chatgpt.com")
        #expect(SiteCatalog.webURL(from: "http://example.com")?.scheme == "http")
        #expect(SiteCatalog.webURL(from: "file:///etc/passwd") == nil)
        #expect(SiteCatalog.webURL(from: "javascript:alert(1)") == nil)
        #expect(SiteCatalog.webURL(from: "slack://open") == nil)
        #expect(SiteCatalog.webURL(from: "x-apple.systempreferences:com.apple.preference") == nil)
        #expect(SiteCatalog.webURL(from: "https://user:pw@example.com") == nil)
        #expect(SiteCatalog.webURL(from: "report.pdf") == nil)
        #expect(SiteCatalog.webURL(from: "two words.com") == nil)
    }

    @Test func everyCatalogEntryHasAWebURLAndAWorkingSearch() {
        for site in Set(SiteCatalog.byName.values) {
            #expect(site.url.scheme == "https", "\(site.name)")
            if site.searchTemplate != nil {
                #expect(site.searchURL("red socks")?.absoluteString.contains("red%20socks") == true, "\(site.name)")
            }
        }
    }
}

// MARK: - Resolver

@Suite struct AppResolverTests {
    let resolver = AppResolver(index: InstantFakeIndex.standard)

    func id(_ s: String) -> String? {
        if case .found(let app, _) = resolver.resolve(s) { return app.bundleID }
        return nil
    }

    @Test func aliasesAndNormalizedNames() {
        #expect(id("chat gpt") == "com.openai.chat")
        #expect(id("Chat-GPT") == "com.openai.chat")
        #expect(id("vs code") == "com.microsoft.VSCode")
        #expect(id("code") == "com.microsoft.VSCode")
        #expect(id("settings") == "com.apple.systempreferences")
        #expect(id("system preferences") == "com.apple.systempreferences")
        #expect(id("zoom") == "us.zoom.xos")
        #expect(id("com.apple.Notes") == "com.apple.Notes")
    }

    @Test func aliasForAMissingAppFallsThrough() {
        let r = AppResolver(index: InstantFakeIndex(list: [InstalledApp(name: "Code", bundleID: "com.vscodium")]))
        if case .found(let app, _) = r.resolve("code") { #expect(app.bundleID == "com.vscodium") } else { Issue.record("not found") }
    }

    @Test func fuzzyMatchesSlipsButNotStrangers() {
        #expect(id("chat gtp") == "com.openai.chat")
        #expect(id("spotfy") == "com.spotify.client")
        #expect(id("teams") == "com.microsoft.teams2")
        #expect(id("photo booth") == "com.apple.PhotoBooth")
        #expect(resolver.resolve("banana") == .notFound)
        #expect(resolver.resolve("x") == .notFound)
    }

    @Test func closeCallsAreAmbiguous() {
        if case .ambiguous(let apps) = resolver.resolve("studio") {
            #expect(Set(apps.map(\.bundleID)) == ["com.microsoft.VSCode", "com.google.android.studio"])
        } else { Issue.record("expected ambiguous") }
        if case .ambiguous = resolver.resolve("photo") {} else { Issue.record("expected ambiguous") }
        let twins = AppResolver(index: InstantFakeIndex(list: [
            InstalledApp(name: "Foo", bundleID: "a.foo"), InstalledApp(name: "Foo", bundleID: "b.foo"),
        ]))
        if case .ambiguous = twins.resolve("foo") {} else { Issue.record("expected ambiguous") }
        let oneRunning = AppResolver(index: InstantFakeIndex(list: [
            InstalledApp(name: "Foo", bundleID: "a.foo"), InstalledApp(name: "Foo", bundleID: "b.foo", isRunning: true),
        ]))
        if case .found(let app, _) = oneRunning.resolve("foo") { #expect(app.bundleID == "b.foo") } else { Issue.record("expected running one") }
    }

    /// Reads this Mac's real app folders (no launching): the first scan is paid once in the
    /// background at install; after that a lookup is a few stats plus the running-app list.
    @Test func systemIndexIsCheapOnceWarm() {
        let index = SystemAppIndex()
        let clock = ContinuousClock()
        let cold = clock.measure { _ = index.apps() }
        let resolver = AppResolver(index: index)
        var warm = Duration.zero
        for name in ["finder", "chat gpt", "system settings", "nothing like this app"] {
            warm = max(warm, clock.measure { _ = resolver.resolve(name) })
        }
        print("SystemAppIndex: cold scan \(cold), worst warm resolve \(warm), \(index.apps().count) apps")
        #expect(warm < .milliseconds(100))
    }

    @Test func systemIndexScansFoldersAndNoticesNewApps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func makeApp(_ name: String, _ id: String) throws {
            let contents = dir.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeApp("Glide Test One", "dev.glide.test.one")
        let index = SystemAppIndex(folders: [dir.path])
        #expect(index.apps().contains { $0.bundleID == "dev.glide.test.one" })
        // A folder's modification date only moves when its entries change; make sure it does.
        try makeApp("Glide Test Two", "dev.glide.test.two")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: dir.path)
        #expect(index.apps().contains { $0.bundleID == "dev.glide.test.two" })
    }
}

// MARK: - Engine behaviour

@Suite struct InstantEngineTests {
    @Test func openAppSaysItAndOffersANextStep() async throws {
        let rig = InstantRig()
        let r = try #require(await rig.engine.handle("open chatgpt"))
        #expect(r.ack == "Opening ChatGPT.")
        #expect(r.summary == "Opened ChatGPT.")
        #expect(r.remainder == nil)
        #expect(r.context == nil)
        let q = try #require(r.followUp)
        #expect(q.text == "Want me to do anything in ChatGPT?")
        #expect(q.lowRisk)
        #expect(q.defaultOption == nil)
        #expect(rig.opener.apps == ["com.openai.chat"])
    }

    @Test func runningAppIsSwitchedTo() async throws {
        let r = try #require(await InstantRig().engine.handle("open slack"))
        #expect(r.ack == "Switching to Slack.")
    }

    @Test func noFollowUpWhenTurnedOffOrForSearches() async throws {
        var s = AppSettings()
        s.conversation.offerNextStep = false
        #expect(try #require(await InstantRig(settings: s).engine.handle("open chatgpt")).followUp == nil)
        let search = try #require(await InstantRig().engine.handle("search amazon for socks"))
        #expect(search.ack == "Searching Amazon for socks.")
        #expect(search.followUp == nil)
        let site = try #require(await InstantRig().engine.handle("open youtube"))
        #expect(site.followUp?.text == "Want me to do anything on YouTube?")
    }

    @Test func compoundCarriesRemainderAndContext() async throws {
        let rig = InstantRig()
        let r = try #require(await rig.engine.handle("Open ChatGPT and ask it about the Weather"))
        #expect(r.remainder == "ask it about the Weather")
        #expect(r.context == "ChatGPT (desktop app) is open and in front.")
        #expect(r.followUp == nil)
    }

    @Test func chatGPTFallsBackToTheWebsiteWithoutTheApp() async throws {
        let rig = InstantRig(index: InstantFakeIndex(list: []))
        let r = try #require(await rig.engine.handle("open chatgpt"))
        #expect(r.ack == "Opening ChatGPT.")
        #expect(rig.opener.urls.map(\.absoluteString) == ["https://chatgpt.com/"])
        #expect(rig.opener.apps.isEmpty)
    }

    @Test func pagesUseGlidesBrowserWhenConnected() async throws {
        let rig = InstantRig(browserConnected: true)
        let r = try #require(await rig.engine.handle("go to amazon and add socks to my cart"))
        #expect(rig.browser.tabs.map(\.absoluteString) == ["https://www.amazon.com/"])
        #expect(rig.opener.urls.isEmpty)
        #expect(r.remainder == "add socks to my cart")
        #expect(r.context?.contains("Glide's browser") == true)
    }

    @Test func pagesFallBackToTheDefaultBrowser() async throws {
        let failing = InstantRig(browserConnected: true, browserFails: true)
        _ = try #require(await failing.engine.handle("open youtube"))
        #expect(failing.opener.urls.map(\.absoluteString) == ["https://www.youtube.com/"])
        let offline = InstantRig(browserConnected: false)
        _ = try #require(await offline.engine.handle("open youtube"))
        #expect(offline.opener.urls.map(\.absoluteString) == ["https://www.youtube.com/"])
        #expect(offline.browser.tabs.isEmpty)
    }

    @Test func plannerRequestsTouchNothing() async {
        let rig = InstantRig()
        #expect(await rig.engine.handle("add socks on amazon") == nil)
        #expect(rig.opener.apps.isEmpty && rig.opener.urls.isEmpty)
    }

    @Test func dryRunDescribesWithoutOpening() async {
        let rig = InstantRig()
        let yes = await rig.engine.describe("open chat gpt and summarize my day")
        #expect(yes.contains("com.openai.chat"))
        #expect(yes.contains("Opening ChatGPT."))
        #expect(yes.contains("summarize my day"))
        let no = await rig.engine.describe("buy socks")
        #expect(no.hasPrefix("Not instant"))
        #expect(rig.opener.apps.isEmpty && rig.opener.urls.isEmpty)
    }

    @Test func installSetsTheHandler() async {
        let previous = InstantActions.handler
        defer { InstantActions.handler = previous }
        let rig = InstantRig()
        InstantActionsSetup.install(engine: rig.engine)
        let r = await InstantActions.handler?("open notes")
        #expect(r?.ack == "Opening Notes.")
        let plan = await InstantActionsSetup.dryRunPlan("open notes")
        #expect(plan?.bundleID == "com.apple.Notes")
    }

    @Test func resolvingAndStartingIsFast() async {
        // A large Mac: 400 apps. Resolve + start opening must stay far under 100 ms.
        var list = InstantFakeIndex.standard.list
        for i in 0..<400 { list.append(InstalledApp(name: "Utility App \(i)", bundleID: "dev.example.app\(i)")) }
        let rig = InstantRig(index: InstantFakeIndex(list: list))
        let phrases = ["open chatgpt", "hey can you open up chat gtp", "search amazon for socks", "open youtube", "add socks on amazon"]
        let clock = ContinuousClock()
        var worst = Duration.zero
        for p in phrases {
            let elapsed = await clock.measure { _ = await rig.engine.handle(p) }
            worst = max(worst, elapsed)
        }
        #expect(worst < .milliseconds(100), "worst \(worst)")
    }
}

// MARK: - Jev assist

@Suite struct InstantAssistTests {
    @Test func confidentGuessOpensTheApp() async throws {
        let jev = InstantFakeClassifier(.openApp, 0.95)
        let rig = InstantRig(classifier: jev)
        let r = try #require(await rig.engine.handle("chat gpt"))
        #expect(r.ack == "Opening ChatGPT.")
        #expect(jev.calls == 1)
    }

    @Test func confidentSearchGuess() async throws {
        let rig = InstantRig(classifier: InstantFakeClassifier(.searchSite, 0.97))
        _ = try #require(await rig.engine.handle("amazon socks"))
        #expect(rig.opener.urls.map(\.absoluteString) == ["https://www.amazon.com/s?k=socks"])
    }

    @Test func unsureOrOtherGoesToThePlanner() async {
        #expect(await InstantRig(classifier: InstantFakeClassifier(.openApp, 0.8)).engine.handle("chat gpt") == nil)
        #expect(await InstantRig(classifier: InstantFakeClassifier(.other, 0.99)).engine.handle("chat gpt") == nil)
    }

    @Test func longOrWorkPhrasingNeverAsksJev() async {
        let jev = InstantFakeClassifier(.openApp, 0.99)
        let rig = InstantRig(classifier: jev)
        #expect(await rig.engine.handle("i was wondering whether you might maybe have a look at things") == nil)
        #expect(await rig.engine.handle("buy socks") == nil)
        #expect(jev.calls == 0)
    }

    @Test func slowJevIsAbandonedAtTheTimeout() async {
        let rig = InstantRig(classifier: InstantFakeClassifier(.openApp, 0.99, delay: .seconds(10)), assistTimeout: 0.2)
        let clock = ContinuousClock()
        var result: InstantResult?
        let elapsed = await clock.measure { result = await rig.engine.handle("chat gpt") }
        #expect(result == nil)
        #expect(elapsed < .seconds(1.5), "took \(elapsed)")
    }

    @Test func noKeyMeansNoJev() {
        let creds = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        creds.useMemoryOnly()
        #expect(JevInstantClassifier.configured(settings: AppSettings(), credentials: creds) == nil)
        creds.useMemoryOnly([.jev: "test-key"])
        #expect(JevInstantClassifier.configured(settings: AppSettings(), credentials: creds) != nil)
    }
}
