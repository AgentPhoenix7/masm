; Question 1
; Read 10 bytes, calculate (value * 5) + 10, and transfer the results.
;
; Program flow:
;   1. Read and validate ten decimal numbers, storing their byte values at 3000H.
;   2. Calculate (value * 5) + 10 for each source byte and store AL at 4000H.
;   3. Print the ten destination bytes in decimal and return control to DOS.
; All offsets below are relative to DS, not absolute physical memory addresses.
; AX, BX, CX and DX are 16-bit registers; AH/AL, BH/BL, CH/CL and DH/DL
; are their upper/lower 8-bit halves. H marks a hexadecimal numeric constant.

; SEGMENT/ENDS delimit a segment for the assembler; they are not CPU instructions.
; PARA requests a 16-byte-aligned segment. STACK identifies the stack segment
; so the linker can record the initial SS:SP values in the DOS .EXE header.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW reserves 16-bit words: 128 words provide 256 bytes for the stack.
    ; DUP repeats the declaration; ? means no initial value is specified.
    ; CALL/PUSH use this stack; RET/POP remove the saved values again.
    DW 128 DUP (?)
STACKSEG ENDS

; PUBLIC permits compatible data segments to be combined by the linker.
; DB declares individual bytes. Quoted text is stored as character codes.
DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; DOS function 09H prints until '$'; the terminator itself is not printed.
    ; 13 is carriage return (column 0); 10 is line feed (the next line).
    TITLE_TEXT  DB 13,10,'QUESTION 1 - BLOCK TRANSFER',13,10,'$'
    PROMPT_TEXT DB 'Enter a byte (0-255): $'
    OUTPUT_TEXT DB 'Output: $'
    ERROR_TEXT  DB 'ERROR: enter a decimal number from 0 to 255.$'
    NEWLINE     DB 13,10,'$'

    ; DOS function 0AH expects: maximum buffer size, returned character count,
    ; then the characters themselves followed by a carriage return.
    ; Maximum 4 includes room for that return, allowing three typed digits.
    ; The returned count excludes the return. Five bytes are allocated after
    ; the two header bytes, giving more character storage than DOS needs here.
    INPUT_BUFFER DB 4,0,5 DUP (0)

    ; ORG advances the assembler's location counter within DATASEG to 3000H.
    ; SOURCE_BYTES names ten consecutive bytes, at offsets 3000H..3009H.
    ; Their initial contents are unspecified; input will overwrite each byte.
    ORG 3000H
SOURCE_BYTES DB 10 DUP (?)

    ; Place the destination at offsets 4000H..4009H in the same data segment.
    ; These ten bytes start at zero and are overwritten by the transfer loop.
    ORG 4000H
DEST_BYTES DB 10 DUP (0)
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME tells the assembler which segments the registers are intended
    ; to address. It does not load those registers or execute at run time.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    ; x86 hardware does not allow loading a segment register directly with an immediate
    ; address, so DATASEG is moved into AX first and then transferred into DS. (Unlike CS
    ; and SS, DOS does not automatically point DS to your data segment on .exe startup).
    MOV AX, DATASEG
    MOV DS, AX

    ; LEA loads the offset of TITLE_TEXT into DX, not the text at that address.
    ; PRINT_STRING passes DS:DX to DOS. CALL saves a return address on the
    ; stack, allowing the procedure's RET to resume at the following instruction.
    LEA DX, TITLE_TEXT
    CALL PRINT_STRING

    ; DI is the next source-array offset; CX is the remaining input count.
    ; READ_BYTE preserves CX and SI, so its own parsing loop cannot disturb
    ; this outer loop. Ten successful reads fill DS:3000H through DS:3009H.
    MOV DI, 3000H
    MOV CX, 10

INPUT_LOOP:
    ; Display one prompt, then convert the typed decimal text into a byte.
    ; READ_BYTE returns AL = value and clears CF (carry flag) on success.
    LEA DX, PROMPT_TEXT
    CALL PRINT_STRING
    CALL READ_BYTE
    ; JNC means jump if carry is clear: valid input continues at INPUT_OK.
    ; Otherwise take the unconditional JMP to report the error and terminate.
    JNC INPUT_OK
    JMP BAD_INPUT

INPUT_OK:
    ; [DI] refers to the byte in memory at DS:DI. AL makes this a byte store.
    ; Advance DI by one because the next array element occupies one byte.
    MOV [DI], AL
    INC DI
    ; Move to a fresh output line after the entered value.
    CALL PRINT_NEWLINE
    ; LOOP subtracts one from CX and jumps while CX is nonzero. After ten
    ; iterations CX is zero and execution falls through to the transfer setup.
    LOOP INPUT_LOOP

    ; Reset the pointers for the main calculation: SI reads the source block,
    ; DI writes the destination block, and CX counts ten elements again.
    MOV SI, 3000H
    MOV DI, 4000H
    MOV CX, 10

TRANSFER_LOOP:
    ; Fetch one unsigned source byte into AL and load the multiplier into BL.
    MOV AL, [SI]
    MOV BL, 5
    ; Byte MUL uses AL implicitly: AL * BL produces a 16-bit result in AX.
    ; Any previous AH is irrelevant because MUL replaces the whole AX result.
    MUL BL
    ; Add 10 to the full product. The largest result is 255*5+10 = 1285,
    ; which fits in AX, but may be too large for a single destination byte.
    ADD AX, 10
    ; Store only AL (the low eight bits): the stored value is (5*x+10) mod 256.
    ; AH is discarded. Example: x=50 gives AX=260=0104H, so byte 04H is stored.
    MOV [DI], AL

    ; Advance both byte pointers and repeat until all ten values are processed.
    INC SI
    INC DI
    LOOP TRANSFER_LOOP

    ; Display the output label, then reset SI and CX to traverse the result block.
    LEA DX, OUTPUT_TEXT
    CALL PRINT_STRING
    MOV SI, 4000H
    MOV CX, 10

OUTPUT_LOOP:
    ; Clear both halves of AX before loading AL so AX is the unsigned byte
    ; extended to 16 bits (0..255), as required by PRINT_BYTE's word division.
    XOR AX, AX
    MOV AL, [SI]
    CALL PRINT_BYTE

    ; DOS function 02H prints the single character in DL. Here it separates
    ; adjacent decimal results with a space, including after the final result.
    MOV DL, ' '
    MOV AH, 02H
    INT 21H

    ; Visit the next destination byte until CX reaches zero, then end the line.
    INC SI
    LOOP OUTPUT_LOOP
    CALL PRINT_NEWLINE
    ; Skip BAD_INPUT so successful execution reaches the normal exit path.
    JMP EXIT_OK

BAD_INPUT:
    ; Invalid input ends the program immediately; this path does not retry.
    ; Print the error and newline, then use DOS function 4CH to terminate.
    LEA DX, ERROR_TEXT
    CALL PRINT_STRING
    CALL PRINT_NEWLINE
    ; AH=4CH selects termination; AL=01H returns failure status 1 to DOS.
    MOV AX, 4C01H
    INT 21H

EXIT_OK:
    ; AH=4CH terminates the process; AL=00H returns success status 0.
    MOV AX, 4C00H
    INT 21H

; Read one decimal number from 0 through 255.
; Return: AL = byte and CF = 0, or CF = 1 for invalid input.
; AX holds the result; BX, CX, DX and SI are restored before returning.
; PROC NEAR declares a procedure called within the current code segment.
READ_BYTE PROC NEAR
    ; Preserve the caller's working registers. PUSH stores words on SS:SP.
    ; The matching POP instructions must restore them in reverse order.
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    ; DS:DX points to the DOS line-input buffer. AH=0AH selects buffered input;
    ; INT 21H invokes DOS, which echoes input and returns after Enter is pressed.
    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    ; Read the returned character count into CL and clear CH so CX contains
    ; exactly that count. JCXZ rejects an empty line without entering the loop.
    MOV CL, INPUT_BUFFER[1]
    XOR CH, CH
    JCXZ RB_INVALID
    ; A byte needs at most three decimal digits. JA is an unsigned comparison:
    ; reject a length greater than 3. CMP sets flags without changing operands.
    CMP CX, 3
    JA RB_INVALID

    ; Skip the two buffer-header bytes to reach the first typed character.
    ; BX accumulates the numeric value, starting at zero.
    LEA SI, INPUT_BUFFER[2]
    XOR BX, BX

RB_NEXT_DIGIT:
    ; ASCII digit codes run consecutively from '0' through '9'. Reject any
    ; character below '0' (JB) or above '9' (JA), using unsigned comparisons.
    MOV AL, [SI]
    CMP AL, '0'
    JB RB_INVALID
    CMP AL, '9'
    JA RB_INVALID

    ; Preserve the character in DL and subtract ASCII '0' to get a digit 0..9.
    ; Clearing DH makes DX a 16-bit digit, ready for addition to AX below.
    MOV DL, AL
    SUB DL, '0'
    XOR DH, DH

    ; Decimal accumulation: new value = old value * 10 + new digit.
    ; On the 8086, each SHL by 1 doubles a register. Save 2*old in BX,
    ; shift AX twice more to obtain 8*old, then add BX to obtain 10*old.
    ; For example, old=12 and digit=3 produces 120+3=123.
    MOV AX, BX
    SHL AX, 1                  ; AX = 2 * old value.
    MOV BX, AX                 ; BX saves the 2 * old value term.
    SHL AX, 1                  ; AX = 4 * old value.
    SHL AX, 1                  ; AX = 8 * old value.
    ADD AX, BX                 ; AX = 10 * old value.
    ADD AX, DX                 ; AX = 10 * old value + current digit.

    ; Reject values above the unsigned-byte limit before accepting this digit.
    ; Each prior value was at most 255, so this intermediate fits in 16 bits.
    CMP AX, 255
    JA RB_INVALID
    ; Keep the updated value, move to the next character and reduce CX.
    MOV BX, AX
    INC SI
    LOOP RB_NEXT_DIGIT

    ; All digits passed validation: copy the accumulated value to AX (and AL).
    ; CLC explicitly clears carry, the success indicator used by the caller.
    MOV AX, BX
    CLC
    ; Bypass STC on success. SHORT specifies a nearby relative jump encoding.
    JMP SHORT RB_RETURN

RB_INVALID:
    ; STC sets carry to report invalid input; AL has no valid result here.
    STC

RB_RETURN:
    ; Restore the caller's registers. POP and RET do not change CF, so the
    ; success/failure flag survives until the caller's JNC tests it.
    POP SI
    POP DX
    POP CX
    POP BX
    RET
; ENDP marks the end of the procedure for the assembler; RET returns at run time.
READ_BYTE ENDP

; Print the unsigned byte in AX as decimal.
; Caller supplies AX=0..255, with AH cleared. All four registers below are saved.
PRINT_BYTE PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    ; CX counts the extracted digits. BX=10 is the divisor for decimal conversion.
    XOR CX, CX
    MOV BX, 10

PB_DIVIDE:
    ; Word DIV divides the unsigned 32-bit dividend DX:AX by BX. Clear DX
    ; before EVERY division so the dividend is just the current value in AX.
    ; The quotient returns in AX and the remainder (a digit 0..9) in DX.
    XOR DX, DX
    DIV BX
    ; Division extracts digits from right to left. Save each remainder on the
    ; stack so popping later reverses that order for left-to-right printing.
    PUSH DX
    INC CX
    ; OR AX,AX leaves AX unchanged and sets ZF if the quotient is zero.
    ; Continue dividing while a quotient remains. Even an input of zero runs
    ; this loop once, pushing a zero digit, so it correctly prints as "0".
    OR AX, AX
    JNZ PB_DIVIDE

PB_PRINT:
    ; Pop the next digit, convert 0..9 to ASCII by adding '0', then print DL
    ; with DOS function 02H. LOOP uses CX to print exactly the saved digit count.
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PB_PRINT

    ; All digit words have now been popped, exposing the saved registers.
    ; Restore them in reverse order and return to the output loop.
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_BYTE ENDP

PRINT_STRING PROC NEAR
    ; Caller supplies DS:DX pointing to a '$'-terminated string. AH selects
    ; DOS service 09H; INT 21H prints it. AX is not preserved by this helper.
    MOV AH, 09H
    INT 21H
    RET
PRINT_STRING ENDP

PRINT_NEWLINE PROC NEAR
    ; Reuse PRINT_STRING with the CR/LF string. The nested CALL returns here
    ; first; this procedure's RET then returns to its own caller. DX changes.
    LEA DX, NEWLINE
    CALL PRINT_STRING
    RET
PRINT_NEWLINE ENDP

CODESEG ENDS
; END closes the source module and identifies START as the .EXE entry point.
; It is an assembler directive, not a run-time replacement for DOS termination.
END START
