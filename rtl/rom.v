// ============================================================================
// rom.v     64 KB ROM for TMEPT CPU, initialised from rom_init.hex
// ============================================================================
//
// Asynchronous (combinational) read, no write port.
// Initialised from rom_init.hex — Verilog $readmemh format produced by
// tmept_asm.py.  The hex file uses @AAAA address markers so sparse images
// load correctly; any address not present in the file reads as 8'hFF because
// the mem array is pre-declared and Gowin block RAM initialises to 0 anyway
// (the CPU treats 0x00 as ADD R0,R0,R0 — a harmless NOP equivalent).
//
// Two instances are instantiated in top.v:
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

    initial $readmemh("rom_init.hex", mem);

    assign data = mem[addr];

endmodule

`endif // _ROM_V_
