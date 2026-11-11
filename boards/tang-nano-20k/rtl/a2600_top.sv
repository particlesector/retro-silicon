// SPDX-License-Identifier: Apache-2.0
// systems/atari-2600 on the Tang Nano 20K, under the test shell (a2600_sys), with its picture and
// sound on the HDMI connector at 720p (a2600_video).
//
// Clocks, as nes_top's: one rPLL makes 371.25 MHz from the 27 MHz oscillator (x55/4), the
// serializers' clock; its divided output, 371.25 / 8 = 46.40625 MHz, is the system's clock, held
// off by DQCE until the PLL locks; CLKDIV makes the 74.25 MHz pixel clock (371.25 / 5). At
// 46.40625 MHz a UART bit is 31 clocks (1.497 Mbaud, 0.2% slow of the host's 1.5), and the colour
// clock 7/89 of the clock, 3.64986 MHz, 1.96% faster than NTSC's: keeping pace with the display,
// the 2600 waits at each frame's end, and a frame of 262 lines takes 98.2% of a 60 Hz display
// frame (at NTSC's rate it would take 100.1% and miss every request).
module a2600_top #(
    parameter int          CLKS_PER_BIT = 31,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,  // 27 MHz
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [5:0] led,

    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);
    logic fclk, clkd, lock, sclk, pclk;
    /* verilator lint_off UNUSEDSIGNAL */
    logic clkp, clkd3;
    /* verilator lint_on UNUSEDSIGNAL */

    rPLL #(
        .FCLKIN("27"), .IDIV_SEL(3), .FBDIV_SEL(54), .ODIV_SEL(2),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .DYN_SDIV_SEL(8), .CLKOUTD_SRC("CLKOUT"), .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clk), .CLKFB(1'b0), .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0), .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0),
        .CLKOUT(fclk), .LOCK(lock), .CLKOUTP(clkp), .CLKOUTD(clkd), .CLKOUTD3(clkd3));

    DQCE u_gate (.CLKIN(clkd), .CE(lock), .CLKOUT(sclk));

    CLKDIV #(.DIV_MODE("5")) u_div (.HCLKIN(fclk), .RESETN(lock), .CALIB(1'b0), .CLKOUT(pclk));

    logic [9:0] tmds0, tmds1, tmds2;

    // The cartridge's ROM in 16 KB of block RAM (8 of the 46): F8, F6, E0, FE, FA, E7 and 3F up to 16 KB.
    a2600_sys #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(464_063), .CC_NUM(7), .CC_DEN(89), .VIDEO(1'b1),
                .ROM_LOG2(14), .BUILD_ID(BUILD_ID)) u_sys (
        .clk(sclk), .uart_rx, .uart_tx, .led, .pclk, .tmds0, .tmds1, .tmds2);

    tmds_phy #(.TRUE_LVDS(1'b1)) u_phy (
        .pclk, .fclk, .rst(!lock), .tmds0, .tmds1, .tmds2,
        .tmds_clk_p, .tmds_clk_n, .tmds_d_p, .tmds_d_n);
endmodule
