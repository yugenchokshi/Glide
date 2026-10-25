import Foundation

/// Installs the instant-actions handler (`InstantActions.handler`). Called once at launch by
/// `AgentSetup.installAll`.
public enum InstantActionsSetup {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var engine: InstantActionEngine?

    /// Installs the live engine (this Mac's apps, NSWorkspace, Glide's browser). Settings are
    /// read per request, so turning off "offer next step" or switching browser backends
    /// applies to the very next utterance. The app folders are indexed in the background now,
    /// so the first "open …" doesn't pay for the scan.
    public static func install() {
        SystemAppIndex.shared.warmUp()
        install(engine: .live())
    }

    /// Installs a specific engine (tests, or a host with its own opener).
    public static func install(engine: InstantActionEngine) {
        lock.withLock { self.engine = engine }
        InstantActions.handler = { utterance in await engine.handle(utterance) }
        // `glidectl say --dry-run`: nil when the utterance isn't an instant action.
        InstantPreview.describe = { utterance in
            await engine.plan(utterance, useAssist: false) == nil ? nil : await engine.describe(utterance)
        }
    }

    /// Describes what `utterance` would do — which app or URL, what Glide would say, what's left
    /// for the planner — without opening anything or asking Jev. Backs `glidectl say --dry-run`.
    public static func dryRun(_ utterance: String) async -> String {
        let current = lock.withLock { engine } ?? .live()
        return await current.describe(utterance)
    }

    /// The plan for `utterance` without doing it, for callers that want the structured form.
    public static func dryRunPlan(_ utterance: String) async -> InstantPlan? {
        let current = lock.withLock { engine } ?? .live()
        return await current.plan(utterance, useAssist: false)
    }
}
