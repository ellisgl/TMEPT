`timescale 1ns / 1ps
`default_nettype none

// ============================================================================
// top.v  —  TMEPT CPU SoC, Tang Nano 9K
// ============================================================================
//
// Memory map
//   0x0000 – 0x3FFF   RAM   16 KB
//   0x5000 – 0x5003   ACIA  6551  (4 registers, RS[1:0])
//   0x6000 – 0x600F   VIA   6522  (16 registers, RS[3:0])
//   0x8000 – 0xFFFF   ROM   32 KB  (includes reset/IRQ vectors)
//
// CPU clock: sys_clk / (2 * CLK_DIVISOR)
//   Default: 27 MHz / 14 ≈ 1.929 MHz
// ============================================================================

// All RTL files are passed explicitly by the Makefile — no `include needed here.

module top #(
    parameter integer SYS_CLK_HZ  = 27_000_000,
    parameter integer CLK_DIVISOR = 7    // cpu_clk = sys_clk / (2 * CLK_DIVISOR) ≈ 1.929 MHz
)(
    input  wire       sys_clk,
    input  wire       rst_n,        // active-low reset (board button)

    // ACIA serial (BL702 USB bridge)
    input  wire       uartRx,
    input  wire       uartCts,
    output wire       uartTx,
    output wire       uartRts,

    // VIA 6522 Port B — expansion GPIO
    inout  wire [7:0] PB,

    // VIA 6522 Port A — PA0=CS PA1=MOSI PA2=SCK PA3=MISO PA4-7=GPIO
    inout  wire [7:0] PA
);

    // ── Clock and reset ───────────────────────────────────────────────────────
    wire clk;    // CPU clock, divided from sys_clk
    wire reset;  // active-high synchronous reset

    clock_divider #(
        .DIVISOR(CLK_DIVISOR)
    ) clk_div_inst (
        .clk_in  (sys_clk),
        .clk_out (clk)
    );

    reset reset_inst (
        .clk     (clk),
        .reset_n (rst_n),
        .reset   (reset)
    );

    wire rst_n_sync = ~reset;   // active-low version for CPU and VIA

    // ── CPU ───────────────────────────────────────────────────────────────────
    wire [15:0] imem_addr;
    wire [7:0]  imem_data;
    wire [15:0] dmem_addr;
    wire [7:0]  dmem_rd_data;
    wire [7:0]  dmem_wr_data;
    wire        dmem_wr_en;
    wire        cpu_irq_n;

    // pc, flags, cpu_sp, cpu_stall are debug outputs — left unconnected here.
    // Synthesisers will trim them; add an ILA/LED mapping if you need them.
    cpu u_cpu (
        .clk          (clk),
        .rst_n        (rst_n_sync),
        .imem_addr    (imem_addr),
        .imem_data    (imem_data),
        .dmem_addr    (dmem_addr),
        .dmem_rd_data (dmem_rd_data),
        .dmem_wr_data (dmem_wr_data),
        .dmem_wr_en   (dmem_wr_en),
        .irq_n        (cpu_irq_n),
        .pc           (),
        .flags        (),
        .cpu_sp       (),
        .cpu_stall    ()
    );

    // ── Chip-select decode ────────────────────────────────────────────────────
    wire ram_cs  = (dmem_addr[15:14] == 2'b00);   // 0x0000 – 0x3FFF
    wire uart_cs = (dmem_addr[15:4]  == 12'h500); // 0x5000 – 0x500F
    wire via_cs  = (dmem_addr[15:4]  == 12'h600); // 0x6000 – 0x600F
    // ROM: everything at 0x8000 and above (bit 15 set)

    // ── ROM ───────────────────────────────────────────────────────────────────
    // Harvard architecture: separate instruction and data bus instances.
    wire [7:0] rom_imem_do;
    wire [7:0] rom_dmem_do;

    rom rom_imem_inst (
        .addr (imem_addr),
        .data (rom_imem_do)
    );

    rom rom_dmem_inst (
        .addr (dmem_addr),
        .data (rom_dmem_do)
    );

    assign imem_data = rom_imem_do;

    // ── RAM ───────────────────────────────────────────────────────────────────
    wire [7:0] ram_do;

    ram ram_inst (
        .clk  (clk),
        .ADDR (dmem_addr[13:0]),
        .WE   (dmem_wr_en),
        .CS   (ram_cs),
        .DI   (dmem_wr_data),
        .DO   (ram_do)
    );

    // ── VIA 6522 ──────────────────────────────────────────────────────────────
    wire [7:0] via_do;
    wire       via_irq_n;

    via via_inst (
        .phi2     (clk),
        .rst_n    (rst_n_sync),
        .cs1      (via_cs),
        .cs2_n    (1'b0),
        .rw       (~dmem_wr_en),
        .rs       (dmem_addr[3:0]),
        .data_in  (dmem_wr_data),
        .data_out (via_do),
        .port_a   (PA),
        .port_b   (PB),
        .ca1      (1'b0),
        .ca2_in   (1'b0),
        .ca2_out  (),
        .cb1_in   (1'b0),
        .cb1_out  (),
        .cb2_in   (1'b0),
        .cb2_out  (),
        .irq_n    (via_irq_n)
    );

    // ── ACIA 6551 ─────────────────────────────────────────────────────────────
    wire [7:0] uart_do;
    wire       uart_irq_n;

    acia #(
        .XTLI_FREQ(SYS_CLK_HZ)
    ) uart_inst (
        .RESET   (reset),           // active-high reset
        .PHI2    (clk),
        .CS      (uart_cs),
        .RWN     (~dmem_wr_en),     // 1=read, 0=write
        .RS      (dmem_addr[1:0]),
        .DATAIN  (dmem_wr_data),
        .DATAOUT (uart_do),
        .XTLI    (sys_clk),         // raw oscillator for baud generation
        .RTSB    (uartRts),
        .CTSB    (uartCts),
        .DTRB    (),
        .RXD     (uartRx),
        .TXD     (uartTx),
        .IRQn    (uart_irq_n)
    );

    // ── Data read mux ─────────────────────────────────────────────────────────
    assign dmem_rd_data =
        ram_cs  ? ram_do      :
        uart_cs ? uart_do     :
        via_cs  ? via_do      :
                  rom_dmem_do;  // ROM default — covers 0x8000–0xFFFF and vectors

    // ── IRQ aggregator ────────────────────────────────────────────────────────
    // Wire-AND of active-low IRQ lines gives combined active-low to CPU
    assign cpu_irq_n = via_irq_n & uart_irq_n;

endmodule

`default_nettype wire
