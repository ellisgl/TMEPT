`ifndef _ALU_SHIFT_V_
`define _ALU_SHIFT_V_

// ============================================================================
// alu_shift.v — Shift & Rotate Unit for the 8-bit CPU
// ----------------------------------------------------------------------------
// Handles: ROL, SOL, SZL, RIL, ROR, SOR, SZR, RIR
//
// All operations act on operand_a only (operand_b unused).
// All operations are purely combinational.
// Operates on all 8 bits — bit 7 is the sign bit but participates in
// shifts and rotates identically to all other bits.
//
// alu_op encoding:
//   3'h0  ROL   Rotate left  — Cin = bit shifted out of bit 7
//   3'h1  SOL   Shift  left  — Cin = 1
//   3'h2  SZL   Shift  left  — Cin = 0
//   3'h3  RIL   Rotate left  — Cin = ~(bit shifted out of bit 7)
//   3'h4  ROR   Rotate right — Cin = bit shifted out of bit 0
//   3'h5  SOR   Shift  right — Cin = 1
//   3'h6  SZR   Shift  right — Cin = 0
//   3'h7  RIR   Rotate right — Cin = ~(bit shifted out of bit 0)
// ============================================================================

module alu_shift (
    input  wire [7:0] operand_a,    // Source operand (8-bit)
    input  wire [2:0] alu_op,       // Operation select

    output reg  [7:0] result,       // 8-bit result
    output wire       flag_z,       // Zero
    output wire       flag_n,       // Negative (bit 7 of result)
    output wire       flag_c        // Carry: the bit that was shifted out
    // flag_v is always 0 for shift/rotate — not driven here
);

    // ── Carry-out (bit shifted out before the shift) ─────────────────────────
    // Left shifts lose bit 7; right shifts lose bit 0.
    wire carry_out_left  = operand_a[7];
    wire carry_out_right = operand_a[0];

    // ── Carry-in selection ───────────────────────────────────────────────────
    reg cin;
    always @(*) begin
        case (alu_op)
            3'h0: cin = carry_out_left;   // ROL: wrap bit 7 → bit 0
            3'h1: cin = 1'b1;             // SOL: insert 1
            3'h2: cin = 1'b0;             // SZL: insert 0
            3'h3: cin = ~carry_out_left;  // RIL: invert carry
            3'h4: cin = carry_out_right;  // ROR: wrap bit 0 → bit 7
            3'h5: cin = 1'b1;             // SOR: insert 1
            3'h6: cin = 1'b0;             // SZR: insert 0
            3'h7: cin = ~carry_out_right; // RIR: invert carry
            default: cin = 1'b0;
        endcase
    end

    // ── Shift/rotate logic ───────────────────────────────────────────────────
    // Left:  {operand_a[6:0], cin} — bit 7 lost, cin enters at bit 0
    // Right: {cin, operand_a[7:1]} — bit 0 lost, cin enters at bit 7
    always @(*) begin
        case (alu_op)
            3'h0, 3'h1, 3'h2, 3'h3: // Left operations
                result = {operand_a[6:0], cin};
            3'h4, 3'h5, 3'h6, 3'h7: // Right operations
                result = {cin, operand_a[7:1]};
            default:
                result = operand_a;
        endcase
    end

    // ── Flag generation ──────────────────────────────────────────────────────
    assign flag_z = (result == 8'b0);
    assign flag_n =  result[7];

    // Carry flag = the bit that was shifted out
    assign flag_c = (alu_op[2] == 1'b0) ? carry_out_left   // left ops
                                         : carry_out_right; // right ops

endmodule

`endif // _ALU_SHIFT_V_
