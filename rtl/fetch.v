`ifndef _FETCH_V_
`define _FETCH_V_

// ============================================================================
// fetch.v     Instruction Fetch Stage for the 8-bit CPU
// ----------------------------------------------------------------------------
// Reads one byte per cycle from asynchronous instruction memory, accumulates
// bytes into a 32-bit instruction word, and asserts instr_valid when a
// complete instruction has been collected.
//
// Reset vector (6502-style):
//   On reset de-assertion the FSM enters S_RST0/S_RST1 before fetching any
//   instruction.  It reads two bytes from the fixed locations:
//     0xFFFC  low  byte of the reset vector
//     0xFFFD  high byte of the reset vector
//   and uses the assembled 16-bit value as the initial PC.
//   Instruction execution begins at that address.
//
// Instruction lengths (opcode-driven):
//   2 bytes: SMAR, LOAD, STOR, IMAR, DMAR, all jumps (JMP..JIO),
//            PUSH, POP, CALL, RET
//   3 bytes: all ALU/shift/bitmanip ops, MOV, LMAR
//   4 bytes: ALE, DJN, SLE, SJN (compound ops)
//
// MOV is always treated as 3 bytes regardless of mode     the execute stage
// uses the mode field in W1 to decide operand source.
//
// FSM states:
//   S_RST0         reading low  byte of reset vector from imem[0xFFFC]
//   S_RST1         reading high byte of reset vector from imem[0xFFFD]
//   S_W0           capturing opcode byte, determining instruction length
//   S_W1           capturing second byte
//   S_W2           capturing third byte (3/4-byte instructions only)
//   S_W3           capturing fourth byte (4-byte instructions only)
//   S_DONE         holding instr_valid high for one cycle; instr is stable
//
// Timing:
//   - mem_data is combinational on mem_addr (async memory)
//   - each byte is captured on posedge clk
//   - instr_valid is asserted for exactly one cycle (S_DONE state)
//   - instr is stable and unchanged during the entire S_DONE cycle
//   - stall is high in all states except S_DONE
//   - on a taken branch (pc_load_en): current accumulation is abandoned,
//     PC is loaded, and fetch restarts from the new address next cycle
// ============================================================================

`include "rtl/decode.v"   // for opcode defines

module fetch (
    input  wire        clk,
    input  wire        rst_n,

    //        Instruction memory interface (asynchronous)
    output wire [15:0] mem_addr,     // Address presented to instruction memory
    input  wire [7:0]  mem_data,     // Byte returned combinationally

    //        Branch / jump interface
    input  wire        pc_load_en,   // Execute stage: take this branch
    input  wire [15:0] pc_load_val,  // New PC value

    //        Outputs to decode
    output reg  [31:0] instr,        // Packed instruction word
    output wire        instr_valid,  // High for one cycle when instr is ready

    //        Pipeline control
    output wire [15:0] pc,           // Current PC value
    output wire        stall         // High while fetch is accumulating
);

    //        FSM state encoding
    localparam S_RST0 = 3'd7;   // reading imem[0xFFFC] (reset vector low)
    localparam S_RST1 = 3'd6;   // reading imem[0xFFFD] (reset vector high)
    localparam S_W0   = 3'd0;
    localparam S_W1   = 3'd1;
    localparam S_W2   = 3'd2;
    localparam S_W3   = 3'd3;
    localparam S_DONE = 3'd4;

    //        Reset vector address
    localparam RESET_VEC_LO = 16'hFFFC;
    localparam RESET_VEC_HI = 16'hFFFD;

    //        Registers
    reg [2:0]  state;
    reg [15:0] pc_r;
    reg [2:0]  instr_len;
    reg [7:0]  vec_lo;      // latches low byte of reset vector

    //        mem_addr mux: point at reset vector locations during RST states,
    //        otherwise follow pc_r normally.
    wire in_rst = (state == S_RST0) || (state == S_RST1);
    assign mem_addr = (state == S_RST0) ? RESET_VEC_LO :
                      (state == S_RST1) ? RESET_VEC_HI :
                                          pc_r;

    assign pc         = pc_r;
    assign stall      = (state != S_DONE);
    assign instr_valid = (state == S_DONE);

    //        Opcode length lookup
    function [2:0] opcode_len;
        input [7:0] opc;
        begin
            case (opc)
                // 2-byte instructions
                `OPC_SMAR,
                `OPC_LOAD, `OPC_STOR,
                `OPC_IMAR, `OPC_DMAR,
                `OPC_JMP,  `OPC_JMZ, `OPC_JMN,
                `OPC_JMG,  `OPC_JMO, `OPC_JIE, `OPC_JIO,
                `OPC_JNE,  `OPC_JGE, `OPC_JLE,
                `OPC_PUSH, `OPC_POP, `OPC_CALL, `OPC_RET:
                    opcode_len = 3'd2;

                // 4-byte compound instructions
                `OPC_ALE, `OPC_DJN, `OPC_SLE, `OPC_SJN:
                    opcode_len = 3'd4;

                // 3-byte default (all ALU, shift, bitmanip, MOV, LMAR)
                default:
                    opcode_len = 3'd3;
            endcase
        end
    endfunction

    //        Main FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_r        <= 16'h0000;
            state       <= S_RST0;      // enter reset-vector sequence
            instr_len   <= 3'd3;
            instr       <= 32'h0000_0000;
            vec_lo      <= 8'h00;
        end else begin

            // Branch overrides everything (not valid during RST states, but
            // harmless since execute is held stalled while stall=1)
            if (pc_load_en && !in_rst) begin
                pc_r        <= pc_load_val;
                state       <= S_W0;
                instr       <= 32'h0000_0000;

            end else begin
                case (state)

                    // ── Reset vector fetch ──────────────────────────────────
                    S_RST0: begin
                        // mem_addr = 0xFFFC combinationally; capture low byte
                        vec_lo <= mem_data;
                        state  <= S_RST1;
                    end

                    S_RST1: begin
                        // mem_addr = 0xFFFD combinationally; capture high byte
                        // Assemble the 16-bit reset vector and load into PC
                        pc_r  <= {mem_data, vec_lo};
                        state <= S_W0;
                    end

                    // ── Normal instruction fetch ────────────────────────────
                    S_W0: begin
                        instr[31:24] <= mem_data;
                        instr[23:0]  <= 24'h000000;
                        instr_len    <= opcode_len(mem_data);
                        pc_r         <= pc_r + 1;
                        state        <= S_W1;
                    end

                    S_W1: begin
                        instr[23:16] <= mem_data;
                        pc_r         <= pc_r + 1;
                        if (instr_len == 3'd2) begin
                            instr[15:0] <= 16'h0000;
                            state       <= S_DONE;
                        end else begin
                            state       <= S_W2;
                        end
                    end

                    S_W2: begin
                        instr[15:8]  <= mem_data;
                        pc_r         <= pc_r + 1;
                        if (instr_len == 3'd3) begin
                            instr[7:0]  <= 8'h00;
                            state       <= S_DONE;
                        end else begin
                            state       <= S_W3;
                        end
                    end

                    S_W3: begin
                        instr[7:0]   <= mem_data;
                        pc_r         <= pc_r + 1;
                        state        <= S_DONE;
                    end

                    S_DONE: begin
                        state        <= S_W0;
                    end

                    default: begin
                        state       <= S_W0;
                    end

                endcase
            end
        end
    end

endmodule

`endif // _FETCH_V_
