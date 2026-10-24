import Foundation

/// How the job engine obtains a step executor without depending on its implementation.
/// CONTRACT: the step-runner layer installs `make` at launch (the standard StepRouter that
/// dispatches GUI routes to the GUI loop and everything else to the tool loop). Tests inject
/// their own executor directly.
public enum StepExecutorFactory {
    public typealias Make = @Sendable (_ settings: AppSettings, _ runtime: AutomationRuntime, _ tools: ToolRegistry) -> any StepExecuting
    nonisolated(unsafe) public static var make: Make?
}
