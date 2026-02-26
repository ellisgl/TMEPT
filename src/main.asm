; ============================================================================
; main.asm  —  TMEPT CPU / Tang Nano 9K  —  6551 ACIA + 6522 VIA demo
; ============================================================================
;
; Hardware:
;   6551 ACIA  $5000-$5003   serial UART via BL702 USB bridge
;   6522 VIA   $6000-$600F   GPIO + Timer 1 interrupt
;     Port A:  PA0=CS(out)  PA1=MOSI(out)  PA2=SCK(out)  PA3=MISO(in)
;              PA4-PA7 spare outputs
;     Port B:  PB0-PB7 outputs, driven with BLINK_CTR value
;
; What this does:
;   1. Reset and configure ACIA (19200 8N1)
;   2. Configure VIA Port A/B directions and Timer 1 free-run (~33 ms period)
;   3. Enable Timer 1 IRQ
;   4. Send "TMEPT CPU ready.\r\n" over serial
;   5. Main loop: whenever IRQ increments BLINK_CTR, write it to Port B
;
; ── Address loading ───────────────────────────────────────────────────────────
; LOADADDR only loads the low byte of an address (assembler limitation).
; The LOADDR macro below loads a full 16-bit address using lo()/hi() byte
; extraction and 8 x SOL (1-bit left shift) to position the high byte.
; R15 is reserved as the high-byte scratch register inside LOADDR.
; Never use R15 as the destination register for LOADDR.
; ============================================================================

; ── 6551 ACIA registers ───────────────────────────────────────────────────────
ACIA_DATA   = $5000     ; [W] Transmit  /  [R] Receive
ACIA_RST    = $5001     ; [W] Programmed reset (any write)
ACIA_STATUS = $5002     ; [R] Status
ACIA_CMD    = $5002     ; [W] Command  (same address, different R/W)
ACIA_CTRL   = $5003     ; [R/W] Control

; Status bits
ACIA_TDRE   = $10       ; bit4  Transmitter Data Register Empty
ACIA_RDRF   = $08       ; bit3  Receiver Data Register Full

; Control register value: 19200 baud, 8 data bits, 1 stop bit
;   bits[3:0] = 0b1111  = baud 19200 from internal baud-rate gen
;   bit[4]    = 0       = baud-rate generator clock source
;   bits[6:5] = 0b10    = 8 data bits
;   bit[7]    = 0       = 1 stop bit
ACIA_CTRL_VAL = 0b01001111

; Command register value: DTR active, TX enabled, no RX IRQ
;   bits[1:0] = 0b11    = DTR active, receiver IRQ disabled
;   bit[2]    = 0       = RTS low, no TX IRQ
;   bit[3]    = 1       = normal TX
;   bits[7:4] = 0b0000  = no parity
ACIA_CMD_VAL  = 0b00001011

; ── 6522 VIA registers ────────────────────────────────────────────────────────
VIA_ORB     = $6000
VIA_ORA     = $6001
VIA_DDRB    = $6002
VIA_DDRA    = $6003
VIA_T1CL    = $6004     ; read clears Timer 1 IRQ flag
VIA_T1CH    = $6005     ; write starts Timer 1
VIA_T1LL    = $6006
VIA_T1LH    = $6007
VIA_ACR     = $600B
VIA_IFR     = $600D
VIA_IER     = $600E

; VIA interrupt bits
VIA_IRQ_T1  = $40       ; bit6  Timer 1
VIA_IER_SET = $80       ; bit7 must be 1 to set IER bits
VIA_ACR_T1FR = $40      ; ACR: Timer 1 free-run mode

; Timer 1 reload for ~33 ms at 1 929 000 Hz
;   1929000 / 30 = 64300 = $FB2C
T1_LO       = $2C
T1_HI       = $FB

; ── RAM scratch ───────────────────────────────────────────────────────────────
BLINK_CTR   = $8000     ; incremented each Timer 1 IRQ
LAST_BLINK  = $8001     ; last value seen in main loop

; ── LOADDR macro ──────────────────────────────────────────────────────────────
; Load a 16-bit address constant into register dst.
; Clobbers R15 as high-byte scratch.  dst must NOT be R15.
.macro LOADDR dst, addr
    XOR   \dst, \dst, \dst
    ADD   \dst, lo(\addr)
    XOR   R15, R15, R15
    ADD   R15, hi(\addr)
    SOL   R15, R15
    SOL   R15, R15
    SOL   R15, R15
    SOL   R15, R15
    SOL   R15, R15
    SOL   R15, R15
    SOL   R15, R15
    SOL   R15, R15
    OR    \dst, \dst, R15
.endm

; ── Vectors ───────────────────────────────────────────────────────────────────
    .org  $FFFA
    .word irq_handler
    .word main

; ============================================================================
; main
; ============================================================================
    .org  $0000

main:
    ; ── Reset ACIA ────────────────────────────────────────────────────────────
    LMAR  ACIA_RST
    XOR   R1, R1, R1
    STOR  R1

    ; ── Configure ACIA ────────────────────────────────────────────────────────
    LMAR  ACIA_CTRL
    XOR   R1, R1, R1
    ADD   R1, ACIA_CTRL_VAL
    STOR  R1

    LMAR  ACIA_CMD
    XOR   R1, R1, R1
    ADD   R1, ACIA_CMD_VAL
    STOR  R1

    ; ── VIA Port A: PA0-PA2, PA4-PA7 outputs; PA3 input (MISO) ────────────────
    ; DDRA = $F7 = 11110111
    LMAR  VIA_DDRA
    XOR   R1, R1, R1
    ADD   R1, $F7
    STOR  R1

    ; PA0 high = CS deasserted
    LMAR  VIA_ORA
    XOR   R1, R1, R1
    ADD   R1, $01
    STOR  R1

    ; ── VIA Port B: all outputs, start at 0 ───────────────────────────────────
    LMAR  VIA_DDRB
    XOR   R1, R1, R1
    ADD   R1, $FF
    STOR  R1

    LMAR  VIA_ORB
    XOR   R1, R1, R1
    STOR  R1

    ; ── VIA Timer 1: free-run mode ────────────────────────────────────────────
    LMAR  VIA_ACR
    XOR   R1, R1, R1
    ADD   R1, VIA_ACR_T1FR
    STOR  R1

    LMAR  VIA_T1LL
    XOR   R1, R1, R1
    ADD   R1, T1_LO
    STOR  R1

    LMAR  VIA_T1LH
    XOR   R1, R1, R1
    ADD   R1, T1_HI
    STOR  R1

    ; Write T1CH: load counter from latch and start
    LMAR  VIA_T1CH
    XOR   R1, R1, R1
    ADD   R1, T1_HI
    STOR  R1

    ; ── Enable Timer 1 IRQ ────────────────────────────────────────────────────
    LMAR  VIA_IER
    XOR   R1, R1, R1
    ADD   R1, VIA_IER_SET | VIA_IRQ_T1
    STOR  R1

    ; ── Initialise RAM ────────────────────────────────────────────────────────
    LMAR  BLINK_CTR
    XOR   R1, R1, R1
    STOR  R1
    LMAR  LAST_BLINK
    STOR  R1

    ; ── Send banner ───────────────────────────────────────────────────────────
    ; R12 = char pointer   R13 = uart_tx_char address
    LOADDR  R12, banner
    LOADDR  R13, uart_tx_char

banner_loop:
    SMAR  R12
    LOAD  R1                  ; R1 = byte at R12
    LOADDR  R14, main_loop
    JMZ   R14                 ; null terminator -> enter main loop
    CALL  R13                 ; send byte via ACIA
    ADD   R12, 1
    LOADDR  R14, banner_loop
    JMP   R14

; ============================================================================
; main_loop
; ============================================================================
main_loop:
    LMAR  BLINK_CTR
    LOAD  R2
    LMAR  LAST_BLINK
    LOAD  R3
    CMP   R2, R3
    LOADDR  R8, main_loop
    JMZ   R8                  ; no change -> spin

    ; Changed: save and drive Port B
    LMAR  LAST_BLINK
    STOR  R2
    LMAR  VIA_ORB
    STOR  R2
    LOADDR  R8, main_loop
    JMP   R8

; ============================================================================
; uart_tx_char  — send one byte via ACIA
;   Entry:  R1 = byte to send
;   Clobbers R2, R3 (R2 saved/restored via stack)
; ============================================================================
    .org  $0080

uart_tx_char:
    PUSH  R2
tx_poll:
    LMAR  ACIA_STATUS
    LOAD  R2
    AND   R2, ACIA_TDRE       ; 2-op immediate: R2 = R2 & $10
    LOADDR  R3, tx_poll
    JMZ   R3                  ; TDRE=0 -> busy, keep polling
    LMAR  ACIA_DATA
    STOR  R1
    POP   R2
    RET

; ============================================================================
; irq_handler  — services VIA Timer 1 IRQ
;   Increments BLINK_CTR, clears T1 flag by reading VIA_T1CL.
; ============================================================================
    .org  $00C0

irq_handler:
    PUSH  R1
    PUSH  R2

    ; Check IFR for Timer 1 (bit6)
    LMAR  VIA_IFR
    LOAD  R1
    MOV   R2, R1              ; copy IFR value
    AND   R2, VIA_IRQ_T1       ; R2 = R2 & $40  (2-op immediate)
    LOADDR  R3, irq_done
    JMZ   R3                  ; not Timer 1 -> done

    ; Clear Timer 1 flag: reading T1CL does it
    LMAR  VIA_T1CL
    LOAD  R2

    ; Increment BLINK_CTR
    LMAR  BLINK_CTR
    LOAD  R1
    ADD   R1, 1
    STOR  R1

irq_done:
    POP   R2
    POP   R1
    RET

; ============================================================================
; String data
; ============================================================================
    .org  $0200

banner:                         ; "TMEPT CPU ready.\r\n\0"
    .byte  $54, $4D, $45, $50, $54, $20, $43, $50
    .byte  $55, $20, $72, $65, $61, $64, $79, $2E
    .byte  $0D, $0A, $00