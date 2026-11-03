; 8086 / MASM / DOS: two players with simultaneous held-key movement.
; P1: @, WASD.  P2: &, IJKL (I up, J left, K down, L right).  Esc exits.
; Steps count successful moves only; walls and players block movement.
; Build: MASM MAZE4.ASM; then LINK MAZE4.OBJ;

.8086
.MODEL SMALL
.STACK 200H

MAZE_ROWS EQU 9
MAZE_COLS EQU 20
MAZE_TOP  EQU 4
MOVE_TICKS EQU 2           ; One movement frame per two BIOS timer ticks

.DATA
    TITLE_TEXT DB 'TWO-PLAYER MAZE - Esc exits.',13,10,'$'
    P1_TEXT DB 'P1 @ (WASD)   Steps: ',0
    P2_TEXT DB 'P2 & (IJKL)   Steps: ',0

    MAZE DB '####################'
         DB '#     #            #'
         DB '# ### # #### ##### #'
         DB '# #   #    #     # #'
         DB '# # ###### # ### # #'
         DB '# #        # #   # #'
         DB '# ########## # ### #'
         DB '#                  #'
         DB '####################'

    PLAYER_ROWS DB 1,7
    PLAYER_COLS DB 1,18
    STEPS DD 0,0          ; Two 32-bit counters, updated using 16-bit math
    KEY_STATE DB 128 DUP (0)
    KEY_PENDING DB 128 DUP (0) ; Preserve quick taps until a frame uses them
    ; Scan codes in up, down, left, right order for each player.
    CONTROLS DB 11H,1FH,1EH,20H, 17H,25H,24H,26H
    OLD_INT9 DD ?
    LAST_TICK DW ?
    CHANGED DB 0

.CODE
MAIN PROC
    MOV AX, @DATA
    MOV DS, AX
    CLD

    MOV AX, 0003H         ; Clear screen, select 80x25 text mode
    INT 10H
    MOV AH, 01H           ; Hide the blinking cursor
    MOV CX, 2000H
    INT 10H
    LEA DX, TITLE_TEXT
    MOV AH, 09H
    INT 21H
    CALL DRAW_SCREEN

    ; Save the previous hardware keyboard interrupt handler.
    MOV AX, 3509H
    INT 21H               ; ES:BX = old INT 09h vector
    MOV WORD PTR OLD_INT9, BX
    MOV AX, ES
    MOV WORD PTR OLD_INT9+2, AX

    ; Install our handler using DS:DX = CS:KEYBOARD_ISR.
    PUSH DS
    PUSH CS
    POP DS
    MOV DX, OFFSET KEYBOARD_ISR
    MOV AX, 2509H
    INT 21H
    POP DS

    MOV AH, 00H
    INT 1AH               ; CX:DX = BIOS tick count
    MOV LAST_TICK, DX

WAIT_FRAME:
    CMP KEY_STATE[01H], 0 ; Esc held?
    JNE EXIT_PROGRAM
    CMP KEY_PENDING[01H], 0 ; A quick Esc tap must also be recognized
    JNE EXIT_PROGRAM
    MOV AH, 00H
    INT 1AH
    MOV AX, DX
    SUB AX, LAST_TICK      ; Unsigned subtraction handles low-word wrap
    CMP AX, MOVE_TICKS
    JB IDLE_WAIT
    MOV LAST_TICK, DX

    ; Read both players' held keys and update positions in one frame.
    ; Interrupts are disabled briefly; no BIOS/DOS calls occur here.
    CLI
    MOV CHANGED, 0
    XOR SI, SI            ; Player 1 index = 0
    CALL MOVE_PLAYER
    INC SI                ; Player 2 index = 1
    CALL MOVE_PLAYER
    STI
    CMP CHANGED, 0
    JE IDLE_WAIT
    CALL DRAW_SCREEN      ; Show both positions and counters together

IDLE_WAIT:
    STI
    HLT                   ; Wake on a timer or keyboard interrupt
    JMP WAIT_FRAME

EXIT_PROGRAM:
    ; Always restore the original keyboard handler before returning to DOS.
    PUSH DS
    LDS DX, OLD_INT9
    MOV AX, 2509H
    INT 21H
    POP DS
    MOV AX, 0003H         ; Restore a clear screen and visible cursor
    INT 10H
    MOV AX, 4C00H
    INT 21H
MAIN ENDP

; IRQ1 / INT 09h: record make (press) and break (release) scan codes.
; BIOS INT 16h alone cannot tell us which two keys are held together.
; This handler owns IRQ1 while the game runs; it does not call DOS.
KEYBOARD_ISR PROC FAR
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
    MOV KEY_STATE[BX], AH
IRQ_DONE:
    MOV AL, 20H           ; End of interrupt to the master PIC
    OUT 20H, AL
    POP DS
    POP BX
    POP AX
    IRET
KEYBOARD_ISR ENDP

; SI = player index (0 or 1). At most one move per player per frame.
; If several directions are held, priority is up, down, left, right.
MOVE_PLAYER PROC NEAR
    MOV BX, SI
    SHL BX, 1
    SHL BX, 1             ; Four control scan codes per player
    XOR BP, BP
    MOV CX, 4
FIND_DIRECTION:
    XOR AX, AX
    MOV AL, CONTROLS[BX]
    MOV DI, AX
    CMP KEY_PENDING[DI], 0
    JNE HAVE_DIRECTION
    CMP KEY_STATE[DI], 0
    JNE HAVE_DIRECTION
    INC BX
    INC BP
    LOOP FIND_DIRECTION
    RET

HAVE_DIRECTION:
    CMP KEY_PENDING[DI], 0
    JE GET_POSITION
    DEC KEY_PENDING[DI]   ; Consume one press, even when a wall blocks it
GET_POSITION:
    MOV DH, PLAYER_ROWS[SI]
    MOV DL, PLAYER_COLS[SI]
    CMP BP, 0
    JE MOVE_UP
    CMP BP, 1
    JE MOVE_DOWN
    CMP BP, 2
    JE MOVE_LEFT
    INC DL
    JMP CHECK_MOVE
MOVE_UP:
    DEC DH
    JMP CHECK_MOVE
MOVE_DOWN:
    INC DH
    JMP CHECK_MOVE
MOVE_LEFT:
    DEC DL

CHECK_MOVE:
    CMP DH, MAZE_ROWS
    JAE MOVE_DONE
    CMP DL, MAZE_COLS
    JAE MOVE_DONE
    MOV AL, DH
    MOV BL, MAZE_COLS
    MUL BL                ; AX = row * columns; candidate DX is preserved
    XOR BX, BX
    MOV BL, DL
    ADD BX, AX
    CMP BYTE PTR MAZE[BX], '#'
    JE MOVE_DONE

    MOV BX, SI
    XOR BX, 1             ; Index of the other player
    CMP DH, PLAYER_ROWS[BX]
    JNE ACCEPT_MOVE
    CMP DL, PLAYER_COLS[BX]
    JE MOVE_DONE          ; Do not overlap the other player
ACCEPT_MOVE:
    MOV PLAYER_ROWS[SI], DH
    MOV PLAYER_COLS[SI], DL
    MOV BX, SI
    SHL BX, 1
    SHL BX, 1
    ADD WORD PTR STEPS[BX], 1
    ADC WORD PTR STEPS[BX+2], 0
    MOV CHANGED, 1
MOVE_DONE:
    RET
MOVE_PLAYER ENDP

DRAW_SCREEN PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH BP

    MOV DH, 1
    XOR DL, DL
    MOV AH, 02H
    XOR BH, BH
    INT 10H
    LEA SI, P1_TEXT
    CALL PRINT_TEXT
    MOV AX, WORD PTR STEPS
    MOV DX, WORD PTR STEPS+2
    CALL PRINT_NUMBER

    MOV DH, 2
    XOR DL, DL
    MOV AH, 02H
    XOR BH, BH
    INT 10H
    LEA SI, P2_TEXT
    CALL PRINT_TEXT
    MOV AX, WORD PTR STEPS+4
    MOV DX, WORD PTR STEPS+6
    CALL PRINT_NUMBER

    XOR SI, SI
    MOV DH, MAZE_TOP
    MOV BP, MAZE_ROWS
DRAW_ROW:
    XOR DL, DL
    MOV CX, MAZE_COLS
DRAW_CELL:
    PUSH CX
    MOV AH, 02H
    XOR BH, BH
    INT 10H
    MOV AL, MAZE[SI]
    MOV AH, 09H
    MOV BX, 0007H         ; White on black, including erased player cells
    MOV CX, 1
    INT 10H
    POP CX
    INC SI
    INC DL
    LOOP DRAW_CELL
    INC DH
    DEC BP
    JNZ DRAW_ROW

    MOV DH, PLAYER_ROWS
    ADD DH, MAZE_TOP
    MOV DL, PLAYER_COLS
    MOV AH, 02H
    XOR BH, BH
    INT 10H
    MOV AL, '@'
    MOV AH, 09H
    MOV BX, 000EH         ; Player 1: yellow
    MOV CX, 1
    INT 10H

    MOV DH, PLAYER_ROWS+1
    ADD DH, MAZE_TOP
    MOV DL, PLAYER_COLS+1
    MOV AH, 02H
    XOR BH, BH
    INT 10H
    MOV AL, '&'
    MOV AH, 09H
    MOV BX, 000BH         ; Player 2: cyan
    MOV CX, 1
    INT 10H

    POP BP
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
DRAW_SCREEN ENDP

; DS:SI points to a zero-terminated string.
PRINT_TEXT PROC NEAR
    PUSH AX
    PUSH BX
    PUSH SI
PRINT_NEXT:
    LODSB
    OR AL, AL
    JZ TEXT_DONE
    MOV AH, 0EH
    MOV BX, 0007H
    INT 10H
    JMP PRINT_NEXT
TEXT_DONE:
    POP SI
    POP BX
    POP AX
    RET
PRINT_TEXT ENDP

; Print unsigned DX:AX in decimal using two 16-bit divisions per digit.
PRINT_NUMBER PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    MOV BX, 10
    XOR CX, CX
DIVIDE_DIGIT:
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
    POP AX
    ADD AL, '0'
    MOV AH, 0EH
    MOV BX, 0007H
    INT 10H
    LOOP PRINT_DIGIT
    MOV CX, 10            ; Erase any leftover counter text
PRINT_PADDING:
    MOV AX, 0E20H
    MOV BX, 0007H
    INT 10H
    LOOP PRINT_PADDING
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_NUMBER ENDP

END MAIN
