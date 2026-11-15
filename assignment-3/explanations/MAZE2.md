# MAZE2 — two players, held keys, and 32-bit step counts

Read this beside [MAZE2.ASM](../MAZE2.ASM).
The earlier [MAZE guide](MAZE.md) explains coordinate indexing and simple
BIOS text output. This version adds hardware keyboard input and timed updates.

The game has two players:

| Player | Marker | Keys | Initial maze position |
| --- | --- | --- | --- |
| P1 | `@` | W/A/S/D | `(1,1)` |
| P2 | `&` | I/J/K/L | `(7,18)` |

There is no finish cell or race winner in this version.
Each player has a counter of successful steps.

---

## 1. The most important change: input state instead of one key event

The first intended maze reads one key through BIOS `INT 16H` and reacts to it.
This version keeps arrays describing the keyboard:

```text
KEY_STATE[scan]   → is this key currently held?
KEY_PENDING[scan] → how many new presses have not yet been consumed?
```

A hardware keyboard interrupt updates those arrays.
The foreground game loop reads them every two BIOS timer ticks.

This separates two jobs:

```text
interrupt handler → capture input promptly
foreground loop   → decide when and how players move
```

The processor is still executing one instruction stream at a time.
“Two-player simultaneous controls” does not mean parallel CPUs or parallel
execution of the movement routines.

---

## 2. Directives and constants

```asm
.8086
.MODEL SMALL
.STACK 200H

MAZE_ROWS EQU 9
MAZE_COLS EQU 20
MAZE_TOP EQU 4
MOVE_TICKS EQU 2
```

The stack now reserves `200H = 512` bytes.
Calls and saved registers use it, and a hardware interrupt also temporarily
uses the interrupted program's stack.

The map remains nine by twenty.
Its first screen row is four, leaving room for title and step counters.

`MOVE_TICKS=2` controls the movement frame interval.
The standard PC BIOS timer is approximately 18.2 ticks per second, so two ticks
are about 0.11 seconds, giving roughly nine movement frames per second.
This is a timer-based approximation, not a precise real-time guarantee.

---

## 3. A misleading build comment is not the source filename

The header comment mentions building `MAZE4.ASM`.
The file explained here is `MAZE2.ASM`, and its content is the two-player game.

Comments can become stale when a program is copied between versions.
Use the actual filename and declarations to identify this version.
These notes describe the source and do not report a fresh assembly or runtime
test of its existing executable.

---

## 4. Strings have two different terminators

```asm
TITLE_TEXT DB 'TWO-PLAYER MAZE - Esc exits.',13,10,'$'
P1_TEXT DB 'P1 @ (WASD)   Steps: ',0
P2_TEXT DB 'P2 & (IJKL)   Steps: ',0
```

The title is printed through DOS `AH=09H`, so it ends in `$`.
The status labels use the program's `PRINT_TEXT` routine, so they end in zero.

The map has neither terminator.
Its dimensions determine how many bytes drawing reads.

There is no universal assembly string terminator.
The routine that consumes a string determines the representation it expects.

---

## 5. Parallel player arrays

```asm
PLAYER_ROWS DB 1,7
PLAYER_COLS DB 1,18
STEPS DD 0,0
```

The same index selects the same player in each array:

```text
index 0 → P1
index 1 → P2
```

For example:

```text
PLAYER_ROWS[1] = 7
PLAYER_COLS[1] = 18
```

Byte arrays use an offset of `index`.
Each `STEPS` element is a doubleword, so it uses an offset of `4*index`.

`DD` means define doubleword: four bytes, or 32 bits.
It does not give the 8086 a 32-bit general-purpose register.
The code accesses those four bytes as two 16-bit words.

---

## 6. Held keys and pending presses solve different problems

```asm
KEY_STATE DB 128 DUP (0)
KEY_PENDING DB 128 DUP (0)
```

The index is a normalized keyboard scan code from zero through 127.
`KEY_STATE` contains zero or one.
`KEY_PENDING` is a saturating byte count.

Why not use only held state?

```text
frame A reads key up
key pressed
key released
frame B reads key up
```

The entire tap occurred between frames.
A held-state-only design would miss it.

The pending count retains that press even after release.
It is consumed by a later movement frame.

---

## 7. The control table stores scan codes

```asm
CONTROLS DB 11H,1FH,1EH,20H, 17H,25H,24H,26H
```

Within each group the order is **up, down, left, right**:

| Direction | P1 | P1 scan | P2 | P2 scan |
| --- | --- | --- | --- | --- |
| Up | W | `11H` | I | `17H` |
| Down | S | `1FH` | K | `25H` |
| Left | A | `1EH` | J | `24H` |
| Right | D | `20H` | L | `26H` |

These are keyboard scan codes, not ASCII values for letters.
Shift or Caps Lock does not change which physical control scan the table uses.

If several controls are active for one player, the first in this table wins.
The game therefore has a fixed directional priority, not diagonal motion.

---

## 8. Other state variables

```asm
OLD_INT9 DD ?
LAST_TICK DW ?
CHANGED DB 0
```

`OLD_INT9` stores a far address as two words:

```text
OLD_INT9+0 → original handler offset
OLD_INT9+2 → original handler segment
```

`LAST_TICK` stores the low word of the BIOS tick count at the previous frame.
`CHANGED` tells the main loop whether movement changed anything worth redrawing.

The question mark in `DD ?` reserves storage without providing an initial value.
The program writes the old vector before attempting to restore it.

---

## 9. `MAIN` initializes data and string direction

```asm
MOV AX, @DATA
MOV DS, AX
CLD
```

`MAIN` begins by making `DS` identify the data group before instructions access arrays and strings.
`CLD` clears the direction flag.

Later `LODSB` loads a byte from `DS:SI` and advances `SI` because the direction
flag is clear.
If the flag were set, it would decrement `SI` instead.

8085 has no direct `LODSB` instruction or direction flag.
The conceptual 8085 sequence is load from the pointer and then increment it.

Startup then selects text mode, hides the visible cursor, prints the title,
and calls `DRAW_SCREEN` for the initial state.

---

## 10. Save the original keyboard interrupt vector

```asm
MOV AX, 3509H
INT 21H
MOV WORD PTR OLD_INT9, BX
MOV AX, ES
MOV WORD PTR OLD_INT9+2, AX
```

DOS service `AH=35H` gets an interrupt vector.
`AL=09H` selects interrupt `09H`, the PC hardware keyboard handler.
DOS returns its address in `ES:BX`.

The game saves both words.
A saved offset without its segment would not describe the complete far address.

In an 8085 system, interrupt entry points and hardware conventions are different.
The general idea of replacing and later restoring a handler transfers;
the DOS vector services do not.

---

## 11. Install the game's handler with `DS:DX`

```asm
PUSH DS
PUSH CS
POP DS
MOV DX, OFFSET KEYBOARD_ISR
MOV AX, 2509H
INT 21H
POP DS
```

DOS service `AH=25H`, `AL=09H` installs the handler whose address is in `DS:DX`.
The handler's instructions are in the code segment, so `DS` temporarily becomes
the value of `CS`.

`OFFSET KEYBOARD_ISR` supplies its offset within that segment.
After the service, `POP DS` restores the game's normal data segment.

This temporary use of `DS` does not move the code or data.
It simply presents the far address in the register convention DOS expects.

---

## 12. Initialize the movement clock

```asm
MOV AH, 00H
INT 1AH
MOV LAST_TICK, DX
```

BIOS clock service `00H` returns its daily tick counter in `CX:DX`.
The game stores only `DX`, the low sixteen bits.

This version needs a short interval between frames rather than a complete
elapsed race duration.
It does not display a timer or use the full 32-bit daily counter for scoring.

---

## 13. Escape works for a held key or a quick tap

```asm
CMP KEY_STATE[01H], 0
JNE EXIT_PROGRAM
CMP KEY_PENDING[01H], 0
JNE EXIT_PROGRAM
```

The Escape scan code is `01H`.
Checking both arrays ensures that a tap is not lost just because Escape was
released before the next foreground check.

The game owns hardware keyboard handling while it runs.
It does not wait for the normal BIOS keyboard event queue in this loop.

---

## 14. Wait until two ticks have passed

```asm
MOV AH, 00H
INT 1AH
MOV AX, DX
SUB AX, LAST_TICK
CMP AX, MOVE_TICKS
JB IDLE_WAIT
MOV LAST_TICK, DX
```

The unsigned subtraction computes a difference modulo 65536.
That handles ordinary low-word wrap when the two readings are close together.

For example:

```text
LAST_TICK = FFFFH
current DX = 0001H
0001H - FFFFH, keeping 16 bits = 0002H
```

`JB` skips movement if the unsigned difference is below two.

This is not a catch-up loop that executes every missed frame.
If rendering or scheduling delays the program, it runs one update and sets
`LAST_TICK` to the current reading.

The BIOS daily midnight reset is a different discontinuity from a simple
65536-tick low-word wrap; this version does not contain the explicit daily
rollover correction found in `MAZE3`.

---

## 15. Protect the short game update from keyboard interrupts

```asm
CLI
MOV CHANGED, 0
XOR SI, SI
CALL MOVE_PLAYER
INC SI
CALL MOVE_PLAYER
STI
```

`CLI` clears the interrupt-enable flag, preventing ordinary maskable hardware
interrupts from interrupting this short region.
`STI` enables them again.

This keeps the key arrays stable while movement consumes pending presses.
The region performs no BIOS or DOS calls.

The two calls use `SI=0` and `SI=1`.
That means P1 moves before P2 within every frame.
The code does not first build both proposals and then resolve them together.

---

## 16. “Same frame” still has a movement order

Imagine two adjacent players in a corridor:

```text
P1 at column 4
P2 at column 5
both want right
```

P1 is checked first and sees P2 still at column five, so P1 is blocked.
P2 can then move from five to six if that cell is free.

Reverse their order along the corridor:

```text
P1 at column 5
P2 at column 4
both want right
```

P1 may move to six.
P2 then sees P1's updated position and may move into the newly vacated five.

This ordering effect is actual behavior of `MAZE2`.
`MAZE3` introduces a proposal-and-resolution system to address frame-wide
collision decisions.

---

## 17. Redraw only after a successful move

```asm
CMP CHANGED, 0
JE IDLE_WAIT
CALL DRAW_SCREEN
```

`MOVE_PLAYER` sets `CHANGED=1` only when it accepts a move.
Walls, occupied cells, and no active direction leave it unchanged.

Both movement calls finish before the screen is redrawn.
The display therefore presents the completed frame rather than repainting
between P1's update and P2's update.

---

## 18. `STI` and `HLT` avoid a continuous busy loop

```asm
IDLE_WAIT:
    STI
    HLT
    JMP WAIT_FRAME
```

`HLT` stops normal instruction execution until an interrupt or other suitable
wakeup event occurs.
The timer or keyboard can wake this loop.

Interrupts must be enabled for ordinary hardware wakeups.
That is why `STI` precedes `HLT`.

8085 also has `HLT`, but its interrupt-enable instruction is `EI`, not `STI`.
Interrupt details remain specific to each processor and system.

---

## 19. `KEYBOARD_ISR`: what interrupt entry saves automatically

When the PC keyboard generates IRQ1 and the CPU enters interrupt `09H`,
8086 hardware saves the interrupted flags and return address on the stack.
It does not automatically preserve all general-purpose registers.

The handler begins:

```asm
PUSH AX
PUSH BX
PUSH DS
```

Those are the registers it modifies.
It restores them before returning with `IRET`.

`IRET` restores the saved instruction pointer, code segment, and flags.
An ordinary `RET` would not perform that interrupt return.

---

## 20. Read and acknowledge the keyboard byte

```asm
IN AL, 60H
MOV BL, AL

IN AL, 61H
MOV AH, AL
OR AL, 80H
OUT 61H, AL
MOV AL, AH
OUT 61H, AL
```

Port `60H` provides the raw scan byte in this PC-compatible setup.
The code saves it in `BL` while pulsing the acknowledgement bit through port
`61H` and restoring that port's previous value.

`IN` and `OUT` are recognizable from 8085, but the port numbers and hardware
meaning belong to the PC keyboard interface.
They are not universal keyboard ports on every computer.

The handler then loads `DS=@DATA` before accessing the key arrays.
The interrupted foreground code cannot be assumed to have supplied the
handler's desired data segment in every circumstance.

---

## 21. Make codes and break codes

```asm
MOV AH, 1
TEST BL, 80H
JZ STORE_KEY
XOR AH, AH
```

For the simple scan-code convention used here:

```text
bit 7 clear → make: key pressed
bit 7 set   → break: key released
```

`AH` becomes one for press and zero for release.
`TEST` performs an AND for flags without storing the AND result.

Then:

```asm
AND BL, 7FH
XOR BH, BH
```

This strips the release bit and creates an unsigned array index in `BX`.
Both press `11H` and release `91H` address the W entry, index `11H`.

---

## 22. Latch a new press, but ignore typematic repeats

```asm
OR AH, AH
JZ SAVE_KEY_STATE
CMP KEY_STATE[BX], 0
JNE SAVE_KEY_STATE
CMP KEY_PENDING[BX], 0FFH
JE SAVE_KEY_STATE
INC KEY_PENDING[BX]
```

A release does not add a pending press.
A make code for a key already marked down is a repeated make event, so it
does not add another pending press either.

Only an up-to-down transition increments the pending counter.
At `FFH` it saturates rather than wrapping to zero.

Finally:

```asm
MOV KEY_STATE[BX], AH
```

The current held state is always updated.
Releasing a key leaves its queued pending presses intact.

---

## 23. A quick-tap trace

Consider W, whose scan code is `11H`:

| Event | `KEY_STATE[11H]` | `KEY_PENDING[11H]` |
| --- | --- | --- |
| Initial | 0 | 0 |
| W make | 1 | 1 |
| W break | 0 | 1 |
| Foreground selects W | 0 | 0 |

The pending press causes one attempted up move.
It is consumed even if the wall check rejects that attempt.

For a held key, the first frame consumes its initial pending press; later
frames continue choosing it through `KEY_STATE=1`.
The game does not need typematic keyboard repetition to sustain movement.

---

## 24. Finish the interrupt without calling DOS

```asm
MOV AL, 20H
OUT 20H, AL
POP DS
POP BX
POP AX
IRET
```

Writing `20H` to master-PIC command port `20H` signals end-of-interrupt.
This allows normal interrupt-controller handling to continue.

The handler does not draw, move players, or call DOS.
It also does not chain to the original keyboard handler while the game runs.
Consequently, ordinary BIOS keyboard-buffer processing is replaced during play.

The old handler is preserved for restoration on exit, not invoked after every
keyboard event.

---

## 25. A limitation of the prefix handling

The handler discards scan bytes `E0H` and `E1H` themselves.
It does not keep a full prefix state machine that suppresses or separately
interprets all subsequent bytes in an extended sequence.

The selected letter controls work with simple make/break scan codes.
Do not describe this as a complete general-purpose keyboard driver.
Some extended-key sequences can be interpreted as ordinary scan entries.

This is different from the original maze's BIOS scan-code results.
Here the application is responsible for raw hardware-byte handling.

---

## 26. `MOVE_PLAYER`: find that player's four controls

```asm
MOV BX, SI
SHL BX, 1
SHL BX, 1
XOR BP, BP
MOV CX, 4
```

Input `SI` is the player index.
Two one-bit shifts compute `BX=4*SI`, the start of that player's controls.
`BP` records direction number zero through three.
`CX` limits the scan to four directions.

Although `BP` often serves as a stack-frame pointer in other x86 programs,
here it is just a direction counter.
Its name does not force that conventional role.

---

## 27. Choose the first active direction

```asm
XOR AX, AX
MOV AL, CONTROLS[BX]
MOV DI, AX
CMP KEY_PENDING[DI], 0
JNE HAVE_DIRECTION
CMP KEY_STATE[DI], 0
JNE HAVE_DIRECTION
```

`DI` receives the control's scan-code index.
The code first checks pending presses and then held state for that direction.
If neither is active, it advances `BX` and `BP` and tries the next control.

The priority is decided by direction order, not by comparing timestamps of
different key presses.
A held up key can take precedence over a pending lower-priority direction.

If all four controls are inactive, the routine returns immediately.

---

## 28. Consume one selected pending press

```asm
CMP KEY_PENDING[DI], 0
JE GET_POSITION
DEC KEY_PENDING[DI]
```

One attempted move consumes at most one queued press.
The later collision result does not undo this consumption.

Otherwise a quick tap into a wall could remain pending forever and keep being
retried even after the user released the key.

Unselected directions retain their pending counts.
That is why the array is more than a single “last key” variable.

---

## 29. Build and validate a candidate position

The routine copies `PLAYER_ROWS[SI]` into `DH` and `PLAYER_COLS[SI]` into `DL`.
`BP` selects up, down, left, or right.

It rejects:

```text
candidate row >= 9
candidate column >= 20
map[candidate row*20+candidate column] == '#'
```

The unsigned dimension checks also reject byte underflow such as `00H-1=FFH`.

The index calculation uses byte multiplication:

```asm
MOV AL, DH
MOV BL, MAZE_COLS
MUL BL
XOR BX, BX
MOV BL, DL
ADD BX, AX
```

`BX` now indexes the map byte.
The candidate `DX` remains intact because byte `MUL BL` returns its result in
`AX`, not in `DX:AX`.

---

## 30. Block the other player's current cell

```asm
MOV BX, SI
XOR BX, 1
CMP DH, PLAYER_ROWS[BX]
JNE ACCEPT_MOVE
CMP DL, PLAYER_COLS[BX]
JE MOVE_DONE
```

For indices zero and one, XOR with one selects the other player:

```text
0 XOR 1 = 1
1 XOR 1 = 0
```

Occupancy requires both row and column to match.
If the rows differ, the move can be accepted immediately.
If the rows match, the columns must be checked too.

Remember that P2 sees P1's already updated coordinates because calls are
sequential within the frame.

---

## 31. Commit and increment a 32-bit step count

```asm
MOV PLAYER_ROWS[SI], DH
MOV PLAYER_COLS[SI], DL
MOV BX, SI
SHL BX, 1
SHL BX, 1
ADD WORD PTR STEPS[BX], 1
ADC WORD PTR STEPS[BX+2], 0
MOV CHANGED, 1
```

The byte coordinates use player index `SI` directly.
The doubleword counter uses offset `BX=4*SI`.

The low counter word is incremented first.
`ADC` adds zero plus the carry from that low-word addition into the high word.

Example:

```text
before: high=0000H, low=FFFFH  → 65535
ADD low,1 → low=0000H, CF=1
ADC high,0 → high=0001H
after:  0001:0000H            → 65536
```

This is the same carry-chain idea as multi-byte addition with 8085 `ADC`.
Do not insert a flag-changing instruction between this `ADD` and `ADC`.

---

## 32. What counts as a step?

Only an accepted coordinate change increments `STEPS`.

```text
held direction into floor       → one step per eligible frame
held direction into wall        → zero steps
direction into occupied cell    → zero steps
no active direction             → zero steps
```

The counter measures successful moves, not key presses, elapsed time, or
attempted moves.

The count is an unsigned 32-bit value and eventually wraps modulo `2^32`.
There is no overflow warning or saturation for step counts.

---

## 33. `DRAW_SCREEN`: status before maze

The routine saves `AX`, `BX`, `CX`, `DX`, `SI`, and `BP`.
It positions the BIOS cursor at row one for P1's label and count, then at row
two for P2's label and count.

For P1:

```asm
LEA SI, P1_TEXT
CALL PRINT_TEXT
MOV AX, WORD PTR STEPS
MOV DX, WORD PTR STEPS+2
CALL PRINT_NUMBER
```

For P2, the corresponding counter words are `STEPS+4` and `STEPS+6`.
The convention for `PRINT_NUMBER` is high word in `DX`, low word in `AX`.

`DX:AX` is a notation for the combined unsigned value, not a separate 32-bit
register on the 8086.

---

## 34. Draw every map cell at an explicit cursor position

This version uses BIOS character-and-attribute service `09H` for map cells.
Unlike teletype output, that service does not advance the cursor.
The code therefore positions every cell explicitly.

```asm
PUSH CX
MOV AH, 02H
XOR BH, BH
INT 10H
MOV AL, MAZE[SI]
MOV AH, 09H
MOV BX, 0007H
MOV CX, 1
INT 10H
POP CX
```

The map-loop count was already in `CX`, but service `09H` needs `CX=1` to print
one character.
Saving and restoring it protects the loop counter.

After each cell the code advances `SI` and `DL`.
After each row it advances `DH` and decrements the row counter `BP`.

---

## 35. Overlay both players

After the entire map is redrawn, the code positions the cursor at each player's
maze row plus `MAZE_TOP`, with the stored maze column.

It writes:

```text
P1: @ with attribute 0EH, yellow on black
P2: & with attribute 0BH, bright cyan on black
```

Repainting the map first erases the old markers.
Player markers are not written into the collision map.

The shared map is still immutable game data.
Collision with the other player is checked through the coordinate arrays.

---

## 36. `PRINT_TEXT`: zero-terminated BIOS output

```asm
PRINT_NEXT:
    LODSB
    OR AL, AL
    JZ TEXT_DONE
    MOV AH, 0EH
    MOV BX, 0007H
    INT 10H
    JMP PRINT_NEXT
```

`LODSB` reads `DS:[SI]` into `AL` and advances `SI` because startup executed `CLD`.
`OR AL,AL` tests for zero without changing the byte.
Zero ends the text; otherwise BIOS teletype output prints the character.

The routine saves and restores `AX`, `BX`, and `SI`.
The caller's original string pointer survives.

The zero terminator is not printed.
The `$` convention of DOS function `09H` is irrelevant inside this routine.

---

## 37. Why decimal printing needs more than one ordinary division

The input to `PRINT_NUMBER` can be as large as `FFFFFFFFH`.
8086 word `DIV BX` divides `DX:AX` by `BX`, but its quotient must fit in `AX`.

Trying to divide an arbitrary 32-bit counter directly by ten in one such
instruction can overflow the 16-bit quotient.

The code therefore performs long division using the two words:

```text
first divide 0:high by 10
then divide first_remainder:low by 10
```

The two quotient words together form the new 32-bit quotient.
The final remainder is the next decimal digit.

---

## 38. The two-division sequence

```asm
MOV SI, AX
MOV AX, DX
XOR DX, DX
DIV BX
MOV DI, AX
MOV AX, SI
DIV BX
PUSH DX
MOV DX, DI
```

Here `BX=10`.

1. `SI` saves the original low word.
2. The first division produces the high quotient word and a remainder below ten.
3. `DI` saves that high quotient.
4. The second division combines that remainder with the original low word.
5. Its remainder is pushed as a digit.
6. `DX:AX` becomes the complete new quotient.

The second quotient fits because its high input word is less than the divisor.
That is the crucial reason this long-division method avoids division overflow.

---

## 39. Worked conversion of 65536

Initial input is `DX:AX=0001:0000H`.

```text
high division: 1 / 10 → high quotient 0, remainder 1
low division:  1:0000H / 10 → low quotient 6553, remainder 6
```

The routine pushes digit six and continues with quotient 6553.
Subsequent divisions push digits three, five, five, and six.

The stack reverses their order:

```text
push: 6, 3, 5, 5, 6
pop:  6, 5, 5, 3, 6
text: 65536
```

This is the same reason a stack is useful when printing an ordinary 8085 number
whose least significant digits are obtained first.

---

## 40. Stop when both quotient words are zero

```asm
INC CX
MOV SI, AX
OR SI, DX
JNZ DIVIDE_DIGIT
```

`CX` counts the pushed decimal digits.
OR-ing the quotient's low and high words tests whether the entire quotient is
zero.
Testing `AX` alone would incorrectly stop for values whose low word is zero
while their high word remains nonzero.

The routine performs at least one division before this test.
Input zero therefore produces one zero remainder and correctly prints `0`.

---

## 41. Print digits and clear stale counter text

```asm
POP AX
ADD AL, '0'
MOV AH, 0EH
MOV BX, 0007H
INT 10H
LOOP PRINT_DIGIT
```

Adding ASCII `'0'` turns numeric digits zero through nine into characters.
Each digit word pushed earlier is popped exactly once.

After the number, `PRINT_NUMBER` outputs ten spaces.
This erases leftover counter text following the current value.
It then restores `DI`, `SI`, `DX`, `CX`, `BX`, and `AX`.

The padding is a display behavior of this particular version's printing routine.
It is not part of the mathematical decimal representation.

---

## 42. Restore the original interrupt handler before exit

```asm
PUSH DS
LDS DX, OLD_INT9
MOV AX, 2509H
INT 21H
POP DS
```

`LDS DX,OLD_INT9` reads a far pointer from memory:

```text
DX ← saved offset
DS ← saved segment
```

That supplies the address DOS needs to restore interrupt `09H`.
The game then restores its own `DS`, resets text mode, and exits through DOS.

Restoration matters because the game's handler is inside its process memory.
Leaving the vector pointing there after termination would leave a dangling
interrupt-handler address.

The source's normal Escape path performs this restoration.
Do not assume that every external forced termination would execute that path.

---

## 43. Whole-program pseudocode

```c
initialize_data_and_video();
draw_screen();
save_original_keyboard_vector();
install_game_keyboard_isr();
last_tick = bios_ticks_low_word();

for (;;) {
    if (escape_held_or_pending())
        break;

    uint16_t now = bios_ticks_low_word();
    if ((uint16_t)(now - last_tick) >= 2) {
        last_tick = now;
        disable_maskable_interrupts();
        changed = false;
        move_player(0);  // immediately updates position
        move_player(1);  // sees player 0's new position
        enable_maskable_interrupts();
        if (changed)
            draw_screen();
    }
    enable_interrupts_and_wait();
}

restore_original_keyboard_vector();
restore_text_mode();
dos_exit(0);
```

The interrupt handler independently records make/break events and acknowledges
the hardware; it does not execute `move_player`.

---

## 44. 8085 connections and new machinery

| Familiar idea | Connection here |
| --- | --- |
| carry-chain arithmetic | `ADD` low word, `ADC` high word for 32-bit counters |
| port input/output | `IN`/`OUT`, with PC-specific keyboard/PIC ports |
| subroutine register preservation | `PUSH`/`POP` around drawing and printing |
| interrupt service routines | prompt capture of external keyboard events |
| pointer arithmetic | `SI`, `DI`, and `BX` index arrays in `DS` |
| count-controlled loops | `CX` with `LOOP` |

The segment model, DOS vector services, PC scan codes, BIOS tick clock, and
`IRET` stack format are new platform details.
An 8085 interrupt handler cannot be ported merely by renaming registers.

---

## 45. Exam-ready explanation

`MAZE2` installs an IRQ1 handler that tracks held keys and pending presses for
two players. Every two BIOS ticks, the foreground loop briefly disables
interrupts, moves P1 and then P2, and redraws if either position changed.
Each movement attempt checks bounds, walls, and the other player's current
cell. Accepted moves increment separate unsigned 32-bit step counters using
`ADD` and `ADC`. BIOS routines draw the map and player markers, and a two-stage
long-division routine prints the counters. Escape restores the saved keyboard
interrupt vector before the program returns to DOS.

The key limitation to mention is sequential movement within each frame.
This version does not build simultaneous intents or implement race scoring.
