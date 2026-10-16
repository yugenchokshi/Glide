import Foundation

public struct TaskRecord: Sendable, Identifiable, Hashable, Codable {
    public var id: String
    public var instruction: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: String
    public var summary: String?
    public var error: String?
    public var plan: Plan?
    public var metrics: TaskMetrics.Snapshot?
    public var durationMs: Double?

    public static func == (a: TaskRecord, b: TaskRecord) -> Bool { a.id == b.id && a.status == b.status && a.endedAt == b.endedAt }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// Local task history and saved skills in one SQLite file under Application Support.
public final class LocalStore: @unchecked Sendable {
    public static let shared: LocalStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Glide")
        migrateLegacyStore(from: support.appendingPathComponent("NotchBuddy"), to: dir)
        return (try? LocalStore(path: dir.appendingPathComponent("glide.sqlite").path)) ?? (try! LocalStore(path: NSTemporaryDirectory() + "glide.sqlite"))
    }()

    /// The app was called NotchBuddy before; move its history to the Glide folder once.
    static func migrateLegacyStore(from legacy: URL, to dir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: dir.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: dir)
            for suffix in ["", "-wal", "-shm"] {
                let old = dir.appendingPathComponent("notchbuddy.sqlite" + suffix)
                if fm.fileExists(atPath: old.path) { try fm.moveItem(at: old, to: dir.appendingPathComponent("glide.sqlite" + suffix)) }
            }
        } catch {
            // Leave the old files in place; a fresh history starts in the new folder.
        }
    }

    let db: SQLiteDatabase
    public var path: String { db.path }

    public init(path: String) throws {
        db = try SQLiteDatabase(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS tasks (
          id TEXT PRIMARY KEY, instruction TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL,
          status TEXT NOT NULL, summary TEXT, error TEXT, plan_json TEXT, metrics_json TEXT, duration_ms REAL)
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS events (
          id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, ts REAL NOT NULL,
          kind TEXT NOT NULL, title TEXT NOT NULL, detail TEXT, route TEXT, success INTEGER, duration_ms REAL, step_id INTEGER)
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS events_task ON events(task_id, ts)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS skills (
          id TEXT PRIMARY KEY, json TEXT NOT NULL, updated_at REAL NOT NULL)
        """)
    }

    // MARK: Tasks

    public func startTask(id: String, instruction: String, at date: Date = Date()) {
        try? db.execute("INSERT OR REPLACE INTO tasks (id, instruction, started_at, status) VALUES (?, ?, ?, 'running')",
                        [.text(id), .text(SecretScrubber.scrub(instruction)), .real(date.timeIntervalSince1970)])
    }

    public func appendEvent(taskID: String, _ e: ActivityEntry) {
        try? db.execute("INSERT OR REPLACE INTO events (id, task_id, ts, kind, title, detail, route, success, duration_ms, step_id) VALUES (?,?,?,?,?,?,?,?,?,?)", [
            .text(e.id.uuidString), .text(taskID), .real(e.timestamp.timeIntervalSince1970), .text(e.kind.rawValue),
            .text(SecretScrubber.scrub(e.title)), e.detail.map { .text(SecretScrubber.scrub($0)) } ?? .null,
            e.route.map { .text($0.rawValue) } ?? .null, e.success.map { .int($0 ? 1 : 0) } ?? .null,
            e.durationMs.map { .real($0) } ?? .null, e.stepID.map { .int(Int64($0)) } ?? .null,
        ])
    }

    public func finishTask(id: String, result: TaskResult, at date: Date = Date()) {
        let plan = result.plan.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        let metrics = (try? JSONEncoder().encode(result.metrics)).map { String(decoding: $0, as: UTF8.self) }
        try? db.execute("UPDATE tasks SET ended_at=?, status=?, summary=?, error=?, plan_json=?, metrics_json=?, duration_ms=? WHERE id=?", [
            .real(date.timeIntervalSince1970), .text(result.status.rawValue), .text(SecretScrubber.scrub(result.summary)),
            result.error.map { .text(SecretScrubber.scrub($0)) } ?? .null, plan.map { .text($0) } ?? .null,
            metrics.map { .text($0) } ?? .null, .real(result.durationMs), .text(id),
        ])
    }

    public func recentTasks(limit: Int = 50) -> [TaskRecord] {
        let rows = (try? db.query("SELECT * FROM tasks ORDER BY started_at DESC LIMIT ?", [.int(Int64(limit))])) ?? []
        return rows.map(record)
    }

    public func task(id: String) -> TaskRecord? {
        ((try? db.query("SELECT * FROM tasks WHERE id=?", [.text(id)])) ?? []).first.map(record)
    }

    public func events(taskID: String) -> [ActivityEntry] {
        let rows = (try? db.query("SELECT * FROM events WHERE task_id=? ORDER BY ts", [.text(taskID)])) ?? []
        return rows.map { r in
            var e = ActivityEntry(kind: ActivityEntry.Kind(rawValue: r["kind"]?.string ?? "info") ?? .info, title: r["title"]?.string ?? "",
                                  detail: r["detail"]?.string, route: r["route"]?.string.flatMap(ExecutionRoute.init(rawValue:)),
                                  success: r["success"]?.int.map { $0 == 1 }, durationMs: r["duration_ms"]?.double, stepID: r["step_id"]?.int)
            e.id = UUID(uuidString: r["id"]?.string ?? "") ?? UUID()
            e.timestamp = Date(timeIntervalSince1970: r["ts"]?.double ?? 0)
            return e
        }
    }

    public func deleteTask(id: String) { try? db.execute("DELETE FROM tasks WHERE id=?", [.text(id)]) }

    public func clearHistory() {
        try? db.execute("DELETE FROM events")
        try? db.execute("DELETE FROM tasks")
        try? db.execute("VACUUM")
    }

    private func record(_ r: [String: SQLiteDatabase.Value]) -> TaskRecord {
        TaskRecord(
            id: r["id"]?.string ?? "", instruction: r["instruction"]?.string ?? "",
            startedAt: Date(timeIntervalSince1970: r["started_at"]?.double ?? 0),
            endedAt: r["ended_at"]?.double.map { Date(timeIntervalSince1970: $0) },
            status: r["status"]?.string ?? "unknown", summary: r["summary"]?.string, error: r["error"]?.string,
            plan: r["plan_json"]?.string.flatMap { try? JSONDecoder().decode(Plan.self, from: Data($0.utf8)) },
            metrics: r["metrics_json"]?.string.flatMap { try? JSONDecoder().decode(TaskMetrics.Snapshot.self, from: Data($0.utf8)) },
            durationMs: r["duration_ms"]?.double)
    }

    // MARK: Skills

    public func saveSkill(_ skill: Skill) {
        guard let data = try? JSONEncoder().encode(skill) else { return }
        try? db.execute("INSERT OR REPLACE INTO skills (id, json, updated_at) VALUES (?,?,?)",
                        [.text(skill.id), .text(String(decoding: data, as: UTF8.self)), .real(Date().timeIntervalSince1970)])
    }

    public func skills() -> [Skill] {
        let rows = (try? db.query("SELECT json FROM skills ORDER BY updated_at DESC")) ?? []
        return rows.compactMap { $0["json"]?.string.flatMap { try? JSONDecoder().decode(Skill.self, from: Data($0.utf8)) } }
    }

    public func deleteSkill(id: String) { try? db.execute("DELETE FROM skills WHERE id=?", [.text(id)]) }
}

/// A reusable workflow: semantic steps (never raw coordinates) the planner follows when a
/// request matches.
public struct Skill: Codable, Sendable, Identifiable, Hashable {
    public var id: String = UUID().uuidString
    public var name: String
    public var description: String
    /// Phrases that trigger this skill ("meeting note").
    public var triggers: [String]
    /// Named parameters filled from the request ("topic").
    public var parameters: [String]
    public var preconditions: String
    public var steps: [String]
    public var verification: String
    public var requiresApproval: Bool
    public var apps: [String]

    public init(name: String, description: String, triggers: [String], parameters: [String] = [], preconditions: String = "",
                steps: [String], verification: String = "", requiresApproval: Bool = false, apps: [String] = []) {
        self.name = name
        self.description = description
        self.triggers = triggers
        self.parameters = parameters
        self.preconditions = preconditions
        self.steps = steps
        self.verification = verification
        self.requiresApproval = requiresApproval
        self.apps = apps
    }

    /// Creates a skill from a completed task's plan (semantic steps only).
    public static func from(plan: Plan, instruction: String) -> Skill {
        Skill(name: String(plan.goal.prefix(60)), description: instruction, triggers: [String(instruction.prefix(80))],
              steps: plan.steps.map { "\($0.title): \($0.instruction)" },
              verification: plan.steps.last?.doneWhen ?? "", requiresApproval: plan.steps.contains { $0.risk == .high },
              apps: Array(Set(plan.steps.compactMap(\.app))))
    }

    /// Relevance of this skill to a request (token overlap with name/triggers).
    public func relevance(to request: String) -> Double {
        let req = Set(ElementMatcherShim.tokens(request))
        guard !req.isEmpty else { return 0 }
        var best = 0.0
        for phrase in triggers + [name] {
            let t = Set(ElementMatcherShim.tokens(phrase))
            guard !t.isEmpty else { continue }
            best = max(best, Double(req.intersection(t).count) / Double(t.count))
        }
        return best
    }

    public var promptText: String {
        var s = "Skill “\(name)”: \(description)\n"
        if !preconditions.isEmpty { s += "Preconditions: \(preconditions)\n" }
        if !parameters.isEmpty { s += "Parameters: \(parameters.joined(separator: ", "))\n" }
        s += steps.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !verification.isEmpty { s += "\nDone when: \(verification)" }
        return s
    }
}

enum ElementMatcherShim {
    static let stop: Set<String> = ["the", "a", "an", "to", "and", "of", "in", "on", "for", "my", "me", "please", "with", "it"]
    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 && !stop.contains($0) }
    }
}
