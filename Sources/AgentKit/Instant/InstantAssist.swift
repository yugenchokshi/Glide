import Foundation
import AutomationKit

/// What kind of request a short, unclear utterance is, as guessed by a fast classifier.
public enum InstantGuessKind: String, Sendable, Hashable, CaseIterable {
    case openApp = "open_app"
    case openWebsite = "open_website"
    case searchSite = "search_site"
    case other
}

public struct InstantGuess: Sendable, Hashable {
    public var kind: InstantGuessKind
    public var confidence: Double

    public init(kind: InstantGuessKind, confidence: Double) {
        self.kind = kind
        self.confidence = confidence
    }
}

/// Classifies short phrasing the rules didn't catch ("chat gpt", "youtube lofi"). Behind a
/// protocol so tests use a fake and never call a paid API.
public protocol InstantIntentClassifying: Sendable {
    func classify(_ utterance: String) async throws -> InstantGuess
}

/// One Jev Choice question. Jev is calibrated and fast, so a high-confidence answer is safe
/// to act on; anything less goes to the planner.
public struct JevInstantClassifier: InstantIntentClassifying {
    let client: JevClient

    public init(client: JevClient) {
        self.client = client
    }

    /// A Jev client when a Jev key (TypeSafe or Vercel AI Gateway) is saved. Unlike element
    /// selection this doesn't need "Use Jev for selection": having the key is the opt-in.
    public static func configured(settings: AppSettings, credentials: CredentialStore = .shared) -> JevInstantClassifier? {
        let provider = settings.routing.effectiveJevProvider
        guard let key = credentials.get(ModelRouter.jevKey(provider)), !key.isEmpty else { return nil }
        return JevInstantClassifier(client: JevClient(apiKey: key, model: settings.routing.effectiveJevModel, provider: provider))
    }

    public func classify(_ utterance: String) async throws -> InstantGuess {
        let options: [String: String] = [
            InstantGuessKind.openApp.rawValue: "Open or switch to a Mac app by its name",
            InstantGuessKind.openWebsite.rawValue: "Open a website by its name or address",
            InstantGuessKind.searchSite.rawValue: "Search a named website for something (site name, then what to search)",
            InstantGuessKind.other.rawValue: "Anything else: a task with steps, a question, or unclear",
        ]
        let answer = try await client.choose(state: .string("The user said to their Mac assistant: \"\(utterance)\""),
                                             instructions: "What does the user want done?", options: options)
        return InstantGuess(kind: InstantGuessKind(rawValue: answer.choice) ?? .other, confidence: answer.confidence)
    }
}

enum InstantAssist {
    /// Runs the classifier, answering nil after `timeout` (the user is waiting to hear
    /// something). The race is unstructured on purpose: a task group would wait for a slow
    /// request to notice its cancellation, and this must never take longer than the timeout.
    static func guess(_ classifier: any InstantIntentClassifying, _ utterance: String, timeout: TimeInterval) async -> InstantGuess? {
        await withCheckedContinuation { (continuation: CheckedContinuation<InstantGuess?, Never>) in
            let once = InstantResumeOnce(continuation)
            let work = Task {
                let g = try? await classifier.classify(utterance)
                once.resume(g)
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                work.cancel()
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever side gets there first.
final class InstantResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        let c = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
    }
}
