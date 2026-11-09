// SPDX-License-Identifier: Apache-2.0
// The TIA's ball, as Stella 7.0 runs it.
//
// A position counter runs 0-159, one step per tick; the ball starts when it decodes 156, and shows 4
// ticks later for 1, 2, 4 or 8 ticks (CTRLPF bits 5-4). RESBL starts it too, wherever it is. `on` is
// this colour clock's pixel, from the state before its tick. Writes land on the edge after their
// colour clock: `tick` first, then CTRLPF and RESBL, then ENABL and the vertical-delay shuffle (GRP1
// landing) as the TIA hands them over a clock late. With VDELBL the ball shows the enable from before
// the last shuffle.

module tia_ball (
    input  logic       clk,
    input  logic       rst,
    input  logic       cc,
    input  logic       tick,

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
        end else if (cc) begin
            logic [7:0]        c;
            logic              r;
            logic signed [4:0] rc;
            c = counter; r = rendering; rc = render;

            // The tick, at the width before any CTRLPF write.
            if (tick) begin
                if (c == 8'd156) begin
                    r  = 1'b1;
                    rc = -5'sd4;
                end else if (r) begin
                    rc = rc + 5'sd1;
                    if (rc >= width) r = 1'b0;
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
            if (w_ctrlpf) sz <= size;
            if (w_vdel) vdl <= vdel;
            if (w_enabl) en_new <= enabl;
            if (w_shuffle) en_old <= en_new;  // never on the clock ENABL lands
        end else if (st_we) begin
            {vdl, en_old, en_new, sz, render, rendering, counter} <= st_wdata[18:0];
        end
    end

    assign st_word = {13'd0, vdl, en_old, en_new, sz, render, rendering, counter};
    wire [12:0] unused_st = st_wdata[31:19];

endmodule
