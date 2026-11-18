// SPDX-License-Identifier: Apache-2.0
// systems/game-boy on the Tang Console 138K, built with Gowin EDA (build.sh), under the test shell,
// its cartridge's ROM in its SDRAM module (gb_sdram: two W9825G6KH on the SDRAM0 connector,
// RANKS=2, as the NES's; up to 8 MB, all of it), 32 KB of its RAM in block RAM, with its picture
// and sound on the HDMI connector at 720p (gb_video). Its pins are the NES's (nes.cst).
//
// Clocks, as nes_top's: the PLL makes 371.875 MHz for the serializers and 37.1875 MHz for the
// system from the 50 MHz oscillator, the system's held off by DCE until the PLL locks; CLKDIV makes
// the 74.375 MHz pixel clock. A UART bit is 25 clocks (1.4875 Mbaud). A T-cycle is 35/304 of the
// system clock, 4.28142 MHz: the 20K's ratio to the pixel clock (its 7/76 of 46.40625 MHz, against
// 74.25), so the Game Boy keeps pace with its display as on the 20K, a frame of 70,224 T-cycles
// taking 98.6% of a display frame, and the 20K's video CRCs hold.
module gb_top #(
    parameter int          CLKS_PER_BIT = 25,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,  // 50 MHz
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n,

    output logic        O_sdram_clk,
    output logic        O_sdram_cs_n,
    output logic        O_sdram_ras_n,
    output logic        O_sdram_cas_n,
    output logic        O_sdram_wen_n,
    output logic [1:0]  O_sdram_ba,
    output logic [12:0] O_sdram_addr,
    output logic [1:0]  O_sdram_dqm,
    inout  wire  [15:0] IO_sdram_dq
);
    logic fclk, sclk_u, lock, sclk, pclk;
    /* verilator lint_off UNUSEDSIGNAL */
    logic co1, co3, co4, co5, co6, cfb;
    logic [5:0] led;
    logic       cke;  // the module ties CKE high
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] dq_o;
    logic        dq_oe;

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

    // FREQ_MHZ and REFRESH_NS as the NES's (nes_top.sv has why).
    gb_sdram #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(371_875), .T_NUM(35), .T_DEN(304), .VIDEO(1'b1),
               .FREQ_MHZ(38), .DQ_W(16), .ROW_W(13), .COL_W(9), .RANKS(2), .REFRESH_NS(7_000),
               .BUILD_ID(BUILD_ID)) u_sys (
        .clk(sclk), .uart_rx, .uart_tx, .led,
        .sd_cke(cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n), .sd_cas_n(O_sdram_cas_n),
        .sd_we_n(O_sdram_wen_n), .sd_ba(O_sdram_ba), .sd_addr(O_sdram_addr), .sd_dqm(O_sdram_dqm),
        .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(IO_sdram_dq),
        .pclk, .tmds0, .tmds1, .tmds2);

    // The SDRAM's clock is the system clock's inverse (see memory/sdram).
    assign O_sdram_clk = ~sclk;
    assign IO_sdram_dq = dq_oe ? dq_o : 'z;

    tmds_phy u_phy (
        .pclk, .fclk, .rst(!lock), .tmds0, .tmds1, .tmds2,
        .tmds_clk_p, .tmds_clk_n, .tmds_d_p, .tmds_d_n);
endmodule
