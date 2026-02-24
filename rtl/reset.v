`timescale 1ns / 1ps
`default_nettype none
////////////////////////////////////////////////////////////////////////////////
// Reset Synchronizer Module
// Synchronizes asynchronous reset input to clock domain using a 2-stage
// flip-flop chain to prevent metastability. Output is active-high reset.
////////////////////////////////////////////////////////////////////////////////
module reset (
    input  wire clk,     // Clock signal
    input  wire reset_n, // Asynchronous active-low reset input
    output wire reset    // Synchronized active-high reset output
);

    // Synchronization chain registers (2 stages for metastability prevention)
    reg q0;
    reg q1;

    // Synchronous reset synchronization
    always @(posedge clk) begin
        if (~reset_n) begin
            // Asynchronous reset: Set stages to 1 (active reset)
            q0 <= 1'b1;
            q1 <= 1'b1;
        end else begin
            // Normal operation: Shift the inverted reset through the chain
            q0 <= ~reset_n;  // Input inverted (active-low to active-high)
            q1 <= q0;
        end
    end

    // Output: Active-high if any stage is 1 (ensures reset assertion)
    assign reset = q0 | q1;
endmodule
`default_nettype wire
