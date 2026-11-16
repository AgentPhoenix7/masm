# M4UI.INC — host controls, the keyboard interrupt, and the PC display

Source: [M4UI.INC](../M4UI.INC).

Read this alongside [MAZE4.ASM](../MAZE4.ASM), which declares shared game data
and inserts this file into the executable.
[MAZE4.md](MAZE4.md) explains the complete system;
[M4CORE.md](M4CORE.md) covers game rules;
[M4SER.md](M4SER.md) covers the transport and lifecycle routines called here.

This is a detailed guide to the UI module itself.
It follows the actual instructions and assumes you already understand basic
8085 registers, flags, pointers, loops, subroutines, and interrupts.
No earlier maze version or guide is required. The MAZE4-specific state,
calling conventions, input representation, and video layout are introduced here.
It does not report a newly assembled executable or a fresh phone/game test.

The module's three jobs are:

```text
MAIN and HOST_CONTROLS
    → coordinate foreground work and local host actions

keyboard-vector routines and KEYBOARD_ISR
    → capture host key presses without using the BIOS key queue

video routines and DRAW_SCREEN
    → render authoritative game state into PC text-video memory
```

---

## 1. An include is source insertion, not another running program

The main source contains:

```asm
INCLUDE M4CORE.INC
IFNDEF M4_TEST
INCLUDE M4SER.INC
INCLUDE M4UI.INC
ENDIF
```

MASM reads the included text as part of the same assembly unit.
`M4UI.INC` does not run independently and is not a separately linked process.
Its `MAIN` is the normal program entry point selected by `END MAIN`.

This also explains why UI code can refer directly to `PHASE`, `SYSTEM_TICK`,
`READY`, `POSITIONS`, and routines declared in the other included files.
They share the executable's data group and code segment.

Tests defining `M4_TEST` omit the normal serial/UI includes and can provide
their own entry point around the same core.

---

## 2. Where UI responsibility ends

The UI does not calculate legal moves, collision penalties, shortest routes,
player leases, serial ownership, or winners.
It calls the routines responsible for those decisions and displays their state.

Examples:

| UI operation | Routine providing the decision |
| --- | --- |
| Space requests a race start | `START_RACE` in the serial/lifecycle module |
| R requests another map | `REGENERATE` |
| N requests another room | `NEW_ROOM` |
| Number key requests removal | `DROP_PLAYER` |
| Periodic movement update | `GAME_TICK`, which calls the core |
| Display an adjusted score | `GET_SCORE` in the core |

The host keyboard is not a player movement keyboard in this version.
Phone directions arrive through the serial path.

---

## 3. The module's data at a glance

```asm
KEY_DOWN DB 256 DUP(0)
KEY_EDGE DB 256 DUP(0)
EXTENDED_KEY DB 0
PAUSE_BYTES DB 0
OLD_INT9 DD 0
KEY_HOOKED DB 0
```

The first four objects describe raw host-keyboard input.
`OLD_INT9` holds a saved far pointer to the previous keyboard handler.
`KEY_HOOKED` records whether the replacement handler was installed.

Display state is separate:

```asm
VIDEO_ATTR DB 07H
SHOW_SCORES DB 0
DRAW_TICK DW 0FFFFH
PLAYER_COLORS DB 0EH,0BH,0DH,09H,0CH,0AH,0FH,06H
```

`VIDEO_ATTR` is the current text attribute for video helper output.
`SHOW_SCORES` selects map/roster view or the statistics table.
`DRAW_TICK` throttles full redraws.
`PLAYER_COLORS` gives a color to each slot from zero through seven.

---

## 4. Held state and an edge latch mean different things

For a scan-code index `k`:

```text
KEY_DOWN[k] = 1 → the key is currently held
KEY_EDGE[k] = 1 → a press occurred and the foreground has not consumed it
```

A release clears `KEY_DOWN`, but does not clear `KEY_EDGE`.
A tap can therefore survive the interval between two foreground checks.

`KEY_EDGE` is a Boolean latch: its stored values are zero or one, rather than
the number of presses waiting to be consumed.
Several complete taps before consumption can merge into one pending action.

The intended host behavior is one action per observed new press, rather than
repeated toggles for every movement frame while a key remains held.

---

## 5. The 256-entry index space separates extended keys

An ordinary scan code uses the lower half of each key array.
An E0-prefixed key uses the corresponding index with bit seven set.

```text
ordinary base code 1CH → index 001CH
E0-prefixed base 1CH  → index 009CH
```

The break/release bit of an incoming byte is not used directly as an array
index bit.
The handler saves that release information, removes it, and then adds its
separate remembered E0 marker.

That distinction prevents an extended key from masquerading as its ordinary
counterpart merely because both share the same base scan-code number.

---

## 6. UI strings are zero-terminated, but names are counted records

For example:

```asm
UI_TITLE DB 'MAZE4 | Internet phone race | Tab: scores | Esc: quit',0
UI_READY DB 'READY',0
UI_WAIT DB 'WAIT ',0
```

`VIDEO_TEXT` stops on a zero byte.
It does not use the `$` convention of DOS `INT 21H/AH=09H`.

Player names are different:

```asm
PLAYER_NAMES DB 64 DUP(32)
```

That shared declaration provides eight eight-byte, space-padded names.
The renderer prints exactly eight bytes for each name.
There is no per-name zero terminator and no search for a `$`.

---

## 7. `MAIN`: initialize data, extra segment, and direction

```asm
MOV AX,@DATA
MOV DS,AX
MOV ES,AX
CLD
```

`DS` points to the data group for ordinary variables and source strings.
`ES` also starts at that data group because other modules use `REP MOVSB`,
`REP STOSB`, and `REP STOSW` to manipulate data arrays.

`CLD` clears the direction flag.
String instructions then advance their pointers instead of decrementing them.

These are shared contracts, not just UI preferences.
Video helpers temporarily change `ES` to video memory and restore it so that
later lifecycle routines still have the expected data destination segment.

8085 has no `DS`, `ES`, or direction flag.
Its load/store-and-increment sequences provide the conceptual comparison.

---

## 8. Select and clear PC text mode

```asm
MOV AX,3
INT 10H
MOV AH,1
MOV CX,2000H
INT 10H
```

BIOS video service zero with mode three selects the familiar 80-column,
25-row color text display and clears it with this request value.
The following cursor-shape request hides the blinking cursor in the intended
PC-compatible environment.

The video mode and its `B800H` memory layout are PC platform conventions.
They are not universal features of every 8086 system.

The executable does not save and restore an arbitrary previous video mode.
Its normal exit explicitly selects mode three again.

---

## 9. Capture the clock before generating the maze

```asm
MOV AH,0
INT 1AH
MOV WORD PTR LAST_BIOS,DX
MOV WORD PTR LAST_BIOS+2,CX
MOV AX,DX
XOR AX,CX
OR AX,1
MOV RNG_SEED,AX
```

BIOS clock service zero returns a daily tick reading in `CX:DX`.
The code saves both words for the first `READ_CLOCK` delta.

It also combines the tick words and forces the result odd to form the initial
maze-generator seed.
The OR guarantees a nonzero odd seed; it does not make the generator
cryptographically unpredictable.

That seed is for maze variation, not browser authentication.
The HTTPS bridge handles controller credentials using host facilities.

---

## 10. Startup calls occur in a deliberate order

```asm
CALL GENERATE_MAZE
CALL SERIAL_INIT
CALL INSTALL_KEYS
```

The map and capacity are generated before normal serial admission and host
keyboard handling begin.
`SERIAL_INIT` configures COM1 for polled operation.
`INSTALL_KEYS` then installs the host keyboard ISR.

The program enters `MAIN_LOOP` after those calls.
There is no separate unconditional `DRAW_SCREEN` immediately before that loop;
the first redraw follows the normal timing gate.

If generation leaves capacity below two, the loop still runs and the renderer
can display the retry/error footer.

---

## 11. The foreground loop's ordering

The central call order is:

```asm
CALL READ_CLOCK
CALL SERIAL_POLL
CMP KEY_EDGE[1],0
JNE EXIT_MAIN
CALL HOST_CONTROLS
CALL GAME_TICK
```

First refresh time, then process a bounded amount of incoming serial data.
Escape is checked before any host action or new game update in that iteration.
Host controls run before the movement/lifecycle tick.

As a result, a valid Space press can start the room before that iteration's
`GAME_TICK` checks its phase.
`START_RACE` itself resets the frame budget, so it does not immediately spend
old lobby time as race movement.

All those routines execute in the foreground, not from the keyboard ISR.

---

## 12. Time, input, rules, output: one loop, different schedules

`READ_CLOCK` maintains `SYSTEM_TICK`, a 16-bit accumulated tick counter.
`GAME_TICK` normally runs movement when its own frame budget reaches two ticks.

Snapshots have a four-tick gate:

```asm
MOV AX,SYSTEM_TICK
SUB AX,STATE_TICK
CMP AX,4
JB MAIN_FLUSH
MOV AX,SYSTEM_TICK
MOV STATE_TICK,AX
CALL SEND_STATE
```

`SEND_STATE` queues a consistent state snapshot when transport capacity permits.
Calling it does not mean every byte has already left the UART.

These gates keep clock maintenance, serial polling, game updates, snapshot
creation, and screen drawing from becoming one expensive operation on every
loop iteration.

---

## 13. Unsigned subtraction handles short low-word wraps

The tick gates subtract the previous low-word reading from the current reading.
The 16-bit result is modular arithmetic:

```text
previous = FFFEH
current  = 0002H
current - previous, keeping 16 bits = 0004H
```

Thus a normal short interval spanning a low-word wrap still compares as four.
This is useful for periodic scheduling and leases.

It does not identify arbitrarily long delays spanning many complete wraps.
Race elapsed time is maintained separately using 32-bit quantities and BIOS
daily-rollover handling in `READ_CLOCK`.

---

## 14. The initial `FFFFH` timing markers

`STATE_TICK` in the serial module and `DRAW_TICK` here start at `FFFFH`.
An illustrative sequence, assuming `SYSTEM_TICK` initially reads zero, is:

| `SYSTEM_TICK` | Difference from `FFFFH` | Initial draw gate | Initial snapshot gate |
| --- | --- | --- | --- |
| 0 | 1 | below 2 | below 4 |
| 1 | 2 | eligible | below 4 |
| 3 | 4 | depends on updated draw marker | eligible |

Generation and startup can already have consumed ticks before the first loop,
so actual first-operation timing depends on that elapsed time.

After an operation, its marker is assigned the current tick.
The ordinary intervals are then two ticks for redraw and four for snapshots.

---

## 15. Flush the UART before considering a redraw

```asm
CALL SERIAL_FLUSH
MOV AX,SYSTEM_TICK
SUB AX,DRAW_TICK
CMP AX,2
JB MAIN_IDLE
MOV AX,SYSTEM_TICK
MOV DRAW_TICK,AX
CALL DRAW_SCREEN
```

`SERIAL_FLUSH` sends only bytes the UART is ready to accept, with a bounded
per-call budget.
It returns instead of waiting for the next hardware-ready transition.

The screen is drawn at most once per two accumulated ticks under this gate.
That is approximately nine redraws per second at the usual BIOS timer rate.
The source does not promise a fixed frame rate under every host scheduling load.

A key toggle changes `SHOW_SCORES` immediately in memory, but its visible
effect appears at the next eligible redraw.

---

## 16. Pending transmission keeps the loop active

```asm
MOV AX,TX_HEAD
CMP AX,TX_TAIL
JNE MAIN_LOOP
STI
HLT
JMP MAIN_LOOP
```

`TX_HEAD` identifies the next unsent encoded byte; `TX_TAIL` marks the end.
If they differ, the program immediately loops to keep servicing output and
other foreground work.

When the queue is empty, `STI` enables maskable interrupts and `HLT` sleeps
until an interrupt or other appropriate wakeup event occurs.
The BIOS timer and keyboard can wake it.

COM1 is configured for polling with UART interrupts disabled.
An arriving serial byte is therefore not being relied on to trigger a UART
interrupt that wakes this loop; a later timer/keyboard wakeup allows polling.

---

## 17. `STI`/`HLT` versus an 8085 idle loop

8085 also has a halt instruction and an interrupt-enable instruction.
The conceptual purpose is familiar: wait for hardware rather than repeatedly
executing a useless jump.

The exact x86 sequence, interrupt-enable flag, hardware interrupt controller,
and PC IRQ assignments are different.
Do not substitute 8085 `EI` into this source or assume identical interrupt
entry/return stack formats.

The pending-TX branch deliberately bypasses `HLT`.
Consequently this is not an unconditional sleep at the end of every iteration.

---

## 18. `HOST_CONTROLS`: consume press edges, not held state

The routine reads `KEY_EDGE`, clears a handled entry, then executes its action.
It does not repeatedly act on `KEY_DOWN=1`.

| Key | Ordinary scan index | Action |
| --- | --- | --- |
| Tab | `0FH` | toggle map/table view |
| Space | `39H` | request start |
| M | `32H` | toggle collision mode in lobby |
| R | `13H` | request lobby map regeneration |
| N | `31H` | request a new room outside an active race |
| 1 through 8 | `02H` through `09H` | remove corresponding occupied slot |
| Escape | `01H` | exit, checked by `MAIN` |

These are local PC host controls.
The public phone protocol does not provide a general “execute host key” command.

---

## 19. Tab toggles one display-state bit

```asm
CMP KEY_EDGE[0FH],0
JE HOST_SPACE
MOV KEY_EDGE[0FH],0
XOR SHOW_SCORES,1
```

XOR with one switches the low bit between zero and one.
With the variable initialized to zero and modified this way, it remains a
two-state view selector.

```text
0 → map plus side roster
1 → statistics table
```

This changes presentation, not collision rules, movement positions, or scoring.
In 8085 terms, the same bit-toggle idea can be expressed using XOR operations,
although the memory-operand syntax differs.

---

## 20. Space requests a start; the lifecycle routine enforces it

The UI clears the Space edge and calls `START_RACE`.
It does not set `PHASE=2` directly.

`START_RACE` requires a lobby, at least two participants, and readiness for
every occupied slot.
It then resets elapsed and frame timers and enters the racing phase.

If a requirement fails, the call is a no-op.
The consumed Space edge is not automatically retried until another press.

This separation prevents the display module from maintaining its own competing
copy of the start rules.

---

## 21. M changes the collision mode only in the lobby

```asm
CMP PHASE,1
JNE HOST_MAZE
XOR COLLISION_MODE,1
```

The M edge is consumed before this phase test.
Holding M does not keep toggling, and pressing it during a race does not leave
a deferred toggle waiting for the next lobby.

Mode zero is block plus a three-second penalty per new contact episode.
Mode one is rotating priority without collision penalties.
Those policies are implemented in the core; this routine selects the mode.

---

## 22. R and N delegate different kinds of reset

R calls `REGENERATE`, which only changes a lobby map.
The lifecycle routine can reject a candidate that cannot accommodate the
existing roster, restoring the previous map and metadata.
An accepted map changes generation and clears readiness and movement inputs.

N calls `NEW_ROOM`.
That routine refuses during an active race; otherwise it resets room/game
state, changes the room epoch, clears the roster, and generates another map.

The UI consumes each edge before calling the corresponding routine.
It does not implement backup/rollback or ownership revocation itself.

---

## 23. Number keys map directly to slots

```asm
XOR SI,SI
HOST_REMOVE_NEXT:
    MOV BX,SI
    ADD BX,2
    CMP KEY_EDGE[BX],0
    JE HOST_REMOVE_SKIP
    MOV KEY_EDGE[BX],0
    CMP PLAYER_STATE[SI],0
    JE HOST_REMOVE_SKIP
    CALL DROP_PLAYER
```

`SI` is slot zero through seven.
Adding two produces ordinary scan indices `02H..09H` for keys 1..8.
This removes the slot number, not the first, second, or third nonempty row.

In the lobby, dropping an occupied player frees the slot and reduces the
participant count.
After the lobby, ownership is revoked; a racing player becomes DNF, while an
already finished player's result remains finished.

An empty slot does not call `DROP_PLAYER`, avoiding a spurious count decrement.

---

## 24. Host actions have a fixed order within one pass

The routine checks Tab, Space, M, R, N, then number keys.
Several latched edges can therefore trigger several actions in one call.

For example, if a valid Space start and M are both pending:

```text
Space runs first and changes PHASE to racing
M is consumed next, sees a non-lobby phase, and does not toggle
```

If Space cannot start, M can still toggle in the same pass because the room
remains in the lobby.

This is source-order behavior, not a timestamp-based ordering of physical key
presses.
The ISR does not record timestamps or queue a chronological command list.

---

## 25. `INSTALL_KEYS`: save the old far address

```asm
PUSH ES
MOV AX,3509H
INT 21H
MOV WORD PTR OLD_INT9,BX
MOV WORD PTR OLD_INT9+2,ES
```

DOS service `AH=35H`, `AL=09H` returns the current interrupt-09 handler in
`ES:BX`.
The module stores the offset word first and segment word second.

`DD` reserves four bytes, but there is no single 32-bit register transfer here.
The code writes the two pointer components separately.

`ES` was saved because DOS uses it for the return value, while the rest of
the program needs its normal extra-segment value afterward.

---

## 26. Why installation temporarily sets `DS=CS`

```asm
PUSH DS
PUSH CS
POP DS
MOV DX,OFFSET KEYBOARD_ISR
MOV AX,2509H
INT 21H
POP DS
MOV KEY_HOOKED,1
POP ES
```

DOS service `25H` expects the new vector in `DS:DX`.
The handler's instructions reside in the code segment, so the supplied segment
must be `CS`, not the game's ordinary data segment.

Pushing `CS` and popping it into `DS` copies that segment value.
After installation, the saved data `DS` and original `ES` are restored.
`KEY_HOOKED=1` records that cleanup must undo the hook.

The source expects this installation once during normal startup.
It is not a general stack of nested handler installations.

---

## 27. `RESTORE_KEYS`: use `LDS` to load the saved pointer

```asm
CMP KEY_HOOKED,0
JE KEYS_RESTORED
PUSH DS
LDS DX,OLD_INT9
MOV AX,2509H
INT 21H
POP DS
MOV KEY_HOOKED,0
```

`LDS DX,OLD_INT9` loads:

```text
DX ← saved offset
DS ← saved segment
```

That is exactly the pointer convention required by the DOS restore call.
Saving `DS` around the operation prevents the old handler's segment from
remaining the game's data segment.

The hooked flag makes a restore request harmless when this module has no
active installed hook.

---

## 28. Clean exit restores the keyboard before returning to DOS

```asm
EXIT_MAIN:
    CALL RESTORE_KEYS
    MOV AX,3
    INT 10H
    MOV AX,4C00H
    INT 21H
```

The keyboard vector must stop pointing into the terminating program's code.
The game then resets text mode and terminates with exit status zero.

This path does not wait for every queued serial byte to be transmitted or
promise one final network snapshot.
It also does not save and reconstruct every previous UART or video setting.

Normal Escape cleanup is explicit in the source.
An external forced termination is not evidence that this cleanup path ran.

---

## 29. `KEYBOARD_ISR`: hardware entry is different from `CALL`

On 8086 interrupt entry, the processor saves flags and a return address and
transfers to the vector's code.
General-purpose registers still need preservation by the handler itself.

```asm
PUSH AX
PUSH BX
PUSH DS
```

Those are the registers this ISR modifies.
It explicitly loads `DS=@DATA` before accessing keyboard arrays, because an
interrupt may occur while foreground code temporarily uses another segment.

Declaring the procedure `FAR` describes its addressing to the assembler.
The explicit `IRET` at the end supplies interrupt-return behavior.

---

## 30. Read the raw scan byte and acknowledge the keyboard

```asm
IN AL,60H
MOV BL,AL
IN AL,61H
MOV AH,AL
OR AL,80H
OUT 61H,AL
MOV AL,AH
OUT 61H,AL
```

The scan byte is read from port `60H` and saved in `BL`.
The code pulses bit seven of port `61H` and restores its previous value.

8085 has familiar `IN`/`OUT` concepts, but these port numbers and this
acknowledgement sequence belong to the intended PC-compatible hardware model.
They are not universal keyboard behavior on every processor board.

The handler captures input only.
It performs no drawing, DOS calls, serial packet parsing, or maze generation.

---

## 31. E1 starts a Pause sequence that must not become host actions

```asm
CMP PAUSE_BYTES,0
JE IRQ_PREFIX
DEC PAUSE_BYTES
JMP IRQ_DONE
```

If a Pause sequence is already being skipped, the next byte is discarded.
Otherwise:

```asm
CMP BL,0E1H
JNE IRQ_EXTENDED
MOV PAUSE_BYTES,5
MOV EXTENDED_KEY,0
JMP IRQ_DONE
```

The expected six-byte Pause sequence begins with E1.
Skipping the next five bytes prevents its embedded scan values from appearing
as ordinary host controls.
This is stateful handling, unlike simply discarding E1 and interpreting every
following byte independently.

---

## 32. E0 prefixes the next extended-key byte

```asm
CMP BL,0E0H
JNE IRQ_STORE
MOV EXTENDED_KEY,80H
JMP IRQ_DONE
```

The prefix is not recorded as a key press.
Instead it marks the next non-prefix scan byte for the upper half of the
256-entry arrays.

The marker is cleared after that byte is decoded.
Ordinary host commands continue to check lower-half indices.

This is targeted scan-prefix handling for the game's control needs, not a
claim that the source implements every possible modern keyboard protocol.

---

## 33. Decode release information separately from the extended index

```asm
MOV AH,BL
AND BL,7FH
OR BL,EXTENDED_KEY
XOR BH,BH
MOV EXTENDED_KEY,0
TEST AH,80H
JNZ IRQ_RELEASE
```

`AH` preserves the incoming make/break bit.
`BL` first becomes the base scan code and then acquires the remembered E0 bit.
Clearing `BH` creates a proper unsigned word index in `BX`.

For an E0-prefixed release byte `9CH`:

```text
saved AH = 9CH → release bit is set
base BL  = 1CH
E0 marker adds 80H → array index 9CH
```

The index's bit seven and the saved release bit have different meanings.

---

## 34. Latch a make only when the key was previously up

```asm
CMP KEY_DOWN[BX],0
JNE IRQ_DONE
MOV KEY_DOWN[BX],1
MOV KEY_EDGE[BX],1
```

A first make marks the key down and records a pending press edge.
Typematic repeated make bytes while the key is down do nothing.

The release path is:

```asm
MOV KEY_DOWN[BX],0
```

It intentionally preserves any pending edge.
The foreground, rather than the release interrupt, consumes that edge.

The arrays therefore represent state and an unconsumed event separately.

---

## 35. Worked Tab press, hold, release, and second press

Tab uses ordinary index `0FH`:

| Event | `KEY_DOWN[0FH]` | `KEY_EDGE[0FH]` | View change |
| --- | --- | --- | --- |
| Initial | 0 | 0 | none |
| Tab make | 1 | 1 | none yet |
| `HOST_CONTROLS` | 1 | 0 | toggles once |
| Typematic make | 1 | 0 | none |
| Tab break | 0 | 0 | none |
| New Tab make | 1 | 1 | pending next toggle |

For a quick tap, release can happen before `HOST_CONTROLS`; its edge still
survives and causes the toggle.
Two taps before consumption do not produce a count of two; the edge remains
the Boolean value one.

---

## 36. End-of-interrupt and `IRET`

```asm
MOV AL,20H
OUT 20H,AL
POP DS
POP BX
POP AX
IRET
```

The master PIC receives its end-of-interrupt command at port `20H`.
The saved registers are restored in reverse order.
`IRET` restores the interrupted instruction pointer, code segment, and flags.

An ordinary `RET` would not restore that interrupt frame.
The return mechanism is not interchangeable with a DOS process exit either.

This ISR owns keyboard handling while installed and does not chain to the old
BIOS handler after every byte.
The old vector is retained for restoration, not routine per-key forwarding.

---

## 37. What interrupt safety this module actually provides

The ISR keeps its work short, preserves its modified registers, supplies its
own data segment, and avoids DOS/BIOS calls.
It does not execute `STI` internally to invite nested maskable interrupts.

Foreground host-edge handling does not wrap every compare-and-clear sequence
in `CLI`/`STI`.
Its input representation is a Boolean latch, not a lossless, atomically
dequeued chronological command queue.

Byte writes and latching are suitable for this small host interface, but do
not describe it as preserving arbitrarily many rapidly repeated actions.
All game and serial state mutation remains foreground work.

---

## 38. The video-memory address formula

The selected color text screen uses segment `B800H`.
Its physical base in real mode is `B8000H`, from `segment*16+offset`.

One screen cell is a word:

```text
low byte  → character
high byte → attribute
```

For zero-based screen row `r` and column `c`:

```text
byte offset = r*160 + c*2
```

There are eighty cells per row and two bytes per cell.
The full 80-by-25 screen occupies 4000 bytes, or 2000 words.

`DI` is a byte offset into that screen representation, not a character count.

---

## 39. Character attributes and a concrete word example

For `AX=0E31H`:

```text
AL=31H → character '1'
AH=0EH → bright yellow foreground, black background
```

Writing that word into one text cell displays a yellow `1`.
The usual attribute format combines foreground and background information,
with the high attribute bit's blink/background behavior depending on video
configuration.

This program mainly uses low attributes such as gray `07H`, green `0AH`,
yellow `0EH`, and red `0CH` on black.
Player colors come from the eight-entry table.

No bitmap font or graphics-mode pixel coordinates are involved.

---

## 40. `CLEAR_SCREEN`: fill all 2000 cells

```asm
MOV AX,0B800H
MOV ES,AX
XOR DI,DI
MOV AX,0720H
MOV CX,2000
REP STOSW
```

`0720H` means space character `20H` with gray-on-black attribute `07H`.
`STOSW` writes a word to `ES:DI` and advances `DI` by two because `CLD` is in
effect.
`REP` repeats the operation until `CX` reaches zero.

The routine saves and restores `AX`, `CX`, `DI`, and `ES`.
It leaves the caller's destination pointer unchanged despite its internal fill.
It does not use or change `VIDEO_ATTR` to determine its fill value.

---

## 41. `VIDEO_CHAR`: one character, one advancing destination

Input is character `AL`, global `VIDEO_ATTR`, and destination byte offset `DI`.
The routine forms a word with the attribute in `AH`, temporarily sets
`ES=B800H`, and executes `STOSW`.

```asm
MOV AH,VIDEO_ATTR
PUSH AX
MOV AX,0B800H
MOV ES,AX
POP AX
STOSW
```

It restores the caller's `AX` and `ES`, but deliberately leaves `DI` advanced
by two.
That lets a sequence of helper calls append text naturally.

Direct memory output does not update the BIOS cursor position.
The display pointer is the explicit `DI`, not the hidden BIOS cursor.

---

## 42. `VIDEO_TEXT`: zero-terminated source, advancing screen destination

```asm
VIDEO_TEXT_NEXT:
    LODSB
    OR AL,AL
    JZ VIDEO_TEXT_DONE
    CALL VIDEO_CHAR
    JMP VIDEO_TEXT_NEXT
```

Input `DS:SI` points to a zero-terminated string.
`LODSB` advances the source pointer internally; `VIDEO_CHAR` advances the
destination pointer.

The routine restores the original `AX` and `SI` on return.
It leaves `DI` after the last visible output cell.
For a string of length `n`, the destination advances by `2*n` bytes.

The zero terminator is consumed from the source but is not drawn.
There is no line wrapping or newline interpretation in this helper.

---

## 43. Video-helper register contracts

| Routine | Main inputs | Intentional result/change |
| --- | --- | --- |
| `CLEAR_SCREEN` | fixed screen layout | clears VRAM; restores its working registers including `DI`/`ES` |
| `VIDEO_CHAR` | `AL`, `VIDEO_ATTR`, `DI` | writes one cell; `DI += 2`; preserves `AX`/`ES` |
| `VIDEO_TEXT` | `DS:SI`, `VIDEO_ATTR`, `DI` | writes string; advances `DI`; restores `AX`/`SI` |
| `VIDEO_NUMBER` | unsigned `DX:AX`, `DI` | decimal digits; advances `DI`; restores working registers |
| `VIDEO_TIME` | unsigned tenths `DX:AX`, `DI` | seconds with one decimal; advances `DI`; restores working registers |
| `STATE_LABEL` | slot `BX` | chosen `DS:SI` label; preserves `BX`; does not draw |
| `WARNING_LABEL` | slot `BX` | chosen `DS:SI` and changed `VIDEO_ATTR`; does not draw |
| `DRAW_SCREEN` | shared game/UI state | redraws a frame; restores saved general registers and `ES` |

Do not assume flags are preserved across these general helper calls.
`DRAW_SCREEN` restores registers but does not restore every display-global
variable it changed, such as `VIDEO_ATTR`.

---

## 44. `VIDEO_NUMBER`: print a 32-bit value on a 16-bit CPU

The input is an unsigned number in `DX:AX`.
The notation means high word `DX`, low word `AX`; it is not a 32-bit 8086
general-purpose register.

The routine repeatedly calls `DIVIDE_U32` with `BX=10`.
That shared helper returns a full 32-bit quotient in `DX:AX` and the remainder
in `CX`.

Each remainder is a decimal digit, obtained least-significant first.
The UI pushes the remainders and later pops them to reverse their order.
`BP` counts the saved digits because `CX` is the division helper's remainder
output, not a stable outer counter.

---

## 45. The decimal extraction and output loops

```asm
CALL DIVIDE_U32
PUSH CX
INC BP
MOV SI,AX
OR SI,DX
JNZ VIDEO_DIGIT
```

Both quotient words must be zero before extraction stops.
Testing only `AX` would mistake `0001:0000H` for zero.

Then:

```asm
POP AX
ADD AL,'0'
CALL VIDEO_CHAR
DEC BP
JNZ VIDEO_DIGIT_OUT
```

Each saved numeric remainder becomes an ASCII digit.
The routine saves/restores `AX`, `BX`, `CX`, `DX`, `SI`, and `BP`.
`DIVIDE_U32` preserves `DI` internally, while the actual character writes
advance `DI` for the caller.

---

## 46. Worked decimal trace: 65536 and zero

For `DX:AX=0001:0000H`, the value is 65536.
Successive divide-by-ten results are:

```text
65536 → quotient 6553, remainder 6
 6553 → quotient  655, remainder 3
  655 → quotient   65, remainder 5
   65 → quotient    6, remainder 5
    6 → quotient    0, remainder 6
```

The stack pops `6,5,5,3,6`, so the output is `65536`.
Five characters advance `DI` by ten bytes.

For input zero, the extraction loop still runs once and pushes remainder zero.
The result is the single character `0`, not an empty string.

The stack reversal and multiword arithmetic are familiar techniques from
8085 programming; the word sizes and register conventions differ.

---

## 47. `VIDEO_TIME`: tenths stay integers until formatting

The routine divides the input tenths by ten with `DIVIDE_U32`.
The quotient is whole seconds, and the remainder is the fractional digit.

It pushes the remainder across `VIDEO_NUMBER`, writes a literal dot, and then
writes the remainder plus `'0'`.

```text
input 123 tenths
123 / 10 → 12 whole seconds, remainder 3
output → 12.3
```

Input zero displays `0.0`.
There is no floating-point representation or x87 instruction in this process.

`VIDEO_TIME` preserves its arithmetic registers while allowing `DI` to advance
through all the output characters.

---

## 48. `STATE_LABEL`: select text without printing it

Input `BX` is the slot index, used directly for byte arrays.
The selection order is:

```text
PLAYER_STATE == 0 → EMPTY
PLAYER_STATE == 3 → DNF
PLAYER_STATE == 2 → DONE
otherwise:
    PHASE != lobby → RACE
    lobby and READY == 0 → WAIT
    lobby and READY != 0 → READY
```

The result is a label pointer in `SI`; `BX` remains available to the caller.
The routine does not print, move `DI`, or change `VIDEO_ATTR`.

State one is also used for occupied lobby slots.
The room's `PHASE` is what lets the UI label them WAIT/READY rather than RACE.

---

## 49. `WARNING_LABEL`: choose both text and color

```text
WARNINGS[BX] == 0 → ' SAFE',    attribute 07H
WARNINGS[BX] == 1 → ' CAUTION', attribute 0EH
otherwise        → ' DANGER',  attribute 0CH
```

The helper returns `SI` and intentionally leaves `VIDEO_ATTR` changed for the
next text output.
It does not calculate player distance.
The core has already assigned warning levels from walkable path distances.

The displayed rule is caution below five path steps and danger below three.
Walls matter to that path calculation; screen proximity alone is not the rule.

An unexpected warning byte other than zero or one is rendered as danger by
this selection code, although normal producers use zero, one, and two.

---

## 50. `DRAW_SCREEN`: full redraw with saved registers

The procedure saves `AX`, `BX`, `CX`, `DX`, `SI`, `DI`, `BP`, and `ES`.
It first calls `CLEAR_SCREEN`, then renders the shared header and one of two
main views.

```text
row 0  title
row 1  player count/capacity, equal route, floor count
row 2  lobby/racing/results instruction line
row 3  collision-mode explanation
row 4  warning thresholds and new-room help
row 5  race time and winner slot numbers
row 6  room password and launcher connection guidance
row 7 onward  map/roster or score table
```

The header is present in both views.
The function reads rule state; it does not run collision resolution as part
of drawing.

---

## 51. Header values require the right numeric width

`PLAYER_COUNT` and `CAPACITY` are bytes, while the decimal printer expects
`DX:AX`.
The renderer clears the wider registers and loads the byte into `AL`.

`COMMON_DISTANCE` and `FLOOR_COUNT` are words.
The high numeric word remains zero when those values are printed in this
header sequence.

The count line means:

```text
joined participants / generated maze capacity
equal shortest route length selected by generation
number of walkable cells excluding the exit in the maze metadata
```

It does not claim every generated map supports exactly eight players.
Eight is a maximum; the generated capacity can be smaller.

---

## 52. Phase, mode, clock, and winner text

Phase one selects lobby instructions, phase two selects racing instructions,
and other normal phase values select results instructions.
Collision mode zero selects the block/penalty help; the alternative selects
rotating-priority help.

`ELAPSED_TENTHS` is loaded as two words and passed to `VIDEO_TIME`.
The renderer scans all eight bits of `WIN_MASK` and writes the one-based slot
number for every set bit.

A mask of `00000101b` displays players 1 and 3.
If no finisher won and the mask is zero, no winner numbers are added.

This line displays the elapsed race time plus winner identities.
It does not display `BEST_SCORE` as that clock value.

---

## 53. Room text is local display information

The renderer prints `ROOM_CODE` through `VIDEO_TEXT`, so the shared field has
a terminating zero after its twelve visible bytes.
It follows with guidance that the HTTPS address is in the launcher terminal.

The UI does not discover the public tunnel address, perform TLS, or authenticate
the browser itself.
Those are bridge/launcher responsibilities described in the complete-system
guide.

The password on the local PC screen is intentional host-facing information.
It is not a cryptographic property of the video-memory output routine.

---

## 54. Map mode: contiguous source, wider screen rows

With `SHOW_SCORES=0`, the map begins at screen row seven, column zero:

```asm
MOV AX,0B800H
MOV ES,AX
MOV DI,7*160
LEA SI,MAZE
MOV BP,ROWS
```

Each row contains 61 source bytes.
`LODSB` reads one character and `STOSW` writes its character/attribute word.
Ordinary cells use `07H`; the shared `E` uses green `0AH`.

After 61 cells, `DI` has advanced 122 bytes.
Adding `(80-COLS)*2 = 38` skips the unused remainder of that screen row,
making the total advance 160 bytes.

The map occupies columns zero through sixty and rows seven through twenty-three.

---

## 55. Convert a linear player cell back into row and column

Each `POSITIONS` element is a word containing `row*61+column`.
The renderer uses word offset `2*slot` and divides that cell index by 61:

```asm
MOV AX,POSITIONS[BX]
XOR DX,DX
MOV BX,COLS
DIV BX
```

The quotient in `AX` is the maze row.
The remainder in `DX` is the maze column.
Clearing `DX` before word division makes the dividend the intended unsigned
16-bit cell value rather than an accidental larger `DX:AX` value.

It then computes the video offset:

```text
(maze row + 7)*160 + maze column*2
```

---

## 56. Worked player-overlay address

Suppose a player's linear cell index is 193:

```text
193 / 61 → row 3, remainder 10
screen row = 3+7 = 10
screen column = 10
video offset = 10*160 + 10*2 = 1620
```

The renderer saves the column remainder on the stack while multiplying the
row by 160, because word `MUL` overwrites `DX:AX`.
It restores that column, doubles it, and adds it to the row byte offset.

Only `PLAYER_STATE=1` slots are overlaid on the maze.
That includes occupied lobby slots; finished and DNF slots remain in the
roster/table but disappear from the map.

---

## 57. Map mode's side roster uses two rows per slot

The first line for slot `i` begins at:

```text
screen row = 7 + 2*i
screen column = 63
byte offset = i*320 + 7*160 + 63*2
```

It prints the colored one-based number, a space, and exactly eight name bytes.
The second line is one screen row lower and prints the state and warning.

Slot seven therefore uses rows twenty-one and twenty-two.
The map ends at column sixty, leaving columns sixty-one and sixty-two as
space before the roster begins at sixty-three.

The names use offset `8*i`, implemented by shifting the slot index left three
bits before adding `OFFSET PLAYER_NAMES`.

---

## 58. Counted name output and color inheritance

The name loop loads one byte with `LODSB`, calls `VIDEO_CHAR`, and repeats
with `CX=8`.
It does not call `VIDEO_TEXT` because the padded record has no required zero
terminator.

The first roster line selects the player's color before printing number/name.
`STATE_LABEL` does not change that color, so the state text inherits it.
`WARNING_LABEL` then changes the color specifically for SAFE/CAUTION/DANGER.

The next slot explicitly selects its own player color again.
This illustrates why `VIDEO_ATTR` is part of the helper contract rather than
an invisible constant inside every output routine.

---

## 59. Table mode replaces the map and roster

When `SHOW_SCORES` is nonzero, `DRAW_SCREEN` jumps to `DRAW_TABLE`.
It prints the statistics heading at row seven, then one record every two rows
starting at row eight.

The eight records use rows eight, ten, twelve, fourteen, sixteen, eighteen,
twenty, and twenty-two.
Blank alternate rows improve readability.

Each record includes slot/name, state, steps, penalty, adjusted score, and
warning.
The top seven header rows remain the same as in map mode.

Table selection changes no room or player state.

---

## 60. Table columns combine advancing pointers and fixed anchors

The number, space, and eight name bytes occupy columns zero through nine.
`ADD DI,8` skips four character cells, placing the five-character state at
column fourteen.
Another eight-byte skip puts the step count at column twenty-three.

Later fields use explicit row/column anchors:

| Field | Starting screen column |
| --- | --- |
| Number/name | 0 |
| State | 14 |
| Steps | 23 |
| Penalty | 38 |
| Adjusted score | 52 |
| Warning | 62 |

Remember that `ADD DI,8` means four text cells, not eight.
Direct-video pointers count bytes.

---

## 61. Table arithmetic uses byte, word, and doubleword scaling

The slot index selects `PLAYER_STATE`, `READY`, and `WARNINGS` directly.
Names use `8*slot` bytes.
Steps and penalties use `4*slot` bytes and are loaded as low/high words.

For the adjusted score, the renderer sets `SI=slot` and calls core `GET_SCORE`.
State two uses its frozen finish time; other states use current elapsed time;
the player's penalty is then added.

An empty or DNF row can therefore display a numeric value in the score field.
That displayed number does not make the slot eligible to win.
Winner selection separately admits only finishers.

`BP` keeps the table's slot index stable while other routines reuse `SI`, `BX`,
`CX`, `DX`, and `AX` for pointers and arithmetic.

---

## 62. The error footer and final register restoration

After either main view:

```asm
CMP CAPACITY,2
JAE DRAW_RETURN
MOV DI,24*160
LEA SI,UI_BAD
CALL VIDEO_TEXT
```

A generated capacity below two produces the retry/error message on row
twenty-four.
The source does not explicitly reset `VIDEO_ATTR` immediately before this
message, so it uses the current inherited attribute.

The routine then restores `ES`, `BP`, `DI`, `SI`, `DX`, `CX`, `BX`, and `AX`.
In particular, `DRAW_SCREEN` restores the caller's `DI`, unlike its smaller
output helpers, which intentionally advance it.

---

## 63. Presentation limits visible in the implementation

The renderer clears and rewrites the screen at each eligible redraw.
There is no back buffer, changed-cell diff, or synchronized page flip here.
Direct writes keep the operation simple and avoid a BIOS call for each cell,
but they are not a guarantee of flicker-free rendering in every emulator.

Text/number helpers do not clip output to a field width or automatically wrap
at a chosen column.
Large numeric strings can run into neighboring fixed-position fields.
The usual values and the declared layout fit the intended text screen.

The UI assumes the selected PC color text mode and valid game cell indices.
It does not independently validate every shared array entry before displaying it.

---

## 64. Foreground pseudocode with module boundaries preserved

```c
initialize_DS_ES_and_forward_string_direction();
select_text_mode_and_hide_cursor();
last_bios = bios_daily_ticks();
rng_seed = (last_bios.low ^ last_bios.high) | 1;
generate_maze();
serial_init();
install_keyboard_handler();

for (;;) {
    read_clock();
    serial_poll_bounded_input();
    if (key_edge[ESC])
        break;

    consume_host_edges_and_call_lifecycle_actions();
    game_tick_if_due();

    if ((uint16_t)(system_tick - state_tick) >= 4) {
        state_tick = system_tick;
        queue_state_snapshot_if_space();
    }
    serial_flush_ready_bytes_with_budget();

    if ((uint16_t)(system_tick - draw_tick) >= 2) {
        draw_tick = system_tick;
        draw_screen();
    }
    if (tx_head == tx_tail)
        enable_interrupts_and_halt_until_wakeup();
}

restore_keyboard_handler_if_installed();
select_text_mode();
dos_exit(0);
```

The pseudocode does not move lifecycle or game rules into the renderer.
It shows which module services the UI coordinates.

---

## 65. Keyboard pseudocode with prefix and edge state

```c
keyboard_interrupt() {
    save_AX_BX_DS();
    byte scan = read_port_60h();
    acknowledge_keyboard_port_61h();
    load_game_data_segment();

    if (pause_bytes != 0) {
        pause_bytes--;
    } else if (scan == 0xE1) {
        pause_bytes = 5;
        extended_key = 0;
    } else if (scan == 0xE0) {
        extended_key = 0x80;
    } else {
        bool release = (scan & 0x80) != 0;
        unsigned index = (scan & 0x7F) | extended_key;
        extended_key = 0;
        if (release) {
            key_down[index] = 0;
        } else if (!key_down[index]) {
            key_down[index] = 1;
            key_edge[index] = 1;
        }
    }

    send_master_PIC_EOI();
    restore_DS_BX_AX();
    interrupt_return();
}
```

---

## 66. Procedure map and 8085 connections

| Procedure | What to remember |
| --- | --- |
| `MAIN` | initialization, bounded foreground services, timing gates, idle, exit |
| `HOST_CONTROLS` | consume Boolean press edges and request local actions |
| `INSTALL_KEYS` | save far vector and install code-segment ISR |
| `RESTORE_KEYS` | guarded old-vector restoration with `LDS` |
| `KEYBOARD_ISR` | scan prefixes, make/break state, edge latches, EOI, `IRET` |
| `CLEAR_SCREEN` | fill 2000 character/attribute words |
| `VIDEO_CHAR` | one colored character and advancing `DI` |
| `VIDEO_TEXT` | zero-terminated text with preserved source pointer |
| `VIDEO_NUMBER` | unsigned 32-bit decimal digits through stack reversal |
| `VIDEO_TIME` | integer tenths formatted with one decimal place |
| `STATE_LABEL` | choose slot-state text |
| `WARNING_LABEL` | choose proximity text and color |
| `DRAW_SCREEN` | common header plus map/roster or full statistics table |

Your 8085 knowledge carries over through pointer arithmetic, flags, saved
registers, carry-aware multiword values, port I/O, interrupt handlers, and
stack-based digit reversal.
PC BIOS/DOS services, segment registers, text VRAM, scan-prefix decoding,
and the x86 interrupt frame are the additional platform details.

---

## 67. Exam-ready explanation

`M4UI.INC` supplies the normal entry point, local host-key interface, keyboard
interrupt handler, and direct text-video renderer for MAZE4. `MAIN` initializes
segments and video, generates the maze, enables polled serial transport, and
installs the keyboard handler. Its foreground loop updates time, polls input,
handles local commands, advances game logic, periodically queues snapshots,
flushes output, and redraws at a separate interval. The ISR separates ordinary
and extended keys, skips Pause bytes, and latches new press edges while
preserving interrupted registers. Video helpers write character/attribute words
to `B800H`, with `DI` advancing through text cells. The full renderer shows
shared metadata and either a maze with roster or a statistics table, using
integer 32-bit decimal/time formatting. Escape restores the saved keyboard
vector before resetting text mode and returning to DOS.
