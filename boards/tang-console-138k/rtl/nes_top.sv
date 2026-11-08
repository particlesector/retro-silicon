// SPDX-License-Identifier: Apache-2.0
// systems/nes on the Tang Console 138K, built with Gowin EDA (build.sh), with
// PRG ROM in its SDRAM module (nes_sdram: two W9825G6KH on the SDRAM0
// connector, RANKS=2; see README.md), 256 KB of CHR in block RAM, and its
// picture on the HDMI connector at 720p. The NES's 8 MB window is the
// module's first 8 MB. CHR stays in block RAM because CHR from the SDRAM
// (CHR_EXT) needs a 32-bit chip and 8 clocks a dot, and this one has 6.9.
//
// Clocks: the GW5A's PLL runs its VCO at 743.75 MHz from the 50 MHz
// oscillator (x14.875, its multiplier taking eighths; the VCO must be 650 to
// 1300 MHz) and divides it to 371.875 MHz for the serializers (/2) and
// 37.1875 MHz for the system (/20),
// held off by DCE (the GW5A's DQCE) until the PLL locks; CLKDIV makes the
// 74.375 MHz pixel clock (371.875 / 5), in phase with the serializers. The
// HDMI clocks are 0.17% above the 20K's (371.25, 74.25), well inside HDMI's
// tolerance (50 x 14.85 would give the 20K's, but the multiplier only takes
// eighths), and the system clock is half the pixel clock, as on the PYNQ-Z2:
// a UART bit is 25 clocks (1.4875 Mbaud) and the PPU's dot rate 35/242 of the
// clock, so the NES keeps pace with its display as on the PYNQ-Z2. Gowin EDA
// places the NES at 37.7 to 41 MHz here, short of the 20K's 46.4.
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

    // FREQ_MHZ rounds the system clock up, so the SDRAM's timings have margin;
    // but then a refresh period counted in clocks is 2% longer than
    // REFRESH_NS, and a due refresh can wait for an access, so 7,000 ns keeps
    // each under the chips' 7,812 (8192 rows in 64 ms; at 7,500 the sim's
    // model saw 7,879).
    nes_sdram #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(371_875), .FREQ_MHZ(38), .DOT_NUM(35), .DOT_DEN(242),
                .PACE(1'b1), .CHR_AW(18), .DQ_W(16), .ROW_W(13), .COL_W(9), .RANKS(2), .REFRESH_NS(7_000),
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
