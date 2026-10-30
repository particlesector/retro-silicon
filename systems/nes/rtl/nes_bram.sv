// SPDX-License-Identifier: Apache-2.0
// systems/nes with its memory in block RAM (memory/bram): 2^MEM_AW bytes,
// mirrored through the shell's 8 MB window. Enough for NROM's PRG ROM; for
// boards whose own memory the system can't use yet. Its picture goes out
// as HDMI, picture and sound, through nes_video.
module nes_bram #(
    parameter int          CLKS_PER_BIT = 18,
    parameter int          IDLE_CLKS    = 270_000,
    parameter int          DOT_NUM      = 35,
    parameter int          DOT_DEN      = 176,
    parameter int          MEM_AW       = 18,   // 256 KB
    parameter int          CHR_AW       = 13,   // CHR: 8 KB
    parameter int          BANK_AW      = 32,   // block RAM in banks of 2^BANK_AW bytes, if less than the size
    parameter bit          PACE         = 1'b0,
    parameter bit          SAVE_STATE   = 1'b1,
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
    /* verilator lint_off UNUSEDSIGNAL */
    logic        ref_hold;  // block RAM has no refresh
    /* verilator lint_on UNUSEDSIGNAL */

    // The picture, out through nes_video.
    logic        pix_valid, v_waiting, v_req, v_cap_t, v_crc_ok, v_crc_t;
    logic [8:0]  pix;
    logic [7:0]  pix_x, pix_y;
    logic [31:0] v_crc;
    logic [15:0] v_shown, v_late, v_overrun;
    logic        a_valid;  // the sound, 48 kHz
    logic [15:0] a_pcm;

    por u_por (.clk, .rst);

    nes #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .DOT_NUM(DOT_NUM), .DOT_DEN(DOT_DEN),
          .PACE(PACE), .SAVE_STATE(SAVE_STATE), .MEM_AW(MEM_AW), .CHR_AW(CHR_AW),
          .CHR_BANK_AW(BANK_AW < CHR_AW ? BANK_AW : CHR_AW), .BUILD_ID(BUILD_ID)) u_nes (
        .clk, .uart_rx, .uart_tx, .led,
        .mem_req(req), .mem_we(we), .mem_addr(addr), .mem_wdata(wdata),
        .mem_ack(ack), .mem_rdata(rdata), .mem_rdata_w(32'h0), .mem_ready(ready), .mem_ref_hold(ref_hold),
        .pix_valid, .pix, .pix_x, .pix_y, .v_waiting, .v_req, .v_cap_t,
        .v_crc, .v_crc_ok, .v_crc_t, .v_shown, .v_late, .v_overrun,
        .a_valid, .a_pcm);

    nes_video u_video (
        .clk, .rst, .pix_valid, .pix, .pix_x, .pix_y, .waiting(v_waiting), .req(v_req), .a_valid, .a_pcm,
        .cap_t(v_cap_t), .crc(v_crc), .crc_ok(v_crc_ok), .crc_t(v_crc_t),
        .shown(v_shown), .late(v_late), .overrun(v_overrun),
        .pclk, .tmds0, .tmds1, .tmds2);

    bram_mem #(.AW(MEM_AW), .IW(23), .BANK_AW(BANK_AW < MEM_AW ? BANK_AW : MEM_AW)) u_mem (
        .clk, .rst, .req, .we, .addr, .wdata, .ack, .rdata, .ready);
endmodule
