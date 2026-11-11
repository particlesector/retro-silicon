// SPDX-License-Identifier: Apache-2.0
// systems/atari-2600 (a2600_sys) with its cartridge's ROM in an SDRAM (memory/sdram), from address 0:
// by default the 2M x 32 chip of the Tang Nano 20K. The board drives the chip's clock with the
// inverse of clk and splits the data bus for its tristate buffer. The parameters are a2600_sys's and
// memory/sdram's.
module a2600_sdram #(
    parameter int          CLKS_PER_BIT     = 18,
    parameter int          IDLE_CLKS        = 270_000,
    parameter int          CC_NUM           = 35,
    parameter int          CC_DEN           = 264,
    parameter bit          TIA_SCORE_GLITCH = 1'b0,
    parameter bit          VIDEO            = 1'b0,
    parameter int          ROM_LOG2         = 19,       // up to 512 KB (3F's largest)
    parameter int          FREQ_MHZ         = 27,
    parameter int          DQ_W             = 32,
    parameter int          ROW_W            = 11,
    parameter int          COL_W            = 8,
    parameter int          RANKS            = 1,
    parameter int          REFRESH_NS       = 15_000,
    parameter logic [31:0] BUILD_ID         = '0,
    localparam int         NB               = DQ_W / 8,
    localparam int         AW               = (RANKS > 1 ? 1 : 0) + 2 + ROW_W + COL_W + $clog2(NB)
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
    output logic [ROW_W-1:0] sd_addr,
    output logic [NB-1:0]    sd_dqm,
    output logic [DQ_W-1:0]  sd_dq_o,
    output logic        sd_dq_oe,
    input  logic [DQ_W-1:0]  sd_dq_i,

    input  logic        pclk,   // with VIDEO: the HDMI pixel clock, 74.25 MHz
    output logic [9:0]  tmds0,
    output logic [9:0]  tmds1,
    output logic [9:0]  tmds2
);
    logic        rst;
    logic        req, we, ack;
    logic [7:0]  wdata, rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [23:0] addr;   // the SDRAM's AW bits of it
    logic [DQ_W-1:0] rdata_w;
    logic        ready;  // the controller holds requests until it's ready
    /* verilator lint_on UNUSEDSIGNAL */

    por u_por (.clk, .rst);

    a2600_sys #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .CC_NUM(CC_NUM), .CC_DEN(CC_DEN),
                .TIA_SCORE_GLITCH(TIA_SCORE_GLITCH), .VIDEO(VIDEO), .ROM_LOG2(ROM_LOG2), .ROM_EXT(1'b1),
                .BUILD_ID(BUILD_ID)) u_sys (
        .clk, .uart_rx, .uart_tx, .led, .pclk, .tmds0, .tmds1, .tmds2,
        .mem_req(req), .mem_we(we), .mem_addr(addr), .mem_wdata(wdata), .mem_ack(ack), .mem_rdata(rdata));

    sdram_ctrl #(.FREQ_MHZ(FREQ_MHZ), .REFRESH_NS(REFRESH_NS), .DQ_W(DQ_W), .ROW_W(ROW_W), .COL_W(COL_W),
                 .RANKS(RANKS)) u_sdram (
        .clk, .rst,
        .req, .we, .addr(AW'(addr)), .wdata, .ack, .rdata, .rdata_w, .ready, .ref_hold(1'b0),
        .sd_cke, .sd_cs_n, .sd_ras_n, .sd_cas_n, .sd_we_n, .sd_ba, .sd_addr, .sd_dqm,
        .sd_dq_o, .sd_dq_oe, .sd_dq_i);
endmodule
