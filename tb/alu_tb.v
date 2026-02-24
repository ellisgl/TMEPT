// ============================================================================
// alu_tb.v     Testbench for the 8-bit CPU ALU
// ----------------------------------------------------------------------------
// Tests every operation across all three functional units.
// Checks result and all four flags for each case.
//
// Run with:  iverilog -o alu_tb alu_tb.v && vvp alu_tb
// ============================================================================

`timescale 1ns/1ps
`include "rtl/alu.v"

module alu_tb;

    //        DUT ports                                                                                                                                                                                     
    reg  [7:0] operand_a;
    reg  [7:0] operand_b;
    reg  [1:0] alu_group;
    reg  [5:0] alu_op;
    reg        carry_in;

    wire [7:0] result;
    wire       flag_z, flag_n, flag_c, flag_v;

    alu dut (
        .operand_a  (operand_a),
        .operand_b  (operand_b),
        .alu_group  (alu_group),
        .alu_op     (alu_op),
        .carry_in   (carry_in),
        .result     (result),
        .flag_z     (flag_z),
        .flag_n     (flag_n),
        .flag_c     (flag_c),
        .flag_v     (flag_v)
    );

    //        Tracking                                                                                                                                                                                        
    integer pass_count;
    integer fail_count;

    //        Task: check one result                                                                                                                                                 
    task check;
        input [63:0]  test_id;
        input [7:0]   exp_result;
        input         exp_z, exp_n, exp_c, exp_v;
        input [239:0] label;
        begin
            #1;
            if (result !== exp_result || flag_z !== exp_z ||
                flag_n !== exp_n || flag_c !== exp_c || flag_v !== exp_v) begin
                $display("FAIL [%0d] %s", test_id, label);
                $display("       A=%b B=%b grp=%b op=%b cin=%b",
                         operand_a, operand_b, alu_group, alu_op, carry_in);
                $display("       result: got %b (%0d), exp %b (%0d)",
                         result, $signed(result), exp_result, $signed(exp_result));
                $display("       flags Z=%b N=%b C=%b V=%b  exp Z=%b N=%b C=%b V=%b",
                         flag_z, flag_n, flag_c, flag_v,
                         exp_z,  exp_n,  exp_c,  exp_v);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS [%0d] %s", test_id, label);
                pass_count = pass_count + 1;
            end
        end
    endtask

    //        Test stimulus                                                                                                                                                                            
    initial begin
        pass_count = 0;
        fail_count = 0;
        carry_in   = 0;
        operand_a  = 0;
        operand_b  = 0;
        alu_group  = 0;
        alu_op     = 0;

        $display("============================================================");
        $display("  8-bit CPU ALU Testbench");
        $display("============================================================");

        //                                                                                                                                                                                                 
        // GROUP 00: ARITHMETIC / LOGIC
        //                                                                                                                                                                                                 
        $display("\n--- Arithmetic / Logic (group=00) ---");
        alu_group = 2'b00;

        //        ADD                                                                                                                                                                               
        alu_op = 4'h0;
        operand_a = 8'd5;   operand_b = 8'd3;   carry_in = 0;
        check(1,  8'd8,   0,0,0,0, "ADD  5 + 3 = 8");

        operand_a = 8'd0;   operand_b = 8'd0;
        check(2,  8'd0,   1,0,0,0, "ADD  0 + 0 = 0 (Z)");

        // +127 + 1     overflow: 0111_1111 + 0000_0001 = 1000_0000 = -128
        operand_a = 8'h7F;  operand_b = 8'h01;
        check(3,  8'h80,  0,1,0,1, "ADD  +127 + 1 = overflow     -128 (N,V)");

        // -1 + -1 = -2, carry out
        operand_a = 8'hFF;  operand_b = 8'hFF;
        check(4,  8'hFE,  0,1,1,0, "ADD  -1 + -1 = -2 (N,C)");

        // -128 + -1     overflow: 1000_0000 + 1111_1111 = wraps to +127
        operand_a = 8'h80;  operand_b = 8'hFF;
        check(5,  8'h7F,  0,0,1,1, "ADD  -128 + -1 = overflow     +127 (C,V)");

        // unsigned carry: 255 + 1 = 0 with carry
        operand_a = 8'hFF;  operand_b = 8'h01;
        check(6,  8'h00,  1,0,1,0, "ADD  255 + 1 = 0 (Z,C)");

        //        ADC                                                                                                                                                                               
        alu_op = 4'h1;
        operand_a = 8'd5;   operand_b = 8'd3;   carry_in = 1;
        check(7,  8'd9,   0,0,0,0, "ADC  5 + 3 + 1 = 9");

        operand_a = 8'd0;   operand_b = 8'd0;   carry_in = 1;
        check(8,  8'd1,   0,0,0,0, "ADC  0 + 0 + 1 = 1");

        carry_in = 0;
        operand_a = 8'd10;  operand_b = 8'd20;
        check(9,  8'd30,  0,0,0,0, "ADC  10 + 20 + 0 = 30");

        //        SUB                                                                                                                                                                               
        alu_op = 4'h2;   carry_in = 0;
        operand_a = 8'd10;  operand_b = 8'd3;
        check(10, 8'd7,   0,0,0,0, "SUB  10 - 3 = 7");

        operand_a = 8'd5;   operand_b = 8'd5;
        check(11, 8'd0,   1,0,0,0, "SUB  5 - 5 = 0 (Z)");

        // 3 - 10 = -7 (negative, borrow)
        operand_a = 8'd3;   operand_b = 8'd10;
        check(12, 8'hF9,  0,1,1,0, "SUB  3 - 10 = -7 (N, borrow   C)");

        // overflow: -128 - 1     wraps to +127 (no borrow: C=0)
        operand_a = 8'h80;  operand_b = 8'h01;
        check(13, 8'h7F,  0,0,0,1, "SUB  -128 - 1 = overflow     +127 (V)");

        // overflow: +127 - (-1)     wraps to -128 (borrow: C=1)
        operand_a = 8'h7F;  operand_b = 8'hFF;
        check(14, 8'h80,  0,1,1,1, "SUB  +127 - (-1) = overflow     -128 (N,C,V)");

        //        SBC                                                                                                                                                                               
        alu_op = 4'h3;
        operand_a = 8'd10;  operand_b = 8'd3;   carry_in = 1;
        check(15, 8'd6,   0,0,0,0, "SBC  10 - 3 - 1 = 6");

        carry_in = 0;
        operand_a = 8'd10;  operand_b = 8'd3;
        check(16, 8'd7,   0,0,0,0, "SBC  10 - 3 - 0 = 7");

        //        AND                                                                                                                                                                               
        alu_op = 4'h4;   carry_in = 0;
        operand_a = 8'hAA;  operand_b = 8'hF0;
        check(17, 8'hA0,  0,1,0,0, "AND  0xAA & 0xF0 = 0xA0 (N)");

        operand_a = 8'hFF;  operand_b = 8'h00;
        check(18, 8'h00,  1,0,0,0, "AND  0xFF & 0x00 = 0x00 (Z)");

        //        OR                                                                                                                                                                                  
        alu_op = 4'h5;
        operand_a = 8'hAA;  operand_b = 8'h55;
        check(19, 8'hFF,  0,1,0,0, "OR   0xAA | 0x55 = 0xFF (N)");

        operand_a = 8'h00;  operand_b = 8'h00;
        check(20, 8'h00,  1,0,0,0, "OR   0 | 0 = 0 (Z)");

        //        NOR                                                                                                                                                                               
        alu_op = 4'h6;
        operand_a = 8'hAA;  operand_b = 8'h55;
        check(21, 8'h00,  1,0,0,0, "NOR  0xAA | 0x55     ~0xFF = 0x00 (Z)");

        operand_a = 8'h00;  operand_b = 8'h00;
        check(22, 8'hFF,  0,1,0,0, "NOR  0 | 0     ~0 = 0xFF (N)");

        //        NAND                                                                                                                                                                            
        alu_op = 4'h7;
        operand_a = 8'hFF;  operand_b = 8'hFF;
        check(23, 8'h00,  1,0,0,0, "NAND 0xFF & 0xFF     ~0xFF = 0 (Z)");

        operand_a = 8'h00;  operand_b = 8'h00;
        check(24, 8'hFF,  0,1,0,0, "NAND 0 & 0     ~0 = 0xFF (N)");

        //        XOR                                                                                                                                                                               
        alu_op = 4'h8;
        operand_a = 8'hAA;  operand_b = 8'hFF;
        check(25, 8'h55,  0,0,0,0, "XOR  0xAA ^ 0xFF = 0x55");

        operand_a = 8'hAB;  operand_b = 8'hAB;
        check(26, 8'h00,  1,0,0,0, "XOR  A ^ A = 0 (Z)");

        //        CMP                                                                                                                                                                               
        alu_op = 4'h9;
        operand_a = 8'd10;  operand_b = 8'd10;
        check(27, 8'd0,   1,0,0,0, "CMP  10 == 10 (Z)");

        operand_a = 8'd5;   operand_b = 8'd10;
        check(28, 8'hFB,  0,1,1,0, "CMP  5 < 10 (N, borrow)");

        operand_a = 8'd10;  operand_b = 8'd5;
        check(29, 8'd5,   0,0,0,0, "CMP  10 > 5");

        //                                                                                                                                                                                                 
        // GROUP 01: SHIFT / ROTATE
        //                                                                                                                                                                                                 
        $display("\n--- Shift / Rotate (group=01) ---");
        alu_group = 2'b01;

        //        ROL                                                                                                                                                                               
        alu_op = 3'h0;
        operand_a = 8'b0000_0001;
        check(30, 8'b0000_0010, 0,0,0,0, "ROL  0x01     0x02");

        // bit7=1 wraps to bit0, sets carry
        operand_a = 8'b1000_0000;
        check(31, 8'b0000_0001, 0,0,1,0, "ROL  0x80     0x01 (C)");

        operand_a = 8'hFF;
        check(32, 8'hFF,       0,1,1,0, "ROL  0xFF     0xFF (all ones, N, C)");

        operand_a = 8'b0100_0000;
        check(33, 8'b1000_0000, 0,1,0,0, "ROL  0x40     0x80 (N)");

        //        SOL                                                                                                                                                                               
        alu_op = 3'h1;
        operand_a = 8'b0000_0000;
        check(34, 8'b0000_0001, 0,0,0,0, "SOL  0x00     0x01 (insert 1)");

        operand_a = 8'b1000_0000;
        check(35, 8'b0000_0001, 0,0,1,0, "SOL  0x80     0x01 (C, insert 1)");

        //        SZL                                                                                                                                                                               
        alu_op = 3'h2;
        operand_a = 8'b0000_0001;
        check(36, 8'b0000_0010, 0,0,0,0, "SZL  0x01     0x02 (insert 0)");

        operand_a = 8'b1000_0000;
        check(37, 8'b0000_0000, 1,0,1,0, "SZL  0x80     0x00 (Z, C)");

        //        RIL                                                                                                                                                                               
        alu_op = 3'h3;
        // bit7=0     ~0=1 inserted at bit0
        operand_a = 8'b0000_0000;
        check(38, 8'b0000_0001, 0,0,0,0, "RIL  0x00     0x01 (inv carry=1)");

        // bit7=1     ~1=0 inserted at bit0
        operand_a = 8'b1000_0000;
        check(39, 8'b0000_0000, 1,0,1,0, "RIL  0x80     0x00 (Z, C, inv carry=0)");

        //        ROR                                                                                                                                                                               
        alu_op = 3'h4;
        operand_a = 8'b0000_0010;
        check(40, 8'b0000_0001, 0,0,0,0, "ROR  0x02     0x01");

        // bit0=1 wraps to bit7, sets carry
        operand_a = 8'b0000_0001;
        check(41, 8'b1000_0000, 0,1,1,0, "ROR  0x01     0x80 (N, C)");

        operand_a = 8'hFF;
        check(42, 8'hFF,        0,1,1,0, "ROR  0xFF     0xFF (N, C)");

        //        SOR                                                                                                                                                                               
        alu_op = 3'h5;
        operand_a = 8'b0000_0000;
        check(43, 8'b1000_0000, 0,1,0,0, "SOR  0x00     0x80 (insert 1 at top, N)");

        operand_a = 8'b0000_0001;
        check(44, 8'b1000_0000, 0,1,1,0, "SOR  0x01     0x80 (N, C=b0 out)");

        //        SZR                                                                                                                                                                               
        alu_op = 3'h6;
        operand_a = 8'b0000_0010;
        check(45, 8'b0000_0001, 0,0,0,0, "SZR  0x02     0x01");

        operand_a = 8'b1000_0001;
        check(46, 8'b0100_0000, 0,0,1,0, "SZR  0x81     0x40 (C=b0 out)");

        //        RIR                                                                                                                                                                               
        alu_op = 3'h7;
        // bit0=0     ~0=1 inserted at top
        operand_a = 8'b0000_0000;
        check(47, 8'b1000_0000, 0,1,0,0, "RIR  0x00     0x80 (inv carry=1, N)");

        // bit0=1     ~1=0 inserted at top
        operand_a = 8'b0000_0001;
        check(48, 8'b0000_0000, 1,0,1,0, "RIR  0x01     0x00 (Z, C, inv carry=0)");

        //                                                                                                                                                                                                 
        // GROUP 10: BIT MANIPULATION
        //                                                                                                                                                                                                 
        $display("\n--- Bit Manipulation (group=10) ---");
        alu_group = 2'b10;

        //        INV                                                                                                                                                                               
        alu_op = 5'h00;
        operand_a = 8'hAA;
        check(49, 8'h55, 0,0,0,0, "INV  0xAA     0x55");

        operand_a = 8'h00;
        check(50, 8'hFF, 0,1,0,0, "INV  0x00     0xFF (N)");

        operand_a = 8'hFF;
        check(51, 8'h00, 1,0,0,0, "INV  0xFF     0x00 (Z)");

        //        INH                                                                                                                                                                               
        alu_op = 5'h01;
        operand_a = 8'hAA; // 1010_1010     0101_1010
        check(52, 8'h5A, 0,0,0,0, "INH  0xAA     0x5A");

        operand_a = 8'hF0;
        check(53, 8'h00, 1,0,0,0, "INH  0xF0     0x00 (Z)");

        //        INL                                                                                                                                                                               
        alu_op = 5'h02;
        operand_a = 8'hAA; // 1010_1010     1010_0101
        check(54, 8'hA5, 0,1,0,0, "INL  0xAA     0xA5 (N)");

        operand_a = 8'h0F;
        check(55, 8'h00, 1,0,0,0, "INL  0x0F     0x00 (Z)");

        //        INE (flip bits 1,3,5,7     XOR 0xAA)                                                                               
        alu_op = 5'h03;
        operand_a = 8'hAA; // even bits all 1     flip to 0
        check(56, 8'h00, 1,0,0,0, "INE  0xAA     0x00 (Z)");

        operand_a = 8'h00;
        check(57, 8'hAA, 0,1,0,0, "INE  0x00     0xAA (N)");

        //        INO (flip bits 0,2,4,6     XOR 0x55)                                                                               
        alu_op = 5'h04;
        operand_a = 8'h55; // odd bits all 1     flip to 0
        check(58, 8'h00, 1,0,0,0, "INO  0x55     0x00 (Z)");

        operand_a = 8'h00;
        check(59, 8'h55, 0,0,0,0, "INO  0x00     0x55");

        //        IEH (flip bits 5,7     XOR 0xA0)                                                                                           
        alu_op = 5'h05;
        operand_a = 8'hA0;
        check(60, 8'h00, 1,0,0,0, "IEH  0xA0     0x00 (Z)");

        operand_a = 8'h00;
        check(61, 8'hA0, 0,1,0,0, "IEH  0x00     0xA0 (N)");

        //        IOH (flip bits 4,6     XOR 0x50)                                                                                           
        alu_op = 5'h06;
        operand_a = 8'h50;
        check(62, 8'h00, 1,0,0,0, "IOH  0x50     0x00 (Z)");

        operand_a = 8'h00;
        check(63, 8'h50, 0,0,0,0, "IOH  0x00     0x50");

        //        IEL (flip bits 1,3     XOR 0x0A)                                                                                           
        alu_op = 5'h07;
        operand_a = 8'h0A;
        check(64, 8'h00, 1,0,0,0, "IEL  0x0A     0x00 (Z)");

        //        IOL (flip bits 0,2     XOR 0x05)                                                                                           
        alu_op = 5'h08;
        operand_a = 8'h05;
        check(65, 8'h00, 1,0,0,0, "IOL  0x05     0x00 (Z)");

        //        IFB (flip bit 0)                                                                                                                                           
        alu_op = 5'h09;
        operand_a = 8'h01;
        check(66, 8'h00, 1,0,0,0, "IFB  0x01     0x00 (Z)");

        operand_a = 8'h00;
        check(67, 8'h01, 0,0,0,0, "IFB  0x00     0x01");

        //        ILB (flip bit 7)                                                                                                                                           
        alu_op = 5'h0A;
        operand_a = 8'h80;
        check(68, 8'h00, 1,0,0,0, "ILB  0x80     0x00 (Z)");

        operand_a = 8'h00;
        check(69, 8'h80, 0,1,0,0, "ILB  0x00     0x80 (N)");

        //        REV                                                                                                                                                                               
        alu_op = 5'h0B;
        operand_a = 8'b0000_0001; // bit0     bit7
        check(70, 8'b1000_0000, 0,1,0,0, "REV  0x01     0x80 (N)");

        operand_a = 8'b1010_0011; // 0xA3     0xC5
        check(71, 8'b1100_0101, 0,1,0,0, "REV  0xA3     0xC5 (N)");

        operand_a = 8'hFF;
        check(72, 8'hFF, 0,1,0,0, "REV  0xFF     0xFF (N)");

        operand_a = 8'h00;
        check(73, 8'h00, 1,0,0,0, "REV  0x00     0x00 (Z)");

        //        RVL                                                                                                                                                                               
        alu_op = 5'h0C;
        operand_a = 8'b1111_0001; // low nibble 0001     1000
        check(74, 8'b1111_1000, 0,1,0,0, "RVL  0xF1     0xF8 (N)");

        operand_a = 8'b0000_1010; // low 1010     0101
        check(75, 8'b0000_0101, 0,0,0,0, "RVL  0x0A     0x05");

        //        RVH                                                                                                                                                                               
        alu_op = 5'h0D;
        operand_a = 8'b0001_1111; // high nibble 0001     1000
        check(76, 8'b1000_1111, 0,1,0,0, "RVH  0x1F     0x8F (N)");

        operand_a = 8'b1010_0000; // high 1010     0101
        check(77, 8'b0101_0000, 0,0,0,0, "RVH  0xA0     0x50");

        //        RVE (1   7, 3   5)                                                                                                                                              
        alu_op = 5'h0E;
        operand_a = 8'b0000_0010; // bit1     bit7
        check(78, 8'b1000_0000, 0,1,0,0, "RVE  bit1   bit7 (N)");

        operand_a = 8'b1000_0000; // bit7     bit1
        check(79, 8'b0000_0010, 0,0,0,0, "RVE  bit7   bit1");

        operand_a = 8'b0010_0000; // bit5     bit3
        check(80, 8'b0000_1000, 0,0,0,0, "RVE  bit5   bit3");

        operand_a = 8'b0000_1000; // bit3     bit5
        check(81, 8'b0010_0000, 0,0,0,0, "RVE  bit3   bit5");

        //        RVO (0   6, 2   4)                                                                                                                                              
        alu_op = 5'h0F;
        operand_a = 8'b0000_0001; // bit0     bit6
        check(82, 8'b0100_0000, 0,0,0,0, "RVO  bit0   bit6");

        operand_a = 8'b0100_0000; // bit6     bit0
        check(83, 8'b0000_0001, 0,0,0,0, "RVO  bit6   bit0");

        operand_a = 8'b0000_0100; // bit2     bit4
        check(84, 8'b0001_0000, 0,0,0,0, "RVO  bit2   bit4");

        operand_a = 8'b0001_0000; // bit4     bit2
        check(85, 8'b0000_0100, 0,0,0,0, "RVO  bit4   bit2");

        //        RLE (1   3)                                                                                                                                                                
        alu_op = 5'h10;
        operand_a = 8'b0000_0010; // bit1     bit3
        check(86, 8'b0000_1000, 0,0,0,0, "RLE  bit1   bit3");

        operand_a = 8'b0000_1000; // bit3     bit1
        check(87, 8'b0000_0010, 0,0,0,0, "RLE  bit3   bit1");

        operand_a = 8'hF5; // bits 1,3 both 0     unchanged
        check(88, 8'hF5, 0,1,0,0, "RLE  0xF5 (bits 1,3=0)     0xF5 unchanged (N)");

        //        RHE (5   7)                                                                                                                                                                
        alu_op = 5'h11;
        operand_a = 8'b0010_0000; // bit5     bit7
        check(89, 8'b1000_0000, 0,1,0,0, "RHE  bit5   bit7 (N)");

        operand_a = 8'b1000_0000; // bit7     bit5
        check(90, 8'b0010_0000, 0,0,0,0, "RHE  bit7   bit5");

        //        RLO (0   2)                                                                                                                                                                
        alu_op = 5'h12;
        operand_a = 8'b0000_0001; // bit0     bit2
        check(91, 8'b0000_0100, 0,0,0,0, "RLO  bit0   bit2");

        operand_a = 8'b0000_0100; // bit2     bit0
        check(92, 8'b0000_0001, 0,0,0,0, "RLO  bit2   bit0");

        //        RHO (4   6)                                                                                                                                                                
        alu_op = 5'h13;
        operand_a = 8'b0001_0000; // bit4     bit6
        check(93, 8'b0100_0000, 0,0,0,0, "RHO  bit4   bit6");

        operand_a = 8'b0100_0000; // bit6     bit4
        check(94, 8'b0001_0000, 0,0,0,0, "RHO  bit6   bit4");

        //        Mixed patterns     verify non-targeted bits unchanged                                     
        alu_op = 5'h10; // RLE: 1   3
        operand_a = 8'b1100_1010; // bit1=1,bit3=0     swap: bit1=0,bit3=1 = 1100_0100... wait
                                   // 1100_1010: b7=1,b6=1,b5=0,b4=0,b3=1,b2=0,b1=1,b0=0
                                   // swap b1   b3: b3=1,b1=1     no change since both differ
                                   // b3 gets b1=1, b1 gets b3=1     1100_1010 unchanged
        check(95, 8'b1100_1010, 0,1,0,0, "RLE  0xCA (b1=1,b3=1 same)     unchanged (N)");

        operand_a = 8'b1100_0100; // b1=0,b3=0     swap yields same
        check(96, 8'b1100_0100, 0,1,0,0, "RLE  0xC4 (b1=0,b3=0 same)     unchanged (N)");

        //                                                                                                                                                                                                 
        // SUMMARY
        //                                                                                                                                                                                                 
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
