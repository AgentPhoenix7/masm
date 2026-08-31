; Question 5
; Interactive string operations: length, comparison, and reversal.
; Self-contained: STRLEN, STRCMP, STRREV, and all keyboard/screen I/O
; live in this one file (no INCLUDE, no separate library).

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    Q5_TITLE      DB 13,10,'QUESTION 5 - STRING OPERATIONS',13,10,'$'
    Q5_RANGE      DB 'Enter strings of up to 30 characters.',13,10,'$'
    FIRST_PROMPT  DB 'String 1: $'
    SECOND_PROMPT DB 'String 2: $'
    LEN1_LABEL    DB 'Length of string 1: $'
    LEN2_LABEL    DB 'Length of string 2: $'
    CMP_LABEL     DB 'Comparison: $'
    CMP_LESS      DB 'string 1 is less than string 2',13,10,'$'
    CMP_GREATER   DB 'string 1 is greater than string 2',13,10,'$'
    CMP_EQUAL     DB 'string 1 equals string 2',13,10,'$'
    REV_LABEL     DB 'Reversed string 1: $'

    ; DOS function 0AH buffer: maximum length, actual length, characters.
    ; Empirically verified against this authentic DOSBox 0.74-3 / MASM 5.10
    ; environment (see Q2.ASM/Q3.ASM/Q4.ASM): typing exactly maxlen
    ; characters never returns from INT 21H/AH=0AH here, so maxlen must sit
    ; well above the longest valid entry. Valid input is up to 30 characters,
    ; so maxlen=40 leaves generous headroom (well beyond the roughly-double
    ; margin used for Q4's much shorter fields); the char area is sized
    ; maxlen+1 (41) to also hold the CR DOS writes after the typed characters.
    STRING1_BUFFER DB 40,0,41 DUP (0)
    STRING2_BUFFER DB 40,0,41 DUP (0)

DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    MOV AX, DATASEG
    MOV DS, AX

    LEA DX, Q5_TITLE
    CALL PRINT_STRING
    LEA DX, Q5_RANGE
    CALL PRINT_STRING

    LEA DX, FIRST_PROMPT
    CALL PRINT_STRING
    LEA DX, STRING1_BUFFER
    CALL READ_STRING
    CALL PRINT_NEWLINE

    LEA DX, SECOND_PROMPT
    CALL PRINT_STRING
    LEA DX, STRING2_BUFFER
    CALL READ_STRING
    CALL PRINT_NEWLINE

    ; Length of string 1
    LEA SI, STRING1_BUFFER+2
    CALL STRLEN
    LEA DX, LEN1_LABEL
    CALL PRINT_STRING
    CALL PRINT_UINT
    CALL PRINT_NEWLINE

    ; Length of string 2
    LEA SI, STRING2_BUFFER+2
    CALL STRLEN
    LEA DX, LEN2_LABEL
    CALL PRINT_STRING
    CALL PRINT_UINT
    CALL PRINT_NEWLINE

    ; Comparison
    LEA SI, STRING1_BUFFER+2
    LEA DI, STRING2_BUFFER+2
    CALL STRCMP
    LEA DX, CMP_LABEL
    CALL PRINT_STRING
    CMP AX, 0FFFFH
    JE Q5_LESS
    CMP AX, 0
    JE Q5_EQUAL
    LEA DX, CMP_GREATER
    CALL PRINT_STRING
    JMP SHORT Q5_REVERSE
Q5_LESS:
    LEA DX, CMP_LESS
    CALL PRINT_STRING
    JMP SHORT Q5_REVERSE
Q5_EQUAL:
    LEA DX, CMP_EQUAL
    CALL PRINT_STRING

Q5_REVERSE:
    LEA SI, STRING1_BUFFER+2
    CALL STRREV
    LEA DX, REV_LABEL
    CALL PRINT_STRING
    LEA DX, STRING1_BUFFER+2
    CALL PRINT_Z
    CALL PRINT_NEWLINE

    MOV AX, 4C00H
    INT 21H

; Read a line into the DOS function 0AH buffer whose address is passed in
; DX, then null-terminate it by overwriting the trailing carriage return
; DOS leaves after the typed characters with a zero byte.
; Buffer layout: byte 0 = maxlen, byte 1 = actual typed length (set by
; DOS), bytes 2.. = typed characters. So the character data always starts
; at offset +2 regardless of maxlen; only that leading 2-byte header size
; is fixed, not the maxlen value itself.
; Input:  DX = buffer address (byte 0 already holds maxlen)
; Output: the string starting at [DX+2] is zero-terminated in place.
READ_STRING PROC NEAR
    PUSH AX
    PUSH BX
    PUSH SI

    MOV AH, 0AH
    INT 21H

    MOV SI, DX
    XOR BX, BX
    MOV BL, [SI+1]
    ADD SI, BX
    MOV BYTE PTR [SI+2], 0

    POP SI
    POP BX
    POP AX
    RET
READ_STRING ENDP

; Input:  DS:SI -> zero-terminated string
; Output: AX = character count (terminating zero is not counted)
; SI is preserved.
STRLEN PROC NEAR
    PUSH SI
    XOR AX, AX
SL_NEXT:
    CMP BYTE PTR [SI], 0
    JE SL_DONE
    INC SI
    INC AX
    JMP SHORT SL_NEXT
SL_DONE:
    POP SI
    RET
STRLEN ENDP

; Input:  DS:SI -> first string, DS:DI -> second string
; Output: AX = FFFFH if first < second, 0000H if equal, 0001H if first > second
; SI and DI are preserved.
STRCMP PROC NEAR
    PUSH BX
    PUSH SI
    PUSH DI
SC_NEXT:
    MOV AL, [SI]
    MOV BL, [DI]
    CMP AL, BL
    JB SC_LESS
    JA SC_GREATER
    OR AL, AL
    JZ SC_EQUAL
    INC SI
    INC DI
    JMP SHORT SC_NEXT
SC_LESS:
    MOV AX, 0FFFFH
    JMP SHORT SC_DONE
SC_GREATER:
    MOV AX, 1
    JMP SHORT SC_DONE
SC_EQUAL:
    XOR AX, AX
SC_DONE:
    POP DI
    POP SI
    POP BX
    RET
STRCMP ENDP

; Input:  DS:SI -> writable zero-terminated string
; Output: AX = character count; the string is reversed in place.
; SI is preserved.
STRREV PROC NEAR
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    CALL STRLEN
    MOV DX, AX
    CMP AX, 1
    JBE SR_DONE
    MOV DI, SI
    ADD DI, AX
    DEC DI
    MOV CX, AX
    SHR CX, 1
SR_SWAP:
    MOV AL, [SI]
    MOV AH, [DI]
    MOV [SI], AH
    MOV [DI], AL
    INC SI
    DEC DI
    LOOP SR_SWAP
SR_DONE:
    MOV AX, DX
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    RET
STRREV ENDP

; Print the dollar-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    PUSH AX
    PUSH DX
    MOV AH, 09H
    INT 21H
    POP DX
    POP AX
    RET
PRINT_STRING ENDP

; Print the zero-terminated string at DS:DX by printing each character
; with DOS function 02H until a zero byte is reached. Needed because DOS
; function 09H requires a $-terminated string, but the user-entered and
; reversed strings in this program are zero-terminated.
PRINT_Z PROC NEAR
    PUSH AX
    PUSH DX
    PUSH SI
    MOV SI, DX
PZ_NEXT:
    MOV DL, [SI]
    CMP DL, 0
    JE PZ_DONE
    MOV AH, 02H
    INT 21H
    INC SI
    JMP SHORT PZ_NEXT
PZ_DONE:
    POP SI
    POP DX
    POP AX
    RET
PRINT_Z ENDP

; Print a carriage return and line feed.
PRINT_NEWLINE PROC NEAR
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
PRINT_NEWLINE ENDP

; Print the unsigned 16-bit value in AX as decimal.
PRINT_UINT PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    MOV BX, 10
    XOR CX, CX
PU_DIVIDE:
    XOR DX, DX
    DIV BX
    PUSH DX
    INC CX
    OR AX, AX
    JNZ PU_DIVIDE
PU_DIGIT:
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PU_DIGIT

    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_UINT ENDP

CODESEG ENDS
END START
