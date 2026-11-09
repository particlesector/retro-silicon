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
//
// Collisions: `cv` is whether the player counts as drawn for them, kept as Stella keeps it: set from
// `on` at each tick, worked out again at the line's end (`last`), and when the graphics change (GRP,
// the shuffle, REFP, VDELP) while it draws, which also asks the TIA to check collisions on the next
// colour clock (`sched`). In horizontal blank, where nothing ticks, the TIA checks them only then and
// during HMOVE.

module tia_player (
    input  logic       clk,
    input  logic       rst,
    input  logic       cc,
    input  logic       tick,       // this colour clock moves the counter
    input  logic       last,       // this colour clock is the line's last

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
    output logic [7:0] pos,        // the position counter, for the missile's RESMP
    output logic [2:0] div_o,      // the width: 1, 2 or 4
    output logic       cv,         // drawn, for collisions
    output logic       sched,      // the graphics changed while drawing: check collisions next

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
    logic              cv_r, sched_r;

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

    // Whether the player draws, with its graphics, reflection and delay as given.
    function automatic logic drawn(input logic r, input logic signed [7:0] rc, input logic [3:0] s,
                                   input logic [2:0] d, input logic [7:0] gn, input logic [7:0] go,
                                   input logic rf, input logic vd);
        logic [7:0] g, p;
        g = vd ? go : gn;
        p = rf ? g : {g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7]};
        drawn = r && rc >= (d == 3'd1 ? 8'sd0 : 8'sd1) && s <= 4'd7 && p[s[2:0]];
    endfunction

    assign pos   = counter;
    assign div_o = div;
    assign on    = drawn(rendering, render, sample, div, gnew, gold, refl, vdl);
    assign cv    = cv_r;
    assign sched = sched_r;

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
            cv_r      <= 1'b0;
            sched_r   <= 1'b0;
        end else if (cc) begin
            logic [7:0]        c;
            logic              r;
            logic signed [7:0] rc;
            logic [3:0]        s;
            logic [2:0]        d, dp, ds, nds;
            logic signed [7:0] dc;
            logic signed [7:0] delta;
            logic              cvn, ev;
            logic [7:0]        gn2, go2;
            logic              rf2, vd2;
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

            // Collisions: the tick's, then the line's end, before this edge's writes.
            cvn = tick ? on : cv_r;
            if (last) cvn = drawn(r, rc, s, d, gnew, gold, refl, vdl);

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

            // Graphics that change while the player draws change `cv` (after this edge's writes).
            gn2 = w_grp ? grp : gnew;
            go2 = w_shuffle ? gnew : gold;
            rf2 = w_refp ? refp : refl;
            vd2 = w_vdel ? vdel : vdl;
            ev  = (w_grp && !vdl && grp != gnew) || (w_shuffle && vdl && gnew != gold) ||
                  (w_refp && refp != refl) || (w_vdel && vdel != vdl);
            sched_r <= 1'b0;
            if (ev && r && rc >= (d == 3'd1 ? 8'sd0 : 8'sd1)) begin
                cvn     = drawn(r, rc, s, d, gn2, go2, rf2, vd2);
                sched_r <= 1'b1;
            end
            cv_r <= cvn;

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
                {sched_r, cv_r, vdl, refl, rendering, gold, gnew, counter} <= st_wdata[28:0];
        end
    end

    assign st_word0 = {3'd0, dec_sel, dcc, div_pend, div, sample, render};
    assign st_word1 = {3'd0, sched_r, cv_r, vdl, refl, rendering, gold, gnew, counter};
    wire [2:0] unused_st = st_wdata[31:29];

endmodule
