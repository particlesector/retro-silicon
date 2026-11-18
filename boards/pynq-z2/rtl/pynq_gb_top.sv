// SPDX-License-Identifier: Apache-2.0
// systems/game-boy on the PYNQ-Z2, built with openXC7, under the test shell, its cartridge's ROM in
// the board's DDR3 (gb_axi, through the Zynq's HP0 port, from 0x10000000, behind a read cache; up
// to 8 MB, all of it) and 32 KB of its RAM in block RAM, with its picture and sound on the HDMI OUT
// connector at 720p (gb_video). As for the NES, the DDR must be set up first, over JTAG
// (boards/xilinx/zynq7/ps7_ddr3.py); until HP0 is out of reset the system waits, and HP0 and the
// AXI bridge run on the 74.25 MHz pixel clock, across memory/port-cdc from the system's 37.125.
//
// Clocks, as pynq_nes_top's: a PLL makes 82.5 MHz from the 125 MHz clock, and from it an MMCM
// makes 371.25 MHz for the serializers, 74.25 MHz for the pixels and 37.125 MHz for the system,
// held off by BUFGCE until the MMCM locks. A UART bit is 25 clocks (1.485 Mbaud). A T-cycle is
// 35/304 of the system clock, 4.27426 MHz: the system clock is half the pixel clock, as on the Tang
// Console 138K, so this is the Tang Nano 20K's ratio to the pixel clock (and its very rate), and the
// Game Boy keeps pace with its display as there, a frame of 70,224 T-cycles taking 98.6% of a
// display frame.
//
// LEDs (active high): ld0 a corrupt command frame was seen, ld1 a stalled one, ld2 running, ld3
// heartbeat.
module pynq_gb_top #(
    parameter int          CLKS_PER_BIT = 25,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,  // 125 MHz
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [3:0] led,

    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);
    logic c825_fb, c82_u, c82, plock;
    /* verilator lint_off UNUSEDSIGNAL */
    logic pll_o1, pll_o2, pll_o3, pll_o4, pll_o5;
    logic mm_o0b, mm_o1b, mm_o2b, mm_o3, mm_o3b, mm_o4, mm_o5, mm_o6, mm_fbb;
    /* verilator lint_on UNUSEDSIGNAL */

    PLLE2_BASE #(
        .CLKIN1_PERIOD(8.0), .DIVCLK_DIVIDE(5), .CLKFBOUT_MULT(33), .CLKOUT0_DIVIDE(10)
    ) u_pll (
        .CLKIN1(clk), .CLKFBIN(c825_fb), .CLKFBOUT(c825_fb), .RST(1'b0), .PWRDWN(1'b0),
        .CLKOUT0(c82_u), .CLKOUT1(pll_o1), .CLKOUT2(pll_o2), .CLKOUT3(pll_o3), .CLKOUT4(pll_o4),
        .CLKOUT5(pll_o5), .LOCKED(plock));

    BUFG u_b82 (.I(c82_u), .O(c82));

    logic mm_fb, fclk_u, pclk_u, sclk_u, mlock, fclk, pclk, sclk;

    MMCME2_BASE #(
        .CLKIN1_PERIOD(12.121), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(9.0),
        .CLKOUT0_DIVIDE_F(2.0), .CLKOUT1_DIVIDE(10), .CLKOUT2_DIVIDE(20)
    ) u_mmcm (
        .CLKIN1(c82), .CLKFBIN(mm_fb), .CLKFBOUT(mm_fb), .CLKFBOUTB(mm_fbb), .RST(!plock), .PWRDWN(1'b0),
        .CLKOUT0(fclk_u), .CLKOUT0B(mm_o0b), .CLKOUT1(pclk_u), .CLKOUT1B(mm_o1b),
        .CLKOUT2(sclk_u), .CLKOUT2B(mm_o2b), .CLKOUT3(mm_o3), .CLKOUT3B(mm_o3b),
        .CLKOUT4(mm_o4), .CLKOUT5(mm_o5), .CLKOUT6(mm_o6), .LOCKED(mlock));

    BUFG   u_bf (.I(fclk_u), .O(fclk));
    BUFG   u_bp (.I(pclk_u), .O(pclk));
    BUFGCE u_bs (.I(sclk_u), .CE(mlock), .O(sclk));

    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] sys_led;  // 4 (stopped at a limit) and 2 (unused) aren't shown
    /* verilator lint_on UNUSEDSIGNAL */
    logic [9:0] tmds0, tmds1, tmds2;

    logic        aresetn;
    logic [31:0] araddr, awaddr;
    logic        arvalid, arready, rvalid, rready, rlast, awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    logic [3:0]  arlen, awlen, arcache, awcache;
    logic [2:0]  arsize, awsize;
    logic [1:0]  arburst, awburst, rresp, bresp;
    logic [5:0]  arid, awid, wid;
    logic [63:0] rdata, wdata;
    logic [7:0]  wstrb;

    gb_axi #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(371_250), .T_NUM(35), .T_DEN(304), .VIDEO(1'b1),
             .BASE(32'h1000_0000), .ASYNC(1'b1), .BUILD_ID(BUILD_ID)) u_sys (
        .clk(sclk), .uart_rx, .uart_tx, .led(sys_led),
        .pclk, .tmds0, .tmds1, .tmds2, .aclk(pclk), .axi_ready(aresetn),
        .m_araddr(araddr), .m_arvalid(arvalid), .m_arready(arready), .m_arlen(arlen), .m_arsize(arsize),
        .m_arburst(arburst), .m_arcache(arcache), .m_arid(arid),
        .m_rdata(rdata), .m_rvalid(rvalid), .m_rready(rready), .m_rresp(rresp), .m_rlast(rlast),
        .m_awaddr(awaddr), .m_awvalid(awvalid), .m_awready(awready), .m_awlen(awlen), .m_awsize(awsize),
        .m_awburst(awburst), .m_awcache(awcache), .m_awid(awid),
        .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wid(wid), .m_wvalid(wvalid), .m_wready(wready),
        .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready));

    ps7_hp0 u_ps (
        .aclk(pclk), .aresetn,
        .m_araddr(araddr), .m_arvalid(arvalid), .m_arready(arready), .m_arlen(arlen), .m_arsize(arsize),
        .m_arburst(arburst), .m_arcache(arcache), .m_arid(arid),
        .m_rdata(rdata), .m_rvalid(rvalid), .m_rready(rready), .m_rresp(rresp), .m_rlast(rlast),
        .m_awaddr(awaddr), .m_awvalid(awvalid), .m_awready(awready), .m_awlen(awlen), .m_awsize(awsize),
        .m_awburst(awburst), .m_awcache(awcache), .m_awid(awid),
        .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wid(wid), .m_wvalid(wvalid), .m_wready(wready),
        .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready));

    tmds_phy_xc7 u_phy (
        .pclk, .fclk, .rst(!mlock), .tmds0, .tmds1, .tmds2,
        .tmds_clk_p, .tmds_clk_n, .tmds_d_p, .tmds_d_n);

    assign led = ~{sys_led[5], sys_led[3], sys_led[1:0]};
endmodule
