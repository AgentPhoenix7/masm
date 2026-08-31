; Question 2
; Read twenty decimal bytes at DS:4000H and rearrange them so that
; a[0] < a[1] > a[2] < a[3] > ...

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    Q2_TITLE      DB 13,10,'QUESTION 2 - 20-BYTE ZIG-ZAG ARRAY',13,10,'$'
    PROMPT_TEXT   DB 'Enter decimal byte (0-255): $'
    BAD_TEXT      DB 'Invalid input. Enter a value from 0 to 255.',13,10,'$'
    ORIGINAL_TEXT DB 'Original array: $'
    ZIGZAG_TEXT   DB 'Zig-zag array:  $'

    ; DOS function 0AH buffer: maximum length, actual length, characters.
    ; Empirically verified against this authentic DOSBox 0.74-3 / MASM 5.10
    ; environment (isolated minimal-repro test, not just this program):
    ; typing exactly maxlen characters never returns from INT 21H/AH=0AH
    ; here, even after extra Enter presses and multi-second waits, while
    ; entering fewer than maxlen characters completes normally. Valid input
    ; is 1-3 decimal digits, so maxlen=6 leaves generous headroom (+3 over
    ; the longest valid input), matching Q4's identical INPUT_BUFFER. The
    ; char area is sized maxlen+1 (7) to also hold the CR DOS writes after
    ; the typed characters.
    INPUT_BUFFER  DB 6,0,7 DUP (0)

    ORG 4000H
ZIGZAG_ARRAY DB 20 DUP (0)
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    MOV AX, DATASEG
    MOV DS, AX

    LEA DX, Q2_TITLE
    CALL PRINT_STRING

    ; Read the twenty values directly into DS:4000H.
    MOV DI, 4000H
    MOV CX, 20
INPUT_LOOP:
    LEA DX, PROMPT_TEXT
    CALL PRINT_STRING
    CALL READ_BYTE
    JNC INPUT_OK
    JMP BAD_INPUT
INPUT_OK:
    MOV [DI], AL
    INC DI
    CALL PRINT_NEWLINE
    LOOP INPUT_LOOP
    JMP SHORT SHOW_ORIGINAL
BAD_INPUT:
    CALL PRINT_NEWLINE
    LEA DX, BAD_TEXT
    CALL PRINT_STRING
    JMP INPUT_LOOP

SHOW_ORIGINAL:
    LEA DX, ORIGINAL_TEXT
    CALL PRINT_STRING
    MOV SI, 4000H
    CALL PRINT_ARRAY
    CALL PRINT_NEWLINE

    ; Main assignment algorithm: make each adjacent pair alternate.
    MOV SI, 4000H
    MOV CX, 19
    XOR BL, BL
ZIGZAG_LOOP:
    MOV AL, [SI]
    MOV AH, [SI+1]
    TEST BL, 1
    JNZ WANT_GREATER
    CMP AL, AH
    JB PAIR_OK
    JMP SHORT SWAP_PAIR
WANT_GREATER:
    CMP AL, AH
    JA PAIR_OK
SWAP_PAIR:
    MOV [SI], AH
    MOV [SI+1], AL
PAIR_OK:
    INC SI
    INC BL
    LOOP ZIGZAG_LOOP

    LEA DX, ZIGZAG_TEXT
    CALL PRINT_STRING
    MOV SI, 4000H
    CALL PRINT_ARRAY
    CALL PRINT_NEWLINE

    MOV AX, 4C00H
    INT 21H

; Print the dollar-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    PUSH AX
    PUSH CX
    PUSH DX
    MOV AH, 09H
    INT 21H
    POP DX
    POP CX
    POP AX
    RET
PRINT_STRING ENDP

; Print a carriage return and line feed.
PRINT_NEWLINE PROC NEAR
    PUSH AX
    PUSH CX
    PUSH DX
    MOV DL, 13
    MOV AH, 02H
    INT 21H
    MOV DL, 10
    MOV AH, 02H
    INT 21H
    POP DX
    POP CX
    POP AX
    RET
PRINT_NEWLINE ENDP

; Read one decimal byte with DOS buffered keyboard input.
; Returns: AX = value and CF clear, or CF set for invalid input.
; Preserves: BX, CX, DX, SI, and DI.
READ_BYTE PROC NEAR
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI

    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    XOR CX, CX
    MOV CL, INPUT_BUFFER+1
    OR CX, CX
    JZ READ_BAD
    CMP CX, 3
    JA READ_BAD

    LEA SI, INPUT_BUFFER+2
    XOR BX, BX
READ_DIGIT:
    MOV DL, [SI]
    CMP DL, '0'
    JB READ_BAD
    CMP DL, '9'
    JA READ_BAD
    SUB DL, '0'
    XOR DH, DH
    MOV DI, DX

    MOV AX, BX
    MOV DX, 10
    MUL DX
    ADD AX, DI
    CMP AX, 255
    JA READ_BAD
    MOV BX, AX

    INC SI
    LOOP READ_DIGIT
    MOV AX, BX
    CLC
    JMP SHORT READ_DONE
READ_BAD:
    STC
READ_DONE:
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_BYTE ENDP

; Print the unsigned byte in AL as decimal.
PRINT_BYTE PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    XOR AH, AH
    MOV BX, 10
    XOR CX, CX
PRINT_DIVIDE:
    XOR DX, DX
    DIV BX
    PUSH DX
    INC CX
    OR AX, AX
    JNZ PRINT_DIVIDE
PRINT_DIGIT:
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PRINT_DIGIT

    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_BYTE ENDP

; Print exactly twenty decimal bytes starting at DS:SI.
PRINT_ARRAY PROC NEAR
    PUSH AX
    PUSH CX
    PUSH DX
    PUSH SI

    MOV CX, 20
PRINT_ARRAY_NEXT:
    MOV AL, [SI]
    CALL PRINT_BYTE
    MOV DL, ' '
    MOV AH, 02H
    INT 21H
    INC SI
    LOOP PRINT_ARRAY_NEXT

    POP SI
    POP DX
    POP CX
    POP AX
    RET
PRINT_ARRAY ENDP

CODESEG ENDS
END START
