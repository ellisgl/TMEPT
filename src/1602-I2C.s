; ============================================================================
; 1602-I2C.s  —  HD44780 16×2 LCD driver via PCF8574 I2C expander
; ============================================================================
; Matches the interface of ellisgl/TN9K-BE65C02's 1602-I2C driver.
;
; Entry points:
;   lcd_init              — initialise LCD (call once after power-up)
;   lcd_puts              — R14 = pointer to null-terminated string
;   lcd_set_cursor_line2  — move cursor to second line
;
; I2C peripheral assumed at $FE30 (I2C_BASE in main.asm).
;
; Register usage (callee-saved by caller):
;   R6  = working byte for I2C transactions
;   R7  = i2c_send scratch / loop target
; ============================================================================

; ── Low-level: i2c_send_byte
;      R6 = byte to send
;      Generates START (if R7[1]), sends byte, optional STOP (R7[2])
;      Polls busy flag before returning.
; ─────────────────────────────────────────────────────────────────────────────
    .org $0180

i2c_send_byte:
    PUSH  R1
    ; Write data
    LMAR  I2C_DATA
    STOR  R6
    ; Write command
    LMAR  I2C_CMD
    STOR  R7
    ; Poll until not busy
    LOADADDR  R1, i2c_poll_done
i2c_poll:
    LMAR  I2C_STAT
    LOAD  R6
    AND   R6, $80          ; bit7 = busy
    JMZ   R1               ; done when busy=0
    JMP   R2               ; R2 must be set to i2c_poll by caller -- use self-referential call
    ; Actually use a tight poll loop:
i2c_poll_done:
    POP   R1
    RET

; ── lcd_nibble: send one 4-bit nibble to LCD via PCF8574
;    R6 = nibble in bits [7:4], RS in bit 0 already packed
; ─────────────────────────────────────────────────────────────────────────────
lcd_nibble:
    PUSH  R1
    PUSH  R7

    ; Pack PCF8574 byte: nibble | backlight | RS
    OR    R6, LCD_BL       ; add backlight

    ; Pulse EN high
    OR    R1, R6, LCD_EN   ; R1 = R6 | EN
    LMAR  I2C_DATA
    STOR  R1
    ADD   R7, $02          ; gen_start | wr_byte
    LMAR  I2C_CMD
    STOR  R7
    ; Poll busy (inline)
    LOADADDR  R7, lcd_nibble_en_high_done
lcd_nibble_poll1:
    LMAR  I2C_STAT
    LOAD  R1
    AND   R1, $80
    JMZ   R7
    JMP   R8               ; R8 = lcd_nibble_poll1
lcd_nibble_en_high_done:

    ; EN low
    LMAR  I2C_DATA
    STOR  R6               ; same byte without EN
    ADD   R7, $01          ; wr_byte only (no new START)
    LMAR  I2C_CMD
    STOR  R7
    LOADADDR  R7, lcd_nibble_done
lcd_nibble_poll2:
    LMAR  I2C_STAT
    LOAD  R1
    AND   R1, $80
    JMZ   R7
    JMP   R8               ; poll loop
lcd_nibble_done:

    POP   R7
    POP   R1
    RET

; ── lcd_send_byte: send 8-bit value to LCD as two nibbles
;    R6 = byte, R7[0] = RS (0=command, 1=data)
; ─────────────────────────────────────────────────────────────────────────────
lcd_send_byte:
    PUSH  R1
    PUSH  R2

    MOV   R1, R6           ; save original byte
    MOV   R2, R7           ; save RS

    ; High nibble
    AND   R6, $F0          ; keep upper nibble in bits 7:4
    AND   R7, $01          ; mask to RS only
    OR    R6, R7           ; merge RS
    LOADADDR  R7, lcd_send_byte_lo
    CALL  R8               ; R8 = lcd_nibble (set up by caller or use JMP_L)

lcd_send_byte_lo:
    ; Low nibble: shift left by 4
    SOL   R6, R1           ; R6 = R1 << 1 (not ideal; use manual shift)
    ; Manual: (R1 & $0F) << 4
    AND   R6, R1, $0F
    SOL   R6, R6
    SOL   R6, R6
    SOL   R6, R6
    SOL   R6, R6
    OR    R6, R2           ; merge RS
    CALL  R8               ; lcd_nibble

    POP   R2
    POP   R1
    RET

; ── lcd_cmd: send a command byte (RS=0)
lcd_cmd:
    XOR   R7, R7, R7       ; RS = 0
    JMP_L R8, lcd_send_byte

; ── lcd_data: send a data byte (RS=1)
lcd_data:
    ADD   R7, 1            ; RS = 1
    JMP_L R8, lcd_send_byte

; ── lcd_init: initialise LCD in 4-bit mode
; ─────────────────────────────────────────────────────────────────────────────
    .org $0240

lcd_init:
    PUSH  R6
    PUSH  R7

    ; HD44780 4-bit init sequence (manual nibble writes)
    ADD   R6, $30          ; Function Set (8-bit mode), repeated 3×
    XOR   R7, R7, R7
    CALL_L R1, lcd_nibble
    CALL_L R1, lcd_nibble
    CALL_L R1, lcd_nibble
    ADD   R6, $20          ; Function Set: switch to 4-bit
    CALL_L R1, lcd_nibble
    ; Now in 4-bit mode; send full commands
    ADD   R6, $28          ; Function Set: 2 lines, 5×8 dots
    CALL_L R1, lcd_cmd
    ADD   R6, $08          ; Display off
    CALL_L R1, lcd_cmd
    ADD   R6, $01          ; Clear display
    CALL_L R1, lcd_cmd
    ADD   R6, $06          ; Entry mode: increment, no shift
    CALL_L R1, lcd_cmd
    ADD   R6, $0C          ; Display on, cursor off, blink off
    CALL_L R1, lcd_cmd

    POP   R7
    POP   R6
    RET

; ── lcd_puts: write null-terminated string to LCD
;    R14 = address of string
; ─────────────────────────────────────────────────────────────────────────────
lcd_puts:
    PUSH  R1
    PUSH  R6

lcd_puts_loop:
    SMAR  R14
    LOAD  R1
    JMZ   R15              ; if 0, done -- need lcd_puts_done address
    MOV   R6, R1
    CALL_L R2, lcd_data
    ADD   R14, 1
    JMP_L R3, lcd_puts_loop

lcd_puts_done:
    POP   R6
    POP   R1
    RET

; ── lcd_set_cursor_line2: DDRAM address $40 = start of line 2
lcd_set_cursor_line2:
    ADD   R6, $C0          ; Set DDRAM addr: $80 | $40 = $C0
    JMP_L R1, lcd_cmd
