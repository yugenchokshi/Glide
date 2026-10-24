import Foundation
import AppKit
import AutomationKit

/// Runs on-screen steps (routes gui and native): observe → deterministic hint → actor →
/// resolve → safety → act → verify, with OCR and then a vision model when a control isn't in
/// the accessibility tree. Step, action, error, repetition and no-effect limits end a step
/// that isn't making progress, so it never loops forever.
///
/// The quick-task orchestrator runs every GUI step of a task through one `TaskSession` (shared
/// notes, action budget, deadline, screenshot consent). The job engine uses the
/// `StepExecuting` entry point, which gives each step its own session.
///
/// Batching: the actor may return follow-up actions after the main one. They run in order
/// against a fresh observation of the same window; the batch stops at the first error,
/// declined or unresolved action, or as soon as the window changes, so the model looks again
/// whenever the screen isn't what it planned against.
public struct GUIStepRunner: StepExecuting {
    let settings: AppSettings
    let runtime: AutomationRuntime
    let router: ModelRouter
    let safety: SafetyPolicy

    public init(settings: AppSettings, runtime: AutomationRuntime = .shared, credentials: CredentialStore = .shared) {
        self.init(settings: settings, runtime: runtime, router: ModelRouter(settings: settings, credentials: credentials))
    }

    init(settings: AppSettings, runtime: AutomationRuntime, router: ModelRouter) {
        self.settings = settings
        self.runtime = runtime
        self.router = router
        self.safety = SafetyPolicy(settings: settings.safety)
    }

    /// Everything one step run needs besides the step: the task it belongs to, the shared task
    /// state and where to report.
    struct Run: Sendable {
        var instruction: String
        var plan: Plan
        var session: TaskSession
        var metrics: TaskMetrics
        /// `log` must persist entries (the orchestrator routes it to its history store).
        var callbacks: AgentCallbacks
        var workspace: (any JobWorkspace)? = nil
        var itemID: String? = nil
        var outputFields: [String] = []
        /// Model turns allowed for this step (the orchestrator relies on the action limits instead).
        var maxTurns: Int = .max
        /// Job steps never stop the shared input gate on their own decisions (an approval's
        /// Stop): stopping a job is the job runner's business, and it cancels the step.
        var isJob = false
        /// Job steps: pauses the step while the user is using the Mac (nil for quick tasks,
        /// which the orchestrator's own monitor pauses, or when the setting is off).
        var takeover: UserTakeoverWatch? = nil
    }

    struct Outcome: Sendable {
        var status: StepResult.Status
        var fields: [String: JSONValue] = [:]
        var actions = 0
        /// Facts the actor read from the screen during this step.
        var learned: [String] = []
    }

    // MARK: - StepExecuting

    public func execute(_ request: StepRequest, callbacks: AgentCallbacks) async throws -> StepResult {
        guard AccessibilityEngine.isTrusted else {
            return StepResult(status: .blocked(AutomationError.accessibilityNotTrusted.localizedDescription))
        }
        let metrics = TaskMetrics()
        let session = TaskSession(limits: settings.limits)
        if !request.context.isEmpty { session.appendNote(request.context) }
        let step = request.step.asPlanStep
        let takeover = UserTakeoverWatch.forStep(request, settings: settings)
        takeover?.start()
        defer { takeover?.stop() }
        let run = Run(instruction: request.goal, plan: Plan(goal: request.goal, steps: [step], clarification: nil), session: session,
                      metrics: metrics, callbacks: callbacks, workspace: request.workspace, itemID: request.itemID,
                      outputFields: request.step.outputFields, maxTurns: max(1, request.maxTurns), isJob: request.jobID != nil,
                      takeover: takeover)
        let outcome: Outcome
        do {
            if request.jobID != nil {
                // A job's on-screen step holds the screen lease, so it is the only one using the
                // shared gate. When the job is stopped or halted (its task cancelled), stop the
                // gate too, so input already being posted (a long text being typed) ends at
                // once, as it does for a quick task's Stop. Whoever takes the lease next resets it.
                let gate = runtime.gate
                outcome = try await withTaskCancellationHandler {
                    try await self.run(step, run)
                } onCancel: {
                    gate.stop()
                }
            } else {
                outcome = try await self.run(step, run)
            }
        } catch is CancellationError {
            throw AutomationError.stopped
        }
        let snapshot = await metrics.snapshot()
        var status = outcome.status
        var output = outcome.learned
        if case .taskDone(let message) = status {
            output.append(message)
            // "The whole task is done" only means something to a quick task; a job step is just done.
            if request.jobID != nil { status = .done }
        }
        return StepResult(status: status, output: output.joined(separator: "\n"), fields: outcome.fields, actions: outcome.actions,
                          modelCalls: snapshot.modelCalls + snapshot.jevCalls,
                          usage: LLMUsage(inputTokens: snapshot.inputTokens, outputTokens: snapshot.outputTokens))
    }

    // MARK: - The loop

    func run(_ step: PlanStep, _ r: Run) async throws -> Outcome {
        let selector = ActionSelector(router: router, metrics: r.metrics)
        let resolver = ActionResolver(jev: router.jevClient(), metrics: r.metrics)
        var history: [String] = []
        var hintTried = false
        var actionsInStep = 0
        var errors = 0
        var noEffectStreak = 0
        var rejections = 0
        var signatures: [String: Int] = [:]
        var turns = 0
        var learned: [String] = []
        var fieldsReminded = false
        let maxFollowUps = settings.tools.batchActions ? max(0, min(ActorSchema.maxFollowUps, settings.tools.maxBatch - 1)) : 0

        func outcome(_ status: StepResult.Status, fields: [String: JSONValue] = [:]) -> Outcome {
            Outcome(status: status, fields: fields, actions: actionsInStep, learned: learned)
        }

        // Bring the step's app forward first if it's already running (cheap, deterministic).
        // Switching apps takes focus from the user, so a job waits until they're idle first.
        try await waitForUser(step, r)
        if let appName = step.app, step.hint?.action != "launch_app",
           let running = runtime.executor.apps.runningApp(named: appName),
           running.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier {
            r.callbacks.phase(.executing, "Switching to \(running.localizedName ?? appName)…")
            if let info = try? await runtime.executor.apps.activate(running, timeout: 6) {
                r.session.currentApp = info
                r.callbacks.log(ActivityEntry(kind: .action, title: "Switched to \(info.name)", route: .native, success: true, stepID: step.id))
            }
        }

        while true {
            try await runtime.gate.checkpoint()
            try r.session.checkLimits(gate: runtime.gate)
            // Below, the screen is observed afresh, so after waiting for the user the step
            // carries on from whatever they left on screen.
            try await waitForUser(step, r)
            guard actionsInStep < settings.limits.maxActionsPerStep else {
                return outcome(.failed("Too many actions without finishing this step (\(actionsInStep))."))
            }
            var obs: ScreenObservation?
            do {
                obs = try await observeCurrent(session: r.session, metrics: r.metrics)
            } catch AutomationError.blockedBySafety(let m) {
                return outcome(.blocked(m))
            } catch AutomationError.accessibilityNotTrusted {
                return outcome(.blocked(AutomationError.accessibilityNotTrusted.localizedDescription))
            } catch {
                history.append("- observe failed: \(error.localizedDescription)")
            }
            if let a = obs?.app { r.session.currentApp = a }

            // 1. Deterministic hint (no model call).
            if !hintTried, let hint = step.hint {
                hintTried = true
                if let action = resolver.compileHint(hint, obs: obs) {
                    let target = Self.targetNode(action, obs: obs)
                    let result = try await perform(action, target: target, obs: obs, modelRisk: step.risk, step: step, expect: nil,
                                                   deterministic: true, history: &history, r)
                    if result.ran { actionsInStep += 1 }
                    switch result {
                    case .ok(let verification): noEffectStreak = verification == .passed ? 0 : noEffectStreak + 1
                    case .rejected: rejections += 1
                    case .blocked(let m): return outcome(.blocked(m))
                    case .error: errors += 1
                    case .skipped: hintTried = false // try the hint again on the fresh screen
                    }
                    // Native single-action steps (launch / open URL) finish when verified.
                    if step.route == .native, case .ok(.passed) = result, Self.isTerminalNative(action) { return outcome(.done) }
                    continue
                }
            }
            hintTried = true

            // 2. Ask the action selector.
            guard turns < r.maxTurns else {
                return outcome(.failed("Reached the limit of \(r.maxTurns) model turns for this step."))
            }
            turns += 1
            r.callbacks.phase(.executing, step.title + "…")
            var extra: String?
            if let app = obs?.app, let browser = BrowserAdapter.browser(forBundleID: app.bundleID), let page = runtime.perception.browser.currentPage(browser) {
                var text = "Browser page: \(page.title) — \(page.url)"
                if Self.wantsReading(step), let pageText = runtime.perception.browser.pageText(browser, maxChars: 8000), !pageText.isEmpty {
                    text += "\nPage text (from the DOM):\n\(pageText)"
                }
                extra = text
            }
            let decision: ActorDecision
            do {
                decision = try await selector.decide(.init(instruction: r.instruction, plan: r.plan, step: step, observation: obs,
                                                           history: history, notes: r.session.notesText, extraContext: extra, tools: nil,
                                                           outputFields: r.outputFields, maxFollowUps: maxFollowUps))
            } catch let e as LLMError {
                errors += 1
                history.append("- model error: \(e.localizedDescription)")
                if errors > settings.limits.retryLimit { return outcome(.failed(e.localizedDescription)) }
                continue
            }
            if let note = decision.remember, !note.isEmpty {
                r.session.appendNote(note)
                learned.append(note)
                if let workspace = r.workspace {
                    await workspace.setFact(workspaceNoteKey(stepID: step.id, itemID: r.itemID, index: learned.count - 1), note)
                }
                r.callbacks.log(ActivityEntry(kind: .info, title: "Noted information", detail: String(note.prefix(400)), stepID: step.id))
            }
            switch decision.status {
            case .stepDone:
                let missing = StepResult.missingFields(decision.resultFields, required: r.outputFields)
                if !missing.isEmpty && !fieldsReminded {
                    // One reminder; after that the step finishes with nulls rather than failing an item over a field.
                    fieldsReminded = true
                    history.append("- step_done needs result_fields_json with: \(missing.joined(separator: ", ")) (null for anything not found)")
                    continue
                }
                return outcome(.done, fields: StepResult.completeFields(decision.resultFields ?? [:], required: r.outputFields))
            case .taskDone:
                return outcome(.taskDone(decision.message ?? "Done"),
                               fields: StepResult.completeFields(decision.resultFields ?? [:], required: r.outputFields))
            case .blocked:
                return outcome(.blocked(decision.message ?? "I can't continue without your help."))
            case .needVision:
                let result = try await groundAndAct(description: decision.targetDescription ?? "the target", kind: decision.action ?? "click",
                                                    decision: decision, obs: obs, step: step, history: &history, r)
                if result.ran { actionsInStep += 1 }
                if case .blocked(let m) = result { return outcome(.blocked(m)) }
                if case .error = result { errors += 1 }
            case .act:
                let resolution = await resolver.resolve(decision, obs: obs, objective: step.instruction)
                switch resolution {
                case .action(let action, let target, _):
                    let sig = "\(action.humanDescription)|\(target?.fingerprint ?? "")"
                    signatures[sig, default: 0] += 1
                    if signatures[sig, default: 0] > 3 {
                        return outcome(.failed("Repeated “\(action.humanDescription)” without progress."))
                    }
                    let result = try await perform(action, target: target, obs: obs, modelRisk: decision.risk, step: step,
                                                   expect: decision.expect, deterministic: false, history: &history, r)
                    if result.ran { actionsInStep += 1 }
                    switch result {
                    case .ok(let verification): noEffectStreak = verification == .passed ? 0 : noEffectStreak + 1
                    case .rejected:
                        rejections += 1
                        if rejections >= 2 { return outcome(.blocked("You declined the proposed action. Tell me how you'd like to proceed.")) }
                    case .blocked(let m): return outcome(.blocked(m))
                    case .error: errors += 1
                    case .skipped: signatures[sig, default: 1] -= 1 // it never ran, so proposing it again isn't a repeat
                    }

                    // 3. Batched follow-ups, while the screen is still the one the model planned against.
                    guard case .ok = result, maxFollowUps > 0, !Self.isTerminalNative(action), let before = obs else { break }
                    var followUps = Array(decision.followUps.prefix(maxFollowUps))
                    if let first = followUps.first, ActorSchema.sameAction(first, decision), !Self.repeatsNaturally(first) {
                        followUps.removeFirst() // the model listed the main action twice; doing it again would type or click twice
                    }
                    batch: for followUp in followUps {
                        guard actionsInStep < settings.limits.maxActionsPerStep else { break }
                        try await runtime.gate.checkpoint()
                        try r.session.checkLimits(gate: runtime.gate)
                        let name = followUp.action ?? "action"
                        let fresh: ScreenObservation?
                        do {
                            fresh = try await observeCurrent(session: r.session, metrics: r.metrics)
                        } catch {
                            history.append("- stopped the batch before \(name): \(error.localizedDescription)")
                            break
                        }
                        guard let fresh, Self.sameScreen(before, fresh) else {
                            history.append("- stopped the batch before \(name): the window changed, look again")
                            break
                        }
                        guard case .action(let next, let nextTarget, _) = await resolver.resolve(followUp, obs: fresh, objective: step.instruction) else {
                            history.append("- stopped the batch: the target of \(name) isn't on screen now")
                            break
                        }
                        let nextSig = "\(next.humanDescription)|\(nextTarget?.fingerprint ?? "")"
                        signatures[nextSig, default: 0] += 1
                        if signatures[nextSig, default: 0] > 3 {
                            return outcome(.failed("Repeated “\(next.humanDescription)” without progress."))
                        }
                        let nextResult = try await perform(next, target: nextTarget, obs: fresh, modelRisk: followUp.risk, step: step,
                                                           expect: followUp.expect, deterministic: false, history: &history, r)
                        if nextResult.ran { actionsInStep += 1 }
                        switch nextResult {
                        case .ok(let verification):
                            noEffectStreak = verification == .passed ? 0 : noEffectStreak + 1
                            if followUp.expect != nil && verification != .passed {
                                history.append("- stopped the batch: the expected result of \(name) didn't appear")
                                break batch
                            }
                            if Self.isTerminalNative(next) { break batch }
                        case .rejected:
                            rejections += 1
                            if rejections >= 2 { return outcome(.blocked("You declined the proposed action. Tell me how you'd like to proceed.")) }
                            break batch
                        case .blocked(let m):
                            return outcome(.blocked(m))
                        case .error:
                            errors += 1
                            break batch
                        case .skipped:
                            signatures[nextSig, default: 1] -= 1
                            break batch
                        }
                    }
                case .needsGrounding(let description, let kind, let d):
                    let result = try await groundAndAct(description: description, kind: kind, decision: d, obs: obs, step: step, history: &history, r)
                    if result.ran { actionsInStep += 1 }
                    if case .blocked(let m) = result { return outcome(.blocked(m)) }
                    if case .error = result { errors += 1 }
                case .tool:
                    history.append("- call_tool isn't available in this step; use the UI.")
                    errors += 1
                case .invalid(let why):
                    history.append("- invalid action: \(why)")
                    errors += 1
                }
            }
            if errors > settings.limits.retryLimit + 1 {
                return outcome(.failed(history.last(where: { $0.contains("error") || $0.contains("failed") || $0.contains("invalid") }) ?? "Too many errors."))
            }
            if noEffectStreak >= 4 {
                return outcome(.failed("The last \(noEffectStreak) actions had no visible effect."))
            }
        }
    }

    // MARK: - Observation

    /// The app to observe: the frontmost app unless it's Glide itself, else the last app acted in.
    func observeCurrent(session: TaskSession, metrics: TaskMetrics, forceOCR: Bool = false) async throws -> ScreenObservation? {
        guard let app = runtime.accessibility.frontmostApp() ?? session.currentApp else { return nil }
        if safety.isExcluded(app: app) { throw AutomationError.blockedBySafety("Glide is set not to read or operate \(app.name).") }
        let t = Date()
        let obs = try await runtime.perception.observe(app, forceOCR: forceOCR)
        await metrics.recordObservation(ms: Date().timeIntervalSince(t) * 1000)
        return obs
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

    /// Key presses and scrolls are often meant to repeat (Tab, Down, scroll again), so an
    /// identical follow-up of those is kept.
    static func repeatsNaturally(_ d: ActorDecision) -> Bool {
        d.action == "key" || d.action == "scroll"
    }

    /// Follow-ups only run while the same window of the same app is in front.
    static func sameScreen(_ a: ScreenObservation, _ b: ScreenObservation) -> Bool {
        a.app.pid == b.app.pid && a.windowTitle == b.windowTitle
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

    // MARK: - Acting

    enum PerformResult {
        /// The action ran; how verification judged it.
        case ok(VerificationResult.Status)
        case rejected
        case blocked(String)
        case error
        /// Not run: the user started using the Mac during a job step. The loop waits for them
        /// and looks at the screen again.
        case skipped

        /// Whether it counts as an action taken.
        var ran: Bool {
            if case .skipped = self { return false }
            return true
        }
    }

    /// Job steps: while the user is using the Mac, waits in place (holding the screen) until
    /// they've been idle long enough, and says so in the job's log. The wait doesn't count
    /// toward the step's time limit.
    private func waitForUser(_ step: PlanStep, _ r: Run) async throws {
        guard let watch = r.takeover else { return }
        let idle = Int(watch.waitSeconds.rounded())
        let waited = try await watch.waitWhileUserActive(gate: runtime.gate) {
            r.callbacks.log(ActivityEntry(kind: .info, title: "Paused because you used the mouse",
                                          detail: "This step continues by itself once you've been idle for \(idle) seconds.", stepID: step.id))
        }
        guard let waited else { return }
        r.session.extendDeadline(by: waited)
        r.callbacks.log(ActivityEntry(kind: .info, title: "Continuing after you've been idle", stepID: step.id))
    }

    /// Safety check → approval → execute → verify → record.
    private func perform(_ action: ComputerAction, target: UIElementNode?, obs: ScreenObservation?, modelRisk: RiskLevel, step: PlanStep,
                         expect: String?, deterministic: Bool, history: inout [String], _ r: Run) async throws -> PerformResult {
        let app = obs?.app ?? runtime.accessibility.frontmostApp() ?? r.session.currentApp
        let verdict = safety.assess(action, target: target, app: app, modelRisk: modelRisk, stepRisk: step.risk)
        if let blocked = verdict.blocked {
            r.callbacks.log(ActivityEntry(kind: .approval, title: "Blocked: \(action.humanDescription)", detail: blocked, success: false, stepID: step.id))
            return .blocked(blocked)
        }
        let label = target.map { " “\($0.label.prefix(40))”" } ?? ""
        if safety.needsApproval(verdict) {
            r.callbacks.phase(.awaitingApproval, "Needs your approval")
            let req = ApprovalRequest(kind: .action, title: action.humanDescription + label,
                                      detail: step.instruction, appName: app?.name, risk: verdict.risk, reasons: verdict.reasons)
            switch await r.callbacks.approve(req) {
            case .approve:
                // Answering moved the mouse; that's consent to this action, not a takeover.
                r.takeover?.clear()
                r.callbacks.log(ActivityEntry(kind: .approval, title: "You approved: \(action.humanDescription)\(label)", success: true, stepID: step.id))
                r.callbacks.phase(.executing, step.title + "…")
            case .reject:
                r.callbacks.log(ActivityEntry(kind: .approval, title: "You declined: \(action.humanDescription)\(label)", success: false, stepID: step.id))
                history.append("- \(action.humanDescription)\(label) → the user DECLINED this action; do not retry it")
                r.callbacks.phase(.executing, step.title + "…")
                return .rejected
            case .stop:
                if !r.isJob { runtime.gate.stop() }
                throw AutomationError.stopped
            }
        }
        if let watch = r.takeover, watch.userTookOver {
            // The user came back after the screen was read (often during the model call): don't
            // act on their screen; the loop waits for them and looks again.
            history.append("- \(action.humanDescription)\(label) → not done: the user was using the Mac; look at the screen again")
            return .skipped
        }
        r.callbacks.phase(.executing, action.humanDescription + label)
        try r.session.checkLimits(gate: runtime.gate)
        do {
            let outcome = try await runtime.executor.execute(action, observation: obs)
            r.session.addActions()
            await r.metrics.recordAction(deterministic: deterministic)
            if let a = outcome.app { r.session.currentApp = a }
            let expectation: Expectation = expect.map { .elementAppears($0) } ?? outcome.expectation
            let verifyApp = outcome.app ?? app
            var result = await runtime.verification.verify(expectation, app: verifyApp, before: obs, sinceGeneration: outcome.generationBefore,
                                                           timeout: Self.isTerminalNative(action) ? 4 : 2)
            // If a specific expected element didn't appear, still accept a visible change.
            if result.status == .failed, let expect {
                let fallback = await runtime.verification.verify(.uiChanged, app: verifyApp, before: obs, sinceGeneration: outcome.generationBefore, timeout: 0.3)
                if fallback.passed { result = VerificationResult(status: .unconfirmed, detail: "changed, but “\(expect)” not seen", durationMs: result.durationMs) }
            }
            r.callbacks.log(ActivityEntry(kind: .action, title: action.humanDescription + label,
                                          detail: "\(outcome.method) · \(result.detail)",
                                          route: Self.isTerminalNative(action) ? .native : .gui, success: result.status != .failed,
                                          durationMs: outcome.durationMs + result.durationMs, stepID: step.id))
            history.append("- \(action.humanDescription)\(label) via \(outcome.method) → \(result.status.rawValue): \(result.detail)")
            return .ok(result.status)
        } catch AutomationError.stopped {
            throw AutomationError.stopped
        } catch is CancellationError {
            throw AutomationError.stopped
        } catch AutomationError.blockedBySafety(let m) {
            return .blocked(m)
        } catch {
            r.callbacks.log(ActivityEntry(kind: .error, title: action.humanDescription + label, detail: error.localizedDescription, success: false, stepID: step.id))
            history.append("- \(action.humanDescription)\(label) → error: \(error.localizedDescription)")
            return .error
        }
    }

    /// Finds a target visually (OCR, then a vision model) and performs the action at the
    /// validated point.
    private func groundAndAct(description: String, kind: String, decision: ActorDecision?, obs: ScreenObservation?, step: PlanStep,
                              history: inout [String], _ r: Run) async throws -> PerformResult {
        guard let obs else {
            history.append("- no window to search for \(description)")
            return .error
        }
        guard ScreenCapture.hasPermission else {
            history.append("- can't look for “\(description)” visually: Screen Recording permission isn't granted")
            r.callbacks.log(ActivityEntry(kind: .vision, title: "Screen Recording permission needed to find “\(description)”", success: false, stepID: step.id))
            return .error
        }
        let grounding = VisionGrounding(perception: runtime.perception)
        r.callbacks.phase(.executing, "Looking for “\(description.prefix(40))”…")
        var hit: VisionGrounding.Hit?
        if let h = try? await grounding.groundWithOCR(description, obs: obs) { hit = h }
        if hit == nil {
            switch settings.safety.screenshotConsent {
            case .never:
                history.append("- “\(description)” isn't in the accessibility tree and screenshots are disabled in Settings")
                return .error
            case .ask where !r.session.screenshotConsentGiven:
                r.callbacks.phase(.awaitingApproval, "Allow a screenshot?")
                let req = ApprovalRequest(kind: .screenshot, title: "Send a screenshot of \(obs.app.name) to the vision model?",
                                          detail: "“\(description)” isn't exposed to accessibility. A redacted capture of this window (password fields blacked out) will be sent to your configured vision provider.",
                                          appName: obs.app.name, risk: .medium, reasons: ["screenshot leaves your Mac"])
                switch await r.callbacks.approve(req) {
                case .approve:
                    r.session.screenshotConsentGiven = true
                    r.takeover?.clear()
                case .reject:
                    history.append("- the user declined sending a screenshot; find another way")
                    return .rejected
                case .stop:
                    if !r.isJob { runtime.gate.stop() }
                    throw AutomationError.stopped
                }
            default: break
            }
            do {
                let route = try router.route(.vision)
                hit = try await grounding.groundWithModel(description, context: step.instruction, obs: obs, route: route, metrics: r.metrics)
            } catch {
                history.append("- vision grounding failed: \(error.localizedDescription)")
                return .error
            }
        }
        guard let hit else {
            history.append("- couldn't find “\(description)” on screen, even visually")
            r.callbacks.log(ActivityEntry(kind: .vision, title: "Couldn't find “\(description)”", success: false, stepID: step.id))
            return .error
        }
        r.callbacks.log(ActivityEntry(kind: .vision, title: "Found “\(description)” via \(hit.source.rawValue)", detail: hit.description, success: true, stepID: step.id))
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
                                 expect: decision?.expect, deterministic: false, history: &history, r)
    }
}

// MARK: - The user taking over during a job step

/// The user-input monitor a job's on-screen step runs; a protocol so tests can drive it.
protocol UserInputMonitoring: AnyObject, Sendable {
    func start(onUserInput: @escaping @Sendable () -> Void)
    func stop()
}

extension UserInterferenceMonitor: UserInputMonitoring {}

/// Pauses a background job's on-screen step while the user is using the Mac
/// (`SafetySettings.pauseOnUserInput`). A quick task pauses until the user presses Resume; a
/// job has nobody to press it, so its step waits in place, still holding the screen, until the
/// user has been idle for the jobs' idle threshold (`JobSettings.idleSeconds`), then looks at
/// the screen again and carries on. The item isn't failed for it.
///
/// Any real mouse input during the step counts (Glide's own events carry its tag and are
/// ignored), not only input that collides with the agent's as for quick tasks: a job uses the
/// screen because the user is away, so input means they're back. Each step gets its own
/// monitor, so it never touches the quick task's (`AutomationRuntime.interference`).
final class UserTakeoverWatch: @unchecked Sendable {
    /// Shortest wait, so an idle setting of 0 doesn't resume while the user is mid-gesture.
    static let minimumIdleSeconds: Double = 3

    private let lock = NSLock()
    private var tookOver = false
    private let monitor: any UserInputMonitoring
    private let idleProbe: ScreenLease.IdleProbe
    private let pollInterval: Double
    /// How long the user must leave the Mac alone before the step continues.
    let waitSeconds: Double

    init(monitor: any UserInputMonitoring = UserInterferenceMonitor(), idleSeconds: Double,
         idleProbe: @escaping ScreenLease.IdleProbe = ScreenLease.systemIdleSeconds, pollInterval: Double = 0.5) {
        self.monitor = monitor
        self.waitSeconds = max(idleSeconds, Self.minimumIdleSeconds)
        self.idleProbe = idleProbe
        self.pollInterval = max(0.01, pollInterval)
    }

    /// The watch for one step, or nil: quick tasks are watched by the orchestrator, and the
    /// user may have turned the setting off.
    static func forStep(_ request: StepRequest, settings: AppSettings) -> UserTakeoverWatch? {
        guard request.jobID != nil, settings.safety.pauseOnUserInput else { return nil }
        return UserTakeoverWatch(idleSeconds: settings.jobs.idleSeconds)
    }

    func start() { monitor.start { [weak self] in self?.noteUserInput() } }
    func stop() { monitor.stop() }

    func noteUserInput() { lock.withLock { tookOver = true } }
    var userTookOver: Bool { lock.withLock { tookOver } }
    /// Forgets input so far (answering an approval moves the mouse too).
    func clear() { lock.withLock { tookOver = false } }

    /// If the user took over since the last wait, calls `onPause`, waits until they've been
    /// idle for `waitSeconds` and returns how long that took; returns nil at once otherwise.
    /// Cancellation and a stopped `gate` end the wait with `AutomationError.stopped`.
    func waitWhileUserActive(gate: ExecutionGate?, onPause: () -> Void) async throws -> TimeInterval? {
        guard userTookOver else { return nil }
        onPause()
        let start = Date()
        while true {
            if Task.isCancelled || gate?.isStopped == true { throw AutomationError.stopped }
            if idleProbe() >= waitSeconds { break }
            do {
                try await Task.sleep(for: .seconds(pollInterval))
            } catch {
                throw AutomationError.stopped
            }
        }
        clear()
        return Date().timeIntervalSince(start)
    }
}
