// SPDX-License-Identifier: Apache-2.0
// 8N1 UART transmitter with a valid/ready input. Back-to-back bytes take exactly
// 10 bit times each, so an echo keeps pace with the sender.
module uart_tx #(
    parameter int CLKS_PER_BIT = 9  // clk / baud; 27 MHz / 3 Mbaud = 9
) (
    input  logic       clk,
    input  logic       rst,    // synchronous
    input  logic [7:0] data,
    input  logic       valid,
    output logic       ready,  // a byte is taken on valid && ready
    output logic       tx
);
    localparam int CW = $clog2(CLKS_PER_BIT + 1);
    localparam logic [CW-1:0] LAST = CW'(CLKS_PER_BIT - 1);

    logic [9:0]    shift;  // stop, data[7:0], start; sent LSB first
    logic [3:0]    left;   // bits still to send
    logic [CW-1:0] cnt;

    // Ready from the last clock of the stop bit, so the next start bit follows at once.
    assign ready = !rst && (left == 4'd0 || (left == 4'd1 && cnt == LAST));
    assign tx    = shift[0];  // straight from a flop, so the pin never glitches

    always_ff @(posedge clk)
        if (rst) begin
            shift <= '1;
            left  <= '0;
            cnt   <= '0;
        end else if (ready && valid) begin
            shift <= {1'b1, data, 1'b0};
            left  <= 4'd10;
            cnt   <= '0;
        end else if (left != 4'd0) begin
            if (cnt == LAST) begin
                cnt   <= '0;
                shift <= {1'b1, shift[9:1]};
                left  <= left - 1'b1;
            end else
                cnt <= cnt + 1'b1;
        end
endmodule
