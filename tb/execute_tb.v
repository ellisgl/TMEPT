// ============================================================================
// execute_tb.v     Testbench for the execute stage
// ============================================================================

`timescale 1ns/1ps
`include "rtl/execute.v"

module execute_tb;

    reg         clk, rst_n;
    reg  [31:0] instr;
    reg         instr_valid;
    reg  [7:0]  mem_rd_data;

    wire [15:0] mar;
    wire [7:0]  mem_wr_data;
    wire        mem_wr_en;
    wire        pc_load_en;
    wire [15:0] pc_load_val;
    wire [4:0]  flags;
    wire        stall;

    execute dut (
        .clk(clk), .rst_n(rst_n), .instr(instr), .instr_valid(instr_valid),
        .mem_rd_data(mem_rd_data), .mar(mar), .mem_wr_data(mem_wr_data),
        .mem_wr_en(mem_wr_en), .pc_load_en(pc_load_en), .pc_load_val(pc_load_val),
        .flags(flags), .stall(stall)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    wire flag_Z = flags[0], flag_N = flags[1], flag_C = flags[2];
    wire flag_V = flags[3], flag_O = flags[4];

    integer pass_count, fail_count;

    task check;
        input [63:0] id; input [31:0] got, exp; input [239:0] label;
        begin
            if (got !== exp) begin
                $display("  FAIL [%0d] %s: got 0x%0h, exp 0x%0h", id, label, got, exp);
                fail_count = fail_count + 1;
            end else begin
                $display("  PASS [%0d] %s", id, label);
                pass_count = pass_count + 1;
            end
        end
    endtask

    function [31:0] mk_std;
        input [7:0] opc; input [1:0] md; input [3:0] dst, s1, s2;
        mk_std = {opc, md, dst, 2'b00, s1, s2, 8'h00};
    endfunction
    function [31:0] mk_imm;
        input [7:0] opc; input [3:0] dst; input [7:0] imm;
        mk_imm = {opc, 2'b10, dst, 2'b00, imm, 8'h00};
    endfunction
    function [31:0] mk_jmp;
        input [7:0] opc; input [3:0] tgt;
        mk_jmp = {opc, 2'b00, tgt, 2'b00, 8'h00, 8'h00};
    endfunction
    function [31:0] mk_cmp;
        input [3:0] reg_n; input [7:0] imm;
        mk_cmp = {8'h09, 2'b10, reg_n, 2'b00, imm, 8'h00};
    endfunction

    //        Timing model                                                                                                                                                                               
    // clk1: instr presented     instr_r/valid_r latched
    // clk2: valid_r=1, ALU runs, flags_r/pc_load_en/wr_a_en registered in execute
    // clk3: wr_a_en seen by reg_file, register write committed
    //
    // issue2 = wait clk1+clk2: read flags, pc_load_en, MAR, mem_wr_en
    // issue3 = wait clk1+clk2+clk3: read register values after writeback

    task issue2;
        input [31:0] i;
        begin
            instr = i; instr_valid = 1;
            @(posedge clk); #1;
            instr_valid = 0; instr = 32'h0;
            @(posedge clk); #1;
        end
    endtask

    task issue3;
        input [31:0] i;
        begin
            instr = i; instr_valid = 1;
            @(posedge clk); #1;
            instr_valid = 0; instr = 32'h0;
            @(posedge clk); #1;
            @(posedge clk); #1;
        end
    endtask

    task load_reg;
        input [3:0] reg_n; input [7:0] val;
        begin
            // Zero the register first (XOR Rn,Rn,Rn = 0), then ADD #val
            issue3(mk_std(8'h08, 2'b00, reg_n, reg_n, reg_n)); // XOR Rn=0
            issue3(mk_imm(8'h00, reg_n, val));                  // ADD Rn,#val
        end
    endtask

    initial begin
        pass_count = 0; fail_count = 0;
        instr = 32'h0; instr_valid = 0; mem_rd_data = 8'h00;

        $display("============================================================");
        $display("  Execute Stage Testbench");
        $display("============================================================");

        //        Reset                                                                                                                                                                                        
        $display("\n--- Reset ---");
        rst_n = 0; @(posedge clk); #1; @(posedge clk); #1;
        rst_n = 1; #1;
        check(1, flags,      5'b00000, "flags = 0 after reset");
        check(2, mar,        16'h0000, "MAR = 0 after reset");
        check(3, pc_load_en, 0,        "pc_load_en = 0 after reset");

        //        ADD R1=10                                                                                                                                                                            
        $display("\n--- ADD immediate: R1 = 10 ---");
        issue2(mk_imm(8'h00, 4'h1, 8'h0A));
        check(4, flag_Z, 0, "Z=0 (result non-zero)");
        check(5, flag_N, 0, "N=0 (result positive)");
        check(6, flag_C, 0, "C=0 (no carry)");
        @(posedge clk); #1; // commit R1 writeback

        //        ADD R2=20                                                                                                                                                                            
        $display("\n--- ADD immediate: R2 = 20 ---");
        load_reg(4'h2, 8'h14);

        //        ADD 3-address R3=R1+R2                                                                                                                                     
        $display("\n--- ADD 3-address: R3 = R1 + R2 ---");
        issue3(mk_std(8'h00, 2'b00, 4'h3, 4'h1, 4'h2));
        issue2(mk_cmp(4'h3, 8'h1E)); // CMP R3,#30
        check(7, flag_Z, 1, "Z=1: R3 == 30");
        check(8, flag_N, 0, "N=0");
        @(posedge clk); #1;

        //        SUB R5=R1-R2                                                                                                                                                                   
        $display("\n--- SUB: R5 = R1 - R2 (10-20=-10) ---");
        issue3(mk_std(8'h02, 2'b00, 4'h5, 4'h1, 4'h2));
        issue2(mk_cmp(4'h5, 8'hF6)); // CMP R5,#0xF6
        check(9,  flag_Z, 1, "Z=1: R5 == 0xF6 (-10)");
        check(10, flag_N, 0, "N=0 after CMP");
        @(posedge clk); #1;
        issue2(mk_std(8'h02, 2'b00, 4'h5, 4'h1, 4'h2));
        check(11, flag_N, 1, "N=1: result negative");
        check(12, flag_C, 1, "C=1: borrow occurred");
        @(posedge clk); #1;

        //        Overflow                                                                                                                                                                               
        $display("\n--- ADD overflow: 127+1 ---");
        load_reg(4'h6, 8'h7F); load_reg(4'h7, 8'h01);
        issue2(mk_std(8'h00, 2'b00, 4'h8, 4'h6, 4'h7));
        check(13, flag_V, 1, "V=1: signed overflow");
        check(14, flag_N, 1, "N=1: result looks negative");
        check(15, flag_Z, 0, "Z=0: result non-zero");
        @(posedge clk); #1;

        //        Zero flag                                                                                                                                                                            
        $display("\n--- Zero flag: R1 - R1 ---");
        issue2(mk_std(8'h02, 2'b00, 4'h9, 4'h1, 4'h1));
        check(16, flag_Z, 1, "Z=1: result is zero");
        check(17, flag_N, 0, "N=0");
        check(18, flag_C, 0, "C=0: no borrow");
        @(posedge clk); #1;

        //        AND                                                                                                                                                                                              
        $display("\n--- AND: 0xF0 & 0x0F = 0x00 ---");
        load_reg(4'h1, 8'hF0); load_reg(4'h2, 8'h0F);
        issue2(mk_std(8'h04, 2'b00, 4'h3, 4'h1, 4'h2));
        check(19, flag_Z, 1, "Z=1: 0xF0 & 0x0F = 0");
        @(posedge clk); #1;

        //        XOR parity                                                                                                                                                                         
        $display("\n--- XOR: odd parity flag ---");
        load_reg(4'h1, 8'hFF); load_reg(4'h2, 8'h00);
        issue2(mk_std(8'h08, 2'b00, 4'h3, 4'h1, 4'h2));
        check(20, flag_O, 0, "O=0: 0xFF has even parity");
        @(posedge clk); #1;
        load_reg(4'h1, 8'h01);
        issue2(mk_std(8'h08, 2'b00, 4'h3, 4'h1, 4'h2));
        check(21, flag_O, 1, "O=1: 0x01 has odd parity");
        @(posedge clk); #1;

        //        LMAR                                                                                                                                                                                           
        $display("\n--- LMAR 0x1234 ---");
        issue2({8'h2E, 8'h12, 8'h34, 8'h00});
        @(posedge clk); #1;
        check(22, mar, 16'h1234, "MAR = 0x1234 after LMAR");

        //        IMAR / DMAR                                                                                                                                                                      
        $display("\n--- IMAR / DMAR ---");
        issue2({8'h32, 8'h00, 8'h00, 8'h00});
        @(posedge clk); #1;
        check(23, mar, 16'h1235, "MAR = 0x1235 after IMAR");
        issue2({8'h33, 8'h00, 8'h00, 8'h00});
        @(posedge clk); #1;
        check(24, mar, 16'h1234, "MAR = 0x1234 after DMAR");

        //        LOAD                                                                                                                                                                                           
        $display("\n--- LOAD R1 from memory ---");
        mem_rd_data = 8'hAB;
        issue3({8'h30, 2'b11, 4'h1, 2'b00, 8'h00, 8'h00});
        issue2(mk_cmp(4'h1, 8'hAB));
        check(25, flag_Z, 1, "Z=1: R1 loaded 0xAB from memory");
        @(posedge clk); #1;

        //        STOR                                                                                                                                                                                           
        $display("\n--- STOR: write R2 to memory ---");
        load_reg(4'h2, 8'h5A);
        instr = {8'h31, 2'b11, 4'h2, 2'b00, 8'h00, 8'h00};
        instr_valid = 1;
        @(posedge clk); #1;
        // clk1+#1: valid_r=1, instr_r=STOR     check combinational mem_wr_en HERE,
        // before the next posedge overwrites valid_r to 0.
        check(26, mem_wr_en,   1,     "mem_wr_en=1 during STOR");
        check(27, mem_wr_data, 8'h5A, "mem_wr_data=0x5A");
        instr_valid = 0; instr = 32'h0;
        @(posedge clk); #1; // clk2: execute fires (old valid_r=1), updates valid_r to 0
        @(posedge clk); #1; // clk3: reg-file writeback window

        //        JMP                                                                                                                                                                                              
        $display("\n--- JMP unconditional ---");
        load_reg(4'h5, 8'h80); // R5 = 0x0080
        // pc_load_val is a combinational wire (rd_data0     regs[src1_addr]).
        // It is only valid while instr_r holds the JMP and valid_r=1, i.e. at clk1+#1.
        // pc_load_en is registered and is valid at clk2+#1, so we use a manual
        // two-phase sequence: check pc_load_val at clk1+#1, then check pc_load_en
        // at clk2+#1.
        instr = mk_jmp(8'h26, 4'h5); instr_valid = 1;
        @(posedge clk); #1;           // clk1+#1: instr_r=JMP, valid_r=1
        instr_valid = 0; instr = 32'h0;
        @(posedge clk); #1;           // clk2+#1: execute fired; pc_load_en and pc_load_val both registered
        check(28, pc_load_en,  1,        "pc_load_en=1 for JMP");
        check(29, pc_load_val, 16'h0080, "pc_load_val=0x0080");
        @(posedge clk); #1;

        //        JMZ taken                                                                                                                                                                            
        $display("\n--- JMZ: taken when Z=1 ---");
        issue2(mk_std(8'h02, 2'b00, 4'h9, 4'h1, 4'h1)); // Z=1
        issue2(mk_jmp(8'h27, 4'h5));
        check(30, pc_load_en, 1, "JMZ taken when Z=1");
        @(posedge clk); #1;

        //        JMZ not taken                                                                                                                                                                
        $display("\n--- JMZ: not taken when Z=0 ---");
        issue2(mk_imm(8'h00, 4'h1, 8'h01)); // Z=0
        issue2(mk_jmp(8'h27, 4'h5));
        check(31, pc_load_en, 0, "JMZ not taken when Z=0");
        @(posedge clk); #1;

        //        JNE                                                                                                                                                                                              
        $display("\n--- JNE: taken when Z=0 ---");
        issue2(mk_imm(8'h00, 4'h1, 8'h05));
        issue2(mk_jmp(8'h38, 4'h5));
        check(32, pc_load_en, 1, "JNE taken when Z=0");
        @(posedge clk); #1;

        //        JMG                                                                                                                                                                                              
        // Zero R1 first so R1+5 = 5 (positive, non-zero) regardless of any
        // accumulated value from prior tests, then check Z=0 AND N=0.
        $display("\n--- JMG: taken when Z=0 AND N=0 ---");
        issue3(mk_std(8'h08, 2'b00, 4'h1, 4'h1, 4'h1)); // XOR R1,R1,R1     R1=0
        issue2(mk_imm(8'h00, 4'h1, 8'h05));              // ADD R1,#5     flags: Z=0,N=0
        issue2(mk_jmp(8'h29, 4'h5));
        check(33, pc_load_en, 1, "JMG taken");
        @(posedge clk); #1;

        //        JMN                                                                                                                                                                                              
        // Zero R1 first so ADD R1,#0x80 gives result=0x80 (bit7=1     N=1) cleanly.
        $display("\n--- JMN: taken when N=1 ---");
        issue3(mk_std(8'h08, 2'b00, 4'h1, 4'h1, 4'h1)); // XOR R1,R1,R1     R1=0
        issue2(mk_imm(8'h00, 4'h1, 8'h80));              // ADD R1,#0x80     flags: N=1
        issue2(mk_jmp(8'h28, 4'h5));
        check(34, pc_load_en, 1, "JMN taken when N=1");
        @(posedge clk); #1;

        //        JGE                                                                                                                                                                                              
        $display("\n--- JGE: taken when N=V ---");
        issue2(mk_jmp(8'h39, 4'h5)); // N=1,V=0 from prev     not taken
        check(35, pc_load_en, 0, "JGE not taken when N!=V");
        @(posedge clk); #1;
        load_reg(4'h6, 8'h7F); load_reg(4'h7, 8'h01);
        issue2(mk_std(8'h00, 2'b00, 4'h8, 4'h6, 4'h7)); // N=1,V=1
        issue2(mk_jmp(8'h39, 4'h5));
        check(36, pc_load_en, 1, "JGE taken when N=V=1");
        @(posedge clk); #1;

        //        JLE                                                                                                                                                                                              
        $display("\n--- JLE: taken when Z=1 ---");
        issue2(mk_std(8'h02, 2'b00, 4'h9, 4'h1, 4'h1)); // Z=1
        issue2(mk_jmp(8'h3A, 4'h5));
        check(37, pc_load_en, 1, "JLE taken when Z=1");
        @(posedge clk); #1;

        //        DJN compound loop                                                                                                                                                    
        $display("\n--- DJN compound loop ---");
        load_reg(4'h1, 8'h03);
        load_reg(4'h5, 8'h80);

        instr = {8'h35, 4'h1, 4'h0, 4'h0, 4'h0, 4'h5, 4'h0};
        instr_valid = 1;
        @(posedge clk); #1; instr_valid = 0; instr = 32'h0;
        @(posedge clk); #1;
        check(38, pc_load_en, 1, "DJN taken: R1=3->2, non-zero");
        @(posedge clk); #1;

        instr = {8'h35, 4'h1, 4'h0, 4'h0, 4'h0, 4'h5, 4'h0};
        instr_valid = 1;
        @(posedge clk); #1; instr_valid = 0; instr = 32'h0;
        @(posedge clk); #1;
        check(39, pc_load_en, 1, "DJN taken: R1=2->1, non-zero");
        @(posedge clk); #1;

        instr = {8'h35, 4'h1, 4'h0, 4'h0, 4'h0, 4'h5, 4'h0};
        instr_valid = 1;
        @(posedge clk); #1; instr_valid = 0; instr = 32'h0;
        @(posedge clk); #1;
        check(40, pc_load_en, 0, "DJN not taken: R1=1->0, zero");
        @(posedge clk); #1;

        //        LOAD/STOR flag preservation                                                                                                                      
        // Regression test for the bug where LOAD/STOR inadvertently clobbered
        // flags because decode.v left alu_group = GRP_ARITH (default) instead
        // of GRP_SPEC, causing the execute stage's flag-update gate to fire.
        $display("\n--- LOAD does not clobber flags ---");
        // Set a known flag state: Z=1 (SUB R1-R1)
        issue2(mk_std(8'h02, 2'b00, 4'h9, 4'h1, 4'h1)); // Z=1
        check(41, flag_Z, 1, "Z=1 before LOAD");
        @(posedge clk); #1;
        // Now LOAD R4 from memory (mem_rd_data still 0xAB from earlier test)
        mem_rd_data = 8'hFF; // use a value that would set N=1 and O=1 if flags were updated
        issue2({8'h30, 2'b11, 4'h4, 2'b00, 8'h00, 8'h00});
        check(42, flag_Z, 1, "Z still 1 after LOAD (flags preserved)");
        check(43, flag_N, 0, "N still 0 after LOAD (flags preserved)");
        @(posedge clk); #1;

        $display("\n--- STOR does not clobber flags ---");
        // Set a known flag state: Z=1 again
        issue2(mk_std(8'h02, 2'b00, 4'h9, 4'h1, 4'h1)); // Z=1
        check(44, flag_Z, 1, "Z=1 before STOR");
        @(posedge clk); #1;
        // STOR R2 (=0x5A from earlier) to memory
        instr = {8'h31, 2'b11, 4'h2, 2'b00, 8'h00, 8'h00};
        instr_valid = 1;
        @(posedge clk); #1; instr_valid = 0; instr = 32'h0;
        @(posedge clk); #1;
        check(45, flag_Z, 1, "Z still 1 after STOR (flags preserved)");
        check(46, flag_N, 0, "N still 0 after STOR (flags preserved)");
        @(posedge clk); #1;

        $display("\n--- LMAR/IMAR/DMAR do not clobber flags ---");
        issue2(mk_std(8'h02, 2'b00, 4'h9, 4'h1, 4'h1)); // Z=1
        check(47, flag_Z, 1, "Z=1 before LMAR");
        @(posedge clk); #1;
        issue2({8'h2E, 8'hAB, 8'hCD, 8'h00}); // LMAR 0xABCD
        @(posedge clk); #1;
        check(48, flag_Z, 1, "Z still 1 after LMAR (flags preserved)");
        issue2({8'h32, 8'h00, 8'h00, 8'h00}); // IMAR
        @(posedge clk); #1;
        check(49, flag_Z, 1, "Z still 1 after IMAR (flags preserved)");
        issue2({8'h33, 8'h00, 8'h00, 8'h00}); // DMAR
        @(posedge clk); #1;
        check(50, flag_Z, 1, "Z still 1 after DMAR (flags preserved)");

        //        Summary                                                                                                                                                                                  
        $display("\n============================================================");
        $display("  Results: %0d passed, %0d failed  (total: %0d)",
                 pass_count, fail_count, pass_count + fail_count);
        $display("============================================================");
        if (fail_count == 0) $display("  ALL TESTS PASSED");
        else $display("  *** FAILURES DETECTED ***");
        $finish;
    end

endmodule
