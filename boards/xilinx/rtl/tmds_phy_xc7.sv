// SPDX-License-Identifier: Apache-2.0
// HDMI's physical layer on a Xilinx 7-series FPGA: each channel's 10-bit TMDS
// symbol through a master and slave OSERDESE2 (10:1, bit 0 first, at five
// times the pixel clock on both edges) to an OBUFDS, and the clock channel as
// the pixel clock, five bits high and five low. Give the outputs IOSTANDARD
// TMDS_33. fclk and pclk must come from the same MMCM or PLL, each through a
// BUFG, for the serializers' two clocks to stay in phase.
module tmds_phy_xc7 (
    input  logic       pclk,   // pixel clock
    input  logic       fclk,   // five times pclk, in phase with it
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

    // The serializers take their reset synchronously to pclk, for a few
    // clocks after the clocks are stable.
    logic [3:0] rst_q;

    always_ff @(posedge pclk or posedge rst)
        if (rst)
            rst_q <= '1;
        else
            rst_q <= {rst_q[2:0], 1'b0};

    logic [3:0] q, s1, s2;
    wire  [3:0] p, n;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0] m_ofb, m_tq, m_tfb, m_tbo, m_so1, m_so2, s_oq, s_ofb, s_tq, s_tfb, s_tbo;
    /* verilator lint_on UNUSEDSIGNAL */

    for (genvar i = 0; i < 4; i++) begin : g_ch
        OSERDESE2 #(
            .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10), .SERDES_MODE("MASTER"),
            .TRISTATE_WIDTH(1)
        ) u_master (
            .CLK(fclk), .CLKDIV(pclk), .RST(rst_q[3]), .OCE(1'b1), .TCE(1'b0), .TBYTEIN(1'b0),
            .D1(sym[i][0]), .D2(sym[i][1]), .D3(sym[i][2]), .D4(sym[i][3]),
            .D5(sym[i][4]), .D6(sym[i][5]), .D7(sym[i][6]), .D8(sym[i][7]),
            .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
            .SHIFTIN1(s1[i]), .SHIFTIN2(s2[i]), .OQ(q[i]),
            .OFB(m_ofb[i]), .TQ(m_tq[i]), .TFB(m_tfb[i]), .TBYTEOUT(m_tbo[i]),
            .SHIFTOUT1(m_so1[i]), .SHIFTOUT2(m_so2[i]));
        OSERDESE2 #(
            .DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10), .SERDES_MODE("SLAVE"),
            .TRISTATE_WIDTH(1)
        ) u_slave (
            .CLK(fclk), .CLKDIV(pclk), .RST(rst_q[3]), .OCE(1'b1), .TCE(1'b0), .TBYTEIN(1'b0),
            .D1(1'b0), .D2(1'b0), .D3(sym[i][8]), .D4(sym[i][9]),
            .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
            .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
            .SHIFTIN1(1'b0), .SHIFTIN2(1'b0), .SHIFTOUT1(s1[i]), .SHIFTOUT2(s2[i]),
            .OQ(s_oq[i]), .OFB(s_ofb[i]), .TQ(s_tq[i]), .TFB(s_tfb[i]), .TBYTEOUT(s_tbo[i]));
        OBUFDS u_buf (.I(q[i]), .O(p[i]), .OB(n[i]));
    end

    assign {tmds_clk_p, tmds_d_p} = p;
    assign {tmds_clk_n, tmds_d_n} = n;
endmodule
