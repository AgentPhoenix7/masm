# M4SER.INC — serial messages, player sessions, and the race clock

Source: [M4SER.INC](../M4SER.INC). Shared declarations:
[MAZE4.ASM](../MAZE4.ASM).

This is a standalone walkthrough of the serial/lifecycle include. Read the
[MAZE4 overview](MAZE4.md) for the whole system, [M4CORE](M4CORE.md) for maze
and collision algorithms, and [M4UI](M4UI.md) for the foreground loop and screen.
Those are companion references for the same program. No earlier maze version
or explanation is a prerequisite; the packet layouts, session states, and
timing conventions used by this file are introduced below.

The file contains **19 procedures**. Several procedures also contain named
handlers, such as `RECEIVE_JOIN` and `LEASE_HELD`; those labels are not separate
`PROC` declarations. We will follow those handlers as well.

The central flow is:

```text
UART bytes → hex frame → validated request → player/input state
BIOS ticks → leases and race time → core movement → state snapshot → UART bytes
```

The examples below are derived from source and checked arithmetic. They do not
claim a new DOSBox, network, or physical-phone acceptance test.

---

## 1. What this include contributes

`MAZE4.ASM` inserts this file using:

```asm
INCLUDE M4SER.INC
```

The assembler sees the inserted declarations and instructions as part of the
same program. This is not a second executable or an independently linked driver.

The include switches into `.DATA` to declare serial/session storage, then back
into `.CODE` to declare its procedures. Those sections extend the program's
existing data group and code segment.

## 2. How it differs from an 8085 input exercise

In a simple 8085 program, one input byte might directly represent a switch.
Here one action is represented by several bytes with a defined structure.

For example, a movement request identifies:

```text
which room, which slot, which owner, which maze,
which input sequence, which direction, and whether it is a tap
```

The familiar operations remain loads, comparisons, branches, and stores.
The extra complexity comes from preserving meaning across a byte stream.

## 3. What the caller must establish

The normal `MAIN` in `M4UI.INC` establishes:

```asm
MOV AX,@DATA
MOV DS,AX
MOV ES,AX
CLD
```

Ordinary data references use `DS`. `STOSB`, `STOSW`, and `MOVSB` write through
`ES:DI`; `LODSB` reads through `DS:SI`.

`CLD` makes string instructions advance their pointers. This module relies on
that forward direction and, where it does not set `ES` itself, on `ES=DS`.
An include file does not initialize those CPU registers merely by existing.

## 4. Room phase and player state answer different questions

```asm
PHASE DB 1
```

The room phases are:

```text
1 = lobby
2 = active race
3 = results
```

`PLAYER_STATE`, declared in `MAZE4.ASM`, uses:

```text
0 = empty, 1 = participating, 2 = finished, 3 = DNF
```

A waiting lobby player already has state 1. Motion additionally requires room
phase 2. A slot's state alone does not mean that a race is currently running.

## 5. Epoch, generation, and owner have different scopes

| Variable | Meaning |
| --- | --- |
| `EPOCH` | Current room lifetime |
| `GENERATION` | Current maze generation within that room |
| `OWNER_IDS[i]` | Association between slot `i` and its controller owner |
| `LAST_SEQUENCE[i]` | Most recently accepted movement sequence for that slot |

An old room packet must fail even if its slot number is reused.
An old maze input must fail even if its room and owner still match.
An old direction update must fail even if its room and maze still match.

These fields implement different freshness checks. They are not substitutes
for the bridge's browser authentication.

## 6. Roster declarations

```asm
PLAYER_COUNT DB 0
READY DB 8 DUP(0)
OWNER_IDS DW 8 DUP(0)
PLAYER_NAMES DB 64 DUP(32)
```

`PLAYER_COUNT` counts participants admitted to the roster; it is not recomputed
as the number still racing. During race/results, retained finish/DNF rows remain.

Each name occupies exactly eight bytes. Initial names are spaces, ASCII 32.
They are not `$`-terminated or zero-terminated strings.

`READY[i]` is one byte. `OWNER_IDS[i]` is a word, requiring byte offset `2*i`.

## 7. Session time and direction time are separate

```asm
LAST_SEEN DW 8 DUP(0)
LAST_DIRECTION DW 8 DUP(0)
```

`LAST_SEEN` records the short system-tick value of an owned request passing
the common ownership checks.

`LAST_DIRECTION` records the tick of an accepted direction request.

That separation lets heartbeats keep a controller connected while an old
held direction expires. A connection being alive does not imply that a
previous movement command should remain active indefinitely.

## 8. Input-sequence and direction storage

```asm
LAST_SEQUENCE DW 8 DUP(0)
HAVE_SEQUENCE DB 8 DUP(0)
HELD DB 8 DUP(0)
TAPS DB 8 DUP(0)
```

`HAVE_SEQUENCE=0` allows the first sequence without comparing it to an old value.
Afterward, signed modular differences determine whether an update is newer.

`HELD` persists until replaced or expired. `TAPS` stores one pending direction
for one update. The core consumes the published `DIRECTIONS` array rather
than parsing network fields itself.

## 9. Direction encoding

| Value | Meaning |
| ---: | --- |
| 0 | Idle/release |
| 1 | Up |
| 2 | Down |
| 3 | Left |
| 4 | Right |

These are protocol values, not keyboard scan codes or ASCII digits.
Numeric direction 4 is byte `04H`, not the printable character `'4' = 34H`.

The core later converts a nonzero direction into a maze-cell displacement.
This module decides which requested direction is sufficiently fresh to publish.

## 10. Clock storage

| Variable | Size | Role |
| --- | --- | --- |
| `SYSTEM_TICK` | Word | Short modular scheduling/age counter |
| `LAST_BIOS` | Doubleword | Previous raw BIOS tick reading |
| `ELAPSED_TICKS` | Doubleword | Accumulated active-race ticks |
| `FRAME_TICKS` | Word | Movement-update budget |
| `STATE_TICK` | Word | Last snapshot scheduling tick |

`ELAPSED_TENTHS`, declared in `MAZE4.ASM`, is the converted race time.
The foreground UI uses these shared values to schedule snapshots and redraws.

## 11. Receive storage

```asm
RX_BUFFER DB 96 DUP(0)
RX_SIZE DW 0
RX_ACTIVE DB 0
RX_HALF DB 0
RX_HIGH DB 0
RX_CHECK DB 0
```

The buffer stores **decoded binary bytes**, not the incoming ASCII hex text.
While receiving, its count includes the final checksum byte.

The other fields preserve a partially received frame across calls. A frame
does not have to arrive in one UART poll or one host TCP read.

## 12. Transmit and backup storage

```asm
TX_BUFFER DB 2048 DUP(0)
TX_HEAD DW 0
TX_TAIL DW 0
OUT_BUFFER DB 256 DUP(0)
```

`OUT_BUFFER` stages one binary ACK or snapshot. `TX_BUFFER` stores encoded
wire characters waiting to be sent.

`TX_HEAD` is the next unsent byte; `TX_TAIL` is one past the last queued byte.
`BACKUP_MAP` reserves `CELLS=1037` bytes and `BACKUP_META` reserves 23 bytes
for lobby regeneration rollback.

`OUT_SIZE` and `TEMP_SEQ` are declared but not used by the current instructions.
Do not invent an active role for every declared variable.

---

## 13. `SERIAL_INIT`: select the COM1 registers

COM1 starts at port `3F8H` in this runtime.

| Port | Register use in this module |
| --- | --- |
| `3F8H` | Data, or divisor low byte when DLAB is set |
| `3F9H` | Interrupt enable, or divisor high byte when DLAB is set |
| `3FBH` | Line control and DLAB |
| `3FCH` | Modem control |
| `3FDH` | Line status |

The same port address can select different internal registers depending on DLAB.
This is device behavior, not ordinary array indexing.

## 14. Disable UART interrupts and enable divisor access

The routine begins:

```asm
MOV DX,3F9H
XOR AL,AL
OUT DX,AL
MOV DX,3FBH
MOV AL,80H
OUT DX,AL
```

It writes zero to interrupt enable, then sets line-control bit 7, DLAB.
The following writes to `3F8H` and `3F9H` therefore access the baud divisor.

The intended DOSBox starting configuration has DLAB clear before initialization.
This code is tailored to that environment rather than probing every possible
unknown UART state.

## 15. Set divisor one and 8N1

```asm
MOV DX,3F8H
MOV AL,1
OUT DX,AL
INC DX
XOR AL,AL
OUT DX,AL
MOV DX,3FBH
MOV AL,3
OUT DX,AL
```

The divisor becomes `0001H`, corresponding to the intended 115200-baud setting.
Line-control value `03H` clears DLAB and selects eight data bits, no parity,
and one stop bit: **8N1**.

Finally `03H` at `3FCH` asserts DTR and RTS. No IRQ4 handler is installed.

## 16. Polling versus interrupts

`SERIAL_INIT` disables **UART-generated** interrupts. It does not execute `CLI`
or disable the BIOS timer/keyboard interrupts globally.

The foreground checks UART line status when it has work to do:

```asm
MOV DX,3FDH
IN AL,DX
```

8085 also provides `IN` and `OUT`, but its port-number operand is eight bits.
8086 permits a 16-bit port address in `DX`, allowing access to `3FDH`.
The I/O operation concept transfers; the addressing form differs.

## 17. `QUEUE_CHAR`: append one encoded character

Input: `AL` is the character to queue.

```asm
MOV BX,TX_TAIL
CMP BX,2048
JAE QUEUE_FULL
MOV TX_BUFFER[BX],AL
INC TX_TAIL
```

The procedure saves/restores `BX` around this work. It does not wait for the
UART. At capacity it silently returns without appending.

There is no success Boolean or carry contract. Callers must check/reserve
space before constructing a complete packet.

## 18. Why this queue is linear

Suppose:

```text
TX_HEAD = 1000
TX_TAIL = 2000
```

The unsent data occupies bytes `1000..1999`. The first 1000 bytes are already
sent, but `QUEUE_CHAR` cannot immediately reuse them.

It appends only at `TX_TAIL`. Both indices reset to zero after the queue is
observed drained. There is no wraparound or compaction while data remains.

Therefore “free total bytes” and “available tail space” are different quantities.

## 19. `HEX_NIBBLE`: binary value to printable hex

```asm
AND AL,0FH
ADD AL,'0'
CMP AL,'9'
JBE HEX_CHAR
ADD AL,7
```

Masking keeps values `0..15`. Adding `'0'` directly handles values `0..9`.
Values `10..15` need the seven-character gap between ASCII `'9'` and `'A'`.

For nibble 15:

```text
15 + 30H = 3FH; add 7 → 46H = 'F'
```

It then calls `QUEUE_CHAR`. `AL` is changed to the encoded character.

## 20. `HEX_BYTE`: high nibble before low nibble

```asm
MOV AH,AL
MOV CL,4
SHR AL,CL
CALL HEX_NIBBLE
MOV AL,AH
CALL HEX_NIBBLE
```

The original byte is saved in `AH` while the high nibble is emitted first.
`HEX_NIBBLE` masks the restored original byte to obtain its low nibble.

For `AL=4FH`, output is `'4'`, then `'F'`.
The procedure preserves `AX` and `CX` with pushes/pops. Using `CL` for a
multi-bit shift is compatible with the selected 8086 instruction set.

## 21. The wire frame

```text
colon + uppercase hex(payload + checksum) + line feed
```

The checksum is the XOR of all payload bytes:

```text
checksum = byte0 XOR byte1 XOR ... XOR byteN
```

For illustrative payload `01H,02H`, checksum is `03H`, producing:

```text
:010203\n
```

Here `\n` denotes one LF byte, not the two literal characters backslash and n.
That tiny payload illustrates framing only; it is not a valid game request.

## 22. Why XOR can validate by becoming zero

XOR has these properties:

```text
x XOR x = 0
x XOR 0 = x
```

If the receiver XORs both the payload and its correct checksum, the result is
zero. That is the test used at end of frame.

XOR detects some corruptions, but two compensating changes can cancel.
It provides no encryption or proof of the sender's identity. Browser password,
cookie, and CSRF handling belong to the host bridge, not this checksum.

## 23. `SEND_PACKET`: queue a framed payload

Input: nonempty payload at `DS:SI`, byte count in `CX`, enough tail space.

The procedure queues `':'`, sets `TX_CHECK=0`, then repeats:

```asm
LODSB
XOR TX_CHECK,AL
CALL HEX_BYTE
LOOP SEND_PACKET_BYTE
```

It emits the checksum through `HEX_BYTE` and queues LF byte 10 afterward.
It preserves `AX`, `SI`, and `CX`; the encoded bytes remain in the queue.

## 24. Packet length and the nonempty precondition

For `n` payload bytes:

```text
1 colon + 2*n payload characters + 2 checksum characters + 1 LF
= 2*n + 4 wire bytes
```

The payload loop is entered before any zero-count check. Passing `CX=0`
would still load a byte and then wrap `LOOP`'s counter.
The real callers provide nonzero ACK/snapshot lengths.

`SEND_PACKET` does not validate the payload's meaning or perform whole-frame
capacity checking itself. Its callers enforce those preconditions.

## 25. `SERIAL_FLUSH`: bounded foreground transmission

```asm
MOV CX,512
```

At most 512 bytes can be transmitted in one call. Each iteration first checks
whether `TX_HEAD` has reached `TX_TAIL`, then tests UART readiness:

```asm
IN AL,DX
TEST AL,20H
JZ FLUSH_DONE
```

Line-status bit 5 means the transmit holding register is empty.
If it is not ready, the procedure returns immediately rather than waiting.

## 26. Sending one queued byte and resetting the queue

```asm
MOV AL,TX_BUFFER[BX]
MOV DX,3F8H
OUT DX,AL
INC TX_HEAD
LOOP FLUSH_NEXT
```

When a subsequent empty check observes `HEAD>=TAIL`, both indices become zero.
If the 512th byte exactly drains the queue, the budget path returns first;
the next flush call performs the reset.

This helper uses `AX`, `BX`, `CX`, and `DX` as scratch registers.
It does not preserve them like the small encoding helpers do.

## 27. `PARSE_HEX`: printable hex back to a nibble

```asm
SUB AL,'0'
CMP AL,9
JBE PARSE_HEX_OK
SUB AL,7
CMP AL,10
JB PARSE_HEX_BAD
CMP AL,15
JA PARSE_HEX_BAD
```

ASCII `0..9` becomes values `0..9`. ASCII `A..F` becomes `10..15` after
subtracting the punctuation gap as well.

Return contract: valid nibble in `AL`, `CF=0`; invalid input gives `CF=1`.
Lowercase `a..f` is not accepted by this receiver.

## 28. Parsing examples and status through carry

```text
'7' = 37H → subtract 30H → 7 → valid
'B' = 42H → subtract 30H → 18; subtract 7 → 11 → valid
'G' = 47H → subtract 30H → 23; subtract 7 → 16 → invalid
```

The routine explicitly executes `CLC` or `STC` before `RET`.
The caller uses `JC POLL_INVALID` immediately after the call.

This is a familiar 8085 subroutine convention: a flag can communicate status.
The flag's meaning is agreed by caller and callee, not inferred from the last
arithmetic operation inside the procedure.

## 29. `SERIAL_POLL`: a state machine, not a blocking line read

```asm
MOV SER_BUDGET,256
```

The routine handles at most 256 UART bytes per call. It returns sooner if
line-status bit 0 says no received byte is ready.

Unlike DOS buffered keyboard input, it never waits for an entire frame.
The receive state in memory survives until a later call.

The budget is stored in `SER_BUDGET`, rather than relying on `CX`, because
hex shifts and request-handling procedures also use `CX`.

## 30. Colon starts or restarts a frame

The receiver tests for `':'` before testing `RX_ACTIVE`.
At `POLL_START` it sets:

```text
RX_ACTIVE = 1
RX_SIZE = 0
RX_HALF = 0
RX_CHECK = 0
```

A fresh colon therefore abandons a damaged partial frame and starts over.
Bytes outside an active frame are ignored.

There is no fixed byte alignment in a serial stream; the explicit marker
lets the parser recover alignment without restarting the whole game.

## 31. Assemble two nibble characters into one byte

After the first nibble:

```asm
MOV CL,4
SHL AL,CL
MOV RX_HIGH,AL
MOV RX_HALF,1
```

After the second:

```asm
OR AL,RX_HIGH
MOV RX_HALF,0
```

Receiving `'7'`, then `'8'` produces `70H OR 08H = 78H`.
The parser can return between those characters and resume using `RX_HIGH`.

## 32. Bound the decoded receive array

Before storing each completed byte:

```asm
MOV BX,RX_SIZE
CMP BX,96
JAE POLL_INVALID
MOV RX_BUFFER[BX],AL
INC RX_SIZE
XOR RX_CHECK,AL
```

Valid written indices are `0..95`. A 97th decoded byte abandons the frame
before writing beyond the array.

Because checksum occupies one decoded byte, the framing layer can hold at
most 95 payload bytes. Current operation-specific requests are much smaller.

## 33. End-of-frame validation

On LF, `RX_ACTIVE` is cleared and these conditions are checked:

```text
RX_HALF == 0             no unmatched first nibble
RX_CHECK == 0            payload plus checksum XORs to zero
RX_SIZE >= 6             five-byte request header plus checksum
```

Only then:

```asm
DEC RX_SIZE
CALL RECEIVE_PACKET
```

removes the checksum from the payload count and dispatches the request.
Malformed framing does not receive a normal request ACK.

## 34. Invalid characters and partial input

Invalid hex and decoded-buffer overflow both set `RX_ACTIVE=0`.
The parser then ignores bytes until another colon arrives.

An odd hex-digit count at LF fails because `RX_HALF` is still one.
An unexpected CR is invalid hex; the provided encoder sends LF alone.

An unfinished frame can remain stored across calls without blocking gameplay.
There is no explicit elapsed-time timeout on that partial frame; a colon
restarts it and size checks bound its storage.

## 35. Fragmented valid heartbeat example

Consider this heartbeat payload:

```text
04 34 12 01 00 02 78 56
```

It means opcode 4, request `1234H`, epoch 1, slot 2, owner `5678H`.
Its XOR checksum is `0FH`; the complete 20-byte wire frame is:

```text
:04341201000278560F\n
```

If one poll stops after `:043`, the receiver has stored byte `04H` and saved
high nibble `30H`. The next `'4'` completes `34H`. The LF finally permits
dispatch if the remaining frame and ownership checks pass.

---

## 36. The common request header

| Payload offset | Width | Field |
| ---: | ---: | --- |
| 0 | 1 | Opcode |
| 1 | 2 | Request ID |
| 3 | 2 | Room epoch |

All words use little endian. Request `1234H` is transmitted as bytes `34H,12H`.
Hex encoding converts each byte separately and preserves their order.

The header is five bytes. It does not contain a byte-count field because
the frame parser supplies `RX_SIZE` after removing checksum.

## 37. Opcode sizes

| Opcode | Meaning | Payload length including header |
| ---: | --- | ---: |
| 1 | Configure displayed room password | 17 |
| 2 | Join with an eight-byte name | 13 |
| 3 | Direction/tap input | 14 |
| 4 | Heartbeat | 8 |
| 5 | Leave | 8 |
| 6 | Ready/unready | 9 |

These lengths exclude checksum and ASCII framing.
Each handler requires its exact payload size, not merely a minimum sufficient
to read its favorite fields.

## 38. `RECEIVE_PACKET`: default to rejection

```asm
MOV ACK_CODE,3
MOV ACK_SLOT,0FFH
MOV AX,WORD PTR RX_BUFFER[3]
CMP AX,EPOCH
```

The default is invalid status 3 with no slot.
A room-epoch mismatch selects status 4 and goes directly to the ACK path.

Thus even configuration and joins must carry the current epoch.
Their other contents are not applied when the room lifetime is stale.

## 39. Configuration: validate all twelve characters first

Opcode 1 requires 17 payload bytes. The twelve bytes after the header must
each lie in the inclusive ASCII interval `'2'..'Z'`.

Only after validating all twelve does the code reset `SI` and copy them:

```asm
LEA SI,RX_BUFFER+5
MOV CX,12
REP MOVSB
```

The trailing zero already in `ROOM_CODE` is left intact.
This prevents a bad final character from leaving a partly changed display code.

## 40. Displayed password is not serial authentication

`ROOM_CODE` is the local screen copy of the password generated by the bridge.
This handler does not compare a login password or issue a browser cookie.

Its accepted interval includes punctuation between `'9'` and `'A'`; it is
wider than the bridge's chosen password alphabet.

The configuration handler has no lobby-only check or special owner field.
It relies on the intended private loopback bridge transport, not cryptographic
authentication built into the UART protocol.

## 41. Join identity comes from the request ID

Opcode 2 requires exactly 13 bytes and a nonzero word at payload offset 1.
For joins, that request ID also serves as the stable owner ID.

Before checking lobby or capacity, the handler searches all eight owner fields:

```asm
CMP OWNER_IDS[BX],AX
JE JOIN_ACCEPTED
```

If it finds the same owner, it returns that slot without creating another
participant. This is **idempotency**: retrying the same join has one effect.

## 42. Existing-owner joins bypass new-admission checks

The existing-owner lookup happens before phase, capacity, and new-name validation.

Therefore a correctly sized retry for an existing nonzero owner can succeed
after the race begins or after the room becomes full. It does not rename the
existing player or refresh its `LAST_SEEN` through the owned-request path.

That is different from admitting a new participant after the start.
The ACK confirms an already assigned association, rather than creating a
late entrant.

## 43. New joins need lobby, capacity, and a free slot

A new join requires:

```text
PHASE == 1
PLAYER_COUNT < CAPACITY
some PLAYER_STATE slot equals 0
```

Outside lobby, the handler returns status 1. A full room returns status 2.
The empty-slot search is bounded to eight slots.

The capacity comes from core maze generation; the serial layer does not
recalculate the density/equal-distance rule.

## 44. Validate and store a counted name

The eight name bytes must each be printable ASCII `32..126`.
They are validated before owner, position, or player count is changed.

After successful admission, exactly eight bytes are copied to the record at:

```text
PLAYER_NAMES + 8*slot
```

The serial handler does not itself add padding; the bridge supplies a padded
eight-byte name. A name of eight spaces passes the assembly printable-range
test, even if the browser-facing validation is stricter.

## 45. Initialize a newly admitted player

The handler sets owner, copies `STARTS[slot]` to position, and initializes
both input and liveness timestamps from `SYSTEM_TICK`.

It also sets:

```text
PLAYER_STATE = 1
READY = 0
HAVE_SEQUENCE = 0
HELD = 0
TAPS = 0
DIRECTIONS = 0
```

Only a new admission increments `PLAYER_COUNT`. Existing-owner retries do not.

## 46. Common owned-request fields

All owned operations begin their extra data with:

| Payload offset | Width | Meaning |
| ---: | ---: | --- |
| 5 | 1 | Slot index, 0 through 7 |
| 6 | 2 | Nonzero owner ID |

The handler first requires at least eight bytes, then verifies the slot,
the matching stored owner, and a nonempty player state.

`SI` becomes the unscaled slot and `BX=2*slot` addresses its word fields.
The `AND SI,00FFH` prevents stale `AH` bits from remaining in the index.

## 47. LAST_SEEN changes before operation-specific validation

After ownership checks:

```asm
MOV AX,SYSTEM_TICK
MOV LAST_SEEN[BX],AX
```

Only afterward does the code dispatch opcode 3, 4, 5, or 6 and check each
operation's exact size and other requirements.

Thus an owned but invalid command can refresh session liveness. Examples
include an unknown opcode or a movement packet with a stale generation.
It cannot refresh `LAST_DIRECTION` unless input validation actually succeeds.

## 48. Heartbeat: acknowledge life without extending a direction

Opcode 4 requires exactly eight payload bytes.
The common ownership path already updated `LAST_SEEN`; this handler sets
`ACK_CODE=0` without changing `HELD`, `TAPS`, or `LAST_DIRECTION`.

This permits a stationary phone to remain connected.
It also means repeated heartbeats cannot keep an old movement direction alive.

Ownership checks permit nonempty finished/DNF records too. A heartbeat for
such a record does not turn that player back into a racer.

## 49. Leave: revoke the owned association

Opcode 5 requires exactly eight payload bytes, calls `DROP_PLAYER`, and
acknowledges success.

It is not merely a direction-zero update. A release requests idle input while
retaining the player; leave removes/revokes the association according to phase.

The ACK's slot was set before `DROP_PLAYER`, so the success reply can still
name the slot whose owner has just been cleared.

## 50. Ready/unready: lobby-only Boolean state

Opcode 6 requires:

```text
PHASE == 1
RX_SIZE == 9
payload[8] <= 1
```

It writes that Boolean to `READY[slot]` and acknowledges success.
It does not start the race automatically when the last participant readies.

The local host calls `START_RACE` through the keyboard controls. This separation
keeps host actions outside the phone movement protocol.

## 51. Movement request layout

| Payload offset | Width | Meaning |
| ---: | ---: | --- |
| 0 | 1 | Opcode 3 |
| 1 | 2 | Request ID for ACK matching |
| 3 | 2 | Epoch |
| 5 | 1 | Slot |
| 6 | 2 | Owner |
| 8 | 2 | Maze generation |
| 10 | 2 | Movement sequence |
| 12 | 1 | Direction 0..4 |
| 13 | 1 | Tap flag 0 or 1 |

The request ID and movement sequence are distinct fields with distinct jobs.

## 52. Movement validation order

After common ownership/liveness handling, the input handler requires:

```text
exactly 14 bytes
active race, phase 2
racing player, state 1
matching GENERATION
direction <= 4
tap flag <= 1
new enough sequence
```

No invalid direction is published to the core. A finished or DNF player
cannot resume movement simply by presenting the old valid owner.

## 53. The first sequence needs a separate flag

If `HAVE_SEQUENCE[slot]=0`, the handler accepts the first validated sequence
without subtracting `LAST_SEQUENCE`.

It then stores the accepted sequence and sets `HAVE_SEQUENCE=1`.

This allows the first value to be zero or any other 16-bit value. Treating
an initialized sequence word of zero as an already received packet would
needlessly reject some possible first inputs.

Subsequent input uses the modular comparison described next.

## 54. Signed modular delta rejects duplicate and old input

```asm
MOV DX,AX
SUB DX,LAST_SEQUENCE[BX]
OR DX,DX
JLE RECEIVE_ACK
```

The subtraction computes a 16-bit modular difference. `OR DX,DX` sets the
sign/zero flags from that difference and clears overflow.

`JLE` then rejects zero or a result with its sign bit set. Accepted deltas
are `0001H..7FFFH`, meaning forward progress of 1 through 32767.

This is not a simple signed comparison of the old and new sequence words.

## 55. Sequence wrap examples

| Old | New | Modular delta | Result |
| --- | --- | --- | --- |
| `000AH` | `000BH` | `0001H` | Accept |
| `000AH` | `000AH` | `0000H` | Reject duplicate |
| `000BH` | `000AH` | `FFFFH` | Reject old |
| `7FFFH` | `8000H` | `0001H` | Accept |
| `FFFFH` | `0000H` | `0001H` | Accept wrap |
| `0000H` | `8000H` | `8000H` | Reject half-range jump |

The rule assumes forward updates stay within that half-range window.
It cannot distinguish arbitrary ancient values after unlimited counter reuse.

## 56. Store fresh input and its timestamp

After all validation succeeds:

```asm
MOV LAST_SEQUENCE[BX],AX
MOV HAVE_SEQUENCE[SI],1
MOV AX,SYSTEM_TICK
MOV LAST_DIRECTION[BX],AX
MOV AL,RX_BUFFER[12]
MOV HELD[SI],AL
```

The accepted direction refreshes its own lease.
The routine does not move the player immediately. `GAME_TICK` will publish
a direction and call the core when the next update is due.

## 57. A tap is one pending latch

When the tap flag is nonzero:

```asm
MOV TAPS[SI],AL
MOV HELD[SI],0
```

The first press therefore does not become continuous movement by itself.
At an update, a nonzero pending tap overrides held input once and is consumed.

There is one latch per slot, not a FIFO of button presses. Multiple taps
arriving before an update can replace that slot's previous pending tap.
A tap still makes no successful step if a wall or collision blocks it.

## 58. A release does not erase an already pending tap

A non-tap direction-zero update writes `HELD=0`, but the non-tap path does
not clear `TAPS`.

Consequently a quick press followed by release before the next update can
still deliver the pending one-frame tap. This is distinct from holding a
direction indefinitely.

A tap with direction zero writes a zero tap latch and clears held input.
Input expiry clears both fields. Explicit drop/removal also clears both.

## 59. Worked encoded movement request

For request `1235H`, epoch 1, slot 2, owner `5678H`, generation 3,
sequence `FFFFH`, direction right, and tap 1:

```text
payload: 03 35 12 01 00 02 78 56 03 00 FF FF 04 01
checksum: 0F
frame: :03351201000278560300FFFF04010F\n
```

The payload is 14 bytes; the encoded frame is 32 bytes.
Acceptance still depends on current assembly state. Correct framing alone
does not establish ownership, phase, generation, or sequence freshness.

## 60. `SEND_ACK`: the reply format

The ACK payload is seven bytes:

| Offset | Width | Meaning |
| ---: | ---: | --- |
| 0 | 1 | Type `81H` |
| 1 | 2 | Request ID copied from the received header |
| 3 | 2 | Current epoch |
| 5 | 1 | Status |
| 6 | 1 | Slot or `FFH` |

It is built in `OUT_BUFFER`, then passed to `SEND_PACKET` with `CX=7`.
The encoded frame therefore occupies 18 bytes.

## 61. ACK statuses and congestion guard

```text
0 = accepted
1 = new join outside lobby
2 = new join rejected because room is full
3 = invalid request
4 = stale room epoch
```

`SEND_ACK` skips sending when `TX_TAIL>2028`.
At tail 2028, an 18-byte frame ends at 2046, within the 2048-byte queue.

An ACK can be omitted under congestion; request handling has already occurred.
This is one reason join retry idempotency matters.

## 62. Worked ACK and the meaning of acceptance

An accepted heartbeat for request `1234H`, epoch 1, slot 2 produces:

```text
payload: 81 34 12 01 00 00 02
checksum: A4
frame: :81341201000002A4\n
```

An input ACK means the direction request passed validation and was stored.
It does not mean the player reached the requested neighboring cell.

The later game update may block it, and the next snapshot reports the actual
position, step count, and state.

---

## 63. `DROP_PLAYER`: shared explicit-removal behavior

Input: `SI` is an occupied slot index. The handler first clears:

```text
HELD, TAPS, DIRECTIONS, READY, WARNINGS
```

In lobby it sets player state to empty, clears the owner, and decrements
`PLAYER_COUNT`.

The procedure itself does not guard against decrementing an already empty
lobby slot; its request/host callers check occupancy before calling it.

## 64. Removal after the lobby preserves result rows

Outside lobby, `DROP_PLAYER` clears ownership but does not decrease the
retained roster count or erase the player's counters/name.

If the player is still state 1, it becomes state 3, DNF.
If it is already finished, it remains finished.

That means a finisher does not lose the recorded finish result merely by
leaving the controller. The revoked owner can no longer pass the assembly's
common owned-request check.

## 65. `SEND_STATE`: build one consistent binary snapshot

The snapshot is constructed synchronously in the same foreground execution
that owns game state. The keyboard ISR records keys; it does not alter the
player counters while this serialization runs.

The procedure writes a header, then eight complete records, then queues
the resulting payload as one frame.

It sends all eight records, including empty, finished, and DNF slots.
The internal serial snapshot is different from the bridge's private HTTP
response containing only the authenticated player's record.

## 66. Snapshot header offsets

| Offset | Width | Field |
| ---: | ---: | --- |
| 0 | 1 | Type `82H` |
| 1 | 2 | Epoch |
| 3 | 2 | Generation |
| 5 | 1 | Phase |
| 6 | 1 | Capacity |
| 7 | 1 | Collision mode |
| 8 | 1 | Player count |
| 9 | 1 | Winner mask |
| 10 | 2 | Exit cell |
| 12 | 2 | Common start distance |
| 14 | 2 | Floor count |
| 16 | 4 | Elapsed tenths |
| 20 | 4 | Best score |

The next byte, offset 24, begins player record zero.

## 67. Player-record offsets

Within each record:

| Relative offset | Width | Field |
| ---: | ---: | --- |
| 0 | 1 | State |
| 1 | 1 | Warning |
| 2 | 2 | Owner |
| 4 | 2 | Position |
| 6 | 4 | Steps |
| 10 | 4 | Penalty tenths |
| 14 | 4 | Finish tenths |
| 18 | 1 | Ready |
| 19 | 8 | Name |

Each record is 27 bytes. Player `i` begins at absolute payload offset `24+27*i`.
Player 7 begins at 213 and ends at 239 inclusive.

## 68. Snapshot size, source scaling, and tail reservation

```text
24 header bytes + 8*27 record bytes = 240 payload bytes
2*240+4 = 484 encoded wire bytes
```

This fits the 256-byte `OUT_BUFFER`.
`SEND_STATE` skips when `TX_TAIL>1400`; at tail 1400 its frame ends at 1884.
The guard is deliberately more conservative than the exact required space.

Inside the player loop, `BP` is the slot; word fields use `2*slot`, doublewords
use `4*slot`, and names use `8*slot`. The serialized 27-byte record is packed;
it does not mirror the separate-array layout used in assembly memory.

## 69. Why STOSW produces little-endian fields

For a word value `1234H`:

```text
STOSW writes byte 34H, then byte 12H
```

For a doubleword, the code writes its low word followed by its high word.
The result is little-endian across all four bytes as well.

`REP MOVSB` copies the eight name bytes without a terminator.
At the end, `DI-OFFSET OUT_BUFFER` supplies the payload count to `SEND_PACKET`.
No hardcoded 240 is required in the serialization loop itself.

## 70. A small snapshot-decoding example

Suppose record zero contains:

```text
state=1, warning=2, owner=5678H, position=193
steps=10, penalty=30, finish=0, ready=1, name="ANIS    "
```

Its first fields are bytes:

```text
01 02 78 56 C1 00 0A 00 00 00 1E 00 00 00 ...
```

Position 193 is `00C1H`; penalty 30 means 3.0 seconds, not 30 seconds.
The record's name includes four trailing space bytes after `ANIS`.

---

## 71. `READ_CLOCK`: read the raw BIOS tick pair

```asm
MOV AH,0
INT 1AH
MOV AX,DX
MOV BX,CX
SUB AX,WORD PTR LAST_BIOS
SBB BX,WORD PTR LAST_BIOS+2
```

BIOS returns the raw tick count in `CX:DX`. The procedure copies it to
`BX:AX`, then subtracts the previous doubleword.

`SUB` handles the low word and `SBB` subtracts the high word plus any borrow.
This is the familiar 8085 multi-byte subtraction idea applied to 16-bit words.
Both processors use `SBB` for borrow propagation, with different operand forms.

## 72. Correct the daily BIOS rollover

If the doubleword subtraction borrows, the code adds one BIOS-day count:

```asm
ADD AX,00B0H
ADC BX,0018H
```

The combined constant is `0018:00B0H = 1800B0H` ticks.
It then stores the newly read raw `CX:DX` into `LAST_BIOS`.

This handles the ordinary one-midnight crossing between regular polls.
It does not count an arbitrary number of whole days during a long suspension,
nor does it use the BIOS return's midnight indicator to reconstruct them.

## 73. Worked midnight trace

Suppose:

```text
previous raw count = 0018:00AEH   two ticks before rollover
new raw count      = 0000:0003H   three ticks after rollover
```

The subtraction is negative in unsigned doubleword terms. Adding the daily
count gives:

```text
3 - 1800AEH + 1800B0H = 5 ticks
```

The game advances by five ticks rather than treating midnight as a huge jump.
The stored raw reading becomes three for the next subtraction.

## 74. Update short timers and active-race time

The low difference word advances:

```asm
ADD SYSTEM_TICK,AX
ADD FRAME_TICKS,AX
```

Only phase 2 additionally accumulates the full difference:

```asm
ADD WORD PTR ELAPSED_TICKS,AX
ADC WORD PTR ELAPSED_TICKS+2,BX
```

It converts that total and stores `ELAPSED_TENTHS`. Lobby waiting and results
display do not keep increasing the race's elapsed time.

## 75. Short modular ages

Lease calculations subtract two word tick values:

```text
age = (SYSTEM_TICK - saved_tick) modulo 65536
```

For current `0007H` and saved `FFF0H`, the age is 23 ticks despite the wrap.
That is sufficient for the short 14- and 546-tick thresholds when regularly
polled.

It is not a general long-duration clock: after whole 65536-tick wraps,
the age alone cannot tell how many wraps occurred. The full race clock is
stored separately as a doubleword for that reason.

## 76. `GAME_TICK`: first decide whether an update is due

```asm
CMP FRAME_TICKS,2
JB GAME_DONE
MOV FRAME_TICKS,0
```

An update requires at least two accumulated BIOS ticks, roughly 0.11 seconds.
The code uses literal 2 here; changing `MOVE_TICKS` alone does not alter this
comparison.

The budget resets to zero rather than subtracting two repeatedly. A late
foreground call performs one update and discards extra movement backlog,
while `READ_CLOCK` still accounts for elapsed race time.

## 77. Check session timeout before direction freshness

For each state-1 slot during a race:

```text
if age since LAST_SEEN >= 546 ticks:
    state = DNF
    clear held, tap, direction, ready, warning
    skip further input handling for this slot
```

At the 18.2-Hz approximation, 546 ticks is 30 seconds.
The comparison includes equality: an age of exactly 546 expires.

Lobby participants skip this race-DNF check. Expiration is applied when the
foreground update runs, not by a separate asynchronous timer interrupt.

## 78. Automatic DNF differs from DROP_PLAYER

The timeout branch does **not** clear `OWNER_IDS` or decrement the retained
roster count.

The player cannot move because it is no longer state 1. Its owner remains
associated with the terminal DNF row so the bridge can continue authenticated
status access.

Explicit leave/host removal instead clears the owner through `DROP_PLAYER`.
Neither a heartbeat nor an accepted join retry resurrects a DNF player into
the active race.

## 79. Expire stale held/tap input

For a state-1 slot that has not just timed out:

```text
if age since LAST_DIRECTION >= 14 ticks:
    HELD = 0
    TAPS = 0
```

Fourteen ticks is approximately 0.77 seconds.
This direction freshness check also runs for participating lobby slots,
although normal network movement is only accepted during the race.

A recent heartbeat affects `LAST_SEEN`, so it cannot renew this separate lease.

## 80. Publish and consume one direction

```asm
MOV AL,HELD[SI]
CMP TAPS[SI],0
JE LEASE_SAVE
MOV AL,TAPS[SI]
MOV TAPS[SI],0
```

The selected `AL` is stored into `DIRECTIONS[slot]`.
An unexpired tap overrides held input for this update, then its latch clears.
On the next update, only whatever held input remains can repeat.

Lease checks therefore precede core proposal generation. The core sees a
bounded direction value already selected from fresh controller state.

## 81. Run the core and detect race completion

Only phase 2 executes:

```asm
CALL BUILD_INTENTS
CALL RESOLVE_MOVES
CALL COMMIT_MOVES
CALL UPDATE_WARNINGS
```

Then `GAME_TICK` scans for any remaining state-1 player. If none remains,
it sets phase 3 and calls `FIND_WINNERS`.

A race can end because everyone finished, everyone became DNF, or a mixture.
Winner selection includes finishers only; an all-DNF race has no winner bits.

## 82. Worked release/heartbeat/timeout timeline

```text
SYSTEM_TICK=1000: accept held right; LAST_DIRECTION=LAST_SEEN=1000
SYSTEM_TICK=1010: heartbeat; LAST_SEEN=1010, direction age remains 10
update at 1014: direction age 14; clear held/tap, publish idle
SYSTEM_TICK=1020: heartbeat; player remains connected and stationary
no further owned requests:
update at or after 1566: age since last seen reaches 546; mark DNF
```

The final transition requires an update to run. Its wall-clock instant may
be later than the threshold if execution or transport has been delayed.

## 83. `START_RACE`: validate the entire lobby roster

The procedure requires lobby phase and `PLAYER_COUNT>=2`.
It then scans all eight slots, skipping empty ones and refusing if any
nonempty slot has `READY=0`.

On success:

```text
PHASE = 2
ELAPSED_TICKS = 0
ELAPSED_TENTHS = 0
FRAME_TICKS = 0
```

It returns without a separate Boolean result. The changed phase is the result.
It does not reset every participant's liveness timestamp at start.

## 84. `REGENERATE`: copy a rollback image before generation

Only lobby phase permits this operation.
The routine saves `CELLS` maze bytes into `BACKUP_MAP` and copies 23 bytes
starting at `EXIT_POS` into `BACKUP_META`.

Those contiguous 23 bytes are:

```text
EXIT_POS + COMMON_DISTANCE + FLOOR_COUNT + CAPACITY + STARTS
2 + 2 + 2 + 1 + 16 = 23
```

It calls `GENERATE_MAZE`. If the new capacity is less than `PLAYER_COUNT`,
it restores both saved regions and returns without accepting that new map.

## 85. Accepted regeneration and slot-indexed starts

On acceptance, `GENERATION` increments. For all eight slots, the routine
copies `STARTS[slot]` into position and clears ready, held, and tap fields.

It does not compact a sparse roster or shuffle players into lower slot indices.
Its capacity comparison checks the **count**, while position assignment uses
the **slot number**. Those are different quantities when low slots are vacant.

Do not claim that this routine proves every occupied sparse slot lies within
the newly selected usable start prefix. Its exact code does not perform that
extra check. New generation packets must still satisfy the input identity check.

## 86. Regeneration does not reset a whole room

Owners, epoch, names, player count, and input-sequence history remain.
Readiness must be set again before starting on the changed map.

`DIRECTIONS` is not explicitly cleared in `REPOSITION`, but held/tap inputs
are cleared and lobby phase prevents core motion. The next lease update
publishes the resulting idle input.

The rollback buffers here are separate from `BEST_MAZE/BEST_META`, which
the core generator uses internally while comparing candidate maps.

## 87. `NEW_ROOM`: reset outside an active race

If phase is 2, the routine returns without resetting the race.
Otherwise it calls `RESET_GAME`, increments `EPOCH`, skips zero on wrap,
increments `GENERATION`, and establishes a new lobby.

It clears roster count, ready flags, owners, and names, restores twelve
password-display dashes, then generates a new maze.

Some old serial timestamp/sequence bytes remain in storage, but old owners
are cleared and later new joins initialize their live fields. The changed
epoch also rejects requests belonging to the previous room.

## 88. Host-driven lifecycle, not a serial host-command API

The six request opcodes do not provide start, regenerate, new-room, or
collision-mode operations to phones.

`M4UI.INC` calls `START_RACE`, `REGENERATE`, `NEW_ROOM`, and `DROP_PLAYER`
from local host key handling. The procedures themselves enforce their
phase rules where required.

The host bridge observes a changed epoch and replaces its browser-side room
credentials separately. This include neither generates cryptographic tokens
nor stores HTTP session cookies.

---

## 89. `DIVIDE_U32`: why ordinary word DIV is not enough

8086 word division uses:

```text
DX:AX / BX → quotient AX, remainder DX
```

The dividend is 32 bits, but the quotient must fit 16 bits. A large quotient
would cause a divide exception.

This helper instead returns a full 32-bit quotient in `DX:AX` and remainder
in `CX`. Input divisor `BX` must be nonzero.
It preserves `SI` and `DI`, used for intermediate storage.

## 90. Divide the high word first

```asm
MOV SI,AX
MOV AX,DX
XOR DX,DX
DIV BX
MOV DI,AX
```

The original low word is saved in `SI`. The first division computes:

```text
high_word = high_quotient*divisor + high_remainder
```

`DI` saves the high quotient and `DX` retains that remainder.
Because the first dividend has high half zero, a nonzero word divisor
produces a quotient that fits a word.

## 91. Bring down the original low word

```asm
MOV AX,SI
DIV BX
MOV CX,DX
MOV DX,DI
```

The second division uses `high_remainder:original_low` as its dividend.
Its high word is smaller than the divisor, so its quotient fits in `AX`.

The final quotient combines saved high quotient `DI` and low quotient `AX`.
The final remainder is moved into `CX`, freeing `DX` for the quotient's high word.
This is long division in base 65536.

## 92. Worked doubleword division

Take input `DX:AX=1234:5678H` and divisor 10.

```text
First:  0000:1234H / 10 → high quotient 466 = 01D2H, remainder 0
Second: 0000:5678H / 10 → low quotient 2213 = 08A5H, remainder 6
Return: DX:AX = 01D2:08A5H, CX = 6
```

The original value is 305419896 decimal. Its quotient is 30541989 and
remainder six, confirming the combined result.

An 8085 implementation would use software division and more byte operations,
but the idea of carrying the remainder into the next part is the same.

## 93. `TICKS_TO_TENTHS`: integer time conversion

Input is an unsigned tick total in `DX:AX`; output is tenths in `DX:AX`.
The helper preserves `BX`, `CX`, `SI`, `DI`, and `BP`.

The source approximates BIOS timing as 18.2 ticks per second:

```text
tenths = floor(ticks * 100 / 182)
```

No floating-point arithmetic is needed. Fractional time is represented by
an integer scale: 30 means 3.0 seconds, 137 means 13.7 seconds.

## 94. Divide before multiplying

The helper first calls `DIVIDE_U32` with divisor 182, obtaining:

```text
ticks = 182*q + r, with 0 <= r < 182
```

Therefore:

```text
floor(ticks*100/182) = 100*q + floor(100*r/182)
```

This avoids forming the potentially oversized intermediate `ticks*100`.
The final converted value fits a doubleword for every unsigned doubleword
tick input because the conversion scale `100/182` is less than one.

## 95. Multiply the quotient in two word pieces

After division, `q` is in `DX:AX`. The source saves its high word in `SI`,
then multiplies the low word by 100.

```text
low(q)*100 → partial low word in DI, carry word in BP
high(q)*100 + BP → final high word
```

It restores the low partial word into `AX` and combines the high result in `DX`.
The remainder saved on the CPU stack is handled separately afterward.

This is another instance of multiword arithmetic rather than an instruction
that operates on a native 32-bit 8086 register.

## 96. Add the remainder contribution

Since `r<182`, `r*100` is at most 18100 and safely fits a word.
The source multiplies that remainder by 100, divides by 182, then adds the
fractional contribution to the saved `100*q` result:

```asm
ADD AX,BX
ADC DX,0
```

`ADC` carries an overflow from the low result word into the high word.
Ordinary saved-register `POP` operations restore the caller's scratch values
after the complete doubleword result is ready.

## 97. Checked time-conversion examples

| Ticks | q = ticks/182 | r | Returned tenths | Displayed seconds |
| ---: | ---: | ---: | ---: | --- |
| 0 | 0 | 0 | 0 | 0.0 |
| 182 | 1 | 0 | 100 | 10.0 |
| 10000 | 54 | 172 | 5494 | 549.4 |
| 65536 | 360 | 16 | 36008 | 3600.8 |

For 10000 ticks, `100*54 + floor(17200/182) = 5400+94`.
Computing from the accumulated tick total avoids repeatedly truncating and
losing a fraction on every individual foreground poll.
The 18.2-Hz approximation still differs from a precision physical clock.

## 98. Procedure contracts at a glance

| Procedure | Main input/result and preservation |
| --- | --- |
| `SERIAL_INIT` | Programs UART; uses AX/DX as scratch |
| `QUEUE_CHAR` | AL character; appends if room; preserves BX |
| `HEX_NIBBLE` | AL low nibble; queues one character; changes AL |
| `HEX_BYTE` | AL byte; queues two characters; preserves AX/CX |
| `SEND_PACKET` | DS:SI, CX nonzero; queues frame; preserves AX/SI/CX |
| `SERIAL_FLUSH` | Shared queue; sends at most 512; scratch AX/BX/CX/DX |
| `PARSE_HEX` | AL ASCII; returns nibble/CF status |
| `SERIAL_POLL` | Shared parser; consumes at most 256 UART bytes |
| `SEND_ACK` | RX header and ACK fields; may queue reply |
| `RECEIVE_PACKET` | RX payload and RX_SIZE; mutates validated session state |
| `DROP_PLAYER` | SI occupied slot; clears/revokes according to phase |
| `SEND_STATE` | Shared game state; may queue 240-byte payload |
| `READ_CLOCK` | BIOS count; advances clock storage |
| `GAME_TICK` | Shared frame/lease state; may call core update and results |
| `START_RACE` | Lobby state; phase changes on success |
| `REGENERATE` | Lobby state; replaces or rolls back maze |
| `NEW_ROOM` | Nonrace state; resets room and changes epoch |
| `DIVIDE_U32` | DX:AX / BX; quotient DX:AX, remainder CX; preserves SI/DI |
| `TICKS_TO_TENTHS` | DX:AX ticks → tenths; preserves BX/CX/SI/DI/BP |

The foreground routines without explicit preservation should be treated as
scratch-register users. Their useful results primarily live in shared memory.

## 99. Source-shaped foreground pseudocode

```text
on every foreground iteration:
    read raw BIOS time and update elapsed counters
    receive at most 256 UART bytes
        frame valid requests and dispatch handlers
        queue ACK when space permits

    process host keys

    if at least two frame ticks accrued:
        discard movement backlog by setting frame budget to zero
        for each participating slot:
            if racing and session too old:
                mark DNF and clear input
            else:
                expire stale direction
                publish pending tap or held direction
                consume pending tap

        if phase is race:
            build proposals, resolve collisions, commit, update warnings
            if no racer remains:
                enter results and select winners

    periodically build and queue a state snapshot
    transmit up to 512 queued bytes while UART is ready
    periodically redraw or idle until an interrupt
```

The outer order belongs to `M4UI.INC`; the named serial/lifecycle work is
implemented by this include. No background assembly worker races those updates.

## 100. Important limitations and boundary assumptions

- UART/checksum validity does not prove browser identity. The host bridge is
  part of the trust boundary; serial owner IDs are association values.
- ACKs and snapshots may be skipped under congestion. The TX buffer is linear,
  and no UART helper promises eventual delivery or retransmits on its own.
- Incoming partial frames have bounded storage but no elapsed-time timeout.
- A valid existing-owner join retry bypasses new-admission checks; an owned
  invalid request can renew liveness before command-specific rejection.
- A release clears held input without necessarily clearing a pending tap.
- Short word ages and one-day rollover correction assume regular execution,
  rather than arbitrary multi-day suspension and unlimited counter history.
- Regeneration checks count against capacity but assigns starts by slot index;
  it does not compact sparse rosters or validate that usable-prefix condition.
- The module assumes the caller's segments, string direction, COM1 mapping,
  and intended DOSBox device configuration are established correctly.

These describe the checked-in behavior, not changes made to the program.

## 101. What transfers from 8085

| Familiar idea | Where it appears here |
| --- | --- |
| IN/OUT on peripheral ports | COM1 configuration and polling |
| Masking and shifting bits | Hex nibble conversion |
| Carry as subroutine status | `PARSE_HEX` with CLC/STC and JC |
| Counter and pointer loops | Packet bytes, name bytes, roster scans |
| Multi-byte add/subtract | Word ADD/ADC and SUB/SBB pairs |
| Preserving working registers | Encoding and arithmetic helpers |
| Manual state machine | Partial-frame parser and room phases |
| Long division with remainder | `DIVIDE_U32` across two word pieces |

The new hardware/software details are x86 segments, implicit string operands,
the PC UART/BIOS interface, and network-session protocol fields. Their purpose
is understandable using the same load/compare/branch model you know already.

## 102. Exam-ready explanation

`M4SER.INC` connects validated serial requests to the authoritative assembly
game. It configures COM1, incrementally parses colon/hex/XOR/LF frames, checks
request lengths and room/player identity, and records fresh controller input.
Join retries reuse an owner association; readiness and local host start control
the lobby-to-race transition.

The clock code measures BIOS tick differences, corrects normal midnight wrap,
and maintains separate session, direction, frame, and race timing. Updates
expire stale input or disconnected racers before invoking the core movement
pipeline. State snapshots contain a 24-byte header and eight 27-byte records.
Bounded polling and transmission share foreground time with the game, while
two-word arithmetic implements 32-bit division and time conversion on 8086.
