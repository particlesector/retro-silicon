// SPDX-License-Identifier: Apache-2.0
// systems/nes with its memory in a 2M x 32 SDRAM (memory/sdram), such as the
// Tang Nano 20K's. The board drives the chip's clock with the inverse of clk
// and splits the data bus for its tristate buffer.
module nes_sdram #(
    parameter int          CLKS_PER_BIT = 18,
    parameter int          IDLE_CLKS    = 270_000,
    parameter int          FREQ_MHZ     = 27,
    parameter int          DOT_NUM      = 35,
    parameter int          DOT_DEN      = 176,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic        clk,
    input  logic        uart_rx,
    output logic        uart_tx,
    output logic [5:0]  led,

    output logic        sd_cke,
    output logic        sd_cs_n,
    output logic        sd_ras_n,
    output logic        sd_cas_n,
    output logic        sd_we_n,
    output logic [1:0]  sd_ba,
    output logic [10:0] sd_addr,
    output logic [3:0]  sd_dqm,
    output logic [31:0] sd_dq_o,
    output logic        sd_dq_oe,
    input  logic [31:0] sd_dq_i
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

    sdram_ctrl #(.FREQ_MHZ(FREQ_MHZ)) u_sdram (
        .clk, .rst,
        .req, .we, .addr, .wdata, .ack, .rdata, .ready,
        .sd_cke, .sd_cs_n, .sd_ras_n, .sd_cas_n, .sd_we_n, .sd_ba, .sd_addr, .sd_dqm,
        .sd_dq_o, .sd_dq_oe, .sd_dq_i);
endmodule
