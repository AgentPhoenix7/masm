; Convert infix expression to postfix.
; Supports numbers, +, -, *, /, ^ and parentheses.
;
; This is a direct operator-stack (shunting-yard) conversion for well-formed
; input: copy number tokens immediately, defer operators on a stack, and emit
; them when precedence or a closing parenthesis makes their order definite.
; It constructs postfix text; it does not evaluate the arithmetic expression.
; Example: 12+3*4 becomes "12 3 4 * +". Each token is separated by a space.
; This version assumes valid syntax and balanced parentheses; it does not
; validate all tokens, guard operator-stack underflow, or handle empty output
; safely. The separate prob.asm implements checks around these operations.
; AX/BX/CX/DX are 16-bit registers; AH/AL etc. are their upper/lower bytes.
; H marks hexadecimal constants. All data offsets are relative to DS.

; SEGMENT/ENDS declare assembler sections; PARA requests 16-byte alignment.
; STACK identifies the stack for the linker's initial SS:SP in the .EXE header.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW declares words: 128 words reserve 256 bytes for CALL return addresses.
    ; DUP repeats the declaration; ? means no initial value is specified.
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'

    ; PUBLIC permits compatible segments to be combined by the linker.
    ; DB declares bytes/character codes. DOS service 09H stops printing at '$';
    ; 13 and 10 are carriage return and line feed for a DOS newline.
    PROMPT  DB 'Enter infix expression: $'
    RESULT  DB 13,10,'Postfix expression: $'
    NEWLINE DB 13,10,'$'

    ; DOS function 0AH input buffer. DOS receives DS:DX pointing to this header,
    ; places the length (excluding CR) at +1, and the typed characters at +2.
    ; The capacity includes room for CR. The returned length is used below,
    ; so the converter needs neither a zero nor '$' input terminator.
    INPUT   DB 80     ; first byte of the DOS buffered-input structure
            DB ?      ; actual number of characters entered
            DB 80 DUP (?)    ; Reserves 80 bytes

    POSTFIX DB 170 DUP ('$')  ; Reserves 170 bytes for the resulting postfix expression

    ; This byte array is a software stack for operators, separate from SS:SP.
    ; OP_TOP is a count/next-free index: zero means empty; top item is at top-1.
    ; The CPU stack still holds CALL return addresses during conversion.
    OP_STACK DB 80 DUP (?)    ; stack for operators
    OP_TOP   DW 0             ; stack top

DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME describes register/segment use to the assembler; it does not
    ; initialize DS or any other register at run time.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    ; DOS .EXE startup points DS at the program segment prefix. Load DATASEG
    ; via AX because MOV cannot load a segment register with an immediate.
    MOV AX, DATASEG
    MOV DS, AX

    ; LEA loads the prompt's offset, not its text. DOS service AH=09H prints
    ; the '$'-terminated string at DS:DX when INT 21H invokes DOS.
    LEA DX, PROMPT
    MOV AH, 09H
    INT 21H

    ; Select DOS buffered line input (AH=0AH), which reads and echoes the line.
    LEA DX, INPUT
    MOV AH, 0AH
    INT 21H

    ; CALL saves the next instruction's address on SS:SP. The converter's
    ; RET returns here after it has constructed the output string in memory.
    CALL INFIX_TO_POSTFIX

    ; Print the result label, converted postfix text, and a newline with the
    ; same DOS string service. The final '$' is a terminator, not output text.
    LEA DX, RESULT
    MOV AH, 09H
    INT 21H

    LEA DX, POSTFIX
    MOV AH, 09H
    INT 21H

    LEA DX, NEWLINE
    MOV AH, 09H
    INT 21H

    ; AH=4CH terminates the process; AL=00H returns success status to DOS.
    MOV AX, 4C00H
    INT 21H


; Convert infix expression to postfix.

INFIX_TO_POSTFIX PROC NEAR

    ; PROC NEAR declares a procedure in the current code segment. SI scans
    ; the input, CX counts unconsumed characters, and DI is the next output slot.
    ; No caller-register values are saved: this routine uses them as workspace.
    LEA SI, INPUT+2          ; SI points to first input character

    XOR CX, CX               ; Clear CX
    MOV CL, INPUT+1          ; CX = number of characters entered

    LEA DI, POSTFIX          ; DI points to output buffer
    MOV OP_TOP, 0            ; Set top = 0

NEXT_CHAR:
    ; Dispatch the next unconsumed character. CMP sets flags without changing
    ; operands; JE selects equality. CX=0 ends scanning before any further read.
    CMP CX, 0     ; Checks whether there are any input characters remaining.
    JE END_INPUT  ; entire input has been processed

    MOV AL, [SI]  ; Load value

    ; Spaces are skipped without producing tokens. Other whitespace, such as
    ; tabs, is not recognized by this particular test.
    CMP AL, ' '
    JE SKIP_CHAR

    ; ASCII digits occupy consecutive unsigned codes '0'..'9'. JB/JA branch
    ; below/above that range; a digit starts a complete multi-digit token.
    CMP AL, '0'
    JB NOT_NUMBER
    CMP AL, '9'
    JA NOT_NUMBER

; Copy complete number to postfix.
; Example: 123 -> "123 "

COPY_NUMBER:
    ; Copy digit characters as text, not as a numeric accumulator. This
    ; preserves multi-digit spelling and avoids arithmetic-size limits here.
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

    ; Stop before reading beyond the returned input length. If a nondigit
    ; ends a number, it remains unconsumed for NEXT_CHAR to dispatch later.
    CMP CX, 0
    JE NUMBER_DONE

    JMP COPY_NUMBER

NUMBER_DONE:
    ; Append a separator after the entire integer rather than after each digit.
    ; BYTE PTR specifies a byte-sized store of the immediate space character.
    MOV BYTE PTR [DI], ' '        ; put token separator
    INC DI
    JMP NEXT_CHAR


NOT_NUMBER:
    ; Parentheses take dedicated paths. Every other nondigit/nonspace byte
    ; is treated as an operator here, even if it is not in the supported set.
    CMP AL, '('
    JE LEFT_PAREN

    CMP AL, ')'
    JE RIGHT_PAREN

    ; Keep the incoming operator in DL while AL is reused to inspect the stack.
    MOV DL, AL

; Compare current operator with top of operator stack.

CHECK_STACK:
    ; An empty stack or '(' on top stops popping: '(' is a grouping barrier.
    ; OP_TOP is the next-free slot, so decrement its copy in BX to peek at top.
    CMP OP_TOP, 0               ; empty - nothing to compare
    JE PUSH_OPERATOR            ; put operator in OP_STACK

    MOV BX, OP_TOP              ; Copy stack size/index into `BX`.
    DEC BX                      ; last location

    MOV AL, OP_STACK[BX]        ; Load the operator currently at the top.

    CMP AL, '('
    JE PUSH_OPERATOR

    ; PRECEDENCE returns a priority in AH without changing AL or DX. Save the
    ; stack operator's priority in DH; DL still holds the incoming operator.
    CALL PRECEDENCE
    MOV DH, AH           ; save precedence

    ; Load the incoming operator into AL and get its priority in AH as well.
    MOV AL, DL
    CALL PRECEDENCE

    ; A lower-priority stack operator stays deferred while the new one is pushed.
    ; A higher-priority one must be emitted before the incoming operator.
    CMP DH, AH
    JB PUSH_OPERATOR   ; if stack_precedence < incoming_precedence -> push it

    ; Equal-priority +,-,*,/ are left-associative: emit the earlier one first.
    ; Exponentiation is right-associative: defer equal '^' operators so the
    ; rightmost is emitted first. No powers are actually calculated here.
    CMP DH, AH
    JNE POP_OPERATOR   ; if stack_precedence > incoming_precedence -> pop it

    CMP DL, '^'        ; if 2^3^4 -> 2^(3^4)
    JE PUSH_OPERATOR


; Pop operator from stack and put it in postfix.

POP_OPERATOR:
    ; Remove one operator from the software stack, append it and a separator,
    ; then inspect the next stack item against the SAME incoming operator.
    ; SI/CX are unchanged while popping because that operator is not consumed yet.
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
    ; Store at the next-free index, then increment the count. Only now consume
    ; the incoming character by advancing SI and decrementing CX.
    MOV BX, OP_TOP        ; Add one item at top
    MOV OP_STACK[BX], DL
    INC OP_TOP

    INC SI
    DEC CX

    JMP NEXT_CHAR

; Push '(' onto operator stack.

LEFT_PAREN:
    ; Store '(' as a barrier. It is not an output token; a matching ')' later
    ; removes it after emitting the operators nested inside the parentheses.
    MOV BX, OP_TOP
    MOV OP_STACK[BX], '('
    INC OP_TOP

    INC SI
    DEC CX

    JMP NEXT_CHAR

; For ')', pop until '(' is found.

RIGHT_PAREN:                     ; When `)` occurs, operators are popped until matching `(` is reached.
    ; This path assumes there is a matching '(' in the stack. Without one,
    ; DEC OP_TOP can underflow because this simpler version has no empty check.
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
    ; The opening parenthesis has been discarded. Consume the closing one
    ; without copying either parenthesis into the postfix output.
    INC SI
    DEC CX

    JMP NEXT_CHAR


SKIP_CHAR:
    ; Consume one literal space, then resume token dispatch with the new count.
    INC SI
    DEC CX
    JMP NEXT_CHAR


; ------------------------------------------------------------
; Input finished. Pop all remaining operators.
; ------------------------------------------------------------
END_INPUT:
    ; Drain the deferred operators in last-in, first-out order. For well-formed
    ; input no parentheses remain; this version does not reject unmatched '('.
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
    ; DI is one past the final separator. Back up one byte and overwrite it
    ; with DOS's '$' terminator. This assumes at least one token was emitted:
    ; with empty/space-only input DEC DI would address before POSTFIX.
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

    ; Default to priority 1 and return early for addition/subtraction.
    ; JE tests equality from the preceding CMP without changing AL.
    MOV AH, 1

    CMP AL, '+'
    JE PREC_DONE
    CMP AL, '-'
    JE PREC_DONE

    ; If not + or -, try priority 2 for multiplication/division.
    MOV AH, 2

    CMP AL, '*'
    JE PREC_DONE
    CMP AL, '/'
    JE PREC_DONE

    ; Any remaining code receives priority 3, intended for '^'. Because no
    ; validation occurs here, unknown operator characters also receive 3.
    MOV AH, 3

PREC_DONE:
    ; Return the selected priority in AH to the caller's comparison logic.
    RET

PRECEDENCE ENDP


CODESEG ENDS
; ENDP/ENDS close assembler declarations; END closes the module and selects START.
END START
