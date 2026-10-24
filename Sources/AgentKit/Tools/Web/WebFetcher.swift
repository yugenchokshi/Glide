import Foundation
import PDFKit

/// Errors from fetching, worded for the user and the model.
public enum WebError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case refused(String)
    case network(String)
    case timeout(String)
    case challenge(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let m), .refused(let m), .network(let m), .timeout(let m), .challenge(let m): return m
        }
    }
}

/// Raw bytes of one HTTP response, capped.
public struct FetchedResource: Sendable {
    public var requestedURL: URL
    public var finalURL: URL
    public var status: Int
    public var mimeType: String
    public var textEncodingName: String?
    public var data: Data
    /// The body was longer than the cap and was cut.
    public var truncated: Bool
}

/// A fetched page in readable form.
public struct WebPage: Sendable {
    public enum Kind: String, Sendable { case html, pdf, json, text, other }
    public var url: String
    public var status: Int
    public var contentType: String
    public var kind: Kind
    public var title: String
    public var text: String
    public var links: [PageLink]
    public var truncated: Bool

    public var ok: Bool { (200..<300).contains(status) }

    public var json: JSONValue {
        .object([
            "title": .string(title), "url": .string(url), "status": .number(Double(status)), "content_type": .string(contentType),
            "kind": .string(kind.rawValue), "text": .string(text), "truncated": .bool(truncated),
            "links": .array(links.map { .object(["text": .string($0.text), "url": .string($0.url)]) }),
        ])
    }
}

/// Plain HTTP reads without a browser: a desktop Safari user agent, 20-second limit, 5 MB cap,
/// redirects followed (but never from the internet into this Mac or the local network), no
/// cookies or cache kept between calls.
public enum WebFetcher {
    public static let maxBytes = 5 << 20
    public static let timeout: TimeInterval = 20
    public static let maxRedirects = 10
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    // MARK: URL checks

    /// Normalizes and checks a model-supplied URL: http(s) only, a host, no embedded password.
    public static func validate(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw WebError.invalidURL("The URL is empty.") }
        if let reason = refusedScheme(s) { throw WebError.refused(reason) }
        if s.hasPrefix("//") { s = "https:" + s } else if !s.contains("://") { s = "https://" + s }
        let url = URL(string: s) ?? s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed)).flatMap { URL(string: $0) }
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw WebError.invalidURL("“\(raw.prefix(200))” isn't a web address Glide can fetch (it needs http or https).")
        }
        guard let host = url.host, !host.isEmpty else { throw WebError.invalidURL("“\(raw.prefix(200))” has no host name.") }
        if url.password != nil { throw WebError.refused("Glide won't fetch URLs with a password in them.") }
        return url
    }

    /// Non-web schemes are refused outright; the reason is shown to the user.
    public static func refusedScheme(_ raw: String) -> String? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let colon = lower.firstIndex(of: ":") else { return nil }
        let scheme = lower[..<colon]
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        if scheme == "http" || scheme == "https" { return nil }
        // "example.com:8080/path" has a "scheme" that is really a host.
        if scheme.contains(".") || lower[lower.index(after: colon)...].first?.isNumber == true { return nil }
        if scheme == "localhost" { return nil }
        return "Web tools only read http and https pages; they won't open \(scheme): links."
    }

    /// True for this Mac, the local network and other non-public addresses. Numeric hosts in
    /// any form inet_aton accepts ("127.1", "2130706433", "0x7f.1") are checked as addresses.
    public static func isLocalHost(_ rawHost: String?) -> Bool {
        guard var host = rawHost?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || host == "0.0.0.0" { return true }
        if host.contains(":") {
            if host == "::1" || host == "::" { return true }
            if host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") { return true }
            if host.hasPrefix("::ffff:") { return isLocalHost(String(host.dropFirst(7))) }
            return false
        }
        var addr = in_addr()
        guard host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }), inet_aton(host, &addr) != 0 else { return false }
        let ip = UInt32(bigEndian: addr.s_addr)
        let a = ip >> 24, b = (ip >> 16) & 0xFF
        return a == 127 || a == 10 || a == 0 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
            || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
    }

    // MARK: Fetching

    static func makeRequest(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,application/pdf,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let langs = Locale.preferredLanguages.prefix(3)
        let accept = langs.enumerated().map { $0.offset == 0 ? $0.element : "\($0.element);q=\(String(format: "%.1f", 1 - Double($0.offset) * 0.2))" }
        r.setValue(accept.isEmpty ? "en-US,en;q=0.9" : accept.joined(separator: ","), forHTTPHeaderField: "Accept-Language")
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return r
    }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return c
    }

    /// Performs one request. Stopping `gate` cancels it within ~100 ms. Plain-http requests
    /// that macOS blocks (App Transport Security) are retried once over https.
    public static func fetch(_ request: URLRequest, gate: ExecutionGate? = nil, maxBytes: Int = maxBytes) async throws -> FetchedResource {
        do {
            return try await withGate(gate) { try await perform(request, maxBytes: maxBytes) }
        } catch let e as URLError where e.code == .appTransportSecurityRequiresSecureConnection {
            guard var comps = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }), comps.scheme == "http" else { throw describe(e, request.url) }
            comps.scheme = "https"
            var upgraded = request
            upgraded.url = comps.url
            let secure = upgraded
            do { return try await withGate(gate) { try await perform(secure, maxBytes: maxBytes) } } catch let e as URLError { throw describe(e, secure.url) }
        } catch let e as URLError {
            throw describe(e, request.url)
        }
    }

    private static func describe(_ e: URLError, _ url: URL?) -> WebError {
        let host = url?.host ?? "the site"
        switch e.code {
        case .timedOut: return .timeout("\(host) didn't respond within \(Int(timeout)) seconds.")
        case .cannotFindHost, .dnsLookupFailed: return .network("Couldn't find the server \(host). Check the address.")
        case .cannotConnectToHost: return .network("Couldn't connect to \(host).")
        case .notConnectedToInternet: return .network("This Mac isn't connected to the internet.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .network("\(host) has a security certificate problem, so Glide didn't load it.")
        case .appTransportSecurityRequiresSecureConnection: return .network("macOS blocked the insecure (http) connection to \(host).")
        case .cancelled: return .network("The request to \(host) was cancelled.")
        default: return .network("Couldn't load \(host): \(e.localizedDescription)")
        }
    }

    private static func perform(_ request: URLRequest, maxBytes: Int) async throws -> FetchedResource {
        guard let url = request.url else { throw WebError.invalidURL("The request has no URL.") }
        let task = FetchTask(requestedURL: url, maxBytes: maxBytes, originIsLocal: isLocalHost(url.host))
        let session = URLSession(configuration: configuration(), delegate: task, delegateQueue: nil)
        // The session holds its delegate strongly until invalidated.
        defer { session.finishTasksAndInvalidate() }
        let dataTask = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<FetchedResource, Error>) in
                task.start(dataTask, cont)
            }
        } onCancel: {
            dataTask.cancel()
        }
    }

    /// Runs `op`, throwing `AutomationError.stopped` as soon as `gate` is stopped.
    static func withGate<T: Sendable>(_ gate: ExecutionGate?, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let gate else { return try await op() }
        if gate.isStopped { throw AutomationError.stopped }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                while true {
                    if gate.isStopped { throw AutomationError.stopped }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    // MARK: Rendering

    /// Fetches `url` and turns it into readable text.
    public static func page(_ url: URL, gate: ExecutionGate? = nil, maxLinks: Int = 40) async throws -> WebPage {
        let resource = try await fetch(makeRequest(url), gate: gate)
        return render(resource, maxLinks: maxLinks)
    }

    static func decodeText(_ r: FetchedResource) -> String {
        var encoding: String.Encoding?
        if let name = r.textEncodingName { encoding = encodingFromIANA(name) }
        if encoding == nil, r.mimeType.contains("html") || r.mimeType.contains("xml") {
            let head = String(decoding: r.data.prefix(4096), as: UTF8.self).lowercased()
            if let range = head.range(of: #"charset\s*=\s*["']?([a-z0-9_\-:]+)"#, options: .regularExpression) {
                let match = head[range]
                let name = match.split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) } ?? ""
                encoding = encodingFromIANA(name)
            }
        }
        if let encoding, encoding != .utf8, let s = String(data: r.data, encoding: encoding) { return s }
        if let s = String(data: r.data, encoding: .utf8) { return s }
        // Lossy UTF-8 keeps a page readable even when the cap cut a character in half.
        return String(decoding: r.data, as: UTF8.self)
    }

    static func encodingFromIANA(_ name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    static func sniffKind(_ r: FetchedResource) -> WebPage.Kind {
        let mime = r.mimeType.lowercased()
        if mime == "application/pdf" || r.data.starts(with: Data("%PDF-".utf8)) { return .pdf }
        if mime.contains("html") { return .html }
        if mime == "application/json" || mime.hasSuffix("+json") || mime == "text/json" { return .json }
        if mime.hasPrefix("text/") || mime.hasSuffix("xml") || mime.isEmpty || mime == "application/octet-stream" || mime == "application/javascript" {
            let head = String(decoding: r.data.prefix(1024), as: UTF8.self).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") || (mime.isEmpty && head.contains("<body")) { return .html }
            if (head.hasPrefix("{") || head.hasPrefix("[")) && (try? JSONSerialization.jsonObject(with: r.data, options: [.fragmentsAllowed])) != nil { return .json }
            if mime.hasPrefix("text/") || mime.hasSuffix("xml") || mime == "application/javascript" { return .text }
            return r.data.prefix(2048).contains(0) ? .other : .text
        }
        return .other
    }

    public static func render(_ r: FetchedResource, maxLinks: Int = 40) -> WebPage {
        let kind = sniffKind(r)
        var page = WebPage(url: r.finalURL.absoluteString, status: r.status, contentType: r.mimeType, kind: kind, title: "", text: "", links: [], truncated: r.truncated)
        switch kind {
        case .html:
            let readable = HTMLText.extract(decodeText(r), baseURL: r.finalURL, maxLinks: maxLinks)
            page.title = readable.title
            page.text = readable.text
            page.links = readable.links
        case .text:
            let text = decodeText(r)
            if r.mimeType.lowercased().hasSuffix("xml") {
                // RSS/Atom and other XML: the text content reads better than the markup.
                let readable = HTMLText.extract(text, baseURL: r.finalURL, maxLinks: maxLinks)
                page.title = readable.title
                page.text = readable.text
            } else {
                page.text = text
            }
        case .json:
            if let obj = try? JSONSerialization.jsonObject(with: r.data, options: [.fragmentsAllowed]),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) {
                page.text = String(decoding: pretty, as: UTF8.self)
            } else {
                page.text = decodeText(r)
            }
        case .pdf:
            if let doc = PDFDocument(data: r.data) {
                page.title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
                var text = ""
                for i in 0..<min(doc.pageCount, 500) {
                    if let s = doc.page(at: i)?.string, !s.isEmpty { text += (text.isEmpty ? "" : "\n\n") + s }
                    if text.count > 200_000 { break }
                }
                page.text = text.isEmpty ? "This PDF has \(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s") but no selectable text (it may be scanned images)." : text
            } else {
                page.text = r.truncated
                    ? "This PDF is larger than \(maxBytes >> 20) MB, so only part of it was downloaded and it can't be read. Download it and open it with the files tools instead."
                    : "This PDF couldn't be read (it may be damaged or encrypted)."
            }
        case .other:
            let size = ByteCountFormatter.string(fromByteCount: Int64(r.data.count), countStyle: .file)
            page.text = "This is \(r.mimeType.isEmpty ? "binary data" : r.mimeType) (\(size)\(r.truncated ? "+" : "")), not a text document."
        }
        if page.title.isEmpty { page.title = r.finalURL.lastPathComponent.isEmpty || r.finalURL.lastPathComponent == "/" ? (r.finalURL.host ?? "") : r.finalURL.lastPathComponent }
        return page
    }
}

/// URLSession delegate for one capped request. All mutable state is guarded by `lock`, since
/// URLSession calls back on its own queue while cancellation can arrive from any thread.
final class FetchTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FetchedResource, Error>?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var truncated = false
    private var redirects = 0
    private var refusal: WebError?
    private let requestedURL: URL
    private let maxBytes: Int
    private let originIsLocal: Bool

    init(requestedURL: URL, maxBytes: Int, originIsLocal: Bool) {
        self.requestedURL = requestedURL
        self.maxBytes = maxBytes
        self.originIsLocal = originIsLocal
    }

    func start(_ task: URLSessionDataTask, _ cont: CheckedContinuation<FetchedResource, Error>) {
        lock.withLock { continuation = cont }
        task.resume()
    }

    private func finish(_ result: Result<FetchedResource, Error>) {
        let cont = lock.withLock { () -> CheckedContinuation<FetchedResource, Error>? in
            defer { continuation = nil }
            return continuation
        }
        cont?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.withLock { self.response = response as? HTTPURLResponse }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = lock.withLock { () -> Bool in
            let room = maxBytes - buffer.count
            if data.count > room {
                buffer.append(data.prefix(max(0, room)))
                truncated = true
                return true
            }
            buffer.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let decision = lock.withLock { () -> URLRequest? in
            redirects += 1
            guard redirects <= WebFetcher.maxRedirects else {
                refusal = .refused("Too many redirects (more than \(WebFetcher.maxRedirects)).")
                return nil
            }
            guard let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                refusal = .refused("The page redirected to a non-web address, which Glide doesn't follow.")
                return nil
            }
            if !originIsLocal && WebFetcher.isLocalHost(url.host) {
                refusal = .refused("The page redirected to an address on this Mac or the local network, which Glide doesn't follow.")
                return nil
            }
            return request
        }
        completionHandler(decision)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (data, resp, cut, refused) = lock.withLock { (buffer, response, truncated, refusal) }
        if let refused { finish(.failure(refused)); return }
        if let error {
            // Our own cancel after hitting the size cap is a success with a truncated body.
            if cut, (error as? URLError)?.code == .cancelled {} else {
                finish(.failure(error))
                return
            }
        }
        let http = resp ?? (task.response as? HTTPURLResponse)
        let final = http?.url ?? task.currentRequest?.url ?? requestedURL
        finish(.success(FetchedResource(requestedURL: requestedURL, finalURL: final, status: http?.statusCode ?? 0,
                                        mimeType: (http?.mimeType ?? "").lowercased(), textEncodingName: http?.textEncodingName,
                                        data: data, truncated: cut)))
    }
}
