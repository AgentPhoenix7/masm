"use strict";
const $ = (id) => document.getElementById(id);
let csrf = "",
  sequence = 0,
  state = null,
  held = 0,
  pointer = null,
  polling = false;
function newAttempt() {
  const value = Array.from(crypto.getRandomValues(new Uint8Array(16)), (x) =>
    x.toString(16).padStart(2, "0"),
  ).join("");
  try {
    sessionStorage.setItem("maze4-join-attempt", value);
  } catch (_) {}
  return value;
}
// This retry identity is not a controller credential: room password is still
// required. Cookies/CSRF credentials are never written to browser storage.
let attempt;
try {
  attempt = sessionStorage.getItem("maze4-join-attempt");
} catch (_) {}
if (!/^[a-f0-9]{32}$/.test(attempt || "")) attempt = newAttempt();
let inFlight = false,
  pending = null,
  pendingTap = null;
async function api(path, body) {
  const options = {
    credentials: "same-origin",
    cache: "no-store",
    signal: AbortSignal.timeout(3500),
  };
  if (body !== undefined)
    Object.assign(options, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Maze-CSRF": csrf },
      body: JSON.stringify(body),
    });
  const response = await fetch(path, options);
  const data = await response.json();
  if (!response.ok) {
    const e = new Error(data.error || "Connection failed");
    e.status = response.status;
    throw e;
  }
  return data;
}
function resetSession() {
  held = 0;
  pending = null;
  pendingTap = null;
  csrf = "";
  state = null;
  pointer = null;
  $("game").hidden = true;
  $("join-panel").hidden = false;
  document
    .querySelectorAll("[data-direction]")
    .forEach((b) => b.classList.remove("held"));
}
function render(s) {
  const changed =
    state &&
    (state.epoch !== s.epoch ||
      state.generation !== s.generation ||
      s.phase !== 2 ||
      s.player.state !== 1);
  if (changed && held) release();
  state = s;
  csrf = s.csrf;
  sequence = Math.max(sequence, s.sequence);
  $("game").hidden = false;
  $("join-panel").hidden = true;
  $("identity").textContent = `P${s.player.id + 1} · ${s.player.name}`;
  const phases = { 1: "LOBBY", 2: "RACING", 3: "RESULTS" };
  $("phase").textContent = s.player.state === 3 ? "DNF" : phases[s.phase];
  $("connection").textContent =
    "Connected · " + s.count + "/" + s.capacity + " players";
  const warnings = [
    "SAFE",
    "CAUTION · player nearby",
    "DANGER · player very close",
  ];
  $("warning").textContent = warnings[s.player.warning];
  $("warning").className = ["", "caution", "danger"][s.player.warning];
  const score =
    ((s.player.state === 2 ? s.player.finish : s.elapsed) + s.player.penalty) /
    10;
  $("details").textContent =
    `Steps ${s.player.steps} · Penalty ${(s.player.penalty / 10).toFixed(1)}s · ${s.player.state === 3 ? "DNF" : `Score ${score.toFixed(1)}s`}`;
  $("ready").hidden = s.phase !== 1;
  $("ready").textContent = s.player.ready ? "Ready ✓ — tap to undo" : "Ready";
  $("ready").setAttribute("aria-pressed", String(s.player.ready));
  const canMove = s.phase === 2 && s.player.state === 1;
  document
    .querySelectorAll("[data-direction]")
    .forEach((b) => (b.disabled = !canMove));
  $("instruction").textContent =
    s.player.state === 3
      ? "DNF — connection was lost too long. Wait for the next room."
      : s.player.state === 2
        ? "Finished! Your score is frozen."
        : s.phase === 3
          ? s.winners & (1 << s.player.id)
            ? "You won!"
            : "Race complete. See results on the PC."
          : s.phase === 1
            ? "Press Ready, then the host starts the race on the PC."
            : "Look at the maze on the PC. Tap to step; hold to keep moving.";
}
async function poll() {
  if (polling || document.hidden) return;
  polling = true;
  try {
    render(await api("/api/state"));
    $("error").textContent = "";
  } catch (e) {
    if (e.status === 401) {
      resetSession();
      $("connection").textContent = "Enter the room password to join";
    } else {
      $("connection").textContent = "Connection interrupted — reconnecting…";
      if (held) release();
    }
  } finally {
    polling = false;
  }
}
// One outstanding movement request, with a single newest pending request.
// The first tap latch is kept until sent; releases have larger sequence numbers.
async function drain() {
  if (inFlight || (!pending && !pendingTap) || !csrf) return;
  inFlight = true;
  let message;
  if (pendingTap && (!pending || pendingTap.seq < pending.seq)) {
    message = pendingTap;
    pendingTap = null;
  } else {
    message = pending;
    pending = null;
  }
  try {
    await api("/api/input", message);
  } catch (e) {
    if (e.status !== 409) {
      $("error").textContent = e.message;
      held = 0;
      pending = null;
      pendingTap = null;
    }
  } finally {
    inFlight = false;
    if (pending || pendingTap) drain();
  }
}
function move(direction, tap = false) {
  if (!state || state.phase !== 2 || state.player.state !== 1) return;
  const message = { seq: ++sequence, direction, tap };
  if (tap) pendingTap = message;
  else pending = message;
  drain();
}
function press(direction, event) {
  if (held || !state || state.phase !== 2 || state.player.state !== 1) return;
  held = direction;
  pointer = event ? event.pointerId : null;
  document
    .querySelector(`[data-direction="${direction}"]`)
    .classList.add("held");
  move(direction, true);
}
function release() {
  if (!held) return;
  held = 0;
  pointer = null;
  document
    .querySelectorAll("[data-direction]")
    .forEach((b) => b.classList.remove("held"));
  move(0);
}
$("join-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("join").disabled = true;
  $("error").textContent = "";
  try {
    render(
      await api("/api/join", {
        name: $("name").value,
        password: $("password").value.toUpperCase(),
        attempt,
      }),
    );
    $("password").value = "";
  } catch (err) {
    $("error").textContent = err.message;
  } finally {
    $("join").disabled = false;
  }
});
$("ready").addEventListener("click", async () => {
  try {
    await api("/api/ready", { ready: !state.player.ready });
    await poll();
  } catch (e) {
    $("error").textContent = e.message;
  }
});
$("leave").addEventListener("click", async () => {
  release();
  try {
    await api("/api/leave", {});
    resetSession();
    attempt = newAttempt();
  } catch (e) {
    $("error").textContent = e.message;
  }
});
for (const button of document.querySelectorAll("[data-direction]")) {
  button.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    button.setPointerCapture(e.pointerId);
    press(Number(button.dataset.direction), e);
  });
  button.addEventListener("pointerup", (e) => {
    if (e.pointerId === pointer) release();
  });
  button.addEventListener("pointercancel", release);
  button.addEventListener("lostpointercapture", release);
  button.addEventListener("contextmenu", (e) => e.preventDefault());
}
const keys = {
  ArrowUp: 1,
  w: 1,
  ArrowDown: 2,
  s: 2,
  ArrowLeft: 3,
  a: 3,
  ArrowRight: 4,
  d: 4,
};
window.addEventListener("keydown", (e) => {
  if (e.target instanceof HTMLInputElement) return;
  if (keys[e.key]) {
    e.preventDefault();
    if (!e.repeat) press(keys[e.key]);
  }
});
window.addEventListener("keyup", (e) => {
  if (keys[e.key] === held) release();
});
window.addEventListener("blur", release);
document.addEventListener("visibilitychange", () => {
  if (document.hidden) release();
  else poll();
});
window.addEventListener("pagehide", () => {
  if (held && csrf) {
    held = 0;
    fetch("/api/input", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "X-Maze-CSRF": csrf },
      body: JSON.stringify({ seq: ++sequence, direction: 0, tap: false }),
      keepalive: true,
    }).catch(() => {});
  }
});
setInterval(() => {
  if (held) move(held);
}, 150);
setInterval(poll, 300);
poll();
