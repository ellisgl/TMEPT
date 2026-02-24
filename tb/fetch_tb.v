// ============================================================================
// fetch_tb.v     Testbench for the instruction fetch stage
// ============================================================================

`timescale 1ns/1ps
`include "rtl/fetch.v"

module fetch_tb;

    //        DUT ports                                                                                                                                                                                        
    reg         clk, rst_n;
    reg         pc_load_en;
    reg  [15:0] pc_load_val;

    wire [15:0] mem_addr;
    wire [31:0] instr;
    wire        instr_valid;
    wire [15:0] pc;
    wire        stall;

    //        Async instruction memory model                                                                                                                         
    reg [7:0] imem [0:255];
    wire [7:0] mem_data = imem[mem_addr[7:0]];

    fetch dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .mem_addr     (mem_addr),
        .mem_data     (mem_data),
        .pc_load_en   (pc_load_en),
        .pc_load_val  (pc_load_val),
        .instr        (instr),
        .instr_valid  (instr_valid),
        .pc           (pc),
        .stall        (stall)
    );

    //        Clock     10ns period                                                                                                                                                          
    initial clk = 0;
    always #5 clk = ~clk;

    //        Tracking                                                                                                                                                                                           
    integer pass_count, fail_count;

    task check32;
        input [63:0]  id;
        input [31:0]  got, exp;
        input [239:0] label;
        begin
            if (got !== exp) begin
                $display("  FAIL [%0d] %s: got 0x%08h, exp 0x%08h", id, label, got, exp);
                fail_count = fail_count + 1;
            end else begin
                $display("  PASS [%0d] %s", id, label);
                pass_count = pass_count + 1;
            end
        end
    endtask

    task check16;
        input [63:0]  id;
        input [15:0]  got, exp;
        input [239:0] label;
        begin
            if (got !== exp) begin
                $display("  FAIL [%0d] %s: got 0x%04h, exp 0x%04h", id, label, got, exp);
                fail_count = fail_count + 1;
            end else begin
                $display("  PASS [%0d] %s", id, label);
                pass_count = pass_count + 1;
            end
        end
    endtask

    task check1;
        input [63:0]  id;
        input         got, exp;
        input [239:0] label;
        begin
            if (got !== exp) begin
                $display("  FAIL [%0d] %s: got %0d, exp %0d", id, label, got, exp);
                fail_count = fail_count + 1;
            end else begin
                $display("  PASS [%0d] %s", id, label);
                pass_count = pass_count + 1;
            end
        end
    endtask

    // Wait for instr_valid to go high.
    // If valid is already high when called (we're in DONE from a previous
    // instruction), advance one clock first to exit that DONE state.
    task wait_valid;
        input [63:0] timeout_cycles;
        integer i;
        begin
            // If valid is already high, we're still in DONE from the previous
            // instruction     step past it first
            if (instr_valid) begin
                @(posedge clk); #1;
            end
            i = 0;
            while (!instr_valid && i < timeout_cycles) begin
                @(posedge clk); #1;
                i = i + 1;
            end
            if (i >= timeout_cycles)
                $display("  TIMEOUT waiting for instr_valid");
        end
    endtask

    integer i;

    initial begin
        pass_count  = 0;
        fail_count  = 0;
        pc_load_en  = 0;
        pc_load_val = 0;

        for (i = 0; i < 256; i = i + 1)
            imem[i] = 8'h00;

        $display("============================================================");
        $display("  Fetch Stage Testbench");
        $display("============================================================");

        //        Reset                                                                                                                                                                                        
        $display("\n--- Reset ---");
        rst_n = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1; #1;
        check16(1, pc,          16'h0000, "PC = 0x0000 after reset");
        check1 (2, instr_valid, 0,        "instr_valid = 0 after reset");
        check1 (3, stall,       1,        "stall = 1 after reset");

        //        3-byte instruction: ADD R3,R1,R2                                                                                                    
        // Opcode 0x00=ADD, W1=mode(00)+dst(R3)+pad = 0b00_0011_00 = 0x0C
        // W2=src1(R1)+src2(R2) = 0b0001_0010 = 0x12
        // Fetch sequence: W0   W1   W2   DONE = 4 cycles
        $display("\n--- 3-byte instruction (ADD) at 0x0000 ---");
        imem[0] = 8'h00; // ADD
        imem[1] = 8'h0C; // mode=00, dst=R3
        imem[2] = 8'h12; // src1=R1, src2=R2

        rst_n = 0; @(posedge clk); #1; rst_n = 1;

        // Cycle 1: capture W0
        @(posedge clk); #1;
        check1(4, instr_valid, 0, "instr_valid=0 after W0");
        check1(5, stall,       1, "stall=1 after W0");

        // Cycle 2: capture W1
        @(posedge clk); #1;
        check1(6, instr_valid, 0, "instr_valid=0 after W1");

        // Cycle 3: state   S_DONE     instr_valid combinational, fires immediately
        @(posedge clk); #1;
        check1 (7,  instr_valid, 1,           "instr_valid=1 entering DONE");
        check1 (8,  stall,       0,           "stall=0 in DONE");
        check32(10, instr,       32'h000C1200, "instr = 0x000C1200");
        check16(11, pc,          16'h0003,    "PC advanced to 0x0003");

        // Cycle 4: state   S_W0, valid clears
        @(posedge clk); #1;
        check1(12, instr_valid, 0, "instr_valid clears after DONE");

        //        2-byte instruction: JMP R5                                                                                                                         
        // W1 = mode=00, dst=R5     0b00_0101_00 = 0x14
        // Fetch sequence: W0   W1   DONE = 3 cycles
        $display("\n--- 2-byte instruction (JMP) at 0x0003 ---");
        imem[3] = 8'h26; // JMP
        imem[4] = 8'h14; // dst=R5

        wait_valid(8);
        check1 (13, instr_valid, 1,           "instr_valid=1 for JMP");
        check32(14, instr,       32'h26140000, "instr = 0x26140000");
        check16(15, pc,          16'h0005,    "PC advanced to 0x0005");

        //        4-byte instruction: SLE R1,R2,R3,R4                                                                                           
        // Opcode=0x36, W1=0x12(src1=R1,src2=R2), W2=0x30(dst=R3), W3=0x40(jmp=R4)
        // Fetch sequence: W0   W1   W2   W3   DONE = 5 cycles
        $display("\n--- 4-byte instruction (SLE) at 0x0005 ---");
        imem[5] = 8'h36; // SLE
        imem[6] = 8'h12; // src1=R1, src2=R2
        imem[7] = 8'h30; // dst=R3
        imem[8] = 8'h40; // jmp=R4

        wait_valid(10);
        check1 (16, instr_valid, 1,           "instr_valid=1 for SLE");
        check32(17, instr,       32'h36123040, "instr = 0x36123040");
        check16(18, pc,          16'h0009,    "PC advanced to 0x0009");

        //        LMAR 3-byte                                                                                                                                                                      
        $display("\n--- 3-byte LMAR at 0x0009 ---");
        imem[9]  = 8'h2E; // LMAR
        imem[10] = 8'h1A; // addr[15:8]
        imem[11] = 8'h2B; // addr[7:0]

        wait_valid(8);
        check1 (19, instr_valid, 1,           "instr_valid=1 for LMAR");
        check32(20, instr,       32'h2E1A2B00, "instr = 0x2E1A2B00");
        check16(21, pc,          16'h000C,    "PC advanced to 0x000C");

        //        IMAR 2-byte                                                                                                                                                                      
        $display("\n--- 2-byte IMAR at 0x000C ---");
        imem[12] = 8'h32; // IMAR
        imem[13] = 8'h00;

        wait_valid(8);
        check1 (22, instr_valid, 1,           "instr_valid=1 for IMAR");
        check32(23, instr,       32'h32000000, "instr = 0x32000000");
        check16(24, pc,          16'h000E,    "PC advanced to 0x000E");

        //        Branch: PC load                                                                                                                                                          
        $display("\n--- Branch to 0x0080 ---");
        imem[8'h80] = 8'h08; // XOR
        imem[8'h81] = 8'h04; // mode=00, dst=R1
        imem[8'h82] = 8'h23; // src1=R2, src2=R3

        // Let fetch start on the next instruction (0x000E), then assert branch
        @(posedge clk); #1; // W0 of whatever is at 0x000E
        pc_load_en  = 1;
        pc_load_val = 16'h0080;
        @(posedge clk); #1;
        pc_load_en  = 0;
        check16(25, pc, 16'h0080, "PC = 0x0080 after branch");

        wait_valid(10);
        check1 (26, instr_valid, 1,           "instr_valid=1 after branch");
        check32(27, instr,       32'h08042300, "instr = XOR R1,R2,R3");
        check16(28, pc,          16'h0083,    "PC = 0x0083 after XOR");

        //        Stall is inverse of valid                                                                                                                            
        $display("\n--- Stall / valid relationship ---");
        imem[8'h83] = 8'h32; // IMAR (genuinely 2-byte)
        imem[8'h84] = 8'h00;

        @(posedge clk); #1; // clk1: DONE   S_W0, stall=1
        check1(29, stall,       1, "stall=1 during W0");
        check1(30, instr_valid, 0, "instr_valid=0 during W0");
        @(posedge clk); #1; // clk2: S_W0   S_W1, stall=1
        check1(31, stall,       1, "stall=1 during W1");
        @(posedge clk); #1; // clk3: S_W1   S_DONE, combinational
        check1(32, stall,       0, "stall=0 entering DONE");
        check1(33, instr_valid, 1, "instr_valid=1 simultaneously");

        //        Sequential 2-byte instructions                                                                                                          
        $display("\n--- Sequential fetch continuity ---");
        imem[8'h85] = 8'h26; imem[8'h86] = 8'h10; // JMP R4
        imem[8'h87] = 8'h27; imem[8'h88] = 8'h14; // JMZ R5
        imem[8'h89] = 8'h28; imem[8'h8A] = 8'h18; // JMN R6

        wait_valid(8);
        check32(34, instr, 32'h26100000, "JMP R4 fetched");
        check16(35, pc,    16'h0087,     "PC=0x0087 after JMP");

        wait_valid(8);
        check32(36, instr, 32'h27140000, "JMZ R5 fetched");
        check16(37, pc,    16'h0089,     "PC=0x0089 after JMZ");

        wait_valid(8);
        check32(38, instr, 32'h28180000, "JMN R6 fetched");
        check16(39, pc,    16'h008B,     "PC=0x008B after JMN");

        //        Async reset mid-fetch                                                                                                                                        
        $display("\n--- Async reset mid-fetch ---");
        imem[8'h8B] = 8'h00; // ADD (3-byte)
        @(posedge clk); #1;  // W0
        @(posedge clk); #1;  // W1     mid instruction
        #3; rst_n = 0; #2;
        check1 (40, instr_valid, 0,        "instr_valid=0 immediately on reset");
        check16(41, pc,          16'h0000, "PC=0x0000 on reset");
        rst_n = 1;

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
