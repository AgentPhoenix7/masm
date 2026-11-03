; Implement a MASM program to sort an array of n elements. (n should be taken as user input)

; Sort n user-entered elements in ascending order using Bubble Sort
; MASM 5.x / 8086 / DOSBox compatible

STACKSEG SEGMENT PARA STACK 'STACK'
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    TITLE_MSG   DB 13,10,'ARRAY SORTING USING BUBBLE SORT',13,10,'$'
    SIZE_MSG    DB 'Enter number of elements (1-20): $'
    ELEMENT_MSG DB 'Enter element (0-999): $'
    INVALID_MSG DB 'Invalid input. Try again.',13,10,'$'
    RESULT_MSG  DB 13,10,'Sorted array: $'
    SPACE_MSG   DB ' $'
    NEWLINE     DB 13,10,'$'

    ; DOS function 0Ah input buffer:
    ; maximum length, actual length, input characters, carriage return.
    INPUT_BUFFER DB 4,0,4 DUP (0)

    ARRAY_LENGTH DB 0
    ARRAY        DW 20 DUP (0)
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

MAIN PROC
    MOV AX, DATASEG
    MOV DS, AX

    LEA DX, TITLE_MSG
    CALL PRINT_STRING

; Read and validate n.
READ_SIZE:
    LEA DX, SIZE_MSG
    CALL PRINT_STRING
    CALL READ_NUMBER
    JC BAD_SIZE

    CMP AX, 1
    JB BAD_SIZE
    CMP AX, 20
    JA BAD_SIZE

    MOV ARRAY_LENGTH, AL
    JMP READ_ELEMENTS

BAD_SIZE:
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_SIZE

; Read n array elements.
READ_ELEMENTS:
    XOR SI, SI
    XOR CX, CX
    MOV CL, ARRAY_LENGTH

READ_ONE_ELEMENT:
    LEA DX, ELEMENT_MSG
    CALL PRINT_STRING
    CALL READ_NUMBER
    JC BAD_ELEMENT

    CMP AX, 999
    JA BAD_ELEMENT

    MOV ARRAY[SI], AX
    ADD SI, 2
    LOOP READ_ONE_ELEMENT
    JMP SORT_ARRAY

BAD_ELEMENT:
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_ONE_ELEMENT

SORT_ARRAY:
    CALL BUBBLE_SORT

    LEA DX, RESULT_MSG
    CALL PRINT_STRING

    XOR SI, SI
    XOR CX, CX
    MOV CL, ARRAY_LENGTH

PRINT_ARRAY:
    MOV AX, ARRAY[SI]
    CALL PRINT_NUMBER

    ADD SI, 2
    DEC CX
    JZ PRINT_COMPLETE

    LEA DX, SPACE_MSG
    CALL PRINT_STRING
    JMP PRINT_ARRAY

PRINT_COMPLETE:
    LEA DX, NEWLINE
    CALL PRINT_STRING

    MOV AX, 4C00H
    INT 21H
MAIN ENDP

; Sorts ARRAY in ascending unsigned order using Bubble Sort.
BUBBLE_SORT PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    CMP ARRAY_LENGTH, 1
    JBE SORT_DONE

    XOR DX, DX
    MOV DL, ARRAY_LENGTH
    DEC DX                         ; Number of comparisons in first pass

OUTER_LOOP:
    XOR SI, SI
    MOV CX, DX

INNER_LOOP:
    MOV AX, ARRAY[SI]
    MOV BX, ARRAY[SI+2]

    CMP AX, BX
    JBE NO_SWAP

    MOV ARRAY[SI], BX
    MOV ARRAY[SI+2], AX

NO_SWAP:
    ADD SI, 2
    LOOP INNER_LOOP

    DEC DX                         ; One fewer comparison next pass
    JNZ OUTER_LOOP

SORT_DONE:
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
BUBBLE_SORT ENDP

; Reads an unsigned decimal number using DOS buffered input.
; Returns AX = number and CF = 0 for valid numeric input.
; Returns CF = 1 for empty or nonnumeric input.
READ_NUMBER PROC NEAR
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    MOV INPUT_BUFFER[1], 0
    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    ; Move to the next screen row after Enter so the following prompt
    ; does not overwrite the previous input line in DOSBox.
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
    MOV BX, DX                     ; BX = current digit

    MOV DX, 10
    MUL DX                         ; AX = AX * 10
    ADD AX, BX                     ; AX = AX * 10 + digit

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

; Prints the DOS '$'-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    PUSH AX
    PUSH CX
    PUSH DX
    MOV AH, 09H
    INT 21H
    POP DX
    POP CX
    POP AX
    RET
PRINT_STRING ENDP

CODESEG ENDS
END MAIN
