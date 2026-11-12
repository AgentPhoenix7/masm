# MAZE4 verification — 2026-11-12

## Build and scope

The delivered `MAZE4.EXE` is assembled and linked in installed DOSBox 0.74-3
using only this checkout's `dos-tools/MASM.EXE`, its `ML.EXE`, and `LINK.EXE`.
The live supplied linker identifies itself as 5.31.009. The older toolchain
README's 5.10/3.65 descriptions do not describe these currently supplied files.
No original MAZE3 source or supplied tool binary was edited.

## Automated checks

- 128 actual assembly-generated mazes, 128 distinct, independently verified for
  closed boundaries, connected floor cells, valid unique starts, equal shortest
  walkable exit distances, and the declared density/layer/eight-player cap.
- Actual assembly collision cases cover same-target contenders in both modes,
  rotating priority, stationary occupancy, head-on swaps, blocked chains,
  following moves, and simultaneous shared-exit arrivals.
- Collision follow-up reproduced the reported missing penalty: the previous
  default selected no-penalty rotating priority. Block + penalty now starts by
  default, matching MAZE3. A regression checks +3.0 seconds to both once per
  episode, no repeat charge while holding, and +3.0 again after release.
- A second regression reproduced inactive-slot priority bias: slots 0 and 1
  won seven versus one of eight repeated contests. The cursor now rotates
  only through racing players, normalizing before arbitration if its owner is
  absent/DNF. Three sparse rosters now alternate four wins each over eight
  contests. Empty, finished and DNF slots are covered.
- Follow-up collision fixtures cover an eight-player stationary-ended chain
  (all canceled, pairwise penalties), a freely following eight-player chain,
  four-way contention (+9.0 seconds each for three distinct contacts), and
  simultaneous exit arrivals. Both modes recover when a head-on player backs
  away; neither mode automatically swaps players. The final-finisher/no-racer
  cursor scan is bounded and completes.
- Contact latching charges once during sustained contact and again after a
  released episode. Full 32-bit scores and tied winners exclude DNF players.
- Actual assembly lifecycle checks cover ready/start gating, held-input expiry,
  race DNF, lobby persistence, no-finisher results, BIOS midnight rollover,
  path-warning boundaries 2/3/4/5, wall-separated routes, and finishers.
- A regression reproduced a tap repeating three steps while release was in
  transit; the final MASM tap handler latches one step without enabling hold.
- Actual text VRAM checks cover results, scoreboard values, and restoration of
  the original keyboard interrupt vector.
- Actual COM1 tests admit eight players, reject overflow/stale owners/epochs,
  acknowledge idempotent retries, process readiness and leave, and reject
  revoked ownership.
- Real HTTP → authentication → TCP COM1 → actual MASM integration verifies tap
  and release, per-player binding, held-input lease expiry before a wall,
  stale sequences, late-join rejection, and recovery after malformed/oversized
  serial frames.
- HTTP/authentication tests cover Secure/HttpOnly/SameSite cookies, exact Host
  and Origin, CSRF, fixed paths/no public host endpoint, input validation,
  revocation and bounded login attempts.
- Review regressions verify uncertain joins retain their owner reservation,
  reloads preserve the non-credential join retry identity, transport movement
  queues do not retain stale backlogs, tunnel loss does not terminate the PC
  game, and DNF status remains authenticated/readable while explicit removal
  revokes access.
- Tunnel startup regression rejects the Cloudflare API URL inside an error
  message and requires an allocated banner URL plus a registered connection.

Latest result: **24/24 unittest tests passed in 29.066 seconds**. Ruff and Pyright
checks passed across the MAZE4 Python sources and tests. The separate
Node controller retry-identity test and JavaScript syntax check also passed.
The delivered executable is 18,953 bytes, SHA-256:

```text
cfed4c67f898d83ccf162f5d4b2dd8ba79c28087f53a2b5db74fc0469fcf7023
```

## Physical phone and rendered desktop evidence

A real Android 14 CPH2381 used Android Chrome and the public HTTPS controller
page. Three additional independent HTTPS clients joined the same race. Actual
DOSBox host keyboard start was verified with the X11 backend on KDE/Wayland.

The phone's Up/Down/Left/Right buttons were tapped and held. The actual MASM
state trace showed successful moves, blocked directions, and no continued
movement after release. Holds produced multiple steps; the three simulated
players remained stationary. No ADB reverse or forward mapping carried game
traffic. ADB was used only to open/tap/capture the browser. A password-manager
prompt was dismissed without saving the temporary password.

Earlier evidence is under `.scratch/maze4-phone/`:

- `phone-movement.json`: actual phone input and before/after MASM positions/steps.
- `phone-racing.png`, `dosbox-racing.png`, `dosbox-lobby.png`: rendered game screens.
- `final-tests.log`: full automated output.

The collision follow-up's failing reproductions and passing suite are saved in
`.scratch/maze4-collision/before.log`, `after.log`, and `full-tests.log`.
These follow-up tests execute actual MASM in installed DOSBox with an isolated
dummy display; a physical phone collision rerun was not performed.

The physical run exposed the repeated-tap issue; it was then corrected and
verified in real assembly and the real HTTP/COM1 integration. The final post-review physical rerun was **blocked before opening the game**
by repeated Cloudflare Quick Tunnel allocation timeouts. A direct API HEAD
request returned HTTP 405, but cloudflared's tunnel-creation POST timed out;
a process-only HTTP/1.1 diagnostic retry did not resolve it. No unsupported
claim of a final physical pass or provider-wide outage is made. The final tap,
retry, DNF, parser, and lifecycle changes passed real DOSBox/HTTP integration
and their regression tests. The opt-in physical rerun can be repeated with:

```bash
python3 tests/maze4/phone_acceptance.py --device YOUR_ADB_SERIAL
```

That script creates its own room, tests phone controls, stops only its owned
cloudflared child, waits for MASM DNF/results, checks authenticated terminal
status, and quits DOSBox with Esc. It saves a success summary only if every
check passes. Current failed allocation attempts did not produce that summary.

## Review decisions

The collision follow-up received a separate read-only review of MAZE3 parity,
pair latching, cancellation propagation, sparse-roster priority, bounded
no-racer scans, caller registers and the new regression fixtures. It found
no material issues. The author ran the complete 24-test suite.

An independent read-only code review found no critical issues and identified
uncertain join retries, PC shutdown on tunnel loss, and missing phone DNF status.
All three were reproduced and corrected with regression tests. DNF status was
classified as required behavior and fixed rather than deferred.

Implementation rulings and reasons:

- Generated executables, objects, listings and maps under assignment folders are
  ignored; the launcher rebuilds MAZE4 from source when its executable is absent.
  Supplied dos-tools binaries and previously tracked coursework are preserved.
- The small standard-library HTTP adapter has fixed routes and bounded workers
  behind HTTPS; game logic and all game timers remain in MASM.
- Movement lease is 14 BIOS ticks; race disconnect is 546 ticks. Lobby players
  remain until explicit leave/removal so setup prompts do not evict them.
- Room password and controller credentials use host cryptographic facilities;
  no custom 8086 TLS/crypto or Cloudflare API token is introduced.
- Pending join reservations are bounded and retained through uncertain outcomes
  for the room lifetime, so a retry cannot allocate a second player.
- Automatic timeout preserves only authenticated terminal DNF access; explicit
  leave/host removal clears the MASM owner and revokes the credential.

## Limits

Only one physical phone was available; concurrent additional controllers were
simulated. The phone used its existing Wi-Fi connection while requests traveled
through the public Cloudflare HTTPS endpoint. Separate-network/mobile-data
operation was not physically tested; its network settings were not changed.
Internet latency is not equalized. Temporary Cloudflare tunnels have no uptime
guarantee and can fail to allocate an address; startup now reports that failure
instead of presenting an API error URL as the game address.

Phone Chrome DevTools access was rejected by automatic approval review because
it could expose unrelated authenticated tabs. No such access/forward was used;
visible ADB UI inspection and an isolated desktop browser profile were sufficient.
