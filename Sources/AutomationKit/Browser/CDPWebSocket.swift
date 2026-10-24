import Foundation
import Synchronization

// A minimal Chrome DevTools Protocol client. CDP is JSON-RPC over one WebSocket: every command
// carries an `id` and Chrome answers with the same `id`; events arrive as `{method, params}`.
// With flattened sessions (`Target.attachToTarget` + `flatten: true`) one browser-level socket
// talks to every tab: a command addressed to a tab carries that tab's `sessionId`, and the tab's
// events come back tagged with it. That keeps Glide down to a single connection per Chrome.

/// One event pushed by Chrome (`{method, params, sessionId?}`).
public struct CDPEvent: Sendable {
    public let method: String
    public let params: JSONValue
    /// The tab session the event belongs to; nil for browser-level events.
    public let sessionID: String?

    public init(method: String, params: JSONValue, sessionID: String?) {
        self.method = method
        self.params = params
        self.sessionID = sessionID
    }
}

/// An error reply to a CDP command (`{id, error: {code, message}}`).
public struct CDPError: Error, LocalizedError, Sendable, Equatable {
    public let method: String
    public let code: Int
    public let message: String

    public init(method: String, code: Int, message: String) {
        self.method = method
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { "\(method) failed: \(message)" }

    /// Chrome no longer knows the tab session (the tab closed or the debugger detached).
    public var isSessionGone: Bool { message.localizedCaseInsensitiveContains("session with given id not found") }
    /// Chrome no longer knows the target (tab) itself.
    public var isTargetGone: Bool { message.localizedCaseInsensitiveContains("no target with given id") }
}

/// A CDP connection over `URLSessionWebSocketTask`.
///
/// It's an actor so any number of tasks can send commands at once: replies are matched to callers
/// by id, every command has its own timeout, and a dropped connection fails every caller that's
/// still waiting instead of leaving it hanging.
public actor CDPWebSocket {
    public nonisolated let url: URL

    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timer: Task<Void, Never>
    }

    private let session: URLSession
    private let delegate: SocketDelegate
    private let maximumMessageSize: Int
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var subscribers: [UUID: AsyncStream<CDPEvent>.Continuation] = [:]
    private var closedReason: String?
    /// True between a successful `open()` and the connection dropping or `close()`.
    public private(set) var isOpen = false

    /// `maximumMessageSize` must cover full-page screenshots (base64 PNG), which easily pass the
    /// 1 MB URLSession default.
    public init(url: URL, maximumMessageSize: Int = 64 << 20) {
        self.url = url
        self.maximumMessageSize = maximumMessageSize
        let delegate = SocketDelegate()
        self.delegate = delegate
        let config = URLSessionConfiguration.ephemeral
        // DevTools only listens on loopback; never route it through a system proxy.
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Performs the WebSocket handshake. Throws `BrowserError.notConnected` with the reason when
    /// Chrome refuses (e.g. a 403 because of an origin check) or doesn't answer in time.
    public func open(timeout: TimeInterval = 10) async throws {
        guard task == nil, closedReason == nil else {
            if isOpen { return }
            throw BrowserError.notConnected(closedReason ?? "This Chrome connection was already used.")
        }
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = maximumMessageSize
        task = t
        let delegate = self.delegate
        do {
            try await withDeadline(timeout, BrowserError.timeout("Chrome's debugging socket didn't open within \(Int(timeout)) s.")) {
                try await delegate.waitUntilOpen(resuming: t)
            }
        } catch {
            shutDown(reason: "Couldn't connect to Chrome: \(error.localizedDescription)")
            if let e = error as? BrowserError { throw e }
            throw BrowserError.notConnected("Couldn't connect to Chrome's debugging port: \(error.localizedDescription)")
        }
        isOpen = true
        startReceiving(t)
    }

    /// Sends one command and returns its `result` object. `sessionID` addresses a tab.
    public func send(_ method: String, params: JSONValue? = nil, sessionID: String? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        guard isOpen, let task else { throw BrowserError.notConnected(closedReason ?? "Not connected to Chrome.") }
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method)]
        if let params { message["params"] = params }
        if let sessionID { message["sessionId"] = .string(sessionID) }
        let text = JSONValue.object(message).jsonString()
        let seconds = max(0.05, timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled else { return }
                    await self?.finish(id, .failure(BrowserError.timeout("Chrome didn't answer \(method) within \(Int(seconds.rounded(.up))) s.")))
                }
                pending[id] = Pending(method: method, continuation: continuation, timer: timer)
                task.send(.string(text)) { [weak self] error in
                    guard let error else { return }
                    Task { await self?.finish(id, .failure(BrowserError.notConnected("Couldn't send to Chrome: \(error.localizedDescription)"))) }
                }
            }
        } onCancel: {
            Task { await self.finish(id, .failure(CancellationError())) }
        }
    }

    /// A stream of every event Chrome sends from now on. It ends when the connection closes.
    /// Slow consumers lose the oldest events rather than growing memory without bound.
    public func events() -> AsyncStream<CDPEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CDPEvent.self, bufferingPolicy: .bufferingNewest(4096))
        guard isOpen else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Closes the socket and fails every command still waiting.
    public func close() {
        shutDown(reason: "The connection to Chrome was closed.")
    }

    // MARK: - Internals

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func finish(_ id: Int, _ result: Result<JSONValue, Error>) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.timer.cancel()
        p.continuation.resume(with: result)
    }

    private func startReceiving(_ task: URLSessionWebSocketTask) {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    await self?.shutDown(reason: "Chrome closed the connection (\(error.localizedDescription)).")
                    return
                }
                switch message {
                case .string(let text): await self?.handle(Data(text.utf8))
                case .data(let data): await self?.handle(data)
                @unknown default: break
                }
            }
        }
    }

    private func handle(_ data: Data) {
        guard let value = try? JSONValue.parse(data) else { return }
        if let id = value["id"]?.intValue {
            if let error = value["error"], !error.isNull {
                let method = pending[id]?.method ?? "command"
                finish(id, .failure(CDPError(method: method, code: error["code"]?.intValue ?? -1,
                                             message: error["message"]?.stringValue ?? "unknown error")))
            } else {
                finish(id, .success(value["result"] ?? .object([:])))
            }
        } else if let method = value["method"]?.stringValue {
            let event = CDPEvent(method: method, params: value["params"] ?? .object([:]), sessionID: value["sessionId"]?.stringValue)
            for continuation in subscribers.values { continuation.yield(event) }
        }
    }

    private func shutDown(reason: String) {
        if closedReason == nil { closedReason = reason }
        isOpen = false
        let waiting = pending
        pending.removeAll()
        for p in waiting.values {
            p.timer.cancel()
            p.continuation.resume(throwing: BrowserError.notConnected(reason))
        }
        let subs = subscribers
        subscribers.removeAll()
        for continuation in subs.values { continuation.finish() }
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        // URLSession keeps its delegate alive until invalidated.
        session.invalidateAndCancel()
    }
}

/// Bridges URLSession's delegate callbacks for the handshake into async code.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private struct State {
        var opened = false
        var failure: Error?
        var waiter: CheckedContinuation<Void, Error>?
    }

    private let state = Mutex(State())

    /// Resumes `task` and returns once the handshake succeeded; throws if it failed.
    func waitUntilOpen(resuming task: URLSessionWebSocketTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediate: Result<Void, Error>? = state.withLock { s in
                    if s.opened { return .success(()) }
                    if let f = s.failure { return .failure(f) }
                    s.waiter = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) } else { task.resume() }
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()))
        }
    }

    private func resolve(_ result: Result<Void, Error>) {
        let waiter: CheckedContinuation<Void, Error>? = state.withLock { s in
            switch result {
            case .success: s.opened = true
            case .failure(let e): if !s.opened, s.failure == nil { s.failure = e }
            }
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(with: result)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        resolve(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var message = error?.localizedDescription ?? "the connection closed"
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            message = "Chrome answered HTTP \(http.statusCode)"
        }
        resolve(.failure(BrowserError.notConnected("Couldn't connect to Chrome's debugging port: \(message).")))
    }
}

// MARK: - Deadlines

/// Runs `operation` but gives up after `seconds`, throwing `timeoutError`.
///
/// Unlike a task group, this returns as soon as the deadline passes even when the operation
/// ignores cancellation (a backend call stuck on a page that's showing a dialog, say): the
/// operation is cancelled and left to finish on its own. Caller cancellation is forwarded too.
func withDeadline<T: Sendable>(_ seconds: TimeInterval, _ timeoutError: @autoclosure @escaping @Sendable () -> Error,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            race.install(continuation)
            let work = Task {
                do { race.resolve(.success(try await operation())) } catch { race.resolve(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                if !Task.isCancelled, race.resolve(.failure(timeoutError())) { work.cancel() }
            }
            race.attach(work: work, timer: timer)
        }
    } onCancel: {
        race.cancel()
    }
}

/// Resolves a continuation exactly once, from whichever of the operation, the timer or the
/// caller's cancellation gets there first.
final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var done = false
        var cancelled = false
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let alreadyCancelled = state.withLock { s -> Bool in
            s.continuation = continuation
            return s.cancelled
        }
        if alreadyCancelled { resolve(.failure(CancellationError())) }
    }

    func attach(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let finished = state.withLock { s -> Bool in
            s.work = work
            s.timer = timer
            return s.done
        }
        if finished {
            timer.cancel()
        }
    }

    /// Returns true if this call won the race.
    @discardableResult
    func resolve(_ result: Result<T, Error>) -> Bool {
        let (continuation, timer): (CheckedContinuation<T, Error>?, Task<Void, Never>?) = state.withLock { s in
            guard !s.done, let c = s.continuation else { return (nil, nil) }
            s.done = true
            s.continuation = nil
            return (c, s.timer)
        }
        guard let continuation else { return false }
        timer?.cancel()
        continuation.resume(with: result)
        return true
    }

    func cancel() {
        let work = state.withLock { s -> Task<Void, Never>? in
            s.cancelled = true
            return s.work
        }
        if resolve(.failure(CancellationError())) { work?.cancel() }
    }
}
