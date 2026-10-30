// SPDX-License-Identifier: Apache-2.0
// Takes an unsigned audio level at one rate (one sample per `ce`) to signed
// PCM at a lower one: each output sample is the average of the inputs since
// the last (a box filter, the inputs being held levels), taken every DEN/NUM
// inputs on average, then a one-pole DC-blocking high-pass at the output
// rate. Integer arithmetic throughout, so the output depends only on the
// inputs: the same in the sim and on any board.
//
// Decimation: an accumulator adds NUM each input and takes a sample when it
// reaches DEN, so DEN/NUM rounded down or up inputs make each sample. Their
// sum times 2^16 / count, rounded down (a multiplier), is the average. High-pass:
// y = v - v' + y' - y' / 2^HPF, its corner near fs_out / (2 pi 2^HPF), with v
// the average halved. The output is y saturated to 16 bits signed: a
// full-scale step reaches +-32767.
module resampler #(
    parameter int NUM = 1600,   // output samples per DEN inputs
    parameter int DEN = 59561,
    parameter int HPF = 9,
    parameter bit SAVE_STATE = 1'b1  // 0 leaves out the save-state port's logic: writes do nothing, reads give 0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,     // an input sample
    input  logic [15:0] in,     // unsigned
    output logic        valid,  // a one-clock pulse, three clocks after the ce that makes a sample
    output logic        busy,   // a sample is between that ce and its valid: don't save state yet
    output logic signed [15:0] out,    // the latest sample
    // Save state: 4 words
    input  logic [1:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    localparam int LO   = DEN / NUM;                 // inputs a sample: LO or LO + 1
    localparam int R_LO = 65536 / LO;                // 2^16 / count, rounded down so a
    localparam int R_HI = 65536 / (LO + 1);          //   full-scale average stays under 2^16

    logic [21:0]        sum;      // the inputs since the last sample
    logic [5:0]         n;        // how many
    logic [15:0]        acc;
    logic [14:0]        v_prev;
    logic signed [31:0] y;        // 17.15 signed

    always_comb
        case (SAVE_STATE ? st_addr : 2'd3)
            2'd0:    st_rdata = {n, 4'b0, sum};
            2'd1:    st_rdata = {1'b0, v_prev, acc};
            2'd2:    st_rdata = y;
            default: st_rdata = '0;
        endcase

    wire        [21:0] s    = sum + 22'(in);
    wire        [5:0]  c    = n + 1'b1;
    wire        [16:0] a    = 17'(acc) + 17'(NUM);
    wire               take = a >= 17'(DEN);
    // A sample in three steps, a clock each, as the multiply and the
    // high-pass are the longest paths: the sum and its count, then the
    // average, then the high-pass. Samples come many clocks apart.
    logic [21:0] s_t;
    logic        hi_t, go1, go2;
    logic [14:0] v;              // the average, halved
    // y is v less a weighted average of earlier v, all under 2^15, so
    // |y| < 2^16 (2^31 in 17.15) and ny fits.
    wire signed [31:0] ny    = ($signed({17'b0, v}) - $signed({17'b0, v_prev})) * 32'sd32768
                               + y - (y >>> HPF);

    assign busy = go1 || go2;
    wire signed [16:0] whole = y[31:15];

    assign out = whole > 17'sd32767 ? 16'sh7FFF : whole < -17'sd32768 ? -16'sh8000 : whole[15:0];

    always_ff @(posedge clk) begin
        valid <= 1'b0;
        go1   <= 1'b0;
        go2   <= go1;
        if (go1)
            v <= 15'((39'(s_t) * 39'(hi_t ? R_HI : R_LO)) >> 17);
        if (go2) begin
            v_prev <= v;
            y      <= ny;
            valid  <= 1'b1;
        end
        if (rst) begin
            go2    <= 1'b0;
            sum    <= '0;
            n      <= '0;
            acc    <= '0;
            v_prev <= '0;
            y      <= '0;
        end else if (SAVE_STATE && st_we)
            case (st_addr)
                2'd0:    {n, sum} <= {st_wdata[31:26], st_wdata[21:0]};
                2'd1:    {v_prev, acc} <= st_wdata[30:0];
                2'd2:    y <= st_wdata;
                default: ;
            endcase
        else if (ce) begin
            acc <= take ? 16'(a - 17'(DEN)) : 16'(a);
            if (take) begin
                sum  <= '0;
                n    <= '0;
                s_t  <= s;
                hi_t <= c != 6'(LO);
                go1  <= 1'b1;
            end else begin
                sum <= s;
                n   <= c;
            end
        end
    end

    initial
        if (DEN >= 65536 || NUM >= DEN || DEN / NUM > 60)
            $error("resampler: needs NUM < DEN < 65536 and DEN / NUM <= 60");
endmodule
