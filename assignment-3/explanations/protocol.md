# protocol.py — bytes, packets, and the DOSBox connection

Source: [phone/protocol.py](../phone/protocol.py). The matching assembly sender and receiver are in
[M4SER.INC](../M4SER.INC).

This is a standalone guide for a reader who knows basic Python and 8085. You do not need to read another maze
program or assignment first. The guide follows every definition in this file and the actual wire layout. It
explains source behavior; it does not report a new live DOSBox or phone test.

The job of this file is:

> Carry commands to MASM and turn MASM's replies into Python values.

It does not generate the maze, move players, or decide winners. Those decisions stay in the assembly program.
Python packages their inputs and reads their outputs.

---

## 1. Where this file sits

```text
phone browser
    |
    | HTTPS handled elsewhere
    v
Python bridge
    |
    | SerialLink.request(...)
    v
protocol.py
    |
    | TCP bytes on 127.0.0.1
    v
DOSBox's serial redirection
    |
    | emulated COM1 registers
    v
MASM receiver and game state
```

Replies travel back along the same connection. DOSBox provides the serial-to-TCP connection between the two
programs. The Python side is a TCP listener, despite the class name `SerialLink`. It does not open a Linux
`/dev/tty...` serial device.

In an 8085 exercise, a program might read one byte with `IN`. Here, MASM reads its emulated UART with 8086 `IN`
instructions. Python sees socket bytes instead of executing those I/O instructions. The bytes must still follow
an agreed format at both ends.

The higher-level browser authentication is outside this file. Loopback restricts the TCP address to this
computer. The frame checksum does not authenticate a controller.

## 2. Three different meanings of “data”

Keep these three representations separate:

| Representation | Example | Purpose |
| --- | --- | --- |
| Python values | `request=0x1234` | Convenient program variables |
| Binary payload | `04 34 12 02 00 ...` | Compact fields with agreed offsets |
| Encoded frame | `b':043412020000563442\n'` | Delimited text sent over the stream |

An encoded hex digit is an ASCII byte. The two characters `34` represent one binary byte with value `0x34`. They
are not the same byte sequence as that binary byte.

The transport flow is:

```text
values → struct.pack → payload → encode → wire bytes
wire bytes → parser → decode → payload → struct.unpack_from → values
```

`encode` and `decode` know about frames. `decode_state` knows about a particular payload schema. `SerialLink`
supplies connections, buffering, synchronization, and retries.

## 3. Imports: every module has a specific job

```python
import socket
import struct
import threading
import time
from contextlib import contextmanager
from functools import reduce
```

| Import | Used for |
| --- | --- |
| `socket` | Listen, accept, receive, send, shut down connections |
| `struct` | Pack and unpack fixed-width little-endian fields |
| `threading` | Background reader, locks, condition variable, stop event |
| `time` | Monotonic timestamps and deadlines |
| `contextmanager` | Make `bounded_lock` usable with `with` |
| `reduce` | XOR all bytes into one checksum value |

These are Python standard-library facilities. No third-party serial library is imported. No HTTP server is
imported here either.

The background thread exists so receiving can continue while a caller waits. It does not make the assembly game
run in a Python thread. MASM is a separate program running inside DOSBox.

## 4. Python syntax worth recognizing

```python
def encode(payload: bytes) -> bytes:
```

`payload: bytes` describes the expected argument type. `-> bytes` describes the intended return type. These
annotations do not automatically validate every argument at runtime. The function body performs its actual
length checks.

`b":"` is a bytes literal containing one byte, decimal 58. `":"` without the `b` is Python text. The socket
sends bytes, so the distinction matters.

`None` means “no value is available” in several fields. For example, `self.connection = None` means no published
connection. It is different from an empty bytes value `b""` returned by `recv`.

Python indentation defines blocks. The nested loops in `_serve` have different lifetimes. Following their
indentation is as important as following jump labels in assembly.

## 5. The two compiled layouts

```python
HEADER = struct.Struct("<BHHBBBBBHHHII")
PLAYER = struct.Struct("<BBHHIIIB8s")
```

A `Struct` object keeps a reusable format description. It supplies `.size` and `.unpack_from(...)` for that
description. The objects are made when Python loads the module. Creating them does not open a connection or
start a thread.

The format characters used here mean:

| Character | Meaning under `<` | Bytes |
| --- | --- | ---: |
| `<` | Little-endian, standard sizes, no alignment padding | 0 |
| `B` | Unsigned integer | 1 |
| `H` | Unsigned integer | 2 |
| `I` | Unsigned integer | 4 |
| `8s` | One bytes field of exactly eight bytes | 8 |

`8s` returns one bytes value, not eight separate Python values. This distinction explains why one `name`
variable receives all name bytes. `I` is four bytes here even if a native C integer differs on another platform.
The explicit `<` prevents native alignment from inserting invisible gaps.

These rules follow Python's [struct
documentation](https://docs.python.org/3/library/struct.html#byte-order-size-and-alignment).

## 6. Little-endian storage and 8085 knowledge

The word `0x1234` is sent as:

```text
offset +0: 34
offset +1: 12
```

The least significant byte comes first. The numeric value is still `0x1234`, not `0x3412`. Endian order concerns
byte storage, not how a number is written on paper.

For a 32-bit example:

```text
value 0x01020304 → 04 03 02 01
```

An 8085 reader can relate a two-byte value to a register pair. The low and high bytes must be combined in the
agreed order. In this project, MASM's word loads and `STOSW` match Python's `<H` layout. MASM emits doublewords
as the low word followed by the high word. Python's `<I` reconstructs those four bytes as one integer.

Do not apply a generic “network byte order” assumption here. This project's application payload deliberately
uses little-endian fields. TCP transports their bytes without rewriting the payload's integer order.

## 7. Snapshot header offsets

All offsets in this table are relative to the binary snapshot payload. They do not count the colon or ASCII hex
characters.

| Offset | Size | Format | Python variable | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 1 | `B` | `op` | Snapshot type, `0x82` |
| 1 | 2 | `H` | `epoch` | Room lifetime identifier |
| 3 | 2 | `H` | `generation` | Maze generation identifier |
| 5 | 1 | `B` | `phase` | 1 lobby, 2 race, 3 results |
| 6 | 1 | `B` | `cap` | Maze's player capacity |
| 7 | 1 | `B` | `mode` | Collision mode value |
| 8 | 1 | `B` | `count` | Participant count |
| 9 | 1 | `B` | `winners` | Winner bit mask |
| 10 | 2 | `H` | `exit_pos` | Exit cell index |
| 12 | 2 | `H` | `distance` | Common starting distance |
| 14 | 2 | `H` | `floor` | Walkable-cell count excluding the exit |
| 16 | 4 | `I` | `elapsed` | Elapsed race time in tenths |
| 20 | 4 | `I` | `best` | Best score in tenths |

The final field occupies offsets 20 through 23. Therefore `HEADER.size` is 24. The first player record starts
immediately at offset 24.

`epoch` distinguishes rooms. `generation` distinguishes maze versions inside a room. They are related freshness
markers with different purposes.

## 8. Player-record offsets

Offsets here are relative to the start of one player record.

| Offset | Size | Format | Name | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 1 | `B` | `state` | Empty, participating, finished, or DNF |
| 1 | 1 | `B` | `warning` | Proximity warning level |
| 2 | 2 | `H` | `owner` | Serial ownership token |
| 4 | 2 | `H` | `pos` | Current cell index |
| 6 | 4 | `I` | `steps` | Successful movement count |
| 10 | 4 | `I` | `penalty` | Penalty time in tenths |
| 14 | 4 | `I` | `finish` | Raw finish time in tenths |
| 18 | 1 | `B` | `ready` | Boolean readiness byte |
| 19 | 8 | `8s` | `name` | Fixed-width ASCII name |

The final name byte is at record offset 26. Therefore `PLAYER.size` is 27. Player `i` starts at payload offset
`24 + 27*i`.

| Slot | First payload byte | Last payload byte |
| ---: | ---: | ---: |
| 0 | 24 | 50 |
| 1 | 51 | 77 |
| 2 | 78 | 104 |
| 3 | 105 | 131 |
| 4 | 132 | 158 |
| 5 | 159 | 185 |
| 6 | 186 | 212 |
| 7 | 213 | 239 |

There are always eight records, including empty slots. The `count` field does not shorten the payload. An empty
slot still carries a complete fixed-size record.

## 9. Deriving all important size limits

One payload byte becomes two hex characters. The checksum adds another two hex characters. The colon and line
feed add one byte each.

```text
encoded length = 1 + 2*(payload length + 1) + 1
               = 2*payload length + 4
```

For a snapshot:

```text
header = 24
players = 8*27 = 216
payload = 24+216 = 240 bytes
frame = 2*240+4 = 484 bytes
```

For the general `encode` function:

```text
minimum payload = 1 byte → frame 6 bytes
maximum payload = 256 bytes → frame 516 bytes
```

For commands sent through `request`:

```text
frame must be <=194 bytes
2*payload_length+4 <=194
payload_length <=95 bytes
```

MASM's `RX_BUFFER` contains 96 decoded bytes. During parsing, those bytes include the checksum. Thus 95
command-payload bytes plus one checksum byte fit exactly. The five-byte command header leaves at most 90 bytes
for the extra payload.

The 516-byte general frame bound and 194-byte request bound are different. Large snapshots travel from MASM to
Python. Commands travel into MASM's smaller receive buffer.

---

## 10. `encode`: reject an unsuitable payload length

```python
def encode(payload: bytes) -> bytes:
    if not 1 <= len(payload) <= 256:
        raise ValueError("packet size")
```

The chained comparison means both inequalities must hold. An empty payload is rejected. A payload with 257 bytes
is also rejected. The check is on binary payload length, before framing.

The function does not check whether the first byte is a recognized operation. It can frame arbitrary nonempty
bytes within its size bound. Command-specific interpretation occurs elsewhere.

An 8085 equivalent would compare a byte-count variable with allowed limits before entering a transmit loop.
Python reports the failure by raising an exception. It does not return a special checksum or partially built
frame.

## 11. `encode`: compute the XOR checksum

The central expression is:

```python
reduce(int.__xor__, payload, 0)
```

Iteration over a bytes object produces integer byte values. `int.__xor__` is the XOR operation for those
integers. `reduce` repeatedly combines an accumulator with the next byte. The third argument, `0`, is the
initial accumulator.

Equivalent teaching pseudocode is:

```text
checksum = 0
for each byte in payload:
    checksum = checksum XOR byte
```

This resembles clearing an 8085 accumulator and applying `XRA` repeatedly. The final value is between 0 and 255.
`bytes([checksum])` converts it to one binary checksum byte.

The checksum is the XOR of raw bytes. It is not the XOR of the characters used to print those bytes in hex.

## 12. `encode`: build printable frame bytes

```python
return (
    b":"
    + (payload + bytes([reduce(int.__xor__, payload, 0)]))
    .hex()
    .upper()
    .encode("ascii")
    + b"\n"
)
```

The parenthesized payload-plus-checksum expression receives the method calls. First `.hex()` makes hexadecimal
text. Then `.upper()` selects `A` through `F` instead of lowercase letters. Then `.encode("ascii")` converts
that text into bytes for the socket. Finally the colon and line feed delimit the frame.

The line feed is one byte with decimal value 10. The source spelling `\n` is Python's escape notation for that
byte. The wire does not contain a backslash followed by the letter `n`.

There is no carriage return, space, or explicit binary length field. The frame ending tells the receiver where
the hex data stops. The receiver then applies schema-specific length checks.

## 13. A complete XOR and frame example

Take this eight-byte heartbeat command payload:

```text
04 34 12 02 00 00 56 34
```

Its fields will be explained later. For now, calculate the checksum one byte at a time:

| Incoming byte | Accumulator after XOR |
| --- | --- |
| Initial | `00` |
| `04` | `04` |
| `34` | `30` |
| `12` | `22` |
| `02` | `20` |
| `00` | `20` |
| `00` | `20` |
| `56` | `76` |
| `34` | `42` |

Append checksum `42` and encode the nine bytes as hex:

```python
b":043412020000563442\n"
```

Its length is `2*8+4 = 20` bytes. XORing the payload and checksum gives `42 XOR 42 = 00`. That zero result is
what `decode` checks.

XOR can detect some corruption, but multiple changed bytes can cancel. Reordering bytes also leaves their XOR
unchanged. It is neither a cryptographic signature nor proof of semantic correctness.

## 14. `decode`: inspect the outer frame

```python
def decode(frame: bytes) -> bytes:
    if not frame.startswith(b":") or not frame.endswith(b"\n") or len(frame) > 516:
        raise ValueError("frame")
```

`or` means any one failed requirement is enough to reject the frame. The start must be a colon. The final byte
must be a line feed. The entire frame must fit in 516 bytes.

This function expects one completed frame. It does not accumulate fragments across calls. That accumulation is
the responsibility of `_serve`.

There is no explicit minimum length in this first test. The following checks reject empty or too-short contents.
Passing the delimiter check alone does not imply a valid packet.

## 15. `decode`: validate the hexadecimal alphabet

```python
raw = frame[1:-1]
if not raw or any(c not in b"0123456789ABCDEF" for c in raw):
    raise ValueError("hex")
data = bytes.fromhex(raw.decode("ascii"))
```

The slice removes exactly the first and last byte. `raw` contains only the supposed hexadecimal characters. `not
raw` catches an empty middle section. `any(...)` stops when it finds a character outside the allowed alphabet.

Lowercase hex is rejected. Spaces are rejected, even though `bytes.fromhex` alone can accept whitespace. A
carriage return before LF is rejected as well. The explicit alphabet test makes this framing stricter than
generic hex parsing.

An odd number of hex digits passes the alphabet test but fails `fromhex`. That operation raises `ValueError` for
the incomplete byte pair. The code does not need a separate even-length test to reject it.

## 16. `decode`: validate checksum and remove it

```python
if len(data) < 2 or reduce(int.__xor__, data, 0):
    raise ValueError("checksum")
return data[:-1]
```

At least one payload byte and one checksum byte are required. The reduction includes both parts. A nonzero
integer is true in Python, so nonzero XOR causes rejection. Zero XOR passes this check.

The returned slice removes the final checksum byte. The caller receives the original payload, without framing or
checksum. This creates the useful property:

```python
decode(encode(payload)) == payload
```

The property holds for valid bytes payloads of length 1 through 256. It does not imply that such payloads are
meaningful game commands. `decode` has no knowledge of room epochs, slots, or player counts.

## 17. Common frame failures

| Input shape | Result |
| --- | --- |
| Missing colon | `ValueError("frame")` |
| Missing final LF | `ValueError("frame")` |
| More than 516 bytes | `ValueError("frame")` |
| `b":\n"` | `ValueError("hex")` |
| Lowercase hex character | `ValueError("hex")` |
| Odd number of valid hex characters | `ValueError` from `fromhex` |
| Only a checksum byte | `ValueError("checksum")` |
| Payload and checksum with nonzero XOR | `ValueError("checksum")` |

The transport parser catches malformed completed-frame errors. It drops those frames without sending a
Python-generated ACK. Not every error has one of the custom message strings above. Underlying conversion errors
can supply their own message.

---

## 18. `decode_state`: require the complete snapshot

```python
def decode_state(payload: bytes) -> dict:
    if len(payload) != HEADER.size + 8 * PLAYER.size:
        raise ValueError("state size")
```

The only acceptable length is 240 bytes. A truncated snapshot is rejected. A snapshot with extra bytes is also
rejected. This protects the later record-offset calculations.

The argument here is already binary payload bytes. Passing the 484-byte ASCII frame directly would fail this
length check. The correct order is `decode_state(decode(frame))` for a state frame.

The function does not fetch a state from DOSBox. It transforms an already-received payload into a dictionary.
This makes it possible to inspect its behavior without opening a socket.

## 19. `decode_state`: unpack the header

The tuple assignment receives thirteen fields:

```python
(
    op, epoch, generation, phase, cap, mode, count, winners,
    exit_pos, distance, floor, elapsed, best,
) = HEADER.unpack_from(payload)
```

`op` plus the twelve following names account for the complete header. Counting field names is useful when
checking a binary schema. The expression above is only reformatted from the source's vertical assignment.

`unpack_from` starts at offset zero when no offset is supplied. It reads only the 24-byte header according to
`HEADER`. It does not consume or delete bytes from `payload`. Later calls can read player records from the same
immutable bytes object.

The spelling `exit_pos` avoids using a less descriptive local name. The returned dictionary later uses the key
`"exit"`.

## 20. Header validation is deliberately limited

```python
if op != 0x82 or phase not in (1, 2, 3) or cap > 8 or count > 8:
    raise ValueError("state fields")
```

This checks the operation, phase, capacity upper bound, and count upper bound. The unsigned struct fields
already exclude negative values. Capacity zero and count zero are not rejected by this function. `count > cap`
is not checked here.

Other values are decoded without extra range or consistency checks. Examples include `mode`, `winners`,
`exit_pos`, `distance`, and `floor`. It does not verify that winner bits select finished players. It does not
verify an exit index against the maze dimensions. It does not require a nonzero epoch or generation.

This is a parser for the current trusted local game's schema. Do not describe it as a complete validator of
every game invariant. Game-rule enforcement is a different responsibility from unpacking bytes.

## 21. The eight-player decoding loop

```python
players = []
for i in range(8):
    state, warning, owner, pos, steps, penalty, finish, ready, name = (
        PLAYER.unpack_from(payload, HEADER.size + i * PLAYER.size)
    )
```

`range(8)` supplies indices 0 through 7. The loop does not stop at `count`. Each iteration computes its own
record's byte offset. The `players` list accumulates one dictionary for every slot.

An 8085 implementation might advance a record pointer by 27 each iteration. Python calculates `24 + i*27`
instead. Both approaches locate the same fixed-size records. The list index later corresponds to the game's slot
index.

## 22. Player validation and conversion

```python
if state > 3 or warning > 2 or pos >= 1037 or ready > 1:
    raise ValueError("player fields")
```

The grid has `17*61 = 1037` cells, indexed 0 through 1036. Every record's position is checked, including empty
slots. State values 0 through 3 and warnings 0 through 2 are accepted. Readiness must be 0 or 1.

The dictionary converts `ready` using `bool(ready)`. After validation, byte 0 becomes `False` and byte 1 becomes
`True`. It adds `"id": i`; the ID is derived from record position. There is no separate transmitted player-ID
field in the record.

The name conversion is:

```python
name.decode("ascii").rstrip()
```

Non-ASCII bytes raise a decoding error. Trailing whitespace is removed; ordinary MASM names are space padded.
`.rstrip()` is broader than removing only space characters. It does not remove leading whitespace or a trailing
NUL byte. The parser does not separately require every decoded name character to be printable.

## 23. The returned dictionary

The outer keys are:

```text
epoch, generation, phase, capacity, mode, count, winners,
exit, distance, floor, elapsed, best, players
```

Each entry in `players` has:

```text
id, state, warning, owner, pos, steps, penalty, finish, ready, name
```

State meanings are 0 empty, 1 participating, 2 finished, and 3 DNF. State 1 includes a participant waiting in
the lobby. Use the room `phase` to distinguish lobby participation from racing.

The snapshot describes positions and metadata. It does not contain the 1037 maze-character bytes. `generation`
can tell a caller that the map version changed. It does not itself provide a replacement map drawing.

Elapsed, penalty, finish, and best values use tenths of a second. For example, elapsed 1234 represents 123.4
seconds. Decoding leaves them as integers; display formatting happens elsewhere.

## 24. A worked header and player record

This example constructs a valid parser input without running the game:

```python
header = HEADER.pack(
    0x82, 0x1234, 2, 1, 8, 0, 1, 0, 193, 12, 500, 1234, 0
)
player = PLAYER.pack(
    1, 2, 0x3456, 193, 7, 10, 0, 1, b"ANU     "
)
```

The header bytes are:

```text
82 34 12 02 00 01 08 00 01 00 C1 00
0C 00 F4 01 D2 04 00 00 00 00 00 00
```

The player bytes are:

```text
01 02 56 34 C1 00 07 00 00 00 0A 00 00 00
00 00 00 00 01 41 4E 55 20 20 20 20 20
```

`C1 00` decodes to cell 193. `D2 04 00 00` decodes to elapsed 1234. `41 4E 55` is ASCII `ANU`. The five trailing
`20` bytes pad the name to eight bytes.

Seven additional empty records are still required for a complete state payload. With those records,
`decode_state` returns eight player dictionaries. The first has `owner=13398`, `pos=193`, `ready=True`, and
`name="ANU"`.

---

## 25. `TransportError`: distinguish transport failures

```python
class TransportError(RuntimeError):
    pass
```

This defines a specific exception type derived from `RuntimeError`. `pass` means the class body adds no further
methods or attributes. It still inherits normal exception behavior, including a message.

Callers can catch this type to recognize unavailable or failed transport. Malformed byte layouts generally raise
`ValueError` instead. The distinction helps the bridge report an appropriate failure.

An 8085 program might return a status flag or error code. Python exceptions transfer control to an enclosing
matching `except` block. The file uses both mechanisms: exceptions for transport failure, and returned ACK
status codes for a successfully received game response.

## 26. `bounded_lock`: avoid an unlimited command queue

```python
@contextmanager
def bounded_lock(lock, timeout):
    if not lock.acquire(timeout=timeout):
        raise TransportError("Controller transport is busy; stale input discarded")
    try:
        yield
    finally:
        lock.release()
```

The decorator makes this generator function a context manager. The code before `yield` runs when entering the
`with` block. The caller's block runs while the generator is paused at `yield`. The `finally` cleanup runs when
the block exits, even by exception.

If acquisition times out, the function raises before reaching `yield`. It does not release a lock that it failed
to acquire. If acquisition succeeds, the `finally` block releases that lock.

The timeout limits time waiting to become the active request sender. It does not limit the complete duration of
the command after admission. A waiting command that times out here has not been sent by this invocation. The
message refers to discarding that waiting caller's input.

## 27. The two-lock design

`SerialLink` uses two separate synchronization objects:

| Object | Protects or coordinates |
| --- | --- |
| `request_lock` | One whole command/retry/ACK transaction at a time |
| `condition` | Shared connection, latest state, ACK dictionary, notifications |

The condition has its own associated lock. It is separate from `request_lock`. The reader must be able to
publish an ACK while a requester is waiting. Keeping those roles separate makes that possible.

A lock is not an 8085 register or an interrupt-enable flag. It coordinates access between Python threads. The
useful analogy is protecting a shared memory region from overlapping updates. Unlike disabling interrupts
globally, these locks affect cooperating code only.

The most important operation is `condition.wait(...)`. It releases the condition's lock while waiting. It does
not release `request_lock`.

## 28. `SerialLink.__init__`: create the listener

```python
def __init__(self, port=8766):
    self.listener = socket.socket()
    self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    self.listener.bind(("127.0.0.1", port))
    self.listener.listen(1)
    self.listener.settimeout(0.2)
    self.port = self.listener.getsockname()[1]
```

`socket.socket()` uses its defaults: an IPv4 stream socket. `bind` chooses the local address and requested port.
`127.0.0.1` is the loopback address on this computer. `listen` makes this a server socket able to accept
connections.

`SO_REUSEADDR` is a socket reuse option. It helps with ordinary address reuse behavior when restarting a
listener. It does not promise that every conflicting bind will succeed. Binding errors propagate from
construction.

The default requested port is 8766. If the caller passes port 0, the operating system chooses an available port.
`getsockname()[1]` records the actual bound port in `self.port`. DOSBox must be configured to connect to that
actual value.

## 29. `listen(1)` and one active client

The `1` is a pending-connection backlog request. It is not a statement that the socket can serve exactly one
lifetime connection. The operating system manages pending connections subject to its own behavior.

The code serves only one accepted connection at a time because `_serve` stays inside that connection's receive
loop until it ends. Only then does the outer loop return to `accept`. There is no separate worker thread for
each accepted client.

This is suitable for one DOSBox COM1 connection. It is not the public phone-facing server. Multiple phones share
the higher-level bridge's use of this one transport.

The listener timeout is 0.2 seconds. This lets the accept loop periodically check the stop event. The timeout
does not mean a client must connect within 0.2 seconds of startup.

## 30. `__init__`: shared state and lifecycle objects

```python
self.condition = threading.Condition()
self.request_lock = threading.Lock()
self.connection = None
self.state = None
self.state_time = 0.0
self.acks = {}
self.counter = 0
self.stopped = threading.Event()
self.thread = threading.Thread(target=self._serve, daemon=True)
self.thread.start()
```

The connection and snapshot initially do not exist. `state_time` later records local receipt time, not game
time. `acks` maps request IDs to decoded ACK tuples. `counter` supplies automatic request IDs.

The event initially is unset. Calling `.set()` later asks loops to stop. It does not forcibly kill a thread or
cancel a command already sent.

The thread target is the bound method `self._serve`. The method is passed as a callable without executing it
immediately. `thread.start()` begins its execution in a background thread. Calling `SerialLink(...)` therefore
has active networking side effects.

`daemon=True` allows process exit without waiting indefinitely for this thread. It is not a guarantee of
graceful cleanup at interpreter shutdown. The explicit `close` method supplies the intended normal shutdown
path.

## 31. `_serve`: understand the nesting first

The major structure is:

```text
while not stopped:                  outer loop: connection lifetimes
    accept a connection
    publish it
    create an empty frame buffer
    try:
        while not stopped:          middle loop: receive chunks
            receive a chunk
            for each byte in chunk: inner loop: frame parsing
                update parser
    finally:
        close and unpublish connection
```

The outer loop may accept a replacement after disconnection. The middle loop retains the same connection. The
byte loop processes the bytes already returned by one `recv` call. One frame can span several middle-loop
iterations. One chunk can also contain several complete frames.

## 32. `_serve`: accept and publish a connection

```python
while not self.stopped.is_set():
    try:
        connection, _ = self.listener.accept()
    except TimeoutError:
        continue
    except OSError:
        break
```

`accept()` returns a connected socket plus the peer's address. The underscore means the address value is not
used afterward. The listener itself remains the listening socket.

An accept timeout means no connection became available during that wait. `continue` goes back to the outer
stop-event check. Another socket error breaks out of the outer loop.

The accepted socket receives its own 0.2-second timeout. Then, under the condition lock, the code publishes
`self.connection` and sets `self.state = None`. A replacement connection must provide a new valid snapshot. The
previous connection's snapshot is not reused as current state.

This publication block does not call `notify_all()`. Existing ACKs and the request counter are not cleared on
acceptance. Those details matter when discussing late responses and reused IDs.

## 33. `_serve`: receive chunks, timeouts, and EOF

```python
buffer = bytearray()
...
chunk = connection.recv(1024)
```

The buffer is new for each accepted connection. `bytearray` allows in-place append, clear, and slice
replacement. It stores the incomplete encoded frame, not decoded binary player records.

`recv(1024)` asks for at most 1024 bytes at once. It can return fewer bytes, including a single byte. It does
not wait for exactly 1024 bytes or exactly one frame. TCP is a byte stream, so sender write boundaries are not
preserved as messages.

| Receive outcome | What `_serve` does |
| --- | --- |
| Nonempty bytes | Process each byte |
| `TimeoutError` | Keep connection and partial frame; try again |
| `b""` | Break connection loop because peer reached EOF |
| Other `OSError` | Leave loop through error handling and cleanup |

An idle timeout is not EOF. A partial frame survives an idle timeout. An empty receive is not a valid
zero-length packet. These socket behaviors are documented in the [socket
reference](https://docs.python.org/3/library/socket.html#socket.socket.recv).

## 34. `_serve`: colon starts or restarts a frame

```python
for c in chunk:
    if c == 58:
        buffer[:] = b":"
    elif buffer:
        ...
```

Iterating over `chunk` produces integer byte values. Decimal 58 is ASCII colon. Any colon replaces the existing
buffer with one colon byte. This is immediate resynchronization, even halfway through another frame.

When the buffer is empty, all non-colon bytes are ignored. Noise before a frame cannot grow the buffer. The
parser does not assume the first received byte begins a packet.

`buffer[:] = ...` changes the same bytearray object in place. The operation discards any incomplete older frame.
Because colon is not a legal hex character, a new colon is unambiguous within this particular frame alphabet.

## 35. `_serve`: size bound and line-feed completion

```python
buffer.append(c)
if len(buffer) > 516:
    buffer.clear()
elif c == 10:
    try:
        self._receive(decode(bytes(buffer)))
    except (ValueError, UnicodeError):
        pass
    buffer.clear()
```

Only an active frame buffer reaches this block. The new byte is appended before checks run. If it makes the
buffer exceed 516 bytes, the frame is abandoned. That branch runs before line-feed handling.

Decimal 10 marks LF and triggers decoding. `bytes(buffer)` provides an immutable copy for `decode`. The result
goes directly into `_receive`. The buffer is cleared whether decoding succeeded or a listed error occurred.

Invalid non-hex bytes are not rejected at append time here. They remain until LF, a new colon, or overflow ends
that candidate frame. Thus memory is bounded while validation is deferred to `decode`.

The catch also covers state-decoding failures raised inside `_receive`. Bad ASCII names and invalid state fields
do not terminate the reader loop. `pass` means the malformed completed frame is silently discarded.

## 36. Fragmentation and coalescing trace

Use the ACK frame:

```python
b":81341202000000A5\n"
```

It can arrive in these chunks:

```text
recv #1: b":813"
recv #2: b"4120200"
recv #3: b"0000A5\n"
```

After the first call, the parser keeps `:813`. After the second, it keeps the longer partial frame. Only the
third supplies LF and causes one `_receive` call. The checksum and payload decoding see the complete reassembled
frame.

Alternatively, one chunk might contain:

```text
ACK frame + snapshot frame + beginning of next frame
```

The inner byte loop dispatches the first two frames separately. It retains the unfinished third frame for a
later chunk. Neither `recv` call count nor chunk size determines packet count.

## 37. Resynchronization trace

Suppose input arrives as:

```text
noise:12garbage:81341202000000A5\n
```

The initial noise is ignored while the buffer is empty. The first colon starts a candidate frame. The second
colon discards that candidate and starts a fresh one. The final LF completes the valid ACK frame.

If more than 516 bytes follow a colon without successful completion, the parser clears its buffer and ignores
subsequent non-colon bytes. A later colon can begin a new candidate frame. There is no unbounded search history
or growing line buffer.

An invalid checksum followed by LF also clears the candidate. The transport does not request retransmission from
inside this parser. Request-side ACK timeouts supply the separate command retry mechanism.

## 38. `_serve`: disconnection cleanup

The accepted-connection receive work is enclosed by:

```python
except OSError:
    pass
finally:
    connection.close()
    with self.condition:
        self.connection = None
        self.state = None
        self.condition.notify_all()
```

The local connected socket is closed. Shared connection and snapshot references are cleared under the condition
lock. Waiting threads are notified that shared state changed. The outer loop can then accept a replacement
unless stopping was requested.

`state_time` is not reset, but `state is None` makes it unusable in `latest`. The ACK dictionary is not cleared
here. The automatic request counter is not reset either.

Notification does not itself make a waiting request fail immediately. The requester checks its own loop
conditions after reacquiring the lock. Its ACK-wait loop does not explicitly test `self.connection` on every
wakeup.

---

## 39. `_receive`: route a decoded payload

```python
def _receive(self, data):
    with self.condition:
        if data[0] == 0x82:
            ...
        elif data[0] == 0x81 and len(data) == 7:
            ...
        self.condition.notify_all()
```

This method expects binary payload bytes, after frame validation. The ordinary path through `decode` guarantees
at least one payload byte. Calling `_receive(b"")` directly would violate that assumption. The method itself has
no separate empty-input guard.

Type `0x82` identifies a state snapshot. Type `0x81` with exactly seven bytes identifies an ACK. Other payloads
do not update state or ACK storage. They still reach the final notification when no exception is raised.

## 40. `_receive`: publish the latest snapshot

```python
self.state = decode_state(data)
self.state_time = time.monotonic()
```

The decoder builds a complete new dictionary before assignment finishes. If it raises, the existing `self.state`
is not replaced by a partial dictionary. The reader's completed-frame handler catches that decoding failure.

The timestamp records successful local receipt. It is not the snapshot's `elapsed` game timer. Monotonic time is
used for measuring durations and deadlines. It avoids wall-clock changes affecting these elapsed-time
comparisons.

Only the latest dictionary is kept. There is no queue of every movement frame or snapshot history. Readers may
skip intermediate states when newer snapshots arrive quickly. That behavior suits a controller status view.

## 41. ACK field offsets

An ACK payload has seven bytes:

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 1 | Type `0x81` |
| 1 | 2 | Request ID |
| 3 | 2 | Current room epoch |
| 5 | 1 | Status code |
| 6 | 1 | Slot, or `0xFF` for none |

The code skips the already-examined type byte:

```python
request, epoch, code, slot = struct.unpack_from("<HHBB", data, 1)
```

The explicit offset 1 is essential. Without it, the type byte would become part of the request ID. The exact
length check excludes truncated or extended ACKs. No extra range check is applied to `code` or `slot` here.

For request `0x1234`, epoch 2, status 0, slot 0:

```text
payload: 81 34 12 02 00 00 00
checksum: A5
frame: :81341202000000A5 followed by LF
```

## 42. ACK storage and its bound

```python
if len(self.acks) >= 64:
    self.acks.clear()
self.acks[request] = (epoch, code, slot)
```

The dictionary key is the request ID alone. Its value is a three-item tuple. The tuple's epoch is checked later
by `request`. It is not part of the dictionary key.

The size check occurs before every valid ACK insertion. At 64 stored entries, all old entries are cleared
together. This is a simple bound, not an ordered oldest-entry eviction policy. Even an ACK replacing an existing
key encounters that preceding size check.

Most relevant ACKs are removed by the active requester. Unmatched or late ACKs can remain until a matching
removal or bulk clear. The bound prevents that residual storage from growing indefinitely.

## 43. Notifications and lock ownership

`_receive` calls `notify_all()` while holding the condition lock. The call makes waiting threads eligible to
wake. It does not release the lock immediately. They can finish `wait()` only after reacquiring that lock.

At the end of the `with self.condition:` block, the reader releases it. Then a requester or snapshot waiter can
inspect the new values. Every waiter must check its own predicate again. A notification does not identify which
particular condition became true.

These are the standard [Condition
semantics](https://docs.python.org/3/library/threading.html#condition-objects). The predicate loops in `request`
and `wait_for` are therefore necessary. An ACK notification can wake a state waiter without satisfying its
predicate. A state notification can wake a request waiter without providing its ACK.

## 44. `latest`: enforce snapshot receipt freshness

```python
def latest(self):
    with self.condition:
        if self.state is None or time.monotonic() - self.state_time > 2:
            raise TransportError("DOSBox is disconnected or not responding")
        return self.state
```

The method briefly holds the condition lock to read shared state consistently. No state means failure. A last
valid state more than two seconds old also means failure. Exactly two seconds is not rejected by the written `>
2` comparison.

The check is based on received snapshots, not just socket connectivity. A connected but unresponsive game can
therefore fail it. The code does not inspect `self.connection` directly in this method. Normal disconnection
cleanup makes `state` become `None`.

The returned dictionary is the stored object, not a deep copy. Callers should treat it as a read-only snapshot.
Mutating it would mutate the same object other readers can obtain.

Fresh receipt does not prove every game property is current for a caller. For example, callers may still need to
compare `epoch` or `generation`. A recently received snapshot from an old logical expectation is still recent.

---

## 45. `request`: signature and defaults

```python
def request(
    self, op, epoch, payload=b"", request_id=None, *,
    queue_timeout: float = 3, retries=3, timeout=0.8,
):
```

`op` is the command type. `epoch` identifies the room the caller intends to address. `payload` contains
command-specific bytes after the common header. `request_id=None` asks for an automatically generated request
ID.

The `*` makes the remaining options keyword-only. For example, write `timeout=1.0` rather than supplying it
positionally. `queue_timeout` bounds acquisition of the whole-request lock. `retries` is actually the maximum
number of send attempts in this loop. `timeout` is the nominal ACK wait per successful send attempt.

The file does not add explicit range validation for all these options. `struct.pack`, `range`, lock acquisition,
and time calculations impose their own behavior or errors for inappropriate argument values. The usual callers
use the intended numeric types and positive defaults.

## 46. Command-header offsets and operation types

Every command starts with:

```python
struct.pack("<BHH", op, request, epoch)
```

| Offset | Size | Meaning |
| ---: | ---: | --- |
| 0 | 1 | Operation |
| 1 | 2 | Request ID |
| 3 | 2 | Intended room epoch |
| 5 onward | Variable | Command-specific payload |

The current MASM operations are:

| Operation | Name | Total binary payload size |
| ---: | --- | ---: |
| 1 | Configure displayed room code | 17 |
| 2 | Join with eight-byte name | 13 |
| 3 | Direction/input update | 14 |
| 4 | Heartbeat | 8 |
| 5 | Leave | 8 |
| 6 | Ready/unready | 9 |

These totals include the five-byte common header. They exclude checksum and text framing. `request` does not
implement all the command-specific checks itself. MASM's `RECEIVE_PACKET` validates their lengths and applicable
game state.

The additional payload bytes have these absolute binary-payload offsets:

| Operations | Offset | Size | Field |
| --- | ---: | ---: | --- |
| Config, 1 | 5 | 12 | Displayed room-code characters |
| Join, 2 | 5 | 8 | Space-padded display name |
| Input/heartbeat/leave/ready, 3–6 | 5 | 1 | Player slot |
| Input/heartbeat/leave/ready, 3–6 | 6 | 2 | Owner token, little-endian word |
| Input, 3 | 8 | 2 | Map generation, little-endian word |
| Input, 3 | 10 | 2 | Input sequence, little-endian word |
| Input, 3 | 12 | 1 | Direction, 0 through 4 |
| Input, 3 | 13 | 1 | Tap flag, 0 or 1 |
| Ready, 6 | 8 | 1 | Ready flag, 0 or 1 |

MASM accepts config characters from ASCII `2` through `Z` inclusive. For a new join, it validates
all eight name bytes as printable ASCII 32 through 126. Owned requests require a slot below eight,
a nonzero matching owner, and a nonempty player state before their specific command is processed.
Input also requires race phase, a racing player, matching map generation, and a newer sequence.
Those checks belong to assembly; this Python transport only packs the supplied bytes.

## 47. Acquire the transaction lock and choose the ID

```python
with bounded_lock(self.request_lock, queue_timeout):
    self.counter = self.counter % 65535 + 1
    request = self.counter if request_id is None else request_id
```

Only one caller can hold `request_lock` at a time. Other command callers wait for admission up to their queue
timeout. The lock remains held through sending, retries, and ACK processing.

Automatic IDs run through 1, 2, ..., 65535, then return to 1. Zero is never automatically generated. The counter
advances once per admitted `request` invocation. It does not advance separately for every retry.

The counter advances even when the caller supplies an explicit ID. It can also advance before a later packing or
size error occurs. There is no rollback of that increment.

An explicit ID is used as supplied to `struct.pack`. Unsigned-word packing permits 0 through 65535. MASM
separately rejects request ID zero for joining. This class does not reserve explicit IDs or prevent their reuse.

## 48. Build the frame once

```python
packet = encode(struct.pack("<BHH", op, request, epoch) + payload)
if len(packet) > 194:
    raise ValueError("request too large")
```

The common header and additional payload become one binary payload. `encode` then supplies checksum and ASCII
framing. The stricter request bound is checked after general encoding.

The packet is built before entering the retry loop. Every attempt sends the identical encoded bytes. The ID,
epoch, and command payload therefore stay the same across retries.

An operation outside one byte or an epoch outside one unsigned word causes packing failure before any socket
send. A too-large general payload can fail inside `encode` first. A frame exceeding the MASM request bound fails
the explicit check here.

## 49. Remove an already-cached ACK

```python
with self.condition:
    self.acks.pop(request, None)
```

The requester acquires the shared-state condition lock. It removes any ACK already stored under this request ID.
The default `None` makes removal harmless when the key does not exist.

This prevents an already-cached older ACK from immediately completing the new invocation before its first send.
It is useful because IDs eventually wrap or can be explicitly reused.

It cannot prevent every late-ACK ambiguity. An old ACK that arrives after this removal can still use the same
key. The later epoch check rejects one from a different room. An old ACK with the same ID and epoch can still
match. There is no operation, payload digest, or connection generation in the key.

## 50. Send attempts and write failure

```python
for _ in range(retries):
    if self.connection is None:
        raise TransportError("DOSBox is disconnected")
    try:
        self.connection.sendall(packet)
    except OSError as exc:
        raise TransportError("COM1 write failed") from exc
```

The underscore is an unused attempt index. With the default `retries=3`, the loop can send up to three times
total. It does not mean one initial send plus three extra sends.

The connection check occurs at the start of each attempt. `sendall` keeps trying to send the supplied bytes
until complete or error. Its success means bytes were handed through the socket send operation. It does not
prove MASM processed the command.

On write error, the method raises immediately. It does not continue with another send attempt in that exception
branch. `from exc` preserves the underlying exception as the cause.

The connected socket has a 0.2-second timeout configured by `_serve`. That socket timeout also applies to socket
operations such as `sendall`. The later `timeout=0.8` option controls ACK waiting, not socket configuration.

Python's [sendall documentation](https://docs.python.org/3/library/socket.html#socket.socket.sendall) also
explains that failure does not report how many bytes were sent. A write failure can therefore leave the
command's outcome uncertain.

## 51. Set an ACK deadline after sending

```python
deadline = time.monotonic() + timeout
while request not in self.acks and time.monotonic() < deadline:
    self.condition.wait(max(0.001, deadline - time.monotonic()))
```

The deadline is made after `sendall` returns successfully. It is a local monotonic-clock target for this
attempt's ACK wait. The loop ends when the ACK key exists or the deadline test fails.

The wait duration is recomputed from remaining time. `max(0.001, ...)` supplies at least a millisecond for an
entered wait call. Clock sampling and lock reacquisition mean this is not a hard real-time bound. The code does
not promise sub-millisecond deadline accuracy.

The loop ignores the boolean returned by `Condition.wait`. It instead checks the shared ACK dictionary and time
again. This is the correct place to distinguish useful notifications from unrelated ones.

## 52. Why waiting does not deadlock the reader

The requester entered `with self.condition` before sending. At first it owns both the request lock and the
condition lock. While `sendall` runs, the reader cannot publish shared state under that condition.

At `condition.wait(...)`:

```text
request_lock: still held by requester
condition lock: released while requester sleeps
reader: can acquire condition and store ACK/state
```

When the reader notifies and releases the condition lock, the requester reacquires that lock before `wait`
returns. The request lock still excludes another whole command transaction.

Confusing the two locks would suggest a false deadlock. The condition wait temporarily releases only its own
associated lock. It does not exit the surrounding request transaction.

## 53. A two-caller concurrency trace

```text
Caller A: acquire request_lock
Caller A: acquire condition lock
Caller A: remove cached ACK A; send command A
Caller A: wait → releases condition lock

Caller B: wait for request_lock; cannot send command B yet

Reader: acquire condition lock; store ACK A
Reader: notify_all; release condition lock

Caller A: reacquire condition lock; consume ACK A; return
Caller A: leave condition block, then release request_lock

Caller B: acquire request_lock and begin its own command
```

The return statement still triggers both context managers' cleanup. Caller A does not retain a lock after
returning. If Caller B's queue wait expires first, it raises without sending its command.

State-reading callers use only the condition lock. They can run while A is asleep in `wait`. They do not need to
acquire the whole-command request lock.

## 54. Consume and check the ACK

```python
ack = self.acks.pop(request, None)
if ack:
    if ack[0] != epoch:
        raise TransportError("Room changed; join again")
    return ack[1], ack[2], request
```

The ACK is removed from the dictionary when retrieved. Any stored three-item tuple is truthy, even `(0, 0, 0)`.
Therefore status zero is not mistaken for absence of an ACK.

Tuple element 0 is the ACK's current room epoch. It must equal the room epoch supplied by the caller. MASM sends
its current epoch even when rejecting a stale-room request. That produces the explicit “Room changed” transport
error here.

On a matching epoch, the method returns:

```text
(status_code, slot, request_id)
```

The returned third value is the command ID chosen by this invocation. The method does not convert nonzero game
status into `TransportError`. The caller interprets the returned status code.

## 55. ACK status is not the same as transport success

The current assembly status meanings are:

| Code | Meaning |
| ---: | --- |
| 0 | Command accepted |
| 1 | New join rejected by room phase |
| 2 | Room/maze capacity full |
| 3 | Invalid request or command-specific rejection |
| 4 | Stale room epoch |

Receiving status 3 means transport delivered a recognizable ACK. It does not mean the command changed the game
successfully. Likewise, status 0 confirms command acceptance, not eventual victory or movement. An accepted
direction can still encounter a wall during the game update.

This Python layer does not reject unknown numeric status codes. It simply returns them when the ACK epoch
matches. The table describes the current assembly implementation's meanings.

## 56. What happens after an ACK timeout

If the ACK key is still absent, `ack` is `None`. The next `for` iteration sends the same packet again if
attempts remain. No new ID is allocated for that retry. After the loop is exhausted, the code raises:

```python
raise TransportError("DOSBox command timed out")
```

With defaults, there can be three ACK waits of about 0.8 seconds each. Admission can additionally wait up to
three seconds for `request_lock`. Socket sends, scheduling, and lock acquisition add their own elapsed time. Do
not present 2.4 seconds or 5.4 seconds as a strict whole-call maximum.

With `retries=0`, there is no send attempt. The code still advances the counter, builds the packet, and removes
a cached ACK. It then raises the same timeout error. The function is designed for the positive attempt counts
used by its callers.

## 57. A timeout does not cancel MASM work

A command may have reached MASM before its ACK was lost or delayed. MASM can accept it while Python eventually
reports a timeout. Neither a local ACK deadline nor an HTTP caller timeout retracts those bytes.

The transport sends no cancellation packet on timeout. It does not undo a join, readiness update, leave, or
direction update. The caller must treat some failures as an uncertain outcome.

There are two distinct cases:

| Failure point | What this invocation has sent |
| --- | --- |
| Request-lock acquisition timed out | No command from this invocation |
| ACK wait timed out after send | Command may already have been processed |

An outer application timeout can also expire while a worker keeps running. This class does not observe such an
outer deadline automatically. Stopping the waiter at another layer does not imply stopping this transaction.

## 58. Retries do not create universal idempotency

The transport reuses the same command bytes. Whether duplicate execution is safe depends on the MASM operation.
There is no general server-side table remembering every completed request ID.

For joining, MASM uses the request ID as the new owner's token. It first searches existing owners for that ID. A
retry can therefore return the already-created slot. It does not allocate a second slot for the same existing
owner.

Ready sets a Boolean value, so setting the same value again has the same state effect. Heartbeat refreshes a
lease timestamp. Config writes the same supplied room code again. These operations have their own repeat
behavior.

Leave revokes ownership. A retry after the first successful leave can fail ownership validation. The final
received status need not reproduce the first command's result.

Input updates carry a separate per-player sequence number. MASM rejects duplicate or old input sequences. If the
first input ACK was lost, a retry can receive an invalid status even though the first input was accepted.

## 59. Three different identifiers

| Identifier | Role |
| --- | --- |
| Request ID | Match this command's ACK; also owner token when joining |
| Room epoch | Reject commands associated with an older room |
| Map generation/input sequence | Reject wrong-map or duplicate/old movement input |

`request` knows the first two through the common header and ACK. It does not interpret the generation or
sequence inside command-specific payload. The bridge constructs those fields; MASM validates them.

A regenerated map can retain the same room epoch. Therefore matching ACK epoch alone does not prove an input
targeted the current map. MASM's input-specific generation check supplies that rule.

A fresh snapshot also does not authorize reusing an old owner token. Ownership is a separate relation stored by
MASM. These distinctions prevent one “freshness” word from hiding several checks.

## 60. Late ACK and ID-reuse trace

```text
Old command: request ID 9, epoch 2; its ACK is delayed
New invocation: explicitly uses request ID 9, epoch 2
New invocation: removes any currently cached ACK 9
New invocation: sends its packet and waits
Old ACK 9 arrives now, carrying epoch 2
Requester: sees ID 9 and matching epoch, returns its status
```

The existing pop-before-send cannot reject that late arrival. The current matching information is insufficient
to distinguish the two commands. Serialized requests reduce simultaneous in-flight transactions. They do not
make ID reuse immune to arbitrarily late replies.

If that old ACK carries epoch 1 instead, the requester raises “Room changed.” It does not ignore the mismatched
ACK and keep waiting for another one. The code's behavior is an error on mismatch.

ACKs can also remain across connection lifetimes because cleanup does not clear them. The initial pop removes an
already-stored matching key for a new invocation. There is still no explicit per-connection identifier in the
ACK schema.

---

## 61. `wait_for`: wait for a state predicate

```python
def wait_for(self, predicate, timeout=3):
    deadline = time.monotonic() + timeout
    with self.condition:
        while time.monotonic() < deadline:
            if self.state is not None and predicate(self.state):
                return self.state
            self.condition.wait(0.05)
    raise TransportError("Game state did not update")
```

`predicate` is a callable receiving the current state dictionary. It returns a truthy value when the desired
condition is satisfied. For example, a caller could test whether the epoch changed.

The method checks the currently stored state before waiting. It can return immediately if that state already
satisfies the predicate. It does not require a newly received snapshot after the call began.

The condition lock is held while evaluating the predicate. Predicates should therefore be quick and should avoid
blocking work. An exception raised by the predicate propagates to the caller. The context manager still releases
the condition lock on exit.

## 62. `wait_for` differs from `latest`

`wait_for` does not apply the two-second age check from `latest`. It does not compare `state_time` at all. A
previously stored snapshot can satisfy its predicate even when old.

The fixed `wait(0.05)` means periodic rechecks occur even without notification. It is not reduced to the exact
remaining deadline duration. The total elapsed time can therefore slightly exceed the nominal timeout, and
condition-lock acquisition or predicate work can add more time.

The deadline is created before acquiring the condition lock. Time spent acquiring it counts against the
subsequent loop condition. If the deadline has already passed, the loop does not evaluate the predicate.

Disconnection normally clears the state and notifies waiters. This method has no dedicated disconnected error
branch. It continues checking until its predicate succeeds or its own deadline expires.

## 63. `close`: request stop, unblock I/O, wait briefly

```python
def close(self):
    self.stopped.set()
    self.listener.close()
    if self.connection:
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
    self.thread.join(2)
```

The event tells the outer and middle reader loops to stop at their checks. Closing the listener prevents
continued normal acceptance. Shutting down both directions of an active connection helps unblock receive work.
An `OSError` during that shutdown is ignored.

The connected socket's actual `close()` is performed by `_serve` cleanup. That cleanup also clears shared
connection/state and notifies waiters. `close` itself does not directly clear the ACK dictionary.

`join(2)` waits up to two seconds for the reader thread. It does not forcibly terminate the thread at the
deadline. The method does not check `thread.is_alive()` afterward. Consequently a returned `close()` is not an
asserted proof of thread termination.

## 64. Closing and outstanding requests

`close` does not acquire the whole-request lock. It can overlap with an outstanding requester. The requester may
see a socket write error, disconnection on a later attempt, or exhaustion of its ACK wait, depending on timing.

There is no special “closed” test at the start of `request`, `latest`, or `wait_for`. Their existing
connection/state checks and deadlines determine their results. The stop event mainly controls the reader's
loops.

The shutdown code reads `self.connection` without holding the condition lock. Do not describe it as a fully
atomic transition across all shared fields. Likewise, the source does not promise arbitrary concurrent repeated
`close` calls. Its intended use is normal owner-driven shutdown during process supervision.

A command accepted by MASM before closing remains a game action. Closing the socket does not roll back that
command. The assembly game's own leases handle stale controllers and stale held directions.

---

## 65. Full successful request, end to end

Use heartbeat operation 4 with:

```text
request ID = 0x1234
room epoch = 2
slot = 0
owner = 0x3456
```

The command-specific bytes are made by `struct.pack("<BH", 0, 0x3456)`. They are `00 56 34`. The common header
is `04 34 12 02 00`.

The complete flow is:

```text
1. Acquire request_lock within queue_timeout.
2. Advance automatic counter, but choose explicit ID 0x1234.
3. Pack header and append slot/owner bytes.
4. Encode :043412020000563442 plus LF.
5. Acquire condition lock and remove any cached ACK for 0x1234.
6. Send the frame on the connected socket.
7. Wait, temporarily releasing the condition lock.
8. DOSBox delivers bytes through COM1 to MASM.
9. MASM validates epoch, slot, owner, and heartbeat length.
10. MASM refreshes liveness and queues an ACK.
11. Reader reassembles and decodes :81341202000000A5 plus LF.
12. Reader stores acks[0x1234] = (2, 0, 0) and notifies.
13. Requester reacquires condition lock and removes that ACK.
14. Epoch matches, so requester returns (0, 0, 0x1234).
15. Both context managers release their locks.
```

The tuple's final ID is decimal 4660 when printed normally by Python. Hex and decimal are two written
representations of the same integer. No player position is calculated in this sequence by Python.

## 66. Snapshot receipt, end to end

```text
MASM SEND_STATE:
    write 24-byte header to OUT_BUFFER
    write eight 27-byte player records
    frame the 240-byte payload with XOR and uppercase hex

DOSBox/TCP:
    deliver any number of stream chunks

Python _serve:
    find colon, accumulate at most 516 bytes, stop at LF
    decode frame and checksum

Python _receive:
    recognize 0x82
    decode_state checks size and selected field ranges
    publish complete dictionary and local receipt time
    notify condition waiters

Caller:
    latest() checks receipt age, or wait_for(...) checks a predicate
```

The assembled snapshot frame is 484 bytes. It fits the Python receive-frame bound of 516 bytes. It need not fit
MASM's command RX buffer because it travels outward.

## 67. How this relates to 8085 loops and flags

| Python idea | Useful 8085 comparison | Difference to remember |
| --- | --- | --- |
| Byte iteration | Load byte, advance pointer, decrement count | Python manages iteration |
| XOR reduction | Clear accumulator, repeated `XRA` | Python integer operation on byte values |
| Fixed record offset | Base address plus scaled index | Dictionary fields are not raw addresses |
| `raise` | Branch to an error path using status | Exceptions unwind enclosing blocks |
| `finally` | Required cleanup path before returning | Python runs it on exceptional exits too |
| Stop event | Shared stop flag checked in a loop | Thread-safe event object |
| Condition wait | Suspend until shared state changes | Releases and reacquires a lock |
| Request ID | Sequence/tag stored alongside a command | Separate from movement sequence |

The goal of the analogy is to reuse familiar control-flow reasoning. Python sockets, threads, and context
managers have their own exact semantics. They are not disguised 8085 opcodes.

## 68. A compact source-reading checklist

Read this file in the following dependency order:

```text
HEADER / PLAYER
    ↓
encode / decode / decode_state
    ↓
TransportError / bounded_lock
    ↓
SerialLink.__init__
    ↓
_serve → _receive
    ↓
latest / request / wait_for / close
```

For each receive path, ask which representation is present: socket chunk, accumulated frame, decoded payload, or
state dictionary. For each wait, ask which lock is released and which stays held. For each failure, ask whether
a command could already have reached MASM.

Those three questions explain most of this file's subtle behavior. They also prevent confusing a transport ACK
with a successful game outcome.

## 69. Safe, pure examples for checking the layout

The following assumes the functions and structs have been imported. It does not construct `SerialLink` or open a
socket.

```python
assert HEADER.size == 24
assert PLAYER.size == 27

payload = bytes.fromhex("04 34 12 02 00 00 56 34")
frame = encode(payload)
assert frame == b":043412020000563442\n"
assert len(frame) == 20
assert decode(frame) == payload

header = HEADER.pack(
    0x82, 0x1234, 2, 1, 8, 0, 1, 0, 193, 12, 500, 1234, 0
)
player = PLAYER.pack(
    1, 2, 0x3456, 193, 7, 10, 0, 1, b"ANU     "
)
empty = PLAYER.pack(0, 0, 0, 0, 0, 0, 0, 0, b"        ")
snapshot = header + player + empty * 7

assert len(snapshot) == 240
assert len(encode(snapshot)) == 484
state = decode_state(snapshot)
assert state["epoch"] == 0x1234
assert len(state["players"]) == 8
assert state["players"][0]["name"] == "ANU"
assert state["players"][0]["ready"] is True
```

These calculations verify serialization examples. They do not test the accept loop, actual socket timing, COM1,
or a phone. Behavioral claims about those parts above come from reading the source.

## 70. Continue to the neighboring pieces

This file answers “how do the bytes get there and come back?” The [bridge guide](bridge.md) explains controller
authentication and HTTP requests. The [launcher guide](run_maze4.md) explains cooperating process startup and
cleanup. The [M4SER guide](M4SER.md) explains the assembly receiver and race lifecycle. The [MAZE4
guide](MAZE4.md) explains the whole game's assembly organization.

The standard-library details used here were checked against current Python documentation through Context7:
[struct](https://docs.python.org/3/library/struct.html), [threading
conditions](https://docs.python.org/3/library/threading.html#condition-objects), and
[sockets](https://docs.python.org/3/library/socket.html).
