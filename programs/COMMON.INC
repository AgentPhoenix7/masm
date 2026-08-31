; Shared DOS display routines for the question programs.
; Compatible with Microsoft MASM 5.10 and the 8086 instruction set.

PRINT_DOS PROC NEAR
    PUSH AX
    MOV AH, 09H
    INT 21H
    POP AX
    RET
PRINT_DOS ENDP

PRINT_CHAR PROC NEAR
    PUSH AX
    MOV AH, 02H
    INT 21H
    POP AX
    RET
PRINT_CHAR ENDP

PRINT_CRLF PROC NEAR
    PUSH AX
    PUSH DX
    MOV DL, 13
    MOV AH, 02H
    INT 21H
    MOV DL, 10
    MOV AH, 02H
    INT 21H
    POP DX
    POP AX
    RET
PRINT_CRLF ENDP

; Input: AL = one hexadecimal nibble (low four bits).
PRINT_HEX_NIBBLE PROC NEAR
    PUSH AX
    PUSH DX
    AND AL, 0FH
    CMP AL, 09H
    JBE PHN_DIGIT
    ADD AL, 07H
PHN_DIGIT:
    ADD AL, '0'
    MOV DL, AL
    MOV AH, 02H
    INT 21H
    POP DX
    POP AX
    RET
PRINT_HEX_NIBBLE ENDP

; Input: AL = byte to print as two hexadecimal digits.
PRINT_HEX_BYTE PROC NEAR
    PUSH AX
    PUSH BX
    MOV BL, AL
    SHR AL, 1
    SHR AL, 1
    SHR AL, 1
    SHR AL, 1
    CALL PRINT_HEX_NIBBLE
    MOV AL, BL
    CALL PRINT_HEX_NIBBLE
    POP BX
    POP AX
    RET
PRINT_HEX_BYTE ENDP

; Input: AX = word to print as four hexadecimal digits.
PRINT_HEX_WORD PROC NEAR
    PUSH AX
    MOV AL, AH
    CALL PRINT_HEX_BYTE
    POP AX
    CALL PRINT_HEX_BYTE
    RET
PRINT_HEX_WORD ENDP

; Input: AX = unsigned word to print in decimal.
PRINT_UINT PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    XOR CX, CX
    MOV BX, 10
    OR AX, AX
    JNZ PU_DIVIDE
    MOV DL, '0'
    MOV AH, 02H
    INT 21H
    JMP SHORT PU_DONE
PU_DIVIDE:
    XOR DX, DX
    DIV BX
    PUSH DX
    INC CX
    OR AX, AX
    JNZ PU_DIVIDE
PU_PRINT:
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PU_PRINT
PU_DONE:
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_UINT ENDP

; Input: DS:SI = byte array, CX = number of bytes.
PRINT_HEX_ARRAY PROC NEAR
    PUSH AX
    PUSH CX
    PUSH DX
    PUSH SI
    JCXZ PHA_DONE
PHA_NEXT:
    MOV AL, [SI]
    CALL PRINT_HEX_BYTE
    MOV DL, ' '
    CALL PRINT_CHAR
    INC SI
    LOOP PHA_NEXT
PHA_DONE:
    POP SI
    POP DX
    POP CX
    POP AX
    RET
PRINT_HEX_ARRAY ENDP

