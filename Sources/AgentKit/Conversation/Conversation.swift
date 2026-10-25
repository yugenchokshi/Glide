import Foundation

// The conversation contract between Glide's three layers:
//   • the voice layer (GlideApp) hears the user, shows and speaks what Glide says;
//   • the conversation layer (TaskController) decides what an utterance means — an answer, a
//     change to the running task, "stop", or a new request — and asks questions while it works;
//   • instant actions (AgentKit/Instant) handle simple requests ("open ChatGPT") with no model.
// Everything the user says or types goes to `TaskController.handleUtterance`; everything Glide
// wants said comes out of `TaskController.onSpeech` as a `SpeechCue`.

/// Where an utterance came from. Voice answers are often short ("the blue ones", "yes"), so the
/// conversation layer reads them in the context of what Glide just asked.
public enum UtteranceSource: String, Codable, Sendable {
    case voice
    case typed
    /// The user tapped one of a question's option chips; the text is that option, verbatim.
    case option
}

/// A question Glide asks while it keeps working ("Which socks? Athletic crew, no-show or wool?").
/// Only the steps that need the answer wait for it.
public struct AgentQuestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Shown in the notch.
    public var text: String
    /// A few words to say out loud ("Which size?"); nil means say `text`.
    public var spoken: String?
    /// 0–4 short options, shown as chips and accepted when said.
    public var options: [String]
    /// Used when no answer comes within `ConversationSettings.defaultAfterSeconds`, and only
    /// when `lowRisk` (never for buying, sending, deleting or anything irreversible).
    public var defaultOption: String?
    public var lowRisk: Bool
    /// A yes/no approval of a risky action rather than a free question.
    public var isApproval: Bool
    public var taskID: String?

    public init(id: String = UUID().uuidString, text: String, spoken: String? = nil, options: [String] = [],
                defaultOption: String? = nil, lowRisk: Bool = false, isApproval: Bool = false, taskID: String? = nil) {
        self.id = id
        self.text = text
        self.spoken = spoken
        self.options = options
        self.defaultOption = defaultOption
        self.lowRisk = lowRisk
        self.isApproval = isApproval
        self.taskID = taskID
    }

    public var spokenText: String { spoken ?? text }
}

/// Something Glide wants to say. The voice layer speaks it according to `VoiceSettings.speakMode`
/// and always shows it in the notch.
public enum SpeechCue: Sendable, Hashable {
    /// "On it." — only for planned work expected to take a while (at most 4 words). Instant
    /// actions say nothing: the user sees the app open.
    case ack(String)
    /// At most once per task, after about 45 seconds: "Still on it."
    case progress(String)
    /// A question; after speaking it, the voice layer listens for the answer without a tap.
    case question(AgentQuestion)
    /// The result in a few words: "Socks are in your cart." (`SpokenLine` keeps it short.)
    case result(String)
    /// Glide stopped and needs the user: "I need you to log in to Gmail."
    case needsYou(String)
    case error(String)
}

/// What an instant action did. Instant actions run before any model, in milliseconds.
public struct InstantResult: Sendable, Hashable {
    /// A 1–3 word line for the screen only ("Opening ChatGPT."); instant actions aren't spoken.
    public var ack: String
    /// One line for the activity log and history.
    public var summary: String
    /// Asked without blocking afterwards: "Want me to do anything in ChatGPT?"
    public var followUp: AgentQuestion?
    /// The part of the request still left for the planner ("…and ask it about X"), or nil when
    /// the instant action handled everything.
    public var remainder: String?
    /// What was done, for the planner when there is a remainder: "ChatGPT (desktop app) is open
    /// and in front."
    public var context: String?

    public init(ack: String, summary: String, followUp: AgentQuestion? = nil, remainder: String? = nil, context: String? = nil) {
        self.ack = ack
        self.summary = summary
        self.followUp = followUp
        self.remainder = remainder
        self.context = context
    }
}

/// Hook installed by the instant-actions module (`InstantActionsSetup.install()`). Returns nil
/// when the request isn't something it handles, so the planner takes it.
public enum InstantActions {
    nonisolated(unsafe) public static var handler: (@Sendable (_ utterance: String) async -> InstantResult?)?
}
