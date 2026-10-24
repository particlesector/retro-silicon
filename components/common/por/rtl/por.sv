// SPDX-License-Identifier: Apache-2.0
// Power-on reset: holds `rst` high for CYCLES clocks after configuration.
// The one place that relies on a register's initial value, which FPGAs load at
// configuration; everything else resets from `rst`.
module por #(
    parameter int CYCLES = 16
) (
    input  logic clk,
    output logic rst
);
    localparam int CW = $clog2(CYCLES + 1);

    /* verilator lint_off PROCASSINIT */
    logic [CW-1:0] count = '0;
    /* verilator lint_on PROCASSINIT */

    assign rst = count != CW'(CYCLES);

    always_ff @(posedge clk)
        if (rst)
            count <= count + 1'b1;
endmodule
