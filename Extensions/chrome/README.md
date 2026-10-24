# Glide Chrome extension

Lets the Glide Mac app work in your everyday Chrome, with your logins, in background tabs. It
connects to Glide over `ws://127.0.0.1:<port>/glide` (port 47823 by default) and carries out
Glide's requests with `chrome.tabs` and `chrome.debugger`. Plain Manifest V3 JavaScript: no
build step, no dependencies.

## Install

1. In Glide, open **Settings › Browser** and click **Reveal extension folder** (inside the app
   it's `Glide.app/Contents/Resources/ChromeExtension`; in a checkout it's this folder).
2. In Chrome, go to `chrome://extensions` (paste it into the address bar; Chrome won't open it
   from other apps), turn on **Developer mode**, click **Load unpacked** and choose the folder.
3. Back in Glide, click **Pair**. Chrome opens the pairing page and connects. If that page
   can't open, copy the pairing code (`port:token`) from Glide and paste it into the
   extension's toolbar popup.

## Files

| File | What |
|---|---|
| `manifest.json` | MV3 manifest. The `key` (public key only) fixes the extension id at `ijondegifnhgojpklbepjoeocacalghd`, which Glide checks. |
| `service_worker.js` | Connection, reconnects (backoff plus a 30 s alarm), keepalive, and the RPC handlers. |
| `common.js` | Helpers shared with the popup, the pairing page and Glide's tests. |
| `popup.html` / `popup.js` | Status, pasted pairing code, Reconnect, Allow again. |
| `pair.html` / `pair.js` | Reads `#token=…&port=…`, saves it and wipes it from the address bar. |

## Safety

- Both sides prove they know the pairing token with HMAC-SHA256 proofs; the token itself never
  goes over the socket. Nothing except `hello` is obeyed until Glide has proven itself, so
  another program listening on the port can't take control of the browser.
- Chrome's own pages (`chrome://…`), other extensions, the Web Store and `javascript:` URLs are
  never automated.
- A few DevTools methods that could read or erase data from every site at once (all cookies,
  clearing storage, ignoring certificate errors) are refused.
- If you close Chrome's "started debugging this browser" bar, Glide stops working in your tabs
  until you click **Allow again** in the popup.
- When Glide disconnects, the extension detaches from every tab.

## Changing the key

The id is derived from `key`. If you ever replace it, generate a new pair with
`openssl genrsa 2048 | openssl rsa -pubout -outform DER | base64`, put the result in `key`
(never commit the private key), then run `swift scripts/extension_id.swift` and update
`ExtensionBridge.extensionID` with the id it prints.
