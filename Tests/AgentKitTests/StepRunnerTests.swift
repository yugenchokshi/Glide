import Testing
import Foundation
@testable import AgentKit
@testable import AutomationKit

// MARK: - Test doubles

/// A scripted model: replies in order (or computed from each request), recording requests.
final class ScriptedLLM: LLMProvider, @unchecked Sendable {
    let config = ProviderConfig(id: "scripted", kind: .openaiCompatible, name: "Scripted", baseURL: "http://127.0.0.1:9", requiresKey: false)
    private let lock = NSLock()
    private var replies: [JSONValue]
    private let respond: (@Sendable (LLMRequest, Int) -> JSONValue)?
    private var _requests: [LLMRequest] = []

    init(_ replies: [JSONValue]) {
        self.replies = replies
        self.respond = nil
    }

    init(respond: @escaping @Sendable (LLMRequest, Int) -> JSONValue) {
        self.replies = []
        self.respond = respond
    }

    var requests: [LLMRequest] { lock.withLock { _requests } }
    var userMessages: [String] { requests.map { $0.messages.last?.text ?? "" } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let reply: JSONValue? = lock.withLock {
            _requests.append(request)
            if let respond { return respond(request, _requests.count - 1) }
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else { throw LLMError.emptyResponse }
        return LLMResponse(text: reply.jsonString(), json: reply, usage: LLMUsage(inputTokens: 100, outputTokens: 20), model: "scripted",
                           latencyMs: 1, stopReason: "stop")
    }

    func listModels() async throws -> [String] { ["scripted"] }
}

/// A tool whose risk and behavior the test decides; records what it was asked to do.
final class FakeTool: AgentTool, @unchecked Sendable {
    let spec: ToolSpec
    private let lock = NSLock()
    private var _calls: [JSONValue] = []
    private var _assessed: [JSONValue] = []
    private let verdict: @Sendable (JSONValue) -> ToolVerdict
    private let handler: @Sendable (JSONValue, ToolContext) async throws -> ToolOutput

    /// `handler` comes first so a trailing closure is the tool's behavior.
    init(_ name: String, category: ToolCategory = .command, needsScreen: Bool = false,
         handler: @escaping @Sendable (JSONValue, ToolContext) async throws -> ToolOutput = { _, _ in ToolOutput(ok: true, text: "ok") },
         verdict: @escaping @Sendable (JSONValue) -> ToolVerdict = { _ in ToolVerdict(risk: .low, summary: "Run a safe thing") }) {
        self.spec = ToolSpec(name: name, summary: "Test tool \(name)", inputSchema: Schema.object([]), category: category, needsScreen: needsScreen)
        self.verdict = verdict
        self.handler = handler
    }

    var calls: [JSONValue] { lock.withLock { _calls } }
    var assessed: [JSONValue] { lock.withLock { _assessed } }

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        lock.withLock { _assessed.append(arguments) }
        return verdict(arguments)
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        lock.withLock { _calls.append(arguments) }
        return try await handler(arguments, context)
    }
}

/// Records log entries and approval requests; answers approvals from a queue (then rejects).
final class CallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _logs: [ActivityEntry] = []
    private var _approvals: [ApprovalRequest] = []
    private var decisions: [ApprovalDecision]

    init(_ decisions: [ApprovalDecision] = []) { self.decisions = decisions }

    var logs: [ActivityEntry] { lock.withLock { _logs } }
    var approvals: [ApprovalRequest] { lock.withLock { _approvals } }

    var callbacks: AgentCallbacks {
        AgentCallbacks(
            log: { e in self.lock.withLock { self._logs.append(e) } },
            approve: { req in
                self.lock.withLock {
                    self._approvals.append(req)
                    return self.decisions.isEmpty ? .reject : self.decisions.removeFirst()
                }
            })
    }
}

/// Thread-safe ordered list of strings.
final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

/// A reply of the tool loop's decision schema.
func toolReply(_ status: String = "act", calls: [(String, JSONValue)] = [], fields: JSONValue? = nil, message: String? = nil,
               remember: String? = nil) -> JSONValue {
    let encodedCalls: [JSONValue] = calls.map { call -> JSONValue in
        .object(["tool": .string(call.0), "arguments_json": .string(call.1.jsonString())])
    }
    func optional(_ s: String?) -> JSONValue { s.map { JSONValue.string($0) } ?? JSONValue.null }
    return .object([
        "thought": "test",
        "status": .string(status),
        "calls": .array(encodedCalls),
        "result_fields_json": optional(fields?.jsonString()),
        "message": optional(message),
        "remember": optional(remember),
    ])
}

func commandStep(outputFields: [String] = [], route: ExecutionRoute = .command, risk: RiskLevel = .low) -> RecipeStep {
    RecipeStep(id: 1, title: "Working", instruction: "Do the work", route: route, risk: risk, doneWhen: "the work is done", outputFields: outputFields)
}

func request(_ step: RecipeStep = commandStep(), jobID: String? = nil, maxTurns: Int = 14) -> StepRequest {
    StepRequest(goal: "Test goal", step: step, context: "", allowedCategories: step.route.toolCategories, jobID: jobID,
                itemID: jobID.map { "\($0)/1/0" }, maxTurns: maxTurns)
}

func makeRunner(_ tools: [any AgentTool], llm: ScriptedLLM, settings: AppSettings = AppSettings(), runtime: AutomationRuntime = AutomationRuntime(),
                integrations: ToolStepRunner.Integrations = .disabled) -> ToolStepRunner {
    ToolStepRunner(settings: settings, runtime: runtime, tools: ToolRegistry(tools), provider: llm, model: "scripted", integrations: integrations)
}

func highRisk(_ summary: String) -> @Sendable (JSONValue) -> ToolVerdict {
    { _ in ToolVerdict(risk: .high, reasons: ["deletes"], summary: summary) }
}

/// Checks that a schema follows strict mode: every property required, no extra properties.
func expectStrict(_ s: JSONValue, _ path: String = "root") {
    if let props = s["properties"]?.objectValue {
        let required = Set(s["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(required == Set(props.keys), "\(path): every property must be required")
        #expect(s["additionalProperties"] == .bool(false), "\(path): additionalProperties must be false")
        for (k, p) in props { expectStrict(p, "\(path).\(k)") }
    }
    if let items = s["items"] { expectStrict(items, "\(path)[]") }
}

// MARK: - ToolStepRunner

@Suite("ToolStepRunner")
struct ToolStepRunnerTests {
    @Test func batchesCallsInOrderAndCountsUsage() async throws {
        let ledger = Ledger()
        let list = FakeTool("fs.list", category: .files) { _, _ in ledger.add("list"); return ToolOutput(ok: true, text: "a.txt\nb.txt") }
        let read = FakeTool("fs.read", category: .files) { _, _ in ledger.add("read"); return ToolOutput(ok: true, text: "one\ntwo\nthree") }
        let wc = FakeTool("shell.run") { _, _ in ledger.add("wc"); return ToolOutput(ok: true, text: "3 a.txt") }
        let llm = ScriptedLLM([
            toolReply(calls: [("fs.list", ["path": "~/A"]), ("fs.read", ["path": "~/A/a.txt"]), ("shell.run", ["command": "wc -l ~/A/a.txt"])]),
            toolReply("step_done", message: "a.txt has 3 lines"),
        ])
        let rec = CallbackRecorder()
        let result = try await makeRunner([list, read, wc], llm: llm).execute(request(), callbacks: rec.callbacks)
        #expect(result.status == .done)
        #expect(ledger.all == ["list", "read", "wc"])
        #expect(result.actions == 3)
        #expect(result.modelCalls == 2)
        #expect(result.usage == LLMUsage(inputTokens: 200, outputTokens: 40))
        #expect(result.output.contains("3 lines"))
        let second = try #require(llm.userMessages.last)
        #expect(second.contains("fs.list") && second.contains("→ ok") && second.contains("3 a.txt"))
        let toolLogs = rec.logs.filter { $0.kind == .tool }
        #expect(toolLogs.count == 3 && toolLogs.allSatisfy { $0.route == .command && $0.success == true })
        #expect(rec.approvals.isEmpty)
    }

    @Test func batchStopsAtFirstFailure() async throws {
        let first = FakeTool("fs.list", category: .files)
        let broken = FakeTool("fs.read", category: .files) { _, _ in ToolOutput(ok: false, text: "No such file") }
        let never = FakeTool("shell.run")
        let llm = ScriptedLLM([
            toolReply(calls: [("fs.list", ["path": "~"]), ("fs.read", ["path": "~/missing"]), ("shell.run", ["command": "ls"])]),
            toolReply("step_done", message: "done anyway"),
        ])
        let result = try await makeRunner([first, broken, never], llm: llm).execute(request(), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .done)
        #expect(first.calls.count == 1 && broken.calls.count == 1 && never.calls.isEmpty)
        let second = try #require(llm.userMessages.last)
        #expect(second.contains("FAILED") && second.contains("No such file") && second.contains("not run"))
    }

    @Test func batchSizeFollowsSettings() async throws {
        let tool = FakeTool("shell.run")
        var settings = AppSettings()
        settings.tools.maxBatch = 2
        let three: [(String, JSONValue)] = [("shell.run", ["command": "a"]), ("shell.run", ["command": "b"]), ("shell.run", ["command": "c"])]
        let llm = ScriptedLLM([toolReply(calls: three), toolReply("step_done")])
        _ = try await makeRunner([tool], llm: llm, settings: settings).execute(request(), callbacks: CallbackRecorder().callbacks)
        #expect(tool.calls.map { $0["command"]?.stringValue } == ["a", "b"])
        #expect(llm.userMessages[1].contains("only the first 2 calls ran"))

        settings.tools.batchActions = false
        let single = FakeTool("shell.run")
        let llm2 = ScriptedLLM([toolReply(calls: three), toolReply("step_done")])
        _ = try await makeRunner([single], llm: llm2, settings: settings).execute(request(), callbacks: CallbackRecorder().callbacks)
        #expect(single.calls.count == 1)
        #expect(llm2.requests[0].messages[0].text.contains("at most 1 call per turn"))
    }

    @Test func blockedCallsNeverRunAndTheModelIsTold() async throws {
        let sudo = FakeTool("shell.run", verdict: { _ in ToolVerdict(risk: .high, reasons: ["sudo"], blocked: "Glide never runs sudo.", summary: "Run `sudo rm -rf /`") })
        let llm = ScriptedLLM([
            toolReply(calls: [("shell.run", ["command": "sudo rm -rf /"])]),
            toolReply("blocked", message: "This needs administrator rights, which Glide never uses."),
        ])
        let rec = CallbackRecorder([.approve])
        let result = try await makeRunner([sudo], llm: llm).execute(request(), callbacks: rec.callbacks)
        #expect(result.status == .blocked("This needs administrator rights, which Glide never uses."))
        #expect(sudo.calls.isEmpty)
        #expect(rec.approvals.isEmpty, "blocked calls aren't offered for approval")
        #expect(llm.userMessages[1].contains("BLOCKED") && llm.userMessages[1].contains("never runs sudo"))
        #expect(rec.logs.contains { $0.kind == .approval && $0.success == false && $0.title.contains("Blocked") })
    }

    @Test func approvedHighRiskCallRuns() async throws {
        let rm = FakeTool("fs.trash", category: .files, verdict: highRisk("Move old.log to the Trash"))
        let llm = ScriptedLLM([toolReply(calls: [("fs.trash", ["path": "~/old.log"])]), toolReply("step_done", message: "Trashed old.log")])
        let rec = CallbackRecorder([.approve])
        let result = try await makeRunner([rm], llm: llm).execute(request(), callbacks: rec.callbacks)
        #expect(result.status == .done)
        #expect(rm.calls.count == 1)
        let approval = try #require(rec.approvals.first)
        #expect(approval.kind == .tool && approval.title == "Move old.log to the Trash" && approval.risk == .high)
        #expect(approval.reasons == ["deletes"])
        #expect(rec.logs.contains { $0.kind == .approval && $0.success == true })
    }

    @Test func declinedCallIsNotRunAndNotRetried() async throws {
        let rm = FakeTool("fs.trash", category: .files, verdict: highRisk("Move old.log to the Trash"))
        let llm = ScriptedLLM([toolReply(calls: [("fs.trash", ["path": "~/old.log"])]), toolReply("step_done", message: "Left the file alone")])
        let rec = CallbackRecorder([.reject])
        let result = try await makeRunner([rm], llm: llm).execute(request(), callbacks: rec.callbacks)
        #expect(result.status == .done)
        #expect(rm.calls.isEmpty)
        #expect(llm.userMessages[1].contains("DECLINED by the user; don't retry it"))

        // A second refusal in the same step stops and asks the user.
        let again = ScriptedLLM([toolReply(calls: [("fs.trash", ["path": "~/a"])]), toolReply(calls: [("fs.trash", ["path": "~/b"])])])
        let twice = try await makeRunner([rm], llm: again).execute(request(), callbacks: CallbackRecorder([.reject, .reject]).callbacks)
        guard case .blocked = twice.status else { Issue.record("expected blocked, got \(twice.status)"); return }
    }

    @Test func stopFromApprovalEndsTheStep() async throws {
        let rm = FakeTool("fs.trash", category: .files, verdict: highRisk("Trash it"))
        let runtime = AutomationRuntime()
        let llm = ScriptedLLM([toolReply(calls: [("fs.trash", ["path": "~/x"])])])
        await #expect(throws: AutomationError.stopped) {
            try await makeRunner([rm], llm: llm, runtime: runtime).execute(request(), callbacks: CallbackRecorder([.stop]).callbacks)
        }
        #expect(rm.calls.isEmpty)
        #expect(runtime.gate.isStopped, "a quick task's stop also stops input")

        // A job's stop ends only that job: the shared gate stays running.
        let jobRuntime = AutomationRuntime()
        let llm2 = ScriptedLLM([toolReply(calls: [("fs.trash", ["path": "~/x"])])])
        await #expect(throws: AutomationError.stopped) {
            try await makeRunner([rm], llm: llm2, runtime: jobRuntime).execute(request(jobID: "job-1"), callbacks: CallbackRecorder([.stop]).callbacks)
        }
        #expect(!jobRuntime.gate.isStopped)
    }

    @Test func resultFieldsAreReturnedAndCompleted() async throws {
        let fetch = FakeTool("web.fetch", category: .web) { _, _ in ToolOutput(ok: true, text: "Contact: hello@acme.test · 12 people") }
        let step = commandStep(outputFields: ["email", "employees"], route: .web)
        let llm = ScriptedLLM([
            toolReply(calls: [("web.fetch", ["url": "https://acme.test"])]),
            toolReply("step_done", fields: ["email": "hello@acme.test"], message: "Found the email"),
            toolReply("step_done", fields: ["email": "hello@acme.test", "employees": 12], message: "Found both"),
        ])
        let result = try await makeRunner([fetch], llm: llm).execute(request(step, jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .done)
        #expect(result.fields == ["email": "hello@acme.test", "employees": 12])
        #expect(llm.userMessages[2].contains("missing employees"))

        // After one reminder, missing fields become null instead of failing the item.
        let lazy = ScriptedLLM([toolReply("step_done", fields: ["email": "x@y.test"]), toolReply("step_done", fields: ["email": "x@y.test"])])
        let partial = try await makeRunner([fetch], llm: lazy).execute(request(step, jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(partial.status == .done)
        #expect(partial.fields == ["email": "x@y.test", "employees": .null])
    }

    @Test func doneWithCallsRunsThemFirst() async throws {
        let write = FakeTool("fs.write", category: .files)
        let llm = ScriptedLLM([toolReply("step_done", calls: [("fs.write", ["path": "~/a.txt", "content": "hi", "mode": "create"])], message: "Wrote a.txt")])
        let result = try await makeRunner([write], llm: llm).execute(request(), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .done && write.calls.count == 1 && result.modelCalls == 1)

        // With output fields the claim waits for the model to see the results.
        let fetch = FakeTool("web.fetch", category: .web) { _, _ in ToolOutput(ok: true, text: "price: 9") }
        let llm2 = ScriptedLLM([
            toolReply("step_done", calls: [("web.fetch", ["url": "https://a.test"])], fields: ["price": 1]),
            toolReply("step_done", fields: ["price": 9]),
        ])
        let checked = try await makeRunner([fetch], llm: llm2).execute(request(commandStep(outputFields: ["price"], route: .web), jobID: "j"),
                                                                       callbacks: CallbackRecorder().callbacks)
        #expect(checked.fields == ["price": 9])
        #expect(llm2.requests.count == 2)
    }

    @Test func repeatedIdenticalFailuresFailTheStep() async throws {
        let missing = FakeTool("fs.read", category: .files) { _, _ in ToolOutput(ok: false, text: "No such file: ~/nope.txt") }
        let llm = ScriptedLLM(respond: { _, _ in toolReply(calls: [("fs.read", ["path": "~/nope.txt"])]) })
        let result = try await makeRunner([missing], llm: llm).execute(request(), callbacks: CallbackRecorder().callbacks)
        guard case .failed(let reason) = result.status else { Issue.record("expected failure, got \(result.status)"); return }
        #expect(reason.contains("3 times in a row"))
        #expect(missing.calls.count == 3)
        #expect(llm.requests.count == 3)
    }

    @Test func errorBudgetEndsAFlailingStep() async throws {
        let flaky = FakeTool("fs.read", category: .files) { _, _ in ToolOutput(ok: false, text: "permission denied") }
        let llm = ScriptedLLM(respond: { _, i in toolReply(calls: [("fs.read", ["path": .string("~/file\(i)")])]) })
        let result = try await makeRunner([flaky], llm: llm).execute(request(), callbacks: CallbackRecorder().callbacks)
        guard case .failed(let reason) = result.status else { Issue.record("expected failure, got \(result.status)"); return }
        #expect(reason.contains("Too many errors"))
        #expect(flaky.calls.count == ToolStepRunner.errorBudget + 1)
    }

    @Test func turnLimitEndsTheStep() async throws {
        let ok = FakeTool("shell.run")
        let llm = ScriptedLLM(respond: { _, i in toolReply(calls: [("shell.run", ["command": .string("echo \(i)")])]) })
        let result = try await makeRunner([ok], llm: llm).execute(request(maxTurns: 3), callbacks: CallbackRecorder().callbacks)
        guard case .failed(let reason) = result.status else { Issue.record("expected failure"); return }
        #expect(reason.contains("limit of 3 turns"))
        #expect(ok.calls.count == 3)
    }

    @Test func gateStopEndsAQuickTaskStep() async throws {
        let runtime = AutomationRuntime()
        let stopper = FakeTool("shell.run") { _, _ in
            runtime.gate.stop() // the user pressed Stop while this ran
            return ToolOutput(ok: true, text: "done")
        }
        let llm = ScriptedLLM([toolReply(calls: [("shell.run", ["command": "a"]), ("shell.run", ["command": "b"])])])
        await #expect(throws: AutomationError.stopped) {
            try await makeRunner([stopper], llm: llm, runtime: runtime).execute(request(), callbacks: CallbackRecorder().callbacks)
        }
        #expect(stopper.calls.count == 1, "no call runs after Stop")
    }

    @Test func quickTaskToolsSeeTheSharedGateAndJobsAPrivateOne() async throws {
        let runtime = AutomationRuntime()
        let gates = Ledger()
        let probe = FakeTool("shell.run") { _, context in
            gates.add(context.gate === runtime.gate ? "shared" : "private")
            return ToolOutput(ok: true, text: "ok")
        }
        let quick = ScriptedLLM([toolReply(calls: [("shell.run", ["command": "a"])]), toolReply("step_done")])
        _ = try await makeRunner([probe], llm: quick, runtime: runtime).execute(request(), callbacks: CallbackRecorder().callbacks)
        let job = ScriptedLLM([toolReply(calls: [("shell.run", ["command": "a"])]), toolReply("step_done")])
        // A stopped shared gate (left over from a quick task) doesn't affect a job.
        runtime.gate.stop()
        let result = try await makeRunner([probe], llm: job, runtime: runtime).execute(request(jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .done)
        #expect(gates.all == ["shared", "private"])
    }

    @Test func cancellingAJobStepStopsTheRunningCall() async throws {
        let sawStop = Ledger()
        let longRunning = FakeTool("shell.run") { _, context in
            let end = Date().addingTimeInterval(5)
            while Date() < end, !context.gate.isStopped { try? await Task.sleep(for: .milliseconds(20)) }
            sawStop.add(context.gate.isStopped ? "stopped" : "timed out")
            return ToolOutput(ok: false, text: "killed")
        }
        let llm = ScriptedLLM(respond: { _, _ in toolReply(calls: [("shell.run", ["command": "sleep 60"])]) })
        let runner = makeRunner([longRunning], llm: llm)
        let task = Task { try await runner.execute(request(jobID: "job-1"), callbacks: CallbackRecorder().callbacks) }
        for _ in 0..<200 where longRunning.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: AutomationError.stopped) { try await task.value }
        for _ in 0..<200 where sawStop.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sawStop.all == ["stopped"])
    }

    @Test func hungToolsTimeOut() async throws {
        let sawStop = Ledger()
        let hung = FakeTool("shell.run") { _, context in
            // Ignores cancellation on purpose; only the gate ends it.
            let end = Date().addingTimeInterval(3)
            while Date() < end, !context.gate.isStopped { try? await Task.sleep(for: .milliseconds(20)) }
            sawStop.add(context.gate.isStopped ? "gate stopped" : "ran out")
            return ToolOutput(ok: true, text: "late")
        }
        let llm = ScriptedLLM([toolReply(calls: [("shell.run", ["command": "hang"])]), toolReply("blocked", message: "It hangs")])
        var runner = makeRunner([hung], llm: llm)
        runner.callTimeout = 0.2
        let start = Date()
        let result = try await runner.execute(request(jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        // The hung tool would run 3 s on its own; "gate stopped" below proves the timeout ended
        // it. The margin is wide because a loaded machine runs this suite slowly.
        #expect(Date().timeIntervalSince(start) < 2.9)
        #expect(result.status == .blocked("It hangs"))
        #expect(llm.userMessages[1].contains("didn't finish within"))
        for _ in 0..<200 where sawStop.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sawStop.all == ["gate stopped"])
    }

    @Test func onlyAllowedFamiliesAreListedAndCallable() async throws {
        let shell = FakeTool("shell.run")
        let click = FakeTool("browser.click", category: .browser)
        let llm = ScriptedLLM([toolReply(calls: [("browser.click", ["ref": "b1"])]), toolReply("step_done")])
        _ = try await makeRunner([shell, click], llm: llm).execute(request(), callbacks: CallbackRecorder().callbacks)
        #expect(click.calls.isEmpty)
        #expect(!llm.userMessages[0].contains("browser.click"))
        #expect(llm.userMessages[1].contains("isn't available in this step"))
    }

    @Test func backgroundStepsCantUseScreenTools() async throws {
        let open = FakeTool("system.open", category: .system, needsScreen: true)
        let shell = FakeTool("shell.run")
        let llm = ScriptedLLM([toolReply(calls: [("system.open", ["target": "Notes"])]), toolReply("step_done")])
        _ = try await makeRunner([open, shell], llm: llm).execute(request(jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(open.calls.isEmpty)
        #expect(!llm.userMessages[0].contains("system.open"))
    }

    @Test func missingToolFamiliesFailClearly() async throws {
        let llm = ScriptedLLM([])
        let result = try await makeRunner([FakeTool("shell.run")], llm: llm)
            .execute(request(commandStep(route: .web)), callbacks: CallbackRecorder().callbacks)
        guard case .failed(let reason) = result.status else { Issue.record("expected failure"); return }
        #expect(reason.contains("web tools aren't available"))
        #expect(llm.requests.isEmpty)
    }

    @Test func unconfiguredModelFailsWithoutRetrying() async throws {
        var settings = AppSettings()
        settings.providers = []
        let creds = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        creds.useMemoryOnly()
        let tool = FakeTool("shell.run")
        let runner = ToolStepRunner(settings: settings, runtime: AutomationRuntime(), tools: ToolRegistry([tool]), credentials: creds, integrations: .disabled)
        let result = try await runner.execute(request(), callbacks: CallbackRecorder().callbacks)
        guard case .failed(let reason) = result.status else { Issue.record("expected failure"); return }
        #expect(reason.contains("No AI provider"))
        #expect(result.modelCalls == 0 && tool.calls.isEmpty)
    }

    @Test func browserCallsCarryTheElementNameFromTheLatestSnapshot() async throws {
        let snapshot = FakeTool("browser.snapshot", category: .browser) { _, _ in
            ToolOutput(ok: true, text: "Account settings — https://example.test/account\nb1 link \"Home\"\nb7 button \"Delete account\" [focused]")
        }
        let click = FakeTool("browser.click", category: .browser, verdict: { args in
            let label = args["_label"]?.stringValue ?? ""
            return label.lowercased().contains("delete") ? ToolVerdict(risk: .high, reasons: ["clicking “\(label)”"], summary: "Click “\(label)”")
                                                         : ToolVerdict(risk: .low, summary: "Click “\(label)”")
        })
        let llm = ScriptedLLM([
            toolReply(calls: [("browser.click", ["ref": "b7"])]),                  // no snapshot yet → refused
            toolReply(calls: [("browser.snapshot", [:])]),
            toolReply(calls: [("browser.click", ["ref": "b7", "_label": "Next"])]),  // the model's own _label is ignored
            toolReply("step_done", message: "Deleted"),
        ])
        let rec = CallbackRecorder([.approve])
        let result = try await makeRunner([snapshot, click], llm: llm).execute(request(commandStep(route: .browser)), callbacks: rec.callbacks)
        #expect(result.status == .done)
        #expect(llm.userMessages[1].contains("isn't in the latest page snapshot"))
        #expect(click.assessed.map { $0["_label"]?.stringValue } == ["Delete account"])
        #expect(click.calls.count == 1)
        #expect(rec.approvals.first?.title == "Click “Delete account”")
        #expect(rec.approvals.first?.risk == .high)
    }

    @Test func runnerOnlyArgumentsAreStripped() async throws {
        let tool = FakeTool("shell.run")
        let llm = ScriptedLLM([toolReply(calls: [("shell.run", ["command": "ls", "_trusted": true, "_label": "x"])]), toolReply("step_done")])
        _ = try await makeRunner([tool], llm: llm).execute(request(), callbacks: CallbackRecorder().callbacks)
        #expect(tool.calls == [["command": "ls"]])
    }

    @Test func answerRouteWritesWithoutTools() async throws {
        let llm = ScriptedLLM([["message": "It's 9 pm in Tokyo.", "result_fields_json": .null]])
        let quick = try await makeRunner([], llm: llm).execute(request(commandStep(route: .answer)), callbacks: CallbackRecorder().callbacks)
        #expect(quick.status == .taskDone("It's 9 pm in Tokyo."))
        #expect(llm.requests.first?.system.contains("You write the result of a step") == true)

        let verify = ScriptedLLM([["message": "All rows have results", "result_fields_json": .string(#"{"done":true,"reason":"25 of 25 rows"}"#)]])
        let job = try await makeRunner([], llm: verify)
            .execute(request(commandStep(outputFields: ["done", "reason"], route: .answer), jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(job.status == .done)
        #expect(job.fields == ["done": true, "reason": "25 of 25 rows"])
        #expect(job.output == "All rows have results")
    }

    @Test func taskDoneInAJobIsJustDone() async throws {
        let llm = ScriptedLLM([toolReply("task_done", message: "All finished")])
        let result = try await makeRunner([FakeTool("shell.run")], llm: llm).execute(request(jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .done)
        #expect(result.output == "All finished")
        let quick = ScriptedLLM([toolReply("task_done", message: "All finished")])
        let q = try await makeRunner([FakeTool("shell.run")], llm: quick).execute(request(), callbacks: CallbackRecorder().callbacks)
        #expect(q.status == .taskDone("All finished"))
    }

    @Test func mcpToolsRunThroughAdapters() async throws {
        let calls = Ledger()
        let integrations = ToolStepRunner.Integrations(
            composio: { nil },
            mcpTools: {
                [MCPTool(server: "mock", name: "echo", description: "Echo text back.", inputSchema: ["type": "object"]),
                 MCPTool(server: "mock", name: "send_message", description: "Send a chat message.", inputSchema: ["type": "object"])]
            },
            mcpCall: { name, args in
                calls.add(name)
                return ("echo: \(args["text"]?.stringValue ?? "")", false)
            })
        let llm = ScriptedLLM([
            toolReply(calls: [("mock__echo", ["text": "hi"])]),
            toolReply(calls: [("mock__send_message", ["text": "hello team"])]),
            toolReply("step_done", message: "Echoed"),
        ])
        let rec = CallbackRecorder([.reject])
        let result = try await makeRunner([], llm: llm, integrations: integrations).execute(request(commandStep(route: .mcp)), callbacks: rec.callbacks)
        #expect(result.status == .done)
        #expect(calls.all == ["mock__echo"], "send_message is high risk and was declined")
        #expect(rec.approvals.map(\.title) == ["Run send_message on mock"])
        #expect(llm.userMessages[1].contains("echo: hi"))
        #expect(rec.logs.contains { $0.kind == .tool && $0.route == .mcp && $0.success == true })

        let none = try await makeRunner([], llm: ScriptedLLM([])).execute(request(commandStep(route: .mcp)), callbacks: CallbackRecorder().callbacks)
        #expect(none.status == .failed("No MCP servers are connected."))
    }

    @Test func integrationToolsInheritTheStepRisk() async throws {
        let integrations = ToolStepRunner.Integrations(composio: { nil },
                                                       mcpTools: { [MCPTool(server: "crm", name: "update_contact", description: "", inputSchema: ["type": "object"])] },
                                                       mcpCall: { _, _ in ("ok", false) })
        let llm = ScriptedLLM([toolReply(calls: [("crm__update_contact", ["id": "1"])]), toolReply("step_done")])
        let rec = CallbackRecorder([.approve])
        _ = try await makeRunner([], llm: llm, integrations: integrations)
            .execute(request(commandStep(route: .mcp, risk: .high)), callbacks: rec.callbacks)
        #expect(rec.approvals.first?.risk == .high)
    }

    @Test func remembersGoToTheOutput() async throws {
        let llm = ScriptedLLM([toolReply(calls: [("shell.run", ["command": "date"])], remember: "Today is Friday"), toolReply("step_done", message: "Checked the date")])
        let result = try await makeRunner([FakeTool("shell.run")], llm: llm).execute(request(), callbacks: CallbackRecorder().callbacks)
        #expect(result.output == "Today is Friday\nChecked the date")
    }
}

// MARK: - Decoding and schemas

@Suite("Step runner schemas")
struct StepRunnerSchemaTests {
    @Test func schemasAreStrict() {
        expectStrict(PlanSchema.schema)
        expectStrict(ActorSchema.schema)
        expectStrict(ToolDecisionSchema.schema(maxBatch: 6))
        expectStrict(ToolDecisionSchema.answerSchema)
        #expect(PlanSchema.schema["properties"]?["mode"]?["enum"] == JSONValue.array(["quick", "job"]))
        #expect(ActorSchema.schema["properties"]?["actions"] != nil)
    }

    @Test func planModeDecodes() throws {
        func plan(_ mode: String?) throws -> Plan {
            var json: [String: JSONValue] = ["goal": "g", "clarification": .null, "steps": [[
                "title": "Researching", "instruction": "i", "route": "web", "app": .null, "risk": "low", "done_when": "d",
                "hint_action": "none", "hint_target": .null, "hint_text": .null]]]
            if let mode { json["mode"] = .string(mode) }
            return try PlanSchema.decode(.object(json))
        }
        #expect(try plan("job").mode == .job)
        #expect(try plan("quick").mode == .quick)
        #expect(try plan(nil).mode == .quick)
        #expect(try plan("marathon").mode == .quick)
        #expect(try plan("job").steps.first?.route == .web)
    }

    @Test func plansWithoutModeStillLoadFromHistory() throws {
        let old = #"{"goal":"g","steps":[],"clarification":null}"#
        let decoded = try JSONDecoder().decode(Plan.self, from: Data(old.utf8))
        #expect(decoded.mode == .quick)
        let job = Plan(goal: "g", steps: [], clarification: nil, mode: .job)
        #expect(try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(job)).mode == .job)
    }

    @Test func actorFollowUpsDecode() throws {
        let j = try JSONValue.parse("""
        {"thought":"fill the form","status":"act","action":"type","element_id":"e3","target_description":null,"text":"Ada","keys":null,
         "direction":null,"amount":null,"to_element_id":null,"app":null,"url":null,"menu_path":null,"clear_first":true,"submit":false,
         "expect":null,"risk":"low","remember":null,"message":null,"tool_name":null,"tool_arguments_json":null,"result_fields_json":"{\\"name\\":\\"Ada\\"}",
         "actions":[
           {"action":"type","element_id":"e4","target_description":null,"text":"Lovelace","keys":null,"direction":null,"amount":null,
            "to_element_id":null,"app":null,"url":null,"menu_path":null,"clear_first":null,"submit":null,"expect":null,"risk":"low"},
           {"action":"none","element_id":null,"target_description":null,"text":null,"keys":null,"direction":null,"amount":null,
            "to_element_id":null,"app":null,"url":null,"menu_path":null,"clear_first":null,"submit":null,"expect":null,"risk":"low"},
           {"action":"click","element_id":"e9","target_description":null,"text":null,"keys":null,"direction":null,"amount":null,
            "to_element_id":null,"app":null,"url":null,"menu_path":null,"clear_first":null,"submit":null,"expect":"Saved","risk":"medium"}
         ]}
        """)
        let d = ActorSchema.decode(j)
        #expect(d.action == "type" && d.elementID == "e3" && d.clearFirst)
        #expect(d.followUps.map(\.action) == ["type", "click"])
        #expect(d.followUps[1].expect == "Saved" && d.followUps[1].risk == .medium)
        #expect(d.resultFields == ["name": "Ada"])
        #expect(!ActorSchema.sameAction(d, d.followUps[0]))
        var dup = d.followUps[0]
        dup.elementID = "e3"
        dup.text = "Ada"
        #expect(ActorSchema.sameAction(d, dup))

        // The batch is capped, and old replies without the new fields still decode.
        var many = j.objectValue ?? [:]
        many["actions"] = .array(Array(repeating: j["actions"]?[0] ?? .null, count: 9))
        #expect(ActorSchema.decode(.object(many)).followUps.count == ActorSchema.maxFollowUps)
        many["actions"] = nil
        many["result_fields_json"] = nil
        #expect(ActorSchema.decode(.object(many)).followUps.isEmpty)
    }

    @Test func toolDecisionsDecodeTolerantly() throws {
        let j = try JSONValue.parse("""
        {"thought":"t","status":"ACT","calls":[
          {"tool":"shell.run","arguments_json":"{\\"command\\":\\"ls\\"}"},
          {"tool":"browser.snapshot","arguments_json":""},
          {"tool":"fs.read","arguments":{"path":"~/a"}},
          {"tool":"fs.list","arguments_json":"not json"},
          {"tool":"","arguments_json":"{}"}
        ],"result_fields_json":"oops","message":null,"remember":"  "}
        """)
        let d = ToolDecisionSchema.decode(j)
        #expect(d.status == .act)
        #expect(d.calls.map(\.tool) == ["shell.run", "browser.snapshot", "fs.read", "fs.list"])
        #expect(d.calls[0].arguments == ["command": "ls"])
        #expect(d.calls[1].arguments == .object([:]))
        #expect(d.calls[2].arguments == ["path": "~/a"])
        #expect(d.calls[3].arguments == nil)
        #expect(d.resultFieldsUnreadable)
        #expect(d.remember == nil)
        #expect(d.calls[0].signature == d.calls[0].signature && d.calls[0].signature != d.calls[2].signature)
        #expect(ToolDecisionSchema.decode(["status": "whatever"]).status == .act)
    }

    @Test func browserRefsParseTextAndData() {
        let text = """
        Example — https://example.test
        b1 link "Home"
          b12 button "Sign in" [disabled]
        - b13 textbox "Email" value="[secure]"
        [b14] checkbox "Remember me"
        b15 button
        abc b99 "not a ref line"
        """
        let refs = BrowserRefs.parse(ToolOutput(ok: true, text: text))
        #expect(refs["b1"] == "Home" && refs["b12"] == "Sign in" && refs["b13"] == "Email" && refs["b14"] == "Remember me")
        #expect(refs["b15"] == "")
        #expect(refs["b99"] == nil)
        let data = BrowserRefs.parse(ToolOutput(ok: true, text: "snapshot", data: ["elements": [["ref": "b3", "role": "button", "name": "Pay now"]]]))
        #expect(data == ["b3": "Pay now"])

        var state = BrowserRefs()
        state.absorb(tool: "browser.snapshot", output: ToolOutput(ok: true, text: text))
        #expect(state.label(for: "b12") == "Sign in")
        #expect(state.label(for: "12") == nil, "only real refs resolve")
        state.absorb(tool: "browser.read", output: ToolOutput(ok: true, text: "Some article text"))
        #expect(state.label(for: "b12") == "Sign in", "reading doesn't invalidate refs")
        state.absorb(tool: "browser.open", output: ToolOutput(ok: true, text: "Opened https://other.test"))
        #expect(state.label(for: "b12") == nil, "navigating does")
        state.absorb(tool: "shell.run", output: ToolOutput(ok: true, text: "b5 button \"Fake\""))
        #expect(state.label(for: "b5") == nil, "only browser tools provide refs")
    }

    @Test func routeAvailabilityRendersForThePlanner() async {
        let r = RouteAvailability(executionPreference: .fastest, commandAccess: .readOnly, toolFamilies: [.command, .files, .web, .browser],
                                  browser: BrowserStatus(backend: .extensionBridge, connected: false, detail: "Not connected", chromeInstalled: true, extensionPaired: false),
                                  browserOnDemand: false, accessibilityGranted: false, backgroundJobs: true)
        let text = PlanningContext(routes: r).rendered
        #expect(text.contains("Execution preference: Fastest"))
        #expect(text.contains("- command: available (read-only commands only"))
        #expect(text.contains("- web: available"))
        #expect(text.contains("- data: UNAVAILABLE (no spreadsheet tools are installed)"))
        #expect(text.contains("- browser: UNAVAILABLE (no browser is connected)"))
        #expect(text.contains("- gui: UNAVAILABLE (Accessibility permission isn't granted)"))
        #expect(text.contains("Background jobs: available"))
        #expect(r.isAvailable(.command) && r.isAvailable(.web) && !r.isAvailable(.data) && !r.isAvailable(.gui) && r.isAvailable(.answer))

        var off = r
        off.commandAccess = .off
        off.browser?.connected = true
        off.backgroundJobs = false
        off.executionPreference = .showMe
        #expect(!off.isAvailable(.command) && off.isAvailable(.browser))
        let offText = PlanningContext(routes: off).rendered
        #expect(offText.contains("command access is off") && offText.contains("always use mode quick") && offText.contains("Show me"))
        #expect(!PlanningContext().rendered.contains("Routes available now"))

        // Live status: browser tools installed but no backend registered → unavailable.
        let live = await RouteAvailability.current(settings: AppSettings(), tools: ToolRegistry([FakeTool("browser.open", category: .browser)]),
                                                   backgroundJobs: false, hub: BrowserHub())
        #expect(live.toolFamilies == [.browser] && !live.isAvailable(.browser) && !live.isAvailable(.command))
    }
}

// MARK: - StepRouter

/// Records which routes it was asked to run.
final class RecordingExecutor: StepExecuting, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var _routes: [ExecutionRoute] = []
    init(_ name: String) { self.name = name }
    var routes: [ExecutionRoute] { lock.withLock { _routes } }
    func execute(_ request: StepRequest, callbacks: AgentCallbacks) async throws -> StepResult {
        lock.withLock { _routes.append(request.step.route) }
        return StepResult(status: .done, output: name)
    }
}

@Suite("StepRouter")
struct StepRouterTests {
    @Test func dispatchesByRoute() async throws {
        let gui = RecordingExecutor("gui"), tools = RecordingExecutor("tools")
        let router = StepRouter(gui: gui, tools: tools)
        for route in ExecutionRoute.allCases {
            let r = try await router.execute(StepRequest(goal: "g", step: RecipeStep(id: 1, title: "t", instruction: "i", route: route)), callbacks: AgentCallbacks())
            #expect(r.output == (route == .gui || route == .native ? "gui" : "tools"), "\(route)")
        }
        #expect(gui.routes == [.gui, .native])
        #expect(Set(tools.routes) == [.command, .browser, .web, .data, .composio, .mcp, .answer])
    }

    @Test func installsTheStandardFactory() {
        let previous = StepExecutorFactory.make
        StepRouter.install()
        let made = StepExecutorFactory.make?(AppSettings(), AutomationRuntime(), ToolRegistry())
        StepExecutorFactory.make = previous
        #expect(made is StepRouter)
    }

    @Test func noteKeysAreStablePerItem() {
        #expect(workspaceNoteKey(stepID: 3, itemID: "job-1/3/17", index: 0) == "note:step3:item17:0")
        #expect(workspaceNoteKey(stepID: 2, itemID: nil, index: 1) == "note:step2:1")
    }
}

// MARK: - Orchestrator end to end (scripted model over HTTP)

/// The scripted OpenAI-compatible server from `nb-mock-servers llm`, on a free local port.
struct MockLLMServer {
    let process: Process
    let port: Int
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    struct StartError: Error, CustomStringConvertible {
        var description: String { "the mock LLM server didn't start" }
    }

    static func start(_ executable: URL) async throws -> MockLLMServer {
        for _ in 0..<4 {
            let port = Int.random(in: 20000...45000)
            let p = Process()
            p.executableURL = executable
            p.arguments = ["llm", String(port)]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            var probe = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
            probe.timeoutInterval = 0.5
            for _ in 0..<40 where p.isRunning {
                if let (data, _) = try? await URLSession.shared.data(for: probe), String(decoding: data, as: UTF8.self).contains("mock") {
                    return MockLLMServer(process: p, port: port)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
        }
        throw StartError()
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

@Suite("Orchestrator tool routes", .serialized)
struct OrchestratorToolRouteTests {
    func settings(_ server: MockLLMServer) -> AppSettings {
        var s = AppSettings()
        s.providers = [ProviderConfig(id: "mock", kind: .openaiCompatible, name: "Mock", baseURL: server.baseURL, requiresKey: false, models: ["mock"])]
        s.routing.preferredProviderID = "mock"
        s.safety.pauseOnUserInput = false
        s.keepHistory = true
        return s
    }

    func credentials() -> CredentialStore {
        let c = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        c.useMemoryOnly()
        return c
    }

    @Test func commandRouteRunsEndToEnd() async throws {
        let executable = try #require(productURL("nb-mock-servers"), "run `swift build` first so the mock servers exist")
        let server = try await MockLLMServer.start(executable)
        defer { server.stop() }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("glide-steps-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try LocalStore(path: path)
        let shell = FakeTool("shell.run") { args, _ in
            ToolOutput(ok: true, text: (args["command"]?.stringValue ?? "").replacingOccurrences(of: "echo ", with: ""))
        }
        let rec = CallbackRecorder()
        let orchestrator = ExecutionOrchestrator(instruction: "Run the tool-route check", settings: settings(server), runtime: AutomationRuntime(),
                                                 callbacks: rec.callbacks, store: store, credentials: credentials(), tools: ToolRegistry([shell]))
        orchestrator.screenContext = false
        let result = await orchestrator.run()
        #expect(result.status == .completed, "\(result.summary) \(result.error ?? "")")
        #expect(result.summary == "Both commands ran: hello world")
        #expect(result.plan?.steps.map(\.route) == [.command])
        #expect(shell.calls.map { $0["command"]?.stringValue } == ["echo hello", "echo world"])
        #expect(result.metrics.modelCalls == 3) // planner, then two executor turns
        #expect(result.metrics.actions == 2)
        #expect(result.jobID == nil)
        let events = store.events(taskID: orchestrator.taskID)
        #expect(events.filter { $0.kind == .tool && $0.route == .command }.count == 2)
        #expect(store.task(id: orchestrator.taskID)?.status == "completed")
    }

    @Test func jobModePlansAreHandedToTheJobEngine() async throws {
        let executable = try #require(productURL("nb-mock-servers"), "run `swift build` first so the mock servers exist")
        let server = try await MockLLMServer.start(executable)
        defer { server.stop() }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("glide-jobs-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try LocalStore(path: path)
        let handedOff = Ledger()
        let handoff: ExecutionOrchestrator.JobHandoff = { instruction, plan in
            handedOff.add("\(instruction)|\(plan.mode.rawValue)")
            return JobRecord(id: "job-42", title: "Research companies", instruction: instruction, status: .running, folder: NSTemporaryDirectory())
        }
        let shell = FakeTool("shell.run")
        let orchestrator = ExecutionOrchestrator(instruction: "Do the background-job research", settings: settings(server), runtime: AutomationRuntime(),
                                                 callbacks: CallbackRecorder().callbacks, store: store, credentials: credentials(),
                                                 tools: ToolRegistry([shell]), jobHandoff: handoff)
        orchestrator.screenContext = false
        let result = await orchestrator.run()
        #expect(result.status == .completed)
        #expect(result.jobID == "job-42")
        #expect(result.summary == "Started a background job: Research companies")
        #expect(handedOff.all == ["Do the background-job research|job"])
        #expect(result.metrics.modelCalls == 1)
        #expect(shell.calls.isEmpty)

        let failing: ExecutionOrchestrator.JobHandoff = { instruction, _ in
            var job = JobRecord(id: "job-43", title: "t", instruction: instruction, status: .failed, folder: NSTemporaryDirectory())
            job.lastError = "Couldn't plan the job: the sheet is empty."
            return job
        }
        let second = ExecutionOrchestrator(instruction: "Do the background-job research", settings: settings(server), runtime: AutomationRuntime(),
                                           callbacks: CallbackRecorder().callbacks, store: store, credentials: credentials(),
                                           tools: ToolRegistry([shell]), jobHandoff: failing)
        second.screenContext = false
        let failed = await second.run()
        #expect(failed.status == .failed)
        #expect(failed.error == "Couldn't plan the job: the sheet is empty.")
        #expect(failed.jobID == "job-43")
    }
}

// MARK: - Tool names and integration risk

@Suite("SafetyPolicy tool names")
struct SafetyToolNameTests {
    let policy = SafetyPolicy(settings: SafetySettings())

    @Test func toolNamesInAnyStyleBecomeWords() {
        #expect(SafetyPolicy.toolNameWords("API-delete-a-block") == "api delete a block")
        #expect(SafetyPolicy.toolNameWords("deleteRecord") == "delete record")
        #expect(SafetyPolicy.toolNameWords("sendHTTPRequest") == "send http request")
        #expect(SafetyPolicy.toolNameWords("GMAIL_SEND_EMAIL") == "gmail send email")
        #expect(SafetyPolicy.toolNameWords("files/delete.v2") == "files delete v2")
        #expect(SafetyPolicy.toolNameWords("slack:post__message") == "slack post message")
    }

    @Test func destructiveNamesAreHighRiskInEveryStyle() {
        for name in ["API-delete-a-block", "deleteRecord", "sendMessage", "gmail.send", "files/delete", "post-message", "DeleteRecord",
                     "emptyTrash", "placeOrder", "dropTable", "drop_database", "GMAIL_SEND_EMAIL", "stripe_create_refund", "replyToThread",
                     "GMAIL_MOVE_TO_TRASH", "STRIPE_CREATE_CHARGE", "send_invite", "GITHUB_MERGE_A_PULL_REQUEST",
                     // A read verb first doesn't excuse a strong verb later in the name.
                     "get_and_delete", "search_and_replace", "fetchThenSend", "search_console_delete_site"] {
            #expect(policy.assessTool(name: name, risk: .low).risk == .high, "\(name)")
        }
        for name in ["getRecord", "listBlocks", "API-retrieve-a-page", "GMAIL_FETCH_EMAILS", "dropbox_list_files"] {
            #expect(policy.assessTool(name: name, risk: .low).risk == .low, "\(name)")
        }
        #expect(policy.assessTool(name: "API-update-a-block", risk: .low).risk == .medium)
        #expect(policy.assessTool(name: "updateContact", risk: .low).risk == .medium)
        #expect(policy.assessTool(name: "get_or_create_user", risk: .low).risk == .medium)
    }

    /// The reviewer's false positives: an HTTP method spelled into an OpenAPI name, and risky
    /// nouns that a read verb is applied to.
    @Test func readsOfRiskyNounsAreNotHighRisk() {
        for name in ["API-post-search", "API-post-database-query", "getPost", "getPostComments", "get_post", "STRIPE_RETRIEVE_A_CHARGE",
                     "get_invite", "gitlab_get_merge_request", "getShareLink", "post_search", "postSearch", "list_trash", "GMAIL_GET_DRAFT"] {
            #expect(policy.assessTool(name: name, risk: .low).risk == .low, "\(name)")
        }
        // Drag and drop in a browser isn't dropping a table.
        #expect(policy.assessTool(name: "browser_drop", risk: .low).risk == .low)
        // A write method in an OpenAPI name is a write.
        #expect(policy.assessTool(name: "API-patch-page", risk: .low).risk == .medium)
        #expect(policy.assessTool(name: "API-post-page", risk: .low).risk == .medium)
    }

    @Test func integrationToolsRateByWhatTheyDo() {
        // Reads stay low, so "Ask for medium and high" doesn't ask about every lookup.
        for name in ["get_current_time", "GMAIL_FETCH_EMAILS", "notion-search", "API-retrieve-a-page", "get-library-docs", "resolve-library-id",
                     "read_file", "API-post-search", "API-post-database-query", "API-get-self", "getPost", "STRIPE_RETRIEVE_A_CHARGE",
                     "list_directory", "read_query"] {
            #expect(policy.assessIntegrationTool(name: name, arguments: [:]).risk == .low, "\(name)")
        }
        // Anything that doesn't say it reads is at least medium: writes, and names with no verb.
        for name in ["write_query", "run_query", "execute_sql", "browser_click", "browser_drop", "API-post-page", "API-patch-page",
                     "sequentialthinking", "request", "write_file", "GMAIL_CREATE_EMAIL_DRAFT"] {
            #expect(policy.assessIntegrationTool(name: name, arguments: [:]).risk == .medium, "\(name)")
        }
        #expect(policy.assessIntegrationTool(name: "API-delete-a-block", arguments: ["block_id": "b1"]).risk == .high)
        #expect(policy.assessIntegrationTool(name: "GMAIL_SEND_EMAIL", arguments: [:]).risk == .high)
        let delete = policy.assessIntegrationTool(name: "request", arguments: ["method": "delete", "url": "https://api.test/items/1"])
        #expect(delete.risk == .high && delete.reasons.contains("HTTP DELETE"))
        #expect(policy.assessIntegrationTool(name: "request", arguments: ["httpMethod": "GET"]).risk == .medium)
        #expect(policy.assessIntegrationTool(name: "fetch", arguments: ["method": "GET"]).risk == .low)
        #expect(policy.assessIntegrationTool(name: "fetch", arguments: ["method": "POST"]).risk == .medium)

        let context = ToolContext(settings: AppSettings(), gate: ExecutionGate(), log: { _ in })
        let mcp = MCPToolAdapter(tool: MCPTool(server: "notion", name: "API-get-self", description: "", inputSchema: ["type": "object"]),
                                 call: { _, _ in ("", false) })
        #expect(mcp.assess([:], context: context).risk == .low)
        let write = MCPToolAdapter(tool: MCPTool(server: "sqlite", name: "write_query", description: "", inputSchema: ["type": "object"]),
                                   call: { _, _ in ("", false) })
        #expect(write.assess([:], context: context).risk == .medium)
        let composio = ComposioToolAdapter(schema: .init(slug: "NOTION_DELETE_BLOCK", toolkit: "notion", description: "", inputSchema: nil),
                                           client: ComposioClient(apiKey: "test", settings: ComposioSettings()), sessionID: "s")
        #expect(composio.assess([:], context: context).risk == .high)
    }

    /// The reported case: a medium step calls a kebab-case delete tool. It must ask first.
    @Test func kebabCaseDeleteInAMediumStepNeedsApproval() async throws {
        let calls = Ledger()
        let integrations = ToolStepRunner.Integrations(
            composio: { nil },
            mcpTools: { [MCPTool(server: "notion", name: "API-delete-a-block", description: "Delete a block.", inputSchema: ["type": "object"])] },
            mcpCall: { name, _ in calls.add(name); return ("deleted", false) })
        let llm = ScriptedLLM([toolReply(calls: [("notion__API-delete-a-block", ["block_id": "b1"])]), toolReply("step_done", message: "Tidied")])
        let rec = CallbackRecorder([.reject])
        _ = try await makeRunner([], llm: llm, integrations: integrations)
            .execute(request(commandStep(route: .mcp, risk: .medium)), callbacks: rec.callbacks)
        #expect(rec.approvals.map(\.risk) == [.high])
        #expect(calls.all.isEmpty, "declined, so the delete never ran")
    }

    /// A for_each job that searches Notion for every row mustn't stop on "Waiting for your OK"
    /// for each one, even when the user asks about medium-risk actions.
    @Test func searchingWithPostRunsWithoutApproval() async throws {
        for level in [ApprovalLevel.highRiskOnly, .mediumAndHigh] {
            let calls = Ledger()
            let integrations = ToolStepRunner.Integrations(
                composio: { nil },
                mcpTools: { [MCPTool(server: "notion", name: "API-post-search", description: "Search pages.", inputSchema: ["type": "object"]),
                             MCPTool(server: "time", name: "get_current_time", description: "The time.", inputSchema: ["type": "object"])] },
                mcpCall: { name, _ in calls.add(name); return ("found", false) })
            let llm = ScriptedLLM([toolReply(calls: [("notion__API-post-search", ["query": "Acme"]), ("time__get_current_time", [:])]),
                                   toolReply("step_done", message: "Found it")])
            var settings = AppSettings()
            settings.safety.approvalLevel = level
            let rec = CallbackRecorder()
            let result = try await makeRunner([], llm: llm, settings: settings, integrations: integrations)
                .execute(request(commandStep(route: .mcp), jobID: "job-1"), callbacks: rec.callbacks)
            #expect(result.status == .done)
            #expect(rec.approvals.isEmpty, "\(level)")
            #expect(calls.all == ["notion__API-post-search", "time__get_current_time"])
        }
    }
}

// MARK: - result_fields_json as an object

@Suite("Result fields decoding")
struct ResultFieldsDecodingTests {
    @Test func resultFieldsAcceptAnObjectOrAString() {
        let object = StepResult.decodeResultFields(["price": "$20"])
        #expect(object.fields == ["price": "$20"] && !object.unreadable)
        let string = StepResult.decodeResultFields(.string("{\"price\":\"$20\"}"))
        #expect(string.fields == ["price": "$20"] && !string.unreadable)
        for absent: JSONValue? in [nil, .null, .string(""), .string("null")] {
            let r = StepResult.decodeResultFields(absent)
            #expect(r.fields == nil && !r.unreadable)
        }
        for bad: JSONValue in [.string("oops"), .array(["$20"]), .number(20)] {
            let r = StepResult.decodeResultFields(bad)
            #expect(r.fields == nil && r.unreadable)
        }
    }

    @Test func decodersAcceptObjectFields() {
        let tool = ToolDecisionSchema.decode(["status": "step_done", "calls": [], "result_fields_json": ["price": "$20"]])
        #expect(tool.resultFields == ["price": "$20"] && !tool.resultFieldsUnreadable)
        let actor = ActorSchema.decode(["status": "step_done", "action": "none", "risk": "low", "result_fields_json": ["price": "$20"],
                                        "tool_arguments_json": ["to": "a@b.c"]])
        #expect(actor.resultFields == ["price": "$20"])
        #expect(actor.toolArguments?["to"]?.stringValue == "a@b.c")
    }

    @Test func jobStepKeepsObjectFieldsWithoutAReminder() async throws {
        let done: JSONValue = ["thought": "t", "status": "step_done", "calls": [], "result_fields_json": ["price": "$20"],
                               "message": "Found it", "remember": .null]
        let llm = ScriptedLLM([done])
        let result = try await makeRunner([FakeTool("shell.run")], llm: llm)
            .execute(request(commandStep(outputFields: ["price"]), jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(result.status == .done)
        #expect(result.fields == ["price": "$20"])
        #expect(result.modelCalls == 1)

        let answer = ScriptedLLM([["message": "The price is $20", "result_fields_json": ["price": "$20"]]])
        let written = try await makeRunner([], llm: answer)
            .execute(request(commandStep(outputFields: ["price"], route: .answer), jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(written.fields == ["price": "$20"])
        #expect(written.modelCalls == 1)
    }

    /// A step with no output fields doesn't need any, so an odd value (`[]`, `false`, text) the
    /// model sends with step_done is ignored instead of costing an error and another turn.
    @Test func stepsWithoutOutputFieldsIgnoreOddFields() async throws {
        for odd: JSONValue in [.array([]), .bool(false), .number(0), .string("none")] {
            let done: JSONValue = ["thought": "t", "status": "step_done", "calls": [], "result_fields_json": odd, "message": "Done", "remember": .null]
            let llm = ScriptedLLM([done])
            let result = try await makeRunner([FakeTool("shell.run")], llm: llm)
                .execute(request(commandStep(), jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
            #expect(result.status == .done, "\(odd)")
            #expect(result.modelCalls == 1, "\(odd)")
            #expect(result.fields.isEmpty)
        }
        // With output fields, the model is still asked to send them again.
        let bad: JSONValue = ["thought": "t", "status": "step_done", "calls": [], "result_fields_json": .array([]), "message": "Done", "remember": .null]
        let good: JSONValue = ["thought": "t", "status": "step_done", "calls": [], "result_fields_json": ["price": "$20"], "message": "Done", "remember": .null]
        let llm = ScriptedLLM([bad, good])
        let result = try await makeRunner([FakeTool("shell.run")], llm: llm)
            .execute(request(commandStep(outputFields: ["price"]), jobID: "job-1"), callbacks: CallbackRecorder().callbacks)
        #expect(result.fields == ["price": "$20"])
        #expect(result.modelCalls == 2)
        #expect(llm.userMessages.last?.contains("wasn't a valid JSON object") == true)
    }
}

// MARK: - Job steps and the user taking over

/// A user-input monitor the test fires by hand.
final class FakeInputMonitor: UserInputMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    var isRunning: Bool { lock.withLock { handler != nil } }
    func start(onUserInput: @escaping @Sendable () -> Void) { lock.withLock { handler = onUserInput } }
    func stop() { lock.withLock { handler = nil } }
    func userMovedTheMouse() { lock.withLock { handler }?() }
}

/// A value tests change while code under test polls it.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite("Job steps and user input")
struct JobStepUserInputTests {
    @Test func theWatchFollowsTheSettings() {
        let runtime = AutomationRuntime()
        let lease = ScreenLease(idleProbe: { 1000 })
        var settings = AppSettings()
        settings.jobs.idleSeconds = 45
        let idle = UserTakeoverWatch.forStep(request(jobID: "job-1"), settings: settings, runtime: runtime, lease: lease)
        #expect(idle?.mode == .anyInput && idle?.waitSeconds == 45)
        #expect(UserTakeoverWatch.forStep(request(), settings: settings, runtime: runtime, lease: lease) == nil,
                "quick tasks are watched by the orchestrator")
        settings.jobs.idleSeconds = 0
        #expect(UserTakeoverWatch.forStep(request(jobID: "job-1"), settings: settings, runtime: runtime, lease: lease)?.waitSeconds
                == UserTakeoverWatch.minimumIdleSeconds)
        // "Any time": only collisions count, and the wait is a short settle, not the idle time.
        settings.jobs.idleSeconds = 45
        settings.jobs.screenUse = .always
        let always = UserTakeoverWatch.forStep(request(jobID: "job-1"), settings: settings, runtime: runtime, lease: lease)
        #expect(always?.mode == .collisions && always?.waitSeconds == UserTakeoverWatch.minimumIdleSeconds)
        settings.safety.pauseOnUserInput = false
        #expect(UserTakeoverWatch.forStep(request(jobID: "job-1"), settings: settings, runtime: runtime, lease: lease) == nil)
        #expect(UserTakeoverWatch.leaseOwner(jobID: "job-1") == "job:job-1")
    }

    @Test func anyTimeCountsOnlyInputThatCollidesWithTheAgents() {
        let lastPost = Box(Date.distantPast)
        let monitor = FakeInputMonitor()
        let watch = UserTakeoverWatch(monitor: monitor, mode: .collisions, idleSeconds: 3, lastAgentInput: { lastPost.value })
        watch.start()
        monitor.userMovedTheMouse()
        #expect(!watch.userTookOver, "the user moving the mouse while the model thinks isn't a takeover")
        lastPost.value = Date()
        monitor.userMovedTheMouse()
        #expect(watch.userTookOver)

        let whenIdle = UserTakeoverWatch(monitor: FakeInputMonitor(), idleSeconds: 30)
        whenIdle.noteUserInput()
        #expect(whenIdle.userTookOver, "while the user is meant to be away, any input counts")
    }

    /// A step given the screen while the user is busy (the lease took their input for Glide's)
    /// waits before it touches anything; Glide's own recent input doesn't make it wait.
    @Test func aStepStartingWhileTheUserIsBusyWaitsFirst() {
        func watch(idle: Double, glideLastPosted: Double, mode: UserTakeoverWatch.Mode = .anyInput) -> UserTakeoverWatch {
            let posted = Date().addingTimeInterval(-glideLastPosted)
            return UserTakeoverWatch(monitor: FakeInputMonitor(), mode: mode, idleSeconds: 30, idleProbe: { idle }, lastAgentInput: { posted })
        }
        let busy = watch(idle: 2, glideLastPosted: 60)
        busy.noteRecentUserInput()
        #expect(busy.userTookOver, "the user's own input 2 seconds ago")
        let glide = watch(idle: 2, glideLastPosted: 2)
        glide.noteRecentUserInput()
        #expect(!glide.userTookOver, "the last input was the previous step's")
        let away = watch(idle: 45, glideLastPosted: 600)
        away.noteRecentUserInput()
        #expect(!away.userTookOver)
        let anyTime = watch(idle: 2, glideLastPosted: 60, mode: .collisions)
        anyTime.noteRecentUserInput()
        #expect(!anyTime.userTookOver, "with \"any time\" the user may be at the Mac")
    }

    @Test func waitsUntilTheUserIsIdleThenContinues() async throws {
        let monitor = FakeInputMonitor()
        let idle = Box(0.0)
        let watch = UserTakeoverWatch(monitor: monitor, idleSeconds: 5, idleProbe: { idle.value }, pollInterval: 0.01)
        watch.start()
        #expect(monitor.isRunning)
        monitor.userMovedTheMouse()
        #expect(watch.userTookOver)
        let finished = Box(false)
        let wait = Task {
            defer { finished.value = true }
            return try await watch.waitForIdleUser(gate: ExecutionGate())
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!finished.value, "still waiting while the user is active")
        #expect(!monitor.isRunning, "the idle time is what's watched meanwhile")
        idle.value = 6
        let waited = try await wait.value
        // The task may start late on a busy machine, so only "it waited" is reliable.
        #expect(waited > 0)
        #expect(!watch.userTookOver)
        #expect(monitor.isRunning, "watching again once the step carries on")

        // Answering an approval moves the mouse too; that's not a takeover.
        monitor.userMovedTheMouse()
        watch.clear()
        #expect(!watch.userTookOver)
        watch.stop()
        #expect(!monitor.isRunning)
    }

    /// The reviewer's case: the user comes back and starts a quick task while a job's step
    /// waits for them. The quick task gets the screen at once, its Stop doesn't end the job's
    /// wait, and the job takes the screen back after the task, with the gate cleared.
    @Test func givesTheScreenToAQuickTaskWhileWaiting() async throws {
        let lease = ScreenLease(idleProbe: { 1000 })
        try await lease.acquire(owner: "job:j1")
        let monitor = FakeInputMonitor()
        let idle = Box(0.0)
        let gate = ExecutionGate()
        let watch = UserTakeoverWatch(monitor: monitor, idleSeconds: 5, idleProbe: { idle.value }, lease: lease, leaseOwner: "job:j1",
                                      pollInterval: 0.01)
        watch.start()
        monitor.userMovedTheMouse()
        let finished = Box(false)
        let wait = Task {
            defer { finished.value = true }
            return try await watch.waitForIdleUser(gate: gate)
        }
        #expect(await eventually { await lease.currentHolder == nil })
        #expect(watch.screenHandedOver)
        #expect(!monitor.isRunning)

        // A quick task takes the screen straight away and uses the shared gate.
        try await lease.acquire(owner: "task:1", priority: true)
        #expect(await lease.currentHolder == "task:1")
        gate.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!finished.value, "the quick task's Stop is its own")

        // The user goes idle; the job queues behind the quick task.
        idle.value = 10
        #expect(await eventually { await lease.queueLength == 1 })
        #expect(!finished.value)
        await lease.release(owner: "task:1")
        _ = try await wait.value
        #expect(await lease.currentHolder == "job:j1")
        #expect(gate.current == .running, "the quick task's Stop is cleared before the job uses the screen")
        #expect(!watch.screenHandedOver)
        #expect(monitor.isRunning)
        await lease.release(owner: "job:j1")
    }

    @Test func takesTheScreenBackOnlyOnceTheUserIsIdleAgain() async throws {
        let lease = ScreenLease(idleProbe: { 1000 })
        try await lease.acquire(owner: "job:j1")
        let idle = Box(0.0)
        let watch = UserTakeoverWatch(monitor: FakeInputMonitor(), idleSeconds: 5, idleProbe: { idle.value }, lease: lease, leaseOwner: "job:j1",
                                      pollInterval: 0.01)
        watch.noteUserInput()
        let finished = Box(false)
        let wait = Task {
            defer { finished.value = true }
            return try await watch.waitForIdleUser(gate: ExecutionGate())
        }
        #expect(await eventually { await lease.currentHolder == nil })
        try await lease.acquire(owner: "task:1", priority: true)
        idle.value = 10
        #expect(await eventually { await lease.queueLength == 1 })
        // The user's input meanwhile (starting the quick task, say) means the Mac wasn't left alone after all.
        idle.value = 0
        await lease.release(owner: "task:1")
        #expect(await eventually {
            let holder = await lease.currentHolder
            let queued = await lease.queueLength
            return holder == nil && queued == 0
        })
        try await Task.sleep(for: .milliseconds(50))
        #expect(!finished.value, "the screen went back and the wait goes on")
        #expect(await lease.currentHolder == nil)
        idle.value = 10
        _ = try await wait.value
        #expect(await lease.currentHolder == "job:j1")
        await lease.release(owner: "job:j1")
    }

    @Test func stopAndCancellationEndTheWait() async throws {
        let monitor = FakeInputMonitor()
        let watch = UserTakeoverWatch(monitor: monitor, idleSeconds: 30, idleProbe: { 0 }, pollInterval: 0.01)
        watch.start()
        watch.noteUserInput()
        let cancelled = Task { try await watch.waitForIdleUser(gate: ExecutionGate()) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: AutomationError.stopped) { try await cancelled.value }

        // Keeping the screen (no lease to give up), the step's own gate still counts.
        let gate = ExecutionGate()
        let stopped = Task { try await watch.waitForIdleUser(gate: gate) }
        try await Task.sleep(for: .milliseconds(50))
        gate.stop()
        await #expect(throws: AutomationError.stopped) { try await stopped.value }
        watch.stop()

        // Stopping the job while its step waits for the screen leaves the queue and doesn't take it.
        let lease = ScreenLease(idleProbe: { 1000 })
        try await lease.acquire(owner: "job:j1")
        let idle = Box(0.0)
        let handedOver = UserTakeoverWatch(monitor: FakeInputMonitor(), idleSeconds: 5, idleProbe: { idle.value }, lease: lease,
                                           leaseOwner: "job:j1", pollInterval: 0.01)
        handedOver.noteUserInput()
        let queued = Task { try await handedOver.waitForIdleUser(gate: ExecutionGate()) }
        #expect(await eventually { await lease.currentHolder == nil })
        try await lease.acquire(owner: "task:1", priority: true)
        idle.value = 10
        #expect(await eventually { await lease.queueLength == 1 })
        queued.cancel()
        await #expect(throws: AutomationError.stopped) { try await queued.value }
        #expect(await eventually { await lease.queueLength == 0 })
        await lease.release(owner: "task:1")
        #expect(await lease.currentHolder == nil)
    }

    /// Pausing the step's job ends the wait, and the screen it gave up isn't taken back when
    /// the user walks away (nor once a quick task ahead of it finishes). Each wait is let go
    /// after a while, so a wait that ignores the pause fails the test instead of hanging it.
    @Test func pausingTheJobEndsTheWaitWithoutTakingTheScreenBack() async throws {
        let lease = ScreenLease(idleProbe: { 1000 })
        try await lease.acquire(owner: "job:j1")
        let idle = Box(0.0)
        let paused = Box(false)
        let watch = UserTakeoverWatch(monitor: FakeInputMonitor(), idleSeconds: 5, idleProbe: { idle.value }, lease: lease, leaseOwner: "job:j1",
                                      pollInterval: 0.01)
        watch.noteUserInput()
        let ended = Box(false)
        let wait = Task {
            defer { ended.value = true }
            return try await watch.waitForIdleUser(gate: ExecutionGate(), interrupted: { paused.value })
        }
        #expect(await eventually { await lease.currentHolder == nil })
        paused.value = true
        #expect(await eventually(timeout: 3) { ended.value }, "the pause ends the wait")
        idle.value = 10 // the user walks away
        await #expect(throws: AutomationError.stopped) { try await wait.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await lease.currentHolder == nil)
        #expect(watch.screenHandedOver, "the screen stays someone else's")

        // Queued behind a quick task when the job is paused: it leaves the queue.
        try await lease.acquire(owner: "job:j1")
        idle.value = 0
        paused.value = false
        watch.noteUserInput()
        let queuedEnded = Box(false)
        let queued = Task {
            defer { queuedEnded.value = true }
            return try await watch.waitForIdleUser(gate: ExecutionGate(), interrupted: { paused.value })
        }
        #expect(await eventually { await lease.currentHolder == nil })
        try await lease.acquire(owner: "task:1", priority: true)
        idle.value = 10
        #expect(await eventually { await lease.queueLength == 1 })
        paused.value = true
        #expect(await eventually(timeout: 3) { queuedEnded.value }, "the pause ends the wait for the screen")
        #expect(await lease.queueLength == 0)
        await lease.release(owner: "task:1")
        await #expect(throws: AutomationError.stopped) { try await queued.value }
        #expect(await lease.currentHolder == nil)

        // Keeping the screen (no lease to give up), a pause ends the wait too.
        let keptIdle = Box(0.0)
        let kept = UserTakeoverWatch(monitor: FakeInputMonitor(), idleSeconds: 30, idleProbe: { keptIdle.value }, pollInterval: 0.01)
        kept.noteUserInput()
        let keptPaused = Box(false)
        let keptEnded = Box(false)
        let keptWait = Task {
            defer { keptEnded.value = true }
            return try await kept.waitForIdleUser(gate: ExecutionGate(), interrupted: { keptPaused.value })
        }
        try await Task.sleep(for: .milliseconds(50))
        keptPaused.value = true
        #expect(await eventually(timeout: 3) { keptEnded.value })
        keptIdle.value = 100
        await #expect(throws: AutomationError.stopped) { try await keptWait.value }
    }

    /// The runner hands the job's pause to the wait, and still reports the wait's end.
    @Test func theRunnerEndsTheWaitWhenTheJobIsPaused() async throws {
        let credentials = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        credentials.useMemoryOnly()
        let settings = AppSettings()
        let runner = GUIStepRunner(settings: settings, runtime: AutomationRuntime(), router: ModelRouter(settings: settings, credentials: credentials),
                                   screenLease: ScreenLease(idleProbe: { 1000 }))
        let idle = Box(0.0)
        let watch = UserTakeoverWatch(monitor: FakeInputMonitor(), idleSeconds: 5, idleProbe: { idle.value }, pollInterval: 0.01)
        let paused = Box(false)
        let events = Ledger()
        let callbacks = AgentCallbacks(waitingForUser: { events.add("waiting: \($0)") }, jobInterrupted: { paused.value })
        let step = commandStep(route: .gui).asPlanStep
        let run = GUIStepRunner.Run(instruction: "Test goal", plan: Plan(goal: "Test goal", steps: [step], clarification: nil),
                                    session: TaskSession(deadline: Date().addingTimeInterval(60), maxTotalActions: 10),
                                    metrics: TaskMetrics(), callbacks: callbacks, isJob: true, takeover: watch)
        watch.noteUserInput()
        let wait = Task { try await runner.waitForUser(step, run) }
        #expect(await eventually { events.all == ["waiting: true"] })
        paused.value = true
        #expect(await eventually(timeout: 3) { events.all.count == 2 })
        idle.value = 10
        await #expect(throws: AutomationError.stopped) { try await wait.value }
        #expect(events.all == ["waiting: true", "waiting: false"])
    }

    /// A job step's watch waits by the lease's idle time: Glide's own input a moment ago (another
    /// job's step) doesn't count when the user has been away for longer than the idle setting.
    @Test func aJobStepWaitsByTheLeasesIdleTime() async throws {
        let hid = Box((input: Date().addingTimeInterval(-5000), post: Date.distantPast))
        let lease = ScreenLease(idleProbe: { Date().timeIntervalSince(hid.value.input) }, lastSyntheticInput: { hid.value.post })
        // The lease has seen the user's last input, long ago; then another job posted.
        #expect(await lease.userIdleTime() > 4999)
        let now = Date()
        hid.value = (now, now)
        var settings = AppSettings()
        settings.jobs.idleSeconds = 30
        let watch = try #require(UserTakeoverWatch.forStep(request(jobID: "job-1"), settings: settings, runtime: AutomationRuntime(), lease: lease))
        // Not the system's idle time (that's whatever this Mac's real input was).
        #expect(abs(await watch.idleNow() - 5000) < 5)
        let ended = Box(false)
        let wait = Task {
            defer { ended.value = true }
            return try await watch.waitForIdleUser(gate: ExecutionGate())
        }
        #expect(await eventually(timeout: 3) { ended.value }, "the user has been away a minute")
        wait.cancel()
        _ = try? await wait.value
    }

    /// Another job keeps using the screen while this step waits for the user, who has left.
    /// Its clicks and keystrokes are Glide's, not the user's: the step gets the screen back once
    /// the user has been idle long enough, instead of only once that job's on-screen work is done.
    @Test func anotherJobsInputDoesNotKeepTheStepWaiting() async throws {
        // Simulated HID state: when the last event happened, and when Glide last posted one.
        let hid = Box((input: Date().addingTimeInterval(-1000), post: Date.distantPast))
        let rawIdle: ScreenLease.IdleProbe = { Date().timeIntervalSince(hid.value.input) }
        let lease = ScreenLease(idleProbe: rawIdle, lastSyntheticInput: { hid.value.post }, pollInterval: 0.01)
        try await lease.acquire(owner: "job:a")
        let a = UserTakeoverWatch(monitor: FakeInputMonitor(), idleSeconds: UserTakeoverWatch.minimumIdleSeconds, idleProbe: rawIdle,
                                  userIdle: { await lease.userIdleTime() }, lease: lease, leaseOwner: "job:a", pollInterval: 0.01)
        // The user touches the mouse during job a's step, then leaves.
        let userAt = Date()
        hid.value.input = userAt
        a.noteUserInput()
        let finished = Box(false)
        let waiting = Task {
            defer { finished.value = true }
            return try await a.waitForIdleUser(gate: ExecutionGate())
        }
        #expect(await eventually { await lease.currentHolder == nil })
        // Job b uses the screen step after step, posting input all the while.
        let stop = Box(false)
        let b = Task {
            while !stop.value {
                try await lease.acquire(owner: "job:b")
                for _ in 0..<5 {
                    let now = Date()
                    hid.value = (now, now)
                    try await Task.sleep(for: .milliseconds(20))
                }
                await lease.release(owner: "job:b")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(await eventually(timeout: 10) { finished.value })
        #expect(Date().timeIntervalSince(userAt) >= UserTakeoverWatch.minimumIdleSeconds - 0.1, "only once the user had been idle long enough")
        #expect(await lease.currentHolder == "job:a")
        stop.value = true
        waiting.cancel()
        await lease.release(owner: "job:a")
        _ = try? await b.value
        await lease.release(owner: "job:b")
    }

    /// Job steps share one long-lived monitor. A step that gave the screen up and is then
    /// stopped must not switch off the monitor of the step that holds the screen now.
    @Test func aWaitingStepNeverStopsTheNextHoldersMonitor() async throws {
        let shared = FakeInputMonitor()
        let lease = ScreenLease(idleProbe: { 1000 })
        try await lease.acquire(owner: "job:a")
        let a = UserTakeoverWatch(monitor: shared, idleSeconds: 5, idleProbe: { 0 }, lease: lease, leaseOwner: "job:a", pollInterval: 0.01)
        a.start()
        a.noteUserInput()
        let waiting = Task { try await a.waitForIdleUser(gate: ExecutionGate()) }
        #expect(await eventually { await lease.currentHolder == nil })
        try await lease.acquire(owner: "job:b")
        let b = UserTakeoverWatch(monitor: shared, idleSeconds: 5)
        b.start()
        waiting.cancel()
        await #expect(throws: AutomationError.stopped) { try await waiting.value }
        a.stop() // what GUIStepRunner.execute's defer does
        #expect(shared.isRunning, "job b's step is still watched")
        b.stop()
        #expect(!shared.isRunning)
        await lease.release(owner: "job:b")
    }

    /// The runner's side: the wait is logged, reported to the job (so its time budget can leave
    /// it out) and pushes the step's deadline out.
    @Test func theRunnerLogsAndReportsTheWait() async throws {
        let credentials = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
        credentials.useMemoryOnly()
        let settings = AppSettings()
        let runner = GUIStepRunner(settings: settings, runtime: AutomationRuntime(), router: ModelRouter(settings: settings, credentials: credentials),
                                   screenLease: ScreenLease(idleProbe: { 1000 }))
        let idle = Box(0.0)
        let watch = UserTakeoverWatch(monitor: FakeInputMonitor(), idleSeconds: 5, idleProbe: { idle.value }, pollInterval: 0.01)
        let events = Ledger()
        let callbacks = AgentCallbacks(log: { events.add($0.title) }, waitingForUser: { events.add("waiting: \($0)") })
        let step = commandStep(route: .gui).asPlanStep
        let session = TaskSession(deadline: Date().addingTimeInterval(60), maxTotalActions: 10)
        let before = session.deadline
        let run = GUIStepRunner.Run(instruction: "Test goal", plan: Plan(goal: "Test goal", steps: [step], clarification: nil), session: session,
                                    metrics: TaskMetrics(), callbacks: callbacks, isJob: true, takeover: watch)
        #expect(try await runner.waitForUser(step, run) == false, "nothing to wait for")
        #expect(events.all.isEmpty)

        watch.noteUserInput()
        let wait = Task { try await runner.waitForUser(step, run) }
        #expect(await eventually { events.all.count == 2 })
        #expect(events.all == ["Paused because you used the mouse", "waiting: true"])
        try await Task.sleep(for: .milliseconds(100))
        idle.value = 10
        #expect(try await wait.value)
        #expect(events.all == ["Paused because you used the mouse", "waiting: true", "waiting: false", "Continuing after you've been idle"])
        #expect(session.deadline > before.addingTimeInterval(0.05))

        // A stop while waiting still reports the end of the wait.
        idle.value = 0
        watch.noteUserInput()
        let stopped = Task { try await runner.waitForUser(step, run) }
        #expect(await eventually { events.all.count == 6 })
        stopped.cancel()
        await #expect(throws: AutomationError.stopped) { try await stopped.value }
        #expect(events.all.last == "waiting: false")
    }

    @Test func waitingDoesNotCountTowardTheStepTimeLimit() throws {
        let session = TaskSession(deadline: Date().addingTimeInterval(-1), maxTotalActions: 10)
        #expect(throws: AutomationError.self) { try session.checkLimits(gate: nil) }
        session.extendDeadline(by: 60)
        try session.checkLimits(gate: nil)
    }
}

// MARK: - Quick tasks waiting for the screen

@MainActor
@Suite("TaskController and the screen lease", .serialized)
struct TaskControllerLeaseTests {
    final class Fixture {
        let suite = "dev.glide.tests.\(UUID().uuidString)"
        let runtime = AutomationRuntime()
        let lease = ScreenLease(idleProbe: { 1000 })
        let store: SettingsStore
        let controller: TaskController

        @MainActor init() {
            store = SettingsStore(defaults: UserDefaults(suiteName: suite) ?? .standard)
            var s = AppSettings()
            s.providers = [ProviderConfig(id: "mock", kind: .openaiCompatible, name: "Mock", baseURL: "http://127.0.0.1:9", requiresKey: false, models: ["mock"])]
            s.routing.preferredProviderID = "mock"
            s.composio.enabled = false
            store.settings = s
            let credentials = CredentialStore(service: "dev.glide.tests.\(UUID().uuidString)")
            credentials.useMemoryOnly()
            controller = TaskController(runtime: runtime, settingsStore: store, screenLease: lease, credentials: credentials)
        }

        func cleanUp() { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    /// Starts a quick task while a "job" holds the screen and waits until it's queued behind it.
    func startWaiting(_ fx: Fixture) async throws {
        try await fx.lease.acquire(owner: "job:test")
        fx.controller.start("Rename the report")
        let lease = fx.lease
        #expect(await eventually { await lease.queueLength == 1 })
        #expect(fx.controller.status == TaskController.waitingForScreenStatus)
        #expect(fx.controller.phase == .planning)
    }

    @Test func stopWhileWaitingLeavesTheJobsStepAlone() async throws {
        let fx = Fixture()
        defer { fx.cleanUp() }
        try await startWaiting(fx)
        fx.controller.stop()
        #expect(fx.runtime.gate.current == .running, "the job's on-screen step keeps going")
        #expect(await eventuallyOnMain { !fx.controller.isWindingDown })
        #expect(fx.controller.phase == .stopped)
        #expect(fx.controller.lastResult?.status == .stopped)
        #expect(await fx.lease.currentHolder == "job:test")
        #expect(await fx.lease.queueLength == 0)
        await fx.lease.release(owner: "job:test")
    }

    @Test func pauseWhileWaitingLeavesTheJobsStepAlone() async throws {
        let fx = Fixture()
        defer { fx.cleanUp() }
        try await startWaiting(fx)
        fx.controller.pause()
        #expect(fx.controller.phase == .paused)
        #expect(fx.runtime.gate.current == .running)
        // The job's next on-screen step resets the gate; the quick task's pause is its own.
        fx.runtime.gate.reset()
        #expect(fx.controller.phase == .paused)
        fx.controller.resume()
        #expect(fx.controller.phase == .planning)
        #expect(fx.controller.status == TaskController.waitingForScreenStatus)
        #expect(fx.runtime.gate.current == .running)
        fx.controller.stop()
        #expect(await eventuallyOnMain { !fx.controller.isWindingDown })
        #expect(fx.runtime.gate.current == .running)
        await fx.lease.release(owner: "job:test")
    }

    @Test func aPauseFromTheWaitAppliesOnceTheScreenIsHeld() {
        let fx = Fixture()
        defer { fx.cleanUp() }
        let c = fx.controller
        c.previewState(phase: .planning, status: TaskController.waitingForScreenStatus)
        c.pause()
        #expect(fx.runtime.gate.current == .running)
        // An earlier job step's stop is still on the gate when the lease is granted.
        fx.runtime.gate.stop()
        c.takeInputGate()
        #expect(fx.runtime.gate.isPaused, "the stale stop is cleared, the user's pause applied")
        c.resume()
        #expect(fx.runtime.gate.current == .running)
        #expect(c.phase == .executing)
        c.stop()
        #expect(fx.runtime.gate.isStopped, "holding the screen, Stop stops the gate")
    }
}
