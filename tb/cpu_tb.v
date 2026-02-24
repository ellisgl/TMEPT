// ============================================================================
// cpu_tb.v     End-to-end testbench for cpu.v (fetch + execute integrated)
// ============================================================================
//
// Instantiates the full CPU with a flat 64KB instruction ROM and a 256-byte
// data RAM.  Three self-contained programs are loaded one at a time into
// instruction ROM and the CPU is reset between them.
//
// Programs
//                            
//  1. Sum 1..5 (loop)
//       R1 = 5  (counter, counts down)
//       R2 = 0  (accumulator)
//       loop: R2 += R1 ; R1 -= 1 ; if R1 != 0 goto loop
//       Expected: R2 = 15  (1+2+3+4+5)
//
//  2. Memory round-trip
//       LMAR 0x0010 ; STOR R3(=0xA5) ; LOAD R4 ; expect R4 == 0xA5
//
//  3. Fibonacci  (F0=0, F1=1,     F7=13)
//       Computes 8 Fibonacci numbers into R1..R8 using ADD 3-address
//
// Instruction encoding quick-reference (from decode.v comments)
//   Standard 3-byte:  {opc, 2'b00, dst[3:0], 2'b00, src1[3:0], src2[3:0], 8'h00}
//   Immediate 3-byte: {opc, 2'b10, dst[3:0], 2'b00, imm[7:0],  8'h00}
//   Memory  2-byte:   {opc, 2'b11, dst[3:0], 2'b00}  (fetch only takes 2 bytes)
//   LMAR    3-byte:   {opc, addr[15:8], addr[7:0], 8'h00}
//   Branch  2-byte:   {opc, 2'b00, tgt[3:0], 2'b00}  (fetch only takes 2 bytes)
//
// ============================================================================

`timescale 1ns/1ps

`include "rtl/cpu.v"

module cpu_tb;

    //        DUT signals                                                                                                                                                                                  
    reg         clk, rst_n;

    wire [15:0] imem_addr;
    reg  [7:0]  imem_data;

    wire [15:0] dmem_addr;
    reg  [7:0]  dmem_rd_data;
    wire [7:0]  dmem_wr_data;
    wire        dmem_wr_en;

    wire [15:0] pc;
    wire [4:0]  flags;
    wire [3:0]  cpu_sp;
    wire        cpu_stall;

    //        DUT instantiation                                                                                                                                                             
    cpu dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .imem_addr    (imem_addr),
        .imem_data    (imem_data),
        .dmem_addr    (dmem_addr),
        .dmem_rd_data (dmem_rd_data),
        .dmem_wr_data (dmem_wr_data),
        .dmem_wr_en   (dmem_wr_en),
        .pc           (pc),
        .flags        (flags),
        .cpu_sp       (cpu_sp),
        .cpu_stall    (cpu_stall)
    );

    //        Clock                                                                                                                                                                                                 
    initial clk = 0;
    always #5 clk = ~clk;

    //        Memories                                                                                                                                                                                        
    reg [7:0] imem [0:65535];   // 64 KB instruction ROM
    reg [7:0] dmem [0:255];     // 256-byte data RAM

    // Combinational instruction memory read
    always @(*) imem_data = imem[imem_addr];

    // Combinational data memory read
    always @(*) dmem_rd_data = dmem[dmem_addr[7:0]];

    // Synchronous data memory write
    always @(posedge clk)
        if (dmem_wr_en) dmem[dmem_addr[7:0]] <= dmem_wr_data;

    //        Scoreboard helpers                                                                                                                                                             
    integer pass_cnt, fail_cnt;

    task check;
        input [63:0]  id;
        input [31:0]  got, exp;
        input [479:0] label;
        begin
            if (got !== exp) begin
                $display("  FAIL [%0d] %s: got 0x%02h, exp 0x%02h", id, label, got, exp);
                fail_cnt = fail_cnt + 1;
            end else begin
                $display("  PASS [%0d] %s", id, label);
                pass_cnt = pass_cnt + 1;
            end
        end
    endtask

    //        Register-file peek via hierarchical reference                                                                            
    // reg_file is instantiated as 'rf' inside execute (instance 'u_execute')
    // inside cpu (instance 'dut').  regs[] is declared [1:15]; R0 is always 0.
    function [15:0] read_reg;
        input [3:0] addr;
        if (addr == 4'h0)
            read_reg = 16'h0000;
        else
            read_reg = dut.u_execute.rf.regs[addr];
    endfunction

    // Verilog-2001 does not allow bit-selects on function return values in
    // task arguments.  Use this helper to extract the low byte.
    function [7:0] reg8;
        input [3:0] addr;
        reg [15:0] tmp;
        begin
            tmp  = read_reg(addr);
            reg8 = tmp[7:0];
        end
    endfunction

    //        CPU reset helper                                                                                                                                                                
    task cpu_reset;
        begin
            rst_n = 0;
            repeat (4) @(posedge clk); #1;
            rst_n = 1;
        end
    endtask

    //        Run CPU for exactly n cycles then stop.                         
    task run_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
            #1;
        end
    endtask

    //        Instruction assembler helpers                                                                                                                            
    // Returns the byte array for each instruction format.

    // Write bytes into imem starting at 'base'; returns next free address.
    integer wptr;

    task wb; input [15:0] a; input [7:0] d; begin imem[a] = d; end endtask

    // Write the 6502-style reset vector at imem[0xFFFC/0xFFFD]
    task set_reset_vector;
        input [15:0] addr;
        begin
            imem[16'hFFFC] = addr[7:0];   // low  byte
            imem[16'hFFFD] = addr[15:8];  // high byte
        end
    endtask


    // Standard 3-byte: opc, {00,dst,00}, {src1,src2}, 00
    task emit_std;
        input [7:0] opc;
        input [3:0] dst, src1, src2;
        begin
            wb(wptr,   opc);
            wb(wptr+1, {2'b00, dst, 2'b00});
            wb(wptr+2, {src1, src2});
            wptr = wptr + 3;
        end
    endtask

    // Immediate 3-byte: opc, {10,dst,00}, imm, 00
    task emit_imm;
        input [7:0] opc;
        input [3:0] dst;
        input [7:0] imm;
        begin
            wb(wptr,   opc);
            wb(wptr+1, {2'b10, dst, 2'b00});
            wb(wptr+2, imm);
            wptr = wptr + 3;
        end
    endtask

    // Memory 2-byte: opc, {11,dst,00}
    task emit_mem;
        input [7:0] opc;
        input [3:0] dst;
        begin
            wb(wptr,   opc);
            wb(wptr+1, {2'b11, dst, 2'b00});
            wptr = wptr + 2;
        end
    endtask

    // LMAR 3-byte: 0x2E, addr_hi, addr_lo
    task emit_lmar;
        input [15:0] addr;
        begin
            wb(wptr,   8'h2E);
            wb(wptr+1, addr[15:8]);
            wb(wptr+2, addr[7:0]);
            wptr = wptr + 3;
        end
    endtask

    // Branch 2-byte: opc, {00,tgt,00}
    task emit_br;
        input [7:0] opc;
        input [3:0] tgt;
        begin
            wb(wptr,   opc);
            wb(wptr+1, {2'b00, tgt, 2'b00});
            wptr = wptr + 2;
        end
    endtask

    // Load a 16-bit address constant into a register pair via two immediate ADDs.
    // Uses R0 (hardwired 0) as base.  Clobbers flags.
    // NOTE: for 8-bit registers the cpu stores 8-bit values in the low byte.
    // For addresses held in registers we use two consecutive regs (hi, lo) or
    // simply load only the low byte since our test data memory fits in 8 bits.
    task emit_load_imm8;
        input [3:0] dst;
        input [7:0] val;
        begin
            // XOR dst,dst,dst      dst = 0
            emit_std(8'h08, dst, dst, dst);
            // ADD dst, #val        dst = val
            emit_imm(8'h00, dst, val);
        end
    endtask

    //        HALT pseudo-instruction: JMP to self (infinite loop)                                                    
    // We place R15=0 (R0) as the JMP target, but actually we store the
    // halt address in a dedicated register and jump there.
    // Simpler: emit JMP Rh where Rh holds the halt address.
    // We use a self-loop: the jump register holds the PC of the JMP instruction.
    // Handled per-program below.

    // PUSH Rs  (0x3B)
    task emit_push;
        input [3:0] rs;
        begin
            imem[wptr]   = 8'h3B;
            imem[wptr+1] = {2'b00, rs, 2'b00};
            wptr = wptr + 2;
        end
    endtask

    // POP Rd  (0x3C)
    task emit_pop;
        input [3:0] rd;
        begin
            imem[wptr]   = 8'h3C;
            imem[wptr+1] = {2'b00, rd, 2'b00};
            wptr = wptr + 2;
        end
    endtask

    // CALL Rt  (0x3D)
    task emit_call;
        input [3:0] rt;
        begin
            imem[wptr]   = 8'h3D;
            imem[wptr+1] = {2'b00, rt, 2'b00};
            wptr = wptr + 2;
        end
    endtask

    // RET  (0x3E) – no operand
    task emit_ret;
        begin
            imem[wptr]   = 8'h3E;
            imem[wptr+1] = 8'h00;
            wptr = wptr + 2;
        end
    endtask

    // =========================================================================
    // PROGRAM 1     Sum 1..5
    // =========================================================================
    // Register map:
    //   R1 = counter (5 down to 0)
    //   R2 = accumulator
    //   R3 = loop target register (holds address of loop top)
    //   R4 = constant 1 (for decrement)
    //
    // Layout (each instruction starts at the given byte offset):
    //   0x00  XOR R1,R1,R1          (3 bytes)     R1=0
    //   0x03  ADD R1,#5             (3 bytes)     R1=5
    //   0x06  XOR R2,R2,R2          (3 bytes)     R2=0
    //   0x09  XOR R4,R4,R4          (3 bytes)     R4=0
    //   0x0C  ADD R4,#1             (3 bytes)     R4=1
    //   0x0F  XOR R3,R3,R3          (3 bytes)     R3=0
    //   0x12  ADD R3,#0x15          (3 bytes)     R3=0x15 (loop start)
    //        loop top (0x15)      
    //   0x15  ADD R2,R2,R1 (3-addr) (3 bytes)     R2 += R1
    //   0x18  SUB R1,R1,R4 (3-addr) (3 bytes)     R1 -= 1
    //   0x1B  JMZ R3                (2 bytes)     if Z jump to R3 (past loop)
    //   0x1D  JMP R3                ... wait, we need to loop BACK not forward
    //
    // Revised: use two branch targets     R3=loop_top, R5=halt_addr
    //   0x0F  XOR R3,R3,R3          (3)     R3=0
    //   0x12  ADD R3,#0x15          (3)     R3 = loop_top = 0x15
    //   0x15        loop_top       
    //   0x15  ADD R2,R2,R1          (3)     R2 += R1
    //   0x18  SUB R1,R1,R4          (3)     R1 -= 1  (sets Z when R1 hits 0)
    //   0x1B  JMZ R5                (2)     if R1==0 break (jump to halt)
    //   0x1D  JMP R3                (2)     else loop back
    //         halt       
    //   0x1F  XOR R5,R5,R5          (3)     R5=0
    //   0x22  ADD R5,#0x25          (3)     R5=0x25 (halt addr)
    //
    // Problem: R5 must be initialised before the loop, but we need to know
    // the halt address to do so, which depends on instructions after the loop.
    // Simplest approach: emit all setup, record addresses, patch afterwards.
    //
    // Instead, use a fixed layout below.

    task load_prog1;
        integer loop_top;
        integer halt_addr;
        begin
            // Clear imem page 0
            begin : clr1
                integer i;
                for (i = 0; i < 256; i = i + 1) imem[i] = 8'hFF;
            end

            wptr = 0;

            //        Initialise registers                                                                                                                            
            emit_std(8'h08, 4'h1, 4'h1, 4'h1);  // 0x00: XOR R1,R1,R1     R1=0
            emit_imm(8'h00, 4'h1, 8'h05);        // 0x03: ADD R1,#5        R1=5
            emit_std(8'h08, 4'h2, 4'h2, 4'h2);  // 0x06: XOR R2,R2,R2     R2=0
            emit_std(8'h08, 4'h4, 4'h4, 4'h4);  // 0x09: XOR R4,R4,R4     R4=0
            emit_imm(8'h00, 4'h4, 8'h01);        // 0x0C: ADD R4,#1        R4=1

            // Load R3 = loop_top address = 0x15 (address of first loop instr)
            emit_std(8'h08, 4'h3, 4'h3, 4'h3);  // 0x0F: XOR R3,R3,R3
            emit_imm(8'h00, 4'h3, 8'h15);        // 0x12: ADD R3,#0x15

            //        Loop top (0x15)                                                                                                                                              
            loop_top = wptr;   // should be 0x15
            emit_std(8'h00, 4'h2, 4'h2, 4'h1);  // 0x15: ADD R2,R2,R1 (3-addr)
            emit_std(8'h02, 4'h1, 4'h1, 4'h4);  // 0x18: SUB R1,R1,R4 (3-addr)

            // Load R5 = halt address = 0x1F (byte after the two branch instrs)
            // Halt is at wptr+2+2+3+3 = wptr+10 = 0x18+3+2+2 = 0x1F
            // JMZ(2) + JMP(2) = 4 bytes, so halt = 0x18+3+4 = 0x1F
            emit_br(8'h27, 4'h5);                // 0x1B: JMZ R5 (if Z, break)
            emit_br(8'h26, 4'h3);                // 0x1D: JMP R3 (loop back)

            //        Halt (0x1F): load R5 = 0x25 then JMP R5                                                                
            // But R5 must be loaded before the loop! Chicken-and-egg.
            // Trick: emit halt FIRST with a NOP slot, then fix it up.
            //
            // Actual approach: the halt address is here (0x1F).  R5 must hold
            // 0x1F before we enter the loop.  So we emit the R5 init before
            // the loop     but we already used 0x0F   0x14 for R3 init.
            // So insert R5 init into the setup block and recalculate addresses.
            //
            // Re-layout with R5 init included in setup:
            //   0x00  XOR R1 (3) 0x03 ADD R1,#5 (3)
            //   0x06  XOR R2 (3) 0x09 XOR R4 (3) 0x0C ADD R4,#1 (3)
            //   0x0F  XOR R3 (3) 0x12 ADD R3,#? (3)
            //   0x15  XOR R5 (3) 0x18 ADD R5,#? (3)       new
            //   loop_top = 0x1B
            //     0x1B ADD R2,R2,R1 (3)
            //     0x1E SUB R1,R1,R4 (3)
            //     0x21 JMZ R5 (2)      R5 = halt_addr
            //     0x23 JMP R3 (2)      R3 = 0x1B
            //   halt_addr = 0x25
            //     0x25 JMP R6 (2)      R6 = 0x25 = self-loop
            //
            // This is getting complex with fixed-address patching. Let's just
            // emit the whole program in one go with known addresses and verify.
            //
            //           RESTART with proper fixed layout                                                                                     
            begin : blk_prog1
                integer j;
                for (j = 0; j < 256; j = j + 1) imem[j] = 8'hFF;
            end
            wptr = 16'h0000;

            //   0x00: XOR R1,R1,R1      R1=0
            emit_std(8'h08, 4'h1, 4'h1, 4'h1);
            //   0x03: ADD R1,#5         R1=5
            emit_imm(8'h00, 4'h1, 8'h05);
            //   0x06: XOR R2,R2,R2      R2=0
            emit_std(8'h08, 4'h2, 4'h2, 4'h2);
            //   0x09: XOR R4,R4,R4      R4=0
            emit_std(8'h08, 4'h4, 4'h4, 4'h4);
            //   0x0C: ADD R4,#1         R4=1
            emit_imm(8'h00, 4'h4, 8'h01);
            //   0x0F: XOR R3,R3,R3      R3=0  (R3 will hold loop_top=0x1B)
            emit_std(8'h08, 4'h3, 4'h3, 4'h3);
            //   0x12: ADD R3,#0x1B      R3=0x1B
            emit_imm(8'h00, 4'h3, 8'h1B);
            //   0x15: XOR R5,R5,R5      R5=0  (R5 will hold halt_addr=0x27)
            emit_std(8'h08, 4'h5, 4'h5, 4'h5);
            //   0x18: ADD R5,#0x27      R5=0x27
            emit_imm(8'h00, 4'h5, 8'h27);
            //        loop_top = 0x1B       
            //   0x1B: ADD R2,R2,R1 (3-addr 00 mode, dst=R2, src1=R2, src2=R1)
            emit_std(8'h00, 4'h2, 4'h2, 4'h1);
            //   0x1E: SUB R1,R1,R4      R1 -= 1
            emit_std(8'h02, 4'h1, 4'h1, 4'h4);
            //   0x21: JMZ R5            if Z, jump to halt (0x27)
            emit_br(8'h27, 4'h5);
            //   0x23: JMP R3            else loop back to 0x1B
            emit_br(8'h26, 4'h3);
            //        halt_addr = 0x25        
            // We said 0x27 above; 0x21+2+2=0x25 so halt is at 0x25 not 0x27.
            // Fix: recalculate. loop_top=0x1B, ADD(3)+SUB(3)+JMZ(2)+JMP(2)=10
            // halt = 0x1B + 10 = 0x25.  But we loaded R5=0x27. Need to fix R5
            // to 0x25.  The ADD R5,#? was at 0x18; the immediate byte is imem[0x1A].

            // Patch: recalculate halt_addr
            halt_addr = wptr;  // should be 0x25
            // Back-patch imem[0x1A] (immediate byte of ADD R5,#?) = halt_addr
            imem[16'h1A] = halt_addr[7:0];

            //   0x25: XOR R6,R6,R6      R6=0  (R6 will hold 0x25 for self-loop)
            emit_std(8'h08, 4'h6, 4'h6, 4'h6);
            //   0x28: ADD R6,#0x25      R6=0x25  (self-loop address = halt_addr)
            emit_imm(8'h00, 4'h6, 8'h25);
            //   0x2B: JMP R6            infinite loop (HALT)
            emit_br(8'h26, 4'h6);

            // Reset vector -> 0x0000 (program starts at beginning of ROM)
            set_reset_vector(16'h0000);
        end
    endtask

    // =========================================================================
    // PROGRAM 2     Memory round-trip
    // =========================================================================
    // Layout:
    //   0x00  XOR R3,R3,R3      (3) R3=0
    //   0x03  ADD R3,#0xA5      (3) R3=0xA5 (value to store)
    //   0x06  LMAR 0x0010       (3) MAR=0x10
    //   0x09  STOR R3           (2) dmem[0x10]=0xA5
    //   0x0B  LOAD R4           (2) R4=dmem[0x10]
    //   0x0D  XOR R5,R5,R5      (3) R5=0
    //   0x10  ADD R5,#0x13      (3) R5=0x13 (halt addr)
    //   0x13  JMP R5            (2)     halt (self-loop)
    //   0x15  JMP R5            (2)     halt  (pad     not reached)
    task load_prog2;
        begin
            begin : clr2
                integer i;
                for (i = 0; i < 256; i = i + 1) imem[i] = 8'hFF;
                for (i = 0; i < 256; i = i + 1) dmem[i] = 8'h00;
            end
            wptr = 0;

            emit_std(8'h08, 4'h3, 4'h3, 4'h3);  // 0x00 XOR R3,R3,R3
            emit_imm(8'h00, 4'h3, 8'hA5);        // 0x03 ADD R3,#0xA5
            emit_lmar(16'h0010);                  // 0x06 LMAR 0x0010
            emit_mem(8'h31, 4'h3);                // 0x09 STOR R3
            emit_mem(8'h30, 4'h4);                // 0x0B LOAD R4
            // Halt loop
            emit_std(8'h08, 4'h5, 4'h5, 4'h5);  // 0x0D XOR R5,R5,R5
            emit_imm(8'h00, 4'h5, 8'h13);        // 0x10 ADD R5,#0x13
            emit_br(8'h26, 4'h5);                 // 0x13 JMP R5     self

            // Reset vector -> 0x0000
            set_reset_vector(16'h0000);
        end
    endtask

    // =========================================================================
    // PROGRAM 3     Fibonacci  F(0..7) = 0,1,1,2,3,5,8,13
    // =========================================================================
    // Register map:  R1=F(n-2), R2=F(n-1), R3=F(n), R5=loop counter(6),
    //                R6=loop_top addr, R7=halt addr, R4=constant 1
    // Layout:
    //   0x00  XOR  R1,R1,R1         R1=0   (F0)
    //   0x03  XOR  R2,R2,R2         R2=0
    //   0x06  ADD  R2,#1            R2=1   (F1)
    //   0x09  XOR  R5,R5,R5         R5=0
    //   0x0C  ADD  R5,#6            R5=6   (loop 6 more Fibonacci steps)
    //   0x0F  XOR  R4,R4,R4         R4=0
    //   0x12  ADD  R4,#1            R4=1   (constant)
    //   0x15  XOR  R6,R6,R6         R6=0
    //   0x18  ADD  R6,#0x1E         R6=loop_top=0x1E
    //   0x1B  XOR  R7,R7,R7         R7=0
    //   0x1E... wait, need halt addr first. Recalculate:
    //
    // loop_top = 0x1E
    //   loop body:
    //   0x1E  ADD  R3,R1,R2     (3)     R3 = R1+R2
    //   0x21  ADD  R1,R2,R0     ... can't do R1=R2 with ADD. Use MOV or XOR+ADD.
    //         MOV is opcode 0x2D (3-byte, immediate mode: {0x2D, 10, dst, 00, imm, 00})
    //         but MOV moves an 8-bit immediate, not a register.
    //         Use: XOR R1,R1,R1 then ADD R1,R1,R2 (3-addr)?
    //         No, ADD R1,R1,R2 is 3-addr: dst=R1, src1=R1, src2=R2. Result = R1+R2.
    //         We want R1 = R2. So: SUB R1,R2,R0? R0=0 so R2-0=R2. YES.
    //         SUB R1,R2,R0 (3-addr): dst=R1, src1=R2, src2=R0     R1 = R2-0 = R2.    
    //   0x21  SUB  R1,R2,R0     (3)     R1 = R2
    //   0x24  SUB  R2,R3,R0     (3)     R2 = R3 = new F(n)
    //   0x27  SUB  R5,R5,R4     (3)     R5 -= 1 (sets Z when done)
    //   0x2A  JMZ  R7           (2)     if done, halt
    //   0x2C  JMP  R6           (2)     else loop
    //   halt_addr = 0x2E
    //   0x2E  JMP R7            (2)     self-loop (R7 must hold 0x2E)
    //
    // R6 init: ADD R6,#0x1E      R6=0x1E    
    // R7 init: need 0x2E.
    //   0x1B: XOR R7,R7,R7 (3)     R7=0
    //   0x1E: conflicts with loop_top!
    // Re-count setup bytes: 6 XOR/ADD pairs for R1,R2,R5,R4,R6 = 6*6=36=0x24 bytes.
    // Plus R7 init (6 bytes) = 0x2A. loop_top = 0x2A.
    //
    // Revised final layout:
    //   0x00 XOR R1 (3) 0x03 ADD R1,#0 (3)     R1=0 (F0)  [or just XOR, skip ADD]
    //   Use XOR alone for 0-init since we don't need an ADD for zero.
    //   0x00 XOR R1,R1,R1 (3)     R1=0
    //   0x03 XOR R2,R2,R2 (3)     R2=0
    //   0x06 ADD R2,#1    (3)     R2=1
    //   0x09 XOR R4,R4,R4 (3)     R4=0
    //   0x0C ADD R4,#1    (3)     R4=1
    //   0x0F XOR R5,R5,R5 (3)     R5=0
    //   0x12 ADD R5,#6    (3)     R5=6
    //   0x15 XOR R6,R6,R6 (3)     R6=0
    //   0x18 ADD R6,#0x24 (3)     R6=loop_top=0x24  [patch after calculating]
    //   0x1B XOR R7,R7,R7 (3)     R7=0
    //   0x1E ADD R7,#0x2E (3)     R7=halt_addr=0x2E [patch after calculating]
    //   0x21 XOR R8,R8,R8 (3)     R8=0   (will hold latest Fibonacci result)
    //   loop_top=0x24:
    //   0x24 ADD R3,R1,R2 (3)     R3=R1+R2
    //   0x27 SUB R1,R2,R0 (3)     R1=R2
    //   0x2A SUB R2,R3,R0 (3)     R2=R3
    //   0x2D SUB R5,R5,R4 (3)     R5-=1
    //   0x30 JMZ R7       (2)     if done halt
    //   0x32 JMP R6       (2)     else loop
    //   halt=0x34:
    //   0x34 JMP R7       (2)     self-loop (R7 must = 0x34, not 0x2E     fix)
    // Patch R7 init to 0x34 and R6 init to 0x24.
    // The ADD R6,# imm is at byte 0x1A; ADD R7,# imm is at byte 0x20.
    task load_prog3;
        integer lp, ha;
        begin
            begin : clr3
                integer i;
                for (i = 0; i < 256; i = i + 1) imem[i] = 8'hFF;
            end
            wptr = 0;

            emit_std(8'h08, 4'h1, 4'h1, 4'h1);  // 0x00 XOR R1,R1,R1     R1=0
            emit_std(8'h08, 4'h2, 4'h2, 4'h2);  // 0x03 XOR R2,R2,R2     R2=0
            emit_imm(8'h00, 4'h2, 8'h01);        // 0x06 ADD R2,#1        R2=1
            emit_std(8'h08, 4'h4, 4'h4, 4'h4);  // 0x09 XOR R4,R4,R4     R4=0
            emit_imm(8'h00, 4'h4, 8'h01);        // 0x0C ADD R4,#1        R4=1
            emit_std(8'h08, 4'h5, 4'h5, 4'h5);  // 0x0F XOR R5,R5,R5     R5=0
            emit_imm(8'h00, 4'h5, 8'h06);        // 0x12 ADD R5,#6        R5=6
            emit_std(8'h08, 4'h6, 4'h6, 4'h6);  // 0x15 XOR R6,R6,R6     R6=0
            emit_imm(8'h00, 4'h6, 8'hFF);        // 0x18 ADD R6,#?        patch later
            emit_std(8'h08, 4'h7, 4'h7, 4'h7);  // 0x1B XOR R7,R7,R7     R7=0
            emit_imm(8'h00, 4'h7, 8'hFF);        // 0x1E ADD R7,#?        patch later
            emit_std(8'h08, 4'h8, 4'h8, 4'h8);  // 0x21 XOR R8,R8,R8     R8=0 (not used but clean)

            // loop_top
            lp = wptr;  // should be 0x24
            emit_std(8'h00, 4'h3, 4'h1, 4'h2);  // ADD R3,R1,R2     R3=fib
            emit_std(8'h02, 4'h1, 4'h2, 4'h0);  // SUB R1,R2,R0     R1=R2
            emit_std(8'h02, 4'h2, 4'h3, 4'h0);  // SUB R2,R3,R0     R2=R3
            emit_std(8'h02, 4'h5, 4'h5, 4'h4);  // SUB R5,R5,R4     R5-=1
            emit_br(8'h27, 4'h7);                 // JMZ R7     halt if Z
            emit_br(8'h26, 4'h6);                 // JMP R6     loop

            // halt
            ha = wptr;  // should be 0x34
            emit_br(8'h26, 4'h7);                 // JMP R7     self-loop

            // Back-patch loop_top and halt addresses
            imem[16'h1A] = lp[7:0];   // ADD R6,#lp  imm byte
            imem[16'h20] = ha[7:0];   // ADD R7,#ha  imm byte

            // Reset vector -> 0x0000
            set_reset_vector(16'h0000);
        end
    endtask

    // =========================================================================
    // PROGRAM 4     Reset vector test
    // =========================================================================
    // Place a trivial 2-instruction program at 0x0200.
    // Set the reset vector at 0xFFFC/0xFFFD to 0x0200.
    // After reset the CPU should read the vector and start executing at 0x0200
    // rather than at 0x0000 (which is filled with 0xFF = undefined opcode).
    //
    // Halt: JMP R0.  R0 is hardwired to 0x0000.  At 0x0000 the memory is 0xFF
    // (undefined opcode, 3-byte default length, execute ignores it since
    // decode sets valid=0 for unknown opcodes).  This creates a harmless
    // undefined-opcode spin which is fine for sampling purposes.
    task load_prog4;
        begin
            begin : clr4
                integer i;
                // Page 0: 0xFF (undefined) - the CPU must NOT start here
                for (i = 0; i < 256; i = i + 1) imem[i]            = 8'hFF;
                // Page 2: 0xFF (undefined) - zeroed selectively by emit_*
                for (i = 0; i < 256; i = i + 1) imem[16'h0200 + i] = 8'hFF;
            end

            // Program body at 0x0200
            wptr = 16'h0200;
            //   0x0200: XOR R1,R1,R1     R1 = 0
            emit_std(8'h08, 4'h1, 4'h1, 4'h1);
            //   0x0203: ADD R1,#0x42     R1 = 0x42 (the value we will check)
            emit_imm(8'h00, 4'h1, 8'h42);
            //   0x0206: JMP R0           jump to 0x0000 (R0 hardwired = 0)
            //           0x0000 is 0xFF = undefined opcode spin: harmless halt
            emit_br(8'h26, 4'h0);

            // Set reset vector to 0x0200
            set_reset_vector(16'h0200);
        end
    endtask

    // =========================================================================
    // PROGRAM 5     Stack: PUSH, POP, CALL, RET
    // =========================================================================
    // Layout:
    //   0x0000  XOR R1,R1,R1         R1=0
    //   0x0003  ADD R1,#0x11         R1=0x11
    //   0x0006  XOR R2,R2,R2         R2=0
    //   0x0009  ADD R2,#0x22         R2=0x22
    //   0x000C  XOR R3,R3,R3         R3=0  (R3 = sub address)
    //   0x000F  ADD R3,#0x28         R3=0x28  (patched after emit)
    //   0x0012  PUSH R1              stack[15]=0x0011, SP=15
    //   0x0014  PUSH R2              stack[14]=0x0022, SP=14
    //   0x0016  CALL R3              push ret=0x0018, jump to 0x0028
    //   0x0018  POP  R4              R4=stack[SP+1]=0x0022, SP back up
    //   0x001A  POP  R5              R5=stack[SP+1]=0x0011, SP back up
    //   0x001C  XOR R7,R7,R7         R7=0  (halt via JMP R0)
    //   0x001F  JMP R0               jump to 0x0000 region halt spin
    //   0x0021  (pad)
    //   sub at 0x0028:
    //   0x0028  XOR R6,R6,R6         R6=0
    //   0x002B  ADD R6,#0xAB         R6=0xAB
    //   0x002E  RET                  PC <- stack_pop = 0x0018
    //
    // Expected after run: R4=0x22, R5=0x11, R6=0xAB, SP=15 (0xF = full)
    task load_prog5;
        integer sub_addr;
        begin
            begin : clr5
                integer i;
                for (i = 0; i < 256; i = i + 1) imem[i] = 8'hFF;
            end
            wptr = 16'h0000;

            // Setup
            emit_std(8'h08, 4'h1, 4'h1, 4'h1);   // 0x00 XOR R1,R1,R1
            emit_imm(8'h00, 4'h1, 8'h11);         // 0x03 ADD R1,#0x11
            emit_std(8'h08, 4'h2, 4'h2, 4'h2);   // 0x06 XOR R2,R2,R2
            emit_imm(8'h00, 4'h2, 8'h22);         // 0x09 ADD R2,#0x22
            emit_std(8'h08, 4'h3, 4'h3, 4'h3);   // 0x0C XOR R3,R3,R3
            emit_imm(8'h00, 4'h3, 8'hFF);         // 0x0F ADD R3,#? (patch)

            // Stack operations
            emit_push(4'h1);                       // 0x12 PUSH R1
            emit_push(4'h2);                       // 0x14 PUSH R2
            emit_call(4'h3);                       // 0x16 CALL R3
            // return lands here (0x18)
            emit_pop(4'h4);                        // 0x18 POP R4
            emit_pop(4'h5);                        // 0x1A POP R5

            // Halt: JMP R0 (R0=0, 0x0000 is 0xFF = undefined spin)
            emit_br(8'h26, 4'h0);                  // 0x1C JMP R0

            // Pad to sub boundary
            while (wptr < 16'h0028) begin
                imem[wptr] = 8'hFF;
                wptr = wptr + 1;
            end

            // Subroutine at 0x0028
            sub_addr = wptr;   // should be 0x0028
            emit_std(8'h08, 4'h6, 4'h6, 4'h6);   // 0x28 XOR R6,R6,R6
            emit_imm(8'h00, 4'h6, 8'hAB);         // 0x2B ADD R6,#0xAB
            emit_ret();                             // 0x2E RET

            // Back-patch R3 init: imem[0x11] is the imm byte of ADD R3,#?
            imem[16'h11] = sub_addr[7:0];  // 0x28

            set_reset_vector(16'h0000);
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        pass_cnt = 0;
        fail_cnt = 0;

        $display("============================================================");
        $display("  CPU Integration Testbench");
        $display("============================================================");

        //        Program 1: Sum 1..5                                         
        $display("\n--- Program 1: Sum 1..5 (expected R2 = 15) ---");
        load_prog1;
        cpu_reset;
        run_cycles(352);

        $display("  (PC at sample time: 0x%04h)", pc);
        check(1, reg8(4'h2), 8'd15, "R2 = 15 (sum 1+2+3+4+5)");
        check(2, reg8(4'h1), 8'd0,  "R1 = 0 (counter exhausted)");

        //        Program 2: Memory round-trip                                
        $display("\n--- Program 2: Memory round-trip ---");
        load_prog2;
        cpu_reset;
        run_cycles(152);

        check(3, reg8(4'h4), 8'hA5, "R4 = 0xA5 (LOAD from dmem[0x10])");
        check(4, dmem[8'h10],        8'hA5, "dmem[0x10] = 0xA5 (STOR wrote it)");

        //        Program 3: Fibonacci                                        
        // After 6 iterations starting from F0=0, F1=1:
        //   iter 1: R3=1, R1=1, R2=1
        //   iter 2: R3=2, R1=1, R2=2
        //   iter 3: R3=3, R1=2, R2=3
        //   iter 4: R3=5, R1=3, R2=5
        //   iter 5: R3=8, R1=5, R2=8
        //   iter 6: R3=13, R1=8, R2=13
        // Final: R1=8 (F6), R2=13 (F7), R3=13
        $display("\n--- Program 3: Fibonacci (F6=8, F7=13) ---");
        load_prog3;
        cpu_reset;
        run_cycles(502);

        $display("  (PC at sample time: 0x%04h)", pc);
        check(5, reg8(4'h1), 8'd8,  "R1 = 8  (F6)");
        check(6, reg8(4'h2), 8'd13, "R2 = 13 (F7)");
        check(7, reg8(4'h3), 8'd13, "R3 = 13 (last computed fib)");

        //        Program 4: Reset vector
        $display("\n--- Program 4: Reset vector (code at 0x0200) ---");
        load_prog4;
        cpu_reset;
        run_cycles(100);

        $display("  (PC at sample time: 0x%04h)", pc);
        check(8, reg8(4'h1), 8'h42, "R1 = 0x42 (code executed from reset vector 0x0200)");

        //        Program 5: Stack (PUSH, POP, CALL, RET)
        $display("\n--- Program 5: Stack operations ---");
        load_prog5;
        cpu_reset;
        run_cycles(200);

        $display("  (PC at sample time: 0x%04h  SP: 0x%01h)", pc, cpu_sp);
        check(9,  reg8(4'h4), 8'h22, "R4 = 0x22 (POP from stack, was R2)");
        check(10, reg8(4'h5), 8'h11, "R5 = 0x11 (POP from stack, was R1)");
        check(11, reg8(4'h6), 8'hAB, "R6 = 0xAB (executed inside subroutine)");
        check(12, cpu_sp,     4'h0,  "SP = 0 (stack balanced: 3 pushes, 3 pops)");

        //        Summary
        $display("\n============================================================");
        $display("  Results: %0d passed, %0d failed  (total: %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        $display("============================================================");
        if (fail_cnt > 0) $display("  *** FAILURES DETECTED ***");
        else              $display("  All tests passed.");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000;
        $display("TIMEOUT: simulation exceeded 100000 ns");
        $finish;
    end

endmodule
