; Study notes: three-player race with a shared exit and collision penalties.
; Space starts the race. Each frame builds all proposed moves before resolving
; collisions, commits the surviving moves, then updates the screen. Finishing
; removes a player from collisions. After all three finish, compare elapsed
; finish time plus penalties; equal lowest scores share a winner bitmask.
; Timing and scores are 32-bit quantities assembled from 16-bit word operations.
;
; 8086 / MASM / DOS - THREE-PLAYER MAZE RACE v3
; P1 WASD; P2 IJKL; P3 TFGH. Space starts. Esc exits.
; Colliding players each receive +3.0 seconds per contact episode.
; Winner = lowest finish time + penalties, after all three finish.
; Build: MASM MAZE5.ASM; then LINK MAZE5.OBJ;
; Restrict assembly to 8086 instructions; this directive emits no game action.
.8086
; SMALL selects one code segment and one data group. AX/BX/CX/DX are
; 16-bit registers; AH/AL etc. name their high/low bytes. H marks hexadecimal.
.MODEL SMALL
; Reserve 500H=1280 bytes for nested rendering/math calls and interrupt saves.
.STACK 500H
; The fixed map is 17 by 61 cells; top/left margins position it within 80x25.
; MOVE_TICKS=2 controls movement rate; penalties are measured in tenths.
MAZE_ROWS EQU 17
MAZE_COLS EQU 61
MAZE_TOP EQU 7
MAZE_LEFT EQU 9
MOVE_TICKS EQU 2
PENALTY_TENTHS EQU 30
EXIT_ROW EQU 9
EXIT_COL EQU 27

; Begin data declarations. DB/DW/DD allocate bytes/words/doublewords; DUP
; repeats an item. EQU constants allocate no storage. Offsets are relative to DS.
.DATA
TITLE_TEXT DB 'THREE-PLAYER MAZE v5 | WASD / IJKL / TFGH | Esc: quit',0
CLOCK_TEXT DB 'Race: ',0
RULE_TEXT DB 's  | Player collisions: +3.0s to BOTH; walls block.',0
P1_TEXT DB 'P1 WASD',0
P2_TEXT DB 'P2 IJKL',0
P3_TEXT DB 'P3 TFGH',0
PLAYER_TEXTS DW OFFSET P1_TEXT,OFFSET P2_TEXT,OFFSET P3_TEXT
STEP_TEXT DB 'Steps:',0
PEN_TEXT DB 'Penalty:',0
SCORE_TEXT DB 'Score:',0
ACTIVE_TEXT DB 'RACING',0
DONE_TEXT DB 'DONE',0
READY_TEXT DB 'SPACE starts | 1:WASD  2:IJKL  3:TFGH | Reach green E. Esc exits.',0
RACING_TEXT DB 'Reach green E. Score = finish time + penalties. Finishers leave the maze.',0
WIN_TEXT DB 'WINNER: ',0
TIE_TEXT DB 'TIE: ',0
FINAL_TEXT DB ' | Best score: ',0
FINAL_SUFFIX DB 's  (finish time + penalties)',0
LEGEND_TEXT DB '1: W/A/S/D    2: I/J/K/L    3: T/F/G/H    |    Green E = shared exit',0
PLAYER_CHARS DB '1','2','3'
PLAYER_COLORS DB 0EH,0BH,0DH
MAZE DB '#############################################################'
     DB '#           #                 #               #         #   #'
     DB '# ####### # ### # ####### # # # ####### # ### # ### ### # # #'
     DB '#   #     # #   # #     # #             #   # #   # # # #   #'
     DB '### # ### # # # # # ### # ####### ### # # # # # ### # # ### #'
     DB '#   # #   #   #   # #   #         # # #   # #   #   #       #'
     DB '# ### # # ####### # # # # ####### # # ### # # # # ### ##### #'
     DB '#       #     #             #       #   # # # # #     #     #'
     DB '# # ### ##### # # # ######### ### ### # # # # # # # # # #####'
     DB '#     #         #     #    E  #       # # #         # #   # #'
     DB '# ### # ### # ####### # ### ### ### # # # # ### ### ##### # #'
     DB '#         # #   #   #       #     # # #   #   # #       #   #'
     DB '### # ### # # # ### # ##### # ### # ### # ### # # ### # # # #'
     DB '#   #         #   # #       #   #     # #   # #     # #     #'
     DB '# ### ### ### ### # # ####### # # ### # ##### # ### # ### # #'
     DB '#                                   #         #             #'
     DB '#############################################################'
MAZE_END LABEL BYTE
; Parallel arrays share player indices 0..2. Current coordinates are distinct
; from candidate coordinates so collision resolution can precede all commits.
PLAYER_ROWS DB 11,1,3
PLAYER_COLS DB 11,21,43
CAND_ROWS DB 3 DUP(0)
CAND_COLS DB 3 DUP(0)
MOVING DB 3 DUP(0)
BLOCKED DB 3 DUP(0)
DONE DB 3 DUP(0)
STEPS DD 3 DUP(0)
PENALTIES DD 3 DUP(0)       ; Units: tenths of a second
FINISH_TIMES DD 3 DUP(0)    ; Unpenalized elapsed time at the exit
PAIR_TOUCH DB 3 DUP(0)      ; Pairs: 1-2, 1-3, 2-3
PAIR_LATCH DB 3 DUP(0)
; Held state and pending press counts are separate: short taps survive until
; a movement frame, while key repeats do not manufacture extra press events.
KEY_STATE DB 128 DUP(0)
KEY_PENDING DB 128 DUP(0)
; Scan codes, in up/down/left/right order.
CONTROLS DB 11H,1FH,1EH,20H, 17H,25H,24H,26H, 14H,22H,21H,23H
OLD_INT9 DD ?
LAST_BIOS DD 0
ELAPSED_TICKS DD 0
ELAPSED_TENTHS DD 0
FRAME_TICKS DW 0
STARTED DB 0
FINISHED_COUNT DB 0
WIN_MASK DB 0
BEST_SCORE DD 0FFFFFFFFH

; Begin executable code. CALL saves a return address on SS:SP; RET resumes
; after that call. PROC/ENDP are assembler declarations, not run-time actions.
.CODE
MAIN PROC
    ; Initialize DS and forward string direction (CLD), select text mode and
    ; hide the cursor. Save the old IRQ1 vector and install the game ISR using
    ; a temporary DS=CS; restore DS to the data group afterward.
    MOV AX,@DATA
    MOV DS,AX
    CLD
    MOV AX,0003H
    INT 10H
    MOV AH,01H
    MOV CX,2000H
    INT 10H
    CALL DRAW_SCREEN
    MOV AX,3509H
    INT 21H
    MOV WORD PTR OLD_INT9,BX
    MOV AX,ES
    MOV WORD PTR OLD_INT9+2,AX
    PUSH DS
    PUSH CS
    POP DS
    MOV DX,OFFSET KEYBOARD_ISR
    MOV AX,2509H
    INT 21H
    POP DS
WAIT_FRAME:
    ; Escape works whether held or tapped. Before STARTED, require a pending
    ; Space scan code (39H), then record the BIOS clock as the race origin.
    CMP KEY_STATE[01H],0
    JNE EXIT_PROGRAM
    CMP KEY_PENDING[01H],0
    JNE EXIT_PROGRAM
    CMP STARTED,0
    JNE RUNNING
    CMP KEY_PENDING[39H],0
    JE IDLE_WAIT
    MOV STARTED,1
    MOV AH,00H
    INT 1AH
    MOV WORD PTR LAST_BIOS,DX
    MOV WORD PTR LAST_BIOS+2,CX
    CALL DRAW_SCREEN
    JMP IDLE_WAIT
RUNNING:
    ; Stop game updates once all three finish. Otherwise update elapsed time
    ; and wait for two ticks. CLI protects intent construction/collision resolution/
    ; commit from keyboard-state changes; STI occurs before rendering.
    CMP FINISHED_COUNT,3
    JE IDLE_WAIT
    CALL UPDATE_CLOCK
    CMP FRAME_TICKS,MOVE_TICKS
    JB IDLE_WAIT
    MOV FRAME_TICKS,0
    CLI                       ; Snapshot/update game state, without I/O
    CALL BUILD_INTENTS
    CALL RESOLVE_COLLISIONS
    CALL COMMIT_MOVES
    STI
    CMP FINISHED_COUNT,3
    JNE DRAW_FRAME
    CALL FIND_WINNERS
DRAW_FRAME:
    ; Render the completed frame, including winner results if all players finished.
    CALL DRAW_SCREEN
IDLE_WAIT:
    ; Enable interrupts and halt until a timer/keyboard interrupt wakes the loop.
    STI
    HLT
    JMP WAIT_FRAME
EXIT_PROGRAM:
    ; Restore the saved keyboard vector with LDS/2509H, reset text mode, and
    ; terminate through DOS 4C00H. Restoring the vector prevents a dangling ISR.
    PUSH DS
    LDS DX,OLD_INT9
    MOV AX,2509H
    INT 21H
    POP DS
    MOV AX,0003H
    INT 10H
    MOV AX,4C00H
    INT 21H
MAIN ENDP

; Maintain elapsed ticks, including the BIOS midnight rollover.
UPDATE_CLOCK PROC NEAR
    ; Read BIOS CX:DX ticks. SUB/SBB performs a 32-bit difference against
    ; LAST_BIOS; if the daily counter wrapped, add its 0018:00B0H day length.
    ; Accumulate the delta, then convert total ticks into tenths for scoring.
    MOV AH,00H
    INT 1AH
    MOV AX,DX
    MOV BX,CX
    SUB AX,WORD PTR LAST_BIOS
    SBB BX,WORD PTR LAST_BIOS+2
    JNC CLOCK_DELTA_OK
    ADD AX,00B0H              ; BIOS day length = 0018:00B0 ticks
    ADC BX,0018H
CLOCK_DELTA_OK:
    ; Save the current raw clock and add low/high elapsed words with ADD/ADC.
    ; FRAME_TICKS counts when to run movement; ELAPSED_TICKS measures the race.
    MOV WORD PTR LAST_BIOS,DX
    MOV WORD PTR LAST_BIOS+2,CX
    ADD FRAME_TICKS,AX
    ADD WORD PTR ELAPSED_TICKS,AX
    ADC WORD PTR ELAPSED_TICKS+2,BX
    MOV AX,WORD PTR ELAPSED_TICKS
    MOV DX,WORD PTR ELAPSED_TICKS+2
    CALL TICKS_TO_TENTHS
    MOV WORD PTR ELAPSED_TENTHS,AX
    MOV WORD PTR ELAPSED_TENTHS+2,DX
    RET
UPDATE_CLOCK ENDP

KEYBOARD_ISR PROC FAR
    ; Save interrupted registers and read the scan byte. Port 61H acknowledges
    ; the keyboard controller. Load DS before accessing key arrays; bit 7 marks
    ; release rather than press. No DOS or screen calls are made from IRQ1.
    PUSH AX
    PUSH BX
    PUSH DS
    IN AL, 60H            ; Read the keyboard scan code
    MOV BL, AL

    IN AL, 61H            ; Acknowledge the keyboard controller
    MOV AH, AL
    OR AL, 80H
    OUT 61H, AL
    MOV AL, AH
    OUT 61H, AL

    MOV AX, @DATA
    MOV DS, AX
    CMP BL, 0E0H          ; Ignore extended-key prefix bytes
    JE IRQ_DONE
    CMP BL, 0E1H
    JE IRQ_DONE
    MOV AH, 1             ; Make code: key is down
    TEST BL, 80H
    JZ STORE_KEY
    XOR AH, AH            ; Break code: key is up
STORE_KEY:
    ; Convert the scan byte to a 0..127 index. Latch a new press only when
    ; previously up; saturate at FFH and ignore repeated make codes while held.
    AND BL, 7FH
    XOR BH, BH
    OR AH, AH
    JZ SAVE_KEY_STATE      ; Release: keep pending presses for the next frame
    CMP KEY_STATE[BX], 0
    JNE SAVE_KEY_STATE     ; Ignore typematic repeats while a key is held
    CMP KEY_PENDING[BX], 0FFH
    JE SAVE_KEY_STATE
    INC KEY_PENDING[BX]    ; Latch each new press, even if released quickly
SAVE_KEY_STATE:
    ; Save held/released status, preserving pending taps when a key is released.
    MOV KEY_STATE[BX], AH
IRQ_DONE:
    ; Acknowledge the master PIC and use IRET to restore interrupted flags/CS:IP.
    MOV AL, 20H           ; End of interrupt to the master PIC
    OUT 20H, AL
    POP DS
    POP BX
    POP AX
    IRET
KEYBOARD_ISR ENDP

; Build all proposals before checking collisions, so all players share a frame.
BUILD_INTENTS PROC NEAR
    ; Start with player index SI=0. Proposals are built without changing actual
    ; positions, giving collision tests a consistent view of the entire frame.
    XOR SI,SI
BUILD_PLAYER:
    ; Default the candidate to the current cell; clear MOVING/BLOCKED. Finished
    ; players make no new proposal. Index the four-direction control table at 4*SI.
    MOV AL,PLAYER_ROWS[SI]
    MOV CAND_ROWS[SI],AL
    MOV AL,PLAYER_COLS[SI]
    MOV CAND_COLS[SI],AL
    MOV MOVING[SI],0
    MOV BLOCKED[SI],0
    CMP DONE[SI],0
    JNE NEXT_INTENT
    MOV BX,SI
    SHL BX,1
    SHL BX,1
    XOR BP,BP
    MOV CX,4
FIND_DIRECTION:
    ; Choose the first pending or held direction in up/down/left/right order;
    ; if none is active, leave this player's candidate unchanged.
    XOR AX,AX
    MOV AL,CONTROLS[BX]
    MOV DI,AX
    CMP KEY_PENDING[DI],0
    JNE HAVE_DIRECTION
    CMP KEY_STATE[DI],0
    JNE HAVE_DIRECTION
    INC BX
    INC BP
    LOOP FIND_DIRECTION
    JMP NEXT_INTENT
HAVE_DIRECTION:
    ; Consume one pending tap, including one that later hits a wall.
    CMP KEY_PENDING[DI],0
    JE GET_POSITION
    DEC KEY_PENDING[DI]
GET_POSITION:
    ; Change a copy of row/column in DH/DL; BP=0/1/2 selects up/down/left,
    ; and the remaining direction moves right.
    MOV DH,PLAYER_ROWS[SI]
    MOV DL,PLAYER_COLS[SI]
    CMP BP,0
    JE MOVE_UP
    CMP BP,1
    JE MOVE_DOWN
    CMP BP,2
    JE MOVE_LEFT
    INC DL
    JMP CHECK_WALL
MOVE_UP:
    ; Propose one row upward, then use the common bounds/wall check.
    DEC DH
    JMP CHECK_WALL
MOVE_DOWN:
    ; Propose one row downward, then use the common bounds/wall check.
    INC DH
    JMP CHECK_WALL
MOVE_LEFT:
    ; Propose one column left, then fall through to the common check.
    DEC DL
CHECK_WALL:
    ; Unsigned dimension checks also catch byte underflow. Flatten the candidate
    ; to row*61+column; only non-wall cells become MOVING proposals.
    CMP DH,MAZE_ROWS
    JAE NEXT_INTENT
    CMP DL,MAZE_COLS
    JAE NEXT_INTENT
    MOV AL,DH
    MOV BL,MAZE_COLS
    MUL BL
    XOR BX,BX
    MOV BL,DL
    ADD BX,AX
    CMP BYTE PTR MAZE[BX],'#'
    JE NEXT_INTENT
    MOV CAND_ROWS[SI],DH
    MOV CAND_COLS[SI],DL
    MOV MOVING[SI],1
NEXT_INTENT:
    ; Advance SI until all three players have independently proposed their moves.
    INC SI
    CMP SI,3
    JB BUILD_PLAYER
    RET
BUILD_INTENTS ENDP

; Mark equal-destination and head-on swap collisions for one player pair.
; SI/DI = player indices; BX = pair index. Goal arrivals may share E.
CHECK_PAIR PROC NEAR
    ; SI/DI select a pair; BX selects its latch slot. Ignore finished players
    ; and pairs where neither proposed movement. First test shared destinations,
    ; allowing both to arrive at the shared E without collision.
    CMP DONE[SI],0
    JNE PAIR_DONE
    CMP DONE[DI],0
    JNE PAIR_DONE
    MOV AL,MOVING[SI]
    OR AL,MOVING[DI]
    JZ PAIR_DONE
    MOV AL,CAND_ROWS[SI]
    CMP AL,CAND_ROWS[DI]
    JNE CHECK_SWAP
    MOV AL,CAND_COLS[SI]
    CMP AL,CAND_COLS[DI]
    JNE CHECK_SWAP
    CMP AL,EXIT_COL
    JNE CONTACT
    CMP BYTE PTR CAND_ROWS[SI],EXIT_ROW
    JE PAIR_DONE
    JMP CONTACT
CHECK_SWAP:
    ; Detect two moving players exchanging their old positions, a head-on swap.
    ; All row and column comparisons must match before declaring contact.
    CMP MOVING[SI],0
    JE PAIR_DONE
    CMP MOVING[DI],0
    JE PAIR_DONE
    MOV AL,CAND_ROWS[SI]
    CMP AL,PLAYER_ROWS[DI]
    JNE PAIR_DONE
    MOV AL,CAND_COLS[SI]
    CMP AL,PLAYER_COLS[DI]
    JNE PAIR_DONE
    MOV AL,CAND_ROWS[DI]
    CMP AL,PLAYER_ROWS[SI]
    JNE PAIR_DONE
    MOV AL,CAND_COLS[DI]
    CMP AL,PLAYER_COLS[SI]
    JNE PAIR_DONE
CONTACT:
    ; Block both players and mark the pair touched for this frame. Penalty
    ; charging happens later so repeated resolution passes cannot multiply it.
    MOV BLOCKED[SI],1
    MOV BLOCKED[DI],1
    MOV PAIR_TOUCH[BX],1
PAIR_DONE:
    ; Return to the caller's pair enumeration, leaving any block/touch flags set.
    RET
CHECK_PAIR ENDP

RESOLVE_COLLISIONS PROC NEAR
    ; Clear the three pair-touch flags and evaluate pairs (0,1), (0,2), (1,2).
    ; Repeat three passes: canceling one proposal can make another player collide
    ; with the now-stationary participant in a chain.
    MOV PAIR_TOUCH[0],0
    MOV PAIR_TOUCH[1],0
    MOV PAIR_TOUCH[2],0
    MOV BP,3                  ; Propagate a blocked move through a 3-person chain
RESOLVE_PASS:
    ; Check all three pairs against this pass's complete candidate set.
    XOR SI,SI
    MOV DI,1
    XOR BX,BX
    CALL CHECK_PAIR
    MOV DI,2
    INC BX
    CALL CHECK_PAIR
    MOV SI,1
    INC BX
    CALL CHECK_PAIR
    XOR SI,SI
CANCEL_BLOCKED:
    ; For every blocked player, restore the candidate to its old cell and clear
    ; MOVING. Later passes see the canceled movement as stationary occupancy.
    CMP BLOCKED[SI],0
    JE NEXT_BLOCKED
    MOV MOVING[SI],0
    MOV AL,PLAYER_ROWS[SI]
    MOV CAND_ROWS[SI],AL
    MOV AL,PLAYER_COLS[SI]
    MOV CAND_COLS[SI],AL
NEXT_BLOCKED:
    ; Finish cancellation for all players, then repeat or charge each touched pair.
    INC SI
    CMP SI,3
    JB CANCEL_BLOCKED
    DEC BP
    JNZ RESOLVE_PASS
    XOR SI,SI
    MOV DI,1
    XOR BX,BX
    CALL CHARGE_PAIR
    MOV DI,2
    INC BX
    CALL CHARGE_PAIR
    MOV SI,1
    INC BX
    CALL CHARGE_PAIR
    RET
RESOLVE_COLLISIONS ENDP

CHARGE_PAIR PROC NEAR
    ; Charge only a new contact episode: touched now and latch previously zero.
    ; Each participant gets 30 tenths (=3.0 seconds), using ADD/ADC on four-byte
    ; penalties. Save BX/AX while reusing their pair index and touch value.
    MOV AL,PAIR_TOUCH[BX]
    CMP AL,0
    JE SAVE_CONTACT
    CMP PAIR_LATCH[BX],0
    JNE SAVE_CONTACT
    PUSH AX
    PUSH BX
    MOV BX,SI
    SHL BX,1
    SHL BX,1
    ADD WORD PTR PENALTIES[BX],PENALTY_TENTHS
    ADC WORD PTR PENALTIES[BX+2],0
    MOV BX,DI
    SHL BX,1
    SHL BX,1
    ADD WORD PTR PENALTIES[BX],PENALTY_TENTHS
    ADC WORD PTR PENALTIES[BX+2],0
    POP BX
    POP AX
SAVE_CONTACT:
    ; Save this frame's touch state as the next frame's latch; separation clears
    ; it so a later distinct collision can incur another penalty.
    MOV PAIR_LATCH[BX],AL
    RET
CHARGE_PAIR ENDP

COMMIT_MOVES PROC NEAR
    ; Only after resolution, commit proposals for all players that still move.
    XOR SI,SI
COMMIT_PLAYER:
    ; Copy candidate coordinates to the player, increment its 32-bit step count,
    ; and test the shared exit. Reaching E records unpenalized finish time once
    ; and marks the player DONE, so future frames stop moving/drawing it.
    CMP MOVING[SI],0
    JE NEXT_COMMIT
    MOV AL,CAND_ROWS[SI]
    MOV PLAYER_ROWS[SI],AL
    MOV AL,CAND_COLS[SI]
    MOV PLAYER_COLS[SI],AL
    MOV BX,SI
    SHL BX,1
    SHL BX,1
    ADD WORD PTR STEPS[BX],1
    ADC WORD PTR STEPS[BX+2],0
    CMP BYTE PTR PLAYER_ROWS[SI],EXIT_ROW
    JNE NEXT_COMMIT
    CMP BYTE PTR PLAYER_COLS[SI],EXIT_COL
    JNE NEXT_COMMIT
    MOV DONE[SI],1
    INC FINISHED_COUNT
    MOV AX,WORD PTR ELAPSED_TENTHS
    MOV WORD PTR FINISH_TIMES[BX],AX
    MOV AX,WORD PTR ELAPSED_TENTHS+2
    MOV WORD PTR FINISH_TIMES[BX+2],AX
NEXT_COMMIT:
    ; Advance through all three players, then return to the foreground loop.
    INC SI
    CMP SI,3
    JB COMMIT_PLAYER
    RET
COMMIT_MOVES ENDP

; SI = player. Return DX:AX = current/final adjusted score in tenths.
GET_SCORE PROC NEAR
    ; SI is the player index. Use 4*SI for dword arrays. Racers use current
    ; elapsed time; finishers use their frozen finish time. Return score in DX:AX.
    MOV BX,SI
    SHL BX,1
    SHL BX,1
    MOV AX,WORD PTR ELAPSED_TENTHS
    MOV DX,WORD PTR ELAPSED_TENTHS+2
    CMP DONE[SI],0
    JE ADD_PENALTY
    MOV AX,WORD PTR FINISH_TIMES[BX]
    MOV DX,WORD PTR FINISH_TIMES[BX+2]
ADD_PENALTY:
    ; Add the player's 32-bit penalty to the chosen base time using ADD/ADC.
    ADD AX,WORD PTR PENALTIES[BX]
    ADC DX,WORD PTR PENALTIES[BX+2]
    RET
GET_SCORE ENDP

FIND_WINNERS PROC NEAR
    ; Initialize best score to FFFFFFFFH and clear the winner mask. This runs
    ; after all three players finish, so every score is final.
    MOV WORD PTR BEST_SCORE,0FFFFH
    MOV WORD PTR BEST_SCORE+2,0FFFFH
    MOV WIN_MASK,0
    XOR SI,SI
COMPARE_SCORE:
    ; Compare unsigned high words first; compare low words only on a high-word
    ; tie. A lower score replaces the best; an equal score adds another winner.
    CALL GET_SCORE
    CMP DX,WORD PTR BEST_SCORE+2
    JB NEW_BEST
    JA NEXT_SCORE
    CMP AX,WORD PTR BEST_SCORE
    JB NEW_BEST
    JA NEXT_SCORE
    JMP ADD_WINNER
NEW_BEST:
    ; Save both score words and discard earlier winner bits for the higher score.
    MOV WORD PTR BEST_SCORE,AX
    MOV WORD PTR BEST_SCORE+2,DX
    MOV WIN_MASK,0
ADD_WINNER:
    ; Set bit (1<<player index) in WIN_MASK. OR preserves any equal-score winners.
    MOV CX,SI
    MOV AL,1
    SHL AL,CL
    OR WIN_MASK,AL
NEXT_SCORE:
    ; Compare the next player until all three scores have been considered.
    INC SI
    CMP SI,3
    JB COMPARE_SCORE
    RET
FIND_WINNERS ENDP

; Divide unsigned DX:AX by BX. Quotient DX:AX, remainder CX.
DIVIDE_U32 PROC NEAR
    ; Divide unsigned DX:AX by nonzero BX. First divide 0:high, then its
    ; remainder:low; return the full quotient in DX:AX and final remainder in CX.
    ; The second division fits because its high word is already below the divisor.
    PUSH SI
    PUSH DI
    MOV SI,AX
    MOV AX,DX
    XOR DX,DX
    DIV BX
    MOV DI,AX
    MOV AX,SI
    DIV BX
    MOV CX,DX
    MOV DX,DI
    POP DI
    POP SI
    RET
DIVIDE_U32 ENDP

; Convert BIOS ticks to tenths with the 18.2 Hz approximation.
; Predivision avoids overflowing 32 bits when multiplying by 100.
TICKS_TO_TENTHS PROC NEAR
    ; Using 18.2 ticks/second, tenths=floor(ticks*100/182). Split ticks into
    ; quotient q and remainder r on division by 182: compute 100*q plus
    ; floor(100*r/182), avoiding an overflowing intermediate ticks*100.
    ; Save r on the stack; multiply q's low/high words separately and combine them.
    PUSH BX
    PUSH CX
    PUSH SI
    PUSH DI
    PUSH BP
    MOV BX,182
    CALL DIVIDE_U32
    PUSH CX
    MOV SI,DX
    MOV BX,100
    MUL BX
    MOV DI,AX
    MOV BP,DX
    MOV AX,SI
    MUL BX
    ADD AX,BP
    MOV DX,AX
    MOV AX,DI
    POP CX
    PUSH AX
    PUSH DX
    MOV AX,CX
    MUL BX
    MOV BX,182
    DIV BX
    MOV BX,AX
    POP DX
    POP AX
    ADD AX,BX
    ADC DX,0
    POP BP
    POP DI
    POP SI
    POP CX
    POP BX
    RET
TICKS_TO_TENTHS ENDP

; Print DX:AX tenths as seconds, with one fractional digit.
PRINT_TIME PROC NEAR
    ; Divide tenths by ten into whole seconds and remainder digit. Save the
    ; remainder across PRINT_NUMBER, then print a dot and one fractional digit.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    MOV BX,10
    CALL DIVIDE_U32
    PUSH CX
    CALL PRINT_NUMBER
    MOV AL,'.'
    CALL PUT_CHAR
    POP AX
    ADD AL,'0'
    CALL PUT_CHAR
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_TIME ENDP

PUT_CHAR PROC NEAR
    ; Preserve AX/BX and print AL through BIOS INT 10H/AH=0EH on page 0.
    PUSH AX
    PUSH BX
    MOV AH,0EH
    MOV BX,0007H
    INT 10H
    POP BX
    POP AX
    RET
PUT_CHAR ENDP

SET_CURSOR PROC NEAR
    ; Preserve AX/BX and set the page-0 cursor at DH=row, DL=column using AH=02H.
    PUSH AX
    PUSH BX
    MOV AH,02H
    XOR BH,BH
    INT 10H
    POP BX
    POP AX
    RET
SET_CURSOR ENDP

CLEAR_ROW PROC NEAR
    ; Move to column zero of DH, then BIOS AH=09H writes 80 space/attribute
    ; cells without advancing the cursor. The next text begins at that row's start.
    PUSH AX
    PUSH BX
    PUSH CX
    XOR DL,DL
    CALL SET_CURSOR
    MOV AX,0920H
    MOV BX,0007H
    MOV CX,80
    INT 10H
    POP CX
    POP BX
    POP AX
    RET
CLEAR_ROW ENDP

DRAW_SCREEN PROC NEAR
    ; Preserve working registers. Render title, elapsed clock, then each
    ; player's steps, penalty, adjusted score and state before drawing the maze.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    XOR DX,DX
    CALL SET_CURSOR
    LEA SI,TITLE_TEXT
    CALL PRINT_TEXT
    MOV DH,1
    CALL CLEAR_ROW
    LEA SI,CLOCK_TEXT
    CALL PRINT_TEXT
    MOV AX,WORD PTR ELAPSED_TENTHS
    MOV DX,WORD PTR ELAPSED_TENTHS+2
    CALL PRINT_TIME
    LEA SI,RULE_TEXT
    CALL PRINT_TEXT

    XOR DI,DI
DRAW_HUD:
    ; DI is the player index. HUD row=index+2; labels use word pointers (2*index),
    ; while step/penalty counters use four-byte offsets (4*index). Explicit cursor
    ; columns align values; GET_SCORE computes each displayed adjusted time.
    MOV DX,DI
    ADD DH,0                  ; Row = player index + 2
    MOV DH,DL
    ADD DH,2
    CALL CLEAR_ROW
    MOV BX,DI
    SHL BX,1
    MOV SI,PLAYER_TEXTS[BX]
    CALL PRINT_TEXT
    MOV DL,9
    CALL SET_CURSOR
    LEA SI,STEP_TEXT
    CALL PRINT_TEXT
    MOV DL,16
    CALL SET_CURSOR
    MOV BX,DI
    SHL BX,1
    SHL BX,1
    MOV AX,WORD PTR STEPS[BX]
    MOV DX,WORD PTR STEPS[BX+2]
    CALL PRINT_NUMBER
    MOV DX,DI
    MOV DH,DL
    ADD DH,2
    MOV DL,27
    CALL SET_CURSOR
    LEA SI,PEN_TEXT
    CALL PRINT_TEXT
    MOV DL,36
    CALL SET_CURSOR
    MOV BX,DI
    SHL BX,1
    SHL BX,1
    MOV AX,WORD PTR PENALTIES[BX]
    MOV DX,WORD PTR PENALTIES[BX+2]
    CALL PRINT_TIME
    MOV DX,DI
    MOV DH,DL
    ADD DH,2
    MOV DL,46
    CALL SET_CURSOR
    LEA SI,SCORE_TEXT
    CALL PRINT_TEXT
    MOV DL,53
    CALL SET_CURSOR
    MOV SI,DI
    CALL GET_SCORE
    CALL PRINT_TIME
    MOV DX,DI
    MOV DH,DL
    ADD DH,2
    MOV DL,68
    CALL SET_CURSOR
    LEA SI,ACTIVE_TEXT
    CMP DONE[DI],0
    JE PRINT_STATE
    LEA SI,DONE_TEXT
PRINT_STATE:
    ; Print RACING or DONE, advance the HUD index, then draw legend and maze.
    ; The footer selects instructions, racing help, or winners based on state.
    CALL PRINT_TEXT
    INC DI
    CMP DI,3
    JB DRAW_HUD
    MOV DH,5
    CALL CLEAR_ROW
    LEA SI,LEGEND_TEXT
    CALL PRINT_TEXT
    CALL DRAW_MAZE
    MOV DH,24
    CALL CLEAR_ROW
    LEA SI,READY_TEXT
    CMP STARTED,0
    JE PRINT_FOOTER
    LEA SI,RACING_TEXT
    CMP FINISHED_COUNT,3
    JNE PRINT_FOOTER
    CALL DRAW_WINNERS
    JMP SCREEN_DONE
PRINT_FOOTER:
    ; Print the selected zero-terminated status text at the cleared footer row.
    CALL PRINT_TEXT
SCREEN_DONE:
    ; Restore all saved registers after screen output.
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
DRAW_SCREEN ENDP

; Direct text-video writes keep a large maze smooth on an 8086.
DRAW_MAZE PROC NEAR
    ; Use ES=B800H for color text memory. A screen row is 80*2=160 bytes;
    ; each cell is a word with character in AL and attribute/color in AH.
    ; Start at MAZE_TOP*160+MAZE_LEFT*2, preserving ES for the caller.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    PUSH ES
    MOV AX,0B800H
    MOV ES,AX
    MOV DI,MAZE_TOP*160+MAZE_LEFT*2
    LEA SI,MAZE
    MOV BP,MAZE_ROWS
VIDEO_ROW:
    ; Process exactly MAZE_COLS cells per map row, using BP for the row count.
    MOV CX,MAZE_COLS
VIDEO_CELL:
    ; LODSB advances DS:SI through the raw maze; choose normal or green E color.
    LODSB
    MOV AH,07H
    CMP AL,'E'
    JNE WRITE_CELL
    MOV AH,0AH
WRITE_CELL:
    ; STOSW writes character/attribute to ES:DI and advances by two. Skip the
    ; unused screen columns before the next row, then overlay active players.
    STOSW
    LOOP VIDEO_CELL
    ADD DI,(80-MAZE_COLS)*2
    DEC BP
    JNZ VIDEO_ROW
    XOR SI,SI
DRAW_PLAYER:
    ; Skip finishers. Convert maze row/column plus screen margins into a video
    ; byte offset, then write the player's digit and individual color as one word.
    CMP DONE[SI],0
    JNE NEXT_PLAYER_DRAW
    XOR AX,AX
    MOV AL,PLAYER_ROWS[SI]
    ADD AX,MAZE_TOP
    MOV BX,160
    MUL BX
    MOV DI,AX
    XOR AX,AX
    MOV AL,PLAYER_COLS[SI]
    ADD AX,MAZE_LEFT
    SHL AX,1
    ADD DI,AX
    MOV AL,PLAYER_CHARS[SI]
    MOV AH,PLAYER_COLORS[SI]
    STOSW
NEXT_PLAYER_DRAW:
    ; Repeat for all three players and restore the video segment/registers.
    INC SI
    CMP SI,3
    JB DRAW_PLAYER
    POP ES
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
DRAW_MAZE ENDP

DRAW_WINNERS PROC NEAR
    ; A nonzero mask has multiple set bits when mask&(mask-1) is nonzero.
    ; Select WINNER or TIE, then enumerate the set player bits.
    LEA SI,WIN_TEXT
    MOV AL,WIN_MASK
    MOV AH,AL
    DEC AL
    AND AL,AH
    JZ PRINT_WIN_PREFIX
    LEA SI,TIE_TEXT
PRINT_WIN_PREFIX:
    ; Print the chosen prefix and start scanning winner bits at player zero.
    CALL PRINT_TEXT
    XOR DI,DI
PRINT_WINNER:
    ; Test 1<<index; when set, print P and the one-based player number plus a space.
    MOV CX,DI
    MOV AL,1
    SHL AL,CL
    TEST WIN_MASK,AL
    JZ NEXT_WINNER
    MOV AL,'P'
    CALL PUT_CHAR
    MOV AX,DI
    ADD AL,'1'
    CALL PUT_CHAR
    MOV AL,' '
    CALL PUT_CHAR
NEXT_WINNER:
    ; After all winner bits, print the best adjusted score and its explanation.
    INC DI
    CMP DI,3
    JB PRINT_WINNER
    LEA SI,FINAL_TEXT
    CALL PRINT_TEXT
    MOV AX,WORD PTR BEST_SCORE
    MOV DX,WORD PTR BEST_SCORE+2
    CALL PRINT_TIME
    LEA SI,FINAL_SUFFIX
    CALL PRINT_TEXT
    RET
DRAW_WINNERS ENDP

; DS:SI points to a zero-terminated string.
PRINT_TEXT PROC NEAR
    ; Print a zero-terminated string at DS:SI with BIOS teletype output.
    ; Save AX/BX/SI so rendering does not consume the caller's string pointer.
    ; CLD at startup makes LODSB advance SI instead of moving backward.
    PUSH AX
    PUSH BX
    PUSH SI
PRINT_NEXT:
    ; LODSB reads DS:SI into AL and advances SI. OR tests AL without changing
    ; it; zero ends the string. BIOS INT 10H/AH=0EH prints and advances the cursor.
    LODSB
    OR AL, AL
    JZ TEXT_DONE
    MOV AH, 0EH
    MOV BX, 0007H
    INT 10H
    JMP PRINT_NEXT
TEXT_DONE:
    ; Restore saved registers in reverse PUSH order and return to the caller.
    POP SI
    POP BX
    POP AX
    RET
PRINT_TEXT ENDP

; Print unsigned DX:AX in decimal using two 16-bit divisions per digit.
PRINT_NUMBER PROC NEAR
    ; Print unsigned 32-bit DX:AX in decimal while preserving working registers.
    ; An 8086 has 16-bit DIV, so divide the high word first and carry its remainder
    ; into the low-word division. Stack each remainder digit to reverse its order.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    MOV BX, 10
    XOR CX, CX
DIVIDE_DIGIT:
    ; Save the low word, divide 0:high by ten, then divide remainder:low by ten.
    ; The latter remainder is one decimal digit; DI holds the high quotient word.
    ; Continue until BOTH quotient words are zero. Input zero still emits one digit.
    MOV SI, AX            ; Save low word
    MOV AX, DX            ; Divide high word by 10 first
    XOR DX, DX
    DIV BX
    MOV DI, AX            ; High word of quotient
    MOV AX, SI
    DIV BX                ; Divide remainder:low word by 10
    PUSH DX               ; Remainder = next decimal digit
    MOV DX, DI
    INC CX
    MOV SI, AX
    OR SI, DX
    JNZ DIVIDE_DIGIT
PRINT_DIGIT:
    ; Pop digits leftmost first, add ASCII '0', and print with BIOS teletype.
    ; LOOP decrements CX until all temporary digit words have been removed.
    POP AX
    ADD AL, '0'
    MOV AH, 0EH
    MOV BX, 0007H
    INT 10H
    LOOP PRINT_DIGIT
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_NUMBER ENDP


; Close the source module and select MAIN as its executable entry point.
END MAIN
