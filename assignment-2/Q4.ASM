; Implement a MASM program to sort an array of n elements. (n should be taken as user input)

; Sort n user-entered elements in ascending order using Bubble Sort
; MASM 5.x / 8086 / DOSBox compatible
;
; Flow: read n -> read n word-sized values -> bubble-sort them in place ->
; print the ascending result -> return to DOS. Invalid entries retry their
; current field; n is restricted to 1..20 and each value to 0..999.
; AX/BX/CX/DX are 16-bit registers; AH/AL etc. are their upper/lower bytes.
; H marks hexadecimal constants; unmarked numeric constants here are decimal.

; SEGMENT/ENDS declare assembler sections. PARA requests 16-byte alignment;
; STACK lets the linker record initial SS:SP for the DOS .EXE loader.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW reserves words: 128 words provide 256 stack bytes for CALL/PUSH.
    ; DUP repeats the declaration; ? leaves initial contents unspecified.
    DW 128 DUP (?)
STACKSEG ENDS

DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; PUBLIC permits compatible segments to be combined by the linker.
    ; DB stores bytes/character codes. DOS string service 09H stops at '$'.
    ; 13/10 are carriage return/line feed for a DOS newline.
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
    ; Capacity 4 includes the final CR, allowing up to three typed digits.
    ; Returned count at +1 excludes CR; typed characters start at +2.

    ; The length fits in a byte, but each 0..999 element needs a word (DW).
    ; Twenty words occupy forty bytes, indexed at byte offsets 0,2,4,...,38.
    ARRAY_LENGTH DB 0
    ARRAY        DW 20 DUP (0)
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME tells the assembler intended segment-register associations;
    ; it executes nothing and does not initialize DS at run time.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

MAIN PROC
    ; DS initially points to the DOS program segment prefix. Load DATASEG via
    ; AX because MOV cannot load DS directly from an immediate segment value.
    MOV AX, DATASEG
    MOV DS, AX

    ; LEA loads a string offset into DX; PRINT_STRING prints the text at DS:DX.
    ; CALL saves the next instruction's address; RET returns to it via SS:SP.
    LEA DX, TITLE_MSG
    CALL PRINT_STRING

; Read and validate n.
READ_SIZE:
    ; READ_NUMBER returns AX and clears CF (carry) on valid digits. JC rejects
    ; a parse error; unsigned JB/JA additionally require the count to be 1..20.
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
    ; A bad count prints an explanation and retries before touching the array.
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_SIZE

; Read n array elements.
READ_ELEMENTS:
    ; SI starts at byte offset zero. Clear CH before loading the byte length
    ; into CL so CX becomes the complete outer input-loop count.
    XOR SI, SI
    XOR CX, CX
    MOV CL, ARRAY_LENGTH

READ_ONE_ELEMENT:
    ; Parse one unsigned number and enforce the advertised 999 maximum.
    LEA DX, ELEMENT_MSG
    CALL PRINT_STRING
    CALL READ_NUMBER
    JC BAD_ELEMENT

    CMP AX, 999
    JA BAD_ELEMENT

    MOV ARRAY[SI], AX
    ; Store a full word, then advance two bytes. LOOP decrements CX, so only
    ; successfully stored elements count toward the requested array length.
    ADD SI, 2
    LOOP READ_ONE_ELEMENT
    JMP SORT_ARRAY

BAD_ELEMENT:
    ; Retry the current slot without changing SI or CX. READ_NUMBER preserves
    ; both, preventing its internal digit loop from disrupting this input loop.
    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP READ_ONE_ELEMENT

SORT_ARRAY:
    ; Sort the existing array in place. The procedure saves its working
    ; registers; reset SI/CX for a separate traversal of the finished array.
    CALL BUBBLE_SORT

    LEA DX, RESULT_MSG
    CALL PRINT_STRING

    XOR SI, SI
    XOR CX, CX
    MOV CL, ARRAY_LENGTH

PRINT_ARRAY:
    ; Fetch a word and print its decimal representation. PRINT_NUMBER restores
    ; CX so the display's remaining-element count survives the conversion.
    MOV AX, ARRAY[SI]
    CALL PRINT_NUMBER

    ADD SI, 2
    DEC CX
    ; DEC sets the zero flag when the last element has been consumed. JZ ends
    ; output before printing a separator, avoiding a space after the final value.
    JZ PRINT_COMPLETE

    LEA DX, SPACE_MSG
    CALL PRINT_STRING
    JMP PRINT_ARRAY

PRINT_COMPLETE:
    ; Print CR/LF, then terminate through DOS service AH=4CH with AL=0 (success).
    LEA DX, NEWLINE
    CALL PRINT_STRING

    MOV AX, 4C00H
    INT 21H
MAIN ENDP

; Sorts ARRAY in ascending unsigned order using Bubble Sort.
BUBBLE_SORT PROC NEAR
    ; Preserve the caller's registers. SI scans byte offsets, CX counts inner
    ; comparisons, and DX tracks the unsorted part's comparison count per pass.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    ; Empty/single-element arrays need no comparisons. The input path permits
    ; at least one element, but this guard also protects the procedure itself.
    CMP ARRAY_LENGTH, 1
    JBE SORT_DONE

    ; Zero-extend n from DL into DX, then start with n-1 adjacent comparisons.
    XOR DX, DX
    MOV DL, ARRAY_LENGTH
    DEC DX                         ; Number of comparisons in first pass

OUTER_LOOP:
    ; Restart scanning at the first word for each pass, with the current
    ; unsorted comparison count. The suffix already contains its final maxima.
    XOR SI, SI
    MOV CX, DX

INNER_LOOP:
    ; Load the adjacent words before writing either. CMP sets flags; unsigned
    ; JBE keeps left<=right, including equal values, in their existing order.
    MOV AX, ARRAY[SI]
    MOV BX, ARRAY[SI+2]

    CMP AX, BX
    JBE NO_SWAP

    ; Left is larger: exchange the two word values, moving the larger right.
    ; Repeating this across the pass moves the unsorted maximum to its end.
    MOV ARRAY[SI], BX
    MOV ARRAY[SI+2], AX

NO_SWAP:
    ; Advance one word to the next overlapping pair. LOOP decrements CX until
    ; this pass is complete, whether or not any exchanges were necessary.
    ADD SI, 2
    LOOP INNER_LOOP

    DEC DX                         ; One fewer comparison next pass
    ; The largest remaining value is now fixed; exclude it on the next pass.
    ; There is no early-exit swap flag: n*(n-1)/2 comparisons run even for an
    ; already-sorted array. Time is O(n^2); the array needs no extra copy.
    JNZ OUTER_LOOP

SORT_DONE:
    ; Restore words in reverse PUSH order and return to the display setup.
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
    ; Preserve BX/CX/DX/SI for the caller; AX deliberately carries the result.
    ; NEAR means the procedure is called within the current code segment.
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    ; Clear the prior length, then DOS service 0AH reads/echoes a line at DS:DX.
    MOV INPUT_BUFFER[1], 0
    LEA DX, INPUT_BUFFER
    MOV AH, 0AH
    INT 21H

    ; Move to the next screen row after Enter so the following prompt
    ; does not overwrite the previous input line in DOSBox.
    MOV DL, 0AH
    MOV AH, 02H
    INT 21H

    ; Clear CH and load the returned digit count into CL. Reject an empty
    ; line before parsing so zero typed digits is not confused with number 0.
    XOR CX, CX
    MOV CL, INPUT_BUFFER[1]
    CMP CX, 0
    JE NUMBER_INVALID

    ; Skip the buffer header and initialize the decimal accumulator AX to zero.
    LEA SI, INPUT_BUFFER[2]
    XOR AX, AX

CONVERT_DIGIT:
    ; ASCII digit codes are consecutive: accept only unsigned '0'..'9', then
    ; subtract '0' to obtain a digit 0..9 and clear DH to zero-extend it.
    MOV DL, [SI]
    CMP DL, '0'
    JB NUMBER_INVALID
    CMP DL, '9'
    JA NUMBER_INVALID

    SUB DL, '0'
    XOR DH, DH
    MOV BX, DX                     ; BX = current digit

    ; Save the digit in BX because word MUL DX overwrites DX with the high
    ; product word. AX*10+digit builds the number from left to right; at most
    ; three typed digits keep every result <=999, safely within the word AX.
    MOV DX, 10
    MUL DX                         ; AX = AX * 10
    ADD AX, BX                     ; AX = AX * 10 + digit

    ; Advance to the next digit and decrement CX via LOOP until all are checked.
    INC SI
    LOOP CONVERT_DIGIT

    ; Explicit carry status: CLC succeeds and bypasses STC; invalid input sets CF.
    CLC
    JMP READ_NUMBER_DONE

NUMBER_INVALID:
    STC

READ_NUMBER_DONE:
    ; Restore saved registers in reverse order. POP/RET do not change CF, so
    ; the caller's JC tests the parsing result after the procedure returns.
    POP SI
    POP DX
    POP CX
    POP BX
    RET
READ_NUMBER ENDP

; Prints the unsigned number in AX as decimal.
PRINT_NUMBER PROC NEAR
    ; Preserve AX/BX/CX/DX so printing leaves the caller's loop state intact.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    ; Zero takes a direct path: DOS service 02H prints the single character in DL.
    CMP AX, 0
    JNE DIVIDE_NUMBER

    MOV DL, '0'
    MOV AH, 02H
    INT 21H
    JMP PRINT_NUMBER_DONE

DIVIDE_NUMBER:
    ; BX=10 is the decimal divisor; CX counts remainder digits saved on the stack.
    XOR CX, CX
    MOV BX, 10

DIVIDE_LOOP:
    ; Clear DX for each word DIV: divide DX:AX by ten, returning quotient in AX
    ; and digit 0..9 in DX. Push digits so later POPs print the leftmost first.
    XOR DX, DX
    DIV BX
    PUSH DX
    INC CX
    CMP AX, 0
    JNE DIVIDE_LOOP

PRINT_DIGIT:
    ; Add ASCII '0' to each popped numeric digit and print DL through service
    ; 02H. LOOP consumes the digit count until no temporary digit words remain.
    POP DX
    ADD DL, '0'
    MOV AH, 02H
    INT 21H
    LOOP PRINT_DIGIT

PRINT_NUMBER_DONE:
    ; Restore original register words, then RET resumes the array-printing loop.
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_NUMBER ENDP

; Prints the DOS '$'-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    ; Preserve AX/CX/DX while selecting DOS service 09H to print DS:DX.
    ; Saving CX specifically protects loops that call this helper for a space.
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
; ENDP/ENDS close declarations; END closes the module and identifies MAIN as entry.
END MAIN
