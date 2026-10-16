# NotchBuddy

A native macOS computer-use agent that lives in the MacBook notch.

Describe what you want done, press **Start**, and watch the real cursor open apps, click, type, scroll, switch windows and finish the task. NotchBuddy reads each app's **accessibility tree** to find controls (fast, precise, no screenshots). It falls back to local OCR, and then to a vision model, only for controls accessibility can't see.

- **Native**: Swift 6, SwiftUI and AppKit, with no Electron or web runtime. Idle CPU is near zero.
- **Bring your own keys**: OpenAI, Anthropic or any OpenAI-compatible endpoint (Ollama, LM Studio, OpenRouter…). Keys are stored in the macOS Keychain.
- **You stay in control**: sending, deleting, publishing and purchasing wait for your approval. A global emergency stop works even when the UI is hidden, and moving the mouse pauses the agent.
- **Local-first**: there's no account and no NotchBuddy server. Task history stays on your Mac.
- **Optional Jev**: TypeSafe's decision model breaks ties between similar on-screen controls. You can call it directly or through Vercel AI Gateway.
- **Optional integrations**: [Composio](https://composio.dev) (Gmail, Calendar, Slack, Notion, GitHub…) and any MCP server.

| Task input | Running | Approval |
|---|---|---|
| ![input](docs/images/notch-input.png) | ![running](docs/images/notch-executing.png) | ![approval](docs/images/notch-approval.png) |

> Status: v1.0. See [docs/LIMITATIONS.md](docs/LIMITATIONS.md) for what it can't do yet.

## Requirements

- macOS 26 or later (Apple silicon or Intel)
- Xcode 26+ / Swift 6.2+ toolchain to build
- An API key for OpenAI or Anthropic, or a local OpenAI-compatible server

## Install from source

```bash
git clone https://github.com/<you>/NotchBuddy.git
cd NotchBuddy
./scripts/build_app.sh          # builds and signs build/NotchBuddy.app
open build/NotchBuddy.app
```

`build_app.sh` signs with `$NB_SIGN_IDENTITY`. If that's unset, it uses your first *Developer ID Application* or *Apple Development* identity, and falls back to ad-hoc signing. A stable identity matters because macOS ties the Accessibility grant to the code signature. With ad-hoc signing you'll have to re-grant Accessibility after every rebuild. `scripts/notarize.sh` notarizes a Developer ID build for distribution.

## First run

The setup assistant walks you through:

1. Granting **Accessibility** (required) and **Screen Recording** (optional; used for the OCR and vision fallbacks).
2. Choosing a provider and pasting an API key (⌘V or the clipboard button). OpenAI uses `gpt-6-luna` by default. The key is tested on the spot and stored in your Keychain.
3. Reviewing the automatically chosen models.
4. Running a safe first task, which types one line into a new TextEdit document.

You never edit `.env` files or use the terminal.

## Using it

| Action | Default shortcut |
|---|---|
| Open the notch | **⌥ Space** (or click the notch / menu-bar icon) |
| Pause / resume | **⌥⇧ Space** |
| Emergency stop | **⌃⌥⌘ .** (works even with the UI hidden) |

Type a task such as *"Open Safari, search for the latest Apple earnings, summarize the results, and save the summary in Notes"* and press Return. The notch shows the current step. Expand it to see the plan and a live activity timeline. High-risk actions expand the notch with **Approve / Reject / Stop**. Results stay in **History**, and successful runs can be saved as reusable **Skills**.

All shortcuts can be changed in Settings › Shortcuts, which also reports conflicts with shortcuts other apps already use.

## How it works

```
Notch UI → TaskController → Planner (capable model) → ExecutionOrchestrator
   per step: observe (AX tree → element graph, OCR if sparse)
           → resolve (plan hint, deterministic match, fast action model, Jev, vision)
           → safety policy → approval if needed
           → act (real CGEvent cursor/keyboard, or AX action)
           → verify (AX values, focus, windows, files)
   on failure: retry → replan (recovery model) → explain
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module map.

## Command-line companion

`nbctl` drives the same engine without the UI. It's useful for development and benchmarks:

```bash
swift build
.build/debug/nbctl inspect Notes          # print the indexed UI skeleton of Notes
.build/debug/nbctl click "New Note" --app Notes
.build/debug/nbctl workflow               # Finder + Notes deterministic workflow
.build/debug/nbctl bench --json bench.json  # 12-scenario live benchmark
.build/debug/nbctl run "Open TextEdit and type hello"   # full agent with your configured provider
```

`nbctl` shares settings and Keychain entries with the app. It needs Accessibility permission for the terminal that runs it.

Regenerate these images with `.build/debug/NotchBuddy --snapshot docs/images`.

## Tests

```bash
swift build && swift test        # unit + integration tests (no UI control, no paid APIs)
.build/debug/nbctl bench         # live benchmark: moves your real cursor on disposable fixtures
```

See [docs/TESTING.md](docs/TESTING.md).

## Privacy and security

- API keys live only in the Keychain. They are never logged, written to SQLite, or put in prompts.
- Screenshots are taken only when accessibility and local OCR can't find a control, after you allow it. Password fields are blacked out, and nothing is retained unless you turn on debug recording.
- Password fields, payment card numbers and apps on your exclusion list are never touched.

Details are in [SECURITY.md](SECURITY.md).

## Design

The interface follows [BoardUI](https://www.boardui.com)'s visual language: neutral surfaces, hairline borders, pill badges, and agent-progress and thinking patterns. BoardUI is a React/Tailwind library, so it is re-created natively in SwiftUI as "BoardKit" (`Sources/NotchBuddyApp/BoardKit`). No BoardUI source or assets are included. See [docs/DESIGN.md](docs/DESIGN.md).

## License

MIT. See [LICENSE](LICENSE). NotchBuddy has no third-party package dependencies and links only Apple system frameworks and the system SQLite.
