import Foundation

/// What Glide remembers between conversations: facts the user asked it to keep, the tasks it
/// did recently, and the last voice conversation. Each new conversation (and each plan) starts
/// with it, so "send it to my manager" or "what did you find earlier?" work the next day too.
public enum GlideMemory {
    /// Recent tasks older than this are left out.
    static let recentTaskWindow: TimeInterval = 24 * 3600
    static let recentTaskLimit = 8
    /// The last voice conversation is carried over while it's this fresh.
    static let conversationWindow: TimeInterval = 2 * 3600

    /// Saved facts, newest first, as lines for a prompt; nil when there are none.
    public static func facts(store: LocalStore = .shared, limit: Int = 40) -> String? {
        let items = store.memories(limit: limit)
        guard !items.isEmpty else { return nil }
        return items.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// Tasks from the last day, newest first: what was asked and what came of it.
    public static func recentTasks(store: LocalStore = .shared, now: Date = Date()) -> String? {
        let tasks = store.recentTasks(limit: 30)
            .filter { now.timeIntervalSince($0.startedAt) <= recentTaskWindow && $0.status != "running" }
            .prefix(recentTaskLimit)
        guard !tasks.isEmpty else { return nil }
        let df = DateFormatter()
        df.dateFormat = "EEE HH:mm"
        return tasks.map { t in
            let outcome = t.status == "completed" ? clip(t.summary ?? "done", 400) : "\(t.status): \(clip(t.error ?? t.summary ?? "", 200))"
            return "- \(df.string(from: t.startedAt)): \(outcome)"
        }.joined(separator: "\n")
    }

    /// The whole memory block for the start of a voice conversation; nil when there's nothing.
    public static func conversationContext(store: LocalStore = .shared, lastConversation: String? = nil, now: Date = Date()) -> String? {
        var parts: [String] = []
        if let facts = facts(store: store) { parts.append("What the user asked you to remember:\n" + facts) }
        if let tasks = recentTasks(store: store, now: now) {
            parts.append("What Glide did recently, newest first (for reference when the user mentions it; never copy these into a new request):\n" + tasks)
        }
        if let last = lastConversation?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            parts.append("Your last conversation with the user:\n" + last)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    public static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count <= n ? one : String(one.prefix(n)) + "…"
    }
}
