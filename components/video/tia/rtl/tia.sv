// SPDX-License-Identifier: Apache-2.0
// Atari TIA (NTSC): the 2600's video, one colour clock per `cc`.
//
// So far: the line (228 colour clocks: 68 of horizontal blank, then 160 pixels), VSYNC, VBLANK,
// WSYNC, the background, the playfield with its colours, reflection, score mode and priority, the two
// players (`tia_player`), the two missiles (`tia_missile`), the ball (`tia_ball`), HMOVE, collisions and
// the fire buttons' input ports, and RSYNC. The paddles' ports and sound come next.
//
// Timing, as Stella 7.0 runs it:
// - Each CPU cycle is 3 colour clocks; `ce` marks the colour clock that ends one, and the cycle's access
//   (`cs`, `addr`, `we`, `din`) is taken then. A write lands after that clock, so the next colour clock
//   sees it, except those the chip delays: VBLANK, GRP0, GRP1 (with the vertical-delay shuffles),
//   REFP0, REFP1, ENAM0, ENAM1 and ENABL by 1 clock, PF0-PF2 and HMP0-HMCLR by 2, HMOVE by 6.
// - HMOVE starts a movement clock that steps every 4 colour clocks (on colour clocks 0 mod 4 in the
//   line). Each object keeps moving until the step count equals its HM value's count ((HM >> 4) ^ 8,
//   so 0-15), and gets an extra tick on each step while the TIA is in horizontal blank. An HMOVE that
//   lands in horizontal blank before colour clock 68 extends the blank by 8 colour clocks (the
//   "comb"): those pixels are colour 0, and the objects don't tick on them.
// - Collisions are checked on each picture colour clock, and in horizontal blank only on HMOVE's
//   movement steps or the colour clock after an object's graphics or enable changed, all while
//   VBLANK is off, from each object's collision state as Stella keeps it (`cv`; the playfield's ends
//   with each line). A read sees this colour clock's check; CXCLR clears them after it.
// - RSYNC sets the line's counter to 225, so the line ends 3 colour clocks later; any of those in the
//   picture draw on from the column the line had reached. A line's columns it doesn't draw are black.
// - INPT4 and INPT5 read the fire buttons' pins (0 pressed); with VBLANK bit 6 set they latch a press
//   until it's cleared. INPT0-3 read 0: no paddles yet (Stella's joystick leaves them unconnected).
// - WSYNC holds `rdy` low from the write to the line's end, so the CPU's next read cycle completes as
//   the first cycle of the next line (`cpu/6502` repeats a read cycle that ends with rdy low). A write
//   in the cycle that ends the line doesn't hold it.
// - The playfield takes a new bit every 4 pixels, and its reflection only at pixels 0 and 79.
// - VBLANK blanks the picture to colour 0.
// `pix` is each colour clock's colour value (bit 0 clear), `pix_on` whether it draws one of the 160
// pixels (`x` its column), registered: they describe the colour clock before.

module tia #(
    parameter bit SAVE_STATE = 1'b1  // 0 leaves out the save-state port's logic
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cc,      // one colour clock
    input  logic        ce,      // this colour clock ends a CPU cycle (with cc)

    input  logic        cs,
    input  logic [5:0]  addr,
    input  logic        we,
    input  logic [7:0]  din,
    output logic [7:0]  dout,    // bits 7-6; the bus keeps its last value in bits 5-0
    output logic        rdy,
    input  logic [1:0]  fire_n,  // INPT4's and INPT5's pins: player 0's and player 1's fire, 0 pressed

    output logic [7:0]  pix,
    output logic        pix_on,
    output logic [7:0]  x,
    output logic        line_end,  // the colour clock before was the line's last
    output logic        vsync,     // VSYNC's bit 1
    output logic        vblank,    // VBLANK's bit 1, as the picture sees it

    input  logic [3:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);

    localparam logic [5:0] VSYNC = 6'h00, VBLANK = 6'h01, WSYNC = 6'h02, RSYNC = 6'h03,
                           COLUP0 = 6'h06, COLUP1 = 6'h07, COLUPF = 6'h08, COLUBK = 6'h09,
                           CTRLPF = 6'h0A, PF0 = 6'h0D, PF1 = 6'h0E, PF2 = 6'h0F,
                           NUSIZ0 = 6'h04, NUSIZ1 = 6'h05, REFP0 = 6'h0B, REFP1 = 6'h0C,
                           RESP0 = 6'h10, RESP1 = 6'h11, RESM0 = 6'h12, RESM1 = 6'h13, RESBL = 6'h14,
                           GRP0 = 6'h1B, GRP1 = 6'h1C, ENAM0 = 6'h1D, ENAM1 = 6'h1E, ENABL = 6'h1F,
                           HMP0 = 6'h20, HMP1 = 6'h21, HMM0 = 6'h22, HMM1 = 6'h23, HMBL = 6'h24,
                           VDELP0 = 6'h25, VDELP1 = 6'h26, VDELBL = 6'h27, RESMP0 = 6'h28, RESMP1 = 6'h29,
                           HMOVE = 6'h2A, HMCLR = 6'h2B, CXCLR = 6'h2C;

    // ---- State ----
    logic [7:0]  hctr;                   // colour clock in the line, 0-227
    logic        wsync;                  // WSYNC is holding the CPU
    logic        vsync_r;
    logic        vblank_r;               // as the picture sees it
    logic        vblank_new;             // a VBLANK write waiting its clock
    logic        vblank_pend;
    logic [6:0]  colup0, colup1, colupf, colubk;  // colour values' bits 7-1
    logic        reflect, score, pfp;    // CTRLPF bits 0, 1, 2
    logic        reflect_l;              // the reflection as the playfield uses it
    logic [19:0] pf;                     // playfield bits, left to right: PF0 7-4, PF1 7-0, PF2 0-7 ...
    logic [19:0] pf_new;                 // a PF write waiting
    logic [1:0]  pf_cnt;                 // clocks until it lands
    logic        pf_bit;                 // the playfield bit being drawn

    // ---- This colour clock ----
    logic [7:0] rs_delta;                // after RSYNC: how far the counter jumped ahead
    logic       pf_tick;
    wire        in_pic = hctr >= 8'd68;
    wire  [7:0] xc     = hctr - 8'd68 - rs_delta;
    // The playfield steps, and a pixel is drawn, on picture colour clocks and HMOVE's comb (black);
    // not on the last 3 of a line RSYNC cut short in the blank.
    wire        last   = hctr == 8'd227;

    // The playfield's 20 bits, by column: bit n of `pf` is the playfield's nth 4-pixel pf_cell.
    wire        refl_now = (xc == 8'd0 || xc == 8'd79) ? reflect : reflect_l;
    logic [4:0] pf_cell;
    always_comb begin
        if (xc < 8'd79)
            pf_cell = xc[6:2];
        else if (refl_now)
            pf_cell = 5'(8'd39 - {2'd0, xc[7:2]});
        else
            pf_cell = 5'({2'd0, xc[7:2]} - 8'd20);
    end
    wire        pf_bit_now = (pf_tick && xc[1:0] == 2'd0) ? pf[pf_cell] : pf_bit;

    wire wr = ce && cs && we;

    // ---- Horizontal blank and HMOVE ----
    // `hblank` is the TIA's state as this colour clock starts: blank from colour clock 0 to 67, or to
    // 75 when an HMOVE has landed in blank before 68 (`ext`, which colour clock 0 clears). Objects tick
    // on every colour clock out of blank, and on HMOVE's movement steps in it.
    logic       hblank, ext;
    logic [5:0] hmove_sr;                // HMOVE writes on their way: lands as bit 5 is set
    logic [1:0] hmw_sr;                  // an HM write on its way, as hmw_sr[1] lands
    logic [2:0] hmw_sel;                 // 0-4 HMP0, HMP1, HMM0, HMM1, HMBL; 5 HMCLR
    logic [3:0] hmw_val;
    logic [3:0] hm [5];                  // each object's count: P0, P1, M0, M1, BL
    logic [4:0] moving;
    logic       mactive;                 // a movement is in progress
    logic [4:0] mclk;                    // the movement clock, 16 once past 15

    wire        regular  = !hblank;
    wire        mstep    = mactive && hctr[1:0] == 2'd0;
    wire  [3:0] mcount   = mclk[4] ? 4'd0 : mclk[3:0];
    logic [4:0] mstop, extra, moving_now;
    always_comb
        for (int i = 0; i < 5; i++) begin
            mstop[i]      = mstep && moving[i] && mcount == hm[i];
            moving_now[i] = moving[i] && !mstop[i];
            extra[i]      = mstep && moving[i] && !mstop[i] && hblank;
        end
    wire  [4:0] obj_tick = {5{regular}} | extra;
    wire        hblank_next = last ? 1'b1 : ((hctr == 8'd67 && !ext) || hctr == 8'd75) ? 1'b0 : hblank;
    assign      pf_tick     = in_pic && (!hblank || hctr < 8'd76);

    // ---- Players ----
    // Writes taken after this colour clock see the TIA as it will be for the next.
    wire  [7:0] hctr_next = last ? 8'd0 : hctr + 8'd1;
    wire        hb_next   = hblank_next;
    wire  [7:0] resp_count = !hb_next ? 8'd157 : hctr_next >= 8'd73 ? 8'd158 : 8'd159;

    // GRP and REFP land a colour clock after the write.
    logic       grp0_pend, grp1_pend, refp0_pend, refp1_pend;
    logic [7:0] grp0_new, grp1_new;
    logic       refp0_new, refp1_new;

    logic        p0_on, p1_on, p0_cv, p1_cv, p0_sched, p1_sched;
    logic [7:0]  p0_pos, p1_pos;
    logic [2:0]  p0_div, p1_div;
    logic [31:0] p0_st0, p0_st1, p1_st0, p1_st1;
    tia_player u_p0 (
        .clk, .rst, .cc, .tick(obj_tick[0]),
        .w_nusiz(wr && addr == NUSIZ0), .nusiz(din[2:0]), .w_hblank(hb_next),
        .w_resp(wr && addr == RESP0), .resp_count,
        .w_vdel(wr && addr == VDELP0), .vdel(din[0]),
        .w_grp(grp0_pend), .grp(grp0_new), .w_shuffle(grp1_pend),
        .w_refp(refp0_pend), .refp(refp0_new),
        .last, .on(p0_on), .pos(p0_pos), .div_o(p0_div), .cv(p0_cv), .sched(p0_sched),
        .st_we(SAVE_STATE && st_we && (st_addr == 4'd5 || st_addr == 4'd6)), .st_addr(st_addr == 4'd6),
        .st_wdata, .st_word0(p0_st0), .st_word1(p0_st1)
    );
    tia_player u_p1 (
        .clk, .rst, .cc, .tick(obj_tick[1]),
        .w_nusiz(wr && addr == NUSIZ1), .nusiz(din[2:0]), .w_hblank(hb_next),
        .w_resp(wr && addr == RESP1), .resp_count,
        .w_vdel(wr && addr == VDELP1), .vdel(din[0]),
        .w_grp(grp1_pend), .grp(grp1_new), .w_shuffle(grp0_pend),
        .w_refp(refp1_pend), .refp(refp1_new),
        .last, .on(p1_on), .pos(p1_pos), .div_o(p1_div), .cv(p1_cv), .sched(p1_sched),
        .st_we(SAVE_STATE && st_we && (st_addr == 4'd7 || st_addr == 4'd8)), .st_addr(st_addr == 4'd8),
        .st_wdata, .st_word0(p1_st0), .st_word1(p1_st1)
    );

    // ---- Missiles and the ball ----
    // ENAM and ENABL land a colour clock after the write. RESMP's release puts a missile where its
    // player's RESP would have: the player's counter after this clock's tick, less 5, 8 or 12 by its
    // width.
    logic       enam0_pend, enam1_pend, enabl_pend;
    logic       enam0_new, enam1_new, enabl_new;

    function automatic logic [7:0] resmp_pos(input logic t, input logic [7:0] pos, input logic [2:0] div);
        logic [7:0] p, back;
        p    = (t && pos == 8'd159) ? 8'd0 : t ? pos + 8'd1 : pos;
        back = div == 3'd4 ? 8'd12 : div == 3'd2 ? 8'd8 : 8'd5;
        resmp_pos = p >= back ? p - back : p + 8'd160 - back;
    endfunction

    logic        m0_on, m1_on, bl_on, m0_cv, m1_cv, bl_cv, m0_sched, m1_sched, bl_sched;
    logic [31:0] m0_st, m1_st, bl_st;
    tia_missile u_m0 (
        .clk, .rst, .cc, .tick(obj_tick[2]), .regular, .moving(moving_now[2]), .hc(hctr[1:0]),
        .w_nusiz(wr && addr == NUSIZ0), .nusiz(din[5:0]), .w_hblank(hb_next),
        .w_resm(wr && addr == RESM0), .resp_count,
        .w_resmp(wr && addr == RESMP0), .resmp(din[1]), .pl_pos(resmp_pos(obj_tick[0], p0_pos, p0_div)),
        .w_enam(enam0_pend), .enam(enam0_new),
        .last, .on(m0_on), .cv(m0_cv), .sched(m0_sched),
        .st_we(SAVE_STATE && st_we && st_addr == 4'd10), .st_wdata, .st_word(m0_st)
    );
    tia_missile u_m1 (
        .clk, .rst, .cc, .tick(obj_tick[3]), .regular, .moving(moving_now[3]), .hc(hctr[1:0]),
        .w_nusiz(wr && addr == NUSIZ1), .nusiz(din[5:0]), .w_hblank(hb_next),
        .w_resm(wr && addr == RESM1), .resp_count,
        .w_resmp(wr && addr == RESMP1), .resmp(din[1]), .pl_pos(resmp_pos(obj_tick[1], p1_pos, p1_div)),
        .w_enam(enam1_pend), .enam(enam1_new),
        .last, .on(m1_on), .cv(m1_cv), .sched(m1_sched),
        .st_we(SAVE_STATE && st_we && st_addr == 4'd11), .st_wdata, .st_word(m1_st)
    );
    tia_ball u_bl (
        .clk, .rst, .cc, .tick(obj_tick[4]), .regular, .moving(moving_now[4]), .mstep,
        .w_ctrlpf(wr && addr == CTRLPF), .size(din[5:4]),
        .w_resbl(wr && addr == RESBL), .resp_count,
        .w_vdel(wr && addr == VDELBL), .vdel(din[0]),
        .w_enabl(enabl_pend), .enabl(enabl_new), .w_shuffle(grp1_pend),
        .last, .on(bl_on), .cv(bl_cv), .sched(bl_sched),
        .st_we(SAVE_STATE && st_we && st_addr == 4'd12), .st_wdata, .st_word(bl_st)
    );

    // ---- Collisions ----
    // Each object's collision state after this colour clock's tick, and the 15 pairs. A check happens
    // on picture colour clocks, HMOVE's steps while something still moves, and the colour clock after
    // an object asked for one, never under VBLANK.
    logic        pf_cv;                  // the playfield's collision state
    logic [14:0] cx;                     // the latches, by pair (below)
    wire         pf_cvn = pf_tick ? pf_bit_now : pf_cv;
    wire         p0c = obj_tick[0] ? p0_on : p0_cv;
    wire         p1c = obj_tick[1] ? p1_on : p1_cv;
    wire         m0c = obj_tick[2] ? m0_on : m0_cv;
    wire         m1c = obj_tick[3] ? m1_on : m1_cv;
    wire         blc = obj_tick[4] ? bl_on : bl_cv;
    wire         cx_check = !vblank_r && (regular || (mstep && |moving_now) ||
                                          p0_sched || p1_sched || m0_sched || m1_sched || bl_sched);
    // Bits: 14 M0-P1, 13 M0-P0, 12 M1-P0, 11 M1-P1, 10 P0-PF, 9 P0-BL, 8 P1-PF, 7 P1-BL, 6 M0-PF,
    // 5 M0-BL, 4 M1-PF, 3 M1-BL, 2 BL-PF, 1 P0-P1, 0 M0-M1: CXM0P to CXPPMM's bits 7 and 6 in order.
    wire  [14:0] cx_now = {15{cx_check}} & {m0c && p1c, m0c && p0c, m1c && p0c, m1c && p1c,
                                            p0c && pf_cvn, p0c && blc, p1c && pf_cvn, p1c && blc,
                                            m0c && pf_cvn, m0c && blc, m1c && pf_cvn, m1c && blc,
                                            blc && pf_cvn, p0c && p1c, m0c && m1c};
    wire  [14:0] cx_seen = cx | cx_now;

    // ---- Input ports ----
    logic       latch_mode;              // VBLANK bit 6
    logic [1:0] latched;                 // 0: a press seen since latching began
    wire  [1:0] inpt45 = latch_mode ? latched & fire_n : fire_n;

    // ---- The colour, by priority ----
    // Each missile takes its player's colour and place, the ball the playfield's. Normally player 0,
    // player 1, the playfield and ball, then the background. Score mode (CTRLPF bit 1, priority off)
    // colours the playfield with COLUP0 on the left half and COLUP1 on the right, and puts it between
    // the players, with the ball after player 1; priority (bit 2) puts the playfield and ball first.
    wire        score_on = score && !pfp;
    wire  [6:0] pf_col   = score_on ? (xc < 8'd80 ? colup0 : colup1) : colupf;
    wire        p0m0     = p0_on || m0_on;
    wire        p1m1     = p1_on || m1_on;
    logic [6:0] col;
    always_comb begin
        if (pfp)
            col = pf_bit_now ? pf_col : bl_on ? colupf : p0m0 ? colup0 : p1m1 ? colup1 : colubk;
        else if (score_on)
            col = p0m0 ? colup0 : pf_bit_now ? pf_col : p1m1 ? colup1 : bl_on ? colupf : colubk;
        else
            col = p0m0 ? colup0 : p1m1 ? colup1 : pf_bit_now ? pf_col : bl_on ? colupf : colubk;
    end
    wire  [3:0] unused_st  = st_wdata[31:28];

    // The playfield's bits from PF0, PF1, PF2 as written.
    function automatic logic [19:0] pf_with(input logic [19:0] cur, input logic [5:0] a, input logic [7:0] v);
        logic [19:0] r;
        r = cur;
        case (a)
            PF0: r[3:0] = v[7:4];
            PF1: for (int i = 0; i < 8; i++) r[4 + i] = v[7 - i];
            default: r[19:12] = v;
        endcase
        pf_with = r;
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            hctr        <= 8'd0;
            wsync       <= 1'b0;
            vsync_r     <= 1'b0;
            vblank_r    <= 1'b0;
            vblank_new  <= 1'b0;
            vblank_pend <= 1'b0;
            colup0      <= 7'd0;
            colup1      <= 7'd0;
            colupf      <= 7'd0;
            colubk      <= 7'd0;
            reflect     <= 1'b0;
            score       <= 1'b0;
            pfp         <= 1'b0;
            reflect_l   <= 1'b0;
            pf          <= 20'd0;
            pf_new      <= 20'd0;
            pf_cnt      <= 2'd0;
            pf_bit      <= 1'b0;
            grp0_pend   <= 1'b0;
            grp1_pend   <= 1'b0;
            refp0_pend  <= 1'b0;
            refp1_pend  <= 1'b0;
            grp0_new    <= 8'd0;
            grp1_new    <= 8'd0;
            refp0_new   <= 1'b0;
            refp1_new   <= 1'b0;
            enam0_pend  <= 1'b0;
            enam1_pend  <= 1'b0;
            enabl_pend  <= 1'b0;
            enam0_new   <= 1'b0;
            enam1_new   <= 1'b0;
            enabl_new   <= 1'b0;
            hblank      <= 1'b1;
            ext         <= 1'b0;
            hmove_sr    <= 6'd0;
            hmw_sr      <= 2'd0;
            hmw_sel     <= 3'd0;
            hmw_val     <= 4'd0;
            for (int i = 0; i < 5; i++) hm[i] <= 4'd0;
            moving      <= 5'd0;
            mactive     <= 1'b0;
            mclk        <= 5'd0;
            pf_cv       <= 1'b0;
            rs_delta    <= 8'd0;
            cx          <= 15'd0;
            latch_mode  <= 1'b0;
            latched     <= 2'b00;
            pix         <= 8'd0;
            pix_on      <= 1'b0;
            x           <= 8'd0;
            line_end    <= 1'b0;
        end else if (cc) begin
            // Draw this colour clock.
            pix      <= {(in_pic && !hblank && !vblank_r) ? col : 7'd0, 1'b0};
            pix_on   <= pf_tick;
            x        <= xc;
            line_end <= last;
            if (pf_tick) begin
                pf_bit    <= pf_bit_now;
                reflect_l <= refl_now;
            end
            hctr <= last ? 8'd0 : hctr + 8'd1;
            if (last) wsync <= 1'b0;
            if (last) rs_delta <= 8'd0;

            // HMOVE: this colour clock's movement step, unless an HMOVE lands for the next, which
            // restarts the movement and, before colour clock 68, extends the blank.
            hblank   <= hblank_next;
            hmove_sr <= {hmove_sr[4:0], wr && addr == HMOVE};
            if (hmove_sr[5]) begin
                mclk    <= 5'd0;
                mactive <= 1'b1;
                moving  <= 5'b11111;
                ext     <= 1'b1;
            end else begin
                if (hctr == 8'd0) ext <= 1'b0;
                if (mstep) begin
                    moving  <= moving_now;
                    mactive <= |moving_now;
                    if (!mclk[4]) mclk <= mclk + 5'd1;
                end
            end
            hmw_sr <= {hmw_sr[0], 1'b0};
            if (hmw_sr[1]) begin
                if (hmw_sel == 3'd5)
                    for (int i = 0; i < 5; i++) hm[i] <= 4'd8;
                else
                    hm[hmw_sel] <= hmw_val;
            end

            // Collisions: this colour clock's check; the playfield's state ends with the line.
            cx    <= cx_seen;
            pf_cv <= last ? 1'b0 : pf_cvn;
            if (latch_mode) latched <= latched & fire_n;

            // Writes waiting their clock land after it.
            grp0_pend  <= 1'b0;
            grp1_pend  <= 1'b0;
            refp0_pend <= 1'b0;
            refp1_pend <= 1'b0;
            enam0_pend <= 1'b0;
            enam1_pend <= 1'b0;
            enabl_pend <= 1'b0;
            if (vblank_pend) begin
                vblank_r    <= vblank_new;
                vblank_pend <= 1'b0;
            end
            if (pf_cnt != 2'd0) begin
                if (pf_cnt == 2'd1) pf <= pf_new;
                pf_cnt <= pf_cnt - 2'd1;
            end

            // This cycle's write.
            if (wr)
                case (addr)
                    VSYNC:  vsync_r <= din[1];
                    VBLANK: begin
                        vblank_new  <= din[1];
                        vblank_pend <= 1'b1;
                        latch_mode  <= din[6];
                        if (!din[6]) latched <= 2'b11;
                    end
                    CXCLR:  cx <= 15'd0;
                    WSYNC:  if (!last) wsync <= 1'b1;
                    RSYNC:  begin hctr <= 8'd225; rs_delta <= 8'd225 - hctr_next; end
                    COLUP0: colup0 <= din[7:1];
                    COLUP1: colup1 <= din[7:1];
                    COLUPF: colupf <= din[7:1];
                    COLUBK: colubk <= din[7:1];
                    CTRLPF: {pfp, score, reflect} <= din[2:0];
                    GRP0:  begin grp0_new <= din; grp0_pend <= 1'b1; end
                    GRP1:  begin grp1_new <= din; grp1_pend <= 1'b1; end
                    REFP0: begin refp0_new <= din[3]; refp0_pend <= 1'b1; end
                    REFP1: begin refp1_new <= din[3]; refp1_pend <= 1'b1; end
                    ENAM0: begin enam0_new <= din[1]; enam0_pend <= 1'b1; end
                    ENAM1: begin enam1_new <= din[1]; enam1_pend <= 1'b1; end
                    ENABL: begin enabl_new <= din[1]; enabl_pend <= 1'b1; end
                    HMP0, HMP1, HMM0, HMM1, HMBL, HMCLR: begin
                        hmw_sr[0] <= 1'b1;
                        hmw_sel   <= addr == HMCLR ? 3'd5 : 3'(addr - HMP0);
                        hmw_val   <= din[7:4] ^ 4'd8;
                    end
                    PF0, PF1, PF2: begin
                        // A second write before the first lands replaces it.
                        pf_new <= pf_with(pf_cnt != 2'd0 ? pf_new : pf, addr, din);
                        pf_cnt <= 2'd2;
                    end
                    default: ;
                endcase
        end else if (SAVE_STATE && st_we) begin
            case (st_addr)
                4'd9: {enabl_new, enam1_new, enam0_new, enabl_pend, enam1_pend, enam0_pend, refp1_new,
                       refp0_new, grp1_new, grp0_new, refp1_pend, refp0_pend, grp1_pend,
                       grp0_pend} <= st_wdata[27:0];
                4'd0: {pf_cnt, vblank_pend, vblank_new, vblank_r, vsync_r, wsync, pf_bit, reflect_l,
                       pfp, score, reflect, hctr} <= st_wdata[19:0];
                4'd1: {colubk, colupf, colup1, colup0} <= st_wdata[27:0];
                4'd2: pf <= st_wdata[19:0];
                4'd3: pf_new <= st_wdata[19:0];
                4'd4: {rs_delta, line_end, x, pix_on, pix} <= st_wdata[25:0];
                4'd13: {hmove_sr, hmw_sr, hmw_sel, hmw_val, mclk, mactive, ext, hblank} <= st_wdata[22:0];
                4'd14: {moving, hm[4], hm[3], hm[2], hm[1], hm[0]} <= st_wdata[24:0];
                4'd15: {latched, latch_mode, pf_cv, cx} <= st_wdata[18:0];
                default: ;
            endcase
        end
    end

    // The CPU repeats a read cycle that ends with rdy low, so the one that starts the next line is the
    // first to complete.
    assign rdy    = !wsync;
    // Reads by A3-A0: the collision latches (with this colour clock's check), then INPT0-5.
    always_comb
        case (addr[3:0])
            4'h0: dout = {cx_seen[14:13], 6'd0};
            4'h1: dout = {cx_seen[12:11], 6'd0};
            4'h2: dout = {cx_seen[10:9], 6'd0};
            4'h3: dout = {cx_seen[8:7], 6'd0};
            4'h4: dout = {cx_seen[6:5], 6'd0};
            4'h5: dout = {cx_seen[4:3], 6'd0};
            4'h6: dout = {cx_seen[2], 7'd0};
            4'h7: dout = {cx_seen[1:0], 6'd0};
            4'hC: dout = {inpt45[0], 7'd0};
            4'hD: dout = {inpt45[1], 7'd0};
            default: dout = 8'd0;  // INPT0-3: no paddles yet
        endcase
    assign vsync  = vsync_r;
    assign vblank = vblank_r;

    if (SAVE_STATE) begin : g_st
        always_ff @(posedge clk)
            case (st_addr)
                4'd0: st_rdata <= {12'd0, pf_cnt, vblank_pend, vblank_new, vblank_r, vsync_r, wsync, pf_bit,
                                   reflect_l, pfp, score, reflect, hctr};
                4'd1: st_rdata <= {4'd0, colubk, colupf, colup1, colup0};
                4'd2: st_rdata <= {12'd0, pf};
                4'd3: st_rdata <= {12'd0, pf_new};
                4'd4: st_rdata <= {6'd0, rs_delta, line_end, x, pix_on, pix};
                4'd5: st_rdata <= p0_st0;
                4'd6: st_rdata <= p0_st1;
                4'd7: st_rdata <= p1_st0;
                4'd8: st_rdata <= p1_st1;
                4'd9: st_rdata <= {4'd0, enabl_new, enam1_new, enam0_new, enabl_pend, enam1_pend, enam0_pend,
                                   refp1_new, refp0_new, grp1_new, grp0_new, refp1_pend, refp0_pend,
                                   grp1_pend, grp0_pend};
                4'd10: st_rdata <= m0_st;
                4'd11: st_rdata <= m1_st;
                4'd12: st_rdata <= bl_st;
                4'd13: st_rdata <= {9'd0, hmove_sr, hmw_sr, hmw_sel, hmw_val, mclk, mactive, ext, hblank};
                4'd14: st_rdata <= {7'd0, moving, hm[4], hm[3], hm[2], hm[1], hm[0]};
                4'd15: st_rdata <= {13'd0, latched, latch_mode, pf_cv, cx};
                default: st_rdata <= '0;
            endcase
    end else begin : g_no_st
        assign st_rdata = '0;
        wire unused_pst = &{1'b0, p0_st0, p0_st1, p1_st0, p1_st1, m0_st, m1_st, bl_st};
    end

endmodule
