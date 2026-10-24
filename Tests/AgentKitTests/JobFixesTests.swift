import Testing
import Foundation
import Observation
import Synchronization
@testable import AgentKit
@testable import AutomationKit

// Regression tests for job-engine fixes: screen-lease idle detection, the cross-process job
// lock, approvals after Stop, queued waits, retries, write-back, budgets, browser tabs,
// keep-awake and export. Offline like the rest: scripted executors, no models, no UI.

// MARK: - Helpers

/// A gate a scripted step waits on; ignores cancellation, like a step finishing its last call.
final class Latch: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let open = state.withLock { s -> Bool in
                if s.open { return true }
                s.waiters.append(c)
                return false
            }
            if open { c.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// A step executor that sees the callbacks the job runner hands its steps.
final class CallbackExecutor: StepExecuting {
    typealias Handler = @Sendable (StepRequest, AgentCallbacks) async throws -> StepResult
    private let handler: Handler
    private let calls = Mutex<[Int]>([])

    init(_ handler: @escaping Handler) { self.handler = handler }

    /// The step ids executed, in order.
    var stepIDs: [Int] { calls.withLock { $0 } }

    func execute(_ request: StepRequest, callbacks: AgentCallbacks) async throws -> StepResult {
        calls.withLock { $0.append(request.step.id) }
        return try await handler(request, callbacks)
    }
}

@MainActor
@Observable
final class SettingsBox {
    var settings: AppSettings
    init(_ settings: AppSettings) { self.settings = settings }
}

@MainActor
func makeTestCenter(_ fx: JobFixture, plan: JobPlan?, executor: (any StepExecuting)?,
                    settings: @escaping @MainActor () -> AppSettings = { testSettings() },
                    lease: ScreenLease = ScreenLease(idleProbe: { 1000 }), now: @escaping @Sendable () -> Date = { Date() },
                    keepAwake: (@MainActor (Bool) -> Void)? = nil,
                    releaseBrowser: @escaping @Sendable (String) async -> Void = { _ in },
                    scope: JobCenter.Scope = .allJobs, elsewherePollSeconds: Double = 0.05) -> JobCenter {
    let planner: any JobPlanning = plan.map { FixedPlanner(plan: $0) } ?? FailingPlanner()
    var env = JobCenter.Environment(
        store: fx.store, settings: settings, planner: { _ in planner },
        planningContext: { request, s in JobPlanningContext(request: request, settings: s) },
        executor: { _ in executor }, lease: lease, models: { _ in (nil, nil) }, keepAwake: keepAwake,
        removeFolder: { url in try FileManager.default.removeItem(at: url) }, now: now, schedulerMaxSleep: 0.05)
    env.releaseBrowser = releaseBrowser
    env.elsewherePollSeconds = elsewherePollSeconds
    env.scope = scope
    return JobCenter(environment: env)
}

/// Waits for `condition` without letting the main actor run, the way a process exiting would
/// leave a center's main-actor work (the end of its runners) undone. Other threads go on.
@MainActor
func holdingMainActor(timeout: Double = 5, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glide-joblock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Screen lease: whose input is it?

@Suite("ScreenLease idle detection")
struct ScreenLeaseIdleTests {
    /// A tool-only quick task holds the lease but posts no input; the user typing meanwhile is
    /// the user, and a job waiting for them to be idle must keep waiting.
    @Test func userInputDuringAQuickTaskStillCounts() async throws {
        let lastInput = Mutex(Date())
        let lease = ScreenLease(idleProbe: { Date().timeIntervalSince(lastInput.withLock { $0 }) }, lastSyntheticInput: { .distantPast }, pollInterval: 0.01)
        try await lease.acquire(owner: "task", priority: true)
        let granted = Mutex<Date?>(nil)
        let job = Task {
            try await lease.acquire(owner: "job", screenUse: .whenIdle, idleSeconds: 0.6)
            granted.withLock { $0 = Date() }
        }
        let typingUntil = Date().addingTimeInterval(0.3)
        while Date() < typingUntil {
            lastInput.withLock { $0 = Date() }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(400))
        await lease.release(owner: "task")
        try await job.value
        let at = try #require(granted.withLock { $0 })
        // The job got the screen only once the user had really been idle for the full time.
        #expect(at.timeIntervalSince(lastInput.withLock { $0 }) >= 0.55)
        await lease.release(owner: "job")
    }

    /// Glide's own clicks and keystrokes during a step aren't the user coming back.
    @Test func glidesOwnInputIsNotTheUsers() async throws {
        let state = Mutex((input: Date().addingTimeInterval(-1000), post: Date.distantPast))
        let lease = ScreenLease(idleProbe: { Date().timeIntervalSince(state.withLock { $0.input }) },
                                lastSyntheticInput: { state.withLock { $0.post } }, pollInterval: 0.01)
        try await lease.acquire(owner: "job", screenUse: .whenIdle, idleSeconds: 30)
        for _ in 0..<5 {
            let now = Date()
            state.withLock { $0 = (now, now) }
            try await Task.sleep(for: .milliseconds(20))
        }
        await lease.release(owner: "job")
        let started = Date()
        try await lease.acquire(owner: "job", screenUse: .whenIdle, idleSeconds: 30)
        #expect(Date().timeIntervalSince(started) < 1)
        await lease.release(owner: "job")
    }

    /// The user moves the mouse between two of Glide's actions, then Glide acts again (hiding
    /// it from the "last event" time). The next step must still wait for them.
    @Test func userComingBackMidStepIsNoticed() async throws {
        let state = Mutex((input: Date().addingTimeInterval(-1000), post: Date.distantPast))
        let lease = ScreenLease(idleProbe: { Date().timeIntervalSince(state.withLock { $0.input }) },
                                lastSyntheticInput: { state.withLock { $0.post } }, pollInterval: 0.01)
        try await lease.acquire(owner: "job", screenUse: .whenIdle, idleSeconds: 0.6)
        try await Task.sleep(for: .milliseconds(350))
        let userAt = Date()
        state.withLock { $0.input = userAt }
        try await Task.sleep(for: .milliseconds(100))
        let glideAt = Date()
        state.withLock { $0 = (glideAt, glideAt) }
        try await Task.sleep(for: .milliseconds(50))
        await lease.release(owner: "job")
        try await lease.acquire(owner: "job", screenUse: .whenIdle, idleSeconds: 0.6)
        #expect(Date().timeIntervalSince(userAt) >= 0.55)
        await lease.release(owner: "job")
    }
}

// MARK: - One process per job

@Suite("Job run lock")
@MainActor
struct JobRunLockTests {
    @Test func excludesOtherHoldersUntilReleased() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!JobRunLock.isHeld(folder: dir))
        let first = try #require(JobRunLock.tryAcquire(folder: dir))
        #expect(JobRunLock.tryAcquire(folder: dir) == nil)
        #expect(JobRunLock.isHeld(folder: dir))
        first.release()
        #expect(!JobRunLock.isHeld(folder: dir))
        // Dropping the lock (as when its owner goes away) frees it too.
        do { let second = JobRunLock.tryAcquire(folder: dir); #expect(second != nil) }
        #expect(!JobRunLock.isHeld(folder: dir))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")))
    func aCrashedProcessLeavesNoLockBehind() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use Fcntl qw(:flock); $| = 1; open(my $f, '>>', $ARGV[0]) or die; flock($f, LOCK_EX) or die; print \"locked\\n\"; sleep 60;",
                       dir.appendingPathComponent(JobRunLock.fileName).path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        #expect(line.contains("locked"))
        #expect(JobRunLock.isHeld(folder: dir))
        #expect(JobRunLock.tryAcquire(folder: dir) == nil)
        kill(p.processIdentifier, SIGKILL)
        p.waitUntilExit()
        #expect(!JobRunLock.isHeld(folder: dir))
        #expect(JobRunLock.tryAcquire(folder: dir) != nil)
    }

    /// glidectl runs a job when the app launches: the app must neither run it a second time
    /// nor mark it interrupted, and its controls leave it alone.
    @Test func aJobAnotherProcessRunsIsLeftAlone() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Long step"), action(2, "After")])])
        let latch = Latch()
        let executor = ScriptedExecutor { req, _ in
            if req.step.id == 1 { await latch.wait() }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let cli = makeTestCenter(fx, plan: plan, executor: executor)
        let created = await cli.create(instruction: "long job")
        #expect(await eventuallyOnMain { executor.calls.count == 1 })

        let appExecutor = ScriptedExecutor()
        let app = makeTestCenter(fx, plan: plan, executor: appExecutor)
        app.launch()
        #expect(app.isRunningElsewhere(created.id))
        #expect(!app.isRunnerActive(created.id))
        #expect(app.job(created.id)?.statusLine.contains("another Glide process") == true)
        app.resume(created.id)
        app.pause(created.id)
        app.retryFailedItems(created.id)
        app.stop(created.id)
        app.delete(created.id)
        #expect(fx.store.job(created.id)?.status == .running)

        var noResume = testSettings()
        noResume.jobs.autoResume = false
        let manual = makeTestCenter(fx, plan: plan, executor: appExecutor, settings: { noResume })
        manual.launch()
        #expect(fx.store.job(created.id)?.status == .running)
        #expect(fx.store.job(created.id)?.lastError == nil)

        latch.open()
        #expect(await eventuallyOnMain { cli.job(created.id)?.status == .completed && !cli.hasRunner(created.id) })
        // Once the other process lets go, the app shows what it saved.
        #expect(await eventuallyOnMain { app.job(created.id)?.status == .completed && !app.isRunningElsewhere(created.id) })
        #expect(await eventuallyOnMain { manual.job(created.id)?.status == .completed })
        #expect(appExecutor.calls.isEmpty)
        #expect(executor.calls.filter { $0.stepID == 1 }.count == 1)
    }

    /// A process that dies mid-run drops its lock; the app then continues the job like one
    /// interrupted by a quit.
    @Test func aJobLetGoMidRunIsPickedUp() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "A")])])
        let record = fx.record(plan)
        let other = try #require(JobRunLock.tryAcquire(folder: fx.store.folder(for: record.id)))
        let executor = ScriptedExecutor()
        let app = makeTestCenter(fx, plan: plan, executor: executor)
        app.launch()
        #expect(app.isRunningElsewhere(record.id))
        try await Task.sleep(for: .milliseconds(150))
        #expect(executor.calls.isEmpty)
        other.release()
        #expect(await eventuallyOnMain { app.job(record.id)?.status == .completed })
        #expect(app.events(record.id).contains { $0.title.contains("other Glide process quit") })
    }

    /// glidectl shares the app's store but looks after only the job it runs: it doesn't take
    /// over a job the app let go of (the user quit the app), wake the app's sleeping jobs, or
    /// pause them on Ctrl-C.
    @Test func glidectlLeavesTheAppsJobsToTheApp() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        func plan(_ id: Int) -> JobPlan { JobPlan(goal: "g\(id)", milestones: [Milestone(id: 1, title: "m", steps: [action(id, "Step \(id)")])]) }
        // The app is running this one.
        let running = fx.record(plan(1))
        let appLock = try #require(JobRunLock.tryAcquire(folder: fx.store.folder(for: running.id)))
        // And has these two asleep: one due in a moment, one tomorrow.
        var soon = fx.record(plan(2))
        soon.status = .waiting
        soon.nextWakeAt = Date().addingTimeInterval(0.2)
        fx.store.saveJob(soon)
        var later = fx.record(plan(3))
        later.status = .waiting
        later.nextWakeAt = Date().addingTimeInterval(86_400)
        fx.store.saveJob(later)

        let own = JobPlan(goal: "Mine", milestones: [Milestone(id: 1, title: "m", steps: [
            action(5, "My step"), JobStep(id: 6, title: "An hour", kind: .wait(.duration(seconds: 3600))),
        ])])
        let executor = ScriptedExecutor()
        let cli = makeTestCenter(fx, plan: own, executor: executor, scope: .ownJobs)
        cli.reload()
        #expect(cli.isRunningElsewhere(running.id))
        // The sleeping job's time comes while glidectl watches the app's running one.
        try await Task.sleep(for: .milliseconds(500))
        #expect(executor.calls.isEmpty)
        #expect(fx.store.job(soon.id)?.status == .waiting)

        // The user quits the app mid-run: its lock goes, the job stays "running" for the app.
        appLock.release()
        #expect(await eventuallyOnMain { !cli.isRunningElsewhere(running.id) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(executor.calls.isEmpty)
        #expect(fx.store.job(running.id)?.status == .running)
        #expect(fx.store.job(running.id)?.lastError == nil)

        // glidectl's own job still runs, sleeps, and is the only one Ctrl-C pauses.
        let mine = await cli.create(instruction: "mine")
        #expect(await eventuallyOnMain { cli.job(mine.id)?.status == .waiting && !cli.hasRunner(mine.id) })
        cli.haltAll()
        #expect(fx.store.job(mine.id)?.status == .paused)
        #expect(fx.store.job(soon.id)?.status == .waiting)
        #expect(fx.store.job(later.id)?.status == .waiting)
        #expect(fx.store.job(later.id)?.nextWakeAt.map { $0.timeIntervalSinceNow > 80_000 } == true)
        #expect(executor.calls.map(\.stepID) == [5])
    }

    /// glidectl dies mid-run or mid-plan (killed, terminal closed, Ctrl-C while planning) after
    /// the app last looked. Opening the notch reloads the list: those jobs must be picked up
    /// like ones found after a quit, not shown as running (with a Pause that does nothing).
    @Test(arguments: [true, false])
    func reloadPicksUpJobsAnotherProcessLeftBehind(autoResume: Bool) async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "A")])])
        var settings = testSettings()
        settings.jobs.autoResume = autoResume
        let executor = ScriptedExecutor()
        let app = makeTestCenter(fx, plan: plan, executor: executor, settings: { settings })
        app.launch()
        // Saved by the process that died (it held their locks, which went with it).
        let running = fx.record(plan)
        var planning = fx.record(plan)
        planning.plan = nil
        planning.status = .planning
        fx.store.saveJob(planning)

        app.reload()
        #expect(await eventuallyOnMain { app.job(planning.id)?.status == .failed })
        if autoResume {
            #expect(await eventuallyOnMain { app.job(running.id)?.status == .completed })
            #expect(app.events(running.id).contains { $0.title.contains("other Glide process quit") })
        } else {
            #expect(await eventuallyOnMain { app.job(running.id)?.status == .paused })
            #expect(app.job(running.id)?.lastError?.contains("other Glide process") == true)
            #expect(executor.calls.isEmpty)
        }
        #expect(app.activeJob == nil)
    }

    /// The other process lets go and the notch opens before the next look at it: the reload
    /// must not forget the job it was watching.
    @Test func aJobLetGoJustBeforeAReloadIsPickedUp() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "A")])])
        let record = fx.record(plan)
        let other = try #require(JobRunLock.tryAcquire(folder: fx.store.folder(for: record.id)))
        let app = makeTestCenter(fx, plan: plan, executor: ScriptedExecutor(), elsewherePollSeconds: 60)
        app.launch()
        #expect(app.isRunningElsewhere(record.id))
        other.release()
        app.reload()
        #expect(await eventuallyOnMain { app.job(record.id)?.status == .completed })
        #expect(!app.isRunningElsewhere(record.id))
    }

    /// glidectl ran a job until a wait and exited; the app had nothing else asleep. The reload
    /// that shows it must also wake it when it's due.
    @Test func aWaitingJobFoundByAReloadWakes() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [
            JobStep(id: 1, title: "A moment", kind: .wait(.duration(seconds: 3600))), action(2, "After"),
        ])])
        let executor = ScriptedExecutor()
        let app = makeTestCenter(fx, plan: plan, executor: executor)
        app.launch()
        var sleeper = fx.record(plan)
        sleeper.status = .waiting
        sleeper.nextWakeAt = Date().addingTimeInterval(0.2)
        fx.store.saveJob(sleeper)
        app.reload()
        #expect(await eventuallyOnMain { app.job(sleeper.id)?.status == .completed })
        #expect(executor.calls.contains { $0.stepID == 2 })
    }
}

// MARK: - JobCenter fixes

@Suite("JobCenter fixes")
@MainActor
struct JobCenterFixTests {
    /// Stop lands after the runner decided to ask but before the request reached the center.
    @Test func approvalArrivingAfterStopIsAnsweredStop() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Working")])])
        let latch = Latch()
        let executor = ScriptedExecutor { req, _ in
            if req.step.id == 1 { await latch.wait() }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let center = makeTestCenter(fx, plan: plan, executor: executor)
        let created = await center.create(instruction: "x")
        #expect(await eventuallyOnMain { executor.calls.count == 1 })
        center.stop(created.id)
        #expect(center.hasRunner(created.id))
        let answered = Mutex<ApprovalDecision?>(nil)
        let request = ApprovalRequest(kind: .tool, title: "Send it?", detail: "", appName: nil, risk: .high, reasons: [])
        Task { @MainActor in
            let d = await center.enqueueApproval(jobID: created.id, request)
            answered.withLock { $0 = d }
        }
        #expect(await eventuallyOnMain(timeout: 2) { answered.withLock { $0 } == .stop })
        #expect(center.pendingApprovals[created.id] == nil)
        latch.open()
        #expect(await eventuallyOnMain { center.job(created.id)?.status == .stopped && !center.hasRunner(created.id) })
    }

    /// A sleeping job whose wait comes due (or that the user runs now) while every slot is busy
    /// finishes its wait when it gets its turn, instead of sleeping the whole wait again.
    @Test(arguments: [false, true])
    func aWaitThatComesDueWhileQueuedFinishes(runNow: Bool) async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let clock = TestClock(Date(timeIntervalSince1970: 1_900_000_000))
        var settings = testSettings()
        settings.jobs.maxConcurrentJobs = 1
        let sleeperPlan = JobPlan(goal: "Sleeper", milestones: [Milestone(id: 1, title: "m", steps: [
            action(1, "Before"), JobStep(id: 2, title: "An hour", kind: .wait(.duration(seconds: 3600))), action(3, "After"),
        ])])
        var sleeper = fx.record(sleeperPlan)
        sleeper.status = .waiting
        sleeper.cursor.stepIndex = 1
        sleeper.nextWakeAt = clock.now.addingTimeInterval(3600)
        fx.store.saveJob(sleeper)

        let blockerPlan = JobPlan(goal: "Blocker", milestones: [Milestone(id: 1, title: "m", steps: [action(7, "Long")])])
        let latch = Latch()
        let executor = ScriptedExecutor { req, _ in
            if req.step.id == 7 { await latch.wait() }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let center = makeTestCenter(fx, plan: blockerPlan, executor: executor, settings: { settings }, now: clock.function)
        center.launch()
        let blocker = await center.create(instruction: "block")
        #expect(await eventuallyOnMain { executor.calls.count == 1 })

        if runNow {
            center.resume(sleeper.id)
        } else {
            clock.set(clock.now.addingTimeInterval(3601))
        }
        #expect(await eventuallyOnMain { center.job(sleeper.id)?.statusLine.contains("Queued") == true })
        #expect(fx.store.job(sleeper.id)?.nextWakeAt != nil)
        // The UI asks the center: the record alone looks like a job sleeping until a past time.
        #expect(center.isQueued(sleeper.id))
        #expect(!center.isQueued(blocker.id))

        latch.open()
        #expect(await eventuallyOnMain { center.job(blocker.id)?.status == .completed })
        #expect(await eventuallyOnMain { center.job(sleeper.id)?.status == .completed })
        #expect(!center.isQueued(sleeper.id))
        #expect(executor.calls.contains { $0.stepID == 3 })
    }

    /// glidectl resumed a job the app had queued and left it asleep until later. When a slot
    /// frees up the app skips it, and must then wake it at its new time instead of keeping the
    /// queued copy that has no wake time.
    @Test func aQueuedJobPutToSleepElsewhereWakesAtItsTime() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        var settings = testSettings()
        settings.jobs.maxConcurrentJobs = 1
        let blockerPlan = JobPlan(goal: "Blocker", milestones: [Milestone(id: 1, title: "m", steps: [action(7, "Long")])])
        let sleeperPlan = JobPlan(goal: "Sleeper", milestones: [Milestone(id: 1, title: "m", steps: [
            JobStep(id: 1, title: "A while", kind: .wait(.duration(seconds: 3600))), action(2, "After"),
        ])])
        var sleeper = fx.record(sleeperPlan)
        sleeper.status = .paused
        fx.store.saveJob(sleeper)
        let latch = Latch()
        let executor = ScriptedExecutor { req, _ in
            if req.step.id == 7 { await latch.wait() }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let center = makeTestCenter(fx, plan: blockerPlan, executor: executor, settings: { settings })
        center.launch()
        let blocker = await center.create(instruction: "block")
        #expect(await eventuallyOnMain { executor.calls.count == 1 })
        center.resume(sleeper.id)
        #expect(center.isQueued(sleeper.id))

        // Another process ran it meanwhile, into its wait.
        sleeper.status = .waiting
        sleeper.nextWakeAt = Date().addingTimeInterval(1.5)
        sleeper.statusLine = "Waiting until later"
        fx.store.saveJob(sleeper)
        latch.open()
        #expect(await eventuallyOnMain { center.job(blocker.id)?.status == .completed })
        #expect(!center.isQueued(sleeper.id))
        #expect(await eventuallyOnMain { center.job(sleeper.id)?.status == .completed })
        #expect(executor.calls.contains { $0.stepID == 2 })
    }

    /// Opening the notch reloads the list. Jobs this process runs keep the lines their runner
    /// shows but never saves, so a job blocked on the user doesn't look like it's progressing.
    @Test func reloadKeepsWhatRunningJobsShow() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let lease = ScreenLease(idleProbe: { 1000 }, pollInterval: 0.01)
        try await lease.acquire(owner: "task", priority: true)
        let latch = Latch()
        let executor = ScriptedExecutor { req, _ in
            if req.step.id == 1 || req.step.id == 2 { await latch.wait() }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Clicking", route: .gui), action(2, "Thinking")])])
        let center = makeTestCenter(fx, plan: plan, executor: executor, lease: lease)
        let job = await center.create(instruction: "x")
        let waitLine = "Waiting to use the screen…"
        #expect(await eventuallyOnMain { center.job(job.id)?.statusLine == waitLine })
        #expect(fx.store.job(job.id)?.statusLine != waitLine)
        center.reload()
        #expect(center.job(job.id)?.statusLine == waitLine)

        // Once it has the screen, the progress line is back.
        await lease.release(owner: "task")
        #expect(await eventuallyOnMain { executor.calls.count == 1 })
        #expect(await eventuallyOnMain { center.job(job.id)?.statusLine == "Clicking" })

        // "Pausing…" is only in memory too.
        center.pause(job.id)
        center.reload()
        #expect(center.job(job.id)?.statusLine == "Pausing after the current step…")
        latch.open()
        #expect(await eventuallyOnMain { center.job(job.id)?.status == .paused && !center.hasRunner(job.id) })
        #expect(center.job(job.id)?.statusLine == "Paused")
    }

    /// glidectl waits at "Start? [y/N]" holding nothing, and the user stops, deletes, or starts
    /// and finishes the job in the app meanwhile. Answering "y" then shows what happened
    /// instead of a confirmation nothing will act on (glidectl followed that forever).
    @Test(arguments: ["stop", "delete", "finish"])
    func startingAJobChangedElsewhereShowsWhatHappened(change: String) async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "A")])])
        let cliExecutor = ScriptedExecutor()
        let cli = makeTestCenter(fx, plan: plan, executor: cliExecutor, scope: .ownJobs)
        let job = await cli.create(instruction: "x", autoStartIfSmall: false)
        #expect(job.status == .awaitingConfirmation)

        let app = makeTestCenter(fx, plan: plan, executor: ScriptedExecutor())
        app.launch()
        switch change {
        case "stop": app.stop(job.id)
        case "delete": app.delete(job.id)
        default:
            app.start(job.id)
            #expect(await eventuallyOnMain { app.job(job.id)?.status == .completed && !app.hasRunner(job.id) })
        }

        cli.start(job.id)
        #expect(!cli.isRunnerActive(job.id))
        #expect(!cli.isRunningElsewhere(job.id))
        switch change {
        case "stop": #expect(cli.job(job.id)?.status == .stopped)
        case "delete": #expect(cli.job(job.id) == nil)
        default: #expect(cli.job(job.id)?.status == .completed)
        }
        #expect(cliExecutor.calls.isEmpty)
    }

    /// glidectl's Ctrl-C halts the job, and pressed again it quits while the halted step is
    /// still unwinding (a command being ended, a browser call). The job must be left paused:
    /// saved as running, the app would continue it once the exit drops its lock; saved as
    /// stopped (the runner's last save, before the halt makes that a pause), it couldn't be
    /// resumed.
    @Test(arguments: [false, true])
    func quittingWhileAHaltedStepUnwindsLeavesTheJobPaused(runnerSavedItsEnd: Bool) async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Slow to stop"), action(2, "After")])])
        let latch = Latch()
        let executor = ScriptedExecutor { req, _ in
            if req.step.id == 1 { await latch.wait() }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let cli = makeTestCenter(fx, plan: plan, executor: executor, scope: .ownJobs)
        let job = await cli.create(instruction: "long job")
        #expect(await eventuallyOnMain { executor.calls.count == 1 })
        cli.haltAll()
        #expect(cli.isRunnerActive(job.id))
        #expect(fx.store.job(job.id)?.status == .running)
        if runnerSavedItsEnd {
            // The step ends and the runner saves the job as stopped, but the process exits
            // before this center gets to turn that into a pause (a moment later).
            latch.open()
            #expect(holdingMainActor { fx.store.job(job.id)?.status == .stopped })
        }

        cli.saveHaltedForExit()
        let saved = try #require(fx.store.job(job.id))
        #expect(saved.status == .paused)
        #expect(saved.statusLine.contains("resume"))
        // What the app decides when it finds the job after the exit: leave it as it is.
        #expect(JobScheduler.launchActions(for: [saved], autoResume: true).isEmpty)
        // Nothing takes it over while its step still unwinds here. (That the runner's own last
        // save can't undo this is `aDetachedRunnerLeavesTheSavedRecordAlone`.)
        #expect(JobRunLock.isHeld(folder: fx.store.folder(for: job.id)))

        // The process stayed after all: once the runner is done, the job is still paused (and
        // says so once), and resuming it finishes the job.
        latch.open()
        #expect(await eventuallyOnMain { !cli.isRunnerActive(job.id) })
        #expect(fx.store.job(job.id)?.status == .paused)
        #expect(fx.store.events(jobID: job.id).filter { $0.title == "Halted by the emergency stop" }.count == 1)
        cli.resume(job.id)
        #expect(await eventuallyOnMain { cli.job(job.id)?.status == .completed })
        #expect(executor.calls.contains { $0.stepID == 2 })
    }

    /// glidectl ran a sleeping job early and it went back to sleep until later. When the app's
    /// old wake time comes, it must pick up the new one rather than forget the job.
    @Test func aJobPutBackToSleepElsewhereStillWakes() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        let clock = TestClock(t)
        let plan = JobPlan(goal: "Twice", milestones: [Milestone(id: 1, title: "m", steps: [
            JobStep(id: 1, title: "A while", kind: .wait(.duration(seconds: 3600))), action(2, "After"),
        ])])
        var z = fx.record(plan)
        z.status = .waiting
        z.nextWakeAt = t.addingTimeInterval(10)
        fx.store.saveJob(z)
        let executor = ScriptedExecutor()
        let app = makeTestCenter(fx, plan: plan, executor: executor, now: clock.function)
        app.launch()

        // Another process re-slept it meanwhile.
        z.nextWakeAt = t.addingTimeInterval(100)
        fx.store.saveJob(z)
        clock.set(t.addingTimeInterval(11))
        #expect(await eventuallyOnMain { app.job(z.id)?.nextWakeAt == t.addingTimeInterval(100) })
        try await Task.sleep(for: .milliseconds(200))
        #expect(executor.calls.isEmpty)

        clock.set(t.addingTimeInterval(101))
        #expect(await eventuallyOnMain { app.job(z.id)?.status == .completed })
        #expect(executor.calls.contains { $0.stepID == 2 })
    }

    /// "Retry failed items" while the job sleeps in a 24-hour wait 22 hours in: after the loop is
    /// redone the job finishes the wait it was in, instead of sleeping another full day.
    @Test func retryingKeepsTheWaitItWasSleepingIn() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let t = Date(timeIntervalSince1970: 1_900_000_000)
        let clock = TestClock(t)
        let plan = JobPlan(goal: "Research, wait, follow up", milestones: [Milestone(id: 1, title: "m", steps: [
            listLoop(["ok", "bad"]), JobStep(id: 2, title: "A day", kind: .wait(.duration(seconds: 86_400))), action(3, "Following up"),
        ])])
        let failBad = Mutex(true)
        let store = fx.store
        let executor = ScriptedExecutor { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            if let id = req.itemID, store.item(id)?.title == "bad", failBad.withLock({ $0 }) { return StepResult(status: .failed("blocked by site")) }
            return StepResult(status: .done, fields: ["answer": "y"])
        }
        let center = makeTestCenter(fx, plan: plan, executor: executor, now: clock.function)
        let job = await center.create(instruction: "research")
        #expect(await eventuallyOnMain { center.job(job.id)?.status == .waiting && !center.hasRunner(job.id) })
        let due = t.addingTimeInterval(86_400)
        #expect(fx.store.job(job.id)?.nextWakeAt == due)
        #expect(fx.store.job(job.id)?.usage.itemsFailed == 1)

        clock.set(t.addingTimeInterval(80_000))
        failBad.withLock { $0 = false }
        center.retryFailedItems(job.id)
        #expect(await eventuallyOnMain {
            center.job(job.id)?.status == .waiting && !center.hasRunner(job.id) && center.job(job.id)?.usage.itemsFailed == 0
        })
        #expect(fx.store.job(job.id)?.nextWakeAt == due)
        #expect(!executor.calls.contains { $0.stepID == 3 })

        clock.set(due.addingTimeInterval(1))
        #expect(await eventuallyOnMain { center.job(job.id)?.status == .completed })
        #expect(executor.calls.filter { $0.stepID == 3 }.count == 1)
    }

    /// "Retry failed" redoes the loop's failed items, then goes back to where the job was:
    /// the approval-gated send after the loop isn't done again.
    @Test func retryingFailedItemsDoesNotRedoLaterSteps() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "Research then send", milestones: [
            Milestone(id: 1, title: "Research", steps: [listLoop(["ok", "bad"])]),
            Milestone(id: 2, title: "Send the results", steps: [action(2, "Emailing the results to the team")], requiresApproval: true),
        ])
        let failBad = Mutex(true)
        let store = fx.store
        let executor = ScriptedExecutor { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            if let id = req.itemID, store.item(id)?.title == "bad", failBad.withLock({ $0 }) { return StepResult(status: .failed("blocked by site")) }
            return StepResult(status: .done, fields: ["answer": "y"])
        }
        let center = makeTestCenter(fx, plan: plan, executor: executor)
        let created = await center.create(instruction: "research and send")
        #expect(await eventuallyOnMain { center.pendingApprovals[created.id] != nil })
        center.respond(jobID: created.id, decision: .approve)
        #expect(await eventuallyOnMain { center.job(created.id)?.status == .completed && !center.hasRunner(created.id) })
        #expect(center.job(created.id)?.usage.itemsFailed == 1)

        failBad.withLock { $0 = false }
        center.retryFailedItems(created.id)
        #expect(await eventuallyOnMain {
            center.job(created.id)?.status == .completed && !center.hasRunner(created.id) && center.job(created.id)?.usage.itemsFailed == 0
        })
        #expect(executor.calls.filter { $0.stepID == 2 && $0.itemID == nil }.count == 1)
        #expect(center.pendingApprovals.isEmpty)
        // The report is written again with the new results.
        #expect(executor.calls.filter { $0.stepID == 20_000 }.count == 2)
        #expect(center.job(created.id)?.cursor.milestoneIndex == 2)
        #expect(fx.store.state(jobID: created.id, key: JobRunner.RetryReturn.stateKey) == nil)
    }

    @Test func stoppingOrDeletingAJobWithoutARunnerClosesItsTabs() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [JobStep(id: 1, title: "Long wait", kind: .wait(.duration(seconds: 3600)))])])
        let released = Mutex<[String]>([])
        let center = makeTestCenter(fx, plan: plan, executor: ScriptedExecutor(), releaseBrowser: { id in released.withLock { $0.append(id) } })
        let a = await center.create(instruction: "a")
        #expect(await eventuallyOnMain { center.job(a.id)?.status == .waiting && !center.hasRunner(a.id) })
        center.stop(a.id)
        #expect(await eventually { released.withLock { $0 }.contains(a.id) })
        let b = await center.create(instruction: "b")
        #expect(await eventuallyOnMain { center.job(b.id)?.status == .waiting && !center.hasRunner(b.id) })
        center.delete(b.id)
        #expect(await eventually { released.withLock { $0 }.contains(b.id) })
    }

    @Test func keepAwakeFollowsTheSettingWhileJobsRun() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        var initial = testSettings()
        initial.jobs.keepAwake = true
        let box = SettingsBox(initial)
        let latch = Latch()
        let executor = ScriptedExecutor { req, _ in
            if req.step.id == 1 { await latch.wait() }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let awake = Mutex<[Bool]>([])
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Long")])])
        let center = makeTestCenter(fx, plan: plan, executor: executor, settings: { box.settings },
                                    keepAwake: { on in awake.withLock { $0.append(on) } })
        let job = await center.create(instruction: "long")
        #expect(await eventuallyOnMain { executor.calls.count == 1 })
        #expect(awake.withLock { $0.last } == true)
        // The runner is blocked mid-step, so only the setting itself can change this.
        box.settings.jobs.keepAwake = false
        #expect(await eventuallyOnMain { awake.withLock { $0.last } == false })
        box.settings.jobs.keepAwake = true
        #expect(await eventuallyOnMain { awake.withLock { $0.last } == true })
        latch.open()
        #expect(await eventuallyOnMain { center.job(job.id)?.status == .completed && !center.hasRunner(job.id) })
        #expect(awake.withLock { $0.last } == false)
    }

    @Test func exportNeverOverwritesOtherFiles() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [
            listLoop(["A", "B"], table: "leads", id: 1), listLoop(["C"], table: "companies", id: 2),
        ])])
        let executor = ScriptedExecutor { req, _ in ScriptedExecutor.standard(req) ?? StepResult(status: .done, fields: ["answer": "x"]) }
        let center = makeTestCenter(fx, plan: plan, executor: executor)
        let job = await center.create(instruction: "x")
        #expect(await eventuallyOnMain { center.job(job.id)?.status == .completed })

        let out = fx.root.appendingPathComponent("report.csv")
        let mine = fx.root.appendingPathComponent("report-companies.csv")
        try "my own file\n".write(to: mine, atomically: true, encoding: .utf8)
        let files = try center.exportResultFiles(job.id, to: out)
        #expect(try String(contentsOf: mine, encoding: .utf8) == "my own file\n")
        #expect(files.map(\.lastPathComponent) == ["report.csv", "report-companies 2.csv"])
        #expect(try TableIO.readCSV(files[1].path, hasHeader: true).rows.map { $0[0] } == ["C"])
        #expect(try TableIO.readCSV(out.path, hasHeader: true).rows.map { $0[0] } == ["A", "B"])
        // Exporting again keeps the first export's extra file too.
        #expect(try center.exportResultFiles(job.id, to: out).last?.lastPathComponent == "report-companies 3.csv")
        // The UI's entry point writes the same files.
        try center.exportResults(job.id, to: fx.root.appendingPathComponent("other.csv"))
        #expect(FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("other-companies.csv").path))
        // Two tables whose names map to the same file name don't overwrite each other.
        let taken = [fx.root.appendingPathComponent("x-a_b.csv")]
        #expect(JobCenter.unusedExportURL(in: fx.root, name: "x-a_b", besides: taken).lastPathComponent == "x-a_b 2.csv")
    }
}

// MARK: - JobRunner fixes

@Suite("JobRunner fixes")
struct JobRunnerFixTests {
    /// Waiting for the screen (behind a quick task, or for the user to step away) isn't work.
    @Test func waitingForTheScreenIsNotWorkTime() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Clicking", route: .gui), action(2, "Then this")])])
        let lease = ScreenLease(idleProbe: { 1000 }, pollInterval: 0.01)
        try await lease.acquire(owner: "task", priority: true)
        let record = fx.record(plan, budget: JobBudget(maxCostUSD: nil, maxDurationSeconds: 0.5, maxModelCalls: nil))
        let runner = fx.runner(record, ScriptedExecutor(), lease: lease)
        let task = Task { await runner.run() }
        #expect(await eventually { await lease.queueLength == 1 })
        try await Task.sleep(for: .milliseconds(800))
        await lease.release(owner: "task")
        let final = await task.value
        #expect(final.status == .completed)
        #expect(final.usage.activeSeconds < 0.5)
    }

    /// An on-screen step that gives the screen up while the user works can wait for hours;
    /// that isn't work either, and the job says why nothing moves meanwhile.
    @Test func waitingForTheUserInsideAStepIsNotWorkTime() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Clicking", route: .gui), action(2, "Then this")])])
        let executor = CallbackExecutor { req, callbacks in
            if req.step.id == 1 {
                await callbacks.waitingForUser(true)
                try await Task.sleep(for: .milliseconds(800))
                await callbacks.waitingForUser(false)
            }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let lines = Mutex<[String]>([])
        let record = fx.record(plan, budget: JobBudget(maxCostUSD: nil, maxDurationSeconds: 0.5, maxModelCalls: nil))
        let final = await fx.runner(record, executor, callbacks: JobRunner.Callbacks(update: { r in lines.withLock { $0.append(r.statusLine) } })).run()
        #expect(final.status == .completed)
        #expect(final.usage.activeSeconds < 0.5)
        let shown = lines.withLock { $0 }
        let waitIndex = try #require(shown.firstIndex(of: "Waiting for you to let go of the mouse…"))
        #expect(shown.dropFirst(waitIndex + 1).first == "Clicking", "the progress line comes back once the step carries on")
    }

    /// Pausing a job whose step gave the screen up to wait for the user ends the wait: the job
    /// pauses and never takes the screen back, even once the user walks away. Resuming runs the
    /// step again from a fresh look at the screen.
    @Test(arguments: [false, true])
    func pausingWhileAStepWaitsForTheUserPausesTheJob(behindAQuickTask: Bool) async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Clicking", route: .gui), action(2, "Then this")])])
        let lease = ScreenLease(idleProbe: { 1000 }, pollInterval: 0.01)
        let idle = Box(0.0)
        let waitFor = Box(true)
        // What GUIStepRunner does when the user takes over: wait with the job's own watch.
        let executor = CallbackExecutor { req, callbacks in
            if req.step.id == 1, waitFor.value, let jobID = req.jobID {
                let watch = UserTakeoverWatch(monitor: FakeInputMonitor(), idleSeconds: 5, idleProbe: { idle.value }, lease: lease,
                                              leaseOwner: UserTakeoverWatch.leaseOwner(jobID: jobID), pollInterval: 0.01)
                watch.noteUserInput()
                _ = try await watch.waitForIdleUser(gate: ExecutionGate(), interrupted: callbacks.jobInterrupted)
            }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let record = fx.record(plan)
        let runner = fx.runner(record, executor, lease: lease)
        let ended = Box(false)
        let task = Task {
            defer { ended.value = true }
            return await runner.run()
        }
        #expect(await eventually { executor.stepIDs.count == 1 })
        #expect(await eventually { await lease.currentHolder == nil }, "the step gave the screen up")
        if behindAQuickTask {
            // The user went idle with a quick task running; the step queues for the screen.
            try await lease.acquire(owner: "task", priority: true)
            idle.value = 10
            #expect(await eventually { await lease.queueLength == 1 })
        }
        runner.pause()
        #expect(await eventually(timeout: 3) { ended.value }, "the pause ends the wait")
        #expect(await lease.queueLength == 0)
        if behindAQuickTask {
            #expect(await lease.currentHolder == "task")
            await lease.release(owner: "task")
        }
        // The user walks away: nothing takes the screen.
        idle.value = 10
        let final = await task.value
        #expect(final.status == .paused)
        #expect(final.statusLine == "Paused")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await lease.currentHolder == nil)
        #expect(executor.stepIDs == [1])

        waitFor.value = false
        let resumed = try await fx.resumeRunner(record.id, executor).run()
        #expect(resumed.status == .completed)
        #expect(executor.stepIDs.filter { $0 == 1 }.count == 2)
    }

    /// Once its owner has saved the job for an exit, a runner still ending its run saves
    /// nothing more (nor reports a save), so the record the owner saved stands.
    @Test func aDetachedRunnerLeavesTheSavedRecordAlone() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Slow to stop"), action(2, "After")])])
        let latch = Latch()
        let executor = ScriptedExecutor { req, _ in
            if req.step.id == 1 { await latch.wait() }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let updates = Mutex(0)
        let runner = fx.runner(fx.record(plan), executor, callbacks: JobRunner.Callbacks(update: { _ in updates.withLock { $0 += 1 } }))
        let task = Task { await runner.run() }
        #expect(await eventually { executor.calls.count == 1 })
        runner.detachFromStore()
        var saved = try #require(fx.store.job(runner.jobID))
        JobCenter.markHalted(&saved)
        fx.store.saveJob(saved)
        let reported = updates.withLock { $0 }
        runner.stop()
        latch.open()
        let final = await task.value
        #expect(final.status == .stopped)
        let stored = try #require(fx.store.job(runner.jobID))
        #expect(stored.status == .paused)
        #expect(stored.statusLine == saved.statusLine)
        #expect(updates.withLock { $0 } == reported)
    }

    /// Updaters read the first row as column names, so a headerless source file is left as it
    /// is and the results stay in the job.
    @Test func doesNotWriteIntoAHeaderlessSourceFile() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let original = "Acme\nGlobex\nInitech\n"
        let path = try fx.writeFile("names.csv", original)
        let spec = ForEachSpec(source: .file(path: path, sheet: nil, column: nil, hasHeader: false), itemLabel: "company",
                               recipe: [RecipeStep(id: 1, title: "Shouting", instruction: "Uppercase the name", route: .web, outputFields: ["shout"])],
                               outputTable: "companies", outputColumns: ["shout"], writeBack: WriteBack(path: path, columns: ["shout"]))
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [JobStep(id: 1, title: "Shouting names", kind: .forEach(spec))])])
        let asked = Mutex(0)
        let executor = ScriptedExecutor { req, _ in ScriptedExecutor.standard(req) ?? StepResult(status: .done, fields: ["shout": "LOUD"]) }
        let record = fx.record(plan)
        let final = await fx.runner(record, executor, callbacks: JobRunner.Callbacks(approve: { _ in asked.withLock { $0 += 1 }; return .approve })).run()
        #expect(final.status == .completed)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
        #expect(asked.withLock { $0 } == 0)
        #expect(fx.store.rows(jobID: record.id, table: "companies").count == 3)
        #expect(fx.store.events(jobID: record.id).contains { $0.title.contains("stay in the job") })
    }

    /// Writing back into the source file without naming a sheet goes to the source's sheet,
    /// not the first one; a write-back into another file keeps its own (unnamed) sheet.
    @Test func writesBackIntoTheSheetTheItemsCameFrom() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        // Never created: reads and writes are injected.
        let path = fx.root.appendingPathComponent("leads.xlsx").path
        let other = fx.root.appendingPathComponent("out.xlsx").path
        let reader: TableIO.Reader = { _, sheet, _ in
            TableData(columns: ["Name"], rows: sheet == "Leads" ? [["Ada"], ["Bob"]] : [["wrong sheet"]])
        }
        let writes = Mutex<[(path: String, sheet: String?)]>([])
        let updater: TableIO.Updater = { path, sheet, _, _, _ in writes.withLock { $0.append((path, sheet)) } }
        func loop(_ id: Int, into target: String) -> JobStep {
            JobStep(id: id, title: "Finding emails \(id)", kind: .forEach(ForEachSpec(
                source: .file(path: path, sheet: "Leads", column: "Name", hasHeader: true), itemLabel: "lead",
                recipe: [RecipeStep(id: 1, title: "Finding email", instruction: "Find the email", route: .web, outputFields: ["email"])],
                outputTable: "leads\(id)", outputColumns: ["email"], writeBack: WriteBack(path: target, columns: ["email"]))))
        }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [loop(1, into: path), loop(2, into: other)])])
        let executor = ScriptedExecutor { req, _ in ScriptedExecutor.standard(req) ?? StepResult(status: .done, fields: ["email": "a@b.c"]) }
        let final = await fx.runner(fx.record(plan), executor, configuration: JobRunner.Configuration(tableReader: reader, tableUpdater: updater)).run()
        #expect(final.status == .completed)
        let done = writes.withLock { $0 }
        #expect(done.contains { $0.path == path })
        #expect(done.filter { $0.path == path }.allSatisfy { $0.sheet == "Leads" })
        #expect(done.contains { $0.path == other })
        #expect(done.filter { $0.path == other }.allSatisfy { $0.sheet == nil })
    }
}
