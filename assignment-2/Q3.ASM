; Q3. Implement FCFS (First-Come-First-Served) disk scheduling algorithm using MASM.

; FCFS disk scheduling for 8086
; MASM 5.x / DOSBox compatible
;
; Flow: read a request count -> read cylinders in arrival order -> read initial
; head position -> visit every request in that same order -> print total travel.
; FCFS does not sort or choose a nearest request. Each movement is the absolute
; difference between the current head and the next requested cylinder.
; AX/BX/CX/DX are 16-bit registers; AH/AL etc. are their upper/lower bytes.
; H marks hexadecimal constants; unmarked numeric constants here are decimal.

; SEGMENT/ENDS declare assembler sections. PARA requests 16-byte alignment;
; STACK lets the linker record initial SS:SP for the DOS .EXE loader.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW declares words: 128 words reserve 256 stack bytes for CALL/PUSH.
    ; DUP repeats a declaration; ? leaves the initial contents unspecified.
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; PUBLIC permits compatible segments to be combined by the linker.
    ; DB declares bytes/character codes. DOS service 09H prints until '$';
    ; 13/10 are carriage return/line feed for starting a new output line.
    TITLE_MSG    DB 13,10,'FCFS DISK SCHEDULING',13,10,'$'
    COUNT_MSG    DB 'Enter number of requests (1-10): $'
    REQUEST_MSG  DB 'Enter cylinder request (0-999): $'
    HEAD_MSG     DB 'Enter initial head position (0-999): $'
    INVALID_MSG  DB 'Invalid input. Try again.',13,10,'$'
    SEQUENCE_MSG DB 13,10,'Seek sequence: $'
    ARROW_MSG    DB ' -> $'
    TOTAL_MSG    DB 13,10,'Total head movement: $'
    UNIT_MSG     DB ' cylinders',13,10,'$'

    ; DOS function 0Ah input buffer:
    ; maximum length, actual length, input characters, carriage return.
    INPUT_BUFFER DB 4,0,4 DUP (0)
    ; Capacity 4 includes the CR, leaving up to three typed decimal digits.
    ; Byte 1 receives the count excluding CR; typed data starts at byte 2.

    ; REQUEST_COUNT fits in a byte, but cylinders need words (DW) for 0..999.
    ; Ten requests can move at most 10*999=9990 cylinders, fitting the word total.
    REQUEST_COUNT DB 0
    REQUESTS      DW 10 DUP (0)
    INITIAL_HEAD  DW 0
    CURRENT_HEAD  DW 0
    TOTAL_MOVEMENT DW 0
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME describes intended segment-register use; it does not initialize DS.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

MAIN PROC
    ; DS initially points to the DOS program segment prefix. Load DATASEG via
    ; AX because MOV cannot load a segment register with an immediate value.
    MOV AX, DATASEG
    MOV DS, AX

    ; LEA loads an offset into DX; PRINT_STRING prints the text at DS:DX.
    ; CALL saves a return address on the stack; RET resumes after that CALL.
    LEA DX, TITLE_MSG
    CALL PRINT_STRING

; Read and validate the number of requests.
READ_COUNT:
    ; READ_NUMBER returns AX and clears CF (carry) for valid decimal input.
    ; JC rejects a parsing failure; unsigned JB/JA enforce the range 1..10.
    LEA DX, COUNT_MSG
    CALL PRINT_STRING
    CALL READ_NUMBER
    JC BAD_COUNT

    CMP AX, 1
    JB BAD_COUNT
    CMP AX, 10
    JA BAD_COUNT

    MOV REQUEST_COUNT, AL
    JMP READ_REQUESTS

BAD_COUNT:
    ; Retry only the request count after an empty/nondigit/out-of-range entry.
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_COUNT

; Read all cylinder requests in their original order.
READ_REQUESTS:
    ; SI is a byte offset into the word array, starting at zero. Zero CH so
    ; loading CL gives CX the full request count, with no stale upper byte.
    XOR SI, SI
    XOR CX, CX
    MOV CL, REQUEST_COUNT

READ_ONE_REQUEST:
    ; Read one cylinder. Parsing already limits input to at most three digits;
    ; the explicit unsigned comparison records the intended maximum of 999.
    LEA DX, REQUEST_MSG
    CALL PRINT_STRING
    CALL READ_NUMBER
    JC BAD_REQUEST

    CMP AX, 999
    JA BAD_REQUEST

    MOV REQUESTS[SI], AX
    ; Each DW occupies two bytes: offsets 0,2,4,... address successive requests.
    ; LOOP decrements CX and repeats while nonzero, counting only valid entries.
    ADD SI, 2
    LOOP READ_ONE_REQUEST
    JMP READ_HEAD

BAD_REQUEST:
    ; Leave SI/CX unchanged and retry the same slot. READ_NUMBER preserves
    ; those registers even though its own conversion loop also uses them.
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_ONE_REQUEST

; Read and validate the initial head position.
READ_HEAD:
    ; Initialize both the saved starting position and the mutable current head.
    ; Reset total travel before starting the FCFS loop.
    LEA DX, HEAD_MSG
    CALL PRINT_STRING
    CALL READ_NUMBER
    JC BAD_HEAD

    CMP AX, 999
    JA BAD_HEAD

    MOV INITIAL_HEAD, AX
    MOV CURRENT_HEAD, AX
    MOV TOTAL_MOVEMENT, 0
    JMP RUN_FCFS

BAD_HEAD:
    ; Only the initial head is retried; the previously entered requests stay saved.
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_HEAD

; Service each request in FCFS input order.
RUN_FCFS:
    ; Print the initial head before any arrow, then visit the stored requests
    ; in arrival order. Reset SI/CX because the input loop already consumed them.
    LEA DX, SEQUENCE_MSG
    CALL PRINT_STRING

    MOV AX, INITIAL_HEAD
    CALL PRINT_NUMBER

    XOR SI, SI
    XOR CX, CX
    MOV CL, REQUEST_COUNT

FCFS_LOOP:
    ; Print a separator before each request, then load its cylinder into BX.
    LEA DX, ARROW_MSG
    CALL PRINT_STRING

    MOV BX, REQUESTS[SI]

    ; AX = absolute value of CURRENT_HEAD - request.
    ; CMP sets flags without changing either operand. Unsigned JAE chooses
    ; current-request when current >= request; otherwise calculate request-current.
    MOV AX, CURRENT_HEAD
    CMP AX, BX
    JAE HEAD_IS_GREATER

    MOV AX, BX
    SUB AX, CURRENT_HEAD
    JMP ADD_MOVEMENT

HEAD_IS_GREATER:
    ; This difference is nonnegative, so no signed arithmetic or absolute-value
    ; instruction is needed. Equal positions correctly contribute zero movement.
    SUB AX, BX

ADD_MOVEMENT:
    ; Accumulate this leg, update the head to the serviced cylinder, and print
    ; it. PRINT_NUMBER preserves BX/CX and does not use SI, allowing the
    ; request pointer and loop count to continue afterward.
    ADD TOTAL_MOVEMENT, AX
    MOV CURRENT_HEAD, BX

    MOV AX, BX
    CALL PRINT_NUMBER

    ADD SI, 2
    LOOP FCFS_LOOP

    ; After the final request, display the accumulated distance and its units.
    LEA DX, TOTAL_MSG
    CALL PRINT_STRING

    MOV AX, TOTAL_MOVEMENT
    CALL PRINT_NUMBER

    LEA DX, UNIT_MSG
    CALL PRINT_STRING

    ; AH=4CH terminates the DOS process; AL=00H returns success status.
    MOV AX, 4C00H
    INT 21H
MAIN ENDP

; Reads an unsigned decimal number using DOS buffered input.
; Output: AX = number and CF = 0 when valid.
;         CF = 1 when the input is empty or contains a nondigit.
READ_NUMBER PROC NEAR
    ; Save scratch registers; AX is the returned value. NEAR means this
    ; procedure is called within the current code segment.
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    ; Reset the prior input count and call buffered line input at DS:DX.
    ; DOS service AH=0AH echoes characters and returns after Enter.
    MOV INPUT_BUFFER[1], 0
    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    ; Function 0AH returns the cursor to column 0 but DOSBox does not
    ; advance to the next row. Print LF so the next prompt is not
    ; written over the previous input line.
    MOV DL, 0AH
    MOV AH, 02H
    INT 21H

    ; Clear CH, load the returned length into CL, and reject an empty line.
    ; The count excludes CR, so it is also the number of digits to parse.
    XOR CX, CX
    MOV CL, INPUT_BUFFER[1]
    CMP CX, 0
    JE NUMBER_INVALID

    ; Skip the two-byte header. AX starts the decimal accumulator at zero.
    LEA SI, INPUT_BUFFER[2]
    XOR AX, AX

CONVERT_DIGIT:
    ; ASCII '0'..'9' are consecutive codes. Unsigned JB/JA reject everything
    ; outside that range; subtract '0' to convert the character into digit 0..9.
    MOV DL, [SI]
    CMP DL, '0'
    JB NUMBER_INVALID
    CMP DL, '9'
    JA NUMBER_INVALID

    SUB DL, '0'
    XOR DH, DH
    ; Save the zero-extended digit in BX before multiplication overwrites DX.
    MOV BX, DX

    ; AX = AX * 10 + digit
    ; Word MUL DX uses AX*DX, returning DX:AX. With at most three digits the
    ; accumulated result is <=999, so the product's upper word is zero.
    MOV DX, 10
    MUL DX
    ADD AX, BX

    ; Advance one character and repeat CX times. All digits accepted means
    ; CLC can report success; invalid input instead reaches STC below.
    INC SI
    LOOP CONVERT_DIGIT

    CLC
    JMP READ_NUMBER_DONE

NUMBER_INVALID:
    ; STC sets carry for failure; AX has no valid returned number on this path.
    STC

READ_NUMBER_DONE:
    ; Restore saved words in reverse order. POP/RET preserve the carry result.
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_NUMBER ENDP

; Prints the unsigned number in AX as decimal.
PRINT_NUMBER PROC NEAR
    ; Save registers so printing cannot consume the FCFS accumulator, request
    ; value or loop count. AX is treated as an unsigned word during conversion.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    ; Handle zero directly with DOS service 02H, which prints the character in DL.
    CMP AX, 0
    JNE DIVIDE_NUMBER

    MOV DL, '0'
    MOV AH, 02H
    INT 21H
    JMP PRINT_NUMBER_DONE

DIVIDE_NUMBER:
    ; For a nonzero value, BX=10 is the decimal divisor; CX counts saved digits.
    XOR CX, CX
    MOV BX, 10

DIVIDE_LOOP:
    ; Clear DX before each word DIV so the dividend DX:AX is just AX.
    ; The quotient returns in AX and remainder digit in DX. Push remainders
    ; to reverse their extraction order for left-to-right printing later.
    XOR DX, DX
    DIV BX
    PUSH DX
    INC CX
    CMP AX, 0
    JNE DIVIDE_LOOP

PRINT_DIGIT:
    ; Pop a digit, add ASCII '0', and print DL through DOS service 02H.
    ; LOOP decrements CX until all saved digit words have been removed.
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PRINT_DIGIT

PRINT_NUMBER_DONE:
    ; Restore the original register words, after any temporary digits are gone.
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_NUMBER ENDP

; Prints a DOS '$'-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    ; Preserve AX while selecting DOS service 09H for the text at DS:DX.
    PUSH AX
    MOV AH, 09H
    INT 21H
    POP AX
    RET
PRINT_STRING ENDP

CODESEG ENDS
; ENDP/ENDS close declarations; END closes the source and selects MAIN as entry.
END MAIN
