# Testing

## Unit and integration tests

```bash
swift build      # builds the mock servers the integration tests use
swift test
```

There are a bit over 300 test functions (some run a table of cases, such as the nearly 200 shell commands in `CommandToolsTests.swift`). They never move the cursor, never call paid APIs, never touch your real Keychain entries, and use the network only on localhost. They cover:

- **AutomationKit** (`AutomationKitTests.swift`): key-combination parsing, fuzzy element matching and ambiguity detection, element-id continuity, compact skeleton rendering (secure values hidden), stop and pause semantics of `ExecutionGate`, capture coordinate mapping and redaction, role normalization.
- **AgentKit** (`AgentKitTests.swift`): strict JSON schemas, plan and decision decoding, `SafetyPolicy` (send, delete, purchase, messaging Return, destructive shell, password fields, card numbers, excluded apps, approval levels, tool names), deterministic hint compilation and decision resolution, Anthropic and OpenAI request bodies and response parsing (including refusals), automatic and manual model routing, Keychain round trip, secret scrubbing, the SQLite history and skills store, the **MCP stdio client** against `nb-mock-servers mcp`, and the **OpenAI-compatible client** against `nb-mock-servers llm`.

The tools, browser and job engine have their own files:

| File | What it covers |
|---|---|
| `Tests/AgentKitTests/CommandToolsTests.swift` | `CommandSafety` against a table of nearly 200 command lines (low, medium, high, blocked: `echo hi > ~/x`, `ls; rm -rf ~`, `curl … \| sh`, `find -delete`, `git log && git push`, `sed -i`, here-documents…), `ShellParser`, `ScriptSafety` keywords, `shell.run` (output, exit codes, working folder, timeout, the gate killing the whole process group, output caps, secrets stripped from the environment), AppleScript and JXA results and errors, `do shell script` checked like `shell.run`, the `fs.*` tools in a temp folder (PDF and RTF text, Spotlight search, risk by path), command access levels and the AppleScript/Shortcuts switches, and the clipboard on a private pasteboard. `system.open` and notifications are only assessed, never run. |
| `Tests/AgentKitTests/BrowserTests.swift` | `CDPWebSocket` (replies by id under concurrency, errors, timeouts, events, dropped connections, cancellation), key, URL and snapshot rendering, browser tool risk, `BrowserSessions` and the hub's fallback status. With Chrome installed, it starts **headless Chrome with a temporary profile** and a local fixture HTTP server: snapshots and stable refs, real clicks with the covered-element fallback, typing, submitting and selecting, stale refs, reading, waiting, pressing and scrolling, JavaScript dialogs, two tabs including background ones, cancelling a launch, reconnecting after Chrome quits, and the browser tools through the registry. Without Chrome these tests are skipped. Chrome is always quit and the profile removed afterwards. |
| `Tests/AutomationKitTests/ExtensionBridgeTests.swift` | WebSocket framing, the handshake rules (origin, loopback `Host`, protocol version, HMAC proofs, nonce age and replay), pairing links and tokens, and a live bridge on a random port: wrong origin or token refused, Apple's WebSocket client interoperating, timeouts, the newest connection replacing the old one, reset pairing, probes, idle drops, pings, large fragmented replies, busy ports. Also the `ExtensionBackend` mapping, and the extension files: a valid MV3 manifest, the id matching the manifest key, icon sizes, and `node --check` on the scripts when `node` is installed. With Node 22 or later, it runs the real service worker against the bridge (driving tabs, detaching when Glide goes away, ignoring an impostor server, refused pairing). |
| `Tests/AgentKitTests/DataWebToolsTests.swift` | CSV and TSV parsing and writing (quotes, delimiters, BOMs, encodings, formula neutralizing, in-place updates with `.bak`, concurrent updates), XLSX reading (references, numbers, dates), writing, and in-place updates that keep styles, other sheets and formulas (and refuse shared or array formula cells, damaged, protected and linked workbooks), the `sheet.*` tools and their risk, HTML to text on a saved page, DuckDuckGo result parsing and bot-check detection on a saved page, and `web.fetch`, `web.fetch_many` and `web.search` against a local server. |
| `Tests/AgentKitTests/JobEngineTests.swift` | With a scripted executor and planner and a temp SQLite file: a loop over a CSV with parallelism and write-back, declining write-back, resuming after a simulated crash without redoing items, retries, the failure-rate pause, stuck detection, loops over an earlier step's output, daily repeats, condition waits, model-call and cost budgets, approval checkpoints, pause and stop, milestone verification with remedial steps, `ScreenLease` (one holder, quick tasks first, *never* and *when idle* modes), `JobPlanner` estimates and decoding, `JobStore` and the workspace tools, `JobCenter` (confirmation, export, delete, approvals, queueing, retrying failed items, launch after a crash, pausing a waiting job) and `JobScheduler`. |
| `Tests/AgentKitTests/StepRunnerTests.swift` | `ToolStepRunner` with a mock model: batching, blocked calls, approve, decline and stop, result fields, the repeated-failure guard, error and turn limits, stops and cancellation, hung tools, allowed tool families, `_label` from the latest snapshot, runner-only arguments stripped, the answer route, MCP adapters. Also the strict schemas, plan `mode` decoding, `StepRouter` dispatch, and the orchestrator running a `command` step end to end and handing a `job` plan to the job engine. |

Run one suite with `swift test --filter <type name>`, for example `swift test --filter ScreenLeaseTests`, or `--filter Browser` for every browser suite.

## Live benchmark (PRD §14)

```bash
swift build
.build/debug/glidectl bench --json docs/benchmarks/latest.json
```

This drives your real cursor. It needs Accessibility (and Screen Recording for scenario 12) for the terminal running it. It only uses disposable data:

| # | Scenario | How it's verified |
|---|---|---|
| 1 | Open an application (TextEdit) | TextEdit frontmost |
| 2 | Create a new note | Note body contains the typed text (via AX) |
| 3 | Save a TextEdit document | File exists in a temp folder |
| 4 | Rename a file in Finder | Renamed file exists |
| 5 | Navigate a browser page (local HTML in Safari) | Window title changes to page two |
| 6 | Fill out a web form | Title + "Thanks, Ada Lovelace!" text appear |
| 7 | Switch between two applications | Each app frontmost in turn |
| 8 | Interact with a system dialog (sheet) | Fixture status "dialog confirmed" |
| 9 | Recover from a missing element | Hidden button revealed, then clicked |
| 10 | Stop a task mid-execution | Typing interrupted (stop latency printed) |
| 11 | Request approval before a sensitive action | "Delete Everything" flagged high-risk; nothing happens before approval |
| 12 | Handle an inaccessible control | Canvas control invisible to AX found by OCR and clicked |

Each result records success, action count, duration, average observation time, recoveries, OCR, model and vision calls, and cost. The benchmark is deterministic, so model and vision calls are 0 and cost is $0.

## Trying single tools

`glidectl tool run` runs one tool call with the same safety check the agent uses. It doesn't need Accessibility.

```bash
.build/debug/glidectl tool list                       # names, families, read-only flags
.build/debug/glidectl tool list --category data
.build/debug/glidectl tool run shell.run '{"command":"echo hi"}'
.build/debug/glidectl tool run shell.run '{"command":"sudo ls"}'          # blocked, never runs
.build/debug/glidectl tool run fs.list '{"path":"~/Desktop","pattern":"*.pdf"}'
.build/debug/glidectl tool run sheet.read '{"path":"~/Desktop/companies.csv"}' --json
.build/debug/glidectl tool run web.search '{"query":"swift concurrency"}'
.build/debug/glidectl tool run browser.open '{"url":"https://example.com"}' --headless
.build/debug/glidectl browser status
```

Calls that need approval ask first; `--yes` approves them. `--json` also prints the structured result. Each `tool run` is a separate process, so browser state (the current tab and its snapshot refs) doesn't carry over to the next command. With `--headless`, the throwaway Chrome is closed when the command ends.

## End-to-end agent run without a paid key

`nb-mock-servers llm` is a scripted OpenAI-compatible endpoint. It reads the same UI skeleton a real model would and drives the fixture's "greet" task:

```bash
.build/debug/nb-mock-servers llm 18734 &
.build/debug/NBFixtureApp &
.build/debug/glidectl run "Greet Ada in the NB Fixture app" --mock-url http://127.0.0.1:18734/v1
```

This exercises the whole loop (plan, observe, decide, act with the real cursor, verify, finish) with a deterministic "model".

The same server has scripted scenarios for the new routes, picked by words in the request:

- **`tool-route`**: a quick task with one `command` step, which the tool runner finishes with a batch of two `shell.run` calls (`echo hello`, `echo world`).
- **`background-job`**: a plan in `job` mode, which the orchestrator hands to the job engine (used by `StepRunnerTests`).
- **`shout-job`**: a long job, below.

## A long job without a paid key

The `shout-job` scenario plans a real job: for every row of a CSV, a `command` step uppercases the `Company` value with `shell.run`, 3 items at a time. Results go to the job's `companies` table and back into the CSV as a new `shout` column.

```bash
swift build
mkdir -p /tmp/glide-demo
printf 'Company\nAcme\nGlobex\nInitech\nUmbrella\nHooli\nStark Industries\nWayne Enterprises\nWonka\nTyrell\nCyberdyne\nSoylent\nVandelay\n' > /tmp/glide-demo/companies.csv
.build/debug/nb-mock-servers llm 18734 &
.build/debug/glidectl job run "shout-job: uppercase every company name in /tmp/glide-demo/companies.csv" \
  --mock-url http://127.0.0.1:18734/v1 --yes
```

`--yes` confirms the estimate and approves writing into the existing CSV. When it finishes, `companies.csv` has a `shout` column, `companies.csv.bak` holds the original, and the job folder (printed at the end, under `~/Library/Application Support/Glide/Jobs/`) has `report.md`. The path must not contain spaces: the mock finds it as the first word ending in `.csv`.

To test halting and resuming, slow the mock down and press Ctrl-C partway through:

```bash
NB_MOCK_DELAY_MS=400 .build/debug/nb-mock-servers llm 18734 &
.build/debug/glidectl job run "shout-job: uppercase every company name in /tmp/glide-demo/companies.csv" \
  --mock-url http://127.0.0.1:18734/v1 --yes
# Ctrl-C: "halting — resume with: glidectl job resume <id>"
.build/debug/glidectl job list
.build/debug/glidectl job show <id>
.build/debug/glidectl job resume <id> --mock-url http://127.0.0.1:18734/v1 --yes
```

Ctrl-C works like the emergency stop: the items in flight are cancelled and go back to pending, results finished so far are written into the CSV, and the job ends *paused*. `job resume` runs only the remaining items. Pass `--mock-url` again: each `glidectl` run picks its model provider afresh. Delete or restore the CSV (and its `.bak`) between runs. After the resume, `companies.csv.bak` still holds the original: each backup is tagged with the job that made it, so a resumed job keeps it.

These jobs go into the same job database as the app's, so they also appear in Settings › Jobs after the app is relaunched.

## With a real provider

Add a key in the app's Settings (or the shared Keychain entry), then:

```bash
.build/debug/glidectl run "Open TextEdit, create a new document and type Hello from Glide"
```
