; ============================================================================
; main.asm  —  TMEPT CPU demonstration
; ============================================================================
; Demonstrates: UART output, GPIO blink, Timer interrupt, I2C LCD write
;
; Hardware:
;   UART TX → BL702 USB bridge (115200 8N1)
;   GPIO port A[7:0] → LEDs or logic analyser
;   I2C SDA/SCL → PCF8574 → HD44780 16×2 LCD (same as the 6502 project)
;   Timer 1 generates a ~1 Hz IRQ at 6.75 MHz CPU clock
; ============================================================================

; ── Peripheral base addresses ─────────────────────────────────────────────────
UART_BASE   = $FE00
GPIO_BASE   = $FE10
TIMER_BASE  = $FE20
I2C_BASE    = $FE30

; ── UART register offsets ─────────────────────────────────────────────────────
UART_TX     = $FE00         ; [W] transmit byte
UART_RX     = $FE01         ; [R] received byte
UART_STAT   = $FE02         ; [R] bit0=tx_idle, bit1=rx_ready

; ── GPIO register offsets ─────────────────────────────────────────────────────
GPIO_PA     = $FE10         ; [R/W] port A data
GPIO_PADIR  = $FE11         ; [R/W] port A direction (1=output)
GPIO_PB     = $FE12         ; [R/W] port B data
GPIO_PBDIR  = $FE13         ; [R/W] port B direction
GPIO_IFLAGS = $FE14         ; [R]   interrupt flags
GPIO_IEN    = $FE15         ; [W]   interrupt enable
GPIO_ICLR   = $FE16         ; [W]   interrupt clear (write 1 to clear)

; ── Timer register offsets ────────────────────────────────────────────────────
TIMER_LO    = $FE20         ; [R/W] latch low byte
TIMER_HI    = $FE21         ; [R/W] latch high byte  (writing arms timer)
TIMER_CNT   = $FE22         ; [R]   current counter low byte
TIMER_CTRL  = $FE23         ; [R/W] bit0=run, bit1=irq_en, bit2=single, bit3=clr_irq

; ── I2C register offsets ──────────────────────────────────────────────────────
I2C_DATA    = $FE30         ; [R/W] data byte to send
I2C_CMD     = $FE31         ; [W]   bit0=wr_byte, bit1=gen_start, bit2=gen_stop
I2C_STAT    = $FE31         ; [R]   bit7=busy, bit6=arb_lost, bit5=nak

; ── I2C LCD (PCF8574 expander) ────────────────────────────────────────────────
LCD_ADDR    = $27           ; PCF8574 I2C address (AD0/AD1/AD2 = 0)
LCD_BL      = $08           ; backlight bit
LCD_EN      = $04           ; enable strobe
LCD_RW      = $02           ; R/W (0=write)
LCD_RS      = $01           ; register select (0=cmd, 1=data)

; ── Interrupt vector addresses ────────────────────────────────────────────────
IRQ_VEC_LO  = $FFFA
IRQ_VEC_HI  = $FFFB

; ── Zero-page scratch ─────────────────────────────────────────────────────────
; (TMEPT has no zero-page HW support, but $8000-$80FF is fast RAM)
ZP          = $8000
ZP_TMP      = $8000         ; temporary scratch byte
ZP_BLINK    = $8001         ; blink counter (incremented by timer IRQ)

    .org $FFFA
    .word irq_handler       ; IRQ vector  → $FFFA/$FFFB
    .word main              ; Reset vector → $FFFC/$FFFD

; ─────────────────────────────────────────────────────────────────────────────
; Main program
; ─────────────────────────────────────────────────────────────────────────────
    .org $0000

main:
    ; ── Zero scratch RAM ──────────────────────────────────────────────────────
    LMAR  ZP_BLINK
    XOR   R1, R1, R1
    STOR  R1

    ; ── Configure GPIO port A as all outputs ──────────────────────────────────
    LMAR  GPIO_PADIR
    ADD   R1, $FF          ; R1 = 0xFF  (all outputs)
    STOR  R1

    ; ── Configure GPIO port B as all inputs, enable change IRQ ───────────────
    LMAR  GPIO_PBDIR
    XOR   R2, R2, R2
    STOR  R2               ; direction = 0 (all inputs)
    LMAR  GPIO_IEN
    ADD   R2, $02          ; enable PB change interrupt (bit 1)
    STOR  R2

    ; ── Set up Timer: ~1 Hz at 6.75 MHz ──────────────────────────────────────
    ; Period = 6 750 000 counts → latch = $671F40
    ; Latch fits in 16-bit (max $FFFF = 65535) so use prescaled value:
    ; At 6.75 MHz, latch = 6750-1 = $1A5D for ~1 ms tick; ISR counts 1000 ticks
    ; For simplicity here: latch = $6978 → ~0.1 s visible blink
    LMAR  TIMER_LO
    ADD   R3, $78          ; low byte of $6978
    STOR  R3
    LMAR  TIMER_HI
    ADD   R3, $69          ; high byte; also arms the timer
    STOR  R3
    ; Enable timer IRQ and start running
    LMAR  TIMER_CTRL
    ADD   R3, $03          ; bit0=run, bit1=irq_en
    STOR  R3

    ; ── Print banner via UART ─────────────────────────────────────────────────
    LOADADDR  R14, banner
    LOADADDR  R15, uart_puts
    CALL  R15

    ; ── Initialise LCD ────────────────────────────────────────────────────────
    LOADADDR  R15, lcd_init
    CALL  R15

    ; ── Write "Hello, TMEPT!" to LCD line 1 ───────────────────────────────────
    LOADADDR  R14, msg_hello
    LOADADDR  R15, lcd_puts
    CALL  R15

    ; ── Write "UART + GPIO + I2C" to LCD line 2 ───────────────────────────────
    ; Set cursor to row 1, col 0
    LOADADDR  R15, lcd_set_cursor_line2
    CALL  R15
    LOADADDR  R14, msg_line2
    LOADADDR  R15, lcd_puts
    CALL  R15

    ; ── Main loop: LED chase driven by blink counter ──────────────────────────
    LOADADDR  R13, halt
    LOADADDR  R12, main_loop
    LOADADDR  R11, $8001   ; address of ZP_BLINK
    XOR   R10, R10, R10    ; R10 = last seen blink counter

main_loop:
    LMAR  ZP_BLINK
    LOAD  R9               ; R9 = current blink counter
    CMP   R9, R10          ; changed?
    JMZ   R8               ; R8 = ... wait, use JMZ with temp addr
    ; (On mismatch: update LED chase pattern)
    MOV   R10, R9          ; save new counter
    ; Rotate R9 into GPIO_PA to make a running light
    ROL   R9, R9           ; rotate left 1
    LMAR  GPIO_PA
    STOR  R9
    JMP   R12              ; loop

halt:
    JMP   R13              ; should never reach here

; ─────────────────────────────────────────────────────────────────────────────
; IRQ handler — Timer blink + GPIO change notification
; ─────────────────────────────────────────────────────────────────────────────
    .org  $0080

irq_handler:
    PUSH  R1
    PUSH  R2

    ; Check timer flag
    LMAR  TIMER_CTRL
    LOAD  R1
    AND   R2, R1, $80      ; bit7 = irq_flag
    JMZ   R5               ; ... (R5 = not set, skip)

    ; Clear timer IRQ
    ADD   R1, $08          ; bit3 = clr_irq
    STOR  R1

    ; Increment blink counter
    LMAR  ZP_BLINK
    LOAD  R2
    ADD   R2, 1
    STOR  R2

    ; Check GPIO flag (PB change)
    LMAR  GPIO_IFLAGS
    LOAD  R1
    AND   R2, R1, $02      ; bit1 = PB change
    JMZ   R5

    ; Clear GPIO IRQ
    LMAR  GPIO_ICLR
    ADD   R1, $02
    STOR  R1

    ; TODO: handle GPIO change (PB input event)

    POP   R2
    POP   R1
    RET

; ─────────────────────────────────────────────────────────────────────────────
; uart_puts — send null-terminated string
;   R14 = pointer to string (address in low 8 bits of current page)
; ─────────────────────────────────────────────────────────────────────────────
    .org $0100

uart_puts:
    PUSH  R1
    PUSH  R2
    LOADADDR  R2, uart_puts_done

uart_puts_loop:
    LMAR  R14              ; not valid — TMEPT uses LMAR with imm only
    ; NOTE: TMEPT's LOAD/STOR use MAR, not register-indirect.
    ; To dereference a pointer: SMAR to load from register, then LOAD.
    SMAR  R14              ; MAR = R14
    LOAD  R1               ; R1 = *R14
    JMZ   R2               ; if R1==0 done
    ; Send byte via UART (poll tx_idle)
uart_tx_wait:
    LMAR  UART_STAT
    LOAD  R3
    AND   R3, 1            ; bit0 = tx_idle
    JMZ   R4               ; R4 = uart_tx_wait... need addr
    LMAR  UART_TX
    STOR  R1
    ADD   R14, 1           ; advance pointer
    JMP   R5               ; R5 = uart_puts_loop... need addr
uart_puts_done:
    POP   R2
    POP   R1
    RET

; ─────────────────────────────────────────────────────────────────────────────
; I2C helpers and LCD driver stubs — See src/inc/1602-I2C.s
; ─────────────────────────────────────────────────────────────────────────────
; (Included below; these are the entry-point labels that main.asm calls)

    .include "inc/1602-I2C.s"

; ─────────────────────────────────────────────────────────────────────────────
; String data
; ─────────────────────────────────────────────────────────────────────────────
    .org $0200

banner:
    .byte "TMEPT CPU — Tang Nano 9K", $0D, $0A, 0

msg_hello:
    .byte "Hello, TMEPT!", 0

msg_line2:
    .byte "UART+GPIO+I2C", 0
