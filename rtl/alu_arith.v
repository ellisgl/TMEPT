`ifndef _ALU_ARITH_V_
`define _ALU_ARITH_V_

// ============================================================================
// alu_arith.v — Arithmetic & Logic Unit for the 8-bit CPU
// ----------------------------------------------------------------------------
// Handles: ADD, ADC, SUB, SBC, AND, OR, NOR, NAD, XOR, CMP
//
// All operations are purely combinational.
// Operands are 8-bit two's complement signed values (bit 7 = sign).
// Range: -128 to +127
//
// alu_op encoding (matches opcode[3:0] within the arithmetic group):
//   4'h0  ADD   A + B
//   4'h1  ADC   A + B + carry_in
//   4'h2  SUB   A - B
//   4'h3  SBC   A - B - carry_in
//   4'h4  AND   A & B
//   4'h5  OR    A | B
//   4'h6  NOR   ~(A | B)
//   4'h7  NAD   ~(A & B)
//   4'h8  XOR   A ^ B
//   4'h9  CMP   A - B  (result discarded by writeback; flags only)
// ============================================================================

module alu_arith (
    input  wire [7:0] operand_a,    // Source operand A (8-bit)
    input  wire [7:0] operand_b,    // Source operand B (8-bit)
    input  wire [3:0] alu_op,       // Operation select
    input  wire       carry_in,     // Carry/borrow input for ADC/SBC

    output reg  [7:0] result,       // 8-bit result
    output wire       flag_z,       // Zero
    output wire       flag_n,       // Negative (bit 7)
    output wire       flag_c,       // Carry out (unsigned overflow)
    output wire       flag_v        // Signed overflow
);

    // ── Intermediate 9-bit wires for carry detection ─────────────────────────
    // We extend to 9 bits so bit 8 captures the carry out of bit 7.
    reg [8:0] extended;

    // ── Operation select ─────────────────────────────────────────────────────
    always @(*) begin
        case (alu_op)
            4'h0: extended = {1'b0, operand_a} + {1'b0, operand_b};
            4'h1: extended = {1'b0, operand_a} + {1'b0, operand_b} + {8'b0, carry_in};
            4'h2: extended = {1'b0, operand_a} - {1'b0, operand_b};
            4'h3: extended = {1'b0, operand_a} - {1'b0, operand_b} - {8'b0, carry_in};
            4'h4: extended = {1'b0, operand_a  & operand_b};
            4'h5: extended = {1'b0, operand_a  | operand_b};
            4'h6: extended = {1'b0, ~(operand_a | operand_b)};
            4'h7: extended = {1'b0, ~(operand_a & operand_b)};
            4'h8: extended = {1'b0, operand_a  ^ operand_b};
            4'h9: extended = {1'b0, operand_a} - {1'b0, operand_b}; // CMP
            default: extended = {9{1'b0}};
        endcase
        result = extended[7:0];
    end

    // ── Flag generation ──────────────────────────────────────────────────────

    // Zero: result is all zeros
    assign flag_z = (result == 8'b0);

    // Negative: sign bit of result
    assign flag_n = result[7];

    // Carry: bit 8 of the extended result.
    // For subtraction, carry represents the inverted borrow.
    assign flag_c = extended[8];

    // Signed overflow: occurs when the sign of the result is wrong.
    // For addition:    overflow if both operands have the same sign
    //                  but the result has a different sign.
    // For subtraction: overflow if operands have different signs
    //                  and the result sign differs from operand_a's sign.
    // For logic ops:   overflow is always 0 (meaningless).
    reg flag_v_r;
    always @(*) begin
        case (alu_op)
            4'h0, 4'h1: // ADD, ADC
                flag_v_r = (~operand_a[7] & ~operand_b[7] &  result[7])
                         | ( operand_a[7] &  operand_b[7] & ~result[7]);
            4'h2, 4'h3, 4'h9: // SUB, SBC, CMP
                flag_v_r = (~operand_a[7] &  operand_b[7] &  result[7])
                         | ( operand_a[7] & ~operand_b[7] & ~result[7]);
            default:
                flag_v_r = 1'b0;
        endcase
    end
    assign flag_v = flag_v_r;

endmodule

`endif // _ALU_ARITH_V_
