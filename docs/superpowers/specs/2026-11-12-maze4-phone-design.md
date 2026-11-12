# MAZE4: one DOSBox PC with authenticated internet phone controllers

Status: approved by the user on 2026-11-12 and implemented. See
`assignment-3/VERIFICATION.md` for test evidence and the final external-service
rerun limitation.
The later collision correction in `2026-11-12-maze4-collision-design.md`
sets block + penalty as the default and keeps rotating priority as the alternate.
User correction on 2026-11-12: normal play uses the internet, not ADB; require
authentication and keep as much of the program as possible in MASM.

## Intent and constraints

Extend `assignment-3/MAZE3.ASM` into `assignment-3/MAZE4.ASM`: a multiplayer
maze race displayed by the installed DOSBox, with each phone or tablet opening
an authenticated HTTPS controller webpage over the internet. Phones may use
mobile data or a different Wi-Fi network from the PC. Normal play needs neither
ADB nor a USB connection. Retain real 8086/MASM code and the supplied DOS
assembler/linker. MAZE3 is the baseline and stays available.

The user's selected architecture is one PC plus browser controllers. Separate
DOSBox PCs, native Android apps, and a browser reimplementation of the game do
not meet that selection. Keep all game behavior in MASM, including serial
parsing, lobby/player admission, readiness, frame scheduling, input expiry,
disconnect/DNF transitions, generation, movement, collision handling, warnings,
timing, scoring, and PC rendering. The small host bridge supplies only HTTP,
browser authentication/session security, and transport to COM1. Browser code
renders controller buttons and sends input; it contains no duplicate game engine.
Use established host TLS and cryptographic facilities rather than implementing
internet TLS or security-sensitive cryptography in 8086 assembly.

The bridge uses Python's standard library; the page uses HTML/CSS/JavaScript.
Internet reachability additionally requires an HTTPS reverse proxy/tunnel.
Cloudflare Tunnel is the proposed default connector, not a game-rule dependency.
Reuse the already installed `cloudflared`; no installation step is needed.
The installed Cloudflare Python SDK is optional: starting the connector and
forwarding authenticated controller traffic do not require Cloudflare API calls
or an API token. Keep it outside the game runtime unless account-managed tunnel
administration becomes an explicit requirement.

## Approaches and choice

1. **DOSBox COM1 nullmodem bridge (proposed implementation choice):** a local
   Python process serves controller pages and accepts DOSBox's transparent TCP
   serial connection. MAZE4 owns generation, player admission, movement,
   collisions, warnings, timing, and results. This provides independent player
   inputs without window focus or a limited set of keyboard bindings. Internet
   traffic reaches only the authenticated HTTP interface over an HTTPS tunnel;
   the serial TCP socket remains bound to loopback.
2. **Desktop keyboard injection:** simpler initial transport, but depends on
   display/focus and complicates independent held inputs as player count grows.
3. **Shared files polled by DOS:** avoids serial setup but adds filesystem
   polling, update races, and latency to the input path.

The user selected the one-PC/browser architecture; serial is the builder's
recommended transport within it. It is documented in the installed DOSBox
0.74-3 README and the [official manual](https://www.dosbox.com/DOSBoxManual.html).
The previous scratch prototype's IPX transport is unsuitable for this request.
Its assembly core is a candidate for reuse after independent verification.

For internet access, propose an outbound HTTPS tunnel to the PC instead of
direct router port forwarding. A temporary Cloudflare Quick Tunnel can support
the test/demo without an account or domain; its hostname changes on restart and
it has no uptime guarantee. A named tunnel with a stable HTTPS hostname is the
option for recurring use and needs the user's account/domain setup. Keep the
application compatible with another HTTPS reverse proxy so neither the game nor
its authentication depends on a particular provider. These are proposed
deployment defaults, not a claim that a tunnel is already configured.

Sources: [Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)
and [Cloudflare Tunnel setup](https://developers.cloudflare.com/tunnel/get-started/).
Quick Tunnels support at most 200 concurrent in-flight requests and do not
support server-sent events (SSE); use bounded HTTP polling and movement POSTs.

## Maze generation and fair starts

- Generate a new connected 17-row by 61-column maze at runtime, using randomized
  depth-first carving plus selected loop openings, keeping the outer boundary
  closed. Choose the shared exit randomly from traversable cells.
- Seed the generator from BIOS/DOS time. Provide a deterministic seed option
  only for repeatable tests; normal play must not use a fixed seed or layout.
- Run breadth-first search (BFS) from the exit. A starting cell's distance means
  its shortest walkable route, counting orthogonal moves through floor cells;
  it does not mean straight-line or Manhattan distance through walls.
- Select a distance layer at least 12 moves from the exit with enough distinct
  cells, then randomly sample and shuffle that layer for the starting positions.
  Every admitted player receives a unique cell with exactly the same minimum
  route length. Randomization must preserve this invariant.
- Let `F` be usable floor cells excluding the exit and `L` be the number of
  available cells in the chosen equal-distance layer. The admission cap is
  `min(8, floor(F / 20), L)`: no more than one player per 20 usable floor cells,
  bounded by the fair-start pool and the display/protocol limit of eight.
  Show the computed cap, floor count, and common starting distance.
- Try a bounded number of candidates for a useful multiplayer capacity. If no
  candidate supports at least two players, report generation failure and allow
  a retry; never substitute unfair or overlapping starts.

Eight, 20 floor cells per player, and a minimum starting distance of 12 are
proposed builder defaults. The game supports a variable roster rather than
three hardcoded participants. Finite memory and a readable DOS display justify
a documented upper bound.

## Lobby and adding players

- A phone opens the public HTTPS page, enters the room password and a short
  display name, and presses Join.
  The page receives a player number and a private controller token only after
  MAZE4 accepts the join. Names are bounded printable ASCII for DOS display.
- Distinct devices join as distinct players. A reload reconnects to the same
  player using its secure session cookie. Additional independent simulated
  controllers allow testing a larger roster with one physical phone.
- The PC lobby lists admitted players and the capacity. It offers start, new
  maze, collision-mode selection, and player removal before the race. A new
  maze resets readiness and is rejected if it cannot hold the existing roster.
- Starting requires at least two admitted players. Freeze admissions and the
  maze when the host starts; late joins receive a clear refusal. The host PC
  controls start/reset through MASM keyboard handling; internet controller
  pages control only their player. No public host-administration endpoint exists.
- A player can leave during the lobby. During a race, explicit leave becomes
  DNF and vacates the maze. A disconnected controller stops moving immediately
  after its short input lease expires; allow reconnection, with prolonged
  disconnection becoming DNF after a documented timeout.
- After results, the host can begin another lobby, invalidating stale movement
  commands from the previous race.

## Internet access and authentication

- Publish a public HTTPS controller address and a separate randomly generated
  room password on the PC. Proposed default: 12 unambiguous base32 characters
  (60 bits of entropy), generated with the host OS cryptographic RNG. Send it
  only to invited players. The address alone must not authorize joining.
- Submit the room password in a POST body over HTTPS; never put it in a URL,
  query string, browser storage, or access logs. Constant-time comparison and
  bounded authentication attempts are the bridge's security responsibilities.
  Password checks do not reserve a game slot: MASM must still accept admission
  within the capacity and phase rules before a controller becomes active.
- After acceptance, issue a distinct unpredictable 256-bit session credential
  per player using a Secure, HttpOnly, SameSite=Strict cookie scoped to this
  application. Keep credentials server-side/in cookies, not JavaScript local
  storage. Bind each session to the admitted MASM player and current room epoch.
  A request's supplied player number never overrides that binding.
- Require a valid player session for every movement, private state, heartbeat,
  and leave action. Check the exact configured HTTPS origin for state-changing
  browser requests and use CSRF protection. Disable cross-origin access; bound
  request sizes, polling concurrency, login attempts, and input rates.
- Reject invalid/expired credentials, stale room epochs, and non-increasing
  per-controller input sequence numbers. Do not let a late hold request undo a
  newer release. Duplicate join retries must return the existing result rather
  than allocate another slot. Bound pending authentication/join records too.
- Local host removal revokes the controller's credential as well as removing
  its MASM player. A new room/session rotates the password and invalidates old
  sessions; a browser reload can reconnect only within the existing session.
  Losing the cookie requires fresh admission, not claiming a known player name.
- The bridge listens on loopback behind the tunnel by default. Trust proxy
  metadata only from the configured local tunnel/proxy path; never trust an
  arbitrary client-supplied forwarding header for authorization or rate limits.
  Refuse a public plaintext-HTTP mode. Any localhost-only test exception must be
  explicit and must never be enabled by the public launcher.
- The serial TCP endpoint is loopback-only and has no public tunnel route.
  DOSBox never accepts arbitrary internet traffic, and the public route cannot
  reach files, shell commands, or host-management actions. Serve only the fixed
  controller assets and bounded API paths.
- A tunnel protects transport and supplies reachability; application password
  and session checks remain required. TLS terminates at the selected provider,
  so that provider is part of the transport trust boundary. No email accounts
  or third-party sign-in are required for players.
- The launcher may support an existing HTTPS origin and an optional temporary
  tunnel mode. Starting a public tunnel exposes the controller service to the
  internet; do so only as part of the user's authorized deployment/test step.
  Do not register a domain, change router rules, create a paid resource, or
  modify the user's existing tunnel configuration as a side effect.

The room-password method and tunnel provider are proposed builder defaults.
The requirement for authenticated internet play and a primarily MASM program
comes directly from the user's correction.

## Phone controls and transport

- Serve a responsive page with large Up/Down/Left/Right buttons, player identity,
  connection status, proximity warning, and finish/DNF status. Support touch,
  mouse, and keyboard. The PC displays the full maze and roster.
- A tap requests one movement step. A held button repeats at the game frame
  rate (one movement frame per two BIOS ticks, about 110 ms). Release, pointer
  cancellation, page hiding, navigation, and disconnect all clear held input.
- Use compact framed serial messages with a length/terminator and sequence or
  request identifiers. Bound packet sizes and parsing work; reject malformed
  fields and out-of-range players or directions. Acknowledge lobby actions so
  retries cannot create duplicate players or start the race twice.
- Preserve the newest held direction per player. Proposed internet default:
  refresh about every 150 ms while held and expire held input in MASM after
  roughly 750 ms without refresh; do not allow a backlog to move players after
  release. Measure delay/jitter during testing and document the chosen values.
  Preserve valid quick taps for a movement frame. All players' movement intents
  are evaluated together on each game frame.
- MAZE4 is authoritative. Python handles browser sessions and transport, never
  duplicates the game's rules or assigns positions independently. State returned
  by assembly supplies admission results, phase, warnings, and scores.
- MASM owns frame-based input expiry and the prolonged-disconnect/DNF timer;
  propose 30 seconds without authenticated heartbeats before DNF. The bridge
  forwards validated input/heartbeat events and cannot substitute browser time
  for the game clock. On bridge loss, DOSBox expires all held movement and
  continues to process the local quit control.
- Configure DOSBox COM1 as a transparent nullmodem client to a loopback TCP
  listener owned by the bridge. Public HTTPS routes only to the authenticated
  HTTP bridge. Host controls remain in the MASM PC interface.
- Provide a single launcher that starts the bridge and DOSBox using a dedicated
  config, without editing the user's global DOSBox settings. It cleans up its
  own child processes and temporary sockets when stopped.
- ADB is a test-automation tool only: it may open the phone browser, capture its
  screen, and tap real controller buttons. The acceptance test uses the public
  HTTPS address with no `adb reverse`, port forwarding, or ADB data transport.
  Normal users simply open that address and authenticate. No Android app install
  or private phone data access is needed.
- Internet jitter does not change the simultaneous movement model: all current
  valid inputs are sampled together per MASM frame. Use bounded queues, session
  epochs, and sequence numbers; do not replay delayed movement bursts. Measure
  response time and document that internet latency is not perfectly equalized.

Exact protocol encoding, HTTP interaction style, port defaults, and module
boundaries are left to the builder. Document these decisions in the repository.

## Movement, proximity warnings, and collisions

- Walls reject moves. Finished/DNF players leave the board. Multiple arrivals
  at the shared exit are allowed in the same frame.
- Calculate the minimum shortest walkable path distance from each active player
  to every other active player, using a bounded BFS. Show **CAUTION** when the
  minimum is strictly below 5 moves (3–4) and **DANGER** below 3 moves (1–2).
  Otherwise show SAFE; no other active player also means SAFE. A nearby player
  behind a wall with no short route must not produce a false path warning.
- Retain MAZE3's mode: reject colliding moves and add 3.0 seconds to both players
  once per contact episode. Clear the contact latch after the episode ends.
- Add **rotating priority** as the default alternative: when two moving players
  request the same empty cell, the player earlier in the current circular
  priority order moves and the other yields without a time penalty. Advance
  priority each frame so the same player does not always win ties.
- A stationary player's occupied cell cannot be taken. Head-on swaps are
  rejected for both players. Propagate cancellations through blocked chains
  until no overlap can result; do not let arbitration push or teleport anyone.
- Rotating priority handles contention fairly but does not promise to solve a
  deadlock in a one-cell corridor; players can back away. This is a limitation
  to document and test, not an implicit automatic relocation rule.

Thresholds and rotating priority are proposed defaults because the request did
not specify a threshold or the second collision technique.

## Timing, scores, and presentation

Retain MAZE3's elapsed time, movement steps, penalties, and adjusted finish
score. Use a 32-bit accumulated BIOS tick clock with midnight rollover handling.
Freeze a finisher's time at the exit. When every admitted player is finished or
DNF, show the best adjusted score, all tied winners, and every player's result;
DNF players cannot win. Display up to eight distinct player symbols and colors
with names in the roster, plus warnings, current mode, and race phase.

## Deliverables

- `assignment-3/MAZE4.ASM`, supporting includes if useful, and a built executable.
- A minimal Python authentication/transport launcher, browser assets, dedicated
  DOSBox config, optional HTTPS tunnel connector instructions, and repeatable
  build command using the supplied MASM and LINK.
- `assignment-3/README.md` with PC startup, authenticated internet play, room
  password/session lifecycle, HTTPS/tunnel setup, ADB-only testing instructions,
  game rules, capacity/fairness definitions, collision modes, latency and tunnel
  limitations, MASM/bridge responsibility boundaries, and actual verification.
- Repeatable tests that exercise the assembly in installed DOSBox and the
  controller bridge. Diagnostic scripts, downloads, logs, and intermediate build
  files stay under the project's `.scratch/`; requested source and tests remain
  in their intended repository locations.

## Verification and acceptance

1. Assemble/link with the supplied MASM/LINK in installed DOSBox 0.74-3; require
   zero assembler errors and inspect the actual rendered lobby/game/results.
2. Execute the assembly generator for many seeds; independently BFS-check outer
   walls, connectivity, unique valid starts, equal shortest distances, density
   cap, and variation of both maze and start positions.
3. Exercise real assembly collision scenarios: same target, occupied target,
   head-on swap, blocked chains, simultaneous exits, priority rotation, contact
   latching, penalties, score ties, and disconnected/DNF exclusions.
4. Test warning boundaries (2, 3, 4, 5), wall-separated proximity, finishers,
   and the no-other-player case in the actual assembly code.
5. Test joins/removals/reloads, full capacity, race-time rejection, held input,
   quick taps, release, stale input expiry, malformed messages, loss/reconnection,
   and controller authorization. Verify one controller cannot move another and
   unauthenticated requests cannot consume player slots or reveal private state.
   Test wrong passwords, expired/revoked cookies, CSRF/origin rejection, bounded
   failed logins, stale epochs, out-of-order input/release, and room reset.
6. On the attached Android phone, open the public HTTPS page, authenticate,
   join, tap and hold directional buttons, and compare game-reported positions
   before/after. Verify release stops movement and wall moves are rejected.
   ADB may automate taps/screenshots but must carry no game traffic; verify no
   reverse/forward mapping is used. Cover at least a public-address test with
   PC and phone on different internet connections, ideally phone mobile data.
   Do not change the phone's mobile-data/Wi-Fi settings without user direction;
   if that separate-network test cannot be performed, report it as untested.
   Simulate additional independent controllers to prove more than three players
   work together. One physical phone does not establish multi-phone hardware
   behavior; report simulated and physical coverage separately.
7. Check the ordinary launcher without test-only instrumentation. Preserve
   evidence of successful build, automated rule checks, actual phone input,
   and rendered PC/phone screens; clearly report any untested requirement.
8. Test increased internet latency, jitter, brief outage, bridge/tunnel loss,
   reconnection, held-input expiry, and the prolonged DNF timeout. Verify local
   host quit still works and no public route can reach COM1 or host controls.

## Initial design-stage environment observed on 2026-11-12

- Supplied DOS tools: MASM 5.10 and LINK 3.65, as recorded by `dos-tools/README.md`.
- Installed emulator reports DOSBox 0.74-3.
- Verified installed `cloudflared` reports version 2026.10.7; Python distribution
  `cloudflare` reports version 5.10.0. Reuse these installations where needed.
- ADB lists one attached device and successfully reports model CPH2381,
  Android 14. Desktop X display `:0` responds to `xdpyinfo`.
- No gameplay or phone movement test has run for this proposed implementation.
- No public HTTPS tunnel has been started and no internet authentication or
  separate-network gameplay test has run.

## Implementation record

Implementation uses only the supplied `dos-tools` assembler/driver/linker
binaries. Fresh builds showed that the supplied MASM compatibility driver
invokes the supplied ML executable and that LINK identifies as 5.31.009; the
initial toolchain README version descriptions were stale. See the delivered
README and VERIFICATION for current commands, source responsibilities, the
19 passing automated tests, real phone evidence, and Cloudflare timeout limits.
