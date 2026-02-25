// ============================================================================
// rom.v     64 KB ROM for TMEPT CPU, initialised from rom_init.bin
// ============================================================================
//
// Asynchronous (combinational) read, no write port.
// Initialised from rom_init.bin — the flat binary produced by tmept_asm.py.
// Unused locations read as $FF.
//
// Two instances are used in top.v:
//   u_rom   – instruction bus (full 64 KB, serves imem_addr)
//   u_rom_d – data bus read port (serves dmem_addr for ROM reads)
// ============================================================================

`ifndef _ROM_V_
`define _ROM_V_

module rom (
    input  wire [15:0] addr,
    output wire [7:0]  data
);
    reg [7:0] mem [0:65535];

    initial begin
        integer i;
        for (i = 0; i < 65536; i = i + 1)
            mem[i] = 8'hFF;         // default: $FF (unused space)
        $readmemb("rom_init.bin", mem);
    end

    assign data = mem[addr];

endmodule

`endif // _ROM_V_
