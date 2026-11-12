// SPDX-License-Identifier: Apache-2.0
// systems/atari-2600 on the Tang Console 138K, built with Gowin EDA (build.sh), under the test
// shell, with its picture and sound on the HDMI connector at 720p (a2600_video). The cartridge's
// ROM is in block RAM (a2600_sys, ROM_LOG2 19: 512 KB, the 20K's room in its SDRAM), which the
// GW5AST has plenty of, so no access waits for it.
//
// Clocks, as nes_top's: the PLL makes 371.875 MHz for the serializers and 37.1875 MHz for the
// system from the 50 MHz oscillator, the system's held off by DCE until the PLL locks; CLKDIV makes
// the 74.375 MHz pixel clock. A UART bit is 25 clocks (1.4875 Mbaud). The colour clock is 35/356 of
// the system clock, 3.65625 MHz: the 20K's ratio to the pixel clock (its 7/89 of 46.40625 MHz,
// against 74.25), so the 2600 keeps pace with its display as on the 20K, a frame of 262 lines
// taking 98.2% of a display frame.
module a2600_top #(
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
    logic        mem_req, mem_we;  // ROM_EXT's port, unused: the ROM is in block RAM
    logic [23:0] mem_addr;
    logic [7:0]  mem_wdata;
    /* verilator lint_on UNUSEDSIGNAL */

    PLL #(
        .FCLKIN("50"), .IDIV_SEL(1), .FBDIV_SEL(1), .MDIV_SEL(14), .MDIV_FRAC_SEL(7),
        .ODIV0_SEL(2), .ODIV2_SEL(20),
        .CLKOUT0_EN("TRUE"), .CLKOUT2_EN("TRUE"), .CLKFB_SEL("INTERNAL")
    ) u_pll (
        .CLKIN(clk), .CLKFB(1'b0), .RESET(1'b0), .PLLPWD(1'b0), .RESET_I(1'b0), .RESET_O(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .MDSEL(7'b0), .MDSEL_FRAC(3'b0), .ODSEL0(7'b0), .ODSEL0_FRAC(3'b0),
        .ODSEL1(7'b0), .ODSEL2(7'b0), .ODSEL3(7'b0), .ODSEL4(7'b0), .ODSEL5(7'b0), .ODSEL6(7'b0),
        .ENCLK0(1'b1), .ENCLK1(1'b1), .ENCLK2(1'b1), .ENCLK3(1'b1), .ENCLK4(1'b1), .ENCLK5(1'b1), .ENCLK6(1'b1),
        .DT0(4'b0), .DT1(4'b0), .DT2(4'b0), .DT3(4'b0), .ICPSEL(6'b0), .LPFRES(3'b0), .LPFCAP(2'b0),
        .PSSEL(3'b0), .PSDIR(1'b0), .PSPULSE(1'b0), .SSCPOL(1'b0), .SSCON(1'b0), .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0),
        .LOCK(lock), .CLKOUT0(fclk), .CLKOUT1(co1), .CLKOUT2(sclk_u), .CLKOUT3(co3), .CLKOUT4(co4),
        .CLKOUT5(co5), .CLKOUT6(co6), .CLKFBOUT(cfb));
    DCE u_gate (.CLKIN(sclk_u), .CE(lock), .CLKOUT(sclk));
    CLKDIV #(.DIV_MODE("5")) u_div (.HCLKIN(fclk), .RESETN(lock), .CALIB(1'b0), .CLKOUT(pclk));

    logic [9:0] tmds0, tmds1, tmds2;

    a2600_sys #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(371_875), .CC_NUM(35), .CC_DEN(356), .VIDEO(1'b1),
                .ROM_LOG2(19), .BUILD_ID(BUILD_ID)) u_sys (
        .clk(sclk), .uart_rx, .uart_tx, .led,
        .pclk, .tmds0, .tmds1, .tmds2,
        .mem_req, .mem_we, .mem_addr, .mem_wdata, .mem_ack(1'b0), .mem_rdata(8'h00));

    tmds_phy u_phy (
        .pclk, .fclk, .rst(!lock), .tmds0, .tmds1, .tmds2,
        .tmds_clk_p, .tmds_clk_n, .tmds_d_p, .tmds_d_n);
endmodule
