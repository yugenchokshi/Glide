import AppKit

MainActor.assumeIsolated {
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        _ = NSApplication.shared
        SnapshotRenderer.run(into: CommandLine.arguments[i + 1])
        exit(0)
    }
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot-settings"), i + 1 < CommandLine.arguments.count {
        _ = NSApplication.shared
        SettingsSnapshotRenderer.run(into: CommandLine.arguments[i + 1])
        exit(0)
    }
    // Created first, so `NSApp` is the subclass that drops the agent's own input.
    let app = GlideApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
