; Question 2
; Read twenty decimal bytes at DS:4000H and rearrange them so that
; a[0] < a[1] > a[2] < a[3] > ...
;
; Program flow:
;   1. Read twenty valid unsigned bytes into offsets 4000H..4013H of DATASEG.
;   2. Print the original array before modifying it.
;   3. Visit the nineteen adjacent pairs, alternating the desired comparison.
;   4. Swap a pair when necessary, print the rearranged array, and exit to DOS.
; With distinct values the comparisons are strict, as shown above. Equal
; neighbors remain equal when swapped. With duplicate input the guaranteed
; pattern is non-strict (<=, >=, <=, ...); strict signs are not guaranteed.
; AX, BX, CX and DX are 16-bit registers; AH/AL, BH/BL, CH/CL and DH/DL
; name their upper/lower bytes. An H suffix marks a hexadecimal constant.

; SEGMENT/ENDS delimit assembler segments; they do not execute on the CPU.
; PARA requests 16-byte alignment. STACK lets the linker identify the stack
; and record its initial SS:SP in the DOS .EXE header for the loader.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW declares 16-bit words: 128 words reserve 256 bytes for CALL/PUSH.
    ; DUP repeats the declaration; ? leaves the initial contents unspecified.
    ; RET/POP later remove return addresses/saved words from this same stack.
    DW 128 DUP (?)
STACKSEG ENDS

; PUBLIC allows compatible segments to be combined by the linker.
; DB declares bytes; quoted characters are stored as their character codes.
DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; DOS string output ends at '$' without printing that terminator.
    ; 13 is carriage return (column 0); 10 is line feed (the next line).
    Q2_TITLE      DB 13,10,'QUESTION 2 - 20-BYTE ZIG-ZAG ARRAY',13,10,'$'
    PROMPT_TEXT   DB 'Enter decimal byte (0-255): $'
    BAD_TEXT      DB 'Invalid input. Enter a value from 0 to 255.',13,10,'$'
    ORIGINAL_TEXT DB 'Original array: $'
    ZIGZAG_TEXT   DB 'Zig-zag array:  $'

    ; DOS function 0AH buffer: maximum length, actual length, characters.
    ; Empirically verified against this authentic DOSBox 0.74-3 / MASM 5.10
    ; environment (isolated minimal-repro test, not just this program):
    ; typing exactly maxlen characters never returns from INT 21H/AH=0AH
    ; here, even after extra Enter presses and multi-second waits, while
    ; entering fewer than maxlen characters completes normally. Valid input
    ; is 1-3 decimal digits, so maxlen=6 leaves generous headroom (+3 over
    ; the longest valid input), matching Q4's identical INPUT_BUFFER. The
    ; char area is sized maxlen+1 (7) to also hold the CR DOS writes after
    ; the typed characters.
    INPUT_BUFFER  DB 6,0,7 DUP (0)

    ; ORG sets the assembler's location counter to offset 4000H in DATASEG.
    ; The twenty zero-initialized bytes occupy 4000H..4013H (20 = 14H).
    ; These are offsets relative to DS, not absolute physical memory addresses.
    ORG 4000H
ZIGZAG_ARRAY DB 20 DUP (0)
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME tells the assembler the intended segment-register associations.
    ; It does not load registers; DS must still be initialized at run time.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    ; DOS initializes CS and SS from the .EXE header, but DS initially points
    ; to the program segment prefix, not DATASEG. Load DS through AX because
    ; the CPU cannot move an immediate segment address directly into DS.
    MOV AX, DATASEG
    MOV DS, AX

    ; LEA obtains the title's offset, not the text itself. DS:DX identifies
    ; the string for PRINT_STRING. CALL saves a return address on the stack;
    ; the procedure's RET resumes execution at the instruction after CALL.
    LEA DX, Q2_TITLE
    CALL PRINT_STRING

    ; DI points to the next array slot; CX counts the remaining valid inputs.
    ; READ_BYTE saves both registers, so parsing cannot disturb this state.
    MOV DI, 4000H
    MOV CX, 20
INPUT_LOOP:
    ; Print the prompt and read one decimal number. READ_BYTE returns AX as
    ; the value and clears CF (carry flag) if valid; otherwise it sets CF.
    LEA DX, PROMPT_TEXT
    CALL PRINT_STRING
    CALL READ_BYTE
    ; JNC means jump if carry is clear. Valid input goes to INPUT_OK;
    ; invalid input follows the unconditional JMP to the retry handler.
    JNC INPUT_OK
    JMP BAD_INPUT
INPUT_OK:
    ; [DI] addresses DS:DI; using AL makes this a one-byte store.
    ; Advance one slot, print a newline, and count this successful input.
    MOV [DI], AL
    INC DI
    CALL PRINT_NEWLINE
    ; LOOP decrements CX and jumps while it is nonzero. After twenty valid
    ; values, skip BAD_INPUT and display the original array instead.
    LOOP INPUT_LOOP
    JMP SHORT SHOW_ORIGINAL
BAD_INPUT:
    ; Show the error and prompt again for the same slot. This path neither
    ; increments DI nor decrements CX, so invalid entries do not count.
    CALL PRINT_NEWLINE
    LEA DX, BAD_TEXT
    CALL PRINT_STRING
    JMP INPUT_LOOP

SHOW_ORIGINAL:
    ; Print a label, point SI at the array, and display all twenty bytes.
    ; PRINT_ARRAY preserves SI and the caller's other saved registers.
    LEA DX, ORIGINAL_TEXT
    CALL PRINT_STRING
    MOV SI, 4000H
    CALL PRINT_ARRAY
    CALL PRINT_NEWLINE

    ; Main assignment algorithm: rearrange the array in place in one pass.
    ; SI points to the left byte of a pair. Twenty bytes have nineteen pairs.
    ; BL is the zero-based pair index: even means want '<', odd means want '>'.
    ; XOR BL,BL sets BL to zero without needing a separate zero constant.
    MOV SI, 4000H
    MOV CX, 19
    XOR BL, BL
ZIGZAG_LOOP:
    ; Load adjacent bytes into AL (left) and AH (right), without changing memory.
    MOV AL, [SI]
    MOV AH, [SI+1]
    ; TEST checks BL's low bit without changing BL. Bit 0 is clear for even
    ; indices and set for odd indices; JNZ selects the odd-pair comparison.
    TEST BL, 1
    JNZ WANT_GREATER
    ; Even pair: keep it if left < right. CMP changes flags, not AL or AH;
    ; JB tests unsigned 'below', appropriate because the bytes are 0..255.
    ; Otherwise jump to the swap. SHORT selects a nearby relative jump.
    CMP AL, AH
    JB PAIR_OK
    JMP SHORT SWAP_PAIR
WANT_GREATER:
    ; Odd pair: keep it if left > right. JA tests unsigned 'above'.
    ; If left <= right, fall through into SWAP_PAIR without a separate jump.
    CMP AL, AH
    JA PAIR_OK
SWAP_PAIR:
    ; Exchange the two memory values using the copies already in AL and AH.
    ; On equality this writes identical values, leaving the pair unchanged.
    ; A swap preserves the preceding pair's non-strict relation: fixing an
    ; even pair makes its left value smaller, preserving the previous '>=';
    ; fixing an odd pair makes its left value larger, preserving the previous
    ; '<='. Thus earlier pairs need not be revisited or the array fully sorted.
    MOV [SI], AH
    MOV [SI+1], AL
PAIR_OK:
    ; Move one byte to the next overlapping pair and flip parity by increasing
    ; BL. LOOP decrements CX and repeats until all nineteen pairs are checked.
    ; This uses O(n) time and constant extra storage; no second array is needed.
    INC SI
    INC BL
    LOOP ZIGZAG_LOOP

    ; Show the final array from the same starting offset, followed by a newline.
    LEA DX, ZIGZAG_TEXT
    CALL PRINT_STRING
    MOV SI, 4000H
    CALL PRINT_ARRAY
    CALL PRINT_NEWLINE

    ; DOS function AH=4CH terminates the process; AL=00H returns success status.
    MOV AX, 4C00H
    INT 21H

; Print the dollar-terminated string at DS:DX.
; PROC NEAR declares a procedure within the current code segment.
PRINT_STRING PROC NEAR
    ; Save the caller's AX, CX and DX before selecting DOS service 09H.
    ; In particular, preserving CX protects loops that call this helper.
    PUSH AX
    PUSH CX
    PUSH DX
    MOV AH, 09H
    INT 21H
    ; Restore words in reverse PUSH order, then return to the caller.
    POP DX
    POP CX
    POP AX
    RET
PRINT_STRING ENDP

; Print a carriage return and line feed.
PRINT_NEWLINE PROC NEAR
    ; Preserve the registers used by this helper and the caller's loop counter.
    PUSH AX
    PUSH CX
    PUSH DX
    ; DOS service AH=02H prints one character from DL. First return to column 0.
    MOV DL, 13
    MOV AH, 02H
    INT 21H
    ; Then advance to the next line. Reload AH to select the character service.
    MOV DL, 10
    MOV AH, 02H
    INT 21H
    ; Restore the caller's register values and return.
    POP DX
    POP CX
    POP AX
    RET
PRINT_NEWLINE ENDP

; Read one decimal byte with DOS buffered keyboard input.
; Returns: AX = value and CF clear, or CF set for invalid input.
; Preserves: BX, CX, DX, SI, and DI.
READ_BYTE PROC NEAR
    ; Keep the outer array pointer and count safe while reusing these registers
    ; for parsing. Each PUSH saves a word; matching POPs use reverse order.
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI

    ; DS:DX points to the input buffer described above. DOS service 0AH reads
    ; and echoes a line, returning a count and characters after Enter is pressed.
    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    ; Clear all of CX before loading its low byte with the returned length.
    ; INPUT_BUFFER+1 refers to the count byte, which excludes the final CR.
    ; OR CX,CX leaves CX unchanged but sets ZF (zero flag) for an empty input.
    XOR CX, CX
    MOV CL, INPUT_BUFFER+1
    OR CX, CX
    ; Reject empty text with JZ, or more than three characters with unsigned JA.
    ; The character loop below separately checks digits and the numeric range.
    JZ READ_BAD
    CMP CX, 3
    JA READ_BAD

    ; Skip the two header bytes to reach the first character. BX starts at
    ; zero and will hold the numeric value accumulated from accepted digits.
    LEA SI, INPUT_BUFFER+2
    XOR BX, BX
READ_DIGIT:
    ; ASCII digit codes are consecutive. Reject any character outside '0'..'9'
    ; with unsigned JB/JA, including signs, spaces and decimal points.
    MOV DL, [SI]
    CMP DL, '0'
    JB READ_BAD
    CMP DL, '9'
    JA READ_BAD
    ; Convert the character code to a numeric digit by subtracting ASCII '0'.
    ; Clear DH so DX contains just 0..9, then save it in DI before MUL uses DX.
    SUB DL, '0'
    XOR DH, DH
    MOV DI, DX

    ; Decimal accumulation: new value = old value * 10 + current digit.
    ; Word MUL implicitly multiplies AX by DX and writes the 32-bit result
    ; into DX:AX (high word in DX, low word in AX), replacing the old DX.
    ; The saved digit in DI therefore survives multiplication by ten.
    MOV AX, BX
    MOV DX, 10
    MUL DX
    ADD AX, DI
    ; Each prior accepted value is <=255, so this intermediate is <=2559:
    ; it fits in AX and the high product word is zero. Reject anything >255
    ; before accepting it as the next accumulated unsigned-byte value.
    CMP AX, 255
    JA READ_BAD
    MOV BX, AX

    ; Advance to the next character; LOOP consumes one count from CX.
    INC SI
    LOOP READ_DIGIT
    ; After every digit passes, return the value in AX and explicitly clear
    ; carry with CLC. Jump over READ_BAD so success does not execute STC.
    MOV AX, BX
    CLC
    JMP SHORT READ_DONE
READ_BAD:
    ; STC sets carry to signal failure; AX has no valid returned value here.
    STC
READ_DONE:
    ; POP and RET do not alter CF, so the caller's JNC sees the result flag
    ; even after these saved registers have been restored.
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_BYTE ENDP

; Print the unsigned byte in AL as decimal.
PRINT_BYTE PROC NEAR
    ; Save AX/BX/CX/DX so conversion does not disturb the caller's values.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    ; Clear AH to extend AL to the unsigned 16-bit value AX=0..255.
    ; BX=10 selects decimal conversion; CX counts how many digits are saved.
    XOR AH, AH
    MOV BX, 10
    XOR CX, CX
PRINT_DIVIDE:
    ; Word DIV divides DX:AX by BX. Clear DX before every division so the
    ; dividend is the current quotient in AX, with no leftover high word.
    ; DIV returns the new quotient in AX and the remainder (digit 0..9) in DX.
    XOR DX, DX
    DIV BX
    ; Digits emerge rightmost first. Stack them to reverse their print order,
    ; counting one saved word per digit in CX.
    PUSH DX
    INC CX
    ; OR tests whether the quotient is zero without changing AX; JNZ repeats
    ; while digits remain. Input zero still runs once and saves a zero digit.
    OR AX, AX
    JNZ PRINT_DIVIDE
PRINT_DIGIT:
    ; Pop the leftmost remaining digit, add ASCII '0' to make a character,
    ; and print DL with DOS service 02H. LOOP prints all CX saved digits.
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PRINT_DIGIT

    ; The temporary digit words are gone, exposing the saved registers again.
    ; Restore them in reverse order, including the caller's original AX.
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_BYTE ENDP

; Print exactly twenty decimal bytes starting at DS:SI.
PRINT_ARRAY PROC NEAR
    ; Save the caller's registers and initial array offset. PRINT_BYTE saves
    ; its own BX, so this procedure has no need to modify or save BX itself.
    PUSH AX
    PUSH CX
    PUSH DX
    PUSH SI

    ; Use a local count of twenty elements, regardless of the caller's CX.
    MOV CX, 20
PRINT_ARRAY_NEXT:
    ; Fetch one byte at DS:SI and print its unsigned decimal representation.
    ; PRINT_BYTE clears AH internally and restores CX, preserving this loop.
    MOV AL, [SI]
    CALL PRINT_BYTE
    ; Print a separating space with DOS service 02H, also after the last byte.
    MOV DL, ' '
    MOV AH, 02H
    INT 21H
    ; Advance by one byte and continue until all twenty values are displayed.
    INC SI
    LOOP PRINT_ARRAY_NEXT

    ; Restore SI so printing does not consume the caller's array pointer;
    ; restore DX, CX and AX, then return to SHOW_ORIGINAL or the final display.
    POP SI
    POP DX
    POP CX
    POP AX
    RET
PRINT_ARRAY ENDP

CODESEG ENDS
; ENDP/ENDS close assembler declarations. END closes the source module and
; identifies START as the .EXE entry point; DOS service 4CH ends execution.
END START
