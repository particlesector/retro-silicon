// SPDX-License-Identifier: Apache-2.0
// systems/nes on the Tang Console 138K, at 50 MHz, with its memory in block
// RAM (nes_bram): the board's DDR3 needs a controller the open flow doesn't
// have yet. The PPU's dot rate is 189/1760 of 50 MHz, the NTSC rate exactly.
// LEDs unwired, as in echo_top.
module nes_top #(
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

    nes_bram #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(500_000), .DOT_NUM(189), .DOT_DEN(1760),
               .BUILD_ID(BUILD_ID)) u_sys (
        .clk, .uart_rx, .uart_tx, .led);
endmodule
