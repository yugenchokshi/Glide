# Known limitations

These are stated plainly so you know what to expect.

- **Real-model accuracy varies.** Planning and action choice depend on the model you configure. Small local models via OpenAI-compatible endpoints may fail on multi-step tasks. Quality also depends on how well an app exposes accessibility data.
- **Apps with poor accessibility** (games, some Electron or canvas apps, remote desktops) fall back to OCR and then vision. These are slower and less precise, and vision needs your consent for screenshots.
- **Browser DOM access** is read-only and optional. Page text over Apple Events requires enabling *Allow JavaScript from Apple Events* in Safari's or Chrome's developer settings. The CDP adapter requires starting Chrome with `--remote-debugging-port=9222`. Interaction with web pages goes through the browser's accessibility tree.
- **Logins, passwords, 2FA, CAPTCHAs and payment details** are deliberately not handled. The task stops and asks you.
- **Irreversible actions** can't be undone after they run. Approvals gate them beforehand, but a stop only prevents *further* actions.
- **Composio** requires your own Composio project API key. Tools that ask for extra input (`input_required`) aren't answered in-app yet; the task reports it instead.
- **MCP** supports tools over stdio and Streamable HTTP. Resources, prompts, sampling and elicitation are not implemented. HTTP servers that need OAuth must be given a token as a secret header.
- **Skills** are stored and applied as planner guidance. Learning from demonstration is not implemented.
- **Keyboard layouts.** Key combinations use ANSI key codes; text typing is layout-independent (Unicode events).
- **Multiple displays.** The agent can act on any display. The notch UI lives on the built-in notched display, or on the main display if there is no notch.
- **Ad-hoc builds** lose the Accessibility grant on every rebuild. Sign with a stable identity (see README).
- **Time to first action** includes one planner call (typically 1–4 s with a hosted model). The engine itself snapshots typical windows in 5–60 ms. See `docs/benchmarks/`.
- **Shortcut conflicts with other apps.** Glide detects clashes with macOS system shortcuts and between its own actions. Another app that registers the same global shortcut (ChatGPT also defaults to ⌥Space, for example) can't be detected, and whichever app registered first receives it. Change the shortcut in Settings › Shortcuts if it doesn't open Glide.
