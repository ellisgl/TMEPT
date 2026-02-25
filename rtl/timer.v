// ============================================================================
// timer.v    16-bit interval timer for TMEPT CPU
// ============================================================================
//
// Mirrors the core behaviour of the 6522 VIA's Timer 1 (continuous mode).
//
// The timer counts down from the latch value at the CPU clock rate.
// When it reaches zero it asserts irq for one cycle, reloads from the latch,
// and continues — giving a periodic interrupt at  f_cpu / (latch + 1)  Hz.
//
// Writing the high byte of the latch also arms the timer (loads and starts).
// The timer can be stopped by writing 0 to the control register.
//
// Register map (2-bit addr):
//   $00  [R/W]  Latch low byte    – write low 8 bits of reload value
//   $01  [R/W]  Latch high byte   – write high 8 bits; arms / restarts timer
//                                   read returns current counter high byte
//   $02  [R]    Counter low byte  – current down-counter value (low)
//   $03  [R/W]  Control           – bit 0: run (1=running, 0=stopped)
//                                   bit 1: irq enable
//                                   bit 2: single-shot (1) vs continuous (0)
//                                   read: also bit 7 = irq pending flag
//                                   write bit 3: clear irq flag
//
// IRQ output: active-high, one-clock pulse (even if enable=0, flag still sets)
// ============================================================================

`ifndef _TIMER_V_
`define _TIMER_V_

module timer (
    input  wire       clk,
    input  wire       rst_n,

    // CPU interface
    input  wire [1:0] addr,
    input  wire       wr_en,
    input  wire [7:0] wr_data,
    output reg  [7:0] rd_data,

    // Interrupt to CPU
    output wire       irq
);

    reg [15:0] latch;      // reload value
    reg [15:0] counter;    // down-counter
    reg        run;        // 1 = counting
    reg        irq_en;     // 1 = drive IRQ pin when flag set
    reg        single;     // 1 = single-shot, stop after one period
    reg        irq_flag;   // interrupt pending

    // ── Count & reload logic ──────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latch    <= 16'hFFFF;
            counter  <= 16'hFFFF;
            run      <= 1'b0;
            irq_en   <= 1'b0;
            single   <= 1'b0;
            irq_flag <= 1'b0;
        end else begin
            // ── CPU writes ───────────────────────────────────────────────────
            if (wr_en) begin
                case (addr)
                    2'h0: latch[7:0]  <= wr_data;
                    2'h1: begin
                        latch[15:8] <= wr_data;
                        // Writing high byte arms the timer
                        counter <= {wr_data, latch[7:0]};
                        run     <= 1'b1;
                        irq_flag <= 1'b0;
                    end
                    2'h3: begin
                        run     <= wr_data[0];
                        irq_en  <= wr_data[1];
                        single  <= wr_data[2];
                        if (wr_data[3]) irq_flag <= 1'b0;  // clear flag
                    end
                    default: ;
                endcase
            end

            // ── Count down ───────────────────────────────────────────────────
            if (run) begin
                if (counter == 16'h0000) begin
                    irq_flag <= 1'b1;
                    if (single) begin
                        run     <= 1'b0;
                        counter <= latch;
                    end else begin
                        counter <= latch;
                    end
                end else begin
                    counter <= counter - 16'h1;
                end
            end
        end
    end

    assign irq = irq_flag & irq_en;

    // ── CPU read mux ─────────────────────────────────────────────────────────
    always @(*) begin
        case (addr)
            2'h0:    rd_data = latch[7:0];
            2'h1:    rd_data = counter[15:8];
            2'h2:    rd_data = counter[7:0];
            2'h3:    rd_data = {irq_flag, 4'h0, single, irq_en, run};
            default: rd_data = 8'hFF;
        endcase
    end

endmodule

`endif // _TIMER_V_
