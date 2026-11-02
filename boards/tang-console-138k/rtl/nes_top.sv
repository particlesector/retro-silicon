// SPDX-License-Identifier: Apache-2.0
// systems/nes on the Tang Console 138K, built with Gowin EDA (build.sh), with
// its memory in block RAM (nes_bram: the board's DDR3 needs a controller) and
// its picture on the HDMI connector at 720p.
//
// Clocks: the GW5A's PLL runs its VCO at 1487.5 MHz from the 50 MHz
// oscillator (x29.75, its multiplier taking eighths) and divides it to
// 371.875 MHz for the serializers (/4) and 37.1875 MHz for the system (/40),
// held off by DCE (the GW5A's DQCE) until the PLL locks; CLKDIV makes the
// 74.375 MHz pixel clock (371.875 / 5), in phase with the serializers. The
// HDMI clocks are 0.17% above the 20K's (371.25, 74.25), well inside HDMI's
// tolerance (50 x 29.7 would give the 20K's, but the multiplier only takes
// eighths), and the system clock is half the pixel clock, as on the PYNQ-Z2:
// a UART bit is 25 clocks (1.4875 Mbaud) and the PPU's dot rate 35/242 of the
// clock, so the NES keeps pace with its display as on the PYNQ-Z2. Gowin EDA
// places the NES at about 41 MHz here, short of the 20K's 46.4.
module nes_top #(
    parameter int          CLKS_PER_BIT = 25,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,  // 50 MHz
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);
    logic fclk, sclk_u, lock, sclk, pclk;
    /* verilator lint_off UNUSEDSIGNAL */
    logic co1, co3, co4, co5, co6, cfb;
    logic [5:0] led;
    /* verilator lint_on UNUSEDSIGNAL */

    PLL #(
        .FCLKIN("50"), .IDIV_SEL(1), .FBDIV_SEL(1), .MDIV_SEL(29), .MDIV_FRAC_SEL(6),
        .ODIV0_SEL(4), .ODIV2_SEL(40),
        .CLKOUT0_EN("TRUE"), .CLKOUT2_EN("TRUE"), .CLKFB_SEL("INTERNAL")
    ) u_pll (
        .CLKIN(clk), .CLKFB(1'b0), .RESET(1'b0), .PLLPWD(1'b0), .RESET_I(1'b0), .RESET_O(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .MDSEL(7'b0), .MDSEL_FRAC(3'b0), .ODSEL0(7'b0), .ODSEL0_FRAC(3'b0),
        .ODSEL1(7'b0), .ODSEL2(7'b0), .ODSEL3(7'b0), .ODSEL4(7'b0), .ODSEL5(7'b0), .ODSEL6(7'b0),
        .ENCLK0(1'b1), .ENCLK1(1'b1), .ENCLK2(1'b1), .ENCLK3(1'b1), .ENCLK4(1'b1), .ENCLK5(1'b1), .ENCLK6(1'b1),
        .LOCK(lock), .CLKOUT0(fclk), .CLKOUT1(co1), .CLKOUT2(sclk_u), .CLKOUT3(co3), .CLKOUT4(co4),
        .CLKOUT5(co5), .CLKOUT6(co6), .CLKFBOUT(cfb));
    DCE u_gate (.CLKIN(sclk_u), .CE(lock), .CLKOUT(sclk));
    CLKDIV #(.DIV_MODE("5")) u_div (.HCLKIN(fclk), .RESETN(lock), .CALIB(1'b0), .CLKOUT(pclk));

    logic [9:0] tmds0, tmds1, tmds2;

    nes_bram #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(371_875), .DOT_NUM(35), .DOT_DEN(242), .CHR_AW(17),
               .PACE(1'b1), .BUILD_ID(BUILD_ID)) u_sys (
        .clk(sclk), .uart_rx, .uart_tx, .led,
        .pclk, .tmds0, .tmds1, .tmds2);

    tmds_phy u_phy (
        .pclk, .fclk, .rst(!lock), .tmds0, .tmds1, .tmds2,
        .tmds_clk_p, .tmds_clk_n, .tmds_d_p, .tmds_d_n);
endmodule
