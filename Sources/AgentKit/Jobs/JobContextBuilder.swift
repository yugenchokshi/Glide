import Foundation

/// Builds the compact context a step model gets inside a job: where the job is, the current
/// item, the facts relevant to this step and an overview of what's been saved. It's what keeps
/// prompts small and steady in size however long the job runs.
enum JobContextBuilder {
    struct ItemContext: Sendable {
        var item: JobItem
        var label: String
        var total: Int
        /// Fields earlier recipe steps produced for this item in this attempt.
        var partial: [String: JSONValue]
    }

    static func build(record: JobRecord, milestoneIndex: Int, step: RecipeStep, parentTitle: String?, item: ItemContext?,
                      workspace: any JobWorkspace, maxChars: Int = 7000) async -> String {
        var lines: [String] = []
        let plan = record.plan
        if let plan {
            lines.append("Job: \(plan.goal.isEmpty ? record.instruction : plan.goal)")
            if !plan.outputs.isEmpty { lines.append("Expected outputs: \(plan.outputs)") }
            if plan.milestones.indices.contains(milestoneIndex) {
                let m = plan.milestones[milestoneIndex]
                var line = "Milestone \(milestoneIndex + 1) of \(plan.milestones.count): \(m.title)"
                if !m.description.isEmpty { line += " — \(m.description)" }
                if !m.doneWhen.isEmpty { line += " (done when: \(m.doneWhen))" }
                lines.append(line)
                let done = plan.milestones.prefix(milestoneIndex).map { "“\($0.title)”" }
                if !done.isEmpty { lines.append("Finished milestones: " + done.joined(separator: ", ")) }
            }
        } else {
            lines.append("Job: \(record.instruction)")
        }
        if let parentTitle { lines.append("Current loop: \(parentTitle)") }
        let u = record.usage
        if u.itemsTotal > 0 {
            lines.append("Progress: \(u.itemsDone) of \(u.itemsTotal) items done" + (u.itemsFailed > 0 ? ", \(u.itemsFailed) failed" : ""))
        }
        if let item {
            lines.append("")
            lines.append("Current \(item.label) (\(item.item.index + 1) of \(item.total)): \(item.item.title)")
            lines.append("Item data: " + String(item.item.input.jsonString().prefix(2000)))
            if !item.partial.isEmpty {
                lines.append("Results so far for this \(item.label): " + String(JSONValue.object(item.partial).jsonString().prefix(2000)))
            }
            if item.item.attempts > 1, let err = item.item.error {
                lines.append("A previous attempt failed: \(err.prefix(300)). Try a different approach.")
            }
        }
        let facts = await workspace.facts(matching: step.title + " " + step.instruction + " " + (item?.item.title ?? ""), limit: 8)
        if !facts.isEmpty {
            lines.append("")
            lines.append("Relevant facts from earlier in the job:")
            for f in facts { lines.append("- \(f.key): \(SQLiteJobWorkspace.oneLine(f.value, max: 400))") }
        }
        lines.append("")
        lines.append("Job memory overview:")
        lines.append(await workspace.summary(maxChars: 1500))
        if !step.outputFields.isEmpty {
            lines.append("")
            lines.append("Produce these result fields: " + step.outputFields.joined(separator: ", "))
        }
        let text = lines.joined(separator: "\n")
        return text.count > maxChars ? String(text.prefix(maxChars - 1)) + "…" : text
    }
}

/// Spreadsheet write-back helpers: building updates from item results, and a CSV updater
/// used when the data-tools family (which also handles XLSX) isn't installed.
enum JobWriteBack {
    /// Writes `updates` with an injected updater, else the installed `TableIO.updater`, else
    /// the CSV fallback (which adds new columns in the write-back's column order).
    static func write(_ path: String, _ wb: WriteBack, _ updates: [String: [String: String]], injected: TableIO.Updater?, owner: String? = nil) throws {
        if let updater = injected ?? TableIO.updater {
            try updater(path, wb.sheet, wb.keyColumn, updates, TableIO.UpdateOptions(columnOrder: wb.columns, owner: owner))
        } else {
            try csvUpdate(path, keyColumn: wb.keyColumn, updates: updates, columnOrder: wb.columns)
        }
    }

    /// `TableIO.Updater`-shaped CSV fallback.
    static let csvUpdate: TableIO.Updater = { path, _, keyColumn, updates, options in
        try csvUpdate(path, keyColumn: keyColumn, updates: updates, columnOrder: options.columnOrder)
    }

    /// Updates cells of a CSV in place: adds missing columns (in `columnOrder`, then
    /// alphabetically), matches rows by `keyColumn` (all rows with that value) or by 0-based
    /// data-row index, appends rows for unknown keys, keeps a one-time `.bak` copy, and writes
    /// atomically.
    static func csvUpdate(_ path: String, keyColumn: String?, updates: [String: [String: String]], columnOrder: [String]) throws {
        let expanded = (path as NSString).expandingTildeInPath
        let ext = (expanded as NSString).pathExtension.lowercased()
        guard ext == "csv" || ext == "txt" else {
            throw ToolError.unavailable("Writing results into .\(ext) files needs Glide's spreadsheet tools, which aren't installed in this build.")
        }
        var table = try TableIO.readCSV(expanded, hasHeader: true)
        func columnIndex(_ name: String) -> Int? {
            table.columns.firstIndex { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
        }
        let mentioned = Set(updates.values.flatMap(\.keys))
        for column in columnOrder where mentioned.contains(column) && columnIndex(column) == nil { table.columns.append(column) }
        for column in mentioned.sorted() where columnIndex(column) == nil { table.columns.append(column) }
        let width = table.columns.count
        for i in table.rows.indices where table.rows[i].count < width {
            table.rows[i] += Array(repeating: "", count: width - table.rows[i].count)
        }
        let keyIndex = keyColumn.flatMap(columnIndex)
        for key in updates.keys.sorted() {
            guard let change = updates[key] else { continue }
            var targets: [Int] = []
            if let keyIndex {
                targets = table.rows.indices.filter { table.rows[$0][keyIndex].trimmingCharacters(in: .whitespaces) == key.trimmingCharacters(in: .whitespaces) }
                if targets.isEmpty {
                    var row = Array(repeating: "", count: width)
                    row[keyIndex] = key
                    table.rows.append(row)
                    targets = [table.rows.count - 1]
                }
            } else if let index = Int(key), table.rows.indices.contains(index) {
                targets = [index]
            }
            for t in targets {
                for (column, value) in change {
                    if let c = columnIndex(column) { table.rows[t][c] = value }
                }
            }
        }
        let backup = expanded + ".bak"
        if !FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.copyItem(atPath: expanded, toPath: backup)
        }
        try TableIO.writeCSV(expanded, table)
    }

    /// Case-insensitive field lookup in an item's results.
    static func field(_ name: String, in fields: [String: JSONValue]) -> JSONValue? {
        if let v = fields[name] { return v }
        let n = name.lowercased().replacingOccurrences(of: " ", with: "_")
        return fields.first { $0.key.lowercased().replacingOccurrences(of: " ", with: "_") == n }?.value
    }

    /// Cell text for a result value.
    static func cell(_ v: JSONValue) -> String {
        switch v {
        case .null: return ""
        case .string, .number, .bool: return v.stringValue ?? ""
        case .array(let a) where a.allSatisfy({ $0.stringValue != nil }): return a.compactMap(\.stringValue).joined(separator: "; ")
        default: return v.jsonString()
        }
    }
}

extension JSONValue {
    /// Lenient truth test for model-produced flags ("true", "yes", 1).
    var truthy: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "y", "1", "done", "met": return true
            case "false", "no", "n", "0", "not done", "not met": return false
            default: return nil
            }
        default: return nil
        }
    }
}
