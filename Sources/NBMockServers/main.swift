import Foundation
import Network

// Test doubles, used only by tests and benchmarks:
//   nb-mock-servers mcp          a stdio MCP server with `echo` and `add` tools
//   nb-mock-servers llm [port]   a scripted OpenAI-compatible endpoint that drives the
//                                NB Fixture "greet" task deterministically, so the whole
//                                agent loop (plan → act → verify) runs against real UI
//                                without a paid model. It reads the same compact UI list a
//                                real model gets and answers by matching labels.

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func json(_ obj: Any) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
}

// MARK: - MCP (stdio)

func runMCP() {
    while let line = readLine() {
        guard let data = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        guard let id = msg["id"] else { continue } // notification
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        var result: Any = [:]
        switch method {
        case "initialize":
            result = ["protocolVersion": "2025-06-18", "capabilities": ["tools": [:]], "serverInfo": ["name": "nb-mock", "version": "1.0"]]
        case "tools/list":
            result = ["tools": [
                ["name": "echo", "description": "Echo back the given text.", "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]],
                ["name": "add", "description": "Add two numbers.", "inputSchema": ["type": "object", "properties": ["a": ["type": "number"], "b": ["type": "number"]], "required": ["a", "b"]]],
            ]]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let a = params["arguments"] as? [String: Any] ?? [:]
            if name == "echo" {
                result = ["content": [["type": "text", "text": "echo: \(a["text"] ?? "")"]]]
            } else if name == "add" {
                let sum = ((a["a"] as? Double) ?? 0) + ((a["b"] as? Double) ?? 0)
                result = ["content": [["type": "text", "text": "\(sum)"]]]
            } else {
                print(json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown tool"]]))
                continue
            }
        default:
            print(json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]]))
            continue
        }
        print(json(["jsonrpc": "2.0", "id": id, "result": result]))
    }
}

// MARK: - Scripted LLM

struct ScriptedModel {
    /// Element lines look like: `e12 button "Greet" in "NB Fixture"`.
    static func element(_ screen: String, role: String? = nil, label: String) -> String? {
        for line in screen.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, parts[0].hasPrefix("e") else { continue }
            if let role, parts[1] != role { continue }
            if line.contains("\"\(label)\"") { return String(parts[0]) }
        }
        return nil
    }

    static func reply(system: String, user: String) -> [String: Any] {
        if system.contains("You are the planner") || system.contains("recovery planner") {
            return [
                "goal": "Greet Ada in the NB Fixture app", "clarification": NSNull(),
                "steps": [
                    ["title": "Opening NB Fixture", "instruction": "Bring the NBFixtureApp window to the front.", "route": "native", "app": "NBFixtureApp",
                     "risk": "low", "done_when": "NB Fixture is frontmost", "hint_action": "activate_app", "hint_target": "NBFixtureApp", "hint_text": NSNull()],
                    ["title": "Entering the name", "instruction": "Type Ada into the Name field.", "route": "gui", "app": "NBFixtureApp",
                     "risk": "low", "done_when": "The Name field contains Ada", "hint_action": "none", "hint_target": NSNull(), "hint_text": NSNull()],
                    ["title": "Pressing Greet", "instruction": "Click the Greet button and confirm the greeting appears.", "route": "gui", "app": "NBFixtureApp",
                     "risk": "low", "done_when": "Status shows Hello, Ada!", "hint_action": "none", "hint_target": NSNull(), "hint_text": NSNull()],
                ],
            ]
        }
        if system.contains("You are the executor") {
            let screen = user.components(separatedBy: "SCREEN:").last ?? ""
            var d: [String: Any] = ["thought": "", "status": "act", "action": "none", "element_id": NSNull(), "target_description": NSNull(), "text": NSNull(),
                                    "keys": NSNull(), "direction": NSNull(), "amount": NSNull(), "to_element_id": NSNull(), "app": NSNull(), "url": NSNull(),
                                    "menu_path": NSNull(), "clear_first": NSNull(), "submit": NSNull(), "expect": NSNull(), "risk": "low", "remember": NSNull(),
                                    "message": NSNull(), "tool_name": NSNull(), "tool_arguments_json": NSNull()]
            if user.contains("CURRENT STEP 2") {
                if screen.contains("value=\"Ada\"") {
                    d["status"] = "step_done"; d["thought"] = "The name field already contains Ada."
                } else if let id = element(screen, role: "textfield", label: "Name") {
                    d["action"] = "type"; d["element_id"] = id; d["text"] = "Ada"; d["clear_first"] = true; d["thought"] = "Type the name."
                } else {
                    d["status"] = "blocked"; d["message"] = "Name field not found"
                }
            } else if user.contains("CURRENT STEP 3") {
                if screen.contains("Hello, Ada!") {
                    d["status"] = "task_done"; d["message"] = "Greeted Ada — the fixture shows “Hello, Ada!”."
                } else if let id = element(screen, role: "button", label: "Greet") {
                    d["action"] = "click"; d["element_id"] = id; d["expect"] = "Status: Hello, Ada!"; d["thought"] = "Press Greet."
                } else {
                    d["status"] = "blocked"; d["message"] = "Greet button not found"
                }
            } else {
                d["status"] = "step_done"
            }
            return d
        }
        return ["message": "ok"]
    }
}

final class LLMServer: @unchecked Sendable {
    let listener: NWListener
    init(port: UInt16) throws {
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            self.receive(conn, buffer: Data())
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { print("mock llm listening on \(self.listener.port?.rawValue ?? 0)") }
        }
        listener.start(queue: .global())
    }

    func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, _ in
            var buf = buffer
            if let data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[headerEnd.upperBound...]
                if body.count >= length {
                    self.respond(conn, head: head, body: Data(body.prefix(length)))
                    return
                }
            }
            if done { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    func respond(_ conn: NWConnection, head: String, body: Data) {
        let requestLine = head.split(separator: "\r\n").first ?? ""
        var payload: String
        if requestLine.contains("/models") {
            payload = json(["data": [["id": "mock"]]])
        } else {
            let obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
            let messages = obj["messages"] as? [[String: Any]] ?? []
            let system = messages.first(where: { $0["role"] as? String == "system" })?["content"] as? String ?? ""
            let user = messages.last(where: { $0["role"] as? String == "user" })?["content"] as? String ?? ""
            let content = json(ScriptedModel.reply(system: system, user: user))
            payload = json(["id": "mock-1", "model": "mock", "choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": content]]],
                            "usage": ["prompt_tokens": user.count / 4, "completion_tokens": content.count / 4]])
        }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n" + payload
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}

switch args.first {
case "mcp":
    runMCP()
case "llm":
    let port = UInt16(args.dropFirst().first ?? "18734") ?? 18734
    let server = try LLMServer(port: port)
    server.start()
    dispatchMain()
default:
    print("usage: nb-mock-servers mcp | llm [port]")
    exit(2)
}
