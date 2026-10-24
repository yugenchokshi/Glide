# Security

Glide controls your real mouse and keyboard, runs commands, and works in your browser, so its safety model is part of the product. This document describes what it does to protect you and what it can't guarantee.

## Reporting a vulnerability

Please open a private security advisory on GitHub (Security › Report a vulnerability) rather than a public issue. Include steps to reproduce and the macOS version.

## Credentials

- API keys for OpenAI, Anthropic, custom endpoints, Composio and TypeSafe, and secret MCP headers, are stored only in the macOS Keychain as generic passwords with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The Chrome extension's pairing token is stored there too.
- Keys are never written to settings, SQLite or logs, never placed in model prompts, and never shown in full in the UI (they're masked by default). `SecretScrubber` removes key-shaped strings from anything stored in history.
- Requests go straight from your Mac to the provider you configured. The repository contains no Glide server and no developer-owned keys.
- Composio sign-ins for third-party apps use Composio's hosted connect flow in your browser. No OAuth client secret ships in the app.

## Actions

- **Approval.** High-risk actions require your approval before they run: sending messages or email, deleting, publishing or posting, purchases, payments, security settings and destructive shell commands. Risk is the higher of a deterministic rule set and the model's own label. In Settings you can also require approval for medium-risk actions or for every action.
- **Hard blocks.** Typing into password (secure text) fields, entering anything that passes a Luhn check as a card number, and acting in apps on your exclusion list are refused outright.
- **Emergency stop.** The global shortcut (default ⌃⌥⌘.) works with the UI hidden. It stops all further input injection immediately: every event checks a shared gate before it's posted. It also halts every background job (see [Jobs](#jobs)). Actions that already completed can't be undone.
- **User takeover.** Moving or clicking the mouse during a task pauses it. Agent events are tagged so they can be told apart from yours.
- **Runaway protection.** Limits on steps, actions, retries, replans, total time and repeated identical actions all end the task with an explanation.

## Commands, scripts and files

Every tool call is assessed by the tool's own fixed rules before it runs. No model is involved, and the model can't lower a call's risk. A blocked call never runs; a call that needs approval waits for you, following your approval level in Settings › Safety.

**Command access** (Settings › Speed & Commands) applies on top:

| Setting | Effect |
|---|---|
| Off | No command, file or system tools are offered, and any such call is blocked. |
| Read-only | Only calls rated low risk run. Tools that can only change things aren't offered. |
| Full (default) | Calls follow their risk level and your approval settings. Blocked calls stay blocked. |

Turning off AppleScript or Shortcuts also blocks `osascript` and `shortcuts` inside shell commands.

`shell.run` parses the whole command line before it runs: every command in pipelines, `;`, `&&` and `||` lists, `$(…)` and backtick substitutions, subshells, `sh -c` strings, `eval`, `find -exec`, `xargs` and here-documents, plus every redirection. The highest risk wins. Anything the checker can't see through, such as a program name chosen at run time, is rated high. Low and medium calls run without asking unless you raised the approval level in Settings › Safety.

| Risk | Examples |
|---|---|
| Low | Reading: `ls`, `cat`, `grep`, `find` without `-delete`/`-exec`, `mdfind`, `git status`/`log`/`diff`, `curl` that only fetches, `fs.list`, `fs.read`, `sheet.read`, `web.fetch` of a public page. |
| Medium | Local changes in your home or temporary folders: `mv`, `cp`, `mkdir`, writes through redirection, `git commit`, package installs, `fs.write` to a new file, `sheet.append`, `clipboard.write`, `system.open`, running a shortcut. |
| High (always asks) | Deleting (`rm`, `find -delete`, `git clean`, `fs.trash`); overwriting (`fs.write` in overwrite mode, `fs.move` with overwrite, `sheet.update` or `sheet.write` overwrite of a file that existed before the task); sending or uploading (`curl` POST or uploads, `ssh`, `scp`, `rsync` to another computer, `git push`, mail); stopping processes (`kill`, `pkill`); `launchctl` and `crontab` changes; `chmod -R`, `chown`; anything written outside your home and temporary folders; reading or changing private keys and credentials (`~/.ssh`, `~/.aws`, keychains…); changing shell startup files, LaunchAgents or Glide's own settings. |
| Blocked (never runs) | `sudo`, `su`, `doas`; shutting down or restarting; `csrutil`, `nvram`, turning off Gatekeeper; formatting, erasing or partitioning disks (`diskutil erase…`, `mkfs`, `dd of=`); recursively deleting `/`, your home folder or other system or account folders, or deleting `~/Library` or the keychains; piping downloaded content into a shell or interpreter (`curl … \| sh`); fork bombs; `kill -1`. |

AppleScript and JavaScript for Automation are rated by a keyword scan. Scripts that send, delete, remove, empty the Trash, restart, shut down or log out, erase, buy, type keystrokes, or run shell commands or other scripts are high, and so is JXA that uses the Objective-C bridge. Literal `do shell script "…"` commands are also checked like `shell.run`, so the script route can't run something the shell route would block. A shortcut is medium (its actions can't be checked in advance), or high when its name says it sends, deletes or buys.

Commands and scripts run in their own process group with an empty stdin and a timeout (for `shell.run`, 60 seconds by default and at most 10 minutes). The emergency stop or a timeout ends the whole group: SIGTERM, then SIGKILL two seconds later. Environment variables whose names contain `KEY`, `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD` or `CREDENTIAL` are removed before a command starts. `clipboard.read` refuses items a password manager marked as concealed. `system.open` of `file:`, `javascript:` or `data:` URLs, or of a file that runs code, is high.

## Browser

Glide controls Chrome at the DOM level in one of two ways: the Glide extension in your own Chrome, or Glide's own Chrome window. The same rules apply to both.

**What browser tools may do.** Risk comes from the element the model saw in the latest snapshot (its name, role and the form or dialog it's in), the page's address and title, and the call's arguments. The word lists are the ones `SafetyPolicy` uses on screen, so a "Send", "Delete", "Buy now" or "Publish" button needs approval in a background tab exactly as it does on screen.

- Clicking a button that commits a form on a checkout or payment page is high.
- Pressing Return in a messaging site (Gmail, Slack, WhatsApp, Discord, Teams, LinkedIn…) is high, and so is ⌘/Ctrl+Return anywhere.
- Typing into password fields, and entering card numbers or typing into card-number, CVV or expiry fields, is blocked. Snapshots never include the value of a password field.
- Opening `file:` or `javascript:` URLs is high. Chrome's own pages, other extensions and the Web Store can't be opened or automated.
- Closing a tab Glide didn't open is high.
- Actions must use an element ref from the latest snapshot, and the step runner fills in the element's name itself, so the model can't describe a risky button as a harmless one.

**The extension connection.**

- The extension connects out to Glide over `ws://127.0.0.1:<port>/glide` (port 47823 by default). The bridge listens only on the loopback interface, and refuses requests whose `Host` isn't `127.0.0.1` or `localhost`, as a defense against DNS rebinding.
- It accepts only the `Origin` Chrome sends for the Glide extension, `chrome-extension://ijondegifnhgojpklbepjoeocacalghd`. The id is fixed by the public key in `Extensions/chrome/manifest.json`; the private key isn't in the repository.
- Pairing uses a secret of 32 random bytes, kept in the Keychain on the Mac and in the extension's `chrome.storage.local`. The pairing link (`chrome-extension://<id>/pair.html#token=…&port=…`) carries it in the URL fragment, which is never sent anywhere, and the pairing page wipes it from the address bar. You can also paste a `port:token` pairing code into the extension's popup.
- The secret itself never goes over the connection. The extension's connection request carries a timestamped one-time nonce and an HMAC-SHA256 proof made with the secret. Glide refuses proofs that don't match, nonces more than 2 minutes off, and nonces it has seen before. Glide's first message carries its own HMAC proof for the same nonce, and the extension obeys nothing until it has checked it. So another program listening on the port while Glide isn't running learns only a single-use proof and can't command your browser.
- One extension connection is active at a time; a newer one replaces it. **Reset pairing** in Settings › Browser mints a new secret and disconnects the extension.
- The extension refuses DevTools methods that could read or erase data from every site at once or weaken security: reading all cookies, clearing cookies, cache or site data, ignoring certificate errors, and changing download behavior.
- Chrome shows its "started debugging this browser" bar while the extension is attached to any tab. If you close that bar, Glide stops working in your tabs until you click **Allow again** in the extension's popup. When Glide disconnects, the extension detaches from every tab.
- JavaScript dialogs are answered automatically so they can't stall a tab: alerts are dismissed, leaving a page is allowed, and `confirm()` and `prompt()` are declined.

**Glide's own Chrome** uses a separate profile in `~/Library/Application Support/Glide/GlideChrome`, apart from your everyday Chrome, and a DevTools port on localhost chosen by Chrome at launch. As with any Chrome started with remote debugging, other programs on this Mac could connect to that port while that Chrome is running. Prefer the extension if that matters to you.

## Web and data

- `web.fetch`, `web.fetch_many` and `web.search` only read. They accept only `http` and `https` URLs, refuse URLs with a password in them, follow at most 10 redirects and read at most 5 MB. Addresses on this Mac or your local network are rated medium, so they follow your approval level.
- When DuckDuckGo answers a search with a bot check, the search fails with a message. Glide never tries to get around it.
- Spreadsheet tools refuse to write into system folders (`/System`, `/usr`, `/etc`…) and the keychains. Writes outside your home and temporary folders are high. Updating or overwriting a file that existed before the task is high, and the first change a task or job makes to such a file keeps a `<file>.bak` copy of it. A job keeps its first backup even when it is resumed after a relaunch: the `.bak` is tagged with the job that made it.
- Values are written as text or plain numbers, never as formulas. In CSV files, text that a spreadsheet app would run as a formula (`=`, `+`, `-`, `@`…) is neutralized, since values often come from web pages.

## Jobs

Background jobs use the same tools, the same deterministic checks and the same approval policy as quick tasks. In addition:

- **Approvals wait.** A job's approval request shows in the notch (and as a notification when the notch is closed) and the job waits for your answer. Time spent waiting doesn't count toward its time budget.
- **Write-back asks first.** Before a loop writes results into a spreadsheet that already exists, the job asks once per loop (the answer is remembered across pauses and restarts) and keeps a `.bak` copy. If you decline, results stay in the job's table for export.
- **Checkpoints.** The job planner is told to mark milestones that send, post, publish, delete or buy as "asks first", and the job asks before starting those. That marking is the model's choice; the per-call checks above apply either way.
- **Budgets.** Each job has a cost, running-time and model-call budget (defaults $5, 4 hours and 2,000 calls, set in Settings › Jobs). Reaching one pauses the job with status *needs input*; resuming allows the same amount again. A job also pauses when 12 steps in a row make no progress, or when more than 30% of at least 5 finished items failed. An item that needs you (a sign-in, for example) is marked failed without being retried.
- **Emergency stop.** The emergency stop cancels every job's step in flight at once, the same way Stop does (commands are killed, browser calls end), but leaves the jobs *paused* so they can be resumed. Each job also has its own stop switch, so stopping one job never affects another.
- **The screen.** Jobs run on-screen steps only while holding the screen lease. With *Use the screen: Never*, such a step pauses the job and asks instead.
- **Job files.** `workspace.*` file tools only read and write inside the job's folder.

## Screen content

- Accessibility data (control roles, labels and values) is sent to your planner and action models as text. Secure field values are never read.
- Browser snapshots (element names, values other than passwords, headings and page text) and tool output (command output, file contents, fetched pages) are sent to your action model as text.
- Screenshots are captured only when a control isn't in the accessibility tree and local OCR can't find it. With the default setting, you're asked before any screenshot goes to a vision model. Secure fields are blacked out first. You can set this to *always* or *never* in Settings › Safety.
- Screenshots aren't stored. Task history keeps only text descriptions of actions.

## Prompt injection

Web pages, documents, command output and files can contain text aimed at the agent. Glide treats that text as data. The executor prompt tells the model never to enter passwords or payment details and to stop at logins and CAPTCHAs. The deterministic safety rules, the blocked list and the approval gate don't depend on the model's cooperation. Even so, a model can be misled into a harmful *low-risk-looking* action, and background tabs and jobs make it easier to miss. Keep approvals enabled, use *Read-only* command access if you don't need changes, exclude sensitive apps, and supervise tasks that touch untrusted content.

## Permissions

Glide asks for:

- **Accessibility** (required): reading UI and injecting input.
- **Screen Recording** (optional): OCR and vision fallback.
- **Automation** (optional, per app): browser URL and page text, and apps that AppleScript tools script.
- **Microphone and Speech** (optional): on-device dictation.
- **Notifications** (optional): telling you when a background job finishes or needs you.

It can't run in the App Sandbox, because Accessibility clients aren't allowed there. It is built with the hardened runtime.
