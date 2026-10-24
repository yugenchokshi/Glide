import Testing
import Foundation
import Synchronization
@testable import AgentKit
@testable import AutomationKit

// Offline tests for the job engine: a scripted executor stands in for the step runners and a
// fixed plan for the planning model, so nothing here calls a model, the network or the UI.

// MARK: - Fixtures

/// A temporary database and jobs folder, removed by `cleanup()`.
struct JobFixture {
    let root: URL
    let store: JobStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("glide-jobtests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try JobStore(path: root.appendingPathComponent("jobs.sqlite").path, jobsRoot: root.appendingPathComponent("Jobs", isDirectory: true))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// A saved, ready-to-run record for `plan`.
    func record(_ plan: JobPlan, budget: JobBudget = JobBudget(), id: String = UUID().uuidString) -> JobRecord {
        var r = JobRecord(id: id, title: plan.goal, instruction: plan.goal, status: .running, folder: store.ensureFolder(for: id).path, budget: budget)
        r.plan = plan
        store.saveJob(r)
        return r
    }

    func writeFile(_ name: String, _ text: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func runner(_ record: JobRecord, _ executor: any StepExecuting, settings: AppSettings = testSettings(), lease: ScreenLease = ScreenLease(idleProbe: { 1000 }),
                callbacks: JobRunner.Callbacks = JobRunner.Callbacks(), configuration: JobRunner.Configuration = JobRunner.Configuration()) -> JobRunner {
        JobRunner(record: record, store: store, executor: executor, lease: lease, settings: settings, callbacks: callbacks, configuration: configuration)
    }

    /// Resumes a job from what's persisted, the way the app does after a restart.
    func resumeRunner(_ id: String, _ executor: any StepExecuting, configuration: JobRunner.Configuration = JobRunner.Configuration(),
                      callbacks: JobRunner.Callbacks = JobRunner.Callbacks()) throws -> JobRunner {
        let r = try #require(store.job(id))
        return runner(r, executor, callbacks: callbacks, configuration: configuration)
    }
}

func testSettings() -> AppSettings {
    var s = AppSettings()
    s.jobs.screenUse = .always
    s.jobs.keepAwake = false
    s.jobs.notifications = false
    return s
}

/// Answers step requests from a script and records every call.
final class ScriptedExecutor: StepExecuting {
    typealias Handler = @Sendable (StepRequest, Int) async throws -> StepResult

    struct Call: Sendable {
        var stepID: Int
        var title: String
        var itemID: String?
        var context: String
        var route: ExecutionRoute
    }

    private struct State {
        var calls: [Call] = []
        var inFlight = 0
        var maxInFlight = 0
    }

    private let state = Mutex(State())
    private let handler: Handler

    init(_ handler: @escaping Handler = { req, _ in ScriptedExecutor.standard(req) ?? StepResult(status: .done, output: "ok", modelCalls: 1) }) {
        self.handler = handler
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    /// Calls that worked on items (not reports or checks), as item ids.
    var itemCalls: [String] { calls.compactMap(\.itemID) }

    func execute(_ request: StepRequest, callbacks: AgentCallbacks) async throws -> StepResult {
        let n = state.withLock { s -> Int in
            s.calls.append(Call(stepID: request.step.id, title: request.step.title, itemID: request.itemID, context: request.context, route: request.step.route))
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
            return s.calls.count
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        return try await handler(request, n)
    }

    /// Default answers for the engine's own requests: the report and milestone checks.
    static func standard(_ req: StepRequest) -> StepResult? {
        switch req.step.id {
        case 20_000: return StepResult(status: .done, output: "Report", fields: ["summary": "All done: the report."], modelCalls: 1)
        case 10_000..<20_000: return StepResult(status: .done, fields: ["done": true, "reason": "complete"], modelCalls: 1)
        default: return nil
        }
    }
}

func eventually(timeout: Double = 8, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor
func eventuallyOnMain(timeout: Double = 8, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

func listLoop(_ items: [String], parallelism: Int = 1, table: String = "results", recipe: [RecipeStep]? = nil, id: Int = 1) -> JobStep {
    JobStep(id: id, title: "Working through items", kind: .forEach(ForEachSpec(
        source: .list(items), itemLabel: "item",
        recipe: recipe ?? [RecipeStep(id: 1, title: "Look it up", instruction: "Look up the item", route: .web, outputFields: ["answer"])],
        parallelism: parallelism, outputTable: table, outputColumns: ["answer"])))
}

func action(_ id: Int, _ title: String, route: ExecutionRoute = .command, fields: [String] = []) -> JobStep {
    JobStep(id: id, title: title, kind: .action(RecipeStep(id: id, title: title, instruction: "Do: \(title)", route: route, outputFields: fields)))
}

/// Mutable clock for tests that simulate days passing.
final class TestClock: Sendable {
    private let date: Mutex<Date>
    init(_ start: Date) { date = Mutex(start) }
    var now: Date { date.withLock { $0 } }
    func set(_ d: Date) { date.withLock { $0 = d } }
    var function: @Sendable () -> Date { { [self] in self.now } }
}

// MARK: - Loops

@Suite("JobEngine loops")
struct JobLoopTests {
    @Test func forEachOverCSVWithWriteBackAndParallelism() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        var csv = "Company,Country\n"
        for i in 1...25 { csv += "Co \(i),\(i % 2 == 0 ? "US" : "DE")\n" }
        let path = try fx.writeFile("companies.csv", csv)
        let spec = ForEachSpec(
            source: .file(path: path, sheet: nil, column: "Company", hasHeader: true), itemLabel: "company",
            recipe: [RecipeStep(id: 1, title: "Finding the website", instruction: "Find the website", route: .web, outputFields: ["website"]),
                     RecipeStep(id: 2, title: "Finding the CEO", instruction: "Find the CEO", route: .web, outputFields: ["ceo"])],
            parallelism: 4, outputTable: "companies", outputColumns: ["website", "ceo"],
            writeBack: WriteBack(path: path, keyColumn: "Company", columns: ["website", "ceo"]))
        let plan = JobPlan(goal: "Research companies", milestones: [Milestone(id: 1, title: "Research", steps: [JobStep(id: 1, title: "Researching companies", kind: .forEach(spec))])])
        let store = fx.store
        let executor = ScriptedExecutor { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            try await Task.sleep(for: .milliseconds(15))
            let item = try #require(store.item(req.itemID ?? ""))
            let name = item.input["Company"]?.stringValue ?? "?"
            let n = name.replacingOccurrences(of: "Co ", with: "")
            let fields: [String: JSONValue] = req.step.id == 1 ? ["website": .string("https://co\(n).example")] : ["ceo": .string("CEO \(n)")]
            return StepResult(status: .done, output: "found", fields: fields, actions: 1, modelCalls: 1, usage: LLMUsage(inputTokens: 100, outputTokens: 10))
        }
        let usesFallback = TableIO.updater == nil
        let asked = Mutex<[ApprovalRequest]>([])
        let approve = JobRunner.Callbacks(approve: { req in asked.withLock { $0.append(req) }; return .approve })
        let final = await fx.runner(fx.record(plan), executor, callbacks: approve).run()
        // Changing the user's existing file is asked once, up front.
        #expect(asked.withLock { $0.count } == 1)
        #expect(asked.withLock { $0.first?.title } == "Write results into companies.csv?")
        #expect(asked.withLock { $0.first?.risk } == .high)

        #expect(final.status == .completed)
        #expect(final.usage.itemsTotal == 25)
        #expect(final.usage.itemsDone == 25)
        #expect(final.usage.itemsFailed == 0)
        #expect(final.usage.modelCalls == 51) // 25 × 2 recipe steps + the report
        #expect(final.usage.inputTokens == 5000)
        #expect(final.usage.toolCalls == 50)
        #expect(final.progressFraction == 1)
        #expect(executor.maxInFlight <= 4)
        #expect(executor.maxInFlight >= 2)
        // Results table, in source order despite parallel work.
        let rows = fx.store.rows(jobID: final.id, table: "companies")
        #expect(rows.count == 25)
        #expect(rows.first?.key == "Co 1")
        #expect(rows.last?.key == "Co 25")
        #expect(rows[6].fields["website"]?.stringValue == "https://co7.example")
        #expect(rows[6].fields["ceo"]?.stringValue == "CEO 7")
        // Write-back filled the new columns of the user's file, kept the rest, and left a backup.
        let updated = try TableIO.readCSV(path, hasHeader: true)
        #expect(Array(updated.columns.prefix(2)) == ["Company", "Country"])
        #expect(Set(updated.columns) == ["Company", "Country", "website", "ceo"])
        if usesFallback { #expect(updated.columns == ["Company", "Country", "website", "ceo"]) }
        #expect(updated.rows.count == 25)
        for (i, row) in updated.records.enumerated() {
            #expect(row["Company"] == "Co \(i + 1)")
            #expect(row["website"] == "https://co\(i + 1).example")
            #expect(row["ceo"] == "CEO \(i + 1)")
        }
        if usesFallback { #expect(FileManager.default.fileExists(atPath: path + ".bak")) }
        // Report written to the job folder.
        let report = try String(contentsOfFile: final.folder + "/report.md", encoding: .utf8)
        #expect(report.contains("All done: the report."))
        #expect(final.summary == "All done: the report.")
        // Each item request carried the item's data.
        #expect(executor.calls.first { $0.itemID != nil }?.context.contains("Item data:") == true)
    }

    @Test func decliningWriteBackKeepsResultsInTheJob() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let original = "Name\nAda\nBob\n"
        let path = try fx.writeFile("people.csv", original)
        let spec = ForEachSpec(source: .file(path: path, sheet: nil, column: "Name", hasHeader: true), itemLabel: "person",
                               recipe: [RecipeStep(id: 1, title: "Finding email", instruction: "Find the email", route: .web, outputFields: ["email"])],
                               parallelism: 2, outputTable: "people", outputColumns: ["email"], writeBack: WriteBack(path: path, keyColumn: "Name", columns: ["email"]))
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [JobStep(id: 1, title: "Finding emails", kind: .forEach(spec))])])
        let executor = ScriptedExecutor { req, _ in ScriptedExecutor.standard(req) ?? StepResult(status: .done, fields: ["email": "x@y.z"]) }
        let record = fx.record(plan)
        let final = await fx.runner(record, executor, callbacks: JobRunner.Callbacks(approve: { _ in .reject })).run()
        #expect(final.status == .completed)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
        #expect(fx.store.rows(jobID: record.id, table: "people").count == 2)
        #expect(fx.store.state(jobID: record.id, key: "writeBack:1") == "declined")
    }

    @Test func resumesAfterACrashWithoutRedoingFinishedItems() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let items = (1...25).map { "Item \($0)" }
        let plan = JobPlan(goal: "Look up items", milestones: [Milestone(id: 1, title: "Look up", steps: [listLoop(items, parallelism: 2)])])
        let record = fx.record(plan)
        // First run: 10 calls answer, then everything hangs (the "crash" happens mid-loop).
        let first = ScriptedExecutor { req, n in
            if n > 10 { try await Task.sleep(for: .seconds(60)) }
            return StepResult(status: .done, fields: ["answer": .string(req.itemID ?? "")], modelCalls: 1)
        }
        let runner = fx.runner(record, first)
        let task = Task { await runner.run() }
        let store = fx.store
        #expect(await eventually { store.itemCounts(jobID: record.id)[.done] == 10 && store.itemCounts(jobID: record.id)[.running] == 2 })
        // Snapshot the database as a crash would leave it (status running, items running).
        let crashedRecord = try #require(fx.store.job(record.id))
        let crashedItems = fx.store.items(jobID: record.id)
        let doneIDs = Set(crashedItems.filter { $0.status == .done }.map(\.id))
        #expect(crashedRecord.status == .running)
        task.cancel()
        _ = await task.value
        fx.store.saveJob(crashedRecord)
        fx.store.insertItems(crashedItems)

        let second = ScriptedExecutor { req, _ in
            ScriptedExecutor.standard(req) ?? StepResult(status: .done, fields: ["answer": .string(req.itemID ?? "")], modelCalls: 1)
        }
        let final = await (try fx.resumeRunner(record.id, second)).run()
        #expect(final.status == .completed)
        #expect(final.usage.itemsDone == 25)
        #expect(Set(second.itemCalls).isDisjoint(with: doneIDs))
        #expect(second.itemCalls.count == 15)
        #expect(Set(second.itemCalls).count == 15)
        #expect(fx.store.rows(jobID: record.id, table: "results").count == 25)
        #expect(fx.store.items(jobID: record.id).allSatisfy { $0.status == .done })
    }

    @Test func retriesItemsAndRecordsFailures() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [listLoop(["A", "B", "C", "D"])])])
        let record = fx.record(plan, budget: JobBudget(maxItemAttempts: 2, maxFailureRate: 1.0))
        let store = fx.store
        let executor = ScriptedExecutor { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            let item = try #require(store.item(req.itemID ?? ""))
            if item.title == "C" || (item.title == "B" && item.attempts == 1) {
                return StepResult(status: .failed("no luck for \(item.title)"), modelCalls: 1)
            }
            return StepResult(status: .done, fields: ["answer": .string(item.title.lowercased())], modelCalls: 1)
        }
        let final = await fx.runner(record, executor).run()
        #expect(final.status == .completed)
        #expect(final.usage.itemsDone == 3)
        #expect(final.usage.itemsFailed == 1)
        let byTitle = Dictionary(uniqueKeysWithValues: fx.store.items(jobID: record.id).map { ($0.title, $0) })
        #expect(byTitle["B"]?.status == .done)
        #expect(byTitle["B"]?.attempts == 2)
        #expect(byTitle["C"]?.status == .failed)
        #expect(byTitle["C"]?.attempts == 2)
        #expect(byTitle["C"]?.error?.contains("no luck for C") == true)
        #expect(executor.itemCalls.count == 6) // A, B, C, D, then B and C again
        // A retry is told what went wrong before.
        #expect(executor.calls.last { $0.itemID == byTitle["C"]?.id }?.context.contains("A previous attempt failed") == true)
    }

    @Test func pausesWhenTooManyItemsFailAndContinuesOnResume() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let titles = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [listLoop(titles)])])
        let record = fx.record(plan, budget: JobBudget(maxItemAttempts: 1, maxFailureRate: 0.3))
        let store = fx.store
        let handler: ScriptedExecutor.Handler = { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            let item = try #require(store.item(req.itemID ?? ""))
            return ["B", "D"].contains(item.title) ? StepResult(status: .failed("site down")) : StepResult(status: .done, fields: ["answer": "ok"])
        }
        let paused = await fx.runner(record, ScriptedExecutor(handler)).run()
        #expect(paused.status == .needsInput)
        #expect(paused.lastError?.contains("2 of the last 5") == true)
        #expect(paused.lastError?.contains("site down") == true)
        #expect(paused.usage.itemsDone == 3)
        #expect(paused.usage.itemsFailed == 2)

        let resumed = await (try fx.resumeRunner(record.id, ScriptedExecutor(handler))).run()
        #expect(resumed.status == .completed)
        #expect(resumed.usage.itemsDone == 8)
        #expect(resumed.usage.itemsFailed == 2)
    }

    @Test func detectsBeingStuck() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [listLoop(["A", "B", "C", "D", "E", "F"])])])
        let record = fx.record(plan, budget: JobBudget(maxItemAttempts: 50, stuckTurns: 4, maxFailureRate: 1.0))
        let executor = ScriptedExecutor { _, _ in StepResult(status: .failed("nothing works"), modelCalls: 1) }
        let final = await fx.runner(record, executor).run()
        #expect(final.status == .needsInput)
        #expect(final.statusLine.contains("stuck"))
        #expect(executor.calls.count == 4)
    }

    @Test func loopsOverAnEarlierStepsListOutput() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let loop = JobStep(id: 2, title: "Visiting pages", kind: .forEach(ForEachSpec(
            source: .stepOutput(stepID: 1), itemLabel: "page",
            recipe: [RecipeStep(id: 1, title: "Reading", instruction: "Read the page", route: .web, outputFields: ["title"])], parallelism: 3, outputTable: "pages")))
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Finding pages", route: .web, fields: ["items"]), loop])])
        let record = fx.record(plan)
        let executor = ScriptedExecutor { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            if req.itemID == nil {
                return StepResult(status: .done, output: "3 pages", fields: ["items": [["url": "https://a.example", "name": "Alpha"], ["url": "https://b.example", "name": "Beta"], "https://c.example"]])
            }
            return StepResult(status: .done, fields: ["title": "T"])
        }
        let final = await fx.runner(record, executor).run()
        #expect(final.status == .completed)
        let titles = fx.store.items(jobID: record.id, stepID: 2).map(\.title)
        #expect(titles == ["Alpha", "Beta", "https://c.example"])
        #expect(fx.store.rows(jobID: record.id, table: "pages").count == 3)
        // The action's output is in memory as a fact and a row.
        #expect(fx.store.facts(jobID: record.id).contains { $0.key == "step:1" && $0.value == "3 pages" })
        #expect(fx.store.row(jobID: record.id, table: "steps", key: "1") != nil)
    }
}

// MARK: - Waits, budgets, approvals, control

@Suite("JobEngine control")
struct JobControlTests {
    @Test func dailyRepeatRunsTheRestOfTheMilestoneEachDay() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let cal = Calendar.current
        let start = try #require(cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 8, minute: 0)))
        let clock = TestClock(start)
        let plan = JobPlan(goal: "Check prices daily", milestones: [Milestone(id: 1, title: "Daily", steps: [
            JobStep(id: 1, title: "Every morning", kind: .wait(.daily(hour: 9, minute: 0, times: 3))), action(2, "Checking prices", route: .web),
        ])])
        let record = fx.record(plan)
        let executor = ScriptedExecutor()
        let config = JobRunner.Configuration(now: clock.function)

        var r = await fx.runner(record, executor, configuration: config).run()
        #expect(r.status == .waiting)
        #expect(r.nextWakeAt == cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 9, minute: 0)))
        for day in 0..<3 {
            clock.set(try #require(r.nextWakeAt).addingTimeInterval(60))
            r = await (try fx.resumeRunner(record.id, executor, configuration: config)).run()
            if day < 2 {
                #expect(r.status == .waiting)
                #expect(r.cursor.waitIteration == day + 1)
                #expect(r.nextWakeAt == cal.date(from: DateComponents(year: 2026, month: 1, day: 6 + day, hour: 9, minute: 0)))
            }
        }
        #expect(r.status == .completed)
        #expect(executor.calls.filter { $0.stepID == 2 }.count == 3)
    }

    @Test func conditionWaitRechecksUntilMet() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [
            JobStep(id: 1, title: "Waiting for shipping", kind: .wait(.condition(check: "my order page shows Shipped", everySeconds: 600, maxTries: 5))),
            action(2, "Telling the user"),
        ])])
        let record = fx.record(plan)
        let executor = ScriptedExecutor { req, n in
            if let s = ScriptedExecutor.standard(req) { return s }
            if req.step.id == 30_001 { return StepResult(status: .done, fields: ["met": n >= 2 ? "yes" : "no", "details": "status"]) }
            return StepResult(status: .done)
        }
        let config = JobRunner.Configuration(now: clock.function)
        let first = await fx.runner(record, executor, configuration: config).run()
        #expect(first.status == .waiting)
        #expect(first.nextWakeAt == clock.now.addingTimeInterval(600))
        #expect(executor.calls.first?.route == .browser)
        clock.set(clock.now.addingTimeInterval(601))
        let second = await (try fx.resumeRunner(record.id, executor, configuration: config)).run()
        #expect(second.status == .completed)
        #expect(executor.calls.map(\.stepID).prefix(3) == [30_001, 30_001, 2])
    }

    @Test func stopsAtTheModelCallBudgetAndContinuesWhenExtended() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: (1...5).map { action($0, "Step \($0)") })])
        let record = fx.record(plan, budget: JobBudget(maxCostUSD: nil, maxDurationSeconds: nil, maxModelCalls: 5))
        let executor = ScriptedExecutor { req, _ in ScriptedExecutor.standard(req) ?? StepResult(status: .done, modelCalls: 2) }
        let stopped = await fx.runner(record, executor).run()
        #expect(stopped.status == .needsInput)
        #expect(stopped.lastError?.contains("budget of 5 model calls") == true)
        #expect(executor.calls.count == 3)
        #expect(stopped.cursor.stepIndex == 3)
        #expect(fx.store.state(jobID: record.id, key: "budgetStop") == "calls")

        var extended = try #require(fx.store.job(record.id))
        JobCenter.extendBudget(&extended, kind: "calls")
        #expect(extended.budget.maxModelCalls == 11)
        fx.store.saveJob(extended)
        let final = await fx.runner(extended, executor).run()
        #expect(final.status == .completed)
        #expect(executor.calls.count == 6) // steps 4 and 5, then the report
    }

    @Test func stopsAtTheCostBudget() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: (1...6).map { action($0, "Step \($0)") })])
        let record = fx.record(plan, budget: JobBudget(maxCostUSD: 0.25, maxDurationSeconds: nil, maxModelCalls: nil))
        // claude-haiku-5-5: $0.10 per million input tokens → $0.10 per call here.
        let executor = ScriptedExecutor { _, _ in StepResult(status: .done, modelCalls: 1, usage: LLMUsage(inputTokens: 1_000_000, outputTokens: 0)) }
        let final = await fx.runner(record, executor, configuration: JobRunner.Configuration(actorModel: "claude-haiku-5-5")).run()
        #expect(final.status == .needsInput)
        #expect(final.lastError?.contains("cost budget") == true)
        #expect(executor.calls.count == 3)
        #expect(abs(final.usage.costUSD - 0.3) < 1e-9)
        #expect(final.usage.costKnown)
    }

    @Test func approvalCheckpointApproveRejectAndStop() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "Draft and send", milestones: [
            Milestone(id: 1, title: "Draft", steps: [action(1, "Drafting")]),
            Milestone(id: 2, title: "Send the emails", steps: [action(2, "Sending")], requiresApproval: true),
        ])
        let asked = Mutex<[ApprovalRequest]>([])

        // Reject: the gated milestone never runs.
        let rejected = fx.record(plan)
        let ex1 = ScriptedExecutor()
        let r1 = await fx.runner(rejected, ex1, callbacks: JobRunner.Callbacks(approve: { req in asked.withLock { $0.append(req) }; return .reject })).run()
        #expect(r1.status == .needsInput)
        #expect(r1.lastError?.contains("declined") == true)
        #expect(ex1.calls.map(\.stepID) == [1])
        #expect(asked.withLock { $0.first?.title.contains("Send the emails") } == true)
        #expect(asked.withLock { $0.first?.kind } == .action)

        // Resuming asks again; approving runs it.
        let r2 = await (try fx.resumeRunner(rejected.id, ex1, callbacks: JobRunner.Callbacks(approve: { _ in .approve }))).run()
        #expect(r2.status == .completed)
        #expect(ex1.calls.map(\.stepID).contains(2))

        // Stop at the checkpoint stops the job.
        let stopped = fx.record(plan)
        let ex2 = ScriptedExecutor()
        let r3 = await fx.runner(stopped, ex2, callbacks: JobRunner.Callbacks(approve: { _ in .stop })).run()
        #expect(r3.status == .stopped)
        #expect(!ex2.calls.contains { $0.stepID == 2 })
    }

    @Test func pauseFinishesItemsInFlightThenResumes() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [listLoop((1...8).map { "I\($0)" }, parallelism: 2)])])
        let record = fx.record(plan)
        let handler: ScriptedExecutor.Handler = { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            try await Task.sleep(for: .milliseconds(60))
            return StepResult(status: .done, fields: ["answer": "x"])
        }
        let executor = ScriptedExecutor(handler)
        let runner = fx.runner(record, executor)
        let task = Task { await runner.run() }
        let store = fx.store
        #expect(await eventually { (store.itemCounts(jobID: record.id)[.done] ?? 0) >= 2 })
        runner.pause()
        let paused = await task.value
        #expect(paused.status == .paused)
        let doneAtPause = fx.store.itemCounts(jobID: record.id)[.done] ?? 0
        #expect(doneAtPause >= 2 && doneAtPause < 8)
        #expect(fx.store.itemCounts(jobID: record.id)[.running] == nil)

        let resumed = await (try fx.resumeRunner(record.id, executor)).run()
        #expect(resumed.status == .completed)
        #expect(executor.itemCalls.count == 8)
        #expect(Set(executor.itemCalls).count == 8)
    }

    @Test func stopCancelsTheStepInFlight() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [listLoop(["A", "B"])])])
        let record = fx.record(plan)
        let executor = ScriptedExecutor { _, _ in
            try await Task.sleep(for: .seconds(60))
            return StepResult(status: .done)
        }
        let runner = fx.runner(record, executor)
        let started = Date()
        let task = Task { await runner.run() }
        #expect(await eventually { executor.calls.count == 1 })
        runner.stop()
        let final = await task.value
        #expect(final.status == .stopped)
        #expect(Date().timeIntervalSince(started) < 10)
        // The interrupted attempt doesn't count against the item.
        let a = try #require(fx.store.items(jobID: record.id).first { $0.title == "A" })
        #expect(a.status == .pending)
        #expect(a.attempts == 0)
    }

    @Test func verificationAddsRemedialStepsThenFails() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "Collect", doneWhen: "every company has a website", steps: [action(1, "Collecting", route: .web)])])

        // Not done once, then done: one remedial step.
        let r1 = fx.record(plan)
        let ex1 = ScriptedExecutor { req, n in
            if (10_000..<20_000).contains(req.step.id) {
                let verifications = n <= 2 ? 1 : 2
                return StepResult(status: .done, fields: ["done": verifications == 1 ? false : true, "reason": "two websites are missing"])
            }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let f1 = await fx.runner(r1, ex1).run()
        #expect(f1.status == .completed)
        #expect(f1.plan?.milestones[0].steps.count == 2)
        let remedial = try #require(ex1.calls.first { $0.stepID == 2 })
        #expect(remedial.title.contains("Finishing"))
        #expect(remedial.route == .web)

        // Never done: two remedial steps, then the job fails with the reason.
        let r2 = fx.record(plan)
        let ex2 = ScriptedExecutor { req, _ in
            if (10_000..<20_000).contains(req.step.id) { return StepResult(status: .done, fields: ["done": false, "reason": "no websites found"]) }
            return StepResult(status: .done)
        }
        let f2 = await fx.runner(r2, ex2).run()
        #expect(f2.status == .failed)
        #expect(f2.lastError?.contains("no websites found") == true)
        #expect(f2.plan?.milestones[0].steps.count == 3)
    }

    @Test func failedActionStepIsRetriedThenFailsTheJob() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Fetching")])])
        let executor = ScriptedExecutor { _, _ in StepResult(status: .failed("404")) }
        let final = await fx.runner(fx.record(plan, budget: JobBudget(maxItemAttempts: 2)), executor).run()
        #expect(final.status == .failed)
        #expect(final.lastError?.contains("404") == true)
        #expect(executor.calls.count == 2)
        #expect(executor.calls[1].context.contains("previous try failed"))
    }
}

// MARK: - Screen lease

@Suite("ScreenLease")
struct ScreenLeaseTests {
    @Test func oneHolderAtATime() async throws {
        let lease = ScreenLease(idleProbe: { 1000 }, pollInterval: 0.01)
        let counter = Mutex((now: 0, max: 0))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask {
                    try await lease.withLease(owner: "job\(i)") {
                        counter.withLock { $0.now += 1; $0.max = Swift.max($0.max, $0.now) }
                        try await Task.sleep(for: .milliseconds(15))
                        counter.withLock { $0.now -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(counter.withLock { $0.max } == 1)
        #expect(await lease.currentHolder == nil)
    }

    @Test func quickTasksGoFirst() async throws {
        let lease = ScreenLease(idleProbe: { 1000 }, pollInterval: 0.01)
        try await lease.acquire(owner: "jobA")
        let order = Mutex<[String]>([])
        let b = Task { try await lease.acquire(owner: "jobB"); order.withLock { $0.append("jobB") }; await lease.release(owner: "jobB") }
        #expect(await eventually { await lease.queueLength == 1 })
        let task = Task { try await lease.acquire(owner: "task", priority: true); order.withLock { $0.append("task") }; await lease.release(owner: "task") }
        #expect(await eventually { await lease.queueLength == 2 })
        await lease.release(owner: "jobA")
        try await b.value
        try await task.value
        #expect(order.withLock { $0 } == ["task", "jobB"])
    }

    @Test func neverModeBlocksJobsButNotQuickTasks() async throws {
        let lease = ScreenLease(idleProbe: { 1000 })
        await #expect(throws: ScreenLease.LeaseError.self) { try await lease.acquire(owner: "job", screenUse: .never) }
        try await lease.acquire(owner: "task", screenUse: .never, priority: true)
        #expect(await lease.currentHolder == "task")
        await lease.release(owner: "task")
    }

    @Test func whenIdleWaitsForTheUser() async throws {
        let idle = Mutex(0.0)
        let lease = ScreenLease(idleProbe: { idle.withLock { $0 } }, pollInterval: 0.01)
        let acquired = Mutex(false)
        let t = Task {
            try await lease.acquire(owner: "job", screenUse: .whenIdle, idleSeconds: 30)
            acquired.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(!acquired.withLock { $0 })
        #expect(await lease.currentHolder == nil)
        idle.withLock { $0 = 45 }
        try await t.value
        #expect(acquired.withLock { $0 })
        #expect(await lease.currentHolder == "job")
    }

    @Test func cancellingAWaiterLeavesTheQueue() async throws {
        let lease = ScreenLease(idleProbe: { 1000 })
        try await lease.acquire(owner: "a")
        let waiter = Task { try await lease.acquire(owner: "b") }
        #expect(await eventually { await lease.queueLength == 1 })
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await lease.queueLength == 0)
        await lease.release(owner: "a")
        #expect(await lease.currentHolder == nil)
    }

    @Test func screenStepsHoldTheLeaseAndNeverModeAsks() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "Clicking", route: .gui)])])
        let lease = ScreenLease(idleProbe: { 1000 })
        let holders = Mutex<[String?]>([])
        let executor = ScriptedExecutor { req, _ in
            if req.step.id == 1 { let h = await lease.currentHolder; holders.withLock { $0.append(h) } }
            return ScriptedExecutor.standard(req) ?? StepResult(status: .done)
        }
        let record = fx.record(plan)
        let final = await fx.runner(record, executor, lease: lease).run()
        #expect(final.status == .completed)
        #expect(holders.withLock { $0 } == ["job:\(record.id)"])
        #expect(await lease.currentHolder == nil)

        var never = testSettings()
        never.jobs.screenUse = .never
        let r2 = fx.record(plan)
        let f2 = await fx.runner(r2, ScriptedExecutor(), settings: never, lease: lease).run()
        #expect(f2.status == .needsInput)
        #expect(f2.lastError?.contains("Screen use") == true)
    }
}

// MARK: - Planning and estimates

@Suite("JobPlanner")
struct JobPlannerTests {
    @Test func estimateMath() throws {
        let loop = JobStep(id: 1, title: "Researching", kind: .forEach(ForEachSpec(
            source: .list((1...25).map(String.init)), itemLabel: "company",
            recipe: [RecipeStep(id: 1, title: "a", instruction: "a", route: .web), RecipeStep(id: 2, title: "b", instruction: "b", route: .web)],
            parallelism: 4, outputTable: "t")))
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", doneWhen: "x", steps: [loop])])
        let e = JobPlanner.estimate(plan, items: [1: 25], actorModel: "claude-haiku-5-5", plannerModel: "claude-opus-5-5")
        #expect(e.items == 25)
        #expect(e.modelCalls == 103) // 25 × (1.5 × 2 + 1) + verify + report + planning
        #expect(abs(e.minutes - 3.6) < 1e-9) // (25 × 32 s / 4 + 8 + 8) / 60
        #expect(abs((e.costUSD ?? 0) - 0.1301) < 1e-9)
        #expect(e.notes.contains("25 companies × 2 steps, 4 at a time"))

        // On-screen loops run one at a time at 20 s per turn; action steps take 3 calls.
        let gui = JobStep(id: 1, title: "Clicking", kind: .forEach(ForEachSpec(source: .list(["a", "b"]), itemLabel: "row",
            recipe: [RecipeStep(id: 1, title: "a", instruction: "a", route: .gui)], parallelism: 4, outputTable: "t")))
        let plan2 = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(2, "Prep", route: .command), gui])])
        let e2 = JobPlanner.estimate(plan2, items: [1: 2])
        #expect(e2.modelCalls == 3 + 5 + 1 + 1) // action 3, 2 × 2.5, report, planning
        #expect(abs(e2.minutes - (24 + 2 * 38 + 8) / 60.0) < 1e-9)
        #expect(e2.costUSD == nil)

        // Unknown item counts assume 10; limits cap them.
        let limited = JobStep(id: 1, title: "L", kind: .forEach(ForEachSpec(source: .table(name: "x"), itemLabel: "x",
            recipe: [RecipeStep(id: 1, title: "a", instruction: "a", route: .web)], parallelism: 1, outputTable: "t", limit: 3)))
        #expect(JobPlanner.estimate(JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [limited])])).items == 3)
    }

    @Test func decodesAPlanWithLoopsAndWaits() throws {
        let json = try JSONValue.parse("""
        {"goal":"Research and follow up","clarification":null,"outputs":"A table","milestones":[
          {"title":"Find","description":"d","done_when":"have a list","requires_approval":false,"steps":[
            {"kind":"action","title":"Listing companies","action":{"title":"Listing","instruction":"List 20 startups","route":"web","app":null,"risk":"low","done_when":"20 listed","output_fields":["items"]},"for_each":null,"wait":null},
            {"kind":"for_each","title":"Researching","action":null,"wait":null,"for_each":{
              "source":{"kind":"step_output","path":null,"sheet":null,"column":null,"has_header":true,"table":null,"items":null,"step_number":1},
              "item_label":"company","parallelism":9,"output_table":"companies","output_columns":["website"],"limit":null,
              "recipe":[{"title":"Opening site","instruction":"Open the site","route":"browser","app":null,"risk":"low","done_when":"open","output_fields":["website"]}],
              "write_back":null}}]},
          {"title":"Follow up","description":"","done_when":"","requires_approval":true,"steps":[
            {"kind":"wait","title":"Every morning","action":null,"for_each":null,"wait":{"kind":"daily","seconds":null,"until":null,"hour":9,"minute":30,"times":5,"check":null,"every_seconds":null,"max_tries":null}},
            {"kind":"wait","title":"Until launch","action":null,"for_each":null,"wait":{"kind":"until","seconds":null,"until":"2026-11-02T10:00","hour":null,"minute":null,"times":null,"check":null,"every_seconds":null,"max_tries":null}},
            {"kind":"action","title":"Emailing","action":{"title":"Emailing","instruction":"Send the summary","route":"mcp","app":null,"risk":"high","done_when":"sent","output_fields":[]},"for_each":null,"wait":null}]}]}
        """)
        let plan = try JobPlanSchema.decode(json)
        #expect(plan.milestones.count == 2)
        #expect(plan.milestones.flatMap(\.steps).map(\.id) == [1, 2, 3, 4, 5])
        #expect(plan.milestones[1].requiresApproval)
        guard case .forEach(let spec) = plan.milestones[0].steps[1].kind else { Issue.record("expected a loop"); return }
        #expect(spec.source == .stepOutput(stepID: 1))
        #expect(spec.parallelism == 2) // capped for browser recipes
        guard case .wait(.daily(9, 30, 5)) = plan.milestones[1].steps[0].kind else { Issue.record("expected daily"); return }
        guard case .wait(.until(let date)) = plan.milestones[1].steps[1].kind else { Issue.record("expected until"); return }
        #expect(Calendar.current.component(.hour, from: date) == 10)
    }

    @Test func rejectsNonsensePlans() throws {
        func plan(_ steps: String) throws -> JSONValue {
            try JSONValue.parse(#"{"goal":"g","clarification":null,"outputs":"","milestones":[{"title":"m","description":"","done_when":"","requires_approval":false,"steps":["# + steps + "]}]}")
        }
        let loopOverLater = try plan(#"{"kind":"for_each","title":"L","action":null,"wait":null,"for_each":{"source":{"kind":"step_output","path":null,"sheet":null,"column":null,"has_header":true,"table":null,"items":null,"step_number":3},"item_label":"x","parallelism":1,"output_table":"t","output_columns":[],"limit":null,"recipe":[{"title":"a","instruction":"a","route":"web","app":null,"risk":"low","done_when":"","output_fields":[]}],"write_back":null}}"#)
        #expect(throws: JobPlanError.self) { try JobPlanSchema.decode(loopOverLater) }
        let emptyRecipe = try plan(#"{"kind":"for_each","title":"L","action":null,"wait":null,"for_each":{"source":{"kind":"list","path":null,"sheet":null,"column":null,"has_header":true,"table":null,"items":["a"],"step_number":null},"item_label":"x","parallelism":1,"output_table":"t","output_columns":[],"limit":null,"recipe":[],"write_back":null}}"#)
        #expect(throws: JobPlanError.self) { try JobPlanSchema.decode(emptyRecipe) }
        let badWait = try plan(#"{"kind":"wait","title":"W","action":null,"for_each":null,"wait":{"kind":"until","seconds":null,"until":"someday","hour":null,"minute":null,"times":null,"check":null,"every_seconds":null,"max_tries":null}}"#)
        #expect(throws: JobPlanError.self) { try JobPlanSchema.decode(badWait) }
        #expect(throws: JobPlanError.self) { try JobPlanSchema.decode(try JSONValue.parse(#"{"goal":"g","clarification":null,"outputs":"","milestones":[]}"#)) }
        let question = try JobPlanSchema.decode(try JSONValue.parse(#"{"goal":"g","clarification":"Which sheet?","outputs":"","milestones":[]}"#))
        #expect(question.clarification == "Which sheet?")
        #expect(question.milestones.isEmpty)
    }

    @Test func schemaIsStrict() {
        func check(_ s: JSONValue) {
            if let branches = s["anyOf"]?.arrayValue { branches.forEach(check); return }
            if let items = s["items"] { check(items) }
            guard let props = s["properties"]?.objectValue else { return }
            let required = Set(s["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            #expect(required == Set(props.keys))
            #expect(s["additionalProperties"] == .bool(false))
            props.values.forEach(check)
        }
        check(JobPlanSchema.schema)
    }

    @Test func planningContextReadsMentionedSpreadsheets() throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let path = try fx.writeFile("leads list.csv", "Name,Email\nAda,a@x.com\nBob,b@x.com\nCy,c@x.com\nDi,d@x.com\n")
        let files = JobPlanningContext.mentionedFiles(in: "For each row in \"\(path)\", find their LinkedIn. Also /definitely/not/here.csv", searchFolders: [])
        #expect(files.count == 1)
        #expect(files.first?.preview?.columns == ["Name", "Email"])
        #expect(files.first?.preview?.rows.count == 3)
        #expect(files.first?.rowCount == 4)
        var ctx = JobPlanningContext(request: "x", files: files, commandAccess: .readOnly)
        ctx.browser = "connected"
        #expect(ctx.rendered.contains("read-only"))
        #expect(ctx.rendered.contains("“Email”"))
        // Bare file names are looked up in the given folders.
        let bare = JobPlanningContext.mentionedFiles(in: "update leads.csv please", searchFolders: [fx.root])
        #expect(bare.isEmpty)
        _ = try fx.writeFile("leads.csv", "A\n1\n")
        #expect(JobPlanningContext.mentionedFiles(in: "update leads.csv please", searchFolders: [fx.root]).count == 1)
    }

    @Test func pluralizes() {
        #expect(JobPlanner.pluralize("company", 2) == "companies")
        #expect(JobPlanner.pluralize("day", 2) == "days")
        #expect(JobPlanner.pluralize("box", 3) == "boxes")
        #expect(JobPlanner.pluralize("row", 1) == "row")
    }
}

// MARK: - Store, workspace and tools

@Suite("JobStore and workspace")
struct JobStoreTests {
    @Test func factsRowsEventsAndDeletion() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let ws = SQLiteJobWorkspace(jobID: "j1", store: fx.store)
        await ws.setFact("pricing_url", "https://acme.example/pricing")
        await ws.setFact("ceo", "Jane Doe runs Acme")
        await ws.setFact("weather", "sunny")
        let hits = await ws.facts(matching: "who is the Acme CEO", limit: 5)
        #expect(hits.first?.key == "ceo")
        #expect(!hits.contains { $0.key == "weather" })
        #expect(await ws.facts(matching: nil, limit: 2).count == 2)

        await ws.upsertRow(table: "companies", key: "Acme", fields: ["site": "a"])
        await ws.upsertRow(table: "companies", key: "Beta", fields: ["site": "b"])
        await ws.upsertRow(table: "companies", key: "Acme", fields: ["site": "a2"])
        let rows = await ws.rows(table: "companies", limit: nil)
        #expect(rows.map(\.key) == ["Acme", "Beta"])
        #expect(rows.first?.fields["site"] == "a2")
        #expect(await ws.tableNames() == ["companies"])
        try FileManager.default.createDirectory(at: ws.folder, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: ws.folder.appendingPathComponent("notes.txt"))
        let summary = await ws.summary(maxChars: 2000)
        #expect(summary.contains("companies: 2 rows"))
        #expect(summary.contains("ceo: Jane Doe"))
        #expect(summary.contains("notes.txt"))
        #expect(await ws.summary(maxChars: 40).count <= 40)

        for i in 0..<5 { fx.store.appendEvent(jobID: "j1", ActivityEntry(kind: .info, title: "e\(i) sk-ant-abcdefghijklmnop")) }
        let tail = fx.store.events(jobID: "j1", limit: 3)
        #expect(tail.map { $0.title.prefix(2) } == ["e2", "e3", "e4"])
        #expect(!tail.contains { $0.title.contains("sk-ant") })

        fx.store.deleteJob("j1")
        #expect(fx.store.facts(jobID: "j1").isEmpty)
        #expect(fx.store.rows(jobID: "j1", table: "companies").isEmpty)
        #expect(fx.store.events(jobID: "j1").isEmpty)
    }

    @Test func itemQueriesAndRecovery() throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        var items = (0..<4).map { JobItem(jobID: "j", stepID: 1, index: $0, title: "t\($0)", input: .string("t\($0)")) }
        items[0].status = .done
        items[1].status = .failed; items[1].attempts = 2
        items[2].status = .running; items[2].attempts = 1
        fx.store.insertItems(items)
        #expect(fx.store.progressCounts(jobID: "j", maxAttempts: 2) == (4, 1, 1, 0))
        #expect(fx.store.progressCounts(jobID: "j", maxAttempts: 3).failed == 0)
        #expect(fx.store.runnableItems(jobID: "j", stepID: 1, maxAttempts: 3).map(\.index) == [1, 3])
        #expect(fx.store.resetRunningItems(jobID: "j") == 1)
        #expect(fx.store.item("j/1/2")?.status == .pending)
        #expect(fx.store.item("j/1/2")?.attempts == 0)
        #expect(fx.store.requeueFailedItems(jobID: "j") == [1])
        #expect(fx.store.item("j/1/1")?.attempts == 0)
        #expect(fx.store.itemCounts(jobID: "j")[.pending] == 3)
    }

    @Test func recordsRoundTrip() throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [listLoop(["a"]), JobStep(id: 2, title: "w", kind: .wait(.duration(seconds: 5)))])])
        var r = fx.record(plan)
        r.nextWakeAt = Date(timeIntervalSince1970: 1_900_000_000)
        r.status = .waiting
        fx.store.saveJob(r)
        let back = try #require(fx.store.job(r.id))
        #expect(back.plan == plan)
        #expect(back.nextWakeAt == r.nextWakeAt)
        #expect(fx.store.jobs(status: .waiting).map(\.id) == [r.id])
        #expect(fx.store.folder(for: "../../etc").path.hasPrefix(fx.store.jobsRoot.path + "/"))
    }
}

@Suite("Write-back")
struct WriteBackTests {
    @Test func csvFallbackUpdatesInPlace() throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let path = try fx.writeFile("sheet.csv", "Name,Note\nAda,\"has, comma\"\nBob,x\n")
        try JobWriteBack.csvUpdate(path, keyColumn: "name", updates: ["Bob": ["Email": "b@x.com", "Score": "2"], "Cy": ["Email": "c@x.com"]], columnOrder: ["Score", "Email"])
        var t = try TableIO.readCSV(path, hasHeader: true)
        #expect(t.columns == ["Name", "Note", "Score", "Email"])
        #expect(t.rows == [["Ada", "has, comma", "", ""], ["Bob", "x", "2", "b@x.com"], ["Cy", "", "", "c@x.com"]])
        #expect(try String(contentsOfFile: path + ".bak", encoding: .utf8).contains("Bob,x"))
        // Row order (0-based data rows) when there's no key column.
        try JobWriteBack.csvUpdate(path, keyColumn: nil, updates: ["0": ["Score": "9"], "7": ["Score": "nope"]], columnOrder: [])
        t = try TableIO.readCSV(path, hasHeader: true)
        #expect(t.records[0]["Score"] == "9")
        #expect(t.rows.count == 3)
        #expect(throws: ToolError.self) { try JobWriteBack.csvUpdate(fx.root.appendingPathComponent("x.xlsx").path, keyColumn: nil, updates: [:], columnOrder: []) }
    }

    @Test func updatesComeFromItemResults() {
        var item = JobItem(jobID: "j", stepID: 1, index: 4, title: "Acme", input: ["Company": "Acme Inc"])
        item.result = ["website": "https://acme.example", "Employees": 120, "tags": ["a", "b"]]
        let byKey = JobRunner.writeBackUpdate(item, WriteBack(path: "x.csv", keyColumn: "company", columns: ["website", "employees", "tags", "missing"]))
        #expect(byKey?.key == "Acme Inc")
        #expect(byKey?.values == ["website": "https://acme.example", "employees": "120", "tags": "a; b"])
        #expect(JobRunner.writeBackUpdate(item, WriteBack(path: "x.csv", columns: ["website"]))?.key == "4")
        #expect(JobRunner.writeBackUpdate(item, WriteBack(path: "x.csv", columns: ["missing"])) == nil)
    }
}

@Suite("Workspace tools")
struct WorkspaceToolTests {
    func context(_ ws: (any JobWorkspace)?) -> ToolContext { ToolContext(settings: AppSettings(), gate: ExecutionGate(), workspace: ws) }

    @Test func roundTrip() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let ws = SQLiteJobWorkspace(jobID: "j", store: fx.store)
        try FileManager.default.createDirectory(at: ws.folder, withIntermediateDirectories: true)
        let tools = Dictionary(uniqueKeysWithValues: WorkspaceTools.all.map { ($0.spec.name, $0) })
        #expect(Set(tools.keys) == ["workspace.remember", "workspace.recall", "workspace.save_row", "workspace.rows", "workspace.write_file", "workspace.read_file"])
        #expect(tools.values.allSatisfy { $0.spec.category == .workspace && $0.assess(.object([:]), context: context(ws)).risk == .low })
        let ctx = context(ws)

        #expect(try await tools["workspace.remember"]!.run(["key": "plan", "value": "Pro costs $20"], context: ctx).ok)
        let recalled = try await tools["workspace.recall"]!.run(["query": "pro plan cost", "limit": nil], context: ctx)
        #expect(recalled.text.contains("Pro costs $20"))
        #expect(try await tools["workspace.save_row"]!.run(["table": "plans", "key": "Pro", "fields": ["price": 20]], context: ctx).ok)
        #expect(try await tools["workspace.save_row"]!.run(["table": "plans", "key": "Team", "fields_json": #"{"price": 50}"#], context: ctx).ok)
        let rows = try await tools["workspace.rows"]!.run(["table": "plans"], context: ctx)
        #expect(rows.data?.arrayValue?.count == 2)
        #expect(rows.text.contains("Team"))
        #expect(try await tools["workspace.write_file"]!.run(["name": "drafts/email.md", "content": "Hello"], context: ctx).ok)
        let read = try await tools["workspace.read_file"]!.run(["name": "drafts/email.md"], context: ctx)
        #expect(read.ok && read.text == "Hello")
        #expect(!(try await tools["workspace.read_file"]!.run(["name": "missing.txt"], context: ctx)).ok)
    }

    @Test func staysInsideTheJobFolder() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let ws = SQLiteJobWorkspace(jobID: "j", store: fx.store)
        try FileManager.default.createDirectory(at: ws.folder, withIntermediateDirectories: true)
        let write = WorkspaceWriteFileTool(), read = WorkspaceReadFileTool()
        let ctx = context(ws)
        for bad in ["../escape.txt", "/tmp/escape.txt", "~/escape.txt", "a/../../escape.txt", "./x"] {
            await #expect(throws: ToolError.self) { _ = try await write.run(["name": .string(bad), "content": "x"], context: ctx) }
        }
        #expect(!FileManager.default.fileExists(atPath: fx.store.jobsRoot.appendingPathComponent("escape.txt").path))
        try FileManager.default.createSymbolicLink(at: ws.folder.appendingPathComponent("link"), withDestinationURL: fx.root)
        await #expect(throws: ToolError.self) { _ = try await write.run(["name": "link/escape.txt", "content": "x"], context: ctx) }
        await #expect(throws: ToolError.self) { _ = try await read.run(["name": "link/jobs.sqlite"], context: ctx) }
        #expect(!FileManager.default.fileExists(atPath: fx.root.appendingPathComponent("escape.txt").path))
    }

    @Test func explainsWhenNotInAJob() async {
        await #expect(throws: ToolError.self) { _ = try await WorkspaceRememberTool().run(["key": "k", "value": "v"], context: context(nil)) }
    }
}

// MARK: - JobCenter

final class URLLog: Sendable {
    let urls = Mutex<[URL]>([])
}

struct FixedPlanner: JobPlanning {
    let plan: JobPlan
    func plan(_ instruction: String, context: JobPlanningContext) async throws -> JobPlanOutcome {
        JobPlanOutcome(plan: plan, usage: LLMUsage(inputTokens: 10, outputTokens: 5), modelCalls: 1)
    }
}

struct FailingPlanner: JobPlanning {
    func plan(_ instruction: String, context: JobPlanningContext) async throws -> JobPlanOutcome {
        throw JobPlanError.invalid("it has no milestones.")
    }
}

@MainActor
func makeCenter(_ fx: JobFixture, plan: JobPlan?, executor: (any StepExecuting)?, settings: AppSettings = testSettings(),
                removed: URLLog? = nil) -> JobCenter {
    let planner: any JobPlanning = plan.map { FixedPlanner(plan: $0) } ?? FailingPlanner()
    let env = JobCenter.Environment(
        store: fx.store, settings: { settings }, planner: { _ in planner },
        planningContext: { request, s in JobPlanningContext(request: request, settings: s) },
        executor: { _ in executor }, lease: ScreenLease(idleProbe: { 1000 }), models: { _ in (nil, nil) }, keepAwake: nil,
        removeFolder: { url in removed?.urls.withLock { $0.append(url) }; try FileManager.default.removeItem(at: url) },
        schedulerMaxSleep: 0.05)
    return JobCenter(environment: env)
}

@Suite("JobCenter")
@MainActor
struct JobCenterTests {
    @Test func smallJobsStartAndWaitStepsWakeUpViaTheScheduler() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "Wait and continue", milestones: [Milestone(id: 1, title: "m", steps: [
            action(1, "Before"), JobStep(id: 2, title: "Short wait", kind: .wait(.duration(seconds: 0.3))), action(3, "After"),
        ])])
        let executor = ScriptedExecutor()
        let center = makeCenter(fx, plan: plan, executor: executor)
        let finished = Mutex<[JobStatus]>([])
        center.onJobFinished = { r in finished.withLock { $0.append(r.status) } }
        let created = await center.create(instruction: "Do it, wait, do more")
        #expect(created.plan?.estimate != nil)
        #expect(created.usage.modelCalls == 1) // planning counted
        #expect(await eventuallyOnMain { center.job(created.id)?.status == .waiting })
        let waiting = try #require(center.job(created.id))
        #expect(waiting.nextWakeAt != nil)
        #expect(waiting.statusLine.contains("Waiting until"))
        #expect(await eventuallyOnMain { center.job(created.id)?.status == .completed })
        #expect(executor.calls.map(\.stepID) == [1, 3, 20_000])
        // onJobFinished fires once the runner has unwound, just after the final status arrives.
        #expect(await eventuallyOnMain { finished.withLock { $0 } == [.completed] })
        #expect(center.events(created.id).contains { $0.title.contains("Waking up") })
    }

    @Test func bigJobsAwaitConfirmationThenExportAndDelete() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "Look things up", milestones: [Milestone(id: 1, title: "m", steps: [listLoop(["Alpha", "Beta, Inc", "Gamma"], parallelism: 2, table: "things")])])
        var settings = testSettings()
        settings.jobs.confirmAboveMinutes = 0.01
        let executor = ScriptedExecutor { req, _ in
            ScriptedExecutor.standard(req) ?? StepResult(status: .done, fields: ["answer": .string("found \(req.itemID ?? "")"), "extra": 1])
        }
        let removed = URLLog()
        let center = makeCenter(fx, plan: plan, executor: executor, settings: settings, removed: removed)
        let attention = Mutex(0)
        center.onAttentionNeeded = { _ in attention.withLock { $0 += 1 } }
        let created = await center.create(instruction: "Look up Alpha, Beta and Gamma")
        #expect(created.status == .awaitingConfirmation)
        #expect(created.plan?.estimate?.items == 3)
        #expect(created.statusLine.contains("3 items"))
        #expect(attention.withLock { $0 } == 1)
        #expect(executor.calls.isEmpty)

        center.start(created.id)
        #expect(await eventuallyOnMain { center.job(created.id)?.status == .completed })
        #expect(center.items(created.id).count == 3)

        let out = fx.root.appendingPathComponent("export.csv")
        try center.exportResults(created.id, to: out)
        let table = try TableIO.readCSV(out.path, hasHeader: true)
        #expect(table.columns == ["Item", "answer", "extra"])
        #expect(table.rows.map { $0[0] } == ["Alpha", "Beta, Inc", "Gamma"])

        let folder = try #require(center.job(created.id)).folder
        #expect(await eventuallyOnMain { !center.hasRunner(created.id) })
        center.delete(created.id)
        #expect(center.job(created.id) == nil)
        #expect(fx.store.job(created.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(removed.urls.withLock { $0.count } == 1)
        #expect(throws: JobCenterError.self) { try center.exportResults(created.id, to: out) }
    }

    @Test func routesApprovalsAndHonorsStop() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "Send", milestones: [
            Milestone(id: 1, title: "Prepare", steps: [action(1, "Preparing")]),
            Milestone(id: 2, title: "Send it", steps: [action(2, "Sending")], requiresApproval: true),
        ])
        let executor = ScriptedExecutor()
        let center = makeCenter(fx, plan: plan, executor: executor)
        let created = await center.create(instruction: "prepare and send")
        #expect(await eventuallyOnMain { center.pendingApprovals[created.id] != nil })
        #expect(center.pendingApprovals[created.id]?.title.contains("Send it") == true)
        center.respond(jobID: created.id, decision: .approve)
        #expect(await eventuallyOnMain { center.job(created.id)?.status == .completed })
        #expect(center.pendingApprovals.isEmpty)
        #expect(executor.calls.map(\.stepID).contains(2))

        // Stop while it waits for approval.
        let second = await center.create(instruction: "again")
        #expect(await eventuallyOnMain { center.pendingApprovals[second.id] != nil })
        center.stop(second.id)
        #expect(await eventuallyOnMain { center.job(second.id)?.status == .stopped })
        #expect(center.pendingApprovals[second.id] == nil)
    }

    @Test func failsClearlyWithoutAStepRunnerOrAPlan() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "A")])])
        let noRunner = makeCenter(fx, plan: plan, executor: nil)
        let r = await noRunner.create(instruction: "x")
        #expect(r.status == .failed)
        #expect(r.lastError == "Step runner not installed")

        let noPlan = makeCenter(fx, plan: nil, executor: ScriptedExecutor())
        let r2 = await noPlan.create(instruction: "x")
        #expect(r2.status == .failed)
        #expect(r2.lastError?.contains("no milestones") == true)

        let question = makeCenter(fx, plan: JobPlan(goal: "g", milestones: [], clarification: "Which file?"), executor: ScriptedExecutor())
        let r3 = await question.create(instruction: "x")
        #expect(r3.status == .needsInput)
        #expect(r3.statusLine == "Which file?")
    }

    @Test func queuesBeyondTheConcurrencyLimitAndRetriesFailedItems() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        var settings = testSettings()
        settings.jobs.maxConcurrentJobs = 1
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [listLoop(["ok", "bad"]), action(2, "Summarizing")])])
        let failBad = Mutex(true)
        let store = fx.store
        let executor = ScriptedExecutor { req, _ in
            if let s = ScriptedExecutor.standard(req) { return s }
            try await Task.sleep(for: .milliseconds(30))
            if let id = req.itemID, store.item(id)?.title == "bad", failBad.withLock({ $0 }) { return StepResult(status: .failed("blocked by site")) }
            return StepResult(status: .done, fields: ["answer": "y"])
        }
        let center = makeCenter(fx, plan: plan, executor: executor, settings: settings)
        let a = await center.create(instruction: "first")
        let b = await center.create(instruction: "second")
        #expect(center.job(b.id)?.status == .waiting)
        #expect(center.job(b.id)?.statusLine.contains("Queued") == true)
        #expect(await eventuallyOnMain { center.job(a.id)?.status == .completed && center.job(b.id)?.status == .completed })
        #expect(center.job(a.id)?.usage.itemsFailed == 1)

        failBad.withLock { $0 = false }
        #expect(await eventuallyOnMain { !center.hasRunner(a.id) })
        center.retryFailedItems(a.id)
        #expect(await eventuallyOnMain { center.job(a.id)?.status == .completed && center.job(a.id)?.usage.itemsFailed == 0 })
        #expect(center.job(a.id)?.usage.itemsDone == 2)
    }

    @Test func launchHandlesInterruptedJobs() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [action(1, "A")])])
        var running = fx.record(plan)
        running.status = .running
        fx.store.saveJob(running)
        var planning = JobRecord(title: "p", instruction: "p", status: .planning, folder: fx.store.ensureFolder(for: "p").path)
        planning.plan = nil
        fx.store.saveJob(planning)

        var noResume = testSettings()
        noResume.jobs.autoResume = false
        let center = makeCenter(fx, plan: plan, executor: ScriptedExecutor(), settings: noResume)
        center.launch()
        #expect(center.job(running.id)?.status == .paused)
        #expect(center.job(running.id)?.lastError?.contains("quit") == true)
        #expect(center.job(planning.id)?.status == .failed)

        // With auto-resume, an interrupted job continues by itself.
        var again = try #require(fx.store.job(running.id))
        again.status = .running
        fx.store.saveJob(again)
        let auto = makeCenter(fx, plan: plan, executor: ScriptedExecutor())
        auto.launch()
        #expect(await eventuallyOnMain { auto.job(running.id)?.status == .completed })

        let actions = JobScheduler.launchActions(for: [running, planning], autoResume: true)
        #expect(actions[running.id] == .resume)
        #expect(actions[planning.id] == .markPlanningFailed)
    }

    @Test func pauseAndResumeAWaitingJob() async throws {
        let fx = try JobFixture()
        defer { fx.cleanup() }
        let plan = JobPlan(goal: "g", milestones: [Milestone(id: 1, title: "m", steps: [JobStep(id: 1, title: "Long wait", kind: .wait(.duration(seconds: 3600))), action(2, "After")])])
        let executor = ScriptedExecutor()
        let center = makeCenter(fx, plan: plan, executor: executor)
        let created = await center.create(instruction: "wait an hour")
        #expect(await eventuallyOnMain { center.job(created.id)?.status == .waiting && !center.hasRunner(created.id) })
        center.pause(created.id)
        #expect(center.job(created.id)?.status == .paused)
        // Resuming a paused sleeper goes back to sleep until its time…
        center.resume(created.id)
        #expect(await eventuallyOnMain { center.job(created.id)?.status == .waiting && !center.hasRunner(created.id) })
        #expect(executor.calls.isEmpty)
        // …while resuming a sleeping job means "go now".
        center.resume(created.id)
        #expect(await eventuallyOnMain { center.job(created.id)?.status == .completed })
        #expect(executor.calls.map(\.stepID) == [2, 20_000])
    }
}

@Suite("JobScheduler")
struct JobSchedulerTests {
    @Test func dueAndEarliest() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func job(_ status: JobStatus, _ wake: Double?) -> JobRecord {
            var r = JobRecord(title: "t", instruction: "t", status: status, folder: "/tmp")
            r.nextWakeAt = wake.map { now.addingTimeInterval($0) }
            return r
        }
        let past = job(.waiting, -5), future = job(.waiting, 50), paused = job(.paused, -5), queued = job(.waiting, nil)
        #expect(JobScheduler.dueJobs([past, future, paused, queued], now: now) == [past.id])
        #expect(JobScheduler.earliestWake([future, paused, queued]) == future.nextWakeAt)
        #expect(JobScheduler.launchActions(for: [queued], autoResume: false)[queued.id] == .resume)
    }

    @Test func conditionRoutes() {
        #expect(JobRunner.conditionRoute("the file ~/Downloads/report.pdf exists") == .command)
        #expect(JobRunner.conditionRoute("my order shows Shipped") == .browser)
        #expect(JobRunner.conditionRoute("Apple announced the new iPad") == .web)
    }
}
