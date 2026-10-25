import Foundation

/// A website Glide knows by its spoken name, with how to search it.
public struct KnownSite: Sendable, Hashable {
    /// How Glide says it: "YouTube", "Google Flights".
    public var name: String
    public var url: URL
    /// Search URL with `{q}` where the percent-encoded query goes; nil when the site has none.
    public var searchTemplate: String?
    /// Desktop apps that are the same service; "open ChatGPT" prefers the app when installed.
    public var appBundleIDs: [String]

    public init(name: String, url: URL, searchTemplate: String? = nil, appBundleIDs: [String] = []) {
        self.name = name
        self.url = url
        self.searchTemplate = searchTemplate
        self.appBundleIDs = appBundleIDs
    }

    public var host: String { url.host() ?? url.absoluteString }

    public func searchURL(_ query: String) -> URL? {
        guard let searchTemplate else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        let q = query.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: searchTemplate.replacingOccurrences(of: "{q}", with: q))
    }
}

/// The sites "open …" and "search … on …" understand without a model, and the URL rules for
/// everything else said out loud.
public enum SiteCatalog {
    static func site(_ name: String, _ url: String, search: String? = nil, apps: [String] = []) -> KnownSite {
        // Literal, known-good URLs; a typo here is a programming error caught by the tests.
        KnownSite(name: name, url: URL(string: url) ?? URL(filePath: "/"), searchTemplate: search, appBundleIDs: apps)
    }

    /// Spoken names (compact-normalized, see `AppResolver.compact`) → site.
    static let byName: [String: KnownSite] = {
        let rows: [([String], KnownSite)] = [
            (["chatgpt", "chat gpt", "openai"], site("ChatGPT", "https://chatgpt.com/", search: "https://chatgpt.com/?q={q}", apps: ["com.openai.chat"])),
            (["claude", "claude ai"], site("Claude", "https://claude.ai/new", search: "https://claude.ai/new?q={q}", apps: ["com.anthropic.claudefordesktop"])),
            (["youtube", "you tube", "yt"], site("YouTube", "https://www.youtube.com/", search: "https://www.youtube.com/results?search_query={q}")),
            (["youtube music"], site("YouTube Music", "https://music.youtube.com/", search: "https://music.youtube.com/search?q={q}")),
            (["gmail", "g mail", "google mail"], site("Gmail", "https://mail.google.com/", search: "https://mail.google.com/mail/u/0/#search/{q}")),
            (["google", "the web", "web", "the internet", "internet"], site("Google", "https://www.google.com/", search: "https://www.google.com/search?q={q}")),
            (["google maps", "maps google"], site("Google Maps", "https://www.google.com/maps", search: "https://www.google.com/maps/search/{q}")),
            (["google flights", "flights"], site("Google Flights", "https://www.google.com/travel/flights", search: "https://www.google.com/travel/flights?q={q}")),
            (["google docs", "docs"], site("Google Docs", "https://docs.google.com/document/")),
            (["google sheets", "sheets"], site("Google Sheets", "https://docs.google.com/spreadsheets/")),
            (["google drive", "drive"], site("Google Drive", "https://drive.google.com/", search: "https://drive.google.com/drive/search?q={q}")),
            (["google calendar"], site("Google Calendar", "https://calendar.google.com/")),
            (["amazon"], site("Amazon", "https://www.amazon.com/", search: "https://www.amazon.com/s?k={q}")),
            (["github", "git hub"], site("GitHub", "https://github.com/", search: "https://github.com/search?q={q}")),
            (["linkedin", "linked in"], site("LinkedIn", "https://www.linkedin.com/", search: "https://www.linkedin.com/search/results/all/?keywords={q}")),
            (["airbnb", "air bnb"], site("Airbnb", "https://www.airbnb.com/", search: "https://www.airbnb.com/s/{q}/homes")),
            (["wikipedia", "wiki"], site("Wikipedia", "https://en.wikipedia.org/", search: "https://en.wikipedia.org/w/index.php?search={q}")),
            (["netflix"], site("Netflix", "https://www.netflix.com/", search: "https://www.netflix.com/search?q={q}")),
            (["x", "twitter", "x twitter", "x com"], site("X", "https://x.com/", search: "https://x.com/search?q={q}")),
            (["reddit"], site("Reddit", "https://www.reddit.com/", search: "https://www.reddit.com/search/?q={q}")),
            (["ebay"], site("eBay", "https://www.ebay.com/", search: "https://www.ebay.com/sch/i.html?_nkw={q}")),
            (["spotify"], site("Spotify", "https://open.spotify.com/", search: "https://open.spotify.com/search/{q}", apps: ["com.spotify.client"])),
            (["slack"], site("Slack", "https://app.slack.com/", apps: ["com.tinyspeck.slackmacgap"])),
            (["notion"], site("Notion", "https://www.notion.so/", apps: ["notion.id"])),
            (["figma"], site("Figma", "https://www.figma.com/", apps: ["com.figma.Desktop"])),
            (["whatsapp", "whats app"], site("WhatsApp", "https://web.whatsapp.com/", apps: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"])),
            (["discord"], site("Discord", "https://discord.com/app", apps: ["com.hnc.Discord"])),
            (["instagram", "insta"], site("Instagram", "https://www.instagram.com/")),
            (["facebook"], site("Facebook", "https://www.facebook.com/")),
            (["stack overflow", "stackoverflow"], site("Stack Overflow", "https://stackoverflow.com/", search: "https://stackoverflow.com/search?q={q}")),
            (["perplexity"], site("Perplexity", "https://www.perplexity.ai/", search: "https://www.perplexity.ai/search?q={q}")),
            (["hacker news", "hn"], site("Hacker News", "https://news.ycombinator.com/")),
            (["bing"], site("Bing", "https://www.bing.com/", search: "https://www.bing.com/search?q={q}")),
            (["duckduckgo", "duck duck go"], site("DuckDuckGo", "https://duckduckgo.com/", search: "https://duckduckgo.com/?q={q}")),
            (["yelp"], site("Yelp", "https://www.yelp.com/", search: "https://www.yelp.com/search?find_desc={q}")),
            (["imdb"], site("IMDb", "https://www.imdb.com/", search: "https://www.imdb.com/find/?q={q}")),
            (["booking", "booking com"], site("Booking.com", "https://www.booking.com/", search: "https://www.booking.com/searchresults.html?ss={q}")),
            (["outlook web", "outlook com"], site("Outlook", "https://outlook.live.com/mail/")),
        ]
        var out: [String: KnownSite] = [:]
        for (names, s) in rows { for n in names { out[AppResolver.compact(n)] = s } }
        return out
    }()

    public static func site(named spoken: String) -> KnownSite? {
        byName[AppResolver.compact(spoken)]
    }

    /// The catalog entry for a host the user said ("youtube.com" → YouTube), so its name is
    /// used in what Glide says back.
    static func site(forHost host: String) -> KnownSite? {
        let h = host.lowercased().replacingOccurrences(of: "www.", with: "")
        return byName.values.first { $0.host.lowercased().replacingOccurrences(of: "www.", with: "") == h }
    }

    /// Top-level domains accepted in a spoken or typed bare domain ("chatgpt.com"). A short list
    /// on purpose: "report.pdf" or "notes.txt" must not become a website.
    static let tlds: Set<String> = [
        "com", "org", "net", "io", "ai", "dev", "app", "co", "edu", "gov", "me", "tv", "us", "uk", "in", "de", "fr", "jp",
        "ca", "au", "xyz", "so", "gg", "ly", "fm", "news", "info", "biz", "tech", "site", "page", "nl", "es", "it", "se",
        "ch", "br", "mx", "nz", "ie", "sg", "to", "sh", "is", "cc", "ws", "chat", "blog", "store", "shop",
    ]

    /// An http(s) URL for what the user said, or nil. Accepts "https://…", "www.…" and bare
    /// domains with a known TLD; turns spoken "dot" into ".". Refuses every other scheme
    /// (file:, javascript:, custom app schemes), credentials in the URL, and anything with spaces.
    public static func webURL(from spoken: String) -> URL? {
        var s = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: " dot ", with: ".", options: .caseInsensitive)
        s = s.replacingOccurrences(of: " slash ", with: "/", options: .caseInsensitive)
        while let last = s.last, ".,!?;".contains(last) { s.removeLast() }
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        let lower = s.lowercased()
        let spelledScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        if !spelledScheme {
            // Any other scheme ("file:", "javascript:", "mailto:", "slack://") is refused.
            if lower.contains(":") { return nil }
            s = "https://" + s
        }
        guard let comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased(), !host.isEmpty, comps.user == nil, comps.password == nil else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
        // A spelled-out scheme may use any TLD; a bare word needs one we know.
        if !spelledScheme, !tlds.contains(String(tld)) { return nil }
        return comps.url
    }
}
