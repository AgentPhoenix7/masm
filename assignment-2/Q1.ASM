; Q1. Boot-level password verification system. Simulate a BIOS-like password verification system, where the steps would be:
; a. accepting hidden password input (no echo)
; b. comparing with a hardcoded value
; c. allowing up to 3 retries before locking
; d. using BIOS interrupts for keyboard handling

; BIOS-like password verification system for 8086
; MASM 5.x / DOSBox compatible
; Hardcoded password: admin123

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

MAX_INPUT EQU 20

DATASEG SEGMENT PARA PUBLIC 'DATA'
    TITLE_MSG    DB 13,10,'BIOS PASSWORD VERIFICATION',13,10,'$'
    PROMPT_MSG   DB 'Enter password: $'
    SUCCESS_MSG  DB 13,10,'Access granted.',13,10,'$'
    WRONG_MSG    DB 13,10,'Incorrect password. Attempts left: $'
    LOCK_MSG     DB 13,10,'SYSTEM LOCKED.',13,10,'$'
    NEWLINE      DB 13,10,'$'

    PASSWORD     DB 'admin123'
    PASSWORD_LEN EQU $ - PASSWORD

    INPUT_BUFFER DB MAX_INPUT DUP (0)
    INPUT_LEN    DB 0
    ATTEMPTS     DB 3
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

MAIN PROC FAR
    MOV AX, DATASEG
    MOV DS, AX
    MOV ES, AX

    LEA DX, TITLE_MSG
    CALL PRINT_STRING

TRY_AGAIN:
    LEA DX, PROMPT_MSG
    CALL PRINT_STRING

    CALL READ_PASSWORD
    CALL CHECK_PASSWORD

    CMP AL, 1
    JE ACCESS_GRANTED

    DEC ATTEMPTS
    CMP ATTEMPTS, 0
    JE SYSTEM_LOCKED

    LEA DX, WRONG_MSG
    CALL PRINT_STRING

    MOV DL, ATTEMPTS
    ADD DL, '0'
    MOV AH, 02H
    INT 21H

    LEA DX, NEWLINE
    CALL PRINT_STRING
    JMP TRY_AGAIN

ACCESS_GRANTED:
    LEA DX, SUCCESS_MSG
    CALL PRINT_STRING
    JMP EXIT_PROGRAM

SYSTEM_LOCKED:
    LEA DX, LOCK_MSG
    CALL PRINT_STRING

EXIT_PROGRAM:
    MOV AX, 4C00H
    INT 21H
MAIN ENDP


; Reads the password using BIOS keyboard interrupt.
; Characters are not displayed.
READ_PASSWORD PROC NEAR
    PUSH AX
    PUSH BX

    XOR BX, BX                 ; BX = number of characters entered

READ_KEY:
    MOV AH, 00H
    INT 16H                    ; BIOS: wait for keyboard input

    CMP AL, 0DH                ; Enter pressed?
    JE INPUT_FINISHED

    CMP AL, 08H                ; Backspace pressed?
    JE HANDLE_BACKSPACE

    CMP AL, 20H                ; Ignore control characters
    JB READ_KEY

    CMP AL, 7EH                ; Ignore characters above printable ASCII
    JA READ_KEY

    CMP BX, MAX_INPUT          ; Prevent buffer overflow
    JAE READ_KEY

    MOV INPUT_BUFFER[BX], AL
    INC BX
    JMP READ_KEY

HANDLE_BACKSPACE:
    CMP BX, 0
    JE READ_KEY

    DEC BX                     ; Remove previous character
    JMP READ_KEY

INPUT_FINISHED:
    MOV INPUT_LEN, BL

    POP BX
    POP AX
    RET
READ_PASSWORD ENDP


; Compares the entered password with the hardcoded password.
; Returns AL = 1 for a match and AL = 0 otherwise.
CHECK_PASSWORD PROC NEAR
    PUSH CX
    PUSH SI
    PUSH DI

    XOR CX, CX
    MOV CL, INPUT_LEN

    CMP CX, PASSWORD_LEN
    JNE PASSWORD_WRONG

    LEA SI, INPUT_BUFFER
    LEA DI, PASSWORD

    CLD                        ; Compare from left to right
    REPE CMPSB
    JNE PASSWORD_WRONG

    MOV AL, 1
    JMP CHECK_DONE

PASSWORD_WRONG:
    MOV AL, 0

CHECK_DONE:
    POP DI
    POP SI
    POP CX
    RET
CHECK_PASSWORD ENDP


; Prints the DOS '$'-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    PUSH AX

    MOV AH, 09H
    INT 21H

    POP AX
    RET
PRINT_STRING ENDP

CODESEG ENDS
END MAIN
