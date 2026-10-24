import Foundation

/// One call at launch that installs everything the agent can use: the tool families
/// (commands, files, data, web, workspace, browser), the step router the job engine executes
/// steps with, and the browser backends.
public enum AgentSetup {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false

    /// Installs the tool families and step router once per process.
    /// - Parameter startBrowserBridge: only the app hosts the Chrome extension bridge (one
    ///   process can own its port), so the CLI passes false.
    public static func installAll(settings: AppSettings, startBrowserBridge: Bool) {
        let first = lock.withLock { () -> Bool in
            defer { installed = true }
            return !installed
        }
        if first {
            CommandTools.install()
            DataTools.install()
            WebTools.install()
            WorkspaceTools.install()
            BrowserTools.install()
            StepRouter.install()
        }
        if startBrowserBridge { ExtensionBridge.shared.start(settings: settings.browser) }
    }
}
