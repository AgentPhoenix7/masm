# MAZE4 — MASM maze race with internet phone controllers

One PC runs `MAZE4.EXE` in DOSBox. Each player opens the HTTPS controller page on
an Android/iOS phone, tablet, or browser, enters the room password, and controls
one player. Phones can use mobile data or another internet connection. The PC
screen displays the maze; the phone is a movement controller.

## Install dependencies

The supplied launcher targets **Linux** and expects DOSBox at
`/usr/bin/dosbox` and cloudflared at `/usr/bin/cloudflared`. Use a graphical
desktop for normal play. On the host PC, install:

| Dependency | Purpose |
| --- | --- |
| Python 3.10 or newer | Build script, controller bridge, launcher and Python tests |
| DOSBox 0.74-3 | Run the supplied MASM/LINK tools and the DOS game |
| `cloudflared` CLI | Public HTTPS address when using `--internet` |
| Supplied `dos-tools/` directory | Required assembler/linker; keep it alongside `assignment-3/` |

The Python code uses only the standard library: **no pip packages are required**.
The `python-cloudflare`/`cloudflare` Python SDK is separate from the
`cloudflared` executable and is not used by this project. Cloudflared is optional
for localhost tests or an existing HTTPS proxy supplied through `--origin`.

### Garuda / Arch Linux

Install from the distribution repositories:

```bash
sudo pacman -Syu --needed python dosbox cloudflared
```

Both [DOSBox](https://archlinux.org/packages/extra/x86_64/dosbox/) and
[cloudflared](https://archlinux.org/packages/extra/x86_64/cloudflared/) are in
Arch's Extra repository; an AUR helper is not needed for these packages.

### Ubuntu 22.04+ / Debian 12+

Install Python, DOSBox and the tools needed to add Cloudflare's repository:

```bash
sudo apt-get update
sudo apt-get install -y python3 dosbox curl ca-certificates
```

Install cloudflared from Cloudflare's signed stable repository:

```bash
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt-get update
sudo apt-get install -y cloudflared
```

These repository/key commands follow the
[official Cloudflare package instructions](https://pkg.cloudflare.com/).
The launcher creates the temporary tunnel itself; Quick Tunnel mode requires
no Cloudflare login, API token, domain, or system service. See
[Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/).

### Check the installation

From the repository root:

```bash
python3 --version
/usr/bin/cloudflared --version
test -x /usr/bin/dosbox && echo 'DOSBox executable found'
test -f dos-tools/MASM.EXE && test -f dos-tools/ML.EXE \
  && test -f dos-tools/LINK.EXE && echo 'Supplied DOS tools found'
```

If a dependency was installed in a different location, adjust the executable
paths in `build_maze4.py` and `run_maze4.py` before running. After these checks,
continue with **Build and run** below. Phones need only a current web browser
and internet access.

### Optional tools for verification

The Python/DOSBox test suite uses `unittest` from Python's standard library.
Install Node.js to run the separate controller JavaScript checks:

```bash
# Garuda / Arch
sudo pacman -Syu --needed nodejs

# Ubuntu / Debian
sudo apt-get install -y nodejs
```

The physical Android acceptance script additionally uses ADB, KDE Plasma's
`qdbus6`, `xdotool`, and Spectacle. It is tailored to a KDE Plasma desktop with
X11/XWayland input automation. On Garuda/Arch, install its tools with:

```bash
sudo pacman -Syu --needed android-tools qt6-tools xdotool spectacle
```

For that optional test, enable USB debugging on the Android phone, connect it
by USB, accept the debugging authorization prompt, and check the connection:

```bash
adb devices -l
```

Use the serial shown with status `device` when invoking the acceptance script.
Pass `--adb "$(command -v adb)"` to use the distro-installed executable; the
script's default path is `/opt/android-sdk/platform-tools/adb`. ADB automates
the phone UI during testing; movement requests still travel over public HTTPS.

## Build and run

From the repository root:

```bash
python3 assignment-3/build_maze4.py
python3 assignment-3/run_maze4.py --internet
```

The build uses **only the supplied binaries in `dos-tools/`**, mounted as `T:`
in the installed DOSBox. The supplied `MASM.EXE` is a compatibility driver that
invokes the supplied `ML.EXE`; the supplied `LINK.EXE` links the DOS executable.
No downloaded or host-native assembler/linker substitutes are used. Build logs
and intermediate OBJ files go to `.scratch/maze4-phone/build/`; the fresh final
executable is copied to `assignment-3/MAZE4.EXE`. The launcher rebuilds when a
source/include is newer than that executable.

For a manual build in DOSBox, mount `assignment-3` directly as C and the
repository's `dos-tools` directory as T. Set `PATH T:\;Z:\` so the MASM driver
can find the supplied ML executable, then use:

```dos
T:\MASM MAZE4.ASM;
T:\LINK MAZE4.OBJ;
MAZE4.EXE
```

For phone play, use the launcher: it creates the authenticated bridge and the
COM1 link before starting DOSBox. Running the EXE alone is useful for viewing
the interface but cannot receive internet phone inputs.

The launcher prints a temporary `https://....trycloudflare.com` address and a
12-character room password. Give both to the invited players. The address and
password are separate; knowing only the address does not authorize joining.
The password is also displayed in DOSBox. Players enter a printable ASCII name
of 1–8 characters, join, and press **Ready**. The host presses **Space** on the
PC when at least two players are ready.

Once installed, `cloudflared` is reused by the launcher. No Cloudflare account,
Cloudflare Python SDK calls, API key, router port forwarding, Android app,
USB connection, or ADB forwarding is required for this temporary tunnel mode.
The local Python bridge binds only to `127.0.0.1`. The HTTPS tunnel exposes its
fixed controller routes; the serial TCP port is not exposed.

Press Esc in DOSBox or Ctrl+C in the launcher to stop its own DOSBox/tunnel and
bridge processes. It does not install an autostart entry or service and does
not edit the global DOSBox configuration.

A temporary tunnel has a changing address and no uptime guarantee. For an
existing stable HTTPS proxy/tunnel pointed at `http://127.0.0.1:8080`, use:

```bash
python3 assignment-3/run_maze4.py --origin https://your-game.example
```

The origin must match the actual phone address exactly. Named tunnel/account/
domain administration is outside this launcher. Source documentation:
[Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/).
The bridge uses bounded polling and POST requests; it does not depend on SSE.

For localhost-only automated checks, there is an explicit isolated mode:

```bash
python3 assignment-3/run_maze4.py --local-test --headless
```

This mode permits a non-Secure test cookie only on localhost. It cannot be
combined with internet mode or a public plaintext origin.

## PC controls

| Key | Action |
| --- | --- |
| Space | Start the lobby when at least two players are present and all are ready |
| M | Toggle collision mode in the lobby |
| R | Generate another maze in the lobby; all players must ready again |
| N | New room after results or in the lobby; rotates the password and revokes old sessions |
| 1–8 | Remove that player; during a race, mark an active player DNF |
| Tab | Toggle maze/scoreboard |
| Esc | Quit and restore the original keyboard interrupt vector |

Phone controls support taps, holds, mouse pointers, WASD, and arrow keys. A tap
is latched in MASM for a movement frame even if release arrives before that
frame. A held direction refreshes every 150 ms. Release, lost pointer capture,
page hiding, and disconnect stop held movement. There is a short lease as a
fallback when a release packet cannot arrive.

## Rules and fairness

- MAZE4 generates a connected 17×61 maze at runtime by randomized depth-first
  carving plus loop openings. The outer boundary is closed. The exit is chosen
  randomly; normal play seeds the generator from the BIOS clock.
- BFS from the exit computes **shortest walkable path length**, not straight-line
  distance through walls. Starts are distinct, randomly sampled/shuffled cells
  on the same distance layer, at least 12 moves from the exit.
- With `F` floor cells excluding the exit and `L` available cells in the selected
  distance layer, admission is capped at `min(8, F // 20, L)`. This is a variable
  roster, with a finite maximum of eight and at least 20 usable cells per player.
  The PC shows the actual cap, floor count, and equal starting distance.
- The generator tries at most 64 candidates and keeps the best capacity. A
  generation with fewer than two starts is reported; R can retry. Regeneration
  cannot silently evict an existing roster or assign unequal starts.
- Every movement frame samples all players together. A frame is two BIOS ticks,
  about 110 ms. Walls block moves; finished/DNF players vacate the maze.
- Proximity warnings use bounded BFS between active players: **DANGER** at 1–2
  walkable moves, **CAUTION** at 3–4, **SAFE** otherwise. Walls can make nearby
  coordinates safe if the shortest route is longer. A lone player is SAFE.

Two selectable collision techniques are implemented:

1. **Block + penalty** (default, same rules as MAZE3): same-target or head-on
   contacts block movement and add
   3.0 seconds to each player once per contact episode. Continuing the same
   contact does not repeatedly charge; separating/releasing ends the episode.
2. **Rotating priority**: when moving players request the same empty
   cell, the earlier player in the circular priority order proceeds and the
   other yields, without a time penalty. The priority cursor advances each
   frame to the next racing player, skipping empty, finished and DNF slots.
   Stationary occupants cannot be displaced; head-on swaps are blocked.

Both techniques propagate cancellations through blocked chains so a rejected
move cannot leave two players occupying one cell. Simultaneous arrivals at the
shared exit are allowed. In **both modes**, head-on players must back away to
let the other pass; holding toward each other keeps both blocked. In the
default mode, each receives +3.0 seconds when the contact episode starts,
without repeatedly charging for holding the same contact. This is a deliberate
blocking rule, not a frozen game. Press Tab to inspect penalties, or check the
phone's Penalty value. Press M in the lobby to change modes; the PC displays the
current choice. Rotating priority is useful for junction contention and
deliberately adds no penalty. Neither mode automatically swaps players.

The best score is **finish time + collision penalties**. MASM keeps 32-bit
elapsed/finish/penalty/step values and handles BIOS midnight rollover. A
finisher's time freezes at the exit. The result includes all tied winners;
DNF players cannot win. Tab shows each player's steps, penalty, score, status,
and warning.

## Authentication and disconnect behavior

The bridge generates room passwords with the OS cryptographic RNG (12 base32
characters = 60 random bits). After MASM accepts admission, the browser receives
an independent 256-bit `Secure; HttpOnly; SameSite=Strict` session cookie. The
cookie is not placed in URLs or JavaScript local storage. A separate
non-credential join-attempt ID is kept in session storage so reloading after a
lost join response can retry the same admission; the room password is still
required. Every private state,
movement, heartbeat, readiness and leave request requires that session. Movement
uses the player bound to the session; a submitted player number cannot control
someone else. Mutations also check the exact Origin and a per-session CSRF token.

The bridge serves only fixed controller assets/API paths, limits request bodies
and worker count, rate-limits joins and authenticated requests, and does not
publish host administration. It deliberately does not trust arbitrary forwarded
IP headers. Room passwords/cookies are not written into access logs. A new room
or host removal invalidates the relevant controller credentials. Reloading the
page resumes a valid cookie; losing it requires fresh admission.

MASM owns input sequence checks, frame scheduling, and the timers. A held input
expires after **14 BIOS ticks** (about 0.77 s) without refresh. During a race,
**546 ticks** (about 30 s) without an authenticated heartbeat marks the player
DNF. Lobby players remain until they leave or the host removes them, allowing
password-manager prompts and interruptions during setup. A bridge/tunnel loss
cannot keep a player moving indefinitely; local host quit remains available.
If the tunnel process stops after startup, the PC race continues so MASM can
expire inputs and mark disconnected players DNF. Timed-out players retain
authenticated terminal-status access; explicit leave/removal revokes it.

Internet delay is not equalized among players. Equal starting distance is a
maze fairness guarantee, not a promise of identical network latency. HTTPS
terminates at the chosen tunnel/proxy provider, which is part of the transport
trust boundary. Application authentication remains required independently.

## Source responsibilities

| File | Responsibility |
| --- | --- |
| `MAZE4.ASM` | 8086 model, game arrays/constants, module composition |
| `M4CORE.INC` | Random maze, BFS, fair starts, intents, both collision algorithms, warnings, scoring |
| `M4SER.INC` | UART/framing, authoritative joins/readiness/ownership, input sequences/leases, disconnects, state snapshots, race clock/lifecycle |
| `M4UI.INC` | PC rendering, host controls, keyboard interrupt install/restore |
| `phone/protocol.py` | TCP/COM1 transport and binary-state decoding |
| `phone/bridge.py` | Browser authentication, cookies, CSRF/origin checks and fixed HTTP routes |
| `phone/controller.*` | Phone interface and input transmission |
| `build_maze4.py`, `run_maze4.py`, `PHONE4.CONF` | Supplied-tool build and isolated runtime/process setup |

All maze/player/race behavior remains in **MASM**. Python and JavaScript do not
implement movement, maze generation, collision rules, capacity selection,
proximity calculation, race timing, or winner selection. TLS and cryptographic
browser authentication use host facilities rather than hand-written 8086 crypto.

## COM1 protocol

DOSBox is a transparent nullmodem client to a loopback listener, 115200 baud,
8N1. Each frame is `:` followed by uppercase hex of payload + one XOR checksum
byte, then LF. The MASM receiver accepts at most 96 decoded bytes and resets on
invalid/oversized input; a new `:` resynchronizes parsing. Snapshot payloads are
240 bytes. The transmit queue is bounded and non-blocking.

Requests start with `<opcode:u8, request:u16, room_epoch:u16>` in little endian.

| Opcode | Extra payload |
| --- | --- |
| 1 | 12-byte room password for local display; loopback bridge setup only |
| 2 | 8-byte space-padded name; request ID is the stable, idempotent owner ID |
| 3 | slot:u8, owner:u16, maze_generation:u16, sequence:u16, direction:u8, tap:u8 |
| 4 | slot:u8, owner:u16 — authenticated heartbeat |
| 5 | slot:u8, owner:u16 — leave |
| 6 | slot:u8, owner:u16, ready:u8 |

Directions are 0 idle, 1 up, 2 down, 3 left, 4 right. Input sequence deltas must
be positive in the 16-bit modular window; stale epochs/generations/owners are
rejected. ACK `0x81` includes request ID, current room epoch, status and slot.
Status 0 means accepted; 1 race started; 2 capacity reached; 3 invalid request;
4 stale room. Snapshot `0x82` contains a single consistent header and all eight
player records. Only a controller's own record is returned over HTTP; internal
owner IDs never become browser credentials.

## Verification

Run from the repository root:

```bash
python3 -m unittest discover -s tests/maze4 -p 'test_*.py' -v
node --check assignment-3/phone/controller.js
node tests/maze4/test_controller.cjs
```

The socket tests require local TCP access. `test_core.py` runs actual generated
8086 code in installed DOSBox for 128 seeds and uses an independent Python BFS
oracle. `test_lifecycle.py` runs assembly readiness, lease, DNF, midnight, and
warning-boundary cases. `test_runtime.py` checks actual DOSBox COM1 admission,
capacity, idempotency, ownership, readiness and stale requests. HTTP tests check
cookie flags, origin/CSRF enforcement, authorization, stale requests and limits.
`test_collisions.py` checks the default penalty, sparse-roster priority rotation,
eight-player collision chains, head-on recovery, and shared-exit completion.

For a credential-free host state trace during phone testing:

```bash
SDL_VIDEODRIVER=x11 python3 assignment-3/run_maze4.py --internet --state-trace
```

The trace is `.scratch/maze4-phone/run/state.json`. X11 is useful for synthetic
host key tests on KDE/Wayland; the default launcher supports normal physical
keyboard play. ADB may open the public HTTPS page and tap its buttons. **Do not
use `adb reverse` or HTTP forwarding for this acceptance test.** ADB is test
instrumentation, never a player transport.

For the opt-in physical-phone acceptance run, with the phone available:

```bash
python3 tests/maze4/phone_acceptance.py --device YOUR_ADB_SERIAL --adb "$(command -v adb)"
```

This starts its own temporary test room, authenticates the phone via its visible
browser UI, adds three independent clients, tests movement and tunnel loss,
and closes its own processes. It does not change Wi-Fi/mobile-data settings.
Android UI inspection needs a temporary on-device XML dump; the test pulls it
into project scratch and removes only that dump afterward. It does not use
phone browser DevTools. Run this separately from an existing game on port 8080.

Current verification results and evidence, including external-service test
limitations, are recorded in `VERIFICATION.md`.
