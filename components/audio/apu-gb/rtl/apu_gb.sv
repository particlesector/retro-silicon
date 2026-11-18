// SPDX-License-Identifier: Apache-2.0
// The Game Boy's APU: two pulse channels (the first with a frequency sweep),
// the wave channel and the noise channel, their length counters and volume
// envelopes, the frame sequencer that clocks those, and the registers at
// $FF10-$FF3F. The output is each channel's 4-bit level and its DAC's state,
// and the two mixes NR50 and NR51 make of them.
//
// Time runs in the APU's 2 MHz ticks (`t2`, every other T-cycle): a pulse
// channel's frequency timer counts two a duty step, the wave channel's one a
// sample, and the noise channel's counter one a step of its divisor. The
// frame sequencer steps on `fs`, the system counter's bit 12 falling (512 Hz,
// or sooner after a DIV write): the lengths on its odd steps, the sweep on
// steps 3 and 7. The envelopes count on step 7; one whose count has run out
// reloads it as the bit rises again (`fs_rise`, half a step on) and changes
// its volume on the next step, unless it's at the end of its range (0 going
// down, 15 going up), when it stops until the channel is triggered again. A
// register write (`wr`) lands on its own clock, never with `t2` or `fs`.
//
// With CGB clear (the default) it's the DMG's: the length counters take
// writes while the APU is off (and keep them through power-on); wave RAM is
// reachable while the wave channel plays only in the tick it read a byte
// (else reads give $FF and writes are lost); retriggering the wave channel
// as it reads copies the bytes it was about to read over wave RAM's first;
// and a pulse channel's timer runs on after its length or sweep stops it,
// until its DAC goes off.
module apu_gb #(
    parameter bit CGB = 1'b0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        t2,         // a 2 MHz tick
    input  logic        fs,         // the frame sequencer's clock: the system counter's bit 12 falls
    input  logic        fs_rise,    // ...and rises
    input  logic        div_b12,    // that bit now (powering on with it set skips the next fs)

    input  logic        wr,         // a CPU write lands
    input  logic [5:0]  sel,        // ...at $FF10 + sel
    input  logic [7:0]  wdata,
    input  logic [5:0]  rsel,       // a CPU read of $FF10 + rsel
    output logic [7:0]  rdata,      // ...as the CPU reads it now

    output logic [15:0] levels,     // the channels' digital levels, channel 4 to 1 (0 when not playing)
    output logic [3:0]  dac,        // the channels' DACs are on, channel 4 to 1
    output logic [7:0]  nr50,
    output logic [7:0]  nr51,
    output logic signed [9:0] mix_l, // the DACs' outputs panned by NR51 and scaled by NR50
    output logic signed [9:0] mix_r
);
    // ---- the registers as written ----
    logic [7:0] nr10, nr11, nr12, nr13, nr14, nr21, nr22, nr23, nr24;
    logic [7:0] nr30, nr32, nr33, nr34, nr42, nr43, nr44, r50, r51;
    logic       on;
    logic [7:0] wave [16];

    // ---- state ----
    logic [2:0]  fs_step;            // the frame sequencer's last step
    logic        fs_skip;
    logic        lf;                 // the 1 MHz phase: toggles each tick
    logic [1:0]  al;                 // ticks since power-on, mod 4 (even at every CPU write)

    // the pulse channels: playing, timer running, silent until its first step,
    // the duty bit, the timer just reloaded, length enabled
    logic [1:0]  sq_act, sq_run, sq_supp, sq_duty, sq_just, sq_lenen;
    logic [6:0]  sq_len [2];
    logic [12:0] sq_cd [2];
    logic [2:0]  sq_pos [2];

    // channel 1's sweep
    logic [10:0] sw_shadow;
    logic [3:0]  sw_t;
    logic        sw_en, sw_negused;

    // the wave channel
    logic        wv_act, wv_lenen, wv_just;
    logic [8:0]  wv_len;
    logic [11:0] wv_cd;
    logic [4:0]  wv_pos;
    logic [7:0]  wv_buf;

    // the noise channel
    logic        ns_act, ns_lenen;
    logic [6:0]  ns_len;
    logic [14:0] ns_lfsr;
    logic [13:0] ns_cnt;
    logic [5:0]  ns_cd;
    // the noise counter counts while the channel's DAC was on at its trigger (ns_on) or, on the
    // DMG, from any trigger until its DAC goes off (ns_bg); its LFSR's feedback is latched as the
    // counter's bit falls (ns_fbl) and shifted in as it rises; a trigger off the 1 MHz phase waits
    // 6 ticks (ns_dly, then ns_go)
    logic        ns_on, ns_bg, ns_dacoff, ns_did, ns_fbl, ns_go;
    logic [2:0]  ns_dly;

    // the envelopes, channels 1, 2 and 4: the volume, the count to the next change, armed to
    // change at the next step, stopped, and whether it stops at that change (its volume is at the
    // end of its range)
    logic [3:0]  env_v [3];
    logic [2:0]  env_cd [3];
    logic [2:0]  env_clk, env_lock, env_end;

    // ---- small functions ----
    function automatic logic duty_bit(input logic [1:0] d, input logic [2:0] p);
        case (d)
            2'd0: duty_bit = p == 3'd7;
            2'd1: duty_bit = p == 3'd0 || p == 3'd7;
            2'd2: duty_bit = p == 3'd0 || p >= 3'd5;
            default: duty_bit = p != 3'd0 && p != 3'd7;
        endcase
    endfunction

    // A pulse timer's reload, in ticks: (2047 - frequency) x 2 + 1, so a step every 2 x (2048 - frequency).
    function automatic logic [12:0] sq_reload(input logic [10:0] f);
        sq_reload = {1'b0, ~f, 1'b1};
    endfunction

    // The noise counter's divisor, in ticks.
    function automatic logic [5:0] ns_div(input logic [2:0] r);
        ns_div = r == 3'd0 ? 6'd2 : {1'b0, r, 2'b00};
    endfunction

    // A length counter after an NRx4 write (`w`: its bits 7 and 6): a trigger with a length of 0
    // loads the full length; enabling the length while the next frame step
    // won't clock lengths (`half`) clocks it once, and if that empties it the
    // channel stops, unless the same write triggers it: then it's full less
    // one. Gives {stop, length}.
    function automatic logic [9:0] len_wr(input logic [8:0] l, input logic en, input logic [1:0] w,
                                         input logic half, input logic [8:0] full);
        logic [8:0] n;
        logic       e, stop;
        n    = w[1] && l == 0 ? full : l;
        e    = en && !(w[1] && l == 0);
        stop = 1'b0;
        if (w[0] && !e && half && n != 0) begin
            n = n - 9'd1;
            if (n == 0) begin
                if (w[1]) n = full - 9'd1;
                else stop = 1'b1;
            end
        end
        len_wr = {stop, n};
    endfunction

    wire [10:0] sq_f0  = {nr14[2:0], nr13};
    wire [10:0] sq_f1  = {nr24[2:0], nr23};
    wire [10:0] wv_f   = {nr34[2:0], nr33};
    wire [3:0]  dac_on = {nr42[7:3] != 0, nr30[7], nr22[7:3] != 0, nr12[7:3] != 0};
    wire        len_half = fs_step[0];   // the last step clocked the lengths; the next won't

    // The sweep's next frequency from the shadow; over 2047 stops channel 1.
    wire [10:0] sw_delta = sw_shadow >> nr10[2:0];
    wire [11:0] sw_next  = nr10[3] ? {1'b0, sw_shadow} - {1'b0, sw_delta} : {1'b0, sw_shadow} + {1'b0, sw_delta};
    wire [11:0] sw_check = {1'b0, sw_next[10:0]} + {1'b0, sw_next[10:0] >> nr10[2:0]};

    // An NRx4 write's channel and length.
    wire        sq_c    = sel == 6'h09;
    wire [10:0] sq_wf   = {wdata[2:0], sq_c ? nr23 : nr13};
    wire [7:0]  sq_nrx2 = sq_c ? nr22 : nr12;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [9:0]  sq_lw   = len_wr({2'b00, sq_len[sq_c]}, sq_lenen[sq_c], wdata[7:6], len_half, 9'd64);
    wire [9:0]  ns_lw   = len_wr({2'b00, ns_len}, ns_lenen, {wdata[7] && !ns_late, wdata[6]}, len_half, 9'd64);
    wire [9:0]  ns_lw2  = len_wr({2'b00, ns_len}, ns_lenen, {1'b1, nr44[6]}, len_half, 9'd64);
    /* verilator lint_on UNUSEDSIGNAL */
    wire [9:0]  wv_lw   = len_wr(wv_len, wv_lenen, wdata[7:6], len_half, 9'd256);
    wire [11:0] sq_trig_chk = {1'b0, sq_wf} + {1'b0, sq_wf >> nr10[2:0]};

    wire [4:0]  wv_pos1 = wv_pos + 5'd1;
    wire [3:0]  wv_off  = wv_pos1[4:1];  // the byte the wave channel reads next

    // The noise counter's next count, and whether NR43's bit of it rises or falls (14 and 15 never do).
    wire [13:0] ns_cnt1 = ns_cnt + 14'd1;
    wire        ns_bit  = nr43[7:4] < 4'd14 && ns_cnt[nr43[7:4]];
    wire        ns_bit1 = nr43[7:4] < 4'd14 && ns_cnt1[nr43[7:4]];
    wire        ns_fb   = ~(ns_lfsr[0] ^ ns_lfsr[1]);
    wire [5:0]  ns_cde  = ns_cd == 0 ? ns_div(nr43[2:0]) : ns_cd;   // a count of 0 reloads first
    wire        ns_dac  = nr42[7:3] != 0;
    wire        ns_late = !CGB && al[1];                         // a trigger now waits 6 ticks

    // A trigger's start (on the 1 MHz phase): the counter's count to its next step, depending on the
    // divisor and on whether it was counting already; a count about to step steps at once.
    logic [5:0]  ns_scd;
    logic [13:0] ns_scnt;
    logic        ns_sstep;
    always_comb begin
        logic [3:0] rr;
        logic       d1g;
        rr = {1'b0, nr43[2:0]};
        d1g = 1'b0;
        ns_scnt  = ns_cnt;
        ns_sstep = 1'b0;
        if (nr43[2:0] > 3'd1 && ns_cd == 6'd1)
            ns_scnt = ns_cnt1;
        else if (ns_cd == 6'd2 && ns_act) begin
            if (nr43[2:0] == 3'd0) rr = 4'd8;
            else if (nr43[2:0] == 3'd1) begin
                d1g      = !ns_did;
                ns_scnt  = ns_cnt1;
                ns_sstep = !ns_bit && ns_bit1;
            end
        end
        ns_scd = rr == 0 ? 6'd6 : {rr, 2'b00} + 6'd6;
        if (rr > 4'd1) ns_scd = ns_scd - 6'd4;
        else if (rr == 4'd1 && ns_act && nr43[7:4] == 0) ns_scd = ns_scd - 6'd4;
        if (rr > 4'd1) begin
            if (!ns_dac) ns_scd = ns_scd + 6'd4;
        end else if (ns_bg && !ns_act) begin
            if (rr == 0) begin
                if (ns_dacoff) ns_scd = ns_scd + 6'd28;
            end else
                ns_scd = ns_scd - 6'd4;
        end
        if (d1g) ns_scd = ns_scd - 6'd4;
    end

    wire [3:0]  env_nrx2 [3];
    assign env_nrx2[0] = nr12[3:0];
    assign env_nrx2[1] = nr22[3:0];
    assign env_nrx2[2] = nr42[3:0];
    wire [2:0]  env_act = {ns_act, sq_act[1], sq_act[0]};

    // ---- outputs ----
    wire [1:0] wv_vol = nr32[6:5];
    wire [3:0] wv_nib = wv_pos[0] ? wv_buf[3:0] : wv_buf[7:4];
    logic [3:0] lv [4];
    always_comb begin
        for (int i = 0; i < 2; i++)
            lv[i] = sq_act[i] && !sq_supp[i] && sq_duty[i] ? env_v[i] : 4'd0;
        lv[2] = !wv_act || wv_vol == 2'd0 ? 4'd0 : wv_nib >> (wv_vol - 2'd1);
        lv[3] = ns_act && ns_lfsr[0] ? env_v[2] : 4'd0;
    end
    assign levels = {lv[3], lv[2], lv[1], lv[0]};
    assign dac    = on ? dac_on : 4'd0;
    assign nr50   = r50;
    assign nr51   = r51;

    // The DACs: level 0 gives +15, 15 gives -15 (Pan Docs: digital 0 is analog
    // 1, 15 is -1), an off DAC 0. NR51 pans them, NR50 scales each side by 1 to 8.
    logic signed [6:0] sum_l, sum_r;
    logic signed [6:0] d [4];
    always_comb begin
        sum_l = '0;
        sum_r = '0;
        for (int i = 0; i < 4; i++) begin
            d[i] = dac[i] ? 7'sd15 - 7'(signed'({3'd0, lv[i]})) - 7'(signed'({3'd0, lv[i]})) : 7'sd0;
            if (r51[i + 4]) sum_l = sum_l + d[i];
            if (r51[i])     sum_r = sum_r + d[i];
        end
        mix_l = 10'(sum_l) * 10'(signed'({2'b00, r50[6:4]} + 5'd1));
        mix_r = 10'(sum_r) * 10'(signed'({2'b00, r50[2:0]} + 5'd1));
    end

    // ---- reads ----
    always_comb begin
        rdata = 8'hFF;
        case (rsel)
            6'h00: rdata = nr10 | 8'h80;
            6'h01: rdata = nr11 | 8'h3F;
            6'h02: rdata = nr12;
            6'h04: rdata = nr14 | 8'hBF;
            6'h06: rdata = nr21 | 8'h3F;
            6'h07: rdata = nr22;
            6'h09: rdata = nr24 | 8'hBF;
            6'h0A: rdata = nr30 | 8'h7F;
            6'h0C: rdata = nr32 | 8'h9F;
            6'h0E: rdata = nr34 | 8'hBF;
            6'h11: rdata = nr42;
            6'h12: rdata = nr43;
            6'h13: rdata = nr44 | 8'hBF;
            6'h14: rdata = r50;
            6'h15: rdata = r51;
            6'h16: rdata = {on, 3'b111, ns_act, wv_act, sq_act[1], sq_act[0]};
            default: ;
        endcase
        if (rsel >= 6'h20) begin
            if (!wv_act) rdata = wave[rsel[3:0]];
            else if (CGB || wv_just) rdata = wave[wv_pos[4:1]];
        end
    end

    // A noise trigger's start.
    task automatic ns_start();
        ns_cd     <= ns_scd;
        ns_cnt    <= ns_scnt;
        ns_lfsr   <= ns_sstep ? {1'b1, 7'd0, nr43[3], 6'd0} : 15'd0;
        ns_fbl    <= 1'b0;
        ns_did    <= 1'b0;
        env_v[2]  <= nr42[7:4];
        env_cd[2] <= nr42[2:0];
        ns_on     <= ns_dac;
        ns_bg     <= 1'b1;
        ns_dacoff <= !ns_dac;
        if (ns_dac) ns_act <= 1'b1;
    endtask

    always_ff @(posedge clk) begin
        if (rst || (wr && sel == 6'h16 && !wdata[7] && on)) begin
            // reset, or power off: every register but wave RAM clears, and all the state
            on <= 1'b0;
            nr10 <= '0;
            nr11 <= '0;
            nr12 <= '0;
            nr13 <= '0;
            nr14 <= '0;
            nr21 <= '0;
            nr22 <= '0;
            nr23 <= '0;
            nr24 <= '0;
            nr30 <= '0;
            nr32 <= '0;
            nr33 <= '0;
            nr34 <= '0;
            nr42 <= '0;
            nr43 <= '0;
            nr44 <= '0;
            r50 <= '0;
            r51 <= '0;
            fs_step <= '0;
            fs_skip <= 1'b0;
            lf <= 1'b1;
            sq_act <= '0;
            sq_run <= '0;
            sq_supp <= '0;
            sq_duty <= '0;
            sq_just <= '0;
            sq_lenen <= '0;
            env_clk <= '0;
            env_lock <= '0;
            env_end <= '0;
            for (int e = 0; e < 3; e++) begin
                env_v[e] <= '0;
                env_cd[e] <= '0;
            end
            for (int i = 0; i < 2; i++) begin
                sq_len[i] <= '0; sq_cd[i] <= '0; sq_pos[i] <= '0;
            end
            sw_shadow <= '0;
            sw_t <= '0;
            sw_en <= '0;
            sw_negused <= '0;
            wv_act <= '0;
            wv_lenen <= '0;
            wv_just <= '0;
            wv_len <= '0;
            wv_cd <= '0;
            wv_pos <= '0;
            wv_buf <= '0;
            ns_act <= '0;
            ns_lenen <= '0;
            ns_len <= '0;
            ns_lfsr <= '0;
            ns_cnt <= '0;
            ns_cd <= '0;
            {ns_on, ns_bg, ns_dacoff, ns_did, ns_fbl, ns_go} <= '0;
            ns_dly <= '0;
            al <= '0;
        end else begin
            // ---- the 2 MHz tick ----
            if (t2 && on) begin
                lf <= !lf;
                al <= al + 2'd1;
                for (int i = 0; i < 2; i++) begin
                    sq_just[i] <= 1'b0;
                    if (sq_act[i] || (!CGB && sq_run[i])) begin
                        if (sq_cd[i] == 0) begin
                            sq_cd[i]   <= sq_reload(i == 0 ? sq_f0 : sq_f1);
                            sq_pos[i]  <= sq_pos[i] + 3'd1;
                            sq_duty[i] <= duty_bit(i == 0 ? nr11[7:6] : nr21[7:6], sq_pos[i] + 3'd1);
                            sq_supp[i] <= 1'b0;
                            sq_just[i] <= 1'b1;
                        end else
                            sq_cd[i] <= sq_cd[i] - 13'd1;
                    end
                end
                wv_just <= 1'b0;
                if (wv_act) begin
                    if (wv_cd == 0) begin
                        wv_cd   <= {1'b0, ~wv_f};
                        wv_pos  <= wv_pos1;
                        wv_buf  <= wave[wv_off];
                        wv_just <= 1'b1;
                    end else
                        wv_cd <= wv_cd - 12'd1;
                end
                if (ns_on || (!CGB && ns_bg)) begin
                    if (ns_cde == 6'd1) begin
                        ns_cd  <= ns_div(nr43[2:0]);
                        ns_cnt <= ns_cnt1;
                        ns_did <= 1'b1;
                        if (ns_act && ns_bit && !ns_bit1) ns_fbl <= ns_fb;
                        if (ns_act && !ns_bit && ns_bit1) begin
                            ns_lfsr <= {CGB ? ns_fb : ns_fbl, ns_lfsr[14:1]};
                            if (nr43[3]) ns_lfsr[6] <= CGB ? ns_fb : ns_fbl;
                        end
                    end else
                        ns_cd <= ns_cde - 6'd1;
                end
                if (ns_dly != 0) begin
                    ns_dly <= ns_dly - 3'd1;
                    if (ns_dly == 3'd1) ns_go <= 1'b1;
                end
            end

            // ---- the frame sequencer ----
            if (fs && on) begin
                if (fs_skip)
                    fs_skip <= 1'b0;
                else begin
                    fs_step <= fs_step + 3'd1;
                    if (!fs_step[0]) begin          // to an odd step: the lengths
                        for (int i = 0; i < 2; i++)
                            if (sq_lenen[i] && sq_len[i] != 0) begin
                                sq_len[i] <= sq_len[i] - 7'd1;
                                if (sq_len[i] == 7'd1) sq_act[i] <= 1'b0;
                            end
                        if (wv_lenen && wv_len != 0) begin
                            wv_len <= wv_len - 9'd1;
                            if (wv_len == 9'd1) wv_act <= 1'b0;
                        end
                        if (ns_lenen && ns_len != 0) begin
                            ns_len <= ns_len - 7'd1;
                            if (ns_len == 7'd1) ns_act <= 1'b0;
                        end
                    end
                    if (fs_step[1:0] == 2'd2) begin  // to step 3 or 7: the sweep
                        if (sw_t > 4'd1)
                            sw_t <= sw_t - 4'd1;
                        else begin
                            sw_t <= nr10[6:4] == 0 ? 4'd8 : {1'b0, nr10[6:4]};
                            if (sw_en && nr10[6:4] != 0) begin
                                if (nr10[3]) sw_negused <= 1'b1;
                                if (sw_next > 12'h7FF)
                                    sq_act[0] <= 1'b0;
                                else if (nr10[2:0] != 0) begin
                                    sw_shadow <= sw_next[10:0];
                                    nr13      <= sw_next[7:0];
                                    nr14[2:0] <= sw_next[10:8];
                                    // and the check again with the new frequency, which isn't written
                                    if (!nr10[3] && sw_check > 12'h7FF) sq_act[0] <= 1'b0;
                                end
                            end
                        end
                    end
                    // the envelopes: those not armed count on step 7; those armed change, or stop
                    for (int e = 0; e < 3; e++) begin
                        if (!env_clk[e]) begin
                            if (fs_step == 3'd6) env_cd[e] <= env_cd[e] - 3'd1;
                        end else begin
                            env_clk[e] <= 1'b0;
                            if (env_end[e]) env_lock[e] <= 1'b1;
                            else if (!env_lock[e] && env_nrx2[e][2:0] != 0)
                                env_v[e] <= env_nrx2[e][3] ? env_v[e] + 4'd1 : env_v[e] - 4'd1;
                        end
                    end
                end
            end

            // ---- a noise trigger that waited ----
            if (ns_go) begin
                ns_go <= 1'b0;
                ns_start();
                ns_len <= ns_lw2[6:0];
                if (ns_lw2[9]) ns_act <= 1'b0;
            end

            // ---- the envelopes' reload, half a step on ----
            if (fs_rise && on)
                for (int e = 0; e < 3; e++)
                    if (env_act[e] && env_cd[e] == 0) begin
                        env_cd[e] <= env_nrx2[e][2:0];
                        if (env_nrx2[e][2:0] != 0 && !env_clk[e]) begin
                            env_clk[e] <= 1'b1;
                            env_end[e] <= env_nrx2[e][3] ? env_v[e] == 4'hF : env_v[e] == 4'h0;
                        end else if (env_nrx2[e][2:0] == 0 && env_clk[e]) begin
                            env_clk[e] <= 1'b0;
                            if (env_end[e]) env_lock[e] <= 1'b1;
                        end
                    end

            // ---- writes ----
            if (wr) begin
                if (sel >= 6'h20) begin
                    if (!wv_act) wave[sel[3:0]] <= wdata;
                    else if (CGB || wv_just) wave[wv_pos[4:1]] <= wdata;
                end else if (sel == 6'h16) begin
                    if (wdata[7] && !on) begin
                        // power on: the frame sequencer from step 0, skipping its next clock
                        // if the counter's bit 12 is set now
                        on      <= 1'b1;
                        fs_step <= 3'd0;
                        fs_skip <= div_b12;
                        lf      <= 1'b1;
                    end
                end else if (!on) begin
                    // off: on the DMG, the length counters still take writes
                    if (!CGB) case (sel)
                        6'h01: begin sq_len[0] <= 7'd64 - {1'b0, wdata[5:0]}; nr11 <= {2'b00, wdata[5:0]}; end
                        6'h06: begin sq_len[1] <= 7'd64 - {1'b0, wdata[5:0]}; nr21 <= {2'b00, wdata[5:0]}; end
                        6'h0B: wv_len <= 9'd256 - {1'b0, wdata};
                        6'h10: ns_len <= 7'd64 - {1'b0, wdata[5:0]};
                        default: ;
                    endcase
                end else case (sel)
                    6'h00: begin
                        // leaving negate after a calculation used it stops channel 1
                        if (nr10[3] && !wdata[3] && sw_negused) sq_act[0] <= 1'b0;
                        nr10 <= wdata;
                    end
                    6'h01: begin nr11 <= wdata; sq_len[0] <= 7'd64 - {1'b0, wdata[5:0]}; end
                    6'h06: begin nr21 <= wdata; sq_len[1] <= 7'd64 - {1'b0, wdata[5:0]}; end
                    6'h02, 6'h07: begin
                        if (sel == 6'h02) nr12 <= wdata; else nr22 <= wdata;
                        if (wdata[7:3] == 0) begin   // the DAC off
                            sq_act[sel == 6'h07] <= 1'b0;
                            sq_run[sel == 6'h07] <= 1'b0;
                        end
                    end
                    6'h03, 6'h08: begin
                        if (sel == 6'h03) nr13 <= wdata; else nr23 <= wdata;
                        // a timer that has just reloaded takes the new frequency
                        if (sq_just[sel == 6'h08])
                            sq_cd[sel == 6'h08] <= sq_reload(sel == 6'h03 ? {nr14[2:0], wdata} : {nr24[2:0], wdata});
                    end
                    6'h04, 6'h09: begin
                        if (sq_c) nr24 <= wdata; else nr14 <= wdata;
                        if (sq_just[sq_c]) sq_cd[sq_c] <= sq_reload(sq_wf);
                        if (wdata[7]) begin
                            // the timer starts late: by 3 M-cycles, or 2 if it was playing
                            sq_cd[sq_c]   <= {1'b0, ~sq_wf, 1'b0} + (sq_act[sq_c] ? (lf ? 13'd3 : 13'd4) : (lf ? 13'd5 : 13'd6));
                            env_v[{1'b0, sq_c}]  <= sq_nrx2[7:4];
                            env_cd[{1'b0, sq_c}] <= sq_nrx2[2:0];
                            env_clk[{1'b0, sq_c}]  <= 1'b0;
                            env_lock[{1'b0, sq_c}] <= 1'b0;
                            sq_run[sq_c]  <= sq_nrx2[7:3] != 0;
                            if (sq_nrx2[7:3] != 0) begin
                                sq_act[sq_c] <= 1'b1;
                                if (!sq_act[sq_c]) sq_supp[sq_c] <= 1'b1;
                            end
                            if (!sq_c) begin
                                sw_shadow  <= sq_wf;
                                sw_t       <= nr10[6:4] == 0 ? 4'd8 : {1'b0, nr10[6:4]};
                                sw_en      <= nr10[6:4] != 0 || nr10[2:0] != 0;
                                sw_negused <= 1'b0;
                                // with a shift, the overflow check comes at once
                                if (nr10[2:0] != 0) begin
                                    if (nr10[3]) sw_negused <= 1'b1;
                                    else if (sq_trig_chk > 12'h7FF) sq_act[0] <= 1'b0;
                                end
                            end
                        end
                        sq_len[sq_c]   <= sq_lw[6:0];
                        sq_lenen[sq_c] <= wdata[6];
                        if (sq_lw[9]) sq_act[sq_c] <= 1'b0;
                    end
                    6'h0A: begin
                        nr30 <= wdata;
                        if (!wdata[7]) wv_act <= 1'b0;
                    end
                    6'h0B: wv_len <= 9'd256 - {1'b0, wdata};
                    6'h0C: nr32 <= wdata;
                    6'h0D: nr33 <= wdata;
                    6'h0E: begin
                        nr34 <= wdata;
                        if (wdata[7]) begin
                            // retriggered as it reads: wave RAM's first bytes take those it was about to read
                            if (!CGB && wv_act && wv_cd == 0) begin
                                if (wv_off < 4'd4)
                                    wave[0] <= wave[wv_off];
                                else
                                    for (int k = 0; k < 4; k++)
                                        wave[k] <= wave[{wv_off[3:2], 2'(k)}];
                            end
                            wv_pos <= '0;
                            if (wv_act && wv_cd == 0) wv_buf <= wave[0];
                            if (nr30[7]) wv_act <= 1'b1;
                            wv_cd <= {1'b0, ~{wdata[2:0], nr33}} + 12'd3;
                        end
                        wv_len   <= wv_lw[8:0];
                        wv_lenen <= wdata[6];
                        if (wv_lw[9]) wv_act <= 1'b0;
                    end
                    6'h10: ns_len <= 7'd64 - {1'b0, wdata[5:0]};
                    6'h11: begin
                        nr42 <= wdata;
                        if (wdata[7:3] == 0) begin
                            // the DAC off: the counter stops (a step about to come comes first)
                            if (ns_act && nr43[2:0] != 0 && ns_cd <= 6'd2) ns_cnt <= ns_cnt1;
                            ns_act <= 1'b0;
                            ns_on  <= 1'b0;
                            if (!CGB) ns_bg <= 1'b0;
                        end
                    end
                    6'h12: nr43 <= wdata;
                    6'h13: begin
                        nr44 <= wdata;
                        if (wdata[7]) begin
                            env_clk[2]  <= 1'b0;
                            env_lock[2] <= 1'b0;
                            if (ns_late) ns_dly <= 3'd6;
                            else ns_start();
                        end
                        ns_len   <= ns_lw[6:0];
                        ns_lenen <= wdata[6];
                        if (ns_lw[9]) ns_act <= 1'b0;
                    end
                    6'h14: r50 <= wdata;
                    6'h15: r51 <= wdata;
                    default: ;
                endcase
            end
        end
    end
endmodule
