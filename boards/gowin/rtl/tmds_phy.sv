// SPDX-License-Identifier: Apache-2.0
// HDMI's physical layer on a Gowin FPGA: each channel's 10-bit TMDS symbol
// through an OSER10 serializer (bit 0 first, at five times the pixel clock on
// both edges) to a differential output, and the clock channel as the pixel
// clock, five bits high and five low. The outputs are emulated differential
// pairs (ELVDS_OBUF, IO_TYPE LVCMOS33D), which work in a 3.3 V bank, or with
// TRUE_LVDS true LVDS drivers (TLVDS_OBUF, LVDS25), which make their bank
// 2.5 V: only where nothing else in the bank needs 3.3 V.
module tmds_phy #(
    parameter bit TRUE_LVDS = 1'b0
) (
    input  logic       pclk,   // pixel clock
    input  logic       fclk,   // five times pclk, in phase with it (pclk is fclk / 5 by CLKDIV)
    input  logic       rst,    // asynchronous: hold while the clocks start
    input  logic [9:0] tmds0,
    input  logic [9:0] tmds1,
    input  logic [9:0] tmds2,
    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n
);
    wire [3:0][9:0] sym = {10'b0000011111, tmds2, tmds1, tmds0};
    logic [3:0] q;

    for (genvar i = 0; i < 4; i++) begin : g_ch
        OSER10 u_ser (
            .D0(sym[i][0]), .D1(sym[i][1]), .D2(sym[i][2]), .D3(sym[i][3]), .D4(sym[i][4]),
            .D5(sym[i][5]), .D6(sym[i][6]), .D7(sym[i][7]), .D8(sym[i][8]), .D9(sym[i][9]),
            .PCLK(pclk), .FCLK(fclk), .RESET(rst), .Q(q[i]));
    end

    wire [3:0] p, n;

    for (genvar i = 0; i < 4; i++) begin : g_out
        if (TRUE_LVDS) begin : g_t
            TLVDS_OBUF u_buf (.I(q[i]), .O(p[i]), .OB(n[i]));
        end else begin : g_e
            ELVDS_OBUF u_buf (.I(q[i]), .O(p[i]), .OB(n[i]));
        end
    end

    assign {tmds_clk_p, tmds_d_p} = p;
    assign {tmds_clk_n, tmds_d_n} = n;
endmodule
