// SPDX-License-Identifier: Apache-2.0
// One TMDS channel's encoder, as DVI 1.0 section 3.2.2 gives it: in the
// video period an 8-bit value becomes a 10-bit symbol that minimises
// transitions and keeps the running disparity (ones minus zeros sent) near
// zero; in the blanking period the two control bits become one of four
// fixed symbols, and the disparity restarts from zero. Bit 0 goes out first.
// It's two register stages, one per step of the spec's algorithm, so the
// symbol is for the inputs of two clocks before.
module tmds_encoder (
    input  logic       clk,
    input  logic       rst,
    input  logic       de,    // video period: send d
    input  logic [7:0] d,
    input  logic [1:0] c,     // blanking period: send c (channel 0 carries {vsync, hsync})
    output logic [9:0] q
);
    // Stage 1: transition-minimised q_m, by XOR or XNOR chaining.
    // XOR chaining makes bit i the parity of d[i:0]; XNOR chaining inverts
    // the odd bits of that.
    logic [3:0] n1d;
    logic       use_xnor, par;
    logic [8:0] qm;

    always_comb begin
        n1d = '0;
        for (int i = 0; i < 8; i++)
            n1d = n1d + {3'd0, d[i]};
        use_xnor = n1d > 4'd4 || (n1d == 4'd4 && !d[0]);
        par = 1'b0;
        for (int i = 0; i < 8; i++) begin
            par   = par ^ d[i];
            qm[i] = par ^ (use_xnor && i % 2 == 1);
        end
        qm[8] = !use_xnor;
    end

    logic [8:0] qm_q;
    logic       de_q;
    logic [1:0] c_q;

    always_ff @(posedge clk) begin
        qm_q <= qm;
        de_q <= !rst && de;
        c_q  <= c;
    end

    // Stage 2: invert q_m[7:0] or not, by the running disparity.
    logic [3:0]        n1q;
    logic signed [5:0] diff;  // ones minus zeros in q_m[7:0]
    logic signed [5:0] cnt;
    logic signed [5:0] cnt_next;
    logic [9:0]        q_next;

    always_comb begin
        n1q = '0;
        for (int i = 0; i < 8; i++)
            n1q = n1q + {3'd0, qm_q[i]};
        diff = $signed({1'b0, n1q, 1'b0}) - 6'sd8;  // 2*n1q - 8
        if (cnt == 6'sd0 || diff == 6'sd0) begin
            q_next   = {!qm_q[8], qm_q[8], qm_q[8] ? qm_q[7:0] : ~qm_q[7:0]};
            cnt_next = qm_q[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 6'sd0 && diff > 6'sd0) || (cnt < 6'sd0 && diff < 6'sd0)) begin
            q_next   = {1'b1, qm_q[8], ~qm_q[7:0]};
            cnt_next = cnt + (qm_q[8] ? 6'sd2 : 6'sd0) - diff;
        end else begin
            q_next   = {1'b0, qm_q[8], qm_q[7:0]};
            cnt_next = cnt - (qm_q[8] ? 6'sd0 : 6'sd2) + diff;
        end
    end

    always_ff @(posedge clk)
        if (rst) begin
            q   <= 10'b1101010100;
            cnt <= '0;
        end else if (de_q) begin
            q   <= q_next;
            cnt <= cnt_next;
        end else begin
            cnt <= '0;
            unique case (c_q)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                2'b11: q <= 10'b1010101011;
            endcase
        end
endmodule
