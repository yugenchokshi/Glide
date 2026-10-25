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
- **Emergency stop.** The global shortcut (default ⌃⌥⌘.) works with the UI hidden. It stops all further input injection immediately: every event checks a shared gate before it's posted. It also halts every background job the app runs (see [Jobs](#jobs)); a job `glidectl` runs is halted with Ctrl-C in its terminal. Actions that already completed can't be undone.
- **User takeover.** Moving or clicking the mouse during a task pauses it. A background job's on-screen step stops the same way, gives the screen back, and carries on by itself once you've been idle (with *Use the screen: Any time*, only input that collides with the agent's counts). Agent events are tagged so they can be told apart from yours.
- **Glide's own controls.** The agent can't see Glide's windows, so Glide drops any input its agent posted before a window sees it, and the notch lets clicks pass through while the agent uses the pointer. Approve, Reject and Stop answer the request they were drawn for. A click on a request that has just been replaced, or that appeared less than half a second ago, is ignored.
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

The checker also follows the ways a shell can run code or reach a file indirectly:

- **Text that runs as code** is checked like the command it runs: `eval`, `sh -c`, zsh's `emulate -c`, `${(e)…}`, glob qualifiers that run code, and wrappers that start another program (`env`, `zpty`, `script`, `sandbox-exec`, `taskpolicy`, `setsid`…). When that text is only known at run time, the call is high. Arithmetic over run-time text (`(( $(cmd) ))`, or a variable read from command output) is high, because the shell can run commands hidden in it, and blocked when the text was downloaded.
- **Options and settings that name a program.** git options and settings that make git run a program (`git -c core.sshCommand=…`, `--upload-pack`, `rebase --exec`, a saved `git config` value, an alias) are high, including long options shortened to a prefix git accepts (`--upl`). So are pager and helper options such as `less +!cmd` and `man -P`.
- **Environment variables** that make programs run a command or load code (`GIT_SSH_COMMAND`, `PAGER`, `DYLD_*`, `BASH_ENV`, `HOME`, a `PATH` entry in a folder Glide can write to…) are high however they're set: before a command, with `export`, `declare` or `typeset`, by `read`, or as a `for` loop variable. Values that do nothing, such as `GIT_EDITOR=true` or `PAGER=cat`, stay low.
- **Paths are matched the way the shell will expand them.** Globs, braces, `~` forms and variables set earlier on the line are matched against the protected folders, so `rm -rf ~/L*` is blocked like `rm -rf ~/Library` and `cat ~/.ss*/id_ed25519` is high like reading `~/.ssh`. A relative path after a `cd` that might not take effect is also judged against the folder before it.
- **Bounded.** The checker never guesses: a line nested too deeply to follow is rated high, and a brace expression with too many alternatives to list is judged as if it could name any file. A command over 200,000 characters isn't run at all.

| Risk | Examples |
|---|---|
| Low | Reading: `ls`, `cat`, `grep`, `find` without `-delete`/`-exec`, `mdfind`, `git status`/`log`/`diff`, `curl` that only fetches, `fs.list`, `fs.read`, `sheet.read`, `web.fetch` of a public page. |
| Medium | Local changes in your home or temporary folders: `mv`, `cp`, `mkdir`, writes through redirection, `git commit`, package installs, `fs.write` to a new file, `sheet.append`, `clipboard.write`, `system.open`, running a shortcut, running a program from a folder Glide can write to (`~/bin/tool`). |
| High (always asks) | Deleting (`rm`, `find -delete`, `git clean`, `fs.trash`); overwriting (`fs.write` in overwrite mode, `fs.move` with overwrite, `sheet.update` or `sheet.write` overwrite of a file that existed before the task); sending or uploading (`curl` POST or uploads, `ssh`, `scp`, `rsync` to another computer, `git push`, mail); stopping processes (`kill`, `pkill`); `launchctl` and `crontab` changes; `chmod -R`, `chown`; anything written outside your home and temporary folders; reading or changing private keys and credentials (`~/.ssh`, `~/.aws`, keychains…); changing shell startup files, LaunchAgents or Glide's own settings; running text or a program chosen at run time (`eval "$x"`, `$cmd file`); git options and environment variables that make a program run a command (`git -c core.pager=…`, `GIT_SSH_COMMAND=…`); reading the clipboard after a delay or in a loop. |
| Blocked (never runs) | `sudo`, `su`, `doas`; shutting down or restarting; `csrutil`, `nvram`, turning off Gatekeeper; formatting, erasing or partitioning disks (`diskutil erase…`, `mkfs`, `dd of=`); recursively deleting `/`, your home folder or other system or account folders, or deleting `~/Library` or the keychains, also through a glob, a variable or a wrapper (`rm -rf ~/L*`, `x=rm; $x -rf ~`, `zpty p rm -rf ~`); piping downloaded content into a shell or interpreter, or evaluating it (`curl … \| sh`); fork bombs; `kill -1`. |

AppleScript and JavaScript for Automation are rated by a keyword scan. Scripts that send, delete, remove, empty the Trash, restart, shut down or log out, erase, buy, type keystrokes, or run shell commands or other scripts are high, and so is JXA that uses the Objective-C bridge. Literal `do shell script "…"` commands are also checked like `shell.run`, so the script route can't run something the shell route would block. A shortcut is medium (its actions can't be checked in advance), or high when its name says it sends, deletes or buys.

Composio and MCP tools run code Glide can't inspect, so they're judged by name. The name is split into words whatever its style (`gmail_send`, `API-delete-a-block`, `deleteRecord`), and the verb decides: a tool whose verb only reads (`get`, `list`, `search`, `fetch`…) starts at low, any other at medium, and one that sends, deletes, posts or pays is high. A generic request tool called with HTTP `DELETE` is high, and with `POST`, `PUT` or `PATCH` at least medium.

Commands and scripts run in their own process group with an empty stdin and a timeout (for `shell.run`, 60 seconds by default and at most 10 minutes). The emergency stop or a timeout ends the whole group: SIGTERM, then SIGKILL two seconds later. Environment variables whose names contain `KEY`, `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD` or `CREDENTIAL` are removed before a command starts. `clipboard.read` refuses items a password manager marked as concealed. For the same reason, a `shell.run` command that reads the clipboard or starts a script interpreter, and every AppleScript and JXA script, won't run while the clipboard holds such an item. That check looks only at the item's type, never its contents. `system.open` of `file:`, `javascript:` or `data:` URLs, or of a file that runs code, is high.

## Browser

Glide controls Chrome at the DOM level in one of two ways: the Glide extension in your own Chrome, or Glide's own Chrome window. The same rules apply to both.

**What browser tools may do.** Risk comes from the element the model saw in the latest snapshot (its name, role and the form or dialog it's in), the page's address and title, and the call's arguments. The word lists are the ones `SafetyPolicy` uses on screen, so a "Send", "Delete", "Buy now" or "Publish" button needs approval in a background tab exactly as it does on screen.

- Clicking a button that commits a form on a checkout or payment page is high.
- Pressing Return in a messaging site (Gmail, Slack, WhatsApp, Discord, Teams, LinkedIn…) is high, and so is ⌘/Ctrl+Return anywhere.
- Typing into password fields, and entering card numbers or typing into card-number, CVV or expiry fields, is blocked. Snapshots never include the value of a password field.
- The same goes for `browser.press`, which types one key at a time. It won't type or paste (⌘V, Shift+Insert) into a password or payment card field, and right before each key that puts text in, it checks the field that has focus at that moment. A call that types after a key that can move focus (Tab, Enter, Escape…) is refused: the model presses that key in one call and types in the next. Enter and Tab on their own still work, so a form you filled in can be submitted. Typing where the snapshot can't see focus (inside a cross-origin frame, say) is medium.
- Opening `file:` or `javascript:` URLs is high. Chrome's own pages, other extensions and the Web Store can't be opened or automated.
- Closing a tab Glide didn't open is high. A new tab that a page opens counts as Glide's only when it came from one of Glide's own tabs while Glide was working there; one opened from your tab stays yours.
- Actions must use an element ref from the latest snapshot, and the step runner fills in the element's name itself, so the model can't describe a risky button as a harmless one.
- **Page dialogs.** A JavaScript dialog freezes its page until it's answered. In tabs Glide opened, and in a tab it's working in at that moment, Glide answers it the same way every time: alerts are dismissed, `confirm()` and `prompt()` are declined, and leaving the page is allowed. In your own tabs, "Leave site?" is accepted only when one of Glide's clicks, keys or navigations brought it up, never while Glide only reads the tab. Any other dialog is left for you, and Glide's commands in that tab fail at once ("Answer it in Chrome") until you've answered it. This applies to both the extension and Glide's own Chrome.

**The extension connection.**

- The extension connects out to Glide over `ws://127.0.0.1:<port>/glide` (port 47823 by default). The bridge listens only on the loopback interface, and refuses requests whose `Host` isn't `127.0.0.1` or `localhost`, as a defense against DNS rebinding.
- It accepts only the `Origin` Chrome sends for the Glide extension, `chrome-extension://ijondegifnhgojpklbepjoeocacalghd`. The id is fixed by the public key in `Extensions/chrome/manifest.json`; the private key isn't in the repository.
- Pairing uses a secret of 32 random bytes, kept in the Keychain on the Mac and in the extension's `chrome.storage.local`. The pairing link (`chrome-extension://<id>/pair.html#token=…&port=…`) carries it in the URL fragment, which is never sent anywhere, and the pairing page wipes it from the address bar. Opening the link isn't enough: the page shows the port it would connect to and saves nothing until you click **Pair**, so another app that opens such a link in Chrome can't point the extension at a server of its own. The page points out a port other than 47823, and a pairing it would replace. You can also paste a `port:token` pairing code into the extension's popup.
- The secret itself never goes over the connection. The extension's connection request carries a timestamped one-time nonce and an HMAC-SHA256 proof made with the secret. Glide refuses proofs that don't match, nonces more than 2 minutes off, and nonces it has seen before. Glide's first message carries its own HMAC proof for the same nonce, and the extension obeys nothing until it has checked it. So another program listening on the port while Glide isn't running learns only a single-use proof and can't command your browser.
- One extension connection is active at a time; a newer one replaces it. **Reset pairing** in Settings › Browser mints a new secret and disconnects the extension.
- The extension refuses DevTools methods that could read or erase data from every site at once or weaken security: reading all cookies, clearing cookies, cache or site data, ignoring certificate errors, and changing download behavior.
- Chrome shows its "started debugging this browser" bar while the extension is attached to any tab. If you close that bar, Glide stops working in your tabs until you click **Allow again** in the extension's popup. The extension detaches from a tab you opened 45 seconds after Glide's last command there (tabs Glide opened stay attached until it closes them), and from every tab when Glide disconnects.
- The extension also uses `chrome.webNavigation`, only to tell which tab a new tab was opened from.

**Glide's own Chrome** uses a separate profile in `~/Library/Application Support/Glide/GlideChrome`, apart from your everyday Chrome, and a DevTools port on localhost chosen by Chrome at launch. As with any Chrome started with remote debugging, other programs on this Mac could connect to that port while that Chrome is running. Prefer the extension if that matters to you.

## Web and data

- `web.fetch`, `web.fetch_many` and `web.search` only read. They accept only `http` and `https` URLs, refuse URLs with a password in them, follow at most 10 redirects and read at most 5 MB. Addresses on this Mac or your local network (by IP address, including IPv4 written inside IPv6, or by names such as `.local` and `.lan`) are rated medium, so they follow your approval level.
- A name that resolves to this Mac or your local network, such as an intranet site or a `.test` development host, is fetched like a local address. A page that started on the internet still can't reach in: Glide looks up every redirect's name and refuses one that leads to a local address, and refuses a response whose connection ended at a local address.
- When DuckDuckGo answers a search with a bot check, the search fails with a message. Glide never tries to get around it.
- Spreadsheet tools refuse to write into system folders (`/System`, `/usr`, `/etc`…) and the keychains. Writes outside your home and temporary folders are high. Updating or overwriting a file that existed before the task is high, and the first change a task or job makes to such a file keeps a `<file>.bak` copy of it. A job keeps its first backup even when it is resumed after a relaunch: the `.bak` is tagged with the job that made it.
- Values are written as text or plain numbers, never as formulas. In CSV files, text that a spreadsheet app would run as a formula (`=`, `+`, `-`, `@`…) is neutralized, since values often come from web pages.

## Jobs

Background jobs use the same tools, the same deterministic checks and the same approval policy as quick tasks. In addition:

- **Approvals wait.** A job's approval request shows in the notch (and as a notification when the notch is closed or busy with something else) and the job waits for your answer. Time spent waiting doesn't count toward its time budget. While a quick task holds the screen, a job's approval waits until the task is done, since the task's clicks could land on it (the running pill shows a raised hand meanwhile). A job's approval card takes clicks only once the agent's pointer has been still for a second.
- **Write-back asks first.** Before a loop writes results into a spreadsheet that already exists, the job asks once per loop (the answer is remembered across pauses and restarts) and keeps a `.bak` copy. If you decline, results stay in the job's table for export. Results go into the sheet the items came from, and a source file without a header row is never written to.
- **One process per job.** The app and `glidectl` share the job store, but a lock file in the job's folder keeps them from running the same job at once. A job another process is running is shown, not controlled: the app labels it *Running in another Glide process* and hides its controls. `glidectl` looks after only the jobs it runs, so its Ctrl-C never pauses the app's jobs.
- **Checkpoints.** The job planner is told to mark milestones that send, post, publish, delete or buy as "asks first", and the job asks before starting those. That marking is the model's choice; the per-call checks above apply either way.
- **Budgets.** Each job has a cost, running-time and model-call budget (defaults $5, 4 hours and 2,000 calls, set in Settings › Jobs). Reaching one pauses the job with status *needs input*; resuming allows the same amount again. A job also pauses when 12 steps in a row make no progress, or when more than 30% of at least 5 finished items failed. An item that needs you (a sign-in, for example) is marked failed without being retried.
- **Emergency stop.** The emergency stop cancels every job's step in flight at once, the same way Stop does (commands are killed, browser calls end), but leaves the jobs *paused* so they can be resumed. Each job also has its own stop switch, so stopping one job never affects another. It covers the jobs the app runs; stop a job `glidectl` runs with Ctrl-C in its terminal.
- **The screen.** Jobs run on-screen steps only while holding the screen lease. With *Use the screen: Never*, such a step pauses the job and asks instead. Input Glide posts itself never counts as yours when it decides whether you're idle. A step waiting for you to leave the Mac alone never takes the screen back once you've paused or stopped its job.
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
