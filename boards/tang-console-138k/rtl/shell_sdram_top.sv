// SPDX-License-Identifier: Apache-2.0
// systems/shell-sdram on the Tang Console 138K with its SDRAM module: two
// W9825G6KH (16M x 16, 32 MB each) on the board's SDRAM0 connector, 64 MB in
// all. The module wires them as MiSTer's dual-chip boards do, the second
// chip's CS the first's inverted (RANKS=2 in memory/sdram), so the shell's
// address bit 25 picks the chip. On the 50 MHz oscillator, as echo and the
// shell are. The SDRAM's clock is the inverse of clk: the chips sample each
// command half a cycle after the controller registers it (see memory/sdram).
// The module ties CKE high.
module shell_sdram_top #(
    parameter int          CLKS_PER_BIT = 33,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic        clk,
    input  logic        uart_rx,
    output logic        uart_tx,

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
    logic [15:0] dq_o;
    logic        dq_oe;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0]  led;  // the board's user LEDs aren't driven yet
    logic        cke;  // the module ties CKE high
    /* verilator lint_on UNUSEDSIGNAL */

    shell_sdram #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(500_000), .FREQ_MHZ(50), .BUILD_ID(BUILD_ID),
                  .REFRESH_NS(7_500), .DQ_W(16), .ROW_W(13), .COL_W(9), .RANKS(2)) u_sys (
        .clk, .uart_rx, .uart_tx, .led,
        .sd_cke(cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n), .sd_cas_n(O_sdram_cas_n),
        .sd_we_n(O_sdram_wen_n), .sd_ba(O_sdram_ba), .sd_addr(O_sdram_addr), .sd_dqm(O_sdram_dqm),
        .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(IO_sdram_dq));

    assign O_sdram_clk = ~clk;
    assign IO_sdram_dq = dq_oe ? dq_o : 'z;
endmodule
