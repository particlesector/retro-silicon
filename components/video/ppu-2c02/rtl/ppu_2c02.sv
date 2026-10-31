// SPDX-License-Identifier: Apache-2.0
// The NES's 2C02 PPU (NTSC), dot-exact: 341 dots by 262 lines, one dot per
// clock with `ce` high. Its timing follows the 2C02 as MesenCE models it, so
// frames compare against MesenCE pixel for pixel. See README.md for the
// details and for what isn't modelled.
//
// Positions: line 0-239 visible, 240 post-render, 241-260 vertical blank, 261
// pre-render; dots 0-340. After reset the PPU sits at line 261, dot 340, so its
// first dot is line 0, dot 0.
//
// The next dot is computed every clock and registered, and `ce` commits it, so
// `ce` must come at least 2 clocks apart, and the PPU's inputs must be
// settled the clock before each `ce`: no `reg_ce` or `st_we` then or on it,
// and `vrdata` as it will be on the `ce` clock.
//
// CPU port: one register access per strobe of `reg_ce`, between dots. A
// read's data is on `reg_rdata` from the clock after the strobe until the
// next one.
//
// Video memory port: `vaddr`, `vwe` and `vwdata` change only on `ce` clocks
// and hold until the next. Memory must answer the address on `vrdata` from
// the clock before the next `ce` through it, and perform a write once,
// before that. `vaddr_next` is the address `vaddr` will take at the next
// `ce`, for memory too slow to answer within a dot: from the second clock
// after a `ce` (and so after that dot's register access) it's final for a
// pattern fetch or a $2007 read, whose addresses don't depend on that dot's
// `vrdata`. `vread_next` marks those reads (whether rendering is on or not):
// the PPU uses no other dot's data from $0000-$1FFF.
//
// Pixels: pixel x of a line comes out two dots after it's drawn, which is
// when grayscale and emphasis apply (as on the 2C02, a $2001 write changes
// the two pixels before it). `pix` is {emphasis BGR, colour}, as a 512-entry
// palette indexes it.
//
// Save state (docs/conventions.md): 101 words.
//   0-63   OAM, 4 bytes a word, byte 0 in bits 7-0
//   64-71  palette RAM, likewise
//   72-79  secondary OAM, likewise
//   80-87  sprite units: pattern low, pattern high, X, then valid, priority, palette
//   88-100 registers and pipeline (see the packing at the end)
module ppu_2c02 #(
    parameter int OPEN_BUS_DECAY = 3,     // frames before an unrefreshed open-bus bit reads 0
    parameter bit SAVE_STATE     = 1'b1   // 0 leaves out the save-state port's logic, but for OAM's writes
) (
    input  logic        clk,
    input  logic        rst,  // synchronous; the power-up state
    input  logic        ce,   // one dot

    // CPU registers $2000-$2007.
    input  logic        reg_ce,
    input  logic        reg_we,
    input  logic [2:0]  reg_addr,
    input  logic [7:0]  reg_wdata,
    output logic [7:0]  reg_rdata,
    output logic        nmi_n,

    // Video memory: pattern tables and nametables ($0000-$3EFF).
    output logic [13:0] vaddr,
    output logic [13:0] vaddr_next,
    output logic        vread_next,
    output logic        vwe,
    output logic [7:0]  vwdata,
    input  logic [7:0]  vrdata,

    // Pixels, a one-clock pulse each.
    output logic        pix_valid,
    output logic [8:0]  pix,
    output logic [7:0]  pix_x,
    output logic [7:0]  pix_y,
    output logic        frame_end,  // one-clock pulse at line 240, dot 0

    output logic [8:0]  dbg_line,
    output logic [8:0]  dbg_dot,

    // Save-state port.
    input  logic [6:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    // ---- State ----
    logic [7:0]  ctrl, mask;
    logic        vbl, s0hit, ovf;
    logic [7:0]  oamaddr;
    logic [14:0] v, t;
    logic [2:0]  fx;
    logic        w;
    logic [7:0]  rdbuf;
    logic [7:0]  io;           // the open-bus latch
    logic [23:0] io_age;       // frames since each bit was refreshed, 3 bits each, saturating
    logic        odd;          // odd frame: the pre-render line skips its last dot
    logic [8:0]  dot, line;

    logic [15:0] sh_lo, sh_hi; // background pattern shifters
    logic [1:0]  pal_prev, pal_cur, tile_pal;
    logic [7:0]  tile_lo, tile_hi;
    logic [12:0] tile_addr;

    logic [7:0]  oam_buf;      // the sprite evaluation's copy buffer
    logic [7:0]  sec_addr;     // secondary OAM address
    logic        in_range, copy_done, s0_added, s0_vis;
    logic [1:0]  ovf_cnt;      // the overflow bug's realignment count
    logic [12:0] sp_addr;      // sprite fetch: pattern address, attributes, X, in range
    logic [7:0]  sp_attr, sp_x, sp_lo;
    logic        sp_in;

    logic        ren_cur, ren_prev;  // rendering enabled, one and two dots after $2001
    logic        prevent;            // a $2002 read one dot early suppresses this VBL
    logic [2:0]  rd_sm, wr_sm;       // $2007 read and write, dots until they happen
    logic [7:0]  wr_latch;
    logic        need_inc;           // increment v after a $2007 access
    logic [2:0]  ign;                // a second $2007 read this soon is ignored
    logic [1:0]  upd_delay;          // dots until a $2006 write reaches v
    logic [14:0] upd_addr;
    logic [13:0] bus_addr;           // the last address on the video bus
    logic        fill;               // the read buffer takes vrdata on the next dot

    logic [5:0]  p1_c, p2_c;         // pixels waiting for grayscale and emphasis
    logic        p1_v, p2_v;
    logic [7:0]  p1_x, p2_x, p1_y, p2_y;

    logic [31:0] oam[64];
    logic [7:0]  pal[32];
    logic [7:0]  sec[32];
    logic [7:0]  sl_lo[8], sl_hi[8], sl_x[8];
    logic [7:0]  sl_valid, sl_pri;
    logic [1:0]  sl_pal[8];

    assign nmi_n    = !(vbl && ctrl[7]);

    initial begin
        if (OPEN_BUS_DECAY < 1 || OPEN_BUS_DECAY > 6)
            $error("ppu_2c02: OPEN_BUS_DECAY must be 1 to 6 frames");
    end
    assign dbg_line = line;
    assign dbg_dot  = dot;

    // ---- Helpers ----
    function automatic logic [14:0] inc_h(input logic [14:0] a);
        inc_h = a[4:0] == 5'd31 ? {a[14:11], ~a[10], a[9:5], 5'd0} : a + 15'd1;
    endfunction

    function automatic logic [14:0] inc_v(input logic [14:0] a);
        logic [14:0] r;
        r = a;
        if (a[14:12] != 3'd7)
            r[14:12] = a[14:12] + 3'd1;
        else begin
            r[14:12] = 3'd0;
            if (a[9:5] == 5'd29) begin
                r[9:5] = 5'd0;
                r[11]  = ~a[11];
            end else if (a[9:5] == 5'd31)
                r[9:5] = 5'd0;
            else
                r[9:5] = a[9:5] + 5'd1;
        end
        inc_v = r;
    endfunction

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [13:0] nt_addr(input logic [14:0] a);
        nt_addr = {2'b10, a[11:0]};
    endfunction

    function automatic logic [13:0] at_addr(input logic [14:0] a);
        at_addr = {2'b10, a[11:10], 4'b1111, a[9:7], a[4:2]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Palette index with $3F10/$14/$18/$1C as their mirrors.
    function automatic logic [4:0] pal_ix(input logic [4:0] a);
        pal_ix = a[1:0] == 2'b00 ? {1'b0, a[3:0]} : a;
    endfunction

    function automatic logic [7:0] rev8(input logic [7:0] b);
        for (int i = 0; i < 8; i++)
            rev8[i] = b[7 - i];
    endfunction

    wire        rline  = line < 9'd240 || line == 9'd261;  // a rendering line, by the current position
    wire  [4:0] spr_h  = ctrl[5] ? 5'd16 : 5'd8;
    wire  [7:0] oam_rd = oam[oamaddr[7:2]][8*oamaddr[1:0] +: 8];

    // ---- One dot: the next state if `ce` ----
    logic        n_vbl, n_s0hit, n_ovf;
    logic [7:0]  n_oamaddr;
    logic [14:0] n_v, n_t;
    logic [7:0]  n_rdbuf, n_io;
    logic [23:0] n_io_age;
    logic        n_odd;
    logic [8:0]  n_dot, n_line;
    logic [15:0] n_sh_lo, n_sh_hi;
    logic [1:0]  n_pal_prev, n_pal_cur, n_tile_pal;
    logic [7:0]  n_tile_lo, n_tile_hi;
    logic [12:0] n_tile_addr;
    logic [7:0]  n_oam_buf, n_sec_addr;
    logic        n_in_range, n_copy_done, n_s0_added, n_s0_vis;
    logic [1:0]  n_ovf_cnt;
    logic [12:0] n_sp_addr;
    logic [7:0]  n_sp_attr, n_sp_x, n_sp_lo;
    logic        n_sp_in;
    logic        n_ren_cur, n_ren_prev, n_prevent;
    logic [2:0]  n_rd_sm, n_wr_sm, n_ign;
    logic        n_need_inc;
    logic [1:0]  n_upd_delay;
    logic [13:0] n_bus_addr;
    logic        n_fill;
    logic [5:0]  n_p1_c;
    logic        n_p1_v;
    logic [7:0]  n_p1_x, n_p1_y;
    logic [13:0] n_vaddr;
    logic        n_vread;  // the next dot's read is one the PPU may use: a pattern fetch or a $2007 read
    logic        n_vwe;
    logic [7:0]  n_vwdata;
    logic        n_frame;
    // Writes this dot makes to the memories.
    logic        sec_we;
    logic [4:0]  sec_wa;
    logic [7:0]  sec_wd;
    logic        pal_we;
    logic [4:0]  pal_wa;
    logic [7:0]  pal_wd;
    logic        sl_we, sl_clear;
    logic [2:0]  sl_wa;

    always_comb begin
        logic [8:0]  cd, cl;
        logic        vis, pre;
        logic [7:0]  bgc, sbg, spc, x8;
        logic [3:0]  spi;
        logic        spf;
        logic [4:0]  color;
        logic [8:0]  diff;
        logic [7:0]  ah, al;
        logic [2:0]  slot;
        logic [8:0]  nd, nl;
        logic [3:0]  rr;
        logic [12:0] sa;
        logic [7:0]  sy, stile, sattr;
        logic [8:0]  so;      // a sprite unit's pixel offset
        logic        inr;     // the copy buffer's Y is in range

        n_vbl = vbl; n_s0hit = s0hit; n_ovf = ovf;
        n_oamaddr = oamaddr;
        n_v = v; n_t = t;
        n_rdbuf = rdbuf; n_io = io; n_io_age = io_age;
        n_odd = odd;
        n_sh_lo = sh_lo; n_sh_hi = sh_hi;
        n_pal_prev = pal_prev; n_pal_cur = pal_cur; n_tile_pal = tile_pal;
        n_tile_lo = tile_lo; n_tile_hi = tile_hi; n_tile_addr = tile_addr;
        n_oam_buf = oam_buf; n_sec_addr = sec_addr;
        n_in_range = in_range; n_copy_done = copy_done; n_s0_added = s0_added; n_s0_vis = s0_vis;
        n_ovf_cnt = ovf_cnt;
        n_sp_addr = sp_addr; n_sp_attr = sp_attr; n_sp_x = sp_x; n_sp_in = sp_in;
        n_ren_cur = ren_cur; n_ren_prev = ren_prev; n_prevent = prevent;
        n_rd_sm = rd_sm; n_wr_sm = wr_sm; n_ign = ign; n_need_inc = need_inc;
        n_upd_delay = upd_delay;
        n_bus_addr = bus_addr;
        n_fill = 1'b0;
        n_p1_c = p1_c; n_p1_v = 1'b0; n_p1_x = p1_x; n_p1_y = p1_y;
        n_vwe = 1'b0; n_vwdata = vwdata;
        n_frame = 1'b0;
        sec_we = 1'b0; sec_wa = '0; sec_wd = '0;
        pal_we = 1'b0; pal_wa = '0; pal_wd = '0;
        sl_we = 1'b0; sl_clear = 1'b0; sl_wa = '0;
        bgc = '0; sbg = '0; spc = '0; spi = 4'd8; spf = 1'b0; color = '0; x8 = '0;
        diff = '0; ah = '0; al = '0; slot = '0; rr = '0; sa = '0; sy = '0; stile = '0; sattr = '0;
        so = '0; inr = 1'b0;
        n_sp_lo = sp_lo;

        // A buffered $2007 read finished last dot: its data is here now.
        if (fill)
            n_rdbuf = vrdata;

        // ---- Advance ----
        if (dot == 9'd340) begin
            cd = 9'd0;
            cl = line == 9'd261 ? 9'd0 : line + 9'd1;
        end else begin
            cd = dot + 9'd1;
            cl = line;
        end
        n_dot  = cd;
        n_line = cl;
        vis = cl < 9'd240;
        pre = cl == 9'd261;

        if (cd == 9'd0) begin
            // ---- Dot 0 ----
            if (pre) begin
                sl_clear = 1'b1;
                n_ovf    = 1'b0;
                n_s0hit  = 1'b0;
            end else if (vis) begin
                if (ren_prev)
                    n_sec_addr = '0;
            end else if (cl == 9'd240) begin
                if (ren_prev)
                    n_sec_addr = '0;
                n_bus_addr = v[13:0];
                n_frame    = 1'b1;
                n_odd      = ~odd;
                for (int i = 0; i < 8; i++)
                    if (io_age[3*i +: 3] <= 3'(OPEN_BUS_DECAY)) begin
                        n_io_age[3*i +: 3] = io_age[3*i +: 3] + 3'd1;
                        if (io_age[3*i +: 3] == 3'(OPEN_BUS_DECAY))
                            n_io[i] = 1'b0;
                    end
            end
        end else if (vis || pre) begin
            if (cd <= 9'd256) begin
                // ---- Dots 1-256 ----
                if (vis) begin
                    // Draw pixel cd-1.
                    x8 = 8'(cd - 9'd1);
                    if (mask[3] && (mask[1] || cd > 9'd8))
                        sbg = {6'b0, sh_hi[4'd15 - {1'b0, fx}], sh_lo[4'd15 - {1'b0, fx}]};
                    bgc = sbg;
                    if (ren_prev && sl_valid != '0) begin
                        for (int i = 7; i >= 0; i--) begin
                            so = cd - {1'b0, sl_x[i]} - 9'd1;
                            if (sl_valid[i] && so < 9'd8 && {sl_hi[i][3'd7 - so[2:0]], sl_lo[i][3'd7 - so[2:0]]} != 2'b00) begin
                                spc = {6'b0, sl_hi[i][3'd7 - so[2:0]], sl_lo[i][3'd7 - so[2:0]]};
                                spi = 4'(i);
                            end
                        end
                        if (mask[4] && (mask[2] || cd > 9'd8) && spc != '0) begin
                            if (s0_vis && spi == 4'd0 && sbg != '0 && cd != 9'd256 && mask[3] && !s0hit)
                                n_s0hit = 1'b1;
                            if (bgc == '0 || !sl_pri[spi[2:0]]) begin
                                spf   = 1'b1;
                                color = {1'b1, sl_pal[spi[2:0]], spc[1:0]};
                            end
                        end
                    end
                    if (!spf)
                        color = {1'b0, ({1'b0, fx} + {1'b0, x8[2:0]} < 4'd8) ? pal_prev : pal_cur, bgc[1:0]};
                    n_p1_v = 1'b1;
                    n_p1_x = x8;
                    n_p1_y = cl[7:0];
                    if (ren_cur || v[13:8] != 6'h3F)
                        n_p1_c = pal[color[1:0] != 2'b00 ? color : 5'd0][5:0];
                    else
                        n_p1_c = pal[v[4:0]][5:0];
                end

                if (ren_prev) begin
                    if (vis) begin
                        // ---- Sprite evaluation for the next line ----
                        if (cd < 9'd65) begin
                            n_oam_buf = 8'hFF;
                            sec_we = 1'b1;
                            sec_wa = sec_addr[4:0];
                            sec_wd = 8'hFF;
                            n_sec_addr = sec_addr + {7'b0, !cd[0]};
                        end else if (cd[0]) begin
                            if (cd == 9'd65) begin
                                n_s0_added  = 1'b0;
                                n_in_range  = 1'b0;
                                n_sec_addr  = '0;
                                n_ovf_cnt   = '0;
                                n_copy_done = 1'b0;
                            end
                            n_oam_buf = oam_rd;
                        end else begin
                            ah = {2'b0, oamaddr[7:2]};
                            al = {6'b0, oamaddr[1:0]};
                            if (copy_done) begin
                                ah = (ah + 8'd1) & 8'h3F;
                                n_oam_buf = sec[sec_addr[4:0]];
                            end else begin
                                inr = {1'b0, cl[7:0]} >= {1'b0, oam_buf} && {1'b0, cl[7:0]} < {1'b0, oam_buf} + {4'b0, spr_h};
                                if (!in_range && inr)
                                    n_in_range = 1'b1;
                                if (sec_addr < 8'h20) begin
                                    sec_we = 1'b1;
                                    sec_wa = sec_addr[4:0];
                                    sec_wd = oam_buf;
                                    if (n_in_range) begin
                                        if (cd == 9'd66)
                                            n_s0_added = 1'b1;
                                        al = al + 8'd1;
                                        n_sec_addr = sec_addr + 8'd1;
                                        if (al >= 8'd4) begin
                                            ah = (ah + 8'd1) & 8'h3F;
                                            al = '0;
                                            if (ah == '0)
                                                n_copy_done = 1'b1;
                                        end
                                        if (n_sec_addr[1:0] == 2'b00) begin
                                            n_in_range = 1'b0;
                                            if (al != '0 && !inr)
                                                al = '0;
                                        end
                                    end else begin
                                        ah = (ah + 8'd1) & 8'h3F;
                                        al = '0;
                                        if (ah == '0)
                                            n_copy_done = 1'b1;
                                    end
                                end else begin
                                    n_oam_buf = sec[sec_addr[4:0]];
                                    if (n_in_range) begin
                                        n_ovf = 1'b1;
                                        al = al + 8'd1;
                                        if (al == 8'd4) begin
                                            ah = (ah + 8'd1) & 8'h3F;
                                            al = '0;
                                        end
                                        if (ovf_cnt == 2'd0)
                                            n_ovf_cnt = 2'd3;
                                        else begin
                                            n_ovf_cnt = ovf_cnt - 2'd1;
                                            if (ovf_cnt == 2'd1) begin
                                                n_copy_done = 1'b1;
                                                al = '0;
                                            end
                                        end
                                    end else begin
                                        ah = (ah + 8'd1) & 8'h3F;
                                        al = (al + 8'd1) & 8'h03;
                                        if (ah == '0)
                                            n_copy_done = 1'b1;
                                    end
                                end
                            end
                            n_oamaddr = {ah[5:0], al[1:0]};
                        end
                        // Shift the background.
                        n_sh_lo = {sh_lo[14:0], 1'b0};
                        n_sh_hi = {sh_hi[14:0], 1'b1};
                    end else if (cd == 9'd1)
                        n_vbl = 1'b0;

                    if (cd[2:0] == 3'd0) begin
                        n_v = inc_h(n_v);
                        if (cd == 9'd256)
                            n_v = inc_v(n_v);
                    end
                    // ---- Background fetches ----
                    case (cd[2:0])
                        3'd0: begin
                            n_sh_hi    = {n_sh_hi[15:8], tile_hi};
                            n_sh_lo    = {n_sh_lo[15:8], tile_lo};
                            n_pal_prev = pal_cur;
                            n_pal_cur  = tile_pal;
                        end
                        3'd1: begin
                            n_bus_addr  = nt_addr(n_v);
                            n_tile_addr = {ctrl[4], vrdata, 1'b0, n_v[14:12]};
                        end
                        3'd3: begin
                            n_bus_addr = at_addr(n_v);
                            n_tile_pal = 2'(vrdata >> {n_v[6], n_v[1], 1'b0});
                        end
                        3'd5: begin
                            n_bus_addr = {1'b0, tile_addr};
                            n_tile_lo  = vrdata;
                        end
                        3'd7: begin
                            n_bus_addr = {1'b0, tile_addr | 13'd8};
                            n_tile_hi  = vrdata;
                        end
                        default: ;
                    endcase
                end else if (pre && cd == 9'd1)
                    n_vbl = 1'b0;
            end else if (cd <= 9'd320) begin
                // ---- Dots 257-320: sprite fetches ----
                if (ren_prev) begin
                    n_s0_vis   = s0_added;
                    n_oamaddr  = '0;
                    slot = 3'((cd - 9'd257) >> 3);
                    case (3'(cd - 9'd257))
                        3'd0, 3'd2: n_bus_addr = nt_addr(n_v);
                        3'd4: begin
                            sy    = sec[{slot, 2'd0}];
                            stile = sec[{slot, 2'd1}];
                            sattr = sec[{slot, 2'd2}];
                            diff  = {1'b0, pre ? 8'd5 : cl[7:0]} - {1'b0, sy};
                            rr    = diff[3:0] ^ (sattr[7] ? (ctrl[5] ? 4'd15 : 4'd7) : 4'd0);
                            if (ctrl[5])
                                sa = {stile[0], stile[7:1], rr[3], 1'b0, rr[2:0]};
                            else
                                sa = {ctrl[3], stile, 1'b0, rr[2:0]};
                            n_sp_addr  = sa;
                            n_sp_attr  = sattr;
                            n_sp_x     = sec[{slot, 2'd3}];
                            n_sp_in    = !diff[8] && diff[7:0] <= (ctrl[5] ? 8'd15 : 8'd7);
                            n_bus_addr = {1'b0, sa};
                            n_sp_lo    = vrdata;
                        end
                        3'd6: begin
                            n_bus_addr = {1'b0, sp_addr | 13'd8};
                            sl_we = 1'b1;
                            sl_wa = slot;
                        end
                        default: ;
                    endcase
                    if (pre && cd >= 9'd280 && cd <= 9'd304)
                        n_v = {t[14:11], n_v[10], t[9:5], n_v[4:0]};
                    if (((cd - 9'd1) & 9'd4) == 9'd0)
                        n_sec_addr = n_sec_addr + 8'd1;
                end
                if (cd == 9'd257) begin
                    sl_clear = 1'b1;
                    if (ren_prev) begin
                        n_v = {n_v[14:11], t[10], n_v[9:5], t[4:0]};
                        n_sec_addr = '0;
                    end
                end
            end else if (cd <= 9'd336) begin
                // ---- Dots 321-336: the next line's first two tiles ----
                if (ren_prev) begin
                    if (cd == 9'd321)
                        n_sec_addr = sec_addr + 8'd1;
                    else if (cd == 9'd328 || cd == 9'd336)
                        n_v = inc_h(n_v);
                    n_sh_lo = {sh_lo[14:0], 1'b0};
                    n_sh_hi = {sh_hi[14:0], 1'b1};
                    case (cd[2:0])
                        3'd0: begin
                            n_sh_hi    = {n_sh_hi[15:8], tile_hi};
                            n_sh_lo    = {n_sh_lo[15:8], tile_lo};
                            n_pal_prev = pal_cur;
                            n_pal_cur  = tile_pal;
                        end
                        3'd1: begin
                            n_bus_addr  = nt_addr(n_v);
                            n_tile_addr = {ctrl[4], vrdata, 1'b0, n_v[14:12]};
                        end
                        3'd3: begin
                            n_bus_addr = at_addr(n_v);
                            n_tile_pal = 2'(vrdata >> {n_v[6], n_v[1], 1'b0});
                        end
                        3'd5: begin
                            n_bus_addr = {1'b0, tile_addr};
                            n_tile_lo  = vrdata;
                        end
                        3'd7: begin
                            n_bus_addr = {1'b0, tile_addr | 13'd8};
                            n_tile_hi  = vrdata;
                        end
                        default: ;
                    endcase
                end
            end else if (cd == 9'd337 || cd == 9'd339) begin
                if (ren_cur) begin
                    n_bus_addr = nt_addr(n_v);
                    // The unused nametable fetches' byte: dot 0 puts its
                    // pattern address on the bus (below).
                    if (cd == 9'd339)
                        n_tile_addr = {ctrl[4], vrdata, 1'b0, n_v[14:12]};
                    if (cd == 9'd339 && pre && odd)
                        n_dot = 9'd340;  // the odd frame's skipped dot
                end
            end
        end else if (cd == 9'd1 && cl == 9'd241) begin
            if (!prevent)
                n_vbl = 1'b1;
            n_prevent = 1'b0;
        end

        // ---- End of the dot: delayed effects of register writes ----
        if (ren_prev != ren_cur) begin
            n_ren_prev = ren_cur;
            if ((cl < 9'd240 || cl == 9'd261) && !ren_cur) begin
                // Rendering just stopped mid-frame.
                n_bus_addr = n_v[13:0];
                if (cd >= 9'd65 && cd <= 9'd256)
                    n_oamaddr = n_oamaddr + 8'd1;
            end
        end
        n_ren_cur = mask[3] || mask[4];

        if (upd_delay != '0) begin
            n_upd_delay = upd_delay - 2'd1;
            if (upd_delay == 2'd1) begin
                n_v = upd_addr;
                n_t = upd_addr;
                if ((cl >= 9'd240 && cl <= 9'd260) || !n_ren_cur)
                    n_bus_addr = upd_addr[13:0];
            end
        end
        if (ign != '0)
            n_ign = ign - 3'd1;
        if (need_inc) begin
            n_need_inc = 1'b0;
            if ((cl >= 9'd240 && cl <= 9'd260) || !n_ren_cur) begin
                n_v = n_v + (ctrl[2] ? 15'd32 : 15'd1);
                n_bus_addr = n_v[13:0];
            end else
                n_v = inc_v(inc_h(n_v));
        end
        if (rd_sm != '0) begin
            n_rd_sm = rd_sm - 3'd1;
            if (rd_sm == 3'd1) begin
                n_fill     = 1'b1;
                n_need_inc = 1'b1;
            end
        end
        if (wr_sm != '0) begin
            n_wr_sm = wr_sm - 3'd1;
            if (wr_sm == 3'd1) begin
                if (n_bus_addr[13:8] == 6'h3F) begin
                    pal_we = 1'b1;
                    pal_wa = n_bus_addr[4:0];
                    pal_wd = {2'b0, wr_latch[5:0]};
                end else begin
                    n_vwe    = 1'b1;
                    n_vwdata = ((cl >= 9'd240 && cl <= 9'd260) || !n_ren_cur) ? wr_latch : n_bus_addr[7:0];
                end
                n_need_inc = 1'b1;
            end
        end

        // ---- The address for the next dot ----
        if (n_dot == 9'd340) begin
            nd = 9'd0;
            nl = cl == 9'd261 ? 9'd0 : cl + 9'd1;
        end else begin
            nd = n_dot + 9'd1;
            nl = cl;
        end
        // With rendering off (as the next dot will see it), the address is the
        // bus's: v, as MesenCE's PPU leaves it, so a mapper watching A12 sees
        // no fetches.
        n_vaddr = n_bus_addr;
        n_vread = n_fill;
        if (!n_fill && !n_vwe && n_ren_prev && (nl < 9'd240 || nl == 9'd261)) begin
            if ((nd >= 9'd1 && nd <= 9'd256) || (nd >= 9'd321 && nd <= 9'd336)) begin
                case (nd[2:0])
                    3'd1:    n_vaddr = nt_addr(n_v);
                    3'd3:    n_vaddr = at_addr(n_v);
                    3'd5:    begin n_vaddr = {1'b0, n_tile_addr}; n_vread = 1'b1; end
                    3'd7:    begin n_vaddr = {1'b0, n_tile_addr | 13'd8}; n_vread = 1'b1; end
                    default: ;
                endcase
            end else if (nd >= 9'd257 && nd <= 9'd320) begin
                slot = 3'((nd - 9'd257) >> 3);
                case (3'(nd - 9'd257))
                    3'd4: begin
                        n_vread = 1'b1;
                        sy    = sec[{slot, 2'd0}];
                        stile = sec[{slot, 2'd1}];
                        sattr = sec[{slot, 2'd2}];
                        diff  = {1'b0, nl == 9'd261 ? 8'd5 : nl[7:0]} - {1'b0, sy};
                        rr    = diff[3:0] ^ (sattr[7] ? (ctrl[5] ? 4'd15 : 4'd7) : 4'd0);
                        if (ctrl[5])
                            n_vaddr = {1'b0, stile[0], stile[7:1], rr[3], 1'b0, rr[2:0]};
                        else
                            n_vaddr = {1'b0, ctrl[3], stile, 1'b0, rr[2:0]};
                    end
                    3'd6:    begin n_vaddr = {1'b0, n_sp_addr | 13'd8}; n_vread = 1'b1; end
                    default: n_vaddr = nt_addr(n_v);
                endcase
            end else if (nd == 9'd337 || nd == 9'd339)
                n_vaddr = nt_addr(n_v);
            // Dot 0 of a visible line puts the pattern address of dot 339's
            // nametable byte on the bus, as MesenCE's PPU does (not on line 0
            // after the odd frame's skipped dot): with the background at
            // $1000, A12 rises there, so an MMC3 doesn't see it low from dot
            // 337 to dot 4 and count a second rise in the line.
            else if (nd == 9'd0 && nl < 9'd240 && (nl != 9'd0 || cd != 9'd339))
                n_vaddr = {1'b0, n_tile_addr};
        end
    end


    // ---- The next dot, registered ----
    // Everything a dot changes is computed every clock and registered here,
    // and a ce commits the registered copy: the dot logic gets the clocks
    // between dots instead of one. So its inputs (the state, the memories,
    // vrdata) must be settled the clock before each ce.
    typedef struct packed {
        logic        vbl, s0hit, ovf;
        logic [7:0]  oamaddr;
        logic [14:0] v, t;
        logic [7:0]  rdbuf, io;
        logic [23:0] io_age;
        logic        odd;
        logic [8:0]  dot, line;
        logic [15:0] sh_lo, sh_hi;
        logic [1:0]  pal_prev, pal_cur, tile_pal;
        logic [7:0]  tile_lo, tile_hi;
        logic [12:0] tile_addr;
        logic [7:0]  oam_buf, sec_addr;
        logic        in_range, copy_done, s0_added, s0_vis;
        logic [1:0]  ovf_cnt;
        logic [12:0] sp_addr;
        logic [7:0]  sp_attr, sp_x, sp_lo;
        logic        sp_in;
        logic        ren_cur, ren_prev, prevent;
        logic [2:0]  rd_sm, wr_sm, ign;
        logic        need_inc;
        logic [1:0]  upd_delay;
        logic [13:0] bus_addr;
        logic        fill;
        logic [5:0]  p1_c;
        logic        p1_v;
        logic [7:0]  p1_x, p1_y;
        logic [13:0] vaddr;
        logic        vread;
        logic        vwe;
        logic [7:0]  vwdata;
        logic        frame;
        logic        sec_we;
        logic [4:0]  sec_wa;
        logic [7:0]  sec_wd;
        logic        pal_we;
        logic [4:0]  pal_wa;
        logic [7:0]  pal_wd;
        logic        sl_we, sl_clear;
        logic [2:0]  sl_wa;
    } next_t;

    next_t nq;

    assign vaddr_next = nq.vaddr;
    assign vread_next = nq.vread;

    always_ff @(posedge clk)
        nq <= {n_vbl, n_s0hit, n_ovf, n_oamaddr, n_v, n_t, n_rdbuf, n_io, n_io_age, n_odd, n_dot, n_line,
                n_sh_lo, n_sh_hi, n_pal_prev, n_pal_cur, n_tile_pal, n_tile_lo, n_tile_hi, n_tile_addr,
                n_oam_buf, n_sec_addr, n_in_range, n_copy_done, n_s0_added, n_s0_vis, n_ovf_cnt,
                n_sp_addr, n_sp_attr, n_sp_x, n_sp_lo, n_sp_in, n_ren_cur, n_ren_prev, n_prevent,
                n_rd_sm, n_wr_sm, n_ign, n_need_inc, n_upd_delay, n_bus_addr, n_fill,
                n_p1_c, n_p1_v, n_p1_x, n_p1_y, n_vaddr, n_vread, n_vwe, n_vwdata, n_frame,
                sec_we, sec_wa, sec_wd, pal_we, pal_wa, pal_wd, sl_we, sl_clear, sl_wa};

    // ---- Register access: the next state if `reg_ce` ----
    logic [7:0]  r_ctrl, r_mask, r_oamaddr, r_io, r_rdata, r_oam_buf, r_wr_latch;
    logic        r_vbl, r_prevent, r_w;
    logic [14:0] r_t, r_upd_addr;
    logic [2:0]  r_fx, r_rd_sm, r_wr_sm, r_ign;
    logic [1:0]  r_upd_delay;
    logic [23:0] r_io_age;
    logic        oam_we;
    logic [7:0]  oam_wd;

    always_comb begin
        logic [7:0] ret, omask;

        r_ctrl = ctrl; r_mask = mask; r_oamaddr = oamaddr; r_io = io; r_io_age = io_age;
        r_oam_buf = oam_buf; r_wr_latch = wr_latch;
        r_vbl = vbl; r_prevent = prevent; r_w = w;
        r_t = t; r_upd_addr = upd_addr; r_fx = fx;
        r_rd_sm = rd_sm; r_wr_sm = wr_sm; r_ign = ign; r_upd_delay = upd_delay;
        oam_we = 1'b0; oam_wd = '0;
        ret = '0; omask = 8'hFF;

        if (reg_we) begin
            r_io = reg_wdata;
            r_io_age = '0;
            case (reg_addr)
                3'd0: begin
                    r_ctrl = reg_wdata;
                    r_t[11:10] = reg_wdata[1:0];
                end
                3'd1: r_mask = reg_wdata;
                3'd3: r_oamaddr = reg_wdata;
                3'd4:
                    if ((line >= 9'd240 && line <= 9'd260) || !ren_cur) begin
                        oam_we = 1'b1;
                        oam_wd = oamaddr[1:0] == 2'd2 ? reg_wdata & 8'hE3 : reg_wdata;
                        r_oamaddr = oamaddr + 8'd1;
                    end else
                        r_oamaddr = (oamaddr + 8'd4) & 8'hFC;
                3'd5: begin
                    if (w)
                        r_t = {reg_wdata[2:0], t[11:10], reg_wdata[7:3], t[4:0]};
                    else begin
                        r_fx = reg_wdata[2:0];
                        r_t[4:0] = reg_wdata[7:3];
                    end
                    r_w = !w;
                end
                3'd6: begin
                    if (w) begin
                        r_t[7:0] = reg_wdata;
                        r_upd_delay = 2'd3;
                        r_upd_addr = {t[14:8], reg_wdata};
                    end else
                        r_t[14:8] = {1'b0, reg_wdata[5:0]};
                    r_w = !w;
                end
                3'd7: begin
                    r_wr_sm = 3'd5;
                    r_wr_latch = reg_wdata;
                end
                default: ;
            endcase
            ret = reg_wdata;
        end else begin
            case (reg_addr)
                3'd2: begin
                    r_w = 1'b0;
                    ret = {vbl, s0hit, ovf, 5'b0};
                    r_vbl = 1'b0;
                    if (line == 9'd241 && dot == 9'd0)
                        r_prevent = 1'b1;
                    omask = 8'h1F;
                end
                3'd4: begin
                    if (rline && ren_cur) begin
                        if ((dot >= 9'd257 && dot <= 9'd340) || dot == 9'd0)
                            r_oam_buf = sec[sec_addr[4:0]];
                        ret = r_oam_buf;
                    end else
                        ret = oam_rd;
                    omask = 8'h00;
                end
                3'd7:
                    if (ign == '0) begin
                        ret = rdbuf;
                        r_rd_sm = 3'd5;
                        r_ign = 3'd6;
                        if (bus_addr[13:8] == 6'h3F) begin
                            ret = {io[7:6], pal[pal_ix(bus_addr[4:0])][5:0] & (mask[0] ? 6'h30 : 6'h3F)};
                            omask = 8'hC0;
                        end else
                            omask = 8'h00;
                    end
                default: ;
            endcase
            ret = ret | (io & omask);
            for (int i = 0; i < 8; i++)
                if (!omask[i]) begin
                    r_io[i] = ret[i];
                    r_io_age[3*i +: 3] = '0;
                end
        end
        r_rdata = ret;
    end

    // ---- Save-state packing of the registers ----
    localparam int RW = 13;  // register words
    logic [32*RW-1:0] sv;
    assign sv = {
        // 88
        ctrl, mask, oamaddr, rdbuf,
        // 89
        v, t, w, 1'b0,
        // 90
        io, io_age,
        // 91
        dot, line, fx, ign, odd, vbl, s0hit, ovf, ren_cur, ren_prev, prevent, fill,
        // 92
        sh_lo, sh_hi,
        // 93
        tile_lo, tile_hi, pal_prev, pal_cur, tile_pal, need_inc, 9'b0,
        // 94
        oam_buf, sec_addr, in_range, copy_done, s0_added, s0_vis, ovf_cnt, sp_in, 1'b0, sp_x,
        // 95
        sp_addr, sp_attr, sp_lo, 3'b0,
        // 96
        rd_sm, wr_sm, wr_latch, upd_delay, upd_addr, 1'b0,
        // 97
        bus_addr, vaddr, vwe, 3'b0,
        // 98
        vwdata, p1_c, p1_v, p2_c, p2_v, 10'b0,
        // 99
        p1_x, p1_y, p2_x, p2_y,
        // 100
        tile_addr, 19'b0
    };

    logic [32*RW-1:0] sv_w;
    always_comb begin
        sv_w = sv;
        for (int i = 0; i < RW; i++)
            if (st_addr == 7'(88 + i))
                sv_w[32*(RW-1-i) +: 32] = st_wdata;
    end

    // ---- Registers ----
    always_ff @(posedge clk) begin
        pix_valid <= 1'b0;
        frame_end <= 1'b0;

        if (rst) begin
            ctrl <= '0; mask <= '0;
            vbl <= 1'b0; s0hit <= 1'b0; ovf <= 1'b0;
            oamaddr <= '0;
            v <= '0; t <= '0; fx <= '0; w <= 1'b0;
            rdbuf <= '0;
            io <= '0;
            io_age <= {8{3'd1}};
            odd <= 1'b1;
            dot <= 9'd340; line <= 9'd261;
            sh_lo <= '0; sh_hi <= '0;
            pal_prev <= '0; pal_cur <= '0; tile_pal <= '0;
            tile_lo <= '0; tile_hi <= '0; tile_addr <= '0;
            oam_buf <= '0; sec_addr <= '0;
            in_range <= 1'b0; copy_done <= 1'b0; s0_added <= 1'b0; s0_vis <= 1'b0;
            ovf_cnt <= '0;
            sp_addr <= '0; sp_attr <= '0; sp_x <= '0; sp_in <= 1'b0; sp_lo <= '0;
            ren_cur <= 1'b0; ren_prev <= 1'b0; prevent <= 1'b0;
            rd_sm <= '0; wr_sm <= '0; wr_latch <= '0; need_inc <= 1'b0; ign <= '0;
            upd_delay <= '0; upd_addr <= '0;
            bus_addr <= '0; fill <= 1'b0;
            p1_c <= '0; p1_v <= 1'b0; p2_c <= '0; p2_v <= 1'b0;
            p1_x <= '0; p1_y <= '0; p2_x <= '0; p2_y <= '0;
            vaddr <= '0; vwe <= 1'b0; vwdata <= '0;
            reg_rdata <= '0;
            sl_valid <= '0;
        end else if (SAVE_STATE && st_we) begin
            if (st_addr >= 7'd88)
                {ctrl, mask, oamaddr, rdbuf,
                 v, t, w, sv_pad[0],
                 io, io_age,
                 dot, line, fx, ign, odd, vbl, s0hit, ovf, ren_cur, ren_prev, prevent, fill,
                 sh_lo, sh_hi,
                 tile_lo, tile_hi, pal_prev, pal_cur, tile_pal, need_inc, sv_pad[9:1],
                 oam_buf, sec_addr, in_range, copy_done, s0_added, s0_vis, ovf_cnt, sp_in, sv_pad[10], sp_x,
                 sp_addr, sp_attr, sp_lo, sv_pad[13:11],
                 rd_sm, wr_sm, wr_latch, upd_delay, upd_addr, sv_pad[14],
                 bus_addr, vaddr, vwe, sv_pad[17:15],
                 vwdata, p1_c, p1_v, p2_c, p2_v, sv_pad[27:18],
                 p1_x, p1_y, p2_x, p2_y,
                 tile_addr, sv_pad[46:28]} <= sv_w;
            else if (st_addr >= 7'd80)
                {sl_lo[st_addr[2:0]], sl_hi[st_addr[2:0]], sl_x[st_addr[2:0]],
                 sl_valid[st_addr[2:0]], sl_pri[st_addr[2:0]], sl_pal[st_addr[2:0]]} <= st_wdata[31:4];
        end else if (ce) begin
            vbl <= nq.vbl; s0hit <= nq.s0hit; ovf <= nq.ovf;
            oamaddr <= nq.oamaddr;
            v <= nq.v; t <= nq.t;
            rdbuf <= nq.rdbuf; io <= nq.io; io_age <= nq.io_age;
            odd <= nq.odd;
            dot <= nq.dot; line <= nq.line;
            sh_lo <= nq.sh_lo; sh_hi <= nq.sh_hi;
            pal_prev <= nq.pal_prev; pal_cur <= nq.pal_cur; tile_pal <= nq.tile_pal;
            tile_lo <= nq.tile_lo; tile_hi <= nq.tile_hi; tile_addr <= nq.tile_addr;
            oam_buf <= nq.oam_buf; sec_addr <= nq.sec_addr;
            in_range <= nq.in_range; copy_done <= nq.copy_done; s0_added <= nq.s0_added; s0_vis <= nq.s0_vis;
            ovf_cnt <= nq.ovf_cnt;
            sp_addr <= nq.sp_addr; sp_attr <= nq.sp_attr; sp_x <= nq.sp_x; sp_in <= nq.sp_in;
            ren_cur <= nq.ren_cur; ren_prev <= nq.ren_prev; prevent <= nq.prevent;
            rd_sm <= nq.rd_sm; wr_sm <= nq.wr_sm; ign <= nq.ign; need_inc <= nq.need_inc;
            upd_delay <= nq.upd_delay;
            bus_addr <= nq.bus_addr; fill <= nq.fill;
            vaddr <= nq.vaddr; vwe <= nq.vwe; vwdata <= nq.vwdata;
            frame_end <= nq.frame;
            sp_lo <= nq.sp_lo;

            // The pixel pipeline: grayscale and emphasis apply two dots after drawing.
            pix_valid <= p2_v;
            pix       <= {mask[7:5], p2_c & (mask[0] ? 6'h30 : 6'h3F)};
            pix_x     <= p2_x;
            pix_y     <= p2_y;
            p2_c <= p1_c; p2_v <= p1_v; p2_x <= p1_x; p2_y <= p1_y;
            p1_c <= nq.p1_c; p1_v <= nq.p1_v; p1_x <= nq.p1_x; p1_y <= nq.p1_y;

            if (nq.sl_clear)
                sl_valid <= '0;
            if (nq.sl_we) begin
                sl_lo[nq.sl_wa]    <= sp_in ? (sp_attr[6] ? rev8(sp_lo) : sp_lo) : 8'h00;
                sl_hi[nq.sl_wa]    <= sp_in ? (sp_attr[6] ? rev8(vrdata) : vrdata) : 8'h00;
                sl_x[nq.sl_wa]     <= sp_x;
                sl_pri[nq.sl_wa]   <= sp_attr[5];
                sl_pal[nq.sl_wa]   <= sp_attr[1:0];
                sl_valid[nq.sl_wa] <= sp_in;
            end
        end else if (reg_ce) begin
            ctrl <= r_ctrl; mask <= r_mask; oamaddr <= r_oamaddr;
            io <= r_io; io_age <= r_io_age;
            oam_buf <= r_oam_buf; wr_latch <= r_wr_latch;
            vbl <= r_vbl; prevent <= r_prevent; w <= r_w;
            t <= r_t; upd_addr <= r_upd_addr; fx <= r_fx;
            rd_sm <= r_rd_sm; wr_sm <= r_wr_sm; ign <= r_ign; upd_delay <= r_upd_delay;
            reg_rdata <= r_rdata;
        end
    end

    // Padding bits of the register words.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [46:0] sv_pad;
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- Memories ----
    always_ff @(posedge clk) begin
        // OAM: $2004 writes, or the save-state port.
        if (st_we && st_addr < 7'd64)
            oam[st_addr[5:0]] <= st_wdata;
        else if (reg_ce && oam_we) begin
            logic [31:0] wv;
            wv = oam[oamaddr[7:2]];
            wv[8*oamaddr[1:0] +: 8] = oam_wd;
            oam[oamaddr[7:2]] <= wv;
        end

        if (rst) begin
            // MesenCE's power-up palette (blargg's power_up_palette values).
            pal[0]  <= 8'h09; pal[1]  <= 8'h01; pal[2]  <= 8'h00; pal[3]  <= 8'h01;
            pal[4]  <= 8'h00; pal[5]  <= 8'h02; pal[6]  <= 8'h02; pal[7]  <= 8'h0D;
            pal[8]  <= 8'h08; pal[9]  <= 8'h10; pal[10] <= 8'h08; pal[11] <= 8'h24;
            pal[12] <= 8'h00; pal[13] <= 8'h00; pal[14] <= 8'h04; pal[15] <= 8'h2C;
            pal[16] <= 8'h09; pal[17] <= 8'h01; pal[18] <= 8'h34; pal[19] <= 8'h03;
            pal[20] <= 8'h00; pal[21] <= 8'h04; pal[22] <= 8'h00; pal[23] <= 8'h14;
            pal[24] <= 8'h08; pal[25] <= 8'h3A; pal[26] <= 8'h00; pal[27] <= 8'h02;
            pal[28] <= 8'h00; pal[29] <= 8'h20; pal[30] <= 8'h2C; pal[31] <= 8'h08;
            for (int i = 0; i < 32; i++)
                sec[i] <= '0;
        end else if (SAVE_STATE && st_we && st_addr >= 7'd64 && st_addr < 7'd72) begin
            for (int i = 0; i < 4; i++)
                pal[{st_addr[2:0], 2'(i)}] <= st_wdata[8*i +: 8];
        end else if (SAVE_STATE && st_we && st_addr >= 7'd72 && st_addr < 7'd80) begin
            for (int i = 0; i < 4; i++)
                sec[{st_addr[2:0], 2'(i)}] <= st_wdata[8*i +: 8];
        end else if (ce) begin
            if (nq.pal_we) begin
                // $3F00/$3F10 and the like are one entry, written in both places.
                if (nq.pal_wa[1:0] == 2'b00) begin
                    pal[{1'b0, nq.pal_wa[3:0]}] <= nq.pal_wd;
                    pal[{1'b1, nq.pal_wa[3:0]}] <= nq.pal_wd;
                end else
                    pal[nq.pal_wa] <= nq.pal_wd;
            end
            if (nq.sec_we)
                sec[nq.sec_wa] <= nq.sec_wd;
        end
    end

    // ---- Save-state reads ----
    always_ff @(posedge clk) begin
        if (st_addr < 7'd64)
            st_rdata <= oam[st_addr[5:0]];
        else if (st_addr < 7'd72)
            st_rdata <= {pal[{st_addr[2:0], 2'd3}], pal[{st_addr[2:0], 2'd2}], pal[{st_addr[2:0], 2'd1}], pal[{st_addr[2:0], 2'd0}]};
        else if (st_addr < 7'd80)
            st_rdata <= {sec[{st_addr[2:0], 2'd3}], sec[{st_addr[2:0], 2'd2}], sec[{st_addr[2:0], 2'd1}], sec[{st_addr[2:0], 2'd0}]};
        else if (st_addr < 7'd88)
            st_rdata <= {sl_lo[st_addr[2:0]], sl_hi[st_addr[2:0]], sl_x[st_addr[2:0]],
                         sl_valid[st_addr[2:0]], sl_pri[st_addr[2:0]], sl_pal[st_addr[2:0]], 4'b0};
        else if (st_addr < 7'(88 + RW))
            st_rdata <= sv[32*(RW-1-(32'(st_addr) - 88)) +: 32];
        else
            st_rdata <= '0;
        if (!SAVE_STATE)
            st_rdata <= '0;
    end
endmodule
