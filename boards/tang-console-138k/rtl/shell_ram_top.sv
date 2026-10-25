// SPDX-License-Identifier: Apache-2.0
// systems/shell-ram on the Tang Console 138K, at 50 MHz. LEDs unwired, as in
// echo_top.
module shell_ram_top #(
    parameter int          CLKS_PER_BIT = 33,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic clk,
    input  logic uart_rx,
    output logic uart_tx
);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] led;
    /* verilator lint_on UNUSEDSIGNAL */

    shell_ram #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(500_000), .BUILD_ID(BUILD_ID)) u_sys (
        .clk, .uart_rx, .uart_tx, .led);
endmodule
