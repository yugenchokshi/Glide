import Foundation
import os

/// A text-frame WebSocket. The real one wraps `URLSessionWebSocketTask`; tests use a fake.
/// `send` may be called from any thread (the microphone tap sends audio directly).
protocol RealtimeTransport: AnyObject, Sendable {
    /// Opens the socket. `onMessage` gets each text frame; `onClose` runs once when the socket
    /// fails or closes (nil error: closed by us).
    func connect(onMessage: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable ((any Error)?) -> Void)
    func send(_ frame: String)
    func close()
}

enum RealtimeError: Error, Equatable, CustomStringConvertible {
    case badURL
    case closed(String)
    case server(String)
    case timeout

    var description: String {
        switch self {
        case .badURL: return "The OpenAI base URL isn't valid for real-time voice."
        case .closed(let why): return "The voice connection closed: \(why)"
        case .server(let message): return message
        case .timeout: return "OpenAI didn't answer in time."
        }
    }
}

final class WebSocketTransport: NSObject, RealtimeTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var onMessage: (@Sendable (String) -> Void)?
    private var onClose: (@Sendable ((any Error)?) -> Void)?
    private var closed = false
    private let log = Logger(subsystem: "dev.glide", category: "realtime")

    init(request: URLRequest) {
        self.request = request
    }

    func connect(onMessage: @escaping @Sendable (String) -> Void, onClose: @escaping @Sendable ((any Error)?) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        lock.withLock {
            self.session = session
            self.task = task
            self.onMessage = onMessage
            self.onClose = onClose
        }
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let handler = self.lock.withLock { self.onMessage }
                switch message {
                case .string(let text): handler?(text)
                case .data(let data): handler?(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.receive(task)
            case .failure(let error):
                self.finish(error)
            }
        }
    }

    func send(_ frame: String) {
        guard let task = lock.withLock({ closed ? nil : self.task }) else { return }
        task.send(.string(frame)) { [weak self] error in
            if let error { self?.finish(error) }
        }
    }

    func close() {
        let task: URLSessionWebSocketTask? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            onMessage = nil
            onClose = nil
            return self.task
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func finish(_ error: (any Error)?) {
        let handler: (@Sendable ((any Error)?) -> Void)? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            let h = onClose
            onClose = nil
            onMessage = nil
            return h
        }
        guard let handler else { return }
        if let error { log.error("realtime socket closed: \(String(describing: error), privacy: .public)"); RealtimeDiagnostics.note("socket closed: \(String(describing: error))") }
        handler(error ?? RealtimeError.closed("closed by server"))
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let why = reason.map { String(decoding: $0, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 } ?? "code \(closeCode.rawValue)"
        finish(RealtimeError.closed(why))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) && http.statusCode != 101 {
            finish(RealtimeError.server(http.statusCode == 401 ? "OpenAI didn't accept the API key." : "OpenAI returned \(http.statusCode)."))
        } else {
            finish(error)
        }
    }
}
