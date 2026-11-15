; Convert an infix expression to postfix notation.
; Supports unsigned integer operands, +, -, *, /, ^, and parentheses.
; Unary operators and variables are intentionally not supported.
;
; Flow: initialize DS -> read one bounded line -> validate/convert its tokens ->
; print postfix on success, or print an error and return failure to DOS.
; The operator-stack (shunting-yard) method copies numbers immediately and
; defers operators until precedence/parentheses determine their output order.
; Example: 12+3*4 becomes "12 3 4 * +". This converts text without evaluating it.
; AX/BX/CX/DX are 16-bit registers; AH/AL etc. are their upper/lower bytes.
; H marks hexadecimal constants; offsets refer to memory within DS.

; SEGMENT/ENDS delimit assembler sections; PARA requests 16-byte alignment.
; STACK lets the linker record initial SS:SP for the DOS .EXE loader.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW reserves words: 128 words provide 256 bytes for CALL/PUSH on SS:SP.
    ; DUP repeats the declaration; ? leaves initial contents unspecified.
    DW 128 DUP (?)
STACKSEG ENDS

; EQU defines assembly-time constants, allocating no memory or CPU instructions.
; An extra input byte is reserved below for a zero after up to 80 characters.
MAX_INPUT  EQU 80
MAX_OUTPUT EQU 170

DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; PUBLIC permits compatible segments to be combined by the linker.
    ; DB declares bytes/character codes. DOS service 09H prints until '$';
    ; 13/10 are carriage return/line feed for a new line.
    TITLE_TEXT   DB 13,10,'INFIX TO POSTFIX CONVERTER',13,10,'$'
    HELP_TEXT    DB 'Use integers and + - * / ^ ( ).',13,10,'$'
    PROMPT_TEXT  DB 'Enter infix expression: $'
    RESULT_TEXT  DB 13,10,'Postfix expression: $'
    ERROR_TEXT   DB 13,10,'ERROR: invalid infix expression.',13,10,'$'
    LONG_TEXT    DB 13,10,'ERROR: expression is too long.',13,10,'$'
    NEWLINE      DB 13,10,'$'

    ; Word lengths (DW) track input characters and appended output bytes.
    ; INPUT_DATA uses a zero terminator. POSTFIX_BUFFER uses '$' for DOS output
    ; and starts filled with terminators so unwritten slots are already bounded.
    INPUT_LENGTH      DW 0
    INPUT_DATA        DB MAX_INPUT+1 DUP (0)
    OUTPUT_LENGTH     DW 0
    POSTFIX_BUFFER    DB MAX_OUTPUT DUP ('$')

    ; OP_TOP counts software-stack items: next-free slot=OP_TOP, top=OP_TOP-1.
    ; This operator array is separate from the CPU stack used by CALL/PUSH.
    ; EXPECT_OPERAND=1 permits a number or '('; 0 permits an operator or ')'.
    ; Save the incoming operator and its precedence while inspecting stack items.
    OP_TOP             DB 0
    OPERATOR_STACK     DB MAX_INPUT DUP (0)
    EXPECT_OPERAND     DB 1
    CURRENT_OPERATOR   DB 0
    CURRENT_PRECEDENCE DB 0
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME describes intended register/segment associations to the assembler;
    ; it does not load those registers or execute at run time.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    ; DOS .EXE startup sets CS/SS but DS initially points to the program segment
    ; prefix. Load DATASEG through AX because MOV DS,immediate is not supported.
    MOV AX, DATASEG
    MOV DS, AX

    ; LEA loads a string's offset into DX, not its contents. PRINT_STRING passes
    ; DS:DX to DOS. CALL saves a return address; RET resumes after that CALL.
    LEA DX, TITLE_TEXT
    CALL PRINT_STRING
    LEA DX, HELP_TEXT
    CALL PRINT_STRING
    LEA DX, PROMPT_TEXT
    CALL PRINT_STRING

    ; Procedures report status in CF (carry flag): clear=success, set=failure.
    ; JNC skips the error path when carry is clear; a long line prints its own
    ; error message before converging on the failure exit.
    CALL READ_EXPRESSION
    JNC INPUT_OK
    LEA DX, LONG_TEXT
    CALL PRINT_STRING
    JMP PROGRAM_ERROR

INPUT_OK:
    ; Convert the stored input, checking grammar, parentheses and capacities.
    ; Any conversion failure prints the generic invalid-expression message.
    CALL CONVERT_TO_POSTFIX
    JNC CONVERSION_OK
    LEA DX, ERROR_TEXT
    CALL PRINT_STRING
    JMP PROGRAM_ERROR

CONVERSION_OK:
    ; Print the finished '$'-terminated result only after successful conversion.
    LEA DX, RESULT_TEXT
    CALL PRINT_STRING
    LEA DX, POSTFIX_BUFFER
    CALL PRINT_STRING
    LEA DX, NEWLINE
    CALL PRINT_STRING

    ; DOS service AH=4CH terminates the process; AL=00H returns success status.
    MOV AX, 4C00H
    INT 21H

PROGRAM_ERROR:
    ; The same termination service with AL=01H returns failure status 1.
    MOV AX, 4C01H
    INT 21H

; Read one line a character at a time. DOS function 01H echoes keyboard
; input and also permits the automated tests to redirect a text file.
; Returns CF set when more than MAX_INPUT characters were entered.
READ_EXPRESSION PROC NEAR
    ; Preserve scratch registers; the input result is stored in memory, not AX.
    ; DI is the next input slot; CX counts characters accepted so far.
    PUSH AX
    PUSH CX
    PUSH DI

    LEA DI, INPUT_DATA
    XOR CX, CX

RE_READ:
    ; DOS service AH=01H reads and echoes one character in AL. CR (13) ends
    ; the line before the capacity check, so exactly MAX_INPUT is permitted.
    MOV AH, 01H
    INT 21H
    CMP AL, 13
    JE RE_DONE

    ; JAE is an unsigned 'above or equal' test. If no slot remains, the current
    ; non-CR character is the first excess byte; do not write it to memory.
    CMP CX, MAX_INPUT
    JAE RE_TOO_LONG
    MOV [DI], AL
    INC DI
    INC CX
    JMP RE_READ

RE_TOO_LONG:
    ; Discard the rest of the line before reporting the error.
    MOV AH, 01H
    INT 21H
    CMP AL, 13
    JNE RE_TOO_LONG
    ; STC reports the overlong entry after the remaining characters are consumed.
    STC
    JMP RE_RETURN

RE_DONE:
    ; Store the length and terminate the character array at the next free slot.
    ; BYTE PTR specifies a one-byte immediate store. CLC reports successful input.
    MOV INPUT_LENGTH, CX
    MOV BYTE PTR [DI], 0
    CLC

RE_RETURN:
    ; POP/RET leave CF unchanged, preserving the status for the caller's JNC.
    POP DI
    POP CX
    POP AX
    RET
READ_EXPRESSION ENDP

; Convert INPUT_DATA to POSTFIX_BUFFER with the operator-stack method.
; Returns CF clear for success and CF set for an invalid expression.
CONVERT_TO_POSTFIX PROC NEAR
    ; Preserve the caller's working registers; the output is written to memory
    ; and the status flag is returned separately. SI/CX scan the input stream.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    ; Reset all per-conversion state: no output, empty stack, and an operand
    ; required first. INPUT_LENGTH, not the zero terminator, bounds this scan.
    MOV OUTPUT_LENGTH, 0
    MOV OP_TOP, 0
    MOV EXPECT_OPERAND, 1
    LEA SI, INPUT_DATA
    MOV CX, INPUT_LENGTH

CT_NEXT:
    ; Avoid reading past the recorded input length. The explicit JMP reaches
    ; the end-input handler when no unconsumed characters remain.
    CMP CX, 0
    JNE CT_HAVE_CHARACTER
    JMP CT_END_INPUT

CT_HAVE_CHARACTER:
    ; Inspect the current byte without consuming it; the chosen token handler
    ; advances SI and decrements CX after processing. Only literal spaces skip.
    MOV AL, [SI]

    CMP AL, ' '
    JE CT_SKIP_SPACE

    ; Unsigned JB/JA separate ASCII digits from parentheses/operators/invalid
    ; codes. Digits '0'..'9' form one uninterrupted integer token.
    CMP AL, '0'
    JB CT_NOT_NUMBER
    CMP AL, '9'
    JA CT_NOT_NUMBER

    ; A complete multi-digit integer is one postfix token.
    ; Reject a number where an operator is required: for example "1 2" or
    ; "(1)2". Internal spaces therefore cannot split one integer into pieces.
    CMP EXPECT_OPERAND, 1
    JE CT_NUMBER
    JMP CT_INVALID

CT_NUMBER:
    ; Append digit characters directly as text; the integer is not accumulated
    ; into a fixed-size CPU register. APPEND_OUTPUT checks space for each byte.
    ; JC aborts conversion if that helper returns carry set.
    MOV AL, [SI]
    CALL APPEND_OUTPUT
    JC CT_INVALID
    INC SI
    DEC CX
    ; Check remaining input before looking for another digit. A following
    ; nondigit stays unconsumed for the next token-dispatch pass.
    CMP CX, 0
    JE CT_NUMBER_DONE
    MOV AL, [SI]
    CMP AL, '0'
    JB CT_NUMBER_DONE
    CMP AL, '9'
    JBE CT_NUMBER

CT_NUMBER_DONE:
    ; Finish the integer with a separator and change the grammar state so
    ; the next nonspace token must be an operator or closing parenthesis.
    MOV AL, ' '
    CALL APPEND_OUTPUT
    JC CT_INVALID
    MOV EXPECT_OPERAND, 0
    JMP CT_NEXT

CT_NOT_NUMBER:
    ; Accept only the explicitly listed punctuation. Unknown characters,
    ; variable names and other whitespace fall through to the invalid path.
    CMP AL, '('
    JE CT_OPEN_PAREN
    CMP AL, ')'
    JE CT_CLOSE_PAREN
    CMP AL, '+'
    JE CT_OPERATOR
    CMP AL, '-'
    JE CT_OPERATOR
    CMP AL, '*'
    JE CT_OPERATOR
    CMP AL, '/'
    JE CT_OPERATOR
    CMP AL, '^'
    JE CT_OPERATOR
    JMP CT_INVALID

CT_SKIP_SPACE:
    ; Consume one literal space without changing the operand/operator state.
    INC SI
    DEC CX
    JMP CT_NEXT

CT_OPEN_PAREN:
    ; '(' may start a grouped operand, but cannot follow a complete operand
    ; without an operator: implicit multiplication such as "2(3)" is rejected.
    CMP EXPECT_OPERAND, 1
    JE CT_PUSH_OPEN
    JMP CT_INVALID

CT_PUSH_OPEN:
    ; OP_TOP is a byte count; clear BX before loading BL so BH cannot corrupt
    ; the array index. Check capacity, then push '(' as a grouping barrier.
    XOR BX, BX
    MOV BL, OP_TOP
    CMP BX, MAX_INPUT
    JAE CT_INVALID
    MOV OPERATOR_STACK[BX], '('
    INC OP_TOP
    INC SI
    DEC CX
    JMP CT_NEXT

CT_CLOSE_PAREN:
    ; A closing parenthesis must follow a complete operand: reject empty
    ; groups "()" or incomplete expressions such as "(1+)".
    CMP EXPECT_OPERAND, 0
    JE CT_CLOSE_POP
    JMP CT_INVALID

CT_CLOSE_POP:
    ; Pop until the matching '(' is found, checking for an empty stack first
    ; to reject unmatched ')'. Each intervening operator becomes an output token.
    CMP OP_TOP, 0
    JE CT_INVALID
    DEC OP_TOP
    XOR BX, BX
    MOV BL, OP_TOP
    MOV AL, OPERATOR_STACK[BX]
    CMP AL, '('
    JE CT_CLOSE_DONE
    CALL APPEND_OPERATOR
    JC CT_INVALID
    JMP CT_CLOSE_POP

CT_CLOSE_DONE:
    ; Discard the matching '(' and consume ')'; parentheses never appear in
    ; postfix. EXPECT_OPERAND stays zero because a group is a completed operand.
    INC SI
    DEC CX
    JMP CT_NEXT

CT_OPERATOR:
    ; A binary operator must follow an operand. This rejects leading operators,
    ; repeated operators such as "1++2", and unary forms such as "-3".
    CMP EXPECT_OPERAND, 0
    JE CT_SAVE_OPERATOR
    JMP CT_INVALID

CT_SAVE_OPERATOR:
    ; Save the incoming operator and priority in memory because inspecting
    ; deferred operators reuses AL/AH. GET_PRECEDENCE leaves the operator in AL.
    MOV CURRENT_OPERATOR, AL
    CALL GET_PRECEDENCE
    MOV CURRENT_PRECEDENCE, AH

CT_COMPARE_TOP:
    ; Empty stack means push immediately. Otherwise peek at OP_TOP-1 without
    ; removing it. '(' blocks precedence comparisons across a grouping boundary.
    CMP OP_TOP, 0
    JE CT_PUSH_OPERATOR
    XOR BX, BX
    MOV BL, OP_TOP
    DEC BX
    MOV AL, OPERATOR_STACK[BX]
    CMP AL, '('
    JE CT_PUSH_OPERATOR

    CALL GET_PRECEDENCE
    ; A higher-priority stack operator must be emitted first; a lower-priority
    ; one stays deferred while the incoming operator is pushed on top.
    CMP AH, CURRENT_PRECEDENCE
    JA CT_POP_OPERATOR
    JB CT_PUSH_OPERATOR

    ; Equal-precedence operators are popped, except ^. Exponentiation is
    ; right-associative, so 2^3^4 becomes 2 3 4 ^ ^.
    CMP CURRENT_OPERATOR, '^'
    JE CT_PUSH_OPERATOR

CT_POP_OPERATOR:
    ; AL still holds the peeked stack operator. Remove it from the stack and
    ; append its token, then compare the next top against the SAME incoming
    ; operator. SI/CX have not consumed that incoming operator yet.
    DEC OP_TOP
    CALL APPEND_OPERATOR
    JC CT_INVALID
    JMP CT_COMPARE_TOP

CT_PUSH_OPERATOR:
    ; Check capacity and store the saved incoming operator at the next free
    ; stack slot. Consume its character and require another operand afterward.
    XOR BX, BX
    MOV BL, OP_TOP
    CMP BX, MAX_INPUT
    JAE CT_INVALID
    MOV AL, CURRENT_OPERATOR
    MOV OPERATOR_STACK[BX], AL
    INC OP_TOP
    MOV EXPECT_OPERAND, 1
    INC SI
    DEC CX
    JMP CT_NEXT

CT_END_INPUT:
    ; A valid expression ends after an operand/group. Reject empty input,
    ; spaces-only input and trailing operators before draining the stack.
    CMP EXPECT_OPERAND, 0
    JE CT_EMPTY_STACK
    JMP CT_INVALID

CT_EMPTY_STACK:
    ; Emit remaining operators in last-in, first-out order. Any leftover '('
    ; means an unmatched opening parenthesis, so report invalid input instead.
    CMP OP_TOP, 0
    JE CT_FINISH
    DEC OP_TOP
    XOR BX, BX
    MOV BL, OP_TOP
    MOV AL, OPERATOR_STACK[BX]
    CMP AL, '('
    JE CT_INVALID
    CALL APPEND_OPERATOR
    JC CT_INVALID
    JMP CT_EMPTY_STACK

CT_FINISH:
    ; Replace the final separator with DOS's string terminator.
    ; OUTPUT_LENGTH counts every appended byte, including that trailing space.
    ; Guard against empty output, then overwrite its last byte with '$'.
    MOV BX, OUTPUT_LENGTH
    CMP BX, 0
    JE CT_INVALID
    DEC BX
    MOV POSTFIX_BUFFER[BX], '$'
    ; CLC reports success and skips the failure flag below.
    CLC
    JMP CT_RETURN

CT_INVALID:
    ; Set carry for any grammar, grouping, stack-capacity or output-capacity
    ; failure. The caller does not print partially constructed postfix text.
    STC

CT_RETURN:
    ; Restore words in reverse PUSH order without changing the carry result.
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
CONVERT_TO_POSTFIX ENDP

; Append the operator in AL followed by one separator space.
APPEND_OPERATOR PROC NEAR
    ; Append AL, then a separating space. Propagate a failed first append
    ; immediately; otherwise the second append determines the returned CF.
    ; CALL/RET do not alter carry. AL becomes a space on the second call.
    CALL APPEND_OUTPUT
    JC AO_RETURN
    MOV AL, ' '
    CALL APPEND_OUTPUT
AO_RETURN:
    RET
APPEND_OPERATOR ENDP

; Append AL to POSTFIX_BUFFER. Returns CF set if the buffer is full.
APPEND_OUTPUT PROC NEAR
    ; Preserve BX while using the current output length as an array index.
    ; Reserve at least one slot by accepting indices strictly below 169
    ; (MAX_OUTPUT-1). No write occurs once that bound has been reached.
    PUSH BX

    MOV BX, OUTPUT_LENGTH
    CMP BX, MAX_OUTPUT-1
    JAE AO_FULL
    ; Store one byte and advance the count. Successful appends explicitly clear CF.
    MOV POSTFIX_BUFFER[BX], AL
    INC OUTPUT_LENGTH
    CLC
    JMP AO_DONE

AO_FULL:
    ; Set CF to report that the requested byte was not stored.
    STC
AO_DONE:
    ; POP preserves CF, so either success or failure survives the return.
    POP BX
    RET
APPEND_OUTPUT ENDP

; Input: AL = operator. Output: AH = precedence (1, 2, or 3).
GET_PRECEDENCE PROC NEAR
    ; Try priority 1 for +/-, then 2 for */. Remaining validated operators
    ; receive 3 for '^'; this helper itself does not validate unknown codes.
    MOV AH, 1
    CMP AL, '+'
    JE GP_DONE
    CMP AL, '-'
    JE GP_DONE
    MOV AH, 2
    CMP AL, '*'
    JE GP_DONE
    CMP AL, '/'
    JE GP_DONE
    MOV AH, 3
GP_DONE:
    RET
GET_PRECEDENCE ENDP

PRINT_STRING PROC NEAR
    ; Caller supplies DS:DX pointing to '$'-terminated text. DOS service 09H
    ; prints it; this small helper does not preserve AX (unlike Q4/Q5 helpers).
    MOV AH, 09H
    INT 21H
    RET
PRINT_STRING ENDP

CODESEG ENDS
; ENDP/ENDS close assembler declarations; END closes the module and names START.
END START
