// Glide's Chrome extension: connects to the Glide app on this Mac over a localhost WebSocket and
// carries out its requests with chrome.tabs and chrome.debugger, so Glide can work in your own
// Chrome (your logins) in background tabs. Protocol: see ExtensionBridge.swift in the app.
//
// Security: the connection is authenticated both ways with the pairing token (HMAC proofs; the
// token itself never goes over the socket), and nothing but "hello" is obeyed until Glide has
// proven it knows the token. Chrome's own pages, other extensions and the Web Store are never
// automated.
importScripts("common.js");

const G = self.GlideCommon;
const ALARM_NAME = "glide-reconnect";
const KEEPALIVE_MS = 20000;
const MIN_BACKOFF_MS = 1000;
const MAX_BACKOFF_MS = 30000;
const PROBE_TIMEOUT_MS = 3000;
const HELLO_TIMEOUT_MS = 15000;
const MAX_GLIDE_TABS = 500;
// chrome.tabs.update/create reply as soon as a navigation starts; Glide waits (at most this
// long) for it to commit so it never inspects the page being left.
const NAVIGATION_COMMIT_TIMEOUT_MS = 15000;
// Glide is "driving" a tab while one of its commands runs there and for a moment after: an
// action's dialog or popup can arrive between two of the driver's quick polls.
const ACTIVE_GRACE_MS = 2000;
// Tabs remembered with the tab whose page opened them (see onCreatedNavigationTarget).
const MAX_POPUP_SOURCES = 500;
// The debugger lets go of tabs Glide didn't open after this long without a command, so it
// doesn't stay attached to the user's own tabs (and Chrome's debugging bar goes away).
const IDLE_DETACH_MS = 45000;

// CDP methods refused even though chrome.debugger allows them: each could read or erase data
// from every site at once, or turn off certificate checks. Glide's browser tools never need them.
const BLOCKED_METHODS = new Set([
  "Network.getAllCookies",
  "Network.clearBrowserCookies",
  "Network.clearBrowserCache",
  "Storage.getCookies",
  "Storage.clearCookies",
  "Storage.clearDataForOrigin",
  "Storage.clearDataForStorageKey",
  "Security.setIgnoreCertificateErrors",
  "Security.handleCertificateError",
  "Security.setOverrideCertificateErrors",
  "Page.setDownloadBehavior",
  "Browser.setDownloadBehavior",
]);

let session = null; // {ws, nonce, token, port, verified, opened}
let connecting = null; // promise of the connect attempt in progress
let backoffMs = MIN_BACKOFF_MS;
let reconnectTimer = null;
let keepaliveTimer = null;
let lastStatus = { state: "starting", port: null, chromeVersion: null };
const attached = new Set(); // tab ids our debugger is attached to
const attaching = new Map(); // tab id → in-flight attach promise
const activity = new Map(); // tab id → {inflight, lastAt, actions, lastActionAt}: Glide's commands there
const idleTimers = new Map(); // tab id → timer that detaches a tab Glide didn't open
const openDialogs = new Map(); // tab id → dialog the page shows that's left for the user
const navigationWatchers = new Set(); // see watchNavigation
const popupSources = new Map(); // tab id → the tab whose page opened it

// ---- Event listeners (registered synchronously, as MV3 requires) ----

chrome.runtime.onInstalled.addListener(() => {
  ensureAlarm();
  connect("installed");
});

chrome.runtime.onStartup.addListener(() => {
  ensureAlarm();
  connect("startup");
});

// The worker sleeps when idle; this alarm wakes it every 30 s to reconnect.
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === ALARM_NAME) connect("alarm");
});

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local" || !(G.KEYS.token in changes || G.KEYS.port in changes)) return;
  // New pairing (or unpaired): drop the old connection and start over.
  resetBackoff();
  chrome.storage.session.remove(G.SESSION_KEYS.replaced).catch(() => {});
  disconnect(1000, "Pairing changed");
  connect("pairing");
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleUIMessage(message, sender).then(
    (result) => sendResponse({ ok: true, result }),
    (error) => sendResponse({ ok: false, error: messageOf(error) })
  );
  return true; // respond asynchronously
});

chrome.debugger.onDetach.addListener((source, reason) => {
  onDebuggerDetach(source, reason).catch((e) => console.warn("Glide: detach handling failed", e));
});

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (typeof source.tabId !== "number") return;
  if (method === "Page.javascriptDialogOpening") {
    onDialogOpening(source.tabId, params || {}).catch((e) => console.warn("Glide: dialog handling failed", e));
  } else if (method === "Page.javascriptDialogClosed") {
    openDialogs.delete(source.tabId);
  }
});

// The tab a page opened (a link with target=_blank, window.open). Only webNavigation knows which
// tab that page was in: chrome.tabs' openerTabId is the window's active tab for these, so a
// popup from one of Glide's background tabs would look like the user's doing.
chrome.webNavigation.onCreatedNavigationTarget.addListener((details) => {
  onPopup(details.sourceTabId, details.tabId).catch((e) => console.warn("Glide: popup handling failed", e));
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  for (const watcher of [...navigationWatchers]) watcher.update(tabId, changeInfo || {}, tab || {});
});

chrome.tabs.onRemoved.addListener((tabId) => {
  forgetAttachment(tabId);
  activity.delete(tabId);
  popupSources.delete(tabId);
  for (const watcher of [...navigationWatchers]) if (watcher.tabId === tabId) watcher.finish();
  forgetGlideTab(tabId).catch(() => {});
});

ensureAlarm();
connect("wake");

// ---- Connection ----

function ensureAlarm() {
  chrome.alarms
    .get(ALARM_NAME)
    .then((alarm) => {
      if (!alarm) return chrome.alarms.create(ALARM_NAME, { periodInMinutes: 0.5 });
    })
    .catch(() => chrome.alarms.create(ALARM_NAME, { periodInMinutes: 0.5 }));
}

function isLive(s) {
  return !!s && (s.ws.readyState === WebSocket.OPEN || s.ws.readyState === WebSocket.CONNECTING);
}

/** Starts a connection attempt unless one is open or in progress. */
function connect(reason) {
  if (connecting) return connecting;
  if (isLive(session)) return Promise.resolve();
  connecting = attemptConnect(reason)
    .catch((error) => {
      console.warn("Glide: couldn't connect", error);
      scheduleReconnect();
    })
    .finally(() => {
      connecting = null;
    });
  return connecting;
}

async function attemptConnect(reason) {
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
  const { port, token } = await loadPairing();
  if (!token) {
    await setStatus("not_paired", { port });
    return;
  }
  const manual = reason === "manual" || reason === "pairing";
  if (!manual && (await getSessionValue(G.SESSION_KEYS.replaced))) {
    // Another profile took over; don't fight it until the user asks.
    await setStatus("replaced", { port });
    return;
  }
  // A quick HTTP probe first: it tells "Glide isn't running" apart from "pairing refused", and
  // avoids a failed WebSocket on every retry while Glide is closed.
  const probe = await probeGlide(port);
  if (!probe.running) {
    await setStatus("glide_not_running", { port });
    scheduleReconnect();
    return;
  }
  if (probe.protocol !== G.PROTOCOL_VERSION) {
    await setStatus("version_mismatch", { port });
    scheduleReconnect(MAX_BACKOFF_MS);
    return;
  }
  const nonce = G.makeNonce();
  const proof = await G.clientProof(token, nonce);
  if (isLive(session)) return; // something else connected meanwhile
  await setStatus("connecting", { port });
  const ws = new WebSocket(G.bridgeURL(port, nonce, proof));
  const s = { ws, nonce, token, port, verified: false, opened: false };
  session = s;
  ws.onopen = () => {
    s.opened = true;
    // Glide says hello right away; a server that doesn't is not Glide.
    setTimeout(() => {
      if (session === s && !s.verified && s.ws.readyState === WebSocket.OPEN) {
        setStatus("untrusted", { port: s.port }).finally(() => s.ws.close(4003, "No hello"));
      }
    }, HELLO_TIMEOUT_MS);
  };
  ws.onmessage = (event) => {
    onSocketMessage(s, event.data).catch((e) => console.warn("Glide: message handling failed", e));
  };
  ws.onclose = (event) => {
    onSocketClose(s, event).catch((e) => console.warn("Glide: close handling failed", e));
  };
  ws.onerror = () => {}; // onclose follows with the details
}

async function probeGlide(port) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);
  try {
    const response = await fetch(G.pingURL(port), { cache: "no-store", credentials: "omit", signal: controller.signal });
    if (!response.ok) return { running: false };
    const body = await response.json();
    return body && body.app === "Glide" ? { running: true, protocol: body.protocol } : { running: false };
  } catch (e) {
    return { running: false };
  } finally {
    clearTimeout(timer);
  }
}

function scheduleReconnect(minimumMs) {
  clearTimeout(reconnectTimer);
  const delay = Math.max(minimumMs || 0, backoffMs);
  backoffMs = Math.min(backoffMs * 2, MAX_BACKOFF_MS);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect("retry");
  }, delay);
}

function resetBackoff() {
  backoffMs = MIN_BACKOFF_MS;
  clearTimeout(reconnectTimer);
  reconnectTimer = null;
}

/** Closes the current connection without reacting to its close event. */
function disconnect(code, reason) {
  const s = session;
  session = null;
  stopKeepalive();
  if (s) {
    try {
      s.ws.close(code, reason);
    } catch (e) {
      // already closed
    }
  }
}

function startKeepalive(s) {
  stopKeepalive();
  // Messages keep the MV3 worker alive, and tell Glide this side is still here.
  keepaliveTimer = setInterval(() => send(s, { event: "keepalive" }), KEEPALIVE_MS);
}

function stopKeepalive() {
  clearInterval(keepaliveTimer);
  keepaliveTimer = null;
}

function send(s, message) {
  if (s && s.ws.readyState === WebSocket.OPEN) s.ws.send(JSON.stringify(message));
}

async function onSocketMessage(s, data) {
  if (s !== session || typeof data !== "string") return;
  let message;
  try {
    message = JSON.parse(data);
  } catch (e) {
    return;
  }
  if (!message || typeof message !== "object" || typeof message.method !== "string" || message.id === undefined) return;
  let reply;
  try {
    const result = await handleRequest(s, message.method, message.params && typeof message.params === "object" ? message.params : {});
    reply = { id: message.id, result: result === undefined ? null : result };
  } catch (error) {
    reply = { id: message.id, error: errorPayload(error) };
    if (error && error.fatal) {
      send(s, reply);
      s.ws.close(4003, "Pairing check failed");
      return;
    }
  }
  send(s, reply);
}

async function onSocketClose(s, event) {
  if (s !== session) return;
  session = null;
  stopKeepalive();
  // Without Glide nothing should keep debugging tabs (and showing Chrome's warning bar).
  await detachAll();
  // Close codes only count from a server that proved itself, so an impostor can't park us.
  if (event.code === 4001 && s.verified) {
    await chrome.storage.session.set({ [G.SESSION_KEYS.replaced]: true });
    await setStatus("replaced", { port: s.port });
    return;
  }
  if (event.code === 4002 && s.verified) {
    // Glide reset pairing. Forget the token; the storage listener reports "not paired".
    await chrome.storage.local.remove(G.KEYS.token);
    return;
  }
  if (event.code === 4003 || lastStatus.state === "untrusted") {
    scheduleReconnect(MAX_BACKOFF_MS);
    return;
  }
  if (!s.opened) {
    // Glide answered the probe but refused the upgrade: the pairing (or extension id) is wrong.
    await setStatus("rejected", { port: s.port });
    scheduleReconnect(5000);
    return;
  }
  await setStatus("glide_not_running", { port: s.port });
  scheduleReconnect();
}

// ---- Requests from Glide ----

async function handleRequest(s, method, params) {
  if (method === "hello") return hello(s, params);
  if (!s.verified) throw bridgeError("not_authenticated", "Glide hasn't finished pairing on this connection.");
  switch (method) {
    case "tabs.list":
      return listTabs();
    case "tabs.create":
      return createTab(params);
    case "tabs.update":
      return updateTab(params);
    case "tabs.remove":
      return removeTab(params);
    case "cdp.send":
      return sendCDP(params);
    case "cdp.detach":
      return detachTab(params);
    default:
      throw bridgeError("unknown_method", `This version of the Glide extension doesn't support “${method}”. Update it from Glide.`);
  }
}

async function hello(s, params) {
  const expected = await G.serverProof(s.token, s.nonce);
  if (!G.safeEqual(String(params.proof || ""), expected)) {
    await setStatus("untrusted", { port: s.port });
    const error = bridgeError("untrusted", "The pairing check failed.");
    error.fatal = true;
    throw error;
  }
  s.verified = true;
  resetBackoff();
  await chrome.storage.session.remove(G.SESSION_KEYS.replaced);
  startKeepalive(s);
  const chromeVersion = chromeVersionString();
  await setStatus("connected", { port: s.port, chromeVersion });
  return {
    version: chrome.runtime.getManifest().version,
    chromeVersion,
    extensionId: chrome.runtime.id,
    protocol: G.PROTOCOL_VERSION,
  };
}

async function listTabs() {
  const [tabs, glideTabs] = await Promise.all([chrome.tabs.query({}), loadGlideTabs()]);
  return tabs.filter((tab) => typeof tab.id === "number" && tab.id >= 0).map((tab) => tabInfo(tab, glideTabs));
}

async function createTab(params) {
  const url = typeof params.url === "string" && params.url.trim() ? params.url.trim() : "about:blank";
  assertAllowed(url);
  const active = params.active === true;
  // A new tab starts on an empty page and only then loads the address.
  const watcher = url === "about:blank" ? null : watchNavigation("about:blank");
  let tab;
  try {
    try {
      tab = await chrome.tabs.create({ url, active });
    } catch (error) {
      // Chrome can run with no window open on macOS: open one for the tab.
      const win = await chrome.windows.create({ url, focused: active });
      tab = win && win.tabs && win.tabs[0];
      if (!tab) throw bridgeError("error", `Chrome couldn't open a tab (${messageOf(error)}).`);
    }
    await rememberGlideTab(tab.id);
    if (watcher) {
      await watcher.track(tab.id);
      await watcher.done;
      tab = await chrome.tabs.get(tab.id).catch(() => tab);
    }
  } finally {
    if (watcher) watcher.finish();
  }
  return tabInfo(tab, new Set([tab.id]));
}

async function updateTab(params) {
  const tabId = requireTabId(params);
  const tab = await getTab(tabId);
  const props = {};
  if (typeof params.url === "string" && params.url.trim()) {
    assertAllowed(params.url.trim());
    props.url = params.url.trim();
  }
  if (params.active === true) props.active = true;
  let updated = tab;
  const watcher = props.url && props.url !== "about:blank" ? watchNavigation(tab.url || "") : null;
  try {
    if (watcher) await watcher.track(tabId);
    if (Object.keys(props).length > 0) updated = (await chrome.tabs.update(tabId, props)) || tab;
    if (watcher) {
      await watcher.done;
      updated = await chrome.tabs.get(tabId).catch(() => updated);
    }
  } finally {
    if (watcher) watcher.finish();
  }
  if (params.active === true) await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
  return tabInfo(updated, await loadGlideTabs());
}

async function removeTab(params) {
  const tabId = requireTabId(params);
  const tab = await getTab(tabId);
  if ((await loadGlideTabs()).has(tabId)) {
    // Glide's own tab closes while the debugger is still attached, so a "Leave site?" prompt
    // (the page has unsaved input Glide typed) is answered instead of keeping the tab open.
    if (await wasAttached(tabId)) await ensureAttached(tabId, tab).catch(() => {});
    await chrome.tabs.remove(tabId);
    await detachQuietly(tabId);
  } else {
    // The user's own tab: a "Leave site?" prompt there is theirs to answer.
    await detachQuietly(tabId);
    await chrome.tabs.remove(tabId);
  }
  await forgetGlideTab(tabId);
  return null;
}

/**
 * Watches for a navigation in one tab to commit: its address changes, or it goes through
 * loading to complete (a reload of the same address, or a download that leaves the page as it
 * was). `done` also resolves when the tab closes and after NAVIGATION_COMMIT_TIMEOUT_MS; Glide's
 * own check that the page has settled takes over from there. Events that arrive before the tab
 * id is known (tabs.create can report them first) are kept and replayed by `track`.
 */
function watchNavigation(fromUrl) {
  const early = [];
  const watcher = { tabId: null, sawLoading: false };
  watcher.done = new Promise((resolve) => (watcher.finish = resolve));
  watcher.update = (tabId, changeInfo, tab) => {
    if (watcher.tabId === null) {
      if (early.length < 100) early.push([tabId, changeInfo, tab]);
      return;
    }
    if (tabId !== watcher.tabId) return;
    if (changeInfo.url && changeInfo.url !== fromUrl) {
      watcher.finish();
    } else if (changeInfo.status === "loading") {
      watcher.sawLoading = true;
    } else if (changeInfo.status === "complete" && watcher.sawLoading && tab.url && tab.url !== "about:blank") {
      watcher.finish();
    }
  };
  watcher.track = async (tabId) => {
    watcher.tabId = tabId;
    for (const [id, changeInfo, tab] of early.splice(0)) watcher.update(id, changeInfo, tab);
    // It may have committed before this listener heard of it.
    const current = await chrome.tabs.get(tabId).catch(() => null);
    if (!current) watcher.finish();
    else if (current.url && current.url !== fromUrl && current.url !== "about:blank") watcher.finish();
  };
  const timer = setTimeout(() => watcher.finish(), NAVIGATION_COMMIT_TIMEOUT_MS);
  navigationWatchers.add(watcher);
  watcher.done.then(() => {
    clearTimeout(timer);
    navigationWatchers.delete(watcher);
  });
  return watcher;
}

async function sendCDP(params) {
  const tabId = requireTabId(params);
  const method = params.method;
  if (typeof method !== "string" || !/^[A-Za-z]+\.[A-Za-z]+$/.test(method)) {
    throw bridgeError("bad_request", "A DevTools method such as “Runtime.evaluate” is required.");
  }
  if (BLOCKED_METHODS.has(method)) {
    throw bridgeError("blocked_method", `The Glide extension doesn't allow “${method}”: it could expose or erase data from every site.`);
  }
  if (await getSessionValue(G.SESSION_KEYS.paused)) throw bridgeError("canceled_by_user", G.PAUSED_MESSAGE);
  const tab = await getTab(tabId);
  assertAllowed(tab.url || tab.pendingUrl || "about:blank");
  const dialog = openDialogs.get(tabId);
  if (dialog) {
    // The page is frozen until someone answers, and it's the user's dialog: fail at once
    // rather than hang until the request times out.
    throw bridgeError("dialog_open", waitingDialogMessage(dialog));
  }
  const commandParams = params.params && typeof params.params === "object" ? params.params : {};
  const action = isAction(method, commandParams);
  beginCommand(tabId, action);
  try {
    await ensureAttached(tabId, tab);
    try {
      return (await chrome.debugger.sendCommand({ tabId }, method, commandParams)) || {};
    } catch (error) {
      if (/not attached/i.test(messageOf(error))) {
        // Detached since (navigation to another process, or the worker restarted): once more.
        attached.delete(tabId);
        await ensureAttached(tabId, tab);
        try {
          return (await chrome.debugger.sendCommand({ tabId }, method, commandParams)) || {};
        } catch (retryError) {
          throw bridgeError("cdp", messageOf(retryError));
        }
      }
      throw bridgeError("cdp", messageOf(error));
    }
  } finally {
    endCommand(tabId, action);
  }
}

async function detachTab(params) {
  await detachQuietly(requireTabId(params));
  return null;
}

// ---- Debugger ----

function beginCommand(tabId, action) {
  const a = activity.get(tabId) || { inflight: 0, lastAt: 0, actions: 0, lastActionAt: 0 };
  a.inflight += 1;
  if (action) a.actions += 1;
  activity.set(tabId, a);
  clearTimeout(idleTimers.get(tabId));
  idleTimers.delete(tabId);
}

function endCommand(tabId, action) {
  const a = activity.get(tabId);
  if (a) {
    a.inflight = Math.max(0, a.inflight - 1);
    a.lastAt = Date.now();
    if (action) {
      a.actions = Math.max(0, a.actions - 1);
      a.lastActionAt = a.lastAt;
    }
  }
  if (attached.has(tabId) && !(a && a.inflight > 0)) scheduleIdleDetach(tabId);
}

/** True while Glide is working in the tab: a command is running there, or just finished. */
function isDriving(tabId) {
  const a = activity.get(tabId);
  return !!a && (a.inflight > 0 || Date.now() - a.lastAt < ACTIVE_GRACE_MS);
}

/** True while one of Glide's actions in the tab is running, or just finished (reads don't count). */
function isActing(tabId) {
  const a = activity.get(tabId);
  return !!a && (a.actions > 0 || Date.now() - a.lastActionAt < ACTIVE_GRACE_MS);
}

/**
 * Commands that act on the page the way a person would — input events, navigation, a script
 * run with a user gesture (the driver's click and typing fallbacks) — rather than read it.
 * Must match BrowserDialogPolicy.isAction in Glide (BrowserDriver.swift).
 */
function isAction(method, params) {
  if (method.startsWith("Input.")) return true;
  if (method === "Page.navigate" || method === "Page.navigateToHistoryEntry" || method === "Page.reload") return true;
  return (method === "Runtime.evaluate" || method === "Runtime.callFunctionOn") && !!params && params.userGesture === true;
}

/** The error for a command sent to a tab whose dialog is waiting for the user. */
function waitingDialogMessage(dialog) {
  const kinds = { alert: "an alert", confirm: "a confirmation dialog", prompt: "a prompt", beforeunload: "a “Leave site?” prompt" };
  const what = kinds[dialog.type] || "a dialog";
  const quote = dialog.message ? ` (“${dialog.message.slice(0, 120)}”)` : "";
  return `This tab is showing ${what}${quote}. Answer it in Chrome, then try again.`;
}

/**
 * A page opened a tab. It's remembered with the tab it came from, so Glide can tell its click's
 * popup from tabs that opened meanwhile. When it came from one of Glide's tabs while Glide works
 * there it's Glide's too, and if Chrome brought it to the front over the user's tab (a click
 * opens links in the foreground, even in a background tab) the user's tab goes back in front.
 */
async function onPopup(sourceTabId, tabId) {
  if (typeof sourceTabId !== "number" || typeof tabId !== "number" || sourceTabId < 0 || tabId < 0) return;
  popupSources.delete(tabId);
  popupSources.set(tabId, sourceTabId);
  while (popupSources.size > MAX_POPUP_SOURCES) popupSources.delete(popupSources.keys().next().value);
  if (!isDriving(sourceTabId) || !(await loadGlideTabs()).has(sourceTabId)) return;
  await rememberGlideTab(tabId);
  const [source, popup] = await Promise.all([chrome.tabs.get(sourceTabId).catch(() => null), chrome.tabs.get(tabId).catch(() => null)]);
  // Chrome sets a link's new tab's openerTabId to the tab that was in front when it opened.
  const front = popup && popup.openerTabId;
  if (!source || !popup || source.active || !popup.active || popup.windowId !== source.windowId) return;
  if (typeof front !== "number" || front === sourceTabId || front === tabId) return;
  await chrome.tabs.update(front, { active: true }).catch(() => {});
}

function scheduleIdleDetach(tabId) {
  clearTimeout(idleTimers.get(tabId));
  const timer = setTimeout(() => {
    if (idleTimers.get(tabId) !== timer) return;
    idleTimers.delete(tabId);
    detachIfIdle(tabId).catch((e) => console.warn("Glide: couldn't let go of an idle tab", e));
  }, IDLE_DETACH_MS);
  idleTimers.set(tabId, timer);
}

/** Lets go of a tab Glide didn't open once Glide has stopped using it. Glide's own tabs stay
 * attached: their dialogs are answered for Glide, and Glide closes them when it's done. */
async function detachIfIdle(tabId) {
  if (!attached.has(tabId)) return;
  if ((await loadGlideTabs()).has(tabId)) return;
  if (!attached.has(tabId)) return; // detached while reading storage
  if (isDriving(tabId)) {
    // Still in use (or only just): look again later. A new command cancels this anyway.
    if (!idleTimers.has(tabId)) scheduleIdleDetach(tabId);
    return;
  }
  await detachQuietly(tabId);
}

/**
 * JavaScript dialogs freeze the page's scripts until answered, which would stall every command
 * on the tab. On a tab Glide is working in (its own tab, or one it's sending commands to right
 * now) they're answered the way Glide's own Chrome does — dismiss alerts, let navigation leave
 * the page, decline confirm()/prompt() — and Glide is told. Anywhere else the dialog is the
 * user's: a page's own "Leave site?" or "Delete this?" must never be answered behind their back.
 * In the user's tabs "Leave site?" is accepted only when one of Glide's actions (a click, a key,
 * a navigation) could have caused it: while Glide merely reads the tab, it's the user closing it
 * or leaving a half-filled form, and accepting would throw their input away.
 * Must match BrowserDialogPolicy in Glide (BrowserDriver.swift).
 */
async function onDialogOpening(tabId, params) {
  const type = params.type || "alert";
  const message = String(params.message || "").slice(0, 500);
  // Judged at once: the grace period mustn't run out while storage is read.
  const working = type === "beforeunload" ? isActing(tabId) : isDriving(tabId);
  if (!working && !(await loadGlideTabs()).has(tabId)) {
    openDialogs.set(tabId, { type, message });
    return;
  }
  const accept = type === "alert" || type === "beforeunload";
  chrome.debugger
    .sendCommand({ tabId }, "Page.handleJavaScriptDialog", { accept })
    .catch((e) => console.warn("Glide: couldn't answer a dialog", e));
  if (session && session.verified) send(session, { event: "dialog", tabId, type, message, accepted: accept });
}

/** Whether the debugger is on the tab: ours (also from before the worker restarted) or DevTools'. */
async function wasAttached(tabId) {
  if (attached.has(tabId)) return true;
  try {
    return (await chrome.debugger.getTargets()).some((target) => target.tabId === tabId && target.attached);
  } catch (e) {
    return false;
  }
}

function forgetAttachment(tabId) {
  attached.delete(tabId);
  clearTimeout(idleTimers.get(tabId));
  idleTimers.delete(tabId);
  openDialogs.delete(tabId);
}

function ensureAttached(tabId, tab) {
  if (attached.has(tabId)) return Promise.resolve();
  if (attaching.has(tabId)) return attaching.get(tabId);
  const attempt = (async () => {
    try {
      await chrome.debugger.attach({ tabId }, "1.3");
    } catch (error) {
      const message = messageOf(error);
      if (/already attached/i.test(message)) {
        // Maybe ours from before the worker restarted: a harmless command tells.
        try {
          await chrome.debugger.sendCommand({ tabId }, "Runtime.evaluate", { expression: "1", returnByValue: true });
        } catch (probeError) {
          throw bridgeError("cdp", "Another debugger (such as DevTools) is attached to this tab. Close it and try again.");
        }
      } else if (/file:/i.test(message)) {
        throw bridgeError(
          "cdp",
          "Chrome blocks extensions from local files by default. To allow it: chrome://extensions › Glide › Details › Allow access to file URLs."
        );
      } else if (/cannot access|cannot attach|chrome:\/\/|chrome-extension:/i.test(message)) {
        throw bridgeError("restricted", "Chrome doesn't allow automating this page.", { url: (tab && tab.url) || "" });
      } else {
        throw bridgeError("cdp", message);
      }
    }
    // Page events are needed to see (and answer) JavaScript dialogs.
    try {
      await chrome.debugger.sendCommand({ tabId }, "Page.enable");
    } catch (e) {
      console.warn("Glide: Page.enable failed", e);
    }
    attached.add(tabId);
  })().finally(() => attaching.delete(tabId));
  attaching.set(tabId, attempt);
  return attempt;
}

async function detachQuietly(tabId) {
  forgetAttachment(tabId);
  try {
    await chrome.debugger.detach({ tabId });
  } catch (e) {
    // wasn't attached
  }
}

async function detachAll() {
  const tabIds = new Set(attached);
  try {
    for (const target of await chrome.debugger.getTargets()) {
      if (target.attached && typeof target.tabId === "number") tabIds.add(target.tabId);
    }
  } catch (e) {
    // getTargets unavailable: fall back to what we know
  }
  // Detaching only ever removes our own session, never DevTools'.
  await Promise.all([...tabIds].map((tabId) => detachQuietly(tabId)));
}

async function onDebuggerDetach(source, reason) {
  if (typeof source.tabId !== "number") return;
  forgetAttachment(source.tabId);
  if (reason === "canceled_by_user") {
    // The user dismissed Chrome's debugging bar: stop until they allow it again.
    await chrome.storage.session.set({ [G.SESSION_KEYS.paused]: true });
    await refreshBadge();
  }
  if (session && session.verified) send(session, { event: "detached", tabId: source.tabId, reason: String(reason) });
}

// ---- Popup and pairing page ----

async function handleUIMessage(message, sender) {
  if (!sender || sender.id !== chrome.runtime.id) throw new Error("Not allowed.");
  switch (message && message.type) {
    case "status":
      // Opening the popup is a good moment to retry; live refreshes (poke false) must not
      // trigger connects, or every status write would cause another.
      if (message.poke && !isLive(session) && !connecting) connect("popup");
      return statusSnapshot();
    case "pair": {
      const pairing =
        typeof message.code === "string"
          ? G.parsePairingCode(message.code)
          : G.isValidToken(message.token) && G.isValidPort(Number(message.port))
          ? { port: Number(message.port), token: message.token }
          : null;
      if (!pairing) throw new Error("That pairing code doesn't look right. Copy it again from Glide's Settings › Browser.");
      await chrome.storage.session.remove([G.SESSION_KEYS.replaced, G.SESSION_KEYS.paused]);
      // The storage listener reconnects with the new details.
      await chrome.storage.local.set({ [G.KEYS.port]: pairing.port, [G.KEYS.token]: pairing.token });
      return statusSnapshot();
    }
    case "reconnect":
      await chrome.storage.session.remove([G.SESSION_KEYS.replaced, G.SESSION_KEYS.paused]);
      resetBackoff();
      await refreshBadge();
      if (!(session && session.verified && session.ws.readyState === WebSocket.OPEN)) {
        disconnect(1000, "Reconnecting");
        await connect("manual");
      }
      return statusSnapshot();
    case "allow":
      await chrome.storage.session.remove(G.SESSION_KEYS.paused);
      await refreshBadge();
      return statusSnapshot();
    case "unpair":
      await chrome.storage.local.remove(G.KEYS.token);
      return statusSnapshot();
    default:
      throw new Error("Unknown request.");
  }
}

async function statusSnapshot() {
  const [{ port, token }, paused] = await Promise.all([loadPairing(), getSessionValue(G.SESSION_KEYS.paused)]);
  return { ...lastStatus, port, paired: !!token, paused: !!paused, detail: G.describeStatus({ ...lastStatus, port }) };
}

async function setStatus(state, extra) {
  const next = { state, port: (extra && extra.port) || null, chromeVersion: (extra && extra.chromeVersion) || null };
  const unchanged = lastStatus.state === next.state && lastStatus.port === next.port && lastStatus.chromeVersion === next.chromeVersion;
  lastStatus = next;
  if (unchanged) return; // retries repeat the same state; don't wake listeners for nothing
  try {
    await chrome.storage.session.set({ [G.SESSION_KEYS.status]: lastStatus });
  } catch (e) {
    // storage unavailable while Chrome shuts down
  }
  await refreshBadge();
}

async function refreshBadge() {
  try {
    const paused = await getSessionValue(G.SESSION_KEYS.paused);
    const attention = paused || G.needsAttention(lastStatus.state);
    await chrome.action.setBadgeText({ text: attention ? "!" : "" });
    if (attention) await chrome.action.setBadgeBackgroundColor({ color: "#E8A33D" });
    const line = paused ? G.PAUSED_MESSAGE : G.describeStatus(lastStatus);
    await chrome.action.setTitle({ title: `Glide: ${line}` });
  } catch (e) {
    // action API unavailable
  }
}

// ---- Helpers ----

async function loadPairing() {
  const values = await chrome.storage.local.get([G.KEYS.port, G.KEYS.token]);
  const port = G.isValidPort(Number(values[G.KEYS.port])) ? Number(values[G.KEYS.port]) : G.DEFAULT_PORT;
  const token = G.isValidToken(values[G.KEYS.token]) ? values[G.KEYS.token] : null;
  return { port, token };
}

async function getSessionValue(key) {
  try {
    const values = await chrome.storage.session.get(key);
    return values[key];
  } catch (e) {
    return undefined;
  }
}

async function loadGlideTabs() {
  const ids = await getSessionValue(G.SESSION_KEYS.glideTabs);
  return new Set(Array.isArray(ids) ? ids : []);
}

async function rememberGlideTab(tabId) {
  const ids = [...(await loadGlideTabs()), tabId].slice(-MAX_GLIDE_TABS);
  await chrome.storage.session.set({ [G.SESSION_KEYS.glideTabs]: ids });
}

async function forgetGlideTab(tabId) {
  const ids = await loadGlideTabs();
  if (!ids.delete(tabId)) return;
  await chrome.storage.session.set({ [G.SESSION_KEYS.glideTabs]: [...ids] });
}

function tabInfo(tab, glideTabs) {
  return {
    id: tab.id,
    url: tab.url || tab.pendingUrl || "",
    title: tab.title || "",
    active: !!tab.active,
    windowId: tab.windowId,
    glide: glideTabs.has(tab.id),
    // The tab whose page opened it, so Glide can tell its click's popup from other new tabs.
    // Not tab.openerTabId: for a link's new tab that's whichever tab was in front at the time.
    sourceTabId: popupSources.has(tab.id) ? popupSources.get(tab.id) : null,
  };
}

function requireTabId(params) {
  const tabId = params.tabId;
  if (!Number.isInteger(tabId) || tabId < 0) throw bridgeError("bad_request", "A tab id is required.");
  return tabId;
}

async function getTab(tabId) {
  try {
    return await chrome.tabs.get(tabId);
  } catch (error) {
    throw bridgeError("tab_not_found", `The tab ${tabId} is closed.`, { tabId: String(tabId) });
  }
}

function assertAllowed(url) {
  if (G.isRestrictedURL(url)) throw bridgeError("restricted", "Chrome doesn't allow automating this page.", { url: String(url) });
}

function chromeVersionString() {
  const match = /Chrome\/([\d.]+)/.exec(self.navigator ? self.navigator.userAgent : "");
  return match ? match[1] : "unknown";
}

function bridgeError(code, message, extra) {
  return Object.assign(new Error(message), { code }, extra || {});
}

function errorPayload(error) {
  const payload = { message: messageOf(error), code: (error && error.code) || "error" };
  if (error && error.url !== undefined) payload.url = error.url;
  if (error && error.tabId !== undefined) payload.tabId = error.tabId;
  return payload;
}

function messageOf(error) {
  if (!error) return "Unknown error";
  if (typeof error === "string") return error;
  return error.message || String(error);
}
