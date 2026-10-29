// SPDX-License-Identifier: Apache-2.0
// Takes an unsigned audio level at one rate (one sample per `ce`) to signed
// PCM at a lower one: two one-pole low-pass filters at the input rate, a
// sample every DEN/NUM inputs on average, then a one-pole DC-blocking
// high-pass at the output rate. Integer arithmetic throughout, so the output
// depends only on the inputs: the same in the sim and on any board.
//
// Low-pass: s += (x - s) / 2^LPF, twice, each with its corner near
// fs / (2 pi 2^LPF). Decimation: an accumulator adds NUM each input and takes
// a sample when it reaches DEN. High-pass: y = v - v' + y' - y' / 2^HPF, its
// corner near fs_out / (2 pi 2^HPF), with v the low-passed level halved. The
// output is y saturated to 16 bits signed: a full-scale step reaches +-32767.
module resampler #(
    parameter int NUM = 1600,   // output samples per DEN inputs
    parameter int DEN = 59561,
    parameter int LPF = 4,
    parameter int HPF = 9
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,     // an input sample
    input  logic [15:0] in,     // unsigned
    output logic        valid,  // a one-clock pulse after the ce that makes a sample
    output logic signed [15:0] out,    // the latest sample
    // Save state: 4 words
    input  logic [1:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    logic [23:0]        s1, s2;   // 16.8 unsigned
    logic [15:0]        acc;
    logic [14:0]        v_prev;
    logic signed [31:0] y;        // 17.15 signed

    always_comb
        case (st_addr)
            2'd0:    st_rdata = {8'b0, s1};
            2'd1:    st_rdata = {8'b0, s2};
            2'd2:    st_rdata = {1'b0, v_prev, acc};
            default: st_rdata = y;
        endcase

    wire signed [25:0] d1   = $signed({2'b0, in, 8'b0}) - $signed({2'b0, s1});
    wire        [23:0] n1   = s1 + 24'(d1 >>> LPF);
    wire signed [25:0] d2   = $signed({2'b0, n1}) - $signed({2'b0, s2});
    wire        [23:0] n2   = s2 + 24'(d2 >>> LPF);
    wire        [16:0] a    = 17'(acc) + 17'(NUM);
    wire               take = a >= 17'(DEN);
    wire        [14:0] v    = n2[23:9];
    // y is v less a weighted average of earlier v, all under 2^15, so
    // |y| < 2^16 (2^31 in 17.15) and ny fits.
    wire signed [31:0] ny    = ($signed({17'b0, v}) - $signed({17'b0, v_prev})) * 32'sd32768
                               + y - (y >>> HPF);
    wire signed [16:0] whole = y[31:15];

    assign out = whole > 17'sd32767 ? 16'sh7FFF : whole < -17'sd32768 ? -16'sh8000 : whole[15:0];

    always_ff @(posedge clk) begin
        valid <= 1'b0;
        if (rst) begin
            s1     <= '0;
            s2     <= '0;
            acc    <= '0;
            v_prev <= '0;
            y      <= '0;
        end else if (st_we)
            case (st_addr)
                2'd0:    s1 <= st_wdata[23:0];
                2'd1:    s2 <= st_wdata[23:0];
                2'd2:    {v_prev, acc} <= st_wdata[30:0];
                default: y <= st_wdata;
            endcase
        else if (ce) begin
            s1  <= n1;
            s2  <= n2;
            acc <= take ? 16'(a - 17'(DEN)) : 16'(a);
            if (take) begin
                v_prev <= v;
                y      <= ny;
                valid  <= 1'b1;
            end
        end
    end

    initial
        if (DEN >= 65536 || NUM >= DEN)
            $error("resampler: needs NUM < DEN < 65536");
endmodule
