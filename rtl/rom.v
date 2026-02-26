// ============================================================================
// rom.v     64 KB ROM for TMEPT CPU, initialised from rom_init.hex
// ============================================================================
//
// Asynchronous (combinational) read, no write port.
// Initialised from rom_init.hex — $readmemh-format hex file produced by
// tmept_asm.py (default output format when no -o flag forces .bin).
// Addresses not present in the hex file retain their reset value ($FF via
// the pre-fill loop using a genvar, which Yosys accepts).
//
// Two instances are used in top.v:
//   rom_imem_inst – instruction bus (serves imem_addr)
//   rom_dmem_inst – data bus        (serves dmem_addr)
// ============================================================================

`ifndef _ROM_V_
`define _ROM_V_

module rom (
    input  wire [15:0] addr,
    output wire [7:0]  data
);
    reg [7:0] mem [0:65535];

    // Pre-fill with $FF so unaddressed locations return a defined value.
    // genvar-based generate loop is supported by Yosys (unlike integer for-loops
    // inside initial blocks when files are read via read_verilog).
    generate
        genvar gi;
        for (gi = 0; gi < 65536; gi = gi + 1) begin : fill
            initial mem[gi] = 8'hFF;
        end
    endgenerate

    initial $readmemh("rom_init.hex", mem);

    assign data = mem[addr];

endmodule

`endif // _ROM_V_
