# Design: long-running jobs and fast tools

Status: in development on `feature/long-jobs-and-speed`. This is the build spec. Shared contracts are already in the code; each component below is built against them.

## Goals

1. **Speed.** Do work directly instead of click by click where possible: shell commands, AppleScript/JXA, Shortcuts, file operations, DOM-level browser control (Playwright-style) in the user's own Chrome, HTTP fetches, and direct spreadsheet I/O. The action model returns several actions per call (batching). The cursor is only used for steps that truly need the UI.
2. **Long tasks.** Tasks that run for minutes to hours (or across days) as persisted, resumable **jobs**:
   - plans made of milestones;
   - loops over items with per-item status, retries and parallelism;
   - waits and schedules;
   - structured memory (the workspace);
   - budgets and stuck detection;
   - a background mode that doesn't take over the cursor;
   - progress, approvals and a report.

Glide is an open-source macOS app (Swift 6, SwiftUI/AppKit, SwiftPM, macOS 26, no third-party dependencies). Keep it that way: no new packages.

## Shared contracts (already in the code; don't change their signatures)

| File | What |
|---|---|
| `Sources/AgentKit/Tools/Tool.swift` | `AgentTool`, `ToolSpec`, `ToolCall`, `ToolOutput`, `ToolVerdict`, `ToolContext`, `ToolRegistry` (+ `registerFactory` / `standard`), `ToolError`, arg helpers, `toolTruncate` |
| `Sources/AgentKit/Tools/TableIO.swift` | `TableData`, `TableIO.reader/updater/writer` hooks (CSV fallback built in) |
| `Sources/AgentKit/Jobs/JobModels.swift` | `JobStatus`, `ItemStatus`, `RecipeStep`, `ItemSource`, `WriteBack`, `ForEachSpec`, `WaitSpec`, `JobStepKind`, `JobStep`, `Milestone`, `JobEstimate`, `JobPlan`, `JobBudget`, `JobUsage`, `JobCursor`, `JobRecord`, `JobItem`, `WorkspaceFact`, `WorkspaceRow`, `JobWorkspace` protocol, `StepRequest`, `StepResult`, `StepExecuting`, `ExecutionRoute.toolCategories/needsScreen` |
| `Sources/AgentKit/Jobs/JobCenter.swift` | UI-facing `@MainActor @Observable JobCenter` API (skeleton bodies, filled in by the jobs component) |
| `Sources/AgentKit/Agent/StepExecutorFactory.swift` | Hook through which the job engine gets the standard step executor |
| `Sources/AutomationKit/Browser/BrowserBackend.swift` | `BrowserBackend` protocol, `BrowserBackendKind`, `BrowserTab`, `BrowserError`, `BrowserStatus`, `ChromeLocator` |
| `Sources/AgentKit/Browser/BrowserHub.swift` | Backend registry and selection, status, pairing hooks (`pairingProvider`, `resetPairing`, `isExtensionPaired`) |
| `Sources/AgentKit/Settings/AppSettings.swift` | `ToolSettings` (`executionPreference`, `commandAccess`, …), `BrowserSettings`, `JobSettings` (`screenUse`, budgets, thresholds) |
| `Sources/AgentKit/Agent/Plan.swift` | `ExecutionRoute` now has `.command`, `.browser`, `.web`, `.data` |
| `Sources/AutomationKit/Core/JSONValue.swift` | `JSONValue`, `Schema` builders (moved here; AgentKit re-exports AutomationKit) |

Existing pieces to reuse:
- `SafetyPolicy` (`needsApproval(verdict)`, approval levels)
- `AgentCallbacks` (`phase`, `log`, `plan`, `approve`)
- `ApprovalRequest`, `ActivityEntry`
- `LLMProvider`, `LLMRequest` / `LLMResponse` (strict JSON schema replies), `ModelRouter` (roles: planner, actor, vision, recovery), `TaskMetrics`
- `LocalStore` (SQLite at `~/Library/Application Support/NotchBuddy/notchbuddy.sqlite`, via `SQLiteDatabase`)
- `CredentialStore` (Keychain)
- `AutomationRuntime` (gate, accessibility, executor, verification)
- `ExecutionGate` (stop and pause)
- BoardKit (UI components, `BKTheme`)

## Rules for every component

- **Build and test.** Run `swift build` and your tests (`swift test --filter <YourTests>`) and fix all errors and new warnings.
- **No real UI automation in tests.** Don't move the mouse, type, or launch GUI apps (no `glidectl bench`, no NBFixtureApp). Headless Chrome with a temporary profile is allowed for the browser driver.
- **Nothing outside the Mac.** No calls to paid APIs. No touching the user's real Keychain entries (tests use their own `CredentialStore(service:)`). No network access except localhost and local fixtures.
- **Ownership.** Only edit the files your component owns (listed below). If you need a contract change, don't make it; describe it in your final report.
- **Code style.** Match the existing code: doc comments that explain *why*, Swift 6 strict concurrency, `@unchecked Sendable` only with a lock, no force-unwraps on external data, user-facing errors in plain language.
- **Commit** on your branch with a clear message that ends with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- **Safety is deterministic.** Every tool's `assess` must be fast and model-free. Anything that sends, deletes, overwrites, pays, publishes or changes security goes to `.high`. Truly dangerous things are `blocked`.

---

## A. Commands, files and system tools

**Owns:**
- `Sources/AgentKit/Tools/Commands/*.swift`
- `Tests/AgentKitTests/CommandToolsTests.swift`

**Tools** (each an `AgentTool`; register via `CommandTools.install()` → `ToolRegistry.registerFactory("commands") { settings in [...] }`):

| Tool | Args | Notes |
|---|---|---|
| `shell.run` | `command`, `cwd?`, `timeout_s?` (default 60, max 600) | Runs `/bin/zsh -lc` in a new process group. Captures stdout and stderr (cap 1 MB each, model text truncated), exit code and duration. `context.gate` stop kills the process group (SIGTERM, then SIGKILL after 2 s). Returns `ok = exit == 0`. Environment: inherit, but strip variables whose names contain KEY/TOKEN/SECRET/PASSWORD. |
| `applescript.run` | `script`, `timeout_s?` | `/usr/bin/osascript -e`; returns output. |
| `jxa.run` | `script`, `timeout_s?` | `osascript -l JavaScript`. |
| `shortcuts.list` | — | `/usr/bin/shortcuts list` |
| `shortcuts.run` | `name`, `input?` | `/usr/bin/shortcuts run`; input via a temp file with `-i`. |
| `fs.list` | `path`, `pattern?`, `recursive?`, `max?` | Names, sizes, dates (read-only). |
| `fs.read` | `path`, `max_chars?` | Text files; PDFs via PDFKit text; refuse binaries with a clear message. |
| `fs.write` | `path`, `content`, `mode: create\|overwrite\|append` | `create` fails if the file exists. |
| `fs.move` | `from`, `to`, `overwrite?` | Renames are moves. |
| `fs.copy` | `from`, `to` | |
| `fs.mkdir` | `path` | |
| `fs.trash` | `path` | `NSWorkspace.recycle` (recoverable). **high** risk. |
| `fs.search` | `query`, `folder?`, `max?` | `mdfind` (Spotlight). Read-only. |
| `system.open` | `target` | URL, file path or app name (`/usr/bin/open`). |
| `system.notify` | `title`, `body` | `display notification` via osascript. |
| `clipboard.read` / `clipboard.write` | `text` (write) | NSPasteboard. |

**CommandSafety** (pure function, heavily unit-tested; `CommandSafety.assess(_ command: String) -> ToolVerdict`):
- **Parsing.** Split the command into simple commands on `;`, `&&`, `||`, `|`, newlines, `$(…)` and backticks. Inspect each command's program and flags. Detect redirections (`>`, `>>`, `tee`).
- **Read-only (`.low`):**
  - `ls`, `cat`, `head`, `tail`, `wc`, `grep`/`rg`/`ag`
  - `find` without `-delete`, `-exec` or `-execdir`
  - `mdfind`, `mdls`, `stat`, `file`, `du`, `df`, `pwd`, `echo`/`printf` without redirection, `date`, `cal`, `which`, `whoami`, `id`, `uname`, `sw_vers`, `hostname`, `uptime`
  - `ps`, `top -l`, `pbpaste`, `defaults read`, `plutil -p`/`-lint`, `jq`, `sort`, `uniq`, `cut`, `tr`, `column`
  - `awk` without `system(` and without redirection; `sed` without `-i`
  - `shasum`, `md5`, `base64` (not piped into a shell)
  - `git status`/`log`/`diff`/`show`/`branch`/`remote -v`
  - `curl` or `wget` that only fetch: no `-o`/`-O`, no `-X` other than GET, no `-d`/`--data`/`-F`/`-T`/`--upload-file`
  - `networksetup -get…`, `system_profiler`, `pmset -g`, `ioreg`, `lsof`, `env`, `printenv`, `osascript -e` with a read-only script (see AppleScript rules)
- **Medium:** anything else that changes local state: `mv`, `cp`, `mkdir`, `touch`, `ln`, `chmod` (non-recursive), redirection writes, `git add`/`commit`/`checkout`/`switch`/`stash`, package installs (`npm`, `pip`, `brew install`), `defaults write` (user domain), `open`, `pbcopy`, `zip`/`unzip`/`tar`, `curl -o`.
- **High (approval):**
  - deletion: `rm`, `rmdir`, `trash`, `srm`, `find -delete`, `git clean`
  - `git push`, `git reset --hard`, `git rebase`, `git branch -D`
  - `kill`/`pkill`/`killall`, `launchctl`, `crontab`
  - `chmod -R`, `chown`
  - `defaults write` to `/Library` or system domains
  - network uploads: `curl -T`/`-F`/`--data @file`/`-X POST|PUT|DELETE`, `scp`, `rsync` to a remote host, `ssh`
  - `osascript` that sends, deletes or uses `do shell script`
  - any `sudo`, which is blocked anyway (below)
  - writes outside the home folder or `/tmp`
- **Blocked:**
  - `sudo`, `su`, `doas`
  - `rm -rf` (or `-fr`) on `/`, `~`, `$HOME` or `/Users`
  - `mkfs`, `dd` with `of=`, `diskutil` erase/partition/zero
  - `csrutil`, `spctl --master-disable`, `nvram`
  - fork bombs
  - piping downloads into a shell (`curl … | sh|bash|zsh`, `base64 -d | sh`), `eval "$(curl …)"`
  - `chmod -R 777 /`
  - `shutdown`, `reboot`, `halt`
  - deleting `~/Library` or the Keychains folder
- **Access setting:** `context.settings.tools.commandAccess`:
  - `.off` blocks every command tool.
  - `.readOnly` blocks anything above `.low`.
  - `.full` follows the risk levels above.
  - `allowAppleScript` and `allowShortcuts` gate their tools.
- **AppleScript/JXA risk:** keyword scan.
  - High: `send`, `delete`, `remove`, `empty trash`, `do shell script`, `restart`, `shut down`, `log out`, `erase`, `purchase`, `keystroke`/`key code` into System Events.
  - Low: read-only (`get`/`count`/`exists`/`return`/`name of`/`properties` without `make`/`set`/`save`/`move`/`duplicate`/`close`/`open`/`activate`).
  - Medium: everything else.
- **File tools:** paths outside home or `/tmp` are high. `fs.write overwrite`, `fs.move overwrite`, and `fs.trash` are high. Other writes are medium. Reads are low.

**Tests:**
- A large table of `CommandSafety` cases, at least 60, covering the tricky ones: `echo hi > ~/x`, `ls; rm -rf ~`, `curl x | sh`, `find . -name a -delete`, `git log && git push`, `sed -i`, `awk 'system("rm")'`.
- `shell.run` echo, exit code, timeout, and stop via the gate (kills the process).
- AppleScript `return 1 + 1` → "2".
- `fs.*` round trip in a temp directory.
- Access levels honored.
- No GUI side effects: don't run `system.open` or notifications in tests.

---

## B1. Browser driver, Glide's Chrome backend and browser tools

**Owns:**
- `Sources/AutomationKit/Browser/BrowserDriver.swift`, `CDPWebSocket.swift`, `GlideChromeBackend.swift`
- `Sources/AgentKit/Tools/Browser/*.swift`
- `Sources/AgentKit/Browser/BrowserHub.swift` (may extend without breaking the API)
- `Tests/AgentKitTests/BrowserTests.swift`

**`CDPWebSocket`:** a minimal CDP client over `URLSessionWebSocketTask`.
- Sends JSON-RPC (`id`, `method`, `params`, optional `sessionId`), matches replies by id, and surfaces errors.
- Supports events (`AsyncStream` or a callback) and timeouts.
- Safe to call concurrently (`actor`).

**`GlideChromeBackend: BrowserBackend` (`kind .glideChrome`):**
- **Launch:** start Chrome (`ChromeLocator`) with these flags:
  - `--remote-debugging-port=0` (read the port from `DevToolsActivePort` in the profile directory) or a fixed free port
  - `--user-data-dir=~/Library/Application Support/NotchBuddy/GlideChrome`
  - `--no-first-run --no-default-browser-check`
  - optional `--headless=new` (tests)
- **Connect:** to the browser target's `webSocketDebuggerUrl` (`/json/version`).
- **Tabs:** `Target.createTarget` with `background: true` when requested, `Target.attachToTarget` with `flatten: true` (keep a `sessionId` per tab), `Target.closeTarget`, `Target.activateTarget`, `Target.getTargets` (page targets only).
- **Commands:** `cdp(tabID:method:params:)` sends with the tab's `sessionId`.
- **Reconnect:** when Chrome was quit, `isConnected` is false and `connect()` relaunches.

**`BrowserDriver`** (works on any `BrowserBackend`):
- **`snapshot(tabID:) -> PageSnapshot`.** Injects JS via `Runtime.evaluate` with `returnByValue`. The JS walks the DOM, including open shadow roots and same-origin iframes where possible, and collects visible interactive elements:
  - `a[href]`, `button`, `input` (not hidden), `select`, `textarea`, `[contenteditable]`
  - ARIA roles button, link, checkbox, radio, tab, menuitem, option, switch, textbox, combobox
  - `summary`, `label` for checkboxes, `[onclick]`, `[tabindex]`
  For each element it records:
  - a stable ref: `data-glide-ref="b<n>"`, reused if already present
  - role, accessible name (`aria-label`, `aria-labelledby`, `<label for>`, wrapping label, `alt`, `title`, `placeholder`, trimmed text)
  - value (never for `type=password`: report `[secure]`), checked/selected, disabled, href
  - viewport bounding box, and whether it's in the viewport
  It also returns:
  - page title, URL, scroll position, viewport size
  - headings and readable text, capped at about 6,000 chars, the main content preferred
  Elements cap at about 300, preferring those in the viewport.
  `PageSnapshot.compact()` renders lines like `b12 button "Sign in" [disabled]`, the same style as the AX skeleton.
- **`click(tabID:ref:)`:** `scrollIntoView` (center), then dispatch real mouse events through CDP `Input.dispatchMouseEvent` (moved, pressed, released) at the element center. If the element is covered (`elementFromPoint` isn't the element or inside it), fall back to `element.click()`. Then wait for settle (see `wait`).
- **`type(tabID:ref:text:clear:submit:)`:** focus the element; clear with select-all + Backspace when `clear`; insert text with `Input.insertText`; when `submit`, press Enter with `Input.dispatchKeyEvent` (keyDown/char/keyUp). Refuse `type=password` fields with a clear message.
- **Other actions:**
  - `select(ref:value:)`: set the value, then dispatch `input` and `change` events.
  - `press(keys:)`: e.g. "Enter", "Escape", "Control+A", "Meta+L".
  - `scroll(direction:amount:)`
  - `navigate(url:)`: `Page.navigate`, then wait for load.
  - `back()`
  - `readText(maxChars:selector:)`: main-content text.
  - `screenshot()`: `Page.captureScreenshot` returning PNG data, for the vision fallback.
  - `evaluate(js:)`: exposed only internally.
- **Waiting:** after navigation or a click, poll `document.readyState === "complete"` and a quiet network (track `Network.requestWillBeSent` / `loadingFinished` when events are available, otherwise wait for a stable DOM node count over 300 ms). Overall timeout 15 s. Never use fixed long sleeps.
- **Stale refs:** throw `BrowserError.elementNotFound` with "take a new snapshot".

**Browser tools** (`BrowserTools.install()` → `registerFactory("browser")`). Each resolves the backend with `BrowserHub.shared.backend(for: settings.browser)` and keeps a per-job (or per-task) "current tab" (track it in an actor keyed by `jobID`/`itemID`/"default"; open a background tab on first use):

| Tool | Args |
|---|---|
| `browser.open` | `url`, `new_tab?` |
| `browser.snapshot` | — |
| `browser.click` | `ref` |
| `browser.type` | `ref`, `text`, `clear?`, `submit?` |
| `browser.select` | `ref`, `value` |
| `browser.press` | `keys` |
| `browser.scroll` | `direction`, `amount?` |
| `browser.read` | `max_chars?`, `selector?` |
| `browser.back` | — |
| `browser.tabs` | — |
| `browser.switch_tab` | `tab_id` |
| `browser.close_tab` | `tab_id?` |
| `browser.wait` | `for: text\|selector\|load`, `value?`, `timeout_s?` |

Every action tool returns a fresh compact snapshot (or a diff summary) so the model rarely needs a separate snapshot call.

Risk:
- Click and type assess by the element's name and page context with `SafetyPolicy` word lists (send, delete, buy, post, publish, pay, submit order…). Pass the element name in args: the runner fills `_label` from the last snapshot, so require that `ref` refers to the last snapshot.
- Typing into password fields is blocked.
- `browser.open` of `file:` or `javascript:` URLs is high.

**Tests:** gated on Chrome being installed (skip with a message otherwise).
- Launch headless Glide Chrome with a temp profile and serve a local fixture HTML page from a tiny `NWListener` HTTP server, or use `data:`/`file:` URLs. Cover snapshot refs, click changing text, type and submit a form, select, read text, stale-ref error, two tabs, background tab.
- Always quit Chrome in teardown.

---

## B2. Chrome extension and bridge (your everyday Chrome, your logins)

**Owns:**
- `Extensions/chrome/**`
- `Sources/AutomationKit/Browser/ExtensionBridge.swift`, `ExtensionBackend.swift`
- `Tests/AutomationKitTests/ExtensionBridgeTests.swift`
- `scripts/build_app.sh`: only add copying `Extensions/chrome` to `Glide.app/Contents/Resources/ChromeExtension`
- `scripts/extension_id.swift` (or similar), if needed

**Extension** (Manifest V3, plain JS, no build step, no dependencies):
- **`manifest.json`:**
  - `"name": "Glide"`
  - permissions `["debugger","tabs","storage","alarms","scripting"]`, `host_permissions: ["<all_urls>"]`
  - a background service worker, an `action` popup, and the icons (reuse `build/AppIcon.iconset` PNGs, or generate them)
  - a `"key"` field so the unpacked extension id is stable. Generate an RSA-2048 key pair with `openssl` once; commit only the public key in the manifest, not the private key. Compute the extension id (the first 32 hex chars of the SHA-256 of the DER public key, mapped 0-f → a-p) and expose it as a constant in `ExtensionBridge`.
- **`service_worker.js`:**
  - Connect to `ws://127.0.0.1:<port>/glide?token=<token>`. Port and token come from `chrome.storage.local`; the default port is 47823.
  - Reconnect with backoff. Use a `chrome.alarms` alarm every 0.5 minutes to wake and reconnect. Send a keepalive every 20 s so the MV3 worker stays alive while connected.
  - Implement the RPC commands below.
  - Handle `chrome.debugger.onDetach` (the user dismissed the debugging bar) by reporting it.
  - Never automate `chrome://`, the Web Store, or `chrome-extension://` pages: return a clear error.
- **Pairing:**
  - `pair.html`/`pair.js` reads `#token=…&port=…` from its URL hash and stores them.
  - `popup.html`/`popup.js` shows status (connected, not paired, Glide not running), a field to paste a pairing code (`port:token`), and a "Reconnect" button.

**RPC protocol** (JSON over WebSocket):

```
→ {id, method: "hello"} ← {id, result: {version, chromeVersion, extensionId}}
→ {id, method: "tabs.list"} ← {id, result: [{id, url, title, active, windowId}]}
→ {id, method: "tabs.create", params: {url, active}}
→ {id, method: "tabs.update", params: {tabId, url?, active?}}
→ {id, method: "tabs.remove", params: {tabId}}
→ {id, method: "cdp.send", params: {tabId, method, params}}   (attaches chrome.debugger 1.3 on first use per tab)
→ {id, method: "cdp.detach", params: {tabId}}
← {event: "detached", tabId, reason}
← {id, error: {message}}
```

**`ExtensionBridge`** (in the app process): a localhost-only `NWListener` with `NWProtocolWebSocket`.
- **Bind:** to 127.0.0.1 only, on `settings.browser.bridgePort`.
- **Accept** a connection only if *all* of these hold:
  - the `Origin` header is `chrome-extension://<expected id>`
  - the token query parameter matches the token stored in the Keychain (`CredentialStore.Key.custom("browser.bridge-token")`), minted on first launch: 32 random bytes as hex
  - only one active extension connection is allowed at a time (the newest wins)
- **Requests:** request/response matching by id, a timeout per call (30 s), and keepalive handling.
- **Hub hooks:** installs `BrowserHub.shared.pairingProvider` (token, port, the extension folder inside the app bundle — fall back to the repo's `Extensions/chrome` when running unbundled, the id, and a pairing URL `chrome-extension://<id>/pair.html#token=…&port=…`), `resetPairing` (mints a new token) and `isExtensionPaired` (it has connected at least once).
- **Startup:** `ExtensionBridge.shared.start(settings:)` is called at app launch and registers an `ExtensionBackend` with `BrowserHub`.

**`ExtensionBackend: BrowserBackend` (`kind .extensionBridge`):** maps the protocol methods to the RPC commands above. Tab ids are chrome tab ids as strings. `ownedByGlide` is true for tabs it created. `connect()` waits up to 5 s for the extension to connect, otherwise throws a helpful `BrowserError.notConnected`.

**Tests:** start the bridge on a random port with a test token, connect a fake client (`URLSessionWebSocketTask` sending the `Origin` header), and cover:
- a wrong origin or token is rejected
- RPC round trip
- timeout
- reconnect replaces the old connection

Also lint-check the extension JS with `node --check` if `node` exists, and validate the manifest JSON.

---

## C. Data and web tools

**Owns:**
- `Sources/AgentKit/Tools/Data/*.swift`, `Sources/AgentKit/Tools/Web/*.swift`
- `Tests/AgentKitTests/DataWebToolsTests.swift`
- test fixtures under `Tests/AgentKitTests/Fixtures/` (add `resources` to the test target in `Package.swift` only if needed — that one-line Package.swift change is allowed)

**Spreadsheets** (`Spreadsheet` type plus tools; install `TableIO.reader`, `TableIO.updater` and `TableIO.writer` in `DataTools.install()`):
- **CSV and TSV:** read and write (reuse or extend `TableIO.readCSV` / `writeCSV`).
- **XLSX read:**
  - Unzip with `/usr/bin/unzip -p` (or `-d` to a temp folder).
  - Parse `xl/workbook.xml` (sheet names → rels), `xl/_rels/workbook.xml.rels`, `xl/sharedStrings.xml`, `xl/worksheets/sheetN.xml` with `XMLParser`.
  - Handle shared strings, inline strings, numbers, booleans and formulas (use the cached `<v>`), sparse cells (`r="C5"`), and dates (best effort: numeric with a date style → ISO date).
- **XLSX update in place** (`TableIO.updater`): change only the target cells inside the sheet XML.
  - Write values as inline strings (`t="inlineStr"`), or as numbers when numeric.
  - Insert missing `<c>`/`<row>` elements in sorted position, and add header cells for new columns.
  - Keep everything else (styles, other sheets, formulas) intact.
  - Re-zip with `/usr/bin/zip -X -r` from the extracted folder, preserving entries.
  - Write atomically: write to a temp file, then replace. Keep a `.bak` copy next to the file the first time a job modifies it.
- **XLSX write new** (`TableIO.writer` for `.xlsx` paths): a minimal valid workbook (`[Content_Types].xml`, rels, workbook, one sheet, inline strings).
- **Tools:**

| Tool | Args |
|---|---|
| `sheet.read` | `path`, `sheet?`, `has_header?`, `max_rows?`, `columns?` → table summary + rows (JSON) |
| `sheet.write` | `path`, `columns`, `rows`, `mode: create\|overwrite` |
| `sheet.update` | `path`, `sheet?`, `key_column?`, `updates: {key: {column: value}}` |
| `sheet.append` | `path`, `rows` |

  Risk: read is low; create is medium; overwrite and update are high when the file existed before the job, otherwise medium (approval follows settings).

**Web** (no browser):
- **`web.fetch`** (`url`, `max_chars?`):
  - `URLSession` GET with a desktop Safari user agent, 20 s timeout, 5 MB cap, redirects followed.
  - HTML → readable text: drop `script`/`style`/`noscript`/`svg`/`nav`/`footer`/`aside`/`form`; keep the title, `h1`–`h3` as markdown headings, paragraphs, list items, and table rows as `a | b`; collect up to 40 links (text → absolute URL).
  - PDF → text with PDFKit. JSON → pretty-printed. Other types → a short description.
  - Returns `{title, url, text, links}`.
- **`web.search`** (`query`, `max_results?` default 8):
  - Default backend: DuckDuckGo's HTML endpoint (`https://html.duckduckgo.com/html/?q=`, POST or GET), parsing result titles, URLs (unwrapping `uddg=` redirects) and snippets.
  - A `WebSearchBackend` protocol so a browser-based or API-based search can be plugged in later.
  - Returns a list of `{title, url, snippet}`.
- **`web.fetch_many`** (`urls`, `max_chars_each?`): fetches up to 8 URLs concurrently.
- Risk: all low (read-only). Refuse `file:` URLs.

**Tests (offline):**
- CSV edge cases.
- XLSX: build a small .xlsx fixture in the test with the writer; read it back; update cells (an existing cell, a new column, a new row) and verify the other cells and an extra sheet survive.
- HTML → text on a saved fixture page.
- DuckDuckGo result parsing on a saved fixture HTML string.
- `web.fetch` against a local `NWListener` HTTP server (no internet).

---

## D. Job engine

**Owns:**
- `Sources/AgentKit/Jobs/*.swift`: everything except `JobModels.swift`, whose existing declarations must not change (you may add new types in new files). Implement `JobCenter.swift` bodies, keeping its public API.
- `Sources/AgentKit/Tools/Workspace/*.swift`
- `Tests/AgentKitTests/JobEngineTests.swift`

**Components:**
- **`JobStore`.** New tables in the `LocalStore` SQLite database (open its `SQLiteDatabase` via a new initializer or your own `SQLiteDatabase` on the same path; migrations are idempotent, `CREATE TABLE IF NOT EXISTS`):
  - `jobs` (id, json record, status, updated_at)
  - `job_items` (job_id, step_id, idx, json, status) with an index
  - `job_events` (job_id, ts, json)
  - `job_facts` (job_id, key, value, updated_at)
  - `job_rows` (job_id, table_name, row_key, json, updated_at)
  CRUD plus queries: items by status, counts, events tail. All methods are thread-safe. Store `JobRecord`/`JobItem`/`ActivityEntry` as JSON blobs plus indexed columns. Job folders live at `~/Library/Application Support/NotchBuddy/Jobs/<id>/`.
- **`SQLiteJobWorkspace: JobWorkspace`** backed by `JobStore`. `facts(matching:)` ranks by keyword overlap. `summary(maxChars:)` lists tables with row counts and a sample row, the 10 most recent facts, and the files in the folder.
- **Workspace tools** (`WorkspaceTools.install()` → `registerFactory("workspace")`; they use `context.workspace`, erroring clearly when it's nil):

| Tool | Args |
|---|---|
| `workspace.remember` | `key`, `value` |
| `workspace.recall` | `query?`, `limit?` |
| `workspace.save_row` | `table`, `key`, `fields` |
| `workspace.rows` | `table`, `limit?` |
| `workspace.write_file` | `name`, `content` (inside the job folder only) |
| `workspace.read_file` | `name` |

  All low risk.
- **`JobPlanner`:**
  - Prompt plus strict JSON schema (same style as `PlanSchema` and `Prompts.planner`) that produces a `JobPlan`: milestones of steps, each an action (`RecipeStep` with route), a `forEach` (source, label, recipe, parallelism, output table and columns, optional write-back), or a `wait`.
  - The prompt explains:
    - **Routes:**
      - `command`: shell, AppleScript, files
      - `browser`: Chrome DOM tools, the user's logins, background tabs
      - `web`: search and fetch without a browser
      - `data`: spreadsheets
      - `gui`: on-screen UI only when nothing else can do it
      - `native`: launching apps and opening URLs on screen
      - `composio`, `mcp`
      - `answer`: writing a response
    - Preferring non-screen routes when `settings.tools.executionPreference == .fastest`.
    - Using `forEach` for "for each…/every…/all N…" work.
    - Parallelism: up to 4 for web/data/command; 1 for gui; 2 for browser.
    - Waits and schedules for "every day…/check back…/wait until…".
    - Approval checkpoints before milestones that send or publish.
    - Output columns to collect.
  - Planning context: the request, the files it mentions (only paths that exist; if a spreadsheet is mentioned, read its header and up to 3 rows via `TableIO.reader` and include them), connected integrations, browser availability, command access, current date and time.
  - `estimate(plan, items:) -> JobEstimate`: count items, estimate model calls (per item ≈ 1.5 × recipe steps + 1; per action step ≈ 3), minutes (parallelism-aware; ≈ 8 s per tool turn, 20 s per GUI turn), cost from `ModelPricing` for the actor and planner models when known.
  - Use the `.planner` route (`ModelRouter`). Decode tolerantly; a nonsense plan throws a clear error.
- **`JobRunner`** (an actor per running job):
  - **Inputs:** `JobRecord`, `JobStore`, `any StepExecuting` (injected; production uses `StepExecutorFactory.make`), `ScreenLease`, `AppSettings`, a callbacks sink (status updates, log, approvals).
  - **Loop:** milestones, then steps from the cursor.
  - **`.action`:** acquire the `ScreenLease` if `route.needsScreen`, then `executor.execute(StepRequest)` with:
    - context from `JobContextBuilder`: goal, milestone, step, progress so far, `workspace.summary(1500)`, `facts(matching: step.instruction, 8)`
    - `allowedCategories = route.toolCategories`
    After the step: store `output` as a fact (`step:<id>`) and `fields` as a row in table `steps`.
  - **`.forEach`:**
    - **First visit:** materialize items (via `TableIO.reader` for files, workspace rows, a literal list, or an earlier step's `data`), apply `limit`, and persist them as `JobItem`s.
    - **Every visit:** process `pending` items (and `failed` items with `attempts < maxItemAttempts`) with concurrency `min(parallelism, recipe needs screen ? 1 : parallelism)`.
    - **Per item:** run the recipe steps in order. Each `StepRequest` context includes the item input JSON and the item's partial results. Merge `fields` into the item result.
    - **On success:** mark the item done, save its row to `outputTable` (key = item title or index), and, when `writeBack` is set, batch-update the spreadsheet via `TableIO.updater` every 10 items and at the end.
    - **On failure:** record the error, increment attempts, and move on.
    - **Pause and ask** when the failure rate exceeds `budget.maxFailureRate` after at least 5 completed items.
    - Persist after every item. Update `JobUsage` and `statusLine` (e.g. "Researching companies · 37/100 · 2 failed").
  - **`.wait`:**
    - Compute `nextWakeAt` (duration, until, the next daily time, or condition re-check), set status `.waiting`, persist, and return (the runner exits).
    - On wake, `.daily` with `times` re-runs the *rest of the milestone* the given number of times (track `cursor.waitIteration`).
    - `.condition` runs a check step (route `web`/`browser`/`command` with the check as its instruction and `outputFields: ["met"]`) and either continues or waits again until `maxTries`.
  - **Milestone verification:** after its steps, run a verify `StepRequest` (route `answer`, `outputFields ["done","reason"]`) against the workspace summary. If not done, add one remedial action step built from the reason (at most 2 per milestone), then fail the job with a clear reason.
  - **Approval checkpoints:** `requiresApproval` milestones ask through the callbacks before starting (`ApprovalRequest` kind `.action`).
  - **Budgets:** stop with status `.needsInput` and a clear message when cost, duration or model calls exceed the budget. Track `activeSeconds`.
  - **Stuck detection:** if `budget.stuckTurns` executor calls in a row make no progress (no item completed and no step advanced), pause with `.needsInput` ("I seem to be stuck on …").
  - **Stop and pause:** honor `ExecutionGate` semantics per job. The job runner has its own gate per job, so stopping one job doesn't stop another; the shared runtime gate still stops GUI input. Cancellation marks `.stopped`; pause marks `.paused` at the next checkpoint (after the current item).
  - **Finish:** generate a report (`answer` step with the workspace summary → `summary`), write `report.md` in the job folder, mark `.completed`, and notify via callbacks.
- **`ScreenLease`** (actor): one holder at a time across all jobs and quick tasks.
  - `acquire(owner:, screenUse:, idleSeconds:)` waits for the lease. In `.whenIdle` mode it also waits until the user's input has been idle for at least `idleSeconds` (`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: …)` for mouse and keyboard). In `.never` mode it throws `blocked`.
  - `release`.
  - Quick tasks (`TaskController`) take the lease with priority (they are interactive).
- **`JobScheduler`:** a timer on the earliest `nextWakeAt` among waiting jobs, plus on-launch handling. Jobs that were `.running` when the app quit become resumable (auto-resume if `settings.jobs.autoResume`, otherwise `.paused` with "Interrupted").
- **`PowerAssertion`:** `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` while any job runs and `keepAwake` is on.
- **`JobCenter`:** implement the skeleton. It:
  - owns `JobStore`, `JobScheduler` and the runners (at most `settings.jobs.maxConcurrentJobs`, queueing extra ones)
  - publishes `jobs` and `pendingApprovals` on the main actor
  - routes approvals (`respond`)
  - fires `onAttentionNeeded` and `onJobFinished`
  - `create` plans, estimates, and either auto-starts or sets `.awaitingConfirmation` per the thresholds
  - `exportResults` writes the output tables as CSV
  - `delete` trashes the folder
  The executor comes from `StepExecutorFactory.make(settings, AutomationRuntime.shared, ToolRegistry.standard(settings: settings))`; if nil, fail the job with "Step runner not installed".

**Tests (offline):**
- A scripted mock `StepExecuting` and a mock planner (inject the `JobPlan`; don't call real models).
- A temp SQLite path. Cover:
  - a forEach over a CSV with 25 rows at parallelism 4: results table, write-back updates the CSV, usage counts
  - resume after a simulated crash mid-forEach (create a new runner from the persisted record; already-done items aren't re-run)
  - retries and per-item failures, and failure-rate pause
  - a wait step sets `nextWakeAt` and the scheduler resumes
  - a daily repeat
  - stuck detection
  - budget stop
  - an approval checkpoint (approve and reject)
  - `ScreenLease` serialization
  - stop and pause
  - estimate math

---

## E. Step runners, batching and orchestrator integration

**Owns:**
- `Sources/AgentKit/Agent/ToolStepRunner.swift`, `GUIStepRunner.swift`, `StepRouter.swift`
- edits to `ExecutionOrchestrator.swift`, `Prompts.swift`, `AgentPlanner.swift`, `Plan.swift` (planner schema, not the `ExecutionRoute` cases), `ActionResolver.swift`
- `Sources/AgentKit/Controller/TaskController.swift`
- `Sources/AgentKit/Agent/TaskEvents.swift` (you may add an optional `jobID` to `TaskResult`)
- `Sources/NBMockServers/main.swift`
- `Tests/AgentKitTests/StepRunnerTests.swift`

**`ToolStepRunner: StepExecuting`** (for routes command, browser, web, data, composio, mcp and answer; integration routes wrap the existing Composio and MCP clients as tools via adapters in this file):
- **Prompt:** the goal, step instruction, `doneWhen`, context, the tool listing (`registry.promptListing(categories: request.allowedCategories)`), recent results (last 8, truncated) and the output fields required.
- **Decision schema (strict):**

```
{ thought, status: act|step_done|task_done|blocked,
  calls: [{tool, arguments_json}] (0–maxBatch),
  result_fields_json: string|null (JSON object with outputFields when step_done),
  message: string|null, remember: string|null }
```

- **Each call:**
  - Resolve the tool; check `request.allowedCategories`; `assess`.
  - If blocked, record it and tell the model.
  - If `SafetyPolicy.needsApproval(verdict.safetyVerdict)`, ask `callbacks.approve` (kind `.tool`, title `verdict.summary`). Reject → tell the model "declined, don't retry"; stop → throw `AutomationError.stopped`.
  - Run with a `ToolContext` built from the request (workspace, job id, working directory = job folder or home, gate).
  - Log an `ActivityEntry` (kind `.tool`, route).
  - Stop the batch at the first failure or rejection and feed the results back.
- **Browser calls:** the runner fills `_label` (element name) for click and type from the latest snapshot it saw, so `assess` can judge risk.
- **Limits:** `maxTurns`, repeated identical failing calls (3 in a row → fail the step), and an error budget (4).
- **Answer route:** no tools; return `taskDone` with the written answer for quick tasks, or `done` with fields for jobs.
- **Model:** uses `ModelRouter` route `.actor` (fast). Counts usage into `StepResult`.

**`GUIStepRunner: StepExecuting`:** extract the existing `runGUIStep` loop (observe → hint → actor → resolve → perform → verify, vision grounding, limits) out of `ExecutionOrchestrator` into this reusable type without changing behavior. The orchestrator then uses it. Add **GUI batching**: an optional `actions` array (up to 5) in the actor schema, executed in order while targets resolve; stop on error or unexpected change. Notes and remember go to the request's workspace when present.

**`StepRouter: StepExecuting`:** dispatches by `request.step.route` (`gui`/`native` → `GUIStepRunner`; others → `ToolStepRunner`) and installs `StepExecutorFactory.make` in `StepRouter.install()`.

**Planner updates** (`Prompts.planner`, `PlanSchema`):
- Describe the new routes and prefer non-screen routes when `executionPreference == .fastest`.
- Add `mode: "quick" | "job"` to the plan schema: `job` for long or repetitive work (many items, more than about 15 steps, waits or schedules, anything taking more than about 10 minutes).
- `PlanningContext` gains tool availability: command access, whether a browser is connected (`BrowserHub` status), and the tool families installed.

**Orchestrator:** route `.command`/`.browser`/`.web`/`.data` (and composio/mcp via tool adapters) through `ToolStepRunner`.

**`TaskController`:** when the plan's mode is `job`, hand the instruction to `JobCenter.shared.create(instruction:)` and finish the quick task with a summary like "Started a background job: <title>" (set `TaskResult.jobID`).

**Mock server:** extend `nb-mock-servers llm` with a scripted tool-route scenario (the planner returns a `command`-route step; the actor returns a `shell.run` batch) for tests.

**Tests:**
- `ToolStepRunner` with a mock `LLMProvider` (inject via a `ModelRouter` built from settings with an openaiCompatible provider pointing to the mock server, or add an internal init taking `any LLMProvider`) and mock tools. Cover:
  - batching
  - blocked call
  - approval approve, reject and stop
  - result fields
  - the repeated-failure guard
  - stop
- `PlanSchema` with `mode`
- `StepRouter` dispatch
- the orchestrator running a `command`-route step end to end against the mock server

---

## F. UI

**Owns:**
- new files under `Sources/GlideApp/` (`Settings/SpeedSettings.swift`, `Settings/BrowserSettingsView.swift`, `Settings/JobsView.swift`, `Notch/JobViews.swift`, `System/Notifications.swift`)
- edits to `Settings/SettingsRoot.swift`, `Notch/NotchViews.swift`, `Notch/NotchWindow.swift`, `App/AppDelegate.swift`, `App/SnapshotRenderer.swift`

Build against `JobCenter`'s public API (skeleton now), `BrowserHub` (status and pairing hooks) and `SettingsStore`.

Use BoardKit components and `BKTheme` (read `BoardKit.swift` first; match the existing settings views exactly in structure and spacing).

- **Settings › Speed & Commands:**
  - execution preference (Fastest / Show me) with an explanation
  - command access (Off / Read-only / Full), AppleScript and Shortcuts toggles
  - batch actions toggle and max batch
  - a short safety explainer (what's auto, what asks, what's blocked)
- **Settings › Browser:**
  - backend choice (Your Chrome via extension / Glide's Chrome window)
  - live status (`BrowserHub.status`, polled every 2 s while visible)
  - install steps for the extension: "Reveal extension folder" (`pairingProvider().extensionFolder`); copy `chrome://extensions` to the clipboard and say "paste in Chrome's address bar" (Chrome won't open chrome:// URLs from other apps); "Enable Developer mode → Load unpacked → choose the folder"
  - a "Pair" button that opens `pairingURL` in Chrome via `NSWorkspace.open(urls:withApplicationAt:)`, with a fallback "Copy pairing code" (`port:token`)
  - "Reset pairing"
  - background tabs toggle, fallback toggle, custom Chrome path
- **Settings › Jobs:**
  - **List:** status pill, title, progress ring and `statusLine`, last updated.
  - **Detail:**
    - milestones with step progress
    - an items table (title, status, key result fields, error; filter by status; search)
    - an activity log (`JobCenter.events`)
    - usage (time, model calls, tokens, cost)
    - the job folder ("Show in Finder"), report preview (`report.md`)
  - **Buttons:** Start (if awaiting confirmation), Pause, Resume, Stop, Retry failed, Export CSV (`NSSavePanel` → `exportResults`), Delete (confirm).
  - **Defaults:** screen use (Any time / When idle / Never), max concurrent jobs, auto-resume, keep awake, notifications, default budget (cost, duration), confirmation thresholds.
- **Notch:**
  - When a job is running and no quick task is, the idle and hover notch shows a small progress ring in the right wing (from `progressFraction`, or a spinner when unknown).
  - The running pill shows the job's `statusLine` with pause and stop.
  - The detail view has a "Background jobs" section listing active jobs.
  - `awaitingConfirmation` jobs show a confirmation card (estimate: items, minutes, cost) with Start and Cancel.
  - Job approvals (`pendingApprovals`) use the existing approval view, routing to `JobCenter.respond`.
  - When a job finishes: a result card with "View report" (opens Settings › Jobs detail).
- **AppDelegate:**
  - call `JobCenter.shared.launch()`
  - set `onAttentionNeeded` (expand the notch, plus a `UNUserNotificationCenter` notification when the notch isn't expanded and `settings.jobs.notifications` is on; request authorization lazily on the first job)
  - set `onJobFinished`
  - leave clean hook points where the browser bridge and tool families get installed at launch (call sites are added during integration)
- **SnapshotRenderer:** add snapshots for the job progress pill, the confirmation card and the Jobs settings detail (with fake data via public initializers; add `JobCenter` preview helpers only inside the app target).

**Tests:** the app target has none. Make sure `swift build` passes and `Glide --snapshot docs/images` renders the new images (check them visually).

---

## Integration (after merging)

1. Call each family's `install()` at launch (app and glidectl) plus `StepRouter.install()`, `ExtensionBridge.shared.start`, and register `GlideChromeBackend` with `BrowserHub`.
2. Add glidectl commands: `job run|list|show|resume|stop`, `browser status|open|snapshot|click|type|read`, `tool list|run`.
3. End-to-end checks: the mock-model command route; jobs over a local CSV with the mock executor and with the scripted model; the browser driver headless; the extension bridge with a fake client; a live run with the user's Chrome extension once it's installed.
