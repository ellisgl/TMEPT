`ifndef _DECODE_V_
`define _DECODE_V_

// ============================================================================
// decode.v     Instruction Decode Stage for the 8-bit CPU
// ----------------------------------------------------------------------------
// Purely combinational. Takes a pre-packed 32-bit instruction word from the
// fetch stage and produces control signals for the execute stage.
//
// Instruction encoding recap:
//
//   Standard (3 bytes):
//     [31:24] = W0: opcode[7:0]
//     [23:16] = W1: mode[1:0] dst[3:0] 00
//     [15:8]  = W2: src1[3:0] src2[3:0]
//     [7:0]   = W3: unused (0x00)
//
//   Immediate (3 bytes):
//     [31:24] = W0: opcode[7:0]
//     [23:16] = W1: mode=10 dst[3:0] 00
//     [15:8]  = W2: imm[7:0]
//     [7:0]   = W3: unused
//
//   Memory/MAR (2 bytes):
//     [31:24] = W0: opcode[7:0]
//     [23:16] = W1: mode=11 dst[3:0] 00
//     [15:8]  = W2: unused
//     [7:0]   = W3: unused
//
//   LMAR (3 bytes):
//     [31:24] = W0: opcode[7:0]  (LMAR)
//     [23:16] = W1: addr[15:8]
//     [15:8]  = W2: addr[7:0]
//     [7:0]   = W3: unused
//
//   Compound (4 bytes):
//     [31:24] = W0: opcode[7:0]
//     [23:20] = W1[7:4]: src1[3:0]
//     [19:16] = W1[3:0]: src2[3:0]
//     [15:12] = W2[7:4]: dst[3:0]
//     [11:8]  = W2[3:0]: unused
//     [7:4]   = W3[7:4]: jmp[3:0]
//     [3:0]   = W3[3:0]: unused
//
// ALU group encoding:
//   2'b00 = arithmetic/logic
//   2'b01 = shift/rotate
//   2'b10 = bit manipulation
//   2'b11 = (special     jumps/MAR/mov use ALU pass-through)
//
// Mode encoding:
//   2'b00 = register 3-address (dst = src1 op src2)
//   2'b01 = register 2-address (dst = dst op src2)
//   2'b10 = immediate          (dst = dst op imm)
//   2'b11 = memory via MAR     (dst = dst op mem[MAR])
// ============================================================================

//        Opcode definitions                                                                                                                                                                      
`define OPC_ADD   8'h00
`define OPC_ADC   8'h01
`define OPC_SUB   8'h02
`define OPC_SBC   8'h03
`define OPC_AND   8'h04
`define OPC_OR    8'h05
`define OPC_NOR   8'h06
`define OPC_NAD   8'h07
`define OPC_XOR   8'h08
`define OPC_CMP   8'h09

`define OPC_ROL   8'h0A
`define OPC_SOL   8'h0B
`define OPC_SZL   8'h0C
`define OPC_RIL   8'h0D
`define OPC_ROR   8'h0E
`define OPC_SOR   8'h0F
`define OPC_SZR   8'h10
`define OPC_RIR   8'h11

`define OPC_INV   8'h12
`define OPC_INH   8'h13
`define OPC_INL   8'h14
`define OPC_INE   8'h15
`define OPC_INO   8'h16
`define OPC_IEH   8'h17
`define OPC_IOH   8'h18
`define OPC_IEL   8'h19
`define OPC_IOL   8'h1A
`define OPC_IFB   8'h1B
`define OPC_ILB   8'h1C

`define OPC_REV   8'h1D
`define OPC_RVL   8'h1E
`define OPC_RVH   8'h1F
`define OPC_RVE   8'h20
`define OPC_RVO   8'h21
`define OPC_RLE   8'h22
`define OPC_RHE   8'h23
`define OPC_RLO   8'h24
`define OPC_RHO   8'h25

`define OPC_JMP   8'h26
`define OPC_JMZ   8'h27
`define OPC_JMN   8'h28
`define OPC_JMG   8'h29
`define OPC_JMO   8'h2A
`define OPC_JIE   8'h2B
`define OPC_JIO   8'h2C
`define OPC_JNE   8'h38
`define OPC_JGE   8'h39
`define OPC_JLE   8'h3A

`define OPC_PUSH  8'h3B
`define OPC_POP   8'h3C
`define OPC_CALL  8'h3D
`define OPC_RET   8'h3E

`define OPC_MOV   8'h2D
`define OPC_LMAR  8'h2E
`define OPC_SMAR  8'h2F
`define OPC_LOAD  8'h30
`define OPC_STOR  8'h31
`define OPC_IMAR  8'h32
`define OPC_DMAR  8'h33

`define OPC_ALE   8'h34
`define OPC_DJN   8'h35
`define OPC_SLE   8'h36
`define OPC_SJN   8'h37

//        ALU group constants                                                                                                                                                                      
`define GRP_ARITH  2'b00
`define GRP_SHIFT  2'b01
`define GRP_BMANIP 2'b10
`define GRP_SPEC   2'b11

//        ALU op constants     arithmetic                                                                                                                                     
`define AOP_ADD  4'h0
`define AOP_ADC  4'h1
`define AOP_SUB  4'h2
`define AOP_SBC  4'h3
`define AOP_AND  4'h4
`define AOP_OR   4'h5
`define AOP_NOR  4'h6
`define AOP_NAD  4'h7
`define AOP_XOR  4'h8
`define AOP_CMP  4'h9

//        ALU op constants     shift                                                                                                                                                       
`define SOP_ROL  3'h0
`define SOP_SOL  3'h1
`define SOP_SZL  3'h2
`define SOP_RIL  3'h3
`define SOP_ROR  3'h4
`define SOP_SOR  3'h5
`define SOP_SZR  3'h6
`define SOP_RIR  3'h7

//        ALU op constants     bit manipulation                                                                                                                   
`define BOP_INV  5'h00
`define BOP_INH  5'h01
`define BOP_INL  5'h02
`define BOP_INE  5'h03
`define BOP_INO  5'h04
`define BOP_IEH  5'h05
`define BOP_IOH  5'h06
`define BOP_IEL  5'h07
`define BOP_IOL  5'h08
`define BOP_IFB  5'h09
`define BOP_ILB  5'h0A
`define BOP_REV  5'h0B
`define BOP_RVL  5'h0C
`define BOP_RVH  5'h0D
`define BOP_RVE  5'h0E
`define BOP_RVO  5'h0F
`define BOP_RLE  5'h10
`define BOP_RHE  5'h11
`define BOP_RLO  5'h12
`define BOP_RHO  5'h13

module decode (
    input  wire [31:0] instr,        // Pre-packed instruction from fetch
    input  wire        instr_valid,  // Fetch asserts when full instr is ready

    //        ALU control                                                                                                                                                                               
    output reg  [1:0]  alu_group,    // Functional unit select
    output reg  [5:0]  alu_op,       // Operation within unit

    //        Register addresses                                                                                                                                                             
    output reg  [3:0]  dst_addr,     // Destination register
    output reg  [3:0]  src1_addr,    // Source register 1
    output reg  [3:0]  src2_addr,    // Source register 2
    output reg  [3:0]  jmp_addr,     // Jump target register (compound ops)

    //        Operand / addressing                                                                                                                                                       
    output reg  [1:0]  mode,         // Addressing mode
    output reg  [7:0]  imm,          // 8-bit immediate value
    output reg  [15:0] imm_wide,     // 16-bit immediate (LMAR)

    //        Control flags                                                                                                                                                                            
    output reg         reg_wr_en,    // Write result to dst register
    output reg         reg_wr_wide,  // Write full 16-bit (wide write)
    output reg         mem_rd_en,    // Read from memory (LOAD)
    output reg         mem_wr_en,    // Write to memory (STOR)
    output reg         mar_wr_en,    // Write to MAR register
    output reg         mar_inc,      // Increment MAR
    output reg         mar_dec,      // Decrement MAR
    output reg         is_branch,    // Instruction may alter PC
    output reg         is_compound,  // 4-byte compound instruction
    output reg         uses_carry,   // Reads carry flag (ADC/SBC)
    output reg         valid         // Opcode is defined
);

    //        Instruction field extraction                                                                                                                               
    wire [7:0] opcode   = instr[31:24];
    wire [1:0] w1_mode  = instr[23:22];
    wire [3:0] w1_dst   = instr[21:18];
    // W2 interpretation depends on mode
    wire [3:0] w2_src1  = instr[15:12];
    wire [3:0] w2_src2  = instr[11:8];
    wire [7:0] w2_imm   = instr[15:8];
    // LMAR: 16-bit address across W1+W2
    wire [15:0] w12_addr = instr[23:8];
    // Compound fields
    wire [3:0] cp_src1  = instr[23:20];
    wire [3:0] cp_src2  = instr[19:16];
    wire [3:0] cp_dst   = instr[15:12];
    wire [3:0] cp_jmp   = instr[7:4];

    always @(*) begin
        //        Defaults     safe no-op                                                                                                                                        
        alu_group    = `GRP_ARITH;
        alu_op       = {2'b0, `AOP_ADD};
        dst_addr     = w1_dst;
        src1_addr    = w2_src1;
        src2_addr    = w2_src2;
        jmp_addr     = 4'h0;
        mode         = w1_mode;
        imm          = w2_imm;
        imm_wide     = w12_addr;
        reg_wr_en    = 1'b0;
        reg_wr_wide  = 1'b0;
        mem_rd_en    = 1'b0;
        mem_wr_en    = 1'b0;
        mar_wr_en    = 1'b0;
        mar_inc      = 1'b0;
        mar_dec      = 1'b0;
        is_branch    = 1'b0;
        is_compound  = 1'b0;
        uses_carry   = 1'b0;
        valid        = instr_valid;

        if (instr_valid) begin
            case (opcode)

                //        Arithmetic / Logic                                                                                                                         
                `OPC_ADD: begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_ADD}; reg_wr_en = 1; end
                `OPC_ADC: begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_ADC}; reg_wr_en = 1; uses_carry = 1; end
                `OPC_SUB: begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_SUB}; reg_wr_en = 1; end
                `OPC_SBC: begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_SBC}; reg_wr_en = 1; uses_carry = 1; end
                `OPC_AND: begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_AND}; reg_wr_en = 1; end
                `OPC_OR:  begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_OR};  reg_wr_en = 1; end
                `OPC_NOR: begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_NOR}; reg_wr_en = 1; end
                `OPC_NAD: begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_NAD}; reg_wr_en = 1; end
                `OPC_XOR: begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_XOR}; reg_wr_en = 1; end
                `OPC_CMP: begin alu_group = `GRP_ARITH; alu_op = {2'b0, `AOP_CMP}; reg_wr_en = 0; end // flags only

                //        Shift / Rotate                                                                                                                                     
                `OPC_ROL: begin alu_group = `GRP_SHIFT; alu_op = {3'b0, `SOP_ROL}; reg_wr_en = 1; end
                `OPC_SOL: begin alu_group = `GRP_SHIFT; alu_op = {3'b0, `SOP_SOL}; reg_wr_en = 1; end
                `OPC_SZL: begin alu_group = `GRP_SHIFT; alu_op = {3'b0, `SOP_SZL}; reg_wr_en = 1; end
                `OPC_RIL: begin alu_group = `GRP_SHIFT; alu_op = {3'b0, `SOP_RIL}; reg_wr_en = 1; end
                `OPC_ROR: begin alu_group = `GRP_SHIFT; alu_op = {3'b0, `SOP_ROR}; reg_wr_en = 1; end
                `OPC_SOR: begin alu_group = `GRP_SHIFT; alu_op = {3'b0, `SOP_SOR}; reg_wr_en = 1; end
                `OPC_SZR: begin alu_group = `GRP_SHIFT; alu_op = {3'b0, `SOP_SZR}; reg_wr_en = 1; end
                `OPC_RIR: begin alu_group = `GRP_SHIFT; alu_op = {3'b0, `SOP_RIR}; reg_wr_en = 1; end

                //        Bit Manipulation                                                                                                                               
                `OPC_INV: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_INV}; reg_wr_en = 1; end
                `OPC_INH: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_INH}; reg_wr_en = 1; end
                `OPC_INL: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_INL}; reg_wr_en = 1; end
                `OPC_INE: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_INE}; reg_wr_en = 1; end
                `OPC_INO: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_INO}; reg_wr_en = 1; end
                `OPC_IEH: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_IEH}; reg_wr_en = 1; end
                `OPC_IOH: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_IOH}; reg_wr_en = 1; end
                `OPC_IEL: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_IEL}; reg_wr_en = 1; end
                `OPC_IOL: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_IOL}; reg_wr_en = 1; end
                `OPC_IFB: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_IFB}; reg_wr_en = 1; end
                `OPC_ILB: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_ILB}; reg_wr_en = 1; end
                `OPC_REV: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_REV}; reg_wr_en = 1; end
                `OPC_RVL: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_RVL}; reg_wr_en = 1; end
                `OPC_RVH: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_RVH}; reg_wr_en = 1; end
                `OPC_RVE: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_RVE}; reg_wr_en = 1; end
                `OPC_RVO: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_RVO}; reg_wr_en = 1; end
                `OPC_RLE: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_RLE}; reg_wr_en = 1; end
                `OPC_RHE: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_RHE}; reg_wr_en = 1; end
                `OPC_RLO: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_RLO}; reg_wr_en = 1; end
                `OPC_RHO: begin alu_group = `GRP_BMANIP; alu_op = {1'b0, `BOP_RHO}; reg_wr_en = 1; end

                //        Jumps                                                                                                                                                                
                // src1_addr holds the target register (from w1_dst field)
                `OPC_JMP: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end
                `OPC_JMZ: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end
                `OPC_JMN: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end
                `OPC_JMG: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end
                `OPC_JMO: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end
                `OPC_JIE: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end
                `OPC_JIO: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end
                `OPC_JNE: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end
                `OPC_JGE: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end
                `OPC_JLE: begin is_branch = 1; src1_addr = w1_dst; alu_group = `GRP_SPEC; end

                //        MOV                                                                                                                                                                      
                `OPC_MOV: begin
                    alu_group = `GRP_SPEC;
                    reg_wr_en = 1;
                    // mode=11 means MOV from memory (LOAD effectively)
                    mem_rd_en = (w1_mode == 2'b11);
                end

                //        MAR operations                                                                                                                                     
                // All memory/MAR instructions use GRP_SPEC so the execute stage
                // never updates flags for them (flag gate: alu_group != 2'b11).
                `OPC_LMAR: begin
                    alu_group = `GRP_SPEC;
                    // Load MAR from 16-bit immediate in W1+W2
                    mar_wr_en = 1;
                    imm_wide  = w12_addr;
                end
                `OPC_SMAR: begin
                    alu_group = `GRP_SPEC;
                    // Load MAR from register (src1 holds full 16-bit address)
                    mar_wr_en = 1;
                    src1_addr = w1_dst; // register carrying the address
                end
                `OPC_LOAD: begin
                    alu_group = `GRP_SPEC;
                    mem_rd_en = 1;
                    reg_wr_en = 1;
                end
                `OPC_STOR: begin
                    alu_group = `GRP_SPEC;
                    mem_wr_en = 1;
                    src1_addr = w1_dst; // register to store
                end
                `OPC_IMAR: begin alu_group = `GRP_SPEC; mar_inc = 1; end
                `OPC_DMAR: begin alu_group = `GRP_SPEC; mar_dec = 1; end

                //        Compound ops                                                                                                                                           
                `OPC_ALE: begin
                    alu_group   = `GRP_ARITH;
                    alu_op      = {2'b0, `AOP_ADD};
                    src1_addr   = cp_src1;
                    src2_addr   = cp_src2;
                    dst_addr    = cp_dst;
                    jmp_addr    = cp_jmp;
                    reg_wr_en   = 1;
                    is_branch   = 1;
                    is_compound = 1;
                end
                `OPC_DJN: begin
                    alu_group   = `GRP_ARITH;
                    alu_op      = {2'b0, `AOP_SUB};
                    src1_addr   = cp_src1; // register to decrement
                    dst_addr    = cp_src1; // result written back to same reg
                    jmp_addr    = cp_jmp;
                    reg_wr_en   = 1;
                    is_branch   = 1;
                    is_compound = 1;
                end
                `OPC_SLE: begin
                    alu_group   = `GRP_ARITH;
                    alu_op      = {2'b0, `AOP_SUB};
                    src1_addr   = cp_src1;
                    src2_addr   = cp_src2;
                    dst_addr    = cp_dst;
                    jmp_addr    = cp_jmp;
                    reg_wr_en   = 1;
                    is_branch   = 1;
                    is_compound = 1;
                end
                `OPC_SJN: begin
                    alu_group   = `GRP_ARITH;
                    alu_op      = {2'b0, `AOP_SUB};
                    src1_addr   = cp_src1;
                    src2_addr   = cp_src2;
                    dst_addr    = cp_dst;
                    jmp_addr    = cp_jmp;
                    reg_wr_en   = 1;
                    is_branch   = 1;
                    is_compound = 1;
                end

                //        Stack operations
                `OPC_PUSH: begin
                    alu_group = `GRP_SPEC;
                    src1_addr = w1_dst; // register to push
                end
                `OPC_POP: begin
                    alu_group  = `GRP_SPEC;
                    dst_addr   = w1_dst; // register to receive popped value
                    reg_wr_en  = 1;
                    reg_wr_wide = 1;    // POP writes full 16-bit value
                end
                `OPC_CALL: begin
                    alu_group = `GRP_SPEC;
                    src1_addr = w1_dst; // register holding call target
                    is_branch = 1;
                end
                `OPC_RET: begin
                    alu_group = `GRP_SPEC;
                    is_branch = 1;
                end

                default: begin
                    valid = 1'b0; // Undefined opcode
                end
            endcase
        end
    end

endmodule

`endif // _DECODE_V_
