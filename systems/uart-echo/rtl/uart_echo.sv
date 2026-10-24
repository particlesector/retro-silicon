// SPDX-License-Identifier: Apache-2.0
// UART link test: echoes every received byte through a 2 KB FIFO.
// LEDs (active low): led[0] overflow, led[1] framing error (both sticky until
// reload), led[5] heartbeat.
module uart_echo #(
    parameter int CLKS_PER_BIT = 9  // 27 MHz / 3 Mbaud
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [5:0] led
);
    logic        rst;
    logic [7:0]  rx_data, fifo_data;
    logic        rx_valid, rx_frame_err;
    logic        fifo_full, fifo_empty, fifo_ren;
    logic        tx_ready;
    logic        pending;  // fifo_data holds a byte not yet taken by the transmitter
    logic        overflow, frame_err;
    logic [24:0] beat;

    por u_por (.clk, .rst);

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk, .rst, .rx(uart_rx), .data(rx_data), .valid(rx_valid), .frame_err(rx_frame_err));

    fifo #(.WIDTH(8), .DEPTH_LOG2(11)) u_fifo (
        .clk, .rst, .wdata(rx_data), .wen(rx_valid), .full(fifo_full),
        .ren(fifo_ren), .rdata(fifo_data), .empty(fifo_empty));

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk, .rst, .data(fifo_data), .valid(pending), .ready(tx_ready), .tx(uart_tx));

    assign fifo_ren = !fifo_empty && (!pending || tx_ready);

    always_ff @(posedge clk)
        if (rst) begin
            pending   <= 1'b0;
            overflow  <= 1'b0;
            frame_err <= 1'b0;
            beat      <= '0;
        end else begin
            if (fifo_ren)
                pending <= 1'b1;
            else if (tx_ready)
                pending <= 1'b0;
            if (rx_valid && fifo_full)
                overflow <= 1'b1;
            if (rx_frame_err)
                frame_err <= 1'b1;
            beat <= beat + 1'b1;
        end

    assign led = ~{beat[24], 3'b000, frame_err, overflow};
endmodule
