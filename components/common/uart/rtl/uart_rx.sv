// SPDX-License-Identifier: Apache-2.0
// 8N1 UART receiver. Samples each bit at its middle and returns to idle in the
// middle of the stop bit, so a sender running slightly fast never loses sync.
module uart_rx #(
    parameter int CLKS_PER_BIT = 9  // clk / baud; 27 MHz / 3 Mbaud = 9
) (
    input  logic       clk,
    input  logic       rst,        // synchronous
    input  logic       rx,
    output logic [7:0] data,
    output logic       valid,      // one-cycle pulse: `data` holds a byte
    output logic       frame_err   // one-cycle pulse: stop bit was low, byte dropped
);
    localparam int CW = $clog2(CLKS_PER_BIT + 1);
    localparam logic [CW-1:0] LAST = CW'(CLKS_PER_BIT - 1);
    localparam logic [CW-1:0] HALF = CW'((CLKS_PER_BIT - 1) / 2);

    typedef enum logic [1:0] {IDLE, START, DATA, STOP} state_t;

    logic [2:0]    sync;
    state_t        state;
    logic [CW-1:0] cnt;
    logic [2:0]    bit_n;
    logic [7:0]    shift;

    wire line = sync[2];

    always_ff @(posedge clk) begin
        sync      <= {sync[1:0], rx};
        valid     <= 1'b0;
        frame_err <= 1'b0;

        case (state)
            IDLE:
                if (!line) begin
                    state <= START;
                    cnt   <= '0;
                end
            START:
                if (cnt == HALF) begin
                    state <= line ? IDLE : DATA;  // high again: a glitch, not a start bit
                    cnt   <= '0;
                    bit_n <= '0;
                end else
                    cnt <= cnt + 1'b1;
            DATA:
                if (cnt == LAST) begin
                    cnt   <= '0;
                    shift <= {line, shift[7:1]};
                    if (bit_n == 3'd7)
                        state <= STOP;
                    bit_n <= bit_n + 1'b1;
                end else
                    cnt <= cnt + 1'b1;
            STOP:
                if (cnt == LAST) begin
                    data      <= shift;
                    valid     <= line;
                    frame_err <= !line;
                    state     <= IDLE;
                end else
                    cnt <= cnt + 1'b1;
        endcase

        if (rst) begin
            sync      <= '1;  // line idles high
            state     <= IDLE;
            valid     <= 1'b0;
            frame_err <= 1'b0;
        end
    end
endmodule
