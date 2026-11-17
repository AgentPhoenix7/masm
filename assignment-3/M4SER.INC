; Study notes: polled COM1 transport and foreground session/race control.
; The host bridge handles HTTPS/authentication; MASM validates its serial messages
; against room epoch, slot owner, generation, phase and input sequence as applicable.
; Wire frame: colon, two uppercase hex characters per payload/checksum byte, LF.
; The XOR checksum is for corruption detection; it is not cryptographic proof.
; Integer payload fields are little endian, matching STOSW/word loads on x86.
;
; MASM owns COM1 framing, admissions, sessions, input leases and race clocks.
; Serial wire: ':' + uppercase hex(payload, XOR checksum) + LF.
; All words/dwords are little endian. See phone/protocol.py and README.md.
; Begin data declarations. DB/DW/DD allocate bytes/words/doublewords; DUP
; repeats an item. EQU constants allocate no storage. Offsets are relative to DS.
.DATA
; Phase and epoch separate lobby/racing/results and different room lifetimes.
; GENERATION distinguishes regenerated maps within a room; owners are per-slot.
; Game State Management
PHASE DB 1                       ; 1 lobby, 2 race, 3 results
EPOCH DW 1 ; Identifies the current room session.
GENERATION DW 1 ; Tracks map regeneration.
PLAYER_COUNT DB 0 ; Number of connected players.
; Player Information
READY DB 8 DUP(0) ; Readiness status of 8 players.
OWNER_IDS DW 8 DUP(0) ; Unique owner ID for each player slot.
PLAYER_NAMES DB 64 DUP(32) ; Stores 8 player names, each occupying 8 bytes.
; Session liveness, direction freshness and input sequencing have separate
; word arrays. READY/HELD/TAPS are bytes; names are eight-byte padded records.
; Player Input and Connection Tracking
LAST_SEEN DW 8 DUP(0) ; Tracks when each player was last active.
LAST_DIRECTION DW 8 DUP(0) ; Tracks freshness of direction inputs.
LAST_SEQUENCE DW 8 DUP(0) ; Stores the last input sequence number.
HAVE_SEQUENCE DB 8 DUP(0) ; Indicates whether a sequence number has been received.
HELD DB 8 DUP(0) ; Stores currently held movement inputs.
TAPS DB 8 DUP(0) ; Stores movement button taps.
; Room and Game Timing
ROOM_CODE DB '------------',0 ; Stores the multiplayer room code.
SYSTEM_TICK DW 0 ; Internal timing counter.
LAST_BIOS DD 0 ; Previous BIOS timer value.
ELAPSED_TICKS DD 0 ; Total elapsed game ticks.
FRAME_TICKS DW 0 ; Tracks frame timing.
STATE_TICK DW 0FFFFH ; Tracks game-state update timing.
; Receive state retains partial hex pairs/checksum across nonblocking polls.
; The decoded size includes checksum until POLL_END removes that last byte.
; Serial Data Reception (RX)
RX_BUFFER DB 96 DUP(0) ; Stores received bytes.
RX_SIZE DW 0 ; Number of received bytes.
RX_ACTIVE DB 0 ; Indicates whether a message is being received.
RX_HALF DB 0 ; Tracks whether half of a hexadecimal byte has arrived.
RX_HIGH DB 0 ; Stores the first hexadecimal digit.
RX_CHECK DB 0 ; Maintains the XOR checksum.
; TX_HEAD/TX_TAIL delimit unsent encoded bytes. OUT_BUFFER stages one
; binary payload; BACKUP_MAP/META support lobby regeneration rollback.
; Serial Data Transmission (TX)
TX_BUFFER DB 2048 DUP(0) ; Queue of encoded bytes waiting to be transmitted.
; Manage the transmission queue.
TX_HEAD DW 0
TX_TAIL DW 0
TX_CHECK DB 0 ; Stores the outgoing XOR checksum.
OUT_BUFFER DB 256 DUP(0) ; Temporarily stores a binary message before encoding.
OUT_SIZE DW 0 ; Size of the outgoing message.
; Acknowledgement and Backup
ACK_CODE DB 0 ; Stores acknowledgement status.
ACK_SLOT DB 0FFH ; Identifies the relevant player slot; FFH initially indicates no slot.
SER_BUDGET DW 0 ; Limits serial processing work.
TEMP_SEQ DW 0 ; Temporarily stores a sequence number.
BACKUP_MAP DB CELLS DUP(0) ; Saves the previous map.
BACKUP_META DB 23 DUP(0) ; Saves map metadata for rollback.
; Begin executable code. CALL saves a return address on SS:SP; RET resumes
; after that call. PROC/ENDP are assembler declarations, not run-time actions.
.CODE
; Initializes the COM1 serial port for communication between the MASM racing game and the host bridge.
; 115200 baud, 8N1 (8 data bits, no parity, 1 stop bit), with interrupts disabled.
; Baud Rate Calculation:
; Baud Rate = 115200 / Divisor
; Here, divisor = 1.
; Baud Rate = 115200 bps
SERIAL_INIT PROC NEAR
    ; COM1 ports begin at 3F8H. Disable UART interrupts at 3F9H, set DLAB
    ; in 3FBH to access the baud divisor, then write divisor 1 (115200 baud).
    ; Clear DLAB with line control 3: 8 data bits, no parity, one stop bit.
    ; Modem control 3 asserts DTR/RTS; foreground code polls rather than using IRQ4.
    ; UART: 115200, 8N1, interrupts off; polled by the main loop.
    MOV DX,3F9H ; Selects the UART interrupt enable register (IER).
    XOR AL,AL ; Sets AL = 0.
    OUT DX,AL ; Disables UART interrupts.
    MOV DX,3FBH ; Selects the Line Control Register (LCR).
    MOV AL,80H ; Sets DLAB = 1 to access baud-rate registers.
    OUT DX,AL ; Enables divisor register access.
    MOV DX,3F8H ; Selects the divisor low-byte register.
    MOV AL,1 ; Sets divisor low byte = 1.
    OUT DX,AL ; Writes divisor low byte.
    INC DX ; Moves to port 3F9H (divisor high byte).
    XOR AL,AL ; Sets AL = 0.
    OUT DX,AL ; Writes divisor high byte = 0.
    MOV DX,3FBH ; Selects the Line Control Register again.
    MOV AL,3 ; Configures 8 data bits, no parity, 1 stop bit; clears DLAB.
    OUT DX,AL ; Applies the 8N1 configuration.
    MOV DX,3FCH ; Selects the Modem Control Register (MCR).
    MOV AL,3 ; Sets DTR and RTS signals.
    OUT DX,AL ; Activates DTR and RTS.
    RET
SERIAL_INIT ENDP

; Queue output without blocking game time. A snapshot is skipped if congested.
; Adds a character stored in register AL to the serial transmission buffer (TX_BUFFER) without immediately transmitting it.
QUEUE_CHAR PROC NEAR
    ; Append AL at TX_TAIL if the fixed 2048-byte staging buffer has room.
    ; This is a linear queue reset only when drained, not a circular ring.
    ; BX is preserved; a full queue silently skips the character, so packet
    ; callers must reserve enough room for a complete frame before starting.
    PUSH BX ; Saves the original value of BX.
    MOV BX,TX_TAIL ; Loads the next available buffer position into BX.
    CMP BX,2048 ; Checks whether the buffer has reached its maximum capacity.
    JAE QUEUE_FULL ; Jumps if BX ≥ 2048, meaning the buffer is full.
    MOV TX_BUFFER[BX],AL ; Stores the character from AL at position BX.
    INC TX_TAIL ; Advances the tail pointer to the next position.
QUEUE_FULL:
    ; Restore BX and return without blocking for UART transmission.
    POP BX ; Restores the original BX value.
    RET
QUEUE_CHAR ENDP
; Converts the lowest 4 bits (nibble) of AL into an uppercase hexadecimal ASCII character (0-9, A-F) and adds it to the transmission queue using QUEUE_CHAR.
HEX_NIBBLE PROC NEAR
    ; Keep AL's low four bits, add ASCII '0', then add seven for A..F after
    ; 9. Queue the resulting uppercase character; this helper changes AL.
    AND AL,0FH ; Keeps only the lowest 4 bits of AL (value 0-15).
    ADD AL,'0' ; Converts values 0-9 into ASCII characters.
    CMP AL,'9' ; Checks whether the result is within 0-9.
    JBE HEX_CHAR ; If AL ≤ '9', jumps to HEX_CHAR.
    ADD AL,7 ; Converts values 10-15 into ASCII A-F.
HEX_CHAR:
    ; Append this single hexadecimal digit to the outgoing byte queue.
    CALL QUEUE_CHAR ; Adds the hexadecimal character to TX_BUFFER.
    RET
HEX_NIBBLE ENDP
HEX_BYTE PROC NEAR
    ; Save AX/CX, keep the original byte in AH, and emit its high nibble
    ; then low nibble. A four-bit shift exposes the high nibble in AL.
    ; Saves the original registers.
    PUSH AX
    PUSH CX
    MOV AH,AL ; Copies the original byte into AH.
    MOV CL,4 ; Sets shift count to 4 bits.
    SHR AL,CL ; Shifts AL right by 4 bits to extract the high nibble.
    CALL HEX_NIBBLE ; Converts and queues the high nibble.
    MOV AL,AH ; Restores the original byte from AH.
    CALL HEX_NIBBLE ; Converts and queues the low nibble.
    ; Restores the original registers.
    POP CX
    POP AX
    RET
HEX_BYTE ENDP
SEND_PACKET PROC NEAR
    ; DS:SI names a nonempty payload of CX bytes. Queue a colon, encode
    ; each byte while XOR-accumulating its checksum, encode the checksum,
    ; then queue LF (10). Total framing space is 2*payload_size+4 bytes.
    ; DS:SI payload, CX size. Caller guarantees 2*size+4 bytes of space.
    ; Saves registers.
    PUSH AX
    PUSH SI
    PUSH CX
    MOV AL,':' ; Loads the packet-start character :.
    CALL QUEUE_CHAR ; Adds : to the transmission queue.
    MOV TX_CHECK,0 ; Initializes the XOR checksum to zero.
SEND_PACKET_BYTE:
    ; LODSB consumes one payload byte with forward DS:SI. XOR is independent
    ; of integer endianness here because it checks each raw byte individually.
    LODSB ; Loads one byte from DS:SI into AL and advances SI. CLD in M4UI.
    XOR TX_CHECK,AL ; Updates the checksum using XOR.
    CALL HEX_BYTE ; Converts the byte into two hexadecimal ASCII characters and queues them.
    LOOP SEND_PACKET_BYTE ; Decrements CX and repeats while CX ≠ 0.
    MOV AL,TX_CHECK ; Loads the final checksum into AL.
    CALL HEX_BYTE ; Appends the checksum as two hexadecimal characters.
    MOV AL,10 ; Loads ASCII LF (line feed).
    CALL QUEUE_CHAR ; Adds LF to mark the end of the packet.
    ; Restores registers.
    POP CX
    POP SI
    POP AX
    RET
SEND_PACKET ENDP
; Sends queued characters from TX_BUFFER to the COM1 serial port, transmitting at most 512 bytes per call without blocking gameplay.
SERIAL_FLUSH PROC NEAR
    ; Bound each flush to 512 bytes to share foreground time with gameplay.
    ; TX_HEAD is the next unsent index; TX_TAIL is one past the queued data.
    MOV CX,512 ; Sets the maximum transmission limit to 512 bytes.
FLUSH_NEXT:
    ; UART line-status port 3FDH bit 5 means transmit holding register empty.
    ; If not ready, return immediately; otherwise write the next queued byte
    ; to 3F8H, advance HEAD, and continue within the per-call budget.
    MOV BX,TX_HEAD ; Gets the index of the next unsent byte.
    CMP BX,TX_TAIL ; Checks whether any queued bytes remain.
    JAE FLUSH_EMPTY ; Jumps if the queue is empty.
    MOV DX,3FDH ; Selects the UART Line Status Register.
    IN AL,DX ; Reads the UART status into AL.
    TEST AL,20H ; Checks bit 5 (transmitter holding register empty).
    JZ FLUSH_DONE ; Returns if the UART is not ready.
    MOV AL,TX_BUFFER[BX] ; Loads the next queued character.
    MOV DX,3F8H ; Selects the COM1 transmit data register.
    OUT DX,AL ; Sends the character to the UART.
    INC TX_HEAD ; Advances the queue's read position.
    LOOP FLUSH_NEXT ; Repeats until 512 bytes have been sent or another exit condition occurs.
    RET
; When all queued bytes have been processed, both pointers are reset to zero, allowing the entire 2048-byte buffer to be reused.
FLUSH_EMPTY:
    ; Once HEAD reaches TAIL, reset both to zero so the whole buffer is reusable.
    MOV TX_HEAD,0
    MOV TX_TAIL,0
; Returns immediately if the UART is not ready.
FLUSH_DONE:
    ; Return without waiting for hardware; a later main-loop call resumes flushing.
    RET
SERIAL_FLUSH ENDP

; Returns a nibble in AL, carry on invalid ASCII hex.
; Converts an ASCII hexadecimal character (0-9, A-F) into its numeric value (0-15). It uses the Carry Flag (CF) to indicate whether the character is valid.
PARSE_HEX PROC NEAR
    ; Convert ASCII 0..9 or uppercase A..F into AL=0..15 by subtracting
    ; '0' and the seven-code punctuation gap. Unsigned range tests reject
    ; other bytes, including lowercase. CF is the success/failure return channel.
    SUB AL,'0' ; Subtracts ASCII '0' (30H) to convert numeric characters.
    CMP AL,9 ; Checks whether the result is between 0 and 9.
    JBE PARSE_HEX_OK ; Jumps if AL ≤ 9 (unsigned comparison).
    SUB AL,7 ; Adjusts the ASCII gap between digits and letters.
    CMP AL,10 ; Checks whether the adjusted value is at least 10.
    JB PARSE_HEX_BAD ; Rejects values below 10.
    CMP AL,15 ; Checks whether the value exceeds 15.
    JA PARSE_HEX_BAD ; Rejects values above 15.
PARSE_HEX_OK:
    ; CLC explicitly clears carry for a valid nibble; RET leaves that flag intact.
    CLC ; Clears Carry Flag (CF = 0), indicating valid input.
    RET
PARSE_HEX_BAD:
    ; STC sets carry so the receiver can abandon malformed frame text.
    STC ; Sets Carry Flag (CF = 1), indicating invalid input.
    RET
PARSE_HEX ENDP

; Reads incoming bytes from COM1, converts hexadecimal characters into binary data, verifies the XOR checksum, and passes valid packets to RECEIVE_PACKET.
; It processes at most 256 serial bytes per call to avoid blocking the game.
SERIAL_POLL PROC NEAR
    ; Read at most 256 UART bytes per call, retaining partial-frame state
    ; between polls so slow or fragmented serial input does not block the game.
    MOV SER_BUDGET,256 ; Limits processing to 256 incoming characters.
POLL_BYTE:
    ; Line-status bit 0 means data ready. A colon resynchronizes immediately;
    ; bytes outside a frame are ignored. Inside a frame, LF finishes it and
    ; other characters must parse as hex. First nibble is shifted into bits 7..4.
    MOV DX,3FDH ; Selects UART Line Status Register.
    IN AL,DX ; Reads UART status.
    TEST AL,1 ; Checks whether incoming data is available.
    JZ POLL_DONE ; Returns if no data is available.
    MOV DX,3F8H ; Selects COM1 receive register.
    IN AL,DX ; Reads one incoming character.
    CMP AL,':' ; Checks for packet-start marker.
    JE POLL_START ; Starts a new packet if : is received.
    CMP RX_ACTIVE,0 ; Checks whether a packet is currently being received.
    JE POLL_NEXT ; Ignores characters outside a packet.
    CMP AL,10 ; Checks for LF (packet-ending character).
    JE POLL_END ; Finishes the packet.
    CALL PARSE_HEX ; Converts ASCII hexadecimal into a numeric nibble.
    JC POLL_INVALID ; Rejects invalid hexadecimal characters.
    ; Checks whether the current character is the first or second hexadecimal digit.
    ; For the first digit, shifts its value left by 4 bits.
    ; Stores it in RX_HIGH.
    ; Sets RX_HALF = 1, indicating that the second digit is expected.
    CMP RX_HALF,0
    JNE POLL_LOW
    MOV CL,4
    SHL AL,CL
    MOV RX_HIGH,AL
    MOV RX_HALF,1
    JMP POLL_NEXT
POLL_LOW:
    ; Combine low nibble with RX_HIGH, reset half-byte state, bound the
    ; 96-byte receive array, then store the decoded byte and XOR it into RX_CHECK.
    ; Combines the second hexadecimal digit with the first to reconstruct the original byte.
    OR AL,RX_HIGH
    MOV RX_HALF,0
    ; Checks that the receive buffer has space.
    ; Stores the decoded byte.
    ; Increments the received byte count.
    ; Updates the XOR checksum.
    ; Maximum receive buffer size: 96 bytes, including the checksum.
    MOV BX,RX_SIZE
    CMP BX,96
    JAE POLL_INVALID
    MOV RX_BUFFER[BX],AL
    INC RX_SIZE
    XOR RX_CHECK,AL
    JMP POLL_NEXT
; When LF is received, the procedure verifies:
; 1. No incomplete hexadecimal byte remains.
; 2. XOR checksum equals zero.
; 3. At least 6 decoded bytes were received (5-byte minimum header plus checksum).
; If valid, it removes the checksum from the payload length and calls RECEIVE_PACKET.
POLL_END:
    ; Require complete nibble pairs, XOR zero including the checksum, and at
    ; least a five-byte header plus checksum. Remove the checksum from RX_SIZE
    ; before dispatching. Corrupt/incomplete frames receive no packet dispatch.
    MOV RX_ACTIVE,0
    CMP RX_HALF,0
    JNE POLL_NEXT
    CMP RX_CHECK,0
    JNE POLL_NEXT
    CMP RX_SIZE,6
    JB POLL_NEXT
    DEC RX_SIZE                 ; discard checksum
    CALL RECEIVE_PACKET
    JMP POLL_NEXT
; Discards the current packet when invalid data is detected.
POLL_INVALID:
    ; Abandon the current frame and wait for a new colon to resynchronize.
    MOV RX_ACTIVE,0
    JMP POLL_NEXT
; Starts a fresh packet whenever : is received, resetting all reception variables.
POLL_START:
    ; Begin a fresh frame with zero length/checksum and no partial nibble.
    MOV RX_ACTIVE,1
    MOV RX_SIZE,0
    MOV RX_HALF,0
    MOV RX_CHECK,0
; Decrements the processing budget after each received character.
; If the budget reaches zero or no data is available, the procedure returns to the main program.
POLL_NEXT:
    ; Charge one byte against the poll budget, then continue if budget remains.
    DEC SER_BUDGET
    JNZ POLL_BYTE
POLL_DONE:
    ; Return when the UART has no byte or the foreground work budget is exhausted.
    RET
SERIAL_POLL ENDP

; Creates and queues an ACK (Acknowledgement) packet to inform the sender whether its request was accepted or rejected.
; ACK Packet Structure
; The payload contains 7 bytes.
; Byte offset	Field	                Size
; 0	            Packet type (81H)	    1 byte
; 1-2	        Request ID	            2 bytes
; 3-4	        Room epoch	            2 bytes
; 5	            ACK status (ACK_CODE)	1 byte
; 6	            Player slot (ACK_SLOT)	1 byte

; The two-byte fields are stored in little-endian format.
SEND_ACK PROC NEAR
    ; Only queue an ACK when sufficient tail space remains. The seven-byte
    ; payload contains type 81H, request ID, current room epoch, status and slot.
    ; A slot of FFH means none; OUT_BUFFER is reused after SEND_PACKET encodes it.
    CMP TX_TAIL,2028 ; Checks whether sufficient transmission buffer space remains.
    JA ACK_DONE ; Skips sending if TX_TAIL > 2028.
    MOV OUT_BUFFER,81H ; Sets packet type to 81H (ACK).
    MOV AX,WORD PTR RX_BUFFER[1] ; Reads the 2-byte request ID from the received packet.
    MOV WORD PTR OUT_BUFFER[1],AX ; Copies the request ID into the ACK.
    MOV AX,EPOCH ; Loads the current room epoch.
    MOV WORD PTR OUT_BUFFER[3],AX ; Stores the 2-byte epoch in the ACK.
    MOV AL,ACK_CODE ; Loads the acknowledgement status.
    MOV OUT_BUFFER[5],AL ; Stores the status code.
    MOV AL,ACK_SLOT ; Loads the player slot number.
    MOV OUT_BUFFER[6],AL ; Stores the slot number.
    LEA SI,OUT_BUFFER ; Points SI to the ACK payload.
    MOV CX,7 ; Specifies a 7-byte payload.
    CALL SEND_PACKET ; Encodes the ACK with checksum and queues it.
ACK_DONE:
    ; Return even if congestion caused this ACK to be skipped; transport stays nonblocking.
    RET
SEND_ACK ENDP

; Validates received packets and performs multiplayer game operations such as joining, leaving, movement, heartbeat, and ready status.
; It is the main packet-processing procedure of the racing game.
RECEIVE_PACKET PROC NEAR
    ; Default to invalid status 3/no slot. All requests must match EPOCH;
    ; stale-room status 4 returns the current epoch to the bridge.
    MOV ACK_CODE,3 ; invalid: Sets default status to 3 (invalid request).
    MOV ACK_SLOT,0FFH ; Sets player slot to FFH (no slot).
    ; Checks whether the packet belongs to the current room session. If not, returns status 4 (stale room).
    MOV AX,WORD PTR RX_BUFFER[3]
    CMP AX,EPOCH
    JE RECEIVE_EPOCH
    MOV ACK_CODE,4              ; stale room
    JMP RECEIVE_ACK
RECEIVE_EPOCH:
    ; Dispatch config/join separately. Other requests need at least eight bytes,
    ; slot 0..7, a nonzero matching owner token and a nonempty player state.
    ; An owned request refreshes LAST_SEEN before its command-specific validation;
    ; slot word-array fields use 2*slot. Tokens protect serial session association.
    ; The procedure selects an operation based on the first byte of the received packet.
    ; Packet type	Operation
    ; 1	            Configure room
    ; 2	            Join game
    ; 3	            Player movement input
    ; 4	            Heartbeat
    ; 5	            Leave game
    ; 6	            Ready status

    ; For packet types 3-6, it first verifies the player slot, owner ID, and player state.
    CMP RX_BUFFER,1
    JE RECEIVE_CONFIG
    CMP RX_BUFFER,2
    JE RECEIVE_JOIN
    CMP RX_SIZE,8
    JB RECEIVE_ACK
    XOR SI,SI
    MOV AL,RX_BUFFER[5]
    CMP AL,8
    JAE RECEIVE_ACK
    MOV SI,AX                   ; clear upper byte below
    AND SI,00FFH
    MOV BX,SI
    SHL BX,1
    MOV AX,WORD PTR RX_BUFFER[6]
    CMP AX,0
    JE RECEIVE_ACK
    CMP AX,OWNER_IDS[BX]
    JNE RECEIVE_ACK
    CMP PLAYER_STATE[SI],0
    JE RECEIVE_ACK
    MOV AX,SYSTEM_TICK
    MOV LAST_SEEN[BX],AX
    MOV AX,SI
    MOV ACK_SLOT,AL
    JMP RECEIVE_OWNED
RECEIVE_CONFIG:
    ; Require seventeen payload bytes: header plus twelve room-code characters.
    ; Validate every byte within ASCII '2'..'Z' before copying, so invalid
    ; config data cannot partly replace ROOM_CODE. The existing zero stays after it.
    ; Requires exactly 17 payload bytes.
    ; Validates 12 room-code characters.
    ; Accepts ASCII characters from '2' to 'Z'.
    ; Copies the validated room code into ROOM_CODE using REP MOVSB.
    ; Sets ACK_CODE = 0 on success.
    CMP RX_SIZE,17
    JNE RECEIVE_ACK
    LEA SI,RX_BUFFER+5
    LEA DI,ROOM_CODE
    MOV CX,12
CONFIG_CHAR:
    ; LODSB checks each proposed code byte; LOOP counts all twelve. After
    ; validation, restart SI and REP MOVSB the complete code into shared state.
    LODSB
    CMP AL,'2'
    JB RECEIVE_ACK
    CMP AL,'Z'
    JA RECEIVE_ACK
    LOOP CONFIG_CHAR
    LEA SI,RX_BUFFER+5
    MOV CX,12
    REP MOVSB
    MOV ACK_CODE,0
    JMP RECEIVE_ACK
RECEIVE_JOIN:
    ; Require a thirteen-byte request with a nonzero request/owner ID. First
    ; search existing owners so retrying the same join can return the same slot.
    ; Requires a 13-byte join request.
    ; The procedure:
    ; 1. Checks that the request/owner ID is nonzero.
    ; 2. Checks whether the player has already joined.
    ; 3. Allows new players only during the lobby phase.
    ; 4. Checks whether the room has available capacity.
    ; 5. Finds an empty player slot.
    ; 6. Validates the 8-character player name.
    ; 7. Assigns the owner ID and starting position.
    ; 8. Initializes player state and increments PLAYER_COUNT.
    CMP RX_SIZE,13
    JNE RECEIVE_ACK
    MOV AX,WORD PTR RX_BUFFER[1]
    OR AX,AX
    JZ RECEIVE_ACK
    XOR SI,SI
JOIN_EXISTING:
    ; Compare the request ID against each word owner field; a match is an
    ; idempotent success. Only a genuinely new join must pass lobby/capacity checks.
    MOV BX,SI
    SHL BX,1
    CMP OWNER_IDS[BX],AX
    JE JOIN_ACCEPTED
    INC SI
    CMP SI,8
    JB JOIN_EXISTING
    CMP PHASE,1
    JE JOIN_PHASE_OK
    MOV ACK_CODE,1
    JMP RECEIVE_ACK
JOIN_PHASE_OK:
    ; New admissions need PLAYER_COUNT<CAPACITY. Return full status 2 otherwise;
    ; new joins outside lobby return phase status 1 in the preceding branch.
    MOV AL,PLAYER_COUNT
    CMP AL,CAPACITY
    JB JOIN_FIND
    MOV ACK_CODE,2
    JMP RECEIVE_ACK
JOIN_FIND:
    ; Scan for the first empty slot after confirming lobby capacity remains.
    XOR SI,SI
JOIN_SLOT:
    ; State zero is free. A bounded scan avoids writing beyond the eight slots.
    CMP PLAYER_STATE[SI],0
    JE JOIN_CREATE
    INC SI
    CMP SI,8
    JB JOIN_SLOT
    JMP RECEIVE_ACK
JOIN_CREATE:
    ; Validate the full eight-character, space-padded display name before
    ; reserving a slot. Only printable ASCII 32..126 is accepted.
    ; Validate all name bytes before reserving a slot.
    LEA DI,RX_BUFFER+5
    MOV CX,8
JOIN_NAME_CHECK:
    ; After all eight characters pass, assign owner/start position, initialize
    ; lease timestamps, clear prior input/ready state and increment PLAYER_COUNT.
    ; Name offset=8*slot; REP MOVSB copies exactly eight bytes, not a terminator.
    MOV AL,[DI]
    CMP AL,32
    JB RECEIVE_ACK
    CMP AL,126
    JA RECEIVE_ACK
    INC DI
    LOOP JOIN_NAME_CHECK
    MOV BX,SI
    SHL BX,1
    MOV AX,WORD PTR RX_BUFFER[1]
    MOV OWNER_IDS[BX],AX
    MOV AX,STARTS[BX]
    MOV POSITIONS[BX],AX
    MOV AX,SYSTEM_TICK
    MOV LAST_SEEN[BX],AX
    MOV LAST_DIRECTION[BX],AX
    ; An existing owner receives the same slot without creating another player.
    MOV PLAYER_STATE[SI],1
    MOV READY[SI],0
    MOV HAVE_SEQUENCE[SI],0
    MOV HELD[SI],0
    MOV TAPS[SI],0
    MOV DIRECTIONS[SI],0
    INC PLAYER_COUNT
    PUSH SI
    MOV DI,SI
    MOV CL,3
    SHL DI,CL
    ADD DI,OFFSET PLAYER_NAMES
    LEA SI,RX_BUFFER+5
    MOV CX,8
    REP MOVSB
    POP SI
JOIN_ACCEPTED:
    ; Return the assigned/existing slot with ACK_CODE=0 (success).
    MOV AX,SI
    MOV ACK_SLOT,AL
    MOV ACK_CODE,0
    JMP RECEIVE_ACK
RECEIVE_OWNED:
    ; Only authenticated-to-this-slot serial requests reach this dispatch:
    ; 3=input, 4=heartbeat, 5=leave, 6=ready. Unknown types retain invalid status.
    ; Before processing movement, heartbeat, leave, or ready requests, the code checks:
    ; Valid slot number (0-7).
    ; Matching nonzero owner ID.
    ; Active player state.
    ; It also updates LAST_SEEN, which tracks the player's most recent activity.
    CMP RX_BUFFER,3
    JE RECEIVE_INPUT
    CMP RX_BUFFER,4
    JE RECEIVE_HEARTBEAT
    CMP RX_BUFFER,5
    JE RECEIVE_LEAVE
    CMP RX_BUFFER,6
    JE RECEIVE_READY
    JMP RECEIVE_ACK
RECEIVE_HEARTBEAT:
    ; Require exactly eight bytes. The shared ownership path already refreshed
    ; LAST_SEEN; success acknowledges the heartbeat without changing direction.
    ; Requires exactly 8 bytes.
    ; Confirms that the player is still connected.
    ; The common ownership-validation path has already refreshed LAST_SEEN.
    CMP RX_SIZE,8
    JNE RECEIVE_ACK
    MOV ACK_CODE,0
    JMP RECEIVE_ACK
RECEIVE_LEAVE:
    ; Require exactly eight bytes, drop/revoke the player, then acknowledge success.
    ; Validates the packet length.
    ; Calls DROP_PLAYER to remove the player.
    ; Returns success.
    CMP RX_SIZE,8
    JNE RECEIVE_ACK
    CALL DROP_PLAYER
    MOV ACK_CODE,0
    JMP RECEIVE_ACK
RECEIVE_READY:
    ; Only the lobby accepts ready updates. Require nine bytes and Boolean
    ; value 0/1; set READY[slot] for the later all-ready start check.
    ; Accepts ready updates only during the lobby.
    ; Requires a 9-byte packet.
    ; Accepts only 0 (not ready) or 1 (ready).
    CMP PHASE,1
    JNE RECEIVE_ACK
    CMP RX_SIZE,9
    JNE RECEIVE_ACK
    MOV AL,RX_BUFFER[8]
    CMP AL,1
    JA RECEIVE_ACK
    ; Updates the player's ready status.
    MOV READY[SI],AL
    MOV ACK_CODE,0
    JMP RECEIVE_ACK
; This section handles player movement during the race.
; It validates:
; Packet size = 14 bytes.
; Game phase = 2 (racing).
; Player is racing.
; Map generation matches.
; Direction is between 0 and 4.
; Tap flag is either 0 or 1.
; Input sequence number is newer than the previous accepted sequence.
RECEIVE_INPUT:
    ; Require fourteen bytes, active race, racing player and current generation.
    ; Validate direction 0..4 and tap Boolean, then reject duplicate/old sequence
    ; values using a signed modular 16-bit difference (new increments <32768).
    ; This handles ordinary wrap, including 7FFFH->8000H, without signed CMP.
    CMP RX_SIZE,14
    JNE RECEIVE_ACK
    CMP PHASE,2
    JNE RECEIVE_ACK
    CMP PLAYER_STATE[SI],1
    JNE RECEIVE_ACK
    MOV AX,WORD PTR RX_BUFFER[8]
    CMP AX,GENERATION
    JNE RECEIVE_ACK
    MOV AL,RX_BUFFER[12]
    CMP AL,4
    JA RECEIVE_ACK
    CMP BYTE PTR RX_BUFFER[13],1
    JA RECEIVE_ACK
    MOV AX,WORD PTR RX_BUFFER[10]
    CMP HAVE_SEQUENCE[SI],0
    JE INPUT_NEW
    ; Rejects duplicate or outdated input using a signed 16-bit sequence difference, allowing normal sequence-number wraparound.
    MOV DX,AX
    SUB DX,LAST_SEQUENCE[BX]
    OR DX,DX                    ; modular signed delta, including 7fff->8000
    JLE RECEIVE_ACK
INPUT_NEW:
    ; Save accepted sequence and input timestamp. A held update persists until
    ; fresh input/expiry; a tap latches one step in TAPS and clears HELD so one
    ; press does not accidentally become continuous movement.
    ; Stores the accepted sequence and input timestamp.
    MOV LAST_SEQUENCE[BX],AX
    MOV HAVE_SEQUENCE[SI],1
    MOV AX,SYSTEM_TICK
    MOV LAST_DIRECTION[BX],AX
    ; Stores the current held direction.
    MOV AL,RX_BUFFER[12]
    MOV HELD[SI],AL
    CMP RX_BUFFER[13],0
    JE INPUT_NOT_TAP
    ; If the input is a tap, it records a single movement step instead of continuous movement.
    MOV TAPS[SI],AL
    MOV HELD[SI],0              ; first press is exactly one latched step
INPUT_NOT_TAP:
    ; Mark the validated input successful before using the common ACK path.
    MOV ACK_CODE,0
; All request paths eventually reach this section, which sends an acknowledgement containing the request result.
; ACK Status Codes
; Code	Meaning
; 0	    Success
; 1	    Wrong game phase
; 2	    Room full
; 3	    Invalid request
; 4	    Stale room epoch
RECEIVE_ACK:
    ; Encode the status/slot reply. No request handler directly writes the UART.
    CALL SEND_ACK
    RET
RECEIVE_PACKET ENDP

; Handles a player leaving or disconnecting from the multiplayer racing game. Its behavior depends on whether the game is in the lobby or racing/results phase.
DROP_PLAYER PROC NEAR
    ; Clear motion/ready/warning state. In lobby, free the slot, revoke its
    ; owner and reduce count. After lobby, keep the result row but revoke ownership;
    ; a racer becomes DNF, while an already finished player stays finished.
    MOV HELD[SI],0 ; Clears continuous movement input.
    MOV TAPS[SI],0 ; Clears pending movement taps.
    MOV DIRECTIONS[SI],0 ; Resets movement direction.
    MOV READY[SI],0 ; Clears ready status.
    MOV WARNINGS[SI],0 ; Clears player warnings.
    CMP PHASE,1 ; Checks whether the game is in the lobby.
    JNE DROP_DNF ; If not in the lobby, jumps to DNF handling.
    ; Sets player state to 0 (empty slot).
    ; Calculates the owner's array offset using 2 x SI, because each owner ID occupies 2 bytes.
    ; Clears the player's owner ID.
    ; Decreases the player count.
    ; Returns.
    ; Result: The player's slot becomes available for another player.
    MOV PLAYER_STATE[SI],0
    MOV BX,SI
    SHL BX,1
    MOV OWNER_IDS[BX],0
    DEC PLAYER_COUNT
    RET
; Revokes the player's ownership so further requests using the old owner ID are rejected.
DROP_DNF:
    ; Revoke the owner immediately, then change only a still-racing slot to state 3.
    MOV BX,SI
    SHL BX,1
    MOV OWNER_IDS[BX],0
    ; If the player is still racing (STATE = 1), changes the state to 3 (DNF - Did Not Finish).
    ; If the player has already finished, their result remains unchanged.
    CMP PLAYER_STATE[SI],1
    JNE DROP_DONE
    MOV PLAYER_STATE[SI],3
DROP_DONE:
    ; Return without deleting the retained race/result record.
    RET
DROP_PLAYER ENDP

; Snapshot is one frame: header plus eight complete records, no torn roster.
; Creates a snapshot of the current multiplayer racing game, including game information and all 8 player records, then queues it for serial transmission.
SEND_STATE PROC NEAR
    ; Skip a snapshot if the TX tail exceeds 1400, leaving space for the
    ; full encoded state frame. Build type 82H plus room/map/time metadata
    ; into OUT_BUFFER. STOSB/STOSW write through ES:DI with forward direction.
    ; Checks whether the transmission queue has sufficient space.
    ; If TX_TAIL > 1400, skips sending the snapshot to avoid buffer overflow.
    CMP TX_TAIL,1400
    JA STATE_DONE
    ; DI points to the output buffer.
    ; 82H identifies a game-state packet.
    ; STOSB stores one byte at ES:DI and advances DI, assuming the direction flag is cleared.
    LEA DI,OUT_BUFFER
    MOV AL,82H
    STOSB
    ; Store Game Information
    ; The following instructions use STOSB and STOSW to write game metadata.
    ; Variable	        Purpose
    ; EPOCH	            Current room session
    ; GENERATION	    Current map version
    ; PHASE	            Lobby, race, or results
    ; CAPACITY	        Maximum allowed players
    ; COLLISION_MODE	Collision settings
    ; PLAYER_COUNT	    Number of players
    ; WIN_MASK	        Winner information
    ; EXIT_POS	        Maze exit position
    ; COMMON_DISTANCE	Equal route distance
    ; FLOOR_COUNT	    Number of floors
    ; ELAPSED_TENTHS	Elapsed race time (32-bit)
    ; BEST_SCORE	    Best score (32-bit)

    ; Important instructions:
    ; STOSB: Stores 1 byte and advances DI by 1.
    ; STOSW: Stores 2 bytes and advances DI by 2.
    ; Two STOSW instructions are used to store each 32-bit value.
    MOV AX,EPOCH
    STOSW
    MOV AX,GENERATION
    STOSW
    MOV AL,PHASE
    STOSB
    MOV AL,CAPACITY
    STOSB
    MOV AL,COLLISION_MODE
    STOSB
    MOV AL,PLAYER_COUNT
    STOSB
    MOV AL,WIN_MASK
    STOSB
    MOV AX,EXIT_POS
    STOSW
    MOV AX,COMMON_DISTANCE
    STOSW
    MOV AX,FLOOR_COUNT
    STOSW
    MOV AX,WORD PTR ELAPSED_TENTHS
    STOSW
    MOV AX,WORD PTR ELAPSED_TENTHS+2
    STOSW
    MOV AX,WORD PTR BEST_SCORE
    STOSW
    MOV AX,WORD PTR BEST_SCORE+2
    STOSW
    ; Initializes BP = 0.
    ; Uses BP to iterate through all eight player slots.
    
    ; Each player record contains:
    ; Field	        Size
    ; Player state	1 byte
    ; Warnings	    1 byte
    ; Owner ID	    2 bytes
    ; Position	    2 bytes
    ; Steps	        4 bytes
    ; Penalties	    4 bytes
    ; Finish time	4 bytes
    ; Ready status	1 byte
    ; Player name	8 bytes
    ; Total	        27 bytes
    XOR BP,BP
STATE_PLAYER:
    ; Serialize all eight slots as fixed records: state, warning, owner, position,
    ; 32-bit steps/penalty/finish, ready byte and eight name characters. Scaling
    ; switches from 2*slot for words to 4*slot for dwords and 8*slot for names.
    ; After the loop, DI-start gives the exact payload length for one coherent frame.
    MOV SI,BP
    MOV AL,PLAYER_STATE[SI]
    STOSB
    MOV AL,WARNINGS[SI]
    STOSB
    ; Multiplies the slot index by 2 to access word arrays such as OWNER_IDS and POSITIONS.
    MOV BX,SI
    SHL BX,1
    MOV AX,OWNER_IDS[BX]
    STOSW
    MOV AX,POSITIONS[BX]
    STOSW
    SHL BX,1 ; Multiplies the offset by another 2, giving 4 x slot, to access 32-bit arrays such as STEPS, PENALTIES, and FINISH_TIMES.
    MOV AX,WORD PTR STEPS[BX]
    STOSW
    MOV AX,WORD PTR STEPS[BX+2]
    STOSW
    MOV AX,WORD PTR PENALTIES[BX]
    STOSW
    MOV AX,WORD PTR PENALTIES[BX+2]
    STOSW
    MOV AX,WORD PTR FINISH_TIMES[BX]
    STOSW
    MOV AX,WORD PTR FINISH_TIMES[BX+2]
    STOSW
    MOV AL,READY[SI]
    STOSB
    ; Multiplies the slot index by 8 to locate the player's name.
    MOV CL,3
    SHL SI,CL
    ADD SI,OFFSET PLAYER_NAMES
    ; Copies the player's 8-character name into the output buffer.
    MOV CX,8
    REP MOVSB
    ; Increments the player index and repeats until all eight slots are serialized, including empty slots.
    INC BP
    CMP BP,8
    JB STATE_PLAYER
    ; Calculates the payload size using the difference between the final DI and the beginning of OUT_BUFFER.
    ; Sets SI to the payload's starting address.
    ; Calls SEND_PACKET to encode and queue the complete snapshot.
    MOV CX,DI
    SUB CX,OFFSET OUT_BUFFER
    LEA SI,OUT_BUFFER
    CALL SEND_PACKET
STATE_DONE:
    ; Return after queueing or deliberately skipping the snapshot under congestion.
    RET
SEND_STATE ENDP

READ_CLOCK PROC NEAR
    ; Read BIOS CX:DX and subtract the previous 32-bit value with SUB/SBB.
    ; A borrow indicates daily rollover, corrected by adding 0018:00B0H ticks.
    MOV AH,0 ; Selects BIOS clock-reading function.
    INT 1AH ; Reads BIOS timer ticks into CX:DX.
    MOV AX,DX ; Copies the lower 16 bits of the clock into AX.
    MOV BX,CX ; Copies the upper 16 bits into BX.
    SUB AX,WORD PTR LAST_BIOS ; Subtracts the previous clock's lower word.
    SBB BX,WORD PTR LAST_BIOS+2 ; Subtracts the previous upper word, including borrow.
    JNC READ_CLOCK_OK ; Skips rollover correction if no borrow occurred.
    ; Handle Midnight Rollover
    ; The BIOS timer runs at approximately 18.2 ticks per second and resets at midnight.
    ; These instructions correct the elapsed tick difference when the clock wraps around midnight.
    ; The correction value is:
    ; 001800B0_H = 1572,?
    ; More precisely, it represents 1,572,? ticks per day according to the constant used in the code; the important point is that it adds one day's tick count to the negative difference.
    ADD AX,00B0H ; Adds the lower word of the daily tick count.
    ADC BX,0018H ; Adds the upper word plus carry.
READ_CLOCK_OK:
    ; Save raw clock, advance low-word SYSTEM_TICK and FRAME_TICKS, and
    ; accumulate/convert elapsed race time only in phase 2. SYSTEM_TICK supports
    ; short unsigned modular lease checks; race time keeps its high word too.
    ; LAST_BIOS: Stores the current BIOS clock for the next comparison.
    ; SYSTEM_TICK: Advances the internal game clock.
    ; FRAME_TICKS: Tracks ticks for frame updates.
    MOV WORD PTR LAST_BIOS,DX
    MOV WORD PTR LAST_BIOS+2,CX
    ADD SYSTEM_TICK,AX
    ADD FRAME_TICKS,AX
    ; Only updates the race timer when PHASE = 2 (racing).
    CMP PHASE,2
    JNE CLOCK_DONE
    ; Adds the elapsed ticks to the 32-bit race timer.
    ADD WORD PTR ELAPSED_TICKS,AX
    ADC WORD PTR ELAPSED_TICKS+2,BX
    ; Converts accumulated BIOS ticks into tenths of a second.
    MOV AX,WORD PTR ELAPSED_TICKS
    MOV DX,WORD PTR ELAPSED_TICKS+2
    CALL TICKS_TO_TENTHS
    ; Stores the converted race time.
    MOV WORD PTR ELAPSED_TENTHS,AX
    MOV WORD PTR ELAPSED_TENTHS+2,DX
CLOCK_DONE:
    ; Return to the UI loop with fresh foreground timing values.
    RET
READ_CLOCK ENDP
GAME_TICK PROC NEAR
    ; Run lease/movement updates when at least two ticks accrued. Reset the
    ; frame budget rather than replaying a backlog of delayed movement frames.
    ; Runs the game update only when at least 2 BIOS ticks have passed (approximately 0.11 seconds).
    ; Resets the frame counter.
    ; Prevents movement from updating too frequently.
    CMP FRAME_TICKS,2
    JB GAME_DONE
    MOV FRAME_TICKS,0
    ; Initializes SI = 0.
    ; Checks all 8 player slots.
    ; Processes only players with state 1 (actively racing).
    XOR SI,SI
LEASE_PLAYER:
    ; For each racing slot, use 2*slot to address timestamps. During a race,
    ; 546 ticks without an owned request (about 30 seconds) marks DNF and clears
    ; input. Timeout retains ownership so terminal status remains readable;
    ; explicit leave/removal revokes it through DROP_PLAYER instead.
    CMP PLAYER_STATE[SI],1
    JNE LEASE_NEXT
    ; Calculates 2 x SI to access 16-bit timestamp arrays.
    MOV BX,SI
    SHL BX,1
    ; Checks connection inactivity during the race.
    ; Calculates the time since the player's last valid request.
    ; If inactivity reaches 546 ticks (approximately 30 seconds), the player times out.
    CMP PHASE,2
    JNE LEASE_HELD
    MOV AX,SYSTEM_TICK
    SUB AX,LAST_SEEN[BX]
    CMP AX,546
    JB LEASE_HELD
    ; Timed-out players retain identity only to read their terminal DNF status.
    ; Explicit leave/host removal below revokes ownership immediately.
    ; Marks the player DNF (Did Not Finish) and clears movement-related state.
    ; Unlike DROP_PLAYER, this timeout retains the player's ownership information.
    MOV PLAYER_STATE[SI],3
    MOV HELD[SI],0
    MOV TAPS[SI],0
    MOV DIRECTIONS[SI],0
    MOV READY[SI],0
    MOV WARNINGS[SI],0
    JMP LEASE_NEXT
LEASE_HELD:
    ; A direction older than fourteen ticks (about 0.77 seconds) loses HELD/TAPS,
    ; even if heartbeats kept the session alive, preventing stale movement.
    ; Checks when the player last sent a valid direction.
    ; If the input is at least 14 ticks old (approximately 0.77 seconds), it expires.
    MOV AX,SYSTEM_TICK
    SUB AX,LAST_DIRECTION[BX]
    CMP AX,14
    JB LEASE_FRESH
    ; Clears stale movement inputs to prevent unintended continuous movement.
    MOV HELD[SI],0
    MOV TAPS[SI],0
; Normally uses the held direction.
; If a tap is pending, prioritizes the tap.
; Clears the tap after consuming it so it produces only one movement step.
LEASE_FRESH:
    ; Prefer a queued tap over held direction for this frame, then consume it.
    MOV AL,HELD[SI]
    CMP TAPS[SI],0
    JE LEASE_SAVE
    MOV AL,TAPS[SI]
    MOV TAPS[SI],0
; Stores the selected direction for the movement engine.
LEASE_SAVE:
    ; Publish the leased direction into DIRECTIONS for the core intent builder.
    MOV DIRECTIONS[SI],AL
LEASE_NEXT:
    ; After every slot, phase 2 performs intents, collision resolution, commit
    ; and proximity warnings. Lobby/results skip game motion.
    ; Moves to the next player until all 8 slots have been checked.
    INC SI
    CMP SI,8
    JB LEASE_PLAYER
    ; These procedures handle the actual racing logic.
    ; Procedure	        Purpose
    ; BUILD_INTENTS	    Determines each player's intended movement.
    ; RESOLVE_MOVES	    Resolves movement conflicts and collisions.
    ; COMMIT_MOVES	    Applies accepted movements to player positions.
    ; UPDATE_WARNINGS	Updates proximity or collision warnings.

    ; These are called only during the racing phase.
    CMP PHASE,2
    JNE GAME_DONE
    CALL BUILD_INTENTS
    CALL RESOLVE_MOVES
    CALL COMMIT_MOVES
    CALL UPDATE_WARNINGS
    XOR SI,SI
; Checks whether any player is still racing.
; If at least one player remains active, the race continues.
; If no players remain active, the race ends.
CHECK_REMAINING:
    ; If no slot remains racing, enter results phase and choose winners only
    ; from finishers. A race with only DNF outcomes can have no winner bits.
    CMP PLAYER_STATE[SI],1
    JE GAME_DONE
    INC SI
    CMP SI,8
    JB CHECK_REMAINING
    ; Changes the game to the results phase and determines the winners from players who finished successfully.
    MOV PHASE,3
    CALL FIND_WINNERS
GAME_DONE:
    ; Return to serial flushing/rendering without waiting for the next tick.
    RET
GAME_TICK ENDP
; Starts the race only when the game is in the lobby, at least two players have joined, and every connected player is ready.
START_RACE PROC NEAR
    ; Only lobby with at least two participants can start. Require every
    ; nonempty slot to be ready, then enter phase 2 and reset race/frame timers.
    CMP PHASE,1 ; Checks whether the game is in the lobby.
    JNE START_DONE ; Returns if the game is not in the lobby.
    CMP PLAYER_COUNT,2 ; Checks whether at least 2 players have joined.
    JB START_DONE ; Returns if fewer than 2 players are present.
    XOR SI,SI ; Initializes player index SI = 0.
START_CHECK:
    ; Empty slots do not need readiness; any occupied unready slot aborts start.
    CMP PLAYER_STATE[SI],0 ; Checks whether the player slot is empty.
    JE START_NEXT ; Skips empty slots.
    CMP READY[SI],0 ; Checks whether an occupied player is ready.
    JE START_DONE ; Cancels starting if any occupied player is not ready.
START_NEXT:
    ; After all eight slots pass, initialize the common race clock to zero.
    INC SI ; Moves to the next player slot.
    CMP SI,8 ; Checks whether all 8 slots have been examined.
    JB START_CHECK ; Repeats until all slots are checked.
    MOV PHASE,2 ; Changes the game phase to racing.
    MOV WORD PTR ELAPSED_TICKS,0 ; Resets the lower 16 bits of elapsed ticks.
    MOV WORD PTR ELAPSED_TICKS+2,0 ; Resets the upper 16 bits.
    MOV WORD PTR ELAPSED_TENTHS,0 ; Resets the lower 16 bits of race time.
    MOV WORD PTR ELAPSED_TENTHS+2,0 ; Resets the upper 16 bits.
    MOV FRAME_TICKS,0 ; Resets the frame timer.
START_DONE:
    ; Return whether start succeeded or a prerequisite caused a no-op.
    RET
START_RACE ENDP
REGENERATE PROC NEAR
    ; Only the lobby may change mazes. Back up current map and its contiguous
    ; 23-byte metadata, generate a candidate, and restore if it cannot fit the
    ; current player count. No player is evicted merely because generation is worse.
    CMP PHASE,1
    JNE REGENERATE_DONE
    LEA SI,MAZE
    LEA DI,BACKUP_MAP
    MOV CX,CELLS
    REP MOVSB
    LEA SI,EXIT_POS
    LEA DI,BACKUP_META
    MOV CX,23
    REP MOVSB
    CALL GENERATE_MAZE
    MOV AL,CAPACITY
    CMP AL,PLAYER_COUNT
    JAE REGENERATE_OK
    LEA SI,BACKUP_MAP
    LEA DI,MAZE
    MOV CX,CELLS
    REP MOVSB
    LEA SI,BACKUP_META
    LEA DI,EXIT_POS
    MOV CX,23
    REP MOVSB
    RET
REGENERATE_OK:
    ; Accept the map and increment GENERATION so packets for the old layout fail.
    INC GENERATION
    XOR SI,SI
REPOSITION:
    ; Place each slot at its new start and clear readiness/held/tap state.
    ; Participants must ready again before starting the regenerated maze.
    MOV BX,SI
    SHL BX,1
    MOV AX,STARTS[BX]
    MOV POSITIONS[BX],AX
    MOV READY[SI],0
    MOV HELD[SI],0
    MOV TAPS[SI],0
    INC SI
    CMP SI,8
    JB REPOSITION
REGENERATE_DONE:
    ; Return after acceptance, rollback, or a non-lobby no-op.
    RET
REGENERATE ENDP
NEW_ROOM PROC NEAR
    ; Do not reset an active race. Otherwise clear core state, change EPOCH
    ; and generation, and rebuild a lobby. Skip epoch zero on 16-bit wrap so
    ; zero never becomes a valid room epoch.
    CMP PHASE,2
    JE NEW_ROOM_DONE
    CALL RESET_GAME
    INC EPOCH
    JNZ EPOCH_OK
    INC EPOCH
EPOCH_OK:
    ; Reset roster/owners/readiness, blank fixed-width names, restore room-code
    ; placeholders and generate a new map. Old-session packets fail the epoch test.
    INC GENERATION
    MOV PHASE,1
    MOV PLAYER_COUNT,0
    LEA DI,READY
    MOV CX,8
    XOR AX,AX
    REP STOSB
    LEA DI,OWNER_IDS
    MOV CX,8
    REP STOSW
    LEA DI,PLAYER_NAMES
    MOV AL,32
    MOV CX,64
    REP STOSB
    LEA DI,ROOM_CODE
    MOV AL,'-'
    MOV CX,12
    REP STOSB
    CALL GENERATE_MAZE
NEW_ROOM_DONE:
    ; Return after room initialization or a protected active-race no-op.
    RET
NEW_ROOM ENDP

DIVIDE_U32 PROC NEAR
    ; Divide unsigned DX:AX by nonzero BX using two word divisions. Save the
    ; low word, divide 0:high, then divide remainder:low. Return full quotient
    ; DX:AX and remainder CX; preserve SI/DI used as intermediates.
    PUSH SI
    PUSH DI
    MOV SI,AX
    MOV AX,DX
    XOR DX,DX
    DIV BX
    MOV DI,AX
    MOV AX,SI
    DIV BX
    MOV CX,DX
    MOV DX,DI
    POP DI
    POP SI
    RET
DIVIDE_U32 ENDP

; Convert BIOS ticks to tenths with the 18.2 Hz approximation.
; Predivision avoids overflowing 32 bits when multiplying by 100.
TICKS_TO_TENTHS PROC NEAR
    ; Approximate 18.2 Hz: tenths=floor(ticks*100/182). Divide first into
    ; q and r, then compute 100*q+floor(100*r/182), avoiding a large ticks*100
    ; intermediate. Multiply q's low/high words separately and combine the carries;
    ; stack saves preserve the remainder and partial result during this work.
    PUSH BX
    PUSH CX
    PUSH SI
    PUSH DI
    PUSH BP
    MOV BX,182
    CALL DIVIDE_U32
    PUSH CX
    MOV SI,DX
    MOV BX,100
    MUL BX
    MOV DI,AX
    MOV BP,DX
    MOV AX,SI
    MUL BX
    ADD AX,BP
    MOV DX,AX
    MOV AX,DI
    POP CX
    PUSH AX
    PUSH DX
    MOV AX,CX
    MUL BX
    MOV BX,182
    DIV BX
    MOV BX,AX
    POP DX
    POP AX
    ADD AX,BX
    ADC DX,0
    POP BP
    POP DI
    POP SI
    POP CX
    POP BX
    RET
TICKS_TO_TENTHS ENDP
