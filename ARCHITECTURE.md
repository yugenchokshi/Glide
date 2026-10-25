# Architecture

Glide is a Swift package with three layers. The UI never touches automation code directly.

```
GlideApp (SwiftUI + AppKit)      glidectl (CLI)
        │                                │
        ▼                                ▼
     AgentKit  ── providers, planner, orchestrator, step runners, tools, jobs, safety, history, integrations
        │
        ▼
  AutomationKit ── accessibility, perception, input, verification, browser (CDP) (no UI, no AI)
        ▲
        │ WebSocket on 127.0.0.1
Extensions/chrome ── MV3 extension in the user's Chrome (plain JavaScript)
```

## Module map (PRD §4.3 → source)

| PRD module | Where |
|---|---|
| NotchUI | `Sources/GlideApp/Notch/` (`NotchWindow.swift` with `NotchClickGuard`, `NotchViews.swift`), `App/GlideApplication.swift`, design system in `BoardKit/` |
| SettingsUI | `Sources/GlideApp/Settings/`, `Onboarding/` |
| TaskController | `Sources/AgentKit/Controller/TaskController.swift` |
| AgentPlanner | `Sources/AgentKit/Agent/AgentPlanner.swift` (`AgentPlanner`, `ActionSelector`) |
| ExecutionOrchestrator | `Sources/AgentKit/Agent/ExecutionOrchestrator.swift` |
| RecoveryManager | `ExecutionOrchestrator` replan path + `AgentPlanner.replan` |
| AccessibilityEngine | `Sources/AutomationKit/Accessibility/` (engine, AX helpers, `AXEventMonitor`) |
| PerceptionEngine | `Sources/AutomationKit/Perception/PerceptionEngine.swift` |
| ElementGraph | `Sources/AutomationKit/Graph/ElementGraph.swift` (`ScreenObservation`, `ElementGraph`, `ElementMatcher`) |
| ActionResolver | `Sources/AgentKit/Agent/ActionResolver.swift` |
| NativeActionExecutor | `Sources/AutomationKit/Executor/NativeActionExecutor.swift`, `Input/InputSynthesizer.swift` |
| BrowserAdapter | `Sources/AutomationKit/Browser/BrowserAdapter.swift` (page URL, title and text over Apple Events for planning and on-screen steps) |
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

## Module map: tools, browser and jobs

These came after the PRD. [docs/LONG_TASKS_DESIGN.md](docs/LONG_TASKS_DESIGN.md) is the design record.

| Module | Where |
|---|---|
| Tool contract and registry | `Sources/AgentKit/Tools/Tool.swift` (`AgentTool`, `ToolSpec`, `ToolVerdict`, `ToolContext`, `ToolRegistry`) |
| Command, file and system tools | `Sources/AgentKit/Tools/Commands/` (`ShellTools`, `FileTools`, `SystemTools`, `ProcessRunner`; safety in `CommandSafety`, `ShellParser`, `ScriptSafety`, `PathRules`, `PathPattern`) |
| Browser tools | `Sources/AgentKit/Tools/Browser/` (`BrowserTools`, `BrowserRisk`, `BrowserSessions`) |
| Web tools | `Sources/AgentKit/Tools/Web/` (`WebTools`, `WebFetcher`, `WebSearch`, `HTMLText`, `HTMLTokenizer`) |
| Data tools | `Sources/AgentKit/Tools/Data/` (`DataTools`, `Spreadsheet`, `CSV`, `XLSX`), `Tools/TableIO.swift` |
| Workspace tools | `Sources/AgentKit/Tools/Workspace/WorkspaceTools.swift` |
| Launch wiring | `Sources/AgentKit/Setup/AgentSetup.swift` (installs every tool family, the step router and, in the app, the extension bridge) |
| StepRouter | `Sources/AgentKit/Agent/StepRouter.swift`, `StepExecutorFactory.swift` |
| ToolStepRunner | `Sources/AgentKit/Agent/ToolStepRunner.swift` (also wraps Composio and MCP tools) |
| GUIStepRunner | `Sources/AgentKit/Agent/GUIStepRunner.swift` |
| BrowserHub | `Sources/AgentKit/Browser/BrowserHub.swift`, `ExtensionBridgeSetup.swift` |
| Browser backends and driver | `Sources/AutomationKit/Browser/` (`BrowserBackend`, `BrowserDriver`, `CDPWebSocket`, `GlideChromeBackend`, `ExtensionBackend`, `ExtensionBridge`) |
| Chrome extension | `Extensions/chrome/` (`service_worker.js`, `common.js`, popup and pairing page) |
| Job models | `Sources/AgentKit/Jobs/JobModels.swift` |
| JobCenter | `Sources/AgentKit/Jobs/JobCenter.swift` |
| JobPlanner | `Sources/AgentKit/Jobs/JobPlanner.swift` (`JobPlanner`, `JobPlanningContext`) |
| JobRunner | `Sources/AgentKit/Jobs/JobRunner.swift`, `JobContextBuilder.swift` (`JobWriteBack`) |
| JobStore and workspace | `Sources/AgentKit/Jobs/JobStore.swift`, `SQLiteJobWorkspace.swift` |
| JobScheduler, PowerAssertion | `Sources/AgentKit/Jobs/JobScheduler.swift` |
| JobRunLock | `Sources/AgentKit/Jobs/JobRunLock.swift` |
| ScreenLease | `Sources/AgentKit/Jobs/ScreenLease.swift` |
| Jobs, speed and browser UI | `Sources/GlideApp/Settings/` (`JobsView`, `SpeedSettings`, `BrowserSettingsView`), `Notch/JobViews.swift`, `System/Notifications.swift` |

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
- **Tags every event** so `UserInterferenceMonitor` can tell agent input from yours. If you grab the mouse, the agent pauses. The tag also keeps the agent off Glide's own UI, which it can't see: `GlideApplication` drops tagged clicks and keys before any window gets them, and `NotchClickGuard` makes the notch click-through while the agent uses the pointer (it reopens about a second after agent input stops; the quick task's own approval stays clickable). Approval buttons answer the request they were drawn for, by id.

Every injected event passes through `ExecutionGate`, a shared stop and pause switch. Emergency stop flips it, and the next event post throws. The benchmark measures stop latency at about 2 ms.

## Verifying

`VerificationEngine` checks outcomes from structured state, not screenshot diffs. It can check that an app is frontmost, that the focused field contains the typed text, that an element appeared or disappeared, that the window title changed, that a file exists, or that the UI changed at all (using the AX change counter). Waits are event-driven, with no fixed sleeps.

## The agent loop

`ExecutionOrchestrator.run`:

1. **Plan.** The planner model gets the request, frontmost app, running apps, browser page, connected Composio toolkits, MCP tools, relevant saved skills and which tool routes are available (command access, browser status, installed tool families). It returns 2–8 steps, each with a route (`native`, `gui`, `command`, `browser`, `web`, `data`, `composio`, `mcp`, `answer`), a risk level, a done-when condition and an optional deterministic hint. With *Fastest* execution it prefers the routes that don't need the screen. The plan also has a `mode`: `quick` runs now; `job` (many items, waits or schedules, more than about ten minutes) is handed to `JobCenter` through the orchestrator's `JobHandoff`, and the quick task ends with "Started a background job".
2. **Execute each step.** The step goes to `StepRouter` (see [Step routing](#step-routing)). On-screen steps run in `GUIStepRunner`: if the step's hint resolves unambiguously, it runs with no model call. Otherwise the fast action-selection model chooses an action from the UI skeleton, optionally followed by a short batch of follow-ups. `ActionResolver` maps that choice to a `ComputerAction`. Close candidates can be settled by Jev's calibrated Choice when configured, and unresolved targets go to `VisionGrounding`. Other steps run in `ToolStepRunner`.
3. **Check safety.** `SafetyPolicy` combines deterministic rules with the model's risk label. Rules include send, delete and purchase wording, Return in messaging apps, ⌘⌫, destructive shell commands, password fields, card numbers and excluded apps. Tool calls are judged by each tool's own deterministic `assess`. Anything that needs approval pauses for the user.
4. **Act and verify.** The executor runs the action, then verification checks the result. Each result is appended to the step history the next model call sees.
5. **Stop when progress stops.** Limits cover steps, actions per step and per task, retries, the task timeout and repeated identical actions. After four actions with no visible effect, the step fails. A failed step triggers up to `maxReplans` recovery plans from the current screen, after which the task fails with an explanation.

A quick task takes the `ScreenLease` with priority before it starts, so it goes ahead of background jobs (a job's on-screen step that is already running finishes first). Until it holds the lease, the shared input gate may be driving that job's step, so `TaskController` leaves the gate alone: Stop only cancels the wait, and Pause is held back. Once the lease is granted, the gate is reset and a held-back pause applied.

## Step routing

`StepRouter` is the one `StepExecuting` that quick tasks and jobs share, so a step behaves the same wherever it runs. `gui` and `native` steps go to `GUIStepRunner`; `command`, `browser`, `web`, `data`, `composio`, `mcp` and `answer` go to `ToolStepRunner`. `StepRouter.install()` sets `StepExecutorFactory.make`, which is how the job engine gets its executor.

`ToolStepRunner` loop, per model turn (`ModelRouter` role `.actor`):

1. The prompt has the goal, the step, its done-when, job or task context, the tools the route may use (`ExecutionRoute.toolCategories`), the last results and the output fields the step must produce.
2. The model replies with a strict JSON decision: a status (`act`, `step_done`, `task_done`, `blocked`), up to `maxBatch` tool calls (6 by default, at most 10), result fields and an optional note to remember.
3. Each call is resolved, checked against the allowed families, and assessed. Blocked calls never run and the model is told why. Calls that need approval go through `AgentCallbacks.approve`. The batch stops at the first failure or decline.
4. Runner-only arguments (`_label` and anything else starting with `_`) are stripped from model calls. For `browser.click` and `browser.type`, the runner fills `_label` with the element's name from the latest snapshot so `assess` can judge it.
5. Limits: `maxTurns`, an error budget of 4, a step fails when the same call fails 3 times in a row, and every call has a hard timeout.

`GUIStepRunner` is the observe → hint → actor → resolve → act → verify loop that used to live in `ExecutionOrchestrator`. It now also runs up to 5 follow-up actions per model turn against the same window, stopping at the first error, unexpected change or missing target.

A quick task's run is paused by the orchestrator's input monitor. A job's on-screen step has nobody to press Resume, so with *Pause when I move the mouse* on it runs `UserTakeoverWatch` on `AutomationRuntime.jobInterference` (its own monitor, never the quick task's). With *Use the screen: Only when I'm idle* any real input counts; with *Any time* only input that collides with the agent's. When the user takes over, the pending action is skipped (it doesn't use up a turn), the step releases the screen lease so a quick task can run, waits until the user has been idle for the job's idle time (at least 3 s, measured like the lease measures it, with Glide's own input left out), takes the lease back, brings its app forward and observes the screen again. The wait extends the step's deadline and is reported through `AgentCallbacks.waitingForUser`, so the job runner leaves it out of the job's running time and shows why nothing moves. If the job is paused or stopped meanwhile (`AgentCallbacks.jobInterrupted`), the wait ends without taking the screen back and the run ends paused. Canceling a job's step stops the shared gate, so input already being typed ends at once, except while the step has handed the screen over.

## Tools

A tool (`AgentTool`) declares a `ToolSpec` (dotted name, one-line summary, JSON schema, category, `readOnly`, `needsScreen`), an `assess` that returns a `ToolVerdict` (risk, reasons, optional block message, summary), and `run`. `assess` is deterministic and never calls a model. Each family registers a factory with `ToolRegistry.registerFactory` in its `install()`; `ToolRegistry.standard(settings:)` builds the registry for the current settings, so for example *Read-only* command access leaves out tools that can only change things. `glidectl tool list` prints the registry.

| Family | Tools | Notes |
|---|---|---|
| command | `shell.run`, `applescript.run`, `jxa.run`, `shortcuts.list`, `shortcuts.run` | `/bin/zsh -lc` in its own process group via `posix_spawn`; stop or timeout sends SIGTERM, then SIGKILL after 2 s. Secret-looking environment variables are removed. |
| files | `fs.list`, `fs.read`, `fs.write`, `fs.move`, `fs.copy`, `fs.mkdir`, `fs.trash`, `fs.search` | `fs.read` handles text, PDF, RTF and Word files; `fs.search` uses Spotlight (`mdfind`); `fs.trash` is recoverable. |
| system | `system.open`, `system.notify`, `clipboard.read`, `clipboard.write` | |
| browser | `browser.open`, `snapshot`, `click`, `type`, `select`, `press`, `scroll`, `read`, `back`, `tabs`, `switch_tab`, `close_tab`, `wait` | Every action returns a fresh snapshot. |
| web | `web.search`, `web.fetch`, `web.fetch_many` | `URLSession`, no browser. Search uses DuckDuckGo's HTML page behind a `WebSearchBackend` protocol. |
| data | `sheet.read`, `sheet.write`, `sheet.update`, `sheet.append` | CSV, TSV and XLSX. XLSX updates edit only the target cells in the sheet XML and keep styles, formulas and other sheets. |
| workspace | `workspace.remember`, `recall`, `save_row`, `rows`, `write_file`, `read_file` | The current job's memory; files stay inside the job folder. |

Composio and MCP tools are wrapped as tools by adapters in `ToolStepRunner.swift`. Their `assess` is `SafetyPolicy.assessIntegrationTool`: the name is split into words (`toolNameWords` handles snake, kebab and camel case, dots and slashes), and `toolAction` finds its verbs. A tool whose first verb reads starts at low, any other at medium; the risk word lists can raise it to high (a risky noun after a read verb, as in `getPost`, doesn't count). An HTTP `method` argument of `DELETE` is high, and `POST`, `PUT` or `PATCH` medium.

`TableIO` (`reader`, `updater`, `writer`) is the spreadsheet seam the job engine uses for loop sources and write-back. `DataTools.install()` replaces its CSV-only fallback with the real CSV and XLSX code. `TableIO.Updater` takes `UpdateOptions(columnOrder:owner:)`: the order for new columns, and the owner (job id) that decides when a `.bak` copy is made.

## Browser

`BrowserBackend` is a connection to Chrome that can list, open, navigate, activate and close tabs and send one CDP command to a tab. There are two:

- **`ExtensionBackend`** relays everything through the Glide extension in the user's own Chrome. `ExtensionBridge` is a localhost-only server on a raw TCP `NWListener` (port 47823 by default) that parses the HTTP upgrade itself, does RFC 6455 framing, checks the `Origin` header and the pairing proofs, matches request and reply ids, and enforces per-call timeouts and keepalive. The extension's service worker carries out `tabs.*` with `chrome.tabs` (calls that load an address reply once the new page has committed) and `cdp.send` with `chrome.debugger` (attached on first use per tab, and detached from a tab the user opened 45 s after Glide's last command there). It keeps the set of tabs Glide opened in `chrome.storage.session`, and learns which tab opened a popup from `chrome.webNavigation.onCreatedNavigationTarget` (reported as `sourceTabId`; `chrome.tabs`' own `openerTabId` names whichever tab was in front). One extension connection is active at a time; the newest wins.
- **`GlideChromeBackend`** launches Chrome with a dedicated profile, `--remote-debugging-port=0` (the port is read from `DevToolsActivePort`) and, for tests and `glidectl --headless`, `--headless=new`. It holds one browser-level `CDPWebSocket` and attaches to tabs with flattened sessions. If Glide quits while that Chrome keeps running, the next `connect()` adopts it again. Concurrent callers share one launch; a caller that's canceled stops waiting, and the launch itself is canceled only when nobody is still waiting for it.

Both backends answer JavaScript dialogs by the same rules (`BrowserDialogPolicy` in `BrowserDriver.swift`, mirrored in `service_worker.js`). A tab counts as driven while one of Glide's commands runs there and for 2 s after; actions (`Input.*`, navigation, scripts run with a user gesture) are tracked separately. Dialogs in Glide's own tabs, and in a driven tab, are answered (alerts dismissed, `confirm()`/`prompt()` declined, leaving allowed), except that "Leave site?" in the user's tab is accepted only around an action. Any other dialog is left for the user, and commands to that tab fail with `BrowserError.dialogOpen` until it closes. A popup becomes Glide's only when it came from one of Glide's tabs while that tab was driven.

`BrowserHub` registers the backends and picks one per call from `BrowserSettings`: the preferred backend if it's connected, else Glide's Chrome when fallback is on. It also exposes the pairing hooks Settings › Browser uses. A call stays on the backend its current tab lives in while that backend is connected.

`BrowserDriver` works on either backend. A snapshot injects JavaScript with `Runtime.evaluate` that walks the DOM, including open shadow roots and same-origin frames, and tags up to 300 visible interactive elements with `data-glide-ref="b<n>"`. `PageSnapshot.compact()` renders them like the AX skeleton (`b12 button "Sign in" [disabled]`), with headings and readable text. Clicks scroll the element into view and dispatch real `Input.dispatchMouseEvent` events at its center, falling back to `element.click()` when something covers it. Typing uses `Input.insertText`. `press` looks at the focused field before every key that puts text in (a printable key, Meta+V, Shift+Insert) and refuses password and payment card fields. After each action the driver waits for the page to settle (load state, quiet network, stable DOM) instead of sleeping. `navigate` marks the page being left first, so a backend that replies before the navigation commits can't have the old page taken for the new one (a jump to a `#fragment` of the same page keeps the document). A ref that is no longer on the page fails with "take a new snapshot".

`BrowserSessions` keeps one current tab per quick task, job and job item, so parallel items never share a page, and closes the oldest tabs Glide opened beyond 4 per job (12 overall). Tabs the user opened are never closed by this, and neither is a tab some task, job or item is still working in (the cap is exceeded for a while instead). When a job item finishes, the Glide tabs it used are closed, including ones it opened and left behind. `browser.click` follows a popup only when the backend reports it was opened from the clicked tab; it keeps the popup's owner (Glide's or the user's) as the backend reports it.

## Jobs

- **`JobCenter`** (`@MainActor @Observable`) is the only API the app and `glidectl` use: `create` (plan, estimate, then start or wait for confirmation), `start`, `pause`, `resume`, `stop`, `haltAll`, `retryFailedItems`, `respond` (approvals), `exportResults` (`exportResultFiles` also returns every file written), `delete`, `reload`, plus `jobs`, `pendingApprovals`, `runningElsewhere`, `items` and `events`. It runs at most `maxConcurrentJobs` runners and queues the rest; a queued job keeps a wake time that already came due, so its wait finishes when it gets its turn. `launch()` loads jobs at app start and resumes or pauses the ones that were running. `reload()` re-reads them, keeping the live record of jobs this process runs; the app calls it when the notch or Settings › Jobs opens, so jobs `glidectl` created or changed show up, jobs another process left unfinished are recovered as at launch, and waiting jobs it finds are scheduled. `isQueued` tells a job waiting for a free slot from one sleeping until a time. Its `Scope` says which jobs it looks after on its own (wakes, recovers, pauses on the emergency stop): `.allJobs` in the app, `.ownJobs` in `glidectl`, which then touches only the jobs it creates, starts, resumes or retries.
- **`JobRunLock`** keeps two processes from running one job. It's an advisory `flock` on `.runner.lock` in the job's folder, held while a process plans or runs the job (and briefly while it changes one), and the system drops it when the process exits or crashes. A job whose lock another process holds is in `runningElsewhere`: shown with *Running in another Glide process* and no controls, polled every 2 s, and once it's let go, handled like a job found at launch.
- **`JobPlanner`** turns a request into a `JobPlan` with a strict JSON schema: milestones of steps, where a step is an action (`RecipeStep` with a route), a `forEach` (item source, recipe, parallelism, output table and columns, optional write-back) or a `wait` (duration, until, daily, condition). The planning context includes the header and first rows of spreadsheets the request mentions. `estimate` predicts items, model calls, minutes and cost.
- **`JobRunner`** (an actor per running job) walks milestones from the persisted cursor. Action steps go to the executor. Loops materialize their items once, then run pending and retryable items with bounded parallelism (1 when a recipe step needs the screen), saving each item and its result row as it finishes. Write-back batches results into the spreadsheet the plan names (usually the loop's source) every 10 items and at the end, through `TableIO.updater`. Writing back into the source file uses the source's sheet, and a headerless source is never written back to (its results stay in the job's table). Waits set `nextWakeAt` and end the run. *Retry failed items* re-queues the failed items, moves the cursor back to the earliest loop that has some, and saves a `RetryReturn` (in `job_state`) with how far the job had got and the wake time of a wait it was sleeping in. After the loops it jumps straight back there, so steps it had already finished don't run again. After a milestone, an `answer` step checks its done-when against the workspace and may add up to 2 remedial steps. The run ends with a report (`report.md`). Budgets, stuck detection and the failure rate are checked between steps and items. Time spent waiting for an approval, for the screen lease, or for the user during an on-screen step is left out of the job's running time. Each runner has its own `ExecutionGate`, so stopping one job never stops another.
- **`JobStore`** adds tables to the shared SQLite database: `jobs`, `job_items`, `job_events`, `job_facts`, `job_rows` and `job_state`. **`SQLiteJobWorkspace`** is the job's memory on top of them (facts ranked by keyword overlap, result tables, files in the job folder) and gives each prompt a short summary instead of the whole history.
- **`JobScheduler`** keeps one timer for the earliest wake time and re-checks at least every minute against the wall clock. **`PowerAssertion`** holds `kIOPMAssertionTypePreventUserIdleSystemSleep` while any job runs and *Keep my Mac awake* is on; `JobCenter` observes the setting, so switching it applies at once.
- **`ScreenLease`** (actor) lets one owner at a time run on-screen steps. Quick tasks take it with priority. Jobs take it only for `gui` and `native` steps, after the user has been idle for `idleSeconds` in *Only when I'm idle* mode, and get a clear error in *Never* mode. Idle time leaves out input Glide posted itself (`InputSynthesizer.lastPost`), and is sampled while the lease is held, so a user who comes back between Glide's actions is still noticed. The lease is per process: the app and `glidectl` each have their own.

The emergency stop calls `TaskController.stop()` and `JobCenter.haltAll()`. A halted job's step in flight is canceled (shell process groups are killed, browser calls end), the item goes back to pending, and the job ends `paused`, not `stopped`. Stop, and deleting a job, also close the browser tabs the job opened when no runner is left to do it. `saveHaltedForExit()` is for a process that quits while a halted step is still unwinding (`glidectl`'s second Ctrl-C): it saves those jobs as paused, and their runners stop saving.

## Model routing

`ModelRouter` resolves each role to a provider and model. In automatic mode:

| Role | Anthropic | OpenAI |
|---|---|---|
| Planner | `claude-opus-5-5` (effort low) | `gpt-6-luna` |
| Action selection | `claude-haiku-5-5` (effort low) | `gpt-6-luna` |
| Vision | `claude-opus-5-5` | `gpt-6-luna` |
| Recovery | `claude-opus-5-5` (effort medium) | `gpt-6-luna` |

The job planner uses the planner role; tool steps, milestone checks and job reports use action selection. Manual mode lets you pick provider, model and effort per role. Jev (optional) is called either directly at TypeSafe (`api.typesafe.ai/v1/systemone`, model `jev-latest`) or through Vercel AI Gateway's TypeSafe-compatible endpoint (`ai-gateway.vercel.sh/typesafe/v1/systemone`, model `typesafe-ai/jev`, AI Gateway key). Structured replies use Anthropic `output_config.format` and OpenAI `response_format: json_schema`. Both degrade automatically to JSON-in-prompt for endpoints that don't support those formats.

## Persistence

- Settings: JSON in `UserDefaults` (domain `dev.notchbuddy.app`, shared with `glidectl`). Contains no secrets. Tool, browser and job settings live in `tools`, `browser` and `jobs`.
- Secrets: Keychain generic passwords under the `dev.notchbuddy.credentials` service. The extension's pairing token is stored there too (`browser.bridge-token`).
- These identifiers (and the bundle ID `dev.notchbuddy.app`) date from the app's earlier name, NotchBuddy. They're kept so existing installs keep their settings, keys and permissions. Task history moved from `Application Support/NotchBuddy` to `Application Support/Glide` and is migrated on first launch.
- History and skills: SQLite at `~/Library/Application Support/Glide/glide.sqlite`. Text is scrubbed of anything that looks like a key before it's written.
- Jobs: the `job_*` tables in the same `glide.sqlite`, and one folder per job at `~/Library/Application Support/Glide/Jobs/<id>/` (workspace files, `report.md` and the `.runner.lock` file). Deleting a job moves its folder to the Trash. Exported CSVs go where you choose; extra tables go next to that file as `<name>-<table>.csv`, with " 2", " 3"… added rather than replacing a file.
- Glide's own Chrome profile: `~/Library/Application Support/Glide/GlideChrome`.

## Concurrency

The UI runs on the main actor. `TaskController` starts the orchestrator in a detached task. AX calls are synchronous, thread-safe IPC wrapped in `@unchecked Sendable` engines. AX notifications and the interference event tap each run on a dedicated run-loop thread. `JobCenter` is main-actor isolated; each `JobRunner`, `ScreenLease`, `GlideChromeBackend` and `CDPWebSocket` is an actor. `ExtensionBridge` keeps its state in one `Mutex` and handles Network.framework callbacks on a private serial queue. `JobStore`, `ToolRegistry` and `BrowserSessions` are lock-protected classes. Across processes, `JobRunLock` is the only coordination: the app and `glidectl` share the SQLite store, settings and Keychain, but not the screen lease or the input gate. Swift 6 language mode is enabled for every target.
