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
PHASE DB 1                       ; 1 lobby, 2 race, 3 results
EPOCH DW 1
GENERATION DW 1
PLAYER_COUNT DB 0
READY DB 8 DUP(0)
OWNER_IDS DW 8 DUP(0)
PLAYER_NAMES DB 64 DUP(32)
; Session liveness, direction freshness and input sequencing have separate
; word arrays. READY/HELD/TAPS are bytes; names are eight-byte padded records.
LAST_SEEN DW 8 DUP(0)
LAST_DIRECTION DW 8 DUP(0)
LAST_SEQUENCE DW 8 DUP(0)
HAVE_SEQUENCE DB 8 DUP(0)
HELD DB 8 DUP(0)
TAPS DB 8 DUP(0)
ROOM_CODE DB '------------',0
SYSTEM_TICK DW 0
LAST_BIOS DD 0
ELAPSED_TICKS DD 0
FRAME_TICKS DW 0
STATE_TICK DW 0FFFFH
; Receive state retains partial hex pairs/checksum across nonblocking polls.
; The decoded size includes checksum until POLL_END removes that last byte.
RX_BUFFER DB 96 DUP(0)
RX_SIZE DW 0
RX_ACTIVE DB 0
RX_HALF DB 0
RX_HIGH DB 0
RX_CHECK DB 0
; TX_HEAD/TX_TAIL delimit unsent encoded bytes. OUT_BUFFER stages one
; binary payload; BACKUP_MAP/META support lobby regeneration rollback.
TX_BUFFER DB 2048 DUP(0)
TX_HEAD DW 0
TX_TAIL DW 0
TX_CHECK DB 0
OUT_BUFFER DB 256 DUP(0)
OUT_SIZE DW 0
ACK_CODE DB 0
ACK_SLOT DB 0FFH
SER_BUDGET DW 0
TEMP_SEQ DW 0
BACKUP_MAP DB CELLS DUP(0)
BACKUP_META DB 23 DUP(0)
; Begin executable code. CALL saves a return address on SS:SP; RET resumes
; after that call. PROC/ENDP are assembler declarations, not run-time actions.
.CODE
SERIAL_INIT PROC NEAR
    ; COM1 ports begin at 3F8H. Disable UART interrupts at 3F9H, set DLAB
    ; in 3FBH to access the baud divisor, then write divisor 1 (115200 baud).
    ; Clear DLAB with line control 3: 8 data bits, no parity, one stop bit.
    ; Modem control 3 asserts DTR/RTS; foreground code polls rather than using IRQ4.
    ; UART: 115200, 8N1, interrupts off; polled by the main loop.
    MOV DX,3F9H
    XOR AL,AL
    OUT DX,AL
    MOV DX,3FBH
    MOV AL,80H
    OUT DX,AL
    MOV DX,3F8H
    MOV AL,1
    OUT DX,AL
    INC DX
    XOR AL,AL
    OUT DX,AL
    MOV DX,3FBH
    MOV AL,3
    OUT DX,AL
    MOV DX,3FCH
    MOV AL,3
    OUT DX,AL
    RET
SERIAL_INIT ENDP

; Queue output without blocking game time. A snapshot is skipped if congested.
QUEUE_CHAR PROC NEAR
    ; Append AL at TX_TAIL if the fixed 2048-byte staging buffer has room.
    ; This is a linear queue reset only when drained, not a circular ring.
    ; BX is preserved; a full queue silently skips the character, so packet
    ; callers must reserve enough room for a complete frame before starting.
    PUSH BX
    MOV BX,TX_TAIL
    CMP BX,2048
    JAE QUEUE_FULL
    MOV TX_BUFFER[BX],AL
    INC TX_TAIL
QUEUE_FULL:
    ; Restore BX and return without blocking for UART transmission.
    POP BX
    RET
QUEUE_CHAR ENDP
HEX_NIBBLE PROC NEAR
    ; Keep AL's low four bits, add ASCII '0', then add seven for A..F after
    ; 9. Queue the resulting uppercase character; this helper changes AL.
    AND AL,0FH
    ADD AL,'0'
    CMP AL,'9'
    JBE HEX_CHAR
    ADD AL,7
HEX_CHAR:
    ; Append this single hexadecimal digit to the outgoing byte queue.
    CALL QUEUE_CHAR
    RET
HEX_NIBBLE ENDP
HEX_BYTE PROC NEAR
    ; Save AX/CX, keep the original byte in AH, and emit its high nibble
    ; then low nibble. A four-bit shift exposes the high nibble in AL.
    PUSH AX
    PUSH CX
    MOV AH,AL
    MOV CL,4
    SHR AL,CL
    CALL HEX_NIBBLE
    MOV AL,AH
    CALL HEX_NIBBLE
    POP CX
    POP AX
    RET
HEX_BYTE ENDP
SEND_PACKET PROC NEAR
    ; DS:SI names a nonempty payload of CX bytes. Queue a colon, encode
    ; each byte while XOR-accumulating its checksum, encode the checksum,
    ; then queue LF (10). Total framing space is 2*payload_size+4 bytes.
    ; DS:SI payload, CX size. Caller guarantees 2*size+4 bytes of space.
    PUSH AX
    PUSH SI
    PUSH CX
    MOV AL,':'
    CALL QUEUE_CHAR
    MOV TX_CHECK,0
SEND_PACKET_BYTE:
    ; LODSB consumes one payload byte with forward DS:SI. XOR is independent
    ; of integer endianness here because it checks each raw byte individually.
    LODSB
    XOR TX_CHECK,AL
    CALL HEX_BYTE
    LOOP SEND_PACKET_BYTE
    MOV AL,TX_CHECK
    CALL HEX_BYTE
    MOV AL,10
    CALL QUEUE_CHAR
    POP CX
    POP SI
    POP AX
    RET
SEND_PACKET ENDP
SERIAL_FLUSH PROC NEAR
    ; Bound each flush to 512 bytes to share foreground time with gameplay.
    ; TX_HEAD is the next unsent index; TX_TAIL is one past the queued data.
    MOV CX,512
FLUSH_NEXT:
    ; UART line-status port 3FDH bit 5 means transmit holding register empty.
    ; If not ready, return immediately; otherwise write the next queued byte
    ; to 3F8H, advance HEAD, and continue within the per-call budget.
    MOV BX,TX_HEAD
    CMP BX,TX_TAIL
    JAE FLUSH_EMPTY
    MOV DX,3FDH
    IN AL,DX
    TEST AL,20H
    JZ FLUSH_DONE
    MOV AL,TX_BUFFER[BX]
    MOV DX,3F8H
    OUT DX,AL
    INC TX_HEAD
    LOOP FLUSH_NEXT
    RET
FLUSH_EMPTY:
    ; Once HEAD reaches TAIL, reset both to zero so the whole buffer is reusable.
    MOV TX_HEAD,0
    MOV TX_TAIL,0
FLUSH_DONE:
    ; Return without waiting for hardware; a later main-loop call resumes flushing.
    RET
SERIAL_FLUSH ENDP

; Returns a nibble in AL, carry on invalid ASCII hex.
PARSE_HEX PROC NEAR
    ; Convert ASCII 0..9 or uppercase A..F into AL=0..15 by subtracting
    ; '0' and the seven-code punctuation gap. Unsigned range tests reject
    ; other bytes, including lowercase. CF is the success/failure return channel.
    SUB AL,'0'
    CMP AL,9
    JBE PARSE_HEX_OK
    SUB AL,7
    CMP AL,10
    JB PARSE_HEX_BAD
    CMP AL,15
    JA PARSE_HEX_BAD
PARSE_HEX_OK:
    ; CLC explicitly clears carry for a valid nibble; RET leaves that flag intact.
    CLC
    RET
PARSE_HEX_BAD:
    ; STC sets carry so the receiver can abandon malformed frame text.
    STC
    RET
PARSE_HEX ENDP
SERIAL_POLL PROC NEAR
    ; Read at most 256 UART bytes per call, retaining partial-frame state
    ; between polls so slow or fragmented serial input does not block the game.
    MOV SER_BUDGET,256
POLL_BYTE:
    ; Line-status bit 0 means data ready. A colon resynchronizes immediately;
    ; bytes outside a frame are ignored. Inside a frame, LF finishes it and
    ; other characters must parse as hex. First nibble is shifted into bits 7..4.
    MOV DX,3FDH
    IN AL,DX
    TEST AL,1
    JZ POLL_DONE
    MOV DX,3F8H
    IN AL,DX
    CMP AL,':'
    JE POLL_START
    CMP RX_ACTIVE,0
    JE POLL_NEXT
    CMP AL,10
    JE POLL_END
    CALL PARSE_HEX
    JC POLL_INVALID
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
    OR AL,RX_HIGH
    MOV RX_HALF,0
    MOV BX,RX_SIZE
    CMP BX,96
    JAE POLL_INVALID
    MOV RX_BUFFER[BX],AL
    INC RX_SIZE
    XOR RX_CHECK,AL
    JMP POLL_NEXT
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
POLL_INVALID:
    ; Abandon the current frame and wait for a new colon to resynchronize.
    MOV RX_ACTIVE,0
    JMP POLL_NEXT
POLL_START:
    ; Begin a fresh frame with zero length/checksum and no partial nibble.
    MOV RX_ACTIVE,1
    MOV RX_SIZE,0
    MOV RX_HALF,0
    MOV RX_CHECK,0
POLL_NEXT:
    ; Charge one byte against the poll budget, then continue if budget remains.
    DEC SER_BUDGET
    JNZ POLL_BYTE
POLL_DONE:
    ; Return when the UART has no byte or the foreground work budget is exhausted.
    RET
SERIAL_POLL ENDP

SEND_ACK PROC NEAR
    ; Only queue an ACK when sufficient tail space remains. The seven-byte
    ; payload contains type 81H, request ID, current room epoch, status and slot.
    ; A slot of FFH means none; OUT_BUFFER is reused after SEND_PACKET encodes it.
    CMP TX_TAIL,2028
    JA ACK_DONE
    MOV OUT_BUFFER,81H
    MOV AX,WORD PTR RX_BUFFER[1]
    MOV WORD PTR OUT_BUFFER[1],AX
    MOV AX,EPOCH
    MOV WORD PTR OUT_BUFFER[3],AX
    MOV AL,ACK_CODE
    MOV OUT_BUFFER[5],AL
    MOV AL,ACK_SLOT
    MOV OUT_BUFFER[6],AL
    LEA SI,OUT_BUFFER
    MOV CX,7
    CALL SEND_PACKET
ACK_DONE:
    ; Return even if congestion caused this ACK to be skipped; transport stays nonblocking.
    RET
SEND_ACK ENDP

RECEIVE_PACKET PROC NEAR
    ; Default to invalid status 3/no slot. All requests must match EPOCH;
    ; stale-room status 4 returns the current epoch to the bridge.
    MOV ACK_CODE,3              ; invalid
    MOV ACK_SLOT,0FFH
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
    CMP RX_SIZE,8
    JNE RECEIVE_ACK
    MOV ACK_CODE,0
    JMP RECEIVE_ACK
RECEIVE_LEAVE:
    ; Require exactly eight bytes, drop/revoke the player, then acknowledge success.
    CMP RX_SIZE,8
    JNE RECEIVE_ACK
    CALL DROP_PLAYER
    MOV ACK_CODE,0
    JMP RECEIVE_ACK
RECEIVE_READY:
    ; Only the lobby accepts ready updates. Require nine bytes and Boolean
    ; value 0/1; set READY[slot] for the later all-ready start check.
    CMP PHASE,1
    JNE RECEIVE_ACK
    CMP RX_SIZE,9
    JNE RECEIVE_ACK
    MOV AL,RX_BUFFER[8]
    CMP AL,1
    JA RECEIVE_ACK
    MOV READY[SI],AL
    MOV ACK_CODE,0
    JMP RECEIVE_ACK
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
    MOV DX,AX
    SUB DX,LAST_SEQUENCE[BX]
    OR DX,DX                    ; modular signed delta, including 7fff->8000
    JLE RECEIVE_ACK
INPUT_NEW:
    ; Save accepted sequence and input timestamp. A held update persists until
    ; fresh input/expiry; a tap latches one step in TAPS and clears HELD so one
    ; press does not accidentally become continuous movement.
    MOV LAST_SEQUENCE[BX],AX
    MOV HAVE_SEQUENCE[SI],1
    MOV AX,SYSTEM_TICK
    MOV LAST_DIRECTION[BX],AX
    MOV AL,RX_BUFFER[12]
    MOV HELD[SI],AL
    CMP RX_BUFFER[13],0
    JE INPUT_NOT_TAP
    MOV TAPS[SI],AL
    MOV HELD[SI],0              ; first press is exactly one latched step
INPUT_NOT_TAP:
    ; Mark the validated input successful before using the common ACK path.
    MOV ACK_CODE,0
RECEIVE_ACK:
    ; Encode the status/slot reply. No request handler directly writes the UART.
    CALL SEND_ACK
    RET
RECEIVE_PACKET ENDP

DROP_PLAYER PROC NEAR
    ; Clear motion/ready/warning state. In lobby, free the slot, revoke its
    ; owner and reduce count. After lobby, keep the result row but revoke ownership;
    ; a racer becomes DNF, while an already finished player stays finished.
    MOV HELD[SI],0
    MOV TAPS[SI],0
    MOV DIRECTIONS[SI],0
    MOV READY[SI],0
    MOV WARNINGS[SI],0
    CMP PHASE,1
    JNE DROP_DNF
    MOV PLAYER_STATE[SI],0
    MOV BX,SI
    SHL BX,1
    MOV OWNER_IDS[BX],0
    DEC PLAYER_COUNT
    RET
DROP_DNF:
    ; Revoke the owner immediately, then change only a still-racing slot to state 3.
    MOV BX,SI
    SHL BX,1
    MOV OWNER_IDS[BX],0
    CMP PLAYER_STATE[SI],1
    JNE DROP_DONE
    MOV PLAYER_STATE[SI],3
DROP_DONE:
    ; Return without deleting the retained race/result record.
    RET
DROP_PLAYER ENDP

; Snapshot is one frame: header plus eight complete records, no torn roster.
SEND_STATE PROC NEAR
    ; Skip a snapshot if the TX tail exceeds 1400, leaving space for the
    ; full encoded state frame. Build type 82H plus room/map/time metadata
    ; into OUT_BUFFER. STOSB/STOSW write through ES:DI with forward direction.
    CMP TX_TAIL,1400
    JA STATE_DONE
    LEA DI,OUT_BUFFER
    MOV AL,82H
    STOSB
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
    MOV BX,SI
    SHL BX,1
    MOV AX,OWNER_IDS[BX]
    STOSW
    MOV AX,POSITIONS[BX]
    STOSW
    SHL BX,1
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
    MOV CL,3
    SHL SI,CL
    ADD SI,OFFSET PLAYER_NAMES
    MOV CX,8
    REP MOVSB
    INC BP
    CMP BP,8
    JB STATE_PLAYER
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
    MOV AH,0
    INT 1AH
    MOV AX,DX
    MOV BX,CX
    SUB AX,WORD PTR LAST_BIOS
    SBB BX,WORD PTR LAST_BIOS+2
    JNC READ_CLOCK_OK
    ADD AX,00B0H
    ADC BX,0018H
READ_CLOCK_OK:
    ; Save raw clock, advance low-word SYSTEM_TICK and FRAME_TICKS, and
    ; accumulate/convert elapsed race time only in phase 2. SYSTEM_TICK supports
    ; short unsigned modular lease checks; race time keeps its high word too.
    MOV WORD PTR LAST_BIOS,DX
    MOV WORD PTR LAST_BIOS+2,CX
    ADD SYSTEM_TICK,AX
    ADD FRAME_TICKS,AX
    CMP PHASE,2
    JNE CLOCK_DONE
    ADD WORD PTR ELAPSED_TICKS,AX
    ADC WORD PTR ELAPSED_TICKS+2,BX
    MOV AX,WORD PTR ELAPSED_TICKS
    MOV DX,WORD PTR ELAPSED_TICKS+2
    CALL TICKS_TO_TENTHS
    MOV WORD PTR ELAPSED_TENTHS,AX
    MOV WORD PTR ELAPSED_TENTHS+2,DX
CLOCK_DONE:
    ; Return to the UI loop with fresh foreground timing values.
    RET
READ_CLOCK ENDP
GAME_TICK PROC NEAR
    ; Run lease/movement updates when at least two ticks accrued. Reset the
    ; frame budget rather than replaying a backlog of delayed movement frames.
    CMP FRAME_TICKS,2
    JB GAME_DONE
    MOV FRAME_TICKS,0
    XOR SI,SI
LEASE_PLAYER:
    ; For each racing slot, use 2*slot to address timestamps. During a race,
    ; 546 ticks without an owned request (about 30 seconds) marks DNF and clears
    ; input. Timeout retains ownership so terminal status remains readable;
    ; explicit leave/removal revokes it through DROP_PLAYER instead.
    CMP PLAYER_STATE[SI],1
    JNE LEASE_NEXT
    MOV BX,SI
    SHL BX,1
    CMP PHASE,2
    JNE LEASE_HELD
    MOV AX,SYSTEM_TICK
    SUB AX,LAST_SEEN[BX]
    CMP AX,546
    JB LEASE_HELD
    ; Timed-out players retain identity only to read their terminal DNF status.
    ; Explicit leave/host removal below revokes ownership immediately.
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
    MOV AX,SYSTEM_TICK
    SUB AX,LAST_DIRECTION[BX]
    CMP AX,14
    JB LEASE_FRESH
    MOV HELD[SI],0
    MOV TAPS[SI],0
LEASE_FRESH:
    ; Prefer a queued tap over held direction for this frame, then consume it.
    MOV AL,HELD[SI]
    CMP TAPS[SI],0
    JE LEASE_SAVE
    MOV AL,TAPS[SI]
    MOV TAPS[SI],0
LEASE_SAVE:
    ; Publish the leased direction into DIRECTIONS for the core intent builder.
    MOV DIRECTIONS[SI],AL
LEASE_NEXT:
    ; After every slot, phase 2 performs intents, collision resolution, commit
    ; and proximity warnings. Lobby/results skip game motion.
    INC SI
    CMP SI,8
    JB LEASE_PLAYER
    CMP PHASE,2
    JNE GAME_DONE
    CALL BUILD_INTENTS
    CALL RESOLVE_MOVES
    CALL COMMIT_MOVES
    CALL UPDATE_WARNINGS
    XOR SI,SI
CHECK_REMAINING:
    ; If no slot remains racing, enter results phase and choose winners only
    ; from finishers. A race with only DNF outcomes can have no winner bits.
    CMP PLAYER_STATE[SI],1
    JE GAME_DONE
    INC SI
    CMP SI,8
    JB CHECK_REMAINING
    MOV PHASE,3
    CALL FIND_WINNERS
GAME_DONE:
    ; Return to serial flushing/rendering without waiting for the next tick.
    RET
GAME_TICK ENDP
START_RACE PROC NEAR
    ; Only lobby with at least two participants can start. Require every
    ; nonempty slot to be ready, then enter phase 2 and reset race/frame timers.
    CMP PHASE,1
    JNE START_DONE
    CMP PLAYER_COUNT,2
    JB START_DONE
    XOR SI,SI
START_CHECK:
    ; Empty slots do not need readiness; any occupied unready slot aborts start.
    CMP PLAYER_STATE[SI],0
    JE START_NEXT
    CMP READY[SI],0
    JE START_DONE
START_NEXT:
    ; After all eight slots pass, initialize the common race clock to zero.
    INC SI
    CMP SI,8
    JB START_CHECK
    MOV PHASE,2
    MOV WORD PTR ELAPSED_TICKS,0
    MOV WORD PTR ELAPSED_TICKS+2,0
    MOV WORD PTR ELAPSED_TENTHS,0
    MOV WORD PTR ELAPSED_TENTHS+2,0
    MOV FRAME_TICKS,0
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
