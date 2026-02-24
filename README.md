# TMEPT — 8-Bit CPU

A synthesisable, educational 8-bit CPU written in Verilog. Built around a two-stage
Fetch / Execute pipeline with a 16-register file, a 62-opcode instruction set, a
6502-style reset vector, and a 16-entry hardware stack with `PUSH`, `POP`, `CALL`,
and `RET` instructions.

---

## Features

| | |
|---|---|
| Data width | 8-bit ALU, 16-bit registers and address bus |
| Address space | 64 KB instruction memory + 64 KB data memory (Harvard) |
| Registers | R0–R15 (R0 hardwired to 0), 5-bit FLAGS |
| Opcodes | 62 (0x00–0x3E, with gaps) |
| Pipeline | 2-stage: Fetch + Execute |
| Stack | 16 × 16-bit hardware stack, full-descending, dedicated 4-bit SP |
| Reset vector | 6502-style — PC loaded from `imem[0xFFFC/0xFFFD]` on reset |

---

## Repository Layout

```
rtl/
  cpu.v           Top-level: wires fetch + execute, exposes memory ports
  fetch.v         7-state FSM: RST0/RST1 vector read, W0–W3 accumulation, DONE
  execute.v       Pipeline register, ALU dispatch, flags, MAR, writeback, stack
  decode.v        Combinational opcode decoder
  alu.v           ALU top-level dispatcher
  alu_arith.v     Arithmetic operations (ADD, SUB, ADC, SBC, CMP)
  alu_shift.v     Shift and rotate operations
  alu_bitmanip.v  Bit manipulation operations
  reg_file.v      16 × 16-bit register file, 4 read ports, 2 write ports

tb/
  cpu_tb.v        End-to-end integration testbench (5 programs, 12 checks)
  execute_tb.v    Execute stage directed tests
  alu_tb.v        ALU unit tests
  reg_file_tb.v   Register file unit tests
  decode_tb.v     Decode unit tests
  fetch_tb.v      Fetch FSM unit tests
```

---

## Quick Start

```bash
# Run the full integration suite (requires iverilog)
iverilog -o cpu_tb tb/cpu_tb.v && vvp cpu_tb

# Run a specific unit testbench
iverilog -o alu_tb tb/alu_tb.v && vvp alu_tb
```

All 12 integration checks pass. The five programs exercised are:

1. **Sum 1..5** — loop, decrement, conditional branch
2. **Memory round-trip** — STOR to dmem, LOAD back, verify
3. **Fibonacci** — F6 = 8, F7 = 13
4. **Reset vector** — code placed at 0x0200, confirm CPU fetches from there
5. **Stack operations** — PUSH × 2, CALL, subroutine body, RET, POP × 2

---

## Instruction Set Summary

| Group | Opcodes | Examples |
|---|---|---|
| Arithmetic | 0x00–0x09 | `ADD`, `SUB`, `ADC`, `SBC`, `CMP` |
| Shift / Rotate | 0x0A–0x11 | `ROL`, `ROR`, `SOL`, `SOR`, `SZL`, `SZR` |
| Bit Manipulation | 0x12–0x25 | `INV`, `REV`, `IFB`, `ILB` |
| Data Movement | 0x2D–0x33 | `MOV`, `LOAD`, `STOR`, `LMAR`, `SMAR`, `IMAR`, `DMAR` |
| Branches | 0x26–0x2C, 0x38–0x3A | `JMP`, `JMZ`, `JMN`, `JMG`, `JNE`, `JGE`, `JLE` … |
| Compound | 0x34–0x37 | `ALE`, `DJN`, `SLE`, `SJN` |
| **Stack** | **0x3B–0x3E** | **`PUSH`, `POP`, `CALL`, `RET`** |

All branches are register-indirect — the 16-bit target address is read from a register.

### Stack Instructions

```
PUSH Rs   stack[SP] = Rs (16-bit);  SP--
POP  Rd   Rd = stack[SP+1];  SP++        (result available next cycle)
CALL Rt   stack[SP--] = return_addr;  PC = Rt
RET       PC = stack[SP+1];  SP++        (branch fires next cycle)
```

SP is a dedicated 4-bit hardware register — it is not part of R0–R15 and cannot
be read or written by ALU instructions.

---

## Pipeline

```
Fetch FSM states:   RST0 → RST1 → W0 → W1 → [W2 → W3] → DONE
                    ↑ reset vector   ↑ 1–4 byte accumulation

Execute stages:     clk1: latch instr_r, valid_r, pc_in_r
                    clk2: decode, ALU, flags, MAR, writeback, branch
                    clk3: (POP/RET only) register writeback / PC load
```

Every reset costs 2 extra cycles for the vector read (RST0 + RST1).
Taken branches flush the fetch accumulation and restart from W0.

---

## Known iverilog Quirks

Three simulator-specific issues were encountered and documented:

- **`for`-loop in async-reset blocks** — iverilog skips the reset clause entirely
  when a `for` loop is present. Fixed in `reg_file.v` by replacing the loop with
  15 explicit non-blocking assignments.

- **Dual `always` blocks with identical `negedge rst_n` sensitivity** — iverilog
  silences the second block. Fixed by merging all synchronous logic into one
  `always` block per module.

- **4-bit array index arithmetic** — `mem[sp + 1]` where `sp` is `reg [3:0]` causes
  iverilog to zero-extend `sp` to 32 bits. When `sp = 4'hF` the result is index 16,
  out of bounds on a `[0:15]` array. Fixed with `mem[sp + 4'h1]`.

---

## Reference Document

Full architecture and ISA details are in **`TMEPT_CPU_Reference.docx`** (Revision 1.3),
covering instruction encoding, pipeline timing, all 62 opcodes, stack operation,
reset vector mechanism, and implementation notes.
