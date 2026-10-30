// SPDX-License-Identifier: Apache-2.0
// 2^AW bytes of block RAM behind memory/sdram's byte port, for boards whose
// memory a system can't otherwise use yet: hold req (with addr, we, wdata)
// until ack, a one-clock pulse that also marks rdata valid on a read; req may
// still be high while ack is. Every access takes one clock. Addresses wrap at
// 2^AW, so a wider address mirrors.
//
// The memory is built from banks of 2^BANK_AW bytes, each a memory of its own
// and the read muxed after them, for tools that can't place a deeper one
// (openXC7 can't place more than 32 KB as one).
module bram_mem #(
    parameter int AW      = 18,  // 256 KB
    parameter int IW      = 23,  // the port's address width
    parameter int BANK_AW = AW   // each bank's address width, up to AW
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
    localparam int NB = 2 ** (AW - BANK_AW);

    wire        take = req && !ack;

    /* verilator lint_off UNUSEDSIGNAL */
    wire [IW-1:0] a = addr;  // only the low AW bits select
    /* verilator lint_on UNUSEDSIGNAL */

    if (NB == 1) begin : g_one
        logic [7:0] mem[2**AW];

        always_ff @(posedge clk) begin
            if (take && we)
                mem[a[AW-1:0]] <= wdata;
            rdata <= mem[a[AW-1:0]];
        end
    end else begin : g_banks
        logic [7:0]         q[NB];
        logic [AW-BANK_AW-1:0] sel;

        for (genvar b = 0; b < NB; b++) begin : g_bank
            logic [7:0] mem[2**BANK_AW];

            always_ff @(posedge clk) begin
                if (take && we && a[AW-1:BANK_AW] == (AW - BANK_AW)'(b))
                    mem[a[BANK_AW-1:0]] <= wdata;
                q[b] <= mem[a[BANK_AW-1:0]];
            end
        end

        always_ff @(posedge clk)
            sel <= a[AW-1:BANK_AW];

        assign rdata = q[sel];
    end

    always_ff @(posedge clk)
        ack <= take && !rst;

    assign ready = 1'b1;
endmodule
