// ============================================================================
// i2c.v      I2C master for TMEPT CPU
// ============================================================================
//
// Byte-oriented I2C master.  The CPU writes one byte at a time and polls
// the status register for completion — matching the software driver model
// of the 6502 project's 1602-I2C LCD via PCF8574.
//
// SCL frequency = f_cpu / (4 × (PRESCALE + 1))
// Default: 6.75 MHz / (4 × 28) ≈ 60 kHz  (standard-mode safe for LCD)
//
// Register map (2-bit addr):
//   $00  [W]    Data / address   – byte to transmit (next START/WRITE/STOP)
//   $01  [W]    Command          – bit 2: GEN_STOP  (generate STOP condition)
//                                  bit 1: GEN_START (generate START + send addr)
//                                  bit 0: WR_BYTE   (send Data register)
//        [R]    Status           – bit 7: busy (1 = transaction in progress)
//                                  bit 6: ack  (1 = NAK received last byte)
//                                  bit 5: arb  (1 = arbitration lost)
//   $02  [R/W]  Prescale low     – low byte of SCL prescaler
//   $03  [R/W]  Prescale high    – high byte of SCL prescaler
//
// Typical usage sequence (send byte to slave):
//   1. Write slave address (with W bit) to $00
//   2. Write GEN_START | WR_BYTE to $01  → generates START, sends address
//   3. Poll $01 bit 7 until clear
//   4. Write data byte to $00
//   5. Write WR_BYTE to $01
//   6. Poll until clear
//   7. Write GEN_STOP to $01            → generates STOP
//   8. Poll until clear
// ============================================================================

`ifndef _I2C_V_
`define _I2C_V_

module i2c #(
    parameter CLK_HZ   = 6_750_000,
    parameter I2C_HZ   = 60_000
) (
    input  wire       clk,
    input  wire       rst_n,

    // CPU interface
    input  wire [1:0] addr,
    input  wire       wr_en,
    input  wire [7:0] wr_data,
    output reg  [7:0] rd_data,

    // I2C pins (open-drain: drive low or release/tristate)
    output wire       scl_oe,   // 1 = pull SCL low
    input  wire       scl_in,
    output wire       sda_oe,   // 1 = pull SDA low
    input  wire       sda_in
);

    // ── Prescaler default (overrideable at runtime) ───────────────────────────
    localparam PRESCALE_DEF = (CLK_HZ / (I2C_HZ * 4)) - 1;

    reg [15:0] prescale;
    reg [15:0] clk_cnt;

    // SCL phase clock: ticks every (prescale+1) cpu clocks
    // Full bit = 4 phases: SCL_LOW_0, SDA_CHANGE, SCL_HIGH, SCL_LOW_1
    reg tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_cnt <= 16'h0;
            tick    <= 1'b0;
        end else begin
            tick <= 1'b0;
            if (clk_cnt == prescale) begin
                clk_cnt <= 16'h0;
                tick    <= 1'b1;
            end else begin
                clk_cnt <= clk_cnt + 16'h1;
            end
        end
    end

    // ── State machine ────────────────────────────────────────────────────────
    localparam S_IDLE       = 4'd0;
    localparam S_START_A    = 4'd1;  // SDA goes low while SCL high
    localparam S_START_B    = 4'd2;  // SCL goes low
    localparam S_BIT_LOW    = 4'd3;  // SCL low, set SDA
    localparam S_BIT_HIGH   = 4'd4;  // SCL high (data valid)
    localparam S_BIT_HIGH2  = 4'd5;  // SCL high hold
    localparam S_BIT_LOW2   = 4'd6;  // SCL falls
    localparam S_ACK_LOW    = 4'd7;  // SCL low, release SDA for ACK
    localparam S_ACK_HIGH   = 4'd8;  // SCL high, sample ACK
    localparam S_ACK_LOW2   = 4'd9;  // SCL falls after ACK
    localparam S_STOP_A     = 4'd10; // SCL high, SDA still low
    localparam S_STOP_B     = 4'd11; // SDA goes high (STOP)
    localparam S_DONE       = 4'd12; // one idle tick before ready

    reg [3:0]  state;
    reg [3:0]  bit_cnt;    // counts 7..0 for 8 data bits
    reg [7:0]  shift;      // TX shift register
    reg        do_start;
    reg        do_stop;
    reg        nak;        // 1 = slave NAKed
    reg        arb_lost;

    reg scl_r, sda_r;     // registered drive signals

    assign scl_oe = scl_r;
    assign sda_oe = sda_r;

    // Synchronise SDA_IN
    reg sda_s0, sda_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) {sda_s1, sda_s0} <= 2'b11;
        else        {sda_s1, sda_s0} <= {sda_s0, sda_in};
    end

    reg [7:0] data_reg;
    reg       busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            scl_r     <= 1'b0;   // release (high)
            sda_r     <= 1'b0;
            prescale  <= PRESCALE_DEF[15:0];
            busy      <= 1'b0;
            nak       <= 1'b0;
            arb_lost  <= 1'b0;
            do_start  <= 1'b0;
            do_stop   <= 1'b0;
            bit_cnt   <= 4'd7;
            shift     <= 8'h00;
            data_reg  <= 8'h00;
        end else begin

            // ── CPU register writes (can happen any time) ─────────────────
            if (wr_en && !busy) begin
                case (addr)
                    2'h0: data_reg <= wr_data;
                    2'h1: begin
                        if (wr_data[1]) do_start <= 1'b1;
                        if (wr_data[2]) do_stop  <= 1'b1;
                        if (wr_data[0] || wr_data[1]) begin
                            // Start a byte transfer
                            shift   <= (wr_data[1]) ? data_reg : data_reg;
                            busy    <= 1'b1;
                            bit_cnt <= 4'd7;
                            nak     <= 1'b0;
                            state   <= do_start ? S_START_A : S_BIT_LOW;
                            if (wr_data[1]) do_start <= 1'b0;
                        end
                        if (wr_data[2] && !wr_data[0] && !wr_data[1]) begin
                            // Stop-only command
                            busy  <= 1'b1;
                            state <= S_STOP_A;
                            do_stop <= 1'b0;
                        end
                    end
                    2'h2: prescale[7:0]  <= wr_data;
                    2'h3: prescale[15:8] <= wr_data;
                    default: ;
                endcase
            end

            // ── State machine (advances on tick) ──────────────────────────
            if (tick && busy) begin
                case (state)
                    S_START_A: begin
                        // SDA falls while SCL is high → START condition
                        sda_r <= 1'b1;   // pull SDA low
                        state <= S_START_B;
                    end
                    S_START_B: begin
                        scl_r <= 1'b1;   // pull SCL low
                        state <= S_BIT_LOW;
                    end
                    S_BIT_LOW: begin
                        // SCL low: drive SDA to next bit
                        sda_r <= ~shift[7];   // 0=release(high), 1=pull(low)
                        shift <= {shift[6:0], 1'b0};
                        scl_r <= 1'b1;        // keep SCL low
                        state <= S_BIT_HIGH;
                    end
                    S_BIT_HIGH: begin
                        scl_r <= 1'b0;        // release SCL (goes high)
                        state <= S_BIT_HIGH2;
                    end
                    S_BIT_HIGH2: begin
                        // Hold SCL high one more tick
                        if (bit_cnt == 4'd0)
                            state <= S_ACK_LOW;
                        else begin
                            bit_cnt <= bit_cnt - 4'd1;
                            state   <= S_BIT_LOW2;
                        end
                    end
                    S_BIT_LOW2: begin
                        scl_r <= 1'b1;   // pull SCL low
                        state <= S_BIT_LOW;
                    end
                    S_ACK_LOW: begin
                        sda_r <= 1'b0;   // release SDA for slave to ACK
                        scl_r <= 1'b1;   // SCL low
                        state <= S_ACK_HIGH;
                    end
                    S_ACK_HIGH: begin
                        scl_r <= 1'b0;   // release SCL
                        state <= S_ACK_LOW2;
                    end
                    S_ACK_LOW2: begin
                        nak   <= sda_s1;  // sample: 0=ACK, 1=NAK
                        scl_r <= 1'b1;   // pull SCL low
                        if (do_stop) begin
                            state   <= S_STOP_A;
                            do_stop <= 1'b0;
                        end else
                            state <= S_DONE;
                    end
                    S_STOP_A: begin
                        // SCL high, SDA still low → set up for STOP
                        sda_r <= 1'b1;   // keep SDA low
                        scl_r <= 1'b0;   // release SCL (goes high)
                        state <= S_STOP_B;
                    end
                    S_STOP_B: begin
                        sda_r <= 1'b0;   // release SDA (goes high) → STOP
                        state <= S_DONE;
                    end
                    S_DONE: begin
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end

    // ── CPU read mux ─────────────────────────────────────────────────────────
    always @(*) begin
        case (addr)
            2'h0:    rd_data = data_reg;
            2'h1:    rd_data = {busy, arb_lost, nak, 5'h0};
            2'h2:    rd_data = prescale[7:0];
            2'h3:    rd_data = prescale[15:8];
            default: rd_data = 8'hFF;
        endcase
    end

endmodule

`endif // _I2C_V_
