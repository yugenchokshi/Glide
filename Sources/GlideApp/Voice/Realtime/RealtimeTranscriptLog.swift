import Foundation
import AgentKit

/// The last lines of the latest voice conversation, kept so the next one can pick up where it
/// left off ("and what about the second one?").
struct RealtimeTranscriptLog {
    let defaults: UserDefaults
    var key = "glide.voice.lastConversation"
    /// Older conversations aren't carried over.
    var window: TimeInterval = 2 * 3600
    var maxLines = 16

    func save(_ lines: [String], at date: Date = Date()) {
        guard !lines.isEmpty else { return }
        let kept = lines.suffix(maxLines).map { GlideMemory.clip($0, 600) }
        defaults.set(["at": date.timeIntervalSince1970, "lines": Array(kept)], forKey: key)
    }

    /// The saved lines, while they're fresh; nil otherwise.
    func load(now: Date = Date()) -> String? {
        guard let saved = defaults.dictionary(forKey: key), let at = saved["at"] as? Double,
              now.timeIntervalSince1970 - at <= window, let lines = saved["lines"] as? [String], !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
