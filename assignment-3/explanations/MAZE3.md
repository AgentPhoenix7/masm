# MAZE3 — three-player racing, collision episodes, and timed scores

Read this beside [MAZE3.ASM](../MAZE3.ASM).
The [MAZE2 guide](MAZE2.md) explains the underlying keyboard interrupt handler,
held keys, pending presses, and 32-bit decimal printing.
This guide explains those ideas where they appear here and develops the new
race-specific machinery in detail.

The main rule is:

```text
final score = elapsed time when the player reaches E + collision penalties
```

Lowest score wins after all three players finish.
Each new collision episode adds three seconds to both players involved.
Steps are displayed, but steps do not determine the winner.

---

## 1. Identify the version by its actual source

The file is named `MAZE3.ASM`.
Its comments and title contain several historical version names, including
“v3,” “v5,” and a build comment naming `MAZE5.ASM`.

Those strings do not create different programs.
The declarations in this file describe the three-player race explained here.
Use the actual source filename when identifying it.

These notes are a source walkthrough, not a report of a newly assembled or
played executable.

---

## 2. The complete race flow

```text
initialize video and keyboard interrupt handler
    ↓
show the ready screen
    ↓
Space starts the clock
    ↓
each eligible movement frame:
    build every player's proposed move
    resolve collisions against the complete proposal set
    charge newly touched pairs
    commit the remaining moves
    record players reaching E
    draw the current state
    ↓
after all three finish:
    compute lowest adjusted score and winner bitmask
    show results until Escape
```

The keyboard interrupt continues recording input between foreground frames.
It does not perform the race logic itself.

---

## 3. The assembly environment

```asm
.8086
.MODEL SMALL
.STACK 500H
```

The program uses 8086 instructions and a small-model DOS executable layout.
The stack reserves `500H = 1280` bytes for nested calls, saved registers,
temporary decimal digits, and hardware interrupt entry.

`DB`, `DW`, and `DD` declare one-, two-, and four-byte data objects.
`EQU` declares symbolic constants without allocating a mutable variable.

The processor remains 16-bit.
Every 32-bit race quantity is represented using two 16-bit words.

---

## 4. Logical map coordinates and screen coordinates

```asm
MAZE_ROWS EQU 17
MAZE_COLS EQU 61
MAZE_TOP EQU 7
MAZE_LEFT EQU 9
```

The map has seventeen rows and sixty-one columns.
Its coordinates start at zero.
The screen adds margins:

```text
screen row    = maze row + 7
screen column = maze column + 9
```

The map occupies screen rows seven through twenty-three and columns nine
through sixty-nine, within an 80-by-25 text screen.

The header and scoreboard use the rows above the map.
The footer occupies row twenty-four.

---

## 5. The exit is a coordinate as well as a character

```asm
EXIT_ROW EQU 9
EXIT_COL EQU 27
```

The map contains an `E` at logical cell `(9,27)`.
Movement treats every non-`#` cell as floor.
Finishing, however, is detected by comparing the accepted player coordinates
with these two constants.

Changing the visible `E` alone would not relocate the finish condition.
The constants and map data must agree.

`E` is shared: multiple players may reach it in the same frame without a
same-destination collision penalty.

---

## 6. Initial players and controls

```asm
PLAYER_ROWS DB 11,1,3
PLAYER_COLS DB 11,21,43
PLAYER_CHARS DB '1','2','3'
PLAYER_COLORS DB 0EH,0BH,0DH
```

| Player index | Display | Controls | Start |
| --- | --- | --- | --- |
| 0 | yellow `1` | W/A/S/D | `(11,11)` |
| 1 | cyan `2` | I/J/K/L | `(1,21)` |
| 2 | magenta `3` | T/F/G/H | `(3,43)` |

The control table is arranged in up/down/left/right order for every player:

```asm
CONTROLS DB 11H,1FH,1EH,20H, 17H,25H,24H,26H, 14H,22H,21H,23H
```

For P3, T is up, G is down, F is left, and H is right.
The familiar textual order “TFGH” is not the table's directional order.

The fixed map's three starts each have a shortest floor-path distance of
twenty-six moves to `E`, as obtained by a breadth-first traversal of these
source map bytes. The program itself does not calculate those distances;
its starts and map are fixed declarations.

---

## 7. Current positions and proposed positions are different arrays

```asm
CAND_ROWS DB 3 DUP(0)
CAND_COLS DB 3 DUP(0)
MOVING DB 3 DUP(0)
BLOCKED DB 3 DUP(0)
DONE DB 3 DUP(0)
```

For player index `i`:

```text
PLAYER_ROWS/COLS[i] → current committed position
CAND_ROWS/COLS[i]   → proposed position for this frame
MOVING[i]          → a valid floor move is still proposed
BLOCKED[i]         → collision resolution has canceled this player
DONE[i]            → player already reached the exit
```

`BUILD_INTENTS` initializes each candidate to the current position.
A player with no valid movement therefore behaves as stationary occupancy.

This is the main difference from `MAZE2`, which changes P1's coordinates
before even deciding P2's move.

---

## 8. Per-player counters and their units

```asm
STEPS DD 3 DUP(0)
PENALTIES DD 3 DUP(0)
FINISH_TIMES DD 3 DUP(0)
```

`STEPS` counts accepted moves.
`PENALTIES` stores tenths of seconds.
`FINISH_TIMES` stores the unpenalized elapsed tenths when each player finishes.

All three arrays contain 32-bit unsigned elements.
Element `i` starts at byte offset `4*i`.

```text
element 0 → offsets 0..3
element 1 → offsets 4..7
element 2 → offsets 8..11
```

The low word comes first in memory, followed by the high word.
Do not confuse an array offset in bytes with the player index itself.

---

## 9. Collision state is stored per pair

```asm
PAIR_TOUCH DB 3 DUP(0)
PAIR_LATCH DB 3 DUP(0)
```

Three players have three unordered pairs:

| Pair index | Player indices | Display names |
| --- | --- | --- |
| 0 | `(0,1)` | P1–P2 |
| 1 | `(0,2)` | P1–P3 |
| 2 | `(1,2)` | P2–P3 |

`PAIR_TOUCH` accumulates contact found during this movement frame.
`PAIR_LATCH` records whether that pair touched during the previous frame.

Those arrays prevent a sustained collision from adding three seconds every
two timer ticks.
The penalty applies on a transition into a new contact episode.

---

## 10. Race-wide clock and result state

```asm
LAST_BIOS DD 0
ELAPSED_TICKS DD 0
ELAPSED_TENTHS DD 0
FRAME_TICKS DW 0
STARTED DB 0
FINISHED_COUNT DB 0
WIN_MASK DB 0
BEST_SCORE DD 0FFFFFFFFH
```

`LAST_BIOS` retains the previous raw BIOS daily clock reading.
`ELAPSED_TICKS` accumulates race duration.
`ELAPSED_TENTHS` is its display/scoring conversion.
`FRAME_TICKS` decides when another movement frame may run.

`STARTED` gates the ready state.
`FINISHED_COUNT` determines when the race has ended.
`WIN_MASK` can name one winner or several tied winners.
`BEST_SCORE` begins at the largest unsigned 32-bit value.

---

## 11. Startup and interrupt installation

`MAIN` initializes `DS`, clears the direction flag with `CLD`, selects text
mode, hides the cursor, and draws the ready screen.

It saves the original keyboard vector with:

```asm
MOV AX,3509H
INT 21H
```

The returned `ES:BX` is saved in `OLD_INT9` as offset then segment.
The game temporarily sets `DS=CS` and installs `KEYBOARD_ISR` using DOS
`INT 21H/AX=2509H`, whose input pointer is `DS:DX`.

The normal data-segment value is restored afterward.
These are DOS service conventions, not generic 8086 interrupt-vector syntax.

---

## 12. Space starts the race once

```asm
CMP STARTED,0
JNE RUNNING
CMP KEY_PENDING[39H],0
JE IDLE_WAIT
MOV STARTED,1
```

Scan code `39H` is Space.
A pending press is required, so a quick Space tap is sufficient.

The program then reads BIOS ticks with `INT 1AH/AH=00H` and saves both words
in `LAST_BIOS`.
This establishes the race origin without counting time spent on the ready
screen.

There is no restart or new-maze branch in this file.
After `STARTED` becomes one, Space is no longer used to start another race.

Movement presses collected before the start are not explicitly cleared.
Their held or pending states may therefore influence the initial racing frame.

---

## 13. The running frame pipeline

```asm
CALL UPDATE_CLOCK
CMP FRAME_TICKS,MOVE_TICKS
JB IDLE_WAIT
MOV FRAME_TICKS,0
CLI
CALL BUILD_INTENTS
CALL RESOLVE_COLLISIONS
CALL COMMIT_MOVES
STI
```

`MOVE_TICKS=2` gives approximately one movement frame per 0.11 seconds.
The interrupt-disabled region contains only input-state and game-state work.
BIOS rendering happens after `STI`.

All proposals are made before any move is committed.
This lets collision logic compare a complete frame rather than favoring a
player merely because its movement routine was called first.

Resetting `FRAME_TICKS` to zero discards excess accumulated movement delay.
The code does not execute multiple catch-up movement frames after a long pause.
The elapsed race clock is accumulated separately.

---

## 14. Finished players and the final state

Before another update:

```asm
CMP FINISHED_COUNT,3
JE IDLE_WAIT
```

Once everyone is done, movement and clock updates stop.
The result screen remains visible while the foreground loop waits for Escape.

Immediately after the frame that completes the third finish:

```asm
CMP FINISHED_COUNT,3
JNE DRAW_FRAME
CALL FIND_WINNERS
```

Winner selection uses completed finish times plus penalties.
The first player to touch `E` is not automatically the winner.

---

## 15. `UPDATE_CLOCK`: subtract two 32-bit tick readings

```asm
MOV AH,00H
INT 1AH
MOV AX,DX
MOV BX,CX
SUB AX,WORD PTR LAST_BIOS
SBB BX,WORD PTR LAST_BIOS+2
```

The BIOS returns current ticks in `CX:DX`.
The code copies that into `BX:AX` and subtracts the previous `LAST_BIOS`.

`SUB` processes the low words.
`SBB` subtracts the high words and the low-word borrow.

This is the 16-bit-word version of 8085 multi-byte subtraction with `SBB`.
The underlying carry/borrow propagation idea is the same.

The original current reading remains in `CX:DX`, ready to become the next
`LAST_BIOS` value.

---

## 16. Correct a BIOS midnight rollover

```asm
JNC CLOCK_DELTA_OK
ADD AX,00B0H
ADC BX,0018H
```

The BIOS daily clock resets after `0018:00B0H` ticks.
If the current reading is below the previous reading, the subtraction borrows.
Adding one BIOS day turns the wrapped difference into a small positive delta.

For example:

```text
previous = day_length - 1
current  = 1
actual delta = 2 ticks
```

This handles the ordinary single-midnight transition between frequent reads.
It is not a mechanism to infer arbitrarily many elapsed days while the game
is suspended; the code does not count repeated days from the BIOS rollover
indicator in `AL`.

---

## 17. Accumulate duration independently of movement

```asm
ADD FRAME_TICKS,AX
ADD WORD PTR ELAPSED_TICKS,AX
ADC WORD PTR ELAPSED_TICKS+2,BX
```

The full tick delta is added to the 32-bit elapsed race clock.
The low word also advances the 16-bit frame accumulator.

This is why waiting at a wall still increases your race time.
The clock does not depend on successful steps.

The frame accumulator is designed for frequent short updates.
It does not represent a separate full 32-bit elapsed duration.

After accumulation, `TICKS_TO_TENTHS` converts the total and stores it in
`ELAPSED_TENTHS`.

---

## 18. `KEYBOARD_ISR`: capture input, do not run the race

The handler saves `AX`, `BX`, and `DS`, reads scan port `60H`, acknowledges
the keyboard through port `61H`, and loads the game data segment.

For simple scan codes:

```text
make  = key press
break = key release, with bit 7 set
index = scan byte AND 7FH
```

`KEY_STATE[index]` records zero or one.
`KEY_PENDING[index]` increments only on an up-to-down transition, saturating
at `FFH`.
Repeated make codes for a held key do not create additional pending events.
Release clears held state but leaves pending presses available.

The handler sends end-of-interrupt to the master PIC, restores its registers,
and returns with `IRET`.

---

## 19. Input limitations and interrupt safety

The handler does not call DOS or BIOS and does not chain to the old handler.
It replaces normal BIOS keyboard processing during the game.
The normal Escape exit restores the old vector.

It discards `E0H` and `E1H` prefix bytes themselves, but has no complete
extended-sequence state machine for the following bytes.
This is a small driver for the chosen letter controls, not a complete keyboard
implementation.

The foreground disables maskable interrupts while it reads and consumes key
arrays during the game-state update.
The hardware handler therefore cannot interleave changes halfway through that
short proposal/resolution/commit phase.

`CLI`/`STI` correspond conceptually to controlling interrupt acceptance on 8085,
but the PC interrupt controller, vector numbers, and `IRET` behavior are new
platform details.

---

## 20. `BUILD_INTENTS`: begin with stationary candidates

For each player:

```asm
MOV AL,PLAYER_ROWS[SI]
MOV CAND_ROWS[SI],AL
MOV AL,PLAYER_COLS[SI]
MOV CAND_COLS[SI],AL
MOV MOVING[SI],0
MOV BLOCKED[SI],0
CMP DONE[SI],0
JNE NEXT_INTENT
```

The default candidate is the current cell.
`MOVING=0` means no accepted proposal yet.
`BLOCKED=0` clears collision results from the previous frame.

Finished players skip control processing.
Their old coordinates may remain in the arrays, but `DONE` removes them from
later collision tests and map overlays.

---

## 21. Choose one direction in a fixed priority order

The routine computes control-table offset `4*SI` using two shifts.
It scans four directions with `BP=0,1,2,3` for up/down/left/right.

For each direction it checks pending presses and then held state.
The first active direction wins.

This is not “whichever key was pressed most recently.”
It is not diagonal movement either.
A held up control has priority over another direction lower in the table.

If the selected direction has a pending count, one is consumed before bounds
or wall validation.
Thus a blocked quick tap does not remain queued forever.

---

## 22. Propose one legal floor move

The chosen direction changes a temporary `DH=row`, `DL=column` pair.
The routine checks unsigned bounds and reads:

```text
MAZE[row*61 + column]
```

The exact multiplication is byte `MUL BL`:

```asm
MOV AL,DH
MOV BL,MAZE_COLS
MUL BL
```

Its word result in `AX` can hold the row product, which reaches values above
255 in this larger map.
The candidate in `DX` survives because byte multiplication returns in `AX`.

Only an in-bounds non-wall target becomes a proposed move:

```asm
MOV CAND_ROWS[SI],DH
MOV CAND_COLS[SI],DL
MOV MOVING[SI],1
```

Current position arrays are still untouched.

---

## 23. `CHECK_PAIR`: decide whether two proposals conflict

Inputs are:

```text
SI → first player index
DI → second player index
BX → pair index for PAIR_TOUCH
```

The procedure ignores a pair if either player is finished.
It also ignores it if neither player proposes movement.

Otherwise it checks two collision forms:

```text
same destination
head-on exchange of old positions
```

It can mark both players blocked and set the pair's touch flag.
It does not charge penalties itself.

Separating detection from charging prevents multiple resolution passes from
adding the same frame's penalty repeatedly.

---

## 24. Same-destination collisions include a stationary occupant

The first comparison checks whether both candidate rows and columns match.

If P1 moves toward P2 while P2 makes no move, then:

```text
P1 candidate = P2 current cell
P2 candidate = P2 current cell
```

The destinations match.
Because at least one player is moving, this is contact.
Both receive a penalty for a new episode, even though one was stationary.

The exception is destination `(EXIT_ROW,EXIT_COL)`.
Equal destinations at the shared exit are allowed.

This rule tests equal **proposed** coordinates, not whether the two players
were merely adjacent before the frame.

---

## 25. Head-on swaps are blocked

For two moving players, the code checks:

```text
candidate A == old position B
candidate B == old position A
```

Both row and column must match in each direction.

Example in a corridor:

```text
P1 at (r,4), proposing (r,5)
P2 at (r,5), proposing (r,4)
```

The destination cells differ, so the same-destination test alone would miss it.
The swap test detects that they would pass through one another.
Both moves are blocked.

The program does not automatically swap or push players.
One player must choose another legal move to clear the obstruction.

---

## 26. `CONTACT` records the result

```asm
MOV BLOCKED[SI],1
MOV BLOCKED[DI],1
MOV PAIR_TOUCH[BX],1
```

These flags are monotonic within the current resolution frame:
once blocked or touched, that fact is retained for the remaining passes.

The positions are not changed here.
The caller will cancel blocked candidates together after enumerating the pairs.

This preserves a complete proposal set for the current pass.

---

## 27. `RESOLVE_COLLISIONS`: enumerate all three pairs

The routine first clears `PAIR_TOUCH[0..2]`.
Then it calls `CHECK_PAIR` for:

```text
(0,1), pair slot 0
(0,2), pair slot 1
(1,2), pair slot 2
```

The pair ordering chooses which array latch to use.
It does not declare one player the winner of a collision.
The policy blocks both participants.

After checking every pair, the routine cancels all players whose `BLOCKED`
flag is set.

---

## 28. Cancel by restoring the old coordinates

```asm
MOV MOVING[SI],0
MOV AL,PLAYER_ROWS[SI]
MOV CAND_ROWS[SI],AL
MOV AL,PLAYER_COLS[SI]
MOV CAND_COLS[SI],AL
```

A canceled proposal becomes stationary occupancy at the original cell.
The old position variables have not changed, so this restoration is reliable.

That new stationary occupancy can block a player that originally expected the
cell to be vacated.
The resolver therefore repeats the pair checks for three passes.

With three players, this propagates a blocking decision through the possible
three-person dependency chain.

---

## 29. Worked chain: one blocked move can block its follower

Use three consecutive floor cells in a hypothetical corridor:

```text
P1 at column 4, wants right
P2 at column 5, wants right
P3 at column 6, stays still
```

Initially:

```text
candidates: P1→5, P2→6, P3→6
```

The P2–P3 pair collides at six.
Their moves are canceled, leaving P2 at five and P3 at six.

Now the next pass sees:

```text
candidates: P1→5, P2→5, P3→6
```

P1–P2 also collides.
P1 is canceled as well.

For fresh contact episodes, P1 receives three seconds, P2 receives six seconds
for two distinct pairs, and P3 receives three seconds.
The middle player can be penalized for two separate pair contacts in one frame.

---

## 30. A freely moving following chain is allowed

Change the example so the front player can move forward:

```text
old:       P1=4, P2=5, P3=6
candidate: P1=5, P2=6, P3=7
```

Destinations are distinct and there is no head-on swap.
No player is canceled.
All three moves are committed.

This is why collision checks use proposed positions rather than simply banning
entry into every cell that was occupied at frame start.
The code can allow movement into a cell that another player is successfully
vacating in the same frame.

---

## 31. `CHARGE_PAIR`: charge only new episodes

```asm
MOV AL,PAIR_TOUCH[BX]
CMP AL,0
JE SAVE_CONTACT
CMP PAIR_LATCH[BX],0
JNE SAVE_CONTACT
```

A penalty is charged exactly when:

```text
touched this frame AND not latched from the previous frame
```

Each participant's doubleword penalty is increased by `PENALTY_TENTHS=30`:

```asm
ADD WORD PTR PENALTIES[BX],PENALTY_TENTHS
ADC WORD PTR PENALTIES[BX+2],0
```

Thirty tenths is three seconds.
The low-word addition's carry propagates to the high word.

The routine temporarily reuses `BX` for a player's doubleword offset and saves
the original pair index on the stack while doing so.

---

## 32. What releases a contact latch?

At the end of `CHARGE_PAIR`:

```asm
MOV PAIR_LATCH[BX],AL
```

The previous-frame latch becomes this frame's touch result.

| Frame | Touch | Previous latch | New penalty? | New latch |
| --- | --- | --- | --- | --- |
| 1 | 1 | 0 | yes | 1 |
| 2 | 1 | 1 | no | 1 |
| 3 | 0 | 1 | no | 0 |
| 4 | 1 | 0 | yes | 1 |

A no-contact movement frame releases the latch.
Physical adjacency alone does not keep it set if neither player attempts a
conflicting move.

This is an episode of detected collision attempts, not a distance-based
“players are standing near each other” test.

---

## 33. Three players contesting one non-exit cell

If all three valid proposals target the same ordinary floor cell, all three
pairs touch.
Everyone is blocked.

For previously unlatched pairs, each player participates in two contacts:

```text
P1: P1–P2 + P1–P3 → +6.0 seconds
P2: P1–P2 + P2–P3 → +6.0 seconds
P3: P1–P3 + P2–P3 → +6.0 seconds
```

It is not one universal three-second charge for the entire frame.
Penalties are pair-based.

At the shared `E` cell, the same-destination exception allows simultaneous
arrivals instead.

---

## 34. `COMMIT_MOVES`: apply only surviving proposals

```asm
CMP MOVING[SI],0
JE NEXT_COMMIT
MOV AL,CAND_ROWS[SI]
MOV PLAYER_ROWS[SI],AL
MOV AL,CAND_COLS[SI]
MOV PLAYER_COLS[SI],AL
```

Only after all collision resolution does the routine change current positions.
It increments the corresponding 32-bit step count with low-word `ADD` and
high-word `ADC`.

Blocked movement does not increase steps.
Hitting a wall also does not increase steps or cause a player-collision penalty.

The commit loop is sequential machine code, but its decisions came from the
already resolved complete frame.

---

## 35. Record an arrival once

After committing a move, the routine compares its coordinates with `(9,27)`.
On reaching the exit it:

```text
sets DONE[i] = 1
increments FINISHED_COUNT
copies ELAPSED_TENTHS into FINISH_TIMES[i]
```

All arrivals in the same frame use the same elapsed-time snapshot.
The code does not timestamp each player at a different instruction inside the
commit loop.

In later frames, `BUILD_INTENTS` skips done players, so their finish times are
not repeatedly replaced and their finish count is not repeatedly incremented.
Drawing and collision checks also skip them.

---

## 36. `GET_SCORE`: racing score versus final score

Input is player index `SI`; output is score in `DX:AX`.

```text
if DONE[i] == 0:
    base = ELAPSED_TENTHS
else:
    base = FINISH_TIMES[i]

score = base + PENALTIES[i]
```

The displayed score of a racer increases as the race clock advances.
A finisher's base time is frozen.
Finished players no longer incur new collisions, so their final score stays
fixed during normal subsequent play.

The score addition uses `ADD` for the low word and `ADC` for the high word.

---

## 37. Worked scoring example

Suppose the final values in seconds are:

| Player | Finish time | Penalty | Final score |
| --- | --- | --- | --- |
| P1 | 20.0 | 6.0 | 26.0 |
| P2 | 22.0 | 0.0 | 22.0 |
| P3 | 19.0 | 3.0 | 22.0 |

P3 reached the exit first.
P2 and P3 nevertheless tie for the lowest adjusted score.

Internally those are integer tenths:

```text
P1: 200 + 60 = 260
P2: 220 +  0 = 220
P3: 190 + 30 = 220
```

No floating-point instructions are used.
The decimal point is introduced only when formatting the integer for display.

---

## 38. `FIND_WINNERS`: compare full unsigned scores

The routine starts with `BEST_SCORE=FFFFFFFFH` and `WIN_MASK=0`.
For each player it calls `GET_SCORE`.

The comparison checks the high word first:

```asm
CMP DX,WORD PTR BEST_SCORE+2
JB NEW_BEST
JA NEXT_SCORE
CMP AX,WORD PTR BEST_SCORE
JB NEW_BEST
JA NEXT_SCORE
JMP ADD_WINNER
```

Only if the high words are equal does the low-word comparison matter.
This is how to compare multi-word unsigned values correctly.

Comparing only `AX` would give wrong results after a score crosses a 16-bit
boundary.
The use of `JB`/`JA` is unsigned, unlike signed `JL`/`JG`.

---

## 39. A bitmask can represent tied winners

For a new lower score, the routine updates `BEST_SCORE` and clears old winner
bits.
For an equal score, it retains existing winners and adds this player:

```asm
MOV CX,SI
MOV AL,1
SHL AL,CL
OR WIN_MASK,AL
```

Player index zero uses bit zero, index one bit one, and index two bit two.

```text
001b → P1
010b → P2
100b → P3
110b → P2 and P3 tied
111b → all three tied
```

In 8085, you would build and combine the same bit patterns with shifts/rotates
and logical operations, but the variable-count x86 shift syntax is different.

---

## 40. `DIVIDE_U32`: software long division around 16-bit `DIV`

Inputs:

```text
DX:AX → unsigned 32-bit dividend
BX    → nonzero 16-bit divisor
```

Outputs:

```text
DX:AX → unsigned 32-bit quotient
CX    → remainder
```

The routine divides the high word first, then combines its remainder with the
low word for the second division.

```asm
MOV SI,AX
MOV AX,DX
XOR DX,DX
DIV BX
MOV DI,AX
MOV AX,SI
DIV BX
MOV CX,DX
MOV DX,DI
```

The second division is safe because its high input word is already below the
divisor.
The routine preserves `SI` and `DI`; other documented output registers change.

---

## 41. Why not use one `DIV` on the whole 32-bit number?

8086 word `DIV BX` accepts a 32-bit dividend in `DX:AX`, but its quotient must
fit in the 16-bit `AX` register.
It is not a general 32-bit-quotient division instruction.

For a large dividend and a small divisor, a direct call can raise division
overflow.

The two-stage algorithm computes both quotient words separately.
That is the arithmetic analogue of processing a multi-byte number one part at
a time on 8085.

Callers here supply fixed nonzero divisors such as ten and 182.
`DIVIDE_U32` itself does not check a zero divisor.

---

## 42. `TICKS_TO_TENTHS`: the mathematical formula

Using the source's 18.2-Hz approximation:

```text
seconds = ticks / 18.2
tenths  = floor(ticks × 100 / 182)
```

It is tempting to multiply the entire tick count by 100 first.
That intermediate result can overflow a 32-bit storage range.

Instead divide ticks by 182 first:

```text
ticks = 182*q + r, with 0 <= r < 182

floor(ticks*100/182)
    = 100*q + floor(100*r/182)
```

This rearrangement gives the same integer result without the large initial
product.
It is still a BIOS-clock approximation, not exact wall-clock measurement.

---

## 43. How the tick-conversion instructions implement that formula

The routine calls `DIVIDE_U32` with `BX=182`.
It receives quotient `q` in `DX:AX` and remainder `r` in `CX`.

It pushes `r`, saves the high quotient word, and multiplies the low quotient
word by 100.
The low product word is saved in `DI`, and the carry word in `BP`.
It then multiplies the high quotient word by 100 and adds that carry word.

The combined `DX:AX` is `100*q`.
Finally it computes the small `100*r/182` contribution and adds it with
`ADD`/`ADC`.

This procedure illustrates why a word `MUL BX` returns a doubleword product
in `DX:AX`, whereas byte `MUL BL` used in coordinate indexing returns in `AX`.

---

## 44. Worked tick-conversion examples

For 182 ticks:

```text
q=1, r=0
tenths=100
display=10.0 seconds
```

For one tick:

```text
q=0, r=1
tenths=floor(100/182)=0
display=0.0 seconds
```

For two ticks:

```text
q=0, r=2
tenths=floor(200/182)=1
display=0.1 seconds
```

The displayed time changes in tenths, although the underlying timer advances
in BIOS ticks.
Integer truncation explains small quantization effects.

---

## 45. `PRINT_TIME`: introduce the decimal point during output

The input is a 32-bit count of tenths in `DX:AX`.
The routine divides by ten using `DIVIDE_U32`.

```text
quotient  → whole seconds
remainder → one fractional digit
```

It saves the remainder, prints whole seconds with `PRINT_NUMBER`, writes a dot
with `PUT_CHAR`, then prints remainder plus ASCII `'0'`.

Example input 123 becomes:

```text
123 / 10 → quotient 12, remainder 3
output   → 12.3
```

Input zero becomes `0.0`.
The integer stored in memory never contains a literal decimal-point byte.

---

## 46. `PUT_CHAR`, `SET_CURSOR`, and `CLEAR_ROW`

`PUT_CHAR` prints `AL` through BIOS `INT 10H/AH=0EH`.
It preserves `AX` and `BX`.

`SET_CURSOR` uses `DH=row`, `DL=column`, video page zero, and BIOS service
`AH=02H`.
It also preserves `AX` and `BX`.

`CLEAR_ROW` moves to column zero of row `DH`, then writes eighty spaces with
attribute `07H` using BIOS `AH=09H` and `CX=80`.
That service does not advance the cursor, so subsequent text starts at the
same row's beginning.

These small wrappers reduce repeated BIOS setup in the larger screen routine.
They are ordinary subroutines, comparable to reusable 8085 monitor wrappers
in purpose, but with PC-specific service interfaces.

---

## 47. `DRAW_SCREEN`: the scoreboard layout

The routine saves its working registers and draws:

```text
row 0: title
row 1: elapsed race clock and rule text
row 2: P1 steps, penalties, score, and state
row 3: P2 steps, penalties, score, and state
row 4: P3 steps, penalties, score, and state
row 5: control legend
rows 7..23: maze and active players
row 24: ready/racing/result footer
```

Player labels use the pointer table `PLAYER_TEXTS`.
Those pointers are words, so the table offset is `2*player_index`.
Steps and penalty arrays contain doublewords, so their offsets are
`4*player_index`.

The same index therefore needs different scaling for different arrays.

---

## 48. Why the screen code keeps reconstructing coordinates

`DX` serves two unrelated purposes at different moments:

```text
DH:DL as screen row/column
DX:AX as a 32-bit number for arithmetic and printing
```

Loading a high counter word into `DX` destroys its old row/column contents.
`DRAW_SCREEN` consequently reconstructs the HUD row from the player index
before moving to later fields.

The instruction `ADD DH,0` near the start of a HUD row does not add the desired
row offset; it leaves the value unchanged.
The following `MOV DH,DL` and `ADD DH,2` establish the actual row.

Understanding register reuse is more helpful than assigning one permanent
meaning to `DX` for the entire program.

---

## 49. Footer selection follows race state

Before the start, the footer shows Space/start instructions.
While fewer than three players have finished, it shows the race objective.
After all three finish, it calls `DRAW_WINNERS`.

The final redraw happens after `FIND_WINNERS` computes the mask and best score.
It does not need to recalculate winners during every text-output operation.

There is no phone UI, serial transport, or automatic new room in this version.
Those belong to `MAZE4`.

---

## 50. `DRAW_MAZE`: write directly to text video memory

For the large map, this version switches from one BIOS call per cell to direct
color text-memory writes:

```asm
MOV AX,0B800H
MOV ES,AX
MOV DI,MAZE_TOP*160+MAZE_LEFT*2
LEA SI,MAZE
```

In the selected PC color text mode, segment `B800H` addresses text video RAM.
Each screen cell occupies two bytes:

```text
low byte  → character
high byte → attribute
```

One 80-cell screen row therefore takes 160 bytes.
The initial byte offset is `7*160 + 9*2 = 1138`.

This is a PC hardware layout, not a property of all 8086 machines or an 8085
instruction-set feature.

---

## 51. `LODSB` and `STOSW` move different-sized objects

```asm
LODSB
MOV AH,07H
CMP AL,'E'
JNE WRITE_CELL
MOV AH,0AH
WRITE_CELL:
STOSW
```

`LODSB` loads the next map character from `DS:SI` into `AL` and increments
`SI` by one.
The routine sets the attribute in `AH`: ordinary cells use `07H`, while `E`
uses bright green `0AH`.

`STOSW` writes the whole `AX` word to `ES:DI` and increments `DI` by two.
Thus one byte of logical map data becomes one two-byte screen cell.

Both string instructions advance because startup executed `CLD`.

---

## 52. Move from one map row to the next screen row

After sixty-one cells, the destination pointer has advanced by 122 bytes.
The next screen row begins 160 bytes after the current one.
The renderer skips the remaining bytes:

```asm
ADD DI,(80-MAZE_COLS)*2
```

That is `(80-61)*2 = 38` bytes.
The total destination advance per map row is `122+38=160` bytes.

The source pointer needs no comparable skip because map rows are packed
consecutively with exactly sixty-one bytes each.

The saved `ES` is restored before returning, so this routine's video segment
does not leak into its caller's state.

---

## 53. Overlay only active player markers

For each unfinished player, the renderer computes:

```text
video byte offset = (row+7)*160 + (column+9)*2
```

It puts the corresponding digit in `AL`, the color attribute in `AH`, and uses
`STOSW` to write that one screen cell.

`DONE` players are skipped.
Their old map cells are repainted with the underlying map, and they no longer
cover the shared exit or block later finishers.

As in earlier versions, drawing a digit does not modify `MAZE`.
Map terrain and player state remain separate.

---

## 54. `DRAW_WINNERS`: one bit or several?

The routine distinguishes a single winner from a tie using:

```asm
MOV AL,WIN_MASK
MOV AH,AL
DEC AL
AND AL,AH
JZ PRINT_WIN_PREFIX
```

For a nonzero bitmask, `mask & (mask-1)` is zero exactly when it contains one
set bit.

```text
100b & 011b = 000b → one winner
110b & 101b = 100b → multiple winners
```

The normal completed race produces at least one winner bit.
The code chooses `WINNER:` for a single bit and `TIE:` for multiple bits.

---

## 55. Enumerate the winning players

The renderer loops through indices zero to two, constructs `1<<index`, and
tests that bit in `WIN_MASK`.
For every set bit it prints `P`, the one-based player number, and a space.

It then prints the best score through `PRINT_TIME` and the explanatory suffix.

For the earlier scoring example:

```text
WIN_MASK = 110b
footer includes: TIE: P2 P3
best score displays as 22.0 seconds
```

The mask stores membership, not the score itself.
The score remains in the separate `BEST_SCORE` doubleword.

---

## 56. `PRINT_TEXT`: zero-terminated strings

The routine reads a byte with `LODSB`, tests `AL` for zero, and prints nonzero
bytes through BIOS teletype output.
It saves and restores `AX`, `BX`, and `SI`.

All the screen labels in this file use zero termination.
The fixed-width map uses neither zero nor `$` as a terminator.

`OR AL,AL` tests a value without changing that value, while still updating flags.
This is similar in purpose to 8085 `ORA A` followed by a zero-flag jump.
Exact flag behavior outside the zero test should not be assumed identical.

---

## 57. `PRINT_NUMBER`: reverse decimal digits with the stack

`PRINT_NUMBER` accepts an unsigned 32-bit value in `DX:AX`.
It implements the same two-word long-division pattern inline with divisor ten.

Every division produces one remainder digit, which it pushes onto the stack.
It repeats until both quotient words are zero.
Popping those remainders yields most-significant digit first.

Numeric zero is handled because the division loop executes at least once.
The routine preserves `AX`, `BX`, `CX`, `DX`, `SI`, and `DI`.

Unlike `MAZE2`'s version, this one does not print ten padding spaces afterward.
Screen rows are cleared separately before the HUD is drawn.

---

## 58. Why test both quotient words?

The decimal loop uses:

```asm
MOV SI, AX
OR SI, DX
JNZ DIVIDE_DIGIT
```

If either the quotient's low word or high word is nonzero, more digits remain.
Testing only `AX` would wrongly treat `0001:0000H` as zero because its low
word is zero.

This is another recurring multi-word pattern:

```text
addition   → carry from low to high
subtraction → borrow from low to high
comparison → high first, low only on equality
zero test  → combine all words
division   → high first, remainder carried into low
```

These ideas are equally useful in 8085 multi-byte arithmetic.

---

## 59. Escape restores the original environment

The foreground recognizes held or pending Escape at scan index `01H`.
Its exit path uses `LDS DX,OLD_INT9` to load the saved far pointer, restores
interrupt `09H` through DOS `2509H`, restores the normal data segment, resets
text mode, and exits through DOS `4C00H`.

Restoring the handler is essential because its replacement code belongs to
the terminating program.
`IRET` belongs to interrupt returns; DOS `4CH` belongs to process termination.
Neither is an interchangeable substitute for the other.

The main idle loop uses `STI` followed by `HLT` to sleep until a hardware event
wakes it, then rechecks race state.

---

## 60. High-level pseudocode of one movement frame

```c
for each player i {
    candidate[i] = position[i];
    moving[i] = false;
    blocked[i] = false;
    if (done[i])
        continue;

    direction = first_pending_or_held_direction(i);
    if (direction exists) {
        consume_one_pending_press_if_present(direction);
        target = one_cell_in_direction(position[i], direction);
        if (in_bounds(target) && map[target] != '#') {
            candidate[i] = target;
            moving[i] = true;
        }
    }
}

clear(pair_touch);
repeat 3 times {
    for each pair (a,b) {
        if (either_done(a,b) || neither_moving(a,b))
            continue;
        if (same_non_exit_target(a,b) || head_on_swap(a,b)) {
            blocked[a] = blocked[b] = true;
            pair_touch[a,b] = true;
        }
    }
    for each blocked player i {
        moving[i] = false;
        candidate[i] = position[i];
    }
}

for each pair (a,b) {
    if (pair_touch[a,b] && !pair_latch[a,b]) {
        penalties[a] += 30;
        penalties[b] += 30;
    }
    pair_latch[a,b] = pair_touch[a,b];
}

for each moving player i {
    position[i] = candidate[i];
    steps[i]++;
    if (position[i] == exit) {
        done[i] = true;
        finished_count++;
        finish_times[i] = elapsed_tenths;
    }
}
```

---

## 61. Important limits of this version

The map and three starts are fixed, not generated at runtime.
All players use one PC keyboard.
There is no room, readiness vote, serial protocol, authentication, phone control,
disconnect timeout, or DNF state.

The race waits for all three players to finish.
An unfinished player can keep the final result from appearing indefinitely;
Escape still exits.

Movement uses fixed direction priority and periodic frames.
The displayed timer uses a BIOS-tick approximation and tenths-of-second
truncation.
Counters and scores are finite unsigned 32-bit values without overflow alerts.

Normal Escape cleanup restores the keyboard vector.
An external forced termination is not evidence that the cleanup path ran.

---

## 62. A procedure map for reading the source again

| Procedure | Main responsibility |
| --- | --- |
| `MAIN` | startup, ready/racing/results loop, cleanup |
| `UPDATE_CLOCK` | BIOS tick delta, rollover, elapsed accumulation |
| `KEYBOARD_ISR` | held and pending key capture |
| `BUILD_INTENTS` | one legal floor proposal per active player |
| `CHECK_PAIR` | same-target and head-on contact detection |
| `RESOLVE_COLLISIONS` | repeated pair passes and cancellation |
| `CHARGE_PAIR` | one penalty per new pair-contact episode |
| `COMMIT_MOVES` | positions, successful steps, finish recording |
| `GET_SCORE` | elapsed/frozen finish time plus penalty |
| `FIND_WINNERS` | full score comparison and tied-winner mask |
| `DIVIDE_U32` | 32-bit quotient using two word divisions |
| `TICKS_TO_TENTHS` | overflow-conscious tick conversion |
| `PRINT_TIME` | whole seconds, decimal point, fractional digit |
| `PUT_CHAR` | BIOS teletype character output |
| `SET_CURSOR` | BIOS page-zero cursor positioning |
| `CLEAR_ROW` | erase one complete text row |
| `DRAW_SCREEN` | scoreboard, legend, map, and footer |
| `DRAW_MAZE` | direct text-VRAM terrain and player writes |
| `DRAW_WINNERS` | single/tied result presentation |
| `PRINT_TEXT` | zero-terminated text output |
| `PRINT_NUMBER` | unsigned 32-bit decimal output |

---

## 63. Exam-ready explanation

`MAZE3` implements a fixed three-player maze race using held-key input captured
by a keyboard interrupt handler. Space starts a BIOS-tick clock. Every two
ticks, the foreground constructs all players' movement proposals, repeatedly
resolves same-target and head-on collisions, charges newly touched player pairs,
and commits only surviving moves. Each collision episode adds three seconds
to both participants. Reaching the shared exit freezes a player's finish time
and removes that player from movement, collision, and map drawing. After all
three finish, the program compares unsigned 32-bit finish-time-plus-penalty
scores and records every equal winner in a bitmask. BIOS output and direct
text-memory writes render the interface, and Escape restores the original
keyboard interrupt vector before returning to DOS.
