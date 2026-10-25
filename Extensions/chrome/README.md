# Glide Chrome extension

Lets the Glide Mac app work in your everyday Chrome, with your logins, in background tabs. It
connects to Glide over `ws://127.0.0.1:<port>/glide` (port 47823 by default) and carries out
Glide's requests with `chrome.tabs`, `chrome.debugger` and `chrome.webNavigation` (to tell which
tab a popup came from). Plain Manifest V3 JavaScript: no build step, no dependencies.

## Install

1. In Glide, open **Settings › Browser** and click **Reveal in Finder** (inside the app it's
   `Glide.app/Contents/Resources/ChromeExtension`; in a checkout it's this folder).
2. In Chrome, go to `chrome://extensions` (paste it into the address bar; Chrome won't open it
   from other apps), turn on **Developer mode**, click **Load unpacked** and choose the folder.
3. Back in Glide, click **Pair**. Chrome opens the pairing page, which shows the port it will
   connect to; click **Pair** there to confirm. If that page can't open, click **Copy pairing
   code** in Glide and paste the code (`port:token`) into the extension's toolbar popup.

To use a port other than 47823 (another app holds it, say), change **Bridge port** in
Settings › Browser (1024–65535) and pair again: the pairing code carries the port.

## Files

| File | What |
|---|---|
| `manifest.json` | MV3 manifest. The `key` (public key only) fixes the extension id at `ijondegifnhgojpklbepjoeocacalghd`, which Glide checks. |
| `service_worker.js` | Connection, reconnects (backoff plus a 30 s alarm), keepalive, and the RPC handlers. |
| `common.js` | Helpers shared with the popup, the pairing page and Glide's tests. |
| `popup.html` / `popup.js` | Status, pasted pairing code, Reconnect, Allow again, Forget this pairing. |
| `pair.html` / `pair.js` | Reads `#token=…&port=…` and wipes it from the address bar at once; saves it only after you click **Pair**. |

## Safety

- Both sides prove they know the pairing token with HMAC-SHA256 proofs; the token itself never
  goes over the socket. Nothing except `hello` is obeyed until Glide has proven itself, so
  another program listening on the port can't take control of the browser.
- Chrome's own pages (`chrome://…`), other extensions, the Web Store and `javascript:` URLs are
  never automated.
- A few DevTools methods that could read or erase data from every site at once (all cookies,
  clearing storage, ignoring certificate errors) are refused.
- Pairing never happens by itself: a pairing link only fills in the page, and you confirm it.
  A different port than 47823, or replacing an existing pairing, is pointed out.
- If you close Chrome's "started debugging this browser" bar, Glide stops working in your tabs
  until you click **Allow again** in the popup.
- The debugger lets go of your own tabs after 45 seconds without a command from Glide, and of
  every tab when Glide disconnects. Tabs Glide opened stay attached until Glide closes them.
- Page dialogs (`alert`, `confirm`, `prompt`, "Leave site?") are answered automatically only in
  tabs Glide opened or is working in at that moment: alerts are closed, confirm and prompt are
  declined, and leaving the page is allowed. In your own tabs, "Leave site?" is answered only
  when one of Glide's clicks, keys or navigations brought it up. Anywhere else the dialog is
  left for you, and Glide's commands in that tab fail at once until you answer it.
- New tabs a page opens (links with `target=_blank`, `window.open`) are adopted as Glide's only
  when they came from a tab Glide opened and is working in. `chrome.webNavigation` says which
  tab that was. If Chrome brings such a tab to the front, the extension puts the tab you were
  on back in front.

## Changing the key

The id is derived from `key`. If you ever replace it, generate a new pair with
`openssl genrsa 2048 | openssl rsa -pubout -outform DER | base64`, put the result in `key`
(never commit the private key), then run `swift scripts/extension_id.swift` and update
`ExtensionBridge.extensionID` with the id it prints.
