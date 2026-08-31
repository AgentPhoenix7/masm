; Question 1
; Transform ten user-entered bytes at DS:3000H using (value * 5) + 10,
; then transfer the results to DS:4000H.

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    Q1_TITLE DB 13,10,'QUESTION 1 - TRANSFORMED BLOCK TRANSFER',13,10,'$'
    Q1_FORMULA DB 'Formula applied to every byte: (value * 5) + 10',13,10,'$'
    Q1_PROMPT DB 'Enter byte $'
    Q1_PROMPT_TAIL DB ' (0-255): $'
    Q1_BAD_INPUT DB 'ERROR: input must be a decimal number from 0 through 255.',13,10,'$'
    Q1_SOURCE_LABEL DB 'DS:3000H (input)  = $'
    Q1_DEST_LABEL DB 'DS:4000H (output) = $'

    ORG 3000H
SOURCE_BYTES DB 10 DUP (?)

    ORG 4000H
DEST_BYTES DB 10 DUP (00H)
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    MOV AX, DATASEG
    MOV DS, AX

    LEA DX, Q1_TITLE
    CALL PRINT_DOS
    LEA DX, Q1_FORMULA
    CALL PRINT_DOS

    MOV DI, 3000H
    MOV CX, 10
    MOV BX, 1
Q1_INPUT:
    LEA DX, Q1_PROMPT
    CALL PRINT_DOS
    MOV AX, BX
    CALL PRINT_UINT
    LEA DX, Q1_PROMPT_TAIL
    CALL PRINT_DOS
    CALL READ_UINT8
    JC Q1_BAD_EXIT
    CALL PRINT_CRLF
    MOV [DI], AL
    INC DI
    INC BX
    LOOP Q1_INPUT

    LEA DX, Q1_SOURCE_LABEL
    MOV SI, 3000H
    MOV CX, 10
    CALL DISPLAY_ARRAY

    MOV SI, 3000H
    MOV DI, 4000H
    MOV CX, 10
Q1_TRANSFER:
    MOV AL, [SI]
    MOV BL, 5
    MUL BL
    ADD AX, 10
    MOV [DI], AL
    INC SI
    INC DI
    LOOP Q1_TRANSFER

    LEA DX, Q1_DEST_LABEL
    MOV SI, 4000H
    MOV CX, 10
    CALL DISPLAY_ARRAY

    MOV AX, 4C00H
    INT 21H

Q1_BAD_EXIT:
    CALL PRINT_CRLF
    LEA DX, Q1_BAD_INPUT
    CALL PRINT_DOS
    MOV AX, 4C01H
    INT 21H

; Prints a labelled byte array: DX = label offset, SI = array offset, CX = count.
DISPLAY_ARRAY PROC NEAR
    CALL PRINT_DOS
    CALL PRINT_HEX_ARRAY
    CALL PRINT_CRLF
    RET
DISPLAY_ARRAY ENDP

; Reads a line containing an unsigned decimal number in the range 0..255.
; Returns AX = value and CF clear, or CF set for invalid input.
READ_UINT8 PROC NEAR
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    XOR BX, BX
    XOR SI, SI
RU_READ:
    MOV AH, 01H
    INT 21H
    CMP AL, 13
    JE RU_FINISH
    CMP AL, 10
    JNE RU_DIGIT
    ; A redirected DOS text file uses CR/LF.  The preceding call consumes
    ; CR, so ignore its remaining LF before reading the next number.
    OR SI, SI
    JZ RU_READ
    JMP SHORT RU_FINISH
RU_DIGIT:
    CMP AL, '0'
    JB RU_BAD
    CMP AL, '9'
    JA RU_BAD
    MOV DL, AL
    SUB DL, '0'
    XOR DH, DH
    MOV AX, BX
    SHL AX, 1
    MOV CX, AX
    SHL AX, 1
    SHL AX, 1
    ADD AX, CX
    ADD AX, DX
    CMP AX, 255
    JA RU_BAD
    MOV BX, AX
    INC SI
    JMP SHORT RU_READ
RU_FINISH:
    OR SI, SI
    JZ RU_INVALID
    MOV AX, BX
    CLC
    JMP SHORT RU_RETURN
RU_BAD:
    CMP AL, 13
    JE RU_INVALID
    CMP AL, 10
    JE RU_INVALID
RU_CONSUME:
    MOV AH, 01H
    INT 21H
    CMP AL, 13
    JE RU_INVALID
    CMP AL, 10
    JNE RU_CONSUME
RU_INVALID:
    STC
RU_RETURN:
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_UINT8 ENDP

    INCLUDE COMMON.INC
CODESEG ENDS
END START
