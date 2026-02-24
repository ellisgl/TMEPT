`ifndef _ALU_BITMANIP_V_
`define _ALU_BITMANIP_V_

// ============================================================================
// alu_bitmanip.v — Bit Manipulation Unit for the 8-bit CPU
// ----------------------------------------------------------------------------
// Handles all INx (invert) and RVx/RLx/RHx (reverse/swap) operations.
//
// This module is STRUCTURAL — every operation is expressed as direct wire
// assignments with no logic gates beyond XOR for the invert family.
// The permutation operations are pure wire routing (zero gate cost).
//
// All operations act on all 8 bits of operand_a. Bit 7 is the sign bit
// but is treated as a regular data bit for all manipulation ops.
//
// alu_op encoding:
//   5'h00  INV   Invert all bits         XOR 0xFF
//   5'h01  INH   Invert high nibble      XOR 0xF0
//   5'h02  INL   Invert low  nibble      XOR 0x0F
//   5'h03  INE   Invert even bits        XOR 0xAA  (bits 1,3,5,7)
//   5'h04  INO   Invert odd  bits        XOR 0x55  (bits 0,2,4,6)
//   5'h05  IEH   Invert even of high     XOR 0xA0  (bits 5,7)
//   5'h06  IOH   Invert odd  of high     XOR 0x50  (bits 4,6)
//   5'h07  IEL   Invert even of low      XOR 0x0A  (bits 1,3)
//   5'h08  IOL   Invert odd  of low      XOR 0x05  (bits 0,2)
//   5'h09  IFB   Invert first bit        XOR 0x01  (bit 0)
//   5'h0A  ILB   Invert last  bit        XOR 0x80  (bit 7)
//   5'h0B  REV   Reverse all bits
//   5'h0C  RVL   Reverse low  nibble
//   5'h0D  RVH   Reverse high nibble
//   5'h0E  RVE   Reverse even bits: 1↔7, 3↔5
//   5'h0F  RVO   Reverse odd  bits: 0↔6, 2↔4
//   5'h10  RLE   Swap low  even: 1↔3
//   5'h11  RHE   Swap high even: 5↔7
//   5'h12  RLO   Swap low  odd:  0↔2
//   5'h13  RHO   Swap high odd:  4↔6
// ============================================================================

module alu_bitmanip (
    input  wire [7:0] operand_a,    // Source operand (8-bit)
    input  wire [4:0] alu_op,       // Operation select

    output reg  [7:0] result,       // 8-bit result
    output wire       flag_z,       // Zero
    output wire       flag_n        // Negative (bit 7 of result)
    // flag_c and flag_v are always 0 for bit manipulation — not driven here
);

    // ── Bit aliases for readability ──────────────────────────────────────────
    wire b0 = operand_a[0];
    wire b1 = operand_a[1];
    wire b2 = operand_a[2];
    wire b3 = operand_a[3];
    wire b4 = operand_a[4];
    wire b5 = operand_a[5];
    wire b6 = operand_a[6];
    wire b7 = operand_a[7];

    // ── Invert family (XOR with constant mask) ───────────────────────────────
    // Each invert result is a fixed XOR — synthesises to XOR gates or inverters.
    wire [7:0] inv_INV = {~b7, ~b6, ~b5, ~b4, ~b3, ~b2, ~b1, ~b0};
    wire [7:0] inv_INH = {~b7, ~b6, ~b5, ~b4, b3,   b2,   b1,   b0  };
    wire [7:0] inv_INL = {b7,   b6,   b5,   b4,   ~b3, ~b2, ~b1, ~b0};
    wire [7:0] inv_INE = {~b7, b6,   ~b5, b4,   ~b3, b2,   ~b1, b0  };
    wire [7:0] inv_INO = {b7,   ~b6, b5,   ~b4, b3,   ~b2, b1,   ~b0};
    wire [7:0] inv_IEH = {~b7, b6,   ~b5, b4,   b3,   b2,   b1,   b0  };
    wire [7:0] inv_IOH = {b7,   ~b6, b5,   ~b4, b3,   b2,   b1,   b0  };
    wire [7:0] inv_IEL = {b7,   b6,   b5,   b4,   ~b3, b2,   ~b1, b0  };
    wire [7:0] inv_IOL = {b7,   b6,   b5,   b4,   b3,   ~b2, b1,   ~b0};
    wire [7:0] inv_IFB = {b7,   b6,   b5,   b4,   b3,   b2,   b1,   ~b0};
    wire [7:0] inv_ILB = {~b7, b6,   b5,   b4,   b3,   b2,   b1,   b0  };

    // ── Permutation family (pure wire swaps — zero gate cost) ────────────────

    // REV: full reversal — 7↔0, 6↔1, 5↔2, 4↔3
    wire [7:0] perm_REV = {b0, b1, b2, b3, b4, b5, b6, b7};

    // RVL: reverse low nibble — 3↔0, 2↔1
    wire [7:0] perm_RVL = {b7, b6, b5, b4, b0, b1, b2, b3};

    // RVH: reverse high nibble — 7↔4, 6↔5
    wire [7:0] perm_RVH = {b4, b5, b6, b7, b3, b2, b1, b0};

    // RVE: reverse even-position bits — 1↔7, 3↔5 (odd positions unchanged)
    wire [7:0] perm_RVE = {b1, b6, b3, b4, b5, b2, b7, b0};

    // RVO: reverse odd-position bits — 0↔6, 2↔4 (even positions unchanged)
    wire [7:0] perm_RVO = {b7, b0, b5, b2, b3, b4, b1, b6};

    // RLE: swap low even bits — 1↔3
    wire [7:0] perm_RLE = {b7, b6, b5, b4, b1, b2, b3, b0};

    // RHE: swap high even bits — 5↔7
    wire [7:0] perm_RHE = {b5, b6, b7, b4, b3, b2, b1, b0};

    // RLO: swap low odd bits — 0↔2
    wire [7:0] perm_RLO = {b7, b6, b5, b4, b3, b0, b1, b2};

    // RHO: swap high odd bits — 4↔6
    wire [7:0] perm_RHO = {b7, b4, b5, b6, b3, b2, b1, b0};

    // ── Output mux ───────────────────────────────────────────────────────────
    always @(*) begin
        case (alu_op)
            5'h00: result = inv_INV;
            5'h01: result = inv_INH;
            5'h02: result = inv_INL;
            5'h03: result = inv_INE;
            5'h04: result = inv_INO;
            5'h05: result = inv_IEH;
            5'h06: result = inv_IOH;
            5'h07: result = inv_IEL;
            5'h08: result = inv_IOL;
            5'h09: result = inv_IFB;
            5'h0A: result = inv_ILB;
            5'h0B: result = perm_REV;
            5'h0C: result = perm_RVL;
            5'h0D: result = perm_RVH;
            5'h0E: result = perm_RVE;
            5'h0F: result = perm_RVO;
            5'h10: result = perm_RLE;
            5'h11: result = perm_RHE;
            5'h12: result = perm_RLO;
            5'h13: result = perm_RHO;
            default: result = operand_a; // pass-through for undefined ops
        endcase
    end

    // ── Flag generation ──────────────────────────────────────────────────────
    assign flag_z = (result == 8'b0);
    assign flag_n =  result[7];

endmodule

`endif // _ALU_BITMANIP_V_
