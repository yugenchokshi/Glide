import Testing
import Foundation
@testable import AgentKit
@testable import AutomationKit

// browser.find, dialog-aware scrolling and snapshots, page fingerprints and bot checks. The
// pure parts run on hand-built snapshots; the rest on headless Chrome (and the real extension in
// Chrome for Testing) against local fixture pages shaped like the sites where Glide got stuck:
// a filters dialog whose list hides "Cabin" far down, a product page whose "Add to Cart" is
// beyond the snapshot's element cap, frames and shadow roots.

// MARK: - Fixture pages

enum FindFixtures {
    /// A drawer dialog (aria-modal) on the right, whose middle panel scrolls and holds "Cabin"
    /// at the very bottom. The viewport center is over the page behind it, which scrolls too —
    /// the setup where scrolling used to move the page instead of the dialog.
    static var filters: String {
        let prices = ["Under $100", "$100 to $200", "$200 to $300", "$300 to $400", "Over $400"]
        let amenities = ["Wifi", "Kitchen", "Washer", "Dryer", "Air conditioning", "Heating", "Dedicated workspace", "TV", "Hair dryer",
                         "Iron", "Pool", "Hot tub", "Free parking", "EV charger", "Crib", "Gym", "BBQ grill", "Breakfast",
                         "Indoor fireplace", "Smoking allowed", "Beachfront", "Waterfront", "Ski-in/ski-out", "Piano"]
        let types = ["House", "Apartment", "Guesthouse", "Hotel", "Cabin"]
        func buttons(_ names: [String]) -> String { names.map { "<button type=\"button\" class=\"f\">\($0)</button>" }.joined() }
        let listings = (1...60).map { "<a href=\"/second\">Listing \($0)</a>" }.joined()
        return """
        <!doctype html><html><head><title>Stays</title><style>
          body { margin: 0; font-family: sans-serif; }
          main a { display: block; height: 40px; }
          #filters { position: fixed; top: 0; right: 0; bottom: 0; width: 320px; background: #fff; border-left: 1px solid #ccc;
                     display: flex; flex-direction: column; z-index: 10; }
          #filters header, #filters footer { height: 60px; flex: none; }
          #filters .body { flex: 1; overflow-y: auto; }
          #filters .body button { display: block; height: 36px; margin: 4px; }
        </style></head><body>
        <main><h1>Stays near you</h1><p id="status">No filters</p><a href="/second">Cabin rentals near you</a>\(listings)</main>
        <div id="filters" role="dialog" aria-modal="true" aria-labelledby="fh">
          <header><h2 id="fh">Filters</h2><button type="button" aria-label="Close">×</button></header>
          <div class="body">
            <h3>Price range</h3>\(buttons(prices))
            <h3>Amenities</h3>\(buttons(amenities))
            <h3>Property type</h3>\(buttons(types))
            <label>Max price <input id="max" type="text"></label>
          </div>
          <footer><button type="button">Show 300 places</button></footer>
        </div>
        <script>
          document.querySelectorAll('#filters .f').forEach(function (b) {
            b.addEventListener('click', function () { b.setAttribute('aria-pressed', 'true'); document.getElementById('status').textContent = 'Filter: ' + b.textContent; });
          });
        </script>
        </body></html>
        """
    }

    /// About 600 controls: a block of navigation links fills the snapshot's cap before the buy
    /// box (an Amazon-style submit input labelled by a span) further down on the right, and a
    /// "Customers also bought" row repeats "Add to cart" below it.
    static var product: String {
        let nav = (1...360).map { "<a href=\"/second\">Dept \($0)</a>" }.joined()
        let reviews = (1...200).map { "<button type=\"button\">Helpful \($0)</button>" }.joined()
        let cards = (1...20).map { "<div class=\"card\"><span>Cable \($0)</span><button type=\"button\" class=\"also\">Add to cart</button></div>" }.joined()
        return """
        <!doctype html><html><head><title>Anker USB C Cable</title><style>
          body { margin: 0; font-family: sans-serif; position: relative; }
          nav a { display: inline-block; width: 60px; height: 16px; font-size: 9px; overflow: hidden; }
          #reviews button { display: block; height: 30px; }
          #buy { position: absolute; top: 1600px; right: 20px; width: 220px; border: 1px solid #999; }
        </style></head><body>
        <nav>\(nav)</nav>
        <main><h1>Anker USB C to USB C Cable</h1><p id="status">Cart: empty</p><div id="reviews">\(reviews)</div>
          <section><h2>Customers also bought</h2>\(cards)</section></main>
        <div id="buy"><span class="price">$9.99</span>
          <span class="a-button"><input type="submit" id="add-to-cart-button" aria-labelledby="atc-label" value="Add to Cart"><span id="atc-label">Add to Cart</span></span>
        </div>
        <script>
          document.getElementById('add-to-cart-button').addEventListener('click', function () { document.getElementById('status').textContent = 'Cart: 1 item'; });
        </script>
        </body></html>
        """
    }

    /// A same-origin frame whose button is far down inside it, and a shadow-root button far
    /// down the page.
    static let framed = """
        <!doctype html><html><head><title>Framed</title></head><body>
        <h1>Framed</h1>
        <iframe id="f" src="/framed-inner" title="Checkout frame" style="width:400px;height:200px"></iframe>
        <div style="height:2400px"></div>
        <div id="host"></div>
        <script>
          const root = document.getElementById('host').attachShadow({ mode: 'open' });
          root.innerHTML = '<button onclick="this.textContent=\\'Shadow deep clicked\\'">Shadow deep button</button>';
        </script>
        </body></html>
        """

    static let framedInner = """
        <!doctype html><html><body><div style="height:1500px"></div>
        <button onclick="this.textContent='Deep frame clicked'">Deep frame button</button></body></html>
        """

    /// A fixed overlay with a z-index and no dialog role, whose list scrolls.
    static var overlay: String {
        let rows = (1...40).map { "<button type=\"button\" style=\"display:block;height:40px\">Photo \($0)</button>" }.joined()
        let page = (1...40).map { "<p>Paragraph \($0)</p>" }.joined()
        return """
        <!doctype html><html><head><title>Gallery</title><style>
          #shade { position: fixed; inset: 0; background: rgba(0,0,0,.5); z-index: 50; display: flex; align-items: center; justify-content: center; }
          #box { width: 60%; height: 70%; background: #fff; overflow-y: auto; }
        </style></head><body><h1>Gallery</h1>\(page)
        <div id="shade"><div id="box"><h2>All photos</h2>\(rows)</div></div>
        </body></html>
        """
    }

    /// A dialog whose list doesn't overflow: it moves its rows itself on wheel events, as some
    /// virtualized pickers do.
    static var wheel: String {
        let rows = (1...40).map { "<button type=\"button\" style=\"display:block;height:40px\">Row \($0)</button>" }.joined()
        return """
        <!doctype html><html><head><title>Picker</title><style>
          #dlg { position: fixed; top: 10%; left: 20%; width: 60%; height: 60%; background: #fff; overflow: hidden; z-index: 5; }
        </style></head><body><h1>Picker page</h1>
        <div id="dlg" role="dialog" aria-label="Wheel list"><div id="rows">\(rows)</div></div>
        <script>
          let offset = 0;
          document.getElementById('dlg').addEventListener('wheel', function (e) {
            e.preventDefault();
            offset = Math.max(0, Math.min(1400, offset + e.deltaY));
            document.getElementById('rows').style.transform = 'translateY(' + (-offset) + 'px)';
          }, { passive: false });
        </script>
        </body></html>
        """
    }

    /// A date picker grid whose days take focus one at a time, as ARIA grids do.
    static var calendar: String {
        let days = (1...31).map { d in
            "<div role=\"gridcell\" tabindex=\"\(d == 1 ? 0 : -1)\" aria-label=\"December \(d), 2026\" onclick=\"document.getElementById('status').textContent='Departure: December \(d)'\">\(d)</div>"
        }.joined()
        return """
        <!doctype html><html><head><title>Flights</title><style>#grid div { display: inline-block; width: 30px; }</style></head><body>
        <p id="status">Departure: none</p><div role="grid" id="grid" aria-label="December 2026">\(days)</div></body></html>
        """
    }

    static let captcha = """
        <!doctype html><html><head><title>Just a moment...</title></head><body>
        <h1>shop.example.test</h1><p>Verify you are human by completing the action below.</p>
        <label><input type="checkbox"> I'm not a robot</label></body></html>
        """

    /// A page with many controls whose reCAPTCHA challenge popup is showing.
    static var challengeFrame: String {
        let links = (1...120).map { "<a href=\"/second\">Item \($0)</a> " }.joined()
        return """
        <!doctype html><html><head><title>Sign in</title></head><body><h1>Sign in</h1>\(links)
        <iframe src="/recaptcha/api2/bframe?k=test" title="recaptcha challenge" style="width:400px;height:500px"></iframe></body></html>
        """
    }

    /// An article that talks about robots and pressing and holding, on a page with plenty of
    /// links: not a bot check.
    static var robotsArticle: String {
        let links = (1...100).map { "<a href=\"/second\">Story \($0)</a> " }.joined()
        return """
        <!doctype html><html><head><title>Are you a robot? A history of CAPTCHAs</title></head><body>
        <nav>\(links)</nav><main><h1>Are you a robot?</h1>
        <p>Sites ask you to verify you are human. Press and hold the button, they say, to prove you're not a robot.</p></main></body></html>
        """
    }

    /// An ordinary page with an invisible reCAPTCHA badge, which isn't a bot check.
    static let invisibleCaptcha = """
        <!doctype html><html><head><title>Contact us</title></head><body><h1>Contact us</h1>
        <p>We usually reply within a day. Please don't send passwords or other secrets.</p>
        <button>Send</button>
        <iframe src="/recaptcha/api2/anchor?size=invisible&k=test" title="reCAPTCHA" style="width:256px;height:60px"></iframe></body></html>
        """

    static func route(_ path: String, _ query: [String: String]) -> (Int, String) {
        switch path {
        case "/filters": return (200, filters)
        case "/product": return (200, product)
        case "/framed": return (200, framed)
        case "/framed-inner": return (200, framedInner)
        case "/overlay": return (200, overlay)
        case "/wheel": return (200, wheel)
        case "/captcha": return (200, captcha)
        case "/calendar": return (200, calendar)
        case "/challenge": return (200, challengeFrame)
        case "/contact": return (200, invisibleCaptcha)
        case "/robots": return (200, robotsArticle)
        case "/recaptcha/api2/bframe", "/recaptcha/api2/anchor": return (200, "<!doctype html><body>challenge</body>")
        default: return Fixtures.route(path, query)
        }
    }
}

// MARK: - Pure logic

@Suite("browser.find and snapshot hints (logic)")
struct BrowserFindLogicTests {
    static func dialogPage() -> PageSnapshot {
        PageSnapshot(tabID: "T1", url: "https://stays.example.com/s", title: "Stays", viewportWidth: 1200, viewportHeight: 800,
                     pageHeight: 3000, elements: [
                        .init(ref: "b1", role: "link", name: "Listing 1", href: "https://stays.example.com/l/1"),
                        .init(ref: "b2", role: "button", name: "Close", inModal: true),
                        .init(ref: "b3", role: "button", name: "Wifi", inModal: true),
                        .init(ref: "b4", role: "button", name: "House", y: 900, inViewport: false, inModal: true, offscreen: "below"),
                        .init(ref: "b5", role: "button", name: "Cabin", y: 990, inViewport: false, inModal: true, offscreen: "below"),
                        .init(ref: "b6", role: "link", name: "Listing 60", y: 2600, inViewport: false, offscreen: "below"),
                     ], headings: [.init(level: 1, text: "Stays near you")], text: "Stays near you",
                     modal: .init(name: "Filters", scrollTop: 0, scrollHeight: 1600, clientHeight: 600,
                                  below: [.init(name: "House", group: "Property type"), .init(name: "Cabin", group: "Property type")],
                                  text: "Filters Price range Amenities"),
                     cut: .init(below: 3, right: 2))
    }

    @Test func dialogsComeFirstAndTheirHiddenPartIsNamed() {
        let text = Self.dialogPage().compact()
        #expect(text.contains("dialog open: \"Filters\", scrolled 0 of 1000 (top)"))
        #expect(text.contains("Further down in this dialog (2 elements): Property type: House, Cabin."))
        // The dialog's own controls, then the page behind it.
        let close = text.range(of: "b2 button \"Close\""), behind = text.range(of: "behind the dialog:"), listing = text.range(of: "b1 link \"Listing 1\"")
        #expect(close != nil && behind != nil && listing != nil)
        if let close, let behind, let listing { #expect(close.lowerBound < behind.lowerBound && behind.lowerBound < listing.lowerBound) }
        // The dialog's elements further down are in the hint, not listed again.
        #expect(!text.contains("b5 button"))
        #expect(text.contains("b6 link \"Listing 60\""))
        // Elements past the cap are counted by where they are.
        #expect(text.contains("(5 more interactive elements not listed: 3 below, 2 to the right — use browser.find"))
        #expect(text.contains("dialog text:\nFilters Price range Amenities"))
        // A caller that already showed an element can leave it out.
        #expect(!Self.dialogPage().compact(skip: ["b1"]).contains("b1 link"))
    }

    @Test func theHintStaysShort() {
        let many = (1...200).map { PageSnapshot.Modal.Hint(name: "Amenity number \($0)", group: $0 < 100 ? "Amenities" : "Features") }
        let hint = PageSnapshot.furtherDown(.init(name: "Filters", below: Array(many.prefix(60)), belowCount: 200))
        #expect(hint != nil)
        #expect((hint ?? "").count < 560, "\(hint ?? "")")
        #expect(hint?.hasPrefix("Further down in this dialog (200 elements): Amenities: Amenity number 1, ") == true)
        #expect(hint?.contains("…") == true)
        #expect(PageSnapshot.furtherDown(.init(name: "Filters")) == nil, "nothing further down, no hint")
        #expect(PageSnapshot.furtherDown(.init(name: "", kind: "popup", below: [.init(name: "Photo 9")]))?.hasPrefix("Further down in this popup (1 element): Photo 9.") == true)
    }

    @Test func fingerprintsFollowWhatAPersonWouldNotice() {
        let page = Self.dialogPage()
        #expect(page.fingerprint == Self.dialogPage().fingerprint)
        #expect(page.fingerprint.count == 16)
        var same = page
        same.timestamp = Date().addingTimeInterval(60)
        same.elements[2].focused = true
        same.elements[3].ref = "b40" // re-rendered with new refs
        same.text = "Stays near you (updated 1 s ago)"
        #expect(same.fingerprint == page.fingerprint, "focus, refs, time and plain text don't count")
        var typed = page
        typed.elements[2].value = "on"
        #expect(typed.fingerprint != page.fingerprint)
        var pressed = page
        pressed.elements[2].checked = true
        #expect(pressed.fingerprint != page.fingerprint)
        var scrolled = page
        scrolled.scrollY = 400
        #expect(scrolled.fingerprint != page.fingerprint)
        var dialogScrolled = page
        dialogScrolled.modal?.scrollTop = 300
        #expect(dialogScrolled.fingerprint != page.fingerprint)
        var closed = page
        closed.modal = nil
        #expect(closed.fingerprint != page.fingerprint)
        var moved = page
        moved.url = "https://stays.example.com/s?page=2"
        #expect(moved.fingerprint != page.fingerprint)
        var offscreenOnly = page
        offscreenOnly.elements[5].name = "Listing 61"
        #expect(offscreenOnly.fingerprint == page.fingerprint, "only elements in view count")
        var withFound = page
        withFound.elements.append(.init(ref: "b70", role: "text", name: "Stays near you", pinned: true))
        #expect(withFound.fingerprint == page.fingerprint, "what find pinned isn't part of the page's state")
        #expect(page.changeSummary(since: withFound) == "No visible change on the page.")
        // It's in the data every page-state tool returns.
        #expect(page.modelData["fingerprint"]?.stringValue == page.fingerprint)
        #expect(page.modelData["botCheck"] == nil)
        var bot = page
        bot.botCheck = "the page says “verify you are human”"
        #expect(bot.modelData["botCheck"]?.boolValue == true)
        #expect(bot.compact().contains(PageSnapshot.botCheckNotice))
        #expect(bot.fingerprint != page.fingerprint)
    }

    @Test func changeSummariesMentionDialogs() {
        let page = Self.dialogPage()
        var closed = page
        closed.modal = nil
        #expect(closed.changeSummary(since: page).contains("the “Filters” dialog closed"))
        #expect(page.changeSummary(since: closed).contains("the “Filters” dialog opened"))
        var scrolled = page
        scrolled.modal?.scrollTop = 420
        #expect(scrolled.changeSummary(since: page) == "Same page; the “Filters” dialog scrolled to 420.")
    }

    @Test func pageNumbersNeverTrap() {
        #expect(PageSnapshot.whole(.infinity) == 0 && PageSnapshot.whole(.nan) == 0)
        #expect(PageSnapshot.whole(1e300) == 1_000_000_000_000_000)
        #expect(BrowserDriver.count(.number(1e300)) == 1_000_000_000_000)
        #expect(BrowserDriver.count(.number(-3)) == nil && BrowserDriver.count(.string("x")) == nil && BrowserDriver.count(nil) == nil)
        let snap = BrowserDriver.decodeSnapshot(["url": "https://x.test/", "sy": .number(1e300), "total": .number(1e300),
                                                 "headings": [["level": .number(1e300), "text": "Big"]]], tabID: "t")
        #expect(snap.headings.first?.level == 6)
        #expect(!snap.compact().isEmpty)
        #expect(BrowserArgs.int(["nth": .number(1e300)], "nth", default: 1, in: 1...100) == 100)
        #expect(BrowserArgs.int(["nth": .number(-5)], "nth", default: 1, in: 1...100) == 1)
        #expect(BrowserArgs.int(["nth": "2"], "nth", default: 1, in: 1...100) == 2)
        #expect(BrowserArgs.int([:], "nth", default: 1, in: 1...100) == 1)
    }

    static func result(match: BrowserFindResult.Match?, others: [BrowserFindResult.Match] = [], total: Int, scrolled: Bool = false,
                       stillOut: Bool = false, roles: [String] = [], suggestions: [String] = []) -> BrowserFindResult {
        BrowserFindResult(snapshot: dialogPage(), match: match, scrolled: scrolled, stillOutOfView: stillOut, others: others, total: total,
                          otherRoles: roles, suggestions: suggestions)
    }

    @Test func findReportsTheMatchAndWhereTheOthersAre() {
        let cabin = BrowserFindResult.Match(ref: "b5", role: "button", name: "Cabin", location: "in dialog “Filters”, further down", nth: 1)
        let link = BrowserFindResult.Match(ref: "b6", role: "link", name: "Listing 60", location: "behind the open dialog, further down the page", nth: 2)
        let hidden = BrowserFindResult.Match(ref: "b99", role: "text", name: "Cabin tips", location: "hidden", nth: 3)
        let out = BrowserFindTool.output(Self.result(match: cabin, others: [link, hidden], total: 12, scrolled: true), text: "cabin", role: nil, nth: 1, previous: nil)
        #expect(out.ok)
        #expect(out.text.hasPrefix("Found b5 button \"Cabin\". It was in dialog “Filters”, further down; now scrolled into view."), "\(out.text)")
        #expect(out.text.contains("Other matches (12 in all; nth picks one):"))
        #expect(out.text.contains("- b6 link \"Listing 60\" — behind the open dialog, further down the page (nth 2)"))
        #expect(out.text.contains("- (nth 3) text \"Cabin tips\" — hidden"))
        #expect(out.text.contains("- …and 9 more"))
        #expect(out.data?["match"]?["ref"]?.stringValue == "b5")
        #expect(out.data?["matches"]?.intValue == 12)
        #expect(out.data?["fingerprint"]?.stringValue?.count == 16)
        #expect(out.data?["elements"]?.arrayValue?.contains { $0["ref"]?.stringValue == "b5" } == true, "the runner sees the ref")
        // The match and the listed runner-up aren't repeated in the page listing below.
        #expect(out.text.components(separatedBy: "b6 link").count == 2)

        let onScreen = BrowserFindTool.output(Self.result(match: .init(ref: "b3", role: "button", name: "Wifi", location: "in dialog “Filters”, on screen", nth: 1), total: 1),
                                              text: "wifi", role: nil, nth: 1, previous: nil)
        #expect(onScreen.text.hasPrefix("Found b3 button \"Wifi\", in dialog “Filters”, on screen."), "\(onScreen.text)")
        let stuck = BrowserFindTool.output(Self.result(match: cabin, total: 1, scrolled: true, stillOut: true), text: "cabin", role: nil, nth: 1, previous: nil)
        #expect(stuck.text.contains("scrolling didn't bring it into view"))
    }

    @Test func findSaysPlainlyWhenNothingMatches() {
        let none = BrowserFindTool.output(Self.result(match: nil, total: 0, suggestions: ["Cabin", "Cabins"]), text: "Cabbin", role: nil, nth: 1, previous: nil)
        #expect(!none.ok)
        #expect(none.text.hasPrefix("Nothing on the page matches “Cabbin”. Similar labels: “Cabin”, “Cabins”."), "\(none.text)")
        #expect(none.data?["fingerprint"] != nil)
        let wrongRole = BrowserFindTool.output(Self.result(match: nil, total: 0, roles: ["checkbox", "link", "text"]), text: "Cabin", role: "button", nth: 1, previous: nil)
        #expect(wrongRole.text.hasPrefix("Nothing with role button matches “Cabin”; a checkbox, a link and plain text do. Leave out role"), "\(wrongRole.text)")
        let oneRole = BrowserFindTool.output(Self.result(match: nil, total: 0, roles: ["link"]), text: "Cabin", role: "button", nth: 1, previous: nil)
        #expect(oneRole.text.hasPrefix("Nothing with role button matches “Cabin”; a link does."), "\(oneRole.text)")
        let tooFar = BrowserFindTool.output(Self.result(match: nil, total: 2), text: "Cabin", role: nil, nth: 5, previous: nil)
        #expect(tooFar.text.hasPrefix("There are only 2 matches for “Cabin”; nth 5 is beyond them."))
    }

    @Test func findIsReadOnlyAndLowRisk() {
        let tool = BrowserFindTool(rt: BrowserRuntime(hub: BrowserHub(), sessions: BrowserSessions()))
        #expect(tool.spec.readOnly && tool.spec.category == .browser)
        let verdict = tool.assess(["text": "Delete account"], context: ToolContext(settings: AppSettings(), gate: ExecutionGate()))
        #expect(verdict.risk == .low && verdict.blocked == nil)
        #expect(verdict.summary == "Find “Delete account” in the browser tab")
    }

    @Test func toolDescriptionsPointToTheFasterWays() {
        let tools = BrowserTools.make(hub: BrowserHub(), sessions: BrowserSessions())
        func summary(_ name: String) -> String { tools.first { $0.spec.name == name }?.spec.summary ?? "" }
        #expect(summary("browser.open").contains("https://www.amazon.com/s?k=usb+c+cable"))
        #expect(summary("browser.open").contains("date pickers"))
        #expect(summary("browser.snapshot").contains("browser.find instead"))
        #expect(summary("browser.scroll").contains("dialog"))
        #expect(summary("browser.find").contains("scroll it into view"))
        let schema = tools.first { $0.spec.name == "browser.find" }?.spec.inputSchema
        #expect(schema?["required"]?.arrayValue == ["text"])
        #expect(schema?["properties"]?["role"] != nil && schema?["properties"]?["nth"]?["type"] == "integer")
    }
}

// MARK: - Headless Chrome

@Suite("browser.find, dialogs and fingerprints (headless Chrome)", .serialized,
       .enabled(if: ChromeHarness.installed, "Google Chrome isn't installed; skipping the live browser tests."))
struct BrowserFindChromeTests {
    func setUp(_ backend: GlideChromeBackend) -> (ToolRegistry, ToolContext, BrowserSessions) {
        let hub = BrowserHub()
        hub.register(backend)
        var settings = AppSettings()
        settings.browser.backend = .glideChrome
        let sessions = BrowserSessions()
        return (ToolRegistry(BrowserTools.make(hub: hub, sessions: sessions)), ToolContext(settings: settings, gate: ExecutionGate()), sessions)
    }

    func status(_ driver: BrowserDriver, _ tab: String) async throws -> String {
        try await driver.readText(tabID: tab, selector: "#status").text
    }

    @Test func snapshotsSeeTheDialogAndNameWhatsFurtherDownInIt() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { _, driver, server in
            let (_, snap) = try await ChromeHarness.openHome(driver, server, path: "/filters")
            let modal = try #require(snap.modal)
            #expect(modal.name == "Filters" && modal.kind == "dialog")
            #expect(modal.scrollHeight > modal.clientHeight)
            #expect(modal.below.contains { $0.name == "Cabin" && $0.group == "Property type" }, "\(modal.below)")
            // Cut off by the dialog's own scrolling panel, though inside the window's height.
            let cabin = try #require(snap.named("Cabin"))
            #expect(cabin.inModal == true && !cabin.inViewport && cabin.offscreen == "below")
            #expect(snap.named("Wifi")?.inViewport == true && snap.named("Wifi")?.inModal == true)
            #expect(snap.named("Listing 1")?.inModal != true)
            #expect(snap.elements.contains { $0.inModal == true && !$0.inViewport && $0.y < snap.viewportHeight },
                    "a button inside the window's height that the dialog's panel cuts off isn't in view")
            let text = snap.compact()
            #expect(text.contains("dialog open: \"Filters\""))
            #expect(text.contains("Further down in this dialog") && text.contains("Property type: House, Apartment, Guesthouse, Hotel, Cabin"), "\(text)")
            #expect(text.contains("behind the dialog:"))
            #expect(snap.botCheck == nil)
            // Its text, without the names of the controls listed anyway.
            #expect(modal.text.contains("Price range") && modal.text.contains("Property type"))
            #expect(!modal.text.contains("Hot tub"), "\(modal.text)")
        }
    }

    @Test func scrollingMovesTheDialogNotThePageBehindIt() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { _, driver, server in
            let (tab, before) = try await ChromeHarness.openHome(driver, server, path: "/filters")
            #expect(before.scrollY == 0)
            let outcome = try await driver.scroll(tabID: tab, direction: .down, amount: 1)
            #expect(outcome.moved && outcome.scrolled == "the “Filters” dialog", "\(outcome)")
            #expect(outcome.notes.isEmpty)
            let after = try await driver.snapshot(tabID: tab)
            #expect(after.scrollY == 0, "the page behind stays put")
            #expect((after.modal?.scrollTop ?? 0) > 100)
            #expect(after.changeSummary(since: before).contains("the “Filters” dialog scrolled to"))
            #expect(after.fingerprint != before.fingerprint)
            // At the bottom it says so instead of moving the page.
            _ = try await driver.scroll(tabID: tab, direction: .down, amount: 20)
            let stuck = try await driver.scroll(tabID: tab, direction: .down, amount: 1)
            #expect(!stuck.moved && stuck.notes == ["Nothing scrolled — the “Filters” dialog is already at the bottom."], "\(stuck.notes)")
            #expect(try await driver.snapshot(tabID: tab).scrollY == 0)
            // A ref still scrolls the panel around it: here the page.
            let listing = try #require(after.named("Listing 1")).ref
            let page = try await driver.scroll(tabID: tab, direction: .down, amount: 1, ref: listing)
            #expect(page.moved && page.scrolled == "the page")
        }
    }

    @Test func clickingAndTypingRevealElementsInsideAScrolledDialog() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server, path: "/filters")
            let cabin = try #require(snap.named("Cabin"))
            #expect(!cabin.inViewport)
            let clicked = try await driver.click(tabID: tab, ref: cabin.ref)
            #expect(!clicked.notes.contains { $0.contains("by script") }, "a real click once it's scrolled into view: \(clicked.notes)")
            #expect(try await status(driver, tab) == "Filter: Cabin")
            let after = try await driver.snapshot(tabID: tab)
            #expect(after.element(cabin.ref)?.inViewport == true)
            #expect(after.element(cabin.ref)?.checked == true)
            #expect(after.scrollY == 0)

            _ = try await driver.scroll(tabID: tab, direction: .up, amount: 20)
            let fresh = try await driver.snapshot(tabID: tab)
            let field = try #require(fresh.named("Max price"))
            #expect(!field.inViewport)
            let typed = try await driver.type(tabID: tab, ref: field.ref, text: "250")
            #expect(typed.value == "250")
            #expect(try await driver.snapshot(tabID: tab).element(field.ref)?.inViewport == true)
        }
    }

    @Test func findFindsTheFilterInTheDialogAndItsRefClicks() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { backend, driver, server in
            let (tools, ctx, sessions) = setUp(backend)
            let opened = try await tools.tool(named: "browser.open")!.run(["url": .string(server.url("/filters"))], context: ctx)
            #expect(opened.ok)
            let tab = try #require(sessions.session("default")?.tabID)
            let find = try #require(tools.tool(named: "browser.find"))
            #expect(find.assess(["text": "Cabin"], context: ctx).risk == .low)
            let found = try await find.run(["text": "cabin"], context: ctx)
            #expect(found.ok, "\(found.text)")
            let ref = try #require(found.data?["match"]?["ref"]?.stringValue)
            #expect(found.text.hasPrefix("Found \(ref) button \"Cabin\""), "\(found.text)")
            #expect(found.text.contains("It was in dialog “Filters”, further down; now scrolled into view."), "\(found.text)")
            #expect(found.text.contains("link \"Cabin rentals near you\"") && found.text.contains("behind the open dialog"), "\(found.text)")
            #expect(found.data?["fingerprint"]?.stringValue != nil)
            #expect(sessions.currentSnapshot("default")?.element(ref)?.inViewport == true, "the ref is in the latest snapshot")

            let click = try #require(tools.tool(named: "browser.click"))
            #expect(click.assess(["ref": .string(ref)], context: ctx).risk == .low)
            let clicked = try await click.run(["ref": .string(ref)], context: ctx)
            #expect(clicked.ok && clicked.text.contains("Clicked \(ref) button “Cabin”"), "\(clicked.text)")
            #expect(try await status(driver, tab) == "Filter: Cabin")

            // A role narrows it down; nth takes the next match.
            let link = try await find.run(["text": "Cabin", "role": "link"], context: ctx)
            #expect(link.ok && link.text.hasPrefix("Found ") && link.text.contains("link \"Cabin rentals near you\""), "\(link.text)")
            let second = try await find.run(["text": "Cabin", "nth": 2], context: ctx)
            #expect(second.ok && second.text.contains("link \"Cabin rentals near you\""), "\(second.text)")
            let checkbox = try await find.run(["text": "Cabin", "role": "checkbox"], context: ctx)
            // The status line now reads "Filter: Cabin", so plain text matches too.
            #expect(!checkbox.ok && checkbox.text.contains("Nothing with role checkbox matches “Cabin”; a button, plain text and a link do."), "\(checkbox.text)")
            let typo = try await find.run(["text": "Cabbin"], context: ctx)
            #expect(!typo.ok && typo.text.contains("Nothing on the page matches “Cabbin”.") && typo.text.contains("“Cabin”"), "\(typo.text)")
            let field = try await find.run(["text": "max price", "role": "textbox"], context: ctx)
            #expect(field.ok, "\(field.text)")
            let fieldRef = try #require(field.data?["match"]?["ref"]?.stringValue)
            let typed = try await tools.tool(named: "browser.type")!.run(["ref": .string(fieldRef), "text": "300"], context: ctx)
            #expect(typed.ok && typed.text.contains("It now contains “300”"), "\(typed.text)")
            // By value too, once it has one (never a password's).
            let byValue = try await find.run(["text": "300", "role": "textbox"], context: ctx)
            #expect(byValue.ok && byValue.data?["match"]?["ref"]?.stringValue == fieldRef, "\(byValue.text)")
        }
    }

    @Test func findReachesAddToCartBeyondTheSnapshotCut() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { backend, driver, server in
            let (tools, ctx, sessions) = setUp(backend)
            let opened = try await tools.tool(named: "browser.open")!.run(["url": .string(server.url("/product"))], context: ctx)
            #expect(opened.ok)
            let tab = try #require(sessions.session("default")?.tabID)
            let snap = try #require(sessions.currentSnapshot("default"))
            #expect(snap.totalInteractive > 550)
            #expect(snap.elements.count <= 300)
            #expect(!snap.elements.contains { $0.name == "Add to Cart" }, "the buy box is past the cap")
            #expect(opened.text.contains("more interactive elements not listed:") && opened.text.contains("below"), "\(opened.text.suffix(1500))")

            let found = try await tools.tool(named: "browser.find")!.run(["text": "Add to Cart"], context: ctx)
            #expect(found.ok, "\(found.text)")
            let ref = try #require(found.data?["match"]?["ref"]?.stringValue)
            #expect(found.text.hasPrefix("Found \(ref) button \"Add to Cart\". It was about "), "\(found.text.prefix(400))")
            #expect(found.text.contains(" screens further down the page; now scrolled into view."), "\(found.text.prefix(400))")
            #expect(found.text.contains("button \"Add to cart\" — about "), "the “also bought” row is listed after it")
            #expect(found.data?["matches"]?.intValue == 21, "the buy box and 20 “Add to cart” buttons; the span labelling it isn't another")
            #expect(found.text.contains("…and 12 more"))
            let after = try #require(sessions.currentSnapshot("default"))
            #expect(after.element(ref)?.inViewport == true)
            let clicked = try await tools.tool(named: "browser.click")!.run(["ref": .string(ref)], context: ctx)
            #expect(clicked.ok, "\(clicked.text)")
            #expect(try await status(driver, tab) == "Cart: 1 item")

            // A search that matches nearly everything stays quick and short.
            let started = ContinuousClock.now
            let everything = try await tools.tool(named: "browser.find")!.run(["text": "e"], context: ctx)
            #expect(ContinuousClock.now - started < .seconds(5))
            #expect(everything.ok && (everything.data?["matches"]?.intValue ?? 0) > 500, "\(everything.text.prefix(300))")
            #expect(everything.text.count < 9000)
        }
    }

    @Test func findLooksInFramesAndShadowRoots() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { _, driver, server in
            let (tab, _) = try await ChromeHarness.openHome(driver, server, path: "/framed")
            let inFrame = try await driver.find(tabID: tab, text: "Deep frame button")
            let frameMatch = try #require(inFrame.match)
            #expect(frameMatch.location == "in frame “Checkout frame”, further down", "\(frameMatch.location)")
            #expect(inFrame.scrolled && !inFrame.stillOutOfView)
            #expect(inFrame.snapshot.element(frameMatch.ref)?.inViewport == true)
            let clicked = try await driver.click(tabID: tab, ref: frameMatch.ref)
            #expect(!clicked.notes.contains { $0.contains("by script") }, "\(clicked.notes)")
            #expect(try await driver.snapshot(tabID: tab).named("Deep frame clicked") != nil)

            let inShadow = try await driver.find(tabID: tab, text: "shadow deep")
            let shadowMatch = try #require(inShadow.match)
            #expect(shadowMatch.location.hasSuffix("further down the page"), "\(shadowMatch.location)")
            #expect(inShadow.snapshot.element(shadowMatch.ref)?.inViewport == true)
            _ = try await driver.click(tabID: tab, ref: shadowMatch.ref)
            #expect(try await driver.snapshot(tabID: tab).named("Shadow deep clicked") != nil)

            // Plain text that isn't a control is found too, and gets a ref of its own.
            // (The page is scrolled down to the shadow button by now.)
            let heading = try await driver.find(tabID: tab, text: "Framed")
            #expect(heading.match?.role == "text" && heading.match?.location.hasSuffix("further up the page") == true, "\(String(describing: heading.match))")
            #expect(heading.snapshot.element(heading.match?.ref ?? "")?.role == "text")
            #expect(heading.snapshot.element(heading.match?.ref ?? "")?.inViewport == true)
            let again = try await driver.find(tabID: tab, text: "framed")
            #expect(again.match?.location == "on screen" && !again.scrolled, "\(String(describing: again.match))")
            #expect(again.snapshot.element(again.match?.ref ?? "")?.pinned == true)
            // A plain look afterwards drops the pinned text, but the page hasn't changed.
            let plain = try await driver.snapshot(tabID: tab)
            #expect(plain.element(again.match?.ref ?? "") == nil)
            #expect(plain.fingerprint == again.snapshot.fingerprint)
            #expect(plain.changeSummary(since: again.snapshot) == "No visible change on the page.")
            let nothing = try await driver.find(tabID: tab, text: "Not on this page at all")
            #expect(nothing.match == nil && nothing.total == 0)
        }
    }

    @Test func datePickerDaysAreListedAndFound() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server, path: "/calendar")
            #expect(snap.named("December 5, 2026")?.role == "gridcell", "days with tabindex -1 are still listed")
            let day = try await driver.find(tabID: tab, text: "December 5,", role: "gridcell")
            let match = try #require(day.match)
            #expect(match.name == "December 5, 2026")
            _ = try await driver.click(tabID: tab, ref: match.ref)
            #expect(try await status(driver, tab) == "Departure: December 5")
        }
    }

    @Test func overlaysWithoutARoleScrollToo() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server, path: "/overlay")
            #expect(snap.modal?.kind == "popup" && snap.modal?.name == "All photos", "\(String(describing: snap.modal))")
            let outcome = try await driver.scroll(tabID: tab, direction: .down)
            #expect(outcome.moved && outcome.scrolled == "the “All photos” popup", "\(outcome)")
            #expect(try await driver.snapshot(tabID: tab).scrollY == 0)
        }
    }

    @Test func dialogsThatScrollByScriptGetARealWheel() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { _, driver, server in
            let (tab, snap) = try await ChromeHarness.openHome(driver, server, path: "/wheel")
            #expect(snap.modal?.name == "Wheel list")
            let outcome = try await driver.scroll(tabID: tab, direction: .down)
            #expect(outcome.moved && outcome.scrolled == "the “Wheel list” dialog", "\(outcome)")
            let moved = try await driver.evaluate(tabID: tab, "document.getElementById('rows').style.transform")
            #expect(moved.stringValue?.hasPrefix("translateY(-") == true, "\(moved)")
        }
    }

    @Test func fingerprintsAreInEveryPageResultAndOnlyChangeWithThePage() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { backend, _, server in
            let (tools, ctx, _) = setUp(backend)
            func fingerprint(_ o: ToolOutput) -> String? { o.data?["fingerprint"]?.stringValue }
            let opened = try await tools.tool(named: "browser.open")!.run(["url": .string(server.url("/second"))], context: ctx)
            let start = try #require(fingerprint(opened))
            let look = try await tools.tool(named: "browser.snapshot")!.run([:], context: ctx)
            #expect(fingerprint(look) == start)
            let scroll = try await tools.tool(named: "browser.scroll")!.run(["direction": "down"], context: ctx)
            #expect(scroll.text.hasPrefix("Nothing scrolled — already at the bottom."), "\(scroll.text)")
            #expect(scroll.text.contains("use browser.find"))
            #expect(fingerprint(scroll) == start, "a scroll that moved nothing leaves the page as it was")
            let wait = try await tools.tool(named: "browser.wait")!.run(["for": "load"], context: ctx)
            #expect(fingerprint(wait) == start)

            let home = try await tools.tool(named: "browser.open")!.run(["url": .string(server.url("/"))], context: ctx)
            let homePrint = try #require(fingerprint(home))
            #expect(homePrint != start)
            let fancy = try #require(home.data?["elements"]?.arrayValue?.first { $0["name"]?.stringValue == "Fancy button" }?["ref"]?.stringValue)
            let clicked = try await tools.tool(named: "browser.click")!.run(["ref": .string(fancy)], context: ctx)
            #expect(clicked.ok)
            #expect(fingerprint(clicked).map { $0 != homePrint } == true, "the click relabelled a control")
            let pressed = try await tools.tool(named: "browser.press")!.run(["keys": "Escape"], context: ctx)
            #expect(fingerprint(pressed) == fingerprint(clicked))
            let found = try await tools.tool(named: "browser.find")!.run(["text": "Press me"], context: ctx)
            #expect(fingerprint(found) != nil)
            let scrolled = try await tools.tool(named: "browser.scroll")!.run(["direction": "down"], context: ctx)
            #expect(scrolled.text.hasPrefix("Scrolled the page down."), "\(scrolled.text)")
            #expect(fingerprint(scrolled) != fingerprint(found))
            let back = try await tools.tool(named: "browser.back")!.run([:], context: ctx)
            #expect(fingerprint(back) == start)
        }
    }

    @Test func botChecksAreRecognized() async throws {
        try await ChromeHarness.run(route: FindFixtures.route) { backend, driver, server in
            let (tools, ctx, _) = setUp(backend)
            let captcha = try await tools.tool(named: "browser.open")!.run(["url": .string(server.url("/captcha"))], context: ctx)
            #expect(captcha.data?["botCheck"]?.boolValue == true)
            #expect(captcha.text.contains("The page is asking to verify you're human"), "\(captcha.text)")
            let (challengeTab, challenge) = try await ChromeHarness.openHome(driver, server, path: "/challenge")
            #expect(challenge.botCheck == "a reCAPTCHA challenge", "\(String(describing: challenge.botCheck))")
            try await driver.closeTab(challengeTab)
            for path in ["/contact", "/robots", "/", "/product"] {
                let (tab, snap) = try await ChromeHarness.openHome(driver, server, path: path)
                #expect(snap.botCheck == nil, "\(path): \(snap.botCheck ?? "")")
                try await driver.closeTab(tab)
            }
        }
    }
}

// MARK: - The real extension

// Part of the existing real-extension suite, so its serialization covers this too: one Chrome
// for Testing at a time (pairing is slow on a busy Mac).
extension BrowserExtensionChromeTests {
    @Test func findScrollAndClickWorkInTheUsersChrome() async throws {
        try await ChromeForTesting.run(route: FindFixtures.route) { backend, _, server in
            let hub = BrowserHub()
            hub.register(backend)
            var settings = AppSettings()
            settings.browser.backend = .extensionBridge
            let sessions = BrowserSessions()
            let tools = ToolRegistry(BrowserTools.make(hub: hub, sessions: sessions))
            let ctx = ToolContext(settings: settings, gate: ExecutionGate())
            let opened = try await tools.tool(named: "browser.open")!.run(["url": .string(server.url("/filters"))], context: ctx)
            #expect(opened.ok && opened.text.contains("Further down in this dialog"), "\(opened.text)")
            let scrolled = try await tools.tool(named: "browser.scroll")!.run(["direction": "down"], context: ctx)
            #expect(scrolled.text.hasPrefix("Scrolled the “Filters” dialog down."), "\(scrolled.text)")
            let found = try await tools.tool(named: "browser.find")!.run(["text": "Cabin", "role": "button"], context: ctx)
            #expect(found.ok, "\(found.text)")
            let ref = try #require(found.data?["match"]?["ref"]?.stringValue)
            let clicked = try await tools.tool(named: "browser.click")!.run(["ref": .string(ref)], context: ctx)
            #expect(clicked.ok && clicked.text.contains("Filter: Cabin"), "\(clicked.text)")
            #expect(clicked.data?["fingerprint"]?.stringValue != found.data?["fingerprint"]?.stringValue)
        }
    }
}
