`ifndef _EXECUTE_V_
`define _EXECUTE_V_

// ============================================================================
// execute.v     Execute Stage for the 8-bit CPU
// ----------------------------------------------------------------------------
// Latches decoded control signals on the clock edge (decode/execute pipeline
// register lives here), then performs register reads, ALU operation, flag
// update, branch resolution, MAR update, and register writeback.
//
// Internal structure:
//   1. Input pipeline register      latches decode outputs
//
// Stack:
//   PUSH Rs   SP--, stack[SP] = Rs   (full 16-bit)
//   POP  Rd   Rd = stack[SP+1], SP++ (full 16-bit wide write)
//   CALL Rt   stack[SP--] = return_addr, PC = Rt
//   RET       PC = stack[SP+1], SP++
//   SP is a dedicated 4-bit hardware register (not R0-R15).
//   Stack is full-descending, 16 x 16-bit entries.
//   2. Register file read           async reads via src1/src2 addresses
//   3. Operand mux                  selects src2 vs immediate vs memory
//   4. ALU                          performs the operation
//   5. Flag update                  Z, N, C, V, O updated from ALU result
//   6. Branch resolution            tests flags, drives pc_load_en/val
//   7. MAR update                   LMAR/SMAR/IMAR/DMAR
//   8. Register writeback           routes result back to reg_file port A
//
// Flags (5-bit FLAGS register [4:0]):
//   [4] O      odd parity (XOR of all result bits)
//   [3] V      signed overflow
//   [2] C      carry / borrow
//   [1] N      negative (result[7])
//   [0] Z      zero (result == 0)
//
// Branch conditions:
//   JMP     unconditional
//   JMZ     Z=1  (equal / zero)
//   JMN     N=1  (negative)
//   JMG     Z=0 AND N=0  (greater, signed)
//   JMO     V=1  (overflow)
//   JIE     C=1  (carry set)
//   JIO     O=1  (odd parity)
//   JNE     Z=0  (not equal)
//   JGE     N=V  (greater or equal, signed)
//   JLE     (N!=V) OR Z=1  (less or equal, signed)
//
// Compound op jump conditions:
//   ALE     add, jump if Z=0
//   DJN     decrement, jump if Z=0  (loop while non-zero)
//   SLE     subtract, jump if N=1 OR Z=1  (result <= 0)
//   SJN     subtract, jump if Z=0
// ============================================================================

`include "rtl/alu.v"
`include "rtl/reg_file.v"
`include "rtl/decode.v"   // for opcode defines

module execute (
    input  wire        clk,
    input  wire        rst_n,

    //        Inputs from decode (latched internally on clk edge)
    input  wire [31:0] instr,
    input  wire        instr_valid,

    //        Memory data input (for LOAD/MOV [MAR])
    input  wire [7:0]  mem_rd_data,

    //        Memory interface outputs
    output reg  [15:0] mar,          // Memory Address Register
    output wire [7:0]  mem_wr_data,  // Data to write to memory
    output wire        mem_wr_en,    // Write enable to data memory

    //        Branch outputs (to fetch)
    output reg         pc_load_en,
    output reg  [15:0] pc_load_val,

    //        Flags output (for debug / future use)
    output wire [4:0]  flags,        // {O, V, C, N, Z}

    //        Return address input (from fetch, for CALL)
    input  wire [15:0] pc_in,        // PC of instruction after current one

    //        Stack observability
    output wire [3:0]  sp,           // Stack pointer

    //        Stall output
    output wire        stall         // (reserved for multi-cycle ops, tied 0)
);

    assign stall = 1'b0;

    //        Decode the latched instruction
    // Run decode combinationally from the latched instruction word
    wire [1:0]  alu_group;
    wire [5:0]  alu_op;
    wire [3:0]  dst_addr, src1_addr, src2_addr, jmp_addr;
    wire [1:0]  mode;
    wire [7:0]  imm;
    wire [15:0] imm_wide;
    wire        reg_wr_en, reg_wr_wide;
    wire        mem_rd_en, dec_mem_wr_en;
    wire        mar_wr_en, mar_inc, mar_dec;
    wire        is_branch, is_compound, uses_carry;
    wire        dec_valid;

    // Pipeline register for the instruction word
    reg  [31:0] instr_r;
    reg         valid_r;

    reg [15:0] pc_in_r;   // return address latched with instr_r (for CALL)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            instr_r  <= 32'h0;
            valid_r  <= 1'b0;
            pc_in_r  <= 16'h0000;
        end else begin
            instr_r  <= instr;
            valid_r  <= instr_valid;
            pc_in_r  <= pc_in;   // latch return addr in sync with instruction
        end
    end

    decode dec_inst (
        .instr        (instr_r),
        .instr_valid  (valid_r),
        .alu_group    (alu_group),
        .alu_op       (alu_op),
        .dst_addr     (dst_addr),
        .src1_addr    (src1_addr),
        .src2_addr    (src2_addr),
        .jmp_addr     (jmp_addr),
        .mode         (mode),
        .imm          (imm),
        .imm_wide     (imm_wide),
        .reg_wr_en    (reg_wr_en),
        .reg_wr_wide  (reg_wr_wide),
        .mem_rd_en    (mem_rd_en),
        .mem_wr_en    (dec_mem_wr_en),
        .mar_wr_en    (mar_wr_en),
        .mar_inc      (mar_inc),
        .mar_dec      (mar_dec),
        .is_branch    (is_branch),
        .is_compound  (is_compound),
        .uses_carry   (uses_carry),
        .valid        (dec_valid)
    );

    //        Register file
    wire [15:0] rd_data0, rd_data1, rd_data2, rd_data3;

    // Writeback wires (driven below)
    reg        wr_a_en;
    reg [3:0]  wr_a_addr;
    reg [7:0]  wr_a_data;
    reg        wr_a_wide;
    reg [15:0] wr_a_data_wide;

    reg        wr_b_en;          // port B: used for POP writeback
    reg [3:0]  wr_b_addr;
    reg [15:0] wr_b_data_wide;

    reg_file rf (
        .clk            (clk),
        .rst_n          (rst_n),
        // Read ports
        .rd_addr0       (src1_addr),   // src1
        .rd_data0       (rd_data0),
        .rd_addr1       (src2_addr),   // src2
        .rd_data1       (rd_data1),
        .rd_addr2       (dst_addr),    // dst (for 2-address ops that read dst)
        .rd_data2       (rd_data2),
        .rd_addr3       (jmp_addr),    // jump target register
        .rd_data3       (rd_data3),
        // Write port A (primary writeback)
        .wr_a_en        (wr_a_en),
        .wr_a_addr      (wr_a_addr),
        .wr_a_data      (wr_a_data),
        .wr_a_wide      (wr_a_wide),
        .wr_a_data_wide (wr_a_data_wide),
        // Write port B: POP writeback (wide 16-bit, one cycle after pop_en)
        .wr_b_en        (wr_b_en),
        .wr_b_addr      (wr_b_addr),
        .wr_b_data      (8'h00),       // unused: always wide
        .wr_b_wide      (wr_b_en),     // always wide when enabled
        .wr_b_data_wide (wr_b_data_wide)
    );

    //        Opcode (convenience alias for instr_r MSB)
    wire [7:0] opcode = instr_r[31:24];

    //        Stack (inlined – 16x16-bit full-descending)
    reg [15:0] stk_mem [0:15];
    reg [3:0]  stk_sp;           // next free slot; 0 = empty
    reg [15:0] stk_pop_data;     // registered pop result

    // Stack control signals
    wire dec_push_en = dec_valid && valid_r &&
                       ((opcode == `OPC_PUSH) || (opcode == `OPC_CALL));
    wire dec_pop_en  = dec_valid && valid_r &&
                       ((opcode == `OPC_POP)  || (opcode == `OPC_RET));
    wire [15:0] stack_push_data = (opcode == `OPC_CALL) ? pc_in_r : rd_data0;

    assign sp = stk_sp;


    //        Operand selection
    // operand_a: src1 (low byte) for 3-address; dst (low byte) for 2-address
    // operand_b: src2 (low byte), immediate, or memory data
    wire [7:0] operand_a = (mode == 2'b00) ? rd_data0[7:0]  // 3-address: src1
                                           : rd_data2[7:0]; // 2-address/imm/mem: dst

    wire [7:0] operand_b = (mode == 2'b10)              ? imm            // immediate
                         : (mode == 2'b11)              ? mem_rd_data     // memory [MAR]
                         : (opcode == `OPC_DJN)         ? 8'h01           // DJN always decrements by 1
                         :                               rd_data1[7:0];  // register src2

    //        Flags register
    reg [4:0] flags_r;   // {O, V, C, N, Z}

    // Delayed stack-pop writeback (one cycle after pop_en)
    reg        pop_wb_en;     // write back stk_pop_data to register
    reg [3:0]  pop_wb_addr;   // destination register
    reg        ret_pending;   // issue pc_load from stk_pop_data next cycle
    assign flags = flags_r;

    wire flag_O = flags_r[4];
    wire flag_V = flags_r[3];
    wire flag_C = flags_r[2];
    wire flag_N = flags_r[1];
    wire flag_Z = flags_r[0];

    //        ALU
    wire [7:0] alu_result;
    wire       alu_zero, alu_neg, alu_carry, alu_ovf;

    alu alu_inst (
        .operand_a  (operand_a),
        .operand_b  (operand_b),
        .alu_group  (alu_group),
        .alu_op     (alu_op),
        .carry_in   (uses_carry ? flag_C : 1'b0),
        .result     (alu_result),
        .flag_z     (alu_zero),
        .flag_n     (alu_neg),
        .flag_c     (alu_carry),
        .flag_v     (alu_ovf)
    );

    // Odd parity: XOR of all result bits
    wire alu_odd = ^alu_result;

    //        Branch resolution

    // Branch target: full 16-bit value from jump target register
    // Simple jumps use src1_addr (rd_data0); compound jumps use jmp_addr (rd_data3)
    // pc_load_val is registered alongside pc_load_en (see synchronous block below)

    // Branch taken condition
    wire branch_taken;
    assign branch_taken =
        (opcode == `OPC_JMP)                                  ? 1'b1          :
        (opcode == `OPC_JMZ)                                  ? flag_Z        :
        (opcode == `OPC_JMN)                                  ? flag_N        :
        (opcode == `OPC_JMG)                                  ? (~flag_Z & ~flag_N) :
        (opcode == `OPC_JMO)                                  ? flag_V        :
        (opcode == `OPC_JIE)                                  ? flag_C        :
        (opcode == `OPC_JIO)                                  ? flag_O        :
        (opcode == `OPC_JNE)                                  ? ~flag_Z       :
        (opcode == `OPC_JGE)                                  ? (flag_N == flag_V) :
        (opcode == `OPC_JLE)                                  ? (flag_N != flag_V || flag_Z) :
        // Compound ops
        (opcode == `OPC_ALE)                                  ? ~alu_zero     :
        (opcode == `OPC_DJN)                                  ? ~alu_zero     :
        (opcode == `OPC_SLE)                                  ? (alu_neg | alu_zero) :
        (opcode == `OPC_SJN)                                  ? ~alu_zero     :
        1'b0;

    //        Memory write
    // STOR writes src1's low byte to memory[MAR]
    assign mem_wr_en   = dec_mem_wr_en & valid_r;
    assign mem_wr_data = rd_data0[7:0];  // src1 addr     rd_data0

    //        Synchronous outputs: flags, MAR, writeback, branch
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flags_r        <= 5'b00000;
            mar            <= 16'h0000;
            wr_a_en        <= 1'b0;
            wr_a_addr      <= 4'h0;
            wr_a_data      <= 8'h00;
            wr_a_wide      <= 1'b0;
            wr_a_data_wide <= 16'h0000;
            pc_load_en     <= 1'b0;
            pc_load_val    <= 16'h0000;
            pop_wb_en      <= 1'b0;
            pop_wb_addr    <= 4'h0;
            ret_pending    <= 1'b0;
            wr_b_en        <= 1'b0;
            wr_b_addr      <= 4'h0;
            wr_b_data_wide <= 16'h0000;
            stk_sp         <= 4'h0;
            stk_pop_data   <= 16'h0000;
        end else begin
            // Defaults
            wr_a_en     <= 1'b0;
            wr_b_en     <= 1'b0;
            pc_load_en  <= 1'b0;
            pop_wb_en   <= 1'b0;
            ret_pending <= 1'b0;

            // ── Delayed stack-pop writeback via port B (one cycle after POP/RET) ──
            // Using port B avoids any conflict with port A (ALU writeback).
            if (pop_wb_en) begin
                wr_b_en        <= 1'b1;
                wr_b_addr      <= pop_wb_addr;
                wr_b_data_wide <= stk_pop_data;
            end
            if (ret_pending) begin
                pc_load_en  <= 1'b1;
                pc_load_val <= stk_pop_data;
            end


            //        Stack push / pop
            if (dec_push_en && !dec_pop_en) begin
                stk_mem[stk_sp] <= stack_push_data;
                stk_sp          <= stk_sp - 1;
            end else if (dec_pop_en && !dec_push_en) begin
                stk_pop_data    <= stk_mem[stk_sp + 4'h1];
                stk_sp          <= stk_sp + 1;
            end

            if (valid_r) begin

                //        Flag update
                // Updated by all ALU ops (including CMP); not updated by
                // memory/MAR/branch-only instructions
                if (alu_group != 2'b11) begin
                    flags_r[0] <= alu_zero;           // Z
                    flags_r[1] <= alu_neg;            // N
                    flags_r[2] <= alu_carry;          // C
                    flags_r[3] <= alu_ovf;            // V
                    flags_r[4] <= alu_odd;            // O
                end

                //        MAR update
                if (mar_wr_en) begin
                    if (opcode == `OPC_LMAR)
                        mar <= imm_wide;              // 16-bit immediate
                    else
                        mar <= rd_data0;              // SMAR: full 16-bit from reg
                end else if (mar_inc) begin
                    mar <= mar + 1;
                end else if (mar_dec) begin
                    mar <= mar - 1;
                end

                //        Register writeback
                if (reg_wr_en) begin
                    wr_a_en   <= 1'b1;
                    wr_a_wide <= reg_wr_wide;
                    wr_a_addr <= is_compound ? dst_addr : dst_addr;

                    if (mem_rd_en) begin
                        // LOAD / MOV [MAR]
                        wr_a_data <= mem_rd_data;
                    end else if (opcode == `OPC_MOV) begin
                        // MOV reg-to-reg: src1 low byte
                        wr_a_data <= rd_data0[7:0];
                    end else begin
                        // ALU result
                        wr_a_data <= alu_result;
                    end

                    if (reg_wr_wide)
                        wr_a_data_wide <= rd_data0; // wide reg-to-reg (future)
                end

                //        Branch  (regular + compound; CALL and RET handled below)
                if (is_branch && branch_taken &&
                    opcode != `OPC_CALL && opcode != `OPC_RET) begin
                    pc_load_en  <= 1'b1;
                    pc_load_val <= is_compound ? rd_data3 : rd_data0;
                end

                //        Stack operations
                // push_en/pop_en are combinational and drive the stack module
                // directly. Here we only handle the registered side-effects.
                if (opcode == `OPC_CALL) begin
                    // Jump to call target (src1 field = W1 dst = rd_data0)
                    pc_load_en  <= 1'b1;
                    pc_load_val <= rd_data0;
                end
                if (opcode == `OPC_POP) begin
                    // pop_data arrives next cycle via registered stack read
                    pop_wb_en   <= 1'b1;
                    pop_wb_addr <= dst_addr;
                end
                if (opcode == `OPC_RET) begin
                    // pop_data arrives next cycle; fire PC load then
                    ret_pending <= 1'b1;
                end

            end
        end
    end

endmodule

`endif // _EXECUTE_V_
