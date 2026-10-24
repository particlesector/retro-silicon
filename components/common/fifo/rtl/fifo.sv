// SPDX-License-Identifier: Apache-2.0
// Synchronous FIFO with a registered read port, so Yosys maps it to block RAM.
// `rdata` is valid the cycle after a read is accepted.
module fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH_LOG2 = 11  // 2048 entries: one 18 Kbit BSRAM at 8 bits
) (
    input  logic             clk,
    input  logic             rst,    // synchronous; empties the FIFO
    input  logic [WIDTH-1:0] wdata,
    input  logic             wen,    // ignored when full
    output logic             full,
    input  logic             ren,    // ignored when empty
    output logic [WIDTH-1:0] rdata,
    output logic             empty
);
    logic [WIDTH-1:0]    mem[2**DEPTH_LOG2];
    logic [DEPTH_LOG2:0] wp;  // extra top bit tells full from empty
    logic [DEPTH_LOG2:0] rp;

    assign empty = wp == rp;
    assign full  = wp[DEPTH_LOG2] != rp[DEPTH_LOG2] && wp[DEPTH_LOG2-1:0] == rp[DEPTH_LOG2-1:0];

    always_ff @(posedge clk)
        if (wen && !full)
            mem[wp[DEPTH_LOG2-1:0]] <= wdata;

    always_ff @(posedge clk)
        if (ren && !empty)
            rdata <= mem[rp[DEPTH_LOG2-1:0]];

    always_ff @(posedge clk)
        if (rst) begin
            wp <= '0;
            rp <= '0;
        end else begin
            if (wen && !full)
                wp <= wp + 1'b1;
            if (ren && !empty)
                rp <= rp + 1'b1;
        end
endmodule
