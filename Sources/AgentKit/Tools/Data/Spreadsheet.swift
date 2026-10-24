import Foundation

/// File formats the data tools understand, decided by extension.
public enum SpreadsheetFormat: String, Sendable, Hashable {
    case csv, tsv, xlsx

    /// `.csv` (comma or semicolon, sniffed), `.tsv`/`.tab`, `.txt` (tab or comma, sniffed),
    /// `.xlsx`/`.xlsm`. Anything else gets a plain-language error that says what to do.
    public static func detect(_ path: String) throws -> SpreadsheetFormat {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "csv": return .csv
        case "tsv", "tab", "txt": return .tsv
        case "xlsx", "xlsm": return .xlsx
        case "xls":
            throw SpreadsheetError.unsupportedFormat("“\((path as NSString).lastPathComponent)” is an old Excel .xls file. Open it in Excel or Numbers and save it as .xlsx or CSV first.")
        case "numbers", "ods", "xlsb":
            throw SpreadsheetError.unsupportedFormat("Glide can read and write CSV, TSV and Excel .xlsx files, not .\(ext). Export “\((path as NSString).lastPathComponent)” as .xlsx or CSV first.")
        default:
            throw SpreadsheetError.unsupportedFormat("“\((path as NSString).lastPathComponent)” isn't a spreadsheet Glide can handle. Use a .csv, .tsv or .xlsx file.")
        }
    }

    /// For delimited files: true = tab (.tsv, .tab), false = comma or semicolon (sniffed),
    /// nil = sniff with tab preferred (.txt, which Excel exports tab-delimited).
    static func tabHint(_ path: String) -> Bool? {
        switch (path as NSString).pathExtension.lowercased() {
        case "tsv", "tab": return true
        case "txt": return nil
        default: return false
        }
    }
}

/// What an in-place change did, for tool output and logs.
public struct SpreadsheetChange: Sendable, Hashable {
    public var updatedCells = 0
    public var addedRows = 0
    public var addedColumns: [String] = []
    public var sheet: String?
    /// Set when this change made the `.bak` copy.
    public var backupPath: String?

    public init() {}
}

/// A table plus where each row and column lives in the file, so updates can be written
/// back to exactly the cells that were read.
struct LoadedGrid {
    var columns: [String]
    var rows: [[String]]
    /// For each data row: the CSV line index (0-based) or the XLSX row number (1-based).
    var sourceRows: [Int]
    /// For each column: the CSV field index (0-based) or the XLSX column number (1-based).
    var columnPositions: [Int]
    /// Where the header lives (nil when the table has none).
    var headerSource: Int?
    var nextSourceRow: Int
    var nextColumnPosition: Int
    var sheet: String?
    var sheets: [String]

    var table: TableData { TableData(columns: columns, rows: rows, sheet: sheet) }
}

/// Spreadsheet reading and writing for the data tools and for `TableIO` (job item sources and
/// write-back). Row indexes used for keyless updates are positions in `read(...).rows`: blank
/// rows are skipped there, and the same rule maps an index back to its line or sheet row.
public enum Spreadsheet {
    // MARK: Reading

    public static func read(_ path: String, sheet: String? = nil, hasHeader: Bool = true) throws -> TableData {
        try load(path, sheet: sheet, hasHeader: hasHeader).table
    }

    /// Sheet names of a workbook (empty for CSV/TSV).
    public static func sheetNames(_ path: String) throws -> [String] {
        try load(path, sheet: nil, hasHeader: true).sheets
    }

    static func load(_ rawPath: String, sheet: String?, hasHeader: Bool) throws -> LoadedGrid {
        let path = (rawPath as NSString).expandingTildeInPath
        let format = try SpreadsheetFormat.detect(path)
        try requireFile(path)
        switch format {
        case .csv, .tsv:
            return grid(from: try CSVCodec.load(path, tabSeparated: SpreadsheetFormat.tabHint(path)), hasHeader: hasHeader)
        case .xlsx:
            let dir = try XLSXPackage.makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            try XLSXPackage.checkReadable(path)
            try XLSXPackage.extract(path, to: dir, skipMedia: true)
            let wb = try XLSXWorkbook.load(root: dir)
            let s = try wb.sheet(named: sheet)
            guard let data = XLSXPackage.readPart(dir, s.part) else { throw SpreadsheetError.unreadable("The sheet “\(s.name)” is missing from the workbook.") }
            var g = grid(from: try XLSXSheetReader.read(data, part: s.part, workbook: wb), hasHeader: hasHeader)
            g.sheet = s.name
            g.sheets = wb.sheets.map(\.name)
            return g
        }
    }

    static func requireFile(_ path: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw SpreadsheetError.notFound("There's no file at \((path as NSString).abbreviatingWithTildeInPath).")
        }
        if isDir.boolValue { throw SpreadsheetError.invalid("\((path as NSString).abbreviatingWithTildeInPath) is a folder, not a spreadsheet.") }
    }

    /// Trims names, fills blanks ("Column 3") and disambiguates duplicates ("Name (2)") so every
    /// column can be addressed by name. Lookups only; the file's header text is never rewritten.
    static func normalizeHeader(_ raw: [String]) -> [String] {
        var used = Set<String>()
        return raw.enumerated().map { i, h in
            var name = h.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "Column \(i + 1)" }
            var candidate = name, n = 1
            while used.contains(candidate.lowercased()) { n += 1; candidate = "\(name) (\(n))" }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    private static func isBlank(_ row: [String]) -> Bool { row.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    static func grid(from doc: DelimitedDocument, hasHeader: Bool) -> LoadedGrid {
        let headerIndex = hasHeader ? doc.rows.firstIndex { !isBlank($0) } : nil
        let width = doc.rows.map(\.count).max() ?? 0
        let columns: [String]
        if let headerIndex {
            let h = doc.rows[headerIndex]
            columns = normalizeHeader(h + Array(repeating: "", count: max(0, width - h.count)))
        } else {
            columns = (0..<width).map { "Column \($0 + 1)" }
        }
        var rows: [[String]] = [], sources: [Int] = []
        for (i, r) in doc.rows.enumerated() where i != headerIndex && (headerIndex.map { i > $0 } ?? true) && !isBlank(r) {
            rows.append(r + Array(repeating: "", count: max(0, width - r.count)))
            sources.append(i)
        }
        return LoadedGrid(columns: columns, rows: rows, sourceRows: sources, columnPositions: Array(0..<width),
                          headerSource: hasHeader ? (headerIndex ?? 0) : nil, nextSourceRow: max(doc.rows.count, hasHeader ? 1 : 0),
                          nextColumnPosition: width, sheet: nil, sheets: [])
    }

    static func grid(from cells: [Int: [Int: String]], hasHeader: Bool) -> LoadedGrid {
        let rowNumbers = cells.keys.filter { !(cells[$0]?.isEmpty ?? true) }.sorted()
        guard !rowNumbers.isEmpty else {
            return LoadedGrid(columns: [], rows: [], sourceRows: [], columnPositions: [], headerSource: hasHeader ? 1 : nil,
                              nextSourceRow: hasHeader ? 2 : 1, nextColumnPosition: 1, sheet: nil, sheets: [])
        }
        var headerAt = 0
        if hasHeader {
            // Skip up to three title rows ("Q3 Sales") that have one filled cell above a wider header.
            while headerAt < min(3, rowNumbers.count - 1),
                  cells[rowNumbers[headerAt]]?.count == 1, (cells[rowNumbers[headerAt + 1]]?.count ?? 0) >= 2 {
                headerAt += 1
            }
        }
        let used = rowNumbers[headerAt...]
        let allCols = used.flatMap { cells[$0]?.keys.map { $0 } ?? [] }
        let minCol = allCols.min() ?? 1, maxCol = allCols.max() ?? 1
        let positions = Array(minCol...maxCol)
        func values(_ r: Int) -> [String] { positions.map { cells[r]?[$0] ?? "" } }
        let columns = hasHeader ? normalizeHeader(values(rowNumbers[headerAt])) : positions.indices.map { "Column \($0 + 1)" }
        let dataRows = hasHeader ? Array(used.dropFirst()) : Array(used)
        return LoadedGrid(columns: columns, rows: dataRows.map(values), sourceRows: dataRows, columnPositions: positions,
                          headerSource: hasHeader ? rowNumbers[headerAt] : nil, nextSourceRow: (rowNumbers.last ?? 0) + 1,
                          nextColumnPosition: maxCol + 1, sheet: nil, sheets: [])
    }

    // MARK: Writing whole files

    /// Writes `table` as a new file (replacing any existing one). `backup` keeps a `.bak` of a
    /// file that existed before `owner` touched it; the backup's path is returned when made.
    @discardableResult
    public static func write(_ rawPath: String, _ table: TableData, backup: Bool = false, owner: String? = nil) throws -> String? {
        let path = (rawPath as NSString).expandingTildeInPath
        let format = try SpreadsheetFormat.detect(path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            // Never let an atomic replace swap a whole folder for a file.
            throw SpreadsheetError.invalid("\((path as NSString).abbreviatingWithTildeInPath) is a folder, not a spreadsheet.")
        }
        let folder = (path as NSString).deletingLastPathComponent
        do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch {
            throw SpreadsheetError.toolFailed("Couldn't create the folder \((folder as NSString).abbreviatingWithTildeInPath): \(error.localizedDescription)")
        }
        return try FileLocks.withLock(DataPaths.realPath(path)) {
            let made = backup ? try FileProvenance.backupIfNeeded(path, owner: owner) : nil
            let width = max(table.columns.count, table.rows.map(\.count).max() ?? 0)
            func pad(_ r: [String]) -> [String] { r + Array(repeating: "", count: max(0, width - r.count)) }
            switch format {
            case .csv, .tsv:
                let rows = [pad(table.columns)] + table.rows.map { pad($0).map(neutralizeForCSV) }
                try CSVCodec.save(DelimitedDocument(rows: rows, delimiter: format == .tsv ? "\t" : ","), to: path)
            case .xlsx:
                try XLSXWriter.write(TableData(columns: pad(table.columns), rows: table.rows.map(pad), sheet: table.sheet), to: path)
            }
            return made
        }
    }

    /// Spreadsheet apps run CSV cells that start like a formula ("=HYPERLINK(…)", "+cmd|…").
    /// Values written by Glide often come from web pages, so formula-like text is prefixed with
    /// an apostrophe and stays text. Ordinary values ("-5", "+1 555 0100", "- note") are untouched.
    static func neutralizeForCSV(_ value: String) -> String {
        guard let first = value.unicodeScalars.first else { return value }
        switch first {
        case "=", "@": return "'" + value
        case "+", "-":
            let rest = value.unicodeScalars.dropFirst()
            if let second = rest.first, CharacterSet.letters.contains(second) { return "'" + value }
            if value.contains("|") || value.contains("!") { return "'" + value }
            return value
        case "\t", "\r": return "'" + value
        default: return value
        }
    }

    // MARK: In-place changes

    /// Updates cells in place. With `keyColumn`, each key matches rows whose key cell equals it
    /// (trimmed; case-insensitive when nothing matches exactly), and unknown keys become new
    /// rows. Without it, keys are row indexes into `read(...).rows` (0 = first data row) and
    /// indexes past the end become new rows. Missing columns are added to the header.
    @discardableResult
    public static func update(_ rawPath: String, sheet: String? = nil, keyColumn: String?, updates: [String: [String: String]],
                              owner: String? = nil, columnOrder: [String] = []) throws -> SpreadsheetChange {
        let ordered = updates.keys.sorted { a, b in
            if let x = Int(a), let y = Int(b) { return x < y }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { ($0, updates[$0] ?? [:]) }
        return try change(rawPath, sheet: sheet, keyColumn: keyColumn, ordered: ordered, appendOnly: false, owner: owner, columnOrder: columnOrder)
    }

    /// Appends rows (objects keyed by column name), creating the file when it doesn't exist.
    @discardableResult
    public static func append(_ rawPath: String, sheet: String? = nil, rows: [[String: String]], columnOrder: [String] = [],
                              owner: String? = nil) throws -> SpreadsheetChange {
        let path = (rawPath as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path) {
            _ = try SpreadsheetFormat.detect(path)
            var columns = columnOrder
            for r in rows { for k in r.keys.sorted() where !columns.contains(k) { columns.append(k) } }
            try write(path, TableData(columns: columns, rows: rows.map { r in columns.map { r[$0] ?? "" } }, sheet: sheet))
            FileProvenance.markCreated(DataPaths.realPath(path), owner: owner)
            var c = SpreadsheetChange()
            c.addedRows = rows.count
            c.addedColumns = columns
            c.updatedCells = rows.reduce(0) { $0 + $1.values.filter { !$0.isEmpty }.count }
            return c
        }
        return try change(path, sheet: sheet, keyColumn: nil, ordered: rows.enumerated().map { (String($0.offset), $0.element) },
                          appendOnly: true, owner: owner, columnOrder: columnOrder)
    }

    private static func change(_ rawPath: String, sheet: String?, keyColumn: String?, ordered: [(String, [String: String])],
                               appendOnly: Bool, owner: String?, columnOrder: [String]) throws -> SpreadsheetChange {
        let path = (rawPath as NSString).expandingTildeInPath
        let format = try SpreadsheetFormat.detect(path)
        try requireFile(path)
        return try FileLocks.withLock(DataPaths.realPath(path)) {
            switch format {
            case .csv, .tsv:
                var doc = try CSVCodec.load(path, tabSeparated: SpreadsheetFormat.tabHint(path))
                let g = grid(from: doc, hasHeader: true)
                var (edits, change) = try plan(g, keyColumn: keyColumn, ordered: ordered, appendOnly: appendOnly, columnOrder: columnOrder)
                guard !edits.isEmpty else { return change }
                let width = max(g.nextColumnPosition, (edits.map(\.col).max() ?? -1) + 1)
                let originalCount = doc.rows.count
                for e in edits {
                    while doc.rows.count <= e.row { doc.rows.append([]) }
                    let need = e.row >= originalCount || e.row == g.headerSource ? width : e.col + 1
                    if doc.rows[e.row].count < need { doc.rows[e.row] += Array(repeating: "", count: need - doc.rows[e.row].count) }
                    doc.rows[e.row][e.col] = e.row == g.headerSource ? e.value : neutralizeForCSV(e.value)
                }
                for i in originalCount..<doc.rows.count where doc.rows[i].count < width {
                    doc.rows[i] += Array(repeating: "", count: width - doc.rows[i].count)
                }
                change.backupPath = try FileProvenance.backupIfNeeded(path, owner: owner)
                try CSVCodec.save(doc, to: path)
                return change
            case .xlsx:
                return try changeXLSX(path, sheet: sheet, keyColumn: keyColumn, ordered: ordered, appendOnly: appendOnly, owner: owner, columnOrder: columnOrder)
            }
        }
    }

    private static func changeXLSX(_ path: String, sheet: String?, keyColumn: String?, ordered: [(String, [String: String])],
                                   appendOnly: Bool, owner: String?, columnOrder: [String]) throws -> SpreadsheetChange {
        let fm = FileManager.default
        let dir = try XLSXPackage.makeTempDir()
        defer { try? fm.removeItem(at: dir) }
        try XLSXPackage.checkReadable(path)
        let entries = try XLSXPackage.entries(path)
        try XLSXPackage.extract(path, to: dir, skipMedia: false)
        let wb = try XLSXWorkbook.load(root: dir)
        let s = try wb.sheet(named: sheet)
        guard let data = XLSXPackage.readPart(dir, s.part) else { throw SpreadsheetError.unreadable("The sheet “\(s.name)” is missing from the workbook.") }
        let g = grid(from: try XLSXSheetReader.read(data, part: s.part, workbook: wb), hasHeader: true)
        var (edits, change) = try plan(g, keyColumn: keyColumn, ordered: ordered, appendOnly: appendOnly, columnOrder: columnOrder)
        change.sheet = s.name
        guard !edits.isEmpty else { return change }

        let outcome = try XLSXSheetEditor.apply(data, edits: edits)
        try outcome.data.write(to: dir.appendingPathComponent(s.part))
        var removed: Set<String> = []
        if outcome.replacedFormula, let part = try XLSXWorkbookFixer.dropCalcChain(root: dir, workbook: wb) { removed.insert(part) }
        try XLSXWorkbookFixer.requestFullCalcOnLoad(root: dir, workbook: wb)

        // Re-zip the original entries in their original order.
        let keep = entries.filter { e in
            !removed.contains(e) && !e.hasPrefix("/") && !e.split(separator: "/").contains("..") && fm.fileExists(atPath: dir.appendingPathComponent(e).path)
        }
        let tmp = AtomicFile.siblingTemp(for: path, ext: "xlsx")
        do { try XLSXPackage.zip(dir: dir, entries: keep, to: tmp) } catch {
            try? fm.removeItem(atPath: tmp)
            throw error
        }
        do { change.backupPath = try FileProvenance.backupIfNeeded(path, owner: owner) } catch {
            try? fm.removeItem(atPath: tmp)
            throw error
        }
        try AtomicFile.replace(path, with: tmp)
        return change
    }

    /// Turns keyed updates into cell edits in file coordinates. Unchanged values are skipped,
    /// so re-running a write-back is a no-op and formulas whose result already matches survive.
    static func plan(_ g: LoadedGrid, keyColumn: String?, ordered: [(String, [String: String])], appendOnly: Bool,
                     columnOrder: [String]) throws -> ([CellEdit], SpreadsheetChange) {
        var change = SpreadsheetChange()
        var columns = g.columns
        var positions = g.columnPositions
        var edits: [CellEdit] = []
        var editIndex: [String: Int] = [:]
        let headerRow = g.headerSource ?? g.nextSourceRow

        func addEdit(_ row: Int, _ col: Int, _ value: String) {
            let k = "\(row):\(col)"
            if let i = editIndex[k] { edits[i].value = value } else { editIndex[k] = edits.count; edits.append(CellEdit(row: row, col: col, value: value)) }
        }
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func columnIndex(_ name: String) -> Int? {
            if let i = columns.firstIndex(of: name) { return i }
            let n = norm(name).lowercased()
            return columns.firstIndex { norm($0).lowercased() == n }
        }
        func ensureColumn(_ name: String) throws -> Int {
            if let i = columnIndex(name) { return i }
            let clean = norm(name)
            guard !clean.isEmpty else { throw SpreadsheetError.invalid("A column name is empty.") }
            let pos = g.nextColumnPosition + change.addedColumns.count
            columns.append(clean)
            positions.append(pos)
            change.addedColumns.append(clean)
            addEdit(headerRow, pos, clean)
            return columns.count - 1
        }
        func current(_ dataRow: Int?, _ colIdx: Int) -> String {
            guard let dataRow, colIdx < g.columns.count, dataRow < g.rows.count else { return "" }
            return g.rows[dataRow][colIdx]
        }

        var keyed = false
        var exact: [String: [Int]] = [:], loose: [String: [Int]] = [:]
        if let keyColumn, !appendOnly {
            var found = columnIndex(keyColumn)
            // An empty file gets the key column as its first header cell.
            if found == nil, g.columns.isEmpty { found = try ensureColumn(keyColumn) }
            guard let k = found else {
                throw SpreadsheetError.notFound("There's no column named “\(keyColumn)”. Columns: \(g.columns.joined(separator: ", ")).")
            }
            keyed = true
            for (i, r) in g.rows.enumerated() where k < r.count {
                exact[norm(r[k]), default: []].append(i)
                loose[norm(r[k]).lowercased(), default: []].append(i)
            }
        }

        let orderIndex = Dictionary(columnOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func sortedFields(_ f: [String: String]) -> [(String, String)] {
            f.sorted { a, b in
                let ia = columnIndex(a.key), ib = columnIndex(b.key)
                switch (ia, ib) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    let oa = orderIndex[a.key] ?? Int.max, ob = orderIndex[b.key] ?? Int.max
                    return oa != ob ? oa < ob : a.key < b.key
                }
            }
        }

        for (key, fields) in ordered {
            var targets: [(source: Int, data: Int?)] = []
            if !appendOnly {
                if keyed {
                    let k = norm(key)
                    let hits = exact[k] ?? loose[k.lowercased()] ?? []
                    targets = hits.map { (g.sourceRows[$0], $0) }
                } else {
                    guard let idx = Int(norm(key)), idx >= 0 else {
                        throw SpreadsheetError.invalid("Without a key column, update keys must be row numbers (0 = the first row under the header); “\(key)” isn't one.")
                    }
                    if idx < g.rows.count { targets = [(g.sourceRows[idx], idx)] }
                }
            }
            if targets.isEmpty {
                let src = g.nextSourceRow + change.addedRows
                change.addedRows += 1
                targets = [(src, nil)]
                if let keyColumn, !appendOnly {
                    let ci = try ensureColumn(keyColumn)
                    addEdit(src, positions[ci], norm(key))
                }
            }
            for (column, value) in sortedFields(fields) {
                let ci = try ensureColumn(column)
                for t in targets where current(t.data, ci) != value {
                    addEdit(t.source, positions[ci], value)
                    change.updatedCells += 1
                }
            }
        }
        return (edits, change)
    }
}
