`ifndef _ALU_V_
`define _ALU_V_

// ============================================================================
// alu.v — Top-level ALU for the 8-bit CPU
// ----------------------------------------------------------------------------
// Instantiates the three functional units and muxes their outputs based on
// alu_group. All logic is purely combinational — pipeline registers live
// in the surrounding datapath, not here.
//
// Port summary:
//
//   operand_a [7:0]  — primary source operand (always used)
//   operand_b [7:0]  — secondary operand (arith/logic only; ignored by
//                      shift and bitmanip units which are unary)
//   alu_group [1:0]  — selects functional unit:
//                        2'b00 = arithmetic / logic
//                        2'b01 = shift / rotate
//                        2'b10 = bit manipulation
//                        2'b11 = reserved
//   alu_op    [5:0]  — operation within the selected unit (low bits only;
//                      width covers the largest unit: bitmanip needs 5 bits)
//   carry_in         — carry/borrow for ADC / SBC
//
//   result    [7:0]  — computed result
//   flag_z           — Zero
//   flag_n           — Negative (bit 7)
//   flag_c           — Carry / shift-out
//   flag_v           — Signed overflow (always 0 for shift and bitmanip)
// ============================================================================

`include "rtl/alu_arith.v"
`include "rtl/alu_shift.v"
`include "rtl/alu_bitmanip.v"

module alu (
    input  wire [7:0] operand_a,
    input  wire [7:0] operand_b,
    input  wire [1:0] alu_group,
    input  wire [5:0] alu_op,
    input  wire       carry_in,

    output reg  [7:0] result,
    output reg        flag_z,
    output reg        flag_n,
    output reg        flag_c,
    output reg        flag_v
);

    // ── Arithmetic unit outputs ──────────────────────────────────────────────
    wire [7:0] arith_result;
    wire       arith_z, arith_n, arith_c, arith_v;

    alu_arith u_arith (
        .operand_a  (operand_a),
        .operand_b  (operand_b),
        .alu_op     (alu_op[3:0]),
        .carry_in   (carry_in),
        .result     (arith_result),
        .flag_z     (arith_z),
        .flag_n     (arith_n),
        .flag_c     (arith_c),
        .flag_v     (arith_v)
    );

    // ── Shift/rotate unit outputs ────────────────────────────────────────────
    wire [7:0] shift_result;
    wire       shift_z, shift_n, shift_c;

    alu_shift u_shift (
        .operand_a  (operand_a),
        .alu_op     (alu_op[2:0]),
        .result     (shift_result),
        .flag_z     (shift_z),
        .flag_n     (shift_n),
        .flag_c     (shift_c)
    );

    // ── Bit manipulation unit outputs ────────────────────────────────────────
    wire [7:0] bitmanip_result;
    wire       bitmanip_z, bitmanip_n;

    alu_bitmanip u_bitmanip (
        .operand_a  (operand_a),
        .alu_op     (alu_op[4:0]),
        .result     (bitmanip_result),
        .flag_z     (bitmanip_z),
        .flag_n     (bitmanip_n)
    );

    // ── Output mux — select active unit based on alu_group ──────────────────
    always @(*) begin
        case (alu_group)
            2'b00: begin    // Arithmetic / logic
                result = arith_result;
                flag_z = arith_z;
                flag_n = arith_n;
                flag_c = arith_c;
                flag_v = arith_v;
            end
            2'b01: begin    // Shift / rotate
                result = shift_result;
                flag_z = shift_z;
                flag_n = shift_n;
                flag_c = shift_c;
                flag_v = 1'b0;
            end
            2'b10: begin    // Bit manipulation
                result = bitmanip_result;
                flag_z = bitmanip_z;
                flag_n = bitmanip_n;
                flag_c = 1'b0;
                flag_v = 1'b0;
            end
            default: begin  // Reserved — pass through A, clear flags
                result = operand_a;
                flag_z = 1'b0;
                flag_n = 1'b0;
                flag_c = 1'b0;
                flag_v = 1'b0;
            end
        endcase
    end

endmodule

`endif // _ALU_V_
