`ifndef _CPU_V_
`define _CPU_V_

// ============================================================================
// cpu.v     TMEPT 8-bit CPU top level
// ============================================================================
//
// Wires together the fetch and execute pipeline stages and exposes four
// external memory ports:
//
//   Instruction memory  (read-only, asynchronous / combinational read)
//                                                                                                                                                                                                         
//        imem_addr  [15:0]             byte address                            
//        imem_data  [7:0]              byte returned combinationally           
//                                                                                                                                                                                                         
//
//   Data memory  (read/write, synchronous write, combinational read)
//                                                                                                                                                                                                         
//        dmem_addr  [15:0]             byte address (driven by MAR)            
//        dmem_rd_data [7:0]            byte returned combinationally           
//        dmem_wr_data [7:0]            byte to write                           
//        dmem_wr_en                    write strobe (high for one cycle)        
//                                                                                                                                                                                                         
//
// Pipeline summary
//                                                    
//   fetch   accumulates 2   4 instruction bytes from imem, drives instr /
//           instr_valid to execute; accepts pc_load_en / pc_load_val from
//           execute for branch/jump resolution.
//
//   execute latches instr on instr_valid, reads/writes the register file,
//           runs the ALU, updates flags, drives the data-memory and
//           branch interfaces, and manages the 16x16-bit hardware stack
//           (PUSH / POP / CALL / RET).
//
// Stall policy
//                                        
//   fetch.stall is high while accumulating bytes (states W0   W3). execute
//   receives instr_valid=0 during stall so it does not commit anything.
//   execute.stall is tied low (reserved for future multi-cycle ops).
//   The combined cpu_stall output is the OR of both for external visibility.
//
// ============================================================================

`timescale 1ns/1ps

`include "rtl/fetch.v"
`include "rtl/execute.v"

module cpu (
    input  wire        clk,
    input  wire        rst_n,

    //        Instruction memory (async read)                                                                                                                   
    output wire [15:0] imem_addr,
    input  wire [7:0]  imem_data,

    //        Data memory                                                                                                                                                                               
    output wire [15:0] dmem_addr,      // = MAR from execute
    input  wire [7:0]  dmem_rd_data,
    output wire [7:0]  dmem_wr_data,
    output wire        dmem_wr_en,

    //        Interrupt request (active-low, level-sensitive)
    //        When asserted, CPU completes the current instruction then
    //        vector-jumps to the address stored at $FFFA/$FFFB.
    //        Software must clear the source and re-enable by writing
    //        to the peripheral's interrupt-clear register.
    input  wire        irq_n,

    //        Observability / debug outputs                                                                                                                            
    output wire [15:0] pc,             // Current PC
    output wire [4:0]  flags,          // {O, V, C, N, Z}
    output wire [3:0]  cpu_sp,         // Stack pointer (for debug)
    output wire        cpu_stall       // High while fetch or execute is stalled
);

    //        Internal signals                                                                                                                                                                   

    // Fetch     Execute
    wire [31:0] instr;
    wire        instr_valid;

    // Execute     Fetch  (branch resolution)
    wire        pc_load_en;
    wire [15:0] pc_load_val;

    // Stall signals
    wire        fetch_stall;
    wire        exec_stall;

    // MAR from execute drives the data memory address
    wire [15:0] mar;

    // Internal fetch address (before IRQ mux)
    wire [15:0] imem_addr_fetch;

    // PC from fetch, passed to execute as return-address source for CALL
    wire [15:0] pc_wire;

    // Stack pointer from execute
    wire [3:0]  sp_wire;

    //        Fetch stage                                                                                                                                                                                  
    fetch u_fetch (
        .clk         (clk),
        .rst_n       (rst_n),
        // Instruction memory
        .mem_addr    (imem_addr_fetch),
        .mem_data    (imem_data),
        // Branch / jump from execute (or IRQ vector override)
        .pc_load_en  (final_pc_load_en),
        .pc_load_val (final_pc_load_val),
        // Output to execute
        .instr       (instr),
        .instr_valid (instr_valid),
        // Pipeline status
        .pc          (pc_wire),
        .stall       (fetch_stall)
    );

    //        Execute stage                                                                                                                                                                            
    execute u_execute (
        .clk         (clk),
        .rst_n       (rst_n),
        // Instruction from fetch
        .instr       (instr),
        .instr_valid (instr_valid),
        // Data memory
        .mem_rd_data (dmem_rd_data),
        .mar         (mar),
        .mem_wr_data (dmem_wr_data),
        .mem_wr_en   (dmem_wr_en),
        // Branch / jump to fetch
        .pc_load_en  (pc_load_en),
        .pc_load_val (pc_load_val),
        // Return address for CALL
        .pc_in       (pc_wire),
        // Stack pointer observability
        .sp          (sp_wire),
        // Flags and stall
        .flags       (flags),
        .stall       (exec_stall)
    );

    //        Data memory address = MAR
    assign dmem_addr = mar;

    //        IRQ vector logic
    //        When irq_n is low and the CPU is not stalled (instruction boundary),
    //        force-load PC from $FFFA/$FFFB (the IRQ vector stored in ROM).
    reg        irq_prev_n;
    reg [1:0]  irq_vec_state;   // 0=idle 1=read-lo 2=read-hi 3=jump
    reg [7:0]  irq_vec_lo;
    reg [15:0] irq_vec_addr;

    localparam IRQ_VEC_LO = 16'hFFFA;
    localparam IRQ_VEC_HI = 16'hFFFB;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_prev_n    <= 1'b1;
            irq_vec_state <= 2'd0;
            irq_vec_lo    <= 8'h0;
            irq_vec_addr  <= 16'h0;
        end else begin
            irq_prev_n <= irq_n;
            case (irq_vec_state)
                2'd0: // Trigger on falling edge of irq_n, at instruction boundary
                    if (!irq_n && irq_prev_n && !cpu_stall)
                        irq_vec_state <= 2'd1;
                2'd1: begin
                    irq_vec_lo    <= imem_data;   // ROM[$FFFA] combinational
                    irq_vec_state <= 2'd2;
                end
                2'd2: begin
                    irq_vec_addr  <= {imem_data, irq_vec_lo};
                    irq_vec_state <= 2'd3;
                end
                2'd3:
                    irq_vec_state <= 2'd0;
            endcase
        end
    end

    // Override imem address during vector fetch
    assign imem_addr = (irq_vec_state == 2'd1) ? IRQ_VEC_LO :
                       (irq_vec_state == 2'd2) ? IRQ_VEC_HI :
                       imem_addr_fetch;

    // Override pc_load during vector jump
    wire        final_pc_load_en  = (irq_vec_state == 2'd3) | pc_load_en;
    wire [15:0] final_pc_load_val = (irq_vec_state == 2'd3) ? irq_vec_addr : pc_load_val;

    //        Debug outputs
    assign pc     = pc_wire;
    assign cpu_sp = sp_wire;

    //        Aggregate stall
    assign cpu_stall = fetch_stall | exec_stall;

endmodule

`endif // _CPU_V_
