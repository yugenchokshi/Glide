import Testing
import Foundation
@testable import AgentKit

// Glide's spoken style: quiet, brief, casual and confident. These pin the wording rules so a
// model's chatty line never reaches the speaker as is.

@Suite("Spoken lines stay short")
struct SpokenLineTests {
    static func words(_ s: String) -> Int { s.split(separator: " ").count }

    @Test func tidyRemovesWhatNeverSoundsRight() {
        #expect(SpokenLine.tidy("Done. Added **Hanes crew socks** to your cart.") == "Added Hanes crew socks to your cart.")
        #expect(SpokenLine.tidy("Added the socks. Done.") == "Added the socks.")
        #expect(SpokenLine.tidy("Done.") == "Done.")
        #expect(SpokenLine.tidy("Opened the page at https://www.amazon.com/s?k=socks") == "Opened the page.")
        #expect(!SpokenLine.tidy("Clicked e3045 then b31 (the Send button).").contains("e3045"))
        #expect(!SpokenLine.tidy("Clicked e3045 then b31 (the Send button).").contains("b31"))
        #expect(!SpokenLine.tidy("Clicked e3045 then b31 (the Send button).").contains("Send button"))
        #expect(SpokenLine.tidy("Sent it to [Sam](mailto:sam@example.com) at sam@example.com.") == "Sent it to Sam.")
        #expect(SpokenLine.tidy("`Draft` saved in Gmail") == "Draft saved in Gmail.")
        #expect(SpokenLine.tidy("Draft's ready in Gmail.\nTo: Sam\nSubject: Lunch") == "Draft's ready in Gmail.")
    }

    @Test func tidyCutsLongLinesAtAClause() {
        let long = "I found three pairs of running shoes, the Nike Pegasus, the Brooks Ghost and the Hoka Clifton, all in size ten"
        let t = SpokenLine.tidy(long)
        #expect(Self.words(t) <= SpokenLine.maxWords)
        #expect(t == "I found three pairs of running shoes, the Nike Pegasus.")
        #expect(t.last.map { ".!?…".contains($0) } == true)
        let flat = Array(repeating: "word", count: 30).joined(separator: " ")
        #expect(Self.words(SpokenLine.tidy(flat)) == SpokenLine.maxWords)
    }

    @Test func everyCueIsTidied() {
        #expect(SpokenLine.tidy(SpeechCue.result("Done. Opened https://chatgpt.com")) == .result("Opened."))
        #expect(SpokenLine.tidy(SpeechCue.ack("")) == .ack("On it."))
        // Questions are cleaned but never cut, and untouched when already clean.
        let q = AgentQuestion(id: "q", text: "Which socks — athletic crew, no-show or wool?")
        #expect(SpokenLine.tidy(SpeechCue.question(q)) == .question(q))
        let messy = AgentQuestion(id: "m", text: "Which one (see b12)?", spoken: "Which one (see b12)?")
        guard case .question(let cleaned) = SpokenLine.tidy(SpeechCue.question(messy)) else { Issue.record("not a question"); return }
        #expect(cleaned.spokenText == "Which one?")
        #expect(cleaned.text == "Which one (see b12)?", "the screen keeps the detail")
    }

    @Test func acksAreOnItStyleAndOnlyForSlowWork() {
        let step = { (route: String) in PlanStep(id: 1, title: "Doing", instruction: "Do it", route: ExecutionRoute(rawValue: route) ?? .command,
                                                   app: nil, risk: .low, doneWhen: "done", hint: nil) }
        #expect(SpokenLine.ack("On it — opening Amazon.") == "On it.")
        #expect(SpokenLine.ack("Got it.") == "Got it.")
        #expect(SpokenLine.ack("Sure thing, I'll start by opening Amazon for you") == "On it.")
        #expect(SpokenLine.ack(nil) == "On it.")
        // One quick step: the user sees it happen.
        #expect(SpokenLine.ack(for: Plan(goal: "g", steps: [step("native")], clarification: nil, ack: "On it.")) == nil)
        #expect(SpokenLine.ack(for: Plan(goal: "g", steps: [step("command")], clarification: nil, ack: "On it.")) == nil)
        // Slow work says it's on it.
        #expect(SpokenLine.ack(for: Plan(goal: "g", steps: [step("browser")], clarification: nil, ack: "On it — opening Amazon.")) == "On it.")
        #expect(SpokenLine.ack(for: Plan(goal: "g", steps: [step("command"), step("web")], clarification: nil, ack: "Got it.")) == "Got it.")
        // A question coming right away is the acknowledgement.
        let asking = Plan(goal: "g", steps: [step("browser"), step("browser")], clarification: nil, ack: "On it.",
                          questions: [AgentQuestion(id: "q1", text: "Which socks?")])
        #expect(SpokenLine.ack(for: asking) == nil)
    }

    @Test func resultsAreAFewWords() {
        // The model's spoken line wins, tidied.
        #expect(SpokenLine.result(summary: "long summary", spoken: "Draft's ready in Gmail.") == "Draft's ready in Gmail.")
        // Fallback: first clause, no addresses or quoted titles, at most 10 words.
        let gmail = "Drafted an email to Sam Lee <sam@example.com> with subject “Lunch on Friday” in Gmail. It's saved in your Drafts folder, ready to send."
        #expect(SpokenLine.result(summary: gmail, spoken: nil) == "Drafted an email to Sam Lee in Gmail.")
        let socks = "Added Hanes Men's Crew Socks, 6-pack, size L ($14.98) to your cart — the cart now has 2 items totalling $29.96."
        let s = SpokenLine.result(summary: socks, spoken: nil)
        #expect(Self.words(s) <= SpokenLine.resultWords && !s.contains("$"))
        // Search results are never read out.
        let search = """
        Top results for “best running shoes 2026”:
        1. Nike Pegasus 41 — $130 — https://www.nike.com/pegasus
        2. Brooks Ghost 16 — $140 — https://www.brooksrunning.com/ghost
        3. Hoka Clifton 9 — $145
        """
        #expect(SpokenLine.result(summary: search, spoken: nil) == SpokenLine.listResult)
        #expect(SpokenLine.shorten("Found: 1. Pegasus 2. Ghost 3. Clifton") == SpokenLine.listResult)
        #expect(SpokenLine.shorten("Started a background job: Email every company in the sheet") == "Started a background job.")
    }

    @Test func aQuestionGetsItsAnswerSaid() {
        #expect(SpokenLine.isQuestion("what time is it in Tokyo?"))
        #expect(SpokenLine.isQuestion("How much is the Pegasus on Nike"))
        #expect(!SpokenLine.isQuestion("add socks to my cart"))
        let tokyo = SpokenLine.result(summary: "It's 3:42 PM on Saturday in Tokyo, which is 16 hours ahead of you. Source: timeanddate.com",
                                      spoken: nil, instruction: "what time is it in Tokyo?")
        #expect(tokyo.hasPrefix("It's 3:42 PM"))
        #expect(Self.words(tokyo) <= SpokenLine.maxWords)
    }

    @Test func needsYouIsShortAndHuman() {
        #expect(SpokenLine.needsYou("Please log in to your bank first.") == "I need you to log in to your bank.")
        #expect(SpokenLine.needsYou("Log in to Gmail in Chrome, then say continue.") == "I need you to log in to Gmail.")
        #expect(SpokenLine.needsYou("Gmail needs you to sign in before I can write the draft.") == "I need you to log in to Gmail.")
        #expect(SpokenLine.needsYou("The page shows a CAPTCHA (element e31); please solve it.") == "I need you to prove you're human.")
        #expect(Self.words(SpokenLine.needsYou("The screen is locked, so I can't keep going with the task until you unlock it and say continue.")) <= 12)
    }

    @Test func errorsSoundLikeAPerson() {
        #expect(SpokenLine.error("Couldn't complete “Adding to cart”") == "I got stuck adding to cart.")
        #expect(SpokenLine.error("Step limit reached") == "That took too many steps.")
        #expect(Self.words(SpokenLine.error("The request to https://api.example.com timed out after 60 seconds while waiting for a response from the server")) <= SpokenLine.resultWords)
    }

    @Test func plannerPromptsCarryTheVoiceRules() {
        #expect(Prompts.voice.contains("at most 8 words"))
        #expect(Prompts.voice.contains("Never read out search results"))
        #expect(Prompts.planner.contains("at most 4 words"))
        #expect(Prompts.planner.contains("\"Which size?\""))
        #expect(Prompts.toolStep.contains(Prompts.voice) && Prompts.actor.contains(Prompts.voice) && Prompts.answerWriter.contains(Prompts.voice))
        #expect(!Prompts.planner.contains("25 words") && !Prompts.toolStep.contains("25 words"))
    }
}
