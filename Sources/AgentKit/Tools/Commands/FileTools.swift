import Foundation
import AppKit
import PDFKit

// Direct file operations. Faster and more predictable than shell equivalents for the model,
// and each call is judged on the concrete path: reads are low (except private keys), changes
// in home or /tmp are medium, anything that replaces, trashes, or lands outside home is high.

// MARK: Trash

/// Moves items to the Trash. Production uses `NSWorkspace.recycle`, the same mechanism as
/// Finder, so "Put Back" works; tests inject a trasher that moves into a temporary folder so
/// they never touch the user's real Trash.
public struct FileTrasher: Sendable {
    public var trash: @Sendable (URL) async throws -> URL?

    public init(trash: @escaping @Sendable (URL) async throws -> URL?) {
        self.trash = trash
    }

    public static let system = FileTrasher { url in
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL?, Error>) in
            NSWorkspace.shared.recycle([url]) { map, error in
                guard once.claim() else { return }
                if let error { c.resume(throwing: error) } else { c.resume(returning: map[url]) }
            }
            // recycle reports back on the main queue; if that never runs (a headless process
            // without a main loop), fall back to FileManager after a while instead of hanging.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
                guard once.claim() else { return }
                do {
                    var result: NSURL?
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: &result) }
                    c.resume(returning: result as URL?)
                } catch { c.resume(throwing: error) }
            }
        }
    }
}

/// Lets exactly one of several racing callbacks resume a continuation.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

// MARK: Helpers

enum FileFormat {
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func date(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static func iso(_ d: Date?) -> JSONValue {
        guard let d else { return .null }
        return .string(ISO8601DateFormatter().string(from: d))
    }

    static func display(_ url: URL) -> String { PathRules.display(PathRules.normalize(url.path)) }
}

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Exists, counting broken symlinks (which `fileExists` reports as missing).
    func itemExists(_ url: URL) -> Bool {
        fileExists(atPath: url.path) || (try? attributesOfItem(atPath: url.path)) != nil
    }
}

/// When `to` names an existing folder (or ends with "/"), the item goes inside it.
func destination(for source: URL, to raw: String, _ context: ToolContext) throws -> URL {
    let to = try ToolArgs.path(raw, context)
    if raw.hasSuffix("/") || (FileManager.default.isDirectory(to) && to.standardizedFileURL != source.standardizedFileURL) {
        return to.appendingPathComponent(source.lastPathComponent)
    }
    return to
}

/// True when two URLs name the same file (e.g. a case-only rename on a case-insensitive disk).
func sameFile(_ a: URL, _ b: URL) -> Bool {
    guard let x = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
          let y = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
    return x.isEqual(y)
}

// MARK: fs.list

struct FSListTool: AgentTool {
    static let defaultMax = 200
    static let maxEntries = 2000
    /// Upper bound on entries visited during a recursive walk, so listing `~` recursively
    /// can't take minutes.
    static let visitLimit = 50_000

    let spec = ToolSpec(
        name: "fs.list",
        summary: "List a folder: names, sizes and modification dates. Optional glob pattern (e.g. *.pdf) and recursion. Hidden files appear only when the pattern starts with a dot.",
        inputSchema: ToolArgs.object([
            ("path", Schema.string("Folder (or file) to list; ~ is your home folder.")),
            ("pattern", Schema.string("Optional glob on the file name, e.g. *.csv (case-insensitive).")),
            ("recursive", Schema.boolean("Include subfolders (default false).")),
            ("max", Schema.integer("Maximum entries to return (default 200, max 2000).")),
        ], required: ["path"]),
        category: .files, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        var reasons: [String] = []
        var risk = RiskLevel.low
        let url = ToolArgs.pathForAssessment(arguments.optionalString("path"), context)
        if let url { risk = FileRisk.read(url, reasons: &reasons) }
        return CommandFamilyGate.files.apply(ToolVerdict(risk: risk, reasons: reasons, summary: "List \(url.map(FileFormat.display) ?? "a folder")"), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try ToolArgs.path(try arguments.requiredString("path"), context)
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        let pattern = arguments.optionalString("pattern")
        let recursive = arguments.optionalBool("recursive") ?? false
        let max = ToolArgs.count(arguments, "max", default: Self.defaultMax, max: Self.maxEntries)
        let fm = FileManager.default
        guard fm.itemExists(url) else { return .failure("Nothing exists at \(FileFormat.display(url)).") }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isPackageKey]
        let showHidden = pattern?.hasPrefix(".") ?? false
        var entries: [(rel: String, url: URL)] = []
        var visited = 0
        var hitVisitLimit = false

        if !fm.isDirectory(url) {
            entries = [(url.lastPathComponent, url)]
        } else if recursive {
            let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: opts, errorHandler: { _, _ in true }) else {
                return .failure("Couldn't read the folder \(FileFormat.display(url)).")
            }
            let basePath = url.standardizedFileURL.path
            while let item = e.nextObject() as? URL {
                visited += 1
                if visited % 500 == 0 { try context.gate.checkStopped() }
                if visited > Self.visitLimit { hitVisitLimit = true; break }
                if item.lastPathComponent == ".DS_Store" { continue }
                guard Self.matches(item.lastPathComponent, pattern) else { continue }
                var rel = item.standardizedFileURL.path
                if rel.hasPrefix(basePath + "/") { rel = String(rel.dropFirst(basePath.count + 1)) }
                entries.append((rel, item))
                if entries.count > max { break }
            }
        } else {
            let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            let items: [URL]
            do { items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: opts) }
            catch { return .failure("Couldn't read the folder \(FileFormat.display(url)): \(error.localizedDescription)") }
            entries = items.filter { $0.lastPathComponent != ".DS_Store" && Self.matches($0.lastPathComponent, pattern) }
                .map { ($0.lastPathComponent, $0) }
                .sorted { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
        }

        let more = entries.count > max
        let shown = Array(entries.prefix(max))
        var lines: [String] = []
        var rows: [JSONValue] = []
        for (rel, item) in shown {
            let v = try? item.resourceValues(forKeys: Set(keys))
            let isLink = v?.isSymbolicLink ?? false
            let isDir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            let size = Int64(v?.fileSize ?? 0)
            let type = isLink ? "link" : (isDir ? "folder" : ((v?.isPackage ?? false) ? "package" : "file"))
            let modified = v?.contentModificationDate
            lines.append(isDir ? "\(rel)/  \(FileFormat.date(modified))" : "\(rel)  \(FileFormat.size(size))  \(FileFormat.date(modified))")
            rows.append(["name": .string(rel), "path": .string(item.path), "type": .string(type),
                         "size": isDir ? .null : .number(Double(size)), "modified": FileFormat.iso(modified)])
        }
        var text = shown.isEmpty ? "No matching items in \(FileFormat.display(url))." : "\(FileFormat.display(url)) — \(shown.count) item\(shown.count == 1 ? "" : "s"):\n" + lines.joined(separator: "\n")
        if more { text += "\n…more items not shown (raise max, or narrow with pattern)" }
        if hitVisitLimit { text += "\n…stopped after looking at \(Self.visitLimit) items; list a smaller folder" }
        return ToolOutput(ok: true, text: toolTruncate(text), data: .array(rows))
    }

    static func matches(_ name: String, _ pattern: String?) -> Bool {
        guard let pattern, !pattern.isEmpty else { return true }
        return fnmatch(pattern, name, FNM_CASEFOLD) == 0
    }
}

// MARK: fs.read

struct FSReadTool: AgentTool {
    static let defaultMaxChars = 8000
    static let maxChars = 100_000
    /// Bytes read from disk at most, so a multi-gigabyte log can't be loaded whole.
    static let maxBytes = 8 << 20

    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "bmp", "webp", "ico", "icns", "psd", "zip", "gz", "tgz", "bz2", "xz", "7z", "rar",
        "dmg", "iso", "pkg", "app", "exe", "dll", "dylib", "so", "o", "a", "class", "jar", "mp3", "m4a", "wav", "aac", "flac", "mp4", "mov",
        "m4v", "avi", "mkv", "sqlite", "db", "keychain", "keychain-db", "xlsx", "xls", "pptx", "ppt", "numbers", "pages", "key", "woff", "woff2", "ttf", "otf",
    ]
    static let richTextExtensions: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "wordml"]

    let spec = ToolSpec(
        name: "fs.read",
        summary: "Read a text file (code, notes, CSV, JSON, logs), a PDF's text, or an RTF/Word document's text. Refuses images and other binaries.",
        inputSchema: ToolArgs.object([
            ("path", Schema.string("File to read; ~ is your home folder.")),
            ("max_chars", Schema.integer("Maximum characters to return (default 8000, max 100000).")),
        ], required: ["path"]),
        category: .files, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        var reasons: [String] = []
        var risk = RiskLevel.low
        let url = ToolArgs.pathForAssessment(arguments.optionalString("path"), context)
        if let url { risk = FileRisk.read(url, reasons: &reasons) }
        return CommandFamilyGate.files.apply(ToolVerdict(risk: risk, reasons: reasons, summary: "Read \(url.map(FileFormat.display) ?? "a file")"), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try ToolArgs.path(try arguments.requiredString("path"), context)
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        let maxChars = ToolArgs.count(arguments, "max_chars", default: Self.defaultMaxChars, max: Self.maxChars)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .failure("There's no file at \(FileFormat.display(url)).") }
        let ext = url.pathExtension.lowercased()
        if fm.isDirectory(url), ext != "rtfd" {
            return .failure("\(FileFormat.display(url)) is a folder. Use fs.list to see what's in it.")
        }
        // stat follows symlinks. Only regular files: opening a FIFO or a device would block or
        // stream forever.
        var st = stat()
        guard stat(url.path, &st) == 0 else { return .failure("Couldn't read \(FileFormat.display(url)): \(String(cString: strerror(errno)))") }
        let isRegular = (st.st_mode & S_IFMT) == S_IFREG
        if !isRegular && ext != "rtfd" {
            return .failure("\(FileFormat.display(url)) isn't a regular file (it's a device, pipe or socket), so it can't be read as text.")
        }
        let size = Int64(st.st_size)

        let text: String
        var total: Int?
        var extra: [String: JSONValue] = [:]
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { return .failure("Couldn't open \(FileFormat.display(url)) as a PDF; it may be damaged.") }
            if doc.isLocked { return .failure("\(FileFormat.display(url)) is password-protected.") }
            let s = doc.string ?? ""
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .failure("\(FileFormat.display(url)) has no text layer (it's probably scanned images).")
            }
            text = s
            total = s.count
            extra["pages"] = .number(Double(doc.pageCount))
        } else if Self.richTextExtensions.contains(ext) {
            do {
                let a = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
                text = a.string
                total = text.count
            } catch {
                return .failure("Couldn't read \(FileFormat.display(url)) as a document: \(error.localizedDescription)")
            }
        } else {
            if Self.binaryExtensions.contains(ext) {
                return .failure("\(FileFormat.display(url)) is a binary file (\(ext), \(FileFormat.size(size))). fs.read only reads text, PDFs and RTF/Word documents.")
            }
            let budget = min(Self.maxBytes, max(maxChars * 4 + 16, 65_536))
            let data: Data
            do {
                let h = try FileHandle(forReadingFrom: url)
                defer { try? h.close() }
                data = try h.read(upToCount: budget) ?? Data()
            } catch {
                return .failure("Couldn't read \(FileFormat.display(url)): \(error.localizedDescription)")
            }
            if data.prefix(8192).contains(0) && !Self.looksUTF16(data) {
                return .failure("\(FileFormat.display(url)) looks like a binary file (\(FileFormat.size(size))). fs.read only reads text, PDFs and RTF/Word documents.")
            }
            let complete = Int64(data.count) >= size
            text = Self.decode(data, complete: complete)
            if complete { total = text.count }
        }

        // `total` is nil when only the start of a large file was read from disk.
        let truncated = text.count > maxChars || total == nil
        var shown = String(text.prefix(maxChars))
        if truncated {
            let of = total.map { "\($0) characters" } ?? "a \(FileFormat.size(size)) file"
            shown += "\n…[showing the first \(min(text.count, maxChars)) characters of \(of); raise max_chars to see more]"
        }
        var data: [String: JSONValue] = ["path": .string(url.path), "chars": .number(Double(min(text.count, maxChars))),
                                         "truncated": .bool(truncated), "size_bytes": .number(Double(size))]
        data.merge(extra) { $1 }
        return ToolOutput(ok: true, text: shown.isEmpty ? "(the file is empty)" : shown, data: .object(data))
    }

    static func looksUTF16(_ d: Data) -> Bool {
        d.count >= 2 && ((d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xFE) || (d[d.startIndex] == 0xFE && d[d.startIndex + 1] == 0xFF))
    }

    /// UTF-8 when valid (ignoring a multibyte character cut off at the end of a partial read),
    /// UTF-16 with a BOM, otherwise Windows-1252, which never fails and is the usual legacy
    /// encoding for stray text files.
    static func decode(_ data: Data, complete: Bool) -> String {
        if looksUTF16(data), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if !complete {
            for cut in 1...3 where data.count > cut {
                if let s = String(data: data.dropLast(cut), encoding: .utf8) { return s }
            }
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}

// MARK: fs.write

struct FSWriteTool: AgentTool {
    enum Mode: String { case create, overwrite, append }

    let spec = ToolSpec(
        name: "fs.write",
        summary: "Write text to a file. mode create (default; fails if it exists), overwrite (replaces it), or append. Creates missing parent folders.",
        inputSchema: ToolArgs.object([
            ("path", Schema.string("File to write; ~ is your home folder, relative paths are in the job folder.")),
            ("content", Schema.string("The text to write.")),
            ("mode", Schema.string("create | overwrite | append (default create).", enum: ["create", "overwrite", "append"])),
        ], required: ["path", "content"]),
        category: .files)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let mode = Mode(rawValue: arguments.optionalString("mode") ?? "create") ?? .create
        var reasons: [String] = []
        var risk = RiskLevel.medium
        let url = ToolArgs.pathForAssessment(arguments.optionalString("path"), context)
        if let url { risk = max(risk, FileRisk.write(url, reasons: &reasons)) }
        if mode == .overwrite {
            risk = .high
            reasons.append("overwrites \(url.map(FileFormat.display) ?? "a file")")
        }
        let verb = ["create": "Create", "overwrite": "Overwrite", "append": "Append to"][mode.rawValue] ?? "Write"
        return CommandFamilyGate.files.apply(ToolVerdict(risk: risk, reasons: reasons, summary: "\(verb) \(url.map(FileFormat.display) ?? "a file")"), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try ToolArgs.path(try arguments.requiredString("path"), context)
        guard let content = arguments["content"]?.stringValue else { throw ToolError.invalidArguments("missing “content”") }
        guard let mode = Mode(rawValue: arguments.optionalString("mode") ?? "create") else {
            throw ToolError.invalidArguments("mode must be create, overwrite or append")
        }
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        try context.gate.checkStopped()
        let fm = FileManager.default
        if fm.isDirectory(url) { return .failure("\(FileFormat.display(url)) is a folder, not a file.") }
        let data = Data(content.utf8)
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch mode {
            case .create:
                if fm.itemExists(url) {
                    return .failure("\(FileFormat.display(url)) already exists. Use mode overwrite to replace it, or append to add to it.")
                }
                try data.write(to: url, options: .withoutOverwriting)
            case .overwrite:
                try data.write(to: url, options: .atomic)
            case .append:
                if fm.fileExists(atPath: url.path) {
                    let h = try FileHandle(forWritingTo: url)
                    defer { try? h.close() }
                    try h.seekToEnd()
                    try h.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .withoutOverwriting)
                }
            }
        } catch {
            return .failure("Couldn't write \(FileFormat.display(url)): \(error.localizedDescription)")
        }
        let verb = mode == .append ? "Appended" : "Wrote"
        return ToolOutput(ok: true, text: "\(verb) \(FileFormat.size(Int64(data.count))) to \(FileFormat.display(url)).",
                          data: ["path": .string(url.path), "bytes": .number(Double(data.count))], artifacts: [url])
    }
}

// MARK: fs.move / fs.copy

struct FSMoveTool: AgentTool {
    let trasher: FileTrasher

    init(trasher: FileTrasher = .system) { self.trasher = trasher }

    let spec = ToolSpec(
        name: "fs.move",
        summary: "Move or rename a file or folder. If `to` is an existing folder the item goes inside it. overwrite: true replaces an existing target (the old one goes to the Trash).",
        inputSchema: ToolArgs.object([
            ("from", Schema.string("Existing file or folder.")),
            ("to", Schema.string("New path, or an existing folder to move into.")),
            ("overwrite", Schema.boolean("Replace an existing item at the target (default false).")),
        ], required: ["from", "to"]),
        category: .files)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        var reasons: [String] = []
        var risk = RiskLevel.medium
        let from = ToolArgs.pathForAssessment(arguments.optionalString("from"), context)
        let to = ToolArgs.pathForAssessment(arguments.optionalString("to"), context)
        // Moving takes the item away from where it was, so both ends count as changes.
        if let from {
            risk = max(risk, FileRisk.write(from, reasons: &reasons))
            let p = FileRisk.resolved(from)
            if PathRules.isCriticalTree(p) { risk = .high; reasons.append("moves \(PathRules.display(p)), a system or account folder") }
        }
        if let to { risk = max(risk, FileRisk.write(to, reasons: &reasons)) }
        if arguments.optionalBool("overwrite") == true {
            risk = .high
            reasons.append("replaces \(to.map(FileFormat.display) ?? "the target") if it exists")
        }
        let summary = "Move \(from.map(FileFormat.display) ?? "a file") to \(to.map(FileFormat.display) ?? "another place")"
        return CommandFamilyGate.files.apply(ToolVerdict(risk: risk, reasons: reasons, summary: summary), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let from = try ToolArgs.path(try arguments.requiredString("from"), context)
        let to = try destination(for: from, to: try arguments.requiredString("to"), context)
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        try context.gate.checkStopped()
        let fm = FileManager.default
        guard fm.itemExists(from) else { return .failure("There's nothing at \(FileFormat.display(from)) to move.") }
        if from.standardizedFileURL.path == to.standardizedFileURL.path { return ToolOutput(ok: true, text: "\(FileFormat.display(from)) is already there.") }
        let isRename = sameFile(from, to) // case-only rename on a case-insensitive disk
        do {
            if !isRename, fm.itemExists(to) {
                guard arguments.optionalBool("overwrite") == true else {
                    return .failure("\(FileFormat.display(to)) already exists. Pass overwrite: true to replace it (the old one goes to the Trash).")
                }
                _ = try await trasher.trash(to)
            }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: from, to: to)
        } catch {
            return .failure("Couldn't move \(FileFormat.display(from)): \(error.localizedDescription)")
        }
        return ToolOutput(ok: true, text: "Moved \(FileFormat.display(from)) to \(FileFormat.display(to)).",
                          data: ["from": .string(from.path), "to": .string(to.path)], artifacts: [to])
    }
}

struct FSCopyTool: AgentTool {
    let spec = ToolSpec(
        name: "fs.copy",
        summary: "Copy a file or folder. If `to` is an existing folder the copy goes inside it. Fails if the target exists.",
        inputSchema: ToolArgs.object([
            ("from", Schema.string("Existing file or folder.")),
            ("to", Schema.string("New path, or an existing folder to copy into.")),
        ], required: ["from", "to"]),
        category: .files)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        var reasons: [String] = []
        var risk = RiskLevel.medium
        let from = ToolArgs.pathForAssessment(arguments.optionalString("from"), context)
        let to = ToolArgs.pathForAssessment(arguments.optionalString("to"), context)
        if let from { risk = max(risk, FileRisk.read(from, reasons: &reasons)) }
        if let to { risk = max(risk, FileRisk.write(to, reasons: &reasons)) }
        let summary = "Copy \(from.map(FileFormat.display) ?? "a file") to \(to.map(FileFormat.display) ?? "another place")"
        return CommandFamilyGate.files.apply(ToolVerdict(risk: risk, reasons: reasons, summary: summary), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let from = try ToolArgs.path(try arguments.requiredString("from"), context)
        let to = try destination(for: from, to: try arguments.requiredString("to"), context)
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        try context.gate.checkStopped()
        let fm = FileManager.default
        guard fm.itemExists(from) else { return .failure("There's nothing at \(FileFormat.display(from)) to copy.") }
        if fm.itemExists(to) { return .failure("\(FileFormat.display(to)) already exists. Pick another name, or move it out of the way first.") }
        if fm.isDirectory(from), PathRules.isInside(to.standardizedFileURL.path, from.standardizedFileURL.path) {
            return .failure("Can't copy a folder into itself.")
        }
        do {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
        } catch {
            return .failure("Couldn't copy \(FileFormat.display(from)): \(error.localizedDescription)")
        }
        return ToolOutput(ok: true, text: "Copied \(FileFormat.display(from)) to \(FileFormat.display(to)).",
                          data: ["from": .string(from.path), "to": .string(to.path)], artifacts: [to])
    }
}

// MARK: fs.mkdir

struct FSMkdirTool: AgentTool {
    let spec = ToolSpec(
        name: "fs.mkdir",
        summary: "Create a folder (and any missing parent folders).",
        inputSchema: ToolArgs.object([("path", Schema.string("Folder to create."))], required: ["path"]),
        category: .files)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        var reasons: [String] = []
        var risk = RiskLevel.medium
        let url = ToolArgs.pathForAssessment(arguments.optionalString("path"), context)
        if let url { risk = max(risk, FileRisk.write(url, reasons: &reasons)) }
        return CommandFamilyGate.files.apply(ToolVerdict(risk: risk, reasons: reasons, summary: "Create the folder \(url.map(FileFormat.display) ?? "")"), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try ToolArgs.path(try arguments.requiredString("path"), context)
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        let fm = FileManager.default
        if fm.isDirectory(url) { return ToolOutput(ok: true, text: "\(FileFormat.display(url)) already exists.", data: ["path": .string(url.path)]) }
        if fm.itemExists(url) { return .failure("\(FileFormat.display(url)) exists and is a file, not a folder.") }
        do { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { return .failure("Couldn't create \(FileFormat.display(url)): \(error.localizedDescription)") }
        return ToolOutput(ok: true, text: "Created \(FileFormat.display(url)).", data: ["path": .string(url.path)], artifacts: [url])
    }
}

// MARK: fs.trash

struct FSTrashTool: AgentTool {
    let trasher: FileTrasher

    init(trasher: FileTrasher = .system) { self.trasher = trasher }

    let spec = ToolSpec(
        name: "fs.trash",
        summary: "Move a file or folder to the Trash (recoverable with Put Back). Always asks for approval.",
        inputSchema: ToolArgs.object([("path", Schema.string("File or folder to move to the Trash."))], required: ["path"]),
        category: .files)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let url = ToolArgs.pathForAssessment(arguments.optionalString("path"), context)
        var v = ToolVerdict(risk: .high, reasons: ["moves \(url.map(FileFormat.display) ?? "a file") to the Trash"],
                            summary: "Move \(url.map(FileFormat.display) ?? "a file") to the Trash")
        if let url {
            let p = FileRisk.resolved(url)
            if PathRules.isCriticalTree(p) || PathRules.isProtectedFromDeletion(p) {
                v.blocked = "Glide won't move \(PathRules.display(p)) to the Trash; it's a system or account folder."
            } else {
                var r: [String] = []
                _ = FileRisk.write(url, reasons: &r)
                v.reasons += r
            }
        }
        return CommandFamilyGate.files.apply(v, context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let url = try ToolArgs.path(try arguments.requiredString("path"), context)
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        try context.gate.checkStopped()
        guard FileManager.default.itemExists(url) else { return .failure("There's nothing at \(FileFormat.display(url)).") }
        let result: URL?
        do { result = try await trasher.trash(url) }
        catch { return .failure("Couldn't move \(FileFormat.display(url)) to the Trash: \(error.localizedDescription)") }
        var data: [String: JSONValue] = ["path": .string(url.path)]
        if let result { data["trashed_to"] = .string(result.path) }
        return ToolOutput(ok: true, text: "Moved \(FileFormat.display(url)) to the Trash (it can be put back from there).", data: .object(data))
    }
}

// MARK: fs.search

struct FSSearchTool: AgentTool {
    static let defaultMax = 50
    static let maxResults = 500

    let spec = ToolSpec(
        name: "fs.search",
        summary: "Find files with Spotlight (mdfind): by name or content words, or a Spotlight query like kMDItemContentType == 'com.adobe.pdf'. Optionally only inside a folder.",
        inputSchema: ToolArgs.object([
            ("query", Schema.string("Words to find, or a Spotlight query.")),
            ("folder", Schema.string("Only search inside this folder.")),
            ("max", Schema.integer("Maximum results (default 50, max 500).")),
        ], required: ["query"]),
        category: .files, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let q = arguments.optionalString("query") ?? ""
        let folder = ToolArgs.pathForAssessment(arguments.optionalString("folder"), context)
        let summary = "Search for “\(q.prefix(80))”" + (folder.map { " in \(FileFormat.display($0))" } ?? "")
        return CommandFamilyGate.files.apply(ToolVerdict(risk: .low, summary: summary), context.settings.tools)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        var query = try arguments.requiredString("query")
        try CommandFamilyGate.enforce(assess(arguments, context: context))
        let max = ToolArgs.count(arguments, "max", default: Self.defaultMax, max: Self.maxResults)
        // A leading "-" would be read as an option; a leading space keeps it a query.
        if query.hasPrefix("-") { query = " " + query }
        var args = ["-0"]
        if let f = arguments.optionalString("folder") {
            let url = try ToolArgs.path(f, context)
            guard FileManager.default.isDirectory(url) else { return .failure("\(FileFormat.display(url)) isn't a folder.") }
            args += ["-onlyin", url.path]
        }
        args.append(query)
        let r = try await ProcessRunner.run(executable: "/usr/bin/mdfind", arguments: args, timeout: 30, gate: context.gate)
        if r.stopped { throw AutomationError.stopped }
        guard r.exitCode == 0, !r.timedOut else { return CommandOutput.format(r, timeout: 30, what: "The Spotlight search") }
        let paths = r.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
        let shown = Array(paths.prefix(max))
        var text = shown.isEmpty ? "No files found for “\(query.trimmingCharacters(in: .whitespaces))”." : "\(paths.count) result\(paths.count == 1 ? "" : "s"):\n" + shown.map { PathRules.display($0) }.joined(separator: "\n")
        if paths.count > shown.count { text += "\n…\(paths.count - shown.count) more not shown" }
        return ToolOutput(ok: true, text: toolTruncate(text), data: .array(shown.map { .string($0) }), durationMs: r.durationMs)
    }
}
