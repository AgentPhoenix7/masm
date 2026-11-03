; 8086 / MASM / DOS: navigate a maze using the arrow keys.
; Build: MASM MAZE.ASM; then LINK MAZE.OBJ;
; Run: MAZE.  Press Esc to exit.

.8086
.MODEL SMALL
.STACK 100H

MAZE_ROWS EQU 9
MAZE_COLS EQU 20
MAZE_TOP  EQU 3             ; First maze row on the screen (zero-based)

.DATA
    HELP_TEXT DB 'MAZE - Use arrow keys to move. Esc exits.',13,10
              DB '# = wall   @ = player',13,10,'$'

    ; Each row has exactly MAZE_COLS characters. No terminators here.
    MAZE DB '####################'
         DB '#     #            #'
         DB '# ### # #### ##### #'
         DB '# #   #    #     # #'
         DB '# # ###### # ### # #'
         DB '# #        # #   # #'
         DB '# ########## # ### #'
         DB '#                  #'
         DB '####################'

    PLAYER_ROW DB 1         ; Maze coordinates, zero-based
    PLAYER_COL DB 1

.CODE
MAIN PROC
    MOV AX, @DATA
    MOV DS, AX

    MOV AX, 0003H          ; BIOS: clear screen, 80x25 text mode
    INT 10H
    MOV AH, 01H            ; BIOS: hide the blinking cursor
    MOV CX, 2000H
    INT 10H

    LEA DX, HELP_TEXT
    MOV AH, 09H            ; DOS: print instructions
    INT 21H
    CALL DRAW_MAZE

READ_KEY:
    MOV AH, 00H            ; BIOS: read key without echo
    INT 16H                ; AL = ASCII code, AH = scan code
    CMP AL, 1BH            ; Escape
    JE EXIT_PROGRAM

    ; Ordinary characters must not be interpreted as arrow keys.
    CMP AL, 00H
    JE CHECK_ARROW
    CMP AL, 0E0H           ; Also accept the extended-key prefix
    JNE READ_KEY

CHECK_ARROW:
    MOV DH, PLAYER_ROW     ; Candidate position, not committed yet
    MOV DL, PLAYER_COL
    CMP AH, 48H            ; Up arrow
    JE MOVE_UP
    CMP AH, 50H            ; Down arrow
    JE MOVE_DOWN
    CMP AH, 4BH            ; Left arrow
    JE MOVE_LEFT
    CMP AH, 4DH            ; Right arrow
    JE MOVE_RIGHT
    JMP READ_KEY

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

CHECK_MOVE:
    ; Unsigned comparisons also reject underflow (0 - 1 = 255).
    CMP DH, MAZE_ROWS
    JAE READ_KEY
    CMP DL, MAZE_COLS
    JAE READ_KEY

    ; Offset = row * MAZE_COLS + column.
    ; Byte MUL changes AX only, leaving candidate DH:DL intact.
    MOV AL, DH
    MOV BL, MAZE_COLS
    MUL BL
    XOR BX, BX
    MOV BL, DL
    ADD AX, BX
    MOV SI, AX
    CMP BYTE PTR MAZE[SI], '#'
    JE READ_KEY            ; Wall: keep the old position

    MOV PLAYER_ROW, DH     ; Valid path: commit the new position
    MOV PLAYER_COL, DL
    CALL DRAW_MAZE         ; Redraw paths, then the current player
    JMP READ_KEY

EXIT_PROGRAM:
    MOV AX, 0003H          ; Clear screen and restore visible cursor
    INT 10H
    MOV AX, 4C00H          ; DOS: terminate with exit code 0
    INT 21H
MAIN ENDP

DRAW_MAZE PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH BP

    XOR SI, SI
    MOV DH, MAZE_TOP
    MOV BP, MAZE_ROWS
DRAW_ROW:
    XOR DL, DL
    MOV AH, 02H            ; BIOS: cursor at the start of this row
    XOR BH, BH             ; Video page 0
    INT 10H
    MOV CX, MAZE_COLS
DRAW_CELL:
    MOV AL, MAZE[SI]
    MOV AH, 0EH            ; BIOS: write character, advance cursor
    MOV BX, 0007H
    INT 10H
    INC SI
    LOOP DRAW_CELL
    INC DH
    DEC BP
    JNZ DRAW_ROW

    MOV DH, PLAYER_ROW
    ADD DH, MAZE_TOP
    MOV DL, PLAYER_COL
    MOV AH, 02H
    XOR BH, BH
    INT 10H

    MOV AL, '@'
    MOV AH, 09H            ; BIOS: write character and attribute
    MOV BX, 000EH          ; Page 0, yellow on black
    MOV CX, 1
    INT 10H

    POP BP
    POP SI
    POP DX
    POP CX
    POP BX; 8086 / MASM / DOS: navigate a maze using the arrow keys.
    ; Build: MASM MAZE.ASM; then LINK MAZE.OBJ;
    ; Run: MAZE.  Press Esc to exit.
    
    .8086
    .MODEL SMALL
    .STACK 100H
    
    MAZE_ROWS EQU 9
    MAZE_COLS EQU 20
    MAZE_TOP  EQU 3             ; First maze row on the screen (zero-based)
    
    .DATA
        HELP_TEXT DB 'MAZE - Use arrow keys to move. Esc exits.',13,10
                  DB '# = wall   @ = player',13,10,'$'
    
        ; Each row has exactly MAZE_COLS characters. No terminators here.
        MAZE DB '####################'
             DB '#     #            #'
             DB '# ### # #### ##### #'
             DB '# #   #    #     # #'
             DB '# # ###### # ### # #'
             DB '# #        # #   # #'
             DB '# ########## # ### #'
             DB '#                  #'
             DB '####################'
    
        PLAYER_ROW DB 1         ; Maze coordinates, zero-based
        PLAYER_COL DB 1
    
    .CODE
    MAIN PROC
        MOV AX, @DATA
        MOV DS, AX
    
        MOV AX, 0003H          ; BIOS: clear screen, 80x25 text mode
        INT 10H
        MOV AH, 01H            ; BIOS: hide the blinking cursor
        MOV CX, 2000H
        INT 10H
    
        LEA DX, HELP_TEXT
        MOV AH, 09H            ; DOS: print instructions
        INT 21H
        CALL DRAW_MAZE
    
    READ_KEY:
        MOV AH, 00H            ; BIOS: read key without echo
        INT 16H                ; AL = ASCII code, AH = scan code
        CMP AL, 1BH            ; Escape
        JE EXIT_PROGRAM
    
        ; Ordinary characters must not be interpreted as arrow keys.
        CMP AL, 00H
        JE CHECK_ARROW
        CMP AL, 0E0H           ; Also accept the extended-key prefix
        JNE READ_KEY
    
    CHECK_ARROW:
        MOV DH, PLAYER_ROW     ; Candidate position, not committed yet
        MOV DL, PLAYER_COL
        CMP AH, 48H            ; Up arrow
        JE MOVE_UP
        CMP AH, 50H            ; Down arrow
        JE MOVE_DOWN
        CMP AH, 4BH            ; Left arrow
        JE MOVE_LEFT
        CMP AH, 4DH            ; Right arrow
        JE MOVE_RIGHT
        JMP READ_KEY
    
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
    
    CHECK_MOVE:
        ; Unsigned comparisons also reject underflow (0 - 1 = 255).
        CMP DH, MAZE_ROWS
        JAE READ_KEY
        CMP DL, MAZE_COLS
        JAE READ_KEY
    
        ; Offset = row * MAZE_COLS + column.
        ; Byte MUL changes AX only, leaving candidate DH:DL intact.
        MOV AL, DH
        MOV BL, MAZE_COLS
        MUL BL
        XOR BX, BX
        MOV BL, DL
        ADD AX, BX
        MOV SI, AX
        CMP BYTE PTR MAZE[SI], '#'
        JE READ_KEY            ; Wall: keep the old position
    
        MOV PLAYER_ROW, DH     ; Valid path: commit the new position
        MOV PLAYER_COL, DL
        CALL DRAW_MAZE         ; Redraw paths, then the current player
        JMP READ_KEY
    
    EXIT_PROGRAM:
        MOV AX, 0003H          ; Clear screen and restore visible cursor
        INT 10H
        MOV AX, 4C00H          ; DOS: terminate with exit code 0
        INT 21H
    MAIN ENDP
    
    DRAW_MAZE PROC NEAR
        PUSH AX
        PUSH BX
        PUSH CX
        PUSH DX
        PUSH SI
        PUSH BP
    
        XOR SI, SI
        MOV DH, MAZE_TOP
        MOV BP, MAZE_ROWS
    DRAW_ROW:
        XOR DL, DL
        MOV AH, 02H            ; BIOS: cursor at the start of this row
        XOR BH, BH             ; Video page 0
        INT 10H
        MOV CX, MAZE_COLS
    DRAW_CELL:
        MOV AL, MAZE[SI]
        MOV AH, 0EH            ; BIOS: write character, advance cursor
        MOV BX, 0007H
        INT 10H
        INC SI
        LOOP DRAW_CELL
        INC DH
        DEC BP
        JNZ DRAW_ROW
    
        MOV DH, PLAYER_ROW
        ADD DH, MAZE_TOP
        MOV DL, PLAYER_COL
        MOV AH, 02H
        XOR BH, BH
        INT 10H
    
        MOV AL, '@'
        MOV AH, 09H            ; BIOS: write character and attribute
        MOV BX, 000EH          ; Page 0, yellow on black
        MOV CX, 1
        INT 10H
    
        POP BP
        POP SI
        POP DX
        POP CX
        POP BX
        POP AX
        RET
    DRAW_MAZE ENDP
    
    END MAIN
    POP AX
    RET
DRAW_MAZE ENDP

END MAIN
