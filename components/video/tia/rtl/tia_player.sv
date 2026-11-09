// SPDX-License-Identifier: Apache-2.0
// One of the TIA's two players, as Stella 7.0 runs it (including Andrew Towers' notes on NUSIZ and
// RESP during a draw, as Stella models them).
//
// A position counter runs 0-159, one step per tick (each pixel, and HMOVE's extra clocks). A copy starts
// when it decodes 156, and for NUSIZ's extra copies 12, 28 or 60; the graphics follow 5 ticks later,
// one bit a tick, or every 2 or 4 ticks when stretched (NUSIZ 5, 7). `on` is this colour clock's pixel,
// from the state before its tick. Writes land on the edge after their colour clock: `tick` first, then
// the immediate ones (NUSIZ, RESP, VDELP), then the delayed ones the TIA hands over as they land (GRP,
// the vertical-delay shuffle, REFP).

module tia_player (
    input  logic       clk,
    input  logic       rst,
    input  logic       cc,
    input  logic       tick,       // this colour clock moves the counter

    input  logic       w_nusiz,
    input  logic [2:0] nusiz,
    input  logic       w_hblank,   // the TIA is in horizontal blank as the write lands
    input  logic       w_resp,
    input  logic [7:0] resp_count, // 157 in the picture, 159 in blank, 158 late in an HMOVE blank
    input  logic       w_vdel,
    input  logic       vdel,
    input  logic       w_grp,      // GRP lands
    input  logic [7:0] grp,
    input  logic       w_shuffle,  // the other player's GRP landed: the old graphics take the new
    input  logic       w_refp,
    input  logic       refp,

    output logic       on,

    // Save state: two words, written while `cc` is low.
    input  logic        st_we,
    input  logic        st_addr,
    input  logic [31:0] st_wdata,
    output logic [31:0] st_word0,
    output logic [31:0] st_word1
);

    // ---- State ----
    logic [7:0]        counter;
    logic              rendering;
    logic signed [7:0] render;
    logic [3:0]        sample;
    logic [2:0]        div;        // 1, 2 or 4
    logic [2:0]        div_pend;   // 0 until NUSIZ is first written, as in Stella
    logic signed [7:0] dcc;        // ticks until div_pend applies; -1: none
    logic [2:0]        dec_sel;    // NUSIZ's copies: its value, 5 and 7 as 0
    logic [7:0]        gnew, gold;
    logic              refl, vdl;

    function automatic logic decode(input logic [2:0] sel, input logic [7:0] c);
        case (sel)
            3'd1: decode = c == 8'd156 || c == 8'd12;
            3'd2: decode = c == 8'd156 || c == 8'd28;
            3'd3: decode = c == 8'd156 || c == 8'd12 || c == 8'd28;
            3'd4: decode = c == 8'd156 || c == 8'd60;
            3'd6: decode = c == 8'd156 || c == 8'd28 || c == 8'd60;
            default: decode = c == 8'd156;
        endcase
    endfunction

    function automatic logic [7:0] wrap160(input logic [8:0] v);  // v in 0-319
        wrap160 = v >= 9'd160 ? 8'(v - 9'd160) : v[7:0];
    endfunction

    wire  [7:0] graphics = vdl ? gold : gnew;
    wire  [7:0] pattern  = refl ? graphics : {graphics[0], graphics[1], graphics[2], graphics[3],
                                              graphics[4], graphics[5], graphics[6], graphics[7]};
    wire signed [7:0] trip = div == 3'd1 ? 8'sd0 : 8'sd1;

    assign on = rendering && render >= trip && sample <= 4'd7 && pattern[sample[2:0]];

    always_ff @(posedge clk) begin
        if (rst) begin
            counter   <= 8'd0;
            rendering <= 1'b0;
            render    <= 8'sd0;
            sample    <= 4'd0;
            div       <= 3'd1;
            div_pend  <= 3'd0;
            dcc       <= -8'sd1;
            dec_sel   <= 3'd0;
            gnew      <= 8'd0;
            gold      <= 8'd0;
            refl      <= 1'b0;
            vdl       <= 1'b0;
        end else if (cc) begin
            logic [7:0]        c;
            logic              r;
            logic signed [7:0] rc;
            logic [3:0]        s;
            logic [2:0]        d, dp, ds, nds;
            logic signed [7:0] dc;
            logic signed [7:0] delta;
            c = counter; r = rendering; rc = render; s = sample; d = div; dp = div_pend; dc = dcc;
            ds = dec_sel;

            // The tick.
            if (tick) begin
                if (decode(ds, c)) begin
                    r  = 1'b1;
                    s  = 4'd0;
                    rc = -8'sd5;
                end else if (r) begin
                    rc = rc + 8'sd1;
                    if (d == 3'd1) begin
                        if (rc > 8'sd0) s = s + 4'd1;
                        if (rc >= 8'sd0 && dc >= 8'sd0) begin
                            if (dc == 8'sd0) begin
                                d = dp;
                            end
                            dc = dc - 8'sd1;
                        end
                    end else begin
                        if (rc > 8'sd1 && (((rc - 8'sd1) & 8'(d - 3'd1)) == 8'sd0)) s = s + 4'd1;
                        if (rc > 8'sd0 && dc >= 8'sd0) begin
                            if (dc == 8'sd0) begin
                                d = dp;
                            end
                            dc = dc - 8'sd1;
                        end
                    end
                    if (s > 4'd7) r = 1'b0;
                end
                c = c == 8'd159 ? 8'd0 : c + 8'd1;
            end

            // NUSIZ.
            if (w_nusiz) begin
                nds = (nusiz == 3'd5 || nusiz == 3'd7) ? 3'd0 : nusiz;
                dp  = nusiz == 3'd5 ? 3'd2 : nusiz == 3'd7 ? 3'd4 : 3'd1;
                // A decode on the counter's last value starts a copy now.
                if (!r && decode(nds, wrap160({1'b0, c} + 9'd159))) begin
                    r  = 1'b1;
                    s  = 4'd0;
                    rc = -8'sd5;
                end
                // Changing the copies early in a copy's start can cancel it.
                if (nds != ds && r && (rc + 8'sd5) < 8'sd2 &&
                    !decode(nds, wrap160(9'(c) + 9'd159 - 9'(rc + 8'sd5))))  // rc + 5 is 0 or 1 here
                    r = 1'b0;
                ds = nds;
                if (dp != d) begin
                    delta = rc + 8'sd5;
                    if (!r)
                        d = dp;
                    else
                        case ({d, dp})
                            {3'd1, 3'd2}, {3'd1, 3'd4}:
                                if (w_hblank) begin
                                    if (delta < 8'sd4) d = dp;
                                    else dc = delta < 8'sd5 ? 8'sd1 : 8'sd0;
                                end else begin
                                    if (delta < 8'sd3) d = dp;
                                    else dc = 8'sd1;
                                end
                            {3'd2, 3'd1}, {3'd4, 3'd1}:
                                if (delta < (w_hblank ? 8'sd4 : 8'sd3))
                                    d = dp;
                                else if (delta < (w_hblank ? 8'sd6 : 8'sd5)) begin
                                    d  = dp;
                                    rc = rc - 8'sd1;
                                end else
                                    dc = w_hblank ? 8'sd0 : 8'sd1;
                            default:  // 2 to 4 or 4 to 2
                                if (rc < 8'sd1 || (w_hblank && ((rc & 8'(d - 3'd1)) == 8'sd1)))
                                    d = dp;
                                else
                                    dc = 8'(d) - ((rc - 8'sd1) & 8'(d - 3'd1));
                        endcase
                end
            end

            // RESP: during a copy's start, it shifts the copy.
            if (w_resp) begin
                c = resp_count;
                if (r && (rc + 8'sd5) < 8'sd4)
                    rc = -8'sd5 + 8'(resp_count - 8'd157);
            end

            counter   <= c;
            rendering <= r;
            render    <= rc;
            sample    <= s;
            div       <= d;
            div_pend  <= dp;
            dcc       <= dc;
            dec_sel   <= ds;

            if (w_vdel) vdl <= vdel;
            if (w_grp) gnew <= grp;
            if (w_shuffle) gold <= gnew;  // never on the clock this player's own GRP lands
            if (w_refp) refl <= refp;
        end else if (st_we) begin
            if (!st_addr)
                {dec_sel, dcc, div_pend, div, sample, render} <= st_wdata[28:0];
            else
                {vdl, refl, rendering, gold, gnew, counter} <= st_wdata[26:0];
        end
    end

    assign st_word0 = {3'd0, dec_sel, dcc, div_pend, div, sample, render};
    assign st_word1 = {5'd0, vdl, refl, rendering, gold, gnew, counter};
    wire [2:0] unused_st = st_wdata[31:29];

endmodule
