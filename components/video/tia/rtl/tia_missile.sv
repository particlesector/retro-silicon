// SPDX-License-Identifier: Apache-2.0
// One of the TIA's two missiles, as Stella 7.0 runs it.
//
// A position counter runs 0-159, one step per tick, and a copy starts when it decodes 156 (and NUSIZ's
// extra copies 12, 28 or 60, as the players'); the missile shows 4 ticks later, for 1, 2, 4 or 8 ticks
// (NUSIZ bits 5-4). `on` is this colour clock's pixel, from the state before its tick. Writes land on
// the edge after their colour clock: `tick` first, then NUSIZ, RESM, RESMP, then ENAM as the TIA hands
// it over a clock late. RESMP holds the missile hidden and unstarted; clearing it moves the missile to
// its player's position (`pl_pos`).
//
// HMOVE: the TIA gives extra ticks (`tick` without `regular`) in horizontal blank. While the missile is
// still moving (`moving`) its regular ticks draw it as the chip's merged clocks do (Stella's
// "starfield"): a copy's start can show a clock early, and its width changes by the colour clock's
// phase (`hc`, the colour clock's count in the line, mod 4).

module tia_missile (
    input  logic       clk,
    input  logic       rst,
    input  logic       cc,
    input  logic       tick,
    input  logic       regular,    // the tick is a pixel's, not HMOVE's
    input  logic       moving,     // HMOVE is still moving the missile
    input  logic [1:0] hc,

    input  logic       w_nusiz,
    input  logic [5:0] nusiz,      // NUSIZ bits 5-0 (bit 3 is the players')
    input  logic       w_hblank,   // the TIA is in horizontal blank as the write lands
    input  logic       w_resm,
    input  logic [7:0] resp_count, // 157 in the picture, 159 in blank, 158 late in an HMOVE blank
    input  logic       w_resmp,
    input  logic       resmp,
    input  logic [7:0] pl_pos,     // the player's position counter for RESMP, as the write lands
    input  logic       w_enam,     // ENAM lands
    input  logic       enam,

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
    logic [1:0]        size;       // width 1 << size
    logic [2:0]        dec_sel;    // NUSIZ's copies: its value, 5 and 7 as 0
    logic              en, locked;
    logic [3:0]        ew;         // the width while moving: 0, 1, 2, 4 or 8

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

    function automatic logic signed [4:0] width(input logic [1:0] s);
        width = 5'sd1 <<< s;
    endfunction

    assign on = rendering && en && !locked &&
                (render >= 5'sd0 ||
                 (moving && regular && render == -5'sd1 && !size[1] && hc == 2'd2));

    always_ff @(posedge clk) begin
        if (rst) begin
            counter   <= 8'd0;
            rendering <= 1'b0;
            render    <= 5'sd0;
            size      <= 2'd0;
            dec_sel   <= 3'd0;
            en        <= 1'b0;
            locked    <= 1'b0;
            ew        <= 4'd1;
        end else if (cc) begin
            logic [7:0]        c;
            logic              r;
            logic signed [4:0] rc;
            logic [1:0]        sz;
            logic [2:0]        ds;
            logic [3:0]        e;
            c = counter; r = rendering; rc = render; sz = size; ds = dec_sel; e = ew;

            // The tick.
            if (tick) begin
                if (decode(ds, c) && !locked) begin
                    r  = 1'b1;
                    rc = -5'sd4;
                end else if (r) begin
                    if (rc == -5'sd1) begin
                        if (moving && regular)
                            case (hc)
                                2'd2: begin
                                    e = sz == 2'd0 ? 4'd2 : 4'(width(sz));
                                    if (!sz[1]) rc = rc + 5'sd1;
                                end
                                2'd1:    e = 4'd0;
                                default: e = 4'(width(sz));
                            endcase
                        else
                            e = 4'(width(sz));
                    end
                    rc = rc + 5'sd1;
                    if (rc >= (moving ? $signed({1'b0, e}) : width(sz))) r = 1'b0;
                end
                c = c == 8'd159 ? 8'd0 : c + 8'd1;
            end

            // NUSIZ: a narrower missile ends now if it's already drawn that much.
            if (w_nusiz) begin
                ds = (nusiz[2:0] == 3'd5 || nusiz[2:0] == 3'd7) ? 3'd0 : nusiz[2:0];
                sz = nusiz[5:4];
                if (r && rc >= width(sz)) r = 1'b0;
            end

            // RESM: during a copy, it shifts or ends it, by the width.
            if (w_resm) begin
                c = resp_count;
                if (r) begin
                    if (rc < 5'sd0)
                        rc = -5'sd4 + 5'(resp_count - 8'd157);
                    else
                        case (sz)
                            2'd3: rc = 5'(resp_count - 8'd157) + (rc >= 5'sd4 ? 5'sd4 : 5'sd0);
                            2'd2: rc = 5'(resp_count - 8'd157);
                            2'd1: if (w_hblank) r = rc > 5'sd1;
                                  else if (rc == 5'sd0) rc = 5'sd1;
                            default: if (w_hblank) r = rc > 5'sd0;
                        endcase
                end
            end

            // RESMP: releasing it puts the missile on its player.
            if (w_resmp && resmp != locked) begin
                locked <= resmp;
                if (!resmp) c = pl_pos;
            end

            counter   <= c;
            rendering <= r;
            render    <= rc;
            size      <= sz;
            dec_sel   <= ds;
            ew        <= e;
            if (w_enam) en <= enam;
        end else if (st_we) begin
            {ew, locked, en, dec_sel, size, render, rendering, counter} <= st_wdata[24:0];
        end
    end

    assign st_word = {7'd0, ew, locked, en, dec_sel, size, render, rendering, counter};
    wire [6:0]  unused_st = st_wdata[31:25];
    wire        unused_nusiz = nusiz[3];

endmodule
