// ============================================================================
// top.v     TMEPT CPU system — Tang Nano 9K
// ============================================================================
//
// Inspired by ellisgl/TN9K-BE65C02 — a similar modular SoC architecture for
// the same board, with ROM + RAM + UART + GPIO + Timer + I2C.
//
// ── Memory map ───────────────────────────────────────────────────────────────
//
//   $0000–$7FFF   ROM   32 KB   (code + read-only data)
//   $8000–$FDF7   RAM   ~7.9 KB read/write
//
//   Peripheral I/O  ($FE00–$FFEF):
//   $FE00–$FE02   UART   3 registers  (TX/RX data, status)
//   $FE10–$FE16   GPIO   7 registers  (PA data/dir, PB data/dir, IRQ flags/en/clr)
//   $FE20–$FE23   Timer  4 registers  (latch lo/hi, counter lo, control)
//   $FE30–$FE33   I2C    4 registers  (data, command/status, prescale lo/hi)
//
//   Vectors  ($FFF8–$FFFF, in ROM):
//   $FFFA–$FFFB   IRQ vector    → address of interrupt service routine
//   $FFFC–$FFFD   Reset vector  → address of main program
//   $FFFE–$FFFF   (reserved)
//
// ── On-board resources ───────────────────────────────────────────────────────
//   sys_clk       pin 52   27 MHz crystal oscillator
//   sys_rst_n     pin  4   S1 tactile button, active-low
//   led[5:0]      pins 10,11,13,14,15,16   active-low, show PC[5:0]
//   uart_tx       pin 17   115200 8N1 → BL702 USB-serial bridge
//   uart_rx       pin 18   115200 8N1 ← BL702 USB-serial bridge
//   gpio_a[7:0]   PMOD connector pins (bank 0, LVCMOS33)
//   gpio_b[7:0]   PMOD connector pins (bank 0, LVCMOS33)
//   i2c_scl       open-drain; external pull-up required (e.g. 4.7 kΩ to 3.3 V)
//   i2c_sda       open-drain; external pull-up required
//
// ── Clock ────────────────────────────────────────────────────────────────────
//   27 MHz PLL → 6.75 MHz CPU clock  (27 / 4 = 6.75 MHz)
//   Adjust PLL_IDIV / PLL_FBDIV / PLL_ODIV to taste.
//
// ── Interrupt priority ───────────────────────────────────────────────────────
//   A single irq_n line is the OR of all peripheral IRQ sources.
//   On assertion the CPU vectors through $FFFA/$FFFB.
//   The ISR must poll $FE14 (GPIO flags) and $FE23 bit 7 (Timer flag) to
//   identify the source, clear it, then RTI (software return via RET).
//
// ── ROM initialisation ───────────────────────────────────────────────────────
//   Synthesised from rom_init.bin (flat binary from tmept_asm.py).
//   Build with:  make rom  (assembles src/main.asm → rom_init.bin)
// ============================================================================

`timescale 1ns/1ps

`include "6551-ACIA/rtl/acia_brgen.v"
`include "6551-ACIA/rtl/acia_rx.v"
`include "6551-ACIA/rtl/acia_tx.v"
`include "6551-ACIA/rtl/acia.v"
`include "6522-VIA/rtl/via.v"
`include "rtl/rom.v"
`include "rtl/ram.v"
`include "rtl/cpu.v"
// `include "rtl/gpio.v"
// `include "rtl/timer.v"
// `include "rtl/i2c.v"

module top (
    input  wire        sys_clk,     // 27 MHz crystal
    input  wire        sys_rst_n,   // S1 reset button, active-low

    // UART (via onboard BL702 USB bridge)
    output wire        uart_tx,
    input  wire        uart_rx,

    // GPIO port A — PMOD / expansion header
    inout  wire [7:0]  gpio_a,

    // GPIO port B — PMOD / expansion header
    inout  wire [7:0]  gpio_b,

    // I2C bus (open-drain; board must supply pull-ups)
    inout  wire        i2c_scl,
    inout  wire        i2c_sda,

    // Active-low LEDs (show PC[5:0])
    output wire [5:0]  led
);

    // ── PLL parameters ────────────────────────────────────────────────────────
    // fout = 27 MHz × (PLL_FBDIV+1) / ((PLL_IDIV+1) × 2^PLL_ODIV)
    // Default: 27 × 1 / (1 × 4) = 6.75 MHz
    parameter PLL_IDIV  = 0;
    parameter PLL_FBDIV = 0;
    parameter PLL_ODIV  = 2;

    parameter CPU_CLK_HZ = 6_750_000;
    parameter UART_BAUD  = 115_200;
    parameter I2C_HZ     = 60_000;

    // ── PLL ───────────────────────────────────────────────────────────────────
    wire cpu_clk;
    wire pll_lock;

    PLLVR u_pll (
        .CLKOUT   (cpu_clk),
        .LOCK     (pll_lock),
        .CLKOUTP  (),
        .CLKOUTD  (),
        .CLKOUTD3 (),
        .RESET    (1'b0),
        .RESET_P  (1'b0),
        .CLKIN    (sys_clk),
        .CLKFB    (1'b0),
        .FBDSEL   (6'b0),
        .IDSEL    ({2'b0, PLL_IDIV[3:0]}),
        .ODSEL    ({2'b0, PLL_ODIV[3:0]}),
        .PSDA     (4'b0),
        .DUTYDA   (4'b0),
        .FDLY     (4'b0),
        .FBSEL    (2'b10),
        .FBDIV    ({1'b0, PLL_FBDIV[5:0]})
    );

    // ── Reset synchroniser ───────────────────────────────────────────────────
    // Hold in reset until PLL locks; synchronise button to cpu_clk domain.
    reg [3:0] rst_sr = 4'hF;
    always @(posedge cpu_clk or negedge pll_lock) begin
        if (!pll_lock) rst_sr <= 4'hF;
        else           rst_sr <= {rst_sr[2:0], ~sys_rst_n};
    end
    wire rst_n = ~rst_sr[3];

    // ── CPU ───────────────────────────────────────────────────────────────────
    wire [15:0] imem_addr;
    wire [7:0]  imem_data;
    wire [15:0] dmem_addr;
    wire [7:0]  dmem_rd_data;
    wire [7:0]  dmem_wr_data;
    wire        dmem_wr_en;
    wire [15:0] pc;
    wire [4:0]  flags;
    wire [3:0]  cpu_sp;
    wire        cpu_stall;
    wire        irq_n;

    cpu u_cpu (
        .clk          (cpu_clk),
        .rst_n        (rst_n),
        .imem_addr    (imem_addr),
        .imem_data    (imem_data),
        .dmem_addr    (dmem_addr),
        .dmem_rd_data (dmem_rd_data),
        .dmem_wr_data (dmem_wr_data),
        .dmem_wr_en   (dmem_wr_en),
        .irq_n        (irq_n),
        .pc           (pc),
        .flags        (flags),
        .cpu_sp       (cpu_sp),
        .cpu_stall    (cpu_stall)
    );

    // ── ROM ($0000–$7FFF, plus vectors at $FFF8–$FFFF) ───────────────────────
    // One 64 KB ROM instance serves the instruction bus; a second
    // serves the data bus for ROM-region reads.
    wire [7:0] rom_iq;
    rom u_rom_i (
        .addr (imem_addr),
        .data (rom_iq)
    );
    assign imem_data = rom_iq;

    wire [7:0] rom_dq;
    rom u_rom_d (
        .addr (dmem_addr),
        .data (rom_dq)
    );

    // ── RAM ($8000–$FDFF) ─────────────────────────────────────────────────────
    wire       ram_sel  = (dmem_addr[15] == 1'b1) && (dmem_addr[15:9] != 7'b1111111);
    wire [7:0] ram_q;
    wire       ram_we   = dmem_wr_en & ram_sel;

    ram u_ram (
        .clk     (cpu_clk),
        .addr    (dmem_addr[14:0]),
        .wr_en   (ram_we),
        .wr_data (dmem_wr_data),
        .rd_data (ram_q)
    );

    // ── Peripheral decode ($FE00–$FEFF) ──────────────────────────────────────
    wire periph_sel = (dmem_addr[15:8] == 8'hFE);

    // UART  $FE00–$FE0F  (addr[3:0], only [1:0] used)
    wire       uart_sel = periph_sel && (dmem_addr[7:4] == 4'h0);
    wire [7:0] uart_q;
    wire       uart_we  = dmem_wr_en & uart_sel;

    uart #(
        .CLK_HZ (CPU_CLK_HZ),
        .BAUD   (UART_BAUD)
    ) u_uart (
        .clk     (cpu_clk),
        .rst_n   (rst_n),
        .addr    (dmem_addr[1:0]),
        .wr_en   (uart_we),
        .wr_data (dmem_wr_data),
        .rd_data (uart_q),
        .tx      (uart_tx),
        .rx      (uart_rx)
    );

    // GPIO  $FE10–$FE1F  (addr[2:0])
    wire       gpio_sel = periph_sel && (dmem_addr[7:4] == 4'h1);
    wire [7:0] gpio_q;
    wire       gpio_we  = dmem_wr_en & gpio_sel;
    wire       gpio_irq;

    gpio u_gpio (
        .clk     (cpu_clk),
        .rst_n   (rst_n),
        .addr    (dmem_addr[2:0]),
        .wr_en   (gpio_we),
        .wr_data (dmem_wr_data),
        .rd_data (gpio_q),
        .port_a  (gpio_a),
        .port_b  (gpio_b),
        .irq     (gpio_irq)
    );

    // Timer  $FE20–$FE2F  (addr[1:0])
    wire       timer_sel = periph_sel && (dmem_addr[7:4] == 4'h2);
    wire [7:0] timer_q;
    wire       timer_we  = dmem_wr_en & timer_sel;
    wire       timer_irq;

    timer u_timer (
        .clk     (cpu_clk),
        .rst_n   (rst_n),
        .addr    (dmem_addr[1:0]),
        .wr_en   (timer_we),
        .wr_data (dmem_wr_data),
        .rd_data (timer_q),
        .irq     (timer_irq)
    );

    // I2C  $FE30–$FE3F  (addr[1:0])
    wire       i2c_sel = periph_sel && (dmem_addr[7:4] == 4'h3);
    wire [7:0] i2c_q;
    wire       i2c_we  = dmem_wr_en & i2c_sel;

    // Open-drain I2C: drive pin low via OE; release pin via internal pull-up
    wire scl_oe, sda_oe;
    assign i2c_scl = scl_oe ? 1'b0 : 1'bz;
    assign i2c_sda = sda_oe ? 1'b0 : 1'bz;

    i2c #(
        .CLK_HZ  (CPU_CLK_HZ),
        .I2C_HZ  (I2C_HZ)
    ) u_i2c (
        .clk     (cpu_clk),
        .rst_n   (rst_n),
        .addr    (dmem_addr[1:0]),
        .wr_en   (i2c_we),
        .wr_data (dmem_wr_data),
        .rd_data (i2c_q),
        .scl_oe  (scl_oe),
        .scl_in  (i2c_scl),
        .sda_oe  (sda_oe),
        .sda_in  (i2c_sda)
    );

    // ── Data read mux ─────────────────────────────────────────────────────────
    assign dmem_rd_data = uart_sel  ? uart_q  :
                          gpio_sel  ? gpio_q  :
                          timer_sel ? timer_q :
                          i2c_sel   ? i2c_q   :
                          ram_sel   ? ram_q   :
                                      rom_dq;

    // ── IRQ aggregator ────────────────────────────────────────────────────────
    // All peripheral IRQ sources OR'd together → active-low CPU input
    assign irq_n = ~(gpio_irq | timer_irq);

    // ── LEDs: show PC[5:0], active-low ───────────────────────────────────────
    assign led = ~pc[5:0];

endmodule
