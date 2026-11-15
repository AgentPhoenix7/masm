; Study notes: host keyboard controls, foreground orchestration and video output.
; MAIN initializes game/serial/IRQ1, then repeatedly polls time/input, handles
; local host actions, advances game frames, queues state and renders the screen.
; Host actions stay local; phone inputs reach the core through serial ownership
; checks. Key edges trigger each host command once instead of on every held frame.
; Video memory B800H contains 80x25 word cells: low byte character, high attribute.
;
; Local PC UI and IRQ1 edge controls. Internet clients cannot call host actions.
; Begin data declarations. DB/DW/DD allocate bytes/words/doublewords; DUP
; repeats an item. EQU constants allocate no storage. Offsets are relative to DS.
.DATA
; Separate 256-byte arrays retain held keys and unconsumed press edges.
; Extended-key marker bit 7 selects the upper half; Pause has skip state.
KEY_DOWN DB 256 DUP(0)
KEY_EDGE DB 256 DUP(0)
EXTENDED_KEY DB 0
PAUSE_BYTES DB 0
OLD_INT9 DD 0
KEY_HOOKED DB 0
; VIDEO_ATTR controls direct text colors; SHOW_SCORES selects view mode.
; DRAW_TICK throttles rendering; player colors are indexed by slot 0..7.
VIDEO_ATTR DB 07H
SHOW_SCORES DB 0
DRAW_TICK DW 0FFFFH
PLAYER_COLORS DB 0EH,0BH,0DH,09H,0CH,0AH,0FH,06H
; UI strings are zero-terminated for VIDEO_TEXT, not DOS '$'-terminated.
; Names are the separate fixed-width exception rendered with counted loops.
UI_TITLE DB 'MAZE4 | Internet phone race | Tab: scores | Esc: quit',0
UI_LOBBY DB 'LOBBY | Space: start when all READY | M: mode | R: maze | 1-8: remove',0
UI_RACE DB 'RACING | Phone buttons move players | Green E = shared exit',0
UI_RESULTS DB 'RESULTS | Lowest finish time + penalties wins | N: new room',0
UI_COUNT DB 'Players: ',0
UI_DIST DB '  Equal route: ',0
UI_FLOOR DB '  Floor cells: ',0
UI_MODE0 DB 'Collision: block +3.0s to both per contact | Head-on: back away',0
UI_MODE1 DB 'Collision: rotating priority, no penalty | Head-on: back away',0
UI_WARN DB 'Warnings: CAUTION <5 path steps; DANGER <3 | N: new room (not racing)',0
UI_CODE DB 'Room password: ',0
UI_CONNECT DB ' | HTTPS address is in the launcher terminal',0
UI_CLOCK DB 'Race: ',0
UI_WIN DB 's | Winner(s): ',0
UI_EMPTY DB 'EMPTY',0
UI_ACTIVE DB 'RACE ',0
UI_READY DB 'READY',0
UI_WAIT DB 'WAIT ',0
UI_DONE DB 'DONE ',0
UI_DNF DB 'DNF  ',0
UI_SAFE DB ' SAFE',0
UI_CAUTION DB ' CAUTION',0
UI_DANGER DB ' DANGER',0
UI_TABLE DB 'Player/name   State     Steps          Penalty       Score      Warning',0
UI_BAD DB 'Maze generation failed: press R to retry or Esc to quit.',0
; Begin executable code. CALL saves a return address on SS:SP; RET resumes
; after that call. PROC/ENDP are assembler declarations, not run-time actions.
.CODE
MAIN PROC
    ; Initialize DS=ES=@DATA and CLD for forward REP/LODS/STOS operations.
    ; Select text mode 3, hide the cursor, capture the BIOS clock, and seed the
    ; generator from tick words. Generate a map before enabling serial/keyboard UI.
    MOV AX,@DATA
    MOV DS,AX
    MOV ES,AX
    CLD
    MOV AX,3
    INT 10H
    MOV AH,1
    MOV CX,2000H
    INT 10H
    MOV AH,0
    INT 1AH
    MOV WORD PTR LAST_BIOS,DX
    MOV WORD PTR LAST_BIOS+2,CX
    MOV AX,DX
    XOR AX,CX
    OR AX,1
    MOV RNG_SEED,AX
    CALL GENERATE_MAZE
    CALL SERIAL_INIT
    CALL INSTALL_KEYS
MAIN_LOOP:
    ; Read time and bounded serial input, check Escape's latched edge, process
    ; host actions, and run a game tick. Queue a full state every four SYSTEM_TICK
    ; ticks; unsigned subtraction tolerates short low-word clock wrap.
    CALL READ_CLOCK
    CALL SERIAL_POLL
    CMP KEY_EDGE[1],0
    JNE EXIT_MAIN
    CALL HOST_CONTROLS
    CALL GAME_TICK
    MOV AX,SYSTEM_TICK
    SUB AX,STATE_TICK
    CMP AX,4
    JB MAIN_FLUSH
    MOV AX,SYSTEM_TICK
    MOV STATE_TICK,AX
    CALL SEND_STATE
MAIN_FLUSH:
    ; Drain ready UART output without waiting. Draw at most once per two ticks
    ; so transport polling and game rules are not delayed by needless redraws.
    CALL SERIAL_FLUSH
    MOV AX,SYSTEM_TICK
    SUB AX,DRAW_TICK
    CMP AX,2
    JB MAIN_IDLE
    MOV AX,SYSTEM_TICK
    MOV DRAW_TICK,AX
    CALL DRAW_SCREEN
MAIN_IDLE:
    ; Keep looping while unsent serial bytes exist. Otherwise STI/HLT waits
    ; for a timer/keyboard interrupt, then resumes foreground polling.
    MOV AX,TX_HEAD
    CMP AX,TX_TAIL
    JNE MAIN_LOOP
    STI
    HLT
    JMP MAIN_LOOP
EXIT_MAIN:
    ; Restore the previous keyboard vector before returning to DOS. Reset text
    ; mode for a clear/normal screen, then DOS 4C00H terminates with status zero.
    CALL RESTORE_KEYS
    MOV AX,3
    INT 10H
    MOV AX,4C00H
    INT 21H
MAIN ENDP
HOST_CONTROLS PROC NEAR
    ; Tab edge toggles scores. Clear each handled edge before executing its
    ; action so holding a key or keyboard typematic cannot repeatedly trigger it.
    CMP KEY_EDGE[0FH],0
    JE HOST_SPACE
    MOV KEY_EDGE[0FH],0
    XOR SHOW_SCORES,1
HOST_SPACE:
    ; Consume Space and call START_RACE, which enforces lobby/count/readiness.
    CMP KEY_EDGE[39H],0
    JE HOST_MODE
    MOV KEY_EDGE[39H],0
    CALL START_RACE
HOST_MODE:
    ; Consume M; only in lobby toggle collision mode between block/+3s and
    ; rotating priority. An active race cannot have its rule mode changed here.
    CMP KEY_EDGE[32H],0
    JE HOST_MAZE
    MOV KEY_EDGE[32H],0
    CMP PHASE,1
    JNE HOST_MAZE
    XOR COLLISION_MODE,1
HOST_MAZE:
    ; Consume R and call the lobby-only map regeneration routine.
    CMP KEY_EDGE[13H],0
    JE HOST_NEW
    MOV KEY_EDGE[13H],0
    CALL REGENERATE
HOST_NEW:
    ; Consume N and request a new room; NEW_ROOM refuses during active racing.
    CMP KEY_EDGE[31H],0
    JE HOST_REMOVE
    MOV KEY_EDGE[31H],0
    CALL NEW_ROOM
HOST_REMOVE:
    ; Scan eight numbered key edges (scan codes 02H..09H for 1..8).
    XOR SI,SI
HOST_REMOVE_NEXT:
    ; Clear a numbered edge and drop that occupied slot. DROP_PLAYER handles
    ; freeing a lobby slot versus revoking ownership/marking DNF after start.
    MOV BX,SI
    ADD BX,2
    CMP KEY_EDGE[BX],0
    JE HOST_REMOVE_SKIP
    MOV KEY_EDGE[BX],0
    CMP PLAYER_STATE[SI],0
    JE HOST_REMOVE_SKIP
    CALL DROP_PLAYER
HOST_REMOVE_SKIP:
    ; Advance over all eight slots before returning to the main loop.
    INC SI
    CMP SI,8
    JB HOST_REMOVE_NEXT
    RET
HOST_CONTROLS ENDP
INSTALL_KEYS PROC NEAR
    ; DOS 3509H returns the current IRQ1 vector in ES:BX; save both words.
    ; Temporarily set DS=CS so 2509H installs CS:KEYBOARD_ISR, then restore data
    ; DS/ES and mark KEY_HOOKED. The installed handler belongs to this program.
    PUSH ES
    MOV AX,3509H
    INT 21H
    MOV WORD PTR OLD_INT9,BX
    MOV WORD PTR OLD_INT9+2,ES
    PUSH DS
    PUSH CS
    POP DS
    MOV DX,OFFSET KEYBOARD_ISR
    MOV AX,2509H
    INT 21H
    POP DS
    MOV KEY_HOOKED,1
    POP ES
    RET
INSTALL_KEYS ENDP
RESTORE_KEYS PROC NEAR
    ; Only restore when installed. LDS DX,OLD_INT9 loads the old segment and
    ; offset together; preserve DS around DOS 2509H, then clear KEY_HOOKED.
    CMP KEY_HOOKED,0
    JE KEYS_RESTORED
    PUSH DS
    LDS DX,OLD_INT9
    MOV AX,2509H
    INT 21H
    POP DS
    MOV KEY_HOOKED,0
KEYS_RESTORED:
    ; Return after restoring or after discovering no active hook.
    RET
RESTORE_KEYS ENDP

KEYBOARD_ISR PROC FAR
    ; IRQ1 saves AX/BX/DS, reads port 60H and pulses port 61H bit 7 to
    ; acknowledge the keyboard. Load DS explicitly: an interrupt can arrive while
    ; the foreground temporarily uses another segment. No BIOS/DOS calls occur here.
    PUSH AX
    PUSH BX
    PUSH DS
    IN AL,60H
    MOV BL,AL
    IN AL,61H
    MOV AH,AL
    OR AL,80H
    OUT 61H,AL
    MOV AL,AH
    OUT 61H,AL
    MOV AX,@DATA
    MOV DS,AX
    CMP PAUSE_BYTES,0
    JE IRQ_PREFIX
    DEC PAUSE_BYTES
    JMP IRQ_DONE
IRQ_PREFIX:
    ; E1 begins the six-byte Pause sequence: skip the next five bytes so
    ; embedded scan bytes cannot masquerade as host actions.
    CMP BL,0E1H
    JNE IRQ_EXTENDED
    MOV PAUSE_BYTES,5
    MOV EXTENDED_KEY,0
    JMP IRQ_DONE
IRQ_EXTENDED:
    ; E0 marks an extended key; remember index bit 7 for the next scan byte,
    ; separating extended keys from their ordinary keyboard counterparts.
    CMP BL,0E0H
    JNE IRQ_STORE
    MOV EXTENDED_KEY,80H
    JMP IRQ_DONE
IRQ_STORE:
    ; Save the original release bit, remove it from the scan index, then OR
    ; the E0 marker to form a 0..255 index. Clear the marker after use.
    ; A first make sets DOWN and EDGE; repeated make bytes leave EDGE unchanged.
    MOV AH,BL
    AND BL,7FH
    OR BL,EXTENDED_KEY
    XOR BH,BH
    MOV EXTENDED_KEY,0
    TEST AH,80H
    JNZ IRQ_RELEASE
    CMP KEY_DOWN[BX],0
    JNE IRQ_DONE
    MOV KEY_DOWN[BX],1
    MOV KEY_EDGE[BX],1
    JMP IRQ_DONE
IRQ_RELEASE:
    ; Release clears DOWN but leaves the edge latched until the foreground
    ; consumes it, preserving quick taps between frames.
    MOV KEY_DOWN[BX],0
IRQ_DONE:
    ; Send an EOI to the master PIC, restore saved registers and IRET, which
    ; restores flags/CS:IP rather than using an ordinary procedure RET.
    MOV AL,20H
    OUT 20H,AL
    POP DS
    POP BX
    POP AX
    IRET
KEYBOARD_ISR ENDP

CLEAR_SCREEN PROC NEAR
    ; Temporarily set ES=B800H and fill 2000 word cells with 0720H: spaces
    ; in normal gray-on-black. REP STOSW advances DI by two with CLD set.
    PUSH AX
    PUSH CX
    PUSH DI
    PUSH ES
    MOV AX,0B800H
    MOV ES,AX
    XOR DI,DI
    MOV AX,0720H
    MOV CX,2000
    REP STOSW
    POP ES
    POP DI
    POP CX
    POP AX
    RET
CLEAR_SCREEN ENDP

; Video primitives preserve caller registers except DI (advances on output).
VIDEO_CHAR PROC NEAR
    ; AL is the character and VIDEO_ATTR its color. Build the character/attribute
    ; word, write it with STOSW through ES=B800H, and restore AX/ES. DI advances
    ; one cell; no BIOS cursor state is changed by this direct-memory operation.
    PUSH AX
    PUSH ES
    MOV AH,VIDEO_ATTR
    PUSH AX
    MOV AX,0B800H
    MOV ES,AX
    POP AX
    STOSW
    POP ES
    POP AX
    RET
VIDEO_CHAR ENDP
VIDEO_TEXT PROC NEAR
    ; Print a zero-terminated string at DS:SI; preserve AX/SI but allow DI
    ; to advance through the destination video cells.
    PUSH AX
    PUSH SI
VIDEO_TEXT_NEXT:
    ; LODSB loads/advances the string pointer; OR tests its zero terminator.
    ; Nonzero characters pass to VIDEO_CHAR using the current global attribute.
    LODSB
    OR AL,AL
    JZ VIDEO_TEXT_DONE
    CALL VIDEO_CHAR
    JMP VIDEO_TEXT_NEXT
VIDEO_TEXT_DONE:
    ; Restore the original string pointer and AX after reaching zero.
    POP SI
    POP AX
    RET
VIDEO_TEXT ENDP
VIDEO_NUMBER PROC NEAR
    ; Print unsigned DX:AX as decimal into video memory, preserving working
    ; registers except advancing DI. DIVIDE_U32 returns a quotient and one digit
    ; remainder; BP counts stack-saved digits, independently of scratch CX.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH BP
    MOV BX,10
    XOR BP,BP
VIDEO_DIGIT:
    ; Divide by ten, push remainder CX, then test both quotient words.
    ; The loop runs once for zero, ensuring it prints a digit rather than nothing.
    CALL DIVIDE_U32
    PUSH CX
    INC BP
    MOV SI,AX
    OR SI,DX
    JNZ VIDEO_DIGIT
VIDEO_DIGIT_OUT:
    ; Pop digits in reverse extraction order, add ASCII '0', and output them.
    ; After BP digits, temporary words are gone and saved registers can be restored.
    POP AX
    ADD AL,'0'
    CALL VIDEO_CHAR
    DEC BP
    JNZ VIDEO_DIGIT_OUT
    POP BP
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
VIDEO_NUMBER ENDP
VIDEO_TIME PROC NEAR
    ; Split tenths into whole seconds plus remainder by dividing by ten.
    ; Save the fractional digit across VIDEO_NUMBER, then emit dot and that digit.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    MOV BX,10
    CALL DIVIDE_U32
    PUSH CX
    CALL VIDEO_NUMBER
    MOV AL,'.'
    CALL VIDEO_CHAR
    POP AX
    ADD AL,'0'
    CALL VIDEO_CHAR
    POP DX
    POP CX
    POP BX
    POP AX
    RET
VIDEO_TIME ENDP


; BX player index. Return DS:SI state label, preserving BX.
STATE_LABEL PROC NEAR
    ; BX is the player slot; return DS:SI for EMPTY, DNF, DONE or RACE.
    ; In lobby, an active slot instead displays WAIT or READY from its ready bit.
    ; BX is preserved so the caller can next request this slot's warning label.
    LEA SI,UI_EMPTY
    CMP PLAYER_STATE[BX],0
    JE STATE_LABEL_DONE
    LEA SI,UI_DNF
    CMP PLAYER_STATE[BX],3
    JE STATE_LABEL_DONE
    LEA SI,UI_DONE
    CMP PLAYER_STATE[BX],2
    JE STATE_LABEL_DONE
    LEA SI,UI_ACTIVE
    CMP PHASE,1
    JNE STATE_LABEL_DONE
    LEA SI,UI_WAIT
    CMP READY[BX],0
    JE STATE_LABEL_DONE
    LEA SI,UI_READY
STATE_LABEL_DONE:
    ; Return with the chosen label pointer in SI; this helper itself prints nothing.
    RET
STATE_LABEL ENDP
WARNING_LABEL PROC NEAR
    ; Select SAFE/CAUTION/DANGER plus gray/yellow/red VIDEO_ATTR from WARNINGS[BX].
    ; The attribute is intentionally left changed for the next text output.
    MOV VIDEO_ATTR,07H
    LEA SI,UI_SAFE
    CMP WARNINGS[BX],0
    JE WARNING_LABEL_DONE
    MOV VIDEO_ATTR,0EH
    LEA SI,UI_CAUTION
    CMP WARNINGS[BX],1
    JE WARNING_LABEL_DONE
    MOV VIDEO_ATTR,0CH
    LEA SI,UI_DANGER
WARNING_LABEL_DONE:
    ; Return label pointer and selected attribute to the renderer.
    RET
WARNING_LABEL ENDP
DRAW_SCREEN PROC NEAR
    ; Save working registers and ES, clear the screen, then render header
    ; metadata: player count/capacity, equal route distance, floor count, phase,
    ; collision mode, clock, winner bits and room connection text. DI is a video
    ; byte offset: 160 bytes per row, two bytes per column.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    PUSH ES
    CALL CLEAR_SCREEN
    XOR DI,DI
    MOV VIDEO_ATTR,0FH
    LEA SI,UI_TITLE
    CALL VIDEO_TEXT
    MOV VIDEO_ATTR,07H
    MOV DI,160
    LEA SI,UI_COUNT
    CALL VIDEO_TEXT
    XOR AX,AX
    XOR DX,DX
    MOV AL,PLAYER_COUNT
    CALL VIDEO_NUMBER
    MOV AL,'/'
    CALL VIDEO_CHAR
    XOR AX,AX
    MOV AL,CAPACITY
    CALL VIDEO_NUMBER
    LEA SI,UI_DIST
    CALL VIDEO_TEXT
    MOV AX,COMMON_DISTANCE
    CALL VIDEO_NUMBER
    LEA SI,UI_FLOOR
    CALL VIDEO_TEXT
    MOV AX,FLOOR_COUNT
    CALL VIDEO_NUMBER
    MOV DI,320
    LEA SI,UI_LOBBY
    CMP PHASE,1
    JE DRAW_PHASE
    LEA SI,UI_RACE
    CMP PHASE,2
    JE DRAW_PHASE
    LEA SI,UI_RESULTS
DRAW_PHASE:
    ; Print the label selected from PHASE (lobby/race/results).
    CALL VIDEO_TEXT
    MOV DI,480
    LEA SI,UI_MODE0
    CMP COLLISION_MODE,0
    JE DRAW_MODE
    LEA SI,UI_MODE1
DRAW_MODE:
    ; Print the selected collision rule, then warning help and elapsed time.
    CALL VIDEO_TEXT
    MOV DI,640
    LEA SI,UI_WARN
    CALL VIDEO_TEXT
    MOV DI,800
    LEA SI,UI_CLOCK
    CALL VIDEO_TEXT
    MOV AX,WORD PTR ELAPSED_TENTHS
    MOV DX,WORD PTR ELAPSED_TENTHS+2
    CALL VIDEO_TIME
    LEA SI,UI_WIN
    CALL VIDEO_TEXT
    XOR BP,BP
DRAW_WINNER:
    ; Scan bit 1<<slot in WIN_MASK and print the one-based number for each winner.
    MOV CX,BP
    MOV AL,1
    SHL AL,CL
    TEST WIN_MASK,AL
    JZ DRAW_WINNER_NEXT
    MOV AX,BP
    ADD AL,'1'
    CALL VIDEO_CHAR
    MOV AL,' '
    CALL VIDEO_CHAR
DRAW_WINNER_NEXT:
    ; After scanning all bits, show room code/connection guidance. SHOW_SCORES
    ; selects a full table; otherwise draw the map and side roster.
    INC BP
    CMP BP,8
    JB DRAW_WINNER
    MOV DI,960
    LEA SI,UI_CODE
    CALL VIDEO_TEXT
    LEA SI,ROOM_CODE
    CALL VIDEO_TEXT
    LEA SI,UI_CONNECT
    CALL VIDEO_TEXT
    CMP SHOW_SCORES,0
    JNE DRAW_TABLE
    MOV AX,0B800H
    MOV ES,AX
    MOV DI,7*160
    LEA SI,MAZE
    MOV BP,ROWS
DRAW_ROW:
    ; Start map rows at screen row seven. BP counts ROWS and CX counts COLS;
    ; SI scans the contiguous fixed-width maze bytes without terminators.
    MOV CX,COLS
DRAW_CELL:
    ; Load one map character and choose gray normally or green for shared E.
    LODSB
    MOV AH,07H
    CMP AL,'E'
    JNE DRAW_CELL_SAVE
    MOV AH,0AH
DRAW_CELL_SAVE:
    ; STOSW writes character/attribute and advances two bytes. At row end skip
    ; (80-COLS)*2 bytes to align the next map row in the wider text screen.
    STOSW
    LOOP DRAW_CELL
    ADD DI,(80-COLS)*2
    DEC BP
    JNZ DRAW_ROW
    XOR SI,SI
DRAW_PLAYER:
    ; Draw racing slots only. DIV COLS splits the linear cell into row/column;
    ; video offset=(row+7)*160+column*2. Overlay the player digit and color.
    ; Finished/DNF players are absent from the maze but remain in the roster.
    CMP PLAYER_STATE[SI],1
    JNE DRAW_PLAYER_NEXT
    MOV BX,SI
    SHL BX,1
    MOV AX,POSITIONS[BX]
    XOR DX,DX
    MOV BX,COLS
    DIV BX
    ADD AX,7
    MOV BX,160
    PUSH DX
    MUL BX
    MOV DI,AX
    POP DX
    SHL DX,1
    ADD DI,DX
    MOV AX,SI
    ADD AL,'1'
    MOV AH,PLAYER_COLORS[SI]
    STOSW
DRAW_PLAYER_NEXT:
    ; Advance through eight player slots, then build the side roster.
    INC SI
    CMP SI,8
    JB DRAW_PLAYER
    XOR BP,BP
DRAW_ROSTER:
    ; Each player uses two screen rows at column 63: first colored number/name,
    ; then state and proximity warning. Name offset=8*slot and exactly eight
    ; bytes are printed, because padded names have no zero terminator.
    MOV AX,BP
    MOV BX,320
    MUL BX
    ADD AX,7*160+63*2
    MOV DI,AX
    MOV BX,BP
    MOV AL,PLAYER_COLORS[BX]
    MOV VIDEO_ATTR,AL
    MOV AX,BP
    ADD AL,'1'
    CALL VIDEO_CHAR
    MOV AL,' '
    CALL VIDEO_CHAR
    MOV SI,BP
    MOV CL,3
    SHL SI,CL
    ADD SI,OFFSET PLAYER_NAMES
    MOV CX,8
DRAW_NAME:
    ; Emit each fixed-width name byte, then position the second row for state
    ; and warning labels. Advance BP after both lines have been completed.
    LODSB
    CALL VIDEO_CHAR
    LOOP DRAW_NAME
    MOV AX,BP
    MOV BX,320
    MUL BX
    ADD AX,8*160+63*2
    MOV DI,AX
    MOV BX,BP
    CALL STATE_LABEL
    CALL VIDEO_TEXT
    CALL WARNING_LABEL
    CALL VIDEO_TEXT
    INC BP
    CMP BP,8
    JB DRAW_ROSTER
    JMP DRAW_DONE
DRAW_TABLE:
    ; Replace the maze/side roster with a full-width statistics heading.
    MOV DI,7*160
    LEA SI,UI_TABLE
    CALL VIDEO_TEXT
    XOR BP,BP
DRAW_TABLE_PLAYER:
    ; Give each slot two screen rows. Print number/name/state and 32-bit steps,
    ; then position penalty, adjusted score and warning at fixed columns.
    ; Counter byte offset=4*slot; GET_SCORE chooses live versus final time.
    MOV AX,BP
    MOV BX,320
    MUL BX
    ADD AX,8*160
    MOV DI,AX
    MOV VIDEO_ATTR,07H
    MOV AX,BP
    ADD AL,'1'
    CALL VIDEO_CHAR
    MOV AL,' '
    CALL VIDEO_CHAR
    MOV SI,BP
    MOV CL,3
    SHL SI,CL
    ADD SI,OFFSET PLAYER_NAMES
    MOV CX,8
DRAW_TABLE_NAME:
    ; Print the eight padded name bytes, then continue the table row's fields.
    LODSB
    CALL VIDEO_CHAR
    LOOP DRAW_TABLE_NAME
    ADD DI,8
    MOV BX,BP
    CALL STATE_LABEL
    CALL VIDEO_TEXT
    ADD DI,8
    MOV BX,BP
    SHL BX,1
    SHL BX,1
    MOV AX,WORD PTR STEPS[BX]
    MOV DX,WORD PTR STEPS[BX+2]
    CALL VIDEO_NUMBER
    MOV AX,BP
    MOV BX,320
    MUL BX
    MOV DI,AX
    ADD DI,8*160+38*2
    MOV BX,BP
    SHL BX,1
    SHL BX,1
    MOV AX,WORD PTR PENALTIES[BX]
    MOV DX,WORD PTR PENALTIES[BX+2]
    CALL VIDEO_TIME
    MOV AX,BP
    MOV BX,320
    MUL BX
    MOV DI,AX
    ADD DI,8*160+52*2
    MOV SI,BP
    CALL GET_SCORE
    CALL VIDEO_TIME
    MOV AX,BP
    MOV BX,320
    MUL BX
    MOV DI,AX
    ADD DI,8*160+62*2
    MOV BX,BP
    CALL WARNING_LABEL
    CALL VIDEO_TEXT
    INC BP
    CMP BP,8
    JB DRAW_TABLE_PLAYER
DRAW_DONE:
    ; If generated capacity is below two, print the regeneration-error footer;
    ; otherwise complete normally. No screen branch changes game-rule state.
    CMP CAPACITY,2
    JAE DRAW_RETURN
    MOV DI,24*160
    LEA SI,UI_BAD
    CALL VIDEO_TEXT
DRAW_RETURN:
    ; Restore all saved registers, including ES and DI, after the complete frame.
    POP ES
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
DRAW_SCREEN ENDP
