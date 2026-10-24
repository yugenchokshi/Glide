import Foundation

// Excel .xlsx support without third-party code. An .xlsx file is a zip of XML parts; we use the
// system's /usr/bin/unzip and /usr/bin/zip for the container and XMLParser for reading. Edits
// are surgical: only the touched <row>/<c> elements of one worksheet are rewritten, byte for
// byte everything else (styles, other sheets, formulas, charts) is left exactly as it was.

// MARK: - Cell references

enum XLSXRef {
    static let maxRow = 1_048_576
    static let maxCol = 16_384

    /// "A" → 1, "Z" → 26, "AA" → 27.
    static func columnNumber<S: StringProtocol>(_ letters: S) -> Int? {
        var n = 0
        for u in letters.unicodeScalars {
            let v = Int(u.value)
            switch v {
            case 65...90: n = n * 26 + (v - 64)
            case 97...122: n = n * 26 + (v - 96)
            default: return nil
            }
            if n > maxCol { return nil }
        }
        return n == 0 ? nil : n
    }

    static func letters(_ col: Int) -> String {
        var n = col, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(UInt8(65 + r))) + s
            n = (n - 1) / 26
        }
        return s
    }

    /// "C5" → (row 5, col 3). Also accepts "$C$5".
    static func parse(_ ref: String) -> (row: Int, col: Int)? {
        let r = ref.replacingOccurrences(of: "$", with: "")
        guard let firstDigit = r.firstIndex(where: \.isNumber) else { return nil }
        guard let col = columnNumber(r[..<firstDigit]), let row = Int(r[firstDigit...]), (1...maxRow).contains(row) else { return nil }
        return (row, col)
    }

    /// Column-only refs ("C") are allowed in ranges like "C:C"; this handles the common "A1:D9".
    static func parseRange(_ ref: String) -> (r1: Int, c1: Int, r2: Int, c2: Int)? {
        let parts = ref.split(separator: ":").map(String.init)
        guard let firstPart = parts.first, let a = parse(firstPart) else { return nil }
        let b = parts.count > 1 ? parse(parts[1]) : a
        guard let b else { return nil }
        return (min(a.row, b.row), min(a.col, b.col), max(a.row, b.row), max(a.col, b.col))
    }

    static func string(row: Int, col: Int) -> String { letters(col) + String(row) }
}

// MARK: - Container

enum XLSXPackage {
    /// Uncompressed size above which a workbook is refused (protects against zip bombs).
    static let maxUncompressedBytes: Int64 = 1 << 30

    static func checkReadable(_ path: String) throws {
        let name = (path as NSString).lastPathComponent
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw SpreadsheetError.unreadable("Couldn't open “\(name)”.")
        }
        defer { try? handle.close() }
        let magic = [UInt8]((try? handle.read(upToCount: 8)) ?? Data())
        if magic.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) {
            throw SpreadsheetError.unreadable("“\(name)” is password-protected or in the old .xls format. Open it in Excel or Numbers and save it as an unprotected .xlsx (or CSV) first.")
        }
        guard magic.starts(with: [0x50, 0x4B]) else {
            throw SpreadsheetError.unreadable("“\(name)” isn't a valid .xlsx workbook (it may be damaged or a different format with an .xlsx name).")
        }
        let info = try Subprocess.run("/usr/bin/unzip", ["-Zt", path], timeout: 30)
        guard info.status == 0 else {
            throw SpreadsheetError.unreadable("“\(name)” isn't a valid .xlsx workbook (the zip container is damaged).")
        }
        // "5 files, 12345 bytes uncompressed, 6789 bytes compressed:  45.0%"
        let line = String(decoding: info.stdout, as: UTF8.self)
        if let r = line.range(of: #"([0-9]+) bytes uncompressed"#, options: .regularExpression) {
            let digits = line[r].prefix { $0.isNumber }
            if let total = Int64(digits), total > maxUncompressedBytes {
                throw SpreadsheetError.tooLarge("“\(name)” expands to more than 1 GB, too big to process safely.")
            }
        }
    }

    /// Entry names in archive order.
    static func entries(_ path: String) throws -> [String] {
        let r = try Subprocess.run("/usr/bin/unzip", ["-Z1", path], timeout: 30)
        guard r.status == 0 else { throw SpreadsheetError.unreadable("Couldn't list the parts of “\((path as NSString).lastPathComponent)”.") }
        return String(decoding: r.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Extracts the workbook into `dir`. Info-ZIP strips absolute paths and "../" components;
    /// we additionally refuse archives that contain symlinks, so nothing we later read or
    /// write can point outside the folder.
    static func extract(_ path: String, to dir: URL, skipMedia: Bool) throws {
        var args = ["-qq", "-o", path]
        if skipMedia { args += ["-x", "xl/media/*", "xl/embeddings/*", "xl/printerSettings/*"] }
        args += ["-d", dir.path]
        let r = try Subprocess.run("/usr/bin/unzip", args, timeout: 120)
        guard r.status == 0 || r.status == 1 || r.status == 11 else {
            throw SpreadsheetError.unreadable("Couldn't unpack “\((path as NSString).lastPathComponent)”: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
        }
        try rejectLinks(in: dir)
    }

    static func rejectLinks(in dir: URL) throws {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return }
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: Set(keys)))?.isSymbolicLink == true {
                throw SpreadsheetError.unreadable("This workbook contains file links, which Glide refuses to open for safety.")
            }
        }
    }

    /// Zips `entries` (in that order) from `dir` into `out`. `-nw` keeps names like
    /// "[Content_Types].xml" from being read as wildcards; `-X` drops extra file attributes.
    static func zip(dir: URL, entries: [String], to out: String) throws {
        let list = entries.joined(separator: "\n") + "\n"
        let r = try Subprocess.run("/usr/bin/zip", ["-X", "-q", "-nw", out, "-@"], cwd: dir, stdin: Data(list.utf8), timeout: 120)
        guard r.status == 0 else {
            throw SpreadsheetError.toolFailed("Couldn't build the .xlsx file: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
        }
    }

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Reads a part, refusing anything that isn't a regular file inside `root`.
    static func readPart(_ root: URL, _ part: String) -> Data? {
        let url = root.appendingPathComponent(part)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        return try? Data(contentsOf: url)
    }
}

// MARK: - XML event parsing

/// Thin closure-based wrapper over XMLParser. Element and attribute names arrive without
/// namespace prefixes, so "x:row" and "row" read the same.
final class XMLEvents: NSObject, XMLParserDelegate {
    var onStart: (String, [String: String]) -> Void = { _, _ in }
    var onEnd: (String) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }

    static func localName(_ qName: String) -> String {
        if let i = qName.lastIndex(of: ":") { return String(qName[qName.index(after: i)...]) }
        return qName
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attrs: [String: String] = [:]
        // Namespace declarations ("xmlns:r") would otherwise shadow real attributes ("r").
        for (k, v) in attributeDict where k != "xmlns" && !k.hasPrefix("xmlns:") { attrs[Self.localName(k)] = v }
        onStart(Self.localName(elementName), attrs)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        onEnd(Self.localName(elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { onText(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { onText(String(decoding: CDATABlock, as: UTF8.self)) }

    func run(_ data: Data, part: String) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        if !parser.parse() {
            let reason = parser.parserError?.localizedDescription ?? "unknown error"
            throw SpreadsheetError.unreadable("The workbook part \(part) couldn't be read (\(reason)). The file may be damaged.")
        }
    }
}

// MARK: - Workbook structure

enum XLSXDateKind: Sendable { case date, time, dateTime }

struct XLSXWorkbook {
    struct Sheet {
        var name: String
        /// Package-relative part path, e.g. "xl/worksheets/sheet1.xml".
        var part: String
        var hidden: Bool
    }

    struct Relationship {
        var id: String
        var type: String
        var target: String
        var external: Bool
    }

    var workbookPart: String
    var sheets: [Sheet]
    var date1904: Bool
    var sharedStrings: [String]
    /// cellXfs index → date kind, for cells whose number format is a date or time.
    var dateStyles: [Int: XLSXDateKind]
    var relationships: [Relationship]

    var relsPart: String { Self.relsPath(for: workbookPart) }

    static func relsPath(for part: String) -> String {
        let dir = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        return (dir.isEmpty ? "" : dir + "/") + "_rels/" + file + ".rels"
    }

    /// Resolves a relationship target relative to the part that owns it.
    static func resolve(_ target: String, from part: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var comps = (part as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for c in target.split(separator: "/") {
            if c == ".." { if !comps.isEmpty { comps.removeLast() } } else if c != "." { comps.append(String(c)) }
        }
        return comps.joined(separator: "/")
    }

    static func parseRels(_ data: Data?, part: String) throws -> [Relationship] {
        guard let data else { return [] }
        var rels: [Relationship] = []
        let p = XMLEvents()
        p.onStart = { name, a in
            guard name == "Relationship", let id = a["Id"], let target = a["Target"] else { return }
            rels.append(Relationship(id: id, type: a["Type"] ?? "", target: target, external: a["TargetMode"] == "External"))
        }
        try p.run(data, part: part)
        return rels
    }

    static func load(root: URL) throws -> XLSXWorkbook {
        let rootRels = try parseRels(XLSXPackage.readPart(root, "_rels/.rels"), part: "_rels/.rels")
        let workbookPart = rootRels.first { $0.type.hasSuffix("/officeDocument") }.map { resolve($0.target, from: "") } ?? "xl/workbook.xml"
        guard let wbData = XLSXPackage.readPart(root, workbookPart) else {
            throw SpreadsheetError.unreadable("This file has no workbook inside, so it isn't a valid .xlsx.")
        }
        var rawSheets: [(name: String, rid: String, hidden: Bool)] = []
        var date1904 = false
        let wp = XMLEvents()
        wp.onStart = { name, a in
            if name == "sheet", let n = a["name"], let rid = a["id"] {
                rawSheets.append((n, rid, a["state"] == "hidden" || a["state"] == "veryHidden"))
            } else if name == "workbookPr", let v = a["date1904"] {
                date1904 = v == "1" || v.lowercased() == "true"
            }
        }
        try wp.run(wbData, part: workbookPart)

        let relsPart = relsPath(for: workbookPart)
        let rels = try parseRels(XLSXPackage.readPart(root, relsPart), part: relsPart)
        var sheets: [Sheet] = []
        for s in rawSheets {
            guard let rel = rels.first(where: { $0.id == s.rid }), !rel.external, rel.type.hasSuffix("/worksheet") else { continue }
            sheets.append(Sheet(name: s.name, part: resolve(rel.target, from: workbookPart), hidden: s.hidden))
        }

        var shared: [String] = []
        if let rel = rels.first(where: { $0.type.hasSuffix("/sharedStrings") }) {
            let part = resolve(rel.target, from: workbookPart)
            if let data = XLSXPackage.readPart(root, part) { shared = try parseSharedStrings(data, part: part) }
        }
        var dateStyles: [Int: XLSXDateKind] = [:]
        if let rel = rels.first(where: { $0.type.hasSuffix("/styles") }) {
            let part = resolve(rel.target, from: workbookPart)
            if let data = XLSXPackage.readPart(root, part) { dateStyles = try parseDateStyles(data, part: part) }
        }
        return XLSXWorkbook(workbookPart: workbookPart, sheets: sheets, date1904: date1904, sharedStrings: shared, dateStyles: dateStyles, relationships: rels)
    }

    /// Plain and rich-text shared strings; phonetic runs (<rPh>) are skipped.
    static func parseSharedStrings(_ data: Data, part: String) throws -> [String] {
        var out: [String] = []
        var current = "", inSI = false, inT = false, phoneticDepth = 0
        let p = XMLEvents()
        p.onStart = { name, _ in
            switch name {
            case "si": inSI = true; current = ""
            case "t": inT = phoneticDepth == 0
            case "rPh": phoneticDepth += 1
            default: break
            }
        }
        p.onEnd = { name in
            switch name {
            case "si": out.append(current); inSI = false
            case "t": inT = false
            case "rPh": phoneticDepth = max(0, phoneticDepth - 1)
            default: break
            }
        }
        p.onText = { s in if inSI && inT { current += s } }
        try p.run(data, part: part)
        return out
    }

    /// Built-in number formats that show dates or times.
    static let builtinDateFormats: [Int: XLSXDateKind] = {
        var m: [Int: XLSXDateKind] = [:]
        for id in [14, 15, 16, 17] { m[id] = .date }
        for id in [18, 19, 20, 21, 45, 47] { m[id] = .time }
        m[22] = .dateTime
        for id in Array(27...36) + Array(50...58) { m[id] = .date }
        return m
    }()

    static func parseDateStyles(_ data: Data, part: String) throws -> [Int: XLSXDateKind] {
        var custom: [Int: String] = [:]
        var xfFormats: [Int] = []
        var inCellXfs = false
        let p = XMLEvents()
        p.onStart = { name, a in
            if name == "numFmt", let id = a["numFmtId"].flatMap({ Int($0) }), let code = a["formatCode"] { custom[id] = code }
            else if name == "cellXfs" { inCellXfs = true }
            else if name == "xf", inCellXfs { xfFormats.append(a["numFmtId"].flatMap { Int($0) } ?? 0) }
        }
        p.onEnd = { name in if name == "cellXfs" { inCellXfs = false } }
        try p.run(data, part: part)
        var out: [Int: XLSXDateKind] = [:]
        for (i, fmt) in xfFormats.enumerated() {
            if let code = custom[fmt] {
                if let k = dateKind(formatCode: code) { out[i] = k }
            } else if let k = builtinDateFormats[fmt] {
                out[i] = k
            }
        }
        return out
    }

    /// Classifies a custom number format: date/time tokens outside quotes, escapes and
    /// [colour]/[$-locale] brackets. Elapsed-time formats ([h]:mm) stay numbers.
    static func dateKind(formatCode: String) -> XLSXDateKind? {
        if formatCode.range(of: #"\[(h+|m+|s+)\]"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        var cleaned = ""
        var inQuote = false, inBracket = false, skipNext = false
        for ch in formatCode {
            if skipNext { skipNext = false; continue }
            if inQuote { if ch == "\"" { inQuote = false }; continue }
            if inBracket { if ch == "]" { inBracket = false }; continue }
            switch ch {
            case "\"": inQuote = true
            case "[": inBracket = true
            case "\\", "_", "*": skipNext = true
            default: cleaned.append(ch)
            }
        }
        let c = cleaned.lowercased()
        if c.contains("general") && !c.contains("y") && !c.contains("d") { return nil }
        // Only the first section (positive numbers) matters.
        let first = c.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? c
        let hasY = first.contains("y"), hasD = first.contains("d"), hasH = first.contains("h"), hasS = first.contains("s")
        let hasM = first.contains("m")
        let hasDate = hasY || hasD || (hasM && !hasH && !hasS)
        let hasTime = hasH || hasS
        switch (hasDate, hasTime) {
        case (true, true): return .dateTime
        case (true, false): return .date
        case (false, true): return .time
        default: return nil
        }
    }

    func sheet(named name: String?) throws -> Sheet {
        guard !sheets.isEmpty else { throw SpreadsheetError.unreadable("This workbook has no worksheets.") }
        guard let name, !name.isEmpty else { return sheets.first { !$0.hidden } ?? sheets[0] }
        if let s = sheets.first(where: { $0.name == name }) { return s }
        if let s = sheets.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { return s }
        if let n = Int(name), (1...sheets.count).contains(n) { return sheets[n - 1] }
        throw SpreadsheetError.notFound("There's no sheet named “\(name)”. Sheets: \(sheets.map(\.name).joined(separator: ", ")).")
    }
}

// MARK: - Sheet reading

enum XLSXSheetReader {
    /// Cell text by sheet row then column (both 1-based). Empty cells are absent.
    static func read(_ data: Data, part: String, workbook: XLSXWorkbook) throws -> [Int: [Int: String]] {
        var cells: [Int: [Int: String]] = [:]
        var rowNumber = 0, colNumber = 0
        var cellType = "n", cellStyle: Int? = nil
        var inCell = false, inValue = false, inInline = false, inInlineText = false, phoneticDepth = 0
        var value = "", inlineText = ""
        var hasValue = false
        let p = XMLEvents()
        p.onStart = { name, a in
            switch name {
            case "row":
                rowNumber = a["r"].flatMap { Int($0) } ?? (rowNumber + 1)
                colNumber = 0
            case "c":
                inCell = true
                // The row element decides the row (the editor does the same, so positions agree).
                if let ref = a["r"].flatMap({ XLSXRef.parse($0) }) { colNumber = ref.col } else { colNumber += 1 }
                cellType = a["t"] ?? "n"
                cellStyle = a["s"].flatMap { Int($0) }
                value = ""; inlineText = ""; hasValue = false
            case "v": if inCell { inValue = true; hasValue = true }
            case "is": if inCell { inInline = true; hasValue = true }
            case "t": if inInline { inInlineText = phoneticDepth == 0 }
            case "rPh": phoneticDepth += 1
            default: break
            }
        }
        p.onEnd = { name in
            switch name {
            case "v": inValue = false
            case "t": inInlineText = false
            case "rPh": phoneticDepth = max(0, phoneticDepth - 1)
            case "is": inInline = false
            case "c":
                inCell = false
                guard hasValue, rowNumber > 0, colNumber > 0 else { return }
                let text = cellText(type: cellType, style: cellStyle, value: value, inline: inlineText, workbook: workbook)
                if !text.isEmpty { cells[rowNumber, default: [:]][colNumber] = text }
            default: break
            }
        }
        p.onText = { s in
            if inValue { value += s } else if inInlineText { inlineText += s }
        }
        try p.run(data, part: part)
        return cells
    }

    static func cellText(type: String, style: Int?, value: String, inline: String, workbook: XLSXWorkbook) -> String {
        switch type {
        case "s":
            guard let i = Int(value.trimmingCharacters(in: .whitespaces)), workbook.sharedStrings.indices.contains(i) else { return "" }
            return workbook.sharedStrings[i]
        case "inlineStr": return inline
        case "str", "e", "d": return value
        case "b": return value.trimmingCharacters(in: .whitespaces) == "1" ? "TRUE" : "FALSE"
        default:
            if let style, let kind = workbook.dateStyles[style], let d = Double(value.trimmingCharacters(in: .whitespaces)),
               let s = formatDate(serial: d, kind: kind, date1904: workbook.date1904) {
                return s
            }
            return formatNumber(value)
        }
    }

    /// Integers without ".0"; other numbers at 15 significant digits, which removes binary
    /// noise like 0.30000000000000004 the same way Excel's display does.
    static func formatNumber(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let d = Double(s), d.isFinite else { return s }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(format: "%.15g", d)
    }

    /// Excel serial date → ISO 8601 (UTC calendar math, so time zones never shift the day).
    static func formatDate(serial: Double, kind: XLSXDateKind, date1904: Bool) -> String? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
        var days = Int(serial.rounded(.down))
        var seconds = Int(((serial - Double(days)) * 86_400).rounded())
        if seconds >= 86_400 { days += 1; seconds -= 86_400 }
        let base: DateComponents
        if date1904 {
            base = DateComponents(year: 1904, month: 1, day: 1)
        } else if days < 60 {
            // Serial 1 is 1900-01-01; Excel's fictional 1900-02-29 (serial 60) only shifts later dates.
            base = DateComponents(year: 1899, month: 12, day: 31)
        } else {
            base = DateComponents(year: 1899, month: 12, day: 30)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let start = cal.date(from: base), let date = cal.date(byAdding: .day, value: days, to: start) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        let datePart = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let timePart = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        switch kind {
        case .date: return seconds == 0 ? datePart : datePart + "T" + timePart
        case .time: return days == 0 ? timePart : datePart + "T" + timePart
        case .dateTime: return datePart + "T" + timePart
        }
    }
}

// MARK: - XML text helpers

enum XMLText {
    /// Escapes element text and drops characters XML 1.0 can't hold.
    static func escape(_ s: String, attribute: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\r": continue
            case "\n" where attribute: out += "&#10;"
            case "\t", "\n": out.unicodeScalars.append(u)
            default:
                let v = u.value
                if v < 0x20 || v == 0xFFFE || v == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// Values written as numbers: plain decimals only. "007", "+1 555…", 16-digit ids and
    /// "1e5" stay text so nothing is silently mangled.
    static func isPlainNumber(_ s: String) -> Bool {
        s.range(of: #"^-?(0|[1-9][0-9]{0,14})(\.[0-9]{1,15})?$"#, options: .regularExpression) != nil
    }
}

// MARK: - Sheet editing

/// A change to one cell, in sheet coordinates (1-based).
struct CellEdit: Hashable, Sendable {
    var row: Int
    var col: Int
    var value: String
}

/// Rewrites only the rows a set of edits touches inside one worksheet's XML.
struct XLSXSheetEditor {
    /// Excel's per-cell text limit.
    static let maxCellChars = 32_767

    struct Outcome {
        var data: Data
        /// A formula cell was overwritten with a value (the calc chain must be dropped).
        var replacedFormula: Bool
    }

    private struct Attr { var name: String; var raw: String; var quote: UInt8 }

    private enum RowItem {
        case cell(col: Int, raw: [UInt8], hasRef: Bool)
        case other([UInt8])
    }

    private struct Row {
        var number: Int
        var hasNumber: Bool
        var openTag: [UInt8]
        var selfClosing: Bool
        var items: [RowItem]
        /// Original bytes, emitted unchanged when the row isn't touched.
        var raw: [UInt8]
        var modified = false
    }

    private enum Chunk {
        case row(Row)
        case raw([UInt8])
    }

    private let b: [UInt8]
    private var prefix: [UInt8] = []

    init(_ data: Data) { b = [UInt8](data) }

    static func apply(_ data: Data, edits: [CellEdit]) throws -> Outcome {
        var editor = XLSXSheetEditor(data)
        return try editor.run(edits)
    }

    // MARK: Byte scanning

    private func matches(_ at: Int, _ pattern: [UInt8]) -> Bool {
        guard at >= 0, at + pattern.count <= b.count else { return false }
        for i in 0..<pattern.count where b[at + i] != pattern[i] { return false }
        return true
    }

    private func find(_ pattern: [UInt8], from: Int, to: Int? = nil) -> Int? {
        let end = (to ?? b.count) - pattern.count
        guard !pattern.isEmpty, from <= end else { return nil }
        var i = from
        let first = pattern[0]
        while i <= end {
            if b[i] == first && matches(i, pattern) { return i }
            i += 1
        }
        return nil
    }

    private static func isNameEnd(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x3E || c == 0x2F }

    /// True if an element named `name` (with the sheet's prefix) starts at `at`.
    private func startsElement(_ at: Int, _ name: String) -> Bool {
        let pat = [UInt8(ascii: "<")] + prefix + Array(name.utf8)
        return matches(at, pat) && at + pat.count < b.count && Self.isNameEnd(b[at + pat.count])
    }

    private func closeTag(_ name: String) -> [UInt8] { Array("</".utf8) + prefix + Array(name.utf8) + [UInt8(ascii: ">")] }

    /// Index of the ">" ending the tag that starts at `start`, honoring quoted attribute values.
    private func tagEnd(_ start: Int) throws -> Int {
        var i = start + 1
        var quote: UInt8 = 0
        while i < b.count {
            let c = b[i]
            if quote != 0 { if c == quote { quote = 0 } }
            else if c == 0x22 || c == 0x27 { quote = c }
            else if c == 0x3E { return i }
            i += 1
        }
        throw SpreadsheetError.unreadable("The worksheet XML is damaged (an unterminated tag).")
    }

    private static func attributes(_ tag: ArraySlice<UInt8>) -> [Attr] {
        var out: [Attr] = []
        let t = Array(tag)
        var i = 1
        while i < t.count, !isNameEnd(t[i]) { i += 1 } // skip "<name"
        while i < t.count {
            while i < t.count, t[i] == 0x20 || t[i] == 0x09 || t[i] == 0x0A || t[i] == 0x0D { i += 1 }
            guard i < t.count, t[i] != 0x3E, t[i] != 0x2F else { break }
            let ns = i
            while i < t.count, t[i] != 0x3D, !isNameEnd(t[i]) { i += 1 }
            let name = String(decoding: t[ns..<i], as: UTF8.self)
            while i < t.count, t[i] == 0x20 || t[i] == 0x09 || t[i] == 0x0A || t[i] == 0x0D { i += 1 }
            guard i < t.count, t[i] == 0x3D else { continue }
            i += 1
            while i < t.count, t[i] == 0x20 || t[i] == 0x09 || t[i] == 0x0A || t[i] == 0x0D { i += 1 }
            guard i < t.count, t[i] == 0x22 || t[i] == 0x27 else { break }
            let q = t[i]
            i += 1
            let vs = i
            while i < t.count, t[i] != q { i += 1 }
            out.append(Attr(name: name, raw: String(decoding: t[vs..<min(i, t.count)], as: UTF8.self), quote: q))
            i += 1
        }
        return out
    }

    /// End index (exclusive) of an arbitrary element or comment starting at `at`.
    private func elementEnd(_ at: Int) throws -> Int {
        if matches(at, Array("<!--".utf8)) {
            guard let e = find(Array("-->".utf8), from: at + 4) else { throw SpreadsheetError.unreadable("The worksheet XML is damaged (an unterminated comment).") }
            return e + 3
        }
        let te = try tagEnd(at)
        if b[te - 1] == 0x2F || b[at + 1] == 0x3F || b[at + 1] == 0x21 { return te + 1 }
        var n = at + 1
        while n < te, !Self.isNameEnd(b[n]) { n += 1 }
        let name = Array(b[(at + 1)..<n])
        let close = Array("</".utf8) + name + [UInt8(ascii: ">")]
        // Same-name nesting is rare here (extLst); count it anyway.
        var depth = 1, i = te + 1
        let open = [UInt8(ascii: "<")] + name
        while i < b.count {
            if matches(i, close) { depth -= 1; if depth == 0 { return i + close.count }; i += close.count; continue }
            if matches(i, open), i + open.count < b.count, Self.isNameEnd(b[i + open.count]) {
                let e = try tagEnd(i)
                if b[e - 1] != 0x2F { depth += 1 }
                i = e + 1
                continue
            }
            i += 1
        }
        throw SpreadsheetError.unreadable("The worksheet XML is damaged (an unclosed element).")
    }

    // MARK: Parsing sheetData

    /// Finds `<[prefix:]sheetData …>` and returns (tag start, tag end).
    private mutating func locateSheetData() throws -> (start: Int, end: Int) {
        let name = Array("sheetData".utf8)
        var from = 0
        while let k = find(name, from: from) {
            from = k + 1
            guard k + name.count < b.count, Self.isNameEnd(b[k + name.count]) else { continue }
            if k > 0, b[k - 1] == 0x3C { prefix = []; return (k - 1, try tagEnd(k - 1)) }
            if k > 0, b[k - 1] == 0x3A {
                var j = k - 2
                while j >= 0, b[j] != 0x3C, b[j] != 0x2F, !Self.isNameEnd(b[j]) { j -= 1 }
                if j >= 0, b[j] == 0x3C { prefix = Array(b[(j + 1)..<k]); return (j, try tagEnd(j)) }
            }
        }
        throw SpreadsheetError.unreadable("The worksheet has no cell data section; the file may be damaged.")
    }

    private func parseRows(from start: Int, to end: Int) throws -> [Chunk] {
        var chunks: [Chunk] = []
        var pos = start
        var lastRow = 0
        while pos < end {
            if b[pos] == 0x3C && startsElement(pos, "row") {
                let te = try tagEnd(pos)
                let open = Array(b[pos...te])
                let attrs = Self.attributes(b[pos...te])
                let explicit = attrs.first { $0.name == "r" }.flatMap { Int($0.raw) }
                let number = explicit ?? (lastRow + 1)
                guard (1...XLSXRef.maxRow).contains(number) else { throw SpreadsheetError.unreadable("The worksheet has an invalid row number.") }
                lastRow = number
                if b[te - 1] == 0x2F {
                    chunks.append(.row(Row(number: number, hasNumber: explicit != nil, openTag: open, selfClosing: true, items: [], raw: open)))
                    pos = te + 1
                    continue
                }
                var items: [RowItem] = []
                var q = te + 1
                var lastCol = 0
                let close = closeTag("row")
                while true {
                    guard q < end else { throw SpreadsheetError.unreadable("The worksheet XML is damaged (an unclosed row).") }
                    if matches(q, close) { q += close.count; break }
                    if b[q] == 0x3C && startsElement(q, "c") {
                        let ce = try tagEnd(q)
                        var cellEnd: Int
                        if b[ce - 1] == 0x2F { cellEnd = ce + 1 } else {
                            let cclose = closeTag("c")
                            guard let ci = find(cclose, from: ce + 1, to: end) else { throw SpreadsheetError.unreadable("The worksheet XML is damaged (an unclosed cell).") }
                            cellEnd = ci + cclose.count
                        }
                        let cattrs = Self.attributes(b[q...ce])
                        let ref = cattrs.first { $0.name == "r" }.flatMap { XLSXRef.parse($0.raw) }
                        let col = ref?.col ?? (lastCol + 1)
                        guard col <= XLSXRef.maxCol else { throw SpreadsheetError.unreadable("The worksheet has an invalid cell reference.") }
                        lastCol = col
                        items.append(.cell(col: col, raw: Array(b[q..<cellEnd]), hasRef: ref != nil))
                        q = cellEnd
                    } else if b[q] == 0x3C {
                        let e = try elementEnd(q)
                        items.append(.other(Array(b[q..<e])))
                        q = e
                    } else {
                        var e = q
                        while e < end, b[e] != 0x3C { e += 1 }
                        items.append(.other(Array(b[q..<e])))
                        q = e
                    }
                }
                chunks.append(.row(Row(number: number, hasNumber: explicit != nil, openTag: open, selfClosing: false, items: items, raw: Array(b[pos..<q]))))
                pos = q
            } else if b[pos] == 0x3C {
                let e = try elementEnd(pos)
                chunks.append(.raw(Array(b[pos..<e])))
                pos = e
            } else {
                var e = pos
                while e < end, b[e] != 0x3C { e += 1 }
                chunks.append(.raw(Array(b[pos..<e])))
                pos = e
            }
        }
        return chunks
    }

    // MARK: Building

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func rebuildOpen(_ tag: [UInt8], name: String, ensure: [(String, String)], drop: Set<String>, selfClosing: Bool) -> [UInt8] {
        var attrs = Self.attributes(tag[...])
        for (n, v) in ensure {
            if let i = attrs.firstIndex(where: { $0.name == n }) { attrs[i].raw = v } else { attrs.insert(Attr(name: n, raw: v, quote: 0x22), at: 0) }
        }
        var out = [UInt8(ascii: "<")] + prefix + bytes(name)
        for a in attrs where !drop.contains(a.name) {
            out += [0x20] + bytes(a.name) + [0x3D, a.quote] + bytes(a.raw) + [a.quote]
        }
        out += selfClosing ? bytes("/>") : bytes(">")
        return out
    }

    private func cellXML(ref: String, style: String?, value: String) -> [UInt8]? {
        let p = String(decoding: prefix, as: UTF8.self)
        let s = style.map { " s=\"\($0)\"" } ?? ""
        if value.isEmpty { return style == nil ? nil : bytes("<\(p)c r=\"\(ref)\"\(s)/>") }
        if XMLText.isPlainNumber(value) {
            return bytes("<\(p)c r=\"\(ref)\"\(s)><\(p)v>\(value)</\(p)v></\(p)c>")
        }
        var text = value.replacingOccurrences(of: "\r\n", with: "\n")
        if text.count > Self.maxCellChars { text = String(text.prefix(Self.maxCellChars)) }
        let preserve = (text.first?.isWhitespace ?? false) || (text.last?.isWhitespace ?? false) ? " xml:space=\"preserve\"" : ""
        return bytes("<\(p)c r=\"\(ref)\"\(s) t=\"inlineStr\"><\(p)is><\(p)t\(preserve)>\(XMLText.escape(text))</\(p)t></\(p)is></\(p)c>")
    }

    /// Formula details of an existing cell: (has formula, array range, is shared-formula master).
    private func formulaInfo(_ raw: [UInt8]) -> (has: Bool, arrayRange: String?, sharedMaster: Bool) {
        let pat = [UInt8(ascii: "<")] + prefix + bytes("f")
        var i = 0
        while i + pat.count < raw.count {
            if raw[i] == 0x3C, Array(raw[i..<(i + pat.count)]) == pat, Self.isNameEnd(raw[i + pat.count]) {
                var e = i
                while e < raw.count, raw[e] != 0x3E { e += 1 }
                let attrs = Self.attributes(raw[i..<min(e + 1, raw.count)])
                let t = attrs.first { $0.name == "t" }?.raw
                let ref = attrs.first { $0.name == "ref" }?.raw
                return (true, t == "array" ? ref : nil, t == "shared" && ref != nil)
            }
            i += 1
        }
        return (false, nil, false)
    }

    // MARK: Run

    private mutating func run(_ edits: [CellEdit]) throws -> Outcome {
        let sd = try locateSheetData()
        let selfClosingData = b[sd.end - 1] == 0x2F
        let innerStart = sd.end + 1
        var innerEnd = innerStart
        var afterData = sd.end + 1
        if !selfClosingData {
            guard let ce = find(closeTag("sheetData"), from: innerStart) else { throw SpreadsheetError.unreadable("The worksheet XML is damaged (no end of cell data).") }
            innerEnd = ce
            afterData = ce + closeTag("sheetData").count
        }
        var chunks = selfClosingData ? [] : try parseRows(from: innerStart, to: innerEnd)

        // Ranges no single cell may be written into.
        var arrayRanges: [(Int, Int, Int, Int)] = []
        var sharedMasters: Set<String> = []
        for case .row(let r) in chunks {
            for case .cell(let col, let raw, _) in r.items {
                let info = formulaInfo(raw)
                if let ar = info.arrayRange, let rg = XLSXRef.parseRange(ar) { arrayRanges.append((rg.r1, rg.c1, rg.r2, rg.c2)) }
                if info.sharedMaster { sharedMasters.insert(XLSXRef.string(row: r.number, col: col)) }
            }
        }
        for e in edits {
            let ref = XLSXRef.string(row: e.row, col: e.col)
            if arrayRanges.contains(where: { e.row >= $0.0 && e.row <= $0.2 && e.col >= $0.1 && e.col <= $0.3 }) {
                throw SpreadsheetError.protectedCell("Cell \(ref) is part of an array formula, so Glide won't overwrite it. Choose another column or clear the formula first.")
            }
            if sharedMasters.contains(ref) {
                throw SpreadsheetError.protectedCell("Cell \(ref) holds a formula that other cells copy, so Glide won't overwrite it. Choose another column or clear the formula first.")
            }
        }

        var rowIndex: [Int: Int] = [:]
        for (i, c) in chunks.enumerated() { if case .row(let r) = c { rowIndex[r.number] = i } }
        let needsExplicitRows = chunks.contains { if case .row(let r) = $0 { return !r.hasNumber } else { return false } }

        var replacedFormula = false
        var newRows: [Int: Row] = [:]
        let byRow = Dictionary(grouping: edits, by: \.row)
        for rowNumber in byRow.keys.sorted() {
            var row: Row
            if let i = rowIndex[rowNumber], case .row(let existing) = chunks[i] { row = existing } else {
                let open = bytes("<\(String(decoding: prefix, as: UTF8.self))row r=\"\(rowNumber)\">")
                row = Row(number: rowNumber, hasNumber: true, openTag: open, selfClosing: false, items: [], raw: [])
            }
            for e in (byRow[rowNumber] ?? []).sorted(by: { $0.col < $1.col }) {
                let ref = XLSXRef.string(row: e.row, col: e.col)
                if let idx = row.items.firstIndex(where: { if case .cell(let c, _, _) = $0 { return c == e.col }; return false }),
                   case .cell(_, let raw, _) = row.items[idx] {
                    let te = raw.firstIndex(of: 0x3E) ?? (raw.count - 1)
                    let style = Self.attributes(raw[0...te]).first { $0.name == "s" }?.raw
                    if formulaInfo(raw).has { replacedFormula = true }
                    if let x = cellXML(ref: ref, style: style, value: e.value) {
                        row.items[idx] = .cell(col: e.col, raw: x, hasRef: true)
                    } else {
                        row.items.remove(at: idx)
                    }
                } else if let x = cellXML(ref: ref, style: nil, value: e.value) {
                    let insertAt = row.items.firstIndex { if case .cell(let c, _, _) = $0 { return c > e.col }; return false }
                        ?? (row.items.lastIndex { if case .cell = $0 { return true }; return false }.map { $0 + 1 } ?? row.items.startIndex)
                    row.items.insert(.cell(col: e.col, raw: x, hasRef: true), at: insertAt)
                }
            }
            row.modified = true
            if let i = rowIndex[rowNumber] { chunks[i] = .row(row) } else { newRows[rowNumber] = row }
        }

        // Insert new rows in sorted position.
        if !newRows.isEmpty {
            var merged: [Chunk] = []
            var pending = newRows.keys.sorted()
            for c in chunks {
                if case .row(let r) = c {
                    while let n = pending.first, n < r.number { merged.append(.row(newRows[n]!)); pending.removeFirst() }
                }
                merged.append(c)
            }
            // After the last row, but before any trailing non-row content.
            let lastRowPos = merged.lastIndex { if case .row = $0 { return true }; return false }.map { $0 + 1 } ?? merged.endIndex
            merged.insert(contentsOf: pending.map { Chunk.row(newRows[$0]!) }, at: lastRowPos)
            chunks = merged
        }

        // Serialize sheetData.
        var inner: [UInt8] = []
        for c in chunks {
            switch c {
            case .raw(let r): inner += r
            case .row(let r):
                let mustNumber = needsExplicitRows && !r.hasNumber
                if !r.modified && !mustNumber { inner += r.raw; continue }
                if !r.modified {
                    // Only the row number changes; the content stays byte-identical.
                    let open = rebuildOpen(r.openTag, name: "row", ensure: [("r", String(r.number))], drop: [], selfClosing: r.selfClosing)
                    inner += open + Array(r.raw.dropFirst(r.openTag.count))
                    continue
                }
                let hasCells = r.items.contains { if case .cell = $0 { return true }; return false }
                let selfClose = !hasCells && r.items.isEmpty
                inner += rebuildOpen(r.openTag, name: "row", ensure: [("r", String(r.number))], drop: ["spans"], selfClosing: selfClose)
                if selfClose { continue }
                for item in r.items {
                    switch item {
                    case .other(let o): inner += o
                    case .cell(let col, let raw, let hasRef):
                        if hasRef { inner += raw } else {
                            // Positional cells get explicit refs so later inserts can't shift them.
                            let at = 1 + prefix.count + 1
                            inner += Array(raw[..<at]) + bytes(" r=\"\(XLSXRef.string(row: r.number, col: col))\"") + Array(raw[at...])
                        }
                    }
                }
                inner += closeTag("row")
            }
        }

        var out: [UInt8] = []
        out.reserveCapacity(b.count + inner.count / 4)
        let p = String(decoding: prefix, as: UTF8.self)
        let head = Array(b[..<sd.start])
        out += updatedDimension(head, edits: edits)
        if selfClosingData {
            out += bytes("<\(p)sheetData>") + inner + bytes("</\(p)sheetData>")
        } else {
            out += Array(b[sd.start..<innerStart]) + inner + closeTag("sheetData")
        }
        out += Array(b[afterData...])
        return Outcome(data: Data(out), replacedFormula: replacedFormula)
    }

    /// Widens `<dimension ref="…">` (before sheetData) to cover the edited cells.
    private func updatedDimension(_ head: [UInt8], edits: [CellEdit]) -> [UInt8] {
        let pat = [UInt8(ascii: "<")] + prefix + bytes("dimension")
        guard let start = (0..<max(0, head.count - pat.count)).first(where: { i in head[i] == 0x3C && Array(head[i..<(i + pat.count)]) == pat }),
              let end = head[start...].firstIndex(of: 0x3E) else { return head }
        let attrs = Self.attributes(head[start...end])
        guard let ref = attrs.first(where: { $0.name == "ref" })?.raw else { return head }
        var r1 = Int.max, c1 = Int.max, r2 = 0, c2 = 0
        if let rg = XLSXRef.parseRange(ref) { r1 = rg.r1; c1 = rg.c1; r2 = rg.r2; c2 = rg.c2 }
        for e in edits where !e.value.isEmpty { r1 = min(r1, e.row); c1 = min(c1, e.col); r2 = max(r2, e.row); c2 = max(c2, e.col) }
        guard r2 > 0 else { return head }
        let newRef = r1 == r2 && c1 == c2 ? XLSXRef.string(row: r1, col: c1) : "\(XLSXRef.string(row: r1, col: c1)):\(XLSXRef.string(row: r2, col: c2))"
        guard newRef != ref else { return head }
        let tag = rebuildOpen(Array(head[start...end]), name: "dimension", ensure: [("ref", newRef)], drop: [], selfClosing: head[end - 1] == 0x2F)
        return Array(head[..<start]) + tag + Array(head[(end + 1)...])
    }
}

// MARK: - Workbook-level fixes after an edit

enum XLSXWorkbookFixer {
    /// After a formula cell becomes a value, Excel's calc chain lists a cell that no longer has
    /// a formula and Excel reports the file as damaged. Removing the (optional) chain makes
    /// Excel rebuild it. Returns the part removed, if any.
    static func dropCalcChain(root: URL, workbook: XLSXWorkbook) throws -> String? {
        guard let rel = workbook.relationships.first(where: { $0.type.hasSuffix("/calcChain") }) else { return nil }
        let part = XLSXWorkbook.resolve(rel.target, from: workbook.workbookPart)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(part))
        try removeMatches(root: root, part: workbook.relsPart, pattern: #"<(\w+:)?Relationship\b[^>]*\bId="\#(NSRegularExpression.escapedPattern(for: rel.id))"[^>]*/>"#)
        try removeMatches(root: root, part: "[Content_Types].xml", pattern: #"<(\w+:)?Override\b[^>]*\bPartName="/\#(NSRegularExpression.escapedPattern(for: part))"[^>]*/>"#)
        return part
    }

    /// Asks Excel to recalculate on open, so formulas that depend on changed cells don't show
    /// stale cached results.
    static func requestFullCalcOnLoad(root: URL, workbook: XLSXWorkbook) throws {
        let url = root.appendingPathComponent(workbook.workbookPart)
        guard var xml = try? String(contentsOf: url, encoding: .utf8) else { return }
        let ns = xml as NSString
        let calc = try NSRegularExpression(pattern: #"<(\w+:)?calcPr\b[^>]*?(/?)>"#)
        if let m = calc.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)) {
            var tag = ns.substring(with: m.range)
            if tag.contains("fullCalcOnLoad=") {
                tag = tag.replacingOccurrences(of: #"fullCalcOnLoad="[^"]*""#, with: #"fullCalcOnLoad="1""#, options: .regularExpression)
            } else {
                let close = tag.hasSuffix("/>") ? "/>" : ">"
                tag = String(tag.dropLast(close.count)) + " fullCalcOnLoad=\"1\"" + close
            }
            xml = ns.replacingCharacters(in: m.range, with: tag)
        } else {
            // calcPr goes after these elements (schema order); insert after the last present one.
            let prefixMatch = try NSRegularExpression(pattern: #"<(\w+:)?workbook\b"#).firstMatch(in: xml, range: NSRange(location: 0, length: ns.length))
            let p = prefixMatch.flatMap { $0.range(at: 1).location == NSNotFound ? nil : ns.substring(with: $0.range(at: 1)) } ?? ""
            var insertAt: Int?
            for name in ["definedNames", "externalReferences", "functionGroups", "sheets"] {
                let close = "</\(p)\(name)>"
                let r = ns.range(of: close, options: .backwards)
                if r.location != NSNotFound { insertAt = r.location + r.length; break }
            }
            guard let insertAt else { return }
            xml = ns.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: "<\(p)calcPr fullCalcOnLoad=\"1\"/>")
        }
        try Data(xml.utf8).write(to: url)
    }

    private static func removeMatches(root: URL, part: String, pattern: String) throws {
        let url = root.appendingPathComponent(part)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let re = try NSRegularExpression(pattern: pattern)
        let out = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        if out != text { try Data(out.utf8).write(to: url) }
    }
}

// MARK: - New workbooks

enum XLSXWriter {
    static let mainNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// Excel's sheet-name rules: at most 31 characters, none of []:*?/\, no leading/trailing apostrophe.
    static func sanitizeSheetName(_ name: String?) -> String {
        var s = (name ?? "").filter { !"[]:*?/\\".contains($0) }.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("'") { s.removeFirst() }
        while s.hasSuffix("'") { s.removeLast() }
        if s.count > 31 { s = String(s.prefix(31)) }
        return s.isEmpty ? "Sheet1" : s
    }

    static func sheetXML(_ table: TableData) -> String {
        var rows = ""
        var r = 0
        var maxCol = 0
        func cell(_ ref: String, _ v: String, style: Int?) -> String {
            guard !v.isEmpty else { return "" }
            let s = style.map { " s=\"\($0)\"" } ?? ""
            if XMLText.isPlainNumber(v) { return "<c r=\"\(ref)\"\(s)><v>\(v)</v></c>" }
            var text = v.replacingOccurrences(of: "\r\n", with: "\n")
            if text.count > XLSXSheetEditor.maxCellChars { text = String(text.prefix(XLSXSheetEditor.maxCellChars)) }
            let preserve = (text.first?.isWhitespace ?? false) || (text.last?.isWhitespace ?? false) ? " xml:space=\"preserve\"" : ""
            return "<c r=\"\(ref)\"\(s) t=\"inlineStr\"><is><t\(preserve)>\(XMLText.escape(text))</t></is></c>"
        }
        let all = [table.columns] + table.rows
        for (i, values) in all.enumerated() {
            r += 1
            let cells = values.enumerated().map { cell(XLSXRef.string(row: r, col: $0.offset + 1), $0.element, style: i == 0 ? 1 : nil) }.joined()
            maxCol = max(maxCol, values.count)
            rows += cells.isEmpty ? "<row r=\"\(r)\"/>" : "<row r=\"\(r)\">\(cells)</row>"
        }
        let dim = maxCol == 0 ? "A1" : "A1:\(XLSXRef.string(row: max(r, 1), col: maxCol))"
        let pane = table.rows.isEmpty ? "" : "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
            + "<worksheet xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\"><dimension ref=\"\(dim)\"/>\(pane)<sheetData>\(rows)</sheetData></worksheet>"
    }

    /// A minimal, valid workbook: one sheet, inline strings, a bold header row.
    static func write(_ table: TableData, to path: String) throws {
        let dir = try XLSXPackage.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let decl = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let sheetName = XMLText.escape(sanitizeSheetName(table.sheet), attribute: true)
        let parts: [(String, String)] = [
            ("[Content_Types].xml", decl + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
            </Types>
            """),
            ("_rels/.rels", decl + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(relNS)/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """),
            ("xl/workbook.xml", decl + """
            <workbook xmlns="\(mainNS)" xmlns:r="\(relNS)"><sheets><sheet name="\(sheetName)" sheetId="1" r:id="rId1"/></sheets></workbook>
            """),
            ("xl/_rels/workbook.xml.rels", decl + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="\(relNS)/worksheet" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Type="\(relNS)/styles" Target="styles.xml"/>\
            </Relationships>
            """),
            ("xl/styles.xml", decl + """
            <styleSheet xmlns="\(mainNS)">\
            <fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
            </styleSheet>
            """),
            ("xl/worksheets/sheet1.xml", sheetXML(table)),
        ]
        for (name, text) in parts {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let tmp = AtomicFile.siblingTemp(for: path, ext: "xlsx")
        do { try XLSXPackage.zip(dir: dir, entries: parts.map(\.0), to: tmp) } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            throw error
        }
        try AtomicFile.replace(path, with: tmp)
    }
}
