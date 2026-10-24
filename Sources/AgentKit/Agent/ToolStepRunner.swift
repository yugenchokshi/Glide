import Foundation
import AutomationKit

/// Runs a step with tools instead of the screen (routes command, browser, web, data, composio,
/// mcp and answer): ask the fast model for the next calls → run them in order → feed the
/// results back, until it reports the step done, blocked, or a limit ends the step.
///
/// Every call goes through the same deterministic safety path as UI actions: the tool's own
/// `assess` (fast, never a model) decides blocked or the risk level, and `SafetyPolicy` decides
/// whether the user must approve. The model never chooses its own risk, and it can't pass the
/// runner-only arguments (`_label` and anything else starting with `_`) that tools trust.
///
/// Limits: `maxTurns` model turns per step, an error budget, and a guard that fails the step
/// when the same call fails three times in a row. Each call also has a hard timeout as a
/// backstop for tools that hang.
public struct ToolStepRunner: StepExecuting {
    /// Composio and MCP access for the integration routes; injectable for tests.
    public struct Integrations: Sendable {
        /// The Composio client and session, or nil when Composio isn't configured.
        public var composio: @Sendable () async -> (ComposioClient, String)?
        public var mcpTools: @Sendable () async -> [MCPTool]
        public var mcpCall: @Sendable (_ qualifiedName: String, _ arguments: JSONValue) async throws -> (text: String, isError: Bool)

        public init(composio: @escaping @Sendable () async -> (ComposioClient, String)?,
                    mcpTools: @escaping @Sendable () async -> [MCPTool],
                    mcpCall: @escaping @Sendable (_ qualifiedName: String, _ arguments: JSONValue) async throws -> (text: String, isError: Bool)) {
            self.composio = composio
            self.mcpTools = mcpTools
            self.mcpCall = mcpCall
        }

        /// No integrations (named `disabled`, not `none`, so it never reads as `Optional.none`).
        public static let disabled = Integrations(composio: { nil }, mcpTools: { [] }, mcpCall: { name, _ in throw MCPError.notConnected(name) })

        /// The app's connected MCP servers and, when enabled in settings, its Composio session.
        public static func standard(settings: AppSettings) -> Integrations {
            let composioEnabled = settings.composio.enabled
            return Integrations(
                composio: {
                    guard composioEnabled else { return nil }
                    return try? await ComposioSessionStore.ensureSession()
                },
                mcpTools: { await MCPManager.shared.allTools() },
                mcpCall: { name, arguments in try await MCPManager.shared.call(qualifiedName: name, arguments: arguments) })
        }
    }

    /// Where model replies come from: the configured router, or one fixed provider (tests).
    enum ModelSource: Sendable {
        case router(ModelRouter)
        case fixed(provider: any LLMProvider, model: String)

        func route() throws -> ModelRouter.Route {
            switch self {
            case .router(let router): return try router.route(.actor)
            case .fixed(let provider, let model): return ModelRouter.Route(provider: provider, model: model, effort: nil)
            }
        }
    }

    /// Errors tolerated in one step; the next one fails it.
    static let errorBudget = 4
    /// The same failing call this many times in a row fails the step.
    static let repeatedFailureLimit = 3
    /// Declined calls in one step before it stops to ask the user how to proceed.
    static let rejectionLimit = 2

    let settings: AppSettings
    let runtime: AutomationRuntime
    let registry: ToolRegistry
    let models: ModelSource
    let integrations: Integrations
    let safety: SafetyPolicy
    /// Quick tasks: the orchestrator's task state, so tool calls count toward the task's action
    /// limit and deadline. Nil for job steps (the job engine enforces budgets).
    var session: TaskSession?
    /// Quick tasks: the orchestrator's metrics, so model calls show up in the task's totals.
    var metrics: TaskMetrics?
    /// Hard ceiling for one tool call. Each tool has its own, shorter timeout (shell commands
    /// may run up to 10 minutes); this only catches tools that hang.
    var callTimeout: TimeInterval = 660

    public init(settings: AppSettings, runtime: AutomationRuntime = .shared, tools: ToolRegistry, credentials: CredentialStore = .shared,
                integrations: Integrations? = nil) {
        self.init(settings: settings, runtime: runtime, tools: tools, models: .router(ModelRouter(settings: settings, credentials: credentials)),
                  integrations: integrations ?? .standard(settings: settings))
    }

    /// Uses one provider and model for every turn (tests, scripted runs).
    init(settings: AppSettings, runtime: AutomationRuntime = .shared, tools: ToolRegistry, provider: any LLMProvider, model: String,
         integrations: Integrations = .disabled) {
        self.init(settings: settings, runtime: runtime, tools: tools, models: .fixed(provider: provider, model: model), integrations: integrations)
    }

    init(settings: AppSettings, runtime: AutomationRuntime, tools: ToolRegistry, models: ModelSource, integrations: Integrations) {
        self.settings = settings
        self.runtime = runtime
        self.registry = tools
        self.models = models
        self.integrations = integrations
        self.safety = SafetyPolicy(settings: settings.safety)
    }

    // MARK: - StepExecuting

    public func execute(_ request: StepRequest, callbacks: AgentCallbacks) async throws -> StepResult {
        // Job steps never use the shared input gate: a quick task's Stop must not end a
        // background job, and one job's stop (its task being cancelled) must not stop anything
        // else. Each of their calls gets a private gate that cancellation stops, so tools that
        // watch the gate (e.g. a running shell command) end promptly.
        let gates = CallGates(shared: request.jobID == nil ? runtime.gate : nil)
        do {
            return try await withTaskCancellationHandler {
                try await run(request, callbacks: callbacks, gates: gates)
            } onCancel: {
                gates.stopAll()
            }
        } catch is CancellationError {
            throw AutomationError.stopped
        }
    }

    // MARK: - The loop

    private func run(_ request: StepRequest, callbacks: AgentCallbacks, gates: CallGates) async throws -> StepResult {
        var state = LoopState()
        if request.step.route == .answer {
            return try await answer(request, callbacks: callbacks, gates: gates, state: &state)
        }

        // Integration routes discover their tools per step and wrap them as AgentTools.
        var extraTools: [any AgentTool] = []
        var extraContext: String?
        switch request.step.route {
        case .composio:
            guard let (client, sessionID) = await integrations.composio() else {
                return state.result(.failed("Composio isn't configured. Add your Composio API key in Settings › Integrations, or do this through the app's UI."))
            }
            callbacks.phase(.executing, "Finding the right integration…")
            let found: ComposioClient.SearchResult
            do {
                found = try await client.search(sessionID: sessionID, useCase: request.step.instruction)
            } catch is CancellationError {
                throw AutomationError.stopped
            } catch {
                return state.result(.failed("Couldn't search Composio: \(error.localizedDescription)"))
            }
            if found.tools.isEmpty { return state.result(.failed("No Composio tool matched this step.")) }
            if !found.missingConnections.isEmpty && found.tools.allSatisfy({ found.missingConnections.contains($0.toolkit) }) {
                return state.result(.blocked("Connect \(found.missingConnections.joined(separator: ", ")) in Settings › Integrations, then try again."))
            }
            extraTools = found.tools.map { ComposioToolAdapter(schema: $0, client: client, sessionID: sessionID) }
            if !found.guidance.isEmpty { extraContext = "Composio guidance: " + found.guidance.joined(separator: " ") }
        case .mcp:
            let tools = await integrations.mcpTools()
            guard !tools.isEmpty else { return state.result(.failed("No MCP servers are connected.")) }
            let call = integrations.mcpCall
            extraTools = MCPToolAdapter.relevant(tools, to: request.step.instruction).map { MCPToolAdapter(tool: $0, call: call) }
        default:
            break
        }

        let stepTools = toolsAvailable(to: request, extra: extraTools)
        let primary = request.allowedCategories.subtracting([.workspace, .system])
        if !primary.isEmpty, !stepTools.specs().contains(where: { primary.contains($0.category) }) {
            return state.result(.failed("The \(request.step.route.rawValue) tools aren't available here, so this step can't run with tools."))
        }
        let listing = stepTools.promptListing(categories: request.allowedCategories)
        let maxBatch = settings.tools.batchActions ? min(max(settings.tools.maxBatch, 1), 10) : 1
        let schema = ToolDecisionSchema.schema(maxBatch: maxBatch)

        for _ in 0..<max(1, request.maxTurns) {
            try await checkStop(gates)
            callbacks.phase(.executing, request.step.title + "…")

            // 1. Decide.
            let decision: ToolDecision
            do {
                let message = prompt(request, listing: listing, history: state.history, maxBatch: maxBatch, extraContext: extraContext)
                let response = try await complete(system: Prompts.toolStep, message: message, schema: schema, name: "tool_step", state: &state)
                guard let json = response.json else { throw LLMError.invalidJSON(response.text) }
                decision = ToolDecisionSchema.decode(json)
            } catch let error as LLMError {
                if error.endsStep { return state.result(.failed(error.localizedDescription)) }
                state.note("model error: \(error.localizedDescription)")
                if state.recordError(error.localizedDescription) { return state.result(.failed(state.budgetMessage)) }
                continue
            }
            if let note = decision.remember {
                state.learned.append(note)
                if let workspace = request.workspace {
                    await workspace.setFact(workspaceNoteKey(stepID: request.step.id, itemID: request.itemID, index: state.learned.count - 1), note)
                }
            }
            if decision.status == .blocked {
                return state.result(.blocked(decision.message ?? "I can't continue this step without your help."))
            }
            let finishing = decision.status == .stepDone || decision.status == .taskDone
            if decision.status == .act && decision.calls.isEmpty {
                state.note("status act needs at least one call; to finish, return step_done")
                if state.recordError("no calls") { return state.result(.failed(state.budgetMessage)) }
                continue
            }

            // 2. Act: run the batch in order, stopping at the first failure or declined call.
            var batchFailed = false
            let calls = Array(decision.calls.prefix(maxBatch))
            if decision.calls.count > maxBatch {
                state.note("only the first \(maxBatch) calls ran (the limit per turn); send the rest next turn")
            }
            for call in calls {
                if batchFailed {
                    state.history.append(HistoryEntry(header: "\(call.tool) → not run (an earlier call in this batch failed)"))
                    continue
                }
                try await checkStop(gates)
                let outcome = try await runCall(call, request: request, stepTools: stepTools, callbacks: callbacks, gates: gates, state: &state)
                switch outcome {
                case .ok:
                    state.resetFailures()
                case .failed(let message):
                    batchFailed = true
                    if state.recordFailure(signature: call.signature, tool: call.tool, message: message) {
                        return state.result(.failed("“\(call.tool)” failed \(Self.repeatedFailureLimit) times in a row with the same arguments: \(message)"))
                    }
                    if state.recordError(message) { return state.result(.failed(state.budgetMessage)) }
                case .declined:
                    batchFailed = true
                    state.rejections += 1
                    if state.rejections >= Self.rejectionLimit {
                        return state.result(.blocked("You declined the proposed actions. Tell me how you'd like to proceed."))
                    }
                }
            }

            // 3. Finish when the model says the step is done.
            guard finishing else { continue }
            if !calls.isEmpty {
                // Calls sent together with "done" ran first. Accept the claim only when they all
                // worked and no output fields depend on results the model hasn't seen yet.
                guard !batchFailed, request.step.outputFields.isEmpty else {
                    state.note("the calls sent with \(decision.status.rawValue) ran first; check their results, then report the status again")
                    continue
                }
            }
            if decision.resultFieldsUnreadable {
                state.note("result_fields_json wasn't a valid JSON object; send it again")
                if state.recordError("unreadable result fields") { return state.result(.failed(state.budgetMessage)) }
                continue
            }
            let missing = StepResult.missingFields(decision.resultFields, required: request.step.outputFields)
            if !missing.isEmpty && !state.fieldsReminded {
                // One reminder; then accept nulls rather than failing an item over a missing field.
                state.fieldsReminded = true
                state.note("result_fields_json is missing \(missing.joined(separator: ", ")); include every output field (null when unknown)")
                continue
            }
            let fields = StepResult.completeFields(decision.resultFields ?? [:], required: request.step.outputFields)
            if decision.status == .taskDone && request.jobID == nil {
                return state.result(.taskDone(decision.message ?? "Done"), message: decision.message, fields: fields)
            }
            return state.result(.done, message: decision.message, fields: fields)
        }
        return state.result(.failed("Reached the limit of \(max(1, request.maxTurns)) turns without finishing “\(request.step.title)”." +
                                    (state.lastError.isEmpty ? "" : " Last problem: \(state.lastError)")))
    }

    // MARK: - One call

    enum CallOutcome {
        case ok
        case failed(String)
        case declined
    }

    private func runCall(_ call: ToolDecision.Call, request: StepRequest, stepTools: ToolRegistry, callbacks: AgentCallbacks,
                         gates: CallGates, state: inout LoopState) async throws -> CallOutcome {
        let route = request.step.route
        func refuse(_ message: String) -> CallOutcome {
            state.history.append(HistoryEntry(header: "\(call.tool) \(call.argumentsText) → NOT RUN: \(message)"))
            state.lastError = message
            return .failed(message)
        }

        // Resolve and check the tool.
        guard let tool = stepTools.tool(named: call.tool) else {
            if let other = registry.tool(named: call.tool) {
                return refuse("“\(call.tool)” (\(other.spec.category.rawValue)) isn't available in this step; use a tool from the list")
            }
            return refuse("there's no tool named “\(call.tool)”; use a tool from the list")
        }
        guard request.allowedCategories.contains(tool.spec.category) else {
            return refuse("“\(call.tool)” isn't available in this step; use a tool from the list")
        }
        if tool.spec.needsScreen && request.jobID != nil {
            return refuse("“\(call.tool)” needs the screen, which background steps don't hold; use another tool")
        }
        guard case .object(var arguments)? = call.arguments else {
            return refuse("arguments_json must be a JSON object matching the tool's args schema")
        }
        // Runner-only keys are never taken from the model.
        for key in arguments.keys where key.hasPrefix("_") { arguments[key] = nil }
        if let ref = arguments["ref"]?.stringValue, BrowserRefs.labelledTools.contains(call.tool) {
            if let label = state.browser.label(for: ref) {
                arguments["_label"] = .string(label)
            } else if BrowserRefs.requiresSnapshotRef.contains(call.tool) {
                return refuse("\(ref) isn't in the latest page snapshot; call browser.snapshot and use a ref from it")
            }
        }
        let args = JSONValue.object(arguments)
        let callGate = gates.makeCallGate()
        let context = ToolContext(settings: settings, gate: callGate, workspace: request.workspace, jobID: request.jobID, itemID: request.itemID,
                                  workingDirectory: request.workspace?.folder ?? FileManager.default.homeDirectoryForCurrentUser,
                                  log: callbacks.log)

        // Deterministic safety.
        var verdict = tool.assess(args, context: context)
        if tool.spec.category == .integration, request.step.risk > verdict.risk {
            // An external tool's side effects aren't knowable from its name alone; the planner's
            // step risk is the best extra signal (this matches how integration steps ran before).
            verdict.risk = request.step.risk
            verdict.reasons.append("part of a \(request.step.risk.rawValue)-risk step")
        }
        if let blocked = verdict.blocked {
            callbacks.log(ActivityEntry(kind: .approval, title: "Blocked: \(verdict.summary)", detail: blocked, route: route, success: false, stepID: request.step.id))
            return refuse("BLOCKED by the user's settings or safety rules: \(blocked)")
        }
        if safety.needsApproval(verdict.safetyVerdict) {
            callbacks.phase(.awaitingApproval, "Needs your approval")
            let detail = "\(request.step.instruction)\n\n" + String(args.jsonString(pretty: true).prefix(800))
            let req = ApprovalRequest(kind: .tool, title: verdict.summary, detail: detail, appName: Self.appName(for: tool.spec.category),
                                      risk: verdict.risk, reasons: verdict.reasons)
            switch await callbacks.approve(req) {
            case .approve:
                callbacks.log(ActivityEntry(kind: .approval, title: "You approved: \(verdict.summary)", route: route, success: true, stepID: request.step.id))
            case .reject:
                callbacks.log(ActivityEntry(kind: .approval, title: "You declined: \(verdict.summary)", route: route, success: false, stepID: request.step.id))
                state.history.append(HistoryEntry(header: "\(call.tool) \(call.argumentsText) → DECLINED by the user; don't retry it"))
                callbacks.phase(.executing, request.step.title + "…")
                return .declined
            case .stop:
                if request.jobID == nil { runtime.gate.stop() }
                throw AutomationError.stopped
            }
        }

        // Run.
        try await checkStop(gates)
        callbacks.phase(.executing, verdict.summary)
        let start = Date()
        var output: ToolOutput
        do {
            output = try await runWithTimeout(tool, args, context, callGate: callGate, timeout: callTimeout)
        } catch AutomationError.stopped {
            throw AutomationError.stopped
        } catch is CancellationError {
            throw AutomationError.stopped
        } catch {
            if Task.isCancelled || gates.isStopped { throw AutomationError.stopped }
            output = ToolOutput.failure(error.localizedDescription)
        }
        let ms = output.durationMs > 0 ? output.durationMs : Date().timeIntervalSince(start) * 1000
        state.actions += 1
        session?.addActions()
        await metrics?.recordAction(deterministic: false)
        callbacks.log(ActivityEntry(kind: .tool, title: "\(output.ok ? "Ran" : "Failed"): \(verdict.summary)", detail: String(output.text.prefix(500)),
                                    route: route, success: output.ok, durationMs: ms, stepID: request.step.id))
        state.browser.absorb(tool: call.tool, output: output)
        let status = output.ok ? "ok" : "FAILED"
        state.history.append(HistoryEntry(header: "\(call.tool) \(call.argumentsText) → \(status) (\(Int(ms)) ms)", body: output.text))
        if output.ok {
            state.lastOK = output.text
            return .ok
        }
        state.lastError = String(output.text.prefix(300))
        return .failed(state.lastError.isEmpty ? "the tool reported a failure" : state.lastError)
    }

    /// Runs a tool with a hard timeout. Unlike a task group, this returns on timeout or
    /// cancellation even if the tool ignores cancellation; the call's gate is stopped too, so
    /// tools that watch it (shell commands) end their work.
    private func runWithTimeout(_ tool: any AgentTool, _ args: JSONValue, _ context: ToolContext, callGate: ExecutionGate,
                                timeout: TimeInterval) async throws -> ToolOutput {
        let race = FirstResult<ToolOutput>()
        let ownsGate = callGate !== runtime.gate
        let work = Task {
            do { race.finish(.success(try await tool.run(args, context: context))) } catch { race.finish(.failure(error)) }
        }
        let name = tool.spec.name
        let limit = timeout >= 10 ? "\(Int(timeout)) seconds" : String(format: "%.1f seconds", timeout)
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            if race.finish(.failure(ToolError.timeout("\(name) didn't finish within \(limit)"))) {
                work.cancel()
                if ownsGate { callGate.stop() }
            }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<ToolOutput, Error>) in race.install(c) }
        } onCancel: {
            if race.finish(.failure(CancellationError())) {
                work.cancel()
                if ownsGate { callGate.stop() }
            }
        }
    }

    // MARK: - Answer route

    /// Writes the step's result from its context alone (no tools): the final reply of a quick
    /// task, or a job's summary, report or verification fields.
    private func answer(_ request: StepRequest, callbacks: AgentCallbacks, gates: CallGates, state: inout LoopState) async throws -> StepResult {
        callbacks.phase(.executing, "Writing the answer…")
        var reminder = ""
        for attempt in 0..<2 {
            try await checkStop(gates)
            var message = "Goal: \(request.goal)\n\nSTEP \(request.step.id): \(request.step.title)\nInstruction: \(request.step.instruction)"
            if !request.step.doneWhen.isEmpty { message += "\nDone when: \(request.step.doneWhen)" }
            if !request.step.outputFields.isEmpty {
                message += "\nOutput fields (result_fields_json): " + request.step.outputFields.joined(separator: ", ")
            }
            message += "\n\nContext:\n" + (request.context.isEmpty ? "(none)" : Self.clip(request.context, 12_000))
            if !reminder.isEmpty { message += "\n\n\(reminder)" }
            let response: LLMResponse
            do {
                response = try await complete(system: Prompts.answerWriter, message: message, schema: ToolDecisionSchema.answerSchema,
                                              name: "step_answer", state: &state)
            } catch let error as LLMError {
                if error.endsStep || attempt == 1 { return state.result(.failed(error.localizedDescription)) }
                reminder = "Your previous reply couldn't be read (\(error.localizedDescription)); reply with the JSON object only."
                continue
            }
            let text = (response.json?["message"]?.stringValue ?? response.text).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawFields = response.json?["result_fields_json"]?.stringValue
            let fields = rawFields.flatMap { JSONValue.extractObject(from: $0)?.objectValue }
            let missing = StepResult.missingFields(fields, required: request.step.outputFields)
            if !missing.isEmpty && attempt == 0 {
                reminder = "Your previous reply was missing result_fields_json keys: \(missing.joined(separator: ", ")). Include every listed key (null when unknown)."
                continue
            }
            let complete = StepResult.completeFields(fields ?? [:], required: request.step.outputFields)
            let answer = text.isEmpty ? "Done" : text
            if request.jobID == nil { return state.result(.taskDone(answer), message: answer, fields: complete) }
            return state.result(.done, message: answer, fields: complete)
        }
        return state.result(.failed("Couldn't write the answer."))
    }

    // MARK: - Helpers

    /// The tools this step may see: allowed families only, minus tools that need the screen when
    /// running in the background, plus the integration adapters for this step.
    private func toolsAvailable(to request: StepRequest, extra: [any AgentTool]) -> ToolRegistry {
        let background = request.jobID != nil
        let base = registry.all.filter { tool in
            request.allowedCategories.contains(tool.spec.category) && !(background && tool.spec.needsScreen)
        }
        return ToolRegistry(base + extra.filter { request.allowedCategories.contains($0.spec.category) })
    }

    private func checkStop(_ gates: CallGates) async throws {
        if Task.isCancelled || gates.isStopped { throw AutomationError.stopped }
        if gates.shared != nil {
            // Quick task: honour the user's pause (suspends here) and stop.
            try await runtime.gate.checkpoint()
        }
        try session?.checkLimits(gate: nil)
    }

    private func complete(system: String, message: String, schema: JSONValue, name: String, state: inout LoopState) async throws -> LLMResponse {
        let route = try models.route()
        let req = LLMRequest(model: route.model, system: system, messages: [.user(message)], schema: schema, schemaName: name,
                             maxTokens: 4000, effort: route.effort, timeout: 60)
        let response = try await route.provider.complete(req)
        state.modelCalls += 1
        state.usage = state.usage + response.usage
        await metrics?.recordModel(response, vision: false)
        return response
    }

    private func prompt(_ request: StepRequest, listing: String, history: [HistoryEntry], maxBatch: Int, extraContext: String?) -> String {
        var m = "Goal: \(request.goal)\n\nSTEP \(request.step.id): \(request.step.title)\nInstruction: \(request.step.instruction)"
        m += "\nDone when: " + (request.step.doneWhen.isEmpty ? "the instruction is complete" : request.step.doneWhen)
        if !request.step.outputFields.isEmpty {
            m += "\nOutput fields (result_fields_json with step_done): " + request.step.outputFields.joined(separator: ", ")
        }
        if !request.context.isEmpty { m += "\n\nContext:\n" + Self.clip(request.context, 6000) }
        if let extraContext { m += "\n\n\(extraContext)" }
        m += "\n\nTools (at most \(maxBatch) call\(maxBatch == 1 ? "" : "s") per turn):\n\(listing)"
        // Kept last: the newest results are what the model needs most.
        m += "\n\nRecent results:\n" + HistoryEntry.render(history)
        return m
    }

    static func appName(for category: ToolCategory) -> String {
        switch category {
        case .command: return "Commands"
        case .files: return "Files"
        case .browser: return "Browser"
        case .web: return "Web"
        case .data: return "Spreadsheets"
        case .workspace: return "Job memory"
        case .integration: return "Integrations"
        case .system: return "System"
        }
    }

    static func clip(_ s: String, _ max: Int) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }
}

// MARK: - Loop state

/// Per-step bookkeeping for the tool loop.
struct LoopState {
    var history: [HistoryEntry] = []
    var errors = 0
    var lastError = ""
    var lastOK: String?
    var rejections = 0
    var actions = 0
    var modelCalls = 0
    var usage = LLMUsage()
    var learned: [String] = []
    var fieldsReminded = false
    var browser = BrowserRefs()
    private var failureSignature: String?
    private var failureStreak = 0

    mutating func note(_ text: String) { history.append(HistoryEntry(header: "note: \(text)")) }

    /// Counts an error; true when the budget is exhausted.
    mutating func recordError(_ message: String) -> Bool {
        errors += 1
        lastError = message
        return errors > ToolStepRunner.errorBudget
    }

    var budgetMessage: String { "Too many errors in this step. Last problem: \(lastError)" }

    /// Tracks identical failing calls in a row; true when the same call has failed too often.
    mutating func recordFailure(signature: String, tool: String, message: String) -> Bool {
        if signature == failureSignature { failureStreak += 1 } else { failureSignature = signature; failureStreak = 1 }
        return failureStreak >= ToolStepRunner.repeatedFailureLimit
    }

    mutating func resetFailures() {
        failureSignature = nil
        failureStreak = 0
    }

    /// The step's result with everything counted so far (also on failure, so budgets see usage).
    func result(_ status: StepResult.Status, message: String? = nil, fields: [String: JSONValue] = [:]) -> StepResult {
        var parts = learned
        if let message, !message.isEmpty { parts.append(message) }
        if parts.isEmpty, case .done = status, let lastOK, !lastOK.isEmpty {
            parts.append("Last result: " + ToolStepRunner.clip(lastOK, 1500))
        }
        return StepResult(status: status, output: parts.joined(separator: "\n"), fields: fields, actions: actions,
                          modelCalls: modelCalls, usage: usage)
    }
}

/// One line of "Recent results" in the prompt.
struct HistoryEntry: Sendable {
    var header: String
    var body: String = ""

    /// The last 8 entries; the newest keep the most text (they usually hold what the model is
    /// working from, like a page snapshot or a file it just read).
    static func render(_ entries: [HistoryEntry]) -> String {
        guard !entries.isEmpty else { return "(none yet)" }
        let recent = entries.suffix(8)
        let count = recent.count
        return recent.enumerated().map { i, e in
            let age = count - 1 - i
            let limit = age == 0 ? 6000 : (age == 1 ? 2000 : 600)
            guard !e.body.isEmpty else { return "- \(e.header)" }
            return "- \(e.header):\n" + toolTruncate(e.body, max: limit)
        }.joined(separator: "\n")
    }
}

// MARK: - Decision schema

struct ToolDecision: Sendable {
    enum Status: String, Sendable, CaseIterable {
        case act, stepDone = "step_done", taskDone = "task_done", blocked
    }

    struct Call: Sendable {
        var tool: String
        /// Parsed arguments; nil when arguments_json wasn't valid JSON.
        var arguments: JSONValue?
        /// Compact form for the prompt history.
        var argumentsText: String
        /// Identity for the repeated-failure guard (tool + canonical arguments).
        var signature: String { "\(tool)|\(arguments?.jsonString() ?? argumentsText)" }
    }

    var status: Status
    var thought: String
    var calls: [Call]
    var resultFields: [String: JSONValue]?
    /// result_fields_json was given but isn't a JSON object.
    var resultFieldsUnreadable: Bool
    var message: String?
    var remember: String?
}

enum ToolDecisionSchema {
    static func schema(maxBatch: Int) -> JSONValue {
        Schema.object([
            ("thought", Schema.string("One short sentence: what you know and why these calls.")),
            ("status", Schema.string("act = run the calls; step_done = this step is complete; task_done = the whole task is complete; blocked = can't continue without the user.",
                                     enum: ToolDecision.Status.allCases.map(\.rawValue))),
            ("calls", Schema.array(Schema.object([
                ("tool", Schema.string("Exact tool name from the list.")),
                ("arguments_json", Schema.string("The arguments as a JSON object string matching the tool's args schema, e.g. {\"path\":\"~/Desktop\"}.")),
            ]), description: "Tool calls to run in order when status is act (1 to \(maxBatch)); empty otherwise.")),
            ("result_fields_json", Schema.nullableString("With step_done: a JSON object string with the step's output fields, else null.")),
            ("message", Schema.nullableString("With step_done: what the step produced (facts, numbers, paths). With task_done: the final answer. With blocked: why. Else null.")),
            ("remember", Schema.nullableString("Short facts worth keeping for later steps, else null.")),
        ])
    }

    static let answerSchema: JSONValue = Schema.object([
        ("message", Schema.string("The answer or result, concise and complete.")),
        ("result_fields_json", Schema.nullableString("A JSON object string with the step's output fields when any are listed, else null.")),
    ])

    /// Tolerant decoding: models sometimes send arguments as an object instead of a string, or
    /// leave fields out; none of that should fail the step.
    static func decode(_ j: JSONValue) -> ToolDecision {
        func str(_ k: String) -> String? {
            guard let s = j[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s != "null" else { return nil }
            return s
        }
        let calls: [ToolDecision.Call] = (j["calls"]?.arrayValue ?? []).compactMap { c in
            guard let tool = c["tool"]?.stringValue?.trimmingCharacters(in: .whitespaces), !tool.isEmpty else { return nil }
            let raw = c["arguments_json"] ?? c["arguments"]
            let args: JSONValue?
            let text: String
            switch raw {
            case .object?:
                args = raw
                text = raw?.jsonString() ?? "{}"
            case .string(let s)?:
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == "null" {
                    args = .object([:])
                    text = "{}"
                } else {
                    args = JSONValue.extractObject(from: trimmed)
                    text = args?.jsonString() ?? trimmed
                }
            case nil, .null?:
                args = .object([:])
                text = "{}"
            default:
                args = nil
                text = raw?.jsonString() ?? ""
            }
            return ToolDecision.Call(tool: tool, arguments: args, argumentsText: ToolStepRunner.clip(text, 300))
        }
        let rawFields = str("result_fields_json")
        let fields = rawFields.flatMap { JSONValue.extractObject(from: $0)?.objectValue }
        // An unknown status is treated as act: with calls they run, without calls it costs an
        // error and the model is told what's expected.
        let status = str("status").flatMap { ToolDecision.Status(rawValue: $0.lowercased()) } ?? .act
        return ToolDecision(status: status, thought: str("thought") ?? "", calls: calls, resultFields: fields,
                            resultFieldsUnreadable: rawFields != nil && fields == nil, message: str("message"), remember: str("remember"))
    }
}

// MARK: - Browser labels

/// Element names from the latest browser page snapshot the runner saw. Click and type calls
/// carry the element's name as `_label` so the browser tools' deterministic risk check can
/// judge "Send", "Delete account" or "Place order" — and a ref that isn't in the latest
/// snapshot is refused, since its risk can't be judged.
struct BrowserRefs: Sendable {
    /// Calls that get `_label` filled in.
    static let labelledTools: Set<String> = ["browser.click", "browser.type", "browser.select"]
    /// Calls refused when their ref isn't in the latest snapshot.
    static let requiresSnapshotRef: Set<String> = ["browser.click", "browser.type"]
    /// Calls after which the old refs are invalid even if no new snapshot came back.
    static let pageChangers: Set<String> = ["browser.open", "browser.back", "browser.switch_tab", "browser.close_tab", "browser.navigate"]

    private(set) var labels: [String: String] = [:]
    /// Text of the output the labels came from, for refs in lines the parser didn't recognize.
    private var snapshotText = ""

    mutating func absorb(tool: String, output: ToolOutput) {
        guard tool.hasPrefix("browser.") else { return }
        let parsed = Self.parse(output)
        if !parsed.isEmpty {
            labels = parsed
            snapshotText = output.text
        } else if Self.pageChangers.contains(tool) {
            labels = [:]
            snapshotText = ""
        }
    }

    func label(for ref: String) -> String? {
        guard Self.isRef(ref) else { return nil }
        if let label = labels[ref] { return label }
        // Fallback for snapshot lines in an unexpected format: use the text of the line that
        // names the ref, so risk words in it still count.
        for line in snapshotText.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if tokens.contains(where: { $0 == ref }) {
                return Self.quoted(String(line)) ?? String(line.trimmingCharacters(in: .whitespaces).prefix(120))
            }
        }
        return nil
    }

    static func isRef(_ s: String) -> Bool {
        s.count >= 2 && s.first == "b" && s.dropFirst().allSatisfy(\.isNumber)
    }

    /// Reads refs from structured data when the tool provides it, and from compact snapshot
    /// lines like `b12 button "Sign in" [disabled]`.
    static func parse(_ output: ToolOutput) -> [String: String] {
        var out: [String: String] = [:]
        if let data = output.data {
            for list in [data["elements"], data["snapshot"]?["elements"], data["refs"]] {
                for e in list?.arrayValue ?? [] {
                    guard let ref = (e["ref"] ?? e["id"])?.stringValue, isRef(ref) else { continue }
                    out[ref] = (e["name"] ?? e["label"])?.stringValue ?? ""
                }
            }
        }
        for rawLine in output.text.split(whereSeparator: \.isNewline) {
            var line = Substring(rawLine).drop(while: { $0 == " " || $0 == "\t" || $0 == "-" || $0 == "*" || $0 == "•" || $0 == "[" })
            if line.hasPrefix("ref=") { line = line.dropFirst(4) }
            let token = line.prefix(while: { $0.isLetter || $0.isNumber })
            guard isRef(String(token)), out[String(token)] == nil else { continue }
            let rest = line.dropFirst(token.count)
            guard let next = rest.first, next == " " || next == "]" || next == ":" || next == "\t" else { continue }
            out[String(token)] = quoted(String(rest)) ?? ""
        }
        return out
    }

    /// The first double-quoted text in a line.
    static func quoted(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\"") else { return nil }
        let after = line[line.index(after: open)...]
        guard let close = after.firstIndex(of: "\"") else { return String(after) }
        return String(after[..<close])
    }
}

// MARK: - Gates and timeouts

/// The gates a step's tool calls run under. Quick tasks share the runtime gate (the user's
/// pause and stop apply to tools too); job steps get a fresh gate per call, stopped when the
/// step is cancelled or the call times out.
final class CallGates: @unchecked Sendable {
    let shared: ExecutionGate?
    private let lock = NSLock()
    private var stopped = false
    private var current: ExecutionGate?

    init(shared: ExecutionGate?) { self.shared = shared }

    var isStopped: Bool { lock.withLock { stopped } || shared?.isStopped == true }

    func makeCallGate() -> ExecutionGate {
        if let shared { return shared }
        let gate = ExecutionGate()
        lock.withLock {
            if stopped { gate.stop() }
            current = gate
        }
        return gate
    }

    func stopAll() {
        let gate: ExecutionGate? = lock.withLock {
            stopped = true
            return current
        }
        gate?.stop()
    }
}

/// Delivers the first of several racing results to one continuation, exactly once.
final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var finished = false

    func install(_ c: CheckedContinuation<T, Error>) {
        let ready: Result<T, Error>? = lock.withLock {
            if let early { self.early = nil; return early }
            continuation = c
            return nil
        }
        if let ready { c.resume(with: ready) }
    }

    /// True for the first result; later ones are dropped.
    @discardableResult
    func finish(_ result: Result<T, Error>) -> Bool {
        var waiting: CheckedContinuation<T, Error>?
        let first: Bool = lock.withLock {
            guard !finished else { return false }
            finished = true
            if let c = continuation { waiting = c; continuation = nil } else { early = result }
            return true
        }
        waiting?.resume(with: result)
        return first
    }
}

extension LLMError {
    /// Errors a retry inside the step can't fix (no key, bad model, rejected request): fail the
    /// step at once instead of spending the error budget.
    var endsStep: Bool {
        switch self {
        case .missingKey, .notConfigured: return true
        case .http(let code, _): return !(code == 429 || code == 408 || code >= 500)
        default: return false
        }
    }
}

// MARK: - Integration adapters

/// An MCP server's tool as an `AgentTool`, so MCP steps use the same loop, safety and approvals.
struct MCPToolAdapter: AgentTool {
    let tool: MCPTool
    let call: @Sendable (String, JSONValue) async throws -> (text: String, isError: Bool)

    var spec: ToolSpec {
        ToolSpec(name: tool.qualifiedName, summary: ToolStepRunner.clip(tool.description.isEmpty ? "MCP tool \(tool.name) on \(tool.server)" : tool.description, 240),
                 inputSchema: tool.inputSchema, category: .integration)
    }

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        // The tool's own name is judged (send/delete/post → high); the server name isn't, so a
        // server called "post-office" doesn't make every tool high risk.
        let v = SafetyPolicy(settings: context.settings.safety).assessTool(name: tool.name, risk: .low)
        return ToolVerdict(risk: v.risk, reasons: v.reasons, summary: "Run \(tool.name) on \(tool.server)")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let start = Date()
        let r = try await call(tool.qualifiedName, arguments)
        return ToolOutput(ok: !r.isError, text: toolTruncate(r.text.isEmpty ? (r.isError ? "The tool reported an error." : "(no output)") : r.text),
                          durationMs: Date().timeIntervalSince(start) * 1000)
    }

    /// The tools most relevant to the step (keyword overlap with name and description), capped
    /// so a dozen servers don't crowd the prompt.
    static func relevant(_ tools: [MCPTool], to instruction: String, limit: Int = 40) -> [MCPTool] {
        guard tools.count > limit else { return tools }
        let words = Set(ElementMatcherShim.tokens(instruction))
        let scored = tools.enumerated().map { i, t -> (Int, Int, MCPTool) in
            let text = Set(ElementMatcherShim.tokens(t.name.replacingOccurrences(of: "_", with: " ") + " " + t.description))
            return (words.intersection(text).count, i, t)
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.prefix(limit).map(\.2)
    }
}

/// A Composio tool found for this step, as an `AgentTool`.
struct ComposioToolAdapter: AgentTool {
    let schema: ComposioClient.ToolSchema
    let client: ComposioClient
    let sessionID: String

    var spec: ToolSpec {
        let summary = (schema.toolkit.isEmpty ? "" : "(\(schema.toolkit)) ") + schema.description
        return ToolSpec(name: schema.slug, summary: ToolStepRunner.clip(summary, 300), inputSchema: schema.inputSchema ?? ["type": "object"],
                        category: .integration)
    }

    func assess(_ arguments: JSONValue, context: ToolContext) -> ToolVerdict {
        let v = SafetyPolicy(settings: context.settings.safety).assessTool(name: schema.slug, risk: .low)
        return ToolVerdict(risk: v.risk, reasons: v.reasons, summary: "Run \(schema.slug)")
    }

    func run(_ arguments: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let start = Date()
        let r = try await client.execute(sessionID: sessionID, tool: schema.slug, arguments: arguments)
        let ms = Date().timeIntervalSince(start) * 1000
        if r.needsInput { return ToolOutput(ok: false, text: "The tool needs more input from you in Composio.", durationMs: ms) }
        let text = r.successful ? r.data.jsonString() : (r.error ?? "The tool failed.")
        return ToolOutput(ok: r.successful, text: toolTruncate(text), data: r.successful ? r.data : nil, durationMs: ms)
    }
}
