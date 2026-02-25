; ============================================================================
; example.asm  –  TMEPT CPU demonstration program
; ----------------------------------------------------------------------------
; Demonstrates: constants, labels, macros, built-in macros, all instruction
; groups, the hardware stack, and subroutine calls.
;
; Assemble:
;   python3 tmept_asm.py example.asm -o example.bin -l example.lst
;
; Program summary:
;   1. Compute sum(1..5) using a DJN loop              → R2
;   2. Demonstrate bit-manipulation on the result      → R3
;   3. Call a subroutine (Fibonacci step) five times   → R4, R5
;   4. Write R2 to data memory and read it back        → R6
;   5. Halt (infinite loop)
;
; Memory layout:
;   $0000  main program
;   $0060  subroutine: fib_step
;   $FFFC  reset vector → $0000
; ============================================================================

; ── Constants ────────────────────────────────────────────────────────────────
COUNT      = 5             ; sum upper bound
DMEM_BASE  = $0010         ; data memory address for store/load demo

; ── Macros ───────────────────────────────────────────────────────────────────
; ZERO reg  –  clear a register (XOR with self)
.macro ZERO reg
    XOR  reg, reg, reg
.endm

; ── Reset vector ─────────────────────────────────────────────────────────────
    .org  $FFFC
    .word $8000            ; reset vector → main

; ─────────────────────────────────────────────────────────────────────────────
; Main program
; ─────────────────────────────────────────────────────────────────────────────
    .org  $8000

main:
    ; Load subroutine and halt addresses into registers
    LOADADDR  R7, fib_step     ; R7 = fib_step address
    LOADADDR  R8, halt         ; R8 = halt address

    ; Zero all working registers
    ZERO  R1
    ZERO  R2
    ZERO  R3
    ZERO  R4
    ZERO  R5
    ZERO  R6

    ; ── Section 1: sum(1..5) using DJN loop ──────────────────────────────
    ; R1 = loop counter (counts down from COUNT)
    ; R2 = running sum
    ; R3 = loop-top address
    ADD   R1, COUNT            ; R1 = 5
    LOADADDR  R3, sum_loop     ; R3 = address of loop top

sum_loop:
    ADD   R2, R1               ; R2 += R1  (2-address)
    DJN   R1, R3               ; R1--; jump back if R1 != 0
                               ; Result: R2 = 5+4+3+2+1 = 15

    ; ── Section 2: bit manipulation ──────────────────────────────────────
    MOV   R3, R2               ; R3 = 15 = $0F
    INV   R3                   ; R3 = ~$0F = $F0
    REV   R3                   ; R3 = reverse bits of R3

    ; ── Section 3: Fibonacci via subroutine calls ─────────────────────────
    ; Seed: R4 = 0 (F0), R5 = 1 (F1)
    ADD   R5, 1                ; R5 = 1
    CALL  R7                   ; fib_step → (R4=1, R5=1)
    CALL  R7                   ; → (R4=1,  R5=2)
    CALL  R7                   ; → (R4=2,  R5=3)
    CALL  R7                   ; → (R4=3,  R5=5)
    CALL  R7                   ; → (R4=5,  R5=8)

    ; ── Section 4: data memory round-trip ────────────────────────────────
    MOV   R6, R2               ; R6 = sum result (15)
    LMAR  DMEM_BASE            ; MAR = $0010
    STOR  R6                   ; dmem[$0010] = 15
    ZERO  R6                   ; clear R6
    LOAD  R6                   ; R6 = dmem[$0010] = 15

halt:
    JMP   R8                   ; infinite loop

; ─────────────────────────────────────────────────────────────────────────────
; Subroutine: fib_step
;   Entry:  R4 = a,  R5 = b
;   Exit:   R4 = b,  R5 = a + b
; ─────────────────────────────────────────────────────────────────────────────
    .org  $0060

fib_step:
    PUSH  R4                   ; save a
    ADD   R4, R5               ; R4 = a + b
    POP   R5                   ; R5 = old a
    PUSH  R4                   ; push new b
    MOV   R4, R5               ; R4 = old a (= prev b)
    POP   R5                   ; R5 = new b
    RET
