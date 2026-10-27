import Foundation
import Testing
@testable import AgentKit

@Suite("Memory")
struct MemoryTests {
    func store() throws -> LocalStore {
        try LocalStore(path: NSTemporaryDirectory() + "glide-memory-\(UUID().uuidString).sqlite")
    }

    @Test func savesListsAndForgetsFacts() throws {
        let s = try store()
        s.addMemory("My manager is Priya Shah.")
        s.addMemory("my manager is priya shah.") // same fact, different case
        s.addMemory("Sign emails as Yugen.")
        #expect(s.memories().map(\.text) == ["Sign emails as Yugen.", "My manager is Priya Shah."])
        #expect(s.forgetMemories(matching: "manager") == 1)
        #expect(s.memories().map(\.text) == ["Sign emails as Yugen."])
        #expect(s.forgetMemories(matching: "") == 0)
    }

    func done(_ summary: String) -> TaskResult {
        TaskResult(status: .completed, summary: summary, metrics: TaskMetrics.Snapshot(modelCalls: 0, visionCalls: 0, jevCalls: 0, inputTokens: 0, outputTokens: 0, estimatedCost: 0, modelLatencyMs: 0,
                                                                          actions: 0, deterministicActions: 0, recoveries: 0, interventions: 0, observations: 0, avgObservationMs: 0), durationMs: 1)
    }

    @Test func conversationContextHasFactsRecentTasksAndTheLastConversation() throws {
        let s = try store()
        #expect(GlideMemory.conversationContext(store: s) == nil)
        s.addMemory("My manager is Priya Shah.")
        let now = Date()
        s.startTask(id: "old", instruction: "old thing", at: now.addingTimeInterval(-3 * 86400))
        s.finishTask(id: "old", result: done("Old result"), at: now.addingTimeInterval(-3 * 86400))
        s.startTask(id: "t1", instruction: "What's on Sam's LinkedIn?", at: now.addingTimeInterval(-600))
        s.finishTask(id: "t1", result: done("Sam is a PM at Acme."), at: now.addingTimeInterval(-590))
        let text = try #require(GlideMemory.conversationContext(store: s, lastConversation: "User: hi\nGlide: Hey.", now: now))
        #expect(text.contains("My manager is Priya Shah."))
        #expect(text.contains("Sam is a PM at Acme."))
        #expect(!text.contains("Old result")) // older than a day
        #expect(text.contains("Glide: Hey."))
    }
}

@Suite("Direct one-step plans")
struct DirectPlanTests {
    func context(front: String? = "Google Chrome", page: String? = "Inbox — https://mail.google.com", conversation: String? = nil) -> PlanningContext {
        var c = PlanningContext(frontmostApp: front, browserPage: page,
                                routes: RouteAvailability(toolFamilies: [.browser], browserOnDemand: true))
        c.conversation = conversation
        return c
    }

    @Test(arguments: [
        "Draft a new email to sam@example.com saying hi",
        "What is on this person's LinkedIn profile?",
        "Search YouTube for lofi hip hop",
    ])
    func simpleBrowserRequestsSkipThePlanner(_ text: String) throws {
        let plan = try #require(DirectPlan.make(text, context: context()))
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].route == .browser)
    }

    @Test(arguments: [
        "Add athletic socks to my Amazon cart",
        "Open Gmail, then reply to the newest email",
        "Research the top 20 CRMs and put them in a spreadsheet",
        "Draft an email to Sam. Then send it to Priya too.",
    ])
    func multiStepOrShoppingRequestsArePlanned(_ text: String) {
        #expect(DirectPlan.make(text, context: context()) == nil)
    }

    @Test func aRequestRightAfterAnInstantOpenTargetsThatApp() throws {
        let c = context(front: "ChatGPT", page: nil, conversation: "ChatGPT (desktop app) is open and in front.")
        let plan = try #require(DirectPlan.make("Start a new chat", context: c))
        #expect(plan.steps[0].route == .gui)
        #expect(plan.steps[0].app == "ChatGPT")
        #expect(plan.steps[0].instruction.contains("is open and in front"))
    }

    @Test func nativeRequestsWithoutContextArePlanned() {
        #expect(DirectPlan.make("Make a note about lunch", context: context(front: "Finder", page: nil)) == nil)
    }

    @Test func noBrowserMeansNoBrowserShortcut() {
        var c = context()
        c.routes = RouteAvailability(toolFamilies: [], browserOnDemand: false)
        #expect(DirectPlan.make("Search YouTube for lofi", context: c) == nil)
    }
}
