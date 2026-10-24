import Foundation

/// The no-browser web family: `web.fetch`, `web.fetch_many` and `web.search`. All are read-only.
public enum WebTools {
    /// Call once at launch (app and CLI).
    public static func install() {
        ToolRegistry.registerFactory("web") { _ in tools() }
    }

    /// `search` overrides `WebSearch.backend` (tests pass a local backend).
    public static func tools(search: (any WebSearchBackend)? = nil) -> [any AgentTool] {
        [WebFetchTool(), WebFetchManyTool(), WebSearchTool(backend: search)]
    }

    /// Risk of reading one URL: refused schemes are blocked; this Mac and the local network
    /// are medium (a GET to a router or dev server can still change something); the public
    /// web is low.
    static func verdict(for raw: String, summary: String) -> ToolVerdict {
        if let reason = WebFetcher.refusedScheme(raw) { return ToolVerdict(risk: .high, reasons: ["not a web address"], blocked: reason, summary: summary) }
        guard let url = try? WebFetcher.validate(raw) else { return ToolVerdict(risk: .low, summary: summary) }
        if WebFetcher.isLocalHost(url.host) {
            return ToolVerdict(risk: .medium, reasons: ["reaches \(url.host ?? "a local address") on this Mac or your local network"], summary: summary)
        }
        return ToolVerdict(risk: .low, summary: summary)
    }

    /// Model-facing text for one page: title, address, text cut to `maxChars`, then links.
    static func describe(_ page: WebPage, maxChars: Int, includeLinks: Bool = true) -> (text: String, cut: Bool) {
        var body = page.text
        var cut = page.truncated
        if body.count > maxChars { body = String(body.prefix(maxChars)) + "\n…[\(page.text.count - maxChars) more characters]"; cut = true }
        var out = "# \(page.title)\n\(page.url)"
        if !page.ok { out += "\nHTTP \(page.status)" }
        out += "\n\n" + body
        if includeLinks && !page.links.isEmpty {
            // The model-visible list is shorter than the data's, to keep the text near 8k.
            out += "\n\nLinks:\n" + page.links.prefix(25).map { "- \($0.text) → \($0.url)" }.joined(separator: "\n")
        }
        return (out, cut)
    }

    static func fetchFailure(_ error: Error, url: String, start: Date) -> ToolOutput {
        if let e = error as? AutomationError, e == .stopped { return ToolOutput(ok: false, text: "Stopped.") }
        return ToolOutput(ok: false, text: "Couldn't fetch \(url): \(error.localizedDescription)", data: .object(["url": .string(url), "error": .string(error.localizedDescription)]),
                          durationMs: Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - web.fetch

struct WebFetchTool: AgentTool {
    static let defaultChars = 6000
    static let maxChars = 50_000

    let spec = ToolSpec(
        name: "web.fetch",
        summary: "Download a web page (or PDF/JSON) without a browser and return its readable text, title and main links. Fast; use it for public pages that don't need a login.",
        inputSchema: [
            "type": "object",
            "properties": [
                "url": ["type": "string", "description": "http(s) address."],
                "max_chars": ["type": "integer", "description": "Text to return (default 6000, max 50000)."],
            ],
            "required": ["url"],
        ],
        category: .web,
        readOnly: true
    )

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let raw = arguments.optionalString("url") ?? ""
        return WebTools.verdict(for: raw, summary: "Fetch \(raw.prefix(200))")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let start = Date()
        let raw = try arguments.requiredString("url")
        let maxChars = min(max(arguments.optionalInt("max_chars") ?? Self.defaultChars, 200), Self.maxChars)
        try await context.gate.checkpoint()
        let url: URL
        do { url = try WebFetcher.validate(raw) } catch { return ToolOutput(ok: false, text: error.localizedDescription) }
        let page: WebPage
        do { page = try await WebFetcher.page(url, gate: context.gate) } catch let e as AutomationError where e == .stopped {
            throw e
        } catch {
            return WebTools.fetchFailure(error, url: url.absoluteString, start: start)
        }
        let (text, cut) = WebTools.describe(page, maxChars: maxChars)
        var data = page.json
        if case .object(var o) = data {
            o["text"] = .string(String(page.text.prefix(maxChars)))
            o["truncated"] = .bool(cut)
            data = .object(o)
        }
        return ToolOutput(ok: page.ok, text: toolTruncate(text, max: maxChars + 3000), data: data, durationMs: Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - web.fetch_many

struct WebFetchManyTool: AgentTool {
    static let maxURLs = 8
    static let defaultChars = 3000
    static let maxChars = 20_000

    let spec = ToolSpec(
        name: "web.fetch_many",
        summary: "Fetch up to 8 web pages at once (in parallel) and return each one's readable text. Use instead of several web.fetch calls.",
        inputSchema: [
            "type": "object",
            "properties": [
                "urls": ["type": "array", "items": ["type": "string"], "description": "Up to 8 http(s) addresses."],
                "max_chars_each": ["type": "integer", "description": "Text per page (default 3000, max 20000)."],
            ],
            "required": ["urls"],
        ],
        category: .web,
        readOnly: true
    )

    static func urls(_ arguments: JSONValue) -> [String] {
        SheetArgs.stringList(SheetArgs.structured(arguments["urls"])) ?? []
    }

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let list = Self.urls(arguments)
        let summary = "Fetch \(list.count) page\(list.count == 1 ? "" : "s")"
        var worst = ToolVerdict(risk: .low, summary: summary)
        for u in list.prefix(Self.maxURLs) {
            let v = WebTools.verdict(for: u, summary: summary)
            if v.blocked != nil { return v }
            if v.risk > worst.risk { worst.risk = v.risk }
            worst.reasons += v.reasons
        }
        return worst
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let start = Date()
        let all = Self.urls(arguments)
        guard !all.isEmpty else { throw ToolError.invalidArguments("give “urls”, a list of web addresses") }
        let list = Array(all.prefix(Self.maxURLs))
        let maxChars = min(max(arguments.optionalInt("max_chars_each") ?? Self.defaultChars, 200), Self.maxChars)
        try await context.gate.checkpoint()
        let gate = context.gate

        let pages: [(Int, Result<WebPage, Error>)] = await withTaskGroup(of: (Int, Result<WebPage, Error>).self) { group in
            for (i, raw) in list.enumerated() {
                group.addTask {
                    do {
                        let url = try WebFetcher.validate(raw)
                        return (i, .success(try await WebFetcher.page(url, gate: gate)))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            var out: [(Int, Result<WebPage, Error>)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }
        }
        if gate.isStopped { throw AutomationError.stopped }

        var sections: [String] = []
        var items: [JSONValue] = []
        var okCount = 0
        for (i, result) in pages {
            switch result {
            case .success(let page):
                if page.ok { okCount += 1 }
                let (text, cut) = WebTools.describe(page, maxChars: maxChars, includeLinks: false)
                sections.append("## [\(i + 1)]\n" + text)
                var o = page.json.objectValue ?? [:]
                o["text"] = .string(String(page.text.prefix(maxChars)))
                o["truncated"] = .bool(cut)
                o["links"] = .array(page.links.prefix(10).map { .object(["text": .string($0.text), "url": .string($0.url)]) })
                items.append(.object(o))
            case .failure(let error):
                sections.append("## [\(i + 1)] \(list[i])\nFailed: \(error.localizedDescription)")
                items.append(.object(["url": .string(list[i]), "error": .string(error.localizedDescription)]))
            }
        }
        var text = sections.joined(separator: "\n\n")
        if all.count > list.count { text += "\n\n(Only the first \(Self.maxURLs) URLs were fetched; \(all.count - list.count) skipped.)" }
        return ToolOutput(ok: okCount > 0, text: toolTruncate(text, max: max(8000, maxChars * list.count / 2)), data: .array(items),
                          durationMs: Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - web.search

struct WebSearchTool: AgentTool {
    static let defaultResults = 8
    static let maxResults = 25
    let backend: (any WebSearchBackend)?

    let spec = ToolSpec(
        name: "web.search",
        summary: "Search the web (no browser) and get result titles, URLs and snippets. Follow up with web.fetch or web.fetch_many to read pages.",
        inputSchema: [
            "type": "object",
            "properties": [
                "query": ["type": "string"],
                "max_results": ["type": "integer", "description": "Default 8, max 25."],
            ],
            "required": ["query"],
        ],
        category: .web,
        readOnly: true
    )

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        ToolVerdict(risk: .low, summary: "Search the web for “\((arguments.optionalString("query") ?? "").prefix(200))”")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let start = Date()
        let query = try arguments.requiredString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { throw ToolError.invalidArguments("the query must be 1–500 characters") }
        let limit = min(max(arguments.optionalInt("max_results") ?? Self.defaultResults, 1), Self.maxResults)
        try await context.gate.checkpoint()
        let engine = backend ?? WebSearch.backend
        let results: [WebSearchResult]
        do { results = try await engine.search(query, maxResults: limit, gate: context.gate) } catch let e as AutomationError where e == .stopped {
            throw e
        } catch {
            return ToolOutput(ok: false, text: "Search failed: \(error.localizedDescription)", durationMs: Date().timeIntervalSince(start) * 1000)
        }
        let text = results.isEmpty
            ? "No results for “\(query)”."
            : results.enumerated().map { "\($0.offset + 1). \($0.element.title)\n   \($0.element.url)" + ($0.element.snippet.isEmpty ? "" : "\n   \($0.element.snippet)") }.joined(separator: "\n")
        let data: JSONValue = .object([
            "query": .string(query), "engine": .string(engine.name),
            "results": .array(results.map { .object(["title": .string($0.title), "url": .string($0.url), "snippet": .string($0.snippet)]) }),
        ])
        return ToolOutput(ok: true, text: toolTruncate(text), data: data, durationMs: Date().timeIntervalSince(start) * 1000)
    }
}
