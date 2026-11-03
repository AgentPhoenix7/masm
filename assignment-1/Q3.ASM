; Question 3
; Read one hexadecimal byte (00H-FFH) as two typed hex digits and print
; the value in hex plus, if printable, the ASCII character it represents.

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
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
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

START:
    MOV AX, DATASEG
    MOV DS, AX

    LEA DX, Q3_TITLE
    CALL PRINT_STRING

INPUT_LOOP:
    LEA DX, PROMPT_TEXT
    CALL PRINT_STRING

    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    CMP INPUT_BUFFER+1, 2
    JNE BAD_INPUT

    MOV AL, INPUT_BUFFER+2
    CALL HEX_NIBBLE
    JC BAD_INPUT
    MOV BL, AL
    SHL BL, 1
    SHL BL, 1
    SHL BL, 1
    SHL BL, 1

    MOV AL, INPUT_BUFFER+3
    CALL HEX_NIBBLE
    JC BAD_INPUT
    OR BL, AL

    CALL PRINT_NEWLINE

    LEA DX, HEX_LABEL
    CALL PRINT_STRING
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

    CMP BL, 20H
    JB NOT_PRINTABLE
    CMP BL, 7EH
    JA NOT_PRINTABLE

    LEA DX, ASCII_LABEL
    CALL PRINT_STRING
    MOV DL, BL
    MOV AH, 02H
    INT 21H
    CALL PRINT_NEWLINE
    JMP DONE

NOT_PRINTABLE:
    LEA DX, ASCII_LABEL
    CALL PRINT_STRING
    LEA DX, NOT_PRINTABLE_TEXT
    CALL PRINT_STRING
    CALL PRINT_NEWLINE
    JMP DONE

BAD_INPUT:
    CALL PRINT_NEWLINE
    LEA DX, BAD_TEXT
    CALL PRINT_STRING
    JMP INPUT_LOOP

DONE:
    MOV AX, 4C00H
    INT 21H

; Print the dollar-terminated string at DS:DX.
PRINT_STRING PROC NEAR
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
    CMP AL, '0'
    JB HN_BAD
    CMP AL, '9'
    JA HN_CHECK_UPPER
    SUB AL, '0'
    CLC
    RET
HN_CHECK_UPPER:
    CMP AL, 'A'
    JB HN_BAD
    CMP AL, 'F'
    JA HN_CHECK_LOWER
    SUB AL, 'A' - 10      ; Convert 'A'-'F' to 10-15
    CLC
    RET
HN_CHECK_LOWER:
    CMP AL, 'a'
    JB HN_BAD
    CMP AL, 'f'
    JA HN_BAD
    SUB AL, 'a' - 10
    CLC
    RET
HN_BAD:
    STC
    RET
HEX_NIBBLE ENDP

CODESEG ENDS
END START
