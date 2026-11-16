# MAZE4 — an eight-player maze race, explained from 8085 knowledge

Source: [MAZE4.ASM](../MAZE4.ASM), [M4CORE.INC](../M4CORE.INC),
[M4SER.INC](../M4SER.INC), and [M4UI.INC](../M4UI.INC).

For separate file-by-file walkthroughs, read [M4CORE](M4CORE.md) for game
algorithms, [M4SER](M4SER.md) for communication and race lifecycle, and
[M4UI](M4UI.md) for the main loop, keyboard interrupts, and rendering.

This is a self-contained explanation of the current MAZE4 program. No earlier
maze program or explanation is required. The guide introduces its register,
memory, movement, collision, and communication concepts where they are used.
The 8085 comparisons assume only basic familiarity with that processor.
It follows the actual source, including the procedures inserted by `INCLUDE`;
it does not report a new game or physical-phone test.

The task is:

> Generate a maze, admit phone-controlled players at equally distant starts,
> process their movement together, and compare finish time plus penalties.

The PC displays the maze. Each phone is a controller for one player.
The assembly program decides what happens in the game.

---

## 1. Start with the complete system

```text
phone button
    ↓ HTTPS request
Python bridge: authenticate the controller and encode its request
    ↓ loopback TCP connection
DOSBox: present those bytes through its emulated COM1 UART
    ↓ 8086 IN instructions
MASM: validate input, calculate moves, collisions, time and results
    ↓ OUT instructions and a state snapshot
Python bridge → HTTPS response → phone status
```

The phone does not directly change `POSITIONS`.
It requests a direction; MASM may reject the request or block the move.

In an 8085 laboratory, you might read a switch through an I/O port and update
an LED. The principle of input → state → output transfers here.
HTTPS, DOSBox, BIOS, and DOS are additional layers, not 8085 instructions.

## 2. Which file does what?

| File | Responsibility |
| --- | --- |
| `MAZE4.ASM` | Processor model, constants, shared arrays, includes |
| [M4CORE.INC guide](M4CORE.md) | Maze generation, BFS, starts, movement, collisions, scoring |
| [M4SER.INC guide](M4SER.md) | COM1, packet parsing, players, leases, race clock |
| [M4UI.INC guide](M4UI.md) | `MAIN`, host keys, keyboard ISR, text-screen drawing |
| [protocol.py guide](protocol.md) | Frame encoding/decoding and loopback transport |
| [bridge.py guide](bridge.md) | Browser authentication and HTTP-to-serial adaptation |
| [phone/controller.js](../phone/controller.js) | Buttons, requests, releases, status display |
| [build_maze4.py guide](build_maze4.md) | Build using supplied DOS tools |
| [run_maze4.py guide](run_maze4.md) | Start and supervise the cooperating processes |

The includes are source insertion, not separately running programs.
After assembly, their procedures belong to the same executable.

## 3. `.8086`, `.MODEL SMALL`, and `.STACK`

```asm
.8086
.MODEL SMALL
.STACK 1000H
```

`.8086` restricts the instruction set the assembler accepts.
It does not execute an instruction or switch the running CPU's mode.

The small model uses one code segment and one data group.
The stack reservation is `1000H = 4096` bytes.

Although the machine has 16-bit general registers, the program can represent
32-bit quantities in memory and manipulate them as two 16-bit words.
You already use the same general technique on 8085 when one byte is too small.

The registers used throughout this guide have these roles:

| Register | Meaning here |
| --- | --- |
| `AX`, `BX`, `CX`, `DX` | 16-bit general registers |
| `AH`/`AL`, `BH`/`BL`, `CH`/`CL`, `DH`/`DL` | High/low eight-bit halves of those registers |
| `SI`, `DI` | Source/destination offsets and array indices |
| `BP` | A general working/index register whose memory addressing normally uses `SS` |
| `CS:IP` | Segment and offset of the instruction being executed |
| `DS` | Segment used for ordinary shared-data accesses |
| `ES` | Destination segment for string stores and copies |
| `SS:SP` | Segment and offset of the CPU stack |

For example, `AX=1234H` means `AH=12H` and `AL=34H`. Changing `AL` changes
the low byte of `AX`; it does not create a separate unrelated value.
The notation `DX:AX` joins two registers into one mathematical 32-bit value,
with `DX` as the high word. It is different from a segment:offset address.

In real-mode addressing, a segment:offset pair selects physical address
`segment*16+offset`. A data access such as `MAZE[BX]` adds `BX` to the offset
of `MAZE` within `DS`. The program must load the segment registers at runtime;
declaring `.DATA` does not execute a CPU register load.

`CALL` saves a return address on `SS:SP`; a near `RET` restores the return
offset within the same code segment. `PUSH` and `POP` save/restore words in
last-in, first-out order. `PROC`, `ENDP`, `INCLUDE`, and `END MAIN` are
assembler declarations rather than instructions performed by the game.
The linked DOS executable supplies its initial stack and entry point to the
loader; `MAIN` then initializes the data registers.

`CMP` updates flags as a subtraction would, without storing the difference.
`JE`/`JNE` test equality, and `JB`/`JAE` test unsigned below/at-least relations.
`LOOP` decrements `CX` and branches if the resulting count is nonzero,
independently of the arithmetic zero flag. Entering such a loop with zero
would wrap the counter, so routines using it need a valid nonzero count or
an explicit guard. Later sections identify those assumptions.

## 4. Maze dimensions and linear addresses

```asm
ROWS EQU 17
COLS EQU 61
CELLS EQU ROWS*COLS
MAX_PLAYERS EQU 8
MOVE_TICKS EQU 2
```

`EQU` defines constants without reserving memory.
There are `17 × 61 = 1037` maze bytes.

The cell at row `r`, column `c` has index:

```text
cell = r * 61 + c
```

For example, `(3,10)` becomes `193`.
Up subtracts 61; down adds 61; left subtracts 1; right adds 1.

`MAZE[193]` means the byte at `DS:(OFFSET MAZE + 193)`.
It is not physical memory address `193`.

The main movement code currently compares its frame budget with literal `2`;
do not assume changing the `MOVE_TICKS` declaration alone changes that code.

## 5. Bytes, words, and doublewords

```asm
POSITIONS DW 8 DUP(0)
PLAYER_STATE DB 8 DUP(0)
STEPS DD 8 DUP(0)
```

For player index `i`:

| Array element type | Byte offset of element `i` |
| --- | --- |
| `DB` | `i` |
| `DW` | `2*i` |
| `DD` | `4*i` |

Thus `PLAYER_STATE[SI]` can use the unscaled player index.
`POSITIONS[BX]` needs `BX = 2*i`.
Two `SHL BX,1` instructions produce `4*i` for a doubleword array.

An 8085 `INX H` advances a byte pointer by one.
Likewise, incrementing an 8086 address by one still advances one byte,
even when the array contains words. The programmer must account for size.

## 6. The important state arrays

| Name | Meaning |
| --- | --- |
| `MAZE` | `#` wall, space floor, `E` shared exit |
| `STARTS` | Selected starting cell indices |
| `POSITIONS` | Current player cells |
| `CANDIDATES` | Proposed cells for the current frame |
| `DIRECTIONS` | Input selected for the current movement frame |
| `PLAYER_STATE` | 0 empty, 1 participating/racing, 2 finished, 3 DNF |
| `STEPS` | Successful cell changes |
| `PENALTIES` | Added time in tenths of a second |
| `FINISH_TIMES` | Unpenalized elapsed time when a player reaches `E` |
| `WARNINGS` | 0 safe, 1 caution, 2 danger |

State 1 is also used for participants waiting in the lobby.
`PHASE` distinguishes waiting from an active race.

## 7. Two different state machines

Room phase:

```text
1 lobby → 2 race → 3 results
```

Player state:

```text
0 empty → 1 participating → 2 finished
                         ↘ 3 DNF
```

They answer different questions:

```text
PHASE: What is the whole room doing?
PLAYER_STATE[i]: What happened to this player?
```

An occupied lobby slot has state 1 but cannot move because game motion
also requires phase 2.

## 8. `MAIN`: initialize the machine's environment

```asm
MOV AX,@DATA
MOV DS,AX
MOV ES,AX
CLD
```

`DS` selects the program's data group.
`ES=DS` is needed because copying/filling instructions write through `ES:DI`.

`CLD` clears the direction flag. After it:

```text
LODSB: AL = DS:[SI], then SI increases by 1
STOSB: ES:[DI] = AL, then DI increases by 1
STOSW: ES:[DI] = AX, then DI increases by 2
MOVSB: copy DS:[SI] to ES:[DI], advance both
```

`REP` repeats a string instruction `CX` times.
8085 normally implements these operations with explicit loads, stores,
pointer increments, and a counter loop.

## 9. Set up screen, time, maze, and input

`MAIN` selects BIOS video mode 3 and hides the cursor.
It reads the BIOS tick count through `INT 1AH`, saving `CX:DX` in `LAST_BIOS`.

The random seed is derived from the tick words:

```asm
MOV AX,DX
XOR AX,CX
OR AX,1
MOV RNG_SEED,AX
```

`OR AX,1` makes the seed odd.
This is game randomness, not password generation.

Then:

```asm
CALL GENERATE_MAZE
CALL SERIAL_INIT
CALL INSTALL_KEYS
```

## 10. The foreground loop

The order matters:

```text
READ_CLOCK
SERIAL_POLL
check Escape
HOST_CONTROLS
GAME_TICK
occasionally SEND_STATE
SERIAL_FLUSH
occasionally DRAW_SCREEN
idle or repeat
```

Serial input is processed before the next game update.
Drawing happens after the game state has been updated.

A single foreground thread owns assembly state.
The keyboard interrupt records host key events; it does not calculate moves.

## 11. Why `STI` and `HLT` appear together

When there are no queued outgoing bytes:

```asm
STI
HLT
JMP MAIN_LOOP
```

`STI` enables maskable interrupts.
`HLT` suspends instruction execution until a suitable event such as an
enabled timer or keyboard interrupt wakes the processor.

It does not terminate the DOS process.
The recurring timer lets foreground serial polling resume even though UART
interrupts are disabled.

The 8085 also has `HLT`, but the surrounding interrupt hardware and software
conventions differ.

---

## 12. `RANDOM`: generate a repeatable pseudo-random word

```asm
MOV AX,RNG_SEED
MOV BX,25173
MUL BX
ADD AX,13849
MOV RNG_SEED,AX
```

For word multiplication, `MUL BX` computes `AX * BX → DX:AX`.
Keeping only `AX` implements:

```text
seed = (25173 * seed + 13849) modulo 65536
```

`BX` and `DX` are saved/restored; `AX` returns the new value.
Identical initial seeds produce identical random sequences.

This linear congruential generator helps replay maze generation.
The Python bridge uses separate cryptographic facilities for credentials.

## 13. `RESET_GAME`: reset the contiguous player-state region

```asm
LEA DI,POSITIONS
MOV CX,OFFSET DISTANCES-OFFSET POSITIONS
REP STOSB
```

With `AL=0` and `ES=DS`, this clears the bytes from `POSITIONS` up to,
but excluding, `DISTANCES`.
That region includes movement, counters, warnings, and collision arrays.

The expression is evaluated by the assembler.
It depends on the order of declarations in `MAZE4.ASM`.

Priority, elapsed tenths, winner mask, and best score are reset separately.
The maze and generation scratch arrays are not cleared by this range fill.

## 14. DFS and BFS solve different problems

```text
DFS during carving:
    follow one route deeply, backtrack when stuck

BFS during distance calculation:
    explore all cells at distance 1, then 2, then 3, ...
```

DFS builds the maze.
BFS measures shortest walkable path lengths.

The `QUEUE` word array is reused as a DFS stack and a BFS queue at different
times. The two algorithms do not run simultaneously.

Both data structures are ordinary arrays in `DS`.
They are separate from the CPU stack selected by `SS:SP`.

## 15. `CARVE_MAZE`: fill with walls and open the first room

```asm
LEA DI,MAZE
MOV CX,CELLS
MOV AL,'#'
REP STOSB
MOV MAZE[COLS+1],' '
MOV QUEUE,COLS+1
MOV DFS_TOP,2
```

`COLS+1` is `(1,1)`.
The DFS stack contains one word, so its byte count is 2.

The outermost rows and columns stay walls.
This border is also important to later neighbor checks.

## 16. Carve two cells at a time

The direction table is:

```asm
DELTAS DW -COLS,COLS,-1,1
```

DFS doubles a direction delta before adding it to the current cell.
It moves between room cells separated by a wall.

Example:

```text
current: (1,1), index 62
right two cells: (1,3), index 64
midpoint: index (62+64)/2 = 63
```

The program opens both the new room and its midpoint passage.
It rejects cells outside the interior or already opened.

## 17. Random directions and backtracking

The starting direction comes from higher random bits:

```asm
MOV AL,AH
AND AX,3
SHL AX,1
```

`AX` becomes a word-table offset of 0, 2, 4, or 6.
All four directions are tried cyclically.

On success, the new cell is pushed onto the DFS array stack.
On four failures:

```asm
SUB DFS_TOP,2
```

removes the dead end and returns to the parent cell.
`DFS_TOP=0` means carving has finished.

## 18. Add loops and choose the exit

After DFS, the code scans interior walls.
For some walls passing `TEST AH,3`, it checks for floor on opposite sides.
Opening a qualifying wall creates an extra passage.

It does not open arbitrary boundary walls.
Adding passages preserves connectivity.

`CHOOSE_EXIT` repeatedly reduces a random word modulo `CELLS`:

```asm
XOR DX,DX
MOV BX,CELLS
DIV BX
```

The remainder `DX` is a candidate cell.
When that cell is floor, its index becomes `EXIT_POS` and its byte becomes `E`.

## 19. `BFS`: initialize distances and enqueue the root

Input: `AX` is a valid walkable root cell.
`BFS_LIMIT` controls the maximum explored distance.

```asm
MOV AX,0FFFFH
MOV CX,CELLS
REP STOSW
```

fills the word distance array with `FFFFH`, meaning unvisited.
The actual root then receives distance zero and is enqueued.

`BFS_HEAD` and `BFS_TAIL` are byte offsets into a word array:

```text
enqueue/dequeue one cell index → advance offset by 2
head >= tail → queue empty
```

## 20. BFS explores four neighbors

For each dequeued cell:

```text
if its distance reached BFS_LIMIT:
    do not expand it
else:
    for up, down, left, right:
        reject out-of-range cells
        reject walls
        reject already visited cells
        set distance = current distance + 1
        enqueue the neighbor
```

The distance is set before enqueueing.
Therefore each cell enters the fixed-capacity queue at most once.

FIFO exploration makes the first assigned distance the shortest path length
in this grid, where every step has equal cost.

## 21. Why the bounds test is unsigned

```asm
ADD AX,DELTAS[DI]
CMP AX,CELLS
JAE BFS_SKIP
```

A negative result wraps to a large unsigned word, which is also rejected by
`AX >= CELLS`.

This test alone would not prevent moving right from one row into the next.
The maintained wall border prevents that situation from being accepted.

`JB`/`JAE` are unsigned comparisons.
In 8085, you also interpret carry and zero after subtraction to implement
unsigned relations. The 8086 provides more named branch combinations.

## 22. `SELECT_STARTS`: measure distances from the exit

```asm
MOV BFS_LIMIT,0FFFFH
MOV AX,EXIT_POS
CALL BFS
```

This BFS has no small proximity cutoff.
Each reachable cell gets its shortest route distance to `E`.

The code counts non-exit floor cells in `FLOOR_COUNT`.
For eligible distances at least 12, it increments:

```text
HISTOGRAM[distance]
```

Here the mathematical subscript is a word element index.
The assembly doubles it to obtain a byte offset.

## 23. Capacity and equal-distance fairness

The program chooses a distance layer with the largest eligible population.
Random decisions break ties between equal-size layers.

Capacity is:

```text
minimum of:
    8
    floor(FLOOR_COUNT / 20)
    number of cells in the selected distance layer
```

All selected starts share `COMMON_DISTANCE`, at least 12.
That guarantees equal initial shortest route lengths through the maze.

It does not guarantee equal network delay, identical routes, or equal
interference from other players.

## 24. Reservoir sampling and shuffling

The code scans cells at the chosen distance.
It stores the first eight, then uses reservoir-style replacement:

```text
for eligible cell number n > 8:
    j = random_word modulo n
    if j < 8:
        STARTS[j] = this cell
```

Each reservoir entry comes from a distinct encountered cell.
Only `CAPACITY` entries are used for normal admissions.

A Fisher–Yates-style shuffle exchanges randomly chosen entries within the
usable prefix, so player order is not simply map scan order.

Modulo reduction and the finite pseudo-random generator should not be
mistaken for cryptographically uniform random sampling.

## 25. `GENERATE_MAZE`: keep the best candidate

The outer generator tries up to 64 candidates.
For each it calls:

```asm
CALL CARVE_MAZE
CALL SELECT_STARTS
```

If capacity improves, it copies the map into `BEST_MAZE` and metadata into
`BEST_META`. It stops early at capacity eight.

Finally it restores the best saved candidate.
Equal-capacity later candidates do not replace the saved one.

The 23 metadata bytes are:

```text
EXIT_POS          2
COMMON_DISTANCE   2
FLOOR_COUNT       2
CAPACITY          1
STARTS           16
total            23
```

The renderer displays an error message if final capacity is below two.

---

## 26. Movement is a proposal followed by a decision

The game update calls:

```asm
CALL BUILD_INTENTS
CALL RESOLVE_MOVES
CALL COMMIT_MOVES
CALL UPDATE_WARNINGS
```

All players propose moves using the same old positions.
Nobody moves permanently until pair conflicts have been examined.

This is the main improvement over moving players one at a time.
It also permits following another player into a cell that player successfully
vacates in the same frame.

## 27. `BUILD_INTENTS`: start with no movement

For each slot:

```asm
MOV AX,POSITIONS[BX]
MOV CANDIDATES[BX],AX
MOV BLOCKED[SI],0
```

Nonracers retain their old candidate.
For state 1, direction values mean:

| Direction | Meaning | Delta |
| --- | --- | --- |
| 0 | Idle | None |
| 1 | Up | `-61` |
| 2 | Down | `+61` |
| 3 | Left | `-1` |
| 4 | Right | `+1` |

Out-of-range destinations and walls also leave the candidate unchanged.
Hitting a wall alone does not add a collision penalty.

## 28. `CHECK_PAIR`: test two racing players

Inputs `SI` and `DI` are player indices.
The routine first skips nonracers and pairs where neither player moves.

It checks two conflict types:

```text
same candidate cell, except shared E

or

candidate[i] == old_position[j]
and candidate[j] == old_position[i]
```

The second case is a head-on swap.
Both players are blocked in a head-on exchange in either collision mode.

## 29. `BP` addressing needs an explicit data segment

The routine uses `BX=2*i` and `BP=2*j`:

```asm
MOV AX,CANDIDATES[BX]
MOV DX,DS:CANDIDATES[BP]
```

8086 memory addressing involving `BP` normally defaults to `SS`.
The explicit `DS:` override selects the shared data array instead.

This differs from 8085's single flat address space.
The effective offset is only part of an 8086 memory address; the segment
chosen for that access also matters.

## 30. Default collision mode: block and charge both

`COLLISION_MODE=0` is the default.
Conflicting players have their block flags set:

```asm
MOV BLOCKED[SI],1
MOV BLOCKED[DI],1
```

Contact is recorded in:

```text
PAIR_TOUCH[8*i+j]
```

Only unordered pairs `i<j` are visited.
The 64-byte square array makes indexing simple, even though most entries
are not needed for unordered pairs.

## 31. Alternative mode: rotating priority

`COLLISION_MODE=1` can arbitrate when two moving players want the same
non-exit destination.

Rank is:

```text
(player_index - PRIORITY) & 7
```

The lower rank wins; the other proposal is blocked.
No time penalty is added in this mode.

There are exceptions: a stationary occupant cannot be displaced, and a
head-on swap blocks both. Rotating priority does not exchange their positions.

## 32. `RESOLVE_MOVES`: why repeat pair checks eight times?

Imagine:

```text
A wants B's cell
B wants C's cell
C cannot leave
```

After B's proposal is canceled, B stays where A intended to go.
That can require canceling A too.

The resolver examines all pairs, then cancels blocked proposals as a separate
step. It repeats the process eight times, enough to propagate blocks through
the bounded eight-player roster.

`BLOCKED` remains set during this frame.
A canceled proposal is not reintroduced in a later pass.

## 33. Contact latches prevent repeated charges

After resolution, each pair is charged only when:

```text
mode == 0
PAIR_TOUCH == 1
previous PAIR_LATCH == 0
```

Then:

```asm
ADD WORD PTR PENALTIES[BX],30
ADC WORD PTR PENALTIES[BX+2],0
```

adds 30 tenths, or 3.0 seconds, to each player.

Holding the same blocked contact does not add 3 seconds every frame.
A contact-free frame clears the latch; a later renewed contact can charge again.
One player contacting three distinct opponents can receive three pair penalties.

## 34. `ADD` and `ADC` implement a 32-bit addition

Suppose a counter is:

```text
high word = 0001H
low word  = FFFFH
```

Adding one to the low word wraps it to zero and sets carry.
`ADC high,0` adds that carry:

```text
0001:FFFF → 0002:0000
```

This is the same carry-propagation idea as an 8085 multi-byte addition
using `ADD` for the first byte and `ADC` for the next.
Here each piece is 16 bits instead of 8.

## 35. `COMMIT_MOVES`: apply the surviving proposals

Only state-1 players whose candidate differs from their old position move.
Each actual change increments the 32-bit step count.

At `EXIT_POS`:

```asm
MOV PLAYER_STATE[SI],2
```

marks the player finished and copies `ELAPSED_TENTHS` to `FINISH_TIMES`.
That is the unpenalized finish time.

Finished players are excluded from future movement conflicts.
The shared exit permits multiple arrivals in one frame.

## 36. `ROTATE_PRIORITY`: rotate through racers

Priority advances cyclically until it finds state 1.
Empty, finished, and DNF slots are skipped.

The scan is bounded to eight attempts, so it also terminates after the last
racer disappears.

Why skip empty slots?
If only players 0 and 1 remain, rotating blindly over all eight indices would
give unequal repeated advantages. Rotating through active racers avoids that
particular bias.

The resolver normalizes an invalid priority owner before arbitration.
The commit routine rotates it for the following frame.

## 37. `UPDATE_WARNINGS`: proximity follows walkable routes

For each racing player, the code runs BFS with `BFS_LIMIT=4`.
It inspects the distances of other racing players:

| Shortest walkable distance | Warning |
| --- | --- |
| 0–2 | Danger, value 2 |
| 3–4 | Caution, value 1 |
| Greater than 4 or not visited | Safe, value 0 |

These match the on-screen wording `DANGER <3` and `CAUTION <5`.
Another opponent farther away cannot reduce a warning already raised to red.

Two characters close on the screen but separated by a long wall route
need not trigger a warning.

## 38. `GET_SCORE`: current or final adjusted time

Input: `SI` is the player index.
Output: unsigned score in `DX:AX`.

```text
if player is finished:
    score = FINISH_TIMES[i] + PENALTIES[i]
else:
    score = ELAPSED_TENTHS + PENALTIES[i]
```

The renderer labels DNF separately.
Calling this helper for a DNF row does not make that player eligible to win.

Steps are displayed statistics; they are not added to the score.

## 39. `FIND_WINNERS`: compare full doublewords and preserve ties

Only finished players participate.
Unsigned 32-bit comparison checks the high word first, then the low word.

```text
smaller score → replace best score and clear old winner bits
equal score   → add this player's bit
```

`WIN_MASK` bit `i` represents player `i`.
Players 0 and 3 tying gives `00001001B = 09H`.

Results are selected after no racers remain, not immediately when the first
player reaches the exit. A later arrival can win with fewer penalties.
If everyone becomes DNF, the winner mask stays zero.

---

## 40. COM1 is an I/O device, not a memory array

`SERIAL_INIT` accesses ports beginning at `3F8H`.
Examples:

```asm
MOV DX,3FDH
IN AL,DX
```

read UART status, while writing to port `3F8H` sends a byte.

8085 also has `IN` and `OUT`, but its immediate port addressing is 8-bit.
8086 permits a 16-bit port number in `DX`, needed for these COM1 ports.

DOSBox emulates this UART and carries its byte stream through a loopback
connection to the Python process.

## 41. `SERIAL_INIT`: program the UART

The routine:

```text
disables UART interrupts
sets the divisor-latch access bit
writes divisor 1
selects 8 data bits, no parity, 1 stop bit
asserts DTR and RTS
```

The intended UART configuration is 115200 baud, 8N1.
Foreground polling reads status rather than installing an IRQ4 handler.

Do not confuse disabling UART interrupts with disabling all CPU interrupts.
The BIOS timer and keyboard interrupt still serve the game.

## 42. Wire framing: text around binary payloads

The frame format is:

```text
':' + uppercase hexadecimal(payload bytes + XOR checksum byte) + LF
```

Each payload byte becomes two ASCII hex characters.
If the payload is `01H,02H`, checksum is `03H`:

```text
:010203\n
```

This is an illustration of framing; that short payload is not a valid game
request because a request needs its header.

For `n` payload bytes, encoded frame length is `2*n+4`.
The checksum detects some corruption; it is neither encryption nor authentication.

## 43. `QUEUE_CHAR`, `HEX_NIBBLE`, and `HEX_BYTE`

`QUEUE_CHAR` appends `AL` to `TX_BUFFER` if `TX_TAIL<2048`.
The queue is linear, not circular; it resets when fully drained.

`HEX_NIBBLE` keeps the low four bits, adds ASCII `'0'`, and adds seven more
for values 10–15 to obtain `'A'`–`'F'`.

`HEX_BYTE` saves the original byte, emits its high nibble first, then its low
nibble. A `4FH` byte becomes the characters `'4'`, `'F'`.

A nibble is four bits, so a byte contains a high nibble and a low nibble.
Shifting right by four exposes the high nibble; masking with `0FH` keeps the
low nibble. Each value 0–15 is then represented by one hexadecimal character.
ASCII `'4'` is `34H`; it is not the numeric nibble value 4.

## 44. `SEND_PACKET`: encode a complete frame

Input: `DS:SI` points to a nonempty payload; `CX` is its length.

The procedure queues `:`, loops over payload bytes using `LODSB`, XORs them
into `TX_CHECK`, emits their hex representations, then emits checksum and LF.

Its callers must reserve enough tail space for the complete frame.
`QUEUE_CHAR` itself silently ignores a character if full.

This procedure queues data; it does not wait for the UART to transmit it.
Separating queueing from hardware readiness helps keep game updates responsive.

## 45. `SERIAL_FLUSH`: send only while hardware is ready

The transmit-ready test is:

```asm
IN AL,DX
TEST AL,20H
JZ FLUSH_DONE
```

Status bit 5 indicates the transmit holding register is empty.
The routine transmits at most 512 bytes per call.

When no byte is ready to send, or the hardware is busy, it returns immediately.
When `TX_HEAD` reaches `TX_TAIL`, both reset to zero.

Queued snapshots and ACKs can be skipped under congestion; the program does
not promise delivery merely because a helper was called.

## 46. `PARSE_HEX`: ASCII back to a nibble

This helper accepts `0`–`9` and uppercase `A`–`F`.
It returns the value in `AL` and clears carry.
Invalid input sets carry.

```asm
CALL PARSE_HEX
JC POLL_INVALID
```

is a procedure-result convention, like using carry to report success from a
custom 8085 subroutine.

Lowercase hexadecimal is not accepted by this assembly receiver.
The provided encoder produces uppercase.

## 47. `SERIAL_POLL`: retain a parser across calls

The routine reads at most 256 UART bytes per call.
Its state variables survive when input is temporarily exhausted:

```text
RX_ACTIVE: inside a frame?
RX_HALF:   already have a high nibble?
RX_HIGH:   saved high nibble
RX_SIZE:   decoded bytes stored
RX_CHECK:  XOR of bytes so far
```

A colon starts a fresh frame, including when a damaged frame was in progress.
The first valid hex nibble is shifted left four bits.
The second is ORed into it to form one byte.

## 48. Receive bounds and end-of-frame validation

`RX_BUFFER` holds at most 96 decoded bytes, including the checksum.
Invalid hex or an overflow abandons the frame.

At LF, the parser requires:

```text
no unfinished nibble pair
XOR of payload and checksum == 0
at least 6 decoded bytes
```

The six-byte minimum is five header bytes plus checksum.
The checksum byte is removed from `RX_SIZE` before dispatch.

A malformed frame gets no dispatch; a later colon can resynchronize parsing.
These limits concern incoming requests, not the larger outgoing snapshots.

## 49. Request header and little endian

Every request starts with:

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 1 byte | Opcode |
| 1 | 2 bytes | Request ID |
| 3 | 2 bytes | Room epoch |

Words are little endian.
The word `1234H` appears as bytes `34H,12H`.

This is the same low-byte-first storage order familiar from 8085 register-pair
stores and instruction operands.
Hex framing preserves byte order; it does not reverse each word.

## 50. `RECEIVE_PACKET`: validate before acting

The default reply is invalid status 3 and slot `FFH`.
The first check compares the request epoch with `EPOCH`.
A stale room gets status 4.

Then the opcode selects configuration, join, or an owned-player operation.

| Opcode | Operation | Payload bytes including header |
| --- | --- | --- |
| 1 | Set displayed room password | 17 |
| 2 | Join with an eight-byte name | 13 |
| 3 | Direction/tap input | 14 |
| 4 | Heartbeat | 8 |
| 5 | Leave | 8 |
| 6 | Ready/unready | 9 |

These sizes exclude the checksum and text framing.

## 51. Configuration and the displayed room code

Opcode 1 supplies twelve characters after the header.
MASM validates all twelve before copying them into `ROOM_CODE`.
Its existing trailing zero is retained for screen output.

The Python bridge generates the actual random password and checks it during
browser login. MASM receives it for local display.

The assembly range check accepts characters between ASCII `'2'` and `'Z'`;
the bridge chooses from a narrower 32-character alphabet.

This configuration operation is on the trusted loopback bridge connection.
It is not a public browser host-control endpoint.

## 52. Joining is idempotent

Opcode 2 uses its nonzero request ID as the player's stable owner ID.
Before creating a player, MASM searches `OWNER_IDS` for that value.
If found, it returns the same slot.

This solves an important retry problem:

```text
join accepted → ACK lost → bridge retries same join
```

The retry should not create a second player.

A new join requires the lobby phase and available capacity.
It validates the entire eight-byte printable name before reserving the slot.

## 53. Initialize the admitted player

For a new slot, MASM sets:

```text
owner ID
position from STARTS[slot]
current session/input timestamps
state = 1
ready = 0
no accepted sequence yet
held/tap/direction = 0
```

It copies exactly eight space-padded name bytes.
Names are counted records, not zero-terminated strings.
`PLAYER_COUNT` is incremented only for a new admission.

## 54. Owned requests bind a command to its slot

After the common header, an owned request contains:

```text
slot: 1 byte
owner ID: 2 bytes
```

The slot must be 0–7, the owner must be nonzero and match `OWNER_IDS[slot]`,
and the player state must be nonempty.

The common ownership path refreshes `LAST_SEEN` before command-specific
validation. A rejected input can therefore refresh session liveness without
refreshing direction freshness.

An owner ID is a serial association value, not a browser credential.
The browser's secret session token is handled by the bridge.

## 55. Heartbeat and readiness

A valid opcode-4 heartbeat acknowledges liveness without changing direction.

Opcode 6 requires lobby phase, exact length nine, and a Boolean ready value.
It updates `READY[slot]`.

Readiness is not the same as starting.
The local host must press Space; `START_RACE` verifies the whole roster.

No phone command chooses collision mode, regenerates the maze, or starts a
new room. Those host actions remain local keyboard controls.

## 56. Input validation includes map identity

Opcode 3 requires:

```text
phase 2
player state 1
matching GENERATION
direction 0..4
tap flag 0 or 1
acceptable sequence number
```

Epoch identifies a room lifetime.
Generation identifies a maze layout within that lifetime.

Packets describing an older maze cannot be applied simply because the slot
number and owner still match.

## 57. Sequence numbers reject older input

The first sequence is accepted without comparison.
Later ones use:

```asm
MOV DX,AX
SUB DX,LAST_SEQUENCE[BX]
OR DX,DX
JLE RECEIVE_ACK
```

After `OR`, zero or a negative signed 16-bit delta is rejected.
The acceptable modular difference is 1–32767.

```text
old FFFFH → new 0000H: delta 1, accepted
old 0000H → new FFFFH: delta FFFFH, rejected
same → same: delta 0, rejected
```

This assumes forward jumps stay within the half-range window.
It is not ordinary unsigned `new > old` comparison.

## 58. A tap differs from a hold

For accepted input, MASM saves sequence and `LAST_DIRECTION` timestamp.

A hold stores the direction in `HELD[slot]`.
A tap instead stores the direction in `TAPS[slot]` and clears `HELD`.

At the next movement update:

```text
use pending tap if nonzero
otherwise use held direction
consume pending tap
```

One tap requests one frame's move, even if its later release request is delayed.
It can still produce no step if blocked.
The tap field is one latch per player, not an unbounded queue of presses.

## 59. `SEND_ACK`: acknowledge dispatch results

The seven-byte ACK payload is:

```text
81H, request ID:u16, current epoch:u16, status:u8, slot:u8
```

Status values are:

```text
0 accepted
1 new join outside lobby
2 room full
3 invalid request
4 stale room epoch
```

ACKs are queued only when enough tail space remains.
An ACK reports request handling; it does not guarantee a requested direction
will become a successful cell change.

## 60. `DROP_PLAYER`: leave or host removal

The procedure clears movement, ready, and warning state.

In the lobby it frees the slot, clears ownership, and decreases player count.
After the lobby it keeps the result row, revokes ownership, and changes a
still-racing player to DNF.

An already finished player remains finished.
Their result is not erased by changing their ownership.

Explicit removal is different from an automatic disconnect timeout, which
retains ownership for authenticated terminal-status access.

## 61. `SEND_STATE`: one coherent snapshot

The payload begins with `82H` and room/maze/clock metadata.
It then includes all eight fixed-size player records.

```text
header: 24 bytes
player record: 27 bytes
total: 24 + 8*27 = 240 bytes
encoded frame: 2*240 + 4 = 484 bytes
```

A player record contains state, warning, owner, position, 32-bit steps,
penalty, finish time, readiness, and eight name bytes.

`STOSB`, `STOSW`, and `REP MOVSB` build the binary payload in `OUT_BUFFER`.
The snapshot is skipped when the transmit queue lacks the reserved space.

The bridge returns only the authenticated player's record to that controller,
and strips its internal owner ID.

---

## 62. `READ_CLOCK`: subtract a 32-bit BIOS clock

```asm
MOV AH,0
INT 1AH
MOV AX,DX
MOV BX,CX
SUB AX,WORD PTR LAST_BIOS
SBB BX,WORD PTR LAST_BIOS+2
```

`CX:DX` is the current raw BIOS tick count.
`BX:AX` becomes the difference from the previous reading.

`SBB` propagates borrow into the high word.
This is the subtraction counterpart of `ADD`/`ADC`.

A borrow indicates daily rollover; the code adds `0018:00B0H` ticks to
correct the difference, then saves the new raw reading.

## 63. Three uses of the clock

| Variable | Use |
| --- | --- |
| `SYSTEM_TICK` | Short modular session/input ages and scheduling |
| `FRAME_TICKS` | Whether a movement update is due |
| `ELAPSED_TICKS` | 32-bit active-race time |

Race time accumulates only during phase 2.
Lobby waiting does not add to a player's finish time.

The short ages use 16-bit subtraction and assume regular polling over short
intervals. They are not general elapsed-time measurements for arbitrarily
long program suspension.

## 64. `DIVIDE_U32`: divide a doubleword using word operations

Input: unsigned `DX:AX`, nonzero divisor `BX`.
Output: quotient `DX:AX`, remainder `CX`.

Algorithm:

```text
save original low word
divide 0:high by divisor
save high quotient
divide previous remainder:original low by divisor
combine high quotient and low quotient
```

The second dividend's high word is a remainder smaller than the divisor,
so its quotient fits a word.

A single `DIV BX` cannot generally return a full 32-bit quotient.
8085 has no direct integer divide instruction; you would implement division
in software at a smaller word size.

## 65. `TICKS_TO_TENTHS`: avoid a large intermediate product

The conversion uses the approximation:

```text
tenths = floor(ticks * 100 / 182)
```

Instead of forming `ticks*100` first:

```text
q = ticks / 182
r = ticks % 182
tenths = 100*q + floor(100*r/182)
```

The procedure combines partial word multiplications and carries to return
the doubleword result in `DX:AX`.

This is an approximate BIOS-frequency conversion, not a precision wall clock.
All participants nevertheless use the same assembly race clock.

## 66. `GAME_TICK`: lease checks before movement

If fewer than two frame ticks accrued, the procedure returns.
Otherwise it resets `FRAME_TICKS` to zero.
It does not replay every missed frame after a long delay.

For each racing player it first checks session timeout and direction age.
Then it publishes one direction to `DIRECTIONS`.

Only phase 2 executes the four core movement procedures.
Afterward, if no state-1 player remains, it enters results and calls
`FIND_WINNERS`.

## 67. Two expiration intervals solve different problems

```text
LAST_DIRECTION age >= 14 BIOS ticks:
    clear hold and tap input

LAST_SEEN age >= 546 BIOS ticks during race:
    mark player DNF and clear input
```

At approximately 18.2 ticks/second these are about 0.77 seconds and 30 seconds.

A heartbeat can keep a controller connected without renewing an old direction.
This prevents a lost release from causing movement indefinitely.

Lobby players do not receive the race DNF timeout.
Automatic DNF retains the owner; explicit leave/removal clears it.

## 68. `START_RACE`: require at least two ready players

The procedure returns unless:

```text
phase == lobby
PLAYER_COUNT >= 2
every nonempty slot is ready
```

On success it sets phase 2 and clears elapsed/frame counters.
Players share one start clock.

An unready participant blocks the start even if every other participant is ready.
An empty slot does not need a ready flag.

## 69. `REGENERATE`: back up before replacing the map

Only the lobby permits regeneration.
The routine saves the old map and 23-byte metadata, then generates a new one.

If the new capacity cannot accommodate the current player count, it restores
the old map and metadata.
Otherwise it increments `GENERATION`, repositions slots, and clears readiness
and pending held/tap input.

Participants must ready again because the route has changed.

The implementation indexes starts by slot number; it does not compact the
roster as part of this routine. That is a useful distinction when reading
its loop over all eight slots.

## 70. `NEW_ROOM`: invalidate the previous room lifetime

New room is refused during an active race.
Otherwise it resets core state, increments epoch and generation, clears
roster/owners/readiness/names, restores password placeholders, and generates
a new maze.

Epoch zero is skipped if the 16-bit increment wraps.
The bridge detects the changed epoch, invalidates old browser sessions, and
generates/configures a fresh password.

Changing epoch and generation makes old packets distinguishable from current
ones; neither field is itself a cryptographic credential.

---

## 71. `HOST_CONTROLS`: actions come from key edges

| Key | Action |
| --- | --- |
| Tab | Toggle maze/scoreboard view |
| Space | Try starting the all-ready lobby |
| M | Toggle collision mode in lobby |
| R | Try regenerating the lobby maze |
| N | New room outside an active race |
| 1–8 | Remove an occupied slot |
| Escape | Exit through the main loop's cleanup path |

Each consumed edge is cleared before acting.
Holding a key does not repeatedly toggle a setting every frame.
The underlying routines also enforce their phase restrictions.

## 72. `INSTALL_KEYS` and `RESTORE_KEYS`

DOS function `3509H` returns the old interrupt-9 vector in `ES:BX`.
The program saves both words in `OLD_INT9`.

To install the new handler with DOS function `2509H`, it temporarily sets
`DS=CS`, so `DS:DX` identifies `KEYBOARD_ISR` in the code segment.
It then restores data `DS`.

Restoration uses:

```asm
LDS DX,OLD_INT9
MOV AX,2509H
INT 21H
```

`LDS` loads a far pointer's offset into `DX` and segment into `DS`.
The previous `DS` is saved/restored around this operation.

## 73. `KEYBOARD_ISR`: keep interrupt work short

The interrupt service routine saves `AX`, `BX`, and `DS`, reads port `60H`,
acknowledges the keyboard through port `61H`, and explicitly loads data `DS`.

It maintains:

```text
KEY_DOWN[index]: key currently held
KEY_EDGE[index]: unconsumed first-press event
```

A first make code sets both.
A typematic repeat while already down does not create a new edge.
A break code clears down state while preserving a pending edge.

Thus a quick press/release between foreground frames is still remembered.

## 74. Extended keys, Pause, and `IRET`

An `E0H` prefix marks an extended key; the code uses the upper half of the
256-entry arrays to distinguish it from an ordinary scan code.
An `E1H` Pause prefix causes the next five bytes to be skipped.

The handler sends `20H` to PIC port `20H` as an end-of-interrupt command.
Then it restores saved registers and executes `IRET`.

Unlike ordinary `RET`, `IRET` restores IP, CS, and FLAGS from the interrupt
stack frame. The 8085 interrupt-return environment is different.

The handler does not call DOS/BIOS or perform networking, maze generation,
or drawing. It replaces the keyboard handler until cleanup restores it.

## 75. Video memory is character/attribute pairs

Color text video memory begins at segment `B800H`.
Each screen cell occupies two bytes:

```text
low byte:  ASCII character
high byte: attribute/color
```

For an 80-column screen:

```text
video byte offset = row*160 + column*2
```

The maze begins at screen row seven.
A maze cell `(r,c)` appears at video offset `(r+7)*160+c*2`.

This memory-mapped display is different from the port-mapped UART accessed
with `IN`/`OUT`.

## 76. `CLEAR_SCREEN` and `VIDEO_CHAR`

`CLEAR_SCREEN` temporarily sets `ES=B800H` and fills 2000 words with `0720H`:

```text
20H = space character
07H = normal gray-on-black attribute
```

`VIDEO_CHAR` combines the character in `AL` with `VIDEO_ATTR` in `AH`,
temporarily selects video `ES`, and executes `STOSW`.
It restores `AX` and `ES`, while `DI` advances by two.

Direct memory writes do not advance the BIOS cursor.
The renderer manages positions through `DI` itself.

## 77. `VIDEO_TEXT`: print zero-terminated text

Input: `DS:SI` points to a zero-terminated string; `DI` is the video offset.

```asm
LODSB
OR AL,AL
JZ VIDEO_TEXT_DONE
CALL VIDEO_CHAR
```

It preserves the caller's `AX` and `SI`, but advances `DI` through output.

These strings end with zero, unlike DOS function-09H strings ending with `$`.
Player names are different again: exactly eight bytes with counted output.
Always identify which convention the current routine expects.

## 78. `VIDEO_NUMBER`: doubleword decimal output

Input is unsigned `DX:AX`.
Repeated `DIVIDE_U32` by ten produces remainders in reverse digit order.
They are pushed on the CPU stack, then popped and converted to ASCII.

Example:

```text
1234 / 10 → quotient 123, remainder 4
123  / 10 → quotient 12,  remainder 3
12   / 10 → quotient 1,   remainder 2
1    / 10 → quotient 0,   remainder 1
pop: 1,2,3,4
```

The divide loop executes once even for zero, so zero prints as `0`.
`BP` counts pushed digits independently of division's remainder register `CX`.

## 79. `VIDEO_TIME`: tenths as seconds and one digit

The routine divides the doubleword tenths value by ten.
The quotient is printed as whole seconds, then a dot, then the remainder.

```text
137 tenths → 13 seconds and 7 tenths → "13.7"
30 tenths  → 3 seconds and 0 tenths  → "3.0"
```

The fractional remainder is saved across printing the whole-number part.
No floating-point instruction or decimal fraction is stored in game state.

## 80. `STATE_LABEL` and `WARNING_LABEL`

`STATE_LABEL` returns `DS:SI` for the appropriate label:

```text
EMPTY, DNF, DONE, RACE
or, in lobby, WAIT / READY
```

`WARNING_LABEL` chooses SAFE, CAUTION, or DANGER and changes `VIDEO_ATTR`
to gray, yellow, or red.

These routines select text and color; they do not print it themselves.
The caller then invokes `VIDEO_TEXT`.
`BX` is retained as the player index across label selection.

## 81. `DRAW_SCREEN`: render current state

The routine clears the screen and writes metadata:

```text
count/capacity, equal route distance, floor cells
phase, collision mode, warning help
elapsed time, winner numbers, password/connection guidance
```

In maze view it copies the 17 rows of 61 map characters to video memory,
skipping the unused columns at the end of each screen row.

Only state-1 player digits are overlaid.
Finished and DNF players remain in the roster but disappear from the map.
The shared exit uses a green attribute.

## 82. Side roster and scoreboard view

The normal view places a colored player number/name and state/warning beside
the map. Names are rendered as exactly eight bytes.

Tab selects a full table containing:

```text
name, state, steps, penalty, adjusted score, warning
```

The scoreboard calls `GET_SCORE`, not a separate scoring algorithm.
It prints doubleword counters rather than truncating them to a word.

Rendering does not change race rules or award winners.
`DRAW_SCREEN` saves/restores its working registers, including `ES` and `DI`.

---

## 83. The bridge's authentication responsibilities

The host bridge creates a random twelve-character room password.
A successful login gets a separate browser session token, stored in a
Secure, HttpOnly, SameSite=Strict cookie in public mode.

State-changing controller operations also need the session's CSRF value and
the expected Origin. The handler checks the expected Host and fixed routes.

The bridge binds a session to epoch, slot, and owner.
It supplies that binding when building serial requests; the browser does not
choose another player's owner ID.

This is why a valid serial XOR checksum is not the authentication mechanism.
The public trust boundary is handled before a request reaches COM1.

## 84. Why browser retry identity is separate from a credential

`controller.js` retains a random join-attempt ID in `sessionStorage`.
It identifies retries of the same join; the room password is still required.
It is not the secret cookie or CSRF token.

The bridge reserves an owner before sending a join.
If an ACK is lost, it retains that uncertain reservation and reuses the owner
on retry rather than creating a new player.

`SerialLink` serializes request/ACK exchanges and retains the latest decoded
assembly snapshot. It does not predict movement or generate mazes.

## 85. Phone presses and releases

The controller sends a tap when a direction button is first pressed.
While held, it sends direction refreshes at 150 ms intervals.
Release sends direction zero with a newer sequence number.
State polling runs at 300 ms intervals when the document is visible.

It limits movement transmission to one outstanding request, one newest
pending update, and a pending tap latch, rather than building a stale backlog.

Blur, pointer cancellation, lost capture, and page visibility changes attempt
to release held input. The assembly lease remains the fallback if those
messages fail to arrive.

## 86. The launcher is process coordination

The build script stages the assembly sources under project scratch and mounts
the supplied DOS tools as a separate DOS drive. It runs DOSBox to assemble/link,
checks the executable signature and build log, and copies the resulting
executable into the assignment folder.

The launcher starts the loopback serial listener and HTTP bridge, starts
DOSBox, waits for assembly state, and configures the room password.
Internet mode then starts an HTTPS tunnel.

It accepts the tunnel address only after both an allocated banner URL and
a registered connection have been observed.

If a running tunnel stops, the PC race continues and MASM applies its normal
input expiry and disconnect rules. The launcher cleans up its owned processes
when the game ends. See the existing [runtime README](../README.md) for usage.

---

## 87. Worked frame: one successful right move

Suppose:

```text
phase = race
player 0 is state 1 at cell 193
fresh direction = right
cell 194 is floor and uncontested
steps[0] = 9
```

Execution:

```text
GAME_TICK publishes direction 4
BUILD_INTENTS proposes candidate 194
RESOLVE_MOVES finds no conflict
COMMIT_MOVES stores position 194 and steps 10
UPDATE_WARNINGS recomputes nearby opponents
```

The phone's ACK can precede this frame.
The next state snapshot reports the actual result.

## 88. Worked frame: two players want the same cell

```text
old A = 100, old B = 102
candidate A = 101, candidate B = 101
101 is ordinary floor
```

Default mode:

```text
both blocked
candidates return to 100 and 102
new contact episode → each receives 30 tenths
steps unchanged
```

Rotating mode, with A's rank lower:

```text
B blocked, A may move to 101
no time penalty
other pair interactions can still block a proposal
```

If 101 is the shared exit, the same-target exception permits both arrivals.

## 89. Worked trace: a latched contact

| Frame | Pair contact | Previous latch | Added penalty per player |
| --- | --- | --- | --- |
| 1 | Yes | 0 | 3.0 seconds |
| 2 | Yes | 1 | 0 |
| 3 | Yes | 1 | 0 |
| 4 | No | 1 | 0; latch clears |
| 5 | Yes | 0 | 3.0 seconds |

The eight internal collision passes do not multiply the charge.
Charging occurs after all passes and uses the per-pair touch/latch state.

## 90. Worked trace: delayed release and disconnect

```text
tick t:
    fresh held-right input accepted

by a movement update at age >=14 ticks without new direction:
    HELD/TAPS cleared, direction becomes idle

if heartbeats keep arriving:
    player stays connected but no longer moves

at a race update with LAST_SEEN age >=546 ticks:
    player becomes DNF and cannot move or win
```

These are update-time checks, not asynchronous events fired at an exact
wall-clock instant. The foreground loop must run to apply them.

## 91. Worked result: first arrival does not necessarily win

```text
A: finish 20.0s + penalty 6.0s = score 26.0s
B: finish 23.0s + penalty 0.0s = score 23.0s
C: DNF
```

B wins even though A arrived first.
C is excluded rather than assigned a competitive final score.

If A and B both score 23.0 seconds, their bits are both set.
The winner calculation uses all 32 bits of each score.

## 92. High-level equivalent

```c
initialize_segments_video_clock();
generate_best_maze();
initialize_serial();
install_host_keyboard_handler();

while (!escape_edge) {
    read_clock();
    poll_bounded_serial_input();
    handle_local_host_actions();

    if (movement_frame_due()) {
        expire_input_and_disconnected_players();

        if (phase == RACE) {
            build_all_candidates();
            resolve_pairs_and_cancel_for_eight_passes();
            charge_new_contact_episodes();
            commit_surviving_moves_and_finishers();
            update_path_distance_warnings();

            if (no_racers_remain()) {
                phase = RESULTS;
                select_lowest_score_finishers();
            }
        }
    }

    maybe_queue_state_snapshot();
    flush_ready_serial_bytes();
    maybe_draw_screen();
    wait_for_interrupt_when_idle();
}

restore_previous_keyboard_handler();
restore_text_mode_and_exit_to_dos();
```

This pseudocode shows responsibilities, not every register save or parser branch.

## 93. Important limitations when explaining this program

- Eight is an upper bound; actual capacity also depends on floor density and
  the selected equal-distance layer.
- Network delay is not equalized by equal-distance starts.
- Random generation retries are bounded; the UI includes a low-capacity error.
- A tap is a one-frame request, not a guaranteed successful step.
- Movement updates discard excess frame backlog rather than catching up every
  missed move after a pause.
- Bounded serial queues can skip ACKs or snapshots under congestion.
- Epochs, generations, owner IDs, and sequence words are finite counters; their
  purpose is association and stale-input rejection, not cryptography.
- Text rendering assumes the DOS color-text environment provided by the runtime.

The checked-in [VERIFICATION.md](../VERIFICATION.md) records earlier runtime
evidence and its limits. Reading it is different from rerunning those tests.

## 94. What transfers from your 8085 knowledge?

| Familiar 8085 idea | Where it appears here |
| --- | --- |
| Register-pair arithmetic | `DX:AX` and two-word counters |
| Carry/borrow propagation | `ADC` and `SBB` on high words |
| Memory pointer in `HL` | `SI`, `DI`, `BX`, and explicit segment selection |
| Counted byte loop | `CX` with `LOOP` or `REP` |
| Software stack in an array | DFS stack and BFS queue |
| Interrupt routine saves registers | `KEYBOARD_ISR` saves its working registers |
| I/O port input/output | UART and keyboard port accesses |
| Conditional branching after comparison | Unsigned bounds, state tests, pair decisions |

The new concepts are segmented addressing, string instructions, PC services,
two-phase movement, shared state machines, framed communication, and controller
session binding. Learn them one at a time rather than memorizing the file.

## 95. Exam-ready explanation

> MAZE4 is a DOS 8086 maze race whose rules are authoritative in MASM. It carves
> random mazes with DFS, measures shortest exit routes with BFS, and selects
> distinct starts at a common distance. The serial layer validates room, owner,
> generation, and input sequence before supplying leased directions. Each frame
> builds all proposals, resolves pair conflicts before committing, and charges
> new contact episodes in the default penalty mode. Finish time plus penalties
> determines the winner among finishers when no racers remain. The Python and
> browser components provide authenticated transport and controls; the PC renders
> the assembly state and retains local host actions.
