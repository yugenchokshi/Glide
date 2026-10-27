import Foundation

/// One-step plans for simple requests ("reply to the top email", "start a new chat"), so they
/// skip the planning call (3–10 s) and go straight to the step. Anything that looks like more
/// than one step, a purchase, or a long job still goes to the planner.
enum DirectPlan {
    static func make(_ instruction: String, context: PlanningContext) -> Plan? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = " " + text.lowercased() + " "
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= maxWords else { return nil }
        guard !plannerMarkers.contains(where: lower.contains) else { return nil }
        // More than one sentence is usually more than one step.
        guard text.range(of: #"[.!?]\s+\S"#, options: .regularExpression) == nil else { return nil }

        let route: ExecutionRoute
        let app: String?
        if namesWebsite(lower), browserUsable(context) {
            route = .browser
            app = nil
        } else if context.browserPage != nil, !namesOtherApp(lower, front: context.frontmostApp), browserUsable(context) {
            // A browser page is in front and the request doesn't name another app: it's about that page.
            route = .browser
            app = nil
        } else if let front = context.frontmostApp, context.conversation?.contains("is open and in front") == true,
                  context.browserPage == nil, context.routes?.accessibilityGranted ?? true {
            // Right after an instant "open X": the request is about the app that just opened.
            route = .gui
            app = front
        } else {
            return nil
        }
        var instructionWithContext = text
        if let earlier = context.conversation?.trimmingCharacters(in: .whitespacesAndNewlines), !earlier.isEmpty {
            instructionWithContext += "\n\nWhat happened just before (for words like “it” or “them”):\n" + earlier
        }
        if let memory = context.memory?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
            instructionWithContext += "\n\nWhat the user asked you to remember:\n" + String(memory.prefix(1500))
        }
        let step = PlanStep(id: 1, title: title(text), instruction: instructionWithContext, route: route, app: app, risk: .medium,
                            doneWhen: "The user's request is done: \(text)", hint: nil)
        return Plan(goal: text, steps: [step], clarification: nil, mode: .quick)
    }

    static let maxWords = 20

    /// Phrases that mean several steps, a purchase (questions and approvals the planner sets up)
    /// or a long job.
    static let plannerMarkers = [
        " then ", " after that", " afterwards", " and also ", "; ", " every ", " each ", " all of ", " list of ",
        " spreadsheet", " research", " compare", " for all ", " buy ", " order ", " cart", " checkout", " purchase",
        " book a ", " book the ", " pay ", " schedule ", " every day", " daily", " weekly",
    ]

    static let websites = [
        "gmail", "youtube", "linkedin", "twitter", "x.com", "amazon", "google", "reddit", "github", "facebook",
        "instagram", "netflix", "wikipedia", "chatgpt.com", "notion.so", "outlook.com", "google docs", "google sheets",
        "google drive", "google calendar",
    ]

    static func namesWebsite(_ lower: String) -> Bool {
        if websites.contains(where: { lower.contains($0) }) { return true }
        return lower.range(of: #"\b[a-z0-9-]+\.(com|org|net|io|ai|co|in|dev|app)\b"#, options: .regularExpression) != nil
    }

    /// Native apps a request might name instead of the page in front.
    static let nativeApps = ["notes", "finder", "mail app", "calendar app", "messages", "slack", "whatsapp", "spotify",
                             "music", "numbers", "pages", "keynote", "terminal", "xcode", "cursor", "claude app", "chatgpt app"]

    static func namesOtherApp(_ lower: String, front: String?) -> Bool {
        let front = front?.lowercased() ?? ""
        return nativeApps.contains { lower.contains(" \($0)") && !front.contains($0) }
    }

    static func browserUsable(_ context: PlanningContext) -> Bool {
        guard let routes = context.routes else { return true }
        return routes.toolFamilies.contains(.browser) && ((routes.browser?.connected ?? false) || routes.browserOnDemand)
    }

    /// "Draft a reply to Sam" → "Draft a reply to Sam"; long requests are cut to a few words.
    static func title(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}
