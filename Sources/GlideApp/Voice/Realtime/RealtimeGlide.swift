import Foundation
import AgentKit

/// What the realtime voice needs from Glide's agent. `TaskController` in the app; a fake in tests.
@MainActor
protocol GlideControlling: AnyObject {
    var pendingQuestion: AgentQuestion? { get }
    var phase: AgentPhase { get }
    var status: String { get }
    var isRunning: Bool { get }
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
    You are Glide, a cool, quick assistant living in the Mac's notch. Talk like a sharp friend: very short, casual, confident. \
    Never read out search results, links, lists or technical details unless asked. Don't narrate what you're doing. \
    When the user wants something done on the Mac or web, call run_task right away (don't ask first unless something essential is missing); \
    for 'open X' call open_app_or_site. Call tools silently: say nothing before a tool call, and after run_task say at most two words ("On it."). \
    While a task runs, stay quiet unless Glide reports a question, a result or a problem; \
    then say it in a few words. When Glide has asked a question and the user answers it, call answer_glide with their answer. \
    To stop, pause or continue the running task, call control.
    """

    nonisolated static let tools: [RealtimeTool] = [
        RealtimeTool(name: "run_task",
                     description: "Have Glide do something on the Mac or the web (it clicks, types and browses for the user). Returns at once; Glide reports back later.",
                     parameters: [("instruction", "What to do, in the user's words, with every detail they gave.", nil)]),
        RealtimeTool(name: "open_app_or_site",
                     description: "Open an app, website or file right away, e.g. 'Safari', 'youtube.com', 'Notes'.",
                     parameters: [("target", "The app, site or file to open.", nil)]),
        RealtimeTool(name: "answer_glide",
                     description: "Give Glide the user's answer to the question it asked.",
                     parameters: [("answer", "The user's answer, in their words.", nil)]),
        RealtimeTool(name: "control",
                     description: "Stop, pause or resume the task Glide is running.",
                     parameters: [("action", "What to do with the running task.", ["stop", "pause", "resume"])]),
    ]

    /// Runs one tool call and returns its output (JSON text) for `function_call_output`.
    static func dispatch(_ call: RealtimeFunctionCall, to glide: any GlideControlling) -> String {
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
    static func conversationItem(for cue: SpeechCue) -> (text: String, respond: Bool)? {
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
            return ("Glide finished: \(s) Tell the user in a few words.", true)
        case .needsYou(let s):
            return ("Glide needs the user: \(s) Tell them in a few words.", true)
        case .error(let s):
            return ("Glide hit a problem: \(s) Tell the user briefly.", true)
        }
    }
}
