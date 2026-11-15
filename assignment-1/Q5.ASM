; Question 5
; Interactive string operations: length, comparison, and reversal.
; Self-contained: STRLEN, STRCMP, STRREV, and all keyboard/screen I/O
; live in this one file (no INCLUDE, no separate library).
;
; Flow: initialize DS -> read two lines -> replace their CRs with zero bytes ->
; measure each string -> compare them -> reverse string 1 -> print it -> exit.
; User strings use a zero terminator; fixed screen messages use '$'. These
; are different conventions, so the program has a separate printer for each.
; AX/BX/CX/DX are 16-bit registers; AH/AL etc. are their upper/lower bytes.
; H marks hexadecimal constants. DS:SI means a segment plus an offset.

; SEGMENT/ENDS declare assembler sections. PARA requests 16-byte alignment;
; STACK lets the linker record initial SS:SP for the DOS .EXE loader.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW reserves words: 128 words provide 256 stack bytes for CALL/PUSH.
    ; DUP repeats the declaration; ? leaves the initial contents unspecified.
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; PUBLIC allows compatible segments to be combined by the linker.
    ; DB stores bytes/character codes. Service 09H prints until '$'; 13/10
    ; are carriage return/line feed, used together to start a new output line.
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
    ; The displayed limit is 30, but READ_STRING does not explicitly reject
    ; lengths above 30; actual input capacity is controlled by these buffers.

DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME describes intended segment-register use to the assembler;
    ; it performs no runtime initialization of DS.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    ; DOS .EXE startup sets CS/SS from the header; DS initially points to the
    ; program segment prefix. Move DATASEG through AX because MOV cannot load
    ; DS directly from an immediate value, then DS can address the data here.
    MOV AX, DATASEG
    MOV DS, AX

    ; LEA loads an offset, not the bytes at that address. PRINT_STRING uses
    ; DS:DX. CALL saves a return address on the stack; RET resumes after CALL.
    LEA DX, Q5_TITLE
    CALL PRINT_STRING
    LEA DX, Q5_RANGE
    CALL PRINT_STRING

    ; Read each string into its own DOS buffer. READ_STRING changes the
    ; trailing carriage return into a zero byte for the string algorithms.
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

    ; Skip the two-byte DOS header to address string 1's characters.
    ; STRLEN returns the count in AX; PRINT_STRING preserves AX while the
    ; label is printed, so PRINT_UINT still receives the correct length.
    LEA SI, STRING1_BUFFER+2
    CALL STRLEN
    LEA DX, LEN1_LABEL
    CALL PRINT_STRING
    CALL PRINT_UINT
    CALL PRINT_NEWLINE

    ; Repeat the same measurement and decimal display for string 2.
    LEA SI, STRING2_BUFFER+2
    CALL STRLEN
    LEA DX, LEN2_LABEL
    CALL PRINT_STRING
    CALL PRINT_UINT
    CALL PRINT_NEWLINE

    ; Compare character codes lexicographically, using SI for string 1 and DI
    ; for string 2. The first differing byte decides the result; matching
    ; prefixes make the shorter string smaller. Comparison is case-sensitive.
    LEA SI, STRING1_BUFFER+2
    LEA DI, STRING2_BUFFER+2
    CALL STRCMP
    ; PRINT_STRING preserves AX, so printing the label keeps the comparison
    ; result. FFFFH represents -1 in 16-bit two's complement; 0 means equal;
    ; the remaining result, 1, means greater. JE selects exact result values.
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
    ; Print the matching description, then converge on the reversal step.
    LEA DX, CMP_LESS
    CALL PRINT_STRING
    JMP SHORT Q5_REVERSE
Q5_EQUAL:
    ; Equality falls through directly into Q5_REVERSE after its description.
    LEA DX, CMP_EQUAL
    CALL PRINT_STRING

Q5_REVERSE:
    ; Reverse string 1 in its own character area; string 2 is not modified.
    ; PRINT_Z uses a zero terminator, so a '$' inside user text is printable.
    LEA SI, STRING1_BUFFER+2
    CALL STRREV
    LEA DX, REV_LABEL
    CALL PRINT_STRING
    LEA DX, STRING1_BUFFER+2
    CALL PRINT_Z
    CALL PRINT_NEWLINE

    ; AH=4CH terminates the process through DOS; AL=00H returns success.
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
    ; Save the caller's working registers; the returned string lives in memory.
    PUSH AX
    PUSH BX
    PUSH SI

    ; DOS service 0AH reads and echoes the line at DS:DX. The returned length
    ; excludes the CR; the typed characters occupy offsets +2 through +1+length.
    MOV AH, 0AH
    INT 21H

    ; SI starts at the buffer header. Zero-extend the length byte into BX,
    ; then header+length+2 locates the trailing CR to overwrite with zero.
    ; BYTE PTR explicitly requests a one-byte store of the immediate zero.
    MOV SI, DX
    XOR BX, BX
    MOV BL, [SI+1]
    ADD SI, BX
    MOV BYTE PTR [SI+2], 0

    ; Restore saved words in reverse order; RET returns to the instruction
    ; following the caller's CALL within this code segment (PROC NEAR).
    POP SI
    POP BX
    POP AX
    RET
READ_STRING ENDP

; Input:  DS:SI -> zero-terminated string
; Output: AX = character count (terminating zero is not counted)
; SI is preserved.
STRLEN PROC NEAR
    ; Preserve the starting pointer and initialize the returned count to zero.
    PUSH SI
    XOR AX, AX
SL_NEXT:
    ; Test the byte at DS:SI before counting it, so empty strings return zero
    ; and the terminating zero is never included. BYTE PTR selects byte size.
    CMP BYTE PTR [SI], 0
    JE SL_DONE
    ; Move one byte forward and count it; repeat until the terminator is found.
    INC SI
    INC AX
    JMP SHORT SL_NEXT
SL_DONE:
    ; Restore the original pointer but leave the count in AX for the caller.
    POP SI
    RET
STRLEN ENDP

; Input:  DS:SI -> first string, DS:DI -> second string
; Output: AX = FFFFH if first < second, 0000H if equal, 0001H if first > second
; SI and DI are preserved.
STRCMP PROC NEAR
    ; Preserve scratch BX and both starting pointers; AX carries the result.
    PUSH BX
    PUSH SI
    PUSH DI
SC_NEXT:
    ; Read corresponding character bytes. CMP sets flags without changing
    ; them; JB/JA compare unsigned byte values, rather than signed characters.
    MOV AL, [SI]
    MOV BL, [DI]
    CMP AL, BL
    JB SC_LESS
    JA SC_GREATER
    ; Equal bytes may be the common terminator: OR tests AL for zero without
    ; changing it. If nonzero, advance both pointers and compare the next pair.
    ; If only one string ended, the earlier unsigned comparison already chose
    ; the shorter string because its zero byte is below a nonzero character.
    OR AL, AL
    JZ SC_EQUAL
    INC SI
    INC DI
    JMP SHORT SC_NEXT
SC_LESS:
    ; Return FFFFH (-1), 1, or 0 by selecting one of these three paths.
    MOV AX, 0FFFFH
    JMP SHORT SC_DONE
SC_GREATER:
    MOV AX, 1
    JMP SHORT SC_DONE
SC_EQUAL:
    XOR AX, AX
SC_DONE:
    ; Restore pointers and BX; AX is intentionally retained as the result.
    POP DI
    POP SI
    POP BX
    RET
STRCMP ENDP

; Input:  DS:SI -> writable zero-terminated string
; Output: AX = character count; the string is reversed in place.
; SI is preserved.
STRREV PROC NEAR
    ; Preserve all working registers except AX, which returns the string length.
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    ; STRLEN preserves SI. Save its returned length in DX because the swap
    ; loop uses AL/AH as temporary character storage and would overwrite AX.
    CALL STRLEN
    MOV DX, AX
    CMP AX, 1
    ; Unsigned JBE skips empty and one-character strings: neither needs swaps.
    ; This also avoids forming a last-character pointer before an empty string.
    JBE SR_DONE
    ; DI = start+length-1 points to the last character, not the zero terminator.
    MOV DI, SI
    ADD DI, AX
    DEC DI
    MOV CX, AX
    ; SHR divides this nonnegative length by two, discarding any odd remainder.
    ; floor(length/2) swaps reverse the ends; an odd middle byte stays in place.
    SHR CX, 1
SR_SWAP:
    ; Load both end characters before writing either one, then exchange them.
    MOV AL, [SI]
    MOV AH, [DI]
    MOV [SI], AH
    MOV [DI], AL
    ; Move both pointers inward. LOOP decrements CX and repeats until the
    ; required pairs have been exchanged; the zero terminator stays untouched.
    INC SI
    DEC DI
    LOOP SR_SWAP
SR_DONE:
    ; Restore AX from the saved length before restoring the caller's DX.
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
    ; Preserve AX/DX and select DOS service 09H for fixed '$'-terminated text.
    ; AX preservation is needed when labels follow a length/comparison result.
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
    ; Preserve registers and copy the starting offset into SI, since DL will
    ; be reused for character output and can no longer hold part of the pointer.
    PUSH AX
    PUSH DX
    PUSH SI
    MOV SI, DX
PZ_NEXT:
    ; Stop at zero before printing. DOS service 02H prints one character from
    ; DL, allowing a literal '$' in user text to pass through normally.
    MOV DL, [SI]
    CMP DL, 0
    JE PZ_DONE
    MOV AH, 02H
    INT 21H
    ; Advance to the next character until the string terminator is reached.
    INC SI
    JMP SHORT PZ_NEXT
PZ_DONE:
    ; Restore the caller's original pointer and output registers.
    POP SI
    POP DX
    POP AX
    RET
PRINT_Z ENDP

; Print a carriage return and line feed.
PRINT_NEWLINE PROC NEAR
    ; Save AX/DX, then use DOS service 02H twice: CR (13) returns to column 0
    ; and LF (10) advances to the next line. Restore both registers afterward.
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
    ; Preserve all four registers. BX=10 is the decimal divisor; CX counts
    ; extracted digits temporarily stored as words on the CPU stack.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    MOV BX, 10
    XOR CX, CX
PU_DIVIDE:
    ; Clear DX before every word DIV: DX:AX is divided by BX, with quotient
    ; in AX and remainder 0..9 in DX. Push the remainders so they can later
    ; be printed in the reverse of their right-to-left extraction order.
    XOR DX, DX
    DIV BX
    PUSH DX
    INC CX
    ; Test the quotient without changing it. JNZ repeats while it is nonzero;
    ; input zero still passes through once, producing a single digit '0'.
    OR AX, AX
    JNZ PU_DIVIDE
PU_DIGIT:
    ; Pop a digit, add ASCII '0', print DL with service 02H, and decrement CX
    ; through LOOP until all digit words have been removed from the stack.
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PU_DIGIT

    ; Now restore the saved register words in reverse PUSH order.
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_UINT ENDP

CODESEG ENDS
; ENDP/ENDS close declarations; END closes the source and selects START as entry.
END START
