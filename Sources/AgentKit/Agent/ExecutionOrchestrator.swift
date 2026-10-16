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

    public init() {}
}

/// Runs one task end to end: plan → (observe → resolve → safety → act → verify)* → replan on
/// failure → report. Never loops without progress: step, action, retry, time and repetition
/// limits all end the task with an explanation.
public final class ExecutionOrchestrator: @unchecked Sendable {
    public let taskID = UUID().uuidString
    let instruction: String
    let settings: AppSettings
    let runtime: AutomationRuntime
    let callbacks: AgentCallbacks
    let store: LocalStore?
    let router: ModelRouter
    let metrics = TaskMetrics()
    let safety: SafetyPolicy
    let planner: AgentPlanner
    let selector: ActionSelector
    let resolver: ActionResolver
    let grounding: VisionGrounding
    let log = Logger(subsystem: "dev.glide", category: "orchestrator")

    private var notes: [String] = []
    private var totalActions = 0
    private var screenshotConsentGiven = false
    private var start = Date()
    private var deadline = Date.distantFuture
    private var finalMessage: String?
    private var composio: (ComposioClient, String)?
    /// Last app the agent acted in; used when the frontmost app is Glide or a terminal.
    private var currentApp: AppInfo?

    enum StepOutcome {
        case done
        case taskDone(String)
        case failed(String)
        case blocked(String)
    }

    public init(instruction: String, settings: AppSettings, runtime: AutomationRuntime = .shared, callbacks: AgentCallbacks,
                store: LocalStore? = .shared, credentials: CredentialStore = .shared, composio: (ComposioClient, String)? = nil) {
        self.instruction = instruction
        self.settings = settings
        self.runtime = runtime
        self.callbacks = callbacks
        self.store = settings.keepHistory ? store : nil
        self.router = ModelRouter(settings: settings, credentials: credentials)
        self.safety = SafetyPolicy(settings: settings.safety)
        self.planner = AgentPlanner(router: router, metrics: metrics)
        self.selector = ActionSelector(router: router, metrics: metrics)
        self.resolver = ActionResolver(jev: router.jevClient(), metrics: metrics)
        self.grounding = VisionGrounding(perception: runtime.perception)
        self.composio = composio
    }

    // MARK: - Logging helpers

    private func emit(_ e: ActivityEntry) {
        callbacks.log(e)
        store?.appendEvent(taskID: taskID, e)
    }

    private func phase(_ p: AgentPhase, _ status: String) { callbacks.phase(p, status) }

    private var notesText: String { notes.joined(separator: "\n") }

    // MARK: - Run

    public func run(plan presetPlan: Plan? = nil) async -> TaskResult {
        start = Date()
        deadline = start.addingTimeInterval(settings.limits.taskTimeoutSeconds)
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

    private func finish(_ status: TaskResult.Status, summary: String, error: String? = nil, plan: Plan?) async -> TaskResult {
        let snapshot = await metrics.snapshot()
        let duration = Date().timeIntervalSince(start) * 1000
        switch status {
        case .completed: phase(.completed, summary)
        case .failed: phase(.failed, error ?? summary)
        case .stopped: phase(.stopped, "Stopped")
        case .needsInput: phase(.needsInput, summary)
        }
        emit(ActivityEntry(kind: status == .completed ? .result : .error, title: status == .completed ? summary : (error ?? summary), success: status == .completed, durationMs: duration))
        return TaskResult(status: status, summary: summary, error: error, plan: plan, metrics: snapshot, durationMs: duration)
    }

    private func execute(presetPlan: Plan?) async -> TaskResult {
        guard AccessibilityEngine.isTrusted else {
            return await finish(.failed, summary: "Accessibility permission needed", error: AutomationError.accessibilityNotTrusted.localizedDescription, plan: nil)
        }
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
            callbacks.plan(plan, index)
            phase(.executing, step.title + "…")
            emit(ActivityEntry(kind: .step, title: step.title, detail: step.instruction, route: step.route, stepID: step.id))
            let stepStart = Date()
            let outcome: StepOutcome
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
                guard replans < settings.limits.maxReplans, Date() < deadline else {
                    return await finish(.failed, summary: "Couldn't complete “\(step.title)”", error: reason, plan: plan)
                }
                replans += 1
                await metrics.recordRecovery()
                phase(.planning, "Finding another way…")
                emit(ActivityEntry(kind: .recovery, title: "Replanning (attempt \(replans))", detail: reason))
                do {
                    let screen = (try? await observeCurrent())?.compact(maxElements: 120, maxTextChars: 2000) ?? "(no window)"
                    let revised = try await planner.replan(instruction, plan: plan, completed: completed, failedStep: step, failure: reason,
                                                           notes: notesText, screen: screen, context: await planningContext())
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
        let summary = finalMessage ?? (notes.last.map { "Done. \($0.prefix(300))" } ?? "Done: \(plan.goal)")
        return await finish(.completed, summary: summary, plan: plan)
    }

    // MARK: - Context

    private func planningContext() async -> PlanningContext {
        let ax = runtime.accessibility
        let front = ax.frontmostApp()
        var ctx = PlanningContext(frontmostApp: front?.name, runningApps: ax.runningApps().map(\.name))
        if let front { ctx.windowTitle = ax.focusedWindow(pid: front.pid).flatMap { AX_title($0) } }
        if let browser = BrowserAdapter.browser(forBundleID: front?.bundleID), let page = runtime.perception.browser.currentPage(browser) {
            ctx.browserPage = "\(page.title) — \(page.url)"
        }
        if let (client, session) = composio, let kits = try? await client.toolkits(sessionID: session, connectedOnly: true) {
            ctx.composioToolkits = kits.map(\.slug)
        }
        ctx.mcpTools = await MCPManager.shared.allTools()
        ctx.skills = (store ?? LocalStore.shared).skills()
            .map { ($0, $0.relevance(to: instruction)) }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }.map(\.0)
        return ctx
    }

    /// The app to observe: the frontmost app unless it's a terminal/Glide that launched us.
    private func targetApp() -> AppInfo? {
        let ax = runtime.accessibility
        return ax.frontmostApp() ?? currentApp
    }

    private func observeCurrent(forceOCR: Bool = false) async throws -> ScreenObservation? {
        guard let app = targetApp() else { return nil }
        if safety.isExcluded(app: app) { throw AutomationError.blockedBySafety("Glide is set not to read or operate \(app.name).") }
        let t = Date()
        let obs = try await runtime.perception.observe(app, forceOCR: forceOCR)
        await metrics.recordObservation(ms: Date().timeIntervalSince(t) * 1000)
        return obs
    }

    // MARK: - Steps

    private func runStep(_ step: PlanStep, plan: Plan) async throws -> StepOutcome {
        switch step.route {
        case .composio: return try await runComposioStep(step, plan: plan)
        case .mcp: return try await runMCPStep(step, plan: plan)
        case .answer:
            phase(.executing, "Writing the answer…")
            let message = try await selector.answer(instruction: instruction, step: step, notes: notesText)
            return .taskDone(message)
        case .gui, .native:
            return try await runGUIStep(step, plan: plan)
        }
    }

    private func checkLimits() throws {
        if Task.isCancelled || runtime.gate.isStopped { throw AutomationError.stopped }
        if Date() > deadline { throw AutomationError.timeout("the task took longer than \(Int(settings.limits.taskTimeoutSeconds / 60)) minutes") }
        if totalActions >= settings.limits.maxTotalActions { throw AutomationError.timeout("reached the limit of \(settings.limits.maxTotalActions) actions") }
    }

    private func runGUIStep(_ step: PlanStep, plan: Plan) async throws -> StepOutcome {
        var history: [String] = []
        var hintTried = false
        var actionsInStep = 0
        var errors = 0
        var noEffectStreak = 0
        var rejections = 0
        var signatures: [String: Int] = [:]

        // Bring the step's app forward first if it's already running (cheap, deterministic).
        if let appName = step.app, step.hint?.action != "launch_app",
           let running = runtime.executor.apps.runningApp(named: appName),
           running.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            phase(.executing, "Switching to \(running.localizedName ?? appName)…")
            if let info = try? await runtime.executor.apps.activate(running, timeout: 6) {
                currentApp = info
                emit(ActivityEntry(kind: .action, title: "Switched to \(info.name)", route: .native, success: true, stepID: step.id))
            }
        }

        while true {
            try await runtime.gate.checkpoint()
            try checkLimits()
            guard actionsInStep < settings.limits.maxActionsPerStep else {
                return .failed("Too many actions without finishing this step (\(actionsInStep)).")
            }
            var obs: ScreenObservation?
            do {
                obs = try await observeCurrent()
            } catch AutomationError.blockedBySafety(let m) {
                return .blocked(m)
            } catch AutomationError.accessibilityNotTrusted {
                return .blocked(AutomationError.accessibilityNotTrusted.localizedDescription)
            } catch {
                history.append("- observe failed: \(error.localizedDescription)")
            }
            if let a = obs?.app { currentApp = a }

            // 1. Deterministic hint (no model call).
            if !hintTried, let hint = step.hint {
                hintTried = true
                if let action = resolver.compileHint(hint, obs: obs) {
                    let target = Self.targetNode(action, obs: obs)
                    let r = try await perform(action, target: target, obs: obs, modelRisk: step.risk, step: step, expect: nil, deterministic: true, history: &history)
                    actionsInStep += 1
                    switch r {
                    case .ok(let verified): noEffectStreak = verified ? 0 : noEffectStreak + 1
                    case .rejected: rejections += 1
                    case .blocked(let m): return .blocked(m)
                    case .error: errors += 1
                    }
                    // Native single-action steps (launch / open URL) finish when verified.
                    if step.route == .native, case .ok(true) = r, Self.isTerminalNative(action) { return .done }
                    continue
                }
            }
            hintTried = true

            // 2. Ask the action selector.
            phase(.executing, step.title + "…")
            var extra: String?
            if let app = obs?.app, let browser = BrowserAdapter.browser(forBundleID: app.bundleID), let page = runtime.perception.browser.currentPage(browser) {
                extra = "Browser page: \(page.title) — \(page.url)"
                if Self.wantsReading(step), let text = runtime.perception.browser.pageText(browser, maxChars: 8000), !text.isEmpty {
                    extra! += "\nPage text (from the DOM):\n\(text)"
                }
            }
            let decision: ActorDecision
            do {
                decision = try await selector.decide(.init(instruction: instruction, plan: plan, step: step, observation: obs,
                                                           history: history, notes: notesText, extraContext: extra, tools: nil))
            } catch let e as LLMError {
                errors += 1
                history.append("- model error: \(e.localizedDescription)")
                if errors > settings.limits.retryLimit { return .failed(e.localizedDescription) }
                continue
            }
            if let r = decision.remember, !r.isEmpty {
                notes.append(r)
                emit(ActivityEntry(kind: .info, title: "Noted information", detail: String(r.prefix(400)), stepID: step.id))
            }
            switch decision.status {
            case .stepDone:
                return .done
            case .taskDone:
                return .taskDone(decision.message ?? "Done")
            case .blocked:
                return .blocked(decision.message ?? "I can't continue without your help.")
            case .needVision:
                let r = try await groundAndAct(description: decision.targetDescription ?? "the target", kind: decision.action ?? "click",
                                               decision: decision, obs: obs, step: step, history: &history)
                actionsInStep += 1
                if case .blocked(let m) = r { return .blocked(m) }
                if case .error = r { errors += 1 }
            case .act:
                let resolution = await resolver.resolve(decision, obs: obs, objective: step.instruction)
                switch resolution {
                case .action(let action, let target, _):
                    let sig = "\(action.humanDescription)|\(target?.fingerprint ?? "")"
                    signatures[sig, default: 0] += 1
                    if signatures[sig]! > 3 {
                        return .failed("Repeated “\(action.humanDescription)” without progress.")
                    }
                    let r = try await perform(action, target: target, obs: obs, modelRisk: decision.risk, step: step,
                                              expect: decision.expect, deterministic: false, history: &history)
                    actionsInStep += 1
                    switch r {
                    case .ok(let verified): noEffectStreak = verified ? 0 : noEffectStreak + 1
                    case .rejected:
                        rejections += 1
                        if rejections >= 2 { return .blocked("You declined the proposed action. Tell me how you'd like to proceed.") }
                    case .blocked(let m): return .blocked(m)
                    case .error: errors += 1
                    }
                case .needsGrounding(let description, let kind, let d):
                    let r = try await groundAndAct(description: description, kind: kind, decision: d, obs: obs, step: step, history: &history)
                    actionsInStep += 1
                    if case .blocked(let m) = r { return .blocked(m) }
                    if case .error = r { errors += 1 }
                case .tool:
                    history.append("- call_tool isn't available in this step; use the UI.")
                    errors += 1
                case .invalid(let why):
                    history.append("- invalid action: \(why)")
                    errors += 1
                }
            }
            if errors > settings.limits.retryLimit + 1 {
                return .failed(history.last(where: { $0.contains("error") || $0.contains("failed") || $0.contains("invalid") }) ?? "Too many errors.")
            }
            if noEffectStreak >= 4 {
                return .failed("The last \(noEffectStreak) actions had no visible effect.")
            }
        }
    }

    static func wantsReading(_ step: PlanStep) -> Bool {
        let s = (step.instruction + " " + step.title).lowercased()
        return ["read", "extract", "summar", "find", "look up", "get the", "collect", "note the", "copy"].contains { s.contains($0) }
    }

    static func isTerminalNative(_ action: ComputerAction) -> Bool {
        switch action {
        case .launchApp, .activateApp, .openURL: return true
        default: return false
        }
    }

    static func targetNode(_ action: ComputerAction, obs: ScreenObservation?) -> UIElementNode? {
        let target: ElementTarget?
        switch action {
        case .click(let t), .doubleClick(let t), .rightClick(let t), .focus(let t), .selectText(let t), .setValue(let t, _): target = t
        case .typeText(_, let t, _, _): target = t
        default: target = nil
        }
        if case .element(let id)? = target { return obs?.element(id) }
        if case .typeText(_, nil, _, _) = action { return obs?.focusedElement }
        return nil
    }

    enum PerformResult {
        case ok(verified: Bool)
        case rejected
        case blocked(String)
        case error
    }

    /// Safety check → approval → execute → verify → record.
    private func perform(_ action: ComputerAction, target: UIElementNode?, obs: ScreenObservation?, modelRisk: RiskLevel, step: PlanStep,
                         expect: String?, deterministic: Bool, history: inout [String]) async throws -> PerformResult {
        let app = obs?.app ?? targetApp()
        let verdict = safety.assess(action, target: target, app: app, modelRisk: modelRisk, stepRisk: step.risk)
        if let blocked = verdict.blocked {
            emit(ActivityEntry(kind: .approval, title: "Blocked: \(action.humanDescription)", detail: blocked, success: false, stepID: step.id))
            return .blocked(blocked)
        }
        let label = target.map { " “\($0.label.prefix(40))”" } ?? ""
        if safety.needsApproval(verdict) {
            phase(.awaitingApproval, "Needs your approval")
            let req = ApprovalRequest(kind: .action, title: action.humanDescription + label,
                                      detail: step.instruction, appName: app?.name, risk: verdict.risk, reasons: verdict.reasons)
            let decision = await callbacks.approve(req)
            switch decision {
            case .approve:
                emit(ActivityEntry(kind: .approval, title: "You approved: \(action.humanDescription)\(label)", success: true, stepID: step.id))
                phase(.executing, step.title + "…")
            case .reject:
                emit(ActivityEntry(kind: .approval, title: "You declined: \(action.humanDescription)\(label)", success: false, stepID: step.id))
                history.append("- \(action.humanDescription)\(label) → the user DECLINED this action; do not retry it")
                phase(.executing, step.title + "…")
                return .rejected
            case .stop:
                runtime.gate.stop()
                throw AutomationError.stopped
            }
        }
        phase(.executing, action.humanDescription + label)
        try checkLimits()
        do {
            let outcome = try await runtime.executor.execute(action, observation: obs)
            totalActions += 1
            await metrics.recordAction(deterministic: deterministic)
            if let a = outcome.app { currentApp = a }
            let expectation: Expectation = expect.map { .elementAppears($0) } ?? outcome.expectation
            let verifyApp = outcome.app ?? app
            var result = await runtime.verification.verify(expectation, app: verifyApp, before: obs, sinceGeneration: outcome.generationBefore,
                                                           timeout: Self.isTerminalNative(action) ? 4 : 2)
            // If a specific expected element didn't appear, still accept a visible change.
            if result.status == .failed, expect != nil {
                let fallback = await runtime.verification.verify(.uiChanged, app: verifyApp, before: obs, sinceGeneration: outcome.generationBefore, timeout: 0.3)
                if fallback.passed { result = VerificationResult(status: .unconfirmed, detail: "changed, but “\(expect!)” not seen", durationMs: result.durationMs) }
            }
            let verified = result.status == .passed
            emit(ActivityEntry(kind: .action, title: action.humanDescription + label,
                               detail: "\(outcome.method) · \(result.detail)",
                               route: Self.isTerminalNative(action) ? .native : .gui, success: result.status != .failed,
                               durationMs: outcome.durationMs + result.durationMs, stepID: step.id))
            history.append("- \(action.humanDescription)\(label) via \(outcome.method) → \(result.status.rawValue): \(result.detail)")
            return .ok(verified: verified)
        } catch AutomationError.stopped {
            throw AutomationError.stopped
        } catch is CancellationError {
            throw AutomationError.stopped
        } catch AutomationError.blockedBySafety(let m) {
            return .blocked(m)
        } catch {
            emit(ActivityEntry(kind: .error, title: action.humanDescription + label, detail: error.localizedDescription, success: false, stepID: step.id))
            history.append("- \(action.humanDescription)\(label) → error: \(error.localizedDescription)")
            return .error
        }
    }

    /// Finds a target visually (OCR, then a vision model) and performs the action at the
    /// validated point.
    private func groundAndAct(description: String, kind: String, decision: ActorDecision?, obs: ScreenObservation?, step: PlanStep,
                              history: inout [String]) async throws -> PerformResult {
        guard let obs else {
            history.append("- no window to search for \(description)")
            return .error
        }
        guard ScreenCapture.hasPermission else {
            history.append("- can't look for “\(description)” visually: Screen Recording permission isn't granted")
            emit(ActivityEntry(kind: .vision, title: "Screen Recording permission needed to find “\(description)”", success: false, stepID: step.id))
            return .error
        }
        phase(.executing, "Looking for “\(description.prefix(40))”…")
        var hit: VisionGrounding.Hit?
        if let h = try? await grounding.groundWithOCR(description, obs: obs) { hit = h }
        if hit == nil {
            switch settings.safety.screenshotConsent {
            case .never:
                history.append("- “\(description)” isn't in the accessibility tree and screenshots are disabled in Settings")
                return .error
            case .ask where !screenshotConsentGiven:
                phase(.awaitingApproval, "Allow a screenshot?")
                let req = ApprovalRequest(kind: .screenshot, title: "Send a screenshot of \(obs.app.name) to the vision model?",
                                          detail: "“\(description)” isn't exposed to accessibility. A redacted capture of this window (password fields blacked out) will be sent to your configured vision provider.",
                                          appName: obs.app.name, risk: .medium, reasons: ["screenshot leaves your Mac"])
                switch await callbacks.approve(req) {
                case .approve: screenshotConsentGiven = true
                case .reject:
                    history.append("- the user declined sending a screenshot; find another way")
                    return .rejected
                case .stop:
                    runtime.gate.stop()
                    throw AutomationError.stopped
                }
            default: break
            }
            do {
                let route = try router.route(.vision)
                hit = try await grounding.groundWithModel(description, context: step.instruction, obs: obs, route: route, metrics: metrics)
            } catch {
                history.append("- vision grounding failed: \(error.localizedDescription)")
                return .error
            }
        }
        guard let hit else {
            history.append("- couldn't find “\(description)” on screen, even visually")
            emit(ActivityEntry(kind: .vision, title: "Couldn't find “\(description)”", success: false, stepID: step.id))
            return .error
        }
        emit(ActivityEntry(kind: .vision, title: "Found “\(description)” via \(hit.source.rawValue)", detail: hit.description, success: true, stepID: step.id))
        let p = ElementTarget.point(hit.point)
        let pseudo = UIElementNode(role: "button", axRole: "Visual", name: description, frame: CGRect(x: hit.point.x - 2, y: hit.point.y - 2, width: 4, height: 4), source: hit.source)
        let action: ComputerAction
        switch kind {
        case "double_click": action = .doubleClick(p)
        case "right_click": action = .rightClick(p)
        case "type": action = .typeText(decision?.text ?? "", into: p, clearFirst: decision?.clearFirst ?? false, submit: decision?.submit ?? false)
        default: action = .click(p)
        }
        return try await perform(action, target: pseudo, obs: obs, modelRisk: decision?.risk ?? step.risk, step: step,
                                 expect: decision?.expect, deterministic: false, history: &history)
    }

    // MARK: - Integrations

    private func runComposioStep(_ step: PlanStep, plan: Plan) async throws -> StepOutcome {
        guard let (client, session) = composio else {
            return .failed("Composio isn't configured. Add your Composio API key in Settings › Integrations, or do this through the app's UI.")
        }
        phase(.executing, "Finding the right integration…")
        let found = try await client.search(sessionID: session, useCase: step.instruction)
        if found.tools.isEmpty {
            return .failed("No Composio tool matched this step.")
        }
        if !found.missingConnections.isEmpty && found.tools.allSatisfy({ found.missingConnections.contains($0.toolkit) }) {
            return .blocked("Connect \(found.missingConnections.joined(separator: ", ")) in Settings › Integrations, then try again.")
        }
        let toolText = found.tools.map { t in
            "- \(t.slug) (\(t.toolkit)): \(t.description.prefix(300))\n  input schema: \((t.inputSchema ?? [:]).jsonString().prefix(1500))"
        }.joined(separator: "\n") + (found.guidance.isEmpty ? "" : "\nGuidance: " + found.guidance.joined(separator: " "))
        return try await runToolStep(step, plan: plan, toolsText: toolText, route: .composio) { name, args in
            let r = try await client.execute(sessionID: session, tool: name, arguments: args)
            if r.needsInput { return (false, "The tool needs more input from you in Composio.") }
            return (r.successful, r.successful ? r.data.jsonString() : (r.error ?? "failed"))
        }
    }

    private func runMCPStep(_ step: PlanStep, plan: Plan) async throws -> StepOutcome {
        let tools = await MCPManager.shared.allTools()
        guard !tools.isEmpty else { return .failed("No MCP servers are connected.") }
        let toolText = tools.prefix(60).map { "- \($0.qualifiedName): \($0.description.prefix(240))\n  input schema: \($0.inputSchema.jsonString().prefix(1200))" }.joined(separator: "\n")
        return try await runToolStep(step, plan: plan, toolsText: toolText, route: .mcp) { name, args in
            let r = try await MCPManager.shared.call(qualifiedName: name, arguments: args)
            return (!r.isError, r.text)
        }
    }

    private func runToolStep(_ step: PlanStep, plan: Plan, toolsText: String, route: ExecutionRoute,
                             call: (String, JSONValue) async throws -> (Bool, String)) async throws -> StepOutcome {
        var history: [String] = []
        for _ in 0..<3 {
            try checkLimits()
            let d = try await selector.decide(.init(instruction: instruction, plan: plan, step: step, observation: nil, history: history,
                                                    notes: notesText, extraContext: Prompts.toolCaller, tools: toolsText))
            if d.status == .blocked { return .blocked(d.message ?? "No suitable tool.") }
            if d.status == .stepDone || d.status == .taskDone {
                if let r = d.remember { notes.append(r) }
                return d.status == .taskDone ? .taskDone(d.message ?? "Done") : .done
            }
            guard d.action == "call_tool", let name = d.toolName else {
                history.append("- expected call_tool with tool_name")
                continue
            }
            let args = d.toolArguments ?? [:]
            let verdict = safety.assessTool(name: name, risk: max(d.risk, step.risk))
            if safety.needsApproval(verdict) {
                phase(.awaitingApproval, "Needs your approval")
                let req = ApprovalRequest(kind: .tool, title: "Run \(name)", detail: args.jsonString(pretty: true).prefix(600).description,
                                          appName: route == .composio ? "Composio" : "MCP", risk: verdict.risk, reasons: verdict.reasons)
                switch await callbacks.approve(req) {
                case .approve: break
                case .reject: return .blocked("You declined running \(name).")
                case .stop:
                    runtime.gate.stop()
                    throw AutomationError.stopped
                }
            }
            try runtime.gate.checkStopped()
            phase(.executing, "Running \(name)…")
            let t = Date()
            let (ok, output) = try await call(name, args)
            totalActions += 1
            await metrics.recordAction(deterministic: false)
            emit(ActivityEntry(kind: .tool, title: "\(ok ? "Ran" : "Failed") \(name)", detail: String(output.prefix(500)), route: route,
                               success: ok, durationMs: Date().timeIntervalSince(t) * 1000, stepID: step.id))
            if ok {
                notes.append("Result of \(name): \(output.prefix(4000))")
                return .done
            }
            history.append("- \(name) failed: \(output.prefix(300))")
        }
        return .failed(history.last ?? "Tool call failed.")
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
