// Toolbar popup: shows the connection state, takes a pasted pairing code and offers Reconnect.
// All actions go through the service worker, which owns the connection.
(function () {
  "use strict";
  const G = globalThis.GlideCommon;
  const $ = (id) => document.getElementById(id);

  function request(message) {
    return chrome.runtime.sendMessage(message).then((reply) => {
      if (!reply || !reply.ok) throw new Error((reply && reply.error) || "The Glide extension didn't answer.");
      return reply.result;
    });
  }

  function dotClass(state) {
    if (state === "connected") return "ok";
    if (G.needsAttention(state)) return "bad";
    return "warn";
  }

  function render(status) {
    if (!status) return;
    $("dot").className = "dot " + dotClass(status.state);
    $("detail").textContent = status.detail || G.describeStatus(status);
    const meta = [];
    if (status.port) meta.push("Port " + status.port);
    if (status.chromeVersion && status.state === "connected") meta.push("Chrome " + status.chromeVersion);
    $("meta").textContent = meta.join(" · ");
    $("paused").hidden = !status.paused;
    $("unpair").hidden = !status.paired;
    $("reconnect").disabled = status.state === "connected" && !status.paused;
  }

  function showError(error) {
    $("error").textContent = error ? (error.message || String(error)) : "";
    $("error").hidden = !error;
  }

  async function run(message) {
    showError(null);
    try {
      render(await request(message));
    } catch (error) {
      showError(error);
    }
  }

  $("reconnect").addEventListener("click", () => run({ type: "reconnect" }));
  $("allow").addEventListener("click", () => run({ type: "allow" }));
  $("unpair").addEventListener("click", () => run({ type: "unpair" }));
  $("pair").addEventListener("click", async () => {
    const code = $("code").value;
    if (!G.parsePairingCode(code)) {
      showError(new Error("Paste the code exactly as Glide shows it: the port, a colon, then 64 letters and digits."));
      return;
    }
    await run({ type: "pair", code });
    $("code").value = "";
  });
  $("code").addEventListener("keydown", (event) => {
    if (event.key === "Enter") $("pair").click();
  });

  // Live updates while the popup is open.
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "session" && (G.SESSION_KEYS.status in changes || G.SESSION_KEYS.paused in changes)) run({ type: "status" });
    if (area === "local" && G.KEYS.token in changes) run({ type: "status" });
  });

  run({ type: "status", poke: true });
})();
