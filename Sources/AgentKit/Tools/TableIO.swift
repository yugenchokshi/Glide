import Foundation

/// A table read from or written to a spreadsheet (CSV, TSV, XLSX).
public struct TableData: Codable, Sendable, Hashable {
    public var columns: [String]
    /// Row values as strings, aligned with `columns`.
    public var rows: [[String]]
    /// Sheet name (XLSX) when known.
    public var sheet: String?

    public init(columns: [String], rows: [[String]], sheet: String? = nil) {
        self.columns = columns
        self.rows = rows
        self.sheet = sheet
    }

    /// Rows as objects keyed by column name.
    public var records: [[String: String]] {
        rows.map { row in
            var r: [String: String] = [:]
            for (i, c) in columns.enumerated() { r[c] = i < row.count ? row[i] : "" }
            return r
        }
    }
}

/// Spreadsheet access shared by the data tools and the job engine (item sources, write-back).
/// CONTRACT: the data-tools family installs real implementations (CSV + XLSX); until then a
/// minimal CSV-only fallback is used.
public enum TableIO {
    public typealias Reader = @Sendable (_ path: String, _ sheet: String?, _ hasHeader: Bool) throws -> TableData
    /// Updates cells in place (preserving the rest of the file); adds missing columns.
    /// `keyColumn` nil = match by row order. `updates` are keyed by the key value (or row index as string).
    public typealias Updater = @Sendable (_ path: String, _ sheet: String?, _ keyColumn: String?, _ updates: [String: [String: String]]) throws -> Void
    public typealias Writer = @Sendable (_ path: String, _ table: TableData) throws -> Void

    nonisolated(unsafe) public static var reader: Reader = { path, _, hasHeader in try TableIO.readCSV(path, hasHeader: hasHeader) }
    nonisolated(unsafe) public static var updater: Updater? = nil
    nonisolated(unsafe) public static var writer: Writer = { path, table in try TableIO.writeCSV(path, table) }

    /// Minimal RFC 4180 CSV reader (quoted fields, escaped quotes, CRLF).
    public static func readCSV(_ path: String, hasHeader: Bool) throws -> TableData {
        let text = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
        var rows: [[String]] = []
        var field = "", row: [String] = [], inQuotes = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(ch) }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n": row.append(field); field = ""; rows.append(row); row = []
                case "\r": break
                default: field.append(ch)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        rows.removeAll { $0.count == 1 && $0[0].isEmpty }
        guard hasHeader, let header = rows.first else {
            let width = rows.map(\.count).max() ?? 0
            return TableData(columns: (0..<width).map { "Column \($0 + 1)" }, rows: rows)
        }
        return TableData(columns: header, rows: Array(rows.dropFirst()))
    }

    public static func writeCSV(_ path: String, _ table: TableData) throws {
        func esc(_ s: String) -> String {
            s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let lines = [table.columns.map(esc).joined(separator: ",")] + table.rows.map { $0.map(esc).joined(separator: ",") }
        try (lines.joined(separator: "\n") + "\n").write(toFile: (path as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
    }
}
