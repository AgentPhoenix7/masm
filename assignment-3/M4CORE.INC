; Study notes: deterministic game-rule helpers shared by runtime and tests.
; Linear cell indices use row*COLS+column. Word arrays need byte offset 2*index;
; dword counters need 4*player. The caller must establish DS/ES and CLD before
; REP string operations. These routines do not perform BIOS/DOS/transport I/O.
; Generation: randomized DFS -> optional loops -> random floor exit -> BFS
; distance histogram -> equal-distance starts -> retain the best capacity.
; Frame: build all proposals -> resolve repeated pair passes -> commit -> warnings.
;
; Core game rules. All positions are word-sized linear offsets into MAZE.
; No DOS, video, keyboard, or networking calls in this module.

RANDOM PROC NEAR
    ; Return the next 16-bit linear-congruential value in AX:
    ; seed=(25173*seed+13849) mod 65536. MUL writes DX:AX; retaining AX makes
    ; the wrap intentional. Preserve BX/DX for callers; this is not a secure RNG.
    PUSH BX
    PUSH DX
    MOV AX,RNG_SEED
    MOV BX,25173
    MUL BX
    ADD AX,13849
    MOV RNG_SEED,AX
    POP DX
    POP BX
    RET
RANDOM ENDP

RESET_GAME PROC NEAR
    ; Save registers, temporarily set ES=DS, and zero the contiguous region
    ; POSITIONS..DISTANCES-1 with REP STOSB. It includes player/collision state
    ; but not the maze or generation scratch arrays. Reset priority/clock/winners
    ; separately, including BEST_SCORE=FFFFFFFFH as the initial worst score.
    PUSH AX
    PUSH CX
    PUSH DI
    PUSH ES
    PUSH DS
    POP ES
    XOR AX,AX
    LEA DI,POSITIONS
    MOV CX,OFFSET DISTANCES-OFFSET POSITIONS
    REP STOSB
    MOV PRIORITY,0
    MOV WORD PTR ELAPSED_TENTHS,0
    MOV WORD PTR ELAPSED_TENTHS+2,0
    MOV WIN_MASK,0
    MOV WORD PTR BEST_SCORE,0FFFFH
    MOV WORD PTR BEST_SCORE+2,0FFFFH
    POP ES
    POP DI
    POP CX
    POP AX
    RET
RESET_GAME ENDP

; AX = root; BFS_LIMIT = maximum explored path distance. Walls are impassable.
BFS PROC NEAR
    ; AX is a valid walkable root cell. Save registers, set ES=DS, fill all
    ; word distances with FFFFH (unvisited), then enqueue root at distance zero.
    ; HEAD/TAIL are byte offsets in QUEUE, advancing by two per cell index.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    PUSH ES
    PUSH AX
    PUSH DS
    POP ES
    LEA DI,DISTANCES
    MOV AX,0FFFFH
    MOV CX,CELLS
    REP STOSW
    POP AX
    MOV BX,AX
    SHL BX,1
    MOV DISTANCES[BX],0
    MOV QUEUE,AX
    MOV BFS_HEAD,0
    MOV BFS_TAIL,2
BFS_NEXT:
    ; An empty queue (head>=tail) finishes. Otherwise dequeue a cell, read its
    ; known distance, and skip expansion if it reached BFS_LIMIT. Neighbors
    ; receive distance+1, giving shortest path lengths through walkable cells.
    MOV BX,BFS_HEAD
    CMP BX,BFS_TAIL
    JAE BFS_DONE
    MOV SI,QUEUE[BX]
    ADD BFS_HEAD,2
    MOV BX,SI
    SHL BX,1
    MOV BP,DISTANCES[BX]
    CMP BP,BFS_LIMIT
    JAE BFS_NEXT
    INC BP
    XOR DI,DI
BFS_NEIGHBOR:
    ; Try the four signed cell deltas. An unsigned bound rejects negative wrap
    ; and indices past CELLS; wall borders prevent sideways row wrapping.
    ; Skip walls/already-visited cells, record distance before enqueueing, and
    ; therefore put each cell into the fixed-capacity queue at most once.
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
    MOV BX,BFS_TAIL
    MOV QUEUE[BX],AX
    ADD BFS_TAIL,2
BFS_SKIP:
    ; Advance the word-delta offset by two until all four directions were tested.
    ADD DI,2
    CMP DI,8
    JB BFS_NEIGHBOR
    JMP BFS_NEXT
BFS_DONE:
    ; Restore ES and working registers in reverse PUSH order; distances remain
    ; in shared memory for start selection or proximity warnings.
    POP ES
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
BFS ENDP

; Generate up to 64 candidates; keep the best capacity, stop at eight.
GENERATE_MAZE PROC NEAR
    ; Try up to 64 candidates, keeping one with strictly larger CAPACITY.
    ; ES=DS permits REP MOVSB snapshots. Stop early once eight players fit;
    ; otherwise restore the best map and associated exit/start metadata.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    PUSH ES
    PUSH DS
    POP ES
    MOV BEST_CAP,0
    MOV GEN_TRIES,64
GEN_CANDIDATE:
    ; Carve a fresh map, then measure start capacity. On improvement copy CELLS
    ; map bytes, seven metadata bytes and sixteen start bytes into backup storage.
    ; The second copy continues DI after the seven bytes, producing 23 in total.
    CALL CARVE_MAZE
    CALL SELECT_STARTS
    MOV AL,CAPACITY
    CMP AL,BEST_CAP
    JBE GEN_NEXT
    MOV BEST_CAP,AL
    LEA SI,MAZE
    LEA DI,BEST_MAZE
    MOV CX,CELLS
    REP MOVSB
    LEA SI,EXIT_POS
    LEA DI,BEST_META
    MOV CX,7
    REP MOVSB
    LEA SI,STARTS
    MOV CX,16
    REP MOVSB
GEN_NEXT:
    ; Eight is the maximum capacity; otherwise decrement the bounded retry count.
    CMP BEST_CAP,8
    JE GEN_RESTORE
    DEC GEN_TRIES
    JNZ GEN_CANDIDATE
GEN_RESTORE:
    ; Restore the saved map and 23-byte metadata in two pieces, then set CAPACITY
    ; to BEST_CAP. Callers display an error if the resulting capacity is below two.
    LEA SI,BEST_MAZE
    LEA DI,MAZE
    MOV CX,CELLS
    REP MOVSB
    LEA SI,BEST_META
    LEA DI,EXIT_POS
    MOV CX,7
    REP MOVSB
    LEA DI,STARTS
    MOV CX,16
    REP MOVSB
    MOV AL,BEST_CAP
    MOV CAPACITY,AL
    POP ES
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
GENERATE_MAZE ENDP

CARVE_MAZE PROC NEAR
    ; Fill the map with walls, open cell (1,1), and push it onto a DFS stack
    ; using QUEUE. ES=DS and forward direction are supplied by the generator.
    LEA DI,MAZE
    MOV CX,CELLS
    MOV AL,'#'
    REP STOSB
    MOV MAZE[COLS+1],' '
    MOV QUEUE,COLS+1
    MOV DFS_TOP,2
DFS_CELL:
    ; Peek at the current DFS cell. Choose a random starting direction from
    ; higher RNG bits and try all four directions cyclically before backtracking.
    CMP DFS_TOP,0
    JE DFS_LOOPS
    MOV BX,DFS_TOP
    MOV SI,QUEUE[BX-2]
    MOV DFS_CURRENT,SI
    CALL RANDOM
    ; High bits avoid the LCG's alternating low-bit direction pattern.
    MOV AL,AH
    AND AX,3
    SHL AX,1
    MOV DFS_DIRECTION,AX
    MOV DFS_TRIES,4
DFS_TRY:
    ; Move TWO cells so intermediate walls separate the odd-coordinate rooms.
    ; DIV COLS splits the candidate into row/column; keep it strictly inside the
    ; outer wall. If unvisited, open the candidate and its midpoint passage, push
    ; the new cell, and continue deeper without removing the parent stack entry.
    MOV BX,DFS_DIRECTION
    MOV AX,DELTAS[BX]
    SHL AX,1
    ADD AX,DFS_CURRENT
    CMP AX,CELLS
    JAE DFS_REJECT
    MOV DI,AX
    XOR DX,DX
    MOV BX,COLS
    DIV BX
    CMP AX,1
    JB DFS_REJECT
    CMP AX,ROWS-1
    JAE DFS_REJECT
    CMP DX,1
    JB DFS_REJECT
    CMP DX,COLS-1
    JAE DFS_REJECT
    CMP MAZE[DI],'#'
    JNE DFS_REJECT
    MOV MAZE[DI],' '
    MOV BX,DFS_CURRENT
    ADD BX,DI
    SHR BX,1
    MOV MAZE[BX],' '
    MOV BX,DFS_TOP
    MOV QUEUE[BX],DI
    ADD DFS_TOP,2
    JMP DFS_CELL
DFS_REJECT:
    ; Advance the word-direction offset by two, wrapping with AND 7. After
    ; four failed choices, pop the dead-end cell and resume from its parent.
    ADD DFS_DIRECTION,2
    AND DFS_DIRECTION,7
    DEC DFS_TRIES
    JNZ DFS_TRY
    SUB DFS_TOP,2
    JMP DFS_CELL
DFS_LOOPS:
    ; DFS has made a connected maze. Scan interior separating walls and
    ; occasionally open one between opposite floor neighbors to create loops.
    ; Open selected separating walls, retaining connectivity and outer walls.
    MOV SI,COLS+1
LOOP_WALL:
    ; Skip existing floor and boundary columns. A random two-bit test admits
    ; about one quarter of remaining walls for horizontal/vertical passage checks.
    CMP MAZE[SI],'#'
    JNE LOOP_NEXT
    MOV AX,SI
    XOR DX,DX
    MOV BX,COLS
    DIV BX
    CMP DX,0
    JE LOOP_NEXT
    CMP DX,COLS-1
    JE LOOP_NEXT
    CALL RANDOM
    TEST AH,3
    JNZ LOOP_NEXT
    CMP MAZE[SI-1],' '
    JNE LOOP_VERTICAL
    CMP MAZE[SI+1],' '
    JE LOOP_OPEN
LOOP_VERTICAL:
    ; If horizontal floor neighbors do not qualify, require floor above and below.
    CMP MAZE[SI-COLS],' '
    JNE LOOP_NEXT
    CMP MAZE[SI+COLS],' '
    JNE LOOP_NEXT
LOOP_OPEN:
    ; Turn the qualifying separating wall into floor without disconnecting the map.
    MOV MAZE[SI],' '
LOOP_NEXT:
    ; Advance within the interior row range, preserving the outer wall ring.
    INC SI
    CMP SI,(ROWS-1)*COLS
    JB LOOP_WALL
CHOOSE_EXIT:
    ; Reduce a random word modulo CELLS and retry until a floor cell is found.
    ; Store that cell index as EXIT_POS and change its character to shared goal E.
    CALL RANDOM
    XOR DX,DX
    MOV BX,CELLS
    DIV BX
    MOV BX,DX
    CMP MAZE[BX],' '
    JNE CHOOSE_EXIT
    MOV EXIT_POS,BX
    MOV MAZE[BX],'E'
    RET
CARVE_MAZE ENDP

SELECT_STARTS PROC NEAR
    ; Run an unlimited BFS from E, clear the distance histogram, and count
    ; non-exit floor. Starts must share a shortest-path distance of at least 12,
    ; so the race begins with equal route lengths rather than equal straight lines.
    MOV BFS_LIMIT,0FFFFH
    MOV AX,EXIT_POS
    CALL BFS
    LEA DI,HISTOGRAM
    XOR AX,AX
    MOV CX,CELLS
    REP STOSW
    MOV FLOOR_COUNT,0
    XOR SI,SI
HIST_CELL:
    ; For each non-wall/non-exit cell, count floor and increment its distance
    ; bucket if the BFS distance is >=12 and below CELLS (not unreachable FFFFH).
    CMP MAZE[SI],'#'
    JE HIST_NEXT
    CMP SI,EXIT_POS
    JE HIST_NEXT
    INC FLOOR_COUNT
    MOV BX,SI
    SHL BX,1
    MOV AX,DISTANCES[BX]
    CMP AX,12
    JB HIST_NEXT
    CMP AX,CELLS
    JAE HIST_NEXT
    MOV BX,AX
    SHL BX,1
    INC HISTOGRAM[BX]
HIST_NEXT:
    ; Advance over all map cells before selecting the largest eligible distance group.
    INC SI
    CMP SI,CELLS
    JB HIST_CELL
    XOR BP,BP
    MOV COMMON_DISTANCE,12
    MOV SI,24
HIST_MAX:
    ; SI is twice a path distance; BP holds the largest bucket size so far.
    ; Prefer a larger group; random choice breaks equal-count ties among distances.
    MOV AX,HISTOGRAM[SI]
    CMP AX,BP
    JB HIST_MAX_NEXT
    JA HIST_BETTER
    CALL RANDOM
    TEST AH,1
    JZ HIST_MAX_NEXT
HIST_BETTER:
    ; Remember the bucket count and convert its word-array byte offset back
    ; to a distance by shifting right once.
    MOV BP,HISTOGRAM[SI]
    MOV AX,SI
    SHR AX,1
    MOV COMMON_DISTANCE,AX
HIST_MAX_NEXT:
    ; Scan remaining histogram words. Afterwards calculate floor_count/20 as
    ; a density limit, then clamp it to eight and the selected group size.
    ADD SI,2
    CMP SI,CELLS*2
    JB HIST_MAX
    MOV AX,FLOOR_COUNT
    XOR DX,DX
    MOV BX,20
    DIV BX
    CMP AX,8
    JBE CAP_DENSITY
    MOV AX,8
CAP_DENSITY:
    ; Capacity cannot exceed the number of eligible cells in the chosen distance group.
    CMP AX,BP
    JBE CAP_GROUP
    MOV AX,BP
CAP_GROUP:
    ; Save the final capacity and begin reservoir sampling of that whole group.
    MOV CAPACITY,AL
    MOV RESERVOIR_COUNT,0
    XOR SI,SI
RESERVOIR_CELL:
    ; Only cells at COMMON_DISTANCE are eligible. Keep the first eight, then
    ; for eligible cell number n choose a random index in 0..n-1; replace a
    ; reservoir entry only when that index is below eight.
    MOV BX,SI
    SHL BX,1
    MOV AX,DISTANCES[BX]
    CMP AX,COMMON_DISTANCE
    JNE RESERVOIR_NEXT
    INC RESERVOIR_COUNT
    MOV BX,RESERVOIR_COUNT
    CMP BX,8
    JBE RESERVOIR_FIRST
    CALL RANDOM
    XOR DX,DX
    DIV BX
    CMP DX,8
    JAE RESERVOIR_NEXT
    MOV BX,DX
    JMP RESERVOIR_SAVE
RESERVOIR_FIRST:
    ; Convert the first-eight one-based count into a zero-based start slot.
    DEC BX
RESERVOIR_SAVE:
    ; Multiply the start slot by two and store this word-sized cell index.
    SHL BX,1
    MOV STARTS[BX],SI
RESERVOIR_NEXT:
    ; After scanning all cells, shuffle the usable start slots so player-slot
    ; order is not fixed to the order in which floor cells were encountered.
    INC SI
    CMP SI,CELLS
    JB RESERVOIR_CELL
    ; Fisher-Yates shuffles the retained starts, including groups smaller than 8.
    XOR CX,CX
    MOV CL,CAPACITY
    CMP CX,2
    JB STARTS_DONE
SHUFFLE_START:
    ; Fisher-Yates: choose an index below the remaining count, exchange it
    ; with the last remaining slot, then shrink the count using LOOP.
    CALL RANDOM
    XOR DX,DX
    DIV CX
    MOV BX,DX
    SHL BX,1
    MOV DI,CX
    DEC DI
    SHL DI,1
    MOV AX,STARTS[DI]
    XCHG AX,STARTS[BX]
    MOV STARTS[DI],AX
    LOOP SHUFFLE_START
STARTS_DONE:
    ; Return with map metadata, capacity and start cells ready for admissions.
    RET
SELECT_STARTS ENDP

BUILD_INTENTS PROC NEAR
    ; Initialize the proposal pass at player slot zero; no position is committed here.
    XOR SI,SI
INTENT_PLAYER:
    ; Copy actual position to candidate and clear BLOCKED. Only racing slots
    ; (state 1) may move. Directions 1..4 index the four word deltas; idle/invalid
    ; values leave the candidate unchanged. Reject out-of-range cells and walls.
    MOV BX,SI
    SHL BX,1
    MOV AX,POSITIONS[BX]
    MOV CANDIDATES[BX],AX
    MOV BLOCKED[SI],0
    CMP PLAYER_STATE[SI],1
    JNE INTENT_NEXT
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
    CMP AX,CELLS
    JAE INTENT_NEXT
    MOV DI,AX
    CMP MAZE[DI],'#'
    JE INTENT_NEXT
    MOV CANDIDATES[BX],AX
INTENT_NEXT:
    ; Advance over all eight slots, including empty, finished and DNF players.
    INC SI
    CMP SI,8
    JB INTENT_PLAYER
    RET
BUILD_INTENTS ENDP

; SI,DI are player indices. Cancel proposals after each complete pair pass.
RESOLVE_MOVES PROC NEAR
    ; Normalize rotating priority to a live racer, then resolve all candidate
    ; conflicts before any position changes. Repeated passes propagate blocks
    ; through chains of players whose canceled moves restore occupied cells.
    ; The first slot can be empty, or the cursor owner can have become DNF.
    ; Normalize before arbitration so its successor does not get two turns.
    XOR BX,BX
    MOV BL,PRIORITY
    CMP PLAYER_STATE[BX],1
    JE RESOLVE_INIT
    CALL ROTATE_PRIORITY
RESOLVE_INIT:
    ; Temporarily set ES=DS and clear the 64-byte pair-touch matrix using
    ; 32 zero words. Eight passes bound propagation across eight player slots.
    PUSH ES
    PUSH DS
    POP ES
    LEA DI,PAIR_TOUCH
    XOR AX,AX
    MOV CX,32
    REP STOSW
    MOV RESOLVE_PASSES,8
RESOLVE_PASS:
    ; Enumerate every unordered pair i<j against this pass's complete proposals.
    MOV PAIR_I,0
PAIR_OUTER:
    ; Set the inner index to i+1, avoiding self-pairs and duplicate reversed pairs.
    MOV AX,PAIR_I
    INC AX
    MOV PAIR_J,AX
PAIR_INNER:
    ; Load SI/DI from persistent pair counters because CHECK_PAIR reuses scratch
    ; registers. After all pairs, cancel blocked proposals as a separate phase.
    MOV SI,PAIR_I
    MOV DI,PAIR_J
    CALL CHECK_PAIR
    INC PAIR_J
    CMP PAIR_J,8
    JB PAIR_INNER
    INC PAIR_I
    CMP PAIR_I,7
    JB PAIR_OUTER
    XOR SI,SI
CANCEL_PLAYER:
    ; Restore each blocked candidate to its actual cell. Block flags remain set
    ; for later passes, so a rejected proposal cannot re-enter this frame.
    CMP BLOCKED[SI],0
    JE CANCEL_NEXT
    MOV BX,SI
    SHL BX,1
    MOV AX,POSITIONS[BX]
    MOV CANDIDATES[BX],AX
CANCEL_NEXT:
    ; Finish all cancellations, then repeat the full pair scan or begin charging.
    INC SI
    CMP SI,8
    JB CANCEL_PLAYER
    DEC RESOLVE_PASSES
    JNZ RESOLVE_PASS
    XOR SI,SI
CHARGE_OUTER:
    ; Enumerate unordered pairs again to update contact latches and penalties.
    MOV DI,SI
    INC DI
CHARGE_INNER:
    ; Pair byte offset=8*i+j. In block/+3s mode, charge both players only
    ; when TOUCH=1 and the previous LATCH=0. ADD/ADC updates their 32-bit
    ; penalty totals by 30 tenths. Rotating-priority mode does not charge time.
    MOV BX,SI
    MOV CL,3
    SHL BX,CL
    ADD BX,DI
    MOV AL,PAIR_TOUCH[BX]
    CMP COLLISION_MODE,0
    JNE SAVE_LATCH
    CMP AL,0
    JE SAVE_LATCH
    CMP PAIR_LATCH[BX],0
    JNE SAVE_LATCH
    PUSH BX
    MOV BX,SI
    SHL BX,1
    SHL BX,1
    ADD WORD PTR PENALTIES[BX],30
    ADC WORD PTR PENALTIES[BX+2],0
    MOV BX,DI
    SHL BX,1
    SHL BX,1
    ADD WORD PTR PENALTIES[BX],30
    ADC WORD PTR PENALTIES[BX+2],0
    POP BX
SAVE_LATCH:
    ; Remember current contact even in nonpenalty mode; a later frame without
    ; contact clears the latch. Restore ES after every pair has been processed.
    MOV PAIR_LATCH[BX],AL
    INC DI
    CMP DI,8
    JB CHARGE_INNER
    INC SI
    CMP SI,7
    JB CHARGE_OUTER
    POP ES
    RET
RESOLVE_MOVES ENDP

CHECK_PAIR PROC NEAR
    ; Only racing players participate. BX=2*i and BP=2*j address word arrays;
    ; BP normally defaults to SS, so explicit DS: overrides are essential here.
    ; If neither player changes position, there is no movement conflict to resolve.
    CMP PLAYER_STATE[SI],1
    JNE PAIR_DONE
    CMP PLAYER_STATE[DI],1
    JNE PAIR_DONE
    MOV BX,SI
    SHL BX,1
    MOV BP,DI
    SHL BP,1
    MOV AX,CANDIDATES[BX]
    MOV DX,DS:CANDIDATES[BP]
    CMP AX,POSITIONS[BX]
    JNE PAIR_ACTIVE
    CMP DX,DS:POSITIONS[BP]
    JE PAIR_DONE
PAIR_ACTIVE:
    ; Same-destination arrivals conflict except at shared E. In rotating mode,
    ; only two genuinely moving contestants can arbitrate by cyclic rank
    ; (index-PRIORITY)&7; entering an occupied stationary cell still blocks both.
    CMP AX,DX
    JNE PAIR_SWAP
    CMP AX,EXIT_POS
    JE PAIR_DONE
    CMP COLLISION_MODE,1
    JNE PAIR_BOTH
    CMP AX,POSITIONS[BX]
    JE PAIR_BOTH
    CMP DX,DS:POSITIONS[BP]
    JE PAIR_BOTH
    MOV AX,SI
    SUB AL,PRIORITY
    AND AX,7
    MOV DX,DI
    SUB DL,PRIORITY
    AND DX,7
    CMP AX,DX
    JB PAIR_LOSE_J
    MOV BLOCKED[SI],1
    JMP PAIR_CONTACT
PAIR_LOSE_J:
    ; The smaller cyclic rank wins the contested destination; block player j here.
    MOV BLOCKED[DI],1
    JMP PAIR_CONTACT
PAIR_SWAP:
    ; Different destinations may still form a head-on exchange of old positions.
    ; Both reverse-position comparisons must match to classify that collision.
    CMP AX,DS:POSITIONS[BP]
    JNE PAIR_DONE
    CMP DX,POSITIONS[BX]
    JNE PAIR_DONE
PAIR_BOTH:
    ; Block both parties for default-mode contact, stationary occupancy or a swap.
    MOV BLOCKED[SI],1
    MOV BLOCKED[DI],1
PAIR_CONTACT:
    ; Set TOUCH[8*i+j]. Delayed charging avoids counting the same pair once
    ; per resolution pass instead of once per contact episode.
    MOV BX,SI
    MOV CL,3
    SHL BX,CL
    ADD BX,DI
    MOV PAIR_TOUCH[BX],1
PAIR_DONE:
    ; Return with shared flags updated, without committing either proposal.
    RET
CHECK_PAIR ENDP

COMMIT_MOVES PROC NEAR
    ; Apply surviving candidates only after collision resolution is complete.
    XOR SI,SI
COMMIT_PLAYER:
    ; For a racer whose cell actually changes, store it and increment the
    ; 32-bit step count. Reaching E changes state to finished (2) and freezes
    ; unpenalized finish time, excluding this player from future collisions.
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
    CMP AX,EXIT_POS
    JNE COMMIT_NEXT
    MOV PLAYER_STATE[SI],2
    MOV AX,WORD PTR ELAPSED_TENTHS
    MOV WORD PTR FINISH_TIMES[BX],AX
    MOV AX,WORD PTR ELAPSED_TENTHS+2
    MOV WORD PTR FINISH_TIMES[BX+2],AX
COMMIT_NEXT:
    ; Finish all slots, then rotate priority once for the next movement frame.
    INC SI
    CMP SI,8
    JB COMMIT_PLAYER
    CALL ROTATE_PRIORITY
    RET
COMMIT_MOVES ENDP

ROTATE_PRIORITY PROC NEAR
    ; Advance cyclically through active racers only; bound the scan to eight
    ; slots so it terminates even after the final racer finishes or disconnects.
    ; Rotate through racers, not all eight slots. Empty/finished/DNF slots
    ; otherwise bias a two-player contest 7:1. Bound the final-finisher scan.
    MOV CX,MAX_PLAYERS
PRIORITY_NEXT:
    ; AND 7 wraps a slot index modulo eight. Stop when state=1, otherwise
    ; LOOP consumes one of the eight allowed search attempts.
    INC PRIORITY
    AND PRIORITY,7
    XOR BX,BX
    MOV BL,PRIORITY
    CMP PLAYER_STATE[BX],1
    JE PRIORITY_DONE
    LOOP PRIORITY_NEXT
PRIORITY_DONE:
    ; Return with the next racing priority owner, or after the bounded empty scan.
    RET
ROTATE_PRIORITY ENDP

UPDATE_WARNINGS PROC NEAR
    ; Use BFS_LIMIT=4 to measure nearby opponents along walkable paths, not
    ; through walls. Yellow means distance <=4; red means <=2.
    MOV BFS_LIMIT,4
    XOR SI,SI
WARNING_PLAYER:
    ; Clear the warning and skip nonracers. A short BFS from this racer
    ; produces its local distance map while preserving the caller's player index.
    MOV WARNINGS[SI],0
    CMP PLAYER_STATE[SI],1
    JNE WARNING_NEXT
    MOV BX,SI
    SHL BX,1
    MOV AX,POSITIONS[BX]
    CALL BFS
    XOR DI,DI
WARNING_OTHER:
    ; Ignore self/nonracers/unreachable or distant cells. Raise warning to
    ; yellow for distance 3..4 or red for <=2; never lower an existing red
    ; warning just because another opponent is farther away.
    CMP DI,SI
    JE WARNING_OTHER_NEXT
    CMP PLAYER_STATE[DI],1
    JNE WARNING_OTHER_NEXT
    MOV BX,DI
    SHL BX,1
    MOV BX,POSITIONS[BX]
    SHL BX,1
    MOV AX,DISTANCES[BX]
    CMP AX,4
    JA WARNING_OTHER_NEXT
    CMP WARNINGS[SI],2
    JE WARNING_OTHER_NEXT
    MOV WARNINGS[SI],1
    CMP AX,2
    JA WARNING_OTHER_NEXT
    MOV WARNINGS[SI],2
WARNING_OTHER_NEXT:
    ; Scan the remaining possible opponents for this player's highest warning.
    INC DI
    CMP DI,8
    JB WARNING_OTHER
WARNING_NEXT:
    ; Repeat the bounded BFS/warning calculation for each of the eight slots.
    INC SI
    CMP SI,8
    JB WARNING_PLAYER
    RET
UPDATE_WARNINGS ENDP

; SI=player, DX:AX=finish/current elapsed plus penalty.
GET_SCORE PROC NEAR
    ; Return DX:AX as current elapsed+penalty, or frozen finish time+penalty
    ; for state 2. SI is a player index, scaled by four for the dword arrays.
    MOV BX,SI
    SHL BX,1
    SHL BX,1
    MOV AX,WORD PTR ELAPSED_TENTHS
    MOV DX,WORD PTR ELAPSED_TENTHS+2
    CMP PLAYER_STATE[SI],2
    JNE SCORE_PENALTY
    MOV AX,WORD PTR FINISH_TIMES[BX]
    MOV DX,WORD PTR FINISH_TIMES[BX+2]
SCORE_PENALTY:
    ; ADD the low penalty word and ADC its high word, preserving 32-bit carry.
    ADD AX,WORD PTR PENALTIES[BX]
    ADC DX,WORD PTR PENALTIES[BX+2]
    RET
GET_SCORE ENDP

FIND_WINNERS PROC NEAR
    ; Start with no winner and best score FFFFFFFFH. Only finished players
    ; can win; empty/racing/DNF slots are skipped rather than given a score.
    MOV WIN_MASK,0
    MOV WORD PTR BEST_SCORE,0FFFFH
    MOV WORD PTR BEST_SCORE+2,0FFFFH
    XOR SI,SI
WIN_PLAYER:
    ; Compare unsigned high score words first, then low words on a tie.
    ; Smaller replaces the best; complete equality adds another winner bit.
    CMP PLAYER_STATE[SI],2
    JNE WIN_NEXT
    CALL GET_SCORE
    CMP DX,WORD PTR BEST_SCORE+2
    JB WIN_NEW
    JA WIN_NEXT
    CMP AX,WORD PTR BEST_SCORE
    JB WIN_NEW
    JA WIN_NEXT
    JMP WIN_ADD
WIN_NEW:
    ; Store the new best score and discard previous higher-score winner bits.
    MOV WORD PTR BEST_SCORE,AX
    MOV WORD PTR BEST_SCORE+2,DX
    MOV WIN_MASK,0
WIN_ADD:
    ; OR bit 1<<player into WIN_MASK so all equal-score finishers are retained.
    MOV CX,SI
    MOV AL,1
    SHL AL,CL
    OR WIN_MASK,AL
WIN_NEXT:
    ; Advance through every slot; if nobody finished, WIN_MASK remains zero.
    INC SI
    CMP SI,8
    JB WIN_PLAYER
    RET
FIND_WINNERS ENDP
