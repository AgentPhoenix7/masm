# M4CORE.INC — maze generation and game rules, from 8085 knowledge

Source: [M4CORE.INC](../M4CORE.INC). Shared declarations:
[MAZE4.ASM](../MAZE4.ASM).

Related guides: [complete MAZE4 flow](MAZE4.md),
[serial/session module](M4SER.md), and [host interface module](M4UI.md).

This guide follows the core include file in detail. It explains how the maze,
start cells, movement proposals, collision decisions, warnings, and scores are
calculated. Examples are source-derived traces, not reports of a new DOSBox or
phone test.

No earlier maze version or guide is required. Shared storage, traversal
algorithms, movement proposals, and collision episodes are introduced below.

You can read this file as an extension of an 8085 array-processing exercise:
the program still loads memory, compares values, follows pointers, and updates
counters. The larger algorithms arise from combining those operations with
explicit data structures.

---

## 1. What this module owns

`M4CORE.INC` contains fourteen procedures:

| Procedure | Main job |
| --- | --- |
| `RANDOM` | Advance a 16-bit pseudo-random state |
| `RESET_GAME` | Clear player, collision, clock, and result state |
| `BFS` | Calculate shortest walkable path distances |
| `GENERATE_MAZE` | Keep the best of up to 64 generated candidates |
| `CARVE_MAZE` | Create connected passages, loops, and an exit |
| `SELECT_STARTS` | Choose capacity and equally distant starting cells |
| `BUILD_INTENTS` | Convert directions into proposed positions |
| `RESOLVE_MOVES` | Propagate collision cancellations and apply penalties |
| `CHECK_PAIR` | Classify one pair of players' proposals |
| `COMMIT_MOVES` | Apply surviving proposals and record finishes |
| `ROTATE_PRIORITY` | Advance priority through active racers |
| `UPDATE_WARNINGS` | Measure nearby racers through maze corridors |
| `GET_SCORE` | Add elapsed/frozen time and penalty |
| `FIND_WINNERS` | Select all finishers tied for the smallest score |

There are no DOS, BIOS, UART, keyboard, or video calls in this include. External
modules supply input, elapsed time, admission, and display.

---

## 2. An include is source insertion

The main source contains:

```asm
.CODE
INCLUDE M4CORE.INC
```

MASM processes the include's instructions as part of the same executable. This
is not a separate program or a dynamic library.

The `.DATA` declarations in `MAZE4.ASM` are therefore directly accessible by
these procedures. A reference such as `RNG_SEED` names shared memory, not a
parameter copied into a private module.

The model is `.8086` and `.MODEL SMALL`: ordinary arithmetic registers are
16-bit, with one code segment and a data group. Doubleword memory values are
handled through pairs of 16-bit operations.

---

## 3. Map coordinates become one linear cell number

```asm
ROWS EQU 17
COLS EQU 61
CELLS EQU ROWS*COLS
MAZE DB CELLS DUP('#')
```

There are 1037 map bytes. For zero-based row `r` and column `c`:

```text
cell = 61*r + c
```

Examples:

| Coordinate | Cell |
| --- | --- |
| `(0,0)` | 0 |
| `(1,1)` | 62 |
| `(5,10)` | 315 |
| `(5,11)` | 316 |
| `(6,11)` | 377 |

Up/down change the cell by `-61/+61`; left/right change it by `-1/+1`.

`MAZE[315]` means `DS:(OFFSET MAZE+315)`, not physical address 315.

---

## 4. Scale array indices by the element size

The same mathematical player number is used with several storage widths:

```asm
PLAYER_STATE DB 8 DUP(0)
POSITIONS DW 8 DUP(0)
PENALTIES DD 8 DUP(0)
```

For player `i`:

```text
PLAYER_STATE byte offset = i
POSITIONS word offset   = 2*i
PENALTIES dword offset  = 4*i
```

The source expresses multiplication by two with `SHL register,1`.

```asm
MOV BX,SI
SHL BX,1
SHL BX,1
```

converts a player number in `SI` into a doubleword-array byte offset in `BX`.

On 8085, `INX H` moves a pointer by one byte. The same byte-address rule applies
here: word arrays do not automatically make `INC` advance by two.

---

## 5. Player states and directions are small codes

| `PLAYER_STATE[i]` | Meaning |
| --- | --- |
| 0 | Empty |
| 1 | Participating/racing |
| 2 | Finished |
| 3 | DNF, did not finish |

The runtime also uses state 1 for admitted lobby participants; it calls movement
only during the racing phase. The core does not independently check `PHASE`.

| `DIRECTIONS[i]` | Meaning |
| --- | --- |
| 0 | Idle |
| 1 | Up |
| 2 | Down |
| 3 | Left |
| 4 | Right |

The delta table stores words:

```asm
DELTAS DW -COLS,COLS,-1,1
```

The direction code must be reduced by one and doubled before indexing it.

---

## 6. Shared scratch storage has a lifecycle

| Storage | During generation | During a race |
| --- | --- | --- |
| `QUEUE` | DFS stack, then BFS queue | BFS queue for proximity |
| `DISTANCES` | Exit distances for start selection | Current racer's local distances |
| `HISTOGRAM` | Number of cells at each exit distance | Not needed for movement |
| `STARTS` | Selected start cells | Admission/start placement data |
| `CANDIDATES` | Not generation state | Current frame proposals |
| `PAIR_TOUCH` | Not generation state | Contacts found in current resolution |
| `PAIR_LATCH` | Reset for a new game | Previous frame's contact episodes |

Reusing `QUEUE` saves memory because DFS and BFS do not run simultaneously.
The source is foreground shared-state code, not a reentrant library whose
procedures can safely overlap on separate calls.

---

## 7. Register contracts must come from the source

The four procedures below explicitly save their working registers:

| Procedure | Result | Explicitly preserved |
| --- | --- | --- |
| `RANDOM` | Next word in `AX` and `RNG_SEED` | `BX`, `DX` |
| `RESET_GAME` | Shared game state reset | `AX`, `CX`, `DI`, `ES` |
| `BFS` | Shared distance map/queue fields | `AX`, `BX`, `CX`, `DX`, `SI`, `DI`, `BP`, `ES` |
| `GENERATE_MAZE` | Shared map/start metadata | `AX`, `BX`, `CX`, `DX`, `SI`, `DI`, `BP`, `ES` |

Registers not touched by a procedure also survive, but most remaining helpers
freely use their scratch registers. In particular, callers must not expect
`CHECK_PAIR`, `SELECT_STARTS`, or `UPDATE_WARNINGS` to preserve all general
registers.

`GET_SCORE` takes player number `SI`, returns `DX:AX`, and uses `BX` as scratch.
There is no module-wide “carry means success” convention. Flags are scratch
unless a specific instruction sequence immediately consumes them.

---

## 8. DS, ES, and the direction flag

Ordinary data references use `DS`, except addressing through `BP` defaults to
`SS` unless overridden. String stores/copies involve `ES:DI`:

```text
STOSB/STOSW → write AL/AX to ES:DI
MOVSB       → copy DS:SI to ES:DI
```

`REP` uses `CX` as a repetition count. With direction flag clear (`CLD`), the
offsets advance; with direction flag set they retreat.

The runtime initializes `DS=ES=@DATA` and executes `CLD`. Several procedures
temporarily establish `ES=DS` themselves, but none makes its own unconditional
`CLD` guarantee. The caller must maintain forward direction.

8085 has no segment registers or direction flag. A comparable copy normally
uses explicit pointer increments and a software loop.

---

## 9. `RANDOM`: one state word, one recurrence

```asm
MOV AX,RNG_SEED
MOV BX,25173
MUL BX
ADD AX,13849
MOV RNG_SEED,AX
```

Word `MUL BX` forms the unsigned product in `DX:AX`. Keeping `AX` and ignoring
the high word implements:

```text
next = (25173*old + 13849) modulo 65536
```

The addition's overflow is also intentionally discarded. `BX` and `DX` are
saved/restored around the calculation, leaving the result in `AX`.

For seed 1:

```text
25173*1 + 13849 = 39022 = 986EH
```

The generator is deterministic, not cryptographically secure. Same initial
seed and same sequence of calls give the same subsequent values.

---

## 10. Why different random bits are used

The DFS direction choice includes:

```asm
MOV AL,AH
AND AX,3
SHL AX,1
```

After copying `AH` into `AL`, masking to 3 keeps two bits originating from the
upper half of the generated word. Shifting produces one of:

```text
0, 2, 4, 6
```

These are byte offsets of the four word entries in `DELTAS`.

The recurrence's low bit alternates because both multiplier and increment are
odd. Picking directions directly from the lowest bits would expose a simple
pattern. Using higher bits reduces that particular problem; it does not make
the generator secure or perfectly unbiased.

---

## 11. `RESET_GAME`: clear a contiguous state region

```asm
PUSH ES
PUSH DS
POP ES
XOR AX,AX
LEA DI,POSITIONS
MOV CX,OFFSET DISTANCES-OFFSET POSITIONS
REP STOSB
```

The `PUSH DS / POP ES` pair copies a segment register through the stack.

`REP STOSB` zeros the byte interval beginning at `POSITIONS` and ending just
before `DISTANCES`. In the current declaration order that interval is 293
bytes: player arrays, results, pair tables, and blocked flags.

The length is calculated from labels rather than hardcoded. Changing the
declaration order can therefore change what this reset covers.

---

## 12. What reset preserves and reinitializes

`RESET_GAME` additionally sets:

```asm
MOV PRIORITY,0
MOV WORD PTR ELAPSED_TENTHS,0
MOV WORD PTR ELAPSED_TENTHS+2,0
MOV WIN_MASK,0
MOV WORD PTR BEST_SCORE,0FFFFH
MOV WORD PTR BEST_SCORE+2,0FFFFH
```

Zero is appropriate for counters, but the initial best score must be the largest
unsigned doubleword, `FFFFFFFFH`, so the first smaller finisher can replace it.

The map, selected starts, exit, generator seed, capacity, and collision-mode
setting are not rebuilt by this routine. In particular, reset does not imply
maze generation.

Its temporary `ES` value and explicitly saved registers are restored before
returning.

---

## 13. `GENERATE_MAZE`: the outer search

```asm
MOV BEST_CAP,0
MOV GEN_TRIES,64

GEN_CANDIDATE:
    CALL CARVE_MAZE
    CALL SELECT_STARTS
```

Each candidate is a complete map with its own exit, eligible layer, capacity,
and selected starts.

The objective being maximized is **capacity**, not longest path, maximum floor
count, or most visually interesting maze.

```asm
MOV AL,CAPACITY
CMP AL,BEST_CAP
JBE GEN_NEXT
```

Only a strictly larger capacity replaces the saved candidate. Equal-capacity
maps do not replace the earlier winner.

---

## 14. Save the map and packed metadata

The map backup is a 1037-byte copy:

```asm
LEA SI,MAZE
LEA DI,BEST_MAZE
MOV CX,CELLS
REP MOVSB
```

Then the source copies seven bytes beginning at `EXIT_POS`, followed by sixteen
bytes of `STARTS`. Together they are:

| Metadata offset | Field | Bytes |
| --- | --- | --- |
| 0 | `EXIT_POS` | 2 |
| 2 | `COMMON_DISTANCE` | 2 |
| 4 | `FLOOR_COUNT` | 2 |
| 6 | `CAPACITY` | 1 |
| 7..22 | Eight `STARTS` words | 16 |

`DI` continues after the first seven-byte copy, so the start words immediately
follow it inside `BEST_META`.

This layout is packed; no padding directive separates these declarations.

---

## 15. Stop at eight or exhaust 64 candidates

```asm
CMP BEST_CAP,8
JE GEN_RESTORE
DEC GEN_TRIES
JNZ GEN_CANDIDATE
```

Eight is the program's maximum player capacity. Once achieved, more candidates
cannot improve the chosen objective.

Otherwise, every generated candidate consumes one retry count. At most 64
candidates are produced by this outer loop.

At `GEN_RESTORE`, the saved map and its matching metadata are copied back, then
`CAPACITY` is assigned from `BEST_CAP`.

The snapshot does not include `RNG_SEED`, `DISTANCES`, or `HISTOGRAM`. In
particular, restoring an earlier best map does not restore its scratch BFS
distances. Any later distance consumer must call BFS for the restored map.

---

## 16. `CARVE_MAZE`: start with walls

```asm
LEA DI,MAZE
MOV CX,CELLS
MOV AL,'#'
REP STOSB
MOV MAZE[COLS+1],' '
MOV QUEUE,COLS+1
MOV DFS_TOP,2
```

All cells begin as walls. Cell `(1,1)`, index 62, becomes the first floor cell.

The `QUEUE` array is temporarily a **DFS stack**. Its first word contains that
cell index. `DFS_TOP=2` is the next free byte offset, not the number of cells.

Do not confuse this software stack with the CPU's `SS:SP` stack. DFS entries
are in ordinary data memory; `CALL` return addresses remain on the CPU stack.

---

## 17. Peek rather than pop while exploring

```asm
CMP DFS_TOP,0
JE DFS_LOOPS
MOV BX,DFS_TOP
MOV SI,QUEUE[BX-2]
MOV DFS_CURRENT,SI
```

The top entry is at `top-2`, because each entry is a word and `top` points past
the used part.

The current cell stays on the stack while a new neighbor is explored. A child
is pushed after its parent, so returning from a dead end exposes the parent
again.

This implements depth-first search without recursive procedure calls. It is
the same logical backtracking you could implement with an explicit array on
8085.

---

## 18. Four directions, two cells at a time

After choosing a random starting direction, the code sets `DFS_TRIES=4`.

```asm
MOV BX,DFS_DIRECTION
MOV AX,DELTAS[BX]
SHL AX,1
ADD AX,DFS_CURRENT
```

The delta is doubled: move two rows or two columns to another room, leaving a
potential separating wall midway.

Starting from odd row/column `(1,1)`, two-cell steps visit odd-coordinate rooms.
There are eight such interior rows and thirty such columns, or 240 rooms.

The graph of these rooms is connected before carving: each adjacent room is
reachable by a possible two-cell step. DFS opens a connected spanning structure
through them.

---

## 19. Check both the linear index and row/column

```asm
CMP AX,CELLS
JAE DFS_REJECT
MOV DI,AX
XOR DX,DX
MOV BX,COLS
DIV BX
```

The unsigned comparison rejects indices at or above 1037. A subtraction that
wrapped below zero becomes a large unsigned word and is rejected too.

Division by 61 gives:

```text
AX = row
DX = column
```

The following comparisons require:

```text
1 <= row < 16
1 <= column < 60
```

These separate row/column checks prevent a two-cell horizontal move from
wrapping into another row and preserve the closed outer wall ring.

---

## 20. Open a room and its midpoint

```asm
CMP MAZE[DI],'#'
JNE DFS_REJECT
MOV MAZE[DI],' '
MOV BX,DFS_CURRENT
ADD BX,DI
SHR BX,1
MOV MAZE[BX],' '
```

A room already opened by DFS is visited and cannot be carved again through
this branch.

For a two-cell straight move, the midpoint is:

```text
(current cell + target cell) / 2
```

Example: `(1,1)=62` to `(1,3)=64` opens midpoint 63, `(1,2)`.

The index sum is small enough not to overflow a word. Because the endpoints
are two grid steps apart in one direction, their average is an integer cell.

---

## 21. Push the child, or backtrack after four failures

On successful carving:

```asm
MOV BX,DFS_TOP
MOV QUEUE[BX],DI
ADD DFS_TOP,2
JMP DFS_CELL
```

On rejection:

```asm
ADD DFS_DIRECTION,2
AND DFS_DIRECTION,7
DEC DFS_TRIES
JNZ DFS_TRY
SUB DFS_TOP,2
JMP DFS_CELL
```

Direction offsets cycle through 0, 2, 4, 6. Four failures pop this dead end.

When a parent becomes current again, its starting direction is randomized
again; the program does not keep a separate direction cursor for every stack
depth. Already-open rooms are still rejected, so it never reopens them as new
children.

---

## 22. Add some loops without breaking connectivity

After the DFS stack empties, the source scans interior walls. It skips side
boundary columns and uses:

```asm
CALL RANDOM
TEST AH,3
JNZ LOOP_NEXT
```

to consider roughly one quarter of eligible walls, based on those two random
bits.

A selected wall opens if opposite horizontal neighbors are floor, or if
opposite vertical neighbors are floor.

Opening a wall adds connections to a map that is already connected. It does
not disconnect an existing passage. The scan leaves the outer wall ring
closed.

The resulting maze need not be a perfect tree: extra openings can create
cycles and alternative routes.

---

## 23. Choose an exit from actual floor

```asm
CALL RANDOM
XOR DX,DX
MOV BX,CELLS
DIV BX
MOV BX,DX
CMP MAZE[BX],' '
JNE CHOOSE_EXIT
MOV EXIT_POS,BX
MOV MAZE[BX],'E'
```

The remainder is a cell index in `0..1036`. Wall results are retried until a
floor cell is obtained.

The exit is internal walkable floor marked `E`; it is not an opening cut into
the map boundary.

The outer candidate count is bounded, but this particular rejection-sampling
loop has no explicit attempt counter. The map contains many floor cells and
the pseudo-random sequence is used to find one.

---

## 24. `BFS`: shortest paths need a FIFO queue

Depth-first search is useful for carving, but breadth-first search measures
shortest routes through equally weighted grid steps.

`BFS` receives a valid walkable root cell in `AX` and a global distance cutoff
in `BFS_LIMIT`.

Its queue is FIFO:

```text
append new cells at tail
remove old cells at head
```

This visits distance 0, then distance 1, then distance 2, and so on. The first
distance assigned to a cell is therefore its shortest walkable path length
from the root.

The procedure preserves the caller's general registers and `ES`; its results
remain in `DISTANCES` and queue fields.

---

## 25. Initialize all distances to unvisited

```asm
LEA DI,DISTANCES
MOV AX,0FFFFH
MOV CX,CELLS
REP STOSW
```

`STOSW` stores a word and advances `DI` by two. `CX=CELLS` therefore fills 1037
words, or 2074 bytes.

`FFFFH` means unvisited, not a real path length. Valid simple shortest paths
in a 1037-cell graph cannot need 65535 steps.

The original root is saved on the CPU stack while `AX` is reused for the fill.
It is then restored, assigned distance zero, and placed in the first queue
word.

```asm
MOV BFS_HEAD,0
MOV BFS_TAIL,2
```

means one cell is initially queued.

---

## 26. Dequeue and apply the distance cutoff

```asm
MOV BX,BFS_HEAD
CMP BX,BFS_TAIL
JAE BFS_DONE
MOV SI,QUEUE[BX]
ADD BFS_HEAD,2
```

After loading its known distance into `BP`:

```asm
CMP BP,BFS_LIMIT
JAE BFS_NEXT
INC BP
```

the routine expands only cells whose distance is below the limit.

With limit 4, distance-3 cells may discover distance-4 neighbors, but distance-4
cells do not discover distance-5 neighbors. Thus distance 4 is included in the
results.

With limit `FFFFH`, all reachable cells can be explored under this map size.

---

## 27. Reject bad neighbors and mark before enqueueing

```asm
MOV AX,SI
ADD AX,DELTAS[DI]
CMP AX,CELLS
JAE BFS_SKIP
MOV BX,AX
CMP MAZE[BX],'#'
JE BFS_SKIP
SHL BX,1
CMP DISTANCES[BX],0FFFFH
JNE BFS_SKIP
MOV DISTANCES[BX],BP
```

The four delta offsets are 0, 2, 4, 6. `DI` is their byte offset, not a player
number in this procedure.

Marking the distance **before enqueueing** means a second predecessor cannot
enqueue the same cell again. There are at most 1037 queue entries, matching
the allocated word capacity.

The exit `E` is walkable because only `#` is rejected.

---

## 28. A border invariant completes BFS safety

An unsigned linear bound alone does not detect crossing from the last column
of one row into the first column of another.

For generated maps, every boundary cell remains a wall. A valid walkable root
cannot be on that boundary, and reaching a boundary neighbor is rejected as a
wall before it can be expanded.

Therefore BFS depends on two conditions together:

```text
root is valid walkable floor
outer wall ring is intact
```

It is not a general validator for arbitrary corrupted maps. `BUILD_INTENTS`
relies on the same maintained border idea for one-cell movement.

---

## 29. A small BFS trace

Consider this illustrative corridor fragment, with all other adjacent cells
blocked:

```text
62 — 63 — 64
          |
         125
```

Root 62 gives:

| Dequeued | Known distance | Newly discovered |
| --- | --- | --- |
| 62 | 0 | 63 at 1 |
| 63 | 1 | 64 at 2 |
| 64 | 2 | 125 at 3 |
| 125 | 3 | None |

If the cutoff were 2, cell 64 would be recorded but not expanded; cell 125
would remain `FFFFH`.

Walls force path distance to follow corridors. Straight-line closeness alone
does not determine this result.

---

## 30. `SELECT_STARTS`: measure from the exit

```asm
MOV BFS_LIMIT,0FFFFH
MOV AX,EXIT_POS
CALL BFS
```

Now `DISTANCES[2*cell]` is the shortest route length from the exit to that cell.
Movement is undirected, so it is also that cell's shortest route to the exit.

The histogram is cleared using `REP STOSW`, and `FLOOR_COUNT` starts at zero.
For each nonwall cell other than the exit, the source increments floor count.

Only distances at least 12 and below `CELLS` are entered into the histogram.
The upper bound excludes `FFFFH` and any impossible distance value before
doubling it into a word-array byte offset.

---

## 31. A histogram groups equal route lengths

```asm
MOV BX,AX
SHL BX,1
INC HISTOGRAM[BX]
```

Here `AX` is a path distance. Thus the mathematical statement is:

```text
histogram[distance] += 1
```

For example:

| Distance | Eligible cells |
| --- | --- |
| 11 | Not counted for starts |
| 12 | 5 |
| 13 | 7 |
| 14 | 4 |
| 15 | 7 |

The desired layer has as many eligible cells as possible. Distance 13 or 15
would be selected in this example, not distance 14 just because it is larger
than 13.

---

## 32. Select a largest layer and break ties randomly

The scan begins with:

```asm
XOR BP,BP
MOV COMMON_DISTANCE,12
MOV SI,24
```

`SI=24` is twice distance 12. `BP` tracks the largest bucket count.

A smaller bucket is skipped. A larger bucket replaces the best. Equal bucket
counts use a bit from `RANDOM` to decide whether to replace it.

```asm
MOV BP,HISTOGRAM[SI]
MOV AX,SI
SHR AX,1
MOV COMMON_DISTANCE,AX
```

converts the selected byte offset back to a distance.

This pairwise tie-breaking rule is not a proof of uniform selection among all
tied layers. It is simply the actual randomized rule in this source.

---

## 33. Capacity combines three bounds

The calculation is:

```text
capacity = min(8, floor(FLOOR_COUNT/20), largest eligible layer count)
```

Division by 20 uses:

```asm
MOV AX,FLOOR_COUNT
XOR DX,DX
MOV BX,20
DIV BX
```

The quotient is rounded down, giving a policy of at most one admitted player
per twenty non-exit floor cells, before the other caps are applied.

Example: floor count 478 and selected layer count 6 give:

```text
min(8, 23, 6) = 6
```

With these fixed dimensions, the basic 240-room DFS already carves 240 rooms
and 239 connecting cells, so the density bound normally exceeds eight. The
formula still states the implemented capacity policy explicitly.

---

## 34. Equal-distance fairness has a precise meaning

Every usable start is selected from `COMMON_DISTANCE`, and that distance is
at least 12 when an eligible group is selected.

Thus players begin with equal shortest walkable route lengths to `E`.

This does not assert equal turning difficulty, identical paths, equal numbers
of competing players along a route, or equal phone/network latency.

The returned capacity can be below eight even though arrays have eight slots.
The runtime is responsible for enforcing that admission limit and handling a
capacity below the minimum needed for a race.

---

## 35. Reservoir sampling avoids a large temporary cell list

The source scans all cells whose stored distance equals `COMMON_DISTANCE`.

For the first eight matches, it stores the cell in the corresponding start
slot. For eligible cell number `n>8`:

```asm
CALL RANDOM
XOR DX,DX
DIV BX
CMP DX,8
JAE RESERVOIR_NEXT
MOV BX,DX
```

`BX` initially holds `n`; the remainder is an index from 0 through `n-1`.
If it is below eight, that reservoir slot is replaced by the new cell.

With an ideal uniform random choice, this is the standard eight-item reservoir
rule. Here the finite pseudo-random word and modulo reduction introduce the
sampling limitations already noted for the RNG.

---

## 36. Trace the reservoir replacement

Suppose the first eight eligible cells are `a,b,c,d,e,f,g,h`.

```text
STARTS = [a,b,c,d,e,f,g,h]
```

For the ninth cell `i`, a remainder of 3 gives:

```text
STARTS = [a,b,c,i,e,f,g,h]
```

For the tenth cell `j`, a remainder of 9 makes no replacement because 9 is not
below eight.

Every retained entry names a distinct encountered cell: each scan cell appears
once and can replace only one slot.

The reservoir retains up to eight entries regardless of `CAPACITY`; only the
usable prefix is later shuffled and admitted. Entries outside the usable
prefix are not extra authorized starts.

---

## 37. Shuffle the usable starts

```asm
MOV CL,CAPACITY
CMP CX,2
JB STARTS_DONE
```

For a remaining count `CX`, the source picks `j=random modulo CX` and swaps
`STARTS[j]` with `STARTS[CX-1]`:

```asm
MOV AX,STARTS[DI]
XCHG AX,STARTS[BX]
MOV STARTS[DI],AX
LOOP SHUFFLE_START
```

`BX=2*j` and `DI=2*(CX-1)` address word entries. The `XCHG` uses `AX` as the
temporary value for a memory/register exchange.

This Fisher–Yates-style shrinking-prefix shuffle changes slot assignment
without changing the selected cells or their distances. The last iteration
with count one is a harmless self-swap.

---

## 38. Generation outputs and scratch are different

After `GENERATE_MAZE`, consumers should use:

```text
MAZE, EXIT_POS, COMMON_DISTANCE, FLOOR_COUNT, CAPACITY, STARTS
```

as the restored best candidate.

`DISTANCES`, `HISTOGRAM`, and DFS/BFS counters remain scratch from the most
recent calculations; the best-map snapshot does not preserve them.

The backup is updated only on a positive improvement over initial `BEST_CAP=0`.
The normal generated connected maps provide usable layers, but there is no
separate fallback map committed by this routine for a hypothetical run in
which every candidate had zero capacity. The caller checks the resulting
capacity before allowing normal play.

---

## 39. One movement frame has four ordered stages

The runtime calls:

```asm
CALL BUILD_INTENTS
CALL RESOLVE_MOVES
CALL COMMIT_MOVES
CALL UPDATE_WARNINGS
```

These calls occur after the serial/session module has selected fresh leased
directions and established that the race is active.

The core sequence means:

```text
read old positions → propose all moves → resolve all conflicts
                  → change positions → recalculate proximity
```

Updating player 0 immediately before considering player 1 would give the first
player a different view of the frame. Proposals keep the old-position snapshot
available to every pair before committing anything.

---

## 40. `BUILD_INTENTS`: begin with “stay here”

For each of eight slots:

```asm
MOV BX,SI
SHL BX,1
MOV AX,POSITIONS[BX]
MOV CANDIDATES[BX],AX
MOV BLOCKED[SI],0
CMP PLAYER_STATE[SI],1
JNE INTENT_NEXT
```

Every candidate initially equals the old position. A slot must be racing to
receive a different proposal.

This makes idle, invalid, wall-blocked, and nonracing inputs all default to
staying put, without separate assignments in each rejection branch.

`BLOCKED` is cleared once here for the new frame. It will not be cleared during
the collision passes of that same frame.

---

## 41. Convert a valid direction into a neighbor proposal

```asm
XOR DX,DX
MOV DL,DIRECTIONS[SI]
CMP DX,1
JB INTENT_NEXT
CMP DX,4
JA INTENT_NEXT
DEC DX
SHL DX,1
MOV DI,DX
ADD AX,DELTAS[DI]
```

For direction 4, the resulting table offset is `(4-1)*2=6`, selecting `+1`.

The candidate is accepted only if its unsigned index is below `CELLS` and its
map byte is not `#`. `E` is therefore a legal target.

The source does not increment steps or finish a player at this point. An
accepted neighbor is merely a proposal that may still be canceled.

---

## 42. Intent examples before collision resolution

Suppose the shown cells are floor and all named slots are racing:

| Player | Old cell | Direction | Candidate |
| --- | --- | --- | --- |
| 0 | 315 | Right | 316 |
| 1 | 317 | Left | 316 |
| 2 | 377 | Up | 316 |
| 3 | 400 | Idle | 400 |

The first three all propose the same cell. `BUILD_INTENTS` still accepts those
individually because it checks walls/bounds, not player occupancy.

This separation matters: collision policy belongs to the next stage rather
than being mixed into direction decoding.

---

## 43. Pair storage uses a different scaling rule

For player numbers `i` and `j`:

```text
pair offset = 8*i + j
```

The pair arrays each have 64 bytes, corresponding to an 8-by-8 table.

```asm
MOV BX,SI
MOV CL,3
SHL BX,CL
ADD BX,DI
```

calculates this offset. A variable-count shift uses `CL`, an 8086-supported
form; the code does not assume a later processor's arbitrary immediate shift
count encoding.

Only unordered pairs with `i<j` are processed. Thus offset `8*2+5=21` is used
for pair `(2,5)`; the reverse entry is not a separate contact.

---

## 44. `RESOLVE_MOVES`: prepare the complete pass

First, the priority cursor is normalized if its current owner is not a racer:

```asm
XOR BX,BX
MOV BL,PRIORITY
CMP PLAYER_STATE[BX],1
JE RESOLVE_INIT
CALL ROTATE_PRIORITY
```

The cursor is maintained in `0..7` by normal initialization and rotation.

Then `ES` is saved and set to `DS`. The 64-byte touch table is cleared with
32 word stores:

```asm
LEA DI,PAIR_TOUCH
XOR AX,AX
MOV CX,32
REP STOSW
MOV RESOLVE_PASSES,8
```

`PAIR_LATCH` is not cleared here: it must retain previous-frame contact state.

---

## 45. Scan all pairs before canceling proposals

`PAIR_I` runs from 0 through 6; `PAIR_J` runs from `i+1` through 7.

```asm
MOV SI,PAIR_I
MOV DI,PAIR_J
CALL CHECK_PAIR
```

There are:

```text
8*7/2 = 28 unordered pairs
```

per pass. Persistent memory counters are used because `CHECK_PAIR` uses
scratch registers, including `BX`, `BP`, `AX`, `DX`, and `CL`.

`CHECK_PAIR` sets block/contact flags but does not rewrite either candidate.
After the complete pair scan, a separate loop replaces every blocked candidate
with that player's actual position.

---

## 46. Why there are eight resolution passes

Consider three players in adjacent cells:

```text
A at 315 → 316
B at 316 → 317
C at 317 → stays at 317
```

During the first pass, B conflicts with stationary C. B's proposal is canceled
after the pass, restoring candidate 316.

During the second pass, A now conflicts with B's restored occupied cell 316.
So A is canceled too.

Blocks can propagate backward through a longer chain one stage at a time.
Eight passes bound this propagation for eight slots. The code always performs
the full eight passes; it does not test for an earlier fixed point.

Once `BLOCKED[i]` becomes 1, it remains 1 for this frame. A later comparison
cannot re-enable that proposal.

---

## 47. `CHECK_PAIR`: first establish who participates

```asm
CMP PLAYER_STATE[SI],1
JNE PAIR_DONE
CMP PLAYER_STATE[DI],1
JNE PAIR_DONE
```

Only two racing players are considered. Empty, finished, and DNF slots do not
block another racer through this procedure.

The word offsets are:

```asm
MOV BX,SI
SHL BX,1
MOV BP,DI
SHL BP,1
MOV AX,CANDIDATES[BX]
MOV DX,DS:CANDIDATES[BP]
```

`BP`-based memory references normally select `SS`, so the explicit `DS:` on
the second array access is essential. It is not redundant decoration.

---

## 48. Two stationary players do not create a new contact

```asm
CMP AX,POSITIONS[BX]
JNE PAIR_ACTIVE
CMP DX,DS:POSITIONS[BP]
JE PAIR_DONE
```

If neither candidate differs from its old position, there is no attempted
movement conflict to resolve.

Therefore “touch” means a conflict found in the movement proposals, not merely
standing next to someone. Adjacency is handled by the warning subsystem.

This also lets a frame with released input clear a previous contact latch,
even if the two players have not walked away from their nearby cells.

---

## 49. Same destination and the shared exit exception

```asm
CMP AX,DX
JNE PAIR_SWAP
CMP AX,EXIT_POS
JE PAIR_DONE
```

Two equal proposed cells normally mean a conflict. Equal proposals at `E` are
explicitly allowed.

Thus two racers can finish at the shared exit in the same frame without
blocking or charging each other for that same-target arrival.

This exception is tested before collision-mode arbitration. It applies in
both modes.

---

## 50. Default mode blocks both contenders

`COLLISION_MODE=0` is the normal block-plus-penalty mode.

For two moving players proposing the same nonexit cell, execution reaches:

```asm
MOV BLOCKED[SI],1
MOV BLOCKED[DI],1
```

Then the pair's touch byte is set. The later cancellation loop restores both
candidates to their old positions.

The penalty is not charged inside `CHECK_PAIR`. Otherwise the same contact
would be charged again when encountered in later resolution passes.

---

## 51. Rotating mode compares cyclic ranks

For mode 1, two moving contenders for the same nonexit destination
can be ranked by:

```text
rank(i) = (i - PRIORITY) & 7
```

The smaller rank wins. The assembly uses low-byte subtraction followed by a
mask:

```asm
MOV AX,SI
SUB AL,PRIORITY
AND AX,7
MOV DX,DI
SUB DL,PRIORITY
AND DX,7
CMP AX,DX
```

The low-byte wrap is compatible with modulo eight because eight divides 256.

For `PRIORITY=5`, slot 5 has rank 0, slot 6 rank 1, slot 0 rank 3, and slot 4
rank 7.

---

## 52. Priority does not let a racer enter an occupied stationary cell

Before cyclic arbitration, both candidates are checked against their own old
positions. If either contender is stationary, the code blocks both.

Example:

```text
A: 315 → 316
B: 316 → 316
```

B already occupies the destination. A cannot displace B just by having a
smaller cyclic rank.

Priority mode also does not promise that an initially winning proposal will
survive every later dependency: another pass can reveal that its destination
has become occupied after a different move was canceled.

---

## 53. Head-on exchanges block both in either mode

If the destinations differ, `PAIR_SWAP` checks:

```asm
CMP AX,DS:POSITIONS[BP]
JNE PAIR_DONE
CMP DX,POSITIONS[BX]
JNE PAIR_DONE
```

Both comparisons must match to mean:

```text
candidate(i) = old position(j)
candidate(j) = old position(i)
```

So `315→316` and `316→315` is a head-on swap and both are blocked.

Neither mode automatically swaps their positions. A player can break the
conflict by backing away, allowing later forward movement.

---

## 54. Following a moving player is different from a swap

For:

```text
A: 315 → 316
B: 316 → 317
C: 317 → 318
```

the candidates are distinct, and no pair exchanges both old positions.
The chain may move together if its leading destination is free and no other
conflict intervenes.

For a stationary-ended chain of eight players, blocks instead propagate
backward until every candidate is restored. In default mode, the two endpoints
can each encounter one contacting neighbor while middle players encounter two:

```text
new penalties in tenths: [30,60,60,60,60,60,60,30]
```

This is pairwise accounting, not a flat one-penalty-per-frame cap.

---

## 55. `PAIR_TOUCH` accumulates across the passes

Every conflict sets:

```asm
MOV PAIR_TOUCH[BX],1
```

The touch table is cleared once at the start of `RESOLVE_MOVES`, not between
its eight passes. A contact found in an earlier proposal snapshot remains
recorded even after cancellations change that pair's later proposals.

This is intentional: collision detection can involve several passes, but
charging is a separate once-per-frame scan of the accumulated pairs.

The latch table then remembers whether that pair also had contact in the
previous movement frame.

---

## 56. Charge once per contact episode

The default-mode charge condition is:

```text
PAIR_TOUCH[pair] == 1 and PAIR_LATCH[pair] == 0
```

After the decision:

```asm
MOV PAIR_LATCH[BX],AL
```

copies this frame's touch state into the latch, even in priority mode.

| Frame | Touch | Previous latch | New charge to each in mode 0 | New latch |
| --- | --- | --- | --- | --- |
| First attempted contact | 1 | 0 | 30 tenths | 1 |
| Continued attempted contact | 1 | 1 | 0 | 1 |
| No contact | 0 | 1 | 0 | 0 |
| Later new contact | 1 | 0 | 30 tenths | 1 |

Mode 1 adds no time penalty. Keeping its latches still records whether contact
has continued across frames and mode changes.

---

## 57. Add three seconds with low/high word carry

For each charged player:

```asm
ADD WORD PTR PENALTIES[BX],30
ADC WORD PTR PENALTIES[BX+2],0
```

Times use tenths of a second:

```text
30 tenths = 3.0 seconds
```

`ADD` updates the low word. `ADC` adds the high word plus any carry from that
low-word operation.

Example:

```text
old = 0000:FFFAH = 65530
add = 0000:001EH = 30
new = 0001:0018H = 65560
```

Without `ADC`, the low word would wrap but the high word would remain wrong.
On 8085, the same multi-byte technique uses `ADD` on the least-significant
byte and `ADC` on more-significant bytes.

---

## 58. Four-way contention means several independent pair episodes

Take four moving racers approaching one nonexit center cell from its four
neighbors. There are six unordered pairs among them:

```text
(0,1), (0,2), (0,3), (1,2), (1,3), (2,3)
```

In default mode, every racer conflicts with three others. If these are new
contacts, each receives:

```text
3 * 30 = 90 tenths = 9.0 seconds
```

All four stay at their old cells. Holding the same conflicting directions
does not add another 9.0 seconds each frame because those pair latches are set.

This example also explains why penalties are doublewords rather than a small
single collision counter.

---

## 59. `ROTATE_PRIORITY`: scan racers, not all slot numbers equally

```asm
MOV CX,MAX_PLAYERS

PRIORITY_NEXT:
    INC PRIORITY
    AND PRIORITY,7
    XOR BX,BX
    MOV BL,PRIORITY
    CMP PLAYER_STATE[BX],1
    JE PRIORITY_DONE
    LOOP PRIORITY_NEXT
```

Empty, finished, and DNF slots are skipped. For racers only in slots 2 and 5,
the priority owner advances 2 → 5 → 2 rather than spending turns on six unused
slots.

There are at most eight checks. If nobody is racing, it returns after the
bounded scan instead of looping forever. The cursor no longer identifies a
live racer in that case, which is harmless once there are no contenders.

---

## 60. Why normalization and post-frame rotation are separate

`RESOLVE_MOVES` normalizes the cursor before arbitration if its owner has become
inactive, for example through disconnect or a previous finish.

`COMMIT_MOVES` calls `ROTATE_PRIORITY` after applying this frame, advancing the
owner for the next frame among those still racing.

These operations prevent unused slots or departed cursor owners from giving
one of two persistent contenders several extra priority turns.

For otherwise-identical repeated two-racer contests, active-roster rotation
alternates which racer ranks first. That is a local arbitration property, not
a guarantee of equal final scores under arbitrary routes or network inputs.

---

## 61. `COMMIT_MOVES`: count actual cell changes

```asm
CMP PLAYER_STATE[SI],1
JNE COMMIT_NEXT
MOV BX,SI
SHL BX,1
MOV AX,CANDIDATES[BX]
CMP AX,POSITIONS[BX]
JE COMMIT_NEXT
MOV POSITIONS[BX],AX
SHL BX,1
ADD WORD PTR STEPS[BX],1
ADC WORD PTR STEPS[BX+2],0
```

Only a racer whose final candidate differs from its old position moves and
gets a step. Wall attempts, idle input, and canceled collisions add no steps.

After the second shift, `BX` changes from `2*i` to `4*i`, matching the step
counter's doubleword layout.

`STEPS` counts travelled cells, not raw phone button events or attempted moves.

---

## 62. Reaching E freezes unpenalized finish time

```asm
CMP AX,EXIT_POS
JNE COMMIT_NEXT
MOV PLAYER_STATE[SI],2
MOV AX,WORD PTR ELAPSED_TENTHS
MOV WORD PTR FINISH_TIMES[BX],AX
MOV AX,WORD PTR ELAPSED_TENTHS+2
MOV WORD PTR FINISH_TIMES[BX+2],AX
```

`FINISH_TIMES` stores elapsed race time without adding penalties. Score
calculation adds penalties later.

Changing the state to 2 excludes the finisher from later movement, collision,
and racer-proximity calculations.

Two surviving candidates can both enter `E` in this frame. They receive the
same elapsed-time snapshot, though their existing penalties can make final
scores different.

The commit procedure assumes normal initialization placed racers away from
`E`; its finish check occurs only after an actual position change.

---

## 63. `UPDATE_WARNINGS`: proximity follows passages

```asm
MOV BFS_LIMIT,4
XOR SI,SI
```

For each slot, the old warning is cleared. A racing slot runs BFS from its
current position, then scans other racers' distance values.

| Walkable path distance to another racer | Warning code |
| --- | --- |
| 0..2 | 2, red |
| 3..4 | 1, yellow |
| More than 4 or unvisited | 0 unless another racer triggers a warning |

The routine excludes self and nonracers. Once red has been assigned, a later
farther opponent cannot downgrade it to yellow.

Players one screen cell apart across a wall can have a long route between
them and therefore no warning. This is a path-distance rule, not a coordinate
or straight-line distance rule.

---

## 64. Warning array indexing crosses two levels

The source reads an opponent's position, then uses that cell number as an
index into the distance words:

```asm
MOV BX,DI
SHL BX,1
MOV BX,POSITIONS[BX]
SHL BX,1
MOV AX,DISTANCES[BX]
```

The two shifts have different meanings:

```text
first shift  → 2*opponent number, to load a position word
second shift → 2*cell number, to load that cell's distance word
```

`BFS` preserves `SI` and `DI`, so the warning loop's player indices survive its
distance calculation. The warning routine as a whole still uses scratch
registers freely.

---

## 65. `GET_SCORE`: choose time, then add penalty

Input is player index `SI`. Output is unsigned score in `DX:AX`:

```text
DX = high word
AX = low word
```

It starts by loading the current elapsed time. If the player's state is 2, it
replaces that base with the saved finish time. Then:

```asm
ADD AX,WORD PTR PENALTIES[BX]
ADC DX,WORD PTR PENALTIES[BX+2]
```

adds the player's 32-bit penalty.

```text
finished → frozen finish time + penalty
otherwise→ current elapsed time + penalty
```

The getter itself does not reject empty or DNF slots. Callers decide whether
that computed value is meaningful for display or winner eligibility.

---

## 66. `FIND_WINNERS`: filter finishers before comparing scores

The routine resets:

```asm
MOV WIN_MASK,0
MOV WORD PTR BEST_SCORE,0FFFFH
MOV WORD PTR BEST_SCORE+2,0FFFFH
```

It then scans eight slots, calling `GET_SCORE` only when `PLAYER_STATE=2`.
Empty, still-racing, and DNF players cannot win.

Unsigned doubleword comparisons inspect the high word first:

```asm
CMP DX,WORD PTR BEST_SCORE+2
JB WIN_NEW
JA WIN_NEXT
CMP AX,WORD PTR BEST_SCORE
JB WIN_NEW
JA WIN_NEXT
```

Only equal high words require a low-word comparison. Comparing low words
first would misorder scores across the 65536 boundary.

---

## 67. Keep all equal-score winners in a bit mask

On a smaller score, `WIN_NEW` stores the new score and clears previous winner
bits. On a complete tie, it preserves them.

Both paths reach:

```asm
MOV CX,SI
MOV AL,1
SHL AL,CL
OR WIN_MASK,AL
```

Player `i` corresponds to bit `1<<i`.

```text
player 0 → 00000001b
player 2 → 00000100b
player 5 → 00100000b
```

Tied winners 2 and 5 give `00100100b`, hexadecimal `24H`.

If nobody finished, the scan leaves `WIN_MASK=0`. There is no automatic winner
among DNF players merely because all racers have stopped.

---

## 68. Worked scoring and winner trace

Suppose the race ends with:

| Player | State | Finish time | Penalty | Eligible score |
| --- | --- | --- | --- | --- |
| 0 | Finished | 100 tenths | 60 | 160 |
| 1 | Finished | 130 tenths | 0 | 130 |
| 2 | Finished | 100 tenths | 30 | 130 |
| 3 | DNF | Not eligible | 0 | Excluded |

The winner scan proceeds:

```text
player 0 → best 160, mask 00000001b
player 1 → better 130, clear old bit, mask 00000010b
player 2 → tied 130, add bit, mask 00000110b
player 3 → skip
```

Players 1 and 2 tie at 13.0 seconds. Player 0 physically finished earlier than
player 1 but loses after penalties are included.

---

## 69. Generation pseudocode, matching the procedure boundaries

```text
GENERATE_MAZE:
    best_capacity = 0
    repeat at most 64 times:
        CARVE_MAZE:
            fill map with walls
            open room (1,1), push it
            while DFS stack not empty:
                try four two-cell directions from current room
                carve and push an unvisited valid room if one exists
                otherwise pop the current room
            optionally open qualifying interior separating walls
            randomly select an existing floor as E

        SELECT_STARTS:
            BFS from E without a small distance cutoff
            count nonexit floor and eligible distance layers >=12
            select a largest layer, randomizing equal-count replacements
            capacity = min(8, floor_count//20, layer_count)
            reservoir-sample up to eight cells of that layer
            shuffle the usable prefix

        if capacity strictly improves best:
            save map and 23 metadata bytes
        if best_capacity == 8:
            break
    restore best map and metadata
```

---

## 70. Movement pseudocode, including the latch boundary

```text
BUILD_INTENTS:
    for each slot:
        candidate = old position
        blocked = false
        if racer with valid direction and walkable neighbor:
            candidate = neighbor

RESOLVE_MOVES:
    normalize priority to a racer when necessary
    clear this frame's pair-touch table
    repeat 8 passes:
        for each unordered pair:
            CHECK_PAIR, recording blocks and contact
        restore every blocked candidate to its old position

    for each unordered pair:
        if mode 0 and touching now but not latched before:
            add 30 tenths to each player's penalty
        latch = touching now

COMMIT_MOVES:
    for each racer with a changed candidate:
        store position, increment 32-bit steps
        if at E:
            mark finished and freeze elapsed time
    rotate priority through remaining racers

UPDATE_WARNINGS:
    clear warnings
    for each racer:
        limited BFS to distance 4
        choose highest proximity warning from other racers
```

---

## 71. The 8085 connections to keep

| Existing 8085 idea | Larger use in this module |
| --- | --- |
| Walk through bytes with an HL pointer | Scan maze, player arrays, and histogram |
| Counter plus conditional branch | DFS trials, BFS queue loop, bounded pair passes |
| Software stack of values | DFS uses `QUEUE` and `DFS_TOP` |
| Multi-byte arithmetic with carry | 32-bit steps, penalties, and scores |
| Compare before subtracting | Unsigned bounds and score ordering |
| Bit masks | Winner membership and cyclic priority |
| Save working registers across a call | BFS preserves outer-loop indices |

8086 adds useful instructions and addressing forms: native `MUL`/`DIV`,
`REP STOSW`, `REP MOVSB`, independently usable index registers, and segment
overrides. The algorithms remain explicit memory-and-control-flow programs.

---

## 72. Limits and assumptions of the actual core

All procedures assume valid shared array indices and normal initialization.
BFS and one-cell intent bounds rely on the generated closed wall border.
The core is not independently validating arbitrary hostile memory corruption.

The RNG and modulo reductions provide game variation, not security or exact
uniform sampling. Equal shortest starting distances provide one particular
fairness property; they do not equalize transport delays or later interference.

The movement resolver uses bounded repeated cancellation, not a general solver
for arbitrary simultaneous-motion systems. It allows following, blocks head-on
swaps, and permits shared exit arrivals according to these exact rules.

Counters and scores are unsigned 32-bit values. `ADD`/`ADC` correctly propagate
carry between words, but there is no saturation or overflow error beyond the
full 32-bit range.

Clock updates, input leases, disconnects, readiness, and race phases belong to
`M4SER.INC`; display and host keys belong to `M4UI.INC`. The core calculates
rules from the state those modules establish.

---

## 73. Exam-ready explanation

The core creates a connected maze with randomized iterative DFS, adds selected
extra passages, and chooses a floor exit. BFS from that exit supplies shortest
route lengths. A distance histogram chooses the largest eligible equal-distance
layer, capacity is capped by density and eight players, and reservoir sampling
plus shuffling chooses starts. Up to 64 maps are considered, retaining the
candidate with the greatest capacity.

Each movement frame first builds every player's proposal. Repeated pair scans
mark conflicts and propagate blocked moves before any positions are committed.
Default mode blocks contacts and adds three seconds once per pair contact
episode; rotating mode selects between moving same-target contenders without
time penalties. Head-on swaps block both, following can proceed, and the shared
exit accepts simultaneous finishers.

Committed movement increments step counters and freezes finish time at `E`.
Limited BFS computes corridor-distance warnings. Scores add penalties to
elapsed or frozen time, and a high-word-first unsigned comparison retains all
finished players tied for the smallest score in a winner bit mask.
