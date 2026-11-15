; Study notes: MAZE4 shared state and assembly-module wiring.
; M4CORE.INC implements generation, equal-distance starts, collisions and scores.
; M4SER.INC implements COM1 framing, session ownership, input leases and clocks.
; M4UI.INC provides MAIN, keyboard host controls and direct text-video rendering.
; The DOS program is authoritative for game state. HTTPS authentication is done
; by the host bridge; a serial XOR checksum detects corruption, not identity.
;
; MAZE4 - 8086 authoritative maze race with authenticated internet phone inputs.
; Build: MASM MAZE4.ASM;  LINK MAZE4.OBJ;
; MASM owns all game rules. The host bridge supplies HTTPS/authentication/transport.
; Restrict assembly to 8086 instructions; this directive emits no game action.
.8086
; SMALL selects one code segment and one data group. AX/BX/CX/DX are
; 16-bit registers; AH/AL etc. name their high/low bytes. H marks hexadecimal.
.MODEL SMALL
; Reserve 1000H=4096 CPU-stack bytes for nested core/network/UI calls.
.STACK 1000H
; A cell is a linear index row*COLS+column within the 17x61 byte maze.
; Player indices are 0..7; directions 0..4 mean idle/up/down/left/right.
ROWS EQU 17
COLS EQU 61
CELLS EQU ROWS*COLS
MAX_PLAYERS EQU 8
MOVE_TICKS EQU 2
; Begin data declarations. DB/DW/DD allocate bytes/words/doublewords; DUP
; repeats an item. EQU constants allocate no storage. Offsets are relative to DS.
.DATA
; These seven bytes are also the maze-test metadata record.
; The first seven bytes are a packed metadata record: three words and one
; byte. STARTS adds sixteen bytes, making the 23-byte maze metadata snapshot.
EXIT_POS DW 0
COMMON_DISTANCE DW 0
FLOOR_COUNT DW 0
CAPACITY DB 0
STARTS DW 8 DUP(0)
; One character per cell: wall #, walkable space, or shared exit E.
; Generation fills this array; it has fixed dimensions and no string terminator.
MAZE DB CELLS DUP('#')
RNG_SEED DW 1
COLLISION_MODE DB 0             ; MAZE3 default: block/+3s; 1 = rotating priority
PRIORITY DB 0
ELAPSED_TENTHS DD 0
; Word arrays use 2*player offsets; candidate positions are proposals until
; collision resolution finishes. Byte arrays use the plain player index.
POSITIONS DW 8 DUP(0)
CANDIDATES DW 8 DUP(0)
DIRECTIONS DB 8 DUP(0)         ; idle/up/down/left/right = 0/1/2/3/4
PLAYER_STATE DB 8 DUP(0)       ; empty/racing/finished/DNF = 0/1/2/3
; Four-byte counters/times use 4*player offsets and low/high word ADD/ADC.
; Finish time excludes penalties; GET_SCORE adds them. WIN_MASK stores ties.
STEPS DD 8 DUP(0)
PENALTIES DD 8 DUP(0)
FINISH_TIMES DD 8 DUP(0)
WARNINGS DB 8 DUP(0)           ; normal/yellow/red = 0/1/2
WIN_MASK DB 0
BEST_SCORE DD 0FFFFFFFFH
; Pair tables use index 8*i+j. TOUCH is this frame's contact; LATCH retains
; previous contact so sustained blocking charges only one penalty episode.
PAIR_LATCH DB 64 DUP(0)
PAIR_TOUCH DB 64 DUP(0)
BLOCKED DB 8 DUP(0)
; BFS distances are words, with FFFFH meaning unvisited. QUEUE holds word
; cell indices, reused as the DFS carving stack when BFS is not running.
DISTANCES DW CELLS DUP(0FFFFH)
QUEUE DW CELLS DUP(0)
BFS_HEAD DW 0
BFS_TAIL DW 0
BFS_LIMIT DW 0FFFFH
; Count cells at each exit distance to choose an equal-distance start group.
; DFS fields hold carving state; DELTAS list up/down/left/right cell offsets.
HISTOGRAM DW CELLS DUP(0)
DFS_TOP DW 0
DFS_CURRENT DW 0
DFS_DIRECTION DW 0
DFS_TRIES DW 0
DELTAS DW -COLS,COLS,-1,1
; Keep the strongest generated candidate map and its 23-byte metadata.
; GEN_TRIES bounds retries; reservoir sampling selects at most eight starts.
BEST_MAZE DB CELLS DUP(0)
BEST_META DB 23 DUP(0)
BEST_CAP DB 0
GEN_TRIES DW 0
RESERVOIR_COUNT DW 0
PAIR_I DW 0
PAIR_J DW 0
RESOLVE_PASSES DW 0
; Begin executable code. CALL saves a return address on SS:SP; RET resumes
; after that call. PROC/ENDP are assembler declarations, not run-time actions.
.CODE
; INCLUDE inserts assembly source here; these are not separately linked
; modules. Core procedures access the shared data declarations above.
INCLUDE M4CORE.INC
; Normal builds include serial/UI code and MAIN. Tests can define M4_TEST
; to supply their own entry point and exercise the same core without host I/O.
IFNDEF M4_TEST
INCLUDE M4SER.INC
INCLUDE M4UI.INC
ENDIF
; Close the source module and select MAIN as its executable entry point.
END MAIN
