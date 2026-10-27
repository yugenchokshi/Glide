import Foundation
import AgentKit

/// What the realtime voice needs from Glide's agent. `TaskController` in the app; a fake in tests.
@MainActor
protocol GlideControlling: AnyObject {
    var pendingQuestion: AgentQuestion? { get }
    var phase: AgentPhase { get }
    var status: String { get }
    var isRunning: Bool { get }
    var lastFinished: TaskController.FinishedRequest? { get }
    func handleUtterance(_ text: String, source: UtteranceSource)
    func answer(questionID: String, with text: String)
    func pause()
    func resume()
    func stop()
}

extension TaskController: GlideControlling {}

/// Glide as the realtime model's tools: the persona, the tool list, running a tool call, and
/// turning Glide's speech cues into conversation items.
@MainActor
enum RealtimeGlide {
    nonisolated static let instructions = """
    You are Glide, a cool, quick assistant living in the Mac's notch, talking with the user by voice. \
    Talk like a sharp friend: short, casual, confident, one voice. \
    You can't see the screen, web pages, email, profiles or files yourself; Glide can. So for anything \
    about what's on screen or online (what's on this page, who is this person, what's in my inbox) \
    and anything to do on the Mac or web, call run_task at once. Never say you can't see something, \
    and never guess an answer Glide is about to find. Call tools silently: say nothing before or \
    after run_task; Glide reports back and you speak then. For 'open X' call open_app_or_site. \
    When Glide reports a result, answer the user's request from it in your own words, like a \
    conversation: the answer itself in one short sentence (two only if they asked for details), no \
    lists, links or technical details unless asked. Say each thing once. Never say something is done, \
    paused, sent or found until Glide reports it. \
    The microphone also hears videos, ads, music and other people. If what you hear isn't clearly the \
    user talking to you (lyrics, an ad, a stray word like "careful"), say nothing and call nothing. When Glide asks a question, ask it in a few words; when the \
    user answers, call answer_glide with their answer. To stop, pause or continue the running task, \
    call control. \
    You have memory. When the user asks you to remember something, or tells you a lasting fact or \
    preference (their name, who their manager is, how they like emails signed), call remember with \
    it as one short sentence, then say "Got it." When they ask you to forget something, call forget. \
    Use what you remember and what Glide did recently (below) to resolve "it", "him", "that email", \
    and when you call run_task, put the facts it needs into the instruction ("email Priya, my manager, \
    at priya@acme.com"). The instruction is the user's request in their words plus those facts only: \
    never add steps they didn't ask for, even if an earlier task did more.
    """

    nonisolated static let tools: [RealtimeTool] = [
        RealtimeTool(name: "run_task",
                     description: "Have Glide do something on the Mac or the web (it clicks, types and browses for the user). Returns at once; Glide reports back later.",
                     parameters: [("instruction", "Exactly what the user asked, in their words, plus facts they referred to (names, emails). Never add a step: 'search YouTube for jazz' stays 'Search YouTube for jazz', not '…and open the first result'.", nil)]),
        RealtimeTool(name: "open_app_or_site",
                     description: "Open an app, website or file right away, e.g. 'Safari', 'youtube.com', 'Notes'.",
                     parameters: [("target", "The app, site or file to open.", nil)]),
        RealtimeTool(name: "answer_glide",
                     description: "Give Glide the user's answer to the question it asked.",
                     parameters: [("answer", "The user's answer, in their words.", nil)]),
        RealtimeTool(name: "remember",
                     description: "Save a fact or preference about the user for future conversations.",
                     parameters: [("fact", "One short sentence, e.g. 'The user's manager is Priya Shah (priya@acme.com).'", nil)]),
        RealtimeTool(name: "forget",
                     description: "Delete saved facts that mention something.",
                     parameters: [("about", "A word or phrase the facts to delete contain, e.g. 'manager'.", nil)]),
        RealtimeTool(name: "control",
                     description: "Stop, pause or resume the task Glide is running. Only when the user clearly tells you to (\"stop\", \"cancel that\", \"hold on\").",
                     parameters: [("action", "What to do with the running task.", ["stop", "pause", "resume"])]),
    ]

    /// Runs one tool call and returns its output (JSON text) for `function_call_output`.
    static func dispatch(_ call: RealtimeFunctionCall, to glide: any GlideControlling, memory: LocalStore? = nil) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
        func arg(_ key: String) -> String { (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let result: String
        switch call.name {
        case "run_task":
            let instruction = arg("instruction")
            guard !instruction.isEmpty else { return output("error", "No instruction given.", glide) }
            glide.handleUtterance(instruction, source: .voice)
            result = "started"
        case "open_app_or_site":
            let target = arg("target")
            guard !target.isEmpty else { return output("error", "No target given.", glide) }
            glide.handleUtterance("open " + target, source: .voice)
            result = "opening"
        case "answer_glide":
            let answer = arg("answer")
            guard !answer.isEmpty else { return output("error", "No answer given.", glide) }
            if let q = glide.pendingQuestion {
                glide.answer(questionID: q.id, with: answer)
            } else {
                glide.handleUtterance(answer, source: .voice)
            }
            result = "answered"
        case "remember":
            let fact = arg("fact")
            guard !fact.isEmpty else { return output("error", "No fact given.", glide) }
            guard let memory else { return output("unavailable", nil, glide) }
            memory.addMemory(fact)
            result = "remembered"
        case "forget":
            let about = arg("about")
            guard !about.isEmpty else { return output("error", "Nothing to forget given.", glide) }
            guard let memory else { return output("unavailable", nil, glide) }
            let count = memory.forgetMemories(matching: about)
            return output(count == 0 ? "nothing_matched" : "forgot", "\(count) saved fact(s) deleted.", glide)
        case "control":
            switch arg("action").lowercased() {
            case "stop":
                guard glide.isRunning else { return output("nothing_running", nil, glide) }
                glide.stop()
                result = "stopped"
            case "pause":
                guard glide.phase == .executing || glide.phase == .planning else { return output("not_running", nil, glide) }
                glide.pause()
                result = "paused"
            case "resume":
                guard glide.phase == .paused else { return output("not_paused", nil, glide) }
                glide.resume()
                result = "resumed"
            default:
                return output("error", "Unknown action.", glide)
            }
        default:
            return output("error", "Unknown tool \(call.name).", glide)
        }
        return output(result, nil, glide)
    }

    /// `{"result": …, "glide": {"phase": …, "status": …, "question": …}}`
    static func output(_ result: String, _ detail: String?, _ glide: any GlideControlling) -> String {
        var g: [String: Any] = ["phase": glide.phase.rawValue]
        if !glide.status.isEmpty { g["status"] = String(glide.status.prefix(160)) }
        if let q = glide.pendingQuestion { g["question"] = q.spoken ?? q.text }
        var d: [String: Any] = ["result": result, "glide": g]
        if let detail { d["detail"] = detail }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{\"result\":\"\(result)\"}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// What a speech cue adds to the conversation, and whether the model should answer it now.
    /// Acks and progress are left out: the model speaks for itself and stays quiet while Glide works.
    static func conversationItem(for cue: SpeechCue, finished: TaskController.FinishedRequest? = nil) -> (text: String, respond: Bool)? {
        switch cue {
        case .ack, .progress:
            return nil
        case .question(let q):
            var text = "Glide asks the user: \"\(q.spoken ?? q.text)\""
            if !q.options.isEmpty { text += " Options: \(q.options.joined(separator: ", "))." }
            text += q.isApproval ? " This needs a clear yes or no." : ""
            text += " Ask the user in your own words, in a few words, then wait. Pass their reply to answer_glide."
            return (text, true)
        case .result(let s):
            if let done = finished, done.status == .completed, done.summary.count > s.count {
                return ("Glide finished the request “\(clip(done.instruction, 300))”. Its full result: \(clip(done.summary, 2000)) " +
                        "Answer the user from this, conversationally and briefly. Don't repeat anything you already said.", true)
            }
            return ("Glide finished: \(s) Tell the user in a few words.", true)
        case .needsYou(let s):
            return ("Glide needs the user: \(s) Tell them in a few words.", true)
        case .error(let s):
            return ("Glide hit a problem: \(s) Tell the user briefly.", true)
        }
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) + "…" }
}
