import Foundation

public struct WebSearchResult: Codable, Sendable, Hashable {
    public var title: String
    public var url: String
    public var snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

/// A search engine `web.search` can use. DuckDuckGo's HTML page is the default because it needs
/// no account or key; a browser-driven or API-based engine can be plugged in by setting
/// `WebSearch.backend`.
public protocol WebSearchBackend: Sendable {
    var name: String { get }
    func search(_ query: String, maxResults: Int, gate: ExecutionGate?) async throws -> [WebSearchResult]
}

public enum WebSearch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: any WebSearchBackend = DuckDuckGoSearch()

    /// The engine used by `web.search` when a tool wasn't built with its own.
    public static var backend: any WebSearchBackend {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Searches through https://html.duckduckgo.com/html/, the no-JavaScript results page.
public struct DuckDuckGoSearch: WebSearchBackend {
    public static let defaultEndpoint = URL(string: "https://html.duckduckgo.com/html/")!
    public let endpoint: URL
    public var name: String { "DuckDuckGo" }

    public init(endpoint: URL = DuckDuckGoSearch.defaultEndpoint) {
        self.endpoint = endpoint
    }

    public func search(_ query: String, maxResults: Int, gate: ExecutionGate?) async throws -> [WebSearchResult] {
        // A form POST, like the page's own search box. "+" must be escaped: in a form body it means space.
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "b", value: "")]
        let body = (comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let request = WebFetcher.makeRequest(endpoint, method: "POST", body: Data(body.utf8), contentType: "application/x-www-form-urlencoded")
        let resource = try await WebFetcher.fetch(request, gate: gate, maxBytes: 2 << 20)
        guard (200..<300).contains(resource.status) || resource.status == 202 else {
            throw WebError.network("DuckDuckGo answered with HTTP \(resource.status). Try again in a moment.")
        }
        let parsed = DuckDuckGoParser.parse(WebFetcher.decodeText(resource), maxResults: maxResults)
        if parsed.results.isEmpty && parsed.challenged {
            // Never try to get around a bot check; say so and let the planner pick another route.
            throw WebError.challenge("DuckDuckGo asked for a human check instead of returning results. Try again later, or search in the browser.")
        }
        return parsed.results
    }
}

/// Reads the result list out of DuckDuckGo's HTML results page.
enum DuckDuckGoParser {
    struct Parsed {
        var results: [WebSearchResult]
        /// The page is a bot check rather than results.
        var challenged: Bool
    }

    private enum Field { case title, snippet }

    static func parse(_ html: String, maxResults: Int) -> Parsed {
        var results: [WebSearchResult] = []
        var seen = Set<String>()
        var title = "", url = "", snippet = "", isAd = false, started = false
        var capturing: (field: Field, name: String, depth: Int)?

        func commit() {
            defer { title = ""; url = ""; snippet = ""; isAd = false; started = false }
            guard started, !isAd else { return }
            let t = clean(title), u = url
            guard !t.isEmpty, !u.isEmpty, !seen.contains(u) else { return }
            seen.insert(u)
            results.append(WebSearchResult(title: t, url: u, snippet: clean(snippet)))
        }

        HTMLTokenizer.tokenize(html) { token in
            switch token {
            case .start(let tag):
                if let c = capturing, tag.name == c.name, !tag.selfClosing { capturing?.depth += 1 }
                let isResultBlock = (tag.has(class: "result") || tag.has(class: "web-result")) && !tag.has(class: "result__body")
                if isResultBlock && (tag.name == "div" || tag.name == "article" || tag.name == "li") {
                    commit()
                    started = true
                    isAd = tag.has(class: "result--ad") || tag.has(class: "result--ad--small")
                }
                if tag.name == "a", tag.has(class: "result__a") {
                    if !started { commit(); started = true }
                    let href = tag.attributes["href"] ?? ""
                    if isAdLink(href) { isAd = true }
                    url = unwrap(href) ?? ""
                    title = ""
                    capturing = (.title, "a", 1)
                } else if tag.has(class: "result__snippet"), started {
                    snippet = ""
                    capturing = (.snippet, tag.name, 1)
                } else if tag.name == "a", tag.has(class: "result__url"), url.isEmpty, let href = tag.attributes["href"] {
                    url = unwrap(href) ?? ""
                }
            case .end(let name):
                if let c = capturing, name == c.name {
                    capturing?.depth -= 1
                    if (capturing?.depth ?? 0) <= 0 { capturing = nil }
                }
            case .text(let s):
                switch capturing?.field {
                case .title?: title += s
                case .snippet?: snippet += s
                case nil: break
                }
            }
        }
        commit()
        let lower = html.lowercased()
        let challenged = lower.contains("anomaly-modal") || lower.contains("anomaly.js") || lower.contains("challenge-form")
            || lower.contains("bots use duckduckgo too")
        return Parsed(results: Array(results.prefix(max(0, maxResults))), challenged: challenged)
    }

    static func clean(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    static func isAdLink(_ href: String) -> Bool {
        href.contains("duckduckgo.com/y.js") || href.contains("ad_domain=") || href.contains("ad_provider=")
    }

    /// Result links go through "//duckduckgo.com/l/?uddg=<encoded target>&rut=…"; return the target.
    static func unwrap(_ href: String) -> String? {
        var h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        if h.hasPrefix("//") { h = "https:" + h } else if h.hasPrefix("/") { h = "https://duckduckgo.com" + h }
        guard let comps = URLComponents(string: h) else { return nil }
        if let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value, let u = URL(string: target),
           let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return u.absoluteString
        }
        guard let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if let host = comps.host?.lowercased(), host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com") { return nil }
        return comps.url?.absoluteString
    }
}
