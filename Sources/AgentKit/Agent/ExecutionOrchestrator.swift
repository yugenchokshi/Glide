import Foundation
import AppKit
import AutomationKit
import os

/// Shared automation services (one accessibility engine per process).
public final class AutomationRuntime: @unchecked Sendable {
    public static let shared = AutomationRuntime()

    public let gate = ExecutionGate()
    public let accessibility = AccessibilityEngine()
    public lazy var perception = PerceptionEngine(accessibility: accessibility)
    public lazy var verification = VerificationEngine(accessibility: accessibility)
    public lazy var executor: NativeActionExecutor = {
        let e = NativeActionExecutor(accessibility: accessibility, gate: gate)
        let v = verification
        e.onActionStart = { v.noteActionStart() }
        return e
    }()
    public let interference = UserInterferenceMonitor()
    /// The user-input monitor background jobs' on-screen steps run (`UserTakeoverWatch`). Its
    /// own instance, so a job step never stops the quick task's; long-lived, because the
    /// monitor's event tap refers to it without retaining it.
    public let jobInterference = UserInterferenceMonitor()

    public init() {}
}

/// Runs one task end to end: plan → run each step on its route → replan on failure → report.
/// On-screen steps (gui, native) go through `GUIStepRunner`; command, browser, web, data,
/// Composio and MCP steps go through `ToolStepRunner`, which works directly without the
/// cursor. Long or repetitive requests (plan mode `job`) are handed to the job engine when a
/// job host is available. Never loops without progress: step, action, retry, time and
/// repetition limits all end the task with an explanation.
public final class ExecutionOrchestrator: @unchecked Sendable {
    /// Creates a background job for a request the planner marked `job`. Returns nil when no
    /// job could be created, in which case the plan runs as a quick task.
    public typealias JobHandoff = @Sendable (_ instruction: String, _ plan: Plan) async -> JobRecord?

    public let taskID = UUID().uuidString
    let instruction: String
    let settings: AppSettings
    let runtime: AutomationRuntime
    let callbacks: AgentCallbacks
    let store: LocalStore?
    let router: ModelRouter
    let metrics = TaskMetrics()
    let planner: AgentPlanner
    let selector: ActionSelector
    let gui: GUIStepRunner
    let tools: ToolRegistry
    let integrations: ToolStepRunner.Integrations
    let jobHandoff: JobHandoff?
    let log = Logger(subsystem: "dev.glide", category: "orchestrator")

    /// Include the frontmost app, window and browser page in the planning context. Tests turn
    /// it off so planning never reads the user's screen or sends Apple Events to a browser.
    var screenContext = true
    /// Tests: one scripted model for planning, recovery and tool steps instead of the router.
    var testModel: (provider: any LLMProvider, model: String)?
    /// Tests: runs a stuck browser step's on-screen try instead of the GUI loop.
    var onScreenRunner: (@Sendable (PlanStep) async throws -> StepResult)?
    /// Brings the task's browser tab and its Chrome window to the front before the on-screen
    /// try (tests make it a no-op).
    var bringBrowserForward: @Sendable (_ sessionKey: String) async -> Void = { await OnScreenSwitch.bringForward(sessionKey: $0) }
    /// Whether on-screen steps can run now (tests pretend they can).
    var screenAvailable: @Sendable () -> Bool = { AccessibilityEngine.isTrusted }

    /// The task's conversation with the user (the controller's): the plan's ack and questions
    /// go out through it, steps that need an answer wait on it, and the step runners hear the
    /// user's notes from it. Nil runs the task without talking (glidectl `run`, tests).
    var conversation: TaskConversation?
    /// What the conversation so far established, for the planner (the previous task within the
    /// follow-up window, what an instant action just opened).
    var conversationContext: String?
    /// A task still running after this long says "Still on it." once (0 = never). Glide is
    /// otherwise quiet while it works: the notch shows progress.
    var progressAfter: TimeInterval = SpokenLine.progressAfter

    /// Notes, action count, deadline and screenshot consent shared by this task's steps.
    /// Replaced at the start of each run; only read and written by the run itself.
    private var session = TaskSession(limits: LimitSettings())
    private var start = Date()
    private var finalMessage: String?
    /// Set once a step failed or moved on screen: from then on tool steps are told what
    /// already took effect, so they check before repeating it.
    private var retrying = false
    /// Whether a browser step ran, so replanning takes a fresh look at the task's tab.
    private var usedBrowser = false
    /// The final result as the step that finished the task wants it said.
    private var finalSpoken: String?

    private var activePlanner: AgentPlanner {
        testModel.map { AgentPlanner(provider: $0.provider, model: $0.model, metrics: metrics) } ?? planner
    }

    public init(instruction: String, settings: AppSettings, runtime: AutomationRuntime = .shared, callbacks: AgentCallbacks,
                store: LocalStore? = .shared, credentials: CredentialStore = .shared, composio: (ComposioClient, String)? = nil,
                tools: ToolRegistry? = nil, jobHandoff: JobHandoff? = nil) {
        self.instruction = instruction
        self.settings = settings
        self.runtime = runtime
        self.callbacks = callbacks
        self.store = settings.keepHistory ? store : nil
        self.router = ModelRouter(settings: settings, credentials: credentials)
        self.planner = AgentPlanner(router: router, metrics: metrics)
        self.selector = ActionSelector(router: router, metrics: metrics)
        self.gui = GUIStepRunner(settings: settings, runtime: runtime, router: router)
        self.tools = tools ?? ToolRegistry.standard(settings: settings)
        self.jobHandoff = jobHandoff
        let mcp = ToolStepRunner.Integrations.standard(settings: settings)
        self.integrations = ToolStepRunner.Integrations(composio: { composio }, mcpTools: mcp.mcpTools, mcpCall: mcp.mcpCall)
    }

    // MARK: - Logging helpers

    private func emit(_ e: ActivityEntry) {
        callbacks.log(e)
        store?.appendEvent(taskID: taskID, e)
    }

    private func phase(_ p: AgentPhase, _ status: String) { callbacks.phase(p, status) }

    /// Callbacks for the step runners: their log entries are persisted with this task.
    private var stepCallbacks: AgentCallbacks {
        AgentCallbacks(phase: callbacks.phase, log: { [weak self] e in self?.emit(e) }, plan: callbacks.plan, approve: callbacks.approve,
                       waitingForUser: callbacks.waitingForUser, jobInterrupted: callbacks.jobInterrupted)
    }

    // MARK: - Run

    public func run(plan presetPlan: Plan? = nil) async -> TaskResult {
        start = Date()
        session = TaskSession(limits: settings.limits, start: start)
        retrying = false
        usedBrowser = false
        finalSpoken = nil
        finalMessage = nil
        // The caller resets the gate before starting (so a stop pressed early isn't undone here).
        runtime.executor.input.cursorMode = settings.cursorMode
        store?.startTask(id: taskID, instruction: instruction, at: start)
        if settings.safety.pauseOnUserInput {
            runtime.interference.start { [weak self] in self?.userTookOver() }
        }
        defer { runtime.interference.stop() }

        let result = await execute(presetPlan: presetPlan)
        store?.finishTask(id: taskID, result: result)
        return result
    }

    private func userTookOver() {
        guard runtime.gate.current == .running else { return }
        // Only a takeover while the agent is actively driving input counts.
        guard Date().timeIntervalSince(runtime.executor.input.lastPost) < 2.5 else { return }
        runtime.gate.pause()
        Task { await metrics.recordIntervention() }
        phase(.paused, "Paused — you moved the mouse. Resume when ready.")
        emit(ActivityEntry(kind: .info, title: "Paused because you used the mouse"))
    }

    private func finish(_ status: TaskResult.Status, summary: String, error: String? = nil, plan: Plan?, jobID: String? = nil) async -> TaskResult {
        let snapshot = await metrics.snapshot()
        let duration = Date().timeIntervalSince(start) * 1000
        // Nothing is left to answer once the task has ended.
        conversation?.close()
        switch status {
        case .completed: phase(.completed, summary)
        case .failed: phase(.failed, error ?? summary)
        case .stopped: phase(.stopped, "Stopped")
        case .needsInput: phase(.needsInput, summary)
        }
        emit(ActivityEntry(kind: status == .completed ? .result : .error, title: status == .completed ? summary : (error ?? summary), success: status == .completed, durationMs: duration))
        var result = TaskResult(status: status, summary: summary, error: error, plan: plan, metrics: snapshot, durationMs: duration, jobID: jobID)
        if status == .completed { result.spoken = SpokenLine.result(summary: summary, spoken: finalSpoken, instruction: instruction) }
        if status != .stopped { result.front = frontDescription() }
        return result
    }

    /// The app, window and page in front, for a follow-up request; nil when the screen isn't
    /// read (tests).
    private func frontDescription() -> String? {
        guard screenContext else { return nil }
        let ax = runtime.accessibility
        guard let front = ax.frontmostApp() else { return nil }
        var text = front.name
        if let title = ax.focusedWindow(pid: front.pid).flatMap({ AX_title($0) }), !title.isEmpty { text += " — “\(title)”" }
        if let browser = BrowserAdapter.browser(forBundleID: front.bundleID), let page = runtime.perception.browser.currentPage(browser) {
            text += " showing \(page.title) (\(page.url))"
        }
        return text
    }

    private func execute(presetPlan: Plan?) async -> TaskResult {
        // Accessibility is only needed for on-screen steps, so it's checked per step: tasks done
        // entirely with tools run without it.
        phase(.planning, "Understanding your task…")
        let context = await planningContext()
        var plan: Plan
        do {
            if let presetPlan {
                plan = presetPlan
            } else {
                plan = try await activePlanner.plan(instruction, context: context)
            }
        } catch is CancellationError {
            return await finish(.stopped, summary: "Stopped", plan: nil)
        } catch {
            return await finish(.failed, summary: "Couldn't plan the task", error: error.localizedDescription, plan: nil)
        }
        if runtime.gate.isStopped { return await finish(.stopped, summary: "Stopped", plan: plan) }
        if let question = plan.clarification, plan.steps.isEmpty {
            return await finish(.needsInput, summary: question, plan: plan)
        }
        // Ask what the plan needs to know (the question is the acknowledgement), or say "On it."
        // when the work will take a while; quick tasks go quietly. The steps that don't depend
        // on the answers start right away.
        if let conversation {
            if let ack = SpokenLine.ack(for: plan) { conversation.speak(.ack(ack)) }
            for q in plan.questions { conversation.post(q) }
            if !plan.questions.isEmpty {
                emit(ActivityEntry(kind: .info, title: plan.questions.count == 1 ? "Asked a question" : "Asked \(plan.questions.count) questions",
                                   detail: plan.questions.map(\.text).joined(separator: "\n")))
            }
        }
        if plan.mode == .job, let jobHandoff {
            phase(.planning, "Setting up a background job…")
            emit(ActivityEntry(kind: .plan, title: "Long task — handing it to a background job", detail: plan.goal))
            if let job = await jobHandoff(instruction, plan) {
                return await finishHandoff(job, plan: plan)
            }
            // Nil after a Stop means "don't start anything", not "run it here instead".
            if runtime.gate.isStopped || Task.isCancelled { return await finish(.stopped, summary: "Stopped", plan: plan) }
            emit(ActivityEntry(kind: .info, title: "Background jobs aren't available; running it now instead"))
        }
        guard !plan.steps.isEmpty else { return await finish(.failed, summary: "The plan was empty", error: "The planner returned no steps.", plan: plan) }
        emit(ActivityEntry(kind: .plan, title: "Planned \(plan.steps.count) steps", detail: plan.steps.map { "\($0.id). \($0.title) [\($0.route.rawValue)]" }.joined(separator: "\n")))

        // One "Still on it." if the whole task runs past `progressAfter` (planning included).
        let ticker = progressTicker()
        defer { ticker?.cancel() }
        var index = 0
        var completed: [PlanStep] = []
        var replans = 0
        while index < plan.steps.count {
            if index >= settings.limits.maxSteps {
                return await finish(.failed, summary: "Step limit reached", error: "Stopped after \(settings.limits.maxSteps) steps without finishing.", plan: plan)
            }
            let step = plan.steps[index]
            if step.route.needsScreen, !AccessibilityEngine.isTrusted {
                return await finish(.failed, summary: "Accessibility permission needed", error: AutomationError.accessibilityNotTrusted.localizedDescription, plan: plan)
            }
            callbacks.plan(plan, index)
            // Only a step that needs an answer waits for it; everything before it already ran.
            guard await waitForNeeds(of: step, plan: plan) else { return await finish(.stopped, summary: "Stopped", plan: plan) }
            deliverNotes()
            phase(.executing, step.title + "…")
            emit(ActivityEntry(kind: .step, title: step.title, detail: step.instruction, route: step.route, stepID: step.id))
            let stepStart = Date()
            let outcome: StepResult.Status
            do {
                outcome = try await runStep(step, plan: plan)
            } catch is CancellationError {
                return await finish(.stopped, summary: "Stopped", plan: plan)
            } catch AutomationError.stopped {
                return await finish(.stopped, summary: "Stopped", plan: plan)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            let ms = Date().timeIntervalSince(stepStart) * 1000
            switch outcome {
            case .done:
                emit(ActivityEntry(kind: .verify, title: "Finished: \(step.title)", route: step.route, success: true, durationMs: ms, stepID: step.id))
                completed.append(step)
                index += 1
            case .taskDone(let message):
                emit(ActivityEntry(kind: .verify, title: "Finished: \(step.title)", route: step.route, success: true, durationMs: ms, stepID: step.id))
                completed.append(step)
                finalMessage = message
                index = plan.steps.count
            case .blocked(let message):
                return await finish(.needsInput, summary: message, plan: plan)
            case .failed(let reason), .stalled(let reason):
                emit(ActivityEntry(kind: .error, title: "Step failed: \(step.title)", detail: reason, route: step.route, success: false, durationMs: ms, stepID: step.id))
                if runtime.gate.isStopped { return await finish(.stopped, summary: "Stopped", plan: plan) }
                guard replans < settings.limits.maxReplans, Date() < session.deadline else {
                    return await finish(.failed, summary: "Couldn't complete “\(step.title)”", error: reason, plan: plan)
                }
                replans += 1
                retrying = true
                await metrics.recordRecovery()
                phase(.planning, "Finding another way…")
                emit(ActivityEntry(kind: .recovery, title: "Replanning (attempt \(replans))", detail: reason))
                do {
                    let screen = screenContext
                        ? (try? await gui.observeCurrent(session: session, metrics: metrics))?.compact(maxElements: 120, maxTextChars: 2000) ?? "(no window)"
                        : "(not read)"
                    // What already took effect and where the page is now, so the new plan checks
                    // the cart instead of adding the item again.
                    let page = usedBrowser ? await browserPage() : nil
                    let revised = try await activePlanner.replan(instruction, plan: plan, completed: completed, failedStep: step, failure: reason,
                                                                 notes: session.notesText, screen: screen, context: await planningContext(),
                                                                 alreadyDone: session.sideEffects, page: page)
                    if let q = revised.clarification, revised.steps.isEmpty {
                        return await finish(.failed, summary: "Couldn't complete “\(step.title)”", error: q, plan: plan)
                    }
                    // Renumber the remaining steps after the completed ones.
                    var steps = completed
                    for (i, var s) in revised.steps.enumerated() { s.id = completed.count + i + 1; steps.append(s) }
                    plan.steps = steps
                    // New questions the revised plan asks (the ones already asked keep their answers).
                    let known = Set(plan.questions.map(\.id))
                    for q in revised.questions where !known.contains(q.id) {
                        plan.questions.append(q)
                        conversation?.post(q)
                    }
                    emit(ActivityEntry(kind: .plan, title: "Revised plan", detail: revised.steps.map { "\($0.title) [\($0.route.rawValue)]" }.joined(separator: "\n")))
                } catch is CancellationError {
                    return await finish(.stopped, summary: "Stopped", plan: plan)
                } catch {
                    return await finish(.failed, summary: "Couldn't complete “\(step.title)”", error: "\(reason) (replanning failed: \(error.localizedDescription))", plan: plan)
                }
            }
        }
        callbacks.plan(plan, plan.steps.count)
        let summary = finalMessage ?? (session.notes.last.map { "Done. \($0.prefix(300))" } ?? "Done: \(plan.goal)")
        return await finish(.completed, summary: summary, plan: plan)
    }

    /// Finishes the quick task after handing it to the job engine, reporting what happened to the job.
    private func finishHandoff(_ job: JobRecord, plan: Plan) async -> TaskResult {
        switch job.status {
        case .failed:
            return await finish(.failed, summary: "Couldn't start a background job", error: job.lastError ?? "The job couldn't be planned.",
                                plan: plan, jobID: job.id)
        case .needsInput:
            let question = job.plan?.clarification ?? job.lastError ?? (job.statusLine.isEmpty ? "The background job needs more information." : job.statusLine)
            return await finish(.needsInput, summary: question, plan: plan, jobID: job.id)
        case .stopped:
            return await finish(.failed, summary: "The background job was stopped", error: job.lastError ?? "It was stopped before it started.",
                                plan: plan, jobID: job.id)
        case .awaitingConfirmation:
            return await finish(.completed, summary: "Planned a background job: \(job.title). Review the estimate to start it.", plan: plan, jobID: job.id)
        case .completed:
            return await finish(.completed, summary: job.summary ?? "Finished the background job: \(job.title)", plan: plan, jobID: job.id)
        case .planning, .running, .paused, .waiting:
            return await finish(.completed, summary: "Started a background job: \(job.title)", plan: plan, jobID: job.id)
        }
    }

    // MARK: - Conversation

    /// Waits until every question `step` needs is answered. Shows "Waiting for your answer…"
    /// meanwhile, and the wait doesn't count toward the task's time limit. False when the task
    /// was stopped while waiting.
    private func waitForNeeds(of step: PlanStep, plan: Plan) async -> Bool {
        guard let conversation else { return true }
        let open = step.needs.filter { conversation.isOpen($0) }
        guard !open.isEmpty else { return true }
        phase(.executing, Self.waitingStatus)
        emit(ActivityEntry(kind: .info, title: Self.waitingStatus, detail: open.compactMap { conversation.question($0)?.text }.joined(separator: "\n"),
                           stepID: step.id))
        let started = Date()
        for id in open {
            let answer = await conversation.waitForAnswer(id)
            if Task.isCancelled || runtime.gate.isStopped || (answer == nil && conversation.isClosed) { return false }
            if let answer, let q = conversation.question(id) {
                if conversation.wasDefaulted(id) {
                    session.appendNote("No answer to “\(q.text)”, so going with the default: \(answer)")
                    emit(ActivityEntry(kind: .info, title: "Going with \(answer)", detail: q.text, stepID: step.id))
                } else {
                    session.appendNote("The user answered “\(q.text)”: \(answer)")
                    emit(ActivityEntry(kind: .info, title: "You answered: \(answer)", detail: q.text, stepID: step.id))
                }
            }
        }
        session.extendDeadline(by: Date().timeIntervalSince(started))
        return true
    }

    static let waitingStatus = "Waiting for your answer…"

    /// What the user said since the last step, into the notes every later step reads.
    private func deliverNotes() {
        guard let conversation else { return }
        for note in conversation.takeNotes() { session.appendNote("From the user: \(note)") }
    }

    /// Says "Still on it." once when the task has run `progressAfter` seconds. Skipped while
    /// paused or while a question is open (then it waits until neither is true); the
    /// conversation drops it once the task has ended.
    private func progressTicker() -> Task<Void, Never>? {
        guard let conversation, progressAfter > 0 else { return nil }
        let after = max(0, progressAfter - Date().timeIntervalSince(start)), gate = runtime.gate
        return Task {
            try? await Task.sleep(for: .seconds(after))
            while !Task.isCancelled, gate.isPaused || conversation.current != nil {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            conversation.speak(.progress(SpokenLine.progressLine))
        }
    }

    // MARK: - Context

    private func planningContext() async -> PlanningContext {
        var ctx = PlanningContext()
        ctx.conversation = conversationContext
        if screenContext {
            let ax = runtime.accessibility
            let front = ax.frontmostApp()
            ctx.frontmostApp = front?.name
            ctx.runningApps = ax.runningApps().map(\.name)
            if let front { ctx.windowTitle = ax.focusedWindow(pid: front.pid).flatMap { AX_title($0) } }
            if let browser = BrowserAdapter.browser(forBundleID: front?.bundleID), let page = runtime.perception.browser.currentPage(browser) {
                ctx.browserPage = "\(page.title) — \(page.url)"
            }
        }
        if let (client, composioSession) = await integrations.composio(),
           let kits = try? await client.toolkits(sessionID: composioSession, connectedOnly: true) {
            ctx.composioToolkits = kits.map(\.slug)
        }
        ctx.mcpTools = await integrations.mcpTools()
        ctx.skills = (store ?? LocalStore.shared).skills()
            .map { ($0, $0.relevance(to: instruction)) }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }.map(\.0)
        ctx.routes = await RouteAvailability.current(settings: settings, tools: tools, backgroundJobs: jobHandoff != nil)
        return ctx
    }

    // MARK: - Steps

    private func runStep(_ step: PlanStep, plan: Plan) async throws -> StepResult.Status {
        switch step.route {
        case .answer:
            phase(.executing, "Writing the answer…")
            if let testModel {
                // Scripted runs write the answer with the tool loop's answer writer on the test model.
                let runner = ToolStepRunner(settings: settings, runtime: runtime, tools: tools, models: .fixed(provider: testModel.provider, model: testModel.model),
                                            integrations: integrations)
                let request = StepRequest(goal: plan.goal.isEmpty ? instruction : plan.goal, step: RecipeStep(step),
                                          context: "Task: \(instruction)\n\nNotes so far:\n" + session.notesText, allowedCategories: [.workspace])
                let result = try await runner.execute(request, callbacks: stepCallbacks)
                if let spoken = result.fields[ToolStepRunner.spokenField]?.stringValue { finalSpoken = spoken }
                return result.status
            }
            let answer = try await selector.answer(instruction: instruction, step: step, notes: session.notesText)
            finalSpoken = answer.spoken
            return .taskDone(answer.message)
        case .gui, .native:
            var run = GUIStepRunner.Run(instruction: instruction, plan: plan, session: session, metrics: metrics, callbacks: stepCallbacks)
            run.conversation = conversation
            let outcome = try await gui.run(step, run)
            if let spoken = outcome.spoken { finalSpoken = spoken }
            return outcome.status
        case .command, .browser, .web, .data, .composio, .mcp:
            let result = try await runToolStep(step, plan: plan)
            guard OnScreenSwitch.applies(route: step.route, status: result.status, settings: settings), screenAvailable() else { return result.status }
            return try await runOnScreen(step, plan: plan, after: result)
        }
    }

    /// Runs a step with tools (no cursor). What it produced becomes a note, so later steps and
    /// the final answer can use it.
    private func runToolStep(_ step: PlanStep, plan: Plan) async throws -> StepResult {
        if step.route == .browser { usedBrowser = true }
        let planLines = plan.steps.map { ($0.id == step.id ? "→ " : "  ") + "\($0.id). \($0.title) [\($0.route.rawValue)]" }.joined(separator: "\n")
        var context = "Task: \(instruction)\nPlan:\n\(planLines)"
        // Before the notes, which can be long: the step's prompt keeps the start of the context.
        if retrying {
            let page = RetryNotes.page(BrowserSessions.shared.currentSnapshot(BrowserSessions.key(jobID: nil, itemID: nil)))
            if let done = RetryNotes.render(session.sideEffects, page: page) { context += "\n\n" + done }
        }
        let notes = session.notesText
        if !notes.isEmpty { context += "\n\nNotes so far:\n" + String(notes.suffix(5000)) }
        let request = StepRequest(goal: plan.goal.isEmpty ? instruction : plan.goal, step: RecipeStep(step), context: context,
                                  allowedCategories: step.route.toolCategories, maxTurns: settings.limits.maxActionsPerStep)
        let models: ToolStepRunner.ModelSource = testModel.map { .fixed(provider: $0.provider, model: $0.model) } ?? .router(router)
        var runner = ToolStepRunner(settings: settings, runtime: runtime, tools: tools, models: models, integrations: integrations)
        runner.session = session
        runner.metrics = metrics
        runner.conversation = conversation
        let result = try await runner.execute(request, callbacks: stepCallbacks)
        if let spoken = result.fields[ToolStepRunner.spokenField]?.stringValue { finalSpoken = spoken }
        // What a stuck step tried is for its on-screen try, not a note (the final summary
        // may be the last note).
        let facts = ToolStepRunner.facts(in: result.output)
        if !facts.isEmpty {
            session.appendNote("\(step.title): \(facts.prefix(4000))")
            if case .done = result.status {
                emit(ActivityEntry(kind: .info, title: "Noted information", detail: String(facts.prefix(400)), route: step.route, stepID: step.id))
            }
        }
        return result
    }

    /// Runs a browser step that got stuck once more on screen, in the Chrome window showing its
    /// tab (a quick task already holds the screen lease). It's told why the first try stalled,
    /// what it tried and what already took effect. A failure here goes on to the usual
    /// replanning, which hears about both tries.
    private func runOnScreen(_ step: PlanStep, plan: Plan, after result: StepResult) async throws -> StepResult.Status {
        let reason = OnScreenSwitch.reason(result.status)
        retrying = true
        emit(ActivityEntry(kind: .info, title: OnScreenSwitch.title, detail: OnScreenSwitch.detail, route: .gui, stepID: step.id))
        phase(.executing, OnScreenSwitch.title + "…")
        await bringBrowserForward(BrowserSessions.key(jobID: nil, itemID: nil))
        let briefing = OnScreenSwitch.briefing(reason: reason, tried: result.output, alreadyDone: session.sideEffects)
        let screenStep = OnScreenSwitch.screenStep(step, briefing: briefing)
        let status: StepResult.Status
        if let onScreenRunner {
            let r = try await onScreenRunner(screenStep)
            for effect in r.sideEffects { session.recordSideEffect(effect) }
            status = r.status
        } else {
            var run = GUIStepRunner.Run(instruction: instruction, plan: plan, session: session, metrics: metrics, callbacks: stepCallbacks)
            run.conversation = conversation
            let outcome = try await gui.run(screenStep, run)
            if let spoken = outcome.spoken { finalSpoken = spoken }
            status = outcome.status
        }
        switch status {
        case .failed(let why), .stalled(let why): return .failed("\(reason) On screen: \(why)")
        case .done, .taskDone, .blocked: return status
        }
    }

    /// A fresh look at the task's browser tab (title, address and the start of a snapshot) for
    /// the recovery planner; nil when there's no snapshot tool or it doesn't answer in time.
    private func browserPage() async -> String? {
        guard let tool = tools.tool(named: "browser.snapshot") else { return nil }
        let context = ToolContext(settings: settings, gate: runtime.gate, workspace: nil, jobID: nil, itemID: nil,
                                  workingDirectory: FileManager.default.homeDirectoryForCurrentUser, log: { _ in })
        let output: ToolOutput? = await withTaskGroup(of: ToolOutput?.self) { group in
            group.addTask { try? await tool.run(.object([:]), context: context) }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let output, output.ok, !output.text.isEmpty else { return nil }
        return ToolStepRunner.clip(output.text, 3000)
    }

    // MARK: - Control

    public func stop() {
        runtime.gate.stop()
    }
}

private func AX_title(_ el: AXUIElement) -> String? {
    var v: AnyObject?
    guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &v) == .success else { return nil }
    return v as? String
}
