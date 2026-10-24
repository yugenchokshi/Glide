import Testing
import Foundation
import AppKit
import CoreGraphics
@testable import GlideApp
@testable import AgentKit
import AutomationKit

// Offline tests for the notch's click and approval rules. Nothing here posts input, moves
// the cursor, shows a window or calls a model: the notch model runs over in-memory jobs.

/// A notch model over in-memory jobs, an idle quick task and its own settings suite.
@MainActor
struct NotchFixture {
    let suite: String
    let store: SettingsStore
    /// The quick task's own runtime (its gate); never the app's shared one.
    let runtime: AutomationRuntime
    let controller: TaskController
    let jobs: PreviewJobs
    let model: NotchModel
    /// The model's clock; tests move it forward.
    let now: Clock

    final class Clock {
        var date = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func advance(_ seconds: Double) { date = date.addingTimeInterval(seconds) }
    }

    init() throws {
        suite = "dev.glide.tests.notch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        store = SettingsStore(defaults: defaults)
        runtime = AutomationRuntime()
        controller = TaskController(runtime: runtime, settingsStore: store)
        jobs = PreviewJobs()
        model = NotchModel(controller: controller, settings: store, jobs: jobs)
        let clock = Clock()
        now = clock
        model.clock = { clock.date }
        model.currentEventIsAgent = { false }
        model.agentPointerIdleSeconds = { .infinity }
    }

    func cleanup() {
        model.jobDismissWork?.cancel()
        model.dismissWork?.cancel()
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func job(_ id: String, _ status: JobStatus) -> JobRecord {
        JobRecord(id: id, title: "Job \(id)", instruction: "Do \(id)", status: status, folder: "/tmp/glide-tests/\(id)")
    }

    static func request(_ title: String) -> ApprovalRequest {
        ApprovalRequest(kind: .tool, title: title, detail: "", appName: nil, risk: .high, reasons: [])
    }
}

@Suite("Glide notch click guard")
struct GlideNotchClickGuardTests {
    @Test func quickTaskApprovalIsClickableAtOnce() {
        #expect(NotchClickGuard.acceptsClicks(quickTaskApproval: true, jobDecisionShowing: false, pointerIdleSeconds: 0, agentPaused: false))
    }

    @Test func jobDecisionWaitsForAgentInputToSettle() {
        // Agent input in flight: a job's approval or card stays click-through, paused or not
        // (input held by a pause goes out the moment it resumes).
        #expect(!NotchClickGuard.acceptsClicks(quickTaskApproval: false, jobDecisionShowing: true, pointerIdleSeconds: 0.2, agentPaused: false))
        #expect(!NotchClickGuard.acceptsClicks(quickTaskApproval: false, jobDecisionShowing: true, pointerIdleSeconds: 0.2, agentPaused: true))
        #expect(NotchClickGuard.acceptsClicks(quickTaskApproval: false, jobDecisionShowing: true, pointerIdleSeconds: 1.5, agentPaused: false))
    }

    @Test func otherCardsAreClickableWhenSettledOrPaused() {
        #expect(!NotchClickGuard.acceptsClicks(quickTaskApproval: false, jobDecisionShowing: false, pointerIdleSeconds: 0.2, agentPaused: false))
        #expect(NotchClickGuard.acceptsClicks(quickTaskApproval: false, jobDecisionShowing: false, pointerIdleSeconds: 0.2, agentPaused: true))
        #expect(NotchClickGuard.acceptsClicks(quickTaskApproval: false, jobDecisionShowing: false, pointerIdleSeconds: 5, agentPaused: false))
    }

    @Test func decisionsIgnoreAgentClicks() {
        #expect(!NotchClickGuard.acceptsDecision(agentEvent: true, forJob: false, pointerIdleSeconds: .infinity))
        #expect(!NotchClickGuard.acceptsDecision(agentEvent: true, forJob: true, pointerIdleSeconds: .infinity))
        // A job decision reached while the agent is acting can't be told apart from the agent's.
        #expect(!NotchClickGuard.acceptsDecision(agentEvent: false, forJob: true, pointerIdleSeconds: 0.3))
        #expect(NotchClickGuard.acceptsDecision(agentEvent: false, forJob: true, pointerIdleSeconds: 2))
        // The quick task is blocked on its own approval, so a fast answer counts.
        #expect(NotchClickGuard.acceptsDecision(agentEvent: false, forJob: false, pointerIdleSeconds: 0.3))
    }

    @Test func recognizesTheAgentsEventTag() throws {
        // Built in memory and never posted.
        let tagged = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left))
        tagged.setIntegerValueField(.eventSourceUserData, value: InputSynthesizer.eventTag)
        let plain = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left))
        #expect(NotchClickGuard.isAgentEvent(NSEvent(cgEvent: tagged)))
        #expect(!NotchClickGuard.isAgentEvent(NSEvent(cgEvent: plain)))
        #expect(!NotchClickGuard.isAgentEvent(nil))
    }

    @Test func glideDropsTheAgentsClicksAndKeysButNotMoves() throws {
        // Built in memory and never posted.
        func event(_ e: CGEvent?, tag: Bool = true) throws -> NSEvent {
            let e = try #require(e)
            if tag { e.setIntegerValueField(.eventSourceUserData, value: InputSynthesizer.eventTag) }
            return try #require(NSEvent(cgEvent: e))
        }
        func tagged(_ e: CGEvent?) throws -> NSEvent { try event(e) }
        let down = try tagged(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
        let right = try tagged(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: .zero, mouseButton: .right))
        let key = try tagged(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        let scroll = try tagged(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
        let move = try tagged(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left))
        for e in [down, right, key, scroll] { #expect(NotchClickGuard.dropsAgentInput(e), "\(e.type)") }
        #expect(!NotchClickGuard.dropsAgentInput(move))

        // The user's own click and Return go through.
        let userDown = try event(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left), tag: false)
        let userKey = try event(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true), tag: false)
        #expect(!NotchClickGuard.dropsAgentInput(userDown))
        #expect(!NotchClickGuard.dropsAgentInput(userKey))
    }

    @Test func pointerIntentIsRecorded() {
        let intent = PointerIntent()
        #expect(intent.lastMarked == .distantPast)
        intent.mark()
        #expect(Date().timeIntervalSince(intent.lastMarked) < 1)
    }
}

@MainActor
@Suite("Glide notch approvals")
struct GlideNotchApprovalTests {
    @Test func jobApprovalWaitsWhileTheQuickTaskHoldsTheScreen() throws {
        let f = try NotchFixture()
        defer { f.cleanup() }
        f.jobs.jobs = [f.job("a", .running)]
        f.jobs.pendingApprovals = ["a": NotchFixture.request("git push")]
        f.controller.previewState(phase: .executing, status: "Clicking")
        f.model.screenHolder = "task:1"
        f.model.recompute()
        #expect(f.model.presentation == .running)
        #expect(f.model.activeApproval == nil)
        #expect(f.model.jobApprovalWaiting)
        #expect(!f.model.isShowing(job: "a"))

        // The quick task is done: the job's approval takes over.
        f.controller.previewState(phase: .completed, status: "Done")
        f.model.recompute()
        #expect(f.model.presentation == .approval)
        #expect(f.model.activeApproval?.jobID == "a")
        #expect(f.model.showsJobDecision)
        #expect(f.model.isShowing(job: "a"))
    }

    @Test func jobApprovalShowsWhileTheQuickTaskWaitsForThatJobsScreen() throws {
        // The quick task is queued behind job a's on-screen step, which needs an OK: holding
        // the approval back would leave both waiting on each other.
        let f = try NotchFixture()
        defer { f.cleanup() }
        f.jobs.jobs = [f.job("a", .running)]
        f.jobs.pendingApprovals = ["a": NotchFixture.request("Click Send")]
        f.controller.previewState(phase: .planning, status: "Waiting for a background job to finish its on-screen step…")
        f.model.screenHolder = "job:a"
        f.model.recompute()
        #expect(f.model.presentation == .approval)
        #expect(f.model.activeApproval?.jobID == "a")
    }

    @Test func quickTaskApprovalWinsAndIsNotAJobDecision() throws {
        let f = try NotchFixture()
        defer { f.cleanup() }
        f.jobs.jobs = [f.job("a", .running)]
        f.jobs.pendingApprovals = ["a": NotchFixture.request("git push")]
        f.controller.previewState(phase: .awaitingApproval, status: "Needs your approval", approval: NotchFixture.request("Click Send"))
        f.model.screenHolder = "task:1"
        f.model.recompute()
        #expect(f.model.presentation == .approval)
        #expect(f.model.activeApproval?.jobID == nil)
        #expect(!f.model.showsJobDecision)
    }

    @Test func approveAnswersOnlyTheRequestThatWasShown() throws {
        let f = try NotchFixture()
        defer { f.cleanup() }
        let a = NotchFixture.request("Delete a.txt"), b = NotchFixture.request("git push --force")
        f.jobs.jobs = [f.job("a", .running), f.job("b", .running)]
        f.jobs.pendingApprovals = ["a": a]
        f.model.jobNeedsAttention("a")
        let shown = try #require(f.model.activeApproval)
        #expect(shown.request.id == a.id)

        // Job b asks just before the click lands: the card now shows b, and the click for a is dropped.
        f.now.advance(2)
        f.jobs.pendingApprovals["b"] = b
        f.model.jobNeedsAttention("b")
        #expect(!f.model.respondToApproval(.approve, to: shown))
        #expect(f.jobs.pendingApprovals["a"]?.id == a.id)
        #expect(f.jobs.pendingApprovals["b"]?.id == b.id)

        // b only just appeared: a click on it right away doesn't count either.
        let next = try #require(f.model.activeApproval)
        #expect(next.request.id == b.id)
        #expect(!f.model.respondToApproval(.approve, to: next))
        #expect(f.jobs.pendingApprovals["b"] != nil)

        // Once it has been on screen a moment, the click answers b, and only b.
        f.now.advance(NotchModel.approvalReadSeconds + 0.1)
        #expect(f.model.respondToApproval(.approve, to: next))
        #expect(f.jobs.pendingApprovals["b"] == nil)
        #expect(f.jobs.pendingApprovals["a"]?.id == a.id)
    }

    @Test func quickTaskApprovalReplacedByAnotherIsNotAnswered() throws {
        let f = try NotchFixture()
        defer { f.cleanup() }
        let first = NotchFixture.request("Click Send"), second = NotchFixture.request("Click Delete")
        f.controller.previewState(phase: .awaitingApproval, status: "Needs your approval", approval: first)
        f.model.recompute()
        let shown = try #require(f.model.activeApproval)
        f.now.advance(2)
        f.controller.previewState(phase: .awaitingApproval, status: "Needs your approval", approval: second)
        f.model.recompute()
        #expect(!f.model.respondToApproval(.approve, to: shown))
        #expect(f.controller.pendingApproval?.id == second.id)

        f.now.advance(1)
        let current = try #require(f.model.activeApproval)
        #expect(f.model.respondToApproval(.reject, to: current))
        #expect(f.controller.pendingApproval == nil)
    }

    @Test func agentClicksNeverAnswerAJobApproval() throws {
        let f = try NotchFixture()
        defer { f.cleanup() }
        f.jobs.jobs = [f.job("a", .running)]
        f.jobs.pendingApprovals = ["a": NotchFixture.request("git push")]
        f.model.jobNeedsAttention("a")
        let shown = try #require(f.model.activeApproval)
        f.now.advance(2)

        f.model.currentEventIsAgent = { true }
        #expect(!f.model.respondToApproval(.approve, to: shown))
        // The user's click, but the agent used the pointer a moment ago.
        f.model.currentEventIsAgent = { false }
        f.model.agentPointerIdleSeconds = { 0.2 }
        #expect(!f.model.respondToApproval(.approve, to: shown))
        #expect(f.jobs.pendingApprovals["a"] != nil)

        f.model.agentPointerIdleSeconds = { 3 }
        #expect(f.model.respondToApproval(.approve, to: shown))
        #expect(f.jobs.pendingApprovals["a"] == nil)
    }

    @Test func jobCardDecisionsIgnoreAgentClicks() throws {
        let f = try NotchFixture()
        defer { f.cleanup() }
        f.jobs.jobs = [f.job("c", .awaitingConfirmation)]
        f.model.jobNeedsAttention("c")
        #expect(f.model.presentation == .job)
        #expect(f.model.showsJobDecision)

        f.model.currentEventIsAgent = { true }
        f.model.userDecision { f.model.startJob("c") }
        #expect(f.jobs.job("c")?.status == .awaitingConfirmation)

        f.model.currentEventIsAgent = { false }
        f.model.userDecision { f.model.startJob("c") }
        #expect(f.jobs.job("c")?.status == .running)
    }

    @Test func jobRowDecisionsIgnoreAgentClicks() throws {
        // The job rows in the detail view and the pill: Start, Pause, Resume and Stop.
        let f = try NotchFixture()
        defer { f.cleanup() }
        f.jobs.jobs = [f.job("c", .awaitingConfirmation), f.job("r", .running), f.job("p", .paused), f.job("s", .running)]
        let actions: [() -> Void] = [{ f.jobs.start("c") }, { f.jobs.pause("r") }, { f.jobs.resume("p") }, { f.model.stopJob("s") }]
        let before = f.jobs.jobs.map(\.status)

        // The agent's own click, and the user's click while the agent's pointer is still busy.
        f.model.currentEventIsAgent = { true }
        for act in actions { f.model.userDecision(act) }
        f.model.currentEventIsAgent = { false }
        f.model.agentPointerIdleSeconds = { 0.3 }
        for act in actions { f.model.userDecision(act) }
        #expect(f.jobs.jobs.map(\.status) == before)

        f.model.agentPointerIdleSeconds = { 4 }
        for act in actions { f.model.userDecision(act) }
        #expect(f.jobs.job("c")?.status == .running)
        #expect(f.jobs.job("r")?.status == .paused)
        #expect(f.jobs.job("p")?.status == .running)
        #expect(f.jobs.job("s")?.status == .stopped)
    }
}

@MainActor
@Suite("Glide notch pause and resume")
struct GlideNotchResumeTests {
    @Test func resumeGetsTheNotchOutOfTheWayFirst() throws {
        // Input the pause held goes out as soon as the gate opens, so the panel must be
        // click-through before that, not after.
        let f = try NotchFixture()
        defer { f.cleanup() }
        var gatePausedAtHook: [Bool] = []
        f.model.agentWillResume = { gatePausedAtHook.append(f.runtime.gate.isPaused) }
        f.runtime.gate.pause()
        // A task paused mid-run holds the screen, so its pause is the shared gate's.
        f.controller.previewState(phase: .paused, status: "Paused", holdsScreen: true)
        f.model.togglePause()
        #expect(gatePausedAtHook == [true])
        #expect(f.runtime.gate.current == .running)
        #expect(f.controller.phase == .executing)

        // Pausing releases nothing.
        f.model.togglePause()
        #expect(gatePausedAtHook == [true])
        #expect(f.runtime.gate.isPaused)
        #expect(f.controller.phase == .paused)
    }
}

@MainActor
@Suite("Glide notch auto-dismiss")
struct GlideNotchDismissTests {
    @Test func finishedJobCardTimesOutOnlyOnceOnScreen() throws {
        let f = try NotchFixture()
        defer { f.cleanup() }
        let done = f.job("d", .completed)
        f.jobs.jobs = [done]
        f.controller.previewState(phase: .executing, status: "Clicking")
        f.model.jobFinished(done)
        // Hidden behind the running quick task: no timer yet, and no card on screen.
        #expect(f.model.presentation == .running)
        #expect(f.model.jobDismissWork == nil)
        #expect(!f.model.isShowing(job: "d"))

        f.controller.previewState(phase: .completed, status: "Done")
        f.model.recompute()
        #expect(f.model.presentation == .job)
        #expect(f.model.isShowing(job: "d"))
        let work = try #require(f.model.jobDismissWork)

        // Covered by the task field: the timer is dropped, so it can't fire while hidden.
        f.model.inputOpen = true
        f.model.recompute()
        #expect(work.isCancelled)
        #expect(f.model.jobDismissWork == nil)
        work.perform()
        #expect(f.model.attentionJobID == "d")

        // Back on screen: a new timer with the full time.
        f.model.inputOpen = false
        f.model.recompute()
        #expect(f.model.presentation == .job)
        let again = try #require(f.model.jobDismissWork)
        #expect(again !== work)
        #expect(!again.isCancelled)

        // On screen when it fires: the card folds away.
        again.perform()
        #expect(f.model.attentionJobID == nil)
        #expect(f.model.presentation != .job)
    }

    @Test func cardCoveredByAnotherJobsApprovalComesBackWithTheFullTime() throws {
        // A finished card is up, another job asks for an OK a second later, and the user takes
        // a few seconds to answer. The old timer must not fold the card away just after it's back.
        let f = try NotchFixture()
        defer { f.cleanup() }
        let done = f.job("d", .completed)
        f.jobs.jobs = [done, f.job("b", .running)]
        f.model.jobFinished(done)
        #expect(f.model.presentation == .job)
        let first = try #require(f.model.jobDismissWork)

        f.now.advance(1)
        f.jobs.pendingApprovals["b"] = NotchFixture.request("git push")
        f.model.jobNeedsAttention("b")
        // The approval covers the card, which keeps its place (b has no card of its own).
        #expect(f.model.presentation == .approval)
        #expect(f.model.activeApproval?.jobID == "b")
        #expect(f.model.attentionJobID == "d")
        #expect(f.model.isShowing(job: "b"))
        #expect(first.isCancelled)
        #expect(f.model.jobDismissWork == nil)

        f.now.advance(4.5)
        let shown = try #require(f.model.activeApproval)
        #expect(f.model.respondToApproval(.approve, to: shown))
        #expect(f.model.presentation == .job)
        #expect(f.model.isShowing(job: "d"))
        let second = try #require(f.model.jobDismissWork)
        #expect(second !== first)
        #expect(!second.isCancelled)
        // The first timer's deadline passes: nothing happens to the card.
        first.perform()
        #expect(f.model.attentionJobID == "d")
        #expect(f.model.presentation == .job)
    }

    @Test func aJobWithACardOfItsOwnStillTakesTheSlot() throws {
        // Only a bare approval waits behind another job's card; a confirmation replaces it.
        let f = try NotchFixture()
        defer { f.cleanup() }
        let done = f.job("d", .completed)
        f.jobs.jobs = [done, f.job("c", .awaitingConfirmation)]
        f.model.jobFinished(done)
        f.model.jobNeedsAttention("c")
        #expect(f.model.attentionJobID == "c")
        #expect(f.model.presentation == .job)
        #expect(f.model.jobDismissWork == nil)
    }

    @Test func quickTaskResultTimesOutOnlyOnceOnScreen() async throws {
        let f = try NotchFixture()
        defer { f.cleanup() }
        let failed = f.job("x", .failed)
        f.jobs.jobs = [failed]
        f.model.jobFinished(failed)
        #expect(f.model.presentation == .job)

        f.controller.previewState(phase: .completed, status: "Done")
        let metrics = await TaskMetrics().snapshot()
        f.model.taskFinished(TaskResult(status: .completed, summary: "Done", error: nil, plan: nil, metrics: metrics, durationMs: 1))
        // The failed job's card is in front: the result waits without a timer.
        #expect(f.model.presentation == .job)
        #expect(f.model.dismissWork == nil)

        f.model.dismissJobCard()
        #expect(f.model.presentation == .result)
        let work = try #require(f.model.dismissWork)

        // Covered by the detail view, then back: the old timer is gone and a new one starts.
        f.model.detailOpen = true
        f.model.recompute()
        #expect(f.model.presentation == .detail)
        #expect(work.isCancelled)
        #expect(f.model.dismissWork == nil)
        f.model.detailOpen = false
        f.model.recompute()
        #expect(f.model.presentation == .result)
        let again = try #require(f.model.dismissWork)
        #expect(again !== work)
        work.perform()
        #expect(f.model.resultVisible)

        again.perform()
        #expect(!f.model.resultVisible)
    }

    @Test func failedResultsStay() async throws {
        let f = try NotchFixture()
        defer { f.cleanup() }
        f.controller.previewState(phase: .failed, status: "Couldn't find the button")
        let metrics = await TaskMetrics().snapshot()
        f.model.taskFinished(TaskResult(status: .failed, summary: "", error: "Couldn't find the button", plan: nil, metrics: metrics, durationMs: 1))
        #expect(f.model.presentation == .result)
        #expect(f.model.dismissWork == nil)
    }
}

@Suite("Glide job controls")
struct GlideJobControlTests {
    func record(_ status: JobStatus, wake: Date? = nil) -> JobRecord {
        var r = JobRecord(id: "j", title: "J", instruction: "J", status: status, folder: "/tmp/glide-tests/j")
        r.nextWakeAt = wake
        return r
    }

    @Test func onlyRunningJobsOfferPause() {
        // A planning job has no runner yet, so JobCenter.pause has nothing to pause.
        #expect(JobStatus.running.canPause)
        for s in JobStatus.allCases where s != .running { #expect(!s.canPause, "\(s)") }
    }

    @Test func queuedJobsDontOfferRunNow() {
        // Queued behind the concurrency limit: JobCenter.resume ignores it.
        #expect(record(.waiting).isQueued)
        #expect(!record(.waiting).canResume)
        // Sleeping until a time: Run now wakes it.
        #expect(!record(.waiting, wake: Date().addingTimeInterval(600)).isQueued)
        #expect(record(.waiting, wake: Date().addingTimeInterval(600)).canResume)
        for s in [JobStatus.paused, .needsInput, .failed] { #expect(record(s).canResume, "\(s)") }
        for s in [JobStatus.running, .planning, .completed, .stopped, .awaitingConfirmation] { #expect(!record(s).canResume, "\(s)") }
    }
}
