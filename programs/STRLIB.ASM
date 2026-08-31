; Question 5 library module.
; All strings are zero-terminated and addressed through DS.

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ASSUME CS:CODESEG
    PUBLIC STRLEN, STRCMP, STRREV

; Input:  DS:SI -> zero-terminated string
; Output: AX = character count (terminating zero is not counted)
; SI is preserved.
STRLEN PROC NEAR
    PUSH SI
    XOR AX, AX
SL_NEXT:
    CMP BYTE PTR [SI], 0
    JE SL_DONE
    INC SI
    INC AX
    JMP SHORT SL_NEXT
SL_DONE:
    POP SI
    RET
STRLEN ENDP

; Input:  DS:SI -> first string, DS:DI -> second string
; Output: AX = FFFFH if first < second, 0000H if equal, 0001H if first > second
; SI and DI are preserved.
STRCMP PROC NEAR
    PUSH BX
    PUSH SI
    PUSH DI
SC_NEXT:
    MOV AL, [SI]
    MOV BL, [DI]
    CMP AL, BL
    JB SC_LESS
    JA SC_GREATER
    OR AL, AL
    JZ SC_EQUAL
    INC SI
    INC DI
    JMP SHORT SC_NEXT
SC_LESS:
    MOV AX, 0FFFFH
    JMP SHORT SC_DONE
SC_GREATER:
    MOV AX, 1
    JMP SHORT SC_DONE
SC_EQUAL:
    XOR AX, AX
SC_DONE:
    POP DI
    POP SI
    POP BX
    RET
STRCMP ENDP

; Input:  DS:SI -> writable zero-terminated string
; Output: AX = character count; the string is reversed in place.
; SI and DI are preserved.
STRREV PROC NEAR
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    CALL STRLEN
    MOV DX, AX
    CMP AX, 1
    JBE SR_DONE
    MOV DI, SI
    ADD DI, AX
    DEC DI
    MOV CX, AX
    SHR CX, 1
SR_SWAP:
    MOV AL, [SI]
    MOV AH, [DI]
    MOV [SI], AH
    MOV [DI], AL
    INC SI
    DEC DI
    LOOP SR_SWAP
SR_DONE:
    MOV AX, DX
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    RET
STRREV ENDP

CODESEG ENDS
END

