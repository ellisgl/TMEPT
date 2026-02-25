// ============================================================================
// gpio.v     8-bit GPIO port for TMEPT CPU
// ============================================================================
//
// Two independent 8-bit ports (A and B), each with a direction register.
// Mirrors the minimal functionality of the 6522 VIA's port A/B without
// the handshake or shift-register machinery.
//
// Register map (3-bit addr):
//   $00  [R/W]  Port A data        – reads pins, writes output latch
//   $01  [R/W]  Port A direction   – 0=input, 1=output (per bit)
//   $02  [R/W]  Port B data
//   $03  [R/W]  Port B direction
//   $04  [R]    Interrupt flags    – bit 0: PA input-change, bit 1: PB input-change
//   $05  [W]    Interrupt enable   – bit 0: enable PA IRQ, bit 1: enable PB IRQ
//   $06  [W]    Interrupt clear    – write 1 to clear flag
//
// IRQ output is asserted (active-high) when any enabled flag is set.
// Input-change detection uses a one-cycle edge detector on input pins.
// ============================================================================

`ifndef _GPIO_V_
`define _GPIO_V_

module gpio (
    input  wire       clk,
    input  wire       rst_n,

    // CPU interface
    input  wire [2:0] addr,
    input  wire       wr_en,
    input  wire [7:0] wr_data,
    output reg  [7:0] rd_data,

    // Physical pins
    inout  wire [7:0] port_a,
    inout  wire [7:0] port_b,

    // Interrupt to CPU
    output wire       irq
);

    // ── Port A ────────────────────────────────────────────────────────────────
    reg [7:0] pa_out;   // output latch
    reg [7:0] pa_dir;   // direction: 1=output

    // Tristate drive
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : pa_drive
            assign port_a[i] = pa_dir[i] ? pa_out[i] : 1'bz;
        end
    endgenerate

    // Input synchroniser (2-stage)
    reg [7:0] pa_s0, pa_s1, pa_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {pa_s2, pa_s1, pa_s0} <= 24'h0;
        else        {pa_s2, pa_s1, pa_s0} <= {pa_s1, pa_s0, port_a};
    end

    // ── Port B ────────────────────────────────────────────────────────────────
    reg [7:0] pb_out;
    reg [7:0] pb_dir;

    generate
        for (i = 0; i < 8; i = i + 1) begin : pb_drive
            assign port_b[i] = pb_dir[i] ? pb_out[i] : 1'bz;
        end
    endgenerate

    reg [7:0] pb_s0, pb_s1, pb_s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {pb_s2, pb_s1, pb_s0} <= 24'h0;
        else        {pb_s2, pb_s1, pb_s0} <= {pb_s1, pb_s0, port_b};
    end

    // ── Interrupt logic ───────────────────────────────────────────────────────
    // Flag set on any input bit changing (only input pins, masked by ~dir)
    wire pa_change = |(( pa_s2 ^ pa_s1) & ~pa_dir);
    wire pb_change = |(( pb_s2 ^ pb_s1) & ~pb_dir);

    reg [1:0] irq_flags;   // bit 0=PA, bit 1=PB
    reg [1:0] irq_enable;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_flags  <= 2'b00;
            irq_enable <= 2'b00;
        end else begin
            // Set flags on edge
            if (pa_change) irq_flags[0] <= 1'b1;
            if (pb_change) irq_flags[1] <= 1'b1;

            // CPU writes
            if (wr_en) begin
                case (addr)
                    3'h0: pa_out    <= (wr_data & pa_dir)  | (pa_out & ~pa_dir);
                    3'h1: pa_dir    <= wr_data;
                    3'h2: pb_out    <= (wr_data & pb_dir)  | (pb_out & ~pb_dir);
                    3'h3: pb_dir    <= wr_data;
                    3'h5: irq_enable <= wr_data[1:0];
                    3'h6: irq_flags <= irq_flags & ~wr_data[1:0]; // clear
                    default: ;
                endcase
            end
        end
    end

    assign irq = |(irq_flags & irq_enable);

    // ── CPU read mux ─────────────────────────────────────────────────────────
    always @(*) begin
        case (addr)
            3'h0:    rd_data = pa_s2;               // read pins (not latch)
            3'h1:    rd_data = pa_dir;
            3'h2:    rd_data = pb_s2;
            3'h3:    rd_data = pb_dir;
            3'h4:    rd_data = {6'h0, irq_flags};
            3'h5:    rd_data = {6'h0, irq_enable};
            default: rd_data = 8'hFF;
        endcase
    end

endmodule

`endif // _GPIO_V_
