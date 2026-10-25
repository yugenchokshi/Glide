import Foundation

/// The conversation one quick task has with the user while it works: the questions it asks
/// and the notes the user adds ("make it size 10"). Glide asks without stopping: a question is
/// posted, the work that doesn't depend on it carries on, and only what needs the answer
/// waits for it (`waitForAnswer`). Questions are shown one at a time, in the order they were
/// asked; an approval jumps the queue because the task is already stopped on it.
///
/// Thread-safe: the orchestrator and the step runners use it from their tasks, the controller
/// from the main actor. Everything it wants shown or said goes out through `emit`, in order;
/// `emit` runs under the lock, so it must only hand the event on (yield it to a stream, append
/// it to a list) and never call back into the conversation.
public final class TaskConversation: @unchecked Sendable {
    public enum Event: Sendable, Hashable {
        /// Something to say (always shown too).
        case speech(SpeechCue)
        /// The question now shown in the notch, or nil when none is open.
        case question(AgentQuestion?)
    }

    public let taskID: String?
    /// Seconds before an unanswered low-risk question takes its default (0 = always wait).
    public let defaultAfter: TimeInterval
    /// While true, a low-risk default doesn't kick in (the user paused the task).
    public var isPaused: @Sendable () -> Bool {
        get { lock.withLock { _isPaused } }
        set { lock.withLock { _isPaused = newValue } }
    }

    private let lock = NSLock()
    private let emit: @Sendable (Event) -> Void
    private var _isPaused: @Sendable () -> Bool = { false }
    /// Every question asked, by id.
    private var asked: [String: AgentQuestion] = [:]
    /// Unanswered questions in display order; the first is the one shown.
    private var queue: [String] = []
    private var answers: [String: String] = [:]
    /// Questions answered by their default because the user said nothing.
    private var defaulted: Set<String> = []
    private var waiters: [String: [UUID: CheckedContinuation<String?, Never>]] = [:]
    private var notes: [String] = []
    private var closed = false
    private var defaultTimer: Task<Void, Never>?

    public init(taskID: String? = nil, defaultAfter: TimeInterval, emit: @escaping @Sendable (Event) -> Void) {
        self.taskID = taskID
        self.defaultAfter = defaultAfter
        self.emit = emit
    }

    // MARK: Reading

    /// The question shown now.
    public var current: AgentQuestion? { lock.withLock { queue.first.flatMap { asked[$0] } } }
    public var isClosed: Bool { lock.withLock { closed } }
    public func question(_ id: String) -> AgentQuestion? { lock.withLock { asked[id] } }
    public func answer(for id: String) -> String? { lock.withLock { answers[id] } }
    /// True when silence picked the answer (the low-risk default).
    public func wasDefaulted(_ id: String) -> Bool { lock.withLock { defaulted.contains(id) } }
    /// Asked and still waiting for an answer.
    public func isOpen(_ id: String) -> Bool { lock.withLock { queue.contains(id) } }
    /// Every unanswered question, the shown one first.
    public var openQuestions: [AgentQuestion] { lock.withLock { queue.compactMap { asked[$0] } } }

    // MARK: Speaking and asking

    public func speak(_ cue: SpeechCue) {
        lock.withLock {
            guard !closed else { return }
            emit(.speech(cue))
        }
    }

    /// Posts a question without waiting. `first` shows it at once ahead of the others (an
    /// approval); the one it displaces is shown again afterwards. A question already asked
    /// (same id) is ignored.
    public func post(_ question: AgentQuestion, first: Bool = false) {
        lock.withLock {
            guard !closed, asked[question.id] == nil else { return }
            var q = question
            if q.taskID == nil { q.taskID = taskID }
            // Silence never decides an approval or anything that isn't a plain preference.
            if q.isApproval || !q.lowRisk { q.defaultOption = nil }
            q.options = Array(q.options.prefix(4))
            asked[q.id] = q
            let wasCurrent = queue.first
            if first { queue.insert(q.id, at: 0) } else { queue.append(q.id) }
            if queue.first != wasCurrent { showCurrentLocked() }
        }
    }

    /// Posts a question; with `wait`, suspends until it's answered and returns the answer
    /// (nil when the task ended or the question was withdrawn first). Without, returns nil at
    /// once and the answer arrives later as a note (`takeNotes`).
    @discardableResult
    public func ask(_ question: AgentQuestion, wait: Bool) async -> String? {
        post(question)
        guard wait else { return nil }
        return await waitForAnswer(question.id)
    }

    /// The answer to `id`, waiting for it if needed. Nil when the conversation closes (the task
    /// stopped or finished), the question is withdrawn, the task is cancelled, or no such
    /// question was asked.
    public func waitForAnswer(_ id: String) async -> String? {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                lock.withLock {
                    if let a = answers[id] { c.resume(returning: a); return }
                    guard !closed, asked[id] != nil, queue.contains(id), !Task.isCancelled else { c.resume(returning: nil); return }
                    waiters[id, default: [:]][token] = c
                }
            }
        } onCancel: {
            lock.withLock { waiters[id]?.removeValue(forKey: token) }?.resume(returning: nil)
        }
    }

    // MARK: Answering

    /// Records the user's answer. False when the question isn't open (already answered,
    /// withdrawn, or the task ended). When nothing is waiting for it, the answer becomes a
    /// note, so the step already running hears it at its next turn.
    @discardableResult
    public func answer(_ id: String, with text: String) -> Bool {
        lock.withLock { answerLocked(id, text: text, defaulted: false) }
    }

    /// Takes a question back without an answer (an approval answered with the notch's buttons).
    public func withdraw(_ id: String) {
        lock.withLock {
            guard let i = queue.firstIndex(of: id) else { return }
            queue.remove(at: i)
            resumeWaitersLocked(id, with: nil)
            if i == 0 { showCurrentLocked() }
        }
    }

    // MARK: Notes

    /// Something the user said to the running task ("actually the blue ones"). Step runners
    /// pick it up at their next turn.
    public func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.withLock { if !closed { notes.append(trimmed) } }
    }

    /// The notes not yet delivered, oldest first; each is delivered once.
    public func takeNotes() -> [String] {
        lock.withLock {
            defer { notes.removeAll() }
            return notes
        }
    }

    // MARK: Ending

    /// Ends the conversation: whatever waits gets nil, nothing more is shown or said.
    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            defaultTimer?.cancel()
            defaultTimer = nil
            let hadQuestion = !queue.isEmpty
            queue.removeAll()
            for id in Array(waiters.keys) { resumeWaitersLocked(id, with: nil) }
            if hadQuestion { emit(.question(nil)) }
        }
    }

    // MARK: Internals (lock held)

    private func answerLocked(_ id: String, text: String, defaulted: Bool) -> Bool {
        guard !closed, let q = asked[id], let i = queue.firstIndex(of: id) else { return false }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        answers[id] = answer
        if defaulted { self.defaulted.insert(id) }
        queue.remove(at: i)
        // Whoever waits for this answer gets it directly; otherwise it reaches the running step
        // as a note.
        if !q.isApproval && (waiters[id]?.isEmpty ?? true) {
            notes.append(defaulted ? "No answer to “\(q.text)”, so going with the default: \(answer)"
                                   : "The user answered “\(q.text)”: \(answer)")
        }
        resumeWaitersLocked(id, with: answer)
        if i == 0 { showCurrentLocked() }
        return true
    }

    private func resumeWaitersLocked(_ id: String, with answer: String?) {
        for (_, c) in waiters.removeValue(forKey: id) ?? [:] { c.resume(returning: answer) }
    }

    /// Shows (and says) the question at the front of the queue, and starts its default timer.
    private func showCurrentLocked() {
        defaultTimer?.cancel()
        defaultTimer = nil
        guard let id = queue.first, let q = asked[id] else {
            emit(.question(nil))
            return
        }
        emit(.question(q))
        emit(.speech(.question(q)))
        guard q.lowRisk, !q.isApproval, let fallback = q.defaultOption, defaultAfter > 0 else { return }
        let delay = defaultAfter
        defaultTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // A pause holds the default back: the user may be about to answer.
            while !Task.isCancelled, self?.isPaused() == true { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            self?.applyDefault(id, fallback)
        }
    }

    private func applyDefault(_ id: String, _ fallback: String) {
        lock.withLock {
            guard !closed, queue.first == id else { return }
            // Said before the next question comes up, so the two don't run together.
            emit(.speech(.ack(Self.goingWith(fallback))))
            _ = answerLocked(id, text: fallback, defaulted: true)
        }
    }

    /// What Glide says when silence picks a low-risk default.
    static func goingWith(_ option: String) -> String { "Going with \(option) — say stop to change." }
}
