# Architecture

NotchBuddy is a Swift package with three layers. The UI never touches automation code directly.

```
NotchBuddyApp (SwiftUI + AppKit)      nbctl (CLI)
        │                                │
        ▼                                ▼
     AgentKit  ── providers, planner, orchestrator, safety, history, integrations
        │
        ▼
  AutomationKit ── accessibility, perception, input, verification (no UI, no AI)
```

## Module map (PRD §4.3 → source)

| PRD module | Where |
|---|---|
| NotchUI | `Sources/NotchBuddyApp/Notch/` (`NotchWindow.swift`, `NotchViews.swift`), design system in `BoardKit/` |
| SettingsUI | `Sources/NotchBuddyApp/Settings/`, `Onboarding/` |
| TaskController | `Sources/AgentKit/Controller/TaskController.swift` |
| AgentPlanner | `Sources/AgentKit/Agent/AgentPlanner.swift` (`AgentPlanner`, `ActionSelector`) |
| ExecutionOrchestrator | `Sources/AgentKit/Agent/ExecutionOrchestrator.swift` |
| RecoveryManager | `ExecutionOrchestrator` replan path + `AgentPlanner.replan` |
| AccessibilityEngine | `Sources/AutomationKit/Accessibility/` (engine, AX helpers, `AXEventMonitor`) |
| PerceptionEngine | `Sources/AutomationKit/Perception/PerceptionEngine.swift` |
| ElementGraph | `Sources/AutomationKit/Graph/ElementGraph.swift` (`ScreenObservation`, `ElementGraph`, `ElementMatcher`) |
| ActionResolver | `Sources/AgentKit/Agent/ActionResolver.swift` |
| NativeActionExecutor | `Sources/AutomationKit/Executor/NativeActionExecutor.swift`, `Input/InputSynthesizer.swift` |
| BrowserAdapter | `Sources/AutomationKit/Browser/BrowserAdapter.swift` |
| VisionGrounding | `Sources/AgentKit/Agent/VisionGrounding.swift`, `AutomationKit/Perception/{ScreenCapture,OCR}.swift` |
| VerificationEngine | `Sources/AutomationKit/Verification/VerificationEngine.swift` |
| ProviderManager | `Sources/AgentKit/Providers/` (`ModelRouter`, Anthropic, OpenAI/compatible, Jev) |
| CredentialStore | `Sources/AgentKit/Credentials/CredentialStore.swift` |
| ComposioIntegration | `Sources/AgentKit/Integrations/ComposioClient.swift` |
| MCPManager | `Sources/AgentKit/Integrations/MCPClient.swift` |
| TaskHistory | `Sources/AgentKit/History/` (SQLite) |
| PermissionManager | `Sources/AutomationKit/Permissions/PermissionManager.swift` |
| Skills | `Sources/AgentKit/History/TaskHistory.swift` (`Skill`), editor in Settings |
| Benchmarks | `Sources/AgentKit/Benchmarks/` (`ScriptRunner`, `BenchmarkSuite`) |

## Perception

1. **Accessibility tree.** `AccessibilityEngine.observe` walks the focused window, plus any dialogs, with one batched `AXUIElementCopyMultipleAttributeValues` call per node. It keeps interactive and readable nodes, skips subtrees that are scrolled out of view, and stays within node, depth and time limits. Chromium and Electron apps get `AXManualAccessibility` / `AXEnhancedUserInterface` so they expose their DOM.
2. **Element graph.** `ElementGraph.assignIDs` gives each node an id (`e12`) that stays stable across observations whenever its identity (source, role, label, identifier, ancestry) is unchanged. That gives element continuity and cheap diffs. Ids are scoped to observations and revalidated before use.
3. **Cache.** Snapshots are cached until `AXEventMonitor` sees an AX notification for that app. It runs on its own run-loop thread and records focus, value, window, layout and other changes. A cached lookup is about 0.01 ms.
4. **OCR.** When a window exposes fewer than four interactive elements, or the resolver can't find a target, Apple Vision OCR adds `.ocr` text nodes taken from a ScreenCaptureKit capture of the window.
5. **Vision model.** This is the last resort. The window capture is redacted (secure fields blacked out) and sent only with the user's consent. The returned coordinates are checked against the image and window geometry before any click.

The model sees a compact, indexed UI skeleton (`ScreenObservation.compact`), not a screenshot:

```
app: Notes | window: "All iCloud"
focused: e31 textarea "Note body"
e3 button "New Note" in "Toolbar"
e7 searchfield "Search"
e31 textarea "Note body" value="Meeting…" [focused]
```

## Acting

`NativeActionExecutor` handles one action vocabulary, `ComputerAction`: click, double click, right click, type, key, scroll, drag, focus, set value, select text, menu path, launch app, activate app, open URL, and wait. Before each action it:

- **Revalidates the target** against live AX state (frame, enabled). If the element was destroyed, it re-finds it by fingerprint.
- **Hit-tests the point.** If the target really is under the cursor, it clicks with real `CGEvent`s. If something covers the target, it still moves the cursor there so you can see it, then uses the AX press or show-menu action.
- **Types** short text as Unicode keyboard events and pastes long text, restoring the clipboard afterwards. It refuses secure text fields.
- **Tags every event** so `UserInterferenceMonitor` can tell agent input from yours. If you grab the mouse, the agent pauses.

Every injected event passes through `ExecutionGate`, a shared stop and pause switch. Emergency stop flips it, and the next event post throws. The benchmark measures stop latency at about 2 ms.

## Verifying

`VerificationEngine` checks outcomes from structured state, not screenshot diffs. It can check that an app is frontmost, that the focused field contains the typed text, that an element appeared or disappeared, that the window title changed, that a file exists, or that the UI changed at all (using the AX change counter). Waits are event-driven, with no fixed sleeps.

## The agent loop

`ExecutionOrchestrator.run`:

1. **Plan.** The planner model gets the request, frontmost app, running apps, browser page, connected Composio toolkits, MCP tools and relevant saved skills. It returns 2–8 steps, each with a route (`native`, `gui`, `composio`, `mcp`, `answer`), a risk level, a done-when condition and an optional deterministic hint.
2. **Execute each step.** If the step's hint resolves unambiguously, it runs with no model call. Otherwise the fast action-selection model chooses one action from the UI skeleton. `ActionResolver` maps that choice to a `ComputerAction`. Close candidates can be settled by Jev's calibrated Choice when configured, and unresolved targets go to `VisionGrounding`.
3. **Check safety.** `SafetyPolicy` combines deterministic rules with the model's risk label. Rules include send, delete and purchase wording, Return in messaging apps, ⌘⌫, destructive shell commands, password fields, card numbers and excluded apps. Anything that needs approval pauses for the user.
4. **Act and verify.** The executor runs the action, then verification checks the result. Each result is appended to the step history the next model call sees.
5. **Stop when progress stops.** Limits cover steps, actions per step and per task, retries, the task timeout and repeated identical actions. After four actions with no visible effect, the step fails. A failed step triggers up to `maxReplans` recovery plans from the current screen, after which the task fails with an explanation.

Integration steps (`composio`, `mcp`) use the same selector with a tool list. Composio's session search returns the candidate tools and their schemas.

## Model routing

`ModelRouter` resolves each role to a provider and model. In automatic mode:

| Role | Anthropic | OpenAI |
|---|---|---|
| Planner | `claude-opus-5-5` (effort low) | `gpt-luna-6` |
| Action selection | `claude-haiku-5-5` (effort low) | `gpt-luna-6` |
| Vision | `claude-opus-5-5` | `gpt-luna-6` |
| Recovery | `claude-opus-5-5` (effort medium) | `gpt-luna-6` |

Manual mode lets you pick provider, model and effort per role. Structured replies use Anthropic `output_config.format` and OpenAI `response_format: json_schema`. Both degrade automatically to JSON-in-prompt for endpoints that don't support those formats.

## Persistence

- Settings: JSON in `UserDefaults` (domain `dev.notchbuddy.app`, shared with `nbctl`). Contains no secrets.
- Secrets: Keychain generic passwords under the `dev.notchbuddy.credentials` service.
- History and skills: SQLite at `~/Library/Application Support/NotchBuddy/notchbuddy.sqlite`. Text is scrubbed of anything that looks like a key before it's written.

## Concurrency

The UI runs on the main actor. `TaskController` starts the orchestrator in a detached task. AX calls are synchronous, thread-safe IPC wrapped in `@unchecked Sendable` engines. AX notifications and the interference event tap each run on a dedicated run-loop thread. Swift 6 language mode is enabled for every target.
