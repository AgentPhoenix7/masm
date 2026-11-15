; Question 3
; Read one hexadecimal byte (00H-FFH) as two typed hex digits and print
; the value in hex plus, if printable, the ASCII character it represents.
;
; Flow: initialize DS -> read two hex digits -> convert each to a nibble ->
; combine the nibbles -> display the entered hex text and its ASCII character.
; A nibble is four bits (0..15); two nibbles make one byte (0..255).
; AX, BX, CX and DX are 16-bit registers; AH/AL, BH/BL, CH/CL and DH/DL
; are their upper/lower bytes. An H suffix marks hexadecimal constants.

; SEGMENT/ENDS declare assembler sections, rather than CPU instructions.
; PARA requests 16-byte alignment. STACK allows the linker to record the
; initial SS:SP stack address in the DOS .EXE header for the loader.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW declares 16-bit words: 128 words reserve 256 bytes for CALL/PUSH.
    ; DUP repeats the declaration; ? leaves initial contents unspecified.
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; PUBLIC permits compatible segments to be combined by the linker.
    ; DB declares bytes. DOS service 09H stops printing at '$'.
    ; 13/10 are carriage return/line feed, used together for a new line.
    Q3_TITLE      DB 13,10,'QUESTION 3 - HEX BYTE TO ASCII CHARACTER',13,10,'$'
    PROMPT_TEXT   DB 'Enter a hex byte (00-FF): $'
    BAD_TEXT      DB 'Invalid input. Enter exactly two hex digits (0-9, A-F, a-f).',13,10,'$'
    HEX_LABEL     DB 'Hex value: $'
    ASCII_LABEL   DB 'ASCII value: $'
    NOT_PRINTABLE_TEXT DB 'not printable$'

    ; DOS function 0AH buffer: maximum length, actual length, characters.
    ; Valid input is exactly 2 typed characters. Following the same
    ; empirically-verified rule established for Q2 in this authentic
    ; DOSBox 0.74-3 / MASM 5.10 environment (typing exactly maxlen
    ; characters never returns from INT 21H/AH=0AH here), maxlen must be
    ; set higher than any erroneous entry length a user could plausibly
    ; type. maxlen=4 was tried first but confirmed to hang on a 4-character
    ; bad entry (e.g. "12AB") because 4 characters lands exactly on
    ; maxlen=4; maxlen=5 leaves headroom so a 3-4 character erroneous
    ; entry is cleanly rejected instead. The char area is sized maxlen+1
    ; to also hold the CR DOS writes after the typed characters.
    INPUT_BUFFER  DB 5,0,6 DUP (0)
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME tells the assembler the intended segment-register associations;
    ; it does not initialize them. Runtime code below must still set DS.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    ; At DOS .EXE startup DS points to the program segment prefix. Load the
    ; data segment through AX because MOV DS,immediate is not a CPU instruction.
    MOV AX, DATASEG
    MOV DS, AX

    ; LEA loads the title's offset into DX; DS:DX identifies its bytes.
    ; CALL pushes a return address; the helper's RET resumes at the next line.
    LEA DX, Q3_TITLE
    CALL PRINT_STRING

INPUT_LOOP:
    ; Display the prompt. Invalid input later jumps here to request a new line.
    LEA DX, PROMPT_TEXT
    CALL PRINT_STRING

    ; DOS service AH=0AH reads and echoes a buffered line at DS:DX.
    ; Byte 1 receives its length; character data starts at byte 2.
    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    ; Require exactly two typed digits. CMP sets flags without changing data;
    ; JNE branches if the returned count is not two (the CR is not counted).
    CMP INPUT_BUFFER+1, 2
    JNE BAD_INPUT

    ; Convert the first ASCII digit into AL=0..15. CF (carry flag) reports
    ; validity: JC branches to BAD_INPUT if HEX_NIBBLE sets carry.
    MOV AL, INPUT_BUFFER+2
    CALL HEX_NIBBLE
    JC BAD_INPUT
    MOV BL, AL
    ; Move this first nibble to bits 7..4 by shifting left four times.
    ; Each SHL by one doubles BL; e.g. digit A becomes 0AH * 16 = A0H.
    SHL BL, 1
    SHL BL, 1
    SHL BL, 1
    SHL BL, 1

    ; Convert the second digit separately; HEX_NIBBLE leaves BL unchanged.
    MOV AL, INPUT_BUFFER+3
    CALL HEX_NIBBLE
    JC BAD_INPUT
    ; OR combines the disjoint bit fields: (first * 16) OR second.
    ; Example: '4','1' become 40H OR 01H = 41H, the ASCII code for 'A'.
    OR BL, AL

    CALL PRINT_NEWLINE

    ; Print the original two characters from the input buffer, preserving
    ; their entered letter case, then append H to mark a hexadecimal value.
    LEA DX, HEX_LABEL
    CALL PRINT_STRING
    ; DOS service AH=02H prints one character from DL; each INT invokes DOS.
    MOV DL, INPUT_BUFFER+2
    MOV AH, 02H
    INT 21H
    MOV DL, INPUT_BUFFER+3
    MOV AH, 02H
    INT 21H
    MOV DL, 'H'
    MOV AH, 02H
    INT 21H
    CALL PRINT_NEWLINE

    ; Printable ASCII occupies the inclusive range 20H..7EH (space through ~).
    ; JB/JA use unsigned comparisons. Codes outside this range take the
    ; explanatory-text path instead of being emitted as control characters.
    CMP BL, 20H
    JB NOT_PRINTABLE
    CMP BL, 7EH
    JA NOT_PRINTABLE

    ; BL holds the actual byte value, not its hex spelling. Sending it to
    ; character output displays the character represented by that code.
    LEA DX, ASCII_LABEL
    CALL PRINT_STRING
    MOV DL, BL
    MOV AH, 02H
    INT 21H
    CALL PRINT_NEWLINE
    JMP DONE

NOT_PRINTABLE:
    ; Reuse the same label, but print a message for control codes and bytes
    ; outside printable ASCII. Both successful paths finish at DONE.
    LEA DX, ASCII_LABEL
    CALL PRINT_STRING
    LEA DX, NOT_PRINTABLE_TEXT
    CALL PRINT_STRING
    CALL PRINT_NEWLINE
    JMP DONE

BAD_INPUT:
    ; Wrong length or a non-hex character prints an error and retries the
    ; entire entry. Any partial value in BL will be replaced on the next try.
    CALL PRINT_NEWLINE
    LEA DX, BAD_TEXT
    CALL PRINT_STRING
    JMP INPUT_LOOP

DONE:
    ; AH=4CH selects DOS process termination; AL=00H returns success status.
    MOV AX, 4C00H
    INT 21H

; Print the dollar-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    ; NEAR means the procedure is in this code segment. Preserve AX and DX,
    ; select service 09H, and print the '$'-terminated string at DS:DX.
    PUSH AX
    PUSH DX
    MOV AH, 09H
    INT 21H
    POP DX
    POP AX
    RET
PRINT_STRING ENDP

; Print a carriage return and line feed.
PRINT_NEWLINE PROC NEAR
    ; Save the caller's registers. Service 02H prints DL: first CR (13)
    ; returns to column 0, then LF (10) advances to the next line.
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

; Convert one ASCII hex digit in AL to its value (0-15) in AL.
; Accepts '0'-'9', 'A'-'F', and 'a'-'f'. Sets carry for any other input.
HEX_NIBBLE PROC NEAR
    ; First check ASCII '0'..'9'. JB/JA compare unsigned character codes.
    ; Codes below '0' cannot match any later valid range, so reject them.
    CMP AL, '0'
    JB HN_BAD
    CMP AL, '9'
    JA HN_CHECK_UPPER
    ; The ten digit codes are consecutive: subtract '0' to obtain 0..9.
    SUB AL, '0'
    CLC
    RET
HN_CHECK_UPPER:
    ; A value beyond '9' may be an uppercase hex letter. Reject punctuation
    ; below 'A'; values beyond 'F' still have a chance to match lowercase.
    CMP AL, 'A'
    JB HN_BAD
    CMP AL, 'F'
    JA HN_CHECK_LOWER
    SUB AL, 'A' - 10      ; Convert 'A'-'F' to 10-15
    CLC
    RET
HN_CHECK_LOWER:
    ; Accept only 'a'..'f'. Subtracting ('a'-10) maps 'a' to 10 and 'f' to 15.
    CMP AL, 'a'
    JB HN_BAD
    CMP AL, 'f'
    JA HN_BAD
    SUB AL, 'a' - 10
    CLC
    RET
HN_BAD:
    ; STC sets CF for failure. On each successful path CLC clears it.
    ; RET does not change CF, so the caller's JC sees this result directly.
    STC
    RET
HEX_NIBBLE ENDP

CODESEG ENDS
; ENDP/ENDS close declarations; END closes the module and names its entry point.
END START
