# Known limitations

These are stated plainly so you know what to expect.

## The agent

- **Real-model accuracy varies.** Planning and action choice depend on the model you configure. Small local models via OpenAI-compatible endpoints may fail on multi-step tasks. Quality also depends on how well an app exposes accessibility data.
- **Apps with poor accessibility** (games, some Electron or canvas apps, remote desktops) fall back to OCR and then vision. These are slower and less precise, and vision needs your consent for screenshots.
- **Logins, passwords, 2FA, CAPTCHAs and payment details** are deliberately not handled. The task stops and asks you. This holds in the browser and in jobs too: the browser tools refuse password and card fields, and a job item that needs a sign-in is marked failed so you can sign in and use *Retry failed*.
- **Irreversible actions** can't be undone after they run. Approvals gate them beforehand, but a stop only prevents *further* actions.
- **Composio** requires your own Composio project API key. Tools that ask for extra input (`input_required`) aren't answered in-app yet; the task reports it instead.
- **MCP** supports tools over stdio and Streamable HTTP. Resources, prompts, sampling and elicitation are not implemented. HTTP servers that need OAuth must be given a token as a secret header.
- **Skills** are stored and applied as planner guidance. Learning from demonstration is not implemented.
- **Keyboard layouts.** Key combinations use ANSI key codes; text typing is layout-independent (Unicode events).
- **Multiple displays.** The agent can act on any display. The notch UI lives on the built-in notched display, or on the main display if there is no notch.
- **Ad-hoc builds** lose the Accessibility grant on every rebuild. Sign with a stable identity (see README).
- **Time to first action** includes one planner call (typically 1–4 s with a hosted model). The engine itself snapshots typical windows in 5–60 ms. See `docs/benchmarks/`.
- **Shortcut conflicts with other apps.** Glide detects clashes with macOS system shortcuts and between its own actions. Another app that registers the same global shortcut (ChatGPT also defaults to ⌥Space, for example) can't be detected, and whichever app registered first receives it. Change the shortcut in Settings › Shortcuts if it doesn't open Glide.

## Commands, files and data

- **Command safety is rule-based.** The checker parses the shell line and rates every command in it, but it's a fixed rule set, not a sandbox. A command it rates low or medium still runs with your user's full permissions. Use *Read-only* command access if you don't need Glide to change things.
- **Scripts are rated by keywords.** AppleScript and JXA risk comes from a keyword scan, not from understanding the script, and a shortcut's actions can't be inspected at all (shortcuts are at least medium risk).
- **Spreadsheets** are CSV, TSV and `.xlsx` only. Old `.xls`, Numbers, `.ods`, `.xlsb` and password-protected workbooks must be saved as `.xlsx` or CSV first. Glide won't overwrite cells that hold shared or array formulas, and it writes values, never formulas.

## Browser

- **DOM-level control is Chrome only.** The browser tools drive Google Chrome (or Chrome Beta, Chromium, or another Chromium-based browser you pick for Glide's own window in Settings › Browser). Other browsers are driven on screen through their accessibility tree like any app. For Safari, Chrome, Brave, Edge and Arc, on-screen steps also read the page's address and title over Apple Events, and the page text if you enable *Allow JavaScript from Apple Events* in the browser's developer settings.
- **The extension is loaded unpacked.** It isn't in the Chrome Web Store, so you load it from `chrome://extensions` with Developer mode on, and pair it once. It needs Chrome 118 or later. One Chrome profile at a time can be connected; a newer connection replaces the older one.
- **Chrome shows a debugging bar** ("started debugging this browser") while Glide works in your tabs. Closing it stops Glide from working in your tabs until you click **Allow again** in the extension's popup.
- **Glide's own Chrome has its own logins.** It uses a separate profile, so sites you're signed in to in your everyday Chrome aren't signed in there. `glidectl` always uses Glide's own Chrome, because the app owns the extension's port.
- **The bridge port has no control in Settings yet.** The extension connects on port 47823 by default. If another app holds that port, Glide says so in Settings › Browser and keeps retrying. The port is stored as `browser.bridgePort` in Glide's saved settings, but there's no field to change it.
- **What a snapshot sees.** Snapshots list up to 300 interactive elements, including open shadow roots and same-origin frames. Content inside cross-origin frames (many embedded sign-in, payment and comment widgets) isn't visible to the browser tools.
- **Not supported in the browser tools:** file uploads, managing downloads, and pages that need a `confirm()` or `prompt()` dialog accepted (dialogs are answered automatically: alerts dismissed, `confirm()` and `prompt()` declined).
- **Sites that resist automation.** Some sites detect automated browsers and block or challenge them. Glide doesn't try to get around that.
- **Web search depends on DuckDuckGo.** `web.search` reads DuckDuckGo's HTML results page. When DuckDuckGo shows a bot check, the search fails and the model has to use the browser instead, and a change to that page can break parsing. `web.fetch` reads the HTML the server sends, without running JavaScript, and stops at 5 MB and 20 seconds; pages that need scripts or a login need the browser route.

## Jobs

- **Jobs run only while Glide is running.** Waits and daily schedules wake a job only while the app is open. Glide doesn't wake the Mac or start itself for a scheduled job; turn on *Open at login* in Settings › General if you rely on schedules. `glidectl job run` stops following a job once it starts waiting; continue it with `glidectl job resume <id>` (which wakes it now) or from the app after a relaunch.
- **Sleep still pauses work.** While a job runs, Glide prevents *idle* sleep only. Closing the lid or choosing Sleep still puts the Mac to sleep, and work stops until it wakes. A step that was in flight may fail and be retried. Time asleep isn't counted against the job's time budget.
- **On-screen steps wait for the screen.** A job's `gui` and `native` steps need the screen lease, so they run one item at a time and wait while a quick task runs. With *Use the screen: Only when I'm idle* (the default) they wait until you've left the mouse and keyboard alone for 30 seconds; with *Never*, the job pauses and asks.
- **Estimates are rough.** Item counts are real, but minutes, model calls and cost come from a simple formula. Cost is unknown for models without built-in prices.
- **Milestone checks are model judgments.** After each milestone a model decides from the job's saved results whether it's done, and may add up to 2 steps to finish it before the job fails.
- **The app and `glidectl` share one job store without locking.** The app loads the job list when it starts, so jobs that `glidectl` creates or changes while the app is open show up after you relaunch Glide. Don't run the same job from both at once.
