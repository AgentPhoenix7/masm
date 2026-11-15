; Q2. Design and implement a simple command-line shell emulator using MASM (Microsoft Macro Assembler) that accepts user commands from the terminal and performs appropriate actions. The shell must interpret the following commands:
; a. DIR - Display a list of mock file names (simulate file listing)
; b. TYPE <filename> - Display the contents of the specified file
; c. COPY <source> <destination> - Copy the contents of one file to another
; d. EXIT - Exit the shell interface and terminate the program
; e. The emulator should prompt the user for input, parse the entered command, and invoke the appropriate function to operate. All actions should be implemented using MASM and DOS system interrupts (INT 21h) where applicable.

; Simple command-line shell emulator for 8086 DOS
; MASM 5.x compatible
;
; Commands:
;   DIR
;   TYPE <filename>
;   COPY <source> <destination>
;   EXIT
;
; Flow: initialize DS/ES -> prompt/read a line -> parse command and arguments ->
; dispatch a DOS file operation -> return to the prompt until EXIT is entered.
; Despite the mock-DIR wording in the question, this implementation enumerates
; real directory entries and TYPE/COPY access real files in the DOS environment.
; No external command execution is performed; only the four listed commands run.
; AX/BX/CX/DX are 16-bit registers; AH/AL etc. are their upper/lower bytes.
; H marks hexadecimal constants. DS:DX denotes a segment plus a byte offset.

; SEGMENT/ENDS declare assembler sections. PARA requests 16-byte alignment;
; STACK lets the linker record initial SS:SP for the DOS .EXE loader.
STACKSEG SEGMENT PARA STACK 'STACK'
    ; DW reserves words: 128 words provide 256 CPU-stack bytes for CALL/PUSH.
    ; DUP repeats the declaration; ? leaves initial contents unspecified.
    DW 128 DUP (?)
STACKSEG ENDS

; EQU defines constants without allocating storage. The parser returns these
; command identifiers in AL; zero means blank input or a rejected command.
CMD_NONE EQU 0
CMD_DIR  EQU 1
CMD_TYPE EQU 2
CMD_COPY EQU 3
CMD_EXIT EQU 4

DATASEG SEGMENT PARA PUBLIC 'DATA'
    ; PUBLIC permits compatible segments to be combined by the linker.
    ; DB stores bytes/character codes. Screen messages use '$' termination for
    ; DOS service 09H; 13/10 are carriage return/line feed for a new line.
    TITLE_MSG       DB 13,10,'SIMPLE DOS SHELL',13,10
                    DB 'Commands: DIR, TYPE <file>, COPY <source> <destination>, EXIT',13,10,'$'
    PROMPT_MSG      DB 13,10,'SHELL> $'
    DIR_TITLE_MSG   DB 'Directory contents:',13,10,'$'
    NO_FILES_MSG    DB 'No files found.',13,10,'$'
    INVALID_MSG     DB 'Invalid command or syntax.',13,10,'$'
    SAME_FILE_MSG   DB 'Source and destination cannot be the same file.',13,10,'$'
    OPEN_ERROR_MSG  DB 'Error: cannot open source file.',13,10,'$'
    CREATE_ERR_MSG  DB 'Error: cannot create destination file.',13,10,'$'
    READ_ERROR_MSG  DB 'Error: cannot read file.',13,10,'$'
    WRITE_ERROR_MSG DB 'Error: cannot write file.',13,10,'$'
    COPY_OK_MSG     DB 'File copied successfully.',13,10,'$'
    GOODBYE_MSG     DB 'Exiting shell.',13,10,'$'
    NEWLINE         DB 13,10,'$'

    ; Command spellings, filenames and the wildcard instead use ASCIIZ (zero
    ; termination), as required by comparisons and DOS filename services.
    CMD_DIR_TEXT    DB 'DIR',0
    CMD_TYPE_TEXT   DB 'TYPE',0
    CMD_COPY_TEXT   DB 'COPY',0
    CMD_EXIT_TEXT   DB 'EXIT',0
    ALL_FILES       DB '*.*',0

    ; DOS function 0Ah input buffer:
    ; maximum length, actual length, characters followed by CR.
    COMMAND_BUFFER  DB 126,0,127 DUP (0)
    ; Capacity includes the final CR. READ_COMMAND replaces that CR with zero
    ; after DOS returns, allowing the parser to scan without a length counter.

    ; Token arrays reserve one final byte for zero: 15 command characters and
    ; 63 per filename. GET_TOKEN consumes excess characters but truncates the
    ; stored token; it does not report overlong names as a distinct error.
    COMMAND_TOKEN   DB 16 DUP (0)
    SOURCE_NAME     DB 64 DUP (0)
    DEST_NAME       DB 64 DUP (0)

    ; COMMAND_ID selects an operation; PARSE_ERROR distinguishes blank input
    ; from invalid syntax (1) and same-spelling COPY source/destination (2).
    COMMAND_ID      DB CMD_NONE
    PARSE_ERROR     DB 0

    ; Handles are DOS-provided word identifiers for opened files, not pointers.
    ; READ_COUNT saves each copy chunk's exact length across subsequent calls.
    SOURCE_HANDLE   DW 0
    DEST_HANDLE     DW 0
    READ_COUNT      DW 0

    ; IO_BUFFER transfers files in 128-byte chunks; lengths make zero/'$' bytes
    ; ordinary data. DTA_BUFFER holds DOS FindFirst/FindNext directory results.
    IO_BUFFER       DB 128 DUP (0)
    DTA_BUFFER      DB 128 DUP (0)
DATASEG ENDS

CODESEG SEGMENT PARA PUBLIC 'CODE'
    ; ASSUME describes intended segment-register use; it does not load registers.
    ASSUME CS:CODESEG, DS:DATASEG, SS:STACKSEG

MAIN PROC
    ; DOS .EXE startup leaves DS pointing at the program segment prefix. Load
    ; DATASEG through AX because MOV cannot load DS from an immediate segment
    ; value. ES is also set to DATASEG, though token copying here uses DS.
    MOV AX, DATASEG
    MOV DS, AX
    MOV ES, AX

    ; LEA loads an offset, not the string contents. PRINT_STRING uses DS:DX.
    ; CALL saves a return address on SS:SP; RET resumes at the following line.
    LEA DX, TITLE_MSG
    CALL PRINT_STRING

SHELL_LOOP:
    ; Each iteration reads and parses a new command, then dispatches on AL.
    ; CMP sets flags without modifying AL; JE selects a matching command ID.
    LEA DX, PROMPT_MSG
    CALL PRINT_STRING

    CALL READ_COMMAND
    CALL PARSE_COMMAND

    CMP AL, CMD_DIR
    JE RUN_DIR
    CMP AL, CMD_TYPE
    JE RUN_TYPE
    CMP AL, CMD_COPY
    JE RUN_COPY
    CMP AL, CMD_EXIT
    JE RUN_EXIT

    ; No recognized command: blank input silently prompts again. Error 2 gets
    ; the specific same-file message; any other parser error prints syntax help.
    CMP PARSE_ERROR, 0
    JE SHELL_LOOP
    CMP PARSE_ERROR, 2
    JE SHOW_SAME_FILE

    LEA DX, INVALID_MSG
    CALL PRINT_STRING
    JMP SHELL_LOOP

SHOW_SAME_FILE:
    ; Reject identical filename spellings before COPY can create/truncate a file.
    LEA DX, SAME_FILE_MSG
    CALL PRINT_STRING
    JMP SHELL_LOOP

RUN_DIR:
    ; File-operation procedures return here even after errors, keeping the
    ; emulator alive. Each branch returns to the common prompt loop.
    CALL DO_DIR
    JMP SHELL_LOOP

RUN_TYPE:
    CALL DO_TYPE
    JMP SHELL_LOOP

RUN_COPY:
    CALL DO_COPY
    JMP SHELL_LOOP

RUN_EXIT:
    ; EXIT prints a goodbye and terminates with DOS service AH=4CH, AL=0.
    LEA DX, GOODBYE_MSG
    CALL PRINT_STRING

    MOV AX, 4C00H
    INT 21H
MAIN ENDP

; Reads one command line from the keyboard.
READ_COMMAND PROC NEAR
    ; Preserve working registers; the returned line is stored in COMMAND_BUFFER.
    ; NEAR means the procedure is called within the current code segment.
    PUSH AX
    PUSH BX
    PUSH DX
    PUSH SI

    ; Reset the prior count, then DOS service AH=0AH reads/echoes a line at DS:DX.
    MOV COMMAND_BUFFER[1], 0
    LEA DX, COMMAND_BUFFER
    MOV AH, 0AH
    INT 21H

    ; Replace the final carriage return with an ASCIIZ terminator.
    ; Clear BH, load the returned count into BL, then characters+count locates
    ; the CR. BYTE PTR makes the immediate zero store explicitly one byte wide.
    XOR BX, BX
    MOV BL, COMMAND_BUFFER[1]
    LEA SI, COMMAND_BUFFER[2]
    ADD SI, BX
    MOV BYTE PTR [SI], 0

    ; Restore saved words in reverse PUSH order and resume the shell loop.
    POP SI
    POP DX
    POP BX
    POP AX
    RET
READ_COMMAND ENDP

; Parses the command line.
; Returns AL = CMD_* and sets PARSE_ERROR:
;   0 = no error/blank line, 1 = invalid syntax, 2 = same COPY file.
PARSE_COMMAND PROC NEAR
    ; Save scratch registers; AL intentionally returns the command identifier.
    ; Reset parser state so a previous valid command cannot leak into this line.
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI

    MOV COMMAND_ID, CMD_NONE
    MOV PARSE_ERROR, 0

    ; Extract the first space-delimited word into the 16-byte command buffer,
    ; leaving one byte for zero. No token means blank/space-only input.
    LEA SI, COMMAND_BUFFER[2]
    LEA DI, COMMAND_TOKEN
    MOV CX, 15
    CALL GET_TOKEN
    CMP AL, 0
    JE PARSE_FINISHED

    ; Uppercase the command token in place, making command names case-insensitive.
    ; Filename tokens are left unchanged for DOS and later same-name comparison.
    LEA SI, COMMAND_TOKEN
    CALL UPPERCASE_STRING

    LEA SI, COMMAND_TOKEN
    ; Compare the normalized token to each supported command spelling.
    ; STR_EQUAL returns AL=1 only for a complete match, including the terminator.
    LEA DI, CMD_DIR_TEXT
    CALL STR_EQUAL
    CMP AL, 1
    JE PARSE_DIR

    LEA SI, COMMAND_TOKEN
    LEA DI, CMD_TYPE_TEXT
    CALL STR_EQUAL
    CMP AL, 1
    JE PARSE_TYPE

    LEA SI, COMMAND_TOKEN
    LEA DI, CMD_COPY_TEXT
    CALL STR_EQUAL
    CMP AL, 1
    JE PARSE_COPY

    LEA SI, COMMAND_TOKEN
    LEA DI, CMD_EXIT_TEXT
    CALL STR_EQUAL
    CMP AL, 1
    JE PARSE_EXIT

    JMP PARSE_INVALID

PARSE_DIR:
    ; Restart from the original line because SI was reused for command matching.
    ; DIR takes no arguments: skip the command and reject any nonspace remainder.
    LEA SI, COMMAND_BUFFER[2]
    CALL MOVE_PAST_COMMAND
    CALL HAS_MORE_TEXT
    CMP AL, 1
    JE PARSE_INVALID
    MOV COMMAND_ID, CMD_DIR
    JMP PARSE_FINISHED

PARSE_TYPE:
    ; TYPE requires exactly one filename: extract it, reject a missing token,
    ; then reject any extra nonspace text. Filenames cannot contain spaces here;
    ; the parser has no quoting/escape syntax and recognizes literal spaces only.
    LEA SI, COMMAND_BUFFER[2]
    CALL MOVE_PAST_COMMAND

    LEA DI, SOURCE_NAME
    MOV CX, 63
    CALL GET_TOKEN
    CMP AL, 0
    JE PARSE_INVALID

    CALL HAS_MORE_TEXT
    CMP AL, 1
    JE PARSE_INVALID

    MOV COMMAND_ID, CMD_TYPE
    JMP PARSE_FINISHED

PARSE_COPY:
    ; COPY requires two filenames. GET_TOKEN advances SI past each whole token,
    ; so the next call starts at the next argument after skipping its spaces.
    LEA SI, COMMAND_BUFFER[2]
    CALL MOVE_PAST_COMMAND

    LEA DI, SOURCE_NAME
    MOV CX, 63
    CALL GET_TOKEN
    CMP AL, 0
    JE PARSE_INVALID

    LEA DI, DEST_NAME
    MOV CX, 63
    CALL GET_TOKEN
    CMP AL, 0
    JE PARSE_INVALID

    CALL HAS_MORE_TEXT
    CMP AL, 1
    JE PARSE_INVALID

    ; After confirming no third argument, compare source/destination spelling
    ; case-insensitively. This checks text, not canonical file identity: aliases
    ; such as NAME.TXT and .\NAME.TXT are not normalized by SAME_NAMES.
    LEA SI, SOURCE_NAME
    LEA DI, DEST_NAME
    CALL SAME_NAMES
    CMP AL, 1
    JE PARSE_SAME_FILE

    MOV COMMAND_ID, CMD_COPY
    JMP PARSE_FINISHED

PARSE_EXIT:
    ; EXIT, like DIR, takes no arguments. Only mark the command valid after
    ; confirming there is no trailing nonspace text.
    LEA SI, COMMAND_BUFFER[2]
    CALL MOVE_PAST_COMMAND
    CALL HAS_MORE_TEXT
    CMP AL, 1
    JE PARSE_INVALID
    MOV COMMAND_ID, CMD_EXIT
    JMP PARSE_FINISHED

PARSE_INVALID:
    ; Keep COMMAND_ID at CMD_NONE and select the general syntax-error message.
    MOV PARSE_ERROR, 1
    JMP PARSE_FINISHED

PARSE_SAME_FILE:
    ; A separate code lets MAIN explain why the COPY command was rejected.
    MOV PARSE_ERROR, 2

PARSE_FINISHED:
    ; Restore saved registers, then load the final command ID into AL. Valid
    ; command handlers alone set COMMAND_ID, preventing execution on parse errors.
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    MOV AL, COMMAND_ID
    RET
PARSE_COMMAND ENDP

; Advances SI past leading spaces and the command word.
MOVE_PAST_COMMAND PROC NEAR
MPC_SKIP_SPACES:
    ; Skip leading literal spaces, then advance over the command word. SI ends
    ; at the separating space or zero; GET_TOKEN/HAS_MORE_TEXT skip spaces later.
    CMP BYTE PTR [SI], ' '
    JNE MPC_SKIP_WORD
    INC SI
    JMP MPC_SKIP_SPACES

MPC_SKIP_WORD:
    ; BYTE PTR makes each comparison byte-sized because an immediate alone
    ; does not specify the memory operand's width.
    CMP BYTE PTR [SI], 0
    JE MPC_DONE
    CMP BYTE PTR [SI], ' '
    JE MPC_DONE
    INC SI
    JMP MPC_SKIP_WORD

MPC_DONE:
    RET
MOVE_PAST_COMMAND ENDP

; Copies the next space-delimited token from DS:SI to DS:DI.
; CX is the maximum number of characters stored.
; Returns AL = 1 when a token exists, otherwise AL = 0.
GET_TOKEN PROC NEAR
    ; Preserve BX, used as the stored-token length. SI advances through input;
    ; DI remains the token's starting address, and CX is its storage limit.
    PUSH BX

GET_SKIP_SPACES:
    ; Skip leading separators. Reaching zero means no token exists.
    CMP BYTE PTR [SI], ' '
    JNE GET_START
    INC SI
    JMP GET_SKIP_SPACES

GET_START:
    ; A nonzero character starts a token; initialize the stored length to zero.
    CMP BYTE PTR [SI], 0
    JE GET_NONE

    XOR BX, BX

GET_COPY:
    ; Stop on a space or zero without consuming that delimiter. Until then,
    ; store only while BX<CX, using unsigned JAE for the capacity test.
    MOV AL, [SI]
    CMP AL, 0
    JE GET_DONE
    CMP AL, ' '
    JE GET_DONE

    CMP BX, CX
    JAE GET_CONSUME
    MOV [DI+BX], AL
    INC BX

GET_CONSUME:
    ; Always consume the input character, even when it could not fit. This
    ; discards an overlong token's tail while preserving the next argument's
    ; boundary; the returned token text is therefore a truncated prefix.
    INC SI
    JMP GET_COPY

GET_DONE:
    ; Terminate after the stored bytes. AL=1 reports existence, not whether
    ; the full token fit. The caller supplied space for this final zero byte.
    MOV BYTE PTR [DI+BX], 0
    MOV AL, 1
    JMP GET_RETURN

GET_NONE:
    ; Empty output plus AL=0 reports that no next argument was present.
    MOV BYTE PTR [DI], 0
    MOV AL, 0

GET_RETURN:
    ; Restore BX; SI deliberately stays advanced for the caller's next token.
    POP BX
    RET
GET_TOKEN ENDP

; Returns AL = 1 if non-space text remains at DS:SI.
HAS_MORE_TEXT PROC NEAR
HMT_SKIP:
    ; Skip spaces at the current SI, leaving it at either zero or the first
    ; extra character. AL=1 means text remains; AL=0 means only spaces/end.
    CMP BYTE PTR [SI], ' '
    JNE HMT_CHECK
    INC SI
    JMP HMT_SKIP

HMT_CHECK:
    CMP BYTE PTR [SI], 0
    JE HMT_NONE
    MOV AL, 1
    RET

HMT_NONE:
    MOV AL, 0
    RET
HAS_MORE_TEXT ENDP

; Converts an ASCIIZ string at DS:SI to uppercase.
UPPERCASE_STRING PROC NEAR
    ; Preserve AX and the starting SI. ASCII lowercase letters differ from
    ; uppercase by 20H (32), so subtract that only within 'a'..'z'.
    PUSH AX
    PUSH SI

UPPER_LOOP:
    ; Stop at zero; unsigned JB/JA leave digits, punctuation and existing
    ; uppercase letters unchanged. The conversion edits the token in memory.
    MOV AL, [SI]
    CMP AL, 0
    JE UPPER_DONE
    CMP AL, 'a'
    JB UPPER_NEXT
    CMP AL, 'z'
    JA UPPER_NEXT
    SUB BYTE PTR [SI], 20H

UPPER_NEXT:
    ; Advance to the next byte regardless of whether a letter was changed.
    INC SI
    JMP UPPER_LOOP

UPPER_DONE:
    ; Restore the caller's register values after modifying only the string bytes.
    POP SI
    POP AX
    RET
UPPERCASE_STRING ENDP

; Compares ASCIIZ strings DS:SI and DS:DI exactly.
; Returns AL = 1 when equal, otherwise AL = 0.
STR_EQUAL PROC NEAR
    ; Preserve scratch BX and both starting pointers. AX is not saved because
    ; AL returns the Boolean result for the parser to inspect.
    PUSH BX
    PUSH SI
    PUSH DI

STR_EQUAL_LOOP:
    ; Compare corresponding bytes; a mismatch fails immediately. Equal zero
    ; bytes end both strings together, so a matching prefix alone is insufficient.
    MOV AL, [SI]
    MOV BL, [DI]
    CMP AL, BL
    JNE STR_NOT_EQUAL
    CMP AL, 0
    JE STR_IS_EQUAL
    INC SI
    INC DI
    JMP STR_EQUAL_LOOP

STR_IS_EQUAL:
    ; Return true on matching terminators, false on any differing byte.
    MOV AL, 1
    JMP STR_EQUAL_DONE

STR_NOT_EQUAL:
    MOV AL, 0

STR_EQUAL_DONE:
    ; Restore pointers in reverse PUSH order, keeping the returned AL.
    POP DI
    POP SI
    POP BX
    RET
STR_EQUAL ENDP

; Compares two filenames case-insensitively.
SAME_NAMES PROC NEAR
    ; Compare temporary uppercase copies of filename characters, preserving
    ; the original filename bytes and both starting pointers. AL returns 1/0.
    PUSH BX
    PUSH DX
    PUSH SI
    PUSH DI

SAME_LOOP:
    ; Load one byte from each filename and fold lowercase 'a'..'z' in AL first.
    MOV AL, [SI]
    MOV DL, [DI]

    CMP AL, 'a'
    JB SAME_FIRST_READY
    CMP AL, 'z'
    JA SAME_FIRST_READY
    SUB AL, 20H

SAME_FIRST_READY:
    ; Apply the same ASCII case folding to DL, leaving nonletters unchanged.
    CMP DL, 'a'
    JB SAME_SECOND_READY
    CMP DL, 'z'
    JA SAME_SECOND_READY
    SUB DL, 20H

SAME_SECOND_READY:
    ; After folding, a mismatch means different spellings; equal terminators
    ; mean equal names. Otherwise advance both pointers for the next byte.
    CMP AL, DL
    JNE NAMES_DIFFER
    CMP AL, 0
    JE NAMES_EQUAL
    INC SI
    INC DI
    JMP SAME_LOOP

NAMES_EQUAL:
    MOV AL, 1
    JMP SAME_DONE

NAMES_DIFFER:
    MOV AL, 0

SAME_DONE:
    ; Restore saved registers while keeping the Boolean comparison result in AL.
    POP DI
    POP SI
    POP DX
    POP BX
    RET
SAME_NAMES ENDP

; Displays real files from the current DOS directory.
DO_DIR PROC NEAR
    ; Preserve working registers and print a directory heading. DOS directory
    ; search state resides in the DTA (Disk Transfer Area), not in IO_BUFFER.
    PUSH AX
    PUSH CX
    PUSH DX

    LEA DX, DIR_TITLE_MSG
    CALL PRINT_STRING

    ; DOS service 1AH sets the current DTA to DS:DX. The shell keeps using
    ; this private DTA for FindFirst/FindNext rather than restoring the old one.
    LEA DX, DTA_BUFFER
    MOV AH, 1AH
    INT 21H

    ; FindFirst (4EH) searches '*.*' in the current directory. CX=0 requests
    ; ordinary-file matching, excluding special entries such as directories
    ; and hidden/system files. CF set means the search found no usable result
    ; or failed; this program displays the same no-files message for either.
    LEA DX, ALL_FILES
    XOR CX, CX
    MOV AH, 4EH
    INT 21H
    JC DIR_EMPTY

DIR_PRINT_NEXT:
    ; The DOS DTA's ASCIIZ filename begins at byte offset 30 (1EH). Print
    ; that name and a newline before requesting the next matching entry.
    LEA DX, DTA_BUFFER[30]
    CALL PRINT_ZSTRING
    LEA DX, NEWLINE
    CALL PRINT_STRING

    ; FindNext (4FH) reuses DTA search state. JNC repeats while CF is clear;
    ; exhaustion and other FindNext failures both end the listing here.
    MOV AH, 4FH
    INT 21H
    JNC DIR_PRINT_NEXT
    JMP DIR_DONE

DIR_EMPTY:
    ; FindFirst produced no result, so there is no DTA filename to print.
    LEA DX, NO_FILES_MSG
    CALL PRINT_STRING

DIR_DONE:
    ; Restore the caller's registers and return to the main prompt loop.
    POP DX
    POP CX
    POP AX
    RET
DO_DIR ENDP

; Displays the contents of SOURCE_NAME.
DO_TYPE PROC NEAR
    ; Preserve working registers. DOS file reads/writes use explicit byte counts,
    ; so file contents need neither zero nor '$' terminators to be displayed.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    ; DOS open (AH=3DH, AL=00H) opens the ASCIIZ pathname at DS:DX read-only.
    ; On success AX is a handle to save; CF set instead means AX is an error code.
    LEA DX, SOURCE_NAME
    MOV AX, 3D00H
    INT 21H
    JC TYPE_OPEN_ERROR
    MOV SOURCE_HANDLE, AX

TYPE_READ_LOOP:
    ; Read (3FH) up to CX=128 bytes from handle BX into DS:DX. CF indicates
    ; an error; otherwise AX is the actual byte count, with zero meaning EOF.
    MOV BX, SOURCE_HANDLE
    LEA DX, IO_BUFFER
    MOV CX, 128
    MOV AH, 3FH
    INT 21H
    JC TYPE_READ_ERROR
    CMP AX, 0
    JE TYPE_COMPLETE

    ; Write (40H) exactly the bytes read to handle 1 (standard output). Check
    ; both CF and a short count, since a write can succeed with fewer bytes
    ; than requested. Continue reading only after a complete chunk was written.
    MOV CX, AX
    MOV BX, 1
    LEA DX, IO_BUFFER
    MOV AH, 40H
    INT 21H
    JC TYPE_WRITE_ERROR
    CMP AX, CX
    JNE TYPE_WRITE_ERROR
    JMP TYPE_READ_LOOP

TYPE_COMPLETE:
    ; At EOF, close the source with service 3EH and append a display newline.
    MOV BX, SOURCE_HANDLE
    MOV AH, 3EH
    INT 21H
    LEA DX, NEWLINE
    CALL PRINT_STRING
    JMP TYPE_DONE

TYPE_READ_ERROR:
    ; A source was opened, so close it before reporting the read failure.
    MOV BX, SOURCE_HANDLE
    MOV AH, 3EH
    INT 21H
    LEA DX, READ_ERROR_MSG
    CALL PRINT_STRING
    JMP TYPE_DONE

TYPE_WRITE_ERROR:
    ; Output failure also closes the source before returning to the shell.
    MOV BX, SOURCE_HANDLE
    MOV AH, 3EH
    INT 21H
    LEA DX, WRITE_ERROR_MSG
    CALL PRINT_STRING
    JMP TYPE_DONE

TYPE_OPEN_ERROR:
    ; No valid source handle exists on this path, so do not attempt to close it.
    LEA DX, OPEN_ERROR_MSG
    CALL PRINT_STRING

TYPE_DONE:
    ; Close return codes are not checked by these paths. Restore registers and
    ; resume the main prompt after either a successful display or its error.
    POP DX
    POP CX
    POP BX
    POP AX
    RET
DO_TYPE ENDP

; Copies SOURCE_NAME to DEST_NAME using real DOS files.
DO_COPY PROC NEAR
    ; Preserve working registers. COPY streams raw bytes between two handles,
    ; keeping only one 128-byte chunk in memory at a time.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX

    ; Open the ASCIIZ source read-only (3D00H), saving its returned AX handle.
    LEA DX, SOURCE_NAME
    MOV AX, 3D00H
    INT 21H
    JC COPY_OPEN_ERROR
    MOV SOURCE_HANDLE, AX

    ; Create/truncate the ASCIIZ destination with service 3CH. CX=0 requests
    ; normal file attributes. An existing destination is overwritten; success
    ; returns its handle in AX. If creation fails, only the source needs closing.
    LEA DX, DEST_NAME
    XOR CX, CX
    MOV AH, 3CH
    INT 21H
    JC COPY_CREATE_ERROR
    MOV DEST_HANDLE, AX

COPY_READ_LOOP:
    ; Read up to 128 bytes from the source. CF set reports failure; AX=0 is
    ; EOF, while a positive count specifies exactly how much data is valid.
    MOV BX, SOURCE_HANDLE
    LEA DX, IO_BUFFER
    MOV CX, 128
    MOV AH, 3FH
    INT 21H
    JC COPY_READ_ERROR

    CMP AX, 0
    JE COPY_COMPLETE
    MOV READ_COUNT, AX

    ; Write the actual read count, not the whole buffer, to avoid copying stale
    ; bytes after a short final read. A short write or CF error takes cleanup;
    ; this version does not retry partial writes or remove a partial destination.
    MOV BX, DEST_HANDLE
    MOV CX, READ_COUNT
    LEA DX, IO_BUFFER
    MOV AH, 40H
    INT 21H
    JC COPY_WRITE_ERROR
    CMP AX, READ_COUNT
    JNE COPY_WRITE_ERROR
    JMP COPY_READ_LOOP

COPY_COMPLETE:
    ; EOF means all read chunks were written; close both handles and show success.
    CALL CLOSE_COPY_HANDLES
    LEA DX, COPY_OK_MSG
    CALL PRINT_STRING
    JMP COPY_DONE

COPY_READ_ERROR:
    ; Both files were opened, so either transfer error closes both handles.
    CALL CLOSE_COPY_HANDLES
    LEA DX, READ_ERROR_MSG
    CALL PRINT_STRING
    JMP COPY_DONE

COPY_WRITE_ERROR:
    ; The destination may already contain earlier chunks when this error occurs.
    CALL CLOSE_COPY_HANDLES
    LEA DX, WRITE_ERROR_MSG
    CALL PRINT_STRING
    JMP COPY_DONE

COPY_CREATE_ERROR:
    ; Destination creation failed: close just the already-open source handle.
    MOV BX, SOURCE_HANDLE
    MOV AH, 3EH
    INT 21H
    LEA DX, CREATE_ERR_MSG
    CALL PRINT_STRING
    JMP COPY_DONE

COPY_OPEN_ERROR:
    ; Source opening failed: neither handle was acquired, so print without closing.
    LEA DX, OPEN_ERROR_MSG
    CALL PRINT_STRING

COPY_DONE:
    ; Restore the caller's registers and return to the shell prompt.
    POP DX
    POP CX
    POP BX
    POP AX
    RET
DO_COPY ENDP

CLOSE_COPY_HANDLES PROC NEAR
    ; Called only after both handles exist. Close destination then source with
    ; DOS service 3EH. AX/BX are saved; individual close errors are not checked.
    PUSH AX
    PUSH BX

    MOV BX, DEST_HANDLE
    MOV AH, 3EH
    INT 21H

    MOV BX, SOURCE_HANDLE
    MOV AH, 3EH
    INT 21H

    POP BX
    POP AX
    RET
CLOSE_COPY_HANDLES ENDP

; Prints a '$'-terminated string at DS:DX.
PRINT_STRING PROC NEAR
    ; Preserve AX, select DOS service 09H and print DS:DX until '$'. This is for
    ; fixed messages; filenames/file data use zero/count-based output instead.
    PUSH AX
    MOV AH, 09H
    INT 21H
    POP AX
    RET
PRINT_STRING ENDP

; Prints an ASCIIZ string at DS:DX to standard output.
PRINT_ZSTRING PROC NEAR
    ; Preserve working registers. SI scans the ASCIIZ string, while DX keeps
    ; its starting address and CX accumulates its length excluding the zero.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    MOV SI, DX
    XOR CX, CX

PZS_COUNT:
    ; Count one byte per character until zero is reached. BYTE PTR explicitly
    ; chooses a byte-sized comparison against the immediate terminator.
    CMP BYTE PTR [SI], 0
    JE PZS_WRITE
    INC SI
    INC CX
    JMP PZS_COUNT

PZS_WRITE:
    ; DOS service 40H writes CX bytes from DS:DX to standard-output handle 1.
    ; A literal '$' in the name is ordinary data. Unlike TYPE/COPY, this small
    ; helper does not test the write's carry flag or returned byte count.
    MOV BX, 1
    MOV AH, 40H
    INT 21H

    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PRINT_ZSTRING ENDP

CODESEG ENDS
; ENDP/ENDS close assembler declarations; END selects MAIN as the .EXE entry point.
END MAIN
