// Shared by the service worker (importScripts), the popup and the pairing page. A plain script
// rather than a module so it loads the same way everywhere, including Node for Glide's tests.
// Must match Sources/AutomationKit/Browser/ExtensionBridge.swift (labels, nonce format,
// protocol version) and ExtensionBackend.swift (restricted pages).
(function (root) {
  "use strict";

  const DEFAULT_PORT = 47823;
  const PROTOCOL_VERSION = 1;
  const BRIDGE_PATH = "/glide";
  // Both ends prove they know the pairing token without sending it: the extension signs its
  // connection request with CLIENT_LABEL, Glide signs its first message with SERVER_LABEL.
  const CLIENT_LABEL = "glide-bridge/v1 client ";
  const SERVER_LABEL = "glide-bridge/v1 server ";

  // chrome.storage.local: survives restarts.
  const KEYS = Object.freeze({ port: "glidePort", token: "glideToken" });
  // chrome.storage.session: cleared when Chrome quits.
  const SESSION_KEYS = Object.freeze({
    status: "glideStatus",
    replaced: "glideReplaced",
    paused: "glidePausedByUser",
    glideTabs: "glideTabs",
  });

  const RESTRICTED_SCHEMES = new Set([
    "chrome", "chrome-extension", "chrome-untrusted", "chrome-search", "chrome-devtools", "devtools",
    "edge", "brave", "opera", "vivaldi", "view-source", "javascript",
  ]);
  const ALLOWED_ABOUT = new Set(["about:blank", "about:srcdoc"]);

  function isValidToken(token) {
    return typeof token === "string" && /^[0-9a-f]{64}$/.test(token);
  }

  function isValidPort(port) {
    return Number.isInteger(port) && port > 0 && port < 65536;
  }

  /** "47823:<64 hex>" → {port, token}, or null. */
  function parsePairingCode(text) {
    const match = /^(\d{1,5})\s*:\s*([0-9a-fA-F]{64})$/.exec(String(text == null ? "" : text).trim());
    if (!match) return null;
    const port = Number(match[1]);
    const token = match[2].toLowerCase();
    return isValidPort(port) ? { port, token } : null;
  }

  /** "#token=…&port=…" → {port, token}, or null. */
  function parsePairingHash(hash) {
    const params = new URLSearchParams(String(hash || "").replace(/^#/, ""));
    const token = (params.get("token") || "").trim().toLowerCase();
    const port = Number(params.get("port") || DEFAULT_PORT);
    if (!isValidToken(token) || !isValidPort(port)) return null;
    return { port, token };
  }

  function toHex(buffer) {
    return Array.from(new Uint8Array(buffer), (b) => b.toString(16).padStart(2, "0")).join("");
  }

  async function hmacHex(token, message) {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey("raw", encoder.encode(token), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return toHex(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
  }

  /** "<unix seconds>.<32 hex>": timestamped so Glide only needs to remember recent ones. */
  function makeNonce(nowMs) {
    const seconds = Math.floor((nowMs === undefined ? Date.now() : nowMs) / 1000);
    return `${seconds}.${toHex(crypto.getRandomValues(new Uint8Array(16)))}`;
  }

  function clientProof(token, nonce) {
    return hmacHex(token, CLIENT_LABEL + nonce);
  }

  function serverProof(token, nonce) {
    return hmacHex(token, SERVER_LABEL + nonce);
  }

  function safeEqual(a, b) {
    if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
  }

  /** True for pages Chrome won't let extensions automate (and javascript: URLs). */
  function isRestrictedURL(url) {
    const text = String(url == null ? "" : url).trim().toLowerCase();
    if (!text) return false;
    const colon = text.indexOf(":");
    if (colon > 0) {
      const scheme = text.slice(0, colon);
      if (RESTRICTED_SCHEMES.has(scheme)) return true;
      if (scheme === "about") return !ALLOWED_ABOUT.has(text.split(/[?#]/)[0]);
    }
    let parsed;
    try { parsed = new URL(text); } catch (e) { return false; }
    if (parsed.hostname === "chromewebstore.google.com") return true;
    if (parsed.hostname === "chrome.google.com" && parsed.pathname.startsWith("/webstore")) return true;
    return false;
  }

  function bridgeURL(port, nonce, proof) {
    return `ws://127.0.0.1:${port}${BRIDGE_PATH}?v=${PROTOCOL_VERSION}&nonce=${encodeURIComponent(nonce)}&proof=${proof}`;
  }

  function pingURL(port) {
    return `http://127.0.0.1:${port}${BRIDGE_PATH}/ping`;
  }

  /** Plain-language line for a connection state (shown in the popup and the toolbar tooltip). */
  function describeStatus(status) {
    const s = status || {};
    const port = s.port || DEFAULT_PORT;
    switch (s.state) {
      case "connected":
        return "Connected to Glide on this Mac.";
      case "connecting":
        return "Connecting to Glide…";
      case "not_paired":
        return "Not paired yet. In Glide, open Settings › Browser and click Pair.";
      case "glide_not_running":
        return `Glide isn't running (nothing answered on port ${port}). This reconnects by itself when Glide starts.`;
      case "rejected":
        return "Glide refused the connection. Pair again from Glide's Settings › Browser.";
      case "replaced":
        return "Another Chrome window or profile is connected to Glide. Click Reconnect to use this one.";
      case "untrusted":
        return `The app on port ${port} couldn't prove it's your Glide, so it was ignored. Pair again from Glide's Settings › Browser.`;
      case "version_mismatch":
        return "This extension doesn't match your version of Glide. Reload it from chrome://extensions.";
      default:
        return "Starting…";
    }
  }

  /** States where the user has to do something (the toolbar icon shows a badge). */
  function needsAttention(state) {
    return ["not_paired", "rejected", "replaced", "untrusted", "version_mismatch"].includes(state);
  }

  const PAUSED_MESSAGE =
    "You stopped Glide by closing Chrome's “started debugging this browser” bar. Click the Glide toolbar icon and choose Allow again to let it continue.";

  root.GlideCommon = Object.freeze({
    DEFAULT_PORT,
    PROTOCOL_VERSION,
    BRIDGE_PATH,
    CLIENT_LABEL,
    SERVER_LABEL,
    KEYS,
    SESSION_KEYS,
    PAUSED_MESSAGE,
    isValidToken,
    isValidPort,
    parsePairingCode,
    parsePairingHash,
    toHex,
    hmacHex,
    makeNonce,
    clientProof,
    serverProof,
    safeEqual,
    isRestrictedURL,
    bridgeURL,
    pingURL,
    describeStatus,
    needsAttention,
  });
})(typeof globalThis !== "undefined" ? globalThis : self);
