import Foundation

/// Delimited text (CSV, TSV, semicolon CSV from European Excel) with enough bookkeeping to
/// write a file back the way it came: same delimiter, line ending, encoding and byte-order mark.
/// `TableIO.readCSV` stays as the built-in fallback; this is the full implementation.
struct DelimitedDocument: Sendable {
    /// Every line, including blank ones, so row positions map back to the file exactly.
    var rows: [[String]]
    var delimiter: Unicode.Scalar
    var lineEnding: String
    var encoding: String.Encoding
    var hasBOM: Bool

    init(rows: [[String]], delimiter: Unicode.Scalar = ",", lineEnding: String = "\n", encoding: String.Encoding = .utf8, hasBOM: Bool = false) {
        self.rows = rows
        self.delimiter = delimiter
        self.lineEnding = lineEnding
        self.encoding = encoding
        self.hasBOM = hasBOM
    }
}

enum CSVCodec {
    /// Larger files are refused rather than loaded whole into memory.
    static let maxBytes = 100 << 20

    /// RFC 4180 parsing, lenient about the real world: quotes only open at the start of a field,
    /// stray quotes inside a field are kept, an unterminated quote runs to the end of the file,
    /// and CR, LF and CRLF all end a line.
    static func parse(_ text: String, delimiter: Unicode.Scalar) -> [[String]] {
        // Streams the scalars with one character of lookahead instead of materializing them,
        // so a large file costs about its own size in memory, not four times that.
        var it = text.unicodeScalars.makeIterator()
        var peeked: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let p = peeked { peeked = nil; return p }
            return it.next()
        }
        func peek() -> Unicode.Scalar? {
            if peeked == nil { peeked = it.next() }
            return peeked
        }
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldWasQuoted = false
        func endField() { row.append(String(field)); field = String.UnicodeScalarView(); fieldWasQuoted = false }
        func endRow() { endField(); rows.append(row); row = [] }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if peek() == "\"" { _ = next(); field.append("\"") } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty && !fieldWasQuoted {
                inQuotes = true
                fieldWasQuoted = true
            } else if c == delimiter {
                endField()
            } else if c == "\r" {
                if peek() == "\n" { _ = next() }
                endRow()
            } else if c == "\n" {
                endRow()
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty || fieldWasQuoted { endRow() }
        return rows
    }

    /// Picks the delimiter that splits the first line most, preferring `fallback` on ties.
    static func sniffDelimiter(_ text: String, fallback: Unicode.Scalar) -> Unicode.Scalar {
        let candidates: [Unicode.Scalar] = [fallback] + ([",", ";", "\t"] as [Unicode.Scalar]).filter { $0 != fallback }
        var counts: [Unicode.Scalar: Int] = [:]
        var inQuotes = false
        for c in text.unicodeScalars.prefix(20_000) {
            if c == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if c == "\n" || c == "\r" { break }
            if candidates.contains(c) { counts[c, default: 0] += 1 }
        }
        var best = fallback
        for c in candidates where counts[c, default: 0] > counts[best, default: 0] { best = c }
        return best
    }

    /// The first line break's style; new and single-line files use LF.
    static func detectLineEnding(_ text: String) -> String {
        var it = text.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == "\n" { return "\n" }
            if c == "\r" { return it.next() == "\n" ? "\r\n" : "\r" }
        }
        return "\n"
    }

    static func decode(_ data: Data) -> (String, String.Encoding, Bool) {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8, true)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE, let s = String(data: data, encoding: .utf16LittleEndian) {
            return (s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s, .utf16LittleEndian, true)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF, let s = String(data: data, encoding: .utf16BigEndian) {
            return (s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s, .utf16BigEndian, true)
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8, false) }
        // Old Excel "CSV (Windows)" exports are Windows-1252; it decodes any byte sequence.
        if let s = String(data: data, encoding: .windowsCP1252) { return (s, .windowsCP1252, false) }
        return (String(decoding: data, as: UTF8.self), .utf8, false)
    }

    static func load(_ path: String, tabSeparated: Bool?) throws -> DelimitedDocument {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let size = attrs?[.size] as? Int, size > maxBytes {
            throw SpreadsheetError.tooLarge("“\((path as NSString).lastPathComponent)” is larger than \(maxBytes >> 20) MB, too big to load as a table.")
        }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
            throw SpreadsheetError.unreadable("Couldn't read “\((path as NSString).lastPathComponent)”: \(error.localizedDescription)")
        }
        let (text, encoding, bom) = decode(data)
        let delimiter: Unicode.Scalar
        switch tabSeparated {
        case true?: delimiter = "\t"
        case false?: delimiter = sniffDelimiter(text, fallback: ",")
        case nil: delimiter = sniffDelimiter(text, fallback: "\t")
        }
        let lineEnding = detectLineEnding(text)
        var rows = parse(text, delimiter: delimiter)
        // A trailing newline isn't an extra blank row.
        while let last = rows.last, last.count == 1, last[0].isEmpty { rows.removeLast() }
        return DelimitedDocument(rows: rows, delimiter: delimiter, lineEnding: lineEnding, encoding: encoding, hasBOM: bom)
    }

    static func escape(_ s: String, delimiter: Unicode.Scalar) -> String {
        let needsQuotes = s.unicodeScalars.contains { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        return needsQuotes ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func serialize(_ doc: DelimitedDocument) -> String {
        let d = String(Character(doc.delimiter))
        var out = ""
        for row in doc.rows {
            out += row.map { escape($0, delimiter: doc.delimiter) }.joined(separator: d)
            out += doc.lineEnding
        }
        return out
    }

    static func encode(_ doc: DelimitedDocument) -> Data {
        let text = serialize(doc)
        if doc.encoding != .utf8, let data = text.data(using: doc.encoding, allowLossyConversion: false) {
            // UTF-16 `data(using:)` already writes a byte-order mark.
            return data
        }
        // New values may not fit the old encoding; UTF-8 with a BOM is what Excel reads best.
        let bom = doc.hasBOM || doc.encoding != .utf8
        return (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8)
    }

    static func save(_ doc: DelimitedDocument, to path: String) throws {
        try AtomicFile.write(encode(doc), to: path)
    }
}
