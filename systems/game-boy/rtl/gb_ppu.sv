// SPDX-License-Identifier: Apache-2.0
// The Game Boy's PPU (DMG): its registers (LCDC, STAT, SCY, SCX, LY, LYC,
// BGP, OBP0, OBP1, WY, WX), the line and mode timing, STAT's interrupt line,
// the CPU's access blocks on video RAM and OAM, the OAM scan, and mode 3's
// pixel FIFOs and fetcher, the window and objects, dot by dot.
//
// One dot per `ce`. Each event of a line happens at the edge where `lx`
// holds its dot: `lx` counts a line's 456 dots from 0 (as SameBoy's
// cycles_for_line does, so the first line after the LCD is turned on, which
// is 7 dots shorter, jumps ahead at mode 3's start). Mode 3 runs one step of
// the fetcher a dot, and an object's fetch stops it for 6 dots or more, so
// its length comes out of the FIFO and fetcher as on the chip.
//
// The CPU's accesses: `phase` is the dot's place in the M-cycle (0 to 3;
// the CPU's memory writes land at phase 3's edge, its read takes the state
// after phase 2's). A register write lands, by register, where the chip's
// access conflicts put it (SameBoy's offsets from the M-cycle's end): SCX,
// and the first half of LCDC and the palettes (the new bits ORed in), at
// phase 1's edge; SCY and the rest of LCDC and the palettes at phase 2's;
// LYC, WY, WX and STAT at phase 3's, STAT first as all ones (the DMG's STAT
// write bug) and then its value a dot later. So the LCD turns on at phase
// 2's edge, which Mooneye's lcdon tests pin to the dot.
//
// Video RAM and OAM are outside: `vaddr`/`vq` and `oaddr`/`oq` are the PPU's
// read ports, `vq` and `oq` the data a clock after the address (registered
// block RAM); OAM is read 16 bits at a time (word 2i: Y and X of object i,
// word 2i+1: its tile and flags).
//
// The timing is SameBoy's model of the DMG's (read for facts), checked with
// Mooneye's PPU tests and dmg-acid2.
//
// The Game Boy Color (`cgb_hw`): video RAM is two banks read together (`vq`, bank 1 in bits
// 15-8), and the colour palettes' RAM (FF68-FF6B, 64 bytes each for the background and objects)
// is here. In the Color's own mode (`cgb_en`) each background tile has attributes from bank 1
// (palette, bank, flips, priority), objects take a palette of 8 and a bank, LCDC bit 0 takes away
// the background's priority rather than the background, and objects overlap by OAM order. In its
// Game Boy mode, the shades through BGP, OBP0 and OBP1 pick colours of the palettes the boot ROM
// set (background palette 0, object palettes 0 and 1). Either way a pixel comes out as its
// 15-bit colour (`pix_color`), looked up the clock after its dot; on the Game Boy its shade.
module gb_ppu (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,          // one dot
    input  logic [1:0]  phase,       // this dot's place in the M-cycle
    input  logic        wr,          // the CPU writes FF40 + reg_sel this M-cycle
    input  logic [3:0]  reg_sel,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,       // register reg_sel, as read
    input  logic        dma_on,      // OAM DMA is copying
    input  logic        halted,      // the CPU is halted
    input  logic        cgb_hw,      // the Game Boy Color
    input  logic        cgb_en,      // ...in its own mode (KEY0)
    input  logic        dbl,         // ...in double speed (KEY1)
    input  logic        obj_x_pri,   // OPRI bit 0: objects overlap by X, as the Game Boy's (else by OAM order)
    input  logic        pwr,         // the CPU writes FF68 + pal_sel this M-cycle (lands at its end)
    input  logic [1:0]  pal_sel,
    output logic [7:0]  pal_q,       // FF68 + pal_sel, as read
    input  logic        pal_clr,     // zero palette entry pal_clr_a in both palettes (after a reset)
    input  logic [5:0]  pal_clr_a,

    output logic [12:0] vaddr,       // video RAM, the PPU's port
    input  logic [15:0] vq,          // both banks: bank 1 in bits 15-8
    output logic [6:0]  oaddr,       // OAM, 16 bits a word
    input  logic [15:0] oq,

    output logic        vram_rd_blk, // the CPU reads video RAM as FF
    output logic        vram_wr_blk, // the CPU's writes to video RAM are lost
    output logic        oam_rd_blk,  // the CPU reads OAM as FF
    output logic        oam_wr_blk,  // the CPU's writes to OAM are lost

    output logic        irq_vblank,  // with ce: request the interrupt (at this edge)
    output logic        irq_stat,

    output logic        pix_we,      // a pixel (a clock after its dot): its colour, or shade 0 (white) to 3
    output logic [7:0]  pix_x,
    output logic [7:0]  pix_y,
    output logic [14:0] pix_color,
    output logic        frame_end,   // with ce: VBlank starts (the frame is out)
    output logic        frame_cut,   // with ce: the LCD turns off outside VBlank (the frame is cut short)
    output logic        hblank,      // HBlank, mode 0 from mode 3's end (or the LCD off), for the HBlank DMA
    output logic [7:0]  lcdc
);
    // ---- registers ----
    logic [7:0] scy, scx, lyc, bgp, obp0, obp1, wy, wx;
    logic [3:0] stat_en;             // STAT bits 6-3
    logic [7:0] ly;                  // LY as read

    // ---- line state ----
    localparam logic [1:0] MI_NONE = 2'd3;
    logic [8:0] lx;                  // the line's dot
    logic [7:0] line;                // the line being drawn
    logic       first;               // the first line after the LCD is turned on
    logic       cmp_none;            // LY isn't compared with LYC
    logic [7:0] ly_cmp;
    logic [1:0] smode;               // STAT's mode bits
    logic       scoinc;              // STAT's LY=LYC bit
    logic [1:0] mode_int;            // the mode STAT's interrupt line looks at (MI_NONE: none)
    logic       stat_line, lyc_line;
    logic       wy_trig, wy_sched, wx_new;
    logic [7:0] win_y;
    logic       hb1;                 // the dot after mode 3's end
    logic       stat_pend;           // STAT's written value lands at the next dot
    logic [3:0] stat_val;
    logic [7:0] ybus, xbus;          // the last Y and X the scan read

    // ---- mode 3 ----
    typedef enum logic [2:0] { O_NORM, O_A, O_C, O_C2, O_D, O_D2, O_E } ost_t;
    logic       m3;
    ost_t       ost;
    logic       after_obj, resume;
    logic [7:0] pos, lcd_x;
    logic [2:0] fst;                 // the fetcher's step: tile T1 T2, low T1 T2, high T1 T2, push
    logic [7:0] ftile, fdlo;
    logic [15:0] bgf;                // the background FIFO, next pixel in bits 15-14
    logic [3:0] bgn;
    logic [15:0] ofp;                // the object FIFO: pixels, next in bits 15-14
    logic [23:0] ofpal;              // their palettes (3 bits each; the Game Boy's 1 in the lowest), next in 23-21
    logic [31:0] ofslot;             // ...their objects' slots (the Color's priority by OAM order), next in 31-28
    logic [7:0] ofpri;               // ...and priority bits, next in bit 7
    logic [7:0] fattr;               // the Color's tile attributes, fetched with the tile
    logic       ins_px, n_ins_px;    // the next pixel is a blank one, inserted (WX matching again)
    logic       ftsel, n_ftsel;      // LCDC bit 4 as the bitplane's address took it
    logic [7:0] vbg;                 // the bitplane byte the fetcher takes (vb, or the TILE_SEL glitch's)
    logic [3:0] bgattr;              // the background FIFO's: priority, palette (one tile's at a time)
    logic       vbank;               // the bank vaddr's byte is read from
    logic [7:0] fy_c;                // the fetcher's Y, as at the tile's fetch (the Color keeps it)
    logic [3:0] ofn;
    logic       wx_trig, win_fetching;
    logic [4:0] win_tx;

    // ---- the line's objects (up to 10, in OAM order) ----
    logic [7:0] obj_x [0:9];
    logic [7:0] obj_y [0:9];
    logic [5:0] obj_i [0:9];
    logic [9:0] obj_done;
    logic [3:0] nvis;
    logic [3:0] oslot;               // the object being fetched
    logic [7:0] otile, oflags, odlo;
    logic [12:0] obj_addr;

    wire lcd_on = lcdc[7];

    // The Color's writes of LYC and WX, landing a T-cycle after their M-cycle
    logic       late_v, late_sel;
    logic [7:0] late_d;

    // ---- STAT's interrupt line (SameBoy's GB_STAT_update) ----
    // {irq, stat_line, lyc_line, scoinc, smode}. While LY isn't compared (`none`), the Game Boy's
    // LY=LYC bit reads 0; the Color's (`keep`) keeps its value, as SameBoy's CGB-E does.
    function automatic logic [5:0] stat_upd(input logic on, input logic dma, input logic [1:0] sm,
                                            input logic sc, input logic none, input logic [7:0] cmp,
                                            input logic [7:0] lyc_v, input logic lycl, input logic [3:0] en,
                                            input logic [1:0] mi, input logic sl, input logic keep);
        logic [1:0] m_;
        logic       c_, l_, s_;
        m_ = sm; c_ = sc; l_ = lycl; s_ = sl;
        if (on) begin
            if (dma && m_ == 2'd2) m_ = 2'd0;
            if (!none && cmp == lyc_v) begin
                l_ = 1'b1; c_ = 1'b1;
            end else begin
                if (!none) l_ = 1'b0;
                if (!none || !keep) c_ = 1'b0;
            end
            case (mi)
                2'd0: s_ = en[0];
                2'd1: s_ = en[1];
                2'd2: s_ = en[2];
                default: s_ = 1'b0;
            endcase
            if (en[3] && l_) s_ = 1'b1;
            stat_upd = {s_ && !sl, s_, l_, c_, m_};
        end else begin
            stat_upd = {1'b0, sl, lycl, sc, sm};
        end
    endfunction

    // ---- register reads ----
    always_comb begin
        case (reg_sel)
            4'h0: rdata = lcdc;
            4'h1: rdata = {1'b1, stat_en, scoinc, smode};
            4'h2: rdata = scy;
            4'h3: rdata = scx;
            4'h4: rdata = ly;
            4'h5: rdata = lyc;
            4'h7: rdata = bgp;
            4'h8: rdata = obp0;
            4'h9: rdata = obp1;
            4'hA: rdata = wy;
            4'hB: rdata = wx;
            default: rdata = 8'hFF;
        endcase
    end

    // ---- the next object: the not-yet-fetched one with the lowest X (then the lowest slot) ----
    function automatic logic [7:0] xmatch_of(input logic [7:0] p);
        logic [7:0] r;
        r = p + 8'd8;
        xmatch_of = r > 8'd240 ? 8'd0 : r;
    endfunction

    // The next object, chosen from registers that change only on a dot (as the step below has them
    // at its start) and registered every clock: `ce` comes at least 2 clocks apart, so a dot sees
    // the choice for the registers it starts with, and the step's longest path doesn't run through
    // ten comparisons of X.
    logic [7:0] sel_x, c_x;
    logic [3:0] sel_slot, c_slot;
    logic       sel_have, c_have;
    // A tournament, pairs at a time, the lower slot winning a tie: the same choice as taking the
    // slots in order, in 4 comparisons' depth rather than 10.
    logic [15:0] cand [0:15];  // {have, x, 3'b0, slot} for slots 0-9, none for 10-15
    always_comb begin
        logic [7:0] m;
        m = xmatch_of(pos);
        for (int k = 0; k < 16; k++) begin
            cand[k] = '0;
            if (k < 10)
                cand[k] = {4'(k) < nvis && !obj_done[k] && (after_obj || obj_x[k] >= m), obj_x[k], 3'd0, 4'(k)};
        end
        for (int w = 8; w >= 1; w = w / 2)
            for (int k = 0; k < w; k++)
                cand[k] = cand[2 * k][15] && (!cand[2 * k + 1][15] || cand[2 * k][14:7] <= cand[2 * k + 1][14:7])
                          ? cand[2 * k] : cand[2 * k + 1];
        c_have = cand[0][15];
        c_x    = cand[0][15] ? cand[0][14:7] : 8'hFF;
        c_slot = cand[0][15] ? cand[0][3:0] : 4'd0;
    end
    always_ff @(posedge clk) begin
        sel_have <= c_have;
        sel_x    <= c_x;
        sel_slot <= c_slot;
    end

    // ---- the step ----
    logic [7:0]  n_lcdc, n_scy, n_scx, n_lyc, n_bgp, n_obp0, n_obp1, n_wy, n_wx, n_ly;
    logic [3:0]  n_stat_en;
    logic [8:0]  n_lx;
    logic [7:0]  n_line, n_ly_cmp, n_win_y, n_ybus, n_xbus;
    logic        n_stat_pend;
    logic        n_first, n_cmp_none, n_scoinc, n_stat_line, n_lyc_line, n_wy_trig, n_wy_sched, n_wx_new, n_hb1;
    logic [1:0]  n_smode, n_mode_int;
    logic        n_vrb, n_vwb, n_orb, n_owb;
    logic        n_m3, n_after_obj, n_resume, n_wx_trig, n_win_fetching;
    ost_t        n_ost;
    logic [7:0]  n_pos, n_lcd_x, n_ftile, n_fdlo, n_ofpri, n_otile, n_oflags, n_odlo, n_fattr, n_fy_c;
    logic [23:0] n_ofpal;
    logic [31:0] n_ofslot;
    logic [3:0]  n_bgattr;
    logic        n_vbank;
    logic [2:0]  n_fst;
    logic [15:0] n_bgf, n_ofp;
    logic [3:0]  n_bgn, n_ofn, n_nvis, n_oslot;
    logic [4:0]  n_win_tx;
    logic [9:0]  n_obj_done;
    logic        n_ivb, n_ist;
    logic [12:0] n_vaddr;
    logic [6:0]  n_oaddr;
    logic        add_obj;
    logic [3:0]  add_slot;
    logic        n_pix_we, n_pix_obj;
    logic [1:0]  n_pix_shade;
    logic [2:0]  n_pix_pal;
    logic        n_frame_end, n_frame_cut;
    logic [5:0]  su;

    // working values inside a dot
    logic [7:0]  xm, nx;
    logic [3:0]  ns;
    logic        nhave;
    logic        do_render, do_fetch, end_m3;
    logic [7:0]  fy;
    logic [12:0] taddr;
    logic [1:0]  bp, op;
    logic [2:0]  opal;
    logic        opri, draw_obj, popped, bpri;
    logic [7:0]  vb;                 // vq's byte from the bank asked for
    logic        act;
    logic [8:0]  ydiff;
    logic [7:0]  sy;
    logic [7:0]  lo_b, hi_b;
    logic [2:0]  ob;
    logic [1:0]  opx, bgpix;
    logic        wt;
    logic [4:0]  tx;
    logic [7:0]  fdhi_r;
    logic [7:0]  n_pix_x;

    // One STAT update on the working values.
    `define STAT_UPDATE \
        su = stat_upd(n_lcdc[7], dma_on, n_smode, n_scoinc, n_cmp_none, n_ly_cmp, n_lyc, n_lyc_line, \
                      n_stat_en, n_mode_int, n_stat_line, cgb_hw); \
        n_ist = n_ist | su[5]; n_stat_line = su[4]; n_lyc_line = su[3]; n_scoinc = su[2]; n_smode = su[1:0];

    `define WY_CHECK \
        if (n_lcdc[7] && n_lcdc[5] && n_wy == (n_cmp_none ? n_line : n_ly_cmp)) n_wy_trig = 1'b1;

    // The first line's start, a dot after the LCD turns on (in the dot it does, on the Color).
    `define FIRST_LINE \
        n_win_y = 8'hFF; n_wy_trig = 1'b0; n_pos = 8'd240; \
        n_cmp_none = 1'b0; n_ly_cmp = 8'd0; n_smode = 2'd0; n_mode_int = MI_NONE; \
        n_vrb = 1'b0; n_vwb = 1'b0; n_orb = 1'b0; n_owb = 1'b0; \
        `STAT_UPDATE

    always_comb begin
        n_lcdc = lcdc; n_scy = scy; n_scx = scx; n_lyc = lyc; n_bgp = bgp; n_obp0 = obp0; n_obp1 = obp1;
        n_wy = wy; n_wx = wx; n_ly = ly; n_stat_en = stat_en;
        n_lx = lx; n_line = line; n_first = first; n_cmp_none = cmp_none; n_ly_cmp = ly_cmp;
        n_smode = smode; n_scoinc = scoinc; n_mode_int = mode_int; n_stat_line = stat_line; n_lyc_line = lyc_line;
        n_wy_trig = wy_trig; n_wy_sched = wy_sched; n_wx_new = 1'b0; n_win_y = win_y; n_hb1 = 1'b0;
        n_ybus = ybus; n_xbus = xbus;
        n_vrb = vram_rd_blk; n_vwb = vram_wr_blk; n_orb = oam_rd_blk; n_owb = oam_wr_blk;
        n_m3 = m3; n_ost = ost; n_after_obj = after_obj; n_resume = resume;
        n_pos = pos; n_lcd_x = lcd_x; n_fst = fst; n_ftile = ftile; n_fdlo = fdlo;
        n_bgf = bgf; n_bgn = bgn; n_ofp = ofp; n_ofpal = ofpal; n_ofpri = ofpri; n_ofn = ofn;
        n_ofslot = ofslot; n_fattr = fattr; n_ftsel = ftsel; n_ins_px = ins_px; n_bgattr = bgattr; n_vbank = vbank; n_fy_c = fy_c;
        n_wx_trig = wx_trig; n_win_fetching = win_fetching; n_win_tx = win_tx;
        n_obj_done = obj_done; n_nvis = nvis; n_oslot = oslot; n_otile = otile; n_oflags = oflags; n_odlo = odlo;
        n_ivb = 1'b0; n_ist = 1'b0; n_stat_pend = 1'b0;
        n_vaddr = vaddr; n_oaddr = oaddr;
        add_obj = 1'b0; add_slot = nvis;
        n_pix_we = 1'b0; n_pix_shade = 2'd0; n_pix_obj = 1'b0; n_pix_pal = 3'd0; n_frame_end = 1'b0;
        n_frame_cut = 1'b0;
        su = '0;
        xm = '0; nx = '0; ns = '0; nhave = 1'b0; do_render = 1'b0; do_fetch = 1'b0; end_m3 = 1'b0;
        fy = '0; taddr = '0; bp = '0; op = '0; opal = '0; opri = 1'b0; draw_obj = 1'b0; popped = 1'b0;
        bpri = 1'b0;
        vb = vbank ? vq[15:8] : vq[7:0];
        // The Color clearing TILE_SEL (LCDC bit 4) on the dot a bitplane is read from the tile set it
        // had takes the tile index for the bitplane instead, if below $80: Mealybug Tearoom's notes
        // for all but the CPU CGB D, and SameBoy's (its CGB-E) (m3_lcdc_tile_sel_change and _win_).
        vbg = (cgb_hw && !dbl && wr && reg_sel == 4'h0 && phase == 2'd3 && !wdata[4] && ftsel && !ftile[7]) ? ftile : vb;
        act = 1'b0; ydiff = '0; sy = '0; lo_b = '0; hi_b = '0;
        ob = '0; opx = '0; bgpix = '0; wt = 1'b0; tx = '0; n_pix_x = lcd_x;

        if (ce) begin
            // ======== the line's events ========
            if (lcd_on) begin
                n_lx = lx == 9'd455 ? 9'd0 : lx + 9'd1;
                if (lx == 9'd455) begin
                    n_line = line == 8'd153 ? 8'd0 : line + 8'd1;
                    if (line == 8'd153) n_wy_trig = 1'b0;
                end

                if (first) begin
                    // The first line after the LCD is turned on: no mode 2.
                    if (lx == 9'd1) begin
                        `FIRST_LINE
                    end
                    if (lx == 9'd77) begin
                        n_owb = 1'b1;
                        `STAT_UPDATE
                    end
                    if (lx == 9'd79) begin
                        n_nvis = '0; n_obj_done = '0;
                        n_smode = 2'd3; n_mode_int = MI_NONE;
                        n_orb = 1'b1; n_owb = 1'b1; n_vrb = 1'b1; n_vwb = 1'b1;
                    end
                    if (lx == 9'd83) begin
                        n_lx = 9'd91;
                        n_first = 1'b0;
                        n_wx_trig = 1'b0;
                        n_m3 = 1'b1; n_ost = O_NORM; n_after_obj = 1'b0; n_resume = 1'b0;
                        n_bgf = '0; n_bgn = 4'd8; n_ins_px = 1'b0; n_ofn = '0; n_lcd_x = '0; n_fst = '0; n_bgattr = '0;
                    end
                end else if (line < 8'd144) begin
                    if (lx == 9'd0) begin
                        if (line != 8'd0) n_mode_int = 2'd2;
                        `WY_CHECK
                    end
                    if (lx == 9'd3) begin
                        n_ly = line; n_orb = 1'b1;
                        n_cmp_none = line != 8'd0; n_ly_cmp = 8'd0;
                        if (line != 8'd0) n_mode_int = 2'd2;
                        // Line 0, after VBlank: the Game Boy's mode reads 0 for a dot, the Color's
                        // stays 1 (SameBoy's; single speed only, see the README's double speed)
                        if (line != 8'd0 || !cgb_hw || dbl) n_smode = 2'd0;
                        `STAT_UPDATE
                    end
                    if (lx == 9'd4) begin
                        n_smode = 2'd2; n_mode_int = 2'd2; n_owb = 1'b1; n_orb = 1'b1;
                        n_cmp_none = 1'b0; n_ly_cmp = line;
                        `WY_CHECK
                        `STAT_UPDATE
                        n_mode_int = MI_NONE;
                        `STAT_UPDATE
                        n_nvis = '0; n_obj_done = '0;
                    end
                    // The OAM scan: object i at dot 6 + 2i, its Y and X addressed a dot before.
                    if (lx >= 9'd5 && lx <= 9'd83 && lx[0]) n_oaddr = {lx[6:1] - 6'd2, 1'b0};
                    if (lx >= 9'd6 && lx <= 9'd84 && !lx[0]) begin
                        if (!dma_on || halted) begin
                            n_ybus = oq[7:0]; n_xbus = oq[15:8];
                        end
                        sy = (!dma_on || halted) ? oq[7:0] : ybus;
                        ydiff = {1'b0, line} + 9'd16 - {1'b0, sy};
                        if (nvis != 4'd10 && !ydiff[8] && ydiff < (lcdc[2] ? 9'd16 : 9'd8)) begin
                            add_obj = 1'b1;  // obj_x takes the X read with it
                            n_nvis = nvis + 4'd1;
                        end
                        if (lx == 9'd80) begin
                            n_vrb = 1'b1; n_owb = 1'b0;
                        end
                    end
                    if (lx == 9'd84) begin
                        n_smode = 2'd3; n_mode_int = MI_NONE;
                        n_vrb = 1'b1; n_vwb = 1'b1; n_orb = 1'b1; n_owb = 1'b1;
                        `STAT_UPDATE
                    end
                    if (lx == 9'd88) begin
                        n_m3 = 1'b1; n_ost = O_NORM; n_after_obj = 1'b0; n_resume = 1'b0;
                        n_bgf = '0; n_bgn = 4'd8; n_ins_px = 1'b0; n_ofn = '0; n_lcd_x = '0; n_fst = '0; n_bgattr = '0;
                    end
                    if (hb1) begin
                        n_smode = 2'd0; n_mode_int = 2'd0;
                        n_vrb = 1'b0; n_vwb = 1'b0; n_orb = 1'b0; n_owb = 1'b0;
                        `STAT_UPDATE
                    end
                end else if (line < 8'd153) begin
                    // VBlank, lines 144-152
                    if (lx == 9'd0) begin
                        n_cmp_none = 1'b1;
                        `STAT_UPDATE
                    end
                    if (lx == 9'd2) begin
                        n_ly = line;
                        if (line == 8'd144 && !stat_line && stat_en[2]) n_ist = 1'b1;
                    end
                    if (lx == 9'd4) begin
                        n_cmp_none = 1'b0; n_ly_cmp = line;
                        `STAT_UPDATE
                    end
                    if (lx == 9'd5 && line == 8'd144) begin
                        n_smode = 2'd1; n_ivb = 1'b1;
                        if (!n_stat_line && n_stat_en[2]) n_ist = 1'b1;
                        n_mode_int = 2'd1;
                        `STAT_UPDATE
                        n_frame_end = 1'b1;
                    end
                end else begin
                    // Line 153: LY reads 153 briefly, then 0.
                    if (lx == 9'd0) begin
                        n_cmp_none = 1'b1;
                        `STAT_UPDATE
                    end
                    if (lx == 9'd2) n_ly = 8'd153;
                    if (cgb_hw && !dbl) begin
                        // The Color (SameBoy's, its CGB-E) compares LY with 153 two dots sooner and
                        // keeps 153 as LY turns 0, two dots later (single speed only, as above)
                        if (lx == 9'd4) begin
                            n_cmp_none = 1'b0; n_ly_cmp = 8'd153;
                            `STAT_UPDATE
                        end
                        if (lx == 9'd8) n_ly = 8'd0;
                    end else begin
                        if (lx == 9'd6) begin
                            n_ly = 8'd0; n_cmp_none = 1'b0; n_ly_cmp = 8'd153;
                            `STAT_UPDATE
                        end
                        if (lx == 9'd8) begin
                            n_ly = 8'd0; n_cmp_none = 1'b1;
                            `STAT_UPDATE
                        end
                    end
                    if (lx == 9'd12) begin
                        n_cmp_none = 1'b0; n_ly_cmp = 8'd0;
                        `STAT_UPDATE
                    end
                end
                if (wy_sched && line < 8'd144) begin
                    n_wy_sched = 1'b0;
                    `WY_CHECK
                end

                // ======== mode 3, a dot ========
                if (m3) begin
                    // the next object
                    xm = xmatch_of(pos);
                    nhave = sel_have; nx = sel_x; ns = sel_slot;
                    case (ost)
                        O_NORM: begin
                            if (!after_obj && !resume) begin
                                // the window
                                if (!wx_trig && wy_trig && lcdc[5]) begin
                                    act = 1'b0;
                                    if (wx == 8'd0) begin
                                        act = pos == 8'd249 || (pos == 8'd240 && scx[2:0] != 3'd0) ||
                                              (pos >= 8'd241 && pos <= 8'd248);
                                    end else if (wx < (cgb_hw ? 8'd167 : 8'd166)) begin
                                        // (On the Color, 166 is as any other WX; the Game Boy's quirks
                                        // here and at mode 3's end are its own, as SameBoy has them.)
                                        if (wx == pos + 8'd7) act = 1'b1;
                                        else if (wx == pos + 8'd6 && !wx_new && !cgb_hw) begin
                                            act = 1'b1;
                                            if (lcd_x != 8'd0) n_lcd_x = lcd_x - 8'd1;
                                        end
                                    end
                                    if (act) begin
                                        n_win_y = win_y + 8'd1; n_win_tx = '0; n_bgn = '0;
                                        n_wx_trig = 1'b1; n_fst = '0; n_win_fetching = 1'b1;
                                        if (wx == 8'd0 && scx[2:0] != 3'd0) n_resume = 1'b1;
                                    end else if (!cgb_hw && wx == 8'd166 && wx == pos + 8'd7) begin
                                        n_win_y = win_y + 8'd1;
                                    end
                                end
                            end
                            // WX matching again with the window on and its fetch done inserts a blank
                            // pixel at the FIFO's end (the Game Boy's; the Color's only at WX 0, as
                            // SameBoy has it): Mealybug Tearoom's m3_wx_4_change and m3_wx_5_change
                            if (!after_obj && !resume && wx == pos + 8'd7 && (!cgb_hw || wx == 8'd0) &&
                                n_wx_trig && wx_trig && !win_fetching && fst == 3'd0 && bgn == 4'd8)
                                n_ins_px = 1'b1;
                            // objects left of the match point are dropped
                            if (!after_obj && (!n_resume || resume))
                                for (int k = 0; k < 10; k++)
                                    if (4'(k) < nvis && obj_x[k] < xm) n_obj_done[k] = 1'b1;
                            n_after_obj = 1'b0;
                            if (!n_resume || resume) begin
                                n_resume = 1'b0;
                                if (nhave && (lcdc[1] || cgb_en) && nx == xm) begin
                                    // an object's fetch starts: the fetcher runs on until it has a tile
                                    n_ost = O_A; n_oslot = ns;
                                    n_oaddr = {obj_i[ns], 1'b1};
                                    do_fetch = 1'b1;
                                    if (!(fst < 3'd5 || bgn == 4'd0)) n_ost = O_C;
                                end else begin
                                    do_render = 1'b1;
                                    do_fetch = 1'b1;
                                end
                            end
                        end
                        O_A: begin
                            do_fetch = 1'b1;
                            if (!(fst < 3'd5 || bgn == 4'd0)) n_ost = O_C;
                        end
                        O_C: begin
                            do_fetch = 1'b1;
                            n_otile = oq[7:0]; n_oflags = oq[15:8];
                            n_ost = O_C2;
                        end
                        O_C2: begin
                            n_vaddr = obj_addr; n_vbank = cgb_en && oflags[3];
                            n_ost = O_D;
                        end
                        O_D: begin
                            n_odlo = vb;
                            n_vaddr = obj_addr | 13'd1;
                            n_ost = O_D2;
                        end
                        O_D2: begin
                            // the high bitplane's address again, with LCDC's object size as it is now
                            // (SameBoy's, two dots after the low one's: m3_lcdc_obj_size_change)
                            n_vaddr = obj_addr | 13'd1;
                            n_ost = O_E;
                        end
                        default: begin  // O_E: the object's row goes into the object FIFO
                            lo_b = odlo; hi_b = vb;
                            // On the Color, an object fetched with objects off goes nowhere.
                            if (lcdc[1] || !cgb_en) begin
                                // fill to 8 with clear pixels
                                for (int i = 0; i < 8; i++)
                                    if (4'(i) >= ofn) begin
                                        n_ofp[15 - 2 * i -: 2] = 2'd0;
                                        n_ofpal[23 - 3 * i -: 3] = 3'd0;
                                        n_ofslot[31 - 4 * i -: 4] = 4'd0;
                                        n_ofpri[7 - i] = 1'b0;
                                    end
                                n_ofn = 4'd8;
                                for (int i = 0; i < 8; i++) begin
                                    // FIFO entry i takes pixel 7 - i of the row, or pixel i flipped. A pixel
                                    // takes a clear place, or on the Color one of a later object in OAM.
                                    ob = oflags[5] ? 3'(i) : 3'(7 - i);
                                    opx = {hi_b[ob], lo_b[ob]};
                                    if (opx != 2'd0 && (n_ofp[15 - 2 * i -: 2] == 2'd0 ||
                                                        (cgb_en && !obj_x_pri && oslot <= n_ofslot[31 - 4 * i -: 4]))) begin
                                        n_ofp[15 - 2 * i -: 2] = opx;
                                        n_ofpal[23 - 3 * i -: 3] = cgb_en ? oflags[2:0] : {2'd0, oflags[4]};
                                        n_ofslot[31 - 4 * i -: 4] = oslot;
                                        n_ofpri[7 - i] = oflags[7];
                                    end
                                end
                            end
                            n_obj_done[oslot] = 1'b1;
                            n_after_obj = 1'b1;
                            n_ost = O_NORM;
                        end
                    endcase

                    // ---- render a pixel, if it can ----
                    if (do_render && !(nhave && lcdc[1] && nx == 8'd0) && n_bgn != 4'd0) begin
                        if (n_ins_px) begin
                            bp = 2'd0;  // the inserted pixel: colour 0, the FIFO stays
                            n_ins_px = 1'b0;
                        end else begin
                            bp = n_bgf[15:14];
                            n_bgf = {n_bgf[13:0], 2'b00};
                            n_bgn = n_bgn - 4'd1;
                        end
                        if (ofn != 4'd0) begin
                            op = ofp[15:14]; opal = ofpal[23:21]; opri = ofpri[7];
                            n_ofp = {ofp[13:0], 2'b00}; n_ofpal = {ofpal[20:0], 3'b0}; n_ofpri = {ofpri[6:0], 1'b0};
                            n_ofslot = {ofslot[27:0], 4'b0};
                            n_ofn = ofn - 4'd1;
                            draw_obj = op != 2'd0 && lcdc[1];
                        end
                        popped = 1'b1;
                        if (pos >= 8'd240 && pos <= 8'd247) begin
                            if (pos[2:0] == scx[2:0]) n_pos = 8'd248;
                            else if (win_fetching && pos[2:0] == 3'd6 && scx[2:0] == 3'd7) n_pos = 8'd248;
                            else if (pos == 8'd247) begin
                                n_pos = 8'd240;
                                popped = 1'b0;
                            end
                        end
                        if (popped) begin
                            n_win_fetching = 1'b0;
                            if (n_pos >= 8'd160) begin
                                n_pos = n_pos + 8'd1;
                            end else begin
                                n_pix_we = 1'b1;
                                n_pix_x = n_lcd_x;
                                if (cgb_en) begin
                                    // The Color's mode: LCDC bit 0 off takes away the background's priority.
                                    bgpix = bp;
                                    bpri = (opri || bgattr[3]) && lcdc[0];
                                    if (bgpix != 2'd0 && bpri) draw_obj = 1'b0;
                                    n_pix_obj = draw_obj;
                                    n_pix_shade = draw_obj ? op : bgpix;
                                    n_pix_pal = draw_obj ? opal : bgattr[2:0];
                                end else begin
                                    bgpix = lcdc[0] ? bp : 2'd0;
                                    if (bgpix != 2'd0 && opri) draw_obj = 1'b0;
                                    n_pix_obj = draw_obj;
                                    if (draw_obj) n_pix_shade = opal[0] ? obp1[{op, 1'b0} +: 2] : obp0[{op, 1'b0} +: 2];
                                    else n_pix_shade = bgp[{bgpix, 1'b0} +: 2];
                                    n_pix_pal = draw_obj ? {2'd0, opal[0]} : 3'd0;
                                end
                                n_pos = n_pos + 8'd1;
                                n_lcd_x = n_lcd_x + 8'd1;
                            end
                        end
                    end

                    // ---- the fetcher, a step ----
                    if (do_fetch) begin
                        fy = n_wx_trig ? n_win_y : line + scy;
                        case (n_fst)
                            3'd0: begin
                                wt = n_wx_trig && lcdc[5];
                                if (!lcdc[5]) n_wx_trig = 1'b0;
                                fy = wt ? n_win_y : line + scy;
                                if (wt) tx = n_win_tx;
                                else if (n_pos >= 8'd240 && n_pos <= 8'd247) tx = scx[7:3];
                                // the Color's column is a position sooner, but during an object's fetch
                                // (SameBoy's: m3_scx_high_5_bits_change2)
                                else tx = 5'((scx + n_pos + 8'd8 - {7'd0, cgb_hw && ost == O_NORM && n_ost == O_NORM}) >> 3);
                                n_vaddr = {2'b11, (wt ? lcdc[6] : lcdc[3]), fy[7:3], tx};
                                n_vbank = 1'b0;
                                n_fy_c = fy;
                                n_fst = 3'd1;
                            end
                            3'd1: begin
                                // The Color reads the tile's attributes, in bank 1, with it.
                                n_ftile = vq[7:0]; n_fattr = cgb_en ? vq[15:8] : 8'd0; n_fst = 3'd2;
                            end
                            3'd2, 3'd4: begin
                                if (cgb_hw) fy = fy_c;  // the Color keeps the Y it fetched the tile with
                                taddr = lcdc[4] ? {1'b0, ftile, 4'd0} : 13'h1000 + {{1{ftile[7]}}, ftile, 4'd0};
                                n_vaddr = taddr + {9'd0, fy[2:0] ^ {3{fattr[6]}}, (n_fst == 3'd4)};
                                n_vbank = fattr[3];
                                n_ftsel = lcdc[4];
                                n_fst = n_fst + 3'd1;
                            end
                            3'd3: begin n_fdlo = vbg; n_fst = 3'd4; end
                            default: begin
                                if (n_fst == 3'd5) begin
                                    if (n_wx_trig) n_win_tx = n_win_tx + 5'd1;
                                end
                                n_fst = 3'd6;
                                if (n_bgn == 4'd0) begin
                                    // push the tile's row
                                    lo_b = n_fdlo; hi_b = (fst == 3'd5) ? vbg : fdhi_r;
                                    for (int i = 0; i < 8; i++)
                                        n_bgf[15 - 2 * i -: 2] = fattr[5] ? {hi_b[i], lo_b[i]} : {hi_b[7 - i], lo_b[7 - i]};
                                    n_bgattr = {fattr[7], fattr[2:0]};
                                    n_bgn = 4'd8;
                                    n_fst = 3'd0;
                                end
                            end
                        endcase
                    end

                    if (do_render && n_pos == 8'd160) end_m3 = 1'b1;
                end

                if (end_m3) begin
                    n_m3 = 1'b0;
                    n_smode = 2'd0; n_mode_int = 2'd0;
                    n_vrb = 1'b0; n_vwb = 1'b0; n_orb = 1'b0; n_owb = 1'b0;
                    n_pos = 8'd240;
                    if (line == 8'd143) n_win_y = 8'hFF;
                    if (!cgb_hw && wy_trig && lcdc[5] && wx == 8'd166) begin
                        n_wx_trig = 1'b1; n_win_tx = 5'd1; n_win_y = n_win_y + 8'd1;
                    end else begin
                        n_wx_trig = 1'b0;
                    end
                    n_hb1 = 1'b1;
                end
            end

            // ======== the CPU's writes, at their edges ========
            // The Color's are SameBoy's conflict map for it (CGB-E): most land as the M-cycle ends,
            // the palettes 2 T-cycles sooner, LYC and WX a T-cycle later.
            if (stat_pend) begin
                n_stat_en = stat_val;
                `STAT_UPDATE
            end
            if (late_v) begin
                if (late_sel) begin
                    n_wx = late_d;
                end else begin
                    n_lyc = late_d;
                    `STAT_UPDATE
                end
            end
            if (wr) begin
                case (reg_sel)
                    4'h0: begin
                        // What the PPU draws with lands a dot before the LCD's switch (bit 7): the
                        // Game Boy's bit 0 a dot sooner still (SameBoy's; Mealybug Tearoom's m3_lcdc_
                        // tests). In double speed the Color's all lands at phase 3.
                        if (phase == 2'd0 && !cgb_hw) n_lcdc = lcdc | (wdata & 8'h01);
                        if (phase == (cgb_hw ? 2'd2 : 2'd1)) n_lcdc = {lcdc[7], wdata[6:0]};
                        if (phase == (cgb_hw ? 2'd3 : 2'd2)) begin
                            n_lcdc = wdata;
                            n_wy_sched = 1'b1;
                            if (wdata[7] && !lcdc[7]) begin
                                // the LCD turns on: the first line starts, at the same dot against
                                // the CPU on both (the Game Boy's PPU waits a dot more, SameBoy's
                                // timing): the Color's write lands a dot later, so its line starts
                                // a dot on, in this dot
                                n_lx = 9'd1; n_first = 1'b1; n_line = 8'd0;
                                n_m3 = 1'b0; n_hb1 = 1'b0;
                                // single speed only: in double speed the line starts at the
                                // write's dot as the Game Boy's does (SameBoy's readings)
                                if (cgb_hw && !dbl) begin
                                    n_lx = 9'd2;
                                    `FIRST_LINE
                                end
                            end else if (!wdata[7] && lcdc[7]) begin
                                // off: LY and the mode read 0
                                n_frame_cut = smode != 2'd1;
                                n_ly = 8'd0; n_smode = 2'd0; n_line = 8'd0;
                                n_cmp_none = 1'b0; n_ly_cmp = 8'd0; n_wy_trig = 1'b0;
                                n_vrb = 1'b0; n_vwb = 1'b0; n_orb = 1'b0; n_owb = 1'b0;
                                n_m3 = 1'b0; n_hb1 = 1'b0; n_first = 1'b0;
                                n_lx = 9'd0;
                            end
                        end
                    end
                    4'h1: begin
                        if (phase == 2'd3) begin
                            // The DMG's STAT write bug: all ones for a dot (the Color keeps the LYC
                            // interrupt's old bit for it instead).
                            if (cgb_hw) n_stat_en = {stat_en[3], wdata[5:3]};
                            else n_stat_en = (lx == 9'd3 && !first && line < 8'd144 && lcd_on &&
                                              !stat_en[2] && stat_en[0]) ? 4'b1011 : 4'b1111;
                            `STAT_UPDATE
                        end
                        if (phase == 2'd3) n_stat_pend = 1'b1;
                    end
                    4'h2: if (phase == (cgb_hw ? (dbl ? 2'd3 : 2'd2) : 2'd1)) n_scy = wdata;
                    4'h3: if (phase == (cgb_hw ? (dbl ? 2'd3 : 2'd2) : 2'd0)) n_scx = wdata;
                    4'h5: if (phase == 2'd3 && !cgb_hw) begin
                        n_lyc = wdata;
                        `STAT_UPDATE
                    end
                    // The palettes: the Game Boy's ORed with the old value for a dot, then the new
                    // (SameBoy's); the Color's (its CGB D and on) at the M-cycle's first dot, at
                    // single speed (Mealybug Tearoom's m3_bgp_change, m3_obp0_change)
                    4'h7: begin
                        if (phase == 2'd0 && !cgb_hw) n_bgp = bgp | wdata;
                        if (phase == (cgb_hw ? (dbl ? 2'd1 : 2'd0) : 2'd1)) n_bgp = wdata;
                    end
                    4'h8: begin
                        if (phase == 2'd0 && !cgb_hw) n_obp0 = obp0 | wdata;
                        if (phase == (cgb_hw ? (dbl ? 2'd1 : 2'd0) : 2'd1)) n_obp0 = wdata;
                    end
                    4'h9: begin
                        if (phase == 2'd0 && !cgb_hw) n_obp1 = obp1 | wdata;
                        if (phase == (cgb_hw ? (dbl ? 2'd1 : 2'd0) : 2'd1)) n_obp1 = wdata;
                    end
                    4'hA: if (phase == 2'd3) begin
                        n_wy = wdata;
                        n_wy_sched = 1'b1;
                    end
                    4'hB: if (phase == 2'd2 && !cgb_hw) begin
                        n_wx = wdata;
                        n_wx_new = 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end
    `undef STAT_UPDATE
    `undef WY_CHECK
    `undef FIRST_LINE

    // The object's row address: its tile and flags from OAM, its Y from the scan.
    logic [3:0] orow;
    logic [3:0] ot;
    always_comb begin
        orow = line[3:0] - obj_y[oslot][3:0];
        ot = lcdc[2] ? orow[3:0] : {1'b0, orow[2:0]};
        if (oflags[6]) ot = ot ^ (lcdc[2] ? 4'hF : 4'h7);
        obj_addr = {1'b0, (lcdc[2] ? {otile[7:1], 1'b0} : otile), 4'd0} + {8'd0, ot, 1'b0};
    end

    assign irq_vblank = n_ivb;
    assign irq_stat   = n_ist;
    assign frame_end  = n_frame_end;
    assign frame_cut  = n_frame_cut;

    always_ff @(posedge clk)
        if (rst) late_v <= 1'b0;
        else if (ce) begin
            late_v   <= cgb_hw && wr && phase == 2'd3 && (reg_sel == 4'h5 || reg_sel == 4'hB);
            late_sel <= reg_sel == 4'hB;
            late_d   <= wdata;
        end

    // ---- the Color's palettes (FF68-FF6B): 8 of 4 colours each for the background and objects,
    // 15-bit colours in byte pairs, low byte first. The CPU can't reach the data in mode 3 (it reads
    // FF and its writes are lost, though the index still steps). ----
    logic [7:0] bpal [0:63];
    logic [7:0] opal_m [0:63];
    logic [6:0] bcps, ocps;          // {auto-increment, index}
    wire        pal_blk = smode == 2'd3;
    always_comb
        case (pal_sel)
            2'd0: pal_q = {bcps[6], 1'b1, bcps[5:0]};
            2'd1: pal_q = pal_blk ? 8'hFF : bpal[bcps[5:0]];
            2'd2: pal_q = {ocps[6], 1'b1, ocps[5:0]};
            default: pal_q = pal_blk ? 8'hFF : opal_m[ocps[5:0]];
        endcase
    wire pal_wr = !rst && ce && phase == 2'd3 && pwr && !pal_blk;
    always_ff @(posedge clk)
        if (rst) begin
            bcps <= '0;
            ocps <= '0;
        end else if (ce && phase == 2'd3 && pwr)
            case (pal_sel)
                2'd0: bcps <= {wdata[7], wdata[5:0]};
                2'd1: if (bcps[6]) bcps[5:0] <= bcps[5:0] + 6'd1;
                2'd2: ocps <= {wdata[7], wdata[5:0]};
                default: if (ocps[6]) ocps[5:0] <= ocps[5:0] + 6'd1;
            endcase
    // The data, one write port each so that they can be RAM: zeroed a cell at a time after a reset
    // (gameboy's count through its memories), as a reset can't clear a RAM.
    always_ff @(posedge clk)
        if (pal_clr) bpal[pal_clr_a] <= '0;
        else if (pal_wr && pal_sel == 2'd1) bpal[bcps[5:0]] <= wdata;
    always_ff @(posedge clk)
        if (pal_clr) opal_m[pal_clr_a] <= '0;
        else if (pal_wr && pal_sel == 2'd3) opal_m[ocps[5:0]] <= wdata;

    // ---- the pixel, a clock after its dot: its colour from the palettes ----
    logic       q_obj;
    logic [2:0] q_pal;
    logic [1:0] q_sh;
    always_ff @(posedge clk) begin
        pix_we <= ce && n_pix_we && !rst;
        if (ce && n_pix_we) begin
            pix_x <= n_pix_x;
            pix_y <= line;
            q_obj <= n_pix_obj;
            q_pal <= n_pix_pal;
            q_sh  <= n_pix_shade;
        end
    end
    wire [5:0] q_i = {q_pal, q_sh, 1'b0};
    always_comb
        if (!cgb_hw) pix_color = {13'd0, q_sh};
        else if (q_obj) pix_color = {opal_m[q_i | 6'd1][6:0], opal_m[q_i]};
        else pix_color = {bpal[q_i | 6'd1][6:0], bpal[q_i]};

    always_ff @(posedge clk) begin
        if (rst) begin
            lcdc <= '0; scy <= '0; scx <= '0; lyc <= '0; bgp <= '0; obp0 <= '0; obp1 <= '0;
            wy <= '0; wx <= '0; ly <= '0; stat_en <= '0;
            lx <= '0; line <= '0; first <= 1'b0; cmp_none <= 1'b0; ly_cmp <= '0;
            smode <= '0; scoinc <= 1'b0; mode_int <= MI_NONE; stat_line <= 1'b0; lyc_line <= 1'b0;
            hblank <= 1'b0;
            wy_trig <= 1'b0; wy_sched <= 1'b0; wx_new <= 1'b0; win_y <= 8'hFF; hb1 <= 1'b0;
            stat_pend <= 1'b0; stat_val <= '0;
            ybus <= '0; xbus <= '0;
            vram_rd_blk <= 1'b0; vram_wr_blk <= 1'b0; oam_rd_blk <= 1'b0; oam_wr_blk <= 1'b0;
            m3 <= 1'b0; ost <= O_NORM; after_obj <= 1'b0; resume <= 1'b0;
            pos <= 8'd240; lcd_x <= '0; fst <= '0; ftile <= '0; fdlo <= '0; fdhi_r <= '0;
            bgf <= '0; bgn <= '0; ofp <= '0; ofpal <= '0; ofpri <= '0; ofn <= '0;
            ofslot <= '0; fattr <= '0; ftsel <= 1'b0; ins_px <= 1'b0; bgattr <= '0; vbank <= 1'b0; fy_c <= '0;
            wx_trig <= 1'b0; win_fetching <= 1'b0; win_tx <= '0;
            obj_done <= '0; nvis <= '0; oslot <= '0; otile <= '0; oflags <= '0; odlo <= '0;
            vaddr <= '0; oaddr <= '0;
        end else begin
            lcdc <= n_lcdc; scy <= n_scy; scx <= n_scx; lyc <= n_lyc; bgp <= n_bgp; obp0 <= n_obp0;
            obp1 <= n_obp1; wy <= n_wy; wx <= n_wx; ly <= n_ly; stat_en <= n_stat_en;
            lx <= n_lx; line <= n_line; first <= n_first; cmp_none <= n_cmp_none; ly_cmp <= n_ly_cmp;
            smode <= n_smode; scoinc <= n_scoinc; mode_int <= n_mode_int; stat_line <= n_stat_line;
            // STAT reads mode 0 for a dot as each line starts; after VBlank, on line 0, that isn't an
            // HBlank (MesenCE's HBlank DMA moves no block there), so HBlank is mode 0 that began as
            // mode 3 ended, or the LCD off.
            hblank <= n_smode == 2'd0 && (smode == 2'd3 || hblank || !n_lcdc[7]);
            lyc_line <= n_lyc_line; wy_trig <= n_wy_trig; wy_sched <= n_wy_sched; win_y <= n_win_y;
            if (ce) begin
                wx_new <= n_wx_new;
                hb1 <= n_hb1;
                stat_pend <= n_stat_pend;
                if (n_stat_pend) stat_val <= wdata[6:3];
            end
            ybus <= n_ybus; xbus <= n_xbus;
            vram_rd_blk <= n_vrb; vram_wr_blk <= n_vwb; oam_rd_blk <= n_orb; oam_wr_blk <= n_owb;
            m3 <= n_m3; ost <= n_ost; after_obj <= n_after_obj; resume <= n_resume;
            pos <= n_pos; lcd_x <= n_lcd_x; fst <= n_fst; ftile <= n_ftile; fdlo <= n_fdlo;
            if (ce && do_fetch && fst == 3'd5) fdhi_r <= vbg;
            bgf <= n_bgf; bgn <= n_bgn; ofp <= n_ofp; ofpal <= n_ofpal; ofpri <= n_ofpri; ofn <= n_ofn;
            ofslot <= n_ofslot; fattr <= n_fattr; ftsel <= n_ftsel; ins_px <= n_ins_px; bgattr <= n_bgattr; vbank <= n_vbank; fy_c <= n_fy_c;
            wx_trig <= n_wx_trig; win_fetching <= n_win_fetching; win_tx <= n_win_tx;
            obj_done <= n_obj_done; nvis <= n_nvis; oslot <= n_oslot;
            otile <= n_otile; oflags <= n_oflags; odlo <= n_odlo;
            vaddr <= n_vaddr; oaddr <= n_oaddr;
            if (add_obj) begin
                obj_x[add_slot] <= (!dma_on || halted) ? oq[15:8] : xbus;
                obj_y[add_slot] <= (!dma_on || halted) ? oq[7:0] : ybus;
                obj_i[add_slot] <= 6'(lx[6:1] - 6'd3);
            end
        end
    end
endmodule
