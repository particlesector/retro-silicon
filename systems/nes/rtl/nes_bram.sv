// SPDX-License-Identifier: Apache-2.0
// systems/nes with its memory in block RAM (memory/bram): 2^MEM_AW bytes,
// mirrored through the shell's 8 MB window. Enough for NROM's PRG ROM; for
// boards whose own memory the system can't use yet. Its picture goes out
// as HDMI through nes_video.
module nes_bram #(
    parameter int          CLKS_PER_BIT = 18,
    parameter int          IDLE_CLKS    = 270_000,
    parameter int          DOT_NUM      = 35,
    parameter int          DOT_DEN      = 176,
    parameter int          MEM_AW       = 18,   // 256 KB
    parameter bit          PACE         = 1'b0,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [5:0] led,

    input  logic        pclk,   // HDMI pixel clock, 74.25 MHz
    output logic [9:0]  tmds0,  // TMDS symbols for the board's serializers
    output logic [9:0]  tmds1,
    output logic [9:0]  tmds2
);
    logic        rst;
    logic        req, we, ack, ready;
    logic [22:0] addr;
    logic [7:0]  wdata, rdata;

    // The picture, out through nes_video.
    logic        pix_valid, v_waiting, v_req, v_cap_t, v_crc_ok, v_crc_t;
    logic [8:0]  pix;
    logic [7:0]  pix_x, pix_y;
    logic [31:0] v_crc;
    logic [15:0] v_shown, v_late, v_overrun;

    por u_por (.clk, .rst);

    nes #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .DOT_NUM(DOT_NUM), .DOT_DEN(DOT_DEN),
          .PACE(PACE), .BUILD_ID(BUILD_ID)) u_nes (
        .clk, .uart_rx, .uart_tx, .led,
        .mem_req(req), .mem_we(we), .mem_addr(addr), .mem_wdata(wdata),
        .mem_ack(ack), .mem_rdata(rdata), .mem_ready(ready),
        .pix_valid, .pix, .pix_x, .pix_y, .v_waiting, .v_req, .v_cap_t,
        .v_crc, .v_crc_ok, .v_crc_t, .v_shown, .v_late, .v_overrun);

    nes_video u_video (
        .clk, .rst, .pix_valid, .pix, .pix_x, .pix_y, .waiting(v_waiting), .req(v_req),
        .cap_t(v_cap_t), .crc(v_crc), .crc_ok(v_crc_ok), .crc_t(v_crc_t),
        .shown(v_shown), .late(v_late), .overrun(v_overrun),
        .pclk, .tmds0, .tmds1, .tmds2);

    bram_mem #(.AW(MEM_AW), .IW(23)) u_mem (
        .clk, .rst, .req, .we, .addr, .wdata, .ack, .rdata, .ready);
endmodule
