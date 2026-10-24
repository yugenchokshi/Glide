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
        #expect(Date().timeIntervalSince(start) < 2)
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
