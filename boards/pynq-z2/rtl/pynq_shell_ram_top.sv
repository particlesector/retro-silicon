// SPDX-License-Identifier: Apache-2.0
// systems/shell-ram on the PYNQ-Z2, at 125 MHz. LEDs (active high): ld0 a
// corrupt command frame was seen, ld1 a stalled one (both sticky until
// reload), ld3 heartbeat.
module pynq_shell_ram_top #(
    parameter int          CLKS_PER_BIT = 83,  // 125 MHz / 83 = 1.506 Mbaud
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [3:0] led
);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] sys_led;  // 4-2 are always off
    /* verilator lint_on UNUSEDSIGNAL */

    shell_ram #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(1_250_000), .BUILD_ID(BUILD_ID)) u_sys (
        .clk, .uart_rx, .uart_tx, .led(sys_led));

    assign led = ~{sys_led[5], 1'b1, sys_led[1:0]};
endmodule
