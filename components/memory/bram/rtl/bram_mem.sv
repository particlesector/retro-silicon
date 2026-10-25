// SPDX-License-Identifier: Apache-2.0
// 2^AW bytes of block RAM behind memory/sdram's byte port, for boards whose
// memory a system can't otherwise use yet: hold req (with addr, we, wdata)
// until ack, a one-clock pulse that also marks rdata valid on a read; req may
// still be high while ack is. Every access takes one clock. Addresses wrap at
// 2^AW, so a wider address mirrors.
module bram_mem #(
    parameter int AW = 18,   // 256 KB
    parameter int IW = 23    // the port's address width
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          req,
    input  logic          we,
    input  logic [IW-1:0] addr,
    input  logic [7:0]    wdata,
    output logic          ack,
    output logic [7:0]    rdata,
    output logic          ready    // always: block RAM needs no power-up sequence
);
    logic [7:0] mem[2**AW];
    wire        take = req && !ack;

    /* verilator lint_off UNUSEDSIGNAL */
    wire [IW-1:0] a = addr;  // only the low AW bits select
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge clk) begin
        if (take && we)
            mem[a[AW-1:0]] <= wdata;
        rdata <= mem[a[AW-1:0]];
    end

    always_ff @(posedge clk)
        ack <= take && !rst;

    assign ready = 1'b1;
endmodule
