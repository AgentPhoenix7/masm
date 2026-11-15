# MAZE — one player, a fixed map, and arrow-key movement

Read this with [MAZE.ASM](../MAZE.ASM) open beside it.
The comparisons assume that you already know 8085 registers, flags,
memory pointers, jumps, subroutines, and basic input/output.

The intended game is:

```text
draw a fixed maze
    ↓
wait for an arrow key
    ↓
propose a new position
    ↓
reject walls and invalid coordinates
    ↓
save a legal position and redraw
```

There is an important source issue before we study that flow.

---

## 1. The current file contains an accidentally repeated program

Inside the first `DRAW_MAZE` procedure, the source reaches:

```asm
    POP BP
    POP SI
    POP DX
    POP CX
    POP BX; 8086 / MASM / DOS: navigate a maze using the arrow keys.
```

After that line, another copy of the program starts.
It contains another `.MODEL`, `.DATA`, `MAIN`, `DRAW_MAZE`, and `END MAIN`.
The original `POP AX`, `RET`, and closing declarations appear afterward.

The semicolon after `POP BX` begins a comment; it does not make the following
copy part of that comment.
Only the text on that same line is commented out.

Therefore, this file is not a clean, single source module.
Do not assume that its existing `.EXE` was assembled from this exact file.
These notes explain the intended single-copy program and identify the broken
source layout; they do not claim that the current source builds successfully.

The repeated block uses the same movement and rendering ideas.
You do not need to learn a second game algorithm from it.

---

## 2. How this differs from a simple 8085 memory exercise

An 8085 exercise may read a byte from `3000H`, modify it, and store it at `4000H`.
This game still manipulates bytes in memory, but gives those bytes meanings:

```text
'#'       → a wall
' '       → a walkable cell
PLAYER_ROW → vertical position
PLAYER_COL → horizontal position
```

The screen is a display of that state.
It is not the authoritative map used for collision checks.

That separation explains why drawing `@` does not destroy a map byte.
The player is drawn over the map on the screen.

---

## 3. `.8086`, `.MODEL SMALL`, and `.STACK`

```asm
.8086
.MODEL SMALL
.STACK 100H
```

`.8086` tells MASM to accept the 8086 instruction set.
It is an assembler directive, not a CPU instruction executed by the game.

`.MODEL SMALL` selects the simplified model with one code segment and one
data group, appropriate for a small DOS executable.

`.STACK 100H` reserves `100H = 256` stack bytes.
The stack holds return addresses and values saved by `PUSH`.

In 8085 you may explicitly initialize `SP` in a stand-alone exercise.
For this DOS `.EXE` layout, the executable header and loader establish the
initial stack; the game does not begin by loading `SP` itself.

---

## 4. Constants do not allocate variables

```asm
MAZE_ROWS EQU 9
MAZE_COLS EQU 20
MAZE_TOP  EQU 3
```

`EQU` associates names with assembly-time values.
There are no memory bytes named `MAZE_ROWS` that the program updates.

The logical map has nine rows and twenty columns.
Both coordinates start at zero:

```text
row:    0 through 8
column: 0 through 19
```

`MAZE_TOP = 3` is a screen margin.
Maze row zero appears on screen row three.
The map coordinates themselves do not start at three.

---

## 5. The help string and the map use different representations

```asm
HELP_TEXT DB 'MAZE - Use arrow keys to move. Esc exits.',13,10
          DB '# = wall   @ = player',13,10,'$'
```

`DB` emits bytes.
`13,10` are carriage return and line feed.
The final `$` terminates the string for DOS service `INT 21H/AH=09H`.

The map begins:

```asm
MAZE DB '####################'
     DB '#     #            #'
```

Its rows have no `$` and no zero terminator.
The renderer knows their length from `MAZE_COLS`.

The declarations place the rows consecutively in memory:

```text
MAZE+0  through MAZE+19  → row 0
MAZE+20 through MAZE+39  → row 1
MAZE+40 through MAZE+59  → row 2
...
```

Total map size is `9 × 20 = 180` bytes.

---

## 6. The player's position is separate data

```asm
PLAYER_ROW DB 1
PLAYER_COL DB 1
```

The initial position is `(1,1)`.
That is the second row and second column because indexing starts at zero.
It is the floor just inside the top-left wall.

The position needs only two bytes.
There is no array of player objects in this version.

The screen displays `@`, but `@` is not stored into `MAZE`.
That makes moving and erasing the old player simple: redraw the original map,
then draw `@` at the new coordinates.

---

## 7. Why `DS` must be initialized

```asm
MOV AX, @DATA
MOV DS, AX
```

`@DATA` identifies the program's data group.
The first instruction loads its segment value into `AX`.
The second copies it into `DS`.

An 8086 data address is normally a segment and an offset:

```text
physical address = 16 × segment + offset
```

So `MAZE[SI]` means a byte at offset `MAZE + SI` in the current data segment.
It does not mean that `SI` contains the complete physical address.

The 8085 has a flat 16-bit address space and no `DS` register.
Its `HL` pointer is therefore only a conceptual comparison to `SI`.

---

## 8. Selecting text mode

```asm
MOV AX, 0003H
INT 10H
```

Here `AH=00H` selects the BIOS video-mode service.
`AL=03H` requests the standard 80-column, 25-row color text mode.
With this value the screen is also cleared.

`INT 10H` transfers control to a BIOS service.
The instruction `INT` is part of the processor instruction set.
The meaning of service `10H` and its register arguments comes from the
IBM-PC-compatible BIOS environment.

There is no direct 8085 equivalent of “call the PC BIOS video service.”
An 8085 monitor may offer its own routines, but their addresses and arguments
belong to that particular monitor.

---

## 9. Hiding the blinking cursor

```asm
MOV AH, 01H
MOV CX, 2000H
INT 10H
```

BIOS video service `01H` changes the cursor shape.
The selected start-line control value hides the cursor in the intended
PC-compatible text environment.

The game still moves the BIOS cursor internally to choose where to print.
Hiding its visible shape does not disable cursor-position services.

After printing the help text through DOS, `CALL DRAW_MAZE` creates the initial
map and overlays the player.

---

## 10. The main loop waits for a key

```asm
READ_KEY:
    MOV AH, 00H
    INT 16H
```

BIOS keyboard service `00H` waits for a key event without echoing a character.
Its result uses both halves of `AX`:

```text
AL → character value, when the key has one
AH → keyboard scan code
```

An arrow key is not simply an ASCII letter.
That is why the program checks both the character result and the scan code.

This is an event-based game loop: no key event means this read remains waiting.
There is no timer-controlled movement or independent held-key table here.

---

## 11. Escape is checked first

```asm
CMP AL, 1BH
JE EXIT_PROGRAM
```

`1BH` is the Escape character value.
`CMP` subtracts for the purpose of setting flags but does not store the result.
`JE` jumps when the comparison reports equality, meaning `ZF=1`.

This is close to the 8085 sequence:

```asm
CPI 1BH
JZ EXIT
```

The names differ, but the compare-then-conditional-jump pattern transfers
directly from your 8085 knowledge.

---

## 12. Why ordinary characters are filtered out

```asm
CMP AL, 00H
JE CHECK_ARROW
CMP AL, 0E0H
JNE READ_KEY
```

Only results carrying one of these extended-key indicators proceed to the
arrow scan-code tests.
Other characters return to the keyboard read.

The source accepts both `00H` and `E0H` in `AL`.
The exact result returned for extended keys depends on the BIOS keyboard
service/environment; the source contains both checks for that reason.

Do not confuse this returned `AL` value with the raw hardware prefix processing
used by the later maze programs' keyboard interrupt handlers.
This version calls BIOS rather than reading keyboard port `60H` itself.

---

## 13. Copy the current position before changing anything

```asm
MOV DH, PLAYER_ROW
MOV DL, PLAYER_COL
```

`DH` holds a proposed row and `DL` holds a proposed column.
Together they occupy the two halves of `DX`:

```text
DX
├── DH: candidate row
└── DL: candidate column
```

The word “candidate” matters.
The memory variables still contain the old, legal position.
If a later test fails, the program simply returns to `READ_KEY`.
There is no need to undo a premature change to the stored position.

---

## 14. Decode the four arrow scan codes

```asm
CMP AH, 48H
JE MOVE_UP
CMP AH, 50H
JE MOVE_DOWN
CMP AH, 4BH
JE MOVE_LEFT
CMP AH, 4DH
JE MOVE_RIGHT
JMP READ_KEY
```

The table is:

| Key | Scan code | Candidate change |
| --- | --- | --- |
| Up | `48H` | row minus one |
| Down | `50H` | row plus one |
| Left | `4BH` | column minus one |
| Right | `4DH` | column plus one |

An unrecognized scan code causes no movement.

These are PC keyboard scan-code values, not ASCII codes and not CPU opcodes.

---

## 15. Each direction changes exactly one byte

```asm
MOVE_UP:
    DEC DH
    JMP CHECK_MOVE
MOVE_DOWN:
    INC DH
    JMP CHECK_MOVE
MOVE_LEFT:
    DEC DL
    JMP CHECK_MOVE
MOVE_RIGHT:
    INC DL
```

Up and down change only the row.
Left and right change only the column.
Right falls directly into `CHECK_MOVE`, while the other branches jump there.

There is no diagonal move.
There is no call to a direction-specific procedure; these are labels within
the main procedure.

In 8085 terms, these are like `DCR`/`INR` operations on two coordinate bytes.
The exact flags differ between architectures, so compare the algorithm rather
than assuming all flags match instruction-for-instruction.

---

## 16. Unsigned bounds checks also reject underflow

```asm
CMP DH, MAZE_ROWS
JAE READ_KEY
CMP DL, MAZE_COLS
JAE READ_KEY
```

`JAE` means unsigned “above or equal.”
After `CMP`, it branches when the first unsigned operand is at least the second.

Valid rows are below nine; valid columns are below twenty.
Therefore a row of nine or a column of twenty is rejected.

What if the candidate row was zero and `DEC DH` ran?

```text
00H - 1 → FFH = 255
255 >= 9 → reject
```

The byte wraps, but the unsigned comparison catches it.
There is no separate negative-number test.

---

## 17. Convert two coordinates into one memory index

```asm
MOV AL, DH
MOV BL, MAZE_COLS
MUL BL
XOR BX, BX
MOV BL, DL
ADD AX, BX
MOV SI, AX
```

The formula is:

```text
index = row × 20 + column
```

`MUL BL` performs unsigned byte multiplication:

```text
AL × BL → AX
```

The result is a word, which is useful because a general row product can exceed
the range of a byte.
The candidate in `DH:DL` is preserved by this byte multiplication.

Afterward, `BX` is cleared and the candidate column is put into `BL`.
Clearing `BH` makes this a correct zero-extended column value.

---

## 18. A concrete indexing example

Suppose the candidate position is `(2,1)`.

```text
DH = 2
DL = 1

AL = 2
BL = 20
MUL BL → AX = 40

BX = 1
ADD AX,BX → AX = 41
SI = 41
```

`MAZE[41]` is row two, column one.
It is the forty-second byte of the map when counted from one.

In an 8085 program you could obtain the same index through repeated addition,
then add it to the map's base address in `HL`.
8086 supplies a hardware `MUL`, but the row-major storage idea is identical.

---

## 19. Why `BYTE PTR` appears in the wall comparison

```asm
CMP BYTE PTR MAZE[SI], '#'
JE READ_KEY
```

`BYTE PTR` explicitly describes an eight-bit memory operand.
The program compares one map character with ASCII `'#'`.

If they match, it rejects the proposed move.
Any in-bounds cell other than `'#'` is considered walkable by this code.
The actual map uses spaces for those cells.

This check reads the map data, not the character currently visible on screen.

---

## 20. Commit only a legal move

```asm
MOV PLAYER_ROW, DH
MOV PLAYER_COL, DL
CALL DRAW_MAZE
JMP READ_KEY
```

Only after bounds and wall checks does the program update its stored position.
The renderer then displays the resulting state.

That is the central pattern of the game:

```text
read → propose → validate → commit → display
```

The `CALL` saves a return address on the stack.
The intended `RET` in the single-copy drawing routine resumes immediately after
that call.
As noted earlier, the current file's duplicated block interrupts that routine.

---

## 21. Worked move sequence from the starting cell

Start at `(1,1)`.

| Input | Candidate | Cell | Stored result |
| --- | --- | --- | --- |
| Right | `(1,2)` | space | `(1,2)` |
| Up | `(0,2)` | `#` | remains `(1,2)` |
| Left | `(1,1)` | space | `(1,1)` |
| Down | `(2,1)` | space | `(2,1)` |
| Right | `(2,2)` | `#` | remains `(2,1)` |

Notice that blocked movement does not trigger a redraw.
The program already displays the correct state.

There is no step counter or penalty for touching a wall in this version.

---

## 22. `DRAW_MAZE` saves its working registers

```asm
PUSH AX
PUSH BX
PUSH CX
PUSH DX
PUSH SI
PUSH BP
```

The intended routine restores them in the reverse order before returning.
This makes drawing a service that does not destroy the caller's register values.

That is the same stack discipline as saving 8085 register pairs around a
subroutine, although 8086 can push individual 16-bit registers such as `SI`.

The important drawing roles are:

| Register | Role |
| --- | --- |
| `SI` | next map-byte index |
| `DH` | current screen row |
| `DL` | screen column when positioning the cursor |
| `BP` | number of map rows left |
| `CX` | number of cells left in the current row |

---

## 23. Set up the outer row loop

```asm
XOR SI, SI
MOV DH, MAZE_TOP
MOV BP, MAZE_ROWS
```

The first map byte has index zero.
The first map row is drawn at screen row three.
There are nine rows to draw.

At each `DRAW_ROW`, the program sets column zero:

```asm
XOR DL, DL
MOV AH, 02H
XOR BH, BH
INT 10H
MOV CX, MAZE_COLS
```

BIOS service `02H` positions the cursor at `DH,DL` on video page `BH`.
The game uses page zero.

---

## 24. Print the twenty map bytes in a row

```asm
DRAW_CELL:
    MOV AL, MAZE[SI]
    MOV AH, 0EH
    MOV BX, 0007H
    INT 10H
    INC SI
    LOOP DRAW_CELL
```

BIOS teletype service `0EH` prints the character in `AL` and advances the cursor.
`BH=0` selects page zero in the intended environment.
In text mode, do not interpret `BL=07H` as a general per-character color setting
for this service; the later `09H` overlay explicitly supplies an attribute.

`LOOP` decrements `CX` and repeats while it is nonzero.
The source loaded `CX=20`, so exactly twenty map bytes are read.

Unlike an 8085 `DCR counter` plus `JNZ`, `LOOP` itself does not update flags.

---

## 25. Move down to the next screen row

```asm
INC DH
DEC BP
JNZ DRAW_ROW
```

The outer loop uses `BP`, leaving `CX` free for the inner cell loop.
`DEC BP` sets the zero flag, and `JNZ` repeats while rows remain.

`SI` is not reset at the start of each row.
Because rows are consecutive in memory, it already points to the next row.

After nine rows, `SI` has advanced through all 180 map bytes.

---

## 26. Overlay the player after drawing the map

```asm
MOV DH, PLAYER_ROW
ADD DH, MAZE_TOP
MOV DL, PLAYER_COL
MOV AH, 02H
XOR BH, BH
INT 10H
```

The player has logical maze coordinates.
Adding the top margin converts its row to a screen row.
The maze starts at screen column zero, so no column margin is added.

Then:

```asm
MOV AL, '@'
MOV AH, 09H
MOV BX, 000EH
MOV CX, 1
INT 10H
```

BIOS service `09H` writes a character and attribute without advancing the cursor.
`BH=0`, `BL=0EH`, and `CX=1` mean page zero, yellow-on-black attribute,
and one copy.

---

## 27. Why full redraw removes the previous marker

Suppose the player moves from `(1,1)` to `(1,2)`.

```text
before:
map floor at both cells; screen has @ at (1,1)

draw map:
both cells become floor on screen again

overlay player:
screen gets @ at (1,2)
```

No explicit “erase old player” routine is needed.
The source chooses a simple full redraw suitable for this small 180-cell map.

Later versions use different rendering choices for larger maps.

---

## 28. Clean exit restores the screen mode

```asm
EXIT_PROGRAM:
    MOV AX, 0003H
    INT 10H
    MOV AX, 4C00H
    INT 21H
```

The video-mode reset clears the game screen and restores normal text-mode
cursor behavior in the intended environment.
DOS service `4CH` terminates the process, returning exit code `AL=0`.

`INT 21H` here is not a hardware interrupt generated by the keyboard.
It is a software interrupt instruction used to request a DOS service.

---

## 29. High-level pseudocode of the intended game

```c
initialize_data_segment();
select_text_mode();
hide_cursor();
print_help();
draw_map_and_player();

for (;;) {
    Key k = bios_wait_for_key();
    if (k.character == ESC)
        break;
    if (!has_accepted_extended_indicator(k))
        continue;

    unsigned_byte row = player_row;
    unsigned_byte col = player_col;
    if (!apply_arrow_scan_code(k.scan, &row, &col))
        continue;
    if (row >= 9 || col >= 20)
        continue;
    if (maze[row * 20 + col] == '#')
        continue;

    player_row = row;
    player_col = col;
    draw_map_and_player();
}

restore_text_mode();
dos_exit(0);
```

This expresses the intended single-copy logic, not the malformed source layout.

---

## 30. What this version does and does not implement

It has one player, a fixed map, arrow-key events, wall blocking, and Escape exit.
It does not define an exit cell, race clock, score, win condition, random maze,
player collisions, or network controls.

Movement while holding a key depends on keyboard events/repetition supplied by
the BIOS environment.
It is not the simultaneous held-key sampling implemented in `MAZE2`.

The most significant current-source limitation is the duplicated module inside
`DRAW_MAZE`.
The build comment at the top describes an intended build procedure, not evidence
that this malformed revision was assembled.

---

## 31. 8085 ideas that carry across

| Familiar 8085 idea | How this program uses the idea |
| --- | --- |
| `HL` as a pointer | `SI` indexes bytes relative to the `MAZE` base in `DS` |
| `CMP`/`CPI` followed by a jump | `CMP` followed by `JE`, `JNE`, or unsigned `JAE` |
| `CALL` and `RET` | drawing is a callable routine |
| `PUSH` and `POP` | preserve registers across drawing |
| counters with conditional loops | `BP` counts rows and `CX` counts columns |
| memory-mapped application state | map bytes and two position bytes describe the game |

New platform-specific ideas are segment registers, PC BIOS services, scan codes,
and text-mode cursor/attribute operations.
They need to be learned separately from the shared assembly concepts.

---

## 32. Exam-ready explanation

The intended program stores a nine-by-twenty map as consecutive character bytes.
It keeps the player's row and column in separate byte variables.
For an accepted arrow key, it changes a temporary coordinate pair, checks
unsigned bounds, computes `row*20+column`, and rejects `'#'` cells.
A legal move updates the stored coordinates and redraws the map with a yellow
`@` overlaid at the corresponding screen position.
BIOS services handle the keyboard and screen; DOS terminates the program.

When discussing the supplied file itself, add that its repeated source block
inside `DRAW_MAZE` must be resolved before treating it as a clean buildable module.
