# run_maze4.py — starting, coordinating, and stopping the MAZE4 system

Source: [run_maze4.py](../run_maze4.py).

This guide explains the checked-in launcher from the beginning. It assumes basic Python and the registers, memory, I/O,
loops, and subroutines you encounter with an 8085. Knowledge of any other maze program is unnecessary. The commands and
traces below explain intended execution; writing this guide did not start DOSBox, a tunnel, or a phone session.

The supporting guides are [build_maze4.md](build_maze4.md), [bridge.md](bridge.md), [protocol.md](protocol.md), and
[MAZE4.md](MAZE4.md). Each is a companion reference, not a prerequisite for this explanation.

---

## 1. What problem does this file solve?

MAZE4 needs several cooperating pieces:

```text
MASM executable → DOSBox COM1 → Python transport → Python HTTP bridge
                                                        ↑
                                               phone browser requests
```

For internet play, an HTTPS tunnel also forwards requests into the bridge. Starting those pieces in the wrong order
could lose the serial connection, advertise an unconfigured room, or leave child processes behind. The launcher
establishes the order and owns cleanup.

## 2. Who decides the game rules?

The MASM executable owns maze generation, positions, legal movement, collisions, penalties, race timing, and results.
The launcher does not calculate any of them.

An 8085 analogy is a laboratory setup containing an I/O device and a monitor. Connecting the monitor and powering the
device does not transfer the device's control program into the monitor. Likewise, Python connects and supervises this
system while assembly remains authoritative about the game.

## 3. Processes, threads, and objects are different things

| Item | What it is here |
| --- | --- |
| Launcher | Main Python process |
| DOSBox | Child operating-system process |
| cloudflared | Optional child operating-system process |
| Serial receiver | Background thread inside Python |
| HTTP service | Background thread, plus request threads, inside Python |
| Room maintenance | Background thread inside Python |
| Tunnel reader | Optional background thread inside Python |
| `App` | Shared Python object holding controller/room state |

Threads share Python objects; DOSBox and cloudflared have separate address spaces.

## 4. The imports and their jobs

| Import | Use in the launcher |
| --- | --- |
| `argparse` | Parse and validate command-line options |
| `json` | Write optional state snapshots |
| `re` | Recognize a specific tunnel banner URL |
| `signal` | Turn SIGTERM into the normal interruption path |
| `subprocess` | Create, poll, terminate, and wait for child processes |
| `sys` | Set program exit status and write error messages |
| `threading` | Run services concurrently and coordinate readiness |
| `time` | Polling delay and monotonic startup deadline |
| `ExitStack` | Register cleanup dynamically |
| `Path` | Resolve paths and read/write configuration and logs |

## 5. The imported project interfaces

```python
from build_maze4 import SOURCES, build, environment
from phone.bridge import App, ControllerServer
from phone.protocol import SerialLink, TransportError
```

`SOURCES` lists assembly inputs; `build()` produces the executable. `environment()` supplies project-local
temporary-directory settings. `SerialLink` connects the Python side to DOSBox's emulated COM1. `App` adapts
authenticated browser requests to that link. `ControllerServer` serves HTTP on loopback. `TransportError` identifies
expected transport failures.

## 6. `HERE` makes paths independent of the working directory

```python
HERE = Path(__file__).resolve().parent
```

`__file__` is the launcher's filename. `resolve()` obtains an absolute, resolved path; `parent` selects its containing
`assignment-3` directory.

Consequently, the executable, source files, and configuration are selected relative to the script's location. Changing
the shell's current directory does not intentionally change them. Running a different copy of the script selects that
copy's project paths.

## 7. A map of every definition in this file

```text
QuickTunnelReady
    __init__
    feed
monitor_game
main
    stop_process
    interrupt
    read_tunnel       [defined only in internet mode]
    trace_state
    tunnel_outage
```

There are also a default no-op lambda and a state-readiness lambda. Both are explained below.

## 8. `QuickTunnelReady`: construction and persistent state

The class remembers two independent observations:

```python
self.candidate = None
self.connected = False
```

`candidate` will hold the allocated public URL. `connected` records whether any supplied line contained the registration
text. Neither field is reset by later unrelated output. The object belongs to one tunnel launch; it is not shared across
successive launcher runs.

`self` means the newly created instance. `QuickTunnelReady.__init__` accepts no additional arguments and returns implicitly.

```python
readiness = QuickTunnelReady()
```

After this statement, `readiness.feed(...)` can accumulate evidence. This is similar to storing state bytes between
calls to an assembly routine. The fields survive a single call to `feed`; local variables in `feed` do not. There is no
network operation in construction.

## 9. `feed(self, line)` recognizes the allocated banner

The regular expression is:

```python
r"\|\s*(https://(?!api\.|www\.)[a-z0-9-]+\.trycloudflare\.com)\s*\|"
```

It searches anywhere in the line for a vertical bar, optional whitespace, one HTTPS hostname, optional whitespace, and
another vertical bar. The parentheses capture the URL without the surrounding banner characters. `match.group(1)`
extracts that captured URL. The raw-string prefix preserves regex backslashes for the regex parser.

The hostname label accepts lowercase letters, digits, and hyphens. The suffix must be exactly `.trycloudflare.com` in
this pattern. The negative lookahead excludes labels beginning `api.` or `www.`; the remaining character pattern also
prevents extra dotted subdomains.

Thus a generic documentation URL is not accepted merely because it mentions the same service. A plain unboxed URL also
fails this expression. Uppercase host letters and a trailing path inside the bars do not match. These restrictions
describe the parser, not all legal HTTPS URLs.

## 10. Combine banner and registration evidence, with worked traces

```python
if match:
    self.candidate = match.group(1)
if "Registered tunnel connection" in line:
    self.connected = True
return self.candidate if self.connected else None
```

Before registration, a banner stores the candidate but returns `None`. After registration, a remembered candidate can be
returned. Registration may appear before or after the banner. The return value is therefore a URL string or `None`, not
a Boolean.

```text
initial: candidate=None, connected=False
line 1: | https://race-example.trycloudflare.com |
        candidate=URL, connected=False, return None
line 2: some unrelated diagnostic
        candidate=URL, connected=False, return None
line 3: Registered tunnel connection ...
        candidate=URL, connected=True, return URL
```

Line 3 causes the reader to install the public origin in the bridge. The words after the registration substring are not
parsed.

```text
line 1: Registered tunnel connection ...
        candidate=None, connected=True, return None
line 2: | https://race-example.trycloudflare.com |
        candidate=URL, connected=True, return URL
```

The two observations need not occur on the same line. If later lines contain another matching banner, the class updates
its candidate. However, the tunnel reader installs the origin only before its Event is set. That extra guard prevents
repeated origin changes after initial readiness.

It proves that the consumed output contained a banner-shaped URL and the registration substring. It does not send an
HTTP request to the public URL. It does not check DNS, a phone's network, certificate presentation, or that the
registration message describes a connection still alive.

A log-format change can prevent detection even if cloudflared is working. Conversely, detection can be followed
immediately by a tunnel exit. The later process monitor detects a child exit, with the limits explained below.

## 11. `monitor_game` and its full signature

```python
def monitor_game(game, tunnel=None, *, on_outage=lambda: None, on_tick=None):
```

`game` is the DOSBox process-like object. `tunnel` defaults to `None`, meaning no tunnel is monitored. The `*` makes
`on_outage` and `on_tick` keyword-only arguments. The default `lambda: None` is a callable taking no arguments and doing
nothing. `on_tick=None` disables periodic callback work. This helper does not create or terminate either process itself.

## 12. Polling is a question, not a wait for completion

```python
while game.poll() is None:
```

`poll()` checks whether the child has ended. It returns `None` while the child is running, including a running child
that has not recently drawn a frame or produced a state packet. An integer means the process has ended and records its
return code.

The [Python subprocess reference](https://docs.python.org/3/library/subprocess.html#subprocess.Popen.poll) documents
this behavior. The launcher tests process lifetime, not the health of the assembly loop.

## 13. The monitor loop: one outage report, continued play, and callbacks

The loop starts with `reported = False`. On each iteration it evaluates:

```python
if tunnel is not None and tunnel.poll() is not None and not reported:
    on_outage()
    reported = True
```

The condition uses short-circuit evaluation. No method is called on a `None` tunnel. Even if the child remains stopped,
the message callback runs only once.

After the outage callback, the loop continues while DOSBox is running. There is no restart, reconnection attempt, room
reset, or automatic race exit.

The assembly side expires held inputs and handles disconnected players. Python does not invent replacement movement
during an outage. The already running PC race can therefore continue.

This test detects a terminated cloudflared process. An alive process with an unusable internet connection does not
satisfy it. The launcher has no separate end-to-end tunnel health probe.

```python
if on_tick:
    on_tick()
time.sleep(0.2)
return game.returncode
```

The callback runs once per active monitor iteration, when supplied. The sleep adds roughly 0.2 seconds between
iterations; callback duration and scheduling can make intervals longer. Once DOSBox ends, the helper returns its process
return code. If DOSBox has already ended on entry, neither callback runs.

## 14. `main()`: command-line modes, options, and defaults

```python
parser = argparse.ArgumentParser(description=__doc__)
mode = parser.add_mutually_exclusive_group(required=True)
```

The module docstring becomes the help description. Exactly one mode is required: internet, existing origin, or local
test. Missing a mode or combining modes is an argument error. `parse_args()` also handles `--help` before game startup.

Command examples in this guide assume a shell in `assignment-3`. They are explanatory commands, not evidence that those
modes were exercised.

| Option | Value stored | Meaning |
| --- | --- | --- |
| `--internet` | `args.internet=True` | Launcher creates a temporary public HTTPS tunnel |
| `--origin https://host.example` | String in `args.origin` | Use an already configured HTTPS reverse proxy |
| `--local-test` | `args.local_test=True` | Use explicit localhost HTTP testing |

The two `store_true` flags otherwise default to `False`. The origin string otherwise defaults to `None`. `--origin` does
not start or configure the external proxy. `--local-test` cannot be combined with `--internet` in this parser.

| Option | Default | Effect |
| --- | --- | --- |
| `--http-port` | `8080` | Requested loopback HTTP listening port |
| `--serial-port` | `8766` | Requested loopback DOSBox transport listening port |
| `--headless` | `False` | Dummy SDL video/audio for the game process |
| `--rebuild` | `False` | Force assembly/link before startup |
| `--state-trace` | `False` | Write reduced MASM state snapshots during monitoring |

The port options use `type=int`. This checks integer conversion; it is not a custom range validation. Socket
creation/binding can still reject an unusable port.

## 15. Paths created by the launcher

```python
run_dir = HERE.parent / "build" / "maze4" / "run"
run_dir.mkdir(parents=True, exist_ok=True)
exe = HERE / "MAZE4.EXE"
```

In this checkout the run directory is `/home/agntdrgn/Projects/masm/build/maze4/run`. `parents=True` creates
missing parent directories. `exist_ok=True` permits an already existing directory. The launcher does not remove
artifacts from earlier runs first.

## 16. Rebuild decisions and short-circuit evaluation

The rebuild condition is:

```python
args.rebuild
or not exe.exists()
or any((HERE / name).stat().st_mtime > exe.stat().st_mtime for name in SOURCES)
```

Any true part calls `build()` once. The source tuple contains `MAZE4.ASM`, `M4CORE.INC`, `M4SER.INC`, and `M4UI.INC`.
The comparison asks whether a source modification time is strictly newer than the executable modification time.

If `--rebuild` is present, later terms are not evaluated. If the executable is absent, source-versus-executable
comparisons are skipped. Otherwise `any(...)` stops at its first newer source.

Equal timestamps do not force rebuilding. The test is not a content hash or a complete dependency scanner. Changes to
Python, the DOSBox configuration, or build-tool binaries are outside `SOURCES` and do not directly trigger this
condition. A missing source encountered during `stat()` raises an error.

## 17. What the imported build does

The build helper stages assembly inputs under `build/maze4/assembly`, uses supplied MASM/ML/LINK DOS executables through a
build DOSBox, checks the resulting executable and build report, and copies `MAZE4.EXE` back beside the launcher.

This is a synchronous call: game transport setup waits for it to finish. The build DOSBox is separate from the game
DOSBox created later. The launcher's `stop_process` helper does not own the build child. The build helper owns its own
subprocess call and timeout. See [build_maze4.md](build_maze4.md) for the complete implementation.

## 18. `stop_process(proc)`: bounded cleanup and child ownership

```python
if proc.poll() is None:
    proc.terminate()
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(2)
```

The argument is the specific `Popen` object registered for cleanup. Already ended children need no termination request.
`wait(5)` waits up to five seconds after the graceful request.

On the intended POSIX host, `terminate()` sends SIGTERM; `kill()` sends SIGKILL. Neither call by itself is the same as
waiting for the child to be reaped. `wait()` obtains its ending status and completes that lifecycle work.

The first timeout triggers the stronger kill and a second bounded wait. The second timeout is not caught inside this
helper. Termination races and other OS errors are also not swallowed here. See the [Python process lifecycle
reference](https://docs.python.org/3/library/subprocess.html#subprocess.Popen.terminate) for the documented platform
differences.

The callback receives the DOSBox object created by this launcher and, in internet mode, its cloudflared object. There is
no process-name search, `pkill`, or system-wide shutdown.

The code does not create a separate process group or recursively kill an arbitrary descendant tree. It targets those
direct child process objects. An existing reverse proxy supplied through `--origin` is not a child and is never
registered for termination. This distinction is part of interpreting the printed ownership message.

## 19. `interrupt(*_)`, signals, and installation order

```python
def interrupt(*_):
    raise KeyboardInterrupt

signal.signal(signal.SIGTERM, interrupt)
```

Python calls a signal handler with arguments describing the signal/frame. `*_` accepts and deliberately ignores them.
Raising `KeyboardInterrupt` routes SIGTERM through stack unwinding. The ordinary Ctrl+C/SIGINT behavior is not replaced
here. The previous SIGTERM handler is not saved or restored by `main()`.

Signal-handler installation happens after the possible build. The `ExitStack` is entered after handler installation.

Therefore the launcher cleanup stack concerns resources acquired inside the following `with` block. It does not
retroactively manage resources belonging to `build()`. Ctrl+C still reaches the outer `KeyboardInterrupt` handler when
applicable.

For the normal command-line use, `main()` runs in the main Python thread. Calling it from a worker thread would conflict
with Python's signal API.

## 20. `ExitStack` is a dynamic cleanup list

```python
with ExitStack() as stack:
```

Resources are acquired one at a time and immediately given cleanup callbacks. Leaving the block normally, by `return`,
or through an exception unwinds the registered actions in reverse order.

The [Python ExitStack reference](https://docs.python.org/3/library/contextlib.html#contextlib.ExitStack) defines this
reverse registration order. This is analogous to undoing a sequence of setup operations backwards, while accounting for
only the operations that actually completed.

## 21. Start the serial listener before DOSBox

```python
link = SerialLink(args.serial_port)
stack.callback(link.close)
```

The imported constructor binds a TCP listener to `127.0.0.1`, starts its receiving thread, and records its actual bound
port. Its default is 8766, though the launcher explicitly passes the parsed value. Passing serial port 0 lets the OS
allocate a port; `link.port` records it.

The listener must exist before DOSBox tries to connect its COM1 adapter. The transport guide explains framing and
request acknowledgments in detail.

## 22. Choose and validate the initial origin

```python
origin = f"http://127.0.0.1:{args.http_port}" if args.local_test else args.origin
app = App(link, origin, local_test=args.local_test)
stack.callback(app.close)
```

Local testing supplies a loopback HTTP origin. Existing-proxy mode supplies the requested HTTPS origin. Internet mode
initially supplies `None`, because allocation has not happened. The `App` object retains the same `link` object already
created. Its maintenance thread has not started at this point.

`App.set_origin()` accepts an origin with scheme and hostname/port. It rejects credentials, query, fragment, and paths
other than empty or `/`. It also rejects whitespace and a missing hostname.

Public mode requires HTTPS. HTTP is accepted only for explicit local-test mode with `127.0.0.1` or `localhost` as
hostname. The normalized origin and host are used to validate incoming HTTP requests. This validates the supplied URL's
structure; it does not contact a proxy to verify that forwarding or TLS has actually been configured correctly.

## 23. Start HTTP before the room is ready

```python
server = ControllerServer(args.http_port, app)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
stack.callback(server.server_close)
stack.callback(server.shutdown)
```

The server binds to `127.0.0.1`, not all network interfaces. The background thread runs the server's request-accepting
loop. The callback registration order deliberately makes shutdown occur before close. This thread is not explicitly
joined by the launcher.

The listening service starts before DOSBox and before room synchronization. Internet mode has no known origin yet; the
bridge answers requests with an appropriate waiting error until one is set.

Other modes already have an origin, but the game may still be unconfigured or unavailable during startup. The bridge's
transport and configuration checks handle that condition.

Thus a successfully bound HTTP socket and a playable room are distinct states. The launcher waits for assembly state
before advertising the phone address.

## 24. Create the log and connect the generated COM1 configuration

```python
log = stack.enter_context((run_dir / "dosbox.log").open("w"))
conf = run_dir / "phone.conf"
text = (HERE / "PHONE4.CONF").read_text().replace("port:8766", f"port:{link.port}")
```

Opening with `"w"` truncates the previous game log. `enter_context` registers file closure on the cleanup stack. The
configuration is copied as text and modified in the run directory. The source `PHONE4.CONF` is not overwritten. The replacement is
textual and replaces all exact occurrences.

The source configuration contains:

```text
serial1=nullmodem server:127.0.0.1 port:8766 transparent:1 rxdelay:1000
```

The generated file substitutes `link.port` for the default port. DOSBox presents that TCP connection as the DOS
program's COM1 UART. Assembly reads and writes UART ports with its normal I/O instructions.

The phone never connects directly to this serial TCP listener. Both the serial listener and bridge listener are
restricted to loopback.

## 25. Headless settings and project-local child environments

```python
if args.headless:
    text = text.replace("output=openglnb", "output=surface")
conf.write_text(text)
dosenv = environment()
if args.headless:
    dosenv.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
```

This is intended for automated execution without an interactive display. It does not bypass assembly execution or supply
player inputs. It also does not make the launcher exit automatically after a test duration.

The imported `environment()` returns inherited environment variables with `TMPDIR`, `TMP`, and `TEMP` set to the
project's `build/maze4/tmp`. It creates that directory as needed.

The game child receives `dosenv`; cloudflared receives a separate call to `environment()` later. Headless SDL overrides
are added only to `dosenv` here. The launcher does not replace its entire parent environment globally. Build staging,
run artifacts, and temporary storage have different subpaths. All remain under the same repository's `build/maze4`
directory.

## 26. Start DOSBox with an argument list and captured logs

```text
/usr/bin/dosbox
  -conf <run_dir>/phone.conf
  -noautoexec
  -c 'mount c "<assignment-3>"'
  -c 'c:'
  -c 'MAZE4.EXE'
  -c 'exit'
```

The host directory becomes DOS drive C. The executable runs there, then DOSBox is instructed to exit afterward. The
command uses an absolute host DOSBox executable path.

```python
proc = subprocess.Popen(..., env=dosenv, stdout=log, stderr=log)
stack.callback(stop_process, proc)
```

The call starts a child and returns a process handle without waiting for the whole game session to finish. Both standard
output and standard error go into `dosbox.log`. There is no `shell=True`; the argument list goes directly to the
executable. The DOSBox `-c` strings are still commands interpreted by DOSBox itself. Cleanup is registered only after
the process was successfully created.

## 27. Wait for assembly readiness, configure the room, then maintain it

```python
link.wait_for(lambda s: s["capacity"] >= 2, 10)
app.sync_room()
app.start()
```

The lambda accepts a decoded state dictionary and tests capacity. The timeout argument is ten seconds. `wait_for()`
waits on transport state updates rather than sleeping ten seconds unconditionally; if the condition is already true, it
can return promptly. Failure to obtain matching state raises `TransportError`.

Capacity is supplied by the assembly state snapshot. At least two available starts is the launcher's chosen readiness
threshold. This does not mean two people have joined or that a race has begun.

The predicate does not verify a particular room phase, player count, or frame-rate target. It also does not explicitly
poll the DOSBox process during this wait. An early process exit can therefore surface as the ten-second state timeout.
The transport's `wait_for()` checks its stored state and predicate; its separate `latest()` method supplies the
stale-state check used next.

`app.sync_room()` reads current assembly state. On a new epoch it generates a twelve-character room password, clears old
Python sessions/reservations, and configures MASM through a request. Successful first configuration prints the password
to the terminal.

`app.start()` then launches periodic synchronization in a daemon thread. That worker also notices later room changes
while the game runs. It tolerates `TransportError` so transient transport outages do not kill it.

The password can therefore appear before the later phone-address message. This setup runs even in internet mode before
cloudflared is started.

## 28. Mode boundaries: public HTTPS and internal loopback HTTP

```python
tunnel = None
if args.internet:
    ...
```

Both `--origin` and `--local-test` keep `tunnel=None`. They do not create a tunnel reader, readiness Event, tunnel log,
or empty cloudflared configuration during this invocation. Old files from an earlier internet invocation may still exist
in the run directory. Their presence alone does not prove that this run used a tunnel.

```text
phone browser --HTTPS--> public tunnel/proxy endpoint
                              |
                          forwarding
                              |
                    HTTP on 127.0.0.1:<http-port>
                              |
                       ControllerServer
```

The Python server does not load a TLS certificate or listen for HTTPS itself. An HTTPS public origin and a loopback HTTP
forwarding target are compatible. ADB does not participate in this traffic path.

## 29. Internet mode: configuration, log, and cloudflared command

```python
empty = run_dir / "empty-cloudflared.yml"
empty.write_text("{}\n")
tunnel_log = stack.enter_context((run_dir / "tunnel.log").open("w"))
```

The launcher supplies this file with `--config`. Its contents are an empty YAML mapping. The command therefore points at
a known project-local configuration file. `tunnel.log` is truncated for this run and registered for closure. The
launcher neither creates a permanent tunnel definition nor saves credentials.

```text
/usr/bin/cloudflared tunnel
  --config <run_dir>/empty-cloudflared.yml
  --no-autoupdate
  --url http://127.0.0.1:<http-port>
```

`--url` identifies the internal bridge target. The returned banner supplies the different, public origin.
`--no-autoupdate` is passed explicitly. No reverse proxy is launched in `--origin` mode. The tunnel guide here describes
the checked-in invocation, not service guarantees.

## 30. Capture tunnel output and handle immediate pipe failures

The `Popen` options include:

```python
stdout=subprocess.PIPE,
stderr=subprocess.STDOUT,
text=True,
bufsize=1,
```

Both streams enter one readable pipe as text. The main thread does not iterate that pipe itself. A reader thread drains
it while the main thread waits for startup evidence.

The tunnel process gets a cleanup callback immediately after creation. `tunnel.stdout` is copied into `tunnel_output`.
If it is unexpectedly `None`, startup raises `RuntimeError("HTTPS tunnel output is unavailable")`.

`bufsize=1` requests line buffering for the Python-side text stream. It does not force the child to flush every partial
line immediately. The loop processes lines as the pipe iterator delivers them. The launcher does not explicitly close
this pipe with `ExitStack`, and does not explicitly join its daemon reader thread.

## 31. Event construction and the nested `read_tunnel()`

```python
found = threading.Event()
readiness = QuickTunnelReady()

def read_tunnel():
    for line in tunnel_output:
        ...
```

The Event initially has an unset flag. `read_tunnel()` takes no arguments; its closure accesses the pipe, log, parser,
Event, and `app` from `main()`. It is defined only when the internet branch executes.

## 32. `read_tunnel()`: logging, origin installation, EOF, and lifetime

```python
tunnel_log.write(line)
tunnel_log.flush()
public_origin = readiness.feed(line)
if public_origin and not found.is_set():
    app.set_origin(public_origin)
    found.set()
```

Flushing makes processed diagnostics available in the log promptly. The origin is installed before readiness is
signalled. An awakened main thread can therefore inspect `app.origin` afterward. The Event guard allows only the first
detected origin to be installed.

At the end of `read_tunnel()`:

```python
if not found.is_set():
    found.set()
```

This is reached when ordinary pipe iteration ends without readiness. It wakes the main thread rather than forcing it to
wait the full deadline. Consequently, `found` means “readiness detected or output ended.” The main thread must still
inspect `app.origin` to distinguish success. An uncaught reader exception can bypass this EOF code.

```python
threading.Thread(target=read_tunnel, daemon=True).start()
```

Daemon means this thread does not by itself keep Python alive at shutdown. It does not mean its work is automatically
synchronized or joined. The reader normally continues draining logs after startup succeeds. Closing/terminating
resources can race with its final reads and writes.

There is no reader-wide `try/except` transferring an exception to `main()`. If parsing, origin installation, or log
writing fails in that thread, the main thread generally discovers missing readiness through its wait/check.

## 33. Event/deadline coordination and final startup acceptance

```python
deadline = time.monotonic() + 40
while not found.wait(0.2) and time.monotonic() < deadline:
    if proc.poll() is not None:
        raise RuntimeError("DOSBox exited before tunnel startup")
```

Monotonic time is suitable for elapsed-time deadlines because wall-clock adjustments do not redefine its interval.
`Event.wait(0.2)` returns true if the flag becomes set within that wait. The loop polls DOSBox only when both condition
terms allow its body to run.

The code waits on the Event before testing the deadline. Thus forty seconds is a startup waiting budget, not a hard
process watchdog. Scheduler delays and the final wait can add time.

If the Event is already set, the body is skipped entirely. If the deadline has passed after a wait, the body is also
skipped. There is no separate final DOSBox poll in this branch. A very late reader update can race with the next origin
check. This is why the explanation must not promise exact forty-second termination.

```python
if app.origin is None:
    raise RuntimeError(f"HTTPS tunnel did not start; see {run_dir / 'tunnel.log'}")
```

The success criterion here is that a public origin has been installed. EOF without the banner/registration pair leaves
it unset and raises the error. Reaching the waiting limit without an origin raises the same error. The tunnel return
code is not included in that message. Registered readiness followed by immediate tunnel death may pass this check; the
main monitoring phase can then report the outage.

## 34. The three printed startup messages

The launcher prints the phone address, host controls, and ownership guidance. All use `flush=True` to push output
promptly to the terminal/parent reader.

```text
Phone address: <app.origin>
Phones enter the room password. Host: Space=start, M=mode, R=new maze,
N=new room, 1–8=remove, Tab=scores, Esc=quit.
ADB is not used for game traffic. Ctrl+C stops this launcher and its own processes.
```

The actual second message is one printed line. The host keyboard controls room/race actions; phones supply player
movement.

## 35. `trace_state()`: periodic state copying and redaction

```python
def trace_state():
    if not args.state_trace:
        return
```

The function is always supplied as `on_tick`, even when tracing is disabled. Its early return makes those calls
inexpensive in the default mode. It closes over `args`, `link`, and `run_dir`. It has no arguments and no meaningful
return value. Tracing begins only after startup reaches `monitor_game`.

```python
current = link.latest()
trace = {k: v for k, v in current.items() if k != "players"}
trace["players"] = [
    {k: v for k, v in p.items() if k != "owner"}
    for p in current["players"]
]
```

The top-level copy temporarily omits the player array. It then constructs new player dictionaries without the `owner`
field. This does not delete ownership data from the live transport state.

The decoded assembly state includes epoch, generation, phase, capacity, mode, count, winners, exit, distance, floor,
elapsed, best, and players. Player fields retained include ID, state, warning, position, steps, penalty, finish,
readiness, and name.

The transport state does not contain the bridge's password, session token, or CSRF secret, so they are not selected
here. Ownership identifiers are explicitly removed. Player names and game activity remain visible; this is not a general
anonymizer for all personal or future state fields.

## 36. Snapshot replacement, stale files, and log-redaction limits

```python
target = run_dir / "state.json"
temporary = run_dir / "state.new"
temporary.write_text(json.dumps(trace, indent=2))
temporary.replace(target)
```

Each successful tick replaces the last snapshot. Writing a sibling temporary file before replacement avoids readers
seeing a partially written target under the normal same-filesystem replacement model. It is not a multi-run lock or a
disk-durability/fsync protocol. Two launchers using this directory would contend for these fixed filenames.

```python
except TransportError:
    pass
```

Disconnected or stale state can therefore skip a trace update silently. The previous `state.json` remains; it is not
marked stale or deleted. Disabling tracing also leaves any previous file in place. There is no launcher timestamp added
to that snapshot. File-write, JSON, and unexpected state-shape errors are not all ignored; only `TransportError` is
caught inside this callback.

`dosbox.log` contains captured DOSBox standard output/error. `tunnel.log` contains raw tunnel output consumed by the
reader. Neither stream is passed through the state-trace redaction comprehension.

The bridge disables ordinary HTTP request logging to avoid recording credentials, cookies, bodies, and arbitrary
requested URLs through that path. The room password is intentionally printed to the host terminal.

Do not infer that every terminal capture and every runtime log is secret-free because `--state-trace` describes
credential-free assembly snapshots.

## 37. `tunnel_outage()` and the final monitor call

The nested outage callback takes no arguments and prints:

```text
HTTPS tunnel stopped. The PC race continues; MASM expires inputs and handles
disconnects. Use Esc or Ctrl+C to quit.
```

Then `main()` delegates the long-running phase:

```python
return monitor_game(proc, tunnel, on_outage=tunnel_outage, on_tick=trace_state)
```

## 38. ExitStack cleanup order, partial startup, and retained diagnostics

After complete non-internet startup, reverse registration produces:

```text
1. stop_process(proc)           game DOSBox
2. close dosbox.log
3. server.shutdown()            stop HTTP accept loop
4. server.server_close()        close HTTP server socket
5. app.close()                  stop/join maintenance worker
6. link.close()                 stop serial transport worker/listener
```

`App` is stopped before its underlying serial link is closed. The HTTP service is stopped before room-maintenance
cleanup.

The full internet stack unwinds as:

```text
1. stop_process(tunnel)
2. close tunnel.log
3. stop_process(proc)
4. close dosbox.log
5. server.shutdown()
6. server.server_close()
7. app.close()
8. link.close()
```

Suppose HTTP binding fails after `App` construction. Only the already registered App and SerialLink callbacks run.
Suppose DOSBox starts but no suitable assembly state arrives. The DOSBox, log, server, App, and serial callbacks run.

Suppose cloudflared cannot be executed. The opened tunnel log is closed, followed by existing game/service resources. No
tunnel stop callback exists until `Popen` succeeds.

Registration happens after successful acquisition, so a constructor that partially acquires resources and raises owns
its own internal failure handling.

Exiting the stack closes resources; it does not delete the generated files. `phone.conf`, log files, empty tunnel
configuration, and a previous state snapshot can remain for diagnosis.

Shutdown also does not call every daemon thread's `join()` in this file. The App and SerialLink close methods perform
their own bounded joins. HTTP shutdown uses the server API; request threads are daemon threads.

If cleanup itself raises, `ExitStack` continues unwinding remaining callbacks, but the resulting exception can replace
the normal return path.

## 39. Executable entry, return codes, interruption, and error limits

```python
if __name__ == "__main__":
    try:
        sys.exit(main())
```

Importing the module defines its objects without calling `main()`. Executing it as the script enters this block.
Normally `main()` returns the DOSBox process code through `monitor_game`. Python then uses that integer for its own exit
status. A tunnel outage alone does not substitute a failure code for the game code.

The process being polled is `/usr/bin/dosbox`. The launcher does not parse a separate DOS errorlevel packet from
`MAZE4.EXE`. Consequently, its returned code describes DOSBox's process ending.

On POSIX, `Popen.returncode == -N` means the child was terminated by signal N. Passing a negative integer through
`sys.exit` can be represented differently by a shell's finite-width exit-status display.

The [Python return-code reference](https://docs.python.org/3/library/subprocess.html#subprocess.Popen.returncode)
documents the process-level convention; do not relabel it as a race score.

```python
except KeyboardInterrupt:
    print("\nStopped MAZE4.")
except (RuntimeError, OSError, TransportError, ValueError) as exc:
    print(f"MAZE4: {exc}", file=sys.stderr)
    sys.exit(1)
```

Interruption prints a stop message after unwinding and has no explicit nonzero exit call in that handler; normal
completion of the script is status 0. The selected error family prints a concise stderr message and exits 1.
`TransportError` is also a subclass of `RuntimeError`.

`argparse` uses `SystemExit` for help and usage errors; those are not caught by the listed exception tuple. Help
normally exits 0, while malformed arguments normally exit 2.

`subprocess.TimeoutExpired` and `subprocess.CalledProcessError` are not automatically `RuntimeError` just because they
concern a process. Such build failures or a final cleanup wait timeout can escape with a traceback. Unexpected
`KeyError` or other programming failures can also escape. An exception in a background thread is not automatically
re-raised in `main()`. These are limits of the checked-in exception structure, not newly added handling.

## 40. Worked trace: explicit local testing

```text
python run_maze4.py --local-test
parse → create run directory → rebuild if needed → install SIGTERM handler
serial listener → App(http://127.0.0.1:8080) → HTTP thread
game log/config → DOSBox → wait capacity≥2
configure room/password → maintenance thread
print localhost address → monitor until DOSBox ends
reverse cleanup → exit with DOSBox code
```

Another machine's `127.0.0.1` identifies that machine, not this PC. This mode is an explicit local test path, not a LAN
publishing option.

## 41. Worked trace: successful internet startup

```text
python run_maze4.py --internet --state-trace
normal game/bridge setup completes, room password printed
cloudflared starts → reader saves banner → candidate remembered
reader saves registration line → app.set_origin(URL) → Event set
main wakes → origin exists → phone address printed
monitor writes reduced state snapshots while DOSBox runs
host presses Esc → DOSBox ends → monitor returns
tunnel and remaining resources clean up in reverse order
```

The trace is an execution explanation, not a fresh public connectivity test.

## 42. Worked trace: tunnel output ends too early

```text
cloudflared starts but supplies no accepted banner/registration pair
reader reaches EOF → Event set
main wakes → app.origin is still None
RuntimeError: HTTPS tunnel did not start; see .../tunnel.log
ExitStack stops acquired children/services and closes registered files
outer handler prints MAZE4: ... to stderr → exit 1
```

The Event waking the main thread did not mean startup succeeded. This trace explains why the subsequent origin check is
necessary.

## 43. Worked trace: tunnel dies after the race starts

```text
DOSBox running, tunnel previously accepted, reported=False
first iteration after tunnel exit: tunnel.poll() returns an integer
outage callback prints continuation message; reported=True
trace callback can still save assembly state
later iterations: no repeated outage callback
DOSBox continues until host/game exit
monitor returns DOSBox code; cleanup unwinds
```

The launcher does not treat this as a reason to kill the PC race.

## 44. Worked trace: existing HTTPS reverse proxy

```text
python run_maze4.py --origin https://maze.example.test --http-port 8080
App validates/normalizes the supplied origin
ControllerServer listens on 127.0.0.1:8080
DOSBox/room setup completes → address printed → game monitored
```

The proxy must already route that public origin to the loopback HTTP service and preserve the request Host/Origin values
expected by the bridge. The launcher neither proves this forwarding works nor monitors the proxy process. An invalid
origin can fail after an already-needed build has completed.

## 45. Port changes and the special case of zero

```text
python run_maze4.py --local-test --http-port 8090 --serial-port 8770
```

The local origin uses 8090 and the generated COM1 configuration uses the actual serial listener port. Serial port zero
is supported by using the recorded `link.port`.

HTTP port zero has no equivalent origin/forward-target correction here: the server can bind an OS-selected port while
the launcher still formats `:0`. Use an explicit usable HTTP port for the documented operating modes. Do not run
multiple sessions against these shared runtime filenames.

## 46. Whole-launcher pseudocode

```text
parse exactly one mode and optional settings
create run directory; rebuild executable if forced, absent, or older than sources
install SIGTERM → KeyboardInterrupt
with dynamic cleanup stack:
    create serial listener; register close
    construct App with initial origin; register close
    start HTTP server thread; register server close, then shutdown
    open game log; write adjusted configuration
    start DOSBox; register process stop
    wait for capacity≥2; synchronize room; start maintenance
    if internet:
        open tunnel log; start tunnel; register process stop
        start reader that logs output and installs origin after readiness
        wait for readiness/EOF/deadline while checking DOSBox in loop body
        require an installed origin
    print address and host instructions
    monitor DOSBox, reporting tunnel exit once and optionally tracing state
    return DOSBox code after stack unwinds
outer script: print interruption or selected startup errors; set exit status
```

## 47. Reading the launcher as a sequence of guarantees

Before DOSBox starts, its serial listener exists. Before the phone address is printed, assembly state has met the
capacity test and the initial room configuration request has succeeded. In internet mode, the parsed banner/registration
pair has installed an origin. Before `main()` returns normally, its registered cleanup has run.

Those guarantees come from statement order and resource registration. They do not establish that a physical phone
connected successfully, that an external proxy is correct, or that an alive tunnel remains reachable. For the rules
behind the state being supervised, continue with [MAZE4.md](MAZE4.md).
