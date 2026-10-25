// SPDX-License-Identifier: Apache-2.0
// systems/nes with its memory in block RAM (memory/bram): 2^MEM_AW bytes,
// mirrored through the shell's 8 MB window. Enough for NROM's PRG ROM; for
// boards whose own memory the system can't use yet.
module nes_bram #(
    parameter int          CLKS_PER_BIT = 18,
    parameter int          IDLE_CLKS    = 270_000,
    parameter int          DOT_NUM      = 35,
    parameter int          DOT_DEN      = 176,
    parameter int          MEM_AW       = 18,   // 256 KB
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [5:0] led
);
    logic        rst;
    logic        req, we, ack, ready;
    logic [22:0] addr;
    logic [7:0]  wdata, rdata;

    por u_por (.clk, .rst);

    nes #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .DOT_NUM(DOT_NUM), .DOT_DEN(DOT_DEN),
          .BUILD_ID(BUILD_ID)) u_nes (
        .clk, .uart_rx, .uart_tx, .led,
        .mem_req(req), .mem_we(we), .mem_addr(addr), .mem_wdata(wdata),
        .mem_ack(ack), .mem_rdata(rdata), .mem_ready(ready));

    bram_mem #(.AW(MEM_AW), .IW(23)) u_mem (
        .clk, .rst, .req, .we, .addr, .wdata, .ack, .rdata, .ready);
endmodule
