import Foundation

/// Tools for a job's memory: facts, result tables and files in the job folder. They let the
/// step model save what it finds as it goes (so later steps and the final report can use it
/// without re-reading anything) and look things up again.
///
/// All of them only touch the current job's own store and folder, so they're low risk.
public enum WorkspaceTools {
    /// Registers the family with the standard registry. Call once at launch.
    public static func install() {
        ToolRegistry.registerFactory("workspace") { _ in all }
    }

    public static var all: [any AgentTool] {
        [WorkspaceRememberTool(), WorkspaceRecallTool(), WorkspaceSaveRowTool(), WorkspaceRowsTool(), WorkspaceWriteFileTool(), WorkspaceReadFileTool()]
    }

    /// The current job's workspace, or a clear error when the step isn't part of a job.
    static func workspace(_ context: ToolContext) throws -> any JobWorkspace {
        guard let ws = context.workspace else {
            throw ToolError.unavailable("The workspace tools only work inside a background job; this step isn't part of one.")
        }
        return ws
    }

    static let maxFileBytes = 5 * 1024 * 1024

    /// Resolves `name` inside the job folder, refusing anything that would land outside it
    /// (absolute paths, `..`, symlinks pointing elsewhere).
    static func resolve(_ name: String, in folder: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.invalidArguments("missing “name”") }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw ToolError.invalidArguments("“name” must be a file name inside the job folder, not a path like \(trimmed)")
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else {
            throw ToolError.invalidArguments("“name” can't contain “..” or “.”; use a plain file name inside the job folder")
        }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        // Walk the path one component at a time and refuse symlinks: a link inside the job
        // folder (made by a shell step, say) could otherwise point a write anywhere.
        var url = root
        let fm = FileManager.default
        for part in parts {
            url.appendPathComponent(String(part))
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ToolError.blocked("\(trimmed) goes through a symbolic link; only plain files inside the job folder can be used.")
            }
        }
        guard url.path.hasPrefix(root.path + "/") else { throw ToolError.blocked("That file would be outside the job folder.") }
        return url
    }

    static func verdict(_ summary: String) -> ToolVerdict { ToolVerdict(risk: .low, summary: summary) }
}

struct WorkspaceRememberTool: AgentTool {
    let spec = ToolSpec(
        name: "workspace.remember",
        summary: "Save a fact for later steps of this job (key → value). Use it for anything you'll need again: IDs, decisions, findings.",
        inputSchema: Schema.object([
            ("key", Schema.string("Short unique name, e.g. 'pricing_page_url'.")),
            ("value", Schema.string("The fact itself.")),
        ]),
        category: .workspace)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        WorkspaceTools.verdict("Remember “\(arguments["key"]?.stringValue ?? "")”")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let ws = try WorkspaceTools.workspace(context)
        let key = try arguments.requiredString("key")
        guard let value = arguments["value"]?.stringValue else { throw ToolError.invalidArguments("missing “value”") }
        await ws.setFact(key, value)
        return ToolOutput(ok: true, text: "Remembered “\(key)”.")
    }
}

struct WorkspaceRecallTool: AgentTool {
    let spec = ToolSpec(
        name: "workspace.recall",
        summary: "Look up facts saved earlier in this job, by keywords (or the most recent ones).",
        inputSchema: Schema.object([
            ("query", Schema.nullableString("Keywords to match, or null for the most recent facts.")),
            ("limit", Schema.number("How many facts (default 10, max 50).", nullable: true)),
        ]),
        category: .workspace, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        WorkspaceTools.verdict("Recall facts" + (arguments.optionalString("query").map { " about “\($0)”" } ?? ""))
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let ws = try WorkspaceTools.workspace(context)
        let limit = min(50, max(1, arguments.optionalInt("limit") ?? 10))
        let facts = await ws.facts(matching: arguments.optionalString("query"), limit: limit)
        guard !facts.isEmpty else { return ToolOutput(ok: true, text: "No matching facts.", data: .array([])) }
        let text = facts.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
        return ToolOutput(ok: true, text: toolTruncate(text),
                          data: .array(facts.map { .object(["key": .string($0.key), "value": .string($0.value)]) }))
    }
}

struct WorkspaceSaveRowTool: AgentTool {
    let spec = ToolSpec(
        name: "workspace.save_row",
        summary: "Save or update a row in one of this job's result tables (the same key replaces the row).",
        inputSchema: Schema.object([
            ("table", Schema.string("Table name, e.g. 'companies'.")),
            ("key", Schema.string("Unique row key, e.g. the company name.")),
            // A free-form object: any field names. (Tool arguments are written by the model as a
            // JSON string, so this schema is a guide rather than a strict contract.)
            ("fields", .object(["type": "object", "description": "The row's fields, e.g. {\"website\":\"https://…\",\"employees\":120}."])),
        ]),
        category: .workspace)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        WorkspaceTools.verdict("Save row “\(arguments["key"]?.stringValue ?? "")” in \(arguments["table"]?.stringValue ?? "a table")")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let ws = try WorkspaceTools.workspace(context)
        let table = try arguments.requiredString("table")
        let key = try arguments.requiredString("key")
        // Accept the fields as an object (lenient callers) or as a JSON string (strict schema).
        let fields: [String: JSONValue]
        if let obj = arguments["fields"]?.objectValue ?? arguments["fields_json"]?.objectValue {
            fields = obj
        } else if let s = arguments["fields_json"]?.stringValue ?? arguments["fields"]?.stringValue,
                  let obj = JSONValue.extractObject(from: s)?.objectValue {
            fields = obj
        } else {
            throw ToolError.invalidArguments("“fields” must be a JSON object")
        }
        await ws.upsertRow(table: table, key: key, fields: fields)
        return ToolOutput(ok: true, text: "Saved “\(key)” in \(table).")
    }
}

struct WorkspaceRowsTool: AgentTool {
    let spec = ToolSpec(
        name: "workspace.rows",
        summary: "Read rows from one of this job's result tables.",
        inputSchema: Schema.object([
            ("table", Schema.string("Table name.")),
            ("limit", Schema.number("Maximum rows (default 50, max 500).", nullable: true)),
        ]),
        category: .workspace, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        WorkspaceTools.verdict("Read rows of \(arguments["table"]?.stringValue ?? "a table")")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let ws = try WorkspaceTools.workspace(context)
        let table = try arguments.requiredString("table")
        let limit = min(500, max(1, arguments.optionalInt("limit") ?? 50))
        let rows = await ws.rows(table: table, limit: limit)
        guard !rows.isEmpty else {
            let names = await ws.tableNames()
            return ToolOutput(ok: true, text: "No rows in “\(table)”." + (names.isEmpty ? "" : " Tables: \(names.joined(separator: ", "))."), data: .array([]))
        }
        let data = JSONValue.array(rows.map { .object(["key": .string($0.key), "fields": .object($0.fields)]) })
        let text = rows.map { "\($0.key): \(JSONValue.object($0.fields).jsonString())" }.joined(separator: "\n")
        return ToolOutput(ok: true, text: toolTruncate("\(rows.count) row\(rows.count == 1 ? "" : "s") of \(table):\n" + text), data: data)
    }
}

struct WorkspaceWriteFileTool: AgentTool {
    let spec = ToolSpec(
        name: "workspace.write_file",
        summary: "Write a text file in this job's folder (drafts, notes, exports). Replaces a file with the same name.",
        inputSchema: Schema.object([
            ("name", Schema.string("File name inside the job folder, e.g. 'draft.md' or 'notes/acme.txt'.")),
            ("content", Schema.string("The file's full text.")),
        ]),
        category: .workspace)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        WorkspaceTools.verdict("Write \(arguments["name"]?.stringValue ?? "a file") in the job folder")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let ws = try WorkspaceTools.workspace(context)
        let name = try arguments.requiredString("name")
        guard let content = arguments["content"]?.stringValue else { throw ToolError.invalidArguments("missing “content”") }
        let data = Data(content.utf8)
        guard data.count <= WorkspaceTools.maxFileBytes else {
            throw ToolError.invalidArguments("the content is \(data.count / 1024) KB; the limit is \(WorkspaceTools.maxFileBytes / 1024 / 1024) MB")
        }
        try FileManager.default.createDirectory(at: ws.folder, withIntermediateDirectories: true)
        let url = try WorkspaceTools.resolve(name, in: ws.folder)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return .failure("Couldn't write \(name): \(error.localizedDescription)")
        }
        return ToolOutput(ok: true, text: "Wrote \(name) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))).", artifacts: [url])
    }
}

struct WorkspaceReadFileTool: AgentTool {
    let spec = ToolSpec(
        name: "workspace.read_file",
        summary: "Read a text file from this job's folder.",
        inputSchema: Schema.object([
            ("name", Schema.string("File name inside the job folder.")),
        ]),
        category: .workspace, readOnly: true)

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        WorkspaceTools.verdict("Read \(arguments["name"]?.stringValue ?? "a file") from the job folder")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let ws = try WorkspaceTools.workspace(context)
        let name = try arguments.requiredString("name")
        let url = try WorkspaceTools.resolve(name, in: ws.folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            let files = SQLiteJobWorkspace.listFiles(in: ws.folder, max: 20)
            return .failure("There's no file named \(name) in the job folder." + (files.isEmpty ? "" : " Files: \(files.joined(separator: ", "))."))
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= WorkspaceTools.maxFileBytes else { return .failure("\(name) is too large to read (\(size / 1024) KB).") }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return .failure("\(name) isn't a text file.")
        }
        return ToolOutput(ok: true, text: toolTruncate(text), data: .string(String(text.prefix(200_000))))
    }
}
