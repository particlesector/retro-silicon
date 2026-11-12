// SPDX-License-Identifier: Apache-2.0
// The 2600's picture and sound as HDMI at 720p. The picture is the frame as Stella cuts it
// (a2600_frame's 160 x 228), each pixel 6 display pixels wide and 3 lines high: 960 x 684, a
// pixel's shape on a TV, in the middle of the display. The TIA's colours make it RGB (video/tia's
// tia_rgb); video/hdmi times and encodes it, with the sound at 48 kHz as 2-channel audio (the same
// on both).
//
// The lines come through a ring of 32 in block RAM, written as a2600_frame writes its buffer
// (`vw_*`: the pixels drawn and the line's clearing), so a line is whole in the ring when
// a2600_frame says it is (`row_done`). The system keeps pace with the display, as the NES's does
// (systems/nes's nes_video and video/line-scaler): it waits at each frame's end (`waiting`, held
// off while a line is still being cleared) until the display asks for the next frame (`req`, at the
// start of line REQ_Y), so each display frame shows one 2600 frame whole. Running 2% fast of NTSC,
// a frame of 262 lines takes 98% of a display frame, and the system draws its lines a little
// faster than the display shows them, 19 lines ahead at most, which the ring holds.
//
// The display checks each line as it starts showing it: the line has come, and hasn't been
// overwritten by the line 32 later (with 4 to spare for the count's crossing). A frame whose
// system wasn't waiting for the request is drawn black; a line that hasn't come is drawn black and
// `late` counts it, unless the frame has ended without it (a short frame), when it's black as
// Stella's is; a line overwritten is black and counts in `overrun`. In a working system neither
// count moves.
//
// The sound: the two channels' levels summed (`a_level`, 0 to 30) go into audio/resampler, 800
// samples per 19,912 inputs. HDMI plays them at 48 kHz, 800 to a display frame, so each 2600 frame's
// sound must be 800 samples for each display frame it takes, however many lines the cartridge gives
// it: at one input a CPU cycle, frames of 263 lines made 803 and the receiver's buffer filled, and a
// frame over 266 lines, which misses its request and takes two display frames, made 815 for the two
// and it ran dry; either way it muted. So the inputs come at 19,912 x N / C of the CPU cycles
// (`a_ce`), C being the last frame's cycles (counted between `frame_done`s) and N the display frames
// it took (1, and 1 more for each request that came while it ran, up to 4). Frames of a steady
// length then make exactly 800 samples a display frame. A change of length misjudges a frame by up
// to 800 either way, which the FIFO below takes up, and to keep it from adding up the FIFO's level
// steers the next: each frame makes T = 800 x N + (2,048 - level) / 2 samples (0 to 4,000), the
// level taken at the frame's end. Each cycle adds T x 2,489 to an accumulator, and each clock it
// holds C x 100 or more it takes that off and gives the resampler the level of that cycle: T x
// 2,489 / 100 inputs a frame, so T samples. C is taken as at least 16,384 cycles (216 lines: a
// shorter frame still takes a display frame, and a rate from it would flood a longer one after)
// and at most 79,648 (four display frames), and as 19,912 before the first frame. A request with no cycle since the one before
// (the 2600 stopped) isn't counted.
// A sample crosses to the pixel clock by a toggle, as in nes_video, into a FIFO of 4,096, and goes
// to HDMI at exactly 48 kHz (64 / 99,000 of the pixel clock: 800 to a display frame), so a
// receiver's buffer neither fills nor runs dry whatever the 2600 does. It starts once 2,048 are
// waiting, so the sound is 43 ms behind the picture: the room to take misjudged frames either way
// (`tia_audio`'s frames, alternating between two display frames and part of one, take its level
// from 550 to 2,650; with 2,048 of room it ran dry). If it runs dry it repeats the last sample
// until 2,048 are waiting again, and a sample to a full FIFO is dropped.
// `gaps` counts both while playing: none while a cartridge runs at a steady pace, and one when it
// stops and the FIFO drains.
//
// `pcm_valid` and `pcm` are the samples as they're made, for the test shell's CRC of them.
//
// The video CRC, for the test shell, is nes_video's: a toggle of `cap_t` asks for the CRC of the
// display frame that the next request starts (all its TMDS symbols, the data islands' packets as
// 0), which comes with a toggle of `crc_t` and `crc_ok`, whether that frame showed its 2600 frame
// whole. `shown` counts display frames whose 2600 frame started on request.
//
// The pixel side resets itself at configuration (common/por on pclk).
module a2600_video #(
    parameter int X0    = 160,  // the picture's left edge
    parameter int Y0    = 18,   // ...and top line
    parameter int REQ_Y = 690
) (
    // The system's clock
    input  logic        clk,
    input  logic        rst,
    input  logic [3:0]  vw_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [7:0]  vw_y,  // the ring takes the line mod 32
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [5:0]  vw_w,
    input  logic [7:0]  vw_d,
    input  logic        row_done,
    input  logic        frame_done,
    input  logic        waiting,
    output logic        req,
    input  logic        a_ce,
    input  logic [4:0]  a_level,
    input  logic        cap_t,
    output logic [31:0] crc,
    output logic        crc_ok,
    output logic        crc_t,
    output logic [15:0] shown,
    output logic [15:0] late,
    output logic [15:0] overrun,
    output logic [15:0] gaps,      // the sound ran dry or dropped a sample
    output logic        pcm_valid,   // a 48 kHz sample, as it goes to the HDMI
    output logic [15:0] pcm,

    // The pixel clock
    input  logic        pclk,
    output logic [9:0]  tmds0,
    output logic [9:0]  tmds1,
    output logic [9:0]  tmds2
);
    localparam int W = 160, H = 228, SX = 6, SY = 3, RING = 32, SPARE = 4, LATENCY = 2;
    localparam int WORDS = RING * W / 4;  // 1,280

    logic prst;
    por u_ppor (.clk(pclk), .rst(prst));

    // ---- The ring: 4 byte lanes, written on clk, read on pclk ----
    logic [7:0]  ring0 [WORDS], ring1 [WORDS], ring2 [WORDS], ring3 [WORDS];
    wire  [10:0] wa = {vw_y[4:0], 5'd0} + {2'd0, vw_y[4:0], 3'd0} + 11'(vw_w);  // y x 40 + w
    always_ff @(posedge clk) begin
        if (vw_we[0]) ring0[wa] <= vw_d;
        if (vw_we[1]) ring1[wa] <= vw_d;
        if (vw_we[2]) ring2[wa] <= vw_d;
        if (vw_we[3]) ring3[wa] <= vw_d;
    end

    // ---- Lines whole and frames ended, crossing to the pixel clock ----
    logic [15:0] n_rows, g_rows, p_rows;
    logic        end_t, p_end, p_waiting, req_t, req_seen, req_last;
    always_ff @(posedge clk)
        if (rst) begin
            n_rows <= '0;
            g_rows <= '0;
            end_t  <= 1'b0;
        end else begin
            if (row_done) begin
                n_rows <= n_rows + 1'b1;
                g_rows <= (n_rows + 1'b1) ^ ((n_rows + 1'b1) >> 1);
            end
            if (frame_done) end_t <= !end_t;
        end

    cdc_sync #(.W(16)) u_rows (.clk(pclk), .d(g_rows), .q(p_rows));
    cdc_sync u_end (.clk(pclk), .d(end_t), .q(p_end));
    cdc_sync u_wait (.clk(pclk), .d(waiting), .q(p_waiting));
    cdc_sync u_req (.clk, .d(req_t), .q(req_seen));

    always_ff @(posedge clk) begin
        req_last <= req_seen;
        req      <= req_seen != req_last;
        if (rst) req <= 1'b0;
    end

    function automatic logic [15:0] from_gray(input logic [15:0] g);
        logic [15:0] b;
        b = g;
        for (int i = 1; i < 16; i++)
            b = b ^ (g >> i);
        from_gray = b;
    endfunction

    // Decoded in a clock of its own: the decode, the subtraction from the frame's base and the
    // comparisons with the row in one pixel clock were the 138K's slowest path at 74.375 MHz.
    logic [15:0] rows_now;
    always_ff @(posedge pclk)
        rows_now <= from_gray(p_rows);

    // ---- Display ----
    logic [11:0] hx, hy;
    logic        hframe, hline;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        hact;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [23:0] rgb;
    logic        packet;

    // Where the display is: the picture's column and its pixel within (for hx), its line and its
    // display line within (for hy, set as each display line starts).
    logic       x_on, y_on, line_d;
    logic [7:0] col, row;
    logic [2:0] sx;
    logic [1:0] sy;
    // The frame the request starts (pend_*), taken at the request, and the one being shown (cur_*).
    logic        pend_ok, cur_ok, pend_end, cur_end;
    logic [15:0] pend_base, cur_base;
    logic        row_show, slate, sover;

    wire [15:0] got     = rows_now - cur_base;      // the frame's lines whole
    wire        arrived = got > 16'(row);
    wire        over    = got > 16'(row) + 16'(RING - SPARE);
    wire        ended   = p_end != cur_end;

    always_ff @(posedge pclk) begin
        slate  <= 1'b0;
        sover  <= 1'b0;
        line_d <= hline;
        if (hx == 12'(X0 - 1)) begin
            x_on <= 1'b1;
            col  <= '0;
            sx   <= '0;
        end else if (x_on) begin
            if (sx == 3'(SX - 1)) begin
                sx <= '0;
                if (col == 8'(W - 1)) x_on <= 1'b0;
                else col <= col + 8'd1;
            end else
                sx <= sx + 3'd1;
        end
        if (hline) begin
            if (hy == 12'(Y0)) begin
                y_on <= 1'b1;
                row  <= '0;
                sy   <= '0;
            end else if (y_on) begin
                if (sy == 2'(SY - 1)) begin
                    sy <= '0;
                    if (row == 8'(H - 1)) y_on <= 1'b0;
                    else row <= row + 8'd1;
                end else
                    sy <= sy + 2'd1;
            end
            if (hy == 12'(REQ_Y)) begin
                req_t     <= !req_t;
                pend_ok   <= p_waiting;
                pend_base <= rows_now;
                pend_end  <= p_end;
            end
        end
        if (hframe) begin
            cur_ok   <= pend_ok;
            cur_base <= pend_base;
            cur_end  <= pend_end;
        end
        // The line's checks, as its first display line starts (row and sy are set by now).
        if (line_d) begin
            row_show <= cur_ok && arrived && !over;
            if (y_on && sy == 2'd0 && cur_ok) begin
                slate <= !arrived && !ended;
                sover <= arrived && over;
            end
        end
        if (prst) begin
            x_on    <= 1'b0;
            y_on    <= 1'b0;
            req_t   <= 1'b0;
            pend_ok <= 1'b0;
            cur_ok  <= 1'b0;
        end
    end

    // The ring's word for this position; its byte the clock after; its colour the clock after
    // that. The colours are a block RAM, which takes its address on the falling edge before the
    // clock that reads it, as nes_video's do (a block RAM's address needs more hold than a short
    // path from a register gives on the GW2AR-18).
    logic [10:0] ra;
    logic [31:0] q;
    logic [1:0]  lane;
    logic [1:0]  on_d;
    logic [7:0]  pix_n;
    assign ra = {row[4:0], 5'd0} + {2'd0, row[4:0], 3'd0} + 11'(col[7:2]);
    always_ff @(posedge pclk) begin
        q    <= {ring3[ra], ring2[ra], ring1[ra], ring0[ra]};
        lane <= col[1:0];
        on_d <= {on_d[0], x_on && y_on && row_show};
    end

    always_ff @(negedge pclk)
        pix_n <= q[8 * lane +: 8];

    tia_rgb u_rgb (.clk(pclk), .pix(pix_n), .rgb);

    // ---- Sound ----
    logic               a_valid;
    logic signed [15:0] a_pcm;
    /* verilator lint_off UNUSEDSIGNAL */
    logic               a_busy;
    logic [31:0]        a_st;
    /* verilator lint_on UNUSEDSIGNAL */
    localparam int K = 19_912;   // a 262-line frame's CPU cycles: the resampler's 800 samples

    logic [16:0] a_cyc;          // this frame's cycles so far
    logic [1:0]  a_miss;         // requests missed this frame
    logic        a_ran;          // a cycle since the last request
    logic [23:0] a_thr;          // the last frame's cycles x 100
    logic [23:0] a_add, a_acc;   // T x 2,489 a cycle
    logic [4:0]  a_lvl;
    logic        a_in;
    logic [12:0] a_qlv;          // the FIFO's level, from the pixel clock
    wire         a_missed = req && !waiting && a_ran;
    wire  [2:0]  a_n = 3'(a_miss) + 3'(a_missed && a_miss != '1) + 3'd1;
    wire  [16:0] a_c = a_cyc < 17'd16384 ? 17'd16384 : a_cyc > 17'(4 * K) ? 17'(4 * K) : a_cyc;
    wire  signed [13:0] a_tgt = $signed(14'(a_n)) * 14'sd800 + ((14'sd2048 - 14'($signed({1'b0, a_qlv}))) >>> 1);
    wire  [11:0] a_tc = a_tgt < 0 ? '0 : a_tgt > 14'sd4000 ? 12'd4000 : 12'(a_tgt);

    always_ff @(posedge clk) begin
        if (frame_done) begin
            a_thr  <= 24'(a_c) * 24'd100;
            a_add  <= 24'(a_tc) * 24'd2489;
            a_cyc  <= 17'(a_ce);
            a_miss <= '0;
        end else begin
            if (a_ce && a_cyc != '1)
                a_cyc <= a_cyc + 1'b1;
            if (a_missed && a_miss != '1)
                a_miss <= a_miss + 1'b1;
        end
        if (req)
            a_ran <= a_ce;
        else if (a_ce)
            a_ran <= 1'b1;
        if (a_ce)
            a_lvl <= a_level;
        a_in  <= a_acc >= a_thr;
        a_acc <= a_acc + (a_ce ? a_add : '0) - (a_acc >= a_thr ? a_thr : '0);
        if (rst) begin
            a_cyc  <= '0;
            a_thr  <= 24'(K) * 24'd100;
            a_add  <= 24'd800 * 24'd2489;
            a_miss <= '0;
            a_ran  <= 1'b0;
            a_acc  <= '0;
            a_lvl  <= '0;
            a_in   <= 1'b0;
        end
    end

    resampler #(.NUM(100), .DEN(2489), .SAVE_STATE(1'b0)) u_rs (
        .clk, .rst, .ce(a_in), .in({a_lvl, 11'd0}), .valid(a_valid), .busy(a_busy), .out(a_pcm),
        .st_addr(2'd0), .st_rdata(a_st), .st_we(1'b0), .st_wdata(32'd0));

    assign pcm_valid = a_valid;
    assign pcm       = a_pcm;

    logic [15:0] a_hold, a_p;
    logic        a_t, a_seen, a_last, a_new;
    logic        n_gap;

    always_ff @(posedge clk)
        if (rst)
            a_t <= 1'b0;
        else if (a_valid) begin
            a_hold <= a_pcm;
            a_t    <= !a_t;
        end

    cdc_sync u_at (.clk(pclk), .d(a_t), .q(a_seen));

    always_ff @(posedge pclk) begin
        a_last <= a_seen;
        a_new  <= a_seen != a_last;
        if (a_seen != a_last)
            a_p <= a_hold;
        if (prst) begin
            a_last <= a_seen;
            a_new  <= 1'b0;
        end
    end

    // The FIFO, drained at 48 kHz.
    localparam int AQ_LOG2 = 12, AQW = AQ_LOG2 + 1, AQ_START = 2048;
    logic [15:0]        aq_q, a_out;
    logic               aq_full, aq_empty, aq_ren, a_play, a_play_d, a_tick, a_send;
    logic [AQ_LOG2:0]   aq_n;
    logic [16:0]        a_nco;
    logic [12:0]        aq_g, aq_s;   // aq_n Gray-coded, and across to clk (it moves by 1 at most)

    fifo #(.WIDTH(16), .DEPTH_LOG2(AQ_LOG2)) u_aq (
        .clk(pclk), .rst(prst), .wdata(a_p), .wen(a_new), .full(aq_full),
        .ren(aq_ren), .rdata(aq_q), .empty(aq_empty));

    assign a_tick = a_nco >= 17'd99_000 - 17'd64;
    assign aq_ren = a_tick && a_play && !aq_empty;

    cdc_sync #(.W(13)) u_aqn (.clk, .d(aq_g), .q(aq_s));
    assign a_qlv = 13'(from_gray({3'b0, aq_s}));

    always_ff @(posedge pclk) begin
        aq_g   <= aq_n ^ (aq_n >> 1);
        a_nco  <= a_tick ? a_nco + 17'd64 - 17'd99_000 : a_nco + 17'd64;
        aq_n   <= aq_n + AQW'(a_new && !aq_full) - AQW'(aq_ren);
        a_send <= a_tick;
        if (a_play_d)
            a_out <= aq_q;
        n_gap <= a_play && ((a_new && aq_full) || (a_tick && aq_empty));
        if (a_tick && a_play && aq_empty)
            a_play <= 1'b0;
        else if (!a_play && aq_n >= AQW'(AQ_START))
            a_play <= 1'b1;
        if (prst) begin
            a_nco  <= '0;
            aq_n   <= '0;
            aq_g   <= '0;
            a_send <= 1'b0;
            a_out  <= '0;
            a_play <= 1'b0;
            n_gap  <= 1'b0;
        end
    end

    // A sample popped is in aq_q the clock after; one not popped repeats a_out.
    always_ff @(posedge pclk)
        a_play_d <= aq_ren;

    wire [15:0] a_snd = a_play_d ? aq_q : a_out;

    hdmi #(.LATENCY(LATENCY), .AUDIO(1'b1)) u_hdmi (
        .clk(pclk), .rst(prst), .x(hx), .y(hy), .act(hact), .frame(hframe), .line(hline),
        .rgb(on_d[1] ? rgb : 24'h000000), .aud_valid(a_send), .aud_l(a_snd), .aud_r(a_snd),
        .tmds0, .tmds1, .tmds2, .packet);

    // ---- Frame CRC (nes_video's) ----
    // `start` is high while a frame's first symbol is out, LATENCY + 2 clocks after its position;
    // the CRC takes each symbol the clock after it's out. A captured frame's CRC restarts at its
    // start and runs through the next frame's start, and is ready the clock after. A frame is bad if
    // its 2600 frame didn't start on request or a line came late or overwritten.
    logic [LATENCY+1:0] fd;
    logic [29:0]        sym_q;
    logic               cap_seen, cap_last, armed, running, bad, frame_bad, publish;
    logic [31:0]        vcrc, res;
    logic               res_ok, res_t;

    wire start = fd[LATENCY+1];

    cdc_sync u_cap (.clk(pclk), .d(cap_t), .q(cap_seen));

    crc32 #(.W(30)) u_crc (.clk(pclk), .rst(start && armed), .en(running), .data(sym_q), .crc(vcrc),
                           .st_we(1'b0), .st_wdata('0));

    always_ff @(posedge pclk) begin
        fd      <= {fd[LATENCY:0], hframe};
        sym_q   <= packet ? '0 : {tmds2, tmds1, tmds0};
        publish <= start && running;
        if (publish) begin
            res    <= vcrc;
            res_ok <= !frame_bad;
            res_t  <= !res_t;
        end
        if (hframe && cap_seen != cap_last && !running) begin
            cap_last <= cap_seen;
            armed    <= 1'b1;
        end
        if (start) begin
            running <= armed;
            armed   <= 1'b0;
        end
        if (fd[0]) begin
            frame_bad <= bad;
            bad       <= !cur_ok || slate || sover;
        end else if (slate || sover)
            bad <= 1'b1;
        if (prst) begin
            fd       <= '0;
            publish  <= 1'b0;
            res_t    <= 1'b0;
            cap_last <= cap_seen;
            armed    <= 1'b0;
            running  <= 1'b0;
        end
    end

    // ---- Counts, Gray-coded across ----
    logic [15:0] n_shown, g_shown, s_shown, n_late, g_late, s_late, n_over, g_over, s_over;
    logic [15:0] n_gaps, g_gaps, s_gaps;

    always_ff @(posedge pclk)
        if (prst) begin
            n_shown <= '0;
            n_late  <= '0;
            n_over  <= '0;
            g_shown <= '0;
            g_late  <= '0;
            g_over  <= '0;
            n_gaps  <= '0;
            g_gaps  <= '0;
        end else begin
            if (n_gap) begin
                n_gaps <= n_gaps + 1'b1;
                g_gaps <= (n_gaps + 1'b1) ^ ((n_gaps + 1'b1) >> 1);
            end
            if (start && cur_ok) begin
                n_shown <= n_shown + 1'b1;
                g_shown <= (n_shown + 1'b1) ^ ((n_shown + 1'b1) >> 1);
            end
            if (slate) begin
                n_late <= n_late + 1'b1;
                g_late <= (n_late + 1'b1) ^ ((n_late + 1'b1) >> 1);
            end
            if (sover) begin
                n_over <= n_over + 1'b1;
                g_over <= (n_over + 1'b1) ^ ((n_over + 1'b1) >> 1);
            end
        end

    cdc_sync #(.W(16)) u_shown (.clk, .d(g_shown), .q(s_shown));
    cdc_sync #(.W(16)) u_late (.clk, .d(g_late), .q(s_late));
    cdc_sync #(.W(16)) u_over (.clk, .d(g_over), .q(s_over));
    cdc_sync #(.W(16)) u_gaps (.clk, .d(g_gaps), .q(s_gaps));

    assign shown   = from_gray(s_shown);
    assign late    = from_gray(s_late);
    assign overrun = from_gray(s_over);
    assign gaps    = from_gray(s_gaps);

    // The CRC and its flag hold from before res_t toggles until the next frame's, so they cross
    // with it.
    cdc_sync #(.W(33)) u_res (.clk, .d({res_ok, res}), .q({crc_ok, crc}));
    cdc_sync u_res_t (.clk, .d(res_t), .q(crc_t));

    initial begin
        if (X0 < 1 || X0 + W * SX > 1280 || Y0 + H * SY > 720) $error("a2600_video: the picture must fit");
    end
endmodule
