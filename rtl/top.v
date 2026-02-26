`timescale 1ns / 1ps
`default_nettype none
`include "6522-VIA/rtl/via.v"
`include "6551-ACIA/rtl/acia.v"
`include "rtl/clock_divider.v"
`include "rtl/reset.v"
`include "rtl/ram.v"
`include "rtl/rom.v"
`include "rtl/reg_file.v"
`include "rtl/fetch.v"
`include "rtl/decode.v"
`include "rtl/execute.v"
`include "rtl/alu_arith.v"
`include "rtl/alu_bitmanip.v"
`include "rtl/alu_shift.v"
`include "rtl/alu.v"

module top #(
    parameter integer SYS_CLK_HZ  = 27_000_000, // Input oscillator frequency
    parameter integer CLK_DIVISOR = 7           // Divides sys_clk; clk = sys_clk / (2 * DIVISOR)
)(
    input  wire       sys_clk,
    input  wire       rst_n,
    input  wire       uartRx,
    input  wire       uartCts,
    output wire       uartTx,
    output wire       uartRts,
    inout  wire [7:0] PB,        // VIA6522 Port B
    inout  wire [7:0] PA         // VIA6522 Port A 0 = SD CS, 1 = SD MOSI, 2 = SD CLK, 3 = SD MISO, 4-7 = GPIO
);

    // $6001
    // Connect CS   to PA4 (6522 pin 5) > PA0 (6522 pin 1)
    // Connect SCK  to PA3 (6522 pin 4) > PA2 (6522 pin 3)
    // Connect MOSI to PA2 (6522 pin 3) > PA1 (6522 pin 2)
    // Connect MISO to PA1 (6522 pin 2) > PA3 (6522 pin 4)
    localparam  integer CPU_HZ = SYS_CLK_HZ / (2 * CLK_DIVISOR);

    wire        clk;  // Divided clock, about 1.929 MHz with DIVISOR=7 from 27 MHz input
    wire        reset;
    reg  [15:0] address;
    wire [15:0] address_unregistered;
    wire        cpu_we;
    wire        cpu_rdy = 1'b1;
    wire  [7:0] cpu_di;
    wire  [7:0] cpu_do;
    wire        cpu_irq;
    wire        via_cs;
    wire        rom_cs;
    wire        ram_cs;
    wire        uart_cs;
    wire  [7:0] via_do;
    wire        via_irq_n;
    wire        uart_irq_n;
    wire  [7:0] rom_do;
    wire  [7:0] ram_do;
    wire  [7:0] uart_do;


    // VIA 6522 control lines
    wire        via_ca1;
    wire        via_ca2_in;
    wire        via_ca2_out;
    wire        via_cb1_in;
    wire        via_cb1_out;
    wire        via_cb2_in;
    wire        via_cb2_out;
    
    // Tie unused control lines to safe defaults
    assign via_ca1 = 1'b0;
    assign via_ca2_in = 1'b0;
    assign via_cb1_in = 1'b0;
    assign via_cb2_in = 1'b0;

    

    // Instantiate Clock Divider (e.g., divide 27 MHz to ~1 MHz)
    clock_divider #(
        .DIVISOR(CLK_DIVISOR)
    ) clk_div_inst (
        .clk_in(sys_clk),
        .clk_out(clk)
    );

    reset reset_inst (
        .clk(clk),
        .reset_n(rst_n),
        .reset(reset)
    );

    // 16KB RAM at 16'h0000 - 16'h3FFF
    ram ram_inst (
        .clk(clk),
        .ADDR(address[13:0]),
        .WE(cpu_we),
        .CS(ram_cs),
        .DI(cpu_do),
        .DO(ram_do)
    );

    // 32KB ROM at 16'h8000 - 16'hFFFF
    rom rom_inst (
        .ADDR(address[14:0]),
        .CS(rom_cs),
        .DO(rom_do)
    );

    // VIA 6522 at 16'h6000 - 16'h600F
    // 0x6000: ORB/IRB  - Port B
    // 0x6001: ORA/IRA  - Port A  
    // 0x6002: DDRB     - Port B Direction
    // 0x6003: DDRA     - Port A Direction
    // 0x6004: T1C-L    - Timer 1 Counter Low
    // 0x6005: T1C-H    - Timer 1 Counter High
    // 0x6006: T1L-L    - Timer 1 Latch Low
    // 0x6007: T1L-H    - Timer 1 Latch High
    // 0x6008: T2C-L    - Timer 2 Counter Low
    // 0x6009: T2C-H    - Timer 2 Counter High
    // 0x600A: SR       - Shift Register
    // 0x600B: ACR      - Auxiliary Control
    // 0x600C: PCR      - Peripheral Control
    // 0x600D: IFR      - Interrupt Flag Register
    // 0x600E: IER      - Interrupt Enable Register
    // 0x600F: ORA/IRA  - Port A (no handshake)
    via via_inst (
        .phi2(clk),
        .rst_n(~reset),
        .cs1(via_cs),
        .cs2_n(1'b0),          // cs2_n tied low (chip select active)
        .rw(~cpu_we),          // VIA uses RW (1=read, 0=write), opposite of WE
        .rs(address[3:0]),
        .data_in(cpu_do),
        .data_out(via_do),
        .port_a(PA),
        .port_b(PB),
        .ca1(via_ca1),
        .ca2_in(via_ca2_in),
        .ca2_out(via_ca2_out),
        .cb1_in(via_cb1_in),
        .cb1_out(via_cb1_out),
        .cb2_in(via_cb2_in),
        .cb2_out(via_cb2_out),
        .irq_n(via_irq_n)
    );

    // UART at 16'h5000 - 16'h5003
    acia #(
        .XTLI_FREQ(SYS_CLK_HZ)
    ) uart_inst (
        .RESET(~reset),
        .PHI2(clk),
        .CS(~uart_cs),
        .RWN(~cpu_we),
        .RS(address[1:0]),
        .DATAIN(cpu_do),
        .DATAOUT(uart_do),
        .XTLI(sys_clk),// Use the raw oscillator for accurate baud generation
        .RTSB(uartRts),
        .CTSB(1'b0), // Tie CTS low if hardware flow control is unused
        .DTRB(), // Not used
        .RXD(uartRx),
        .TXD(uartTx),
        .IRQn(uart_irq_n)
    );

 hdmi_text_video_compact video (
    .clk_cpu(clk),
    .reset(reset),
    .cs(video_cs),
    .we(cpu_we),
    .addr(address[10:0]),  // Only 11 bits now
    .data_in(cpu_do),
    .data_out(video_do),
    
    .clk_sys(sys_clk),
    
    .tmds_data_p(hdmiTmdsData_p),
    .tmds_data_n(hdmiTmdsData_n),
    .tmds_clk_p(hdmiTmdsClk_p),
    .tmds_clk_n(hdmiTmdsClk_n)
);


    // Note: Tri-state logic is now handled inside via6522 module
    // PA and PB are connected directly as inout ports

    // CPU Interrupt ORing
    assign cpu_irq    = ~via_irq_n | ~uart_irq_n; // CPU input is active high

    // CPU DIN MU X
    assign ram_cs     = (address[15:14] == 2'b00);      // 0x0000 - 0x3FFF
    assign uart_cs    = (address[15:4]  == 12'h500);    // 0x5000 - 0x500F
    assign via_cs     = (address[15:4]  == 12'h600);    // 0x6000 - 0x600F
    assign video_cs   = (address[15:4]  == 12'h700);    // 0x7000 - 0x7FFF
    assign rom_cs     = address[15];                    // 0x8000 - 0xFFFF

    assign cpu_di     =
        rom_cs   ? rom_do   :
        ram_cs   ? ram_do   :
        via_cs   ? via_do   :
        video_cs ? video_do :
        uart_cs  ? uart_do  : 8'hXX;
    
        // "When using external asynchronous memory, you should register the "AD" signals"
    // Also register uart_rx_in to break long paths and resample UART input
    always @(posedge clk) begin
        address    <= address_unregistered;
    end

endmodule
`default_nettype wire
