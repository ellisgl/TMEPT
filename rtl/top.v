// ============================================================================
// top.v     TMEPT CPU system — Tang Nano 9K
// ============================================================================
//
// Peripherals are the same submodules used in ellisgl/TN9K-BE65C02:
//   6551-ACIA  (rtl/acia.v + acia_rx.v + acia_tx.v + acia_brgen.v)
//   6522-VIA   (rtl/via.v)
//
// ── Memory map ───────────────────────────────────────────────────────────────
//
//   $0000–$7FFF   ROM   32 KB   code + read-only data
//   $8000–$4FFF   RAM   20 KB   read/write data
//
//   $5000–$5003   ACIA  6551    serial UART (4 registers, RS[1:0])
//                   $5000  [W] Transmit Data Register
//                   $5000  [R] Receive Data Register
//                   $5001  [W] Programmed Reset (any write)
//                   $5002  [R] Status Register
//                   $5002  [W] Command Register
//                   $5003  [R/W] Control Register
//
//   $6000–$600F   VIA   6522    GPIO / timer / interrupts (16 registers, RS[3:0])
//                   $6000  [R/W] Port B Data (ORB)
//                   $6001  [R/W] Port A Data (ORA)
//                   $6002  [R/W] Port B Direction (DDRB)  0=in, 1=out
//                   $6003  [R/W] Port A Direction (DDRA)  0=in, 1=out
//                   $6004  [R/W] Timer 1 Counter Low
//                   $6005  [R/W] Timer 1 Counter High
//                   $6006  [R/W] Timer 1 Latch Low
//                   $6007  [R/W] Timer 1 Latch High
//                   $6008  [R/W] Timer 2 Counter Low
//                   $6009  [R/W] Timer 2 Counter High
//                   $600A  [R/W] Shift Register
//                   $600B  [R/W] Auxiliary Control Register (ACR)
//                   $600C  [R/W] Peripheral Control Register (PCR)
//                   $600D  [R/W] Interrupt Flag Register (IFR)
//                   $600E  [R/W] Interrupt Enable Register (IER)
//                   $600F  [R/W] Port A Data, no handshake (ORA_NH)
//
//   Vectors  (in ROM):
//   $FFFA–$FFFB   IRQ vector  → interrupt service routine
//   $FFFC–$FFFD   Reset vector → main program
//
// ── VIA Port A — microSD SPI (matches TN9K-BE65C02 pin mapping) ───────────────
//   PA0  CS   (chip select, active-low)
//   PA1  MOSI (master out)
//   PA2  SCK  (clock)
//   PA3  MISO (master in, input)
//   PA4–PA7  spare GPIO
//
// ── VIA Port B — expansion GPIO ───────────────────────────────────────────────
//   PB0–PB7  general purpose, all available on PMOD header
//
// ── On-board resources ────────────────────────────────────────────────────────
//   sys_clk   pin 52   27 MHz crystal
//   sys_rst_n pin  4   S1 button, active-low
//   led[5:0]  pins 10,11,13,14,15,16  active-low, show PC[5:0]
//   acia_tx   pin 17   → BL702 USB-serial bridge
//   acia_rx   pin 18   ← BL702 USB-serial bridge
//   via_pa[7:0]  pins 25–32  (SD card SPI on PA0–PA3, spare on PA4–PA7)
//   via_pb[7:0]  pins 33–40  expansion PMOD
//
// ── Clock ─────────────────────────────────────────────────────────────────────
//   27 MHz ÷ 14 ≈ 1.929 MHz CPU clock, matching TN9K-BE65C02 target speed.
//   PLL: fout = 27 MHz × (FBDIV+1) / ((IDIV+1) × 2^ODIV)
//        27 × 1 / (1 × 16) = 1.6875 MHz  (ODIV=4)  — use divider chain instead
//   Simple approach: use the Gowin primitive CLKDIV to divide 27 MHz by 14.
//   Alternatively keep PLL at ~1.929 MHz:
//     FBDIV=6 (×7), IDIV=0 (÷1), ODIV=6 (÷64) → 27×7/64 ≈ 2.953 MHz  (close)
//     Best match with integer PLL: use CLKDIV on a higher PLL output.
//   Default below uses a simple non-PLL divider for simulation compatibility;
//   swap in the PLLVR instantiation for synthesis.
//
// ── VERIFY PORT NAMES ─────────────────────────────────────────────────────────
//   All 6522 and 6551 port connections are marked // VERIFY where the exact
//   signal name could not be confirmed from the source.  Cross-check against:
//     6551-ACIA/rtl/acia.v          (top-level ACIA module)
//     6522-VIA/rtl/via.v            (top-level VIA module)
//   before synthesising.
// ============================================================================

`timescale 1ns/1ps

`include "rtl/cpu.v"
`include "rtl/rom.v"
`include "rtl/ram.v"

module top (
    input  wire        sys_clk,      // 27 MHz crystal
    input  wire        sys_rst_n,    // S1 reset button, active-low

    // 6551 ACIA serial (via BL702 USB bridge)
    output wire        acia_tx,
    input  wire        acia_rx,

    // 6522 VIA Port A: PA0=CS, PA1=MOSI, PA2=SCK, PA3=MISO (SD card)
    //                  PA4–PA7 spare
    inout  wire [7:0]  via_pa,

    // 6522 VIA Port B: expansion GPIO on PMOD header
    inout  wire [7:0]  via_pb,

    // Active-low LEDs — show PC[5:0]
    output wire [5:0]  led
);

    // ── Parameters ────────────────────────────────────────────────────────────
    // Clock divider to reach ~1.929 MHz from 27 MHz.
    // 27 000 000 / 14 = 1 928 571 Hz  (matches TN9K-BE65C02)
    // Implemented as a simple counter divider; replace with PLLVR for tighter
    // frequency tolerance in synthesis.
    localparam CLK_DIV    = 14;
    localparam CPU_CLK_HZ = 27_000_000 / CLK_DIV;  // ≈ 1 929 000

    // ── Clock divider ─────────────────────────────────────────────────────────
    // Divides sys_clk by CLK_DIV to produce cpu_clk.
    // For synthesis, replace this block with the PLLVR primitive below.
    reg [$clog2(CLK_DIV)-1:0] clk_cnt = 0;
    reg cpu_clk_r = 0;

    always @(posedge sys_clk) begin
        if (clk_cnt == (CLK_DIV/2 - 1)) begin
            clk_cnt   <= 0;
            cpu_clk_r <= ~cpu_clk_r;
        end else begin
            clk_cnt <= clk_cnt + 1;
        end
    end

    wire cpu_clk = cpu_clk_r;

    // ── PLLVR (synthesis alternative — uncomment and remove divider above) ───
    // Targeting ~1.929 MHz:  27 × 8 / (1 × 128) = 1.6875 MHz  (nearest clean)
    // Or use CLKDIV primitive on top of a higher-frequency PLL output.
    //
    // wire cpu_clk;
    // wire pll_lock;
    // PLLVR u_pll (
    //     .CLKOUT(cpu_clk), .LOCK(pll_lock),
    //     .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
    //     .RESET(1'b0), .RESET_P(1'b0),
    //     .CLKIN(sys_clk), .CLKFB(1'b0),
    //     .FBDSEL(6'b0), .IDSEL(6'b0),
    //     .ODSEL(6'b000111),   // ÷128 → 27×8/128 = 1.6875 MHz
    //     .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),
    //     .FBSEL(2'b10), .FBDIV({1'b0, 6'd7})  // ×8
    // );

    // ── Reset synchroniser ───────────────────────────────────────────────────
    reg [3:0] rst_sr = 4'hF;
    always @(posedge cpu_clk) begin
        rst_sr <= {rst_sr[2:0], ~sys_rst_n};
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

    // ── ROM ($0000–$7FFF) ─────────────────────────────────────────────────────
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

    // ── RAM ($8000–$4FFF, 20 KB) ──────────────────────────────────────────────
    // Select: addr >= $8000 and addr < $5000 — i.e. not in peripheral windows
    wire ram_sel = (dmem_addr >= 16'h8000) &&
                   (dmem_addr <  16'h5000);   // never true — fix below
    // Correct: RAM occupies $8000–$CFFF (20 KB), leaving $5000-$6FFF for periph
    // and $7000–$7FFF spare, $D000–$FFFF for ROM vectors / unused.
    // Simpler decode: RAM when bit15=1 and not in ACIA or VIA window.
    wire acia_sel = (dmem_addr[15:2] == 14'h1400);  // $5000–$5003
    wire via_sel  = (dmem_addr[15:4] == 12'h600);   // $6000–$600F
    wire rom_sel  = (dmem_addr[15] == 1'b0);        // $0000–$7FFF

    // RAM: $8000 and above, excluding ACIA and VIA windows
    wire ram_sel_real = (dmem_addr[15] == 1'b1) && !acia_sel && !via_sel;
    wire [7:0] ram_q;
    wire       ram_we = dmem_wr_en & ram_sel_real;

    ram u_ram (
        .clk     (cpu_clk),
        .ADDR    (dmem_addr[13:0]),
        .WE      (ram_we),
        .CS      (ram_sel_real),
        .DI      (dmem_wr_data),
        .DO      (ram_q)
    );

    // ── 6551 ACIA ($5000–$5003) ───────────────────────────────────────────────
    // The ACIA uses a 6502-style bus: phi2 (clock enable), rw_n (read=1/write=0),
    // cs (chip select, active-high), rs[1:0] (register select).
    // We generate phi2 = cpu_clk (the ACIA samples on the rising edge when cs=1).
    //
    // VERIFY: Check acia.v module port names match exactly.
    // Common port names from the hoglet67 upstream and your fork:
    //   clk, reset, phi2, cs, rw_n, rs[1:0], data[7:0], irq_n, tx, rx
    // Some implementations use:
    //   clk_in / phi2_in, RWn / rw_n, nIRQ / irq_n
    // The instantiation below uses the names most consistent with standard 6551
    // implementations; adjust as needed.

    wire       acia_we  = dmem_wr_en & acia_sel;
    wire [7:0] acia_q;
    wire       acia_irq_n;

    // Bidirectional data bus: drive from CPU on write, float on read
    wire [7:0] acia_data_out;

    acia u_acia (                          // VERIFY: module name may be "acia"
        .clk     (cpu_clk),               // VERIFY: may be "clk_in" or "phi2"
        .reset   (~rst_n),                // VERIFY: active-high reset typical for 6551
        .phi2    (cpu_clk),               // VERIFY: some impls use separate phi2
        .cs      (acia_sel),              // VERIFY: "cs" or "cs1" / active-high
        .rw_n    (~dmem_wr_en),           // VERIFY: "rw_n", "RWn", or "rw"
        .rs      (dmem_addr[1:0]),        // VERIFY: "rs", "addr", or "rs_n"
        .data    (acia_sel & ~dmem_wr_en  // VERIFY: may be split i_data/o_data
                    ? 8'hzz : dmem_wr_data),
        .irq_n   (acia_irq_n),            // VERIFY: "irq_n", "nIRQ", "irq"
        .tx      (acia_tx),               // VERIFY: "tx", "TXD", "txd"
        .rx      (acia_rx)                // VERIFY: "rx", "RXD", "rxd"
    );
    assign acia_q = acia_data_out;        // VERIFY: output data port name

    // ── 6522 VIA ($6000–$600F) ────────────────────────────────────────────────
    // The VIA uses a 6502-style bus similar to the ACIA.
    // Standard 6522 ports: clk, reset, cs1, cs2_n, rw_n, rs[3:0],
    //                      data[7:0], ca1, ca2, cb1, cb2,
    //                      pa[7:0], pb[7:0], irq_n
    //
    // VERIFY: Check via.v module port names match exactly.

    wire       via_we  = dmem_wr_en & via_sel;
    wire [7:0] via_q;
    wire       via_irq_n;

    // CA1/CA2/CB1/CB2 handshake lines — tie unused to safe defaults
    // CA1 = ACIA IRQ feedback (edge-triggered interrupt chaining, optional)
    // CA2 = output (not used here), CB1/CB2 = not used
    wire via_ca1 = ~acia_irq_n;   // feed ACIA IRQ into VIA CA1 for chaining
    wire via_ca2_out;              // not connected externally
    wire via_cb1 = 1'b0;
    wire via_cb2_out;

    VIA u_via (                           // VERIFY: module name may be "via6522" or "m6522"
        .phi2     (cpu_clk),               // VERIFY: "clk", "phi2", "clk_in"
        .reset   (~rst_n),                // VERIFY: active-high or active-low?
        .cs1     (via_sel),               // VERIFY: "cs1" active-high
        .cs2_n   (1'b0),                  // VERIFY: "cs2_n" active-low, tie low to always enable
        .rw_n    (~dmem_wr_en),           // VERIFY: "rw_n" or "rw"
        .rs      (dmem_addr[3:0]),        // VERIFY: "rs", "addr", or "a"
        .data_in (dmem_wr_data),          // VERIFY: may be a single bidir "data[7:0]"
        .data_out(via_q),                 // VERIFY: see above
        .pa_in   (via_pa),                // VERIFY: "pa_in"/"pa", inout or split
        .pa_out  (),                      // VERIFY: if split in/out
        .pb_in   (via_pb),                // VERIFY: "pb_in"/"pb"
        .pb_out  (),                      // VERIFY: if split in/out
        .ca1     (via_ca1),               // VERIFY: "ca1"
        .ca2_in  (1'b0),                  // VERIFY: "ca2" may be bidir
        .ca2_out (via_ca2_out),
        .cb1     (via_cb1),               // VERIFY: "cb1"
        .cb2_in  (1'b0),                  // VERIFY: "cb2" may be bidir
        .cb2_out (via_cb2_out),
        .irq_n   (via_irq_n)              // VERIFY: "irq_n", "nIRQ", or "irq"
    );

    // ── Data read mux ─────────────────────────────────────────────────────────
    assign dmem_rd_data = acia_sel ? acia_q   :
                          via_sel  ? via_q    :
                          rom_sel  ? rom_dq   :
                                     ram_q;

    // ── IRQ aggregator ────────────────────────────────────────────────────────
    // Both peripherals produce active-low IRQ.  Combine with AND (wired-OR).
    assign irq_n = acia_irq_n & via_irq_n;

    // ── LEDs: show PC[5:0], active-low ───────────────────────────────────────
    assign led = ~pc[5:0];

endmodule
