; Question 4
; Interactive unsigned 8-bit calculator supporting +, -, * and /.
;
; Flow: initialize DS -> read operand 1 -> read operator -> read operand 2 ->
; select the arithmetic branch -> print its result -> return a DOS exit code.
; Inputs are bytes (0..255), but word storage/arithmetic retains full results:
; addition reaches 510, multiplication reaches 65025, and subtraction may
; need a printed minus sign. Division prints both quotient and remainder.
; AX/BX/CX/DX are 16-bit registers; AH/AL etc. are their upper/lower bytes.
; H marks hexadecimal constants; unmarked numeric constants here are decimal.

; SEGMENT/ENDS declare sections for the assembler. PARA requests 16-byte
; alignment; STACK lets the linker supply initial SS:SP in the .EXE header.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; 128 words (DW) reserve 256 stack bytes for saved registers and return
    ; addresses. DUP repeats the item; ? leaves its initial value unspecified.
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; PUBLIC permits linker combination with compatible segments. DB stores
    ; bytes/character codes; DOS string service 09H stops at '$'. Values
    ; 13 and 10 are carriage return and line feed, forming a DOS newline.
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

; DW reserves two bytes per value; DB reserves one. Storing byte inputs as
; words simplifies later word arithmetic and preserves results wider than AL.
OPERAND1 DW 0
OPERAND2 DW 0
OPERATOR DB 0
QUOTIENT DW 0
REMAINDER DW 0
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME informs the assembler about intended segment-register use;
    ; it does not initialize DS or execute any instructions at run time.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    ; DOS initializes CS and SS from the .EXE header, but DS initially points
    ; to the program segment prefix. Load DATASEG through AX because a segment
    ; register cannot be loaded directly with an immediate value by MOV.
    MOV AX, DATASEG
    MOV DS, AX

    ; LEA supplies an offset in DX; PRINT_STRING prints the text at DS:DX.
    ; CALL saves a return address on the stack; RET returns to the next line.
    LEA DX, Q4_TITLE
    CALL PRINT_STRING
    LEA DX, Q4_RANGE
    CALL PRINT_STRING

    ; Prompt for a byte and test the procedure's carry flag (CF). JNC jumps
    ; on success (CF=0); otherwise the unconditional JMP reports bad input.
    LEA DX, FIRST_PROMPT
    CALL PRINT_STRING
    CALL READ_BYTE
    JNC FIRST_OK
    JMP BAD_INPUT
FIRST_OK:
    ; Zero-extend AL to AX and keep the first operand in word-sized memory.
    XOR AH, AH
    MOV OPERAND1, AX
    CALL PRINT_NEWLINE

    ; READ_OPERATOR requires one of the four supported characters; save it
    ; separately so subsequent input and DOS services cannot overwrite it.
    LEA DX, OPERATOR_PROMPT
    CALL PRINT_STRING
    CALL READ_OPERATOR
    JNC OPERATOR_OK
    JMP BAD_OPERATOR
OPERATOR_OK:
    MOV OPERATOR, AL
    CALL PRINT_NEWLINE

    ; Read and validate the second operand in the same way as the first.
    LEA DX, SECOND_PROMPT
    CALL PRINT_STRING
    CALL READ_BYTE
    JNC SECOND_OK
    JMP BAD_INPUT
SECOND_OK:
    ; Clear AH to ensure the stored word contains the unsigned value 0..255.
    XOR AH, AH
    MOV OPERAND2, AX
    CALL PRINT_NEWLINE

    ; Dispatch by ASCII operator code. CMP sets flags without modifying AL;
    ; JE takes the matching branch. The final jump handles any unsupported code.
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
    ; Use word addition: 255+255=510 fits in AX even though it exceeds a byte.
    ; PRINT_STRING preserves AX, so the computed sum survives label printing.
    MOV AX, OPERAND1
    ADD AX, OPERAND2
    LEA DX, RESULT_LABEL
    CALL PRINT_STRING
    CALL PRINT_UINT
    CALL PRINT_NEWLINE
    JMP Q4_EXIT_OK

Q4_SUBTRACT:
    ; Compare unsigned operands before subtraction. If the first is smaller,
    ; print '-' and calculate second-first as a positive magnitude instead
    ; of printing an unsigned wraparound result. Equality takes the zero path.
    LEA DX, RESULT_LABEL
    CALL PRINT_STRING
    MOV AX, OPERAND1
    CMP AX, OPERAND2
    JAE Q4_SUB_POSITIVE
    ; PRINT_CHAR preserves AX/DX; explicitly load the larger operand afterward
    ; and compute the magnitude for PRINT_UINT, which prints no sign itself.
    MOV DL, '-'
    CALL PRINT_CHAR
    MOV AX, OPERAND2
    SUB AX, OPERAND1
    JMP SHORT Q4_SUB_PRINT
Q4_SUB_POSITIVE:
    ; JAE means unsigned 'above or equal': first-second is nonnegative here.
    SUB AX, OPERAND2
Q4_SUB_PRINT:
    ; Both subtraction paths arrive with the magnitude in AX. SHORT on a
    ; nearby JMP selects a short relative encoding, not a different operation.
    CALL PRINT_UINT
    CALL PRINT_NEWLINE
    JMP SHORT Q4_EXIT_OK

Q4_MULTIPLY:
    ; Word MUL implicitly multiplies AX by BX, returning the 32-bit product
    ; in DX:AX. With inputs <=255 the product <=65025 fits in AX and DX is zero.
    MOV AX, OPERAND1
    MOV BX, OPERAND2
    MUL BX
    LEA DX, RESULT_LABEL
    CALL PRINT_STRING
    CALL PRINT_UINT
    CALL PRINT_NEWLINE
    JMP SHORT Q4_EXIT_OK

Q4_DIVIDE:
    ; Check the divisor before DIV to avoid a CPU divide error on zero.
    CMP OPERAND2, 0
    JE Q4_DIVIDE_ZERO
    MOV AX, OPERAND1
    ; Word DIV divides DX:AX by the word OPERAND2. Clear DX so the dividend
    ; is only operand 1; quotient returns in AX and remainder in DX.
    XOR DX, DX
    DIV OPERAND2
    ; Save both results before loading DX with label addresses. Print them
    ; separately as unsigned decimal integers, preserving integer remainder.
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
    ; These error paths print the appropriate explanation, then terminate;
    ; the calculator does not retry or start another calculation in this run.
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
    ; The operand input already ended with a newline, so print this error directly.
    LEA DX, DIVIDE_ZERO
    CALL PRINT_STRING
Q4_EXIT_ERROR:
    ; DOS service AH=4CH terminates; AL=01H returns failure status 1.
    MOV AX, 4C01H
    INT 21H
Q4_EXIT_OK:
    ; AL=00H returns success status 0 through the same termination service.
    MOV AX, 4C00H
    INT 21H

; Read one decimal byte with DOS buffered keyboard input.
; Accepts 1 to 3 decimal digits, rejects non-digits and values above 255.
; Returns: AX = value and CF clear, or CF set for invalid input.
; Preserves: BX, CX, DX, SI, and DI.
READ_BYTE PROC NEAR
    ; Save the caller's working registers on SS:SP; restore in reverse order.
    ; AX is deliberately not saved because it carries the numeric return value.
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI

    ; DOS service 0AH reads and echoes a buffered line at DS:DX. Its two-byte
    ; header contains the capacity and returned length; characters start at +2.
    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    ; Load the returned length into CX with CH=0. OR tests for zero without
    ; changing CX; JZ rejects empty input, and unsigned JA rejects >3 digits.
    XOR CX, CX
    MOV CL, INPUT_BUFFER+1
    OR CX, CX
    JZ RB_BAD
    CMP CX, 3
    JA RB_BAD

    ; SI addresses the first character; BX starts the accumulated value at zero.
    LEA SI, INPUT_BUFFER+2
    XOR BX, BX
RB_DIGIT:
    ; Compare unsigned ASCII codes: accept only consecutive codes '0'..'9'.
    ; Subtract '0' to obtain a digit and zero DH to make DX a word from 0 to 9.
    MOV DL, [SI]
    CMP DL, '0'
    JB RB_BAD
    CMP DL, '9'
    JA RB_BAD
    SUB DL, '0'
    XOR DH, DH
    ; Save the digit in DI because the following word multiplication replaces DX.
    MOV DI, DX

    ; Calculate old*10+digit. MUL DX uses AX*DX and returns DX:AX; all prior
    ; values were <=255, so the intermediate <=2559 fits in AX without loss.
    MOV AX, BX
    MOV DX, 10
    MUL DX
    ADD AX, DI
    ; Reject values above the byte limit, then retain this partial value in BX.
    CMP AX, 255
    JA RB_BAD
    MOV BX, AX

    ; Advance one character. LOOP decrements CX and repeats while nonzero.
    INC SI
    LOOP RB_DIGIT
    ; Return the accumulated number and clear CF to signal successful parsing.
    MOV AX, BX
    CLC
    JMP SHORT RB_DONE
RB_BAD:
    ; Set carry for failure; AX is not a valid result on this path.
    STC
RB_DONE:
    ; POP and RET preserve CF, allowing the caller's JNC to test the result.
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
    ; Preserve the caller's working registers; return the chosen character in AL.
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    ; Read a separate DOS buffered line for the operator rather than leaving
    ; extra typed characters for the next operand's input call.
    LEA DX, OPERATOR_BUFFER
    MOV AH, 0AH
    INT 21H

    ; The returned length excludes CR. Require exactly one character, then
    ; compare it with each allowed operator; JE accepts an exact match.
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
    ; Explicitly clear carry on a match, bypassing the failure flag below.
    CLC
    JMP SHORT RO_DONE
RO_BAD:
    ; Set carry for a wrong length or unsupported character.
    STC
RO_DONE:
    ; Restore registers in reverse PUSH order without changing the return flag.
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_OPERATOR ENDP

; Print the dollar-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    ; Save AX/DX, select DOS service 09H, and print the '$'-terminated text
    ; addressed by DS:DX. Preserving AX keeps calculated results intact.
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
    ; Save AX/DX, select service 02H to print DL, then restore both registers.
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
    ; Save AX/DX. Print CR (13) to return to column 0, then LF (10) to move
    ; down one line; DOS service 02H prints the character supplied in DL.
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
    ; Save the caller's registers. BX is the decimal divisor, and CX counts
    ; the remainders stored temporarily on the CPU stack.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    MOV BX, 10
    XOR CX, CX
PU_DIVIDE:
    ; Clear DX on every pass: DIV BX divides DX:AX by ten, returning the
    ; quotient in AX and a remainder digit 0..9 in DX. Push each digit so
    ; later POPs reverse their extraction order for left-to-right printing.
    XOR DX, DX
    DIV BX
    PUSH DX
    INC CX
    ; OR tests the quotient without changing it; JNZ continues if nonzero.
    ; Zero input still executes once, ensuring a single '0' is printed.
    OR AX, AX
    JNZ PU_DIVIDE
PU_DIGIT:
    ; Pop a digit, add ASCII '0', and print it through service 02H.
    ; LOOP decrements CX until every saved digit has been printed.
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PU_DIGIT

    ; With the digit words removed, restore the original register words.
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_UINT ENDP

CODESEG ENDS
; ENDP/ENDS end declarations; END closes the source and names START as entry.
END START
