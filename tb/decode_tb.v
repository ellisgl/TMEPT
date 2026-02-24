// ============================================================================
// decode_tb.v     Testbench for the decode stage
// ============================================================================

`timescale 1ns/1ps
`include "rtl/decode.v"

module decode_tb;

    //        DUT ports                                                                                                                                                                                        
    reg  [31:0] instr;
    reg         instr_valid;

    wire [1:0]  alu_group;
    wire [5:0]  alu_op;
    wire [3:0]  dst_addr, src1_addr, src2_addr, jmp_addr;
    wire [1:0]  mode;
    wire [7:0]  imm;
    wire [15:0] imm_wide;
    wire        reg_wr_en, reg_wr_wide;
    wire        mem_rd_en, mem_wr_en;
    wire        mar_wr_en, mar_inc, mar_dec;
    wire        is_branch, is_compound, uses_carry;
    wire        valid;

    decode dut (
        .instr        (instr),
        .instr_valid  (instr_valid),
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
        .mem_wr_en    (mem_wr_en),
        .mar_wr_en    (mar_wr_en),
        .mar_inc      (mar_inc),
        .mar_dec      (mar_dec),
        .is_branch    (is_branch),
        .is_compound  (is_compound),
        .uses_carry   (uses_carry),
        .valid        (valid)
    );

    integer pass_count, fail_count;

    //        Instruction assembly helpers                                                                                                                               
    // Build a standard 3-byte instruction (mode + dst in W1, src1+src2 in W2)
    function [31:0] mk_std;
        input [7:0] opc;
        input [1:0] md;
        input [3:0] dst, s1, s2;
        begin
            mk_std = {opc, md, dst, 2'b00, s1, s2, 8'h00};
        end
    endfunction

    // Build an immediate instruction (mode=10, imm in W2)
    function [31:0] mk_imm;
        input [7:0] opc;
        input [3:0] dst;
        input [7:0] immediate;
        begin
            mk_imm = {opc, 2'b10, dst, 2'b00, immediate, 8'h00};
        end
    endfunction

    // Build a jump instruction (target reg in dst field of W1)
    function [31:0] mk_jmp;
        input [7:0] opc;
        input [3:0] target;
        begin
            mk_jmp = {opc, 2'b00, target, 2'b00, 8'h00, 8'h00};
        end
    endfunction

    // Build LMAR (16-bit address in W1+W2)
    function [31:0] mk_lmar;
        input [15:0] addr;
        begin
            mk_lmar = {8'h2E, addr, 8'h00};
        end
    endfunction

    // Build a compound instruction
    function [31:0] mk_compound;
        input [7:0] opc;
        input [3:0] s1, s2, dst, jmp;
        begin
            mk_compound = {opc, s1, s2, dst, 4'h0, jmp, 4'h0};
        end
    endfunction

    // Build a MAR/memory instruction (reg in dst field of W1)
    function [31:0] mk_mar;
        input [7:0] opc;
        input [3:0] reg_field;
        begin
            mk_mar = {opc, 2'b11, reg_field, 2'b00, 8'h00, 8'h00};
        end
    endfunction

    //        Check task                                                                                                                                                                                     
    task check_sig;
        input [63:0]  test_id;
        input [31:0]  got, exp;
        input [239:0] label;
        begin
            if (got !== exp) begin
                $display("  FAIL [%0d] %s: got %0d, exp %0d", test_id, label, got, exp);
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
    endtask

    // Check all outputs for one instruction
    task check_instr;
        input [63:0]  id;
        input [239:0] label;
        // Expected values
        input [1:0]  e_grp;
        input [5:0]  e_op;
        input [3:0]  e_dst, e_src1, e_src2;
        input [1:0]  e_mode;
        input        e_reg_wr, e_mem_rd, e_mem_wr;
        input        e_mar_wr, e_mar_inc, e_mar_dec;
        input        e_branch, e_compound, e_carry;
        input        e_valid;
        begin
            #1;
            $display("  [%0d] %s", id, label);
            check_sig(id, alu_group,   e_grp,     "alu_group  ");
            check_sig(id, alu_op,      e_op,      "alu_op     ");
            check_sig(id, dst_addr,    e_dst,     "dst_addr   ");
            check_sig(id, src1_addr,   e_src1,    "src1_addr  ");
            check_sig(id, src2_addr,   e_src2,    "src2_addr  ");
            check_sig(id, mode,        e_mode,    "mode       ");
            check_sig(id, reg_wr_en,   e_reg_wr,  "reg_wr_en  ");
            check_sig(id, mem_rd_en,   e_mem_rd,  "mem_rd_en  ");
            check_sig(id, mem_wr_en,   e_mem_wr,  "mem_wr_en  ");
            check_sig(id, mar_wr_en,   e_mar_wr,  "mar_wr_en  ");
            check_sig(id, mar_inc,     e_mar_inc, "mar_inc    ");
            check_sig(id, mar_dec,     e_mar_dec, "mar_dec    ");
            check_sig(id, is_branch,   e_branch,  "is_branch  ");
            check_sig(id, is_compound, e_compound,"is_compound");
            check_sig(id, uses_carry,  e_carry,   "uses_carry ");
            check_sig(id, valid,       e_valid,   "valid      ");
        end
    endtask

    initial begin
        pass_count = 0; fail_count = 0;
        instr_valid = 1;
        instr = 32'h0;

        $display("============================================================");
        $display("  Decode Stage Testbench");
        $display("============================================================");

        //        Arithmetic / Logic                                                                                                                                                 
        $display("\n--- Arithmetic / Logic ---");

        // ADD R3, R1, R2  (3-address, mode=00)
        instr = mk_std(8'h00, 2'b00, 4'h3, 4'h1, 4'h2);
        check_instr(1, "ADD R3,R1,R2 (mode=00)",
            2'b00, 6'h00, 4'h3, 4'h1, 4'h2, 2'b00,
            1,0,0, 0,0,0, 0,0,0, 1);

        // ADC R5, R5, R4  (2-address, mode=01)
        instr = mk_std(8'h01, 2'b01, 4'h5, 4'h5, 4'h4);
        check_instr(2, "ADC R5,R5,R4 (mode=01, uses_carry)",
            2'b00, 6'h01, 4'h5, 4'h5, 4'h4, 2'b01,
            1,0,0, 0,0,0, 0,0,1, 1);

        // SUB R2, R2, #10  (immediate, mode=10)
        // In immediate mode W2=imm=0x0A, so src2_addr gets lower nibble of W2 (0xA)
        // The execute stage ignores src2_addr when mode=10; value is don't-care
        instr = mk_imm(8'h02, 4'h2, 8'h0A);
        check_instr(3, "SUB R2,R2,#10 (mode=10)",
            2'b00, 6'h02, 4'h2, 4'h0, 4'hA, 2'b10,
            1,0,0, 0,0,0, 0,0,0, 1);

        // SBC R1, R1, R0 (mode=01, uses_carry)
        instr = mk_std(8'h03, 2'b01, 4'h1, 4'h1, 4'h0);
        check_instr(4, "SBC R1,R1,R0 (uses_carry)",
            2'b00, 6'h03, 4'h1, 4'h1, 4'h0, 2'b01,
            1,0,0, 0,0,0, 0,0,1, 1);

        // AND R4, R2, R3
        instr = mk_std(8'h04, 2'b00, 4'h4, 4'h2, 4'h3);
        check_instr(5, "AND R4,R2,R3",
            2'b00, 6'h04, 4'h4, 4'h2, 4'h3, 2'b00,
            1,0,0, 0,0,0, 0,0,0, 1);

        // CMP R1, R2     no reg write
        instr = mk_std(8'h09, 2'b01, 4'h1, 4'h1, 4'h2);
        check_instr(6, "CMP R1,R2 (no reg_wr_en)",
            2'b00, 6'h09, 4'h1, 4'h1, 4'h2, 2'b01,
            0,0,0, 0,0,0, 0,0,0, 1);

        //        Shift / Rotate                                                                                                                                                             
        $display("\n--- Shift / Rotate ---");

        // ROL R3
        instr = mk_std(8'h0A, 2'b01, 4'h3, 4'h3, 4'h0);
        check_instr(7, "ROL R3",
            2'b01, 6'h00, 4'h3, 4'h3, 4'h0, 2'b01,
            1,0,0, 0,0,0, 0,0,0, 1);

        // SZR R7
        instr = mk_std(8'h10, 2'b01, 4'h7, 4'h7, 4'h0);
        check_instr(8, "SZR R7",
            2'b01, 6'h06, 4'h7, 4'h7, 4'h0, 2'b01,
            1,0,0, 0,0,0, 0,0,0, 1);

        // RIR R2
        instr = mk_std(8'h11, 2'b01, 4'h2, 4'h2, 4'h0);
        check_instr(9, "RIR R2",
            2'b01, 6'h07, 4'h2, 4'h2, 4'h0, 2'b01,
            1,0,0, 0,0,0, 0,0,0, 1);

        //        Bit Manipulation                                                                                                                                                       
        $display("\n--- Bit Manipulation ---");

        // INV R5
        instr = mk_std(8'h12, 2'b01, 4'h5, 4'h5, 4'h0);
        check_instr(10, "INV R5",
            2'b10, 6'h00, 4'h5, 4'h5, 4'h0, 2'b01,
            1,0,0, 0,0,0, 0,0,0, 1);

        // REV R1
        instr = mk_std(8'h1D, 2'b01, 4'h1, 4'h1, 4'h0);
        check_instr(11, "REV R1",
            2'b10, 6'h0B, 4'h1, 4'h1, 4'h0, 2'b01,
            1,0,0, 0,0,0, 0,0,0, 1);

        // RHO R4
        instr = mk_std(8'h25, 2'b01, 4'h4, 4'h4, 4'h0);
        check_instr(12, "RHO R4",
            2'b10, 6'h13, 4'h4, 4'h4, 4'h0, 2'b01,
            1,0,0, 0,0,0, 0,0,0, 1);

        //        Jumps                                                                                                                                                                                        
        $display("\n--- Jumps ---");

        // JMP R1
        instr = mk_jmp(8'h26, 4'h1);
        check_instr(13, "JMP R1",
            2'b00, 6'h00, 4'h1, 4'h1, 4'h0, 2'b00,
            0,0,0, 0,0,0, 1,0,0, 1);

        // JMZ R3
        instr = mk_jmp(8'h27, 4'h3);
        check_instr(14, "JMZ R3",
            2'b00, 6'h00, 4'h3, 4'h3, 4'h0, 2'b00,
            0,0,0, 0,0,0, 1,0,0, 1);

        // JMN R5
        instr = mk_jmp(8'h28, 4'h5);
        check_instr(15, "JMN R5",
            2'b00, 6'h00, 4'h5, 4'h5, 4'h0, 2'b00,
            0,0,0, 0,0,0, 1,0,0, 1);

        //        MOV                                                                                                                                                                                              
        $display("\n--- MOV ---");

        // MOV R2, R5 (mode=00, reg-to-reg)
        instr = mk_std(8'h2D, 2'b00, 4'h2, 4'h5, 4'h0);
        check_instr(16, "MOV R2,R5 (reg)",
            2'b11, 6'h00, 4'h2, 4'h5, 4'h0, 2'b00,
            1,0,0, 0,0,0, 0,0,0, 1);

        // MOV R2, [MAR] (mode=11, from memory)
        instr = mk_mar(8'h2D, 4'h2);
        check_instr(17, "MOV R2,[MAR] (mem_rd_en)",
            2'b11, 6'h00, 4'h2, 4'h0, 4'h0, 2'b11,
            1,1,0, 0,0,0, 0,0,0, 1);

        //        MAR operations                                                                                                                                                             
        $display("\n--- MAR operations ---");

        // LMAR 0x1A2B
        instr = mk_lmar(16'h1A2B);
        #1;
        $display("  [18] LMAR 0x1A2B");
        check_sig(18, mar_wr_en, 1,        "mar_wr_en");
        check_sig(18, imm_wide,  16'h1A2B, "imm_wide ");
        check_sig(18, reg_wr_en, 0,        "reg_wr_en");
        check_sig(18, valid,     1,        "valid    ");

        // SMAR R3
        instr = mk_mar(8'h2F, 4'h3);
        #1;
        $display("  [19] SMAR R3");
        check_sig(19, mar_wr_en,  1,    "mar_wr_en ");
        check_sig(19, src1_addr,  4'h3, "src1_addr ");
        check_sig(19, reg_wr_en,  0,    "reg_wr_en ");

        // LOAD R4 (from MAR)
        instr = mk_mar(8'h30, 4'h4);
        check_instr(20, "LOAD R4",
            2'b00, 6'h00, 4'h4, 4'h0, 4'h0, 2'b11,
            1,1,0, 0,0,0, 0,0,0, 1);

        // STOR R5 (to MAR)
        instr = mk_mar(8'h31, 4'h5);
        #1;
        $display("  [21] STOR R5");
        check_sig(21, mem_wr_en,  1,    "mem_wr_en ");
        check_sig(21, src1_addr,  4'h5, "src1_addr ");
        check_sig(21, reg_wr_en,  0,    "reg_wr_en ");

        // IMAR
        instr = {8'h32, 24'h000000};
        #1;
        $display("  [22] IMAR");
        check_sig(22, mar_inc,   1, "mar_inc");
        check_sig(22, mar_dec,   0, "mar_dec");
        check_sig(22, mar_wr_en, 0, "mar_wr_en");

        // DMAR
        instr = {8'h33, 24'h000000};
        #1;
        $display("  [23] DMAR");
        check_sig(23, mar_dec,   1, "mar_dec");
        check_sig(23, mar_inc,   0, "mar_inc");

        //        Compound ops                                                                                                                                                                   
        $display("\n--- Compound ops ---");

        // SLE R1, R2, R3, R4
        instr = mk_compound(8'h36, 4'h1, 4'h2, 4'h3, 4'h4);
        #1;
        $display("  [24] SLE R1,R2,R3,R4");
        check_sig(24, alu_group,   2'b00,  "alu_group  ");
        check_sig(24, alu_op,      6'h02,  "alu_op     ");
        check_sig(24, src1_addr,   4'h1,   "src1_addr  ");
        check_sig(24, src2_addr,   4'h2,   "src2_addr  ");
        check_sig(24, dst_addr,    4'h3,   "dst_addr   ");
        check_sig(24, jmp_addr,    4'h4,   "jmp_addr   ");
        check_sig(24, reg_wr_en,   1,      "reg_wr_en  ");
        check_sig(24, is_branch,   1,      "is_branch  ");
        check_sig(24, is_compound, 1,      "is_compound");

        // ALE R2, R3, R5, R6
        instr = mk_compound(8'h34, 4'h2, 4'h3, 4'h5, 4'h6);
        #1;
        $display("  [25] ALE R2,R3,R5,R6");
        check_sig(25, alu_op,      6'h00, "alu_op (ADD)");
        check_sig(25, src1_addr,   4'h2,  "src1_addr   ");
        check_sig(25, dst_addr,    4'h5,  "dst_addr    ");
        check_sig(25, jmp_addr,    4'h6,  "jmp_addr    ");
        check_sig(25, is_compound, 1,     "is_compound ");

        // DJN R7, R8
        instr = mk_compound(8'h35, 4'h7, 4'h0, 4'h0, 4'h8);
        #1;
        $display("  [26] DJN R7,R8");
        check_sig(26, src1_addr,   4'h7, "src1_addr (dec reg)");
        check_sig(26, dst_addr,    4'h7, "dst_addr  (writeback)");
        check_sig(26, jmp_addr,    4'h8, "jmp_addr            ");
        check_sig(26, is_compound, 1,    "is_compound         ");

        //        instr_valid = 0 suppresses valid                                                                                                       
        $display("\n--- instr_valid = 0 ---");
        instr_valid = 0;
        instr = mk_std(8'h00, 2'b00, 4'h1, 4'h2, 4'h3); // ADD
        #1;
        $display("  [27] valid=0 when instr_valid=0");
        check_sig(27, valid, 0, "valid suppressed");
        instr_valid = 1;

        //        Undefined opcode                                                                                                                                                       
        $display("\n--- Undefined opcode ---");
        instr = {8'hFF, 24'h000000};
        #1;
        $display("  [28] Undefined opcode 0xFF");
        check_sig(28, valid, 0, "valid=0 for undefined opcode");

        //        Immediate value extraction                                                                                                                            
        $display("\n--- Immediate extraction ---");
        instr = mk_imm(8'h00, 4'h3, 8'hA5);
        #1;
        $display("  [29] ADD R3, #0xA5     immediate field");
        check_sig(29, imm,      8'hA5, "imm     ");
        check_sig(29, dst_addr, 4'h3,  "dst_addr");
        check_sig(29, mode,     2'b10, "mode=10 ");

        //        Summary                                                                                                                                                                                  
        $display("\n============================================================");
        $display("  Results: %0d passed, %0d failed  (total: %0d)",
                 pass_count, fail_count, pass_count + fail_count);
        $display("============================================================");
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  *** FAILURES DETECTED ***");

        $finish;
    end

endmodule
