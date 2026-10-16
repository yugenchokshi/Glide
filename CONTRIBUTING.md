# Contributing

Thanks for helping improve NotchBuddy.

## Setup

```bash
git clone https://github.com/<you>/NotchBuddy.git && cd NotchBuddy
swift build            # all targets
swift test             # unit + integration tests (safe: no UI control, no paid APIs)
./scripts/build_app.sh debug && open build/NotchBuddy.app
```

You need macOS 26 and a Swift 6.2+ toolchain (Xcode 26 or later). The package has no third-party dependencies, so please keep it that way unless there's a strong reason.

To run the live benchmark (`nbctl bench`), give your terminal Accessibility permission. The benchmark moves your real cursor and uses disposable fixtures: the bundled `NBFixtureApp`, temporary files, a local HTML form, and one test note per run.

## Ground rules

- **Keep layers separate.** `AutomationKit` has no AI and no UI. `AgentKit` has no SwiftUI views. The app talks to automation only through `TaskController`.
- **Accessibility first.** Add structured perception before reaching for screenshots.
- **No mocked success.** Don't mark an action as succeeded unless `VerificationEngine` (or an explicit check) confirms it. Report "unconfirmed" honestly.
- **Safety rules are deterministic.** Anything that sends, deletes, pays or publishes must go through `SafetyPolicy`. Add tests for new rules in `AgentKitTests`.
- **Never log secrets.** Use `CredentialStore` for credentials and `SecretScrubber` for anything persisted.
- **Model IDs and API shapes** must come from the providers' current documentation. Don't guess parameters.

## Pull requests

1. Add or update tests (`swift test` must pass).
2. If you touched the engine, run `nbctl bench` and paste the table into the PR.
3. Update `ARCHITECTURE.md` or `docs/` when behavior changes.
4. Keep the UI consistent with BoardKit tokens (`Sources/NotchBuddyApp/BoardKit`).

By contributing you agree your work is licensed under the MIT License.
