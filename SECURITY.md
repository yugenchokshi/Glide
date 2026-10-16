# Security

NotchBuddy controls your real mouse and keyboard, so its safety model is part of the product. This document describes what it does to protect you and what it can't guarantee.

## Reporting a vulnerability

Please open a private security advisory on GitHub (Security › Report a vulnerability) rather than a public issue. Include steps to reproduce and the macOS version.

## Credentials

- API keys for OpenAI, Anthropic, custom endpoints, Composio and TypeSafe, and secret MCP headers, are stored only in the macOS Keychain as generic passwords with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Keys are never written to settings, SQLite or logs, never placed in model prompts, and never shown in full in the UI (they're masked by default). `SecretScrubber` removes key-shaped strings from anything stored in history.
- Requests go straight from your Mac to the provider you configured. The repository contains no NotchBuddy server and no developer-owned keys.
- Composio sign-ins for third-party apps use Composio's hosted connect flow in your browser. No OAuth client secret ships in the app.

## Actions

- **Approval.** High-risk actions require your approval before they run: sending messages or email, deleting, publishing or posting, purchases, payments, security settings and destructive shell commands. Risk is the higher of a deterministic rule set and the model's own label. In Settings you can also require approval for medium-risk actions or for every action.
- **Hard blocks.** Typing into password (secure text) fields, entering anything that passes a Luhn check as a card number, and acting in apps on your exclusion list are refused outright.
- **Emergency stop.** The global shortcut (default ⌃⌥⌘.) works with the UI hidden. It stops all further input injection immediately: every event checks a shared gate before it's posted. Actions that already completed can't be undone.
- **User takeover.** Moving or clicking the mouse during a task pauses it. Agent events are tagged so they can be told apart from yours.
- **Runaway protection.** Limits on steps, actions, retries, replans, total time and repeated identical actions all end the task with an explanation.

## Screen content

- Accessibility data (control roles, labels and values) is sent to your planner and action models as text. Secure field values are never read.
- Screenshots are captured only when a control isn't in the accessibility tree and local OCR can't find it. With the default setting, you're asked before any screenshot goes to a vision model. Secure fields are blacked out first. You can set this to *always* or *never* in Settings › Safety.
- Screenshots aren't stored. Task history keeps only text descriptions of actions.

## Prompt injection

Web pages and documents can contain text aimed at the agent. NotchBuddy treats on-screen text as data. The executor prompt tells the model never to enter passwords or payment details and to stop at logins and CAPTCHAs. The deterministic safety rules and the approval gate don't depend on the model's cooperation. Even so, a model can be misled into a harmful *low-risk-looking* action. Keep approvals enabled, exclude sensitive apps, and supervise tasks that touch untrusted content.

## Permissions

NotchBuddy asks for:

- **Accessibility** (required): reading UI and injecting input.
- **Screen Recording** (optional): OCR and vision fallback.
- **Automation** (optional, per app): browser URL and page text.
- **Microphone and Speech** (optional): on-device dictation.

It can't run in the App Sandbox, because Accessibility clients aren't allowed there. It is built with the hardened runtime.
