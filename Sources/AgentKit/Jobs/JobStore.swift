import Foundation
import os

/// Persistence for long-running jobs: records, items, the activity log and each job's memory
/// (facts and result tables), in the same SQLite file as task history.
///
/// Everything a job needs to continue lives here, written after every step and item, so a job
/// survives quitting Glide, a crash or a reboot. Records and items are stored as JSON blobs (the
/// models evolve; tolerant JSON decoding keeps old rows readable) next to the few columns that
/// queries filter on.
///
/// Thread-safe: every public method takes `lock`, so multi-statement operations (transactions,
/// read-modify-write) never interleave with each other. The connection is our own (on the
/// shared database file) with a busy timeout, so `LocalStore` writes from other threads wait
/// instead of failing.
public final class JobStore: @unchecked Sendable {
    /// The app's store: `glide.sqlite` next to task history, job folders in `…/Glide/Jobs`.
    public static let shared: JobStore = {
        let dbPath = LocalStore.shared.path
        let root = URL(fileURLWithPath: (dbPath as NSString).deletingLastPathComponent).appendingPathComponent("Jobs", isDirectory: true)
        if let store = try? JobStore(path: dbPath, jobsRoot: root) { return store }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("glide-jobs", isDirectory: true)
        // A temporary store keeps the app usable (jobs just won't persist) instead of crashing.
        return try! JobStore(path: tmp.appendingPathComponent("jobs.sqlite").path, jobsRoot: tmp.appendingPathComponent("Jobs", isDirectory: true))
    }()

    /// Folder that holds one sub-folder per job.
    public let jobsRoot: URL
    public var path: String { db.path }

    let db: SQLiteDatabase
    private let lock = NSLock()
    private let log = Logger(subsystem: "dev.glide", category: "jobs.store")
    /// Events appended per job since the last prune (kept in memory; pruning is best effort).
    private var appendsSincePrune: [String: Int] = [:]

    /// Events kept per job; older ones are pruned so week-long jobs don't grow without bound.
    public static let maxEventsPerJob = 5000

    public init(path: String, jobsRoot: URL) throws {
        db = try SQLiteDatabase(path: path)
        self.jobsRoot = jobsRoot
        try FileManager.default.createDirectory(at: jobsRoot, withIntermediateDirectories: true)
        try db.execute("PRAGMA busy_timeout=5000")
        try migrate()
    }

    private func migrate() throws {
        // Idempotent: safe to run on every launch and alongside LocalStore's own tables.
        try db.execute("""
        CREATE TABLE IF NOT EXISTS jobs (
          id TEXT PRIMARY KEY, json TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL,
          updated_at REAL NOT NULL, next_wake_at REAL)
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS jobs_status ON jobs(status, next_wake_at)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS job_items (
          id TEXT PRIMARY KEY, job_id TEXT NOT NULL, step_id INTEGER NOT NULL, idx INTEGER NOT NULL,
          json TEXT NOT NULL, status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL)
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS job_items_lookup ON job_items(job_id, step_id, status, idx)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS job_events (
          id TEXT PRIMARY KEY, job_id TEXT NOT NULL, ts REAL NOT NULL, json TEXT NOT NULL)
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS job_events_job ON job_events(job_id, ts)")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS job_facts (
          job_id TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, updated_at REAL NOT NULL,
          PRIMARY KEY (job_id, key))
        """)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS job_rows (
          job_id TEXT NOT NULL, table_name TEXT NOT NULL, row_key TEXT NOT NULL, json TEXT NOT NULL,
          ord REAL NOT NULL DEFAULT 0, updated_at REAL NOT NULL, PRIMARY KEY (job_id, table_name, row_key))
        """)
        // Engine bookkeeping that must survive restarts but isn't part of the job's memory
        // (approved milestones, wait progress, failure-rate baselines). Kept out of job_facts so
        // the model never sees or overwrites it.
        try db.execute("""
        CREATE TABLE IF NOT EXISTS job_state (
          job_id TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY (job_id, key))
        """)
    }

    // MARK: - Folders

    /// The job's folder (workspace files, exports, report.md). Ids are sanitized so a corrupted
    /// record can never point outside `jobsRoot`.
    public func folder(for jobID: String) -> URL {
        let safe = String(jobID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }.map(Character.init))
        return jobsRoot.appendingPathComponent(safe.isEmpty ? "job" : safe, isDirectory: true)
    }

    /// Creates (if needed) and returns the job's folder.
    @discardableResult
    public func ensureFolder(for jobID: String) -> URL {
        let url = folder(for: jobID)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Jobs

    public func saveJob(_ record: JobRecord) {
        guard let json = encode(record) else { return }
        locked("save job") {
            try db.execute("""
            INSERT INTO jobs (id, json, status, created_at, updated_at, next_wake_at) VALUES (?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET json=excluded.json, status=excluded.status, updated_at=excluded.updated_at,
              next_wake_at=excluded.next_wake_at
            """, [.text(record.id), .text(json), .text(record.status.rawValue), .real(record.createdAt.timeIntervalSince1970),
                  .real(record.updatedAt.timeIntervalSince1970), record.nextWakeAt.map { .real($0.timeIntervalSince1970) } ?? .null])
        }
    }

    public func job(_ id: String) -> JobRecord? {
        let rows = lockedQuery("SELECT json FROM jobs WHERE id=?", [.text(id)])
        return rows.first.flatMap { $0["json"]?.string }.flatMap { decode(JobRecord.self, $0) }
    }

    /// All jobs, newest first.
    public func allJobs() -> [JobRecord] {
        lockedQuery("SELECT json FROM jobs ORDER BY created_at DESC").compactMap { $0["json"]?.string.flatMap { decode(JobRecord.self, $0) } }
    }

    public func jobs(status: JobStatus) -> [JobRecord] {
        lockedQuery("SELECT json FROM jobs WHERE status=? ORDER BY created_at DESC", [.text(status.rawValue)])
            .compactMap { $0["json"]?.string.flatMap { decode(JobRecord.self, $0) } }
    }

    /// Removes the job and everything recorded for it (the folder is the caller's to trash).
    public func deleteJob(_ id: String) {
        locked("delete job") {
            try transaction {
                try db.execute("DELETE FROM jobs WHERE id=?", [.text(id)])
                for table in ["job_items", "job_events", "job_facts", "job_rows", "job_state"] {
                    try db.execute("DELETE FROM \(table) WHERE job_id=?", [.text(id)])
                }
            }
        }
        lock.withLock { _ = appendsSincePrune.removeValue(forKey: id) }
    }

    // MARK: - Items

    /// Inserts items in one transaction (thousands of rows stay fast). Existing ids are replaced.
    public func insertItems(_ items: [JobItem]) {
        guard !items.isEmpty else { return }
        let encoded = items.compactMap { item in encode(item).map { (item, $0) } }
        locked("insert items") {
            try transaction {
                for (item, json) in encoded { try upsertItem(item, json: json) }
            }
        }
    }

    public func saveItem(_ item: JobItem) {
        guard let json = encode(item) else { return }
        locked("save item") { try upsertItem(item, json: json) }
    }

    /// Unlocked; callers hold `lock`.
    private func upsertItem(_ item: JobItem, json: String) throws {
        try db.execute("""
        INSERT INTO job_items (id, job_id, step_id, idx, json, status, attempts, updated_at) VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET json=excluded.json, status=excluded.status, attempts=excluded.attempts, updated_at=excluded.updated_at
        """, [.text(item.id), .text(item.jobID), .int(Int64(item.stepID)), .int(Int64(item.index)), .text(json),
              .text(item.status.rawValue), .int(Int64(item.attempts)), .real(item.updatedAt.timeIntervalSince1970)])
    }

    public func item(_ id: String) -> JobItem? {
        lockedQuery("SELECT json FROM job_items WHERE id=?", [.text(id)]).first.flatMap { $0["json"]?.string }.flatMap { decode(JobItem.self, $0) }
    }

    /// Items of a job in index order, optionally for one step and/or one status.
    public func items(jobID: String, stepID: Int? = nil, status: ItemStatus? = nil, limit: Int? = nil) -> [JobItem] {
        var sql = "SELECT json FROM job_items WHERE job_id=?"
        var params: [SQLiteDatabase.Value] = [.text(jobID)]
        if let stepID { sql += " AND step_id=?"; params.append(.int(Int64(stepID))) }
        if let status { sql += " AND status=?"; params.append(.text(status.rawValue)) }
        sql += " ORDER BY step_id, idx"
        if let limit { sql += " LIMIT ?"; params.append(.int(Int64(max(0, limit)))) }
        return lockedQuery(sql, params).compactMap { $0["json"]?.string.flatMap { decode(JobItem.self, $0) } }
    }

    /// Items that still need work: pending ones, and failed ones with attempts left.
    public func runnableItems(jobID: String, stepID: Int, maxAttempts: Int) -> [JobItem] {
        lockedQuery("""
        SELECT json FROM job_items WHERE job_id=? AND step_id=? AND (status='pending' OR (status='failed' AND attempts < ?))
        ORDER BY idx
        """, [.text(jobID), .int(Int64(stepID)), .int(Int64(maxAttempts))]).compactMap { $0["json"]?.string.flatMap { decode(JobItem.self, $0) } }
    }

    /// Item counts by status.
    public func itemCounts(jobID: String, stepID: Int? = nil) -> [ItemStatus: Int] {
        var sql = "SELECT status, COUNT(*) AS n FROM job_items WHERE job_id=?"
        var params: [SQLiteDatabase.Value] = [.text(jobID)]
        if let stepID { sql += " AND step_id=?"; params.append(.int(Int64(stepID))) }
        sql += " GROUP BY status"
        var out: [ItemStatus: Int] = [:]
        for row in lockedQuery(sql, params) {
            if let s = row["status"]?.string.flatMap(ItemStatus.init(rawValue:)) { out[s] = row["n"]?.int ?? 0 }
        }
        return out
    }

    /// Progress counts where a failed item only counts as failed once it has no attempts left
    /// (until then it is still going to be retried).
    public func progressCounts(jobID: String, stepID: Int? = nil, maxAttempts: Int) -> (total: Int, done: Int, failed: Int, skipped: Int) {
        var sql = """
        SELECT COUNT(*) AS total,
          SUM(CASE WHEN status='done' THEN 1 ELSE 0 END) AS done,
          SUM(CASE WHEN status='failed' AND attempts >= ? THEN 1 ELSE 0 END) AS failed,
          SUM(CASE WHEN status='skipped' THEN 1 ELSE 0 END) AS skipped
        FROM job_items WHERE job_id=?
        """
        var params: [SQLiteDatabase.Value] = [.int(Int64(maxAttempts)), .text(jobID)]
        if let stepID { sql += " AND step_id=?"; params.append(.int(Int64(stepID))) }
        guard let r = lockedQuery(sql, params).first else { return (0, 0, 0, 0) }
        return (r["total"]?.int ?? 0, r["done"]?.int ?? 0, r["failed"]?.int ?? 0, r["skipped"]?.int ?? 0)
    }

    public func itemCount(jobID: String, stepID: Int) -> Int {
        lockedQuery("SELECT COUNT(*) AS n FROM job_items WHERE job_id=? AND step_id=?", [.text(jobID), .int(Int64(stepID))]).first?["n"]?.int ?? 0
    }

    public func deleteItems(jobID: String, stepID: Int) {
        locked("delete items") { try db.execute("DELETE FROM job_items WHERE job_id=? AND step_id=?", [.text(jobID), .int(Int64(stepID))]) }
    }

    /// Items left `running` by a crash or quit go back to `pending`; the interrupted attempt
    /// doesn't count against the item.
    @discardableResult
    public func resetRunningItems(jobID: String, stepID: Int? = nil) -> Int {
        let stale = items(jobID: jobID, stepID: stepID, status: .running)
        guard !stale.isEmpty else { return 0 }
        let reset = stale.map { item -> JobItem in
            var i = item
            i.status = .pending
            i.attempts = max(0, i.attempts - 1)
            i.updatedAt = Date()
            return i
        }
        insertItems(reset)
        return reset.count
    }

    /// Puts every failed item back to `pending` with fresh attempts. Returns the affected step ids.
    @discardableResult
    public func requeueFailedItems(jobID: String) -> [Int] {
        let failed = items(jobID: jobID, status: .failed)
        guard !failed.isEmpty else { return [] }
        let requeued = failed.map { item -> JobItem in
            var i = item
            i.status = .pending
            i.attempts = 0
            i.error = nil
            i.updatedAt = Date()
            return i
        }
        insertItems(requeued)
        return Array(Set(failed.map(\.stepID))).sorted()
    }

    // MARK: - Events

    public func appendEvent(jobID: String, _ entry: ActivityEntry) {
        var e = entry
        e.title = SecretScrubber.scrub(e.title)
        e.detail = e.detail.map { SecretScrubber.scrub($0) }
        guard let json = encode(e) else { return }
        var prune = false
        locked("append event") {
            try db.execute("INSERT OR REPLACE INTO job_events (id, job_id, ts, json) VALUES (?,?,?,?)",
                           [.text(e.id.uuidString), .text(jobID), .real(e.timestamp.timeIntervalSince1970), .text(json)])
            let n = (appendsSincePrune[jobID] ?? 0) + 1
            appendsSincePrune[jobID] = n
            if n >= 250 { appendsSincePrune[jobID] = 0; prune = true }
        }
        if prune { pruneEvents(jobID: jobID) }
    }

    private func pruneEvents(jobID: String) {
        locked("prune events") {
            try db.execute("""
            DELETE FROM job_events WHERE job_id=? AND id NOT IN (
              SELECT id FROM job_events WHERE job_id=? ORDER BY ts DESC LIMIT ?)
            """, [.text(jobID), .text(jobID), .int(Int64(Self.maxEventsPerJob))])
        }
    }

    /// The most recent `limit` events, oldest first.
    public func events(jobID: String, limit: Int = 300) -> [ActivityEntry] {
        lockedQuery("""
        SELECT json FROM (SELECT json, ts, rowid AS seq FROM job_events WHERE job_id=? ORDER BY ts DESC, rowid DESC LIMIT ?)
        ORDER BY ts ASC, seq ASC
        """, [.text(jobID), .int(Int64(max(0, limit)))]).compactMap { $0["json"]?.string.flatMap { decode(ActivityEntry.self, $0) } }
    }

    // MARK: - Facts

    public func setFact(jobID: String, key: String, value: String, at date: Date = Date()) {
        locked("set fact") {
            try db.execute("""
            INSERT INTO job_facts (job_id, key, value, updated_at) VALUES (?,?,?,?)
            ON CONFLICT(job_id, key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
            """, [.text(jobID), .text(key), .text(value), .real(date.timeIntervalSince1970)])
        }
    }

    /// Facts, most recently updated first.
    public func facts(jobID: String, limit: Int = 2000) -> [WorkspaceFact] {
        lockedQuery("SELECT key, value, updated_at FROM job_facts WHERE job_id=? ORDER BY updated_at DESC, rowid DESC LIMIT ?",
                    [.text(jobID), .int(Int64(max(0, limit)))]).map {
            WorkspaceFact(key: $0["key"]?.string ?? "", value: $0["value"]?.string ?? "",
                          updatedAt: Date(timeIntervalSince1970: $0["updated_at"]?.double ?? 0))
        }
    }

    // MARK: - Rows

    /// Inserts or updates a row. New rows go to the end unless `order` is given (the job engine
    /// passes the item index so result tables keep the source order despite parallel work);
    /// an update keeps the row's place.
    public func upsertRow(jobID: String, table: String, key: String, fields: [String: JSONValue], order: Double? = nil, at date: Date = Date()) {
        guard let json = encode(fields) else { return }
        locked("upsert row") {
            let ord: Double
            if let order {
                ord = order
            } else if let existing = try db.query("SELECT ord FROM job_rows WHERE job_id=? AND table_name=? AND row_key=?",
                                                  [.text(jobID), .text(table), .text(key)]).first?["ord"]?.double {
                ord = existing
            } else {
                let maxOrd = try db.query("SELECT MAX(ord) AS m FROM job_rows WHERE job_id=? AND table_name=?", [.text(jobID), .text(table)])
                    .first?["m"]?.double
                ord = (maxOrd ?? -1) + 1
            }
            try db.execute("""
            INSERT INTO job_rows (job_id, table_name, row_key, json, ord, updated_at) VALUES (?,?,?,?,?,?)
            ON CONFLICT(job_id, table_name, row_key) DO UPDATE SET json=excluded.json, ord=excluded.ord, updated_at=excluded.updated_at
            """, [.text(jobID), .text(table), .text(key), .text(json), .real(ord), .real(date.timeIntervalSince1970)])
        }
    }

    public func rows(jobID: String, table: String, limit: Int? = nil) -> [WorkspaceRow] {
        var sql = "SELECT row_key, json FROM job_rows WHERE job_id=? AND table_name=? ORDER BY ord, rowid"
        var params: [SQLiteDatabase.Value] = [.text(jobID), .text(table)]
        if let limit { sql += " LIMIT ?"; params.append(.int(Int64(max(0, limit)))) }
        return lockedQuery(sql, params).map { r in
            WorkspaceRow(key: r["row_key"]?.string ?? "", fields: r["json"]?.string.flatMap { decode([String: JSONValue].self, $0) } ?? [:])
        }
    }

    public func row(jobID: String, table: String, key: String) -> WorkspaceRow? {
        lockedQuery("SELECT row_key, json FROM job_rows WHERE job_id=? AND table_name=? AND row_key=?", [.text(jobID), .text(table), .text(key)])
            .first.map { r in
                WorkspaceRow(key: r["row_key"]?.string ?? "", fields: r["json"]?.string.flatMap { decode([String: JSONValue].self, $0) } ?? [:])
            }
    }

    /// Table names in the order they were first written to.
    public func tableNames(jobID: String) -> [String] {
        lockedQuery("SELECT table_name, MIN(rowid) AS first FROM job_rows WHERE job_id=? GROUP BY table_name ORDER BY first", [.text(jobID)])
            .compactMap { $0["table_name"]?.string }
    }

    public func rowCount(jobID: String, table: String) -> Int {
        lockedQuery("SELECT COUNT(*) AS n FROM job_rows WHERE job_id=? AND table_name=?", [.text(jobID), .text(table)]).first?["n"]?.int ?? 0
    }

    // MARK: - Engine state

    func state(jobID: String, key: String) -> String? {
        lockedQuery("SELECT value FROM job_state WHERE job_id=? AND key=?", [.text(jobID), .text(key)]).first?["value"]?.string
    }

    func setState(jobID: String, key: String, value: String?) {
        locked("set state") {
            if let value {
                try db.execute("INSERT OR REPLACE INTO job_state (job_id, key, value) VALUES (?,?,?)", [.text(jobID), .text(key), .text(value)])
            } else {
                try db.execute("DELETE FROM job_state WHERE job_id=? AND key=?", [.text(jobID), .text(key)])
            }
        }
    }

    /// Clears every state key starting with `prefix` (e.g. per-milestone retry counters).
    func clearState(jobID: String, prefix: String) {
        locked("clear state") {
            // Escape LIKE wildcards so a prefix can't match more than intended.
            let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            try db.execute("DELETE FROM job_state WHERE job_id=? AND key LIKE ? ESCAPE '\\'", [.text(jobID), .text(escaped + "%")])
        }
    }

    // MARK: - Plumbing

    private func locked(_ what: String, _ body: () throws -> Void) {
        lock.withLock {
            do { try body() } catch { log.error("\(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func lockedQuery(_ sql: String, _ params: [SQLiteDatabase.Value] = []) -> [[String: SQLiteDatabase.Value]] {
        lock.withLock {
            do { return try db.query(sql, params) } catch {
                log.error("query failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        }
    }

    /// Runs `body` in a transaction. Callers hold `lock`, so transactions never nest.
    private func transaction(_ body: () throws -> Void) throws {
        try db.execute("BEGIN IMMEDIATE")
        do {
            try body()
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        // A coder per call: they're cheap, and sharing one across threads isn't documented as safe.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return String(decoding: try encoder.encode(value), as: UTF8.self) } catch {
            log.error("encode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
