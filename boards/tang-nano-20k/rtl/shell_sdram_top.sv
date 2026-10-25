// SPDX-License-Identifier: Apache-2.0
// systems/shell-sdram on the Tang Nano 20K. The GW2AR-18's SDRAM is inside the
// package, on ports the toolchain recognises by name, so they need no
// constraints. Its clock is the inverse of clk: the chip samples each command
// half a cycle after the controller registers it (see memory/sdram).
module shell_sdram_top #(
    parameter int          CLKS_PER_BIT = 18,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic        clk,
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
    inout  wire  [31:0] IO_sdram_dq
);
    logic [31:0] dq_o;
    logic        dq_oe;

    shell_sdram #(.CLKS_PER_BIT(CLKS_PER_BIT), .FREQ_MHZ(27), .BUILD_ID(BUILD_ID)) u_sys (
        .clk, .uart_rx, .uart_tx, .led,
        .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
        .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n), .sd_ba(O_sdram_ba),
        .sd_addr(O_sdram_addr), .sd_dqm(O_sdram_dqm),
        .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(IO_sdram_dq));

    assign O_sdram_clk = ~clk;
    assign IO_sdram_dq = dq_oe ? dq_o : 'z;
endmodule
