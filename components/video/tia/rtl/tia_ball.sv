// SPDX-License-Identifier: Apache-2.0
// The TIA's ball, as Stella 7.0 runs it.
//
// A position counter runs 0-159, one step per tick; the ball starts when it decodes 156, and shows 4
// ticks later for 1, 2, 4 or 8 ticks (CTRLPF bits 5-4). RESBL starts it too, wherever it is. `on` is
// this colour clock's pixel, from the state before its tick. Writes land on the edge after their
// colour clock: `tick` first, then CTRLPF and RESBL, then ENABL and the vertical-delay shuffle (GRP1
// landing) as the TIA hands them over a clock late. With VDELBL the ball shows the enable from before
// the last shuffle.
//
// HMOVE: the TIA gives extra ticks (`tick` without `regular`) in horizontal blank, and `mstep` on each
// of its movement steps, when the ball notes its counter. While the ball is still moving (`moving`), a
// start on a regular tick takes its width from how far the counter has come since that step, mod 4
// (Stella's "starfield").

module tia_ball (
    input  logic       clk,
    input  logic       rst,
    input  logic       cc,
    input  logic       tick,
    input  logic       regular,    // the tick is a pixel's, not HMOVE's
    input  logic       moving,     // HMOVE is still moving the ball
    input  logic       mstep,      // an HMOVE movement step this colour clock

    input  logic       w_ctrlpf,
    input  logic [1:0] size,       // CTRLPF bits 5-4: width 1 << size
    input  logic       w_resbl,
    input  logic [7:0] resp_count, // 157 in the picture, 159 in blank, 158 late in an HMOVE blank
    input  logic       w_vdel,
    input  logic       vdel,
    input  logic       w_enabl,    // ENABL lands
    input  logic       enabl,
    input  logic       w_shuffle,  // GRP1 landed: the old enable takes the new

    output logic       on,

    // Save state: one word, written while `cc` is low.
    input  logic        st_we,
    input  logic [31:0] st_wdata,
    output logic [31:0] st_word
);

    // ---- State ----
    logic [7:0]        counter;
    logic              rendering;
    logic signed [4:0] render;     // -4 to 8
    logic [1:0]        sz;
    logic              en_new, en_old, vdl;
    logic [3:0]        ew;         // the width while moving: 0, 1, 2, 4 or 8
    logic [1:0]        last;       // the counter at the last movement step, mod 4

    wire signed [4:0] width = 5'sd1 <<< sz;

    assign on = rendering && render >= 5'sd0 && (vdl ? en_old : en_new);

    always_ff @(posedge clk) begin
        if (rst) begin
            counter   <= 8'd0;
            rendering <= 1'b0;
            render    <= 5'sd0;
            sz        <= 2'd0;
            en_new    <= 1'b0;
            en_old    <= 1'b0;
            vdl       <= 1'b0;
            ew        <= 4'd1;
            last      <= 2'd0;
        end else if (cc) begin
            logic [7:0]        c;
            logic              r;
            logic signed [4:0] rc;
            logic [3:0]        e;
            logic [1:0]        l, delta;
            logic              star;
            delta = 2'd0;
            c = counter; r = rendering; rc = render; e = ew; l = last;
            star = moving && regular;
            if (mstep) l = c[1:0];

            // The tick, at the width before any CTRLPF write.
            if (tick) begin
                if (c == 8'd156) begin
                    r     = 1'b1;
                    rc    = -5'sd4;
                    delta = 2'd0 - l;  // (156 - l) mod 4
                    if (star && delta == 2'd3 && !sz[1]) rc = rc + 5'sd1;
                    case (delta)
                        2'd3:    e = sz == 2'd0 ? 4'd2 : 4'(width);
                        2'd2:    e = 4'd0;
                        default: e = 4'(width);
                    endcase
                end else if (r) begin
                    rc = rc + 5'sd1;
                    if (rc >= (star ? $signed({1'b0, e}) : width)) r = 1'b0;
                end
                c = c == 8'd159 ? 8'd0 : c + 8'd1;
            end

            if (w_resbl) begin
                c  = resp_count;
                r  = 1'b1;
                rc = -5'sd4 + 5'(resp_count - 8'd157);
            end

            counter   <= c;
            rendering <= r;
            render    <= rc;
            ew        <= e;
            last      <= l;
            if (w_ctrlpf) sz <= size;
            if (w_vdel) vdl <= vdel;
            if (w_enabl) en_new <= enabl;
            if (w_shuffle) en_old <= en_new;  // never on the clock ENABL lands
        end else if (st_we) begin
            {last, ew, vdl, en_old, en_new, sz, render, rendering, counter} <= st_wdata[24:0];
        end
    end

    assign st_word = {7'd0, last, ew, vdl, en_old, en_new, sz, render, rendering, counter};
    wire [6:0]  unused_st = st_wdata[31:25];

endmodule
