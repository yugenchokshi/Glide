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

    /// Notes, action count, deadline and screenshot consent shared by this task's steps.
    /// Replaced at the start of each run; only read and written by the run itself.
    private var session = TaskSession(limits: LimitSettings())
    private var start = Date()
    private var finalMessage: String?

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
        switch status {
        case .completed: phase(.completed, summary)
        case .failed: phase(.failed, error ?? summary)
        case .stopped: phase(.stopped, "Stopped")
        case .needsInput: phase(.needsInput, summary)
        }
        emit(ActivityEntry(kind: status == .completed ? .result : .error, title: status == .completed ? summary : (error ?? summary), success: status == .completed, durationMs: duration))
        return TaskResult(status: status, summary: summary, error: error, plan: plan, metrics: snapshot, durationMs: duration, jobID: jobID)
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
                plan = try await planner.plan(instruction, context: context)
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
            case .failed(let reason):
                emit(ActivityEntry(kind: .error, title: "Step failed: \(step.title)", detail: reason, route: step.route, success: false, durationMs: ms, stepID: step.id))
                if runtime.gate.isStopped { return await finish(.stopped, summary: "Stopped", plan: plan) }
                guard replans < settings.limits.maxReplans, Date() < session.deadline else {
                    return await finish(.failed, summary: "Couldn't complete “\(step.title)”", error: reason, plan: plan)
                }
                replans += 1
                await metrics.recordRecovery()
                phase(.planning, "Finding another way…")
                emit(ActivityEntry(kind: .recovery, title: "Replanning (attempt \(replans))", detail: reason))
                do {
                    let screen = (try? await gui.observeCurrent(session: session, metrics: metrics))?.compact(maxElements: 120, maxTextChars: 2000) ?? "(no window)"
                    let revised = try await planner.replan(instruction, plan: plan, completed: completed, failedStep: step, failure: reason,
                                                           notes: session.notesText, screen: screen, context: await planningContext())
                    if let q = revised.clarification, revised.steps.isEmpty {
                        return await finish(.failed, summary: "Couldn't complete “\(step.title)”", error: q, plan: plan)
                    }
                    // Renumber the remaining steps after the completed ones.
                    var steps = completed
                    for (i, var s) in revised.steps.enumerated() { s.id = completed.count + i + 1; steps.append(s) }
                    plan.steps = steps
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

    // MARK: - Context

    private func planningContext() async -> PlanningContext {
        var ctx = PlanningContext()
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
            let message = try await selector.answer(instruction: instruction, step: step, notes: session.notesText)
            return .taskDone(message)
        case .gui, .native:
            let run = GUIStepRunner.Run(instruction: instruction, plan: plan, session: session, metrics: metrics, callbacks: stepCallbacks)
            return try await gui.run(step, run).status
        case .command, .browser, .web, .data, .composio, .mcp:
            return try await runToolStep(step, plan: plan)
        }
    }

    /// Runs a step with tools (no cursor). What it produced becomes a note, so later steps and
    /// the final answer can use it.
    private func runToolStep(_ step: PlanStep, plan: Plan) async throws -> StepResult.Status {
        let planLines = plan.steps.map { ($0.id == step.id ? "→ " : "  ") + "\($0.id). \($0.title) [\($0.route.rawValue)]" }.joined(separator: "\n")
        var context = "Task: \(instruction)\nPlan:\n\(planLines)"
        let notes = session.notesText
        if !notes.isEmpty { context += "\n\nNotes so far:\n" + String(notes.suffix(5000)) }
        let request = StepRequest(goal: plan.goal.isEmpty ? instruction : plan.goal, step: RecipeStep(step), context: context,
                                  allowedCategories: step.route.toolCategories, maxTurns: settings.limits.maxActionsPerStep)
        var runner = ToolStepRunner(settings: settings, runtime: runtime, tools: tools, models: .router(router), integrations: integrations)
        runner.session = session
        runner.metrics = metrics
        let result = try await runner.execute(request, callbacks: stepCallbacks)
        if !result.output.isEmpty {
            session.appendNote("\(step.title): \(result.output.prefix(4000))")
            if case .done = result.status {
                emit(ActivityEntry(kind: .info, title: "Noted information", detail: String(result.output.prefix(400)), route: step.route, stepID: step.id))
            }
        }
        return result.status
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
