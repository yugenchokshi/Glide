import Foundation

/// A link found on a page.
public struct PageLink: Codable, Sendable, Hashable {
    public var text: String
    public var url: String

    public init(text: String, url: String) {
        self.text = text
        self.url = url
    }
}

/// A page reduced to what a model needs: the title, the readable text (headings as markdown,
/// list items, table rows as `a | b`) and the main links.
public struct ReadablePage: Sendable, Hashable {
    public var title: String
    public var text: String
    public var links: [PageLink]
}

/// HTML → readable text, without a browser. Page chrome (navigation, footers, sidebars,
/// forms, scripts) is dropped, and when the page marks its main content (<main>, <article>,
/// role="main") and that holds most of the text, only that is kept.
public enum HTMLText {
    /// Containers whose content is never the readable part of a page.
    static let skipped: Set<String> = ["script", "style", "noscript", "svg", "nav", "footer", "aside", "form", "template",
                                       "iframe", "button", "select", "textarea", "object", "canvas", "dialog", "math"]
    /// The subset dropped only on a first pass; if that leaves almost nothing (some sites wrap
    /// the whole page in a <form>), the page is read again keeping them.
    static let softSkipped: Set<String> = ["nav", "footer", "aside", "form"]
    static let paragraphBlocks: Set<String> = ["p", "blockquote", "pre", "table", "ul", "ol", "dl", "figure", "hr", "h4", "h5", "h6", "address", "fieldset", "details"]
    static let lineBlocks: Set<String> = ["div", "section", "article", "main", "header", "li", "tr", "dt", "dd", "br", "figcaption", "summary", "caption", "center", "hgroup", "tbody", "thead", "tfoot", "legend", "option"]

    /// Output beyond this is not collected (the tools truncate far earlier anyway).
    static let maxTextChars = 400_000

    public static func extract(_ html: String, baseURL: URL?, maxLinks: Int = 40) -> ReadablePage {
        let first = run(html, baseURL: baseURL, maxLinks: maxLinks, skip: skipped)
        // Heuristic retry: a page that yields almost no text probably wrapped its content in
        // one of the soft-skipped containers. A second pass is cheap next to the fetch.
        if first.text.count < 200 && html.utf8.count > 500 {
            let second = run(html, baseURL: baseURL, maxLinks: maxLinks, skip: skipped.subtracting(softSkipped))
            if second.text.count > first.text.count * 2 { return second }
        }
        return first
    }

    /// Collapses whitespace and builds paragraphs with at most one blank line between them.
    struct TextBuilder {
        var out = ""
        var pendingSpace = false
        var pendingBreaks = 0
        var pendingPrefix = ""
        /// Characters appended so far; `String.count` is O(n), so it's tracked here.
        var length = 0
        var full: Bool { length >= HTMLText.maxTextChars }

        mutating func breakLine(_ count: Int) { pendingBreaks = max(pendingBreaks, count); pendingSpace = false }
        mutating func prefix(_ p: String) { pendingPrefix = p }

        mutating func append(_ s: String, preformatted: Bool) {
            guard !full else { return }
            for ch in s {
                if preformatted {
                    if ch == "\n" { breakLine(1); flushBreaks(); continue }
                    flush()
                    out.append(ch)
                    length += 1
                } else if ch.isWhitespace {
                    if !out.isEmpty && pendingBreaks == 0 { pendingSpace = true }
                } else {
                    flush()
                    out.append(ch)
                    length += 1
                }
            }
        }

        private mutating func flushBreaks() {
            if pendingBreaks > 0 && !out.isEmpty {
                while out.last == " " { out.removeLast() }
                let have = out.reversed().prefix { $0 == "\n" }.count
                if have < pendingBreaks { out += String(repeating: "\n", count: pendingBreaks - have) }
            }
            pendingBreaks = 0
        }

        private mutating func flush() {
            if pendingBreaks > 0 {
                flushBreaks()
                pendingSpace = false
            } else if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            if !pendingPrefix.isEmpty { out += pendingPrefix; pendingPrefix = "" }
        }

        var text: String { out.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private struct Capture {
        var name: String
        var depth = 1
        var builder = TextBuilder()
    }

    private static func run(_ html: String, baseURL: URL?, maxLinks: Int, skip: Set<String>) -> ReadablePage {
        var all = TextBuilder()
        var main: Capture?, article: Capture?
        var mainDone = false, articleDone = false
        var skipName: String?, skipDepth = 0
        var title = "", inTitle = false, titleDone = false
        var firstH1 = "", inH1 = false
        var ogTitle = ""
        var base = baseURL
        var pre = 0
        var listDepth = 0
        var cellIndex = 0
        var link: (href: String, label: String, text: String, inMain: Bool)?
        var links: [(PageLink, Bool)] = []
        var seen = Set<String>()

        // Captures stop collecting once their element closes; the text is kept for the choice below.
        func emit(_ s: String) {
            all.append(s, preformatted: pre > 0)
            if !mainDone { main?.builder.append(s, preformatted: pre > 0) }
            if !articleDone { article?.builder.append(s, preformatted: pre > 0) }
        }
        func breakLine(_ n: Int) {
            all.breakLine(n)
            if !mainDone { main?.builder.breakLine(n) }
            if !articleDone { article?.builder.breakLine(n) }
        }
        func prefix(_ p: String) {
            all.prefix(p)
            if !mainDone { main?.builder.prefix(p) }
            if !articleDone { article?.builder.prefix(p) }
        }
        func isHidden(_ t: HTMLTag) -> Bool {
            if t.attributes["hidden"] != nil || t.attributes["aria-hidden"] == "true" { return true }
            let style = (t.attributes["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            return style.contains("display:none") || style.contains("visibility:hidden")
        }
        func finishLink() {
            guard let l = link else { return }
            link = nil
            guard links.count < maxLinks * 3 else { return }
            let raw = l.href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !raw.hasPrefix("#"), let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.fragment = nil
            let absolute = comps?.url?.absoluteString ?? url.absoluteString
            guard !seen.contains(absolute) else { return }
            seen.insert(absolute)
            var text = l.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if text.isEmpty { text = l.label }
            if text.isEmpty { text = url.host.map { $0 + url.path } ?? absolute }
            if text.count > 100 { text = String(text.prefix(99)) + "…" }
            links.append((PageLink(text: text, url: absolute), l.inMain))
        }

        HTMLTokenizer.tokenize(html) { token in
            switch token {
            case .start(let t):
                let name = t.name
                // Document metadata counts wherever it appears.
                switch name {
                case "title": if !titleDone { inTitle = true }; return
                case "base": if let h = t.attributes["href"], let u = URL(string: h, relativeTo: baseURL) { base = u.absoluteURL }; return
                case "meta":
                    if ogTitle.isEmpty, t.attributes["property"] == "og:title" || t.attributes["name"] == "twitter:title" { ogTitle = t.attributes["content"] ?? "" }
                    return
                default: break
                }
                if let s = skipName {
                    if name == s && !t.selfClosing && !HTMLTokenizer.voidElements.contains(name) { skipDepth += 1 }
                    return
                }
                if skip.contains(name) || isHidden(t) {
                    if !t.selfClosing && !HTMLTokenizer.voidElements.contains(name) { skipName = name; skipDepth = 1 }
                    return
                }
                if !mainDone, main == nil, name == "main" || t.attributes["role"] == "main" {
                    main = Capture(name: name)
                } else if let m = main, name == m.name, !t.selfClosing {
                    main?.depth += 1
                }
                if !articleDone, article == nil, name == "article" {
                    article = Capture(name: name)
                } else if article != nil, name == "article" {
                    article?.depth += 1
                }
                switch name {
                case "h1", "h2", "h3":
                    breakLine(2)
                    prefix(String(repeating: "#", count: Int(String(name.last ?? "1")) ?? 1) + " ")
                    if name == "h1" && firstH1.isEmpty { inH1 = true }
                case "li":
                    breakLine(1)
                    prefix(String(repeating: "  ", count: max(0, listDepth - 1)) + "- ")
                case "ul", "ol":
                    listDepth += 1
                    breakLine(listDepth == 1 ? 2 : 1)
                case "tr":
                    breakLine(1)
                    cellIndex = 0
                case "td", "th":
                    if cellIndex > 0 { emit(" | ") }
                    cellIndex += 1
                case "pre": pre += 1; breakLine(2)
                case "br": breakLine(1)
                case "img":
                    break
                case "a":
                    finishLink()
                    if let href = t.attributes["href"] {
                        link = (href, t.attributes["aria-label"] ?? t.attributes["title"] ?? "", "", main != nil || article != nil)
                    }
                default:
                    if paragraphBlocks.contains(name) { breakLine(2) } else if lineBlocks.contains(name) { breakLine(1) }
                }
            case .end(let name):
                if name == "title" { if inTitle { inTitle = false; titleDone = !title.isEmpty }; return }
                if let s = skipName {
                    if name == s { skipDepth -= 1; if skipDepth <= 0 { skipName = nil } }
                    return
                }
                switch name {
                case "h1", "h2", "h3": breakLine(2); inH1 = false
                case "ul", "ol": listDepth = max(0, listDepth - 1); breakLine(listDepth == 0 ? 2 : 1)
                case "pre": pre = max(0, pre - 1); breakLine(2)
                case "a": finishLink()
                case "tr": breakLine(1)
                default:
                    if paragraphBlocks.contains(name) { breakLine(2) } else if lineBlocks.contains(name) { breakLine(1) }
                }
                if let m = main, name == m.name {
                    main?.depth -= 1
                    if (main?.depth ?? 0) <= 0 { mainDone = true }
                }
                if article != nil, name == "article" {
                    article?.depth -= 1
                    if (article?.depth ?? 0) <= 0 { articleDone = true }
                }
            case .text(let s):
                if inTitle { title += s; return }
                guard skipName == nil else { return }
                if inH1 { firstH1 += s }
                if link != nil { link?.text += s }
                emit(s)
            }
        }
        finishLink()

        let allText = all.text
        var text = allText
        let threshold = max(300, allText.count * 3 / 10)
        if let m = main?.builder.text, m.count >= threshold { text = m } else if let a = article?.builder.text, a.count >= threshold { text = a }
        let chosenMain = text != allText
        var ordered = links
        if chosenMain { ordered.sort { $0.1 && !$1.1 } }
        func clean(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var pageTitle = clean(title)
        if pageTitle.isEmpty { pageTitle = clean(ogTitle) }
        if pageTitle.isEmpty { pageTitle = clean(firstH1) }
        return ReadablePage(title: pageTitle, text: text, links: Array(ordered.prefix(maxLinks).map(\.0)))
    }
}
