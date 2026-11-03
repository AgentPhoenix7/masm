; Develop a MASM program that accepts a string consisting of multiple types of brackets (i.e., (), {}, []) and verifies whether they are balanced and properly nested. The program should simulate a stack-based approach to evaluate the expression, pushing opening brackets and popping when a matching closing bracket is found. The program should output either:
; a. Balanced - if all opening and closing brackets are matched correctly
; b. Non-Balanced

; Check whether (), {}, and [] brackets are balanced and properly nested.
; MASM 5.x / 8086 / DOS INT 21H

.MODEL SMALL
.STACK 100H

MAX_INPUT EQU 80

.DATA
    TITLE_TEXT    DB 13,10,'BRACKET BALANCE CHECKER',13,10,'$'
    PROMPT_TEXT   DB 'Enter brackets using (), {}, and []: $'
    BALANCED_TEXT DB 13,10,'Balanced',13,10,'$'
    NOT_BAL_TEXT  DB 13,10,'Non-Balanced',13,10,'$'

    ; DOS function 0AH needs room for the final carriage return.
    ; Therefore, the maximum-buffer byte is 81 for 80 input characters.
    INPUT_BUFFER  DB MAX_INPUT+1, 0, (MAX_INPUT+1) DUP (0)

    ; This array is the simulated stack. TOP_INDEX stores its size.
    BRACKET_STACK DB MAX_INPUT DUP (0)
    TOP_INDEX     DB 0

.CODE
MAIN PROC
    MOV AX, @DATA
    MOV DS, AX

    LEA DX, TITLE_TEXT
    CALL PRINT_STRING

    LEA DX, PROMPT_TEXT
    CALL PRINT_STRING

    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    MOV TOP_INDEX, 0
    LEA SI, INPUT_BUFFER[2]
    XOR CX, CX
    MOV CL, INPUT_BUFFER[1]

    JCXZ CHECK_STACK_EMPTY

CHECK_NEXT_CHARACTER:
    MOV AL, [SI]

    CMP AL, '('
    JE PUSH_OPENING
    CMP AL, '{'
    JE PUSH_OPENING
    CMP AL, '['
    JE PUSH_OPENING

    CMP AL, ')'
    JE CHECK_ROUND
    CMP AL, '}'
    JE CHECK_CURLY
    CMP AL, ']'
    JE CHECK_SQUARE

    ; The specified input may contain brackets only.
    JMP NON_BALANCED

PUSH_OPENING:
    XOR BX, BX
    MOV BL, TOP_INDEX
    CMP BL, MAX_INPUT
    JAE NON_BALANCED
    MOV BRACKET_STACK[BX], AL
    INC TOP_INDEX
    JMP CHARACTER_DONE

CHECK_ROUND:
    MOV DL, '('
    JMP CHECK_CLOSING

CHECK_CURLY:
    MOV DL, '{'
    JMP CHECK_CLOSING

CHECK_SQUARE:
    MOV DL, '['

CHECK_CLOSING:
    CMP TOP_INDEX, 0
    JE NON_BALANCED

    DEC TOP_INDEX
    XOR BX, BX
    MOV BL, TOP_INDEX
    CMP BRACKET_STACK[BX], DL
    JNE NON_BALANCED

CHARACTER_DONE:
    INC SI
    LOOP CHECK_NEXT_CHARACTER

CHECK_STACK_EMPTY:
    CMP TOP_INDEX, 0
    JNE NON_BALANCED

BALANCED:
    LEA DX, BALANCED_TEXT
    CALL PRINT_STRING
    JMP EXIT_PROGRAM

NON_BALANCED:
    LEA DX, NOT_BAL_TEXT
    CALL PRINT_STRING

EXIT_PROGRAM:
    MOV AX, 4C00H
    INT 21H
MAIN ENDP

; Input: DS:DX points to a string terminated by '$'.
PRINT_STRING PROC NEAR
    PUSH AX
    MOV AH, 09H
    INT 21H
    POP AX
    RET
PRINT_STRING ENDP

END MAIN
