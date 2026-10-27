// SPDX-License-Identifier: Apache-2.0
// systems/uart-echo on the PYNQ-Z2, at 125 MHz from the Ethernet PHY's clock.
// LEDs (active high, so inverted from the system's): ld0 overflow, ld1
// framing error, ld3 heartbeat.
module pynq_echo_top #(
    parameter int CLKS_PER_BIT = 83  // 125 MHz / 83 = 1.506 Mbaud, 0.4% fast of 1.5 Mbaud
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [3:0] led
);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] sys_led;  // 4-2 are always off
    /* verilator lint_on UNUSEDSIGNAL */

    uart_echo #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_sys (.clk, .uart_rx, .uart_tx, .led(sys_led));

    assign led = ~{sys_led[5], 1'b1, sys_led[1:0]};
endmodule
