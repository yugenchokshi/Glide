// Opened by Glide as chrome-extension://<id>/pair.html#token=…&port=… . Saves the pairing,
// wipes the secret from the address bar, and shows the connection come up. It isn't a
// web-accessible resource, so web pages can't open it.
(function () {
  "use strict";
  const G = globalThis.GlideCommon;
  const $ = (id) => document.getElementById(id);
  const pairing = G.parsePairingHash(location.hash);
  // Don't leave the token in the address bar or session history.
  history.replaceState(null, "", location.pathname);

  function render(status) {
    const connected = status.state === "connected";
    $("dot").className = "dot " + (connected ? "ok" : G.needsAttention(status.state) ? "bad" : "warn");
    $("detail").textContent = connected ? "Paired. Glide can now work in your Chrome tabs. You can close this tab." : status.detail || G.describeStatus(status);
    $("meta").textContent = status.port ? "Port " + status.port : "";
  }

  function fail(message) {
    $("dot").className = "dot bad";
    $("detail").textContent = "Couldn't pair.";
    $("error").textContent = message;
    $("error").hidden = false;
  }

  function request(message) {
    return chrome.runtime.sendMessage(message).then((reply) => {
      if (!reply || !reply.ok) throw new Error((reply && reply.error) || "The Glide extension didn't answer.");
      return reply.result;
    });
  }

  if (!pairing) {
    fail("This pairing link is incomplete. In Glide, open Settings › Browser and click Pair again.");
    return;
  }

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "session" && G.SESSION_KEYS.status in changes) request({ type: "status" }).then(render, () => {});
  });

  request({ type: "pair", port: pairing.port, token: pairing.token })
    .then(render)
    .catch((error) => fail(error.message || String(error)));
})();
