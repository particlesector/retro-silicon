// SPDX-License-Identifier: Apache-2.0
// systems/nes with its memory behind an AXI slave (memory/axi-bridge): the
// shell's 8 MB window at AXI address BASE, such as a Zynq-7000's DDR3 through
// an HP port, behind a read cache (memory/cache, 2^CACHE_IDX lines of 8
// bytes): a read through the bridge takes longer than a CPU cycle can wait
// without the system falling behind a display. CHR is in block RAM
// (2^CHR_AW bytes). Its picture goes out as HDMI, picture and sound, through
// nes_video. With ASYNC, the bridge and the AXI port run on their own clock
// (aclk), faster than the system's, behind memory/port-cdc.
module nes_axi #(
    parameter int          CLKS_PER_BIT = 18,
    parameter int          IDLE_CLKS    = 270_000,
    parameter int          DOT_NUM      = 35,
    parameter int          DOT_DEN      = 176,
    parameter int          CHR_AW       = 13,   // CHR: 8 KB
    parameter int          BANK_AW      = 32,   // CHR's block RAM in banks of 2^BANK_AW bytes, if less than its size
    parameter logic [31:0] BASE         = 32'h1000_0000,
    parameter int          CACHE_IDX    = 12,   // the read cache: 4096 lines, 32 KB
    parameter bit          ASYNC        = 1'b0, // the AXI port on aclk, across memory/port-cdc, not on clk
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
    output logic [9:0]  tmds2,

    // The memory: memory/axi-bridge's AXI master, on aclk with ASYNC (else on clk).
    input  logic        aclk,
    input  logic        axi_ready,  // the AXI port is out of reset and its memory set up
    output logic [31:0] m_araddr,
    output logic        m_arvalid,
    input  logic        m_arready,
    output logic [3:0]  m_arlen,
    output logic [2:0]  m_arsize,
    output logic [1:0]  m_arburst,
    output logic [3:0]  m_arcache,
    output logic [5:0]  m_arid,
    input  logic [63:0] m_rdata,
    input  logic        m_rvalid,
    output logic        m_rready,
    input  logic [1:0]  m_rresp,
    input  logic        m_rlast,
    output logic [31:0] m_awaddr,
    output logic        m_awvalid,
    input  logic        m_awready,
    output logic [3:0]  m_awlen,
    output logic [2:0]  m_awsize,
    output logic [1:0]  m_awburst,
    output logic [3:0]  m_awcache,
    output logic [5:0]  m_awid,
    output logic [63:0] m_wdata,
    output logic [7:0]  m_wstrb,
    output logic        m_wlast,
    output logic [5:0]  m_wid,
    output logic        m_wvalid,
    input  logic        m_wready,
    input  logic [1:0]  m_bresp,
    input  logic        m_bvalid,
    output logic        m_bready
);
    logic        rst;
    logic        req, we, ack, ready;
    logic [22:0] addr;
    logic [7:0]  wdata, rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        ref_hold;  // no refresh to hold off: CHR isn't in this memory
    logic [31:0] rdata_w, b_rdata_w;
    logic [7:0]  b_rdata;  // the cache takes whole lines (b_rdata_d)
    /* verilator lint_on UNUSEDSIGNAL */
    logic        b_req, b_we, b_ack, b_ready;
    logic [95:0] stats;  // the cache's hits, misses and prefetches
    logic [22:0] b_addr;
    logic [7:0]  b_wdata;
    logic [63:0] b_rdata_d;

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
          .PACE(PACE), .SAVE_STATE(SAVE_STATE), .MEM_AW(23), .CHR_AW(CHR_AW),
          .CHR_BANK_AW(BANK_AW < CHR_AW ? BANK_AW : CHR_AW), .BUILD_ID(BUILD_ID)) u_nes (
        .clk, .uart_rx, .uart_tx, .led,
        .mem_req(req), .mem_we(we), .mem_addr(addr), .mem_wdata(wdata),
        .mem_ack(ack), .mem_rdata(rdata), .mem_rdata_w(32'h0), .mem_ready(ready), .mem_ref_hold(ref_hold), .mem_stats(stats),
        .pix_valid, .pix, .pix_x, .pix_y, .v_waiting, .v_req, .v_cap_t,
        .v_crc, .v_crc_ok, .v_crc_t, .v_shown, .v_late, .v_overrun,
        .a_valid, .a_pcm);

    nes_video u_video (
        .clk, .rst, .pix_valid, .pix, .pix_x, .pix_y, .waiting(v_waiting), .req(v_req), .a_valid, .a_pcm,
        .cap_t(v_cap_t), .crc(v_crc), .crc_ok(v_crc_ok), .crc_t(v_crc_t),
        .shown(v_shown), .late(v_late), .overrun(v_overrun),
        .pclk, .tmds0, .tmds1, .tmds2);

    mem_cache #(.AW(23), .IDX(CACHE_IDX)) u_cache (
        .clk, .rst, .req, .we, .addr, .wdata, .ack, .rdata, .rdata_w, .ready,
        .d_req(b_req), .d_we(b_we), .d_addr(b_addr), .d_wdata(b_wdata), .d_ack(b_ack), .d_rdata(b_rdata_d),
        .d_ready(b_ready), .hits(stats[31:0]), .misses(stats[63:32]), .prefetches(stats[95:64]));

    // The bridge on the system's clock, or with ASYNC on aclk, across memory/port-cdc.
    logic          x_req, x_we, x_ack, x_ready, x_clk, x_rst;
    logic [22:0]   x_addr;
    logic [7:0]    x_wdata;
    logic [63:0]   x_rdata_d;

    if (ASYNC) begin : g_async
        logic arst;
        por u_apor (.clk(aclk), .rst(arst));

        mem_port_cdc #(.AW(23), .DW(64)) u_cdc (
            .clk, .rst, .req(b_req), .we(b_we), .addr(b_addr), .wdata(b_wdata), .ack(b_ack), .rdata(b_rdata_d),
            .ready(b_ready),
            .mclk(aclk), .mrst(arst), .m_req(x_req), .m_we(x_we), .m_addr(x_addr), .m_wdata(x_wdata),
            .m_ack(x_ack), .m_rdata(x_rdata_d), .m_ready(x_ready));

        assign x_clk = aclk;
        assign x_rst = arst;
    end else begin : g_sync
        assign {x_req, x_we, x_addr, x_wdata} = {b_req, b_we, b_addr, b_wdata};
        assign {b_ack, b_rdata_d, b_ready}     = {x_ack, x_rdata_d, x_ready};
        assign x_clk = clk;
        assign x_rst = rst;
        /* verilator lint_off UNUSEDSIGNAL */
        wire unused_aclk = aclk;
        /* verilator lint_on UNUSEDSIGNAL */
    end

    axi_bridge #(.AW(23), .BASE(BASE)) u_mem (
        .clk(x_clk), .rst(x_rst), .req(x_req), .we(x_we), .addr(x_addr), .wdata(x_wdata), .ack(x_ack),
        .rdata(b_rdata), .rdata_w(b_rdata_w), .rdata_d(x_rdata_d), .ready(x_ready), .axi_ready,
        .m_araddr, .m_arvalid, .m_arready, .m_arlen, .m_arsize, .m_arburst, .m_arcache, .m_arid,
        .m_rdata, .m_rvalid, .m_rready, .m_rresp, .m_rlast,
        .m_awaddr, .m_awvalid, .m_awready, .m_awlen, .m_awsize, .m_awburst, .m_awcache, .m_awid,
        .m_wdata, .m_wstrb, .m_wlast, .m_wid, .m_wvalid, .m_wready,
        .m_bresp, .m_bvalid, .m_bready);
endmodule
