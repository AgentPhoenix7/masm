; Study notes: host keyboard controls, foreground orchestration and video output.
; MAIN initializes game/serial/IRQ1, then repeatedly polls time/input, handles
; local host actions, advances game frames, queues state and renders the screen.
; Host actions stay local; phone inputs reach the core through serial ownership
; checks. Key edges trigger each host command once instead of on every held frame.
; Video memory B800H contains 80x25 word cells: low byte character, high attribute.
;
; Local PC UI and IRQ1 edge controls. Internet clients cannot call host actions.
; Begin data declarations. DB/DW/DD allocate bytes/words/doublewords; DUP
; repeats an item. EQU constants allocate no storage. Offsets are relative to DS.
.DATA
; Separate 256-byte arrays retain held keys and unconsumed press edges.
; Extended-key marker bit 7 selects the upper half; Pause has skip state.
; The program uses keyboard interrupt INT 09H to detect key presses.
; Keyboard handling
KEY_DOWN DB 256 DUP(0) ; Stores which keyboard keys are currently pressed.
KEY_EDGE DB 256 DUP(0) ; Records newly pressed keys so an action happens only once per press.
EXTENDED_KEY DB 0 ; Identifies special keys such as arrow keys.
PAUSE_BYTES DB 0 ; Helps process the special Pause key sequence.
OLD_INT9 DD 0 ; Stores the original keyboard interrupt handler address.
KEY_HOOKED DB 0 ; Indicates whether the custom keyboard handler is installed.
; VIDEO_ATTR controls direct text colors; SHOW_SCORES selects view mode.
; DRAW_TICK throttles rendering; player colors are indexed by slot 0..7.
; Video and display settings
VIDEO_ATTR DB 07H ; Sets the default text color (07H = light grey on black).
SHOW_SCORES DB 0 ; Controls whether the scoreboard is displayed.
DRAW_TICK DW 0FFFFH ; Helps control screen refresh timing.
PLAYER_COLORS DB 0EH,0BH,0DH,09H,0CH,0AH,0FH,06H ; Stores eight different player colors.
; UI strings are zero-terminated for VIDEO_TEXT, not DOS '$'-terminated.
; Names are the separate fixed-width exception rendered with counted loops.
UI_TITLE DB 'MAZE4 | Internet phone race | Tab: scores | Esc: quit',0
UI_LOBBY DB 'LOBBY | Space: start when all READY | M: mode | R: maze | 1-8: remove',0
UI_RACE DB 'RACING | Phone buttons move players | Green E = shared exit',0
UI_RESULTS DB 'RESULTS | Lowest finish time + penalties wins | N: new room',0
UI_COUNT DB 'Players: ',0
UI_DIST DB '  Equal route: ',0
UI_FLOOR DB '  Floor cells: ',0
UI_MODE0 DB 'Collision: block +3.0s to both per contact | Head-on: back away',0
UI_MODE1 DB 'Collision: rotating priority, no penalty | Head-on: back away',0
UI_WARN DB 'Warnings: CAUTION <5 path steps; DANGER <3 | N: new room (not racing)',0
UI_CODE DB 'Room password: ',0
UI_CONNECT DB ' | HTTPS address is in the launcher terminal',0
UI_CLOCK DB 'Race: ',0
UI_WIN DB 's | Winner(s): ',0
UI_EMPTY DB 'EMPTY',0
UI_ACTIVE DB 'RACE ',0
UI_READY DB 'READY',0
UI_WAIT DB 'WAIT ',0
UI_DONE DB 'DONE ',0
UI_DNF DB 'DNF  ',0
UI_SAFE DB ' SAFE',0
UI_CAUTION DB ' CAUTION',0
UI_DANGER DB ' DANGER',0
UI_TABLE DB 'Player/name   State     Steps          Penalty       Score      Warning',0
UI_BAD DB 'Maze generation failed: press R to retry or Esc to quit.',0
; Begin executable code. CALL saves a return address on SS:SP; RET resumes
; after that call. PROC/ENDP are assembler declarations, not run-time actions.
.CODE
MAIN PROC
    ; Initialize DS=ES=@DATA and CLD for forward REP/LODS/STOS operations.
    ; Select text mode 3, hide the cursor, capture the BIOS clock, and seed the
    ; generator from tick words. Generate a map before enabling serial/keyboard UI.
    MOV AX,@DATA
    MOV DS,AX
    MOV ES,AX
    CLD       ; Clears the direction flag so string instructions process memory forward
    MOV AX,3 ; Selects 80x25 color text mode
    INT 10H ; Calls BIOS video services
    MOV AH,1 ; Selects the cursor-shape function
    MOV CX,2000H ; Sets cursor parameters to hide the cursor on typical VGA hardware
    INT 10H ; Applies the cursor settings
    MOV AH,0 ; Reads the system timer tick count
    INT 1AH ; Calls BIOS clock services
    ; CX:DX: Contains the 32-bit tick count
    ; LAST_BIOS: Stores this value for later timing calculations
    MOV WORD PTR LAST_BIOS,DX
    MOV WORD PTR LAST_BIOS+2,CX
    MOV AX,DX ; Copies the lower timer word into AX
    XOR AX,CX ; Combines both timer words to create a seed
    OR AX,1 ; Ensures the seed is odd and nonzero
    MOV RNG_SEED,AX ; Saves the seed
    CALL GENERATE_MAZE ; Creates the maze layout
    CALL SERIAL_INIT ; 	Initializes serial communication with the phone-control system
    CALL INSTALL_KEYS ; Installs the custom keyboard interrupt handler
MAIN_LOOP:
    ; Read time and bounded serial input, check Escape's latched edge, process
    ; host actions, and run a game tick. Queue a full state every four SYSTEM_TICK
    ; ticks; unsigned subtraction tolerates short low-word clock wrap.
    CALL READ_CLOCK ; Updates the game's time information
    ; If Escape was pressed, exit the game.
    CALL SERIAL_POLL ; Checks for incoming data from phone controllers
    CMP KEY_EDGE[1],0 ; Stores the press event for the Escape key (scan code 01H). Compares the value with zero
    JNE EXIT_MAIN ; Jumps if the values are not equal
    CALL HOST_CONTROLS ; Handles PC keyboard commands such as starting the race or changing the maze
    CALL GAME_TICK ; Updates the game logic, including movement, collisions, and race progress
    ; The game avoids sending its full state too frequently
    MOV AX,SYSTEM_TICK ; Loads the current tick count
    SUB AX,STATE_TICK ; Calculates elapsed ticks since the last state update
    CMP AX,4 ; Checks whether at least four ticks have passed
    JB MAIN_FLUSH ; Jumps if fewer than four ticks have passed (unsigned comparison)
    ; Copies the current tick count into STATE_TICK
    ; Queues the latest game state for transmission to connected players
    MOV AX,SYSTEM_TICK
    MOV STATE_TICK,AX
    CALL SEND_STATE
; Sends pending serial data and controls how frequently the game screen is redrawn.
MAIN_FLUSH:
    ; Drain ready UART output without waiting. Draw at most once per two ticks
    ; so transport polling and game rules are not delayed by needless redraws.
    ; Keeps communication responsive without delaying the game
    CALL SERIAL_FLUSH ; Sends queued data through the UART (serial port). It is non-blocking, meaning it does not wait for the serial device to become ready
    ; Prevents unnecessary screen updates
    MOV AX,SYSTEM_TICK ; Loads the current system tick
    SUB AX,DRAW_TICK ; Calculates ticks elapsed since the last screen redraw
    CMP AX,2 ; Checks whether two ticks have passed
    JB MAIN_IDLE ; Skips drawing if fewer than two ticks have passed
    ; Saves the current tick in DRAW_TICK.
    MOV AX,SYSTEM_TICK
    MOV DRAW_TICK,AX
    CALL DRAW_SCREEN ; Redraws the game screen, including the maze, players, and game information
MAIN_IDLE:
    ; Keep looping while unsent serial bytes exist. Otherwise STI/HLT waits
    ; for a timer/keyboard interrupt, then resumes foreground polling.
    ; Keep the CPU active while serial data remains unsent
    MOV AX,TX_HEAD ; TX_HEAD: Position where new outgoing data is added to the transmission buffer.
    CMP AX,TX_TAIL ; TX_TAIL: Position from which data is removed for transmission.
    JNE MAIN_LOOP ; Compares the two positions. If they differ, some data is still pending, so continue processing
    ; Avoids wasting CPU cycles in an empty loop
    STI ; Enables maskable hardware interrupts
    HLT ; Suspends CPU execution until an interrupt or another wake-up event occurs
    JMP MAIN_LOOP ; The game then checks the clock, serial input, keyboard, and game logic again
EXIT_MAIN:
    ; Restore the previous keyboard vector before returning to DOS. Reset text
    ; mode for a clear/normal screen, then DOS 4C00H terminates with status zero.
    CALL RESTORE_KEYS ; Restores the original keyboard interrupt handler (INT 09H). Prevents the custom keyboard handler from remaining installed after the game exits.
    ; Returns the screen to a normal text-mode state
    MOV AX,3 ; Selects 80x25 color text mode
    INT 10H ; Calls the BIOS video service
    ; return 0 (success)
    MOV AX,4C00H
    INT 21H
MAIN ENDP
HOST_CONTROLS PROC NEAR
    ; Tab edge toggles scores. Clear each handled edge before executing its
    ; action so holding a key or keyboard typematic cannot repeatedly trigger it.
    ; KEY_EDGE[0FH]: Stores the press event for the Tab key (scan code 0FH).
    CMP KEY_EDGE[0FH],0 ; Checks whether the value is zero
    JE HOST_SPACE ; If Tab was not pressed, jump to the next keyboard check
    MOV KEY_EDGE[0FH],0 ; Resets the Tab key press event. Prevents the same recorded press from triggering the action repeatedly.
    XOR SHOW_SCORES,1 ; Toggles the lowest bit of SHOW_SCORES.
HOST_SPACE:
    ; Consume Space and call START_RACE, which enforces lobby/count/readiness.
    ; KEY_EDGE[39H]: Stores the press event for Space (scan code 39H).
    CMP KEY_EDGE[39H],0 ; Compares the key event with zero
    JE HOST_MODE ; If Space was not pressed, jump to the next control handler
    MOV KEY_EDGE[39H],0 ; Clears the recorded Space key event. Prevents the same event from starting the race repeatedly.
    ; Calls the START_RACE procedure. That procedure checks whether the game is in the lobby, the player count is valid, and all required players are ready. The race starts only if those conditions are satisfied.
    CALL START_RACE
HOST_MODE:
    ; Consume M; only in lobby toggle collision mode between block/+3s and
    ; rotating priority. An active race cannot have its rule mode changed here.
    ; KEY_EDGE[32H]: Stores the press event for the M key (scan code 32H).
    CMP KEY_EDGE[32H],0 ; Checks whether M was pressed
    JE HOST_MAZE ; If not pressed, skip to maze controls
    MOV KEY_EDGE[32H],0 ; Clears the recorded M key event so the same press is not processed repeatedly
    ; Prevents collision rules from changing during an active race
    ; PHASE: Stores the current game phase.
    ; 1: Represents the lobby.
    CMP PHASE,1
    JNE HOST_MAZE ; Skips mode switching if the game is not in the lobby
    ; 0: Block movement and add a 3-second penalty to both players
    ; 1: Rotating priority, without collision penalty
    XOR COLLISION_MODE,1 ; Switches between two collision modes

; Allows the host to regenerate the maze before racing
HOST_MAZE:
    ; Consume R and call the lobby-only map regeneration routine.
    ; KEY_EDGE[13H]: Checks whether R was pressed.
    CMP KEY_EDGE[13H],0
    JE HOST_NEW ; If not pressed, move to the next control
    MOV KEY_EDGE[13H],0 ; Clears the recorded key event
    CALL REGENERATE ; Attempts to generate a new maze (lobby only)
HOST_NEW:
    ; Consume N and request a new room; NEW_ROOM refuses during active racing.
    ; KEY_EDGE[31H]: Checks whether N was pressed.
    CMP KEY_EDGE[31H],0
    JE HOST_REMOVE ; Skips if N was not pressed
    MOV KEY_EDGE[31H],0 ; Clears the key event
    CALL NEW_ROOM ; Requests creation of a new game room. NEW_ROOM refuses the request during an active race.
HOST_REMOVE:
    ; Scan eight numbered key edges (scan codes 02H..09H for 1..8).
    XOR SI,SI ; Sets the SI register to zero. SI will be used as an index for checking eight number keys (1 through 8).
HOST_REMOVE_NEXT:
    ; Clear a numbered edge and drop that occupied slot. DROP_PLAYER handles
    ; freeing a lobby slot versus revoking ownership/marking DNF after start.
    ; SI: Player index (0-7).
    MOV BX,SI ; Copies the player index into BX
    ADD BX,2 ; Converts the index into the corresponding keyboard scan code. For example, SI = 0 corresponds to key 1 (scan code 02H).
    CMP KEY_EDGE[BX],0 ; Checks whether the corresponding number key was pressed
    JE HOST_REMOVE_SKIP ; If not pressed, skips to the next player
    MOV KEY_EDGE[BX],0 ; Otherwise, clears the key event to prevent repeated processing
    ; PLAYER_STATE[SI]: Stores the state of the selected player.
    ; 0: Indicates an empty slot.
    CMP PLAYER_STATE[SI],0
    JE HOST_REMOVE_SKIP ; Skips removal if the slot is empty
    CALL DROP_PLAYER ; Removes or disqualifies the selected player
HOST_REMOVE_SKIP:
    ; Advance over all eight slots before returning to the main loop.
    INC SI ; Increases the player index by one
    CMP SI,8 ; Checks whether all eight slots have been processed
    JB HOST_REMOVE_NEXT ; Repeats while SI < 8 (unsigned)
    RET ; Returns control to the calling procedure (MAIN_LOOP through CALL HOST_CONTROLS).
HOST_CONTROLS ENDP

; This procedure installs a custom keyboard interrupt handler (KEYBOARD_ISR) by replacing the existing INT 09H vector, while saving the original handler for restoration later.
INSTALL_KEYS PROC NEAR
    ; DOS 3509H returns the current IRQ1 vector in ES:BX; save both words.
    ; Temporarily set DS=CS so 2509H installs CS:KEYBOARD_ISR, then restore data
    ; DS/ES and mark KEY_HOOKED. The installed handler belongs to this program.
    PUSH ES ; Saves the current Extra Segment register
    ; AH = 35H: DOS function to get an interrupt vector.
    ; AL = 09H: Selects keyboard interrupt 09H.
    MOV AX,3509H
    INT 21H ; Returns the original handler address in ES:BX
    MOV WORD PTR OLD_INT9,BX ; Stores the offset (BX) in the first two bytes of OLD_INT9.
    MOV WORD PTR OLD_INT9+2,ES ; Stores the segment (ES) in the next two bytes.
    ; DS = CS. This is necessary because DOS function 25H expects the new interrupt handler address in DS:DX.
    PUSH DS ; Saves the original Data Segment
    PUSH CS ; Pushes the Code Segment value
    POP DS ; Loads CS into DS
    MOV DX,OFFSET KEYBOARD_ISR ; Contains the offset of KEYBOARD_ISR
    ; AH = 25H: DOS function to set an interrupt vector.
    ; AL = 09H: Selects keyboard interrupt 09H.
    MOV AX,2509H
    INT 21H ; Installs the custom handler at CS:KEYBOARD_ISR
    POP DS ; Restores the original Data Segment
    MOV KEY_HOOKED,1 ; Records that the custom handler is installed
    POP ES ; Restores the original Extra Segment
    RET
INSTALL_KEYS ENDP

; Restores the original keyboard interrupt handler (INT 09H) before the game exits.
RESTORE_KEYS PROC NEAR
    ; Only restore when installed. LDS DX,OLD_INT9 loads the old segment and
    ; offset together; preserve DS around DOS 2509H, then clear KEY_HOOKED.
    CMP KEY_HOOKED,0 ; Checks whether KEY_HOOKED is zero
    JE KEYS_RESTORED ; Jumps to KEYS_RESTORED if no custom handler is installed
    PUSH DS ; Saves the current Data Segment register
    ; Loads the original interrupt handler's 32-bit far pointer:
    ; DX = Original handler offset.
    ; DS = Original handler segment.
    LDS DX,OLD_INT9
    ; AH = 25H: DOS function to set an interrupt vector.
    ; AL = 09H: Specifies keyboard interrupt 09H.
    MOV AX,2509H
    INT 21H ; Restores the original handler using DS:DX
    POP DS ; Restores the program's Data Segment
    MOV KEY_HOOKED,0 ; Indicates that the custom keyboard handler is no longer installed
KEYS_RESTORED:
    ; Return after restoring or after discovering no active hook.
    RET
RESTORE_KEYS ENDP

KEYBOARD_ISR PROC FAR
    ; IRQ1 saves AX/BX/DS, reads port 60H and pulses port 61H bit 7 to
    ; acknowledge the keyboard. Load DS explicitly: an interrupt can arrive while
    ; the foreground temporarily uses another segment. No BIOS/DOS calls occur here.
    ; Saves registers so the interrupted program is not affected
    PUSH AX
    PUSH BX
    PUSH DS
    IN AL,60H ; Reads the keyboard scan code from I/O port 60H
    MOV BL,AL ; Saves the scan code in BL
    ; Acknowledges the keyboard interface on traditional PC/AT-compatible hardware
    IN AL,61H ; Reads the keyboard control port 61H
    MOV AH,AL
    OR AL,80H ; Temporarily sets bit 7
    OUT 61H,AL
    MOV AL,AH ; Restores its original value
    OUT 61H,AL
    ; Loads the program's data segment so the ISR can access keyboard variables correctly.
    ; This is necessary because an interrupt may occur while the main program is using another data segment.
    MOV AX,@DATA
    MOV DS,AX
    ; If the ISR is currently processing a Pause-key sequence, it skips the remaining bytes.
    CMP PAUSE_BYTES,0
    JE IRQ_PREFIX
    DEC PAUSE_BYTES
    JMP IRQ_DONE
IRQ_PREFIX:
    ; E1 begins the six-byte Pause sequence: skip the next five bytes so
    ; embedded scan bytes cannot masquerade as host actions.
    ; E1H: Identifies the beginning of the Pause sequence.
    ; The ISR skips the following five bytes.
    ; Prevents Pause-key bytes from being interpreted as other key presses.
    CMP BL,0E1H
    JNE IRQ_EXTENDED
    MOV PAUSE_BYTES,5
    MOV EXTENDED_KEY,0
    JMP IRQ_DONE
IRQ_EXTENDED:
    ; E0 marks an extended key; remember index bit 7 for the next scan byte,
    ; separating extended keys from their ordinary keyboard counterparts.
    ; E0H: Prefix used by extended keys.
    ; EXTENDED_KEY = 80H: Marks the next scan code as extended.
    CMP BL,0E0H
    JNE IRQ_STORE
    MOV EXTENDED_KEY,80H
    JMP IRQ_DONE
IRQ_STORE:
    ; Save the original release bit, remove it from the scan index, then OR
    ; the E0 marker to form a 0..255 index. Clear the marker after use.
    ; A first make sets DOWN and EDGE; repeated make bytes leave EDGE unchanged.
    MOV AH,BL ; Preserves the original scan code
    AND BL,7FH ; Removes the release bit
    OR BL,EXTENDED_KEY ; Adds the extended-key marker
    XOR BH,BH ; Clears BH so BX becomes a valid 16-bit array index
    MOV EXTENDED_KEY,0 ; Clears EXTENDED_KEY for the next scan code
    ; 0: Key pressed (make code)
    ; 1: Key released (break code)
    TEST AH,80H ; Checks bit 7 of the original scan code.
    JNZ IRQ_RELEASE ; If bit 7 is set, execution jumps to IRQ_RELEASE
    ; Checks whether the key is already held.
    ; If already pressed, ignores repeated make codes.
    ; Otherwise, sets KEY_DOWN[BX] = 1.
    ; Sets KEY_EDGE[BX] = 1 to record a new press.
    ; Prevents holding a key from repeatedly triggering the same command
    CMP KEY_DOWN[BX],0
    JNE IRQ_DONE
    MOV KEY_DOWN[BX],1
    MOV KEY_EDGE[BX],1
    JMP IRQ_DONE
IRQ_RELEASE:
    ; Release clears DOWN but leaves the edge latched until the foreground
    ; consumes it, preserving quick taps between frames.
    MOV KEY_DOWN[BX],0 ; Sets KEY_DOWN[BX] = 0 when the key is released. Importantly, KEY_EDGE[BX] is not cleared. This preserves the press event until the main program processes it.
IRQ_DONE:
    ; Send an EOI to the master PIC, restore saved registers and IRET, which
    ; restores flags/CS:IP rather than using an ordinary procedure RET.
    MOV AL,20H
    OUT 20H,AL ; Sends End of Interrupt (EOI) to the master Programmable Interrupt Controller (PIC)
    ; Restores the saved registers
    POP DS
    POP BX
    POP AX
    IRET ; Returns from the interrupt, restoring flags and the previous execution address
KEYBOARD_ISR ENDP

CLEAR_SCREEN PROC NEAR
    ; Temporarily set ES=B800H and fill 2000 word cells with 0720H: spaces
    ; in normal gray-on-black. REP STOSW advances DI by two with CLD set.
    ; Saves the original register values so the procedure does not affect the calling program.
    PUSH AX
    PUSH CX
    PUSH DI
    PUSH ES
    MOV AX,0B800H ; Starting segment of color text-mode video memory
    MOV ES,AX ; Points ES to video memory
    XOR DI,DI ; Sets DI to 0, the beginning of the screen buffer
    ; Each screen cell receives a blank space with the default color
    ; AH: 07H: Light gray text on black background
    ; AL: 20H: ASCII space character
    MOV AX,0720H
    MOV CX,2000 ; Number of screen cells (80 x 25).
    ; All 2000 screen cells are overwritten with blank spaces.
    ; STOSW: Writes AX into memory at ES:DI.
    ; REP: Repeats STOSW until CX becomes zero.
    ; DI: Automatically increases by 2 after each write because CLD was executed earlier.
    REP STOSW
    ; Restores saved registers in reverse order
    POP ES
    POP DI
    POP CX
    POP AX
    RET
CLEAR_SCREEN ENDP

; Video primitives preserve caller registers except DI (advances on output).
VIDEO_CHAR PROC NEAR
    ; AL is the character and VIDEO_ATTR its color. Build the character/attribute
    ; word, write it with STOSW through ES=B800H, and restore AX/ES. DI advances
    ; one cell; no BIOS cursor state is changed by this direct-memory operation.
    ; Saves the original values of AX and ES.
    ; Prevents the procedure from changing these registers permanently.
    PUSH AX
    PUSH ES
    ; AL: Contains the ASCII character to display.
    ; AH: Receives the color attribute from VIDEO_ATTR.
    MOV AH,VIDEO_ATTR
    PUSH AX ; Temporarily saves the combined character and color
    ; B800H: Segment address of color text-mode video memory.
    MOV AX,0B800H
    MOV ES,AX ; Points to the screen buffer
    POP AX ; Restores the character and color word
    ; Writes the 16-bit value in AX to memory at ES:DI.
    ; Low byte (AL) stores the character.
    ; High byte (AH) stores the color.
    ; Automatically advances DI by 2 bytes because the direction flag was cleared earlier.
    ; Displays one character and advances to the next screen cell.
    STOSW
    ; Restore registers and return
    POP ES
    POP AX
    RET
VIDEO_CHAR ENDP
VIDEO_TEXT PROC NEAR
    ; Print a zero-terminated string at DS:SI; preserve AX/SI but allow DI
    ; to advance through the destination video cells.
    PUSH AX ; Saves AX
    PUSH SI ; Saves the source string pointer
VIDEO_TEXT_NEXT:
    ; LODSB loads/advances the string pointer; OR tests its zero terminator.
    ; Nonzero characters pass to VIDEO_CHAR using the current global attribute.
    LODSB ; Loads one character from DS:SI into AL and increments SI by 1 (because CLD was executed earlier)
    OR AL,AL ; Checks whether the character is zero
    JZ VIDEO_TEXT_DONE ; Stops printing when the null terminator is reached
    CALL VIDEO_CHAR ; Prints the character in AL using the current VIDEO_ATTR
    JMP VIDEO_TEXT_NEXT ; Repeats the process for the next character
VIDEO_TEXT_DONE:
    ; Restore the original string pointer and AX after reaching zero.
    POP SI
    POP AX
    RET
VIDEO_TEXT ENDP

; Converts an unsigned 32-bit integer into decimal digits and displays it on the screen using VIDEO_CHAR.
VIDEO_NUMBER PROC NEAR
    ; Print unsigned DX:AX as decimal into video memory, preserving working
    ; registers except advancing DI. DIVIDE_U32 returns a quotient and one digit
    ; remainder; BP counts stack-saved digits, independently of scratch CX.
    ; Saves registers
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH BP
    MOV BX,10 ; Sets the divisor to 10 for decimal conversion
    XOR BP,BP ; Sets BP to zero to count digits
VIDEO_DIGIT:
    ; Divide by ten, push remainder CX, then test both quotient words.
    ; The loop runs once for zero, ensuring it prints a digit rather than nothing.
    ; DIVIDE_U32: Divides the 32-bit number in DX:AX by 10.
    ; The quotient is returned in DX:AX.
    ; The remainder (0-9) is returned in CX.
    CALL DIVIDE_U32
    PUSH CX ; Saves the extracted digit on the stack
    INC BP ; Increases the digit count
    MOV SI,AX
    OR SI,DX ; Checks whether both quotient words are zero
    JNZ VIDEO_DIGIT ; Repeats until the quotient becomes zero
VIDEO_DIGIT_OUT:
    ; Pop digits in reverse extraction order, add ASCII '0', and output them.
    ; After BP digits, temporary words are gone and saved registers can be restored.
    POP AX ; Retrieves a digit from the stack
    ADD AL,'0' ; Converts the numeric digit into its ASCII character
    CALL VIDEO_CHAR ; Displays the digit
    DEC BP ; Decreases the remaining digit count
    JNZ VIDEO_DIGIT_OUT ; Continues until all digits are printed
    ; Restore registers and return
    POP BP
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
VIDEO_NUMBER ENDP

; Converts time stored in tenths of a second into decimal seconds and displays it using VIDEO_NUMBER and VIDEO_CHAR.
VIDEO_TIME PROC NEAR
    ; Split tenths into whole seconds plus remainder by dividing by ten.
    ; Save the fractional digit across VIDEO_NUMBER, then emit dot and that digit.
    ; Saves the original register values
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    MOV BX,10 ; Sets the divisor to 10
    ; DIVIDE_U32: Divides the unsigned 32-bit value in DX:AX by 10.
    ; DX:AX: Receives the quotient (whole seconds).
    ; CX: Receives the remainder (tenths digit).
    CALL DIVIDE_U32
    PUSH CX ; Saves the fractional digit for later
    CALL VIDEO_NUMBER ; Calls VIDEO_NUMBER to display the quotient as a decimal number
    MOV AL,'.' ; Loads the decimal point character into AL
    CALL VIDEO_CHAR ; Calls VIDEO_CHAR to display .
    POP AX ; Retrieves the saved remainder
    ADD AL,'0' ; Converts the numeric digit to ASCII
    CALL VIDEO_CHAR ; Displays the fractional digit
    ; Restore registers and return
    POP DX
    POP CX
    POP BX
    POP AX
    RET
VIDEO_TIME ENDP

; Selects the appropriate status label for a player based on their state, the game phase, and whether they are ready.
; BX player index. Return DS:SI state label, preserving BX.
STATE_LABEL PROC NEAR
    ; BX is the player slot; return DS:SI for EMPTY, DNF, DONE or RACE.
    ; In lobby, an active slot instead displays WAIT or READY from its ready bit.
    ; BX is preserved so the caller can next request this slot's warning label.
    LEA SI,UI_EMPTY ; Initially selects "EMPTY".
    CMP PLAYER_STATE[BX],0
    JE STATE_LABEL_DONE ; If PLAYER_STATE[BX] = 0, returns "EMPTY".
    LEA SI,UI_DNF
    CMP PLAYER_STATE[BX],3
    JE STATE_LABEL_DONE ; If the player state is 3, returns "DNF".
    LEA SI,UI_DONE
    CMP PLAYER_STATE[BX],2
    JE STATE_LABEL_DONE ; If the player state is 2, returns "Done".
    LEA SI,UI_ACTIVE ; Initially selects "RACE ".
    CMP PHASE,1 ; If PHASE != 1, returns "RACE " for a player whose state is neither 0, 2, nor 3.
    JNE STATE_LABEL_DONE ; Continues checking readiness
    ; Selects "WAIT " by default.
    ; If READY[BX] = 0, returns "WAIT ".
    ; Otherwise, selects "READY".
    LEA SI,UI_WAIT
    CMP READY[BX],0
    JE STATE_LABEL_DONE
    LEA SI,UI_READY
STATE_LABEL_DONE:
    ; Return with the chosen label pointer in SI; this helper itself prints nothing.
    RET
STATE_LABEL ENDP
WARNING_LABEL PROC NEAR
    ; Select SAFE/CAUTION/DANGER plus gray/yellow/red VIDEO_ATTR from WARNINGS[BX].
    ; The attribute is intentionally left changed for the next text output.
    ; Set default warning — SAFE
    ; VIDEO_ATTR = 07H: Light gray text on black.
    MOV VIDEO_ATTR,07H
    LEA SI,UI_SAFE
    CMP WARNINGS[BX],0
    JE WARNING_LABEL_DONE
    ; Check CAUTION warning
    ; VIDEO_ATTR = 0EH: Yellow text on black.
    MOV VIDEO_ATTR,0EH
    LEA SI,UI_CAUTION
    CMP WARNINGS[BX],1
    JE WARNING_LABEL_DONE
    ; Select DANGER warning
    ; VIDEO_ATTR = 0CH: Light red text on black.
    MOV VIDEO_ATTR,0CH
    LEA SI,UI_DANGER
WARNING_LABEL_DONE:
    ; Return label pointer and selected attribute to the renderer.
    RET
WARNING_LABEL ENDP
DRAW_SCREEN PROC NEAR
    ; Save working registers and ES, clear the screen, then render header
    ; metadata: player count/capacity, equal route distance, floor count, phase,
    ; collision mode, clock, winner bits and room connection text. DI is a video
    ; byte offset: 160 bytes per row, two bytes per column.
    ; Saves all working registers.
    ; CLEAR_SCREEN fills the screen with blank spaces.
    ; Ensures the previous frame is erased before drawing the next frame.
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI
    PUSH BP
    PUSH ES
    CALL CLEAR_SCREEN
    ; DI = 0: Starts at the top-left corner.
    ; VIDEO_ATTR = 0FH: Bright white text.
    ; UI_TITLE: Displays the game title.
    XOR DI,DI
    MOV VIDEO_ATTR,0FH
    LEA SI,UI_TITLE
    CALL VIDEO_TEXT
    ; The following instructions display player count, capacity, equal route distance, and floor count using VIDEO_NUMBER.
    MOV VIDEO_ATTR,07H
    MOV DI,160
    LEA SI,UI_COUNT
    CALL VIDEO_TEXT
    XOR AX,AX
    XOR DX,DX
    MOV AL,PLAYER_COUNT
    CALL VIDEO_NUMBER
    MOV AL,'/'
    CALL VIDEO_CHAR
    XOR AX,AX
    MOV AL,CAPACITY
    CALL VIDEO_NUMBER
    LEA SI,UI_DIST
    CALL VIDEO_TEXT
    MOV AX,COMMON_DISTANCE
    CALL VIDEO_NUMBER
    LEA SI,UI_FLOOR
    CALL VIDEO_TEXT
    MOV AX,FLOOR_COUNT
    CALL VIDEO_NUMBER
    ; Selects a message based on the game phase.
    ; 1: LOBBY
    ; 2: RACING
    ; Other: RESULTS
    MOV DI,320
    LEA SI,UI_LOBBY
    CMP PHASE,1
    JE DRAW_PHASE
    LEA SI,UI_RACE
    CMP PHASE,2
    JE DRAW_PHASE
    LEA SI,UI_RESULTS
DRAW_PHASE:
    ; Print the label selected from PHASE (lobby/race/results).
    CALL VIDEO_TEXT ; Displays the selected message.
    ; Selects the current collision rule.
    MOV DI,480
    LEA SI,UI_MODE0
    CMP COLLISION_MODE,0
    JE DRAW_MODE
    LEA SI,UI_MODE1
DRAW_MODE:
    ; Print the selected collision rule, then warning help and elapsed time.
    CALL VIDEO_TEXT
    MOV DI,640
    LEA SI,UI_WARN
    CALL VIDEO_TEXT
    MOV DI,800
    LEA SI,UI_CLOCK
    CALL VIDEO_TEXT
    ; Loads the 32-bit elapsed time into DX:AX and displays it in seconds with one decimal place.
    MOV AX,WORD PTR ELAPSED_TENTHS
    MOV DX,WORD PTR ELAPSED_TENTHS+2
    CALL VIDEO_TIME
    LEA SI,UI_WIN
    CALL VIDEO_TEXT
    XOR BP,BP ; BP: Player index from 0 to 7.
; Supports displaying multiple winners when there is a tie.
DRAW_WINNER:
    ; Scan bit 1<<slot in WIN_MASK and print the one-based number for each winner.
    MOV CX,BP
    MOV AL,1
    SHL AL,CL ; Creates a bit mask for the current player
    TEST WIN_MASK,AL ; Checks whether that player's bit is set in WIN_MASK
    JZ DRAW_WINNER_NEXT
    MOV AX,BP
    ADD AL,'1'
    CALL VIDEO_CHAR
    MOV AL,' '
    CALL VIDEO_CHAR
DRAW_WINNER_NEXT:
    ; After scanning all bits, show room code/connection guidance. SHOW_SCORES
    ; selects a full table; otherwise draw the map and side roster.
    INC BP
    CMP BP,8
    JB DRAW_WINNER
    MOV DI,960
    LEA SI,UI_CODE
    CALL VIDEO_TEXT
    LEA SI,ROOM_CODE
    CALL VIDEO_TEXT
    LEA SI,UI_CONNECT
    CALL VIDEO_TEXT
    ; SHOW_SCORES = 0: Display maze and side roster.
    ; SHOW_SCORES != 0: Display detailed statistics table.
    CMP SHOW_SCORES,0
    JNE DRAW_TABLE
    ; ES = B800H: Points to video memory.
    ; DI = 7*160: Starts drawing at screen row 7.
    ; SI: Points to the maze data.
    ; BP: Number of maze rows.
    MOV AX,0B800H
    MOV ES,AX
    MOV DI,7*160
    LEA SI,MAZE
    MOV BP,ROWS
DRAW_ROW:
    ; Start map rows at screen row seven. BP counts ROWS and CX counts COLS;
    ; SI scans the contiguous fixed-width maze bytes without terminators.
    MOV CX,COLS
; LODSB: Reads a maze character.
; AH = 07H: Normal gray color.
; If the character is E, changes the color to green (0AH).
; STOSW: Writes the character and color to video memory.
; LOOP: Repeats for every column.
DRAW_CELL:
    ; Load one map character and choose gray normally or green for shared E.
    LODSB
    MOV AH,07H
    CMP AL,'E'
    JNE DRAW_CELL_SAVE
    MOV AH,0AH
DRAW_CELL_SAVE:
    ; STOSW writes character/attribute and advances two bytes. At row end skip
    ; (80-COLS)*2 bytes to align the next map row in the wider text screen.
    STOSW
    LOOP DRAW_CELL
    ADD DI,(80-COLS)*2
    DEC BP
    JNZ DRAW_ROW
    XOR SI,SI
DRAW_PLAYER:
    ; Draw racing slots only. DIV COLS splits the linear cell into row/column;
    ; video offset=(row+7)*160+column*2. Overlay the player digit and color.
    ; Finished/DNF players are absent from the maze but remain in the roster.
    ; Only players with state 1 are drawn on the maze.
    CMP PLAYER_STATE[SI],1
    JNE DRAW_PLAYER_NEXT
    MOV BX,SI
    SHL BX,1
    ; Converts the player's linear maze position into row and column:
    ; Row = floor(Position / cols)
    ; Column = Position mod cols
    MOV AX,POSITIONS[BX]
    XOR DX,DX
    MOV BX,COLS
    DIV BX
    ADD AX,7
    MOV BX,160
    PUSH DX
    MUL BX
    MOV DI,AX
    POP DX
    SHL DX,1
    ADD DI,DX
    MOV AX,SI
    ADD AL,'1'
    MOV AH,PLAYER_COLORS[SI]
    STOSW
DRAW_PLAYER_NEXT:
    ; Advance through eight player slots, then build the side roster.
    INC SI
    CMP SI,8
    JB DRAW_PLAYER
    XOR BP,BP
DRAW_ROSTER:
    ; Each player uses two screen rows at column 63: first colored number/name,
    ; then state and proximity warning. Name offset=8*slot and exactly eight
    ; bytes are printed, because padded names have no zero terminator.
    MOV AX,BP
    MOV BX,320
    MUL BX
    ADD AX,7*160+63*2
    MOV DI,AX
    MOV BX,BP
    MOV AL,PLAYER_COLORS[BX]
    MOV VIDEO_ATTR,AL
    MOV AX,BP
    ADD AL,'1'
    CALL VIDEO_CHAR
    MOV AL,' '
    CALL VIDEO_CHAR
    MOV SI,BP
    MOV CL,3
    SHL SI,CL
    ADD SI,OFFSET PLAYER_NAMES
    MOV CX,8
DRAW_NAME:
    ; Emit each fixed-width name byte, then position the second row for state
    ; and warning labels. Advance BP after both lines have been completed.
    LODSB
    CALL VIDEO_CHAR
    LOOP DRAW_NAME
    MOV AX,BP
    MOV BX,320
    MUL BX
    ADD AX,8*160+63*2
    MOV DI,AX
    MOV BX,BP
    ; Each player gets two screen rows:
    ; First row: Player number and name.
    ; Second row: Player status and warning.
    ; These calls select and print the player's state and proximity warning.
    ; Player names occupy exactly eight bytes, so the code prints them using a counted loop rather than looking for a null terminator.
    CALL STATE_LABEL
    CALL VIDEO_TEXT
    CALL WARNING_LABEL
    CALL VIDEO_TEXT
    INC BP
    CMP BP,8
    JB DRAW_ROSTER
    JMP DRAW_DONE
; Displays the table heading.
DRAW_TABLE:
    ; Replace the maze/side roster with a full-width statistics heading.
    MOV DI,7*160
    LEA SI,UI_TABLE
    CALL VIDEO_TEXT
    XOR BP,BP

; DRAW_TABLE_PLAYER processes all eight player slots.
; Field                         Procedure / Data
; Player number and name	    PLAYER_NAMES
; State                         STATE_LABEL
; Steps	                        STEPS + VIDEO_NUMBER
; Penalty	                    PENALTIES + VIDEO_TIME
; Score	                        GET_SCORE + VIDEO_TIME
; Warning	                    WARNING_LABEL

; GET_SCORE retrieves the player's live or final adjusted score.
; The code uses fixed screen positions to align each column.
DRAW_TABLE_PLAYER:
    ; Give each slot two screen rows. Print number/name/state and 32-bit steps,
    ; then position penalty, adjusted score and warning at fixed columns.
    ; Counter byte offset=4*slot; GET_SCORE chooses live versus final time.
    MOV AX,BP
    MOV BX,320
    MUL BX
    ADD AX,8*160
    MOV DI,AX
    MOV VIDEO_ATTR,07H
    MOV AX,BP
    ADD AL,'1'
    CALL VIDEO_CHAR
    MOV AL,' '
    CALL VIDEO_CHAR
    MOV SI,BP
    MOV CL,3
    SHL SI,CL
    ADD SI,OFFSET PLAYER_NAMES
    MOV CX,8
DRAW_TABLE_NAME:
    ; Print the eight padded name bytes, then continue the table row's fields.
    LODSB
    CALL VIDEO_CHAR
    LOOP DRAW_TABLE_NAME
    ADD DI,8
    MOV BX,BP
    CALL STATE_LABEL
    CALL VIDEO_TEXT
    ADD DI,8
    MOV BX,BP
    SHL BX,1
    SHL BX,1
    MOV AX,WORD PTR STEPS[BX]
    MOV DX,WORD PTR STEPS[BX+2]
    CALL VIDEO_NUMBER
    MOV AX,BP
    MOV BX,320
    MUL BX
    MOV DI,AX
    ADD DI,8*160+38*2
    MOV BX,BP
    SHL BX,1
    SHL BX,1
    MOV AX,WORD PTR PENALTIES[BX]
    MOV DX,WORD PTR PENALTIES[BX+2]
    CALL VIDEO_TIME
    MOV AX,BP
    MOV BX,320
    MUL BX
    MOV DI,AX
    ADD DI,8*160+52*2
    MOV SI,BP
    CALL GET_SCORE
    CALL VIDEO_TIME
    MOV AX,BP
    MOV BX,320
    MUL BX
    MOV DI,AX
    ADD DI,8*160+62*2
    MOV BX,BP
    CALL WARNING_LABEL
    CALL VIDEO_TEXT
    INC BP
    CMP BP,8
    JB DRAW_TABLE_PLAYER

; Checks whether the generated maze supports at least two players.
; If CAPACITY < 2, displays the maze-generation failure message on the last screen row.
DRAW_DONE:
    ; If generated capacity is below two, print the regeneration-error footer;
    ; otherwise complete normally. No screen branch changes game-rule state.
    CMP CAPACITY,2
    JAE DRAW_RETURN
    MOV DI,24*160
    LEA SI,UI_BAD
    CALL VIDEO_TEXT
DRAW_RETURN:
    ; Restore all saved registers, including ES and DI, after the complete frame.
    POP ES
    POP BP
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
DRAW_SCREEN ENDP
