// SPDX-License-Identifier: Apache-2.0
// systems/nes on the Tang Nano 20K, with its memory in the SDRAM (nes_sdram)
// and its picture on the HDMI connector at 720p.
//
// Clocks: one rPLL makes 371.25 MHz from the 27 MHz oscillator (x55/4), the
// serializers' clock; its divided output, 371.25 / 8 = 46.40625 MHz, is the
// system's clock, held off by DQCE until the PLL locks, so the SDRAM's power-up
// wait counts real time. CLKDIV makes the 74.25 MHz pixel clock (371.25 / 5).
// At 46.40625 MHz a UART bit is 31 clocks (1.497 Mbaud, 0.2% slow of the
// host's 1.5) and the PPU's dot rate 14/121 of the clock, exactly NTSC's.
//
// The GW2AR-18's SDRAM is inside the package, on ports the toolchain
// recognises by name, so they need no constraints. Its clock is the inverse
// of the system's: the chip samples each command half a cycle after the
// controller registers it (see memory/sdram). It's inverted from the PLL's
// output, not from DQCE's: with the open flow, an inverted DQCE output on
// that pin leaves the SDRAM dead (every read is 0xFF), at 27 MHz as at 46.
module nes_top #(
    parameter int          CLKS_PER_BIT = 31,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic        clk,  // 27 MHz
    input  logic        uart_rx,
    output logic        uart_tx,
    output logic [5:0]  led,

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

    output logic        tmds_clk_p,
    output logic        tmds_clk_n,
    output logic [2:0]  tmds_d_p,
    output logic [2:0]  tmds_d_n
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

    logic [31:0] dq_o;
    logic        dq_oe;
    logic [9:0]  tmds0, tmds1, tmds2;

    nes_sdram #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(464_063), .FREQ_MHZ(47), .DOT_NUM(14), .DOT_DEN(121),
                .PACE(1'b1), .SAVE_STATE(1'b0), .CHR_EXT(1'b1), .BUILD_ID(BUILD_ID)) u_sys (
        .clk(sclk), .uart_rx, .uart_tx, .led,
        .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
        .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n), .sd_ba(O_sdram_ba),
        .sd_addr(O_sdram_addr), .sd_dqm(O_sdram_dqm),
        .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(IO_sdram_dq),
        .pclk, .tmds0, .tmds1, .tmds2);

    tmds_phy #(.TRUE_LVDS(1'b1)) u_phy (
        .pclk, .fclk, .rst(!lock), .tmds0, .tmds1, .tmds2,
        .tmds_clk_p, .tmds_clk_n, .tmds_d_p, .tmds_d_n);

    assign O_sdram_clk = ~clkd;
    assign IO_sdram_dq = dq_oe ? dq_o : 'z;
endmodule
