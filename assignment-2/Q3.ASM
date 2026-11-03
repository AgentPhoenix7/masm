; Q3. Implement FCFS (First-Come-First-Served) disk scheduling algorithm using MASM.

; FCFS disk scheduling for 8086
; MASM 5.x / DOSBox compatible

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
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

    REQUEST_COUNT DB 0
    REQUESTS      DW 10 DUP (0)
    INITIAL_HEAD  DW 0
    CURRENT_HEAD  DW 0
    TOTAL_MOVEMENT DW 0
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

MAIN PROC
    MOV AX, DATASEG
    MOV DS, AX

    LEA DX, TITLE_MSG
    CALL PRINT_STRING

; Read and validate the number of requests.
READ_COUNT:
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
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_COUNT

; Read all cylinder requests in their original order.
READ_REQUESTS:
    XOR SI, SI
    XOR CX, CX
    MOV CL, REQUEST_COUNT

READ_ONE_REQUEST:
    LEA DX, REQUEST_MSG
    CALL PRINT_STRING
    CALL READ_NUMBER
    JC BAD_REQUEST

    CMP AX, 999
    JA BAD_REQUEST

    MOV REQUESTS[SI], AX
    ADD SI, 2
    LOOP READ_ONE_REQUEST
    JMP READ_HEAD

BAD_REQUEST:
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_ONE_REQUEST

; Read and validate the initial head position.
READ_HEAD:
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
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_HEAD

; Service each request in FCFS input order.
RUN_FCFS:
    LEA DX, SEQUENCE_MSG
    CALL PRINT_STRING

    MOV AX, INITIAL_HEAD
    CALL PRINT_NUMBER

    XOR SI, SI
    XOR CX, CX
    MOV CL, REQUEST_COUNT

FCFS_LOOP:
    LEA DX, ARROW_MSG
    CALL PRINT_STRING

    MOV BX, REQUESTS[SI]

    ; AX = absolute value of CURRENT_HEAD - request.
    MOV AX, CURRENT_HEAD
    CMP AX, BX
    JAE HEAD_IS_GREATER

    MOV AX, BX
    SUB AX, CURRENT_HEAD
    JMP ADD_MOVEMENT

HEAD_IS_GREATER:
    SUB AX, BX

ADD_MOVEMENT:
    ADD TOTAL_MOVEMENT, AX
    MOV CURRENT_HEAD, BX

    MOV AX, BX
    CALL PRINT_NUMBER

    ADD SI, 2
    LOOP FCFS_LOOP

    LEA DX, TOTAL_MSG
    CALL PRINT_STRING

    MOV AX, TOTAL_MOVEMENT
    CALL PRINT_NUMBER

    LEA DX, UNIT_MSG
    CALL PRINT_STRING

    MOV AX, 4C00H
    INT 21H
MAIN ENDP

; Reads an unsigned decimal number using DOS buffered input.
; Output: AX = number and CF = 0 when valid.
;         CF = 1 when the input is empty or contains a nondigit.
READ_NUMBER PROC NEAR
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

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

    XOR CX, CX
    MOV CL, INPUT_BUFFER[1]
    CMP CX, 0
    JE NUMBER_INVALID

    LEA SI, INPUT_BUFFER[2]
    XOR AX, AX

CONVERT_DIGIT:
    MOV DL, [SI]
    CMP DL, '0'
    JB NUMBER_INVALID
    CMP DL, '9'
    JA NUMBER_INVALID

    SUB DL, '0'
    XOR DH, DH
    MOV BX, DX

    ; AX = AX * 10 + digit
    MOV DX, 10
    MUL DX
    ADD AX, BX

    INC SI
    LOOP CONVERT_DIGIT

    CLC
    JMP READ_NUMBER_DONE

NUMBER_INVALID:
    STC

READ_NUMBER_DONE:
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_NUMBER ENDP

; Prints the unsigned number in AX as decimal.
PRINT_NUMBER PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    CMP AX, 0
    JNE DIVIDE_NUMBER

    MOV DL, '0'
    MOV AH, 02H
    INT 21H
    JMP PRINT_NUMBER_DONE

DIVIDE_NUMBER:
    XOR CX, CX
    MOV BX, 10

DIVIDE_LOOP:
    XOR DX, DX
    DIV BX
    PUSH DX
    INC CX
    CMP AX, 0
    JNE DIVIDE_LOOP

PRINT_DIGIT:
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PRINT_DIGIT

PRINT_NUMBER_DONE:
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_NUMBER ENDP

; Prints a DOS '$'-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    PUSH AX
    MOV AH, 09H
    INT 21H
    POP AX
    RET
PRINT_STRING ENDP

CODESEG ENDS
END MAIN
