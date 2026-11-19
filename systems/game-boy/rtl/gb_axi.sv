// SPDX-License-Identifier: Apache-2.0
// systems/game-boy (gb_sys) with its cartridge's ROM behind an AXI slave (memory/axi-bridge), as
// nes_axi has the NES's: the ROM's 8 MB at AXI address BASE, such as a Zynq-7000's DDR3 through an
// HP port, behind a read cache (memory/cache, 2^CACHE_IDX lines of 8 bytes, fetching the next line
// after a miss), since a read through the bridge takes longer than the system can wait at each
// M-cycle without falling behind a display. With ASYNC, the bridge and the AXI port run on their
// own clock (aclk), faster than the system's, behind memory/port-cdc. The other parameters are
// gb_sys's.
module gb_axi #(
    parameter int          CLKS_PER_BIT = 18,
    parameter int          IDLE_CLKS    = 270_000,
    parameter int          T_NUM        = 65_536,
    parameter int          T_DEN        = 421_875,
    parameter bit          VIDEO        = 1'b0,
    parameter bit          CGB          = 1'b1,
    parameter int          CRAM_LOG2    = 15,
    parameter logic [31:0] BASE         = 32'h1000_0000,
    parameter int          CACHE_IDX    = 12,   // the read cache: 4096 lines, 32 KB
    parameter bit          ASYNC        = 1'b0, // the AXI port on aclk, across memory/port-cdc, not on clk
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [5:0] led,

    input  logic        pclk,   // with VIDEO: the HDMI pixel clock, 74.25 MHz
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
    logic        req, we, ack;
    logic [22:0] addr;
    logic [7:0]  wdata, rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        ready;     // the cache takes a request only when ready, and the system holds it
    logic [31:0] rdata_w, b_rdata_w;
    logic [7:0]  b_rdata;   // the cache takes whole lines (b_rdata_d)
    logic [95:0] stats;     // the cache's hits, misses and prefetches
    /* verilator lint_on UNUSEDSIGNAL */
    logic        b_req, b_we, b_ack, b_ready;
    logic [22:0] b_addr;
    logic [7:0]  b_wdata;
    logic [63:0] b_rdata_d;

    por u_por (.clk, .rst);

    gb_sys #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .T_NUM(T_NUM), .T_DEN(T_DEN), .VIDEO(VIDEO),
             .CGB(CGB), .ROM_LOG2(23), .ROM_EXT(1'b1), .CRAM_LOG2(CRAM_LOG2), .BUILD_ID(BUILD_ID)) u_sys (
        .clk, .uart_rx, .uart_tx, .led, .pclk, .tmds0, .tmds1, .tmds2,
        .mem_req(req), .mem_we(we), .mem_addr(addr), .mem_wdata(wdata), .mem_ack(ack), .mem_rdata(rdata));

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
