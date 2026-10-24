import Testing
import Foundation
import Network
import CoreGraphics
import CoreText
@testable import AgentKit
@testable import AutomationKit

// Offline tests for the data (CSV/TSV/XLSX) and web (fetch/search) tools. Network access is
// limited to a loopback HTTP server started by the tests themselves.

// MARK: - Helpers

private func tempDir(_ label: String = "data") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func fixture(_ name: String) throws -> String {
    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
    guard let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Fixtures") else {
        throw SpreadsheetError.notFound("missing fixture \(name)")
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private func context(_ dir: URL, jobID: String? = nil, gate: ExecutionGate = ExecutionGate()) -> ToolContext {
    ToolContext(settings: AppSettings(), gate: gate, jobID: jobID, workingDirectory: dir)
}

/// Extracts one part of a zip as text.
private func zipPart(_ path: String, _ part: String) throws -> String {
    let r = try Subprocess.run("/usr/bin/unzip", ["-p", path, part], timeout: 30)
    return String(decoding: r.stdout, as: UTF8.self)
}

/// A two-sheet workbook the way Excel writes one: shared strings, styles with date formats, a
/// formula with a calc chain, sparse rows, a styled empty cell, rich text, and content after
/// <sheetData> (cols, margins) that must survive edits.
private enum WorkbookFixture {
    static let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let decl = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    static let styles = decl + """
    <styleSheet xmlns="\(ns)"><numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd\\ hh:mm"/></numFmts>\
    <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
    <fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
    <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
    </styleSheet>
    """

    static let sheet2 = decl + """
    <worksheet xmlns="\(ns)"><dimension ref="A1"/><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>keep me</t></is></c></row></sheetData></worksheet>
    """

    static let sheet1 = decl + """
    <worksheet xmlns="\(ns)" xmlns:r="\(rel)"><dimension ref="A1:D5"/><sheetViews><sheetView workbookViewId="0"/></sheetViews>\
    <sheetFormatPr defaultRowHeight="15"/><cols><col min="1" max="1" width="20" customWidth="1"/></cols><sheetData>\
    <row r="1" spans="1:4"><c r="A1" s="3" t="s"><v>0</v></c><c r="B1" s="3" t="s"><v>1</v></c><c r="C1" s="3" t="s"><v>2</v></c><c r="D1" s="3" t="s"><v>3</v></c></row>\
    <row r="2" spans="1:4"><c r="A2" t="s"><v>4</v></c><c r="B2" t="s"><v>5</v></c><c r="C2"><v>3.5</v></c><c r="D2" s="1"><v>45000</v></c></row>\
    <row r="3" spans="1:4"><c r="A3" t="s"><v>6</v></c><c r="B3" t="inlineStr"><is><t>New York</t></is></c><c r="C3"><f>C2*2</f><v>7</v></c><c r="D3" s="2"><v>45000.75</v></c></row>\
    <row r="5" spans="1:4"><c r="A5" t="s"><v>7</v></c><c r="B5" t="s"><v>8</v></c><c r="C5" t="b"><v>1</v></c><c r="D5" s="1"/></row>\
    </sheetData><pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/></worksheet>
    """

    static let parts: [(String, String)] = [
        ("[Content_Types].xml", decl + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        <Override PartName="/xl/calcChain.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/>\
        </Types>
        """),
        ("_rels/.rels", decl + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """),
        ("xl/workbook.xml", decl + """
        <workbook xmlns="\(ns)" xmlns:r="\(rel)"><workbookPr defaultThemeVersion="164011"/><bookViews><workbookView xWindow="0" yWindow="0"/></bookViews>\
        <sheets><sheet name="People" sheetId="1" r:id="rId1"/><sheet name="Notes" sheetId="2" r:id="rId2"/></sheets><calcPr calcId="191029"/></workbook>
        """),
        ("xl/_rels/workbook.xml.rels", decl + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="\(rel)/worksheet" Target="/xl/worksheets/sheet2.xml"/>\
        <Relationship Id="rId3" Type="\(rel)/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rId4" Type="\(rel)/styles" Target="styles.xml"/>\
        <Relationship Id="rId5" Type="\(rel)/calcChain" Target="calcChain.xml"/></Relationships>
        """),
        ("xl/sharedStrings.xml", decl + """
        <sst xmlns="\(ns)" count="9" uniqueCount="9"><si><t>Name</t></si><si><t>City</t></si><si><t>Score</t></si><si><t>Joined</t></si>\
        <si><t>Ada</t></si><si><t>London &amp; Paris</t></si><si><t>Grace</t></si><si><t>Alan</t></si>\
        <si><r><rPr><b/></rPr><t>Man</t></r><r><t>chester</t></r><rPh sb="0" eb="1"><t>PHONETIC</t></rPh></si></sst>
        """),
        ("xl/styles.xml", styles),
        ("xl/calcChain.xml", decl + "<calcChain xmlns=\"\(ns)\"><c r=\"C3\" i=\"1\"/></calcChain>"),
        ("xl/worksheets/sheet1.xml", sheet1),
        ("xl/worksheets/sheet2.xml", sheet2),
    ]

    static func write(to path: String) throws {
        let dir = try tempDir("fixture")
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, text) in parts {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try XLSXPackage.zip(dir: dir, entries: parts.map(\.0), to: path)
    }
}

/// A loopback-only HTTP/1.1 server for fetch tests. Each request gets one response and the
/// connection closes (or, for `hang`, stays open until the server stops).
private final class TestHTTPServer: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]
        var body = Data()
        var hang = false
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var boundPort: UInt16 = 0
    private let handler: @Sendable (_ method: String, _ path: String, _ body: Data) -> Response

    init(_ handler: @escaping @Sendable (_ method: String, _ path: String, _ body: Data) -> Response) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        self.handler = handler
    }

    func start() async throws -> URL {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
        }
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.fire() {
                        self?.lock.withLock { self?.boundPort = self?.listener.port?.rawValue ?? 0 }
                        cont.resume()
                    }
                case .failed(let e):
                    if once.fire() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
            listener.start(queue: .global())
        }
        let port = lock.withLock { boundPort }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in defer { connections = [] }; return connections }
        open.forEach { $0.cancel() }
    }

    private func accept(_ c: NWConnection) {
        lock.withLock { connections.append(c) }
        c.start(queue: .global())
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[end.upperBound...]
                if body.count >= length { self.respond(c, head: head, body: Data(body.prefix(length))); return }
            }
            if done || error != nil { c.cancel(); return }
            self.receive(c, buf)
        }
    }

    private func respond(_ c: NWConnection, head: String, body: Data) {
        let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let r = handler(method, path, body)
        if r.hang { return }
        let reason = [200: "OK", 202: "Accepted", 302: "Found", 404: "Not Found"][r.status] ?? "Status"
        var out = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
        for (k, v) in r.headers { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        c.send(content: Data(out.utf8) + r.body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// A one-page PDF with real (selectable) text, drawn with Core Text.
private func makePDF(_ text: String) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    ctx.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    return data as Data
}

// MARK: - Suites

@Suite("Data and web tools")
struct DataWebToolsTests {

    // MARK: CSV

    @Suite("CSV and TSV")
    struct CSV {
        @Test func parsesQuotesNewlinesAndLineEndings() {
            let text = "name,note,qty\r\n\"Smith, J\",\"said \"\"hi\"\"\",3\r\n\"multi\nline\",,\r\nplain,end\"quote,7"
            let rows = CSVCodec.parse(text, delimiter: ",")
            #expect(rows.count == 4)
            #expect(rows[1] == ["Smith, J", "said \"hi\"", "3"])
            #expect(rows[2] == ["multi\nline", "", ""])
            #expect(rows[3] == ["plain", "end\"quote", "7"])
            #expect(CSVCodec.parse("a,b\rc,d\r", delimiter: ",") == [["a", "b"], ["c", "d"]])
            #expect(CSVCodec.parse("\"\"", delimiter: ",") == [[""]])
            // An unterminated quote runs to the end instead of losing data.
            #expect(CSVCodec.parse("a,\"open\nstill", delimiter: ",") == [["a", "open\nstill"]])
            #expect(CSVCodec.parse("", delimiter: ",").isEmpty)
        }

        @Test func sniffsDelimitersAndLineEndings() {
            #expect(CSVCodec.sniffDelimiter("a;b;c\n1;2;3", fallback: ",") == ";")
            #expect(CSVCodec.sniffDelimiter("\"x;y\",b\n", fallback: ",") == ",")
            #expect(CSVCodec.sniffDelimiter("a\tb\tc", fallback: ",") == "\t")
            #expect(CSVCodec.sniffDelimiter("single", fallback: "\t") == "\t")
            #expect(CSVCodec.detectLineEnding("a\r\nb") == "\r\n")
            #expect(CSVCodec.detectLineEnding("a\rb") == "\r")
            #expect(CSVCodec.detectLineEnding("a") == "\n")
        }

        @Test func readsBOMRaggedRowsAndMessyHeaders() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("people.csv").path
            try (Data([0xEF, 0xBB, 0xBF]) + Data("Name, ,Name\nAda,1\n\n  \nGrace,2,x,extra\n".utf8)).write(to: URL(fileURLWithPath: path))
            let t = try Spreadsheet.read(path)
            #expect(t.columns == ["Name", "Column 2", "Name (2)", "Column 4"])
            #expect(t.rows.count == 2) // blank lines skipped
            #expect(t.rows[0] == ["Ada", "1", "", ""])
            #expect(t.rows[1] == ["Grace", "2", "x", "extra"])
            #expect(t.records[1]["Name (2)"] == "x")
            let noHeader = try Spreadsheet.read(path, hasHeader: false)
            #expect(noHeader.columns.first == "Column 1")
            #expect(noHeader.rows.count == 3)
        }

        @Test func semicolonAndTabFiles() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let semi = dir.appendingPathComponent("eu.csv").path
            try "Produkt;Preis\nKäse;3,50\n".write(toFile: semi, atomically: true, encoding: .utf8)
            #expect(try Spreadsheet.read(semi).rows == [["Käse", "3,50"]])
            let tsv = dir.appendingPathComponent("t.tsv").path
            try "a\tb\n1,5\t2\n".write(toFile: tsv, atomically: true, encoding: .utf8)
            #expect(try Spreadsheet.read(tsv).rows == [["1,5", "2"]])
            let txt = dir.appendingPathComponent("excel.txt").path
            try Spreadsheet.write(txt, TableData(columns: ["x", "y"], rows: [["1", "2"]]))
            #expect(try String(contentsOfFile: txt, encoding: .utf8) == "x\ty\n1\t2\n")
        }

        @Test func keepsWindows1252Encoding() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("legacy.csv").path
            try Data("City,Note\r\nZ\u{FC}rich,caf\u{E9}\r\n".data(using: .windowsCP1252)!).write(to: URL(fileURLWithPath: path))
            #expect(try Spreadsheet.read(path).rows == [["Zürich", "café"]])
            try Spreadsheet.update(path, keyColumn: "City", updates: ["Zürich": ["Note": "crème"]])
            let raw = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(String(data: raw, encoding: .windowsCP1252) == "City,Note\r\nZürich,crème\r\n")
        }

        @Test func roundTripsAndNeutralizesFormulas() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("out.csv").path
            let rows = [["a,b", "say \"x\"", "line\nbreak"], ["=HYPERLINK(\"http://evil\")", "-5", "+1 555 0100"], ["@SUM(A1)", "-cmd|' /C calc'!A0", "- note"]]
            try Spreadsheet.write(path, TableData(columns: ["c1", "c2", "c3"], rows: rows))
            let back = try Spreadsheet.read(path)
            #expect(back.rows[0] == rows[0])
            #expect(back.rows[1] == ["'=HYPERLINK(\"http://evil\")", "-5", "+1 555 0100"])
            #expect(back.rows[2] == ["'@SUM(A1)", "'-cmd|' /C calc'!A0", "- note"])
        }

        @Test func updatesInPlaceAndKeepsBackup() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("leads.csv").path
            let original = "Company,City,Status\r\nAcme,Paris,\r\n\r\nGlobex,Rome,new\r\n"
            try original.write(toFile: path, atomically: true, encoding: .utf8)
            let owner = "job-\(UUID().uuidString)"
            let c = try Spreadsheet.update(path, keyColumn: "Company", updates: [
                "Acme": ["Status": "contacted", "Email": "hi@acme.test"],
                "globex": ["City": "Rome"],                // case-insensitive match, unchanged value
                "Initech": ["City": "Austin"],             // new row
            ], owner: owner)
            #expect(c.updatedCells == 3)
            #expect(c.addedRows == 1)
            #expect(c.addedColumns == ["Email"])
            #expect(c.backupPath == path + ".bak")
            #expect(try String(contentsOfFile: path + ".bak", encoding: .utf8) == original)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            #expect(text == "Company,City,Status,Email\r\nAcme,Paris,contacted,hi@acme.test\r\n\r\nGlobex,Rome,new\r\nInitech,Austin,,\r\n")
            // The second change by the same job keeps the first backup.
            let c2 = try Spreadsheet.update(path, keyColumn: nil, updates: ["1": ["Status": "won"]], owner: owner)
            #expect(c2.backupPath == nil)
            #expect(try String(contentsOfFile: path + ".bak", encoding: .utf8) == original)
            // Row 1 is Globex: the blank line is skipped the same way reading skips it.
            #expect(try Spreadsheet.read(path).records[1]["Status"] == "won")
            #expect(throws: SpreadsheetError.self) { try Spreadsheet.update(path, keyColumn: "Nope", updates: ["x": ["a": "b"]]) }
            #expect(throws: SpreadsheetError.self) { try Spreadsheet.update(path, keyColumn: nil, updates: ["first": ["a": "b"]]) }
        }

        @Test func appendCreatesThenExtends() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("log.csv").path
            try Spreadsheet.append(path, rows: [["when": "mon", "what": "a"]], columnOrder: ["when", "what"])
            let c = try Spreadsheet.append(path, rows: [["what": "b", "when": "tue"], ["extra": "z"]])
            #expect(c.addedRows == 2)
            #expect(c.addedColumns == ["extra"])
            let t = try Spreadsheet.read(path)
            #expect(t.columns == ["when", "what", "extra"])
            #expect(t.rows == [["mon", "a", ""], ["tue", "b", ""], ["", "", "z"]])
        }

        @Test func unsupportedFormatsExplainWhatToDo() {
            #expect(throws: SpreadsheetError.self) { try SpreadsheetFormat.detect("/tmp/a.xls") }
            #expect(throws: SpreadsheetError.self) { try SpreadsheetFormat.detect("/tmp/a.numbers") }
            #expect(throws: SpreadsheetError.self) { try SpreadsheetFormat.detect("/tmp/a.swift") }
            #expect(throws: SpreadsheetError.self) { try Spreadsheet.read("/nonexistent/\(UUID().uuidString).csv") }
        }

        @Test func neverReplacesAFolder() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let folder = dir.appendingPathComponent("looks-like.csv")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "keep".write(to: folder.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
            #expect(throws: SpreadsheetError.self) { try Spreadsheet.write(folder.path, TableData(columns: ["a"], rows: [])) }
            #expect(throws: SpreadsheetError.self) { try Spreadsheet.update(folder.path, keyColumn: nil, updates: ["0": ["a": "b"]]) }
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("inside.txt").path))
        }

        @Test func concurrentUpdatesDontLoseWrites() async throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("par.csv").path
            try Spreadsheet.write(path, TableData(columns: ["id", "v"], rows: (0..<20).map { [String($0), ""] }))
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<20 {
                    group.addTask { _ = try? await runBlocking { try Spreadsheet.update(path, keyColumn: "id", updates: [String(i): ["v": "done\(i)"]]) } }
                }
            }
            let t = try Spreadsheet.read(path)
            #expect(t.rows.allSatisfy { $0[1] == "done\($0[0])" })
        }
    }

    // MARK: XLSX

    @Suite("XLSX")
    struct XLSX {
        @Test func referencesAndNumbers() {
            #expect(XLSXRef.columnNumber("A") == 1)
            #expect(XLSXRef.columnNumber("AA") == 27)
            #expect(XLSXRef.columnNumber("XFD") == 16_384)
            #expect(XLSXRef.columnNumber("XFE") == nil)
            #expect(XLSXRef.letters(28) == "AB")
            #expect(XLSXRef.parse("$C$5")?.row == 5)
            #expect(XLSXRef.parse("5C") == nil)
            #expect(XLSXRef.parseRange("") == nil)
            #expect(XLSXRef.parseRange("B2:A1")?.c2 == 2)
            #expect(XLSXSheetReader.formatNumber("0.30000000000000004") == "0.3")
            #expect(XLSXSheetReader.formatNumber("1.0") == "1")
            #expect(XLSXSheetReader.formatNumber("-12.5") == "-12.5")
            #expect(XMLText.isPlainNumber("42"))
            #expect(XMLText.isPlainNumber("-3.25"))
            #expect(!XMLText.isPlainNumber("007"))
            #expect(!XMLText.isPlainNumber("1e5"))
            #expect(!XMLText.isPlainNumber("1234567890123456"))
        }

        @Test func datesAndFormats() {
            #expect(XLSXSheetReader.formatDate(serial: 45000, kind: .date, date1904: false) == "2023-03-15")
            #expect(XLSXSheetReader.formatDate(serial: 45000.75, kind: .dateTime, date1904: false) == "2023-03-15T18:00:00")
            #expect(XLSXSheetReader.formatDate(serial: 1, kind: .date, date1904: false) == "1900-01-01")
            #expect(XLSXSheetReader.formatDate(serial: 59, kind: .date, date1904: false) == "1900-02-28")
            #expect(XLSXSheetReader.formatDate(serial: 61, kind: .date, date1904: false) == "1900-03-01")
            #expect(XLSXSheetReader.formatDate(serial: 100, kind: .date, date1904: true) == "1904-04-10")
            #expect(XLSXSheetReader.formatDate(serial: 0.5, kind: .time, date1904: false) == "12:00:00")
            #expect(XLSXSheetReader.formatDate(serial: -1, kind: .date, date1904: false) == nil)
            #expect(XLSXWorkbook.dateKind(formatCode: "yyyy-mm-dd") == .date)
            #expect(XLSXWorkbook.dateKind(formatCode: "h:mm AM/PM") == .time)
            #expect(XLSXWorkbook.dateKind(formatCode: "d/m/yy h:mm") == .dateTime)
            #expect(XLSXWorkbook.dateKind(formatCode: "\"Day\" d") == .date)
            #expect(XLSXWorkbook.dateKind(formatCode: "0.00") == nil)
            #expect(XLSXWorkbook.dateKind(formatCode: "[Red]#,##0") == nil)
            #expect(XLSXWorkbook.dateKind(formatCode: "[h]:mm:ss") == nil)
            #expect(XLSXWorkbook.dateKind(formatCode: "\"Items\" 0") == nil)
        }

        @Test func writerOutputReadsBack() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("new.xlsx").path
            let table = TableData(columns: ["Name", "Zip", "Amount", "Note"],
                                  rows: [["Tom & Jerry <co>", "007", "12.5", " padded "], ["Zoë", "94105", "-3", ""], ["", "", "", "only note"]],
                                  sheet: "Results: Q3/Q4")
            try Spreadsheet.write(path, table)
            let back = try Spreadsheet.read(path)
            #expect(back.sheet == "Results Q3Q4")
            #expect(back.columns == table.columns)
            #expect(back.rows == table.rows)
            #expect(try zipPart(path, "xl/worksheets/sheet1.xml").contains("<c r=\"C2\"><v>12.5</v></c>"))
            let check = try Subprocess.run("/usr/bin/unzip", ["-tq", path])
            #expect(check.status == 0)
            #expect(try XLSXPackage.entries(path).first == "[Content_Types].xml")
        }

        @Test func readsAnExcelStyleWorkbook() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("book.xlsx").path
            try WorkbookFixture.write(to: path)
            let t = try Spreadsheet.read(path)
            #expect(t.sheet == "People")
            #expect(t.columns == ["Name", "City", "Score", "Joined"])
            #expect(t.rows == [
                ["Ada", "London & Paris", "3.5", "2023-03-15"],
                ["Grace", "New York", "7", "2023-03-15T18:00:00"],
                ["Alan", "Manchester", "TRUE", ""],
            ])
            #expect(try Spreadsheet.sheetNames(path) == ["People", "Notes"])
            #expect(try Spreadsheet.read(path, sheet: "notes", hasHeader: false).rows == [["keep me"]])
            #expect(try Spreadsheet.read(path, sheet: "2", hasHeader: false).rows == [["keep me"]])
            #expect(throws: SpreadsheetError.self) { try Spreadsheet.read(path, sheet: "Missing") }
        }

        @Test func updatesCellsAndKeepsEverythingElse() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("book.xlsx").path
            try WorkbookFixture.write(to: path)
            let originalBytes = try Data(contentsOf: URL(fileURLWithPath: path))
            let owner = "job-\(UUID().uuidString)"
            let change = try Spreadsheet.update(path, keyColumn: "Name", updates: [
                "Ada": ["Score": "4", "Status": "done"],   // existing cell + new column
                "Grace": ["City": "Boston", "Score": "8"], // inline string cell + formula cell
                "Linus": ["City": "Helsinki"],             // new row
            ], owner: owner)
            #expect(change.sheet == "People")
            #expect(change.addedColumns == ["Status"])
            #expect(change.addedRows == 1)
            #expect(change.updatedCells == 5)
            #expect(change.backupPath == path + ".bak")
            #expect(try Data(contentsOf: URL(fileURLWithPath: path + ".bak")) == originalBytes)

            let t = try Spreadsheet.read(path)
            #expect(t.columns == ["Name", "City", "Score", "Joined", "Status"])
            #expect(t.rows == [
                ["Ada", "London & Paris", "4", "2023-03-15", "done"],
                ["Grace", "Boston", "8", "2023-03-15T18:00:00", ""],
                ["Alan", "Manchester", "TRUE", "", ""],
                ["Linus", "Helsinki", "", "", ""],
            ])
            #expect(try Spreadsheet.read(path, sheet: "Notes", hasHeader: false).rows == [["keep me"]])

            // Untouched parts are byte-identical; the sheet keeps its other content.
            #expect(try zipPart(path, "xl/styles.xml") == WorkbookFixture.styles)
            #expect(try zipPart(path, "xl/worksheets/sheet2.xml") == WorkbookFixture.sheet2)
            let sheet = try zipPart(path, "xl/worksheets/sheet1.xml")
            #expect(sheet.contains("<cols><col min=\"1\" max=\"1\" width=\"20\" customWidth=\"1\"/></cols>"))
            #expect(sheet.contains("<pageMargins left=\"0.7\""))
            #expect(sheet.contains("<c r=\"D5\" s=\"1\"/>"))
            #expect(sheet.contains("<row r=\"5\" spans=\"1:4\">")) // an untouched row stays verbatim
            #expect(sheet.contains("<c r=\"A1\" s=\"3\" t=\"s\"><v>0</v></c>"))
            #expect(sheet.contains("<c r=\"E1\" t=\"inlineStr\"><is><t>Status</t></is></c>"))
            #expect(sheet.contains("<c r=\"C3\"><v>8</v></c>"))
            #expect(sheet.contains("<row r=\"6\"><c r=\"A6\" t=\"inlineStr\"><is><t>Linus</t></is></c>"))
            #expect(sheet.contains("<dimension ref=\"A1:E6\"/>"))
            #expect(XMLParser(data: Data(sheet.utf8)).parse())

            // The overwritten formula's calc chain is gone; Excel recalculates on open.
            let entries = try XLSXPackage.entries(path)
            #expect(entries.first == "[Content_Types].xml")
            #expect(!entries.contains("xl/calcChain.xml"))
            #expect(!(try zipPart(path, "[Content_Types].xml")).contains("calcChain"))
            #expect(!(try zipPart(path, "xl/_rels/workbook.xml.rels")).contains("calcChain"))
            #expect(try zipPart(path, "xl/workbook.xml").contains("<calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/>"))
            #expect(try Subprocess.run("/usr/bin/unzip", ["-tq", path]).status == 0)

            // Writing the same values again changes nothing and keeps the first backup.
            let again = try Spreadsheet.update(path, keyColumn: "Name", updates: ["Ada": ["Score": "4"]], owner: owner)
            #expect(again.updatedCells == 0 && again.backupPath == nil)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path + ".bak")) == originalBytes)
        }

        @Test func updateByRowIndexAndAppend() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("book.xlsx").path
            try WorkbookFixture.write(to: path)
            // Index 2 is Alan (sheet row 5, after the missing row 4).
            try Spreadsheet.update(path, keyColumn: nil, updates: ["2": ["Joined": "2024-01-02"]])
            #expect(try Spreadsheet.read(path).rows[2] == ["Alan", "Manchester", "TRUE", "2024-01-02"])
            #expect(try zipPart(path, "xl/worksheets/sheet1.xml").contains("<c r=\"D5\" s=\"1\" t=\"inlineStr\"><is><t>2024-01-02</t></is></c>"))
            try Spreadsheet.append(path, rows: [["Name": "Barbara", "Score": "9"]])
            let t = try Spreadsheet.read(path)
            #expect(t.rows.last == ["Barbara", "", "9", ""])
        }

        @Test func largerWorkbookUpdate() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("big.xlsx").path
            try Spreadsheet.write(path, TableData(columns: ["id", "name", "status"], rows: (0..<5000).map { ["\($0)", "Company \($0)", ""] }))
            var updates: [String: [String: String]] = [:]
            for i in stride(from: 0, to: 5000, by: 50) { updates["\(i)"] = ["status": "done", "score": "\(i / 50)"] }
            let start = Date()
            let c = try Spreadsheet.update(path, keyColumn: "id", updates: updates)
            #expect(Date().timeIntervalSince(start) < 20)
            #expect(c.updatedCells == 200)
            let t = try Spreadsheet.read(path)
            #expect(t.rows.count == 5000)
            #expect(t.rows[4950] == ["4950", "Company 4950", "done", "99"])
            #expect(t.rows[4951] == ["4951", "Company 4951", "", ""])
        }

        @Test func editorHandlesPrefixesSelfClosingAndImplicitRefs() throws {
            let prefixed = Data("""
            <x:worksheet xmlns:x="\(WorkbookFixture.ns)"><x:sheetData><x:row r="1"><x:c r="A1" t="inlineStr"><x:is><x:t>a</x:t></x:is></x:c><x:c r="C1"><x:v>3</x:v></x:c></x:row></x:sheetData></x:worksheet>
            """.utf8)
            let out = try XLSXSheetEditor.apply(prefixed, edits: [CellEdit(row: 1, col: 2, value: "b"), CellEdit(row: 3, col: 1, value: "5")])
            let s = String(decoding: out.data, as: UTF8.self)
            #expect(s.contains("<x:c r=\"A1\" t=\"inlineStr\"><x:is><x:t>a</x:t></x:is></x:c><x:c r=\"B1\" t=\"inlineStr\"><x:is><x:t>b</x:t></x:is></x:c><x:c r=\"C1\">"))
            #expect(s.contains("<x:row r=\"3\"><x:c r=\"A3\"><x:v>5</x:v></x:c></x:row>"))
            #expect(XMLParser(data: out.data).parse())

            let empty = Data("<worksheet xmlns=\"\(WorkbookFixture.ns)\"><dimension ref=\"A1\"/><sheetData/><pageMargins left=\"1\"/></worksheet>".utf8)
            let filled = String(decoding: try XLSXSheetEditor.apply(empty, edits: [CellEdit(row: 1, col: 1, value: " x ")]).data, as: UTF8.self)
            #expect(filled.contains("<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t xml:space=\"preserve\"> x </t></is></c></row></sheetData><pageMargins"))

            // Rows and cells without refs get explicit ones so inserts can't shift them.
            let implicit = Data("<worksheet xmlns=\"\(WorkbookFixture.ns)\"><sheetData><row><c><v>1</v></c><c><v>2</v></c></row><row><c><v>3</v></c></row></sheetData></worksheet>".utf8)
            let fixed = String(decoding: try XLSXSheetEditor.apply(implicit, edits: [CellEdit(row: 1, col: 3, value: "9")]).data, as: UTF8.self)
            #expect(fixed.contains("<row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"B1\"><v>2</v></c><c r=\"C1\"><v>9</v></c></row><row r=\"2\"><c><v>3</v></c></row>"))

            // Clearing an unstyled cell removes it; escaping keeps the XML valid.
            let cleared = try XLSXSheetEditor.apply(prefixed, edits: [CellEdit(row: 1, col: 3, value: ""), CellEdit(row: 2, col: 1, value: "a<b>&\u{1}c")])
            let cs = String(decoding: cleared.data, as: UTF8.self)
            #expect(!cs.contains("C1"))
            #expect(cs.contains("a&lt;b&gt;&amp;c"))
        }

        @Test func refusesToBreakSharedAndArrayFormulas() {
            let xml = Data("""
            <worksheet xmlns="\(WorkbookFixture.ns)"><sheetData><row r="1"><c r="A1"><f t="shared" ref="A1:A3" si="0">B1*2</f><v>2</v></c><c r="B1"><f t="array" ref="B1:B2">C1:C2</f><v>1</v></c></row>\
            <row r="2"><c r="A2"><f t="shared" si="0"/><v>4</v></c></row></sheetData></worksheet>
            """.utf8)
            #expect(throws: SpreadsheetError.self) { try XLSXSheetEditor.apply(xml, edits: [CellEdit(row: 1, col: 1, value: "x")]) }
            #expect(throws: SpreadsheetError.self) { try XLSXSheetEditor.apply(xml, edits: [CellEdit(row: 2, col: 2, value: "x")]) }
            // A dependent (non-master) shared-formula cell may be replaced.
            #expect((try? XLSXSheetEditor.apply(xml, edits: [CellEdit(row: 2, col: 1, value: "x")]))?.replacedFormula == true)
        }

        @Test func rejectsDamagedAndProtectedFiles() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let fake = dir.appendingPathComponent("fake.xlsx").path
            try "Name,City\n".write(toFile: fake, atomically: true, encoding: .utf8)
            #expect(throws: SpreadsheetError.self) { try Spreadsheet.read(fake) }
            let ole = dir.appendingPathComponent("locked.xlsx").path
            try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0]).write(to: URL(fileURLWithPath: ole))
            do { _ = try Spreadsheet.read(ole); Issue.record("expected an error") } catch {
                #expect(error.localizedDescription.contains("password-protected"))
            }
        }

        @Test func refusesWorkbooksWithLinks() throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let pkg = dir.appendingPathComponent("pkg")
            for (name, text) in WorkbookFixture.parts where name != "xl/worksheets/sheet1.xml" {
                let url = pkg.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            // The sheet part is a symlink to a file outside the workbook.
            try FileManager.default.createSymbolicLink(atPath: pkg.appendingPathComponent("xl/worksheets/sheet1.xml").path, withDestinationPath: "/etc/hosts")
            let path = dir.appendingPathComponent("evil.xlsx").path
            let list = WorkbookFixture.parts.map(\.0).joined(separator: "\n") + "\n"
            let r = try Subprocess.run("/usr/bin/zip", ["-y", "-q", "-nw", path, "-@"], cwd: pkg, stdin: Data(list.utf8))
            try #require(r.status == 0)
            do { _ = try Spreadsheet.read(path); Issue.record("expected the link to be refused") } catch {
                #expect(error.localizedDescription.contains("links"))
            }
            #expect(throws: SpreadsheetError.self) { try Spreadsheet.update(path, keyColumn: nil, updates: ["0": ["Name": "x"]]) }
        }

        @Test func tableIOHooksUseTheRealImplementation() throws {
            DataTools.install()
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("hooks.xlsx").path
            try TableIO.writer(path, TableData(columns: ["k", "v"], rows: [["a", "1"]]))
            #expect(try TableIO.reader(path, nil, true).rows == [["a", "1"]])
            try #require(TableIO.updater != nil)
            try TableIO.updater?(path, nil, "k", ["a": ["v": "2"], "b": ["v": "3"]], TableIO.UpdateOptions(owner: "test-job"))
            #expect(try TableIO.reader(path, nil, true).rows == [["a", "2"], ["b", "3"]])
            #expect(FileManager.default.fileExists(atPath: path + ".bak"))
            let names = Set(ToolRegistry.standard(settings: AppSettings()).specs(in: [.data]).map(\.name))
            #expect(names.isSuperset(of: ["sheet.read", "sheet.write", "sheet.update", "sheet.append"]))
        }
    }

    // MARK: Sheet tools

    @Suite("Sheet tools")
    struct SheetTools {
        @Test func readToolSummarizesAndFilters() async throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            try Spreadsheet.write(dir.appendingPathComponent("t.csv").path,
                                  TableData(columns: ["Name", "City"], rows: (0..<60).map { ["n\($0)", "c|\($0)"] }))
            let ctx = context(dir)
            let out = try await SheetReadTool().run(["path": "t.csv", "max_rows": 3, "columns": ["city"]], context: ctx)
            #expect(out.ok)
            #expect(out.text.contains("60 rows × 2 columns"))
            #expect(out.text.contains("row | City"))
            #expect(out.text.contains("0 | c/0"))
            #expect(out.data?["row_count"]?.intValue == 60)
            #expect(out.data?["rows"]?[2]?["City"]?.stringValue == "c|2")
            #expect(out.data?["truncated"]?.boolValue == true)
            let page = try await SheetReadTool().run(["path": "t.csv", "start_row": 58], context: ctx)
            #expect(page.data?["rows"]?.arrayValue?.count == 2)
            let missing = try await SheetReadTool().run(["path": "t.csv", "columns": ["Nope"]], context: ctx)
            #expect(!missing.ok && missing.text.contains("Nope"))
            let absent = try await SheetReadTool().run(["path": "absent.csv"], context: ctx)
            #expect(!absent.ok && absent.text.contains("no file"))
            #expect(SheetReadTool().assess(["path": "t.csv"], context: ctx).risk == .low)
        }

        @Test func writeUpdateAppendTools() async throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let ctx = context(dir)
            let created = try await SheetWriteTool().run(["path": "out.xlsx", "columns": ["a", "b"], "rows": [[1, "x"], ["b": "y"]]], context: ctx)
            #expect(created.ok)
            #expect(try Spreadsheet.read(dir.appendingPathComponent("out.xlsx").path).rows == [["1", "x"], ["", "y"]])
            let again = try await SheetWriteTool().run(["path": "out.xlsx", "columns": ["a"], "rows": []], context: ctx)
            #expect(!again.ok && again.text.contains("already exists"))
            await #expect(throws: ToolError.self) { _ = try await SheetWriteTool().run(["path": "out.xlsx", "columns": ["a"], "rows": [[1, 2]], "mode": "overwrite"], context: ctx) }

            let upd = try await SheetUpdateTool().run(["path": "out.xlsx", "key_column": "a", "updates": "{\"1\": {\"b\": \"z\", \"c\": true}}"], context: ctx)
            #expect(upd.ok)
            #expect(upd.data?["updated_cells"]?.intValue == 2)
            let app = try await SheetAppendTool().run(["path": "out.xlsx", "rows": [["9", "q", "w"]]], context: ctx)
            #expect(app.ok && app.text.contains("Appended 1 row"))
            #expect(try Spreadsheet.read(dir.appendingPathComponent("out.xlsx").path).rows == [["1", "z", "true"], ["", "y", ""], ["9", "q", "w"]])
            let bad = try await SheetUpdateTool().run(["path": "out.xlsx", "key_column": "zzz", "updates": ["1": ["b": "c"]]], context: ctx)
            #expect(!bad.ok)
        }

        @Test func riskFollowsProvenanceAndLocation() async throws {
            let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
            let existing = dir.appendingPathComponent("before.csv").path
            try "a\n1\n".write(toFile: existing, atomically: true, encoding: .utf8)
            let quick = context(dir)
            #expect(SheetWriteTool().assess(["path": "new.csv", "mode": "create"], context: quick).risk == .medium)
            #expect(SheetWriteTool().assess(["path": "before.csv", "mode": "overwrite"], context: quick).risk == .high)
            #expect(SheetUpdateTool().assess(["path": "before.csv", "updates": ["0": ["a": "2"]]], context: quick).risk == .high)
            #expect(SheetAppendTool().assess(["path": "before.csv", "rows": [["a": "2"]]], context: quick).risk == .medium)

            // A file this task created may be replaced at medium risk.
            _ = try await SheetWriteTool().run(["path": "mine.csv", "columns": ["a"], "rows": [["1"]]], context: quick)
            #expect(SheetWriteTool().assess(["path": "mine.csv", "mode": "overwrite"], context: quick).risk == .medium)
            #expect(SheetUpdateTool().assess(["path": "mine.csv", "updates": ["0": ["a": "2"]]], context: quick).risk == .medium)

            // Inside a job's own folder, changes are medium.
            let job = context(dir, jobID: "job-\(UUID().uuidString)")
            #expect(SheetUpdateTool().assess(["path": "before.csv", "updates": ["0": ["a": "2"]]], context: job).risk == .medium)

            // Outside the home folder is high; system folders and keychains are blocked.
            #expect(SheetWriteTool().assess(["path": "/Library/Glide/x.csv"], context: quick).risk == .high)
            #expect(SheetWriteTool().assess(["path": "~/Library/Keychains/x.csv"], context: quick).blocked != nil)
            #expect(SheetWriteTool().assess(["path": "/System/x.csv"], context: quick).blocked != nil)
        }
    }

    // MARK: HTML

    @Suite("HTML to text")
    struct HTML {
        @Test func extractsReadableTextFromFixturePage() throws {
            let page = HTMLText.extract(try fixture("article.html"), baseURL: URL(string: "https://example.test/guides/lakes.html"))
            #expect(page.title == "Field Guide to Alpine Lakes & Tarns | Example Outdoors")
            let t = page.text
            #expect(t.hasPrefix("# Alpine Lakes & Tarns"))
            #expect(t.contains("By Ana Ruiz · Updated 3\u{00A0}May\u{00A0}2026") || t.contains("By Ana Ruiz · Updated 3 May 2026"))
            #expect(t.contains("They’re cold, clear and often surrounded by steep cirques."))
            #expect(t.contains("## Best months to visit"))
            #expect(t.contains("larches turn gold — a favourite"))
            #expect(t.contains("- June: ice on the shore, snow on the trail"))
            #expect(t.contains("- July – August: wildflowers, warm afternoons"))
            #expect(t.contains("  - Watch for afternoon thunderstorms"))
            #expect(t.contains("### Elevation and temperature"))
            #expect(t.contains("Lake | Elevation (m) | July water °C"))
            #expect(t.contains("Crater Tarn | 2,645 | 6"))
            #expect(t.contains("  - layers\n  - water filter"))
            #expect(t.contains("Symbols: 5 < 7 > 3, café, 🏔️, © 2026 & more."))
            for marker in ["SCRIPT_TEXT", "NAV_LINK", "SIDEBAR_TEXT", "HIDDEN_TEXT", "INVISIBLE_TEXT", "FORM_BUTTON", "FOOTER_TEXT", "SVG_TEXT", "NOSCRIPT_TEXT", "OG title"] {
                #expect(!t.contains(marker), "leaked \(marker)")
            }
            #expect(!t.contains("\n\n\n"))
            let urls = page.links.map(\.url)
            #expect(urls.contains("https://example.test/guides/larches.html"))
            #expect(urls.contains("https://example.test/safety/cold-water"))
            #expect(urls.contains("https://maps.example.org/lakes?id=42"))
            #expect(!urls.contains { $0.hasPrefix("javascript") || $0.contains("#top") || $0.contains("/hikes") || $0.contains("/privacy") })
            #expect(page.links.first { $0.url.hasSuffix("cold-water") }?.text == "cold-water safety notes")
        }

        @Test func formWrappedPagesStillHaveText() {
            let body = String(repeating: "<p>Quarterly results were strong across every region we operate in.</p>", count: 40)
            let html = "<html><head><title>WebForms</title></head><body><form id=\"aspnetForm\"><div>\(body)</div></form></body></html>"
            let page = HTMLText.extract(html, baseURL: nil)
            #expect(page.text.contains("Quarterly results were strong"))
        }

        @Test func largePagesConvertInLinearTime() {
            let para = "<p>Lorem ipsum dolor sit amet, <a href=\"/x\">consectetur</a> adipiscing elit &amp; more.</p>\n"
            let html = "<html><body><main>" + String(repeating: para, count: 25_000) + "</main></body></html>"
            let start = Date()
            let page = HTMLText.extract(html, baseURL: URL(string: "https://x.test/"))
            #expect(Date().timeIntervalSince(start) < 15)
            #expect(page.text.count > 100_000)
            #expect(page.links.count == 1)
        }

        @Test func titleFallbacksAndLinkCap() {
            let links = (0..<100).map { "<a href=\"/p\($0)\">page \($0)</a>" }.joined(separator: " ")
            let page = HTMLText.extract("<h1>Heading Title</h1><p>\(links)</p>", baseURL: URL(string: "https://x.test/"))
            #expect(page.title == "Heading Title")
            #expect(page.links.count == 40)
            #expect(page.links.first?.url == "https://x.test/p0")
        }

        @Test func tokenizerSurvivesMalformedInput() {
            let inputs = ["<", "<a", "<a href=\"unterminated", "</", "<!", "<!--", "<![CDATA[x", "<a =\"x\">t</a>", "a < b > c", "&#xFFFFFFFF;&#0;&bogus;&amp",
                          "<script>never closed", "<div><<<>>></div>", "<p/><br/><img src=x>", String(repeating: "<b>", count: 5000),
                          String(repeating: "<!x>", count: 2000), "<a href='x'\u{0}>\u{0}</a>"]
            for s in inputs {
                let page = HTMLText.extract(s, baseURL: nil)
                #expect(page.text.count <= s.count + 10)
            }
            #expect(HTMLEntities.decode("&#150;&#x41;&lt;&notanentity;&amp") == "–A<&notanentity;&")
            #expect(HTMLText.extract("<a =\"x\">after</a>", baseURL: nil).text == "after")
        }
    }

    // MARK: Search parsing

    @Suite("DuckDuckGo parsing")
    struct Search {
        @Test func parsesFixtureResults() throws {
            let parsed = DuckDuckGoParser.parse(try fixture("ddg_results.html"), maxResults: 8)
            #expect(!parsed.challenged)
            #expect(parsed.results.count == 3)
            #expect(parsed.results[0] == WebSearchResult(title: "XMLParser | Apple Developer Documentation",
                                                         url: "https://developer.apple.com/documentation/foundation/xmlparser",
                                                         snippet: "An event driven parser of XML documents (including DTD declarations) that's used in conjunction with a delegate."))
            #expect(parsed.results[1].url == "https://www.hackingwithswift.com/example-code/system/how-to-parse-xml?sort=new&lang=en")
            #expect(parsed.results[1].title == "How to parse XML using XMLParser – Hacking with Swift")
            #expect(parsed.results[2].url == "https://swiftforums.example/t/streaming-xml/1234")
            #expect(!parsed.results.contains { $0.title.contains("Sponsored") || $0.snippet.contains("AD_SNIPPET") })
            #expect(DuckDuckGoParser.parse(try fixture("ddg_results.html"), maxResults: 2).results.count == 2)
        }

        @Test func detectsBotChecks() {
            let page = "<html><body><div class=\"anomaly-modal__title\">Unfortunately, bots use DuckDuckGo too.</div></body></html>"
            let parsed = DuckDuckGoParser.parse(page, maxResults: 8)
            #expect(parsed.results.isEmpty && parsed.challenged)
            #expect(DuckDuckGoParser.unwrap("//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.test%2Fx%3Fy%3D1&rut=z") == "https://a.test/x?y=1")
            #expect(DuckDuckGoParser.unwrap("https://duckduckgo.com/settings") == nil)
            #expect(DuckDuckGoParser.unwrap("javascript:alert(1)") == nil)
        }
    }

    // MARK: Fetching

    @Suite("Web fetch")
    struct Fetch {
        fileprivate static func server() async throws -> (TestHTTPServer, URL) {
            let article = try fixture("article.html")
            let ddg = try fixture("ddg_results.html")
            let pdf = makePDF("Glide PDF fixture text")
            let server = try TestHTTPServer { method, path, body in
                switch path {
                case "/page": return .init(body: Data(article.utf8))
                case "/json": return .init(headers: ["Content-Type": "application/json"], body: Data("{\"b\":[1,2],\"a\":{\"url\":\"http://x/y\"}}".utf8))
                case "/big": return .init(headers: ["Content-Type": "text/plain"], body: Data(repeating: 0x61, count: 6 << 20))
                case "/redirect": return .init(status: 302, headers: ["Location": "/page"])
                case "/missing": return .init(status: 404, body: Data("<html><title>Gone</title><body><p>Nothing here</p></body></html>".utf8))
                case "/latin1":
                    return .init(headers: ["Content-Type": "text/html; charset=iso-8859-1"],
                                 body: "<html><title>Caf\u{E9}</title><body><p>Cr\u{E8}me br\u{FB}l\u{E9}e</p></body></html>".data(using: .isoLatin1) ?? Data())
                case "/pdf": return .init(headers: ["Content-Type": "application/pdf"], body: pdf)
                case "/image": return .init(headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]))
                case "/slow": return .init(hang: true)
                case "/html/":
                    let form = String(decoding: body, as: UTF8.self)
                    guard method == "POST", form.contains("q=swift%20xmlparser%2B") else { return .init(status: 404) }
                    return .init(body: Data(ddg.utf8))
                case "/challenge/": return .init(status: 202, body: Data("<div class=\"anomaly-modal\">bots use DuckDuckGo too</div>".utf8))
                default: return .init(status: 404)
                }
            }
            return (server, try await server.start())
        }

        @Test func fetchesAndRendersContentTypes() async throws {
            let (server, base) = try await Self.server()
            defer { server.stop() }
            let ctx = context(FileManager.default.temporaryDirectory)
            let tool = WebFetchTool()

            let page = try await tool.run(["url": .string(base.absoluteString + "/page")], context: ctx)
            #expect(page.ok)
            #expect(page.data?["title"]?.stringValue == "Field Guide to Alpine Lakes & Tarns | Example Outdoors")
            #expect(page.text.contains("## Best months to visit"))
            #expect(page.text.contains("Links:\n- larch season → https://example.test/guides/larches.html"))
            #expect(page.data?["kind"]?.stringValue == "html")

            let json = try await tool.run(["url": .string(base.absoluteString + "/json")], context: ctx)
            #expect(json.data?["text"]?.stringValue?.contains("\"url\" : \"http://x/y\"") == true)

            let big = try await tool.run(["url": .string(base.absoluteString + "/big"), "max_chars": 500], context: ctx)
            #expect(big.ok && big.data?["truncated"]?.boolValue == true)
            #expect(big.text.count < 4000)

            let moved = try await tool.run(["url": .string(base.absoluteString + "/redirect")], context: ctx)
            #expect(moved.data?["url"]?.stringValue == "\(base.absoluteString)/page")

            let gone = try await tool.run(["url": .string(base.absoluteString + "/missing")], context: ctx)
            #expect(!gone.ok && gone.text.contains("HTTP 404") && gone.text.contains("Nothing here"))

            let latin = try await tool.run(["url": .string(base.absoluteString + "/latin1")], context: ctx)
            #expect(latin.data?["title"]?.stringValue == "Café")
            #expect(latin.text.contains("Crème brûlée"))

            let pdf = try await tool.run(["url": .string(base.absoluteString + "/pdf")], context: ctx)
            #expect(pdf.data?["kind"]?.stringValue == "pdf")
            #expect(pdf.text.contains("Glide PDF fixture text"))

            let image = try await tool.run(["url": .string(base.absoluteString + "/image")], context: ctx)
            #expect(image.text.contains("image/png") && image.text.contains("not a text document"))

            let refused = try await tool.run(["url": "file:///etc/passwd"], context: ctx)
            #expect(!refused.ok)
        }

        @Test func fetchManyKeepsOrderAndReportsFailures() async throws {
            let (server, base) = try await Self.server()
            defer { server.stop() }
            let ctx = context(FileManager.default.temporaryDirectory)
            let out = try await WebFetchManyTool().run(["urls": [.string(base.absoluteString + "/page"), "ftp://nope", .string(base.absoluteString + "/json")], "max_chars_each": 300], context: ctx)
            #expect(out.ok)
            let items = out.data?.arrayValue ?? []
            #expect(items.count == 3)
            #expect(items[0]["kind"]?.stringValue == "html")
            #expect(items[1]["error"] != nil)
            #expect(items[2]["kind"]?.stringValue == "json")
            #expect(out.text.contains("## [2] ftp://nope\nFailed:"))
        }

        @Test func stoppingTheGateCancelsAFetch() async throws {
            let (server, base) = try await Self.server()
            defer { server.stop() }
            let gate = ExecutionGate()
            let ctx = context(FileManager.default.temporaryDirectory, gate: gate)
            let url = "\(base.absoluteString)/slow"
            let task = Task { try await WebFetchTool().run(["url": .string(url)], context: ctx) }
            try await Task.sleep(for: .milliseconds(300))
            let stoppedAt = Date()
            gate.stop()
            await #expect(throws: AutomationError.self) { _ = try await task.value }
            #expect(Date().timeIntervalSince(stoppedAt) < 3)
        }

        @Test func searchThroughLocalEndpoint() async throws {
            let (server, base) = try await Self.server()
            defer { server.stop() }
            let ctx = context(FileManager.default.temporaryDirectory)
            let engine = DuckDuckGoSearch(endpoint: base.appendingPathComponent("html/"))
            let tool = WebTools.tools(search: engine).first { $0.spec.name == "web.search" }
            let out = try await #require(tool).run(["query": "swift xmlparser+", "max_results": 2], context: ctx)
            #expect(out.ok)
            #expect(out.data?["results"]?.arrayValue?.count == 2)
            #expect(out.text.hasPrefix("1. XMLParser | Apple Developer Documentation\n   https://developer.apple.com/documentation/foundation/xmlparser"))
            let challenged = DuckDuckGoSearch(endpoint: base.appendingPathComponent("challenge/"))
            await #expect(throws: WebError.self) { _ = try await challenged.search("x", maxResults: 3, gate: nil) }
        }

        @Test func urlRulesAndRisk() throws {
            let ctx = context(FileManager.default.temporaryDirectory)
            #expect(try WebFetcher.validate("example.com/a").absoluteString == "https://example.com/a")
            #expect(try WebFetcher.validate("localhost:8080/x").host == "localhost")
            #expect(throws: WebError.self) { try WebFetcher.validate("file:///etc/hosts") }
            #expect(throws: WebError.self) { try WebFetcher.validate("javascript:alert(1)") }
            #expect(throws: WebError.self) { try WebFetcher.validate("https://user:secret@example.com/") }
            #expect(WebFetchTool().assess(["url": "file:///etc/hosts"], context: ctx).blocked != nil)
            #expect(WebFetchTool().assess(["url": "data:text/html,hi"], context: ctx).blocked != nil)
            #expect(WebFetchTool().assess(["url": "https://example.com"], context: ctx).risk == .low)
            #expect(WebFetchTool().assess(["url": "http://192.168.1.1/admin"], context: ctx).risk == .medium)
            #expect(WebFetchManyTool().assess(["urls": ["https://a.test", "file:///x"]], context: ctx).blocked != nil)
            #expect(WebSearchTool(backend: nil).assess(["query": "x"], context: ctx).risk == .low)
            for local in ["localhost", "127.0.0.1", "127.1", "2130706433", "0x7f000001", "10.2.3.4", "172.20.0.1", "192.168.0.10", "169.254.169.254",
                          "::1", "[::1]", "fd00::1", "fe80::1", "::ffff:10.0.0.1", "printer.local", "router.lan", "0.0.0.0"] {
                #expect(WebFetcher.isLocalHost(local), "\(local) should be local")
            }
            for publicHost in ["example.com", "8.8.8.8", "172.32.0.1", "dead.be", "2001:4860:4860::8888", "fc.example.com"] {
                #expect(!WebFetcher.isLocalHost(publicHost), "\(publicHost) should be public")
            }
        }

        @Test func installRegistersWebTools() {
            WebTools.install()
            let specs = ToolRegistry.standard(settings: AppSettings()).specs(in: [.web])
            #expect(Set(specs.map(\.name)).isSuperset(of: ["web.fetch", "web.fetch_many", "web.search"]))
            #expect(specs.allSatisfy { $0.readOnly && !$0.needsScreen })
        }
    }
}
