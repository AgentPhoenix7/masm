; Question 4
; Interactive unsigned 8-bit calculator supporting +, -, * and /.

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    Q4_TITLE      DB 13,10,'QUESTION 4 - BASIC CALCULATOR',13,10,'$'
    Q4_RANGE      DB 'Enter unsigned decimal operands from 0 through 255.',13,10,'$'
    FIRST_PROMPT  DB 'First operand: $'
    OPERATOR_PROMPT DB 'Operator (+, -, *, /): $'
    SECOND_PROMPT DB 'Second operand: $'
    RESULT_LABEL  DB 'Result: $'
    QUOTIENT_LABEL DB 'Quotient: $'
    REMAINDER_LABEL DB '  Remainder: $'
    INVALID_INPUT DB 'ERROR: input must be a decimal number from 0 through 255.',13,10,'$'
    INVALID_OPERATOR DB 'ERROR: unsupported operator.',13,10,'$'
    DIVIDE_ZERO   DB 'ERROR: division by zero.',13,10,'$'

    ; DOS function 0AH buffer: maximum length, actual length, characters.
    ; Empirically verified against this authentic DOSBox 0.74-3 / MASM 5.10
    ; environment (see Q2.ASM/Q3.ASM): typing exactly maxlen characters
    ; never returns from INT 21H/AH=0AH here, so maxlen must sit well above
    ; the longest valid entry. Valid input is 1-3 decimal digits, so
    ; maxlen=6 leaves generous headroom; the char area is sized maxlen+1
    ; (7) to also hold the CR DOS writes after the typed characters.
    INPUT_BUFFER  DB 6,0,7 DUP (0)

    ; Valid input is exactly one character (+, -, *, /). Same rationale as
    ; above: maxlen=4 leaves headroom above the 1-character valid entry, and
    ; the char area is sized maxlen+1 (5) for the trailing CR.
    OPERATOR_BUFFER DB 4,0,5 DUP (0)

OPERAND1 DW 0
OPERAND2 DW 0
OPERATOR DB 0
QUOTIENT DW 0
REMAINDER DW 0
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    MOV AX, DATASEG
    MOV DS, AX

    LEA DX, Q4_TITLE
    CALL PRINT_STRING
    LEA DX, Q4_RANGE
    CALL PRINT_STRING

    LEA DX, FIRST_PROMPT
    CALL PRINT_STRING
    CALL READ_BYTE
    JNC FIRST_OK
    JMP BAD_INPUT
FIRST_OK:
    XOR AH, AH
    MOV OPERAND1, AX
    CALL PRINT_NEWLINE

    LEA DX, OPERATOR_PROMPT
    CALL PRINT_STRING
    CALL READ_OPERATOR
    JNC OPERATOR_OK
    JMP BAD_OPERATOR
OPERATOR_OK:
    MOV OPERATOR, AL
    CALL PRINT_NEWLINE

    LEA DX, SECOND_PROMPT
    CALL PRINT_STRING
    CALL READ_BYTE
    JNC SECOND_OK
    JMP BAD_INPUT
SECOND_OK:
    XOR AH, AH
    MOV OPERAND2, AX
    CALL PRINT_NEWLINE

    MOV AL, OPERATOR
    CMP AL, '+'
    JE Q4_ADD
    CMP AL, '-'
    JE Q4_SUBTRACT
    CMP AL, '*'
    JE Q4_MULTIPLY
    CMP AL, '/'
    JE Q4_DIVIDE
    JMP BAD_OPERATOR

Q4_ADD:
    MOV AX, OPERAND1
    ADD AX, OPERAND2
    LEA DX, RESULT_LABEL
    CALL PRINT_STRING
    CALL PRINT_UINT
    CALL PRINT_NEWLINE
    JMP Q4_EXIT_OK

Q4_SUBTRACT:
    LEA DX, RESULT_LABEL
    CALL PRINT_STRING
    MOV AX, OPERAND1
    CMP AX, OPERAND2
    JAE Q4_SUB_POSITIVE
    MOV DL, '-'
    CALL PRINT_CHAR
    MOV AX, OPERAND2
    SUB AX, OPERAND1
    JMP SHORT Q4_SUB_PRINT
Q4_SUB_POSITIVE:
    SUB AX, OPERAND2
Q4_SUB_PRINT:
    CALL PRINT_UINT
    CALL PRINT_NEWLINE
    JMP SHORT Q4_EXIT_OK

Q4_MULTIPLY:
    MOV AX, OPERAND1
    MOV BX, OPERAND2
    MUL BX
    LEA DX, RESULT_LABEL
    CALL PRINT_STRING
    CALL PRINT_UINT
    CALL PRINT_NEWLINE
    JMP SHORT Q4_EXIT_OK

Q4_DIVIDE:
    CMP OPERAND2, 0
    JE Q4_DIVIDE_ZERO
    MOV AX, OPERAND1
    XOR DX, DX
    DIV OPERAND2
    MOV QUOTIENT, AX
    MOV REMAINDER, DX
    LEA DX, QUOTIENT_LABEL
    CALL PRINT_STRING
    MOV AX, QUOTIENT
    CALL PRINT_UINT
    LEA DX, REMAINDER_LABEL
    CALL PRINT_STRING
    MOV AX, REMAINDER
    CALL PRINT_UINT
    CALL PRINT_NEWLINE
    JMP SHORT Q4_EXIT_OK

BAD_INPUT:
    CALL PRINT_NEWLINE
    LEA DX, INVALID_INPUT
    CALL PRINT_STRING
    JMP SHORT Q4_EXIT_ERROR
BAD_OPERATOR:
    CALL PRINT_NEWLINE
    LEA DX, INVALID_OPERATOR
    CALL PRINT_STRING
    JMP SHORT Q4_EXIT_ERROR
Q4_DIVIDE_ZERO:
    LEA DX, DIVIDE_ZERO
    CALL PRINT_STRING
Q4_EXIT_ERROR:
    MOV AX, 4C01H
    INT 21H
Q4_EXIT_OK:
    MOV AX, 4C00H
    INT 21H

; Read one decimal byte with DOS buffered keyboard input.
; Accepts 1 to 3 decimal digits, rejects non-digits and values above 255.
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
    JZ RB_BAD
    CMP CX, 3
    JA RB_BAD

    LEA SI, INPUT_BUFFER+2
    XOR BX, BX
RB_DIGIT:
    MOV DL, [SI]
    CMP DL, '0'
    JB RB_BAD
    CMP DL, '9'
    JA RB_BAD
    SUB DL, '0'
    XOR DH, DH
    MOV DI, DX

    MOV AX, BX
    MOV DX, 10
    MUL DX
    ADD AX, DI
    CMP AX, 255
    JA RB_BAD
    MOV BX, AX

    INC SI
    LOOP RB_DIGIT
    MOV AX, BX
    CLC
    JMP SHORT RB_DONE
RB_BAD:
    STC
RB_DONE:
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_BYTE ENDP

; Read one operator character with DOS buffered keyboard input.
; Requires exactly one typed character, accepts only +, -, *, or /.
; Returns: AL = operator character and CF clear, or CF set for invalid
; input (wrong length or unsupported character).
READ_OPERATOR PROC NEAR
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    LEA DX, OPERATOR_BUFFER
    MOV AH, 0AH
    INT 21H

    CMP OPERATOR_BUFFER+1, 1
    JNE RO_BAD

    MOV AL, OPERATOR_BUFFER+2
    CMP AL, '+'
    JE RO_OK
    CMP AL, '-'
    JE RO_OK
    CMP AL, '*'
    JE RO_OK
    CMP AL, '/'
    JE RO_OK
    JMP SHORT RO_BAD
RO_OK:
    CLC
    JMP SHORT RO_DONE
RO_BAD:
    STC
RO_DONE:
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_OPERATOR ENDP

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

; Print the single character in DL.
PRINT_CHAR PROC NEAR
    PUSH AX
    PUSH DX
    MOV AH, 02H
    INT 21H
    POP DX
    POP AX
    RET
PRINT_CHAR ENDP

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
