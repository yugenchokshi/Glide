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
        controller = TaskController(runtime: AutomationRuntime(), settingsStore: store)
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

        // Covered by the task field when the timer fires: the card stays and re-arms later.
        f.model.inputOpen = true
        f.model.recompute()
        work.perform()
        #expect(f.model.attentionJobID == "d")
        #expect(f.model.jobDismissWork == nil)
        f.model.inputOpen = false
        f.model.recompute()
        #expect(f.model.presentation == .job)
        let again = try #require(f.model.jobDismissWork)

        // On screen when it fires: the card folds away.
        again.perform()
        #expect(f.model.attentionJobID == nil)
        #expect(f.model.presentation != .job)
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
        work.perform()
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
