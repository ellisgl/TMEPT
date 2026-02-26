`timescale 1ns / 1ps
`default_nettype none
////////////////////////////////////////////////////////////////////////////////
// Simple Synchronous RAM Module
// 16k x 8-bit RAM with synchronous write and asynchronous read.
////////////////////////////////////////////////////////////////////////////////
module ram (
    input  wire        clk,
    input  wire [13:0] ADDR,
    input  wire        WE,   // active high
    input  wire        CS,   // active high
    input  wire  [7:0] DI,
    output wire  [7:0] DO
);

    reg [7:0] ram[0:16383]; // 16kbyte RAM space.

    always @(posedge clk) begin
        if (WE & CS) begin
            ram[ADDR] <= DI;
        end
    end

    // Output RAM value if reading or DI if writing. If not chip selected, output high impedance.
    assign DO = CS ? (WE ? DI : ram[ADDR]) : 8'bzzzzzzzz;

endmodule
`default_nettype wire
