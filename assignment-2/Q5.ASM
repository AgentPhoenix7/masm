; Develop a MASM program that accepts a string consisting of multiple types of brackets (i.e., (), {}, []) and verifies whether they are balanced and properly nested. The program should simulate a stack-based approach to evaluate the expression, pushing opening brackets and popping when a matching closing bracket is found. The program should output either:
; a. Balanced - if all opening and closing brackets are matched correctly
; b. Non-Balanced

; Check whether (), {}, and [] brackets are balanced and properly nested.
; MASM 5.x / 8086 / DOS INT 21H
;
; Flow: initialize DS -> read one bracket string -> scan left to right ->
; push each opener or match/pop each closer -> require the stack to end empty.
; The stack holds only unmatched opening brackets. Its most recent item must
; match the next closing bracket, enforcing nesting as well as equal counts.
; Example: "([])" succeeds, but "([)]" fails when ')' encounters '[' on top.
; AX/BX/CX/DX are 16-bit registers; AH/AL etc. are their upper/lower bytes.
; H marks hexadecimal constants; DS:SI identifies a segment plus a byte offset.

; Simplified MASM directives: SMALL selects one code segment and one data
; group; .STACK reserves 100H=256 CPU-stack bytes for CALL/PUSH. These are
; assembly/linker declarations, not CPU instructions executed at run time.
.MODEL SMALL
.STACK 100H

MAX_INPUT EQU 80
; EQU is an assembly-time constant, allocating no separate storage.

.DATA
    ; .DATA begins the data section. DB stores bytes/character codes; fixed
    ; messages end in '$' for DOS service 09H. 13/10 are CR/LF for a newline.
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
    ; This software stack is separate from SS:SP. TOP_INDEX is its item count
    ; and next-free index; its current top is at index TOP_INDEX-1 when nonempty.

.CODE
; .CODE begins instructions. MAIN is the entry point named by END MAIN below.
MAIN PROC
    ; @DATA names the data group provided by .MODEL. DS initially points at
    ; the DOS program segment prefix; load @DATA via AX because MOV DS,immediate
    ; is not supported. DS can then address the buffers and messages here.
    MOV AX, @DATA
    MOV DS, AX

    ; LEA loads the string offset, not the string's bytes. PRINT_STRING uses
    ; DS:DX. CALL pushes a return address on SS:SP; RET resumes after CALL.
    LEA DX, TITLE_TEXT
    CALL PRINT_STRING

    LEA DX, PROMPT_TEXT
    CALL PRINT_STRING

    ; DOS service AH=0AH reads and echoes a buffered line at DS:DX. The
    ; returned length at +1 excludes CR; the character bytes begin at +2.
    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    ; Start with no unmatched openers. SI scans input bytes; zero-extend the
    ; returned length into CX so it counts exactly the characters to inspect.
    MOV TOP_INDEX, 0
    LEA SI, INPUT_BUFFER[2]
    XOR CX, CX
    MOV CL, INPUT_BUFFER[1]

    ; Empty input is balanced by this implementation. Skip LOOP on CX=0:
    ; entering a LOOP-controlled body with zero would underflow its counter.
    JCXZ CHECK_STACK_EMPTY

CHECK_NEXT_CHARACTER:
    ; Dispatch one ASCII bracket. CMP changes flags without modifying AL;
    ; JE jumps to the handler for an exact matching character code.
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
    ; Any other character, including a space, immediately reports Non-Balanced.
    JMP NON_BALANCED

PUSH_OPENING:
    ; Clear BH before loading the byte-sized index into BL. Check capacity
    ; with unsigned JAE before writing, then increment the count after the push.
    XOR BX, BX
    MOV BL, TOP_INDEX
    CMP BL, MAX_INPUT
    JAE NON_BALANCED
    MOV BRACKET_STACK[BX], AL
    INC TOP_INDEX
    JMP CHARACTER_DONE

CHECK_ROUND:
    ; Convert each kind of closer to its required opener in DL. The common
    ; checker can then compare a single expected character with the stack top.
    MOV DL, '('
    JMP CHECK_CLOSING

CHECK_CURLY:
    MOV DL, '{'
    JMP CHECK_CLOSING

CHECK_SQUARE:
    ; Fall through into CHECK_CLOSING after selecting the square-bracket opener.
    MOV DL, '['

CHECK_CLOSING:
    ; An empty stack means this closer has no opener. Otherwise decrement
    ; the count to pop, then inspect the removed top item at that new index.
    CMP TOP_INDEX, 0
    JE NON_BALANCED

    DEC TOP_INDEX
    XOR BX, BX
    MOV BL, TOP_INDEX
    ; Mismatched types fail immediately; a deeper matching opener cannot be
    ; used because that would cross nesting boundaries, as in "([)]".
    CMP BRACKET_STACK[BX], DL
    JNE NON_BALANCED

CHARACTER_DONE:
    ; Consume the current character. LOOP decrements CX and repeats while
    ; any input remains; each bracket is pushed or popped at most once.
    INC SI
    LOOP CHECK_NEXT_CHARACTER

CHECK_STACK_EMPTY:
    ; Leftover openers indicate missing closers. A completed scan with an
    ; empty stack is balanced. The scan is O(n), with up to O(n) stack storage.
    CMP TOP_INDEX, 0
    JNE NON_BALANCED

BALANCED:
    ; Print the success description and skip the failure-message path.
    LEA DX, BALANCED_TEXT
    CALL PRINT_STRING
    JMP EXIT_PROGRAM

NON_BALANCED:
    ; Any invalid character, underflow, mismatch, overflow, or leftover opener
    ; reaches this message; no retry is performed within the current run.
    LEA DX, NOT_BAL_TEXT
    CALL PRINT_STRING

EXIT_PROGRAM:
    ; DOS service AH=4CH terminates; AL=0 returns status 0 for BOTH outcomes.
    ; The printed description, rather than the exit status, reports balance.
    MOV AX, 4C00H
    INT 21H
MAIN ENDP

; Input: DS:DX points to a string terminated by '$'.
PRINT_STRING PROC NEAR
    ; Preserve AX while selecting DOS service 09H for '$'-terminated text.
    ; NEAR means a call within this code segment; POP restores AX before RET.
    PUSH AX
    MOV AH, 09H
    INT 21H
    POP AX
    RET
PRINT_STRING ENDP

; END closes the source module and identifies MAIN as the .EXE entry point.
END MAIN
