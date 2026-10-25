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
    /// The lease a job's step gives up while it waits for the user (the job runner's).
    let screenLease: ScreenLease

    public init(settings: AppSettings, runtime: AutomationRuntime = .shared, credentials: CredentialStore = .shared) {
        self.init(settings: settings, runtime: runtime, router: ModelRouter(settings: settings, credentials: credentials))
    }

    init(settings: AppSettings, runtime: AutomationRuntime, router: ModelRouter, screenLease: ScreenLease = .shared) {
        self.settings = settings
        self.runtime = runtime
        self.router = router
        self.safety = SafetyPolicy(settings: settings.safety)
        self.screenLease = screenLease
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
        /// Job steps: waits while the user is using the Mac (nil for quick tasks, which the
        /// orchestrator's own monitor pauses, or when the setting is off).
        var takeover: UserTakeoverWatch? = nil
        /// Quick tasks: the task's conversation. What the user says meanwhile reaches the actor
        /// at its next turn, and a step that would end blocked on a decision asks it instead.
        var conversation: TaskConversation? = nil
    }

    /// Decisions one step may ask the user about instead of ending blocked.
    static let maxBlockedQuestions = 2

    struct Outcome: Sendable {
        var status: StepResult.Status
        var fields: [String: JSONValue] = [:]
        var actions = 0
        /// Facts the actor read from the screen during this step.
        var learned: [String] = []
        /// With `taskDone`: the result to say out loud.
        var spoken: String? = nil
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
        let takeover = UserTakeoverWatch.forStep(request, settings: settings, runtime: runtime, lease: screenLease)
        takeover?.start()
        takeover?.noteRecentUserInput()
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
                // Not while the step has given the screen up to wait for the user: the gate is
                // the quick task's then.
                let gate = runtime.gate
                outcome = try await withTaskCancellationHandler {
                    try await self.run(step, run)
                } onCancel: {
                    if takeover?.screenHandedOver != true { gate.stop() }
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
                          usage: LLMUsage(inputTokens: snapshot.inputTokens, outputTokens: snapshot.outputTokens),
                          sideEffects: session.sideEffects)
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
        var questionsAsked = 0
        let maxFollowUps = settings.tools.batchActions ? max(0, min(ActorSchema.maxFollowUps, settings.tools.maxBatch - 1)) : 0

        func outcome(_ status: StepResult.Status, fields: [String: JSONValue] = [:]) -> Outcome {
            Outcome(status: status, fields: fields, actions: actionsInStep, learned: learned)
        }

        // Bring the step's app forward first if it's already running (cheap, deterministic).
        // Switching apps takes focus from the user, so a job waits until they're idle first.
        _ = try await waitForUser(step, r)
        await bringAppForward(step, r)

        while true {
            try await runtime.gate.checkpoint()
            try r.session.checkLimits(gate: runtime.gate)
            // After waiting for the user the step's app comes forward again and the loop starts
            // over, so the screen is observed afresh and the step carries on from whatever they
            // left on screen.
            if try await waitForUser(step, r) {
                await bringAppForward(step, r)
                continue
            }
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
            if let conversation = r.conversation {
                // What the user said since the last turn ("actually the blue ones").
                for note in conversation.takeNotes() {
                    history.append("- the user said: \(note)")
                    r.session.appendNote("From the user: \(note)")
                }
            }
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
                var done = outcome(.taskDone(decision.message ?? "Done"),
                                   fields: StepResult.completeFields(decision.resultFields ?? [:], required: r.outputFields))
                done.spoken = decision.spoken
                return done
            case .blocked:
                let message = decision.message ?? "I can't continue without your help."
                // A decision only the user can make becomes a question this step waits for; a
                // login, a CAPTCHA or a permission still ends the step for the user to handle.
                if let conversation = r.conversation, !r.isJob, questionsAsked < Self.maxBlockedQuestions,
                   !UtteranceInterpreter.needsPerson(message) {
                    questionsAsked += 1
                    r.callbacks.log(ActivityEntry(kind: .info, title: "Asked: \(message)", stepID: step.id))
                    r.callbacks.phase(.executing, "Waiting for your answer…")
                    let start = Date()
                    let answer = await conversation.ask(AgentQuestion(text: message), wait: true)
                    r.session.extendDeadline(by: Date().timeIntervalSince(start))
                    if Task.isCancelled || runtime.gate.isStopped || (answer == nil && conversation.isClosed) { throw AutomationError.stopped }
                    if let answer {
                        history.append("- you asked the user “\(message)”; they answered: \(answer)")
                        r.session.appendNote("The user answered “\(message)”: \(answer)")
                        continue
                    }
                }
                return outcome(.blocked(message))
            case .needVision:
                let result = try await groundAndAct(description: decision.targetDescription ?? "the target", kind: decision.action ?? "click",
                                                    decision: decision, obs: obs, step: step, history: &history, r)
                if result.ran { actionsInStep += 1 }
                if case .blocked(let m) = result { return outcome(.blocked(m)) }
                if case .error = result { errors += 1 }
                if case .skipped = result { turns -= 1 } // the user took over; this turn's action never ran
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
                    case .skipped:
                        // The user took over before it ran: proposing it again isn't a repeat, and
                        // the turn doesn't count toward the step's limit.
                        signatures[sig, default: 1] -= 1
                        turns -= 1
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
                    if case .skipped = result { turns -= 1 }
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

    /// ⌘ shortcuts that only look or move around (copy, select all, find, address bar, tabs).
    static let lookingShortcuts: Set<String> = ["c", "a", "f", "g", "l", "t", "w", "tab", "[", "]", "`", "left", "right", "up", "down"]

    /// One line for an action that may have changed something (`TaskSession.sideEffects`); nil
    /// for looking around: scrolling, focusing, selecting, switching apps, waiting, and keys
    /// other than Return or a ⌘ shortcut that does something.
    static func sideEffect(_ action: ComputerAction, label: String?, app: String?) -> String? {
        let target = label.flatMap { $0.isEmpty ? nil : "“\(ToolStepRunner.clip($0, 60))”" }
        let place = app.map { " in \($0)" } ?? ""
        switch action {
        case .click, .doubleClick:
            return "Clicked \(target ?? "the screen")\(place)"
        case .typeText(let text, _, _, let submit):
            return "Typed “\(ToolStepRunner.clip(text, 80))”" + (target.map { " into \($0)" } ?? "") + place + (submit ? " and pressed Return" : "")
        case .setValue(_, let value):
            return "Set \(target ?? "a field") to “\(ToolStepRunner.clip(value, 80))”\(place)"
        case .keyPress(let keys):
            let key = keys.key.lowercased()
            let submits = ["return", "enter", "keypadenter"].contains(key)
            guard submits || (keys.modifiers.contains(.command) && !lookingShortcuts.contains(key)) else { return nil }
            return "Pressed \(keys.displayString)\(place)"
        case .menu(let path):
            return "Chose \(path.joined(separator: " › "))\(place)"
        case .openURL(let url, _):
            return "Opened \(ToolStepRunner.clip(url, 200))"
        case .drag:
            return "Dragged \(target ?? "an item")\(place)"
        case .rightClick, .scroll, .focus, .selectText, .launchApp, .activateApp, .waitFor:
            return nil
        }
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

    /// Job steps: once the user has started using the Mac, waits until they leave it alone
    /// (giving the screen to a quick task meanwhile) and says so in the job's log. Returns
    /// whether it waited. The wait doesn't count toward the step's time limit, and is reported
    /// through `waitingForUser` so the job's time budget can leave it out too. Pausing or
    /// stopping the job ends the wait (`AutomationError.stopped`) without taking the screen back.
    func waitForUser(_ step: PlanStep, _ r: Run) async throws -> Bool {
        guard let watch = r.takeover, watch.userTookOver else { return false }
        r.callbacks.log(ActivityEntry(kind: .info, title: "Paused because you used the mouse", detail: watch.pauseDetail, stepID: step.id))
        await r.callbacks.waitingForUser(true)
        let waited: TimeInterval
        do {
            waited = try await watch.waitForIdleUser(gate: runtime.gate, interrupted: r.callbacks.jobInterrupted)
        } catch {
            await r.callbacks.waitingForUser(false)
            throw error
        }
        await r.callbacks.waitingForUser(false)
        r.session.extendDeadline(by: waited)
        r.callbacks.log(ActivityEntry(kind: .info, title: "Continuing after you've been idle", stepID: step.id))
        return true
    }

    /// Brings the step's app to the front if it's running and isn't already.
    private func bringAppForward(_ step: PlanStep, _ r: Run) async {
        guard let appName = step.app, step.hint?.action != "launch_app",
              let running = runtime.executor.apps.runningApp(named: appName),
              running.processIdentifier != NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        r.callbacks.phase(.executing, "Switching to \(running.localizedName ?? appName)…")
        if let info = try? await runtime.executor.apps.activate(running, timeout: 6) {
            r.session.currentApp = info
            r.callbacks.log(ActivityEntry(kind: .action, title: "Switched to \(info.name)", route: .native, success: true, stepID: step.id))
        }
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
            if let effect = Self.sideEffect(action, label: target?.label, app: app?.name) { r.session.recordSideEffect(effect) }
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

/// Holds a background job's on-screen step while the user is using the Mac
/// (`SafetySettings.pauseOnUserInput`). A quick task pauses until the user presses Resume; a
/// job has nobody to press it, so its step waits until the user leaves the Mac alone, then
/// looks at the screen again and carries on. The item isn't failed for it.
///
/// What counts follows `JobSettings.screenUse`. With "only when I'm idle" a job uses the screen
/// because the user is away, so any real mouse input means they're back, and the step waits
/// until they've been idle for `JobSettings.idleSeconds`. With "any time" the user is often at
/// the Mac, so, as for quick tasks, only input that collides with the agent's own counts, and
/// the step waits a few seconds for them to let go. Glide's own events carry its tag and are
/// ignored either way.
///
/// While it waits, the step gives the screen lease up, so a quick task started meanwhile runs
/// at once, and takes it back (behind that task) before carrying on. The monitor is
/// `AutomationRuntime.jobInterference`, never the quick task's, and runs only while the step
/// holds the screen, so job steps never share it.
///
/// Idle time is measured the way the lease measures it (Glide's own input left out), so
/// another job using the screen meanwhile doesn't count as the user being busy. Pausing or
/// stopping the step's job ends the wait, and the screen isn't taken back.
final class UserTakeoverWatch: @unchecked Sendable {
    enum Mode: Sendable, Equatable {
        /// Any real mouse input counts (`ScreenUse.whenIdle`).
        case anyInput
        /// Only input within `collisionWindow` of the agent's own (`ScreenUse.always`).
        case collisions
    }

    /// Shortest wait, so an idle setting of 0 (or "any time") doesn't resume while the user is
    /// mid-gesture.
    static let minimumIdleSeconds: Double = 3
    /// The quick task's rule: user input this soon after the agent's own collides with it.
    static let collisionWindow: Double = 2.5

    private let lock = NSLock()
    private var tookOver = false
    private var watching = false
    private var handedOver = false
    /// When the monitor last saw the user's input.
    private var lastUserInput: Date?
    private let monitor: any UserInputMonitoring
    private let idleProbe: ScreenLease.IdleProbe
    /// The idle time the waits go by, when it isn't `idleProbe` (production: the lease's,
    /// which leaves Glide's own input out).
    private let userIdle: (@Sendable () async -> Double)?
    private let lastAgentInput: @Sendable () -> Date
    private let lease: ScreenLease?
    private let leaseOwner: String?
    private let pollInterval: Double
    let mode: Mode
    /// How long the user must leave the Mac alone before the step continues.
    let waitSeconds: Double

    /// - Parameters:
    ///   - idleProbe: seconds since the last input, the user's or Glide's (the step's start
    ///     tells them apart with `lastAgentInput`).
    ///   - userIdle: seconds the user has left the Mac alone, which the waits go by; nil to
    ///     use `idleProbe`.
    ///   - lastAgentInput: when the agent last posted input, to tell the user's input from it.
    ///   - lease, leaseOwner: the screen lease the step's job holds, given up while waiting.
    init(monitor: any UserInputMonitoring, mode: Mode = .anyInput, idleSeconds: Double,
         idleProbe: @escaping ScreenLease.IdleProbe = ScreenLease.systemIdleSeconds,
         userIdle: (@Sendable () async -> Double)? = nil,
         lastAgentInput: @escaping @Sendable () -> Date = { .distantPast },
         lease: ScreenLease? = nil, leaseOwner: String? = nil, pollInterval: Double = 0.5) {
        self.monitor = monitor
        self.mode = mode
        self.waitSeconds = max(idleSeconds, Self.minimumIdleSeconds)
        self.idleProbe = idleProbe
        self.userIdle = userIdle
        self.lastAgentInput = lastAgentInput
        self.lease = lease
        self.leaseOwner = leaseOwner
        self.pollInterval = max(0.01, pollInterval)
    }

    /// The watch for one step, or nil: quick tasks are watched by the orchestrator, and the
    /// user may have turned the setting off.
    static func forStep(_ request: StepRequest, settings: AppSettings, runtime: AutomationRuntime, lease: ScreenLease) -> UserTakeoverWatch? {
        guard let jobID = request.jobID, settings.safety.pauseOnUserInput else { return nil }
        let owner = leaseOwner(jobID: jobID)
        let input = runtime.executor.input
        // The same idle time the lease grants the screen by, so this step and the job it may be
        // waiting behind agree on whether the user is away.
        let userIdle: @Sendable () async -> Double = { await lease.userIdleTime() }
        if settings.jobs.screenUse == .always {
            return UserTakeoverWatch(monitor: runtime.jobInterference, mode: .collisions, idleSeconds: minimumIdleSeconds, userIdle: userIdle,
                                     lastAgentInput: { input.lastPost }, lease: lease, leaseOwner: owner)
        }
        return UserTakeoverWatch(monitor: runtime.jobInterference, idleSeconds: settings.jobs.idleSeconds, userIdle: userIdle,
                                 lastAgentInput: { input.lastPost }, lease: lease, leaseOwner: owner)
    }

    /// The name a job holds the screen lease under; it must match `JobRunner.leaseOwner`. If it
    /// ever doesn't, the step finds it isn't the holder and waits keeping the screen.
    static func leaseOwner(jobID: String) -> String { "job:\(jobID)" }

    /// What the job's log says while the step waits.
    var pauseDetail: String {
        switch mode {
        case .anyInput: return "It continues by itself once you've been idle for \(Int(waitSeconds.rounded())) seconds."
        case .collisions: return "It continues by itself once you've left the mouse alone for a few seconds."
        }
    }

    func start() {
        lock.withLock { watching = true }
        monitor.start { [weak self] in self?.noteUserInput() }
    }

    /// Stops the monitor if this watch is running it. Once a waiting step has given the screen
    /// up it has stopped it already, and must not stop it again: the next holder's step may be
    /// using it.
    func stop() {
        let wasWatching = lock.withLock { () -> Bool in
            defer { watching = false }
            return watching
        }
        if wasWatching { monitor.stop() }
    }

    func noteUserInput() {
        let now = Date()
        lock.withLock { lastUserInput = now }
        if mode == .collisions, now.timeIntervalSince(lastAgentInput()) >= Self.collisionWindow { return }
        lock.withLock { tookOver = true }
    }

    /// Called as the step starts. The lease can be granted while the user is at the Mac: it
    /// takes any input during a hold for Glide's own, so when a waiting step gives the screen
    /// up while the user is busy, another job may get it. With "only when I'm idle", input
    /// newer than Glide's last event and within the idle time is the user's, so the step waits
    /// before it touches anything.
    func noteRecentUserInput() {
        guard mode == .anyInput else { return }
        let idle = idleProbe()
        guard idle < waitSeconds else { return }
        let lastEvent = Date().addingTimeInterval(-idle)
        if lastEvent > lastAgentInput().addingTimeInterval(0.5) { lock.withLock { tookOver = true } }
    }

    var userTookOver: Bool { lock.withLock { tookOver } }
    /// Forgets input so far (answering an approval moves the mouse too).
    func clear() { lock.withLock { tookOver = false } }
    /// True while the step has given the screen up to wait for the user: the shared input gate
    /// belongs to whoever holds the screen then.
    var screenHandedOver: Bool { lock.withLock { handedOver } }

    /// Waits until the user has left the Mac alone for `waitSeconds` and returns how long that
    /// took. Meanwhile the screen lease is given up (when this step's job holds it) and taken
    /// back before returning, and the shared input gate is then cleared of any Stop or pause the
    /// other task left on it. Cancellation ends the wait with `AutomationError.stopped`; so does
    /// a stopped `gate`, but only while the step keeps the screen (given up, it's another's).
    /// `interrupted` (the step's job was paused or stopped) ends it too, without taking the
    /// screen back: the job's runner then ends the run as paused.
    func waitForIdleUser(gate: ExecutionGate?, interrupted: @escaping @Sendable () -> Bool = { false }) async throws -> TimeInterval {
        let began = Date()
        let wasWatching = lock.withLock { watching }
        stop()
        // One of Glide's own events right after the user's input can hide it from the lease.
        if let lease, let seen = lock.withLock({ lastUserInput }) { await lease.noteUserInput(at: seen) }
        let gaveUp = await giveUpScreen()
        do {
            try await waitUntilIdle(gate: gaveUp ? nil : gate, interrupted: interrupted)
            if gaveUp { try await takeScreenBack(interrupted: interrupted) }
        } catch {
            throw AutomationError.stopped
        }
        if gaveUp, let gate, gate.current != .running { gate.reset() }
        clear()
        if wasWatching { start() }
        return Date().timeIntervalSince(began)
    }

    private func waitUntilIdle(gate: ExecutionGate?, interrupted: @Sendable () -> Bool) async throws {
        while await idleNow() < waitSeconds {
            if Task.isCancelled || gate?.isStopped == true || interrupted() { throw AutomationError.stopped }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        if Task.isCancelled || interrupted() { throw AutomationError.stopped }
    }

    /// The idle time the waits go by.
    func idleNow() async -> Double {
        if let userIdle { return await userIdle() }
        return idleProbe()
    }

    /// Releases the screen lease if this step's job holds it.
    private func giveUpScreen() async -> Bool {
        guard let lease, let leaseOwner, await lease.currentHolder == leaseOwner else { return false }
        lock.withLock { handedOver = true }
        await lease.release(owner: leaseOwner)
        return true
    }

    /// Queues for the screen again, behind a quick task that took it. The user's input since
    /// (starting or watching that task) may mean they haven't been idle long enough after all;
    /// then the screen goes back and the wait goes on. A pause or stop of the job ends the
    /// queueing as well, since the quick task ahead may take a while. A throw leaves the lease
    /// released.
    private func takeScreenBack(interrupted: @escaping @Sendable () -> Bool) async throws {
        guard let lease, let leaseOwner else { return }
        do {
            while true {
                guard try await acquire(lease, owner: leaseOwner, unless: interrupted), !Task.isCancelled, !interrupted() else {
                    throw AutomationError.stopped
                }
                if await idleNow() >= waitSeconds { break }
                await lease.release(owner: leaseOwner)
                try await waitUntilIdle(gate: nil, interrupted: interrupted)
            }
        } catch {
            await lease.release(owner: leaseOwner)
            throw error
        }
        lock.withLock { handedOver = false }
    }

    /// Waits for the lease, or gives up (false) once `interrupted`. Never leaves the lease held
    /// when it gives up: it may have been granted just as the pause was seen.
    private func acquire(_ lease: ScreenLease, owner: String, unless interrupted: @escaping @Sendable () -> Bool) async throws -> Bool {
        let poll = pollInterval
        let granted = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await lease.acquire(owner: owner)
                return true
            }
            group.addTask {
                while !interrupted() { try await Task.sleep(for: .seconds(poll)) }
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !granted { await lease.release(owner: owner) }
        return granted
    }
}
