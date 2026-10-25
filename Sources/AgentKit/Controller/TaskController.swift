import Foundation
import Observation
import AutomationKit

/// UI-facing state machine for the current task. The notch and menu bar observe this; the
/// automation itself runs off the main actor in `ExecutionOrchestrator`.
///
/// It is also the conversation layer (see Conversation.swift): everything the user says or
/// types arrives at `handleUtterance`, which decides whether it stops, pauses or resumes the
/// task, answers the open question, steers the running task, or starts something new (instant
/// actions first, then the planner). Everything Glide wants said leaves through `onSpeech`.
@MainActor
@Observable
public final class TaskController {
    public static let shared = TaskController()

    public private(set) var phase: AgentPhase = .idle
    public private(set) var status = ""
    public private(set) var instruction = ""
    public private(set) var plan: Plan?
    public private(set) var currentStepIndex = 0
    public private(set) var activity: [ActivityEntry] = []
    public private(set) var pendingApproval: ApprovalRequest?
    public private(set) var lastResult: TaskResult?
    public private(set) var lastTaskID: String?
    public private(set) var startedAt: Date?

    public var isRunning: Bool { [.planning, .executing, .awaitingApproval, .paused].contains(phase) }

    /// Called when a task needs attention (approval, completion, error) so the UI can expand.
    public var onAttentionNeeded: (() -> Void)?
    /// Called when a task finishes (any outcome).
    public var onFinished: ((TaskResult) -> Void)?

    let runtime: AutomationRuntime
    let settingsStore: SettingsStore
    /// Receives requests the planner marks as long-running jobs. Resolved only when a job is
    /// handed off (nil = `JobCenter.shared`), so creating a controller doesn't start the job engine.
    private let jobCenterOverride: JobCenter?
    private var jobCenter: JobCenter { jobCenterOverride ?? .shared }
    private let screenLease: ScreenLease
    private var task: Task<Void, Never>?
    private var runTask: Task<TaskResult, Never>?
    private var orchestrator: ExecutionOrchestrator?
    private var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    private var runID = 0
    /// True while this run holds the screen lease. Until then the shared input gate belongs to
    /// whoever does hold it — possibly a background job's on-screen step — so Stop and Pause
    /// must leave the gate alone and only act on this run.
    private var holdsLease = false
    /// Pause pressed before the lease was granted; applied to the gate once this run holds it.
    private var pendingPause = false
    /// What the notch showed before a pause pressed while waiting for the lease.
    private var statusBeforePause = ""

    static let waitingForScreenStatus = "Waiting for a background job to finish its on-screen step…"

    private let credentials: CredentialStore

    public init(runtime: AutomationRuntime = .shared, settingsStore: SettingsStore = .shared, jobCenter: JobCenter? = nil,
                screenLease: ScreenLease = .shared, credentials: CredentialStore = .shared) {
        self.runtime = runtime
        self.settingsStore = settingsStore
        self.jobCenterOverride = jobCenter
        self.screenLease = screenLease
        self.credentials = credentials
        let (stream, continuation) = AsyncStream.makeStream(of: Outgoing.self)
        self.outgoing = continuation
        // One consumer, so cues and question changes reach the UI in the order they happened,
        // whichever task produced them.
        Task { @MainActor [weak self] in
            for await event in stream { self?.deliver(event) }
        }
    }

    /// True while this run holds the screen lease, so the shared input gate is its own.
    public var holdsScreen: Bool { holdsLease }

    /// Paused as far as this run is concerned: the gate once this run holds the lease, the
    /// pending pause before that.
    private var isPaused: Bool { holdsLease ? runtime.gate.isPaused : pendingPause }

    public var isConfigured: Bool { ModelRouter(settings: settingsStore.settings, credentials: credentials).isConfigured }

    /// True while a previous run is still unwinding after Stop.
    public var isWindingDown: Bool { task != nil && !isRunning }

    // MARK: Conversation (see Conversation.swift)

    /// What Glide wants said out loud; the voice layer subscribes.
    public var onSpeech: ((SpeechCue) -> Void)?
    /// The question Glide is waiting on, answered by voice, typing or an option chip.
    public private(set) var pendingQuestion: AgentQuestion?

    /// True while anything is going on: a task running or unwinding, or an utterance still being
    /// routed (an instant action at work). glidectl `say` waits for this to settle.
    public var isBusy: Bool { isRunning || task != nil || routing > 0 }

    /// Long or repetitive requests become background jobs (the app). Off where nothing hosts
    /// jobs (glidectl), so every plan runs as a quick task.
    public var backgroundJobsEnabled = true

    /// What goes to the voice layer, in order.
    private enum Outgoing: Sendable {
        case speech(SpeechCue)
        /// The conversation identified by the token changed its shown question.
        case questionChanged(UUID)
    }

    private let outgoing: AsyncStream<Outgoing>.Continuation
    /// The running task's conversation and the token its events carry.
    private var conversation: TaskConversation?
    private var conversationToken = UUID()
    /// The open approval's question, while the task waits on it.
    private var approvalQuestionID: String?

    /// A question asked when no task runs: an instant action's "anything else there?", or a
    /// planner's clarification. Whatever the user says next answers it.
    private struct IdleQuestion {
        enum Kind {
            /// After an instant action; an answer becomes a new request with what it opened.
            case instant(context: String?)
            /// The planner couldn't start without this; the answer re-runs the request with it.
            case clarify(instruction: String)
        }
        var question: AgentQuestion
        var kind: Kind
    }
    private var idleQuestion: IdleQuestion?

    /// The last finished request, for follow-ups within `followUpWindowMinutes`.
    private struct Exchange {
        var instruction: String
        var result: String
        var front: String?
        var at: Date
    }
    private var lastExchange: Exchange?
    /// The part of a request an instant action left over while another task was running; it
    /// starts when that task finishes.
    private var queuedRequest: (text: String, context: String?)?
    /// Utterances still being routed (waiting on the instant handler).
    private var routing = 0

    // Test seams.
    /// The instant-actions hook (tests install a fake without touching the global one).
    var instantHandler: () -> (@Sendable (String) async -> InstantResult?)? = { InstantActions.handler }
    /// Adjusts each orchestrator before it runs (tests: scripted model, no screen reading).
    var configureOrchestrator: ((ExecutionOrchestrator) -> Void)?
    /// Tools for the orchestrator instead of the standard registry (tests).
    var toolsOverride: ToolRegistry?
    /// Where tasks and instant actions are recorded (tests use a throwaway store).
    var historyStore: () -> LocalStore = { .shared }

    /// Everything the user says or types: answers a pending question, steers or stops the
    /// running task, or starts a new request (instant actions first).
    public func handleUtterance(_ text: String, source: UtteranceSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // (a) Control words act at once.
        if source != .option, let control = UtteranceInterpreter.control(trimmed) {
            if isRunning || task != nil {
                switch control {
                case .stop:
                    stop()
                    speak(.ack("Okay, stopped."))
                case .pause:
                    if phase == .executing || phase == .planning {
                        pause()
                        speak(.ack("Paused — say continue when you're ready."))
                    }
                case .resume:
                    if phase == .paused {
                        resume()
                        speak(.ack("Continuing."))
                    }
                }
                return
            }
            if control == .stop {
                if idleQuestion != nil { clearIdleQuestion() }
                queuedRequest = nil
                speak(.ack("Okay."))
                return
            }
            // "continue" with nothing paused: nothing to do.
            if control == .resume || control == .pause { return }
        }

        // (b) The open question.
        if let idle = idleQuestion, !isRunning {
            answerIdle(trimmed, question: idle)
            return
        }
        if let q = conversation?.current, let answer = UtteranceInterpreter.answer(trimmed, to: q, source: source) {
            self.answer(questionID: q.id, with: answer)
            return
        }

        // (c) While a task runs: an instant request runs alongside it; anything else steers it.
        if isRunning {
            routeWhileRunning(trimmed)
            return
        }
        if task != nil {
            status = "Still stopping the previous task — try again in a moment."
            return
        }

        // (d) Something new.
        routeNewRequest(trimmed, context: recentContext())
    }

    /// Answers a specific question (an option chip, or a typed reply to it).
    public func answer(questionID: String, with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idle = idleQuestion, idle.question.id == questionID {
            answerIdle(trimmed, question: idle)
            return
        }
        guard let conversation else { return }
        if questionID == approvalQuestionID {
            // Approvals take only a yes or a no; anything else asks again.
            guard let yes = UtteranceInterpreter.yesNo(trimmed) else {
                if let q = conversation.question(questionID) { speak(.question(q)) }
                return
            }
            conversation.answer(questionID, with: yes ? "Yes" : "No")
            append(ActivityEntry(kind: .approval, title: yes ? "You said yes" : "You said no", success: yes))
            respondToApproval(yes ? .approve : .reject)
            // "No, use the other card": the rest of it is for the task.
            if !yes, UtteranceInterpreter.normalize(trimmed).split(separator: " ").count > 2 { conversation.addNote(trimmed) }
            return
        }
        if conversation.answer(questionID, with: trimmed) {
            append(ActivityEntry(kind: .info, title: "You answered: \(trimmed)", detail: conversation.question(questionID)?.text))
            refreshQuestion()
        }
    }

    // MARK: Routing

    /// While a task runs: instant requests ("open Spotify") are done right away; anything else
    /// is a note for the running task ("make it size 10").
    private func routeWhileRunning(_ text: String) {
        let handler = instantHandler()
        let conversation = self.conversation
        routing += 1
        Task { @MainActor in
            defer { self.routing -= 1 }
            if let handler, let result = await handler(text) {
                self.speak(.ack(result.ack))
                self.append(ActivityEntry(kind: .result, title: result.summary, success: true))
                if let rest = result.remainder, !rest.isEmpty {
                    self.queuedRequest = (rest, result.context)
                    self.append(ActivityEntry(kind: .info, title: "Next up: \(rest)"))
                }
                return
            }
            guard let conversation, conversation === self.conversation, self.isRunning else {
                // The task ended meanwhile: it's a new request after all.
                if !self.isRunning, self.task == nil { self.routeNewRequest(text, context: self.recentContext()) }
                return
            }
            conversation.addNote(text)
            self.append(ActivityEntry(kind: .info, title: "You said: \(text)"))
            self.speak(.ack("Got it."))
        }
    }

    /// A new request: the instant handler first (milliseconds, no model); what it leaves over,
    /// or anything it doesn't handle, goes to the planner with `context`.
    private func routeNewRequest(_ text: String, context: String?) {
        clearIdleQuestion()
        let handler = instantHandler()
        guard let handler else {
            start(text, context: context)
            return
        }
        routing += 1
        Task { @MainActor in
            defer { self.routing -= 1 }
            let result = await handler(text)
            guard !self.isRunning, self.task == nil else { return }
            if let result {
                await self.finishInstant(text, result, context: context)
            } else {
                self.start(text, context: context)
            }
        }
    }

    /// Shows and says what an instant action did, then plans what it left over or asks its
    /// follow-up question.
    private func finishInstant(_ text: String, _ result: InstantResult, context: String?) async {
        speak(.ack(result.ack))
        let entry = ActivityEntry(kind: .result, title: result.summary, success: true)
        if let rest = result.remainder?.trimmingCharacters(in: .whitespacesAndNewlines), !rest.isEmpty {
            start(rest, context: Self.join(context, result.context ?? result.summary))
            activity.insert(entry, at: 0)
            return
        }
        let metrics = await TaskMetrics().snapshot()
        guard !isRunning, task == nil else { return }
        runID &+= 1
        instruction = text
        plan = nil
        currentStepIndex = 0
        activity = [entry]
        pendingApproval = nil
        startedAt = Date()
        phase = .completed
        status = result.summary
        var done = TaskResult(status: .completed, summary: result.summary, error: nil, plan: nil, metrics: metrics, durationMs: 0)
        done.front = result.context
        lastResult = done
        lastTaskID = nil
        recordInstant(text, entry: entry, result: done)
        lastExchange = Exchange(instruction: text, result: result.summary, front: result.context, at: Date())
        onFinished?(done)
        if let followUp = result.followUp, settingsStore.settings.conversation.offerNextStep {
            askIdle(followUp, kind: .instant(context: result.context ?? result.summary))
        }
        onAttentionNeeded?()
    }

    private func recordInstant(_ text: String, entry: ActivityEntry, result: TaskResult) {
        guard settingsStore.settings.keepHistory else { return }
        let id = UUID().uuidString
        let store = historyStore()
        store.startTask(id: id, instruction: text)
        store.appendEvent(taskID: id, entry)
        store.finishTask(id: id, result: result)
        lastTaskID = id
    }

    private func askIdle(_ question: AgentQuestion, kind: IdleQuestion.Kind) {
        idleQuestion = IdleQuestion(question: question, kind: kind)
        pendingQuestion = question
        speak(.question(question))
    }

    private func clearIdleQuestion() {
        guard idleQuestion != nil else { return }
        idleQuestion = nil
        pendingQuestion = conversation?.current
    }

    /// The answer to a question asked while idle. "No" closes it; anything else continues
    /// from it (an instant follow-up becomes a request with what it opened; a clarification
    /// re-runs the request with the answer).
    private func answerIdle(_ text: String, question idle: IdleQuestion) {
        clearIdleQuestion()
        let yesNo = UtteranceInterpreter.yesNo(text)
        if yesNo == false || UtteranceInterpreter.control(text) == .stop {
            speak(.ack("Okay."))
            return
        }
        switch idle.kind {
        case .instant(let context):
            // A bare "yes": what should it be?
            if yesNo == true, UtteranceInterpreter.normalize(text).split(separator: " ").count <= 3 {
                askIdle(AgentQuestion(text: "What should I do there?"), kind: .instant(context: context))
                return
            }
            routeNewRequest(text, context: Self.join(recentContext(), context))
        case .clarify(let instruction):
            start(instruction + "\n\nThe user's answer to “\(idle.question.text)”: \(text)", context: recentContext())
        }
    }

    /// The last request and its result, while within the follow-up window.
    private func recentContext() -> String? {
        let window = settingsStore.settings.conversation.followUpWindowMinutes
        guard window > 0, let last = lastExchange, Date().timeIntervalSince(last.at) <= window * 60 else { return nil }
        var lines = ["Previous request: \(last.instruction)", "Its result: \(last.result)"]
        if let front = last.front, !front.isEmpty { lines.append("In front afterwards: \(front)") }
        return lines.joined(separator: "\n")
    }

    private static func join(_ a: String?, _ b: String?) -> String? {
        let parts = [a, b].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: Speech

    private func speak(_ cue: SpeechCue) { outgoing.yield(.speech(cue)) }

    private func deliver(_ event: Outgoing) {
        switch event {
        case .speech(let cue):
            onSpeech?(cue)
        case .questionChanged(let token):
            guard token == conversationToken else { return }
            refreshQuestion()
        }
    }

    /// The notch shows the conversation's current question (always read fresh, so events that
    /// arrive late never bring back an answered one).
    private func refreshQuestion() {
        guard idleQuestion == nil else { return }
        let current = conversation?.current
        guard current != pendingQuestion else { return }
        pendingQuestion = current
        if current != nil { onAttentionNeeded?() }
    }

    /// A new conversation for a run; its events reach the UI through `outgoing`.
    private func makeConversation(defaultAfter: TimeInterval) -> TaskConversation {
        let token = UUID()
        conversationToken = token
        let out = outgoing
        let conversation = TaskConversation(defaultAfter: defaultAfter) { event in
            switch event {
            case .speech(let cue): out.yield(.speech(cue))
            case .question: out.yield(.questionChanged(token))
            }
        }
        let gate = runtime.gate
        conversation.isPaused = { gate.isPaused }
        return conversation
    }

    private func endConversation() {
        conversation?.close()
        conversation = nil
        approvalQuestionID = nil
        conversationToken = UUID()
        if idleQuestion == nil { pendingQuestion = nil }
    }

    // MARK: Running

    public func start(_ text: String) {
        start(text, context: nil)
    }

    /// Starts a task with the planner. `context` is what the conversation established (the
    /// previous task, what an instant action opened), for follow-ups like "now add two of them".
    public func start(_ text: String, context: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Refuse while a stopped run is still unwinding: it shares the input gate.
        guard !trimmed.isEmpty, !isRunning else { return }
        if task != nil {
            status = "Still stopping the previous task — try again in a moment."
            return
        }
        runID &+= 1
        let id = runID
        instruction = trimmed
        plan = nil
        currentStepIndex = 0
        activity = []
        lastResult = nil
        pendingApproval = nil
        startedAt = Date()
        phase = .planning
        status = "Understanding your task…"
        idleQuestion = nil
        endConversation()
        let settings = settingsStore.settings
        guard ModelRouter(settings: settings, credentials: credentials).isConfigured else {
            phase = .failed
            status = "Add an AI provider key in Settings to get started."
            speak(.error("I need an AI provider key first — add one in Settings."))
            onAttentionNeeded?()
            return
        }
        let conversation = makeConversation(defaultAfter: settings.conversation.defaultAfterSeconds)
        self.conversation = conversation
        // The gate is reset once this run holds the screen lease (`takeInputGate`), not here: a
        // background job's on-screen step may be using it until then.
        holdsLease = false
        pendingPause = false
        // Every callback carries the run id; anything from an older run is dropped.
        let callbacks = AgentCallbacks(
            phase: { [weak self] p, s in Task { @MainActor in self?.update(phase: p, status: s, run: id) } },
            log: { [weak self] e in Task { @MainActor in if self?.runID == id { self?.append(e) } } },
            plan: { [weak self] p, i in Task { @MainActor in if self?.runID == id { self?.plan = p; self?.currentStepIndex = i } } },
            approve: { [weak self] req in
                guard let self else { return .stop }
                return await self.requestApproval(req, run: id)
            })
        // Long or repetitive requests (plan mode `job`) become background jobs; this quick task
        // then finishes with a short "Started a background job" summary and the job's id.
        var handoff: ExecutionOrchestrator.JobHandoff?
        if backgroundJobsEnabled {
            handoff = { [weak self] instruction, _ in
                guard let self else { return nil }
                return await self.startBackgroundJob(instruction, run: id)
            }
        }
        let jobHandoff = handoff
        let tools = toolsOverride
        let configure = configureOrchestrator
        task = Task { [weak self] in
            var composio: (ComposioClient, String)?
            if settings.composio.enabled {
                composio = try? await ComposioSessionStore.ensureSession()
            }
            // Before this run holds the lease, Stop cancels this task (the gate isn't its yet).
            guard let self, !Task.isCancelled, self.runID == id else {
                await self?.endStopped(run: id)
                return
            }
            // Quick tasks are interactive: they take the screen ahead of background jobs. A job's
            // on-screen step that is already running finishes first; jobs' other work continues.
            let leaseOwner = "task:\(id)"
            let lease = self.screenLease
            if await lease.currentHolder != nil {
                self.update(phase: .planning, status: Self.waitingForScreenStatus, run: id)
            }
            do {
                try await lease.acquire(owner: leaseOwner, priority: true)
            } catch {
                await self.endStopped(run: id)
                return
            }
            guard !Task.isCancelled, self.runID == id else {
                await lease.release(owner: leaseOwner)
                await self.endStopped(run: id)
                return
            }
            self.takeInputGate()
            let orchestrator = ExecutionOrchestrator(instruction: trimmed, settings: self.settingsStore.settings, runtime: self.runtime,
                                                     callbacks: callbacks, store: self.historyStore(), credentials: self.credentials,
                                                     composio: composio, tools: tools,
                                                     jobHandoff: jobHandoff)
            orchestrator.conversation = conversation
            orchestrator.conversationContext = context
            configure?(orchestrator)
            self.orchestrator = orchestrator
            self.lastTaskID = orchestrator.taskID
            let run = Task.detached(priority: .userInitiated) { await orchestrator.run() }
            self.runTask = run
            let result = await run.value
            // Let go of the gate before the lease: once released, a job's on-screen step may
            // start, and a Stop pressed after that must not reach it.
            self.holdsLease = false
            self.runTask = nil
            self.orchestrator = nil
            await lease.release(owner: leaseOwner)
            self.task = nil
            self.finish(result, run: id)
        }
    }

    /// Called once this run holds the screen lease: from here the shared input gate is this
    /// run's. Clears a Stop or pause an earlier task or job left on it, then applies a pause
    /// pressed while waiting.
    func takeInputGate() {
        holdsLease = true
        runtime.gate.reset()
        if pendingPause {
            pendingPause = false
            runtime.gate.pause()
        }
    }

    /// Ends a run that was stopped before it started working.
    private func endStopped(run: Int) async {
        // Snapshot first: clearing `task` and recording the result must happen without a
        // suspension in between, or the run briefly looks finished with no result.
        let metrics = await TaskMetrics().snapshot()
        task = nil
        finish(TaskResult(status: .stopped, summary: "Stopped", error: nil, plan: nil, metrics: metrics, durationMs: 0), run: run)
    }

    /// Plans the request as a background job. Nil when this run was stopped or replaced while
    /// planning, so nothing is started on its behalf.
    private func startBackgroundJob(_ instruction: String, run: Int) async -> JobRecord? {
        guard run == runID, !runtime.gate.isStopped else { return nil }
        status = "Setting up a background job…"
        let job = await jobCenter.create(instruction: instruction)
        // A stop pressed while the job was being planned also stops the new job.
        if run != runID || runtime.gate.isStopped {
            if !job.status.isFinished { jobCenter.stop(job.id) }
            return nil
        }
        return job
    }

    private func update(phase p: AgentPhase, status s: String, run: Int) {
        guard run == runID, isRunning else { return }
        // While paused, progress messages from in-flight work mustn't un-pause the UI.
        if isPaused && p != .paused && p != .awaitingApproval {
            // Still waiting for the screen: show the latest of these again on resume.
            if !holdsLease { statusBeforePause = s }
            return
        }
        phase = p
        status = s
    }

    private func append(_ e: ActivityEntry) {
        activity.append(e)
        if activity.count > 400 { activity.removeFirst(activity.count - 400) }
    }

    private func finish(_ result: TaskResult, run: Int) {
        // Release anything still waiting on this run's approval.
        approvalContinuation?.resume(returning: .stop)
        approvalContinuation = nil
        guard run == runID else { return }
        endConversation()
        lastResult = result
        switch result.status {
        case .completed: phase = .completed; status = result.summary
        case .failed: phase = .failed; status = result.error ?? result.summary
        case .stopped: phase = .stopped; status = "Stopped"
        case .needsInput: phase = .needsInput; status = result.summary
        }
        pendingApproval = nil
        speakOutcome(result)
        if result.status != .stopped {
            lastExchange = Exchange(instruction: instruction, result: result.summary, front: result.front, at: Date())
        }
        onFinished?(result)
        onAttentionNeeded?()
        // What an instant action left over while this task ran starts now (unless it was stopped).
        if let next = queuedRequest {
            queuedRequest = nil
            if result.status != .stopped { start(next.text, context: Self.join(recentContext(), next.context)) }
        }
    }

    /// What Glide says when a task ends. A planner's clarification becomes a question whose
    /// answer re-runs the request; a stop was already acknowledged.
    private func speakOutcome(_ result: TaskResult) {
        switch result.status {
        case .completed:
            speak(.result(result.spoken ?? UtteranceInterpreter.spokenSummary(result.summary)))
        case .failed:
            speak(.error(UtteranceInterpreter.spokenSummary(result.summary)))
        case .needsInput:
            if let plan = result.plan, plan.steps.isEmpty, let question = plan.clarification, question == result.summary, result.jobID == nil {
                askIdle(AgentQuestion(text: question), kind: .clarify(instruction: instruction))
            } else {
                speak(.needsYou(UtteranceInterpreter.spokenSummary(result.summary, maxWords: 30)))
            }
        case .stopped:
            break
        }
    }

    private func requestApproval(_ req: ApprovalRequest, run: Int) async -> ApprovalDecision {
        guard run == runID, !runtime.gate.isStopped else { return .stop }
        return await withCheckedContinuation { (c: CheckedContinuation<ApprovalDecision, Never>) in
            approvalContinuation?.resume(returning: .reject)
            approvalContinuation = c
            pendingApproval = req
            phase = .awaitingApproval
            // Also a yes/no question, so it can be answered by voice. It's shown ahead of any
            // other question (the task is stopped on it) and never answered by silence.
            if let conversation {
                if let old = approvalQuestionID { conversation.withdraw(old) }
                let question = Self.approvalQuestion(req)
                approvalQuestionID = question.id
                conversation.post(question, first: true)
                refreshQuestion()
            }
            onAttentionNeeded?()
        }
    }

    /// The yes/no question for an approval: "Okay to click “Place order”?"
    static func approvalQuestion(_ req: ApprovalRequest) -> AgentQuestion {
        let action = UtteranceInterpreter.lowerFirst(req.title.trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
        let text = "Okay to \(action)?"
        let spoken = text.replacingOccurrences(of: "`", with: "")
        return AgentQuestion(id: "approval-\(req.id.uuidString)", text: text, spoken: spoken == text ? nil : spoken, options: ["Yes", "No"],
                             lowRisk: false, isApproval: true)
    }

    public func respondToApproval(_ decision: ApprovalDecision) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
        if let id = approvalQuestionID {
            // Answered with the notch's buttons: the spoken question goes too.
            approvalQuestionID = nil
            conversation?.withdraw(id)
            refreshQuestion()
        }
        if decision == .stop { stop() } else if isPaused { phase = .paused } else { phase = .executing }
    }

    public func pause() {
        guard phase == .executing || phase == .planning else { return }
        if holdsLease {
            runtime.gate.pause()
        } else {
            // Still waiting for the screen: the gate may be driving a job's on-screen step.
            pendingPause = true
            statusBeforePause = status
        }
        phase = .paused
        status = "Paused"
    }

    public func resume() {
        guard phase == .paused else { return }
        guard holdsLease else {
            pendingPause = false
            phase = .planning
            status = statusBeforePause.isEmpty ? "Understanding your task…" : statusBeforePause
            return
        }
        runtime.gate.resume()
        phase = .executing
        status = plan.map { currentStepIndex < $0.steps.count ? $0.steps[currentStepIndex].title + "…" : "Resuming…" } ?? "Resuming…"
    }

    public func togglePause() {
        if phase == .paused { resume() } else { pause() }
    }

    /// Stops the quick task; once it holds the screen, no further input is injected after this
    /// returns. While it's still waiting for the screen, cancelling the wait is all it takes:
    /// the shared gate then belongs to whoever holds the lease, and stopping it would stop a
    /// background job's on-screen step instead (the emergency stop halts jobs separately,
    /// through `JobCenter.haltAll`).
    public func stop() {
        if holdsLease {
            runtime.gate.stop()
            orchestrator?.stop()
        }
        pendingPause = false
        queuedRequest = nil
        // Steps waiting for an answer end now.
        conversation?.close()
        runTask?.cancel()
        task?.cancel()
        approvalContinuation?.resume(returning: .stop)
        approvalContinuation = nil
        pendingApproval = nil
        if isRunning {
            phase = .stopped
            status = "Stopped"
        }
        pendingQuestion = idleQuestion?.question
    }

    public func retry() {
        guard !isRunning, !instruction.isEmpty else { return }
        start(instruction)
    }

    /// Runs again, telling the planner what went wrong last time.
    public func replan() {
        guard !isRunning, !instruction.isEmpty else { return }
        let previous = lastResult?.error ?? lastResult?.summary ?? ""
        let base = instruction.components(separatedBy: "\n\n(Previous attempt").first ?? instruction
        start(previous.isEmpty ? base : base + "\n\n(Previous attempt failed: \(previous). Try a different approach.)")
    }

    /// Sets display state directly. Used only by the UI snapshot renderer (`--snapshot`).
    public func previewState(phase: AgentPhase, status: String, instruction: String = "", plan: Plan? = nil, stepIndex: Int = 0,
                             activity: [ActivityEntry] = [], approval: ApprovalRequest? = nil, holdsScreen: Bool = false,
                             question: AgentQuestion? = nil) {
        self.holdsLease = holdsScreen
        self.phase = phase
        self.status = status
        self.instruction = instruction
        self.plan = plan
        self.currentStepIndex = stepIndex
        self.activity = activity
        self.pendingApproval = approval
        self.pendingQuestion = question
    }

    public func reset() {
        guard !isRunning else { return }
        phase = .idle
        status = ""
        pendingApproval = nil
    }
}

extension ApprovalDecision: Equatable {}
