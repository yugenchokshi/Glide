import Testing
import Foundation
import CoreGraphics
@testable import AgentKit
@testable import AutomationKit

func makeNode(_ id: String, _ role: String, _ name: String, value: String? = nil, focused: Bool = false, secure: Bool = false) -> UIElementNode {
    var n = UIElementNode(role: role, axRole: "AX", name: name, value: value, frame: CGRect(x: 0, y: 0, width: 50, height: 20), focused: focused, isSecure: secure)
    n.id = id
    n.fingerprint = id
    return n
}

func makeObservation(_ nodes: [UIElementNode], app: String = "Notes") -> ScreenObservation {
    ScreenObservation(app: AppInfo(name: app, bundleID: nil, pid: 1), windowTitle: "W", windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
                      elements: nodes, focusedElementID: nodes.first(where: \.focused)?.id)
}

@Suite("JSON")
struct JSONTests {
    @Test func extractsObjectsFromProseAndFences() {
        #expect(JSONValue.extractObject(from: "Sure! {\"a\": 1, \"b\": \"}\"} trailing")?["a"]?.intValue == 1)
        #expect(JSONValue.extractObject(from: "```json\n{\"x\": true}\n```")?["x"]?.boolValue == true)
        #expect(JSONValue.extractObject(from: "no json here") == nil)
    }

    @Test func strictSchemasRequireEveryProperty() {
        func check(_ s: JSONValue) {
            guard let props = s["properties"]?.objectValue else { return }
            let required = Set(s["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            #expect(required == Set(props.keys))
            #expect(s["additionalProperties"] == .bool(false))
            for p in props.values {
                check(p)
                if let items = p["items"] { check(items) }
            }
        }
        check(PlanSchema.schema)
        check(ActorSchema.schema)
        check(VisionGrounding.schema)
    }

    @Test func numbersRoundTripAsIntegersWhenWhole() {
        #expect(JSONValue.number(3).jsonString() == "3")
        #expect(JSONValue.number(2.5).jsonString() == "2.5")
    }
}

@Suite("Plan decoding")
struct PlanDecodingTests {
    @Test func decodesPlanWithHints() throws {
        let j = try JSONValue.parse("""
        {"goal":"g","clarification":null,"steps":[
          {"title":"Opening Notes","instruction":"Open Notes","route":"native","app":"Notes","risk":"low","done_when":"Notes in front","hint_action":"launch_app","hint_target":"Notes","hint_text":null},
          {"title":"Sending","instruction":"Send it","route":"gui","app":null,"risk":"high","done_when":"sent","hint_action":"none","hint_target":null,"hint_text":null}]}
        """)
        let plan = try PlanSchema.decode(j)
        #expect(plan.steps.count == 2)
        #expect(plan.steps[0].hint?.action == "launch_app")
        #expect(plan.steps[1].hint == nil)
        #expect(plan.steps[1].risk == .high)
        #expect(plan.steps.map(\.id) == [1, 2])
    }

    @Test func decodesActorDecisionWithToolArguments() throws {
        let j = try JSONValue.parse("""
        {"thought":"t","status":"act","action":"call_tool","element_id":null,"target_description":null,"text":null,"keys":null,"direction":null,
         "amount":null,"to_element_id":null,"app":null,"url":null,"menu_path":null,"clear_first":null,"submit":null,"expect":null,"risk":"medium",
         "remember":null,"message":null,"tool_name":"GMAIL_CREATE_EMAIL_DRAFT","tool_arguments_json":"{\\"to\\":\\"a@b.c\\"}"}
        """)
        let d = ActorSchema.decode(j)
        #expect(d.action == "call_tool")
        #expect(d.toolArguments?["to"]?.stringValue == "a@b.c")
        #expect(d.risk == .medium)
    }
}

@Suite("SafetyPolicy")
struct SafetyTests {
    let policy = SafetyPolicy(settings: SafetySettings())
    let mail = AppInfo(name: "Mail", bundleID: "com.apple.mail", pid: 2)
    let messages = AppInfo(name: "Messages", bundleID: "com.apple.MobileSMS", pid: 3)
    let terminal = AppInfo(name: "Terminal", bundleID: "com.apple.Terminal", pid: 4)

    @Test func flagsSendDeletePurchase() {
        for label in ["Send", "Delete", "Move to Trash", "Buy Now", "Place Order", "Publish", "Empty Trash"] {
            let v = policy.assess(.click(.element("e1")), target: makeNode("e1", "button", label), app: mail, modelRisk: .low, stepRisk: .low)
            #expect(v.risk == .high, "\(label) should be high risk")
            #expect(policy.needsApproval(v))
        }
    }

    @Test func ordinaryClicksAreLowRisk() {
        let v = policy.assess(.click(.element("e1")), target: makeNode("e1", "button", "New Note"), app: mail, modelRisk: .low, stepRisk: .low)
        #expect(v.risk == .low)
        #expect(!policy.needsApproval(v))
    }

    @Test func returnInMessagingAppsIsHighRisk() throws {
        let v = policy.assess(.keyPress(try KeyCombination(parsing: "return")), target: nil, app: messages, modelRisk: .low, stepRisk: .low)
        #expect(v.risk == .high)
        let typed = policy.assess(.typeText("hi", into: nil, clearFirst: false, submit: true), target: nil, app: messages, modelRisk: .low, stepRisk: .low)
        #expect(typed.risk == .high)
    }

    @Test func blocksPasswordFieldsCardsAndExcludedApps() {
        let pw = policy.assess(.typeText("x", into: .element("e1"), clearFirst: false, submit: false), target: makeNode("e1", "textfield", "Password", secure: true), app: mail, modelRisk: .low, stepRisk: .low)
        #expect(pw.blocked != nil)
        let card = policy.assess(.typeText("4242 4242 4242 4242", into: nil, clearFirst: false, submit: false), target: nil, app: mail, modelRisk: .low, stepRisk: .low)
        #expect(card.blocked != nil)
        let excluded = policy.assess(.click(.point(.zero)), target: nil, app: AppInfo(name: "1Password", bundleID: nil, pid: 9), modelRisk: .low, stepRisk: .low)
        #expect(excluded.blocked != nil)
    }

    @Test func destructiveShellCommandsAreHighRisk() {
        let v = policy.assess(.typeText("rm -rf ~/Documents", into: nil, clearFirst: false, submit: true), target: nil, app: terminal, modelRisk: .low, stepRisk: .low)
        #expect(v.risk == .high)
        let ls = policy.assess(.typeText("ls -la", into: nil, clearFirst: false, submit: true), target: nil, app: terminal, modelRisk: .low, stepRisk: .low)
        #expect(ls.risk == .medium)
    }

    @Test func approvalLevels() {
        var s = SafetySettings()
        s.approvalLevel = .mediumAndHigh
        let p = SafetyPolicy(settings: s)
        #expect(p.needsApproval(.init(risk: .medium, reasons: [], blocked: nil)))
        #expect(!p.needsApproval(.init(risk: .low, reasons: [], blocked: nil)))
        s.approvalLevel = .everyAction
        #expect(SafetyPolicy(settings: s).needsApproval(.init(risk: .low, reasons: [], blocked: nil)))
    }

    @Test func toolNamesAreAssessed() {
        #expect(policy.assessTool(name: "GMAIL_SEND_EMAIL", risk: .low).risk == .high)
        #expect(policy.assessTool(name: "GMAIL_FETCH_EMAILS", risk: .low).risk == .low)
    }

    @Test func luhn() {
        #expect(SafetyPolicy.looksLikePaymentCard("4111 1111 1111 1111"))
        #expect(!SafetyPolicy.looksLikePaymentCard("1234 5678 9012 3456"))
        #expect(!SafetyPolicy.looksLikePaymentCard("call me at 555 1234"))
    }
}

@Suite("ActionResolver")
struct ResolverTests {
    let resolver = ActionResolver(jev: nil, metrics: TaskMetrics())
    let obs = makeObservation([
        makeNode("e1", "button", "New Note"), makeNode("e2", "searchfield", "Search"),
        makeNode("e3", "textarea", "Body", focused: true), makeNode("e4", "button", "Note A"), makeNode("e5", "button", "Note B"),
    ])

    @Test func compilesUnambiguousHints() {
        #expect(resolver.compileHint(ActionHint(action: "click", target: "New Note", text: nil), obs: obs) == .click(.element("e1")))
        #expect(resolver.compileHint(ActionHint(action: "launch_app", target: "Notes", text: nil), obs: nil) == .launchApp("Notes"))
        #expect(resolver.compileHint(ActionHint(action: "menu", target: "File > Save…", text: nil), obs: obs) == .menu(["File", "Save…"]))
        #expect(resolver.compileHint(ActionHint(action: "type", target: nil, text: "hi"), obs: obs) == .typeText("hi", into: nil, clearFirst: false, submit: false))
        #expect(resolver.compileHint(ActionHint(action: "type", target: "Search", text: "q"), obs: obs) == .typeText("q", into: .element("e2"), clearFirst: false, submit: false))
    }

    @Test func refusesAmbiguousHints() {
        #expect(resolver.compileHint(ActionHint(action: "click", target: "Note", text: nil), obs: obs) == nil)
        #expect(resolver.compileHint(ActionHint(action: "menu", target: "Save", text: nil), obs: obs) == nil)
    }

    func decision(_ action: String, id: String? = nil, desc: String? = nil, text: String? = nil, keys: String? = nil) -> ActorDecision {
        ActorDecision(status: .act, thought: "", action: action, elementID: id, targetDescription: desc, text: text, keys: keys, direction: nil, amount: nil,
                      toElementID: nil, app: nil, url: nil, menuPath: nil, clearFirst: false, submit: false, expect: nil, risk: .low, remember: nil,
                      message: nil, toolName: nil, toolArguments: nil)
    }

    @Test func resolvesDecisions() async {
        if case .action(let a, let t, _) = await resolver.resolve(decision("click", id: "e1"), obs: obs, objective: "") {
            #expect(a == .click(.element("e1")) && t?.name == "New Note")
        } else { Issue.record("expected action") }
        if case .action(let a, _, _) = await resolver.resolve(decision("key", keys: "cmd+n"), obs: obs, objective: "") {
            #expect(a == .keyPress(try! KeyCombination(parsing: "cmd+n")))
        } else { Issue.record("expected key") }
        if case .needsGrounding(let d, _, _) = await resolver.resolve(decision("click", desc: "gear icon in the corner"), obs: obs, objective: "") {
            #expect(d == "gear icon in the corner")
        } else { Issue.record("expected grounding") }
        if case .invalid = await resolver.resolve(decision("key", keys: "cmd+banana"), obs: obs, objective: "") {} else { Issue.record("expected invalid") }
    }
}

@Suite("Providers")
struct ProviderTests {
    let req = LLMRequest(model: "claude-opus-5-5", system: "sys", messages: [.user("hi", images: [LLMImage(pngData: Data([1, 2, 3]), width: 1, height: 1)])],
                         schema: Schema.object([("a", Schema.string())]), maxTokens: 100, effort: "low")

    @Test func anthropicBody() {
        let p = AnthropicProvider(config: .anthropicDefault, apiKey: "k")
        let b = p.body(req, structured: true, fallbacks: true)
        #expect(b["output_config"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(b["output_config"]?["effort"]?.stringValue == "low")
        #expect(b["fallbacks"]?.stringValue == "default")
        #expect(b["messages"]?[0]?["content"]?[0]?["type"]?.stringValue == "image")
        #expect(b["tool_choice"] == nil)
        let prompt = p.body(req, structured: false, fallbacks: false)
        #expect(prompt["output_config"]?["format"] == nil)
        #expect(prompt["system"]?.stringValue?.contains("JSON schema") == true)
    }

    @Test func anthropicParseAndRefusal() throws {
        let p = AnthropicProvider(config: .anthropicDefault, apiKey: "k")
        let ok = Data(#"{"model":"claude-opus-5-5","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"a\":\"x\"}"}],"usage":{"input_tokens":10,"output_tokens":5}}"#.utf8)
        let r = try p.parse(ok, req: req, start: Date())
        #expect(r.json?["a"]?.stringValue == "x")
        #expect(r.usage.inputTokens == 10)
        let refusal = Data(#"{"stop_reason":"refusal","content":[],"stop_details":{"explanation":"no"}}"#.utf8)
        #expect(throws: LLMError.self) { try p.parse(refusal, req: req, start: Date()) }
    }

    @Test func openAIBodies() {
        let openai = OpenAIProvider(config: .openAIDefault, apiKey: "k")
        let b = openai.body(LLMRequest(model: "gpt-5.5", system: "s", messages: [.user("u")], schema: Schema.object([("a", Schema.string())]), effort: "low"), mode: .schema, effort: true)
        #expect(b["max_completion_tokens"] != nil && b["max_tokens"] == nil)
        #expect(b["response_format"]?["json_schema"]?["strict"]?.boolValue == true)
        #expect(b["reasoning_effort"]?.stringValue == "low")
        let compat = OpenAIProvider(config: ProviderConfig(id: "c", kind: .openaiCompatible, name: "C", baseURL: "http://x/v1", requiresKey: false), apiKey: "")
        let cb = compat.body(LLMRequest(model: "m", system: "s", messages: [.user("u")], schema: Schema.object([("a", Schema.string())])), mode: .prompt, effort: false)
        #expect(cb["max_tokens"] != nil && cb["response_format"] == nil)
        #expect(compat.headers.isEmpty)
    }

    @Test func routerAutomaticDefaults() {
        var s = AppSettings()
        s.providers = [.anthropicDefault]
        let creds = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        creds.set("sk-ant-test-123456789", for: .provider("anthropic"))
        defer { creds.remove(.provider("anthropic")) }
        let router = ModelRouter(settings: s, credentials: creds)
        #expect((try? router.route(.planner))?.model == "claude-opus-5-5")
        #expect((try? router.route(.actor))?.model == "claude-haiku-5-5")
        var manual = s
        manual.routing.mode = .manual
        manual.routing.manual[.actor] = ModelChoice(providerID: "anthropic", model: "claude-sonnet-5-5")
        #expect((try? ModelRouter(settings: manual, credentials: creds).route(.actor))?.model == "claude-sonnet-5-5")
    }

    @Test func openAIDefaultsToGpt6LunaForEveryRole() {
        var s = AppSettings()
        s.providers = [.openAIDefault]
        let creds = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        creds.set("sk-test-openai-123456789", for: .provider("openai"))
        defer { creds.remove(.provider("openai")) }
        let router = ModelRouter(settings: s, credentials: creds)
        for role in ModelRole.allCases {
            #expect((try? router.route(role))?.model == "gpt-6-luna")
        }
    }

    @Test func jevThroughVercelGateway() {
        var s = AppSettings()
        s.routing.useJevForSelection = true
        s.routing.jevProvider = .vercelGateway
        #expect(s.routing.effectiveJevModel == "typesafe-ai/jev")
        #expect(JevProvider.vercelGateway.endpoint.absoluteString == "https://ai-gateway.vercel.sh/typesafe/v1/systemone")
        let creds = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        defer { creds.remove(.vercelGateway); creds.remove(.jev) }
        #expect(ModelRouter(settings: s, credentials: creds).jevClient() == nil) // no gateway key yet
        creds.set("tsk-direct-key-123456", for: .jev)
        #expect(ModelRouter(settings: s, credentials: creds).jevClient() == nil) // direct key isn't used for the gateway
        creds.set("vck-gateway-key-123456", for: .vercelGateway)
        let client = ModelRouter(settings: s, credentials: creds).jevClient()
        #expect(client?.endpoint == JevProvider.vercelGateway.endpoint)
        #expect(client?.model == "typesafe-ai/jev")
        s.routing.jevProvider = .typesafe
        s.routing.jevModel = "typesafe-ai/jev"
        #expect(s.routing.effectiveJevModel == "jev-latest")
        #expect(ModelRouter(settings: s, credentials: creds).jevClient()?.endpoint.host == "api.typesafe.ai")
    }

    @Test func oldSettingsWithoutJevProviderStillDecode() throws {
        var s = AppSettings()
        s.routing.jevModel = "jev-latest"
        var json = try JSONValue.parse(JSONEncoder().encode(s))
        if case .object(var root) = json, case .object(var routing)? = root["routing"] {
            routing["jevProvider"] = nil
            root["routing"] = .object(routing)
            json = .object(root)
        }
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json.data())
        #expect(decoded.routing.effectiveJevProvider == .typesafe)
    }

    @Test func routerWithoutKeysIsNotConfigured() {
        var s = AppSettings()
        s.providers = [.anthropicDefault]
        let router = ModelRouter(settings: s, credentials: CredentialStore(service: "dev.glide.tests.empty.\(UUID().uuidString)"))
        #expect(!router.isConfigured)
    }

    @Test func pricing() {
        let c = ModelPricing.cost(model: "claude-haiku-5-5", usage: LLMUsage(inputTokens: 1_000_000, outputTokens: 1_000_000))
        #expect(c == 0.6)
        #expect(ModelPricing.cost(model: "unknown-model", usage: LLMUsage()) == nil)
    }
}

@Suite("Credentials")
struct CredentialTests {
    @Test func keychainRoundTrip() {
        let store = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        #expect(store.get(.composio) == nil)
        #expect(store.set("  ak_secret_value_123  ", for: .composio))
        #expect(store.get(.composio) == "ak_secret_value_123")
        #expect(store.remove(.composio))
        #expect(store.get(.composio) == nil)
    }

    @Test func masksAndScrubs() {
        #expect(CredentialStore.mask("sk-ant-abcdefghijklmnop") == "sk-…mnop")
        let text = "key sk-ant-api03-ABCDEFGHIJKLMNOP and Bearer abcdefghijklmnopqrstuvwxyz"
        let scrubbed = SecretScrubber.scrub(text)
        #expect(!scrubbed.contains("ABCDEFGHIJ"))
        #expect(!scrubbed.contains("abcdefghijklmnopqrst"))
    }
}

@Suite("LocalStore")
struct LocalStoreTests {
    @Test func tasksEventsAndSkills() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nb-test-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try LocalStore(path: path)
        store.startTask(id: "t1", instruction: "Create a note with key sk-ant-SHOULDNOTBESTORED123")
        store.appendEvent(taskID: "t1", ActivityEntry(kind: .action, title: "Clicking New Note", success: true, durationMs: 120))
        let metrics = TaskMetrics.Snapshot(modelCalls: 2, visionCalls: 0, jevCalls: 0, inputTokens: 10, outputTokens: 5, estimatedCost: 0.01, modelLatencyMs: 900,
                                           actions: 3, deterministicActions: 1, recoveries: 0, interventions: 0, observations: 4, avgObservationMs: 20)
        store.finishTask(id: "t1", result: TaskResult(status: .completed, summary: "Done", error: nil, plan: Plan(goal: "g", steps: [], clarification: nil), metrics: metrics, durationMs: 1234))
        let t = try #require(store.task(id: "t1"))
        #expect(t.status == "completed")
        #expect(!t.instruction.contains("SHOULDNOTBESTORED"))
        #expect(t.metrics?.actions == 3)
        #expect(store.events(taskID: "t1").first?.title == "Clicking New Note")
        let skill = Skill(name: "Meeting note", description: "d", triggers: ["meeting note"], steps: ["Open Notes", "New note"])
        store.saveSkill(skill)
        #expect(store.skills().first?.name == "Meeting note")
        #expect(skill.relevance(to: "create a meeting note about Q3") >= 0.99)
        #expect(skill.relevance(to: "open safari") == 0)
        store.clearHistory()
        #expect(store.recentTasks().isEmpty)
    }
}

/// Uses the built mock servers next to the test bundle.
func productURL(_ name: String) -> URL? {
    let bundle = Bundle(for: BundleToken.self).bundleURL
    let url = bundle.deletingLastPathComponent().appendingPathComponent(name)
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
}
final class BundleToken {}

@Suite("Integrations")
struct IntegrationTests {
    @Test func mcpStdioClient() async throws {
        let server = try #require(productURL("nb-mock-servers"), "run `swift build` first so the mock servers exist")
        var config = MCPServerConfig(name: "Mock Server", transport: .stdio)
        config.command = server.path
        config.arguments = ["mcp"]
        let client = MCPClient(config: config)
        try await client.connect(credentials: CredentialStore(service: "dev.glide.tests.mcp"))
        let tools = await client.tools
        #expect(tools.map(\.name).sorted() == ["add", "echo"])
        #expect(tools.first?.qualifiedName.hasPrefix("mock_server__") == true)
        let r = try await client.call("add", arguments: ["a": 2, "b": 40])
        #expect(r.text == "42.0" && !r.isError)
        await client.disconnect()
    }

    @Test func openAICompatibleAgainstMockServer() async throws {
        let server = try #require(productURL("nb-mock-servers"), "run `swift build` first so the mock servers exist")
        let port = Int.random(in: 20000...40000)
        let p = Process()
        p.executableURL = server
        p.arguments = ["llm", String(port)]
        p.standardOutput = Pipe()
        try p.run()
        defer { p.terminate() }
        try await Task.sleep(for: .milliseconds(400))
        let provider = OpenAIProvider(config: ProviderConfig(id: "m", kind: .openaiCompatible, name: "Mock", baseURL: "http://127.0.0.1:\(port)/v1", requiresKey: false), apiKey: "")
        #expect(try await provider.listModels() == ["mock"])
        let r = try await provider.complete(LLMRequest(model: "mock", system: Prompts.planner, messages: [.user("Greet Ada")], schema: PlanSchema.schema))
        let plan = try PlanSchema.decode(try #require(r.json))
        #expect(plan.steps.count == 3)
    }
}
