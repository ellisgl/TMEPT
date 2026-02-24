// ============================================================================
// reg_file_tb.v     Testbench for the 16x16-bit register file
// ============================================================================

`timescale 1ns/1ps
`include "rtl/reg_file.v"

module reg_file_tb;

    //        DUT ports                                                                                                                                                                                        
    reg        clk, rst_n;
    reg  [3:0] rd_addr0, rd_addr1, rd_addr2, rd_addr3;
    wire [15:0] rd_data0, rd_data1, rd_data2, rd_data3;

    reg        wr_a_en, wr_a_wide;
    reg  [3:0] wr_a_addr;
    reg  [7:0] wr_a_data;
    reg [15:0] wr_a_data_wide;

    reg        wr_b_en, wr_b_wide;
    reg  [3:0] wr_b_addr;
    reg  [7:0] wr_b_data;
    reg [15:0] wr_b_data_wide;

    reg_file dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .rd_addr0       (rd_addr0),   .rd_data0 (rd_data0),
        .rd_addr1       (rd_addr1),   .rd_data1 (rd_data1),
        .rd_addr2       (rd_addr2),   .rd_data2 (rd_data2),
        .rd_addr3       (rd_addr3),   .rd_data3 (rd_data3),
        .wr_a_en        (wr_a_en),    .wr_a_addr (wr_a_addr),
        .wr_a_data      (wr_a_data),  .wr_a_wide (wr_a_wide),
        .wr_a_data_wide (wr_a_data_wide),
        .wr_b_en        (wr_b_en),    .wr_b_addr (wr_b_addr),
        .wr_b_data      (wr_b_data),  .wr_b_wide (wr_b_wide),
        .wr_b_data_wide (wr_b_data_wide)
    );

    //        Clock     10ns period                                                                                                                                                          
    initial clk = 0;
    always #5 clk = ~clk;

    //        Tracking                                                                                                                                                                                           
    integer pass_count, fail_count;

    task check;
        input [63:0]  test_id;
        input [15:0]  got, exp;
        input [239:0] label;
        begin
            if (got !== exp) begin
                $display("FAIL [%0d] %s", test_id, label);
                $display("       got 0x%04h, exp 0x%04h", got, exp);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS [%0d] %s", test_id, label);
                pass_count = pass_count + 1;
            end
        end
    endtask

    task write_idle;
        begin
            wr_a_en = 0; wr_a_wide = 0;
            wr_b_en = 0; wr_b_wide = 0;
        end
    endtask

    task write_a_byte;
        input [3:0] addr;
        input [7:0] data;
        begin
            wr_a_en = 1; wr_a_addr = addr;
            wr_a_data = data; wr_a_wide = 0;
            @(posedge clk); #1;
            wr_a_en = 0;
        end
    endtask

    task write_a_wide;
        input [3:0]  addr;
        input [15:0] data;
        begin
            wr_a_en = 1; wr_a_addr = addr;
            wr_a_data_wide = data; wr_a_wide = 1;
            @(posedge clk); #1;
            wr_a_en = 0; wr_a_wide = 0;
        end
    endtask

    task write_b_byte;
        input [3:0] addr;
        input [7:0] data;
        begin
            wr_b_en = 1; wr_b_addr = addr;
            wr_b_data = data; wr_b_wide = 0;
            @(posedge clk); #1;
            wr_b_en = 0;
        end
    endtask

    initial begin
        pass_count = 0; fail_count = 0;
        write_idle;
        wr_a_addr = 0; wr_a_data = 0; wr_a_data_wide = 0;
        wr_b_addr = 0; wr_b_data = 0; wr_b_data_wide = 0;
        rd_addr0 = 0; rd_addr1 = 0; rd_addr2 = 0; rd_addr3 = 0;

        $display("============================================================");
        $display("  Register File Testbench");
        $display("============================================================");

        //        1. Reset                                                                                                                                                                               
        $display("\n--- Reset ---");
        rst_n = 0;
        @(posedge clk); #1;
        rst_n = 1;
        rd_addr0 = 4'h1; rd_addr1 = 4'h7;
        rd_addr2 = 4'hE; rd_addr3 = 4'hF;
        #1;
        check(1,  rd_data0, 16'h0000, "R1  = 0x0000 after reset");
        check(2,  rd_data1, 16'h0000, "R7  = 0x0000 after reset");
        check(3,  rd_data2, 16'h0000, "R14 = 0x0000 after reset");
        check(4,  rd_data3, 16'h0000, "R15 = 0x0000 after reset");

        //        2. R0 is hardwired zero                                                                                                                                  
        $display("\n--- R0 zero register ---");
        write_a_byte(4'h0, 8'hFF);
        rd_addr0 = 4'h0; #1;
        check(5, rd_data0, 16'h0000, "R0 stays 0x0000 after byte write attempt");
        write_a_wide(4'h0, 16'hDEAD);
        rd_addr0 = 4'h0; #1;
        check(6, rd_data0, 16'h0000, "R0 stays 0x0000 after wide write attempt");

        //        3. Low byte write preserves high byte                                                                                        
        $display("\n--- Low byte write preserves high byte ---");
        write_a_wide(4'h1, 16'h12CD);
        write_a_byte(4'h1, 8'hEF);
        rd_addr0 = 4'h1; #1;
        check(7, rd_data0, 16'h12EF, "R1 low byte write preserves high byte: 0x12EF");

        //        4. Wide write, port A                                                                                                                                           
        $display("\n--- Wide write, port A ---");
        write_a_wide(4'h2, 16'hBEEF);
        rd_addr0 = 4'h2; #1;
        check(8, rd_data0, 16'hBEEF, "R2 wide write: 0xBEEF");

        write_a_wide(4'h3, 16'hDEAD);
        rd_addr0 = 4'h3; #1;
        check(9, rd_data0, 16'hDEAD, "R3 wide write: 0xDEAD");

        //        5. Low byte write, port B                                                                                                                               
        $display("\n--- Port B write ---");
        write_b_byte(4'h4, 8'h42);
        rd_addr0 = 4'h4; #1;
        check(10, rd_data0, 16'h0042, "R4 port B low byte write: 0x0042");

        // Wide write via port B
        wr_b_en = 1; wr_b_addr = 4'h5;
        wr_b_data_wide = 16'hCAFE; wr_b_wide = 1;
        @(posedge clk); #1;
        wr_b_en = 0; wr_b_wide = 0;
        rd_addr0 = 4'h5; #1;
        check(11, rd_data0, 16'hCAFE, "R5 port B wide write: 0xCAFE");

        //        6. 4-port simultaneous read                                                                                                                      
        $display("\n--- 4-port simultaneous read ---");
        write_a_wide(4'h6, 16'h1111);
        write_a_wide(4'h7, 16'h2222);
        write_a_wide(4'h8, 16'h3333);
        write_a_wide(4'h9, 16'h4444);
        rd_addr0 = 4'h6; rd_addr1 = 4'h7;
        rd_addr2 = 4'h8; rd_addr3 = 4'h9;
        #1;
        check(12, rd_data0, 16'h1111, "R6  = 0x1111 (4-port read)");
        check(13, rd_data1, 16'h2222, "R7  = 0x2222 (4-port read)");
        check(14, rd_data2, 16'h3333, "R8  = 0x3333 (4-port read)");
        check(15, rd_data3, 16'h4444, "R9  = 0x4444 (4-port read)");

        //        7. Port A priority over port B, same register same cycle                               
        $display("\n--- Write port priority (A beats B) ---");
        write_a_wide(4'hA, 16'h0000);
        wr_a_en = 1; wr_a_addr = 4'hA; wr_a_data = 8'hAA; wr_a_wide = 0;
        wr_b_en = 1; wr_b_addr = 4'hA; wr_b_data = 8'hBB; wr_b_wide = 0;
        @(posedge clk); #1;
        wr_a_en = 0; wr_b_en = 0;
        rd_addr0 = 4'hA; #1;
        check(16, rd_data0, 16'h00AA, "R10 port A wins over port B: 0x00AA");

        //        8. Simultaneous writes to different registers                                                                
        $display("\n--- Simultaneous writes to different registers ---");
        write_a_wide(4'hB, 16'h0000);
        write_a_wide(4'hC, 16'h0000);
        wr_a_en = 1; wr_a_addr = 4'hB; wr_a_data = 8'h11; wr_a_wide = 0;
        wr_b_en = 1; wr_b_addr = 4'hC; wr_b_data = 8'h22; wr_b_wide = 0;
        @(posedge clk); #1;
        wr_a_en = 0; wr_b_en = 0;
        rd_addr0 = 4'hB; rd_addr1 = 4'hC; #1;
        check(17, rd_data0, 16'h0011, "R11 written via port A: 0x0011");
        check(18, rd_data1, 16'h0022, "R12 written via port B: 0x0022");

        //        9. Async reset clears all registers                                                                                              
        $display("\n--- Async reset ---");
        write_a_wide(4'hD, 16'hFFFF);
        write_a_wide(4'hE, 16'hFFFF);
        write_a_wide(4'hF, 16'hFFFF);
        #3; rst_n = 0; #2;
        rd_addr0 = 4'hD; rd_addr1 = 4'hE; rd_addr2 = 4'hF; #1;
        check(19, rd_data0, 16'h0000, "R13 cleared by async reset");
        check(20, rd_data1, 16'h0000, "R14 cleared by async reset");
        check(21, rd_data2, 16'h0000, "R15 cleared by async reset");
        rst_n = 1;
        @(posedge clk); #1;

        //        10. All R1-R15 independently writable and readable                                                 
        $display("\n--- Write and read all R1-R15 ---");
        begin : write_all
            integer r;
            for (r = 1; r < 16; r = r + 1) begin
                wr_a_en = 1; wr_a_addr = r[3:0];
                wr_a_data_wide = r[3:0] * 16'h0101;
                wr_a_wide = 1;
                @(posedge clk); #1;
            end
            wr_a_en = 0; wr_a_wide = 0;
            for (r = 1; r < 16; r = r + 1) begin
                rd_addr0 = r[3:0]; #1;
                check(21 + r, rd_data0, r[3:0] * 16'h0101, "Rn = n*0x0101");
            end
        end

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
