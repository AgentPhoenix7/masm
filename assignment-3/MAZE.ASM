; Study notes: single-player maze movement and BIOS text output.
; Flow: initialize DS/video -> draw maze -> read an arrow key -> propose a cell ->
; reject bounds/walls or commit it -> redraw -> restore text mode on Escape.
; Existing-source note: a second copy of the program begins inside DRAW_MAZE,
; after POP BX, and includes another MAIN and END MAIN. It is preserved here;
; these comments describe the intended routines, not a claim that this file builds.
;
; 8086 / MASM / DOS: navigate a maze using the arrow keys.
; Build: MASM MAZE.ASM; then LINK MAZE.OBJ;
; Run: MAZE.  Press Esc to exit.

; Restrict assembly to 8086 instructions; this directive emits no game action.
.8086
; SMALL selects one code segment and one data group. AX/BX/CX/DX are
; 16-bit registers; AH/AL etc. name their high/low bytes. H marks hexadecimal.
.MODEL SMALL
; Reserve 100H=256 CPU-stack bytes for saved registers and return addresses.
.STACK 100H

; The map is nine rows of twenty bytes. MAZE_TOP adds the screen-row offset.
MAZE_ROWS EQU 9
MAZE_COLS EQU 20
MAZE_TOP  EQU 3             ; First maze row on the screen (zero-based)

; Begin data declarations. DB/DW/DD allocate bytes/words/doublewords; DUP
; repeats an item. EQU constants allocate no storage. Offsets are relative to DS.
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

; Begin executable code. CALL saves a return address on SS:SP; RET resumes
; after that call. PROC/ENDP are assembler declarations, not run-time actions.
.CODE
MAIN PROC
    ; Load @DATA via AX into DS: MOV cannot load DS directly from an immediate.
    ; DOS initially points DS at the program segment prefix, not this data group.
    ; BIOS mode 0003H clears an 80x25 text screen; cursor shape 2000H hides it.
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
    ; BIOS INT 16H/AH=00H waits without echo: AL is ASCII, AH is scan code.
    ; Escape exits. Accept arrow scan codes only when AL indicates an extended key,
    ; so ordinary letters with the same scan code are not misread as movement.
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
    ; Copy the current coordinates into candidate DH=row, DL=column. Compare
    ; AH against arrow scan codes and change only this candidate until validated.
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
    ; Decrease the candidate row by one; common validation decides if it is legal.
    DEC DH
    JMP CHECK_MOVE
MOVE_DOWN:
    ; Increase the candidate row, leaving the column unchanged.
    INC DH
    JMP CHECK_MOVE
MOVE_LEFT:
    ; Decrease the candidate column; byte underflow will be rejected below.
    DEC DL
    JMP CHECK_MOVE
MOVE_RIGHT:
    ; Increase the candidate column and fall through into common validation.
    INC DL

CHECK_MOVE:
    ; CMP sets flags without changing coordinates. Unsigned JAE rejects a row
    ; or column at/above the dimension, including FFH produced by decrementing zero.
    ; Flatten (row,column) into row*20+column to inspect the one-byte map cell.
    ; MUL BL writes AX; adding a zero-extended column produces the map index SI.
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
    ; Resetting video mode restores a clear screen/visible cursor. DOS INT 21H
    ; with AH=4CH terminates and AL=0 returns success status.
    MOV AX, 0003H          ; Clear screen and restore visible cursor
    INT 10H
    MOV AX, 4C00H          ; DOS: terminate with exit code 0
    INT 21H
MAIN ENDP

DRAW_MAZE PROC NEAR
    ; Preserve working registers. SI scans the contiguous map, DH tracks the
    ; screen row, BP counts rows, and CX counts columns within each row.
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
    ; Set the BIOS cursor to page 0, column 0 at DH. Maze rows start at
    ; MAZE_TOP rather than at screen row zero, keeping help text above the maze.
    XOR DL, DL
    MOV AH, 02H            ; BIOS: cursor at the start of this row
    XOR BH, BH             ; Video page 0
    INT 10H
    MOV CX, MAZE_COLS
DRAW_CELL:
    ; Print each raw map byte with teletype output; rows have fixed width and
    ; need no terminators. LOOP counts columns; BP/DH then advance through rows.
    ; After the full map, position the cursor at the player's maze coordinates plus
    ; MAZE_TOP, and use BIOS 09H to overlay one yellow @ without advancing the cursor.
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
    
    ; Restrict assembly to 8086 instructions; this directive emits no game action.
    .8086
    ; SMALL selects one code segment and one data group. AX/BX/CX/DX are
    ; 16-bit registers; AH/AL etc. name their high/low bytes. H marks hexadecimal.
    .MODEL SMALL
    ; Reserve 100H=256 CPU-stack bytes for saved registers and return addresses.
    .STACK 100H
    
    ; The map is nine rows of twenty bytes. MAZE_TOP adds the screen-row offset.
    MAZE_ROWS EQU 9
    MAZE_COLS EQU 20
    MAZE_TOP  EQU 3             ; First maze row on the screen (zero-based)
    
    ; Begin data declarations. DB/DW/DD allocate bytes/words/doublewords; DUP
    ; repeats an item. EQU constants allocate no storage. Offsets are relative to DS.
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
    
    ; Begin executable code. CALL saves a return address on SS:SP; RET resumes
    ; after that call. PROC/ENDP are assembler declarations, not run-time actions.
    .CODE
    MAIN PROC
        ; Load @DATA via AX into DS: MOV cannot load DS directly from an immediate.
        ; DOS initially points DS at the program segment prefix, not this data group.
        ; BIOS mode 0003H clears an 80x25 text screen; cursor shape 2000H hides it.
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
        ; BIOS INT 16H/AH=00H waits without echo: AL is ASCII, AH is scan code.
        ; Escape exits. Accept arrow scan codes only when AL indicates an extended key,
        ; so ordinary letters with the same scan code are not misread as movement.
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
        ; Copy the current coordinates into candidate DH=row, DL=column. Compare
        ; AH against arrow scan codes and change only this candidate until validated.
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
        ; Decrease the candidate row by one; common validation decides if it is legal.
        DEC DH
        JMP CHECK_MOVE
    MOVE_DOWN:
        ; Increase the candidate row, leaving the column unchanged.
        INC DH
        JMP CHECK_MOVE
    MOVE_LEFT:
        ; Decrease the candidate column; byte underflow will be rejected below.
        DEC DL
        JMP CHECK_MOVE
    MOVE_RIGHT:
        ; Increase the candidate column and fall through into common validation.
        INC DL
    
    CHECK_MOVE:
        ; CMP sets flags without changing coordinates. Unsigned JAE rejects a row
        ; or column at/above the dimension, including FFH produced by decrementing zero.
        ; Flatten (row,column) into row*20+column to inspect the one-byte map cell.
        ; MUL BL writes AX; adding a zero-extended column produces the map index SI.
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
        ; Resetting video mode restores a clear screen/visible cursor. DOS INT 21H
        ; with AH=4CH terminates and AL=0 returns success status.
        MOV AX, 0003H          ; Clear screen and restore visible cursor
        INT 10H
        MOV AX, 4C00H          ; DOS: terminate with exit code 0
        INT 21H
    MAIN ENDP
    
    DRAW_MAZE PROC NEAR
        ; Preserve working registers. SI scans the contiguous map, DH tracks the
        ; screen row, BP counts rows, and CX counts columns within each row.
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
        ; Set the BIOS cursor to page 0, column 0 at DH. Maze rows start at
        ; MAZE_TOP rather than at screen row zero, keeping help text above the maze.
        XOR DL, DL
        MOV AH, 02H            ; BIOS: cursor at the start of this row
        XOR BH, BH             ; Video page 0
        INT 10H
        MOV CX, MAZE_COLS
    DRAW_CELL:
        ; Print each raw map byte with teletype output; rows have fixed width and
        ; need no terminators. LOOP counts columns; BP/DH then advance through rows.
        ; After the full map, position the cursor at the player's maze coordinates plus
        ; MAZE_TOP, and use BIOS 09H to overlay one yellow @ without advancing the cursor.
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
    
    ; Close the source module and select MAIN as its executable entry point.
    END MAIN
    POP AX
    RET
DRAW_MAZE ENDP

; Close the source module and select MAIN as its executable entry point.
END MAIN
