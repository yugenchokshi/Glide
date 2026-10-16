# Testing

## Unit and integration tests

```bash
swift build      # builds the mock servers the integration tests use
swift test
```

These tests never move the cursor and never call paid APIs. They cover:

- **AutomationKit**: key-combination parsing, fuzzy element matching and ambiguity detection, element-id continuity, compact skeleton rendering (secure values hidden), stop and pause semantics of `ExecutionGate`, capture coordinate mapping and redaction, role normalization.
- **AgentKit**: strict JSON schemas, plan and decision decoding, `SafetyPolicy` (send, delete, purchase, messaging Return, destructive shell, password fields, card numbers, excluded apps, approval levels, tool names), deterministic hint compilation and decision resolution, Anthropic and OpenAI request bodies and response parsing (including refusals), automatic and manual model routing, Keychain round trip, secret scrubbing, the SQLite history and skills store, the **MCP stdio client** against `nb-mock-servers mcp`, and the **OpenAI-compatible client** against `nb-mock-servers llm`.

## Live benchmark (PRD §14)

```bash
swift build
.build/debug/nbctl bench --json docs/benchmarks/latest.json
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

## End-to-end agent run without a paid key

`nb-mock-servers llm` is a scripted OpenAI-compatible endpoint. It reads the same UI skeleton a real model would and drives the fixture's "greet" task:

```bash
.build/debug/nb-mock-servers llm 18734 &
.build/debug/NBFixtureApp &
.build/debug/nbctl run "Greet Ada in the NB Fixture app" --mock-url http://127.0.0.1:18734/v1
```

This exercises the whole loop (plan, observe, decide, act with the real cursor, verify, finish) with a deterministic "model".

## With a real provider

Add a key in the app's Settings (or the shared Keychain entry), then:

```bash
.build/debug/nbctl run "Open TextEdit, create a new document and type Hello from NotchBuddy"
```
