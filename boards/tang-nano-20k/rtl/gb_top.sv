// SPDX-License-Identifier: Apache-2.0
// systems/game-boy on the Tang Nano 20K, under the test shell, its cartridge's ROM in the SDRAM
// (gb_sdram: up to 8 MB, all of it) and 32 KB of its RAM in block RAM, with its picture and sound
// on the HDMI connector at 720p (gb_video).
//
// Clocks, as nes_top's: one rPLL makes 371.25 MHz from the 27 MHz oscillator (x55/4), the
// serializers' clock; its divided output, 371.25 / 8 = 46.40625 MHz, is the system's clock, held
// off by DQCE until the PLL locks; CLKDIV makes the 74.25 MHz pixel clock (371.25 / 5). At
// 46.40625 MHz a UART bit is 31 clocks (1.497 Mbaud, 0.2% slow of the host's 1.5), and a T-cycle
// 7/76 of the clock, 4.27426 MHz, 1.91% faster than the console's 4.194304: keeping pace with the
// display, the Game Boy waits at each frame's end, and a frame of 70,224 T-cycles takes 98.6% of a
// 60 Hz display frame (at the console's rate it would take 100.5% and miss every request).
//
// The SDRAM is wired as nes_top's: the chip inside the package, on ports the toolchain recognises by
// name, its clock the inverse of the system's, inverted from the PLL's output (not DQCE's, which
// leaves the chip dead with the open flow).
module gb_top #(
    parameter int          CLKS_PER_BIT = 31,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,  // 27 MHz
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [5:0] led,

    output logic        O_sdram_clk,
    output logic        O_sdram_cke,
    output logic        O_sdram_cs_n,
    output logic        O_sdram_cas_n,
    output logic        O_sdram_ras_n,
    output logic        O_sdram_wen_n,
    output logic [3:0]  O_sdram_dqm,
    output logic [10:0] O_sdram_addr,
    output logic [1:0]  O_sdram_ba,
    inout  wire  [31:0] IO_sdram_dq,

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

    logic [9:0]  tmds0, tmds1, tmds2;
    logic [31:0] dq_o;
    logic        dq_oe;

    gb_sdram #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(464_063), .T_NUM(7), .T_DEN(76), .VIDEO(1'b1),
               .FREQ_MHZ(47), .BUILD_ID(BUILD_ID)) u_sys (
        .clk(sclk), .uart_rx, .uart_tx, .led,
        .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
        .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n), .sd_ba(O_sdram_ba),
        .sd_addr(O_sdram_addr), .sd_dqm(O_sdram_dqm),
        .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(IO_sdram_dq),
        .pclk, .tmds0, .tmds1, .tmds2);

    assign O_sdram_clk = ~clkd;
    assign IO_sdram_dq = dq_oe ? dq_o : 'z;

    tmds_phy #(.TRUE_LVDS(1'b1)) u_phy (
        .pclk, .fclk, .rst(!lock), .tmds0, .tmds1, .tmds2,
        .tmds_clk_p, .tmds_clk_n, .tmds_d_p, .tmds_d_n);
endmodule
