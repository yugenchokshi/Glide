// Opened by Glide as chrome-extension://<id>/pair.html#token=…&port=… when the user clicks Pair
// in Settings › Browser. Wipes the secret from the address bar, says what would be paired, and
// saves the pairing only when the user clicks Pair here. It isn't a web-accessible resource, so
// web pages can't open it — but any app on this Mac can open a link in Chrome, so the link
// alone must never be enough to point the extension at a server.
(function () {
  "use strict";
  const G = globalThis.GlideCommon;
  const $ = (id) => document.getElementById(id);
  let pairing = G.parsePairingHash(location.hash);
  // Don't leave the token in the address bar or session history.
  history.replaceState(null, "", location.pathname);

  function showState(dot, detail, meta) {
    $("state").hidden = false;
    $("dot").className = "dot " + dot;
    $("detail").textContent = detail;
    $("meta").textContent = meta || "";
  }

  function render(status) {
    const connected = status.state === "connected";
    const dot = connected ? "ok" : G.needsAttention(status.state) ? "bad" : "warn";
    const detail = connected ? "Paired. Glide can now work in your Chrome tabs. You can close this tab." : status.detail || G.describeStatus(status);
    showState(dot, detail, status.port ? "Port " + status.port : "");
  }

  function fail(message) {
    showState("bad", "Couldn't pair.");
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

  $("target").textContent = `Glide on this Mac, port ${pairing.port}`;
  if (pairing.port !== G.DEFAULT_PORT) {
    $("portWarning").textContent = `Glide normally uses port ${G.DEFAULT_PORT}. Only continue if you chose port ${pairing.port} in Glide's Settings › Browser.`;
    $("portWarning").hidden = false;
  }
  $("confirm").hidden = false;
  request({ type: "status" }).then(
    (status) => {
      $("replaceNote").hidden = !(status && status.paired);
    },
    () => {}
  );

  $("pair").addEventListener("click", () => {
    const chosen = pairing;
    pairing = null;
    if (!chosen) return;
    $("confirm").hidden = true;
    showState("warn", "Pairing…", "Port " + chosen.port);
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === "session" && G.SESSION_KEYS.status in changes) request({ type: "status" }).then(render, () => {});
    });
    request({ type: "pair", port: chosen.port, token: chosen.token })
      .then(render)
      .catch((error) => fail(error.message || String(error)));
  });

  $("cancel").addEventListener("click", () => {
    pairing = null;
    $("confirm").hidden = true;
    showState("warn", "Not paired. You can close this tab.");
  });
})();
