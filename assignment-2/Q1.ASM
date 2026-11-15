; Q1. Boot-level password verification system. Simulate a BIOS-like password verification system, where the steps would be:
; a. accepting hidden password input (no echo)
; b. comparing with a hardcoded value
; c. allowing up to 3 retries before locking
; d. using BIOS interrupts for keyboard handling

; BIOS-like password verification system for 8086
; MASM 5.x / DOSBox compatible
; Hardcoded password: admin123
;
; Flow: initialize data segments -> read a hidden entry -> compare length and
; bytes -> grant access, or reduce the attempt count and retry/print lockout.
; This is a DOS program simulating a password screen, not boot-sector code.
; ATTEMPTS=3 allows three total entries, including the first attempt.
; AX/BX/CX/DX are 16-bit registers; AH/AL etc. are their upper/lower bytes.
; H marks hexadecimal constants. DS:SI denotes a segment and an offset.

; SEGMENT/ENDS declare assembler sections. PARA requests 16-byte alignment;
; STACK lets the linker record initial SS:SP for the DOS .EXE loader.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW reserves words: 128 words provide 256 bytes for CALL/PUSH.
    ; DUP repeats a declaration; ? leaves initial contents unspecified.
    DW 128 DUP (?)
STACKSEG ENDS

MAX_INPUT EQU 20
; EQU defines an assembly-time constant; it reserves no memory at run time.

DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; PUBLIC allows compatible segments to be combined by the linker.
    ; DB stores bytes/character codes. DOS string service 09H prints until '$'.
    ; 13/10 are carriage return/line feed, together forming a DOS newline.
    TITLE_MSG    DB 13,10,'BIOS PASSWORD VERIFICATION',13,10,'$'
    PROMPT_MSG   DB 'Enter password: $'
    SUCCESS_MSG  DB 13,10,'Access granted.',13,10,'$'
    WRONG_MSG    DB 13,10,'Incorrect password. Attempts left: $'
    LOCK_MSG     DB 13,10,'SYSTEM LOCKED.',13,10,'$'
    NEWLINE      DB 13,10,'$'

    PASSWORD     DB 'admin123'
    ; Here $ means the assembler's current location, not a stored '$' character.
    ; Current offset minus PASSWORD computes the eight-byte password length.
    PASSWORD_LEN EQU $ - PASSWORD

    INPUT_BUFFER DB MAX_INPUT DUP (0)
    ; Password entries use an explicit length, rather than zero/'$' termination.
    ; Only the first INPUT_LEN bytes participate in the comparison.
    INPUT_LEN    DB 0
    ATTEMPTS     DB 3
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME describes intended segment-register use; it does not load registers.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

MAIN PROC FAR
    ; FAR declares the entry procedure's call type; DOS enters via END MAIN
    ; and this program terminates with INT 21H instead of returning with RET.
    ; DS initially points to the DOS program segment prefix. Load DATASEG via
    ; AX because MOV cannot load DS directly with an immediate segment value.
    MOV AX, DATASEG
    MOV DS, AX
    ; CMPSB compares DS:SI with ES:DI, so ES must address the same data segment.
    MOV ES, AX

    ; LEA loads an offset into DX, not the string bytes. PRINT_STRING uses DS:DX.
    ; CALL saves a return address on SS:SP; RET resumes after that CALL.
    LEA DX, TITLE_MSG
    CALL PRINT_STRING

TRY_AGAIN:
    ; Start a fresh hidden entry and compare it. CHECK_PASSWORD returns a
    ; Boolean in AL; this interface uses a value, rather than carry, for status.
    LEA DX, PROMPT_MSG
    CALL PRINT_STRING

    CALL READ_PASSWORD
    CALL CHECK_PASSWORD

    ; CMP changes flags without modifying AL; JE branches on equality.
    CMP AL, 1
    JE ACCESS_GRANTED

    ; Each failed comparison consumes one attempt. Check for zero before
    ; displaying the remaining count, so the third failure goes to lockout.
    DEC ATTEMPTS
    CMP ATTEMPTS, 0
    JE SYSTEM_LOCKED

    LEA DX, WRONG_MSG
    CALL PRINT_STRING

    ; The remaining count is one digit (2 or 1). Add ASCII '0' to make its
    ; character code, then DOS service AH=02H prints that character from DL.
    MOV DL, ATTEMPTS
    ADD DL, '0'
    MOV AH, 02H
    INT 21H

    LEA DX, NEWLINE
    CALL PRINT_STRING
    JMP TRY_AGAIN

ACCESS_GRANTED:
    ; Print success and skip the lockout path to reach common termination.
    LEA DX, SUCCESS_MSG
    CALL PRINT_STRING
    JMP EXIT_PROGRAM

SYSTEM_LOCKED:
    ; This message ends the simulation; it does not lock the host or DOS itself.
    LEA DX, LOCK_MSG
    CALL PRINT_STRING

EXIT_PROGRAM:
    ; AH=4CH terminates the DOS process. AL=00H returns status 0 on BOTH
    ; success and lockout; the screen message distinguishes the outcomes.
    MOV AX, 4C00H
    INT 21H
MAIN ENDP


; Reads the password using BIOS keyboard interrupt.
; Characters are not displayed.
READ_PASSWORD PROC NEAR
    ; Preserve AX/BX; BX counts active characters and indexes the next free slot.
    ; BIOS input does not echo, and this routine prints neither text nor stars.
    PUSH AX
    PUSH BX

    XOR BX, BX                 ; BX = number of characters entered

READ_KEY:
    ; BIOS INT 16H/AH=00H waits for a key, returning ASCII in AL and scan code
    ; in AH. A nonprinting/extended key is rejected by the ASCII range checks.
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

    ; Store printable ASCII only while capacity remains. Once full, extra
    ; printable characters are ignored until Backspace or Enter is received.
    MOV INPUT_BUFFER[BX], AL
    INC BX
    JMP READ_KEY

HANDLE_BACKSPACE:
    ; Do nothing if empty. Otherwise reduce the active length; the old byte
    ; need not be erased because it is outside the compared range afterward.
    CMP BX, 0
    JE READ_KEY

    DEC BX                     ; Remove previous character
    JMP READ_KEY

INPUT_FINISHED:
    ; BX is at most 20, so BL stores the complete length for CHECK_PASSWORD.
    ; Every retry starts BX at zero, ignoring bytes left from a previous entry.
    MOV INPUT_LEN, BL

    POP BX
    POP AX
    RET
READ_PASSWORD ENDP


; Compares the entered password with the hardcoded password.
; Returns AL = 1 for a match and AL = 0 otherwise.
CHECK_PASSWORD PROC NEAR
    ; Save the caller's loop count and pointers; AL intentionally carries the
    ; return value. Clear CH before loading the byte length into CL.
    PUSH CX
    PUSH SI
    PUSH DI

    XOR CX, CX
    MOV CL, INPUT_LEN

    ; Reject a length mismatch before comparing bytes: a matching prefix
    ; with additional/missing characters is not accepted as the password.
    CMP CX, PASSWORD_LEN
    JNE PASSWORD_WRONG

    LEA SI, INPUT_BUFFER
    LEA DI, PASSWORD

    CLD                        ; Compare from left to right
    ; CLD clears the direction flag, making CMPSB increment SI and DI.
    ; REPE repeats the byte comparison while CX is nonzero and bytes match,
    ; decrementing CX each time. JNE detects a differing byte via the zero flag.
    ; The prior length check ensures CX=8, so at least one comparison executes.
    REPE CMPSB
    JNE PASSWORD_WRONG

    ; All eight bytes matched exactly (case-sensitive): return true in AL.
    MOV AL, 1
    JMP CHECK_DONE

PASSWORD_WRONG:
    ; Length or content mismatch returns false, without modifying ATTEMPTS here.
    MOV AL, 0

CHECK_DONE:
    ; Restore saved words in reverse PUSH order; leave AL as the Boolean result.
    POP DI
    POP SI
    POP CX
    RET
CHECK_PASSWORD ENDP


; Prints the DOS '$'-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    ; NEAR means a procedure within this code segment. Save AX, select DOS
    ; service 09H to print DS:DX, then restore AX before returning to the caller.
    PUSH AX

    MOV AH, 09H
    INT 21H

    POP AX
    RET
PRINT_STRING ENDP

CODESEG ENDS
; ENDP/ENDS close assembler declarations; END names MAIN as the executable entry.
END MAIN
