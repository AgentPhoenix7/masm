; Study notes: two players controlled by held keyboard keys.
; The hardware keyboard ISR records presses/releases; the foreground loop samples
; them every two BIOS ticks, moves P1 then P2, and redraws successful changes.
; Movement is sequential within a frame, so the second player sees P1's new cell.
; Successful steps use 32-bit counters, updated with 16-bit ADD/ADC instructions.
;
; 8086 / MASM / DOS: two players with simultaneous held-key movement.
; P1: @, WASD.  P2: &, IJKL (I up, J left, K down, L right).  Esc exits.
; Steps count successful moves only; walls and players block movement.
; Build: MASM MAZE4.ASM; then LINK MAZE4.OBJ;

; Restrict assembly to 8086 instructions; this directive emits no game action.
.8086
; SMALL selects one code segment and one data group. AX/BX/CX/DX are
; 16-bit registers; AH/AL etc. name their high/low bytes. H marks hexadecimal.
.MODEL SMALL
; Reserve 200H=512 bytes for foreground calls and interrupt register saves.
.STACK 200H

MAZE_ROWS EQU 9
MAZE_COLS EQU 20
MAZE_TOP  EQU 4
MOVE_TICKS EQU 2           ; One movement frame per two BIOS timer ticks

; Begin data declarations. DB/DW/DD allocate bytes/words/doublewords; DUP
; repeats an item. EQU constants allocate no storage. Offsets are relative to DS.
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
    ; Each player has a four-byte unsigned step count, accessed as two words.
    STEPS DD 0,0          ; Two 32-bit counters, updated using 16-bit math
    ; KEY_STATE tracks held keys; KEY_PENDING separately retains quick presses.
    ; CONTROLS maps the four direction priorities to physical keyboard scan codes.
    KEY_STATE DB 128 DUP (0)
    KEY_PENDING DB 128 DUP (0) ; Preserve quick taps until a frame uses them
    ; Scan codes in up, down, left, right order for each player.
    CONTROLS DB 11H,1FH,1EH,20H, 17H,25H,24H,26H
    OLD_INT9 DD ?
    LAST_TICK DW ?
    CHANGED DB 0

; Begin executable code. CALL saves a return address on SS:SP; RET resumes
; after that call. PROC/ENDP are assembler declarations, not run-time actions.
.CODE
MAIN PROC
    ; Initialize DS through AX and CLD for forward LODSB/string operations.
    ; Set 80x25 text mode, hide the cursor, print help, and draw the initial frame.
    ; DOS service 3509H obtains the old INT 09H vector as ES:BX; keep both words.
    ; To install code with 2509H, temporarily make DS=CS so DS:DX names the ISR.
    ; Restore the data DS afterward; BIOS INT 1AH supplies the initial tick count.
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
    ; Recognize held or quickly tapped Escape. Compare unsigned low-word tick
    ; difference against MOVE_TICKS; subtraction tolerates a 16-bit timer wrap.
    ; CLI protects the short key-consumption/game-update region from IRQ1 changes.
    ; STI re-enables interrupts before any BIOS rendering; redraw only if CHANGED.
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
    ; STI/HLT sleeps until a hardware interrupt instead of continuously spinning.
    ; The timer or a keyboard IRQ wakes the loop to check for the next frame.
    STI
    HLT                   ; Wake on a timer or keyboard interrupt
    JMP WAIT_FRAME

EXIT_PROGRAM:
    ; Restore the saved INT 09H vector before terminating so DOS regains normal
    ; keyboard handling. LDS loads both DS and DX; preserve the game DS around it.
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
    ; IRQ1 can interrupt foreground code at any point. Save AX/BX/DS, read port
    ; 60H, pulse bit 7 of port 61H to acknowledge, then load the game data segment.
    ; Ignore prefix bytes; bit 7 distinguishes make (press) from break (release).
    ; This ISR owns the interrupt rather than chaining the old BIOS handler.
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
    ; Mask the release bit to form the 0..127 scan-code index. AH is 1 for
    ; pressed or 0 for released. A new press increments its pending count, with
    ; saturation at FFH; typematic repeats do not create extra pending presses.
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
    ; Always save current held state. Release leaves pending presses intact,
    ; so a tap between foreground frames is still available for one movement.
    MOV KEY_STATE[BX], AH
IRQ_DONE:
    ; Send 20H (end-of-interrupt) to the master PIC, restore registers and IRET.
    ; IRET restores interrupted flags as well as CS:IP; ordinary RET would not.
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
    ; SI selects player 0 or 1. Four scan codes per player mean table offset
    ; 4*SI. BP numbers directions in priority order up/down/left/right.
    MOV BX, SI
    SHL BX, 1
    SHL BX, 1             ; Four control scan codes per player
    XOR BP, BP
    MOV CX, 4
FIND_DIRECTION:
    ; Inspect a pending press before held state. The first matching direction
    ; wins; if all four are inactive, return without modifying the player.
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
    ; Consume one pending press even if collision validation later blocks it;
    ; otherwise a blocked quick tap would remain queued indefinitely.
    CMP KEY_PENDING[DI], 0
    JE GET_POSITION
    DEC KEY_PENDING[DI]   ; Consume one press, even when a wall blocks it
GET_POSITION:
    ; Load a candidate into DH/DL, then change exactly one coordinate using BP.
    ; BP=3 is right, handled by the default INC DL path.
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
    ; Decrease the candidate row and branch to common collision validation.
    DEC DH
    JMP CHECK_MOVE
MOVE_DOWN:
    ; Increase the candidate row and branch to common collision validation.
    INC DH
    JMP CHECK_MOVE
MOVE_LEFT:
    ; Decrease the candidate column, then fall through into collision validation.
    DEC DL

CHECK_MOVE:
    ; Reject unsigned out-of-bounds coordinates and wall cells using the flattened
    ; row*MAZE_COLS+column index. XOR BX,1 selects the other player (0<->1);
    ; block only if both row and column match that player's current position.
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
    ; Commit the candidate coordinates. DD counters occupy four bytes, so index
    ; STEPS at 4*SI. ADD increments the low word; ADC propagates its carry into
    ; the high word. Mark CHANGED so the foreground loop will repaint the screen.
    MOV PLAYER_ROWS[SI], DH
    MOV PLAYER_COLS[SI], DL
    MOV BX, SI
    SHL BX, 1
    SHL BX, 1
    ADD WORD PTR STEPS[BX], 1
    ADC WORD PTR STEPS[BX+2], 0
    MOV CHANGED, 1
MOVE_DONE:
    ; Return without rendering; the foreground draws both players together.
    RET
MOVE_PLAYER ENDP

DRAW_SCREEN PROC NEAR
    ; Save working registers. Position the BIOS cursor for each status line,
    ; print its zero-terminated label and 32-bit step count, then repaint the map.
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
    ; DH is the screen row and SI the next map byte. BP counts maze rows.
    XOR DL, DL
    MOV CX, MAZE_COLS
DRAW_CELL:
    ; Save the loop count because BIOS service 09H needs CX=1. Position each
    ; cell explicitly; service 09H does not advance the cursor. Repaint the map
    ; before overlaying yellow @ and cyan &, removing obsolete player markers.
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
    MOV CX, 10            ; Erase any leftover counter text
PRINT_PADDING:
    ; Write ten spaces after the counter to erase stale characters from an
    ; earlier display, then restore the caller's saved registers.
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

; Close the source module and select MAIN as its executable entry point.
END MAIN
