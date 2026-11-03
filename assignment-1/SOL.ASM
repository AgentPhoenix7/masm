; Convert infix expression to postfix.
; Supports numbers, +, -, *, /, ^ and parentheses.

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'

    PROMPT  DB 'Enter infix expression: $'
    RESULT  DB 13,10,'Postfix expression: $'
    NEWLINE DB 13,10,'$'

    ; DOS function 0AH input buffer
    INPUT   DB 80     ; first byte of the DOS buffered-input structure
            DB ?      ; actual number of characters entered
            DB 80 DUP (?)    ; Reserves 80 bytes

    POSTFIX DB 170 DUP ('$')  ; Reserves 170 bytes for the resulting postfix expression

    OP_STACK DB 80 DUP (?)    ; stack for operators
    OP_TOP   DW 0             ; stack top

DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    MOV AX, DATASEG
    MOV DS, AX

    ; Print input prompt.
    LEA DX, PROMPT
    MOV AH, 09H
    INT 21H

    ; Read expression from keyboard.
    LEA DX, INPUT
    MOV AH, 0AH
    INT 21H

    ; Convert infix to postfix.
    CALL INFIX_TO_POSTFIX

    ; Print result.
    LEA DX, RESULT
    MOV AH, 09H
    INT 21H

    LEA DX, POSTFIX
    MOV AH, 09H
    INT 21H

    LEA DX, NEWLINE
    MOV AH, 09H
    INT 21H

    ; Exit.
    MOV AX, 4C00H
    INT 21H


; Convert infix expression to postfix.

INFIX_TO_POSTFIX PROC NEAR

    LEA SI, INPUT+2          ; SI points to first input character

    XOR CX, CX               ; Clear CX
    MOV CL, INPUT+1          ; CX = number of characters entered

    LEA DI, POSTFIX          ; DI points to output buffer
    MOV OP_TOP, 0            ; Set top = 0

NEXT_CHAR:
    CMP CX, 0     ; Checks whether there are any input characters remaining.
    JE END_INPUT  ; entire input has been processed

    MOV AL, [SI]  ; Load value

    ; Ignore spaces.
    CMP AL, ' '
    JE SKIP_CHAR

    ; Check for number.
    CMP AL, '0'
    JB NOT_NUMBER
    CMP AL, '9'
    JA NOT_NUMBER

; Copy complete number to postfix.
; Example: 123 -> "123 "

COPY_NUMBER:
    MOV AL, [SI]      ; Load value

    ; If it isn't a digit anymore, the complete number has ended.
    CMP AL, '0'
    JB NUMBER_DONE
    CMP AL, '9'
    JA NUMBER_DONE

    MOV [DI], AL    ; Store at dest
    INC DI          ; move forward
    INC SI
    DEC CX          ; decrement counter

    CMP CX, 0
    JE NUMBER_DONE

    JMP COPY_NUMBER

NUMBER_DONE:
    MOV BYTE PTR [DI], ' '        ; put token separator
    INC DI
    JMP NEXT_CHAR


NOT_NUMBER:
    CMP AL, '('
    JE LEFT_PAREN

    CMP AL, ')'
    JE RIGHT_PAREN

    ; Otherwise it is an operator.
    MOV DL, AL

; Compare current operator with top of operator stack.

CHECK_STACK:
    CMP OP_TOP, 0               ; empty - nothing to compare
    JE PUSH_OPERATOR            ; put operator in OP_STACK

    MOV BX, OP_TOP              ; Copy stack size/index into `BX`.
    DEC BX                      ; last location

    MOV AL, OP_STACK[BX]        ; Load the operator currently at the top.

    CMP AL, '('
    JE PUSH_OPERATOR

    ; Get precedence of stack operator.
    CALL PRECEDENCE
    MOV DH, AH           ; save precedence

    ; Get precedence of current operator.
    MOV AL, DL
    CALL PRECEDENCE

    ; compare precedences
    CMP DH, AH
    JB PUSH_OPERATOR   ; if stack_precedence < incoming_precedence -> push it

    ; ^ is right associative.
    CMP DH, AH
    JNE POP_OPERATOR   ; if stack_precedence > incoming_precedence -> pop it

    CMP DL, '^'        ; if 2^3^4 -> 2^(3^4)
    JE PUSH_OPERATOR


; Pop operator from stack and put it in postfix.

POP_OPERATOR:
    DEC OP_TOP      ; Remove one item from top

    MOV BX, OP_TOP
    MOV AL, OP_STACK[BX]

    MOV [DI], AL
    INC DI

    MOV BYTE PTR [DI], ' '       ; token separator
    INC DI

    JMP CHECK_STACK

; Push current operator.

PUSH_OPERATOR:
    MOV BX, OP_TOP        ; Add one item at top
    MOV OP_STACK[BX], DL
    INC OP_TOP

    INC SI
    DEC CX

    JMP NEXT_CHAR

; Push '(' onto operator stack.

LEFT_PAREN:
    MOV BX, OP_TOP
    MOV OP_STACK[BX], '('
    INC OP_TOP

    INC SI
    DEC CX

    JMP NEXT_CHAR

; For ')', pop until '(' is found.

RIGHT_PAREN:                     ; When `)` occurs, operators are popped until matching `(` is reached.
    DEC OP_TOP

    MOV BX, OP_TOP
    MOV AL, OP_STACK[BX]

    CMP AL, '('                  ; If it is `(`, we've found the matching opening parenthesis.
    JE RIGHT_DONE                ; We do not copy `(` to postfix.

    MOV [DI], AL                 ; Otherwise copy the popped operator to postfix.
    INC DI

    MOV BYTE PTR [DI], ' '
    INC DI

    JMP RIGHT_PAREN

RIGHT_DONE:
    INC SI
    DEC CX

    JMP NEXT_CHAR


SKIP_CHAR:
    INC SI
    DEC CX
    JMP NEXT_CHAR


; ------------------------------------------------------------
; Input finished. Pop all remaining operators.
; ------------------------------------------------------------
END_INPUT:
    CMP OP_TOP, 0
    JE FINISH

    DEC OP_TOP

    MOV BX, OP_TOP
    MOV AL, OP_STACK[BX]

    MOV [DI], AL
    INC DI

    MOV BYTE PTR [DI], ' '
    INC DI

    JMP END_INPUT


; Replace final space with '$' for DOS function 09H.

FINISH:
    DEC DI
    MOV BYTE PTR [DI], '$'

    RET

INFIX_TO_POSTFIX ENDP

; Return operator precedence in AH.
;
; + - = 1
; * / = 2
; ^   = 3

PRECEDENCE PROC NEAR

    MOV AH, 1

    CMP AL, '+'
    JE PREC_DONE
    CMP AL, '-'
    JE PREC_DONE

    MOV AH, 2

    CMP AL, '*'
    JE PREC_DONE
    CMP AL, '/'
    JE PREC_DONE

    MOV AH, 3

PREC_DONE:
    RET

PRECEDENCE ENDP


CODESEG ENDS
END START
