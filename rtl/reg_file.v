`ifndef _REG_FILE_V_
`define _REG_FILE_V_

// ============================================================================
// reg_file.v     Register File for the 8-bit CPU
// ----------------------------------------------------------------------------
// 16 general-purpose 16-bit registers: R0   R15
//
// Registers are 16-bit to natively hold memory addresses. ALU operations
// target the low byte only. The high byte is only modified by explicit
// wide instructions (MOVH etc.) via the wr_wide port.
//
// Port summary:
//
//   Read ports (4, asynchronous/combinational):
//     rd_addr0..3 [3:0]      register select
//     rd_data0..3 [15:0]     register output (full 16-bit, always)
//
//   Write port A     primary ALU writeback (low byte only unless wr_a_wide):
//     wr_a_en                  write enable
//     wr_a_addr   [3:0]        destination register
//     wr_a_data   [7:0]        8-bit data (written to bits [7:0])
//     wr_a_wide                if 1, wr_a_data_wide[15:0] is written instead
//     wr_a_data_wide[15:0]     full 16-bit data for wide writes
//
//   Write port B     secondary (MAR update, compound op writeback, etc.):
//     wr_b_en                  write enable
//     wr_b_addr   [3:0]        destination register
//     wr_b_data   [7:0]        8-bit data (written to bits [7:0])
//     wr_b_wide                if 1, wr_b_data_wide[15:0] is written instead
//     wr_b_data_wide[15:0]     full 16-bit data for wide writes
//
//   Control:
//     clk                      clock (writes are synchronous)
//     rst_n                    async active-low reset (all registers     0)
//
// Write priority: if both ports target the same register in the same cycle,
// port A takes priority.
//
// R0 is a read-only zero register     writes to R0 are silently ignored.
// ============================================================================

module reg_file (
    input  wire        clk,
    input  wire        rst_n,

    //        Read port 0
    input  wire [3:0]  rd_addr0,
    output wire [15:0] rd_data0,

    //        Read port 1
    input  wire [3:0]  rd_addr1,
    output wire [15:0] rd_data1,

    //        Read port 2
    input  wire [3:0]  rd_addr2,
    output wire [15:0] rd_data2,

    //        Read port 3
    input  wire [3:0]  rd_addr3,
    output wire [15:0] rd_data3,

    //        Write port A (primary     ALU writeback)
    input  wire        wr_a_en,
    input  wire [3:0]  wr_a_addr,
    input  wire [7:0]  wr_a_data,
    input  wire        wr_a_wide,
    input  wire [15:0] wr_a_data_wide,

    //        Write port B (secondary)
    input  wire        wr_b_en,
    input  wire [3:0]  wr_b_addr,
    input  wire [7:0]  wr_b_data,
    input  wire        wr_b_wide,
    input  wire [15:0] wr_b_data_wide
);

    //        Register array
    reg [15:0] regs [1:15]; // R1   R15; R0 is hardwired to 0

    //        Asynchronous reads
    // R0 always reads as zero.
    assign rd_data0 = (rd_addr0 == 4'h0) ? 16'h0000 : regs[rd_addr0];
    assign rd_data1 = (rd_addr1 == 4'h0) ? 16'h0000 : regs[rd_addr1];
    assign rd_data2 = (rd_addr2 == 4'h0) ? 16'h0000 : regs[rd_addr2];
    assign rd_data3 = (rd_addr3 == 4'h0) ? 16'h0000 : regs[rd_addr3];

    //        Synchronous writes with async reset
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            regs[1]  <= 16'h0000; regs[2]  <= 16'h0000;
            regs[3]  <= 16'h0000; regs[4]  <= 16'h0000;
            regs[5]  <= 16'h0000; regs[6]  <= 16'h0000;
            regs[7]  <= 16'h0000; regs[8]  <= 16'h0000;
            regs[9]  <= 16'h0000; regs[10] <= 16'h0000;
            regs[11] <= 16'h0000; regs[12] <= 16'h0000;
            regs[13] <= 16'h0000; regs[14] <= 16'h0000;
            regs[15] <= 16'h0000;
        end else begin

            //        Port B writes first (lower priority)
            if (wr_b_en && wr_b_addr != 4'h0) begin
                if (wr_b_wide)
                    regs[wr_b_addr] <= wr_b_data_wide;
                else
                    regs[wr_b_addr] <= {regs[wr_b_addr][15:8], wr_b_data};
            end

            //        Port A writes second (higher priority     overwrites B)
            if (wr_a_en && wr_a_addr != 4'h0) begin
                if (wr_a_wide)
                    regs[wr_a_addr] <= wr_a_data_wide;
                else
                    regs[wr_a_addr] <= {regs[wr_a_addr][15:8], wr_a_data};
            end

        end
    end

endmodule

`endif // _REG_FILE_V_
