import AgentKit

/// What Glide says out loud for each cue. Everything is shown in the notch either way; the
/// speak mode only decides what is also spoken, so a quiet setting never hides information.
enum SpeechPolicy {
    enum Kind: String, Sendable, CaseIterable {
        case ack, progress, question, result, needsYou, error
    }

    static func kind(of cue: SpeechCue) -> Kind {
        switch cue {
        case .ack: return .ack
        case .progress: return .progress
        case .question: return .question
        case .result: return .result
        case .needsYou: return .needsYou
        case .error: return .error
        }
    }

    /// The kinds each mode speaks. Questions and "needs you" are spoken in every mode but
    /// `.never`: they are the moments the user has to act, often while looking elsewhere.
    static func spokenKinds(_ mode: SpeakMode) -> Set<Kind> {
        switch mode {
        case .everything: return Set(Kind.allCases)
        case .questionsAndResults: return [.ack, .question, .result, .needsYou, .error]
        case .questionsOnly: return [.question, .needsYou]
        case .never: return []
        }
    }

    static func shouldSpeak(_ cue: SpeechCue, mode: SpeakMode) -> Bool {
        spokenKinds(mode).contains(kind(of: cue))
    }

    /// The words to say: a question's shorter spoken form when it has one.
    static func spokenText(_ cue: SpeechCue) -> String {
        switch cue {
        case .question(let q): return q.spokenText
        default: return shownText(cue)
        }
    }

    /// The line the notch shows.
    static func shownText(_ cue: SpeechCue) -> String {
        switch cue {
        case .ack(let s), .progress(let s), .result(let s), .needsYou(let s), .error(let s): return s
        case .question(let q): return q.text
        }
    }
}

extension SpeakMode {
    /// Settings labels, short enough for a segmented control.
    var title: String {
        switch self {
        case .everything: return "Everything"
        case .questionsAndResults: return "Questions & results"
        case .questionsOnly: return "Questions only"
        case .never: return "Nothing"
        }
    }

    var detail: String {
        switch self {
        case .everything: return "Glide says what it's starting, how it's going on long tasks, its questions and the result."
        case .questionsAndResults: return "Glide says what it's starting, its questions and the result. Progress stays on screen."
        case .questionsOnly: return "Glide only speaks up when it needs an answer from you."
        case .never: return "Glide stays quiet. Everything still shows in the notch."
        }
    }
}
