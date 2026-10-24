import Foundation

/// The spreadsheet tool family (`sheet.*`) plus the real `TableIO` hooks the job engine uses
/// for item sources and write-back.
public enum DataTools {
    /// Call once at launch (app and CLI).
    public static func install() {
        TableIO.reader = { path, sheet, hasHeader in try Spreadsheet.read(path, sheet: sheet, hasHeader: hasHeader) }
        TableIO.updater = { path, sheet, keyColumn, updates in
            // Write-back keeps one .bak per file per app session, made before the first change.
            try Spreadsheet.update(path, sheet: sheet, keyColumn: keyColumn, updates: updates, owner: "job-write-back")
        }
        TableIO.writer = { path, table in try Spreadsheet.write(path, table) }
        ToolRegistry.registerFactory("data") { _ in tools() }
    }

    public static func tools() -> [any AgentTool] {
        [SheetReadTool(), SheetWriteTool(), SheetUpdateTool(), SheetAppendTool()]
    }
}

// MARK: - Shared helpers

enum SheetArgs {
    static func path(_ args: JSONValue, _ context: ToolContext) throws -> String {
        DataPaths.resolve(try args.requiredString("path"), base: context.workingDirectory)
    }

    /// Who "owns" a change for backups and provenance: the job, else this quick task.
    static func owner(_ context: ToolContext) -> String { context.jobID ?? context.itemID ?? "quick-task" }

    /// JSON value → cell text. Null clears a cell; objects and arrays are stored as JSON.
    static func cell(_ v: JSONValue) -> String {
        switch v {
        case .null: return ""
        case .string(let s): return s
        case .number, .bool: return v.stringValue ?? ""
        case .array, .object: return v.jsonString()
        }
    }

    /// Accepts an array of strings or a comma-separated string.
    static func stringList(_ v: JSONValue?) -> [String]? {
        guard let v, !v.isNull else { return nil }
        if let a = v.arrayValue { return a.compactMap { $0.stringValue }.filter { !$0.isEmpty } }
        if let s = v.stringValue { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return nil
    }

    /// Models sometimes send nested JSON as a string; accept both.
    static func structured(_ v: JSONValue?) -> JSONValue? {
        guard let v, !v.isNull else { return nil }
        if case .string(let s) = v, let parsed = try? JSONValue.parse(s) { return parsed }
        return v
    }

    static func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// Risk of changing a spreadsheet file. Writes outside the user's folders are high, system
    /// folders are blocked, and changing a file that existed before this job is high.
    static func writeVerdict(_ path: String, context: ToolContext, destructive: Bool, summary: String) -> ToolVerdict {
        let real = DataPaths.realPath(path)
        if let reason = DataPaths.forbiddenReason(real) { return ToolVerdict(risk: .high, reasons: ["system folder"], blocked: reason, summary: summary) }
        var risk: RiskLevel = .medium
        var reasons: [String] = []
        if !DataPaths.isInUserSpace(real) { risk = .high; reasons.append("writes outside your home folder") }
        if destructive, FileManager.default.fileExists(atPath: real), !ownedByJob(real, context: context) {
            risk = .high
            reasons.append("changes “\((real as NSString).lastPathComponent)”, which existed before this task")
        }
        return ToolVerdict(risk: risk, reasons: reasons, summary: summary)
    }

    /// Files this job created, or anything inside its own folder.
    static func ownedByJob(_ real: String, context: ToolContext) -> Bool {
        if FileProvenance.wasCreated(real, owner: owner(context)) { return true }
        if DataPaths.isInside(real, folder: context.workspace?.folder) { return true }
        if context.jobID != nil, DataPaths.isInside(real, folder: context.workingDirectory) { return true }
        return false
    }

    static func failure(_ error: Error, start: Date) -> ToolOutput {
        ToolOutput(ok: false, text: error.localizedDescription, durationMs: Date().timeIntervalSince(start) * 1000)
    }

    static func describe(_ c: SpreadsheetChange, path: String) -> String {
        var parts = ["\(c.updatedCells) cell\(c.updatedCells == 1 ? "" : "s") changed"]
        if c.addedRows > 0 { parts.append("\(c.addedRows) row\(c.addedRows == 1 ? "" : "s") added") }
        if !c.addedColumns.isEmpty { parts.append("new column\(c.addedColumns.count == 1 ? "" : "s"): \(c.addedColumns.joined(separator: ", "))") }
        var text = "Updated \(display(path))\(c.sheet.map { " (sheet “\($0)”)" } ?? ""): " + parts.joined(separator: "; ") + "."
        if let b = c.backupPath { text += " The original is saved as \(display(b))." }
        if c.updatedCells == 0 && c.addedRows == 0 && c.addedColumns.isEmpty { text = "Nothing to change in \(display(path)): the values were already there." }
        return text
    }

    static func changeData(_ c: SpreadsheetChange, path: String) -> JSONValue {
        .object([
            "path": .string(path),
            "sheet": c.sheet.map { .string($0) } ?? .null,
            "updated_cells": .number(Double(c.updatedCells)),
            "added_rows": .number(Double(c.addedRows)),
            "added_columns": .array(c.addedColumns.map { .string($0) }),
            "backup": c.backupPath.map { .string($0) } ?? .null,
        ])
    }
}

// MARK: - sheet.read

struct SheetReadTool: AgentTool {
    static let defaultRows = 50
    static let maxRows = 500

    let spec = ToolSpec(
        name: "sheet.read",
        summary: "Read a CSV, TSV or Excel .xlsx file: sheet names, columns, row count and rows as JSON. Rows are numbered from 0 (the first row under the header).",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "File path (~ allowed)."],
                "sheet": ["type": "string", "description": "Sheet name or 1-based number (xlsx). Default: the first sheet."],
                "has_header": ["type": "boolean", "description": "First row holds column names. Default true."],
                "max_rows": ["type": "integer", "description": "Rows to return (default 50, max 500)."],
                "start_row": ["type": "integer", "description": "First row to return, 0-based. Default 0."],
                "columns": ["type": "array", "items": ["type": "string"], "description": "Only these columns."],
            ],
            "required": ["path"],
        ],
        category: .data,
        readOnly: true
    )

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let p = arguments.optionalString("path").map { SheetArgs.display(DataPaths.resolve($0, base: context.workingDirectory)) } ?? "a spreadsheet"
        return ToolVerdict(risk: .low, summary: "Read \(p)")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try context.gate.checkStopped()
        let start = Date()
        let path = try SheetArgs.path(arguments, context)
        let sheet = arguments.optionalString("sheet")
        let hasHeader = arguments.optionalBool("has_header") ?? true
        let maxRows = min(max(arguments.optionalInt("max_rows") ?? Self.defaultRows, 1), Self.maxRows)
        let startRow = max(arguments.optionalInt("start_row") ?? 0, 0)
        let wanted = SheetArgs.stringList(arguments["columns"])
        let grid: LoadedGrid
        do { grid = try await runBlocking { try Spreadsheet.load(path, sheet: sheet, hasHeader: hasHeader) } } catch let e as SpreadsheetError {
            return SheetArgs.failure(e, start: start)
        }

        var colIdx = Array(grid.columns.indices)
        if let wanted, !wanted.isEmpty {
            var picked: [Int] = [], missing: [String] = []
            for w in wanted {
                if let i = grid.columns.firstIndex(where: { $0.caseInsensitiveCompare(w.trimmingCharacters(in: .whitespaces)) == .orderedSame }) { picked.append(i) } else { missing.append(w) }
            }
            if !missing.isEmpty {
                return ToolOutput(ok: false, text: "No column named \(missing.map { "“\($0)”" }.joined(separator: ", ")). Columns: \(grid.columns.joined(separator: ", ")).",
                                  durationMs: Date().timeIntervalSince(start) * 1000)
            }
            colIdx = picked
        }
        let total = grid.rows.count
        let lower = min(startRow, total), upper = min(lower + maxRows, total)
        let slice = grid.rows[lower..<upper]
        let names = colIdx.map { grid.columns[$0] }

        var text = SheetArgs.display(path)
        if let s = grid.sheet { text += " — sheet “\(s)”" + (grid.sheets.count > 1 ? " (sheets: \(grid.sheets.joined(separator: ", ")))" : "") }
        text += " — \(total) row\(total == 1 ? "" : "s") × \(grid.columns.count) column\(grid.columns.count == 1 ? "" : "s")\n"
        text += "Columns: \(grid.columns.joined(separator: ", "))\n"
        if !slice.isEmpty {
            func clip(_ s: String) -> String {
                let flat = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/")
                return flat.count > 120 ? String(flat.prefix(117)) + "…" : flat
            }
            text += "row | " + names.map(clip).joined(separator: " | ") + "\n"
            for (offset, r) in slice.enumerated() {
                text += "\(lower + offset) | " + colIdx.map { clip($0 < r.count ? r[$0] : "") }.joined(separator: " | ") + "\n"
            }
        }
        if upper < total || lower > 0 {
            text += "(rows \(lower)–\(max(lower, upper - 1)) of \(total); use start_row/max_rows for more)\n"
        }
        let records: [JSONValue] = slice.map { r in
            .object(Dictionary(colIdx.map { (grid.columns[$0], JSONValue.string($0 < r.count ? r[$0] : "")) }, uniquingKeysWith: { a, _ in a }))
        }
        let data: JSONValue = .object([
            "path": .string(path),
            "sheet": grid.sheet.map { .string($0) } ?? .null,
            "sheets": .array(grid.sheets.map { .string($0) }),
            "columns": .array(names.map { .string($0) }),
            "row_count": .number(Double(total)),
            "start_row": .number(Double(lower)),
            "rows": .array(records),
            "truncated": .bool(upper < total),
        ])
        return ToolOutput(ok: true, text: toolTruncate(text), data: data, durationMs: Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - sheet.write

struct SheetWriteTool: AgentTool {
    static let maxRows = 200_000

    let spec = ToolSpec(
        name: "sheet.write",
        summary: "Create a CSV, TSV or .xlsx file from columns and rows (format by extension). mode create (default) refuses to replace a file; overwrite replaces it. Values are written as text or plain numbers, never as formulas.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "columns": ["type": "array", "items": ["type": "string"], "description": "Header names, in order."],
                "rows": ["type": "array", "description": "Rows: arrays aligned with columns, or objects keyed by column name."],
                "mode": ["type": "string", "enum": ["create", "overwrite"]],
                "sheet": ["type": "string", "description": "Sheet name for .xlsx (default Sheet1)."],
            ],
            "required": ["path", "columns", "rows"],
        ],
        category: .data
    )

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        guard let raw = arguments.optionalString("path") else { return ToolVerdict(risk: .medium, summary: "Write a spreadsheet") }
        let path = DataPaths.resolve(raw, base: context.workingDirectory)
        let overwrite = arguments.optionalString("mode")?.lowercased() == "overwrite"
        return SheetArgs.writeVerdict(path, context: context, destructive: overwrite,
                                      summary: "\(overwrite ? "Overwrite" : "Create") \(SheetArgs.display(path))")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try context.gate.checkStopped()
        let start = Date()
        let path = try SheetArgs.path(arguments, context)
        let mode = arguments.optionalString("mode")?.lowercased() ?? "create"
        guard mode == "create" || mode == "overwrite" else { throw ToolError.invalidArguments("mode must be “create” or “overwrite”") }
        guard let rowsValue = SheetArgs.structured(arguments["rows"])?.arrayValue else { throw ToolError.invalidArguments("“rows” must be an array") }
        guard rowsValue.count <= Self.maxRows else { throw ToolError.invalidArguments("at most \(Self.maxRows) rows per call") }
        var columns = SheetArgs.stringList(arguments["columns"]) ?? []
        if columns.isEmpty {
            // Derive columns from object rows when none were given.
            for r in rowsValue { for k in (r.objectValue?.keys.sorted() ?? []) where !columns.contains(k) { columns.append(k) } }
        }
        guard !columns.isEmpty else { throw ToolError.invalidArguments("give “columns” (the header names)") }
        var rows: [[String]] = []
        for (i, r) in rowsValue.enumerated() {
            if let a = r.arrayValue {
                guard a.count <= columns.count else { throw ToolError.invalidArguments("row \(i) has \(a.count) values but there are \(columns.count) columns") }
                rows.append(a.map(SheetArgs.cell))
            } else if let o = r.objectValue {
                let unknown = o.keys.filter { !columns.contains($0) }
                guard unknown.isEmpty else { throw ToolError.invalidArguments("row \(i) has fields that aren't columns: \(unknown.sorted().joined(separator: ", "))") }
                rows.append(columns.map { o[$0].map(SheetArgs.cell) ?? "" })
            } else {
                throw ToolError.invalidArguments("row \(i) must be an array or an object")
            }
        }
        do { _ = try SpreadsheetFormat.detect(path) } catch { return SheetArgs.failure(error, start: start) }
        let existed = FileManager.default.fileExists(atPath: path)
        if existed && mode == "create" {
            return ToolOutput(ok: false, text: "\(SheetArgs.display(path)) already exists. Use mode “overwrite” to replace it, or pick another name.",
                              durationMs: Date().timeIntervalSince(start) * 1000)
        }
        let table = TableData(columns: columns, rows: rows, sheet: arguments.optionalString("sheet"))
        let owner = SheetArgs.owner(context)
        let backup: String?
        do {
            backup = try await runBlocking { try Spreadsheet.write(path, table, backup: existed, owner: owner) }
        } catch let e as SpreadsheetError {
            return SheetArgs.failure(e, start: start)
        }
        if !existed { FileProvenance.markCreated(DataPaths.realPath(path), owner: owner) }
        var text = "\(existed ? "Replaced" : "Created") \(SheetArgs.display(path)) with \(rows.count) row\(rows.count == 1 ? "" : "s") × \(columns.count) column\(columns.count == 1 ? "" : "s")."
        if let backup { text += " The previous version is saved as \(SheetArgs.display(backup))." }
        return ToolOutput(ok: true, text: text,
                          data: .object(["path": .string(path), "rows": .number(Double(rows.count)), "columns": .array(columns.map { .string($0) })]),
                          artifacts: [URL(fileURLWithPath: path)], durationMs: Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - sheet.update

struct SheetUpdateTool: AgentTool {
    let spec = ToolSpec(
        name: "sheet.update",
        summary: "Change cells in place in a CSV/TSV/.xlsx, keeping everything else (styles, other sheets, formulas). updates = {key: {column: value}}; key matches key_column, or is a 0-based row number without it. Unknown keys add rows; unknown columns are added. Keeps a .bak of the original.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "sheet": ["type": "string", "description": "Sheet name or 1-based number (xlsx)."],
                "key_column": ["type": "string", "description": "Column whose values identify rows. Omit to use row numbers."],
                "updates": ["type": "object", "description": "{\"<key>\": {\"<column>\": \"<value>\"}}; null clears a cell."],
            ],
            "required": ["path", "updates"],
        ],
        category: .data
    )

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        guard let raw = arguments.optionalString("path") else { return ToolVerdict(risk: .high, summary: "Update a spreadsheet") }
        let path = DataPaths.resolve(raw, base: context.workingDirectory)
        let n = SheetArgs.structured(arguments["updates"])?.objectValue?.count ?? 0
        return SheetArgs.writeVerdict(path, context: context, destructive: true,
                                      summary: "Update \(n) row\(n == 1 ? "" : "s") in \(SheetArgs.display(path))")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try context.gate.checkStopped()
        let start = Date()
        let path = try SheetArgs.path(arguments, context)
        guard let obj = SheetArgs.structured(arguments["updates"])?.objectValue, !obj.isEmpty else {
            throw ToolError.invalidArguments("“updates” must be an object like {\"Acme\": {\"Status\": \"done\"}}")
        }
        var updates: [String: [String: String]] = [:]
        for (key, fields) in obj {
            guard let f = SheetArgs.structured(fields)?.objectValue else { throw ToolError.invalidArguments("the update for “\(key)” must be an object of column → value") }
            updates[key] = f.mapValues(SheetArgs.cell)
        }
        let sheet = arguments.optionalString("sheet"), keyColumn = arguments.optionalString("key_column")
        let owner = SheetArgs.owner(context)
        let change: SpreadsheetChange
        let all = updates
        do {
            change = try await runBlocking { try Spreadsheet.update(path, sheet: sheet, keyColumn: keyColumn, updates: all, owner: owner) }
        } catch let e as SpreadsheetError {
            return SheetArgs.failure(e, start: start)
        }
        return ToolOutput(ok: true, text: SheetArgs.describe(change, path: path), data: SheetArgs.changeData(change, path: path),
                          artifacts: [URL(fileURLWithPath: path)], durationMs: Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - sheet.append

struct SheetAppendTool: AgentTool {
    let spec = ToolSpec(
        name: "sheet.append",
        summary: "Add rows to the end of a CSV/TSV/.xlsx (created if missing). rows are objects keyed by column name, or arrays in column order; unknown columns are added.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "rows": ["type": "array", "description": "Objects {column: value} or arrays of values."],
                "columns": ["type": "array", "items": ["type": "string"], "description": "Column order for array rows or a new file."],
                "sheet": ["type": "string", "description": "Sheet name or 1-based number (xlsx)."],
            ],
            "required": ["path", "rows"],
        ],
        category: .data
    )

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        guard let raw = arguments.optionalString("path") else { return ToolVerdict(risk: .medium, summary: "Append to a spreadsheet") }
        let path = DataPaths.resolve(raw, base: context.workingDirectory)
        let n = SheetArgs.structured(arguments["rows"])?.arrayValue?.count ?? 0
        // Appending never changes existing cells, so it stays medium even on existing files.
        return SheetArgs.writeVerdict(path, context: context, destructive: false,
                                      summary: "Append \(n) row\(n == 1 ? "" : "s") to \(SheetArgs.display(path))")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        try context.gate.checkStopped()
        let start = Date()
        let path = try SheetArgs.path(arguments, context)
        guard let rowsValue = SheetArgs.structured(arguments["rows"])?.arrayValue, !rowsValue.isEmpty else {
            throw ToolError.invalidArguments("“rows” must be a non-empty array")
        }
        guard rowsValue.count <= SheetWriteTool.maxRows else { throw ToolError.invalidArguments("at most \(SheetWriteTool.maxRows) rows per call") }
        let given = SheetArgs.stringList(arguments["columns"]) ?? []
        let sheet = arguments.optionalString("sheet")
        let owner = SheetArgs.owner(context)
        let existed = FileManager.default.fileExists(atPath: path)
        let change: SpreadsheetChange
        do {
            change = try await runBlocking {
                var columns = given
                if columns.isEmpty, existed, rowsValue.contains(where: { $0.arrayValue != nil }) {
                    columns = try Spreadsheet.read(path, sheet: sheet, hasHeader: true).columns
                }
                var rows: [[String: String]] = []
                for (i, r) in rowsValue.enumerated() {
                    if let o = r.objectValue {
                        rows.append(o.mapValues(SheetArgs.cell))
                    } else if let a = r.arrayValue {
                        guard !columns.isEmpty else { throw ToolError.invalidArguments("array rows need “columns” (the file doesn't exist yet)") }
                        guard a.count <= columns.count else { throw ToolError.invalidArguments("row \(i) has \(a.count) values but there are \(columns.count) columns") }
                        var o: [String: String] = [:]
                        for (j, v) in a.enumerated() { o[columns[j]] = SheetArgs.cell(v) }
                        rows.append(o)
                    } else {
                        throw ToolError.invalidArguments("row \(i) must be an object or an array")
                    }
                }
                return try Spreadsheet.append(path, sheet: sheet, rows: rows, columnOrder: columns, owner: owner)
            }
        } catch let e as SpreadsheetError {
            return SheetArgs.failure(e, start: start)
        }
        var text = existed ? SheetArgs.describe(change, path: path) : "Created \(SheetArgs.display(path)) with \(change.addedRows) row\(change.addedRows == 1 ? "" : "s")."
        if existed, change.addedRows > 0 { text = "Appended \(change.addedRows) row\(change.addedRows == 1 ? "" : "s") to \(SheetArgs.display(path))." + (change.addedColumns.isEmpty ? "" : " New columns: \(change.addedColumns.joined(separator: ", ")).") }
        return ToolOutput(ok: true, text: text, data: SheetArgs.changeData(change, path: path),
                          artifacts: [URL(fileURLWithPath: path)], durationMs: Date().timeIntervalSince(start) * 1000)
    }
}
