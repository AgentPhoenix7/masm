# bridge.py — authenticated phone requests become MASM serial commands

Source: [phone/bridge.py](../phone/bridge.py).

This is a standalone explanation of the current MAZE4 HTTP bridge. Basic Python
and familiarity with 8085-style input, memory, and subroutines are enough to
begin. No older maze program or explanation is required.

The companion [protocol guide](protocol.md) explains the byte transport, and
[MAZE4](MAZE4.md) explains the game. Their relevant interfaces are introduced
here as well. [run_maze4](run_maze4.md) creates these objects and manages them.

The central responsibility is:

> Authenticate a phone, bind it to one assembly player, translate its requests,
> and return that player's status without implementing the maze rules in Python.

Examples below illustrate source behavior. They are not a new public-server,
DOSBox, or physical-phone acceptance run.

---

## 1. Begin with the complete request path

```text
phone browser
    ↓ HTTPS through a tunnel or reverse proxy
loopback HTTP ControllerServer
    ↓ ControllerHandler validates HTTP and credentials
App associates the browser with epoch/slot/owner
    ↓ SerialLink builds a binary command and waits for an ACK
loopback TCP → DOSBox COM1 → MASM
    ↓ assembly validates and changes its authoritative state
snapshot/ACK → SerialLink → App → HTTP response
```

HTTPS protects the public connection to the chosen proxy/tunnel endpoint.
The local HTTP server binds to `127.0.0.1`; it does not implement TLS itself.

The Python bridge never directly writes assembly `POSITIONS`, chooses legal
moves, calculates collision penalties, or awards winners.

## 2. The six classes

| Class | Purpose |
| --- | --- |
| `ApiError` | Carry an HTTP status and an application error message |
| `Session` | Store one browser controller's binding and request state |
| `JoinAttempt` | Describe a retry reservation dictionary for type checking |
| `App` | Room synchronization, credentials, joins, commands, private status |
| `ControllerHandler` | HTTP routing, JSON, cookies, response headers |
| `ControllerServer` | Loopback listener and bounded threaded request handling |

An instance stores data in attributes such as `self.sessions`.
A method's `self` identifies the object being operated on.
Multiple handlers share one `App`, which is why synchronization matters.

## 3. Imports grouped by their role

| Imports | Role in this file |
| --- | --- |
| `hashlib`, `hmac`, `secrets` | Token lookup, comparisons, random credentials |
| `json`, `struct`, `re` | HTTP bodies, binary payloads, input syntax |
| `threading`, `time`, `deque` | Locks, maintenance, monotonic age windows |
| `dataclass`, `field`, `TypedDict`, `cast` | Record definitions and type information |
| `SimpleCookie`, `CookieError` | Read cookie headers |
| `BaseHTTPRequestHandler`, `ThreadingHTTPServer` | Standard-library HTTP machinery |
| `Path`, `urlsplit`, `socket` | Fixed assets, origin parsing, socket type annotation |

All these imports are from Python's standard library.
The one project exception type comes from `protocol.py`.

## 4. Package import versus direct-module import

```python
if __spec__ is not None and __spec__.parent:
    from .protocol import TransportError
else:
    from protocol import TransportError
```

When imported as `phone.bridge`, the leading dot means a sibling within the
same package. The alternate branch supports an import context without that
package parent.

This does not start a listener or a game.
Object construction and startup happen later through the launcher.

## 5. Constants and the fixed asset directory

```python
ASSETS = Path(__file__).parent
ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
assert len(ALPHABET) == 32
COOKIE = "__Host-maze4"
```

`ASSETS` points to the directory containing this source file.
The room password alphabet avoids easily confused characters `0`, `1`, `I`,
and `O`. Twelve choices from 32 symbols represent 60 bits of choice space.

The assertion checks the alphabet length when the module is imported under
normal assertion-enabled execution. It is not a password check.

## 6. Separate the identities before reading the code

| Item | Meaning |
| --- | --- |
| Room password | Shared login secret for a room |
| Join-attempt ID | Browser's identity for retrying a particular join |
| Session token | Random secret placed in the controller cookie |
| CSRF token | Additional session value required on controller-changing POSTs |
| Epoch | Assembly's room-lifetime number |
| Slot | Assembly player index, 0–7 |
| Owner | Nonzero 16-bit assembly association for that slot |
| Sequence | Increasing movement-update number |

These are separate fields because they solve separate problems.
A visible player number alone is not enough to authorize its movement.

## 7. Room phase and player state

The snapshots supplied by `SerialLink` describe:

```text
phase: 1 lobby, 2 race, 3 results
player state: 0 empty, 1 participating, 2 finished, 3 DNF
```

DNF means did not finish. State 1 is also used for an admitted lobby player;
phase determines whether movement can run.

The bridge checks bindings and translates commands. Assembly still decides
whether a join, ready change, or direction is valid for its current phase.

## 8. `ApiError.__init__`: an error with structured meaning

```python
class ApiError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)
```

The status is a number such as 401 or 409.
The message is suitable for the controller's JSON response.

Raising an exception interrupts the current operation and unwinds its active
context managers. A later handler catches it and constructs the HTTP reply.
This replaces a chain of manually propagated error flags.

## 9. `Session`: one browser's controller record

The required constructor fields are `epoch`, `slot`, and `owner`.
Other fields have defaults:

| Field | Purpose |
| --- | --- |
| `csrf` | Random per-session verification value |
| `sequence` | Highest browser movement sequence accepted by the bridge |
| `heartbeat` | Last successful bridge heartbeat/input time |
| `created` | Monotonic creation time for the 24-hour lifetime |
| `lock` | Serialize movement input and status work for this session |
| `requests` | Recent authenticated-request timestamps |

`@dataclass` generates ordinary record machinery, including initialization.
It does not automatically validate network requests.

## 10. Why `field(default_factory=...)` is necessary

```python
csrf: str = field(default_factory=lambda: secrets.token_urlsafe(24))
lock: object = field(default_factory=threading.Lock)
requests: deque = field(default_factory=deque)
```

The factories run when a new default is needed for an instance.
Each session therefore gets its own token, lock, and deque.
Sharing one default lock or deque across all sessions would have different
behavior. This per-instance factory behavior is documented by
[Python's dataclass reference](https://docs.python.org/3/library/dataclasses.html#dataclasses.field).

`token_urlsafe(24)` starts from 24 random bytes before text encoding; the
argument is not a request for exactly 24 output characters.

## 11. `JoinAttempt` describes a plain dictionary

Its keys are `owner`, `name`, `digest`, and `token`.
The last two can initially be `None` while a join outcome is uncertain.

`TypedDict` supplies expectations for static type checking. The resulting
records are ordinary dictionaries at runtime; it does not validate JSON.
Similarly, `cast` later in the file returns its argument unchanged at runtime.
See [Python's typing reference](https://docs.python.org/3/library/typing.html#typing.TypedDict).

Actual request validation is performed by explicit comparisons and type checks.

## 12. `App.__init__`: establish the shared room adapter

The constructor receives a link object, optional origin, and `local_test` flag.
It creates room state, session tables, join reservations, locks, a stop event,
and a placeholder for the maintenance thread.

```python
self.lock = threading.RLock()
self.join_lock = threading.Lock()
self.sessions: dict[bytes, Session] = {}
self.attempts: dict[str, JoinAttempt] = {}
```

The dictionary keys for `sessions` are token digests, while `attempts` uses
the browser's retry identity.

## 13. Locks protect different scopes

| Lock | Scope |
| --- | --- |
| `App.lock` | Room/session-table maintenance |
| `join_lock` | One join workflow at a time |
| `Session.lock` | One session's movement/status ordering |
| Link's internal request lock | Serialized serial request/ACK exchange |

`RLock` permits the same thread to acquire it more than once, balancing each
acquisition with a release. It still excludes competing threads.
`with lock:` releases the lock when control leaves the block, including by
exception. These semantics come from
[Python's threading reference](https://docs.python.org/3/library/threading.html#rlock-objects).

These locks coordinate host threads; they are not assembly `CLI` instructions.

## 14. `set_origin`: define the one public origin

An origin is the scheme plus network location, for example:

```text
https://maze.example
```

The method parses the supplied value and rejects an unexpected path, nonempty
query/fragment, user information, missing hostname, or whitespace.
The path may be empty or `/`.

Public mode requires HTTPS. Explicit local test mode also permits HTTP when
the hostname is `127.0.0.1` or `localhost`.

## 15. Origin and Host are stored for exact comparison

```python
self.origin = f"{url.scheme}://{url.netloc}"
self.host = url.netloc
```

`origin` includes the scheme; `host` is the network-location text, including
any port. The handler later compares request headers with these stored values.

This is not a wildcard list of trusted websites, a DNS lookup, or an HTTPS
connection test. The launcher supplies the chosen origin.
Header matching depends on the proxy forwarding the expected external Host.

## 16. `sync_room`: follow the assembly epoch

Under `App.lock`, the method gets the latest assembly snapshot.
If its epoch differs from `self.epoch`, it:

```text
records the new epoch
generates a new twelve-character password
clears sessions, attempts, and allocated owners
marks room configuration incomplete
```

A new room invalidates the bridge's old browser bindings.
It does not merely change the name on the screen.

## 17. Configure the displayed password

If configuration is incomplete, `sync_room` sends opcode 1 with twelve password
bytes. A nonzero ACK status raises `TransportError`.
On success it sets `configured=True` and prints the password to the local
launcher terminal for the host to share.

The host bridge generates this password using `secrets.choice`.
The assembly RNG used for mazes is not used for credentials.
Secure token generation is documented in
[Python's secrets reference](https://docs.python.org/3/library/secrets.html#generating-tokens).

The display copy does not make the serial checksum an authentication system.

## 18. Remove sessions whose assembly association disappeared

The live set contains `(id, owner)` pairs for state 1, 2, or 3 with a nonzero
owner. Sessions survive only if their pair is present and their age is below
86400 seconds.

Finishers and timed-out DNF players can retain status access.
Explicit assembly leave/removal clears the owner, which removes that binding.

The check uses a received snapshot. It is not an instantaneous independent
read of DOS memory at every Python statement.

## 19. Preserve uncertain join reservations

```python
if v["digest"] is None or v["digest"] in self.sessions
```

keeps an attempt when it is still unresolved or its established session is
still retained.

Why keep an unresolved attempt? The assembly may have created the player
before the reply was lost. Retrying must reuse that owner rather than allocate
a second player.

`sync_room` returns the snapshot it used; it does not calculate a replacement
game state.

## 20. `start` and nested `maintain`: periodic room synchronization

`start` defines `maintain`, creates a daemon thread for it, and starts that
thread. The loop waits on the stop event for 0.2 seconds between iterations.

```python
while not self.stopped.wait(0.2):
    try:
        self.sync_room()
    except TransportError:
        pass
```

This thread synchronizes the room and cleans up tables. It does not send
player heartbeats merely because the bridge process remains alive.
Unexpected exceptions are not caught by this particular loop.

## 21. `_state`: require a usable current room

It obtains `link.latest()` and checks that room configuration is complete and
the snapshot epoch matches the bridge epoch.

A mismatch produces `ApiError(503, ...)`, meaning the room is changing or not
ready to serve the operation.
`link.latest()` can also raise `TransportError` for unavailable/stale assembly
state. That is converted to HTTP 503 at the handler boundary.

## 22. `_digest`: turn a token into a lookup key

```python
return hashlib.sha256(token.encode()).digest()
```

The result is digest bytes used as a key in `self.sessions`.
This is hashing, not encryption, and it does not produce an assembly owner ID.

The file does retain a raw token in a completed `JoinAttempt` for idempotent
join responses. Therefore “the sessions table uses hashes” must not be
expanded into a claim that raw tokens are never retained anywhere in memory.

## 23. `authenticate`: validate the cookie's binding

Authentication first obtains a current room snapshot.
It only hashes nonempty token strings shorter than 100 characters.
Then it checks:

```text
session exists
session epoch matches snapshot epoch
session age is below 86400 seconds
snapshot slot still has this owner
snapshot player state is 1, 2, or 3
```

Failure produces HTTP 401. A revoked assembly association also removes the
session entry from the local table.

## 24. Authentication includes a per-session request window

The method removes timestamps older than one second from `session.requests`.
If 30 remain, the next authenticated request is rejected with 429.
Otherwise the current timestamp is appended.

This counts authenticated handler requests, including status polls, rather
than successful maze moves. The check removes entries with age `>1`, so an
entry exactly one second old is still present at that comparison.

Rate windows use `time.monotonic`, which measures elapsed time without relying
on the user's wall-clock date.

## 25. `join`: serialize the complete admission workflow

`with self.join_lock:` covers validation, owner reservation, serial dispatch,
and confirmation. Other joins wait their turn.

The aggregate login deque allows fewer than 120 retained attempts in its
60-second window before admitting another. Old entries are removed when their
age is strictly greater than 60 seconds.

The limit is global to this adapter. The `client` argument is not used to
construct per-IP buckets. Connections arrive through loopback, and the code
does not trust caller-supplied forwarding headers as identity.

## 26. Password checking

The password must be a string of at most 64 characters and must match the
current room password after encoding to bytes.

```python
hmac.compare_digest(password.encode(), self.password.encode())
```

avoids content-based early-exit comparison. It does not make every part of
the entire login path constant-time; length/type checks still exist.
The API's scope is described in
[Python's HMAC reference](https://docs.python.org/3/library/hmac.html#hmac.compare_digest).

The bridge itself does not uppercase the submitted password. The supplied
controller uppercases its form value before sending it.

## 27. Name and retry-ID validation

The name must contain 1–8 printable ASCII characters and must not be all spaces.
The retry ID must be exactly 32 lowercase hexadecimal characters.

The name is later padded to eight bytes, matching the assembly's fixed record.
The retry ID lets a browser repeat the same join after a timeout or reload.

The room password is checked before a cached attempt is used.
The retry ID is not the cookie token or the CSRF token.

## 28. Reuse an existing attempt

If an attempt already exists, the submitted name must match its original name.
If it has a token/digest associated with a retained session, that same session
and token are returned.

If the outcome is unresolved, its original owner ID is reused for another
serial join attempt.

These branches are what make a retry correspond to the same admission rather
than another slot allocation.

## 29. Reserve a new owner before sending anything

For a new attempt, the bridge rejects admission if eight sessions or 32 retained
attempt records already exist. Otherwise it advances `next_owner` modulo 65535
until it finds a nonzero owner not already in `self.owners`.

The candidate counter initially starts at a random value, but owner IDs remain
small serial association values. They are not browser authentication secrets.

The code reserves the owner and attempt dictionary before the network write
or ACK wait. A timeout cannot safely prove that the assembly did nothing.

## 30. Dispatch and confirm the join

```python
code, slot, _ = self.link.request(
    2, state["epoch"], name.ljust(8).encode(), request_id=owner
)
```

Opcode 2 uses the owner as its stable request ID.
Assembly can recognize a repeated request and return the same slot.

On a nonzero ACK, the attempt entry is removed if it is still the same cached
object. A phase/full/other rejection becomes HTTP 409.
The allocated owner set is not rolled back on this path.

## 31. An ACK is followed by a snapshot confirmation

After an accepted ACK, `join` waits for a snapshot whose epoch changed or whose
returned slot contains the reserved owner.

If the room changed, it raises `TransportError` rather than issuing a session
for the old room. The bridge epoch is checked again before saving the session.

Thus success is associated with observed assembly state, rather than merely
an optimistic browser-side player record.

## 32. Create and retain the browser credential

```python
token = secrets.token_urlsafe(32)
session = Session(state["epoch"], slot, owner)
```

The bridge stores the session under `_digest(token)` and updates the attempt
with that digest and token. It then returns the pair to the HTTP handler.

The browser receives the token through `Set-Cookie`; the assembly receives
only its own owner/slot fields. These are deliberately different identities.

## 33. Worked uncertain-join trace

```text
attempt A reserves owner O
bridge sends join with request ID O
MASM creates slot 2 for O
ACK is lost → bridge reports transport failure
attempt A remains unresolved
retry A with same name/password reuses O
MASM finds O and returns slot 2 again
bridge confirms snapshot and creates the cookie session
```

None of the symbolic values here is an actual credential.
An explicit negative ACK differs from an unknown result after a timeout.

## 34. `owned_payload`: pack the binding

```python
return struct.pack("<BH", session.slot, session.owner)
```

`<` selects little-endian standard-size fields, `B` one byte, and `H` two bytes.
For illustrative slot 2 and owner `5678H`, this produces:

```text
02 78 56
```

This mirrors 8085's familiar low-byte-first word storage, but Python explicitly
constructs the byte sequence for a protocol message.

## 35. `command`: add session identity and dispatch

The helper calls `link.request` with opcode, session epoch, and owned payload
followed by any operation-specific fields.

For opcode 3 it sets `queue_timeout=0.2` and `retries=1`.
Other commands use the link defaults.

Short movement admission avoids waiting behind a long stale-input backlog.
It does not remove the link's separate ACK timeout or guarantee instantaneous
completion. A nonzero assembly status becomes HTTP 409.

## 36. `input`: validate Python types as well as ranges

The body must contain:

```text
seq: exact int, 0 <= seq < 2**53
direction: exact int, 0 <= direction <= 4
tap: exact bool
```

Using `type(value) is int` rejects Boolean values in integer fields even though
Python's `bool` is a subclass of `int`.
The explicit Boolean test likewise rejects integer `1` as a tap flag.

Direction codes are 0 idle, 1 up, 2 down, 3 left, 4 right.

## 37. Advance sequence before dispatch

Inside `session.lock`, an input with `seq <= session.sequence` is rejected.
For a newer input, the bridge stores the sequence before obtaining state and
dispatching the serial request.

Consequently a failed or uncertain dispatch still advances this bridge-side
ordering barrier. An older hold must not later overtake a newer release.

The initial sequence is zero, so input sequence zero passes the type/range
test but fails the newer-than comparison for a fresh session.

## 38. Build the movement-specific fields

```python
struct.pack("<HHBB", state["generation"], seq & 65535, direction, tap)
```

The six bytes contain generation, low 16 sequence bits, direction, and tap.
The generation comes from current assembly state; the slot/owner/epoch come
from the authenticated session. The HTTP body does not select them.

Assembly separately checks its modular 16-bit forward sequence window.
A large bridge-side increasing jump can still fail that assembly check.
After success, the bridge records a recent heartbeat time.

## 39. `private_state`: status polling can carry a heartbeat

Inside the session lock, the helper gets current state.
When more than one second has elapsed since its last successful input/heartbeat,
it sends opcode 4 and updates the heartbeat timestamp after success.

Thus active controller polling can keep its player live.
This heartbeat does not refresh the assembly's held-direction timestamp;
movement expiry and player liveness are separate rules.

If the heartbeat fails, a status operation can return a transport/error response
rather than a stale optimistic success.

## 40. Return one player's record

The response includes the snapshot's room-level fields and only this session's
player record, with its owner field removed.
It also returns the session CSRF value and last bridge sequence.

The complete eight-player serial snapshot is not sent as a public roster.
Room-level data such as count, capacity, elapsed time, and winner mask remains.

The player data comes from the snapshot obtained before any heartbeat wait
inside this call; the helper does not issue a second snapshot read afterward.

## 41. `App.close`: stop maintenance cooperatively

It sets the stop event and, if a maintenance thread exists, waits up to four
seconds for that thread to finish.

The event wakes its between-iteration wait. It does not forcibly interrupt an
in-progress link request, and `join(4)` is a bounded wait rather than a kill.

The launcher separately closes the HTTP server, game processes, and serial link.

---

## 42. `ControllerHandler`: one HTTP connection's work

The handler uses a four-second socket timeout, identifies its server version
as `MAZE4`, and sends HTTP/1.0-style responses.

The standard library reads request metadata and dispatches methods such as
GET to `do_GET`, and POST to `do_POST`. Unsupported methods use the base
handler's behavior. See the
[HTTP handler reference](https://docs.python.org/3/library/http.server.html#http.server.BaseHTTPRequestHandler).

This class translates HTTP details into `App` calls; it does not independently
create another application or serial connection for every request.

## 43. The `app` property and `cast`

```python
return cast(ControllerServer, self.server).app
```

The property obtains the shared App through the server object.
`cast` helps the type checker understand that this server has an `app` attribute.
It does not convert the object, perform authentication, or enforce the type
at runtime.

## 44. `log_message`: suppress the standard request log

The override does nothing.
This prevents normal handler logging from recording arbitrary request URLs,
credentials, or cookie-bearing request details through this hook.

It does not control every possible log outside this hook. For example,
`sync_room` intentionally prints the room password to the local terminal.

## 45. `respond`: serialize and frame an HTTP response

Byte bodies are written directly. Other values are JSON-serialized and encoded.
The method sends status and headers, ends the header section, then writes
the body through `wfile`.

```text
status line
headers, including Content-Type and byte Content-Length
blank line
body bytes
```

The length is calculated from encoded bytes, not an assumed character count.
Default response content type is `application/json`.

## 46. Response headers have distinct purposes

| Header | Purpose here |
| --- | --- |
| `Cache-Control: no-store` | Ask clients/intermediaries not to cache responses |
| `X-Content-Type-Options: nosniff` | Request interpretation according to declared content type |
| `Referrer-Policy: no-referrer` | Avoid sending a referrer from this page |
| `Content-Security-Policy` | Restrict resources/actions to the declared policy |
| `Strict-Transport-Security` | Sent in public mode, with a one-year max age |
| `Set-Cookie` | Included when a credential is issued or cleared |

The CSP uses same-origin defaults/scripts/styles/connections, forbids framing
by other pages, forbids base URLs, and restricts form actions to self.
These are browser controls, not substitutes for the server's own validation.

## 47. `cookie`: public and local-test variants

Public mode uses:

```text
__Host-maze4=<token>; Path=/; HttpOnly; SameSite=Strict; Max-Age=86400; Secure
```

There is no Domain attribute. The token is not placed in a query string.
HttpOnly keeps it out of normal script cookie access; the browser still sends
it with eligible requests.

Explicit local-test mode uses name `maze4-test` and omits Secure for loopback
HTTP. Clearing changes `Max-Age` to zero and supplies an empty token.

## 48. `session`: parse cookies and authenticate

The helper constructs `SimpleCookie` from the incoming Cookie header.
It selects the expected public/test cookie name and extracts its value.

A `CookieError` produces an empty token, which fails authentication normally.
No cookie also supplies an empty token.
The method then delegates all room, ownership, expiry, and rate checks to
`App.authenticate`.

## 49. `route`: reject an unconfigured origin first

No configured origin yields HTTP 503.
An unexpected Host yields 403.
A path longer than 128 characters, or containing `?` or `#`, yields 404.

The path checks apply before the GET/POST route-specific behavior.
The code compares fixed raw paths rather than treating arbitrary user text
as a local filename.

## 50. GET routes: fixed assets and private status

| Path | Operation |
| --- | --- |
| `/` | Read `controller.html` from the fixed asset directory |
| `/controller.js` | Read the fixed JavaScript asset |
| `/controller.css` | Read the fixed stylesheet |
| `/api/state` | Authenticate, then return `private_state` |

Assets are available before login so a user can load the join form.
Status requires a valid session.
Unknown GET paths return 404; there is no directory listing route.

## 51. POST routes require the exact Origin

Before handling a POST operation, the handler checks the Origin header against
`App.origin` and admits only:

```text
/api/join
/api/input
/api/ready
/api/leave
```

The browser's origin check and cookie binding serve different purposes.
Knowing a route name or matching Host alone does not authenticate a controller.

## 52. Bound and parse the request body

The handler rejects Transfer-Encoding and requires Content-Type to be exactly
`application/json`.
It parses Content-Length and accepts only values from zero through 1024.
An invalid/out-of-range length produces 413.

It reads at most that declared amount, parses JSON, and requires a dictionary.
Malformed JSON gives 400; a list or number gives 400 as well.
The explicit code does not separately compare the read byte count with the
declared length after an early EOF.

An empty body has an allowed length but fails JSON parsing.

## 53. Join route: an existing cookie can make reload idempotent

For `/api/join`, the handler first tries `session()`.
If a valid cookie exists, it returns that session's private status directly.
It does not create another player or recheck the supplied password on that
already-authenticated branch.

Only a 401 from this preliminary authentication falls back to `App.join`.
Another error, such as 429, is propagated.
For a new successful join, the response sets the cookie and returns status.

## 54. Other POSTs need the CSRF value

After authenticating the cookie, the handler compares `X-Maze-CSRF` with the
session's CSRF token using `compare_digest` on encoded bytes.
Mismatch yields 403.

```text
expected Host + expected Origin
    + valid session cookie + matching CSRF
    → operation-specific validation and dispatch
```

The CSRF field is supplied in the JSON status response for the controller
script to send in its later headers.

## 55. Dispatch input, readiness, and leave

Input delegates the body to `App.input`.
Ready requires `type(body["ready"]) is bool`, then sends opcode 6 with byte
zero or one through `App.command`.

Leave sends opcode 5, removes entries referring to that session from the local
session table, returns `{"left": true}`, and clears the cookie.

Input/ready success returns `{"ok": true}`. Serial acceptance remains distinct
from a successful maze step, which depends on a later assembly update.

## 56. `handle_route`: the exception-to-response boundary

| Exception | Behavior |
| --- | --- |
| `ApiError` | Its status and `{"error": message}` |
| `TransportError` | HTTP 503 and a transport error message |
| `BrokenPipeError`, `ConnectionResetError`, `TimeoutError` | Stop this response path quietly |

This is not a catch-all converting every Python exception to JSON.
For example, unexpected programming or asset-read errors are not listed here.

## 57. `do_GET` and `do_POST`: small adapters

```python
def do_GET(self):
    self.handle_route("GET")

def do_POST(self):
    self.handle_route("POST")
```

The standard-library dispatcher calls these methods.
Both use the same error-handling boundary, which then selects their route.
The method names are part of the framework interface, not assembly labels.

## 58. `ControllerServer.__init__`: bind loopback and retain App

```python
self.app = app
self.slots = threading.BoundedSemaphore(32)
super().__init__(("127.0.0.1", port), ControllerHandler)
```

The constructor creates the listening server and associates its handler class.
The launcher starts `serve_forever` in another thread.

`allow_reuse_address=True` requests the base server's address-reuse behavior.
It does not authorize two independent active servers to own the same port.

## 59. `process_request`: bound concurrent workers

It tries `self.slots.acquire(blocking=False)`.
If no slot is available, the accepted connection is closed immediately.
This is a dropped connection, not an application-generated HTTP 429 reply.

On admission, the superclass starts threaded handling.
If that dispatch raises, the acquired slot is released and the exception is
raised again. No successfully acquired permit should disappear on that path.

The counter bounds HTTP worker activity, not the number of maze players.

## 60. `process_request_thread`: release even after handler failure

The worker delegates processing to the superclass inside `try/finally`.
Its `finally` releases the semaphore permit regardless of ordinary success
or a handler exception.

A bounded semaphore detects excess releases above its initial count, unlike
an unrestricted counter. Nonblocking acquisition returns immediately when no
permit exists; see
[Python's semaphore reference](https://docs.python.org/3/library/threading.html#semaphore-objects).

`daemon_threads=True` means process shutdown need not wait for every worker.
The launcher stops the accepting loop from another thread, as required by
[socketserver shutdown](https://docs.python.org/3/library/socketserver.html#socketserver.BaseServer.shutdown).

## 61. Worked successful movement request

Assume a current racing session and symbolic credential values:

```text
POST /api/input
Host: configured public host
Origin: configured HTTPS origin
Cookie: current controller cookie
X-Maze-CSRF: this session's CSRF
JSON: {"seq": 17, "direction": 4, "tap": true}
```

The handler validates HTTP and credentials. `App.input` checks types/order,
records sequence 17, gets the current generation, and sends owned opcode 3.
MASM accepts or rejects the stored input. Even accepted input may hit a wall.
The next authenticated status snapshot reveals the resulting position.

## 62. Worked rejected and uncertain cases

| Trigger | Local outcome |
| --- | --- |
| Wrong Host | 403 before route-specific handling |
| Wrong room password on a new join | 403 |
| Missing/expired/revoked session | 401 |
| Correct cookie, wrong CSRF on input | 403 |
| Direction `true` instead of integer | 400 |
| Duplicate bridge sequence | 409 before a new serial input |
| MASM rejects a dispatched command | 409 |
| Transport timeout | 503; an already sent command can have an uncertain outcome |
| No free HTTP worker permit | Socket closes without a route response |

These results belong to the particular layer that detected the problem.
They are not all evidence of a broken DOSBox connection.

## 63. Source-shaped pseudocode

```text
MAINTENANCE:
    repeat until stopped:
        read fresh MASM snapshot
        on new epoch, replace password and invalidate old bindings
        configure password display if needed
        retain live unexpired sessions and uncertain join reservations

NEW JOIN:
    serialize with join lock
    apply aggregate attempt window
    validate password, name, retry ID
    reuse cached attempt or reserve owner before dispatch
    send idempotent serial join
    require accepted ACK and matching owner snapshot
    create session token, CSRF, and binding

CONTROLLER POST:
    require expected Host/Origin/path/body
    authenticate cookie binding and request window
    verify CSRF
    validate operation body
    construct payload from server-held identity
    send command and translate ACK/error

STATUS GET:
    authenticate cookie
    optionally send heartbeat
    return room metadata and this player's record without owner
```

## 64. Useful 8085 comparisons and their limits

| Familiar idea | Host-side use here |
| --- | --- |
| Validate an input before changing state | Type/range/origin/ownership checks |
| Keep a record in memory | Session objects and reservation dictionaries |
| Return a status from a subroutine | ACK codes and translated `ApiError` |
| Represent a word as low/high bytes | `struct.pack` for little-endian owner and sequence |
| Keep a monotonically progressing state | Movement sequence barrier |
| Distinguish a request from its final effect | Input accepted versus a committed maze move |

HTTP, cookies, host threads, cryptographic tokens, and exceptions add facilities
outside an 8085 instruction set. They do not move the maze algorithm out of MASM.

## 65. Important boundaries of the implementation

The public deployment expects an HTTPS proxy/tunnel in front of loopback HTTP.
Its availability and TLS termination are outside this module.
The file uses standard-library HTTP with explicit routes, request limits,
and controller checks; it is not a general web framework or arbitrary file API.

Credentials and sessions live in memory. Restarting the bridge does not restore
them from a database. Timestamps use monotonic age, and sessions have a fixed
creation-based lifetime rather than an indefinitely renewed login. The room
password persists until the room epoch is replaced.

Timeouts can leave command outcomes uncertain. Ordering barriers, join retry
reservations, and MASM ownership/sequence checks address particular cases;
they are not a universal exactly-once transport guarantee.

The guide describes the checked-in behavior. It does not certify every possible
concurrent interleaving or report a new security audit.

## 66. A map of all source definitions

| Definition | Responsibility |
| --- | --- |
| `ApiError.__init__` | Status/message exception |
| `Session`, `JoinAttempt` | Controller state and retry-record shape |
| `App.__init__`, `set_origin` | Adapter state and public-origin configuration |
| `App.sync_room` | Epoch/password/session synchronization |
| `App.start`, nested `maintain` | Maintenance thread lifecycle |
| `App._state`, `_digest`, `authenticate` | Current room and token binding checks |
| `App.join` | Validated, reserved, idempotent admission |
| `App.owned_payload`, `command` | Serial association and dispatch |
| `App.input`, `private_state` | Ordered input and private status/heartbeat |
| `App.close` | Cooperative maintenance shutdown |
| `ControllerHandler.app`, `log_message` | Shared App access and logging hook |
| `ControllerHandler.respond`, `cookie`, `session` | Responses and credentials |
| `ControllerHandler.route`, `handle_route` | Routing/validation and errors |
| `ControllerHandler.do_GET`, `do_POST` | Standard-library method adapters |
| `ControllerServer.__init__` | Loopback listener and worker counter |
| `ControllerServer.process_request`, `process_request_thread` | Worker admission/release |

## 67. Exam-ready explanation

The bridge accepts browser requests at a loopback HTTP server behind HTTPS.
It validates origin, fixed routes, JSON, cookies, and CSRF, then binds each
controller to an assembly epoch, slot, and owner. Joins reserve their identity
before serial dispatch so uncertain retries reuse the same admission. Input
uses per-session ordering and server-selected identity fields before MASM
performs its own validation and movement. Status polling can send heartbeats
and returns only the controller's player record. Bounded workers, request
windows, cooperative maintenance, and explicit error translation keep transport
responsibilities separate from the authoritative game rules.
