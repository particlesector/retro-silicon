// SPDX-License-Identifier: Apache-2.0
// The Atari 2600 (atari2600) under the test shell: its cartridge in block RAM (a2600_cart, banked by
// the scheme register 50 sets; with ROM_EXT its ROM in an outside memory on `mem_*`, a byte port as
// memory/sdram's, from address 0), run and stop by
// register, and the checks a board can give the host: each whole frame's CRC as Stella cuts frames
// (a2600_frame) and the sound's CRC as Stella samples it, so the host compares them with the golden
// lists without taking the picture over the link.
//
// Colour clocks come at CC_NUM/CC_DEN of the clock (clock_enable), at least 6 clocks apart, while the
// system runs. The system stops between colour clocks, so stopping and starting leave it exactly as
// if it had run on: the same on any board and in the sim. With ROM_EXT a colour clock also waits
// while the cartridge is fetching the byte its access reads (clock_enable's hold), so only a fetch
// that isn't done by then costs time. A reset clears the frame buffer first
// (about 9,000 clocks) and starts no colour clock until that's done.
//
// With VIDEO set, the picture and sound go out as HDMI at 720p (a2600_video, on `pclk`), and with
// pacing on (register 34) the system keeps pace with the display: it waits at each frame's end
// until the display asks for the next, a stop between colour clocks like the others. The video CRC
// is of the display frame that starts frame `vcap_frame` + 1 (frames, at that request, equal to
// it), the frame whose CRC frame_crc gives as frame vcap_frame + 1.
//
// Shell address map (README.md has the registers):
//   0x00000000-...         the cartridge's ROM, 2^ROM_LOG2 bytes (a 2 KB one written twice)
//   0x01000000-0x0100007F  control and status registers
//   0x05000000-0x05008E7F  the frame buffer: y x 160 + x, the last frame as Stella would show it
// LEDs (active low): led[0] a corrupt command frame, led[1] a stalled one, led[3] running, led[4]
// stopped at a limit, led[5] heartbeat.

module a2600_sys #(
    parameter int          CLKS_PER_BIT     = 18,       // 27 MHz / 18 = 1.5 Mbaud
    parameter int          IDLE_CLKS        = 270_000,  // 10 ms at 27 MHz
    parameter int          CC_NUM           = 35,       // colour clocks per CC_DEN clocks: NTSC's
    parameter int          CC_DEN           = 264,      //   3.579545 MHz from 27 MHz
    parameter bit          TIA_SCORE_GLITCH = 1'b0,
    parameter bit          VIDEO            = 1'b0,     // HDMI out (a2600_video), on pclk
    parameter int          ROM_LOG2         = 16,       // the cartridge's ROM: 2^ROM_LOG2 bytes
    parameter int          ROM_BANK_LOG2    = ROM_LOG2, // in block RAM, in memories of 2^ROM_BANK_LOG2 bytes
    parameter bit          ROM_EXT          = 1'b0,     // the ROM on mem_*, not in block RAM
    parameter logic [31:0] BUILD_ID         = '0
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [5:0] led,

    // With VIDEO: the pixel clock, 74.25 MHz, and the TMDS symbols
    input  logic       pclk,
    output logic [9:0] tmds0,
    output logic [9:0] tmds1,
    output logic [9:0] tmds2,

    // With ROM_EXT: the memory the ROM is in (memory/sdram's byte port)
    output logic        mem_req,
    output logic        mem_we,
    output logic [23:0] mem_addr,
    output logic [7:0]  mem_wdata,
    input  logic        mem_ack,
    input  logic [7:0]  mem_rdata
);
    logic por_rst;
    por u_por (.clk, .rst(por_rst));

    // ---- Test shell ----
    logic [31:0] s_addr;
    logic        s_req, s_we, s_ack;
    logic [7:0]  s_wdata, s_rdata;
    logic        crc_error, timeout;
    test_shell #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .BUILD_ID(BUILD_ID)) u_shell (
        .clk, .rst(por_rst), .uart_rx, .uart_tx,
        .bus_addr(s_addr), .bus_req(s_req), .bus_we(s_we), .bus_wdata(s_wdata),
        .bus_ack(s_ack), .bus_rdata(s_rdata),
        .crc_error, .timeout);

    // ---- Registers ----
    logic [1:0]  ctrl;            // 00: bit 0 run, bit 1 hold in reset
    logic [31:0] stop_cycle;      // 04
    logic [31:0] stop_frame;      // 10
    logic [31:0] audio_limit;     // 28
    logic [7:0]  joy, switches;   // 2C, 2D
    logic [1:0]  fire_n;          // 2E
    logic [3:0]  paddle_on;       // 2F
    logic [31:0] paddle_pos;      // 30
    logic [3:0]  cart_scheme;     // 50: a2600_cart's scheme
    logic        cart_sc;         //     bit 4: the Superchip's RAM
    logic [4:0]  cart_size;       // 51: the ROM's size, log2

    wire rst = por_rst || ctrl[1];

    logic [31:0] cycles, samples, audio_crc, frames, frame_crc, crc_frame;
    logic        busy, fb_busy, cart_clearing, cart_wait, pace_wait;
    assign busy = fb_busy || cart_clearing;
    wire at_limit = (stop_cycle != 0 && cycles >= stop_cycle) || (stop_frame != 0 && frames >= stop_frame);
    wire running  = ctrl[0] && !rst && !busy && !at_limit && !pace_wait;

    // ---- Colour clocks ----
    logic cc, step;
    clock_enable #(.NUM(CC_NUM), .DEN(CC_DEN)) u_cc (.clk, .rst, .en(running), .hold(cart_wait), .ce(cc));
    always_ff @(posedge clk) step <= cc && !rst;

    // ---- The system ----
    logic [11:0] cart_addr;
    logic        cart_sel, cart_we;
    logic [7:0]  cart_wdata, cart_data;
    logic [7:0]  pix, pix_x;
    logic        pix_on, line_end, vsync, vblank, aud_tick;
    logic [3:0]  aud0, aud1;
    logic        cpu_sync, bus_ce, bus_we, bus_stall;
    logic [15:0] cpu_pc;
    logic [12:0] bus_addr;
    logic [7:0]  bus_data;
    atari2600 #(.TIA_SCORE_GLITCH(TIA_SCORE_GLITCH)) u_sys (
        .clk, .rst, .cc,
        .cart_addr, .cart_sel, .cart_we, .cart_wdata, .cart_data,
        .joy, .switches, .fire_n, .paddle_on, .paddle_pos,
        .pix, .pix_on, .pix_x, .line_end, .vsync, .vblank, .aud0, .aud1, .aud_tick,
        .cpu_sync, .cpu_pc, .bus_ce, .bus_addr, .bus_we, .bus_data, .bus_stall);

    // The cartridge, read every clock (a CPU cycle is at least 18) and written by the shell. It
    // watches every access (bus_*), as a cartridge's bank switching does.
    logic [7:0]          cart_sh;
    logic                cart_sh_ack;
    logic [ROM_LOG2-1:0] cart_mem_addr;
    wire                 sh_cart = s_req && s_addr[31:24] == 8'h00 && s_addr[23:ROM_LOG2] == '0;
    a2600_cart #(.ROM_LOG2(ROM_LOG2), .ROM_BANK_LOG2(ROM_BANK_LOG2), .ROM_EXT(ROM_EXT)) u_cart (
        .clk, .por_rst, .rst, .scheme(cart_scheme), .sc(cart_sc), .size_log2(cart_size), .clearing(cart_clearing),
        .ce(bus_ce && !bus_stall), .addr(bus_addr), .we(bus_we), .data(bus_data), .q(cart_data),
        .rom_wait(cart_wait),
        .sh_req(sh_cart && !s_ack), .sh_we(s_we), .sh_addr(s_addr[ROM_LOG2-1:0]), .sh_wdata(s_wdata),
        .sh_ack(cart_sh_ack), .sh_q(cart_sh),
        .mem_req, .mem_we, .mem_addr(cart_mem_addr), .mem_wdata, .mem_ack, .mem_rdata);
    assign mem_addr = 24'(cart_mem_addr);

    // ---- Counts and the sound's CRC ----
    // Each sample is the two channels' levels summed over the colour clocks since the last, as two
    // little-endian 16-bit words; the CRC takes the first `audio_limit` (0: all).
    logic [15:0] sum0, sum1;
    wire  [15:0] next0 = sum0 + 16'(aud0), next1 = sum1 + 16'(aud1);
    wire         take  = step && aud_tick && (audio_limit == 0 || samples < audio_limit);
    crc32 #(.W(32)) u_acrc (.clk, .rst, .en(take), .data({next1, next0}), .crc(audio_crc),
                            .st_we(1'b0), .st_wdata(32'd0));
    always_ff @(posedge clk)
        if (rst) begin
            cycles  <= '0;
            samples <= '0;
            sum0    <= '0;
            sum1    <= '0;
        end else begin
            if (cc && bus_ce) cycles <= cycles + 32'd1;
            if (step) begin
                if (aud_tick) begin
                    sum0    <= '0;
                    sum1    <= '0;
                    samples <= samples + 32'd1;
                end else begin
                    sum0 <= next0;
                    sum1 <= next1;
                end
            end
        end

    // ---- Frames ----
    logic       fb_req, fb_ack;
    logic [7:0] fb_data;
    logic [3:0] vw_we;
    logic [7:0] vw_y, vw_d;
    logic [5:0] vw_w;
    logic       row_done, line_busy, frame_done;
    wire        sh_fb = s_req && !s_we && s_addr[31:24] == 8'h05 && s_addr[23:16] == '0;
    assign fb_req = sh_fb && !s_ack;
    a2600_frame u_frame (
        .clk, .rst, .step, .pix_on, .pix_x, .pix, .line_end, .vsync,
        .frames, .crc(frame_crc), .crc_frame, .busy(fb_busy),
        .rd_req(fb_req), .rd_addr(s_addr[15:0]), .rd_ack(fb_ack), .rd_data(fb_data),
        .vw_we, .vw_y, .vw_w, .vw_d, .row_done, .line_busy, .frame_done);

    // ---- Display pacing and the video CRC ----
    // It waits on the display only when nothing else holds it and no line is still being cleared,
    // so a request that comes while it's stopped is left for the one after it's let go.
    logic        vid_pace, vcap_armed, vcap_wait, vcap_valid, vcap_ok, v_crc_seen, v_cap_t;
    logic [31:0] vcap_frame, vcrc;
    logic        vcap_arm;  // a write of register 34 with bit 1 set, below
    logic        v_req, v_crc_ok, v_crc_t;
    logic [31:0] v_crc;
    logic [15:0] v_shown, v_late, v_overrun, v_gaps;
    logic        pcm_valid;
    logic [15:0] pcm;
    logic [31:0] pcm_crc, pcm_n;

    wire v_waiting = pace_wait && ctrl[0] && !rst && !busy && !at_limit && !line_busy;

    always_ff @(posedge clk) begin
        v_crc_seen <= v_crc_t;
        if (frame_done && vid_pace)
            pace_wait <= 1'b1;
        if (v_req && v_waiting) begin
            pace_wait <= 1'b0;
            if (vcap_armed && frames == vcap_frame) begin
                v_cap_t    <= !v_cap_t;
                vcap_armed <= 1'b0;
                vcap_wait  <= 1'b1;
            end
        end
        if (v_crc_t != v_crc_seen && vcap_wait) begin
            vcrc       <= v_crc;
            vcap_ok    <= v_crc_ok;
            vcap_valid <= 1'b1;
            vcap_wait  <= 1'b0;
        end
        if (vcap_arm) begin
            vcap_armed <= 1'b1;
            vcap_wait  <= 1'b0;
            vcap_valid <= 1'b0;
        end
        if (rst || !vid_pace)
            pace_wait <= 1'b0;
        if (por_rst) begin
            v_cap_t    <= 1'b0;
            vcap_armed <= 1'b0;
            vcap_wait  <= 1'b0;
            vcap_valid <= 1'b0;
            vcap_ok    <= 1'b0;
            vcrc       <= '0;
        end
    end

    // The CRC of every 48 kHz sample made since reset (16 bits, little-endian), and their count.
    crc32 #(.W(16)) u_pcrc (.clk, .rst, .en(pcm_valid), .data(pcm), .crc(pcm_crc), .st_we(1'b0), .st_wdata(32'd0));
    always_ff @(posedge clk)
        if (rst) pcm_n <= '0;
        else if (pcm_valid) pcm_n <= pcm_n + 32'd1;

    if (VIDEO) begin : g_video
        a2600_video u_video (
            .clk, .rst, .vw_we, .vw_y, .vw_w, .vw_d, .row_done, .frame_done,
            .waiting(v_waiting), .req(v_req),
            .a_ce(cc && bus_ce), .a_level(5'(aud0) + 5'(aud1)),
            .cap_t(v_cap_t), .crc(v_crc), .crc_ok(v_crc_ok), .crc_t(v_crc_t),
            .shown(v_shown), .late(v_late), .overrun(v_overrun), .gaps(v_gaps), .pcm_valid, .pcm,
            .pclk, .tmds0, .tmds1, .tmds2);
    end else begin : g_no_video
        assign v_req     = 1'b0;
        assign v_crc     = '0;
        assign v_crc_ok  = 1'b0;
        assign v_crc_t   = 1'b0;
        assign v_shown   = '0;
        assign v_late    = '0;
        assign v_overrun = '0;
        assign v_gaps    = '0;
        assign pcm_valid = 1'b0;
        assign pcm       = '0;
        assign tmds0     = '0;
        assign tmds1     = '0;
        assign tmds2     = '0;
        wire unused_video = &{1'b0, pclk, vw_we, vw_y, vw_w, vw_d, row_done, v_waiting, v_cap_t};
    end

    // ---- The shell's bus ----
    wire       sh_reg = s_req && s_addr[31:24] == 8'h01 && s_addr[23:7] == '0;
    wire [6:0] r = s_addr[6:0];

    function automatic logic [7:0] byte_of(input logic [31:0] v, input logic [1:0] b);
        byte_of = v[8 * b +: 8];
    endfunction

    logic [7:0] reg_q;
    always_comb begin
        reg_q = 8'd0;
        case (r[6:2])
            5'h00: reg_q = r[1:0] == 2'd0 ? {6'd0, ctrl} : 8'd0;
            5'h01: reg_q = byte_of(stop_cycle, r[1:0]);
            5'h02: reg_q = byte_of(cycles, r[1:0]);
            5'h03: reg_q = r[1:0] == 2'd0 ? {3'd0, vcap_valid, busy, crc_frame != 0, running, at_limit} : 8'd0;
            5'h04: reg_q = byte_of(stop_frame, r[1:0]);
            5'h05: reg_q = byte_of(frames, r[1:0]);
            5'h06: reg_q = byte_of(frame_crc, r[1:0]);
            5'h07: reg_q = byte_of(crc_frame, r[1:0]);
            5'h08: reg_q = byte_of(audio_crc, r[1:0]);
            5'h09: reg_q = byte_of(samples, r[1:0]);
            5'h0A: reg_q = byte_of(audio_limit, r[1:0]);
            5'h0B: reg_q = byte_of({4'd0, paddle_on, 6'd0, fire_n, switches, joy}, r[1:0]);
            5'h0C: reg_q = byte_of(paddle_pos, r[1:0]);
            5'h0D: reg_q = byte_of({15'd0, vcap_ok, 14'd0, vcap_armed, vid_pace}, r[1:0]);
            5'h0E: reg_q = byte_of(vcap_frame, r[1:0]);
            5'h0F: reg_q = byte_of(vcrc, r[1:0]);
            5'h10: reg_q = byte_of({v_late, v_shown}, r[1:0]);
            5'h11: reg_q = byte_of({v_gaps, v_overrun}, r[1:0]);
            5'h12: reg_q = byte_of(pcm_crc, r[1:0]);
            5'h13: reg_q = byte_of(pcm_n, r[1:0]);
            5'h14: reg_q = byte_of({7'd0, ROM_EXT, 8'(ROM_LOG2), 3'd0, cart_size, 3'd0, cart_sc, cart_scheme}, r[1:0]);
            default: ;
        endcase
    end

    function automatic logic [31:0] set_byte(input logic [31:0] v, input logic [1:0] b, input logic [7:0] d);
        set_byte = v;
        set_byte[8 * b +: 8] = d;
    endfunction

    always_ff @(posedge clk) begin
        s_ack <= 1'b0;
        if (por_rst) begin
            ctrl        <= 2'b10;
            stop_cycle  <= '0;
            stop_frame  <= '0;
            audio_limit <= '0;
            joy         <= 8'hFF;
            switches    <= 8'hFF;
            fire_n      <= 2'b11;
            paddle_on   <= '0;
            paddle_pos  <= '0;
            vid_pace    <= 1'b0;
            vcap_frame  <= '0;
            cart_scheme <= '0;
            cart_sc     <= 1'b0;
            cart_size   <= 5'd12;
        end else if (s_req && !s_ack) begin
            if (sh_fb) begin
                if (fb_ack) begin
                    s_ack   <= 1'b1;
                    s_rdata <= fb_data;
                end
            end else if (sh_cart) begin
                if (cart_sh_ack) begin
                    s_ack   <= 1'b1;
                    s_rdata <= cart_sh;
                end
            end else begin
                s_ack   <= 1'b1;
                s_rdata <= sh_reg ? reg_q : 8'd0;
                if (sh_reg && s_we)
                    case (r[6:2])
                        5'h00: if (r[1:0] == 2'd0) ctrl <= s_wdata[1:0];
                        5'h01: stop_cycle  <= set_byte(stop_cycle, r[1:0], s_wdata);
                        5'h04: stop_frame  <= set_byte(stop_frame, r[1:0], s_wdata);
                        5'h0A: audio_limit <= set_byte(audio_limit, r[1:0], s_wdata);
                        5'h0D: if (r[1:0] == 2'd0) vid_pace <= s_wdata[0];
                        5'h0E: vcap_frame  <= set_byte(vcap_frame, r[1:0], s_wdata);
                        5'h0B: case (r[1:0])
                                  2'd0: joy       <= s_wdata;
                                  2'd1: switches  <= s_wdata;
                                  2'd2: fire_n    <= s_wdata[1:0];
                                  2'd3: paddle_on <= s_wdata[3:0];
                              endcase
                        5'h0C: paddle_pos <= set_byte(paddle_pos, r[1:0], s_wdata);
                        5'h14: case (r[1:0])
                                  2'd0: {cart_sc, cart_scheme} <= s_wdata[4:0];
                                  2'd1: cart_size <= s_wdata[4:0];
                                  default: ;
                              endcase
                        default: ;
                    endcase
            end
        end
    end

    assign vcap_arm = s_req && !s_ack && sh_reg && s_we && r == 7'h34 && s_wdata[1];

    // ---- LEDs ----
    logic       bad_frame, stalled;
    logic [24:0] beat;
    always_ff @(posedge clk)
        if (por_rst) begin
            bad_frame <= 1'b0;
            stalled   <= 1'b0;
            beat      <= '0;
        end else begin
            if (crc_error) bad_frame <= 1'b1;
            if (timeout) stalled <= 1'b1;
            beat <= beat + 25'd1;
        end
    assign led = ~{beat[24], at_limit, running, 1'b0, stalled, bad_frame};

    wire unused = &{1'b0, cart_addr, cart_sel, cart_we, cart_wdata, vblank, cpu_sync, cpu_pc};
endmodule
