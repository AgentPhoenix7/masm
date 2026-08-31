; Question 1 - beginner version
; Read 10 bytes, calculate (value * 5) + 10, and transfer the results.

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    TITLE_TEXT  DB 13,10,'QUESTION 1 - BLOCK TRANSFER',13,10,'$'
    PROMPT_TEXT DB 'Enter a byte (0-255): $'
    OUTPUT_TEXT DB 'Output: $'
    ERROR_TEXT  DB 'ERROR: enter a decimal number from 0 to 255.$'
    NEWLINE     DB 13,10,'$'

    ; DOS input buffer: maximum length, actual length, typed characters.
    INPUT_BUFFER DB 4,0,5 DUP (0)

    ORG 3000H
SOURCE_BYTES DB 10 DUP (?)

    ORG 4000H
DEST_BYTES DB 10 DUP (0)
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    MOV AX, DATASEG
    MOV DS, AX

    LEA DX, TITLE_TEXT
    CALL PRINT_STRING

    ; Read 10 decimal byte values into DS:3000H.
    MOV DI, 3000H
    MOV CX, 10

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

    ; This is the main part required by the question.
    MOV SI, 3000H
    MOV DI, 4000H
    MOV CX, 10

TRANSFER_LOOP:
    MOV AL, [SI]
    MOV BL, 5
    MUL BL
    ADD AX, 10
    MOV [DI], AL

    INC SI
    INC DI
    LOOP TRANSFER_LOOP

    ; Print the bytes stored at DS:4000H.
    LEA DX, OUTPUT_TEXT
    CALL PRINT_STRING
    MOV SI, 4000H
    MOV CX, 10

OUTPUT_LOOP:
    XOR AX, AX
    MOV AL, [SI]
    CALL PRINT_BYTE

    MOV DL, ' '
    MOV AH, 02H
    INT 21H

    INC SI
    LOOP OUTPUT_LOOP
    CALL PRINT_NEWLINE
    JMP EXIT_OK

BAD_INPUT:
    LEA DX, ERROR_TEXT
    CALL PRINT_STRING
    CALL PRINT_NEWLINE
    MOV AX, 4C01H
    INT 21H

EXIT_OK:
    MOV AX, 4C00H
    INT 21H

; Read one decimal number from 0 through 255.
; Return: AL = byte and CF = 0, or CF = 1 for invalid input.
READ_BYTE PROC NEAR
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    MOV CL, INPUT_BUFFER[1]
    XOR CH, CH
    JCXZ RB_INVALID
    CMP CX, 3
    JA RB_INVALID

    LEA SI, INPUT_BUFFER[2]
    XOR BX, BX

RB_NEXT_DIGIT:
    MOV AL, [SI]
    CMP AL, '0'
    JB RB_INVALID
    CMP AL, '9'
    JA RB_INVALID

    MOV DL, AL
    SUB DL, '0'
    XOR DH, DH

    ; New value = old value * 10 + new digit.
    MOV AX, BX
    SHL AX, 1
    MOV BX, AX
    SHL AX, 1
    SHL AX, 1
    ADD AX, BX
    ADD AX, DX

    CMP AX, 255
    JA RB_INVALID
    MOV BX, AX
    INC SI
    LOOP RB_NEXT_DIGIT

    MOV AX, BX
    CLC
    JMP SHORT RB_RETURN

RB_INVALID:
    STC

RB_RETURN:
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_BYTE ENDP

; Print the unsigned byte in AX as decimal.
PRINT_BYTE PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    XOR CX, CX
    MOV BX, 10

PB_DIVIDE:
    XOR DX, DX
    DIV BX
    PUSH DX
    INC CX
    OR AX, AX
    JNZ PB_DIVIDE

PB_PRINT:
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PB_PRINT

    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_BYTE ENDP

PRINT_STRING PROC NEAR
    MOV AH, 09H
    INT 21H
    RET
PRINT_STRING ENDP

PRINT_NEWLINE PROC NEAR
    LEA DX, NEWLINE
    CALL PRINT_STRING
    RET
PRINT_NEWLINE ENDP

CODESEG ENDS
END START
