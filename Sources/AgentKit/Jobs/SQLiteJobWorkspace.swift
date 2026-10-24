import Foundation

/// A job's memory backed by `JobStore`: facts, result tables and the job folder.
///
/// Model calls only ever see a small, relevant slice of it (`facts(matching:)` and
/// `summary(maxChars:)`), which is what lets a job run for hours without its prompts growing.
public struct SQLiteJobWorkspace: JobWorkspace {
    public let jobID: String
    public let folder: URL
    let store: JobStore

    public init(jobID: String, store: JobStore, folder: URL? = nil) {
        self.jobID = jobID
        self.store = store
        self.folder = folder ?? store.folder(for: jobID)
    }

    public func setFact(_ key: String, _ value: String) async {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        store.setFact(jobID: jobID, key: String(k.prefix(200)), value: String(value.prefix(Self.maxFactChars)))
    }

    /// Facts ranked by how many of the query's keywords they share (key and value), newest
    /// first among equals. Facts sharing no keyword are left out; a nil or keyword-free query
    /// returns the most recent facts.
    public func facts(matching query: String?, limit: Int) async -> [WorkspaceFact] {
        let all = store.facts(jobID: jobID, limit: 2000)
        let wanted = max(0, limit)
        let queryTokens = Set(ElementMatcherShim.tokens(query ?? ""))
        guard !queryTokens.isEmpty else { return Array(all.prefix(wanted)) }
        let scored: [(fact: WorkspaceFact, score: Int, rank: Int)] = all.enumerated().compactMap { offset, fact in
            let tokens = Set(ElementMatcherShim.tokens(fact.key + " " + fact.value))
            let score = tokens.intersection(queryTokens).count
            return score > 0 ? (fact, score, offset) : nil
        }
        // `all` is newest first, so the original offset breaks ties by recency.
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.rank < $1.rank }.prefix(wanted).map(\.fact)
    }

    public func upsertRow(table: String, key: String, fields: [String: JSONValue]) async {
        let t = table.trimmingCharacters(in: .whitespacesAndNewlines), k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !k.isEmpty else { return }
        store.upsertRow(jobID: jobID, table: String(t.prefix(80)), key: String(k.prefix(300)), fields: fields)
    }

    public func rows(table: String, limit: Int?) async -> [WorkspaceRow] {
        store.rows(jobID: jobID, table: table, limit: limit)
    }

    public func tableNames() async -> [String] { store.tableNames(jobID: jobID) }

    /// Tables (row count, columns, one sample row), the 10 most recent facts and the folder's
    /// files, cut to `maxChars`.
    public func summary(maxChars: Int) async -> String {
        var sections: [String] = []
        let tables = store.tableNames(jobID: jobID)
        if tables.isEmpty {
            sections.append("Tables: none yet")
        } else {
            var lines = ["Tables:"]
            for t in tables.prefix(12) {
                let count = store.rowCount(jobID: jobID, table: t)
                let sample = store.rows(jobID: jobID, table: t, limit: 1).first
                let columns = sample.map { $0.fields.keys.sorted().joined(separator: ", ") } ?? ""
                lines.append("- \(t): \(count) row\(count == 1 ? "" : "s")" + (columns.isEmpty ? "" : " (fields: \(columns))"))
                if let sample {
                    lines.append("  e.g. \(sample.key): \(String(JSONValue.object(sample.fields).jsonString().prefix(300)))")
                }
            }
            if tables.count > 12 { lines.append("- …and \(tables.count - 12) more tables") }
            sections.append(lines.joined(separator: "\n"))
        }
        let recent = store.facts(jobID: jobID, limit: 10)
        if recent.isEmpty {
            sections.append("Facts: none yet")
        } else {
            sections.append((["Recent facts:"] + recent.map { "- \($0.key): \(Self.oneLine($0.value, max: 240))" }).joined(separator: "\n"))
        }
        let files = Self.listFiles(in: folder, max: 20)
        sections.append(files.isEmpty ? "Files in the job folder: none" : "Files in the job folder: " + files.joined(separator: ", "))
        let text = sections.joined(separator: "\n")
        return text.count > maxChars ? String(text.prefix(max(0, maxChars - 1))) + "…" : text
    }

    // MARK: - Helpers

    static let maxFactChars = 20_000

    static func oneLine(_ s: String, max: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    /// Relative file names with sizes (top two levels, hidden files skipped).
    static func listFiles(in folder: URL, max: Int) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        let base = folder.standardizedFileURL.path
        while let url = e.nextObject() as? URL {
            if e.level > 2 { e.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            var rel = url.standardizedFileURL.path
            if rel.hasPrefix(base + "/") { rel.removeFirst(base.count + 1) }
            out.append("\(rel) (\(ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)))")
            if out.count >= max { out.append("…"); break }
        }
        return out
    }
}
