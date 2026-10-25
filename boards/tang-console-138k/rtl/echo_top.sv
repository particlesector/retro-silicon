// SPDX-License-Identifier: Apache-2.0
// systems/uart-echo on the Tang Console 138K, at 50 MHz. Its LEDs aren't
// wired: the board's user LEDs are on configuration pins the open flow
// doesn't drive yet (see README.md).
module echo_top #(
    parameter int CLKS_PER_BIT = 33  // 50 MHz / 33 = 1.515 Mbaud, 1% fast of 1.5 Mbaud
) (
    input  logic clk,
    input  logic uart_rx,
    output logic uart_tx
);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] led;
    /* verilator lint_on UNUSEDSIGNAL */

    uart_echo #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_sys (.clk, .uart_rx, .uart_tx, .led);
endmodule
