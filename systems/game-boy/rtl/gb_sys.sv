// SPDX-License-Identifier: Apache-2.0
// The Game Boy (gameboy) under the test shell: its cartridge's controller and
// RAM (gb_cart, set from the cartridge's header by register 50) with the ROM in
// block RAM or, with ROM_EXT, in an outside memory on `mem_*` (a byte port as
// memory/sdram's, from address 0), the boot ROM loaded by the host, run and stop by
// register, and what a board can give the host to check: the serial port's
// bytes (where blargg's and Mooneye's ROMs report) and the CRC of the frame it
// stopped on, as gb_frames.py takes MesenCE's, so the host compares it with
// the golden list without taking the picture over the link.
//
// T-cycles come at T_NUM/T_DEN of the clock (clock_enable), at least 2
// clocks apart, while the system runs. It stops between T-cycles, so stopping
// and starting leave it exactly as if it had run on: the same on any board and
// in the sim. With ROM_EXT, the M-cycle's last T-cycle also waits while the
// cartridge is fetching a ROM byte its access reads (clock_enable's hold), so
// only a fetch that isn't done three T-cycles after its address came costs
// time; register 54 counts the clocks lost.
//
// Frames end as MesenCE ends them, so a frame number means the same moment in both (and
// gb_roms_test counts them alike): as VBlank starts (the PPU's frame_end), as the LCD turns off
// outside VBlank (frame_cut), and with the LCD off, each time 70,224 dots have passed since it
// went off or since the last such frame (a blank frame); never at a count running on from
// before the LCD went on. The frame buffer holds each pixel's shade (or on the Game Boy Color,
// its 15-bit colour) as the PPU last drew it, and turns white as MesenCE's screen does: at a
// blank frame, and at the first frame to end after the LCD goes on (on the Color, only if it
// was off more than 5,000 dots). MesenCE keeps two screens, so a frame cut short shows the
// frame before last under the cut where this shows the last; a check doesn't land there. When the system stops at a limit, it takes the CRC of the frame buffer (2 bytes a pixel,
// little-endian, row by row: as gb_frames.py takes MesenCE's), about 23,000 clocks, and starts no
// T-cycle until that's done.
//
// Register 50's bit 5 makes it a Game Boy Color (gameboy's `cgb_hw`), from the next reset; with
// CGB clear the Color isn't built (register 2C's byte 2 says which), and the frame buffer holds
// shades only.
//
// Shell address map (README.md has the registers):
//   0x00000000-...         the cartridge's ROM, 2^ROM_LOG2 bytes, written and read while held in reset
//   0x01000000-0x0100007F  control and status registers
//   0x02000000-...         the cartridge's RAM, 2^CRAM_LOG2 bytes, written and read while held in reset;
//                          read too while stopped at a limit (a battery game's save, as it plays)
//   0x03000000-0x03000FFF  the boot ROM (256 bytes, or the Color's 2,304), written and read while held in reset
//   0x04000000-0x040007FF  the serial port's bytes: byte n at n mod 2048
//   0x05000000-0x0500B3FF  the frame buffer: 2 bytes a pixel at 2 (y x 160 + x), the shade (0 white to 3)
//                          or colour, little-endian
//   0x06000000-0x0600000C  the cartridge's clock (MBC3's; gb_cart's shell bytes), while held in reset
// The sound's CRC (register 30) is of the APU's two mixes at each M-cycle's end since reset, each
// as a 16-bit little-endian word, left then right, as gb_roms_test takes it. With VIDEO, the mixes
// go to 48 kHz (audio/resampler: 800 samples a frame of 17,556 M-cycles, against the 60 Hz
// display the system keeps pace with) and out with the picture.
// With VIDEO set, the picture goes out as HDMI at 720p (gb_video, on `pclk`), and with pacing on
// (register 34) the system keeps pace with the display: it waits at each frame's end until the
// display asks for the next, a stop between T-cycles like the others. The video CRC is of the
// display frame that starts frame `vcap_frame` + 1 (frames, at that request, equal to it).
//
// LEDs (active low): led[0] a corrupt command frame, led[1] a stalled one,
// led[3] running, led[4] stopped at a limit, led[5] heartbeat.

module gb_sys #(
    parameter int          CLKS_PER_BIT = 18,       // 27 MHz / 18 = 1.5 Mbaud
    parameter int          IDLE_CLKS    = 270_000,  // 10 ms at 27 MHz
    parameter int          T_NUM        = 65_536,   // T-cycles per T_DEN clocks: the console's
    parameter int          T_DEN        = 421_875,  //   4.194304 MHz from 27 MHz
    parameter bit          VIDEO        = 1'b0,     // HDMI out (gb_video), on pclk
    parameter bit          CGB          = 1'b1,     // the Game Boy Color too
    parameter int          ROM_LOG2     = 15,       // room for the cartridge's ROM: 2^ROM_LOG2 bytes (up to 23)
    parameter bit          ROM_EXT      = 1'b0,     // the ROM on mem_*, not in block RAM
    parameter int          CRAM_LOG2    = 15,       // room for its RAM, in block RAM
    parameter logic [31:0] BUILD_ID     = '0
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
    output logic [22:0] mem_addr,
    output logic [7:0]  mem_wdata,
    input  logic        mem_ack,
    input  logic [7:0]  mem_rdata
);
    localparam int W = 160, H = 144;
    localparam int T_PER_FRAME = 70_224;

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
    logic [1:0]  ctrl;        // 00: bit 0 run, bit 1 hold in reset
    logic [31:0] stop_cycle;  // 04: T-cycles
    logic [31:0] stop_frame;  // 10
    logic [7:0]  keys;        // 24: 1 pressed, gameboy's `keys`
    logic [20:0] cart_cfg;    // 50: gb_cart's mbc (bits 2-0), rtc (3), rumble (4), the Color (5),
                              //     rom_log2 (12-8), ram_log2 (20-16)

    wire rst = por_rst || ctrl[1];

    logic [31:0] cycles, frames, frame_crc, crc_frame, ser_count;
    logic        scanning, pace_wait;
    wire at_limit = (stop_cycle != 0 && cycles >= stop_cycle) || (stop_frame != 0 && frames >= stop_frame);
    logic ram_clearing;  // the console zeroing its RAM after a reset
    wire running  = ctrl[0] && !rst && !ram_clearing && !scanning && !at_limit && !pace_wait;

    // ---- T-cycles ----
    logic ce, ce_held;
    logic cart_wait;
    clock_enable #(.NUM(T_NUM), .DEN(T_DEN)) u_ce (.clk, .rst, .en(running), .hold(cart_wait), .ce, .held(ce_held));

    // ---- The system ----
    logic [15:0] cart_addr, cpu_pc;
    logic        cart_rd, cart_wr, m_end, m_last, cpu_sync, boot_on;
    logic [7:0]  cart_wdata, cart_rdata, ser_tx, lcdc;
    logic        ser_tx_valid;
    logic        boot_we;
    logic [11:0] boot_addr;
    logic [7:0]  boot_wdata, boot_sh;
    logic        pix_we, frame_end, frame_cut;
    logic [7:0]  pix_x, pix_y;
    logic [14:0] pix_color;
    logic signed [9:0] aud_l, aud_r;
    localparam int FB_W = CGB ? 15 : 2;  // the frame buffer's bits a pixel
    gameboy #(.CGB(CGB)) u_gb (
        .clk, .rst, .ce, .cgb_hw_in(cart_cfg[5]), .clearing(ram_clearing), .dbl_speed,
        .cart_addr, .cart_rd, .cart_wr, .cart_wdata, .cart_rdata,
        .boot_we, .boot_addr, .boot_wdata, .boot_q(boot_sh),
        .keys, .ser_tx, .ser_tx_valid,
        .m_end, .m_last, .cpu_sync, .cpu_pc, .boot_on, .lcdc,
        .pix_we, .pix_x, .pix_y, .pix_color, .frame_end, .frame_cut, .aud_l, .aud_r);

    // ---- The sound's CRC ----
    logic [31:0] snd_crc;
    wire         m_tick = ce && m_end;
    crc32 #(.W(32)) u_scrc (.clk, .rst, .en(m_tick), .data({16'(aud_r), 16'(aud_l)}),
                            .crc(snd_crc), .st_we(1'b0), .st_wdata(32'd0));

    // ---- The cartridge: its controller and RAM (gb_cart), and the ROM ----
    wire sh_rom  = s_req && s_addr[31:24] == 8'h00 && s_addr[23:ROM_LOG2] == '0;
    wire sh_cram = s_req && s_addr[31:24] == 8'h02 && s_addr[23:CRAM_LOG2] == '0;
    wire sh_rtc  = s_req && s_addr[31:24] == 8'h06 && s_addr[23:4] == '0;
    logic [22:0] rom_full;
    logic [7:0]  rom_q, rom_sh, cart_sh;
    logic        rom_sh_ack;  // with ROM_EXT, the shell's ROM access is done

    // The shell writes the RAM and clock only while the system is held in reset, through gb_cart's
    // port; it reads them through the same port then, and the RAM while the system is stopped at a
    // limit too (a battery game's save as it plays: `ce` is low until a shell write lets it run on,
    // long after, by when the RAM's output is the CPU's byte again).
    gb_cart #(.ROM_AW(23), .RAM_AW(CRAM_LOG2)) u_cart (
        .clk, .rst, .ce,
        .mbc(cart_cfg[2:0]), .rtc(cart_cfg[3]), .rumble(cart_cfg[4]),
        .rom_log2(cart_cfg[12:8]), .ram_log2(cart_cfg[20:16]),
        .addr(cart_addr), .wr(cart_wr), .wdata(cart_wdata), .rdata(cart_rdata),
        .rom_addr(rom_full), .rom_q,
        .sh_rd(at_limit && sh_cram && !s_we), .sh_we(rst && (sh_cram || sh_rtc) && s_we && !s_ack), .sh_rtc(sh_rtc),
        .sh_addr(17'(s_addr[CRAM_LOG2 > 4 ? CRAM_LOG2 - 1 : 3:0])), .sh_wdata(s_wdata), .sh_q(cart_sh));
    wire [ROM_LOG2-1:0] rom_a = rom_full[ROM_LOG2-1:0];
    wire                rom_rd = cart_rd && !cart_addr[15];  // this M-cycle reads the ROM

    if (!ROM_EXT) begin : g_rom_bram
        // A port that writes only for the shell: with Yosys, an 8-bit memory whose writing port also
        // reads takes twice the Gowin parts' block RAM.
        logic [7:0] rom [0:(1 << ROM_LOG2) - 1];
        always_ff @(posedge clk) begin
            rom_q <= rom[rst ? s_addr[ROM_LOG2-1:0] : rom_a];
            if (sh_rom && s_we && !s_ack) rom[s_addr[ROM_LOG2-1:0]] <= s_wdata;
        end
        assign rom_sh     = rom_q;
        assign rom_sh_ack = 1'b0;
        assign cart_wait  = 1'b0;
        assign mem_req    = 1'b0;
        assign mem_we     = 1'b0;
        assign mem_addr   = '0;
        assign mem_wdata  = '0;
        wire unused_mem = &{1'b0, mem_ack, mem_rdata, rom_rd, m_last};
    end else begin : g_rom_ext
        // A ROM read's byte, fetched as its address comes and held; the M-cycle's last T-cycle waits
        // until it has been here a clock (gameboy takes it a clock before that T-cycle ends, and the
        // DMA at it). The wait is decided from registers (whether the access reads the ROM, and
        // whether its byte has been here two clocks, as of the clock before), since `ce` reaches
        // nearly every register: decided from the address, it put the CPU's address decode and the
        // bank's mux in front of the whole system (the 138K's and PYNQ-Z2's system clocks fell to
        // within 2% of their rates). A clock old is still exact: the address and `rd` change only
        // at a T-cycle, at least 2 clocks before the next. The shell's accesses take the port
        // between fetches. Reset by `por_rst` only: an access the memory has started must finish.
        logic                busy, for_sh, f_valid, have_q, rd_q, ok_q;
        logic [ROM_LOG2-1:0] f_ra;
        wire                 have = f_valid && f_ra == rom_a;
        always_ff @(posedge clk) begin
            have_q <= have;
            rd_q   <= rom_rd;
            ok_q   <= have && have_q;
            if (!busy) begin
                if (sh_rom && !s_ack && !rom_sh_ack) begin
                    busy      <= 1'b1;
                    for_sh    <= 1'b1;
                    mem_we    <= s_we;
                    mem_addr  <= 23'(s_addr[ROM_LOG2-1:0]);
                    mem_wdata <= s_wdata;
                    if (s_we) f_valid <= 1'b0;
                end else if (!rst && rom_rd && !have) begin
                    busy     <= 1'b1;
                    for_sh   <= 1'b0;
                    mem_we   <= 1'b0;
                    mem_addr <= 23'(rom_a);
                end
            end else if (mem_ack) begin
                busy <= 1'b0;
                if (!for_sh) begin
                    rom_q   <= mem_rdata;
                    f_ra    <= ROM_LOG2'(mem_addr);
                    f_valid <= 1'b1;
                end
            end
            if (por_rst) begin
                busy    <= 1'b0;
                f_valid <= 1'b0;
            end
        end
        assign mem_req    = busy;
        assign rom_sh_ack = busy && for_sh && mem_ack;
        assign rom_sh     = mem_rdata;
        assign cart_wait  = m_last && rd_q && !ok_q;
    end

    // The first 4 bytes of cartridge RAM as the system last wrote them ($FF from reset), where
    // blargg's newer ROMs report, for the host to read while the system runs (register 44).
    logic [31:0] cram_head;
    always_ff @(posedge clk)
        if (rst) cram_head <= '1;
        else if (cart_wr && cart_addr[15:13] == 3'b101 && cart_addr[12:2] == '0)
            cram_head[8 * cart_addr[1:0] +: 8] <= cart_wdata;

    // The T-cycles in which the system has written cartridge RAM since reset (register 58): the
    // host sees a battery game save when it changes. Counted with `ce`, so not while stopped.
    logic [31:0] cram_writes;
    always_ff @(posedge clk)
        if (rst) cram_writes <= '0;
        else if (ce && cart_wr && cart_addr[15:13] == 3'b101) cram_writes <= cram_writes + 32'd1;

    // The clocks the M-cycles' last T-cycles have waited on the ROM since reset (register 54).
    logic [31:0] waits;
    always_ff @(posedge clk)
        if (rst) waits <= '0;
        else if (ce_held) waits <= waits + 32'd1;

    // ---- The boot ROM: written into the system while it's held in reset, and read back from it
    // then (gameboy reads it at boot_addr in reset) ----
    wire        sh_boot = s_req && s_addr[31:24] == 8'h03 && s_addr[23:12] == '0;
    assign boot_we    = rst && sh_boot && s_we && !s_ack;
    assign boot_addr  = s_addr[11:0];
    assign boot_wdata = s_wdata;

    // ---- The serial port's bytes ----
    logic [7:0] ser_buf [0:2047];
    logic [7:0] ser_sh;
    wire        sh_ser = s_req && s_addr[31:24] == 8'h04 && s_addr[23:11] == '0;
    always_ff @(posedge clk) begin
        if (ser_tx_valid) ser_buf[ser_count[10:0]] <= ser_tx;
        ser_sh <= ser_buf[s_addr[10:0]];
    end

    // ---- Counts and frames ----
    // t_off: dots since the LCD went off or the last blank frame, counting this one (the LCD is
    // off from reset, as MesenCE's count starts at power-on); it holds while the LCD is on. MesenCE
    // sends a blank frame once its count is more than a frame's dots past the last frame, its count
    // stepping 2 dots at a time at normal speed and 1 at double speed: 70,226 dots, or 70,225.
    logic [16:0] t_off;
    logic        lcd_was, white_next, dbl_speed;
    wire         lcd_on     = lcdc[7];
    wire         blank      = ce && !lcd_on && !lcd_was && t_off == 17'(T_PER_FRAME + (dbl_speed ? 1 : 2));
    wire         frame_done = ce && (frame_end || frame_cut || blank);
    wire         white      = frame_done && (blank || white_next);  // the frame buffer turns white
    always_ff @(posedge clk)
        if (rst) begin
            cycles     <= '0;
            frames     <= '0;
            t_off      <= 17'd1;
            lcd_was    <= 1'b0;
            white_next <= 1'b0;
            ser_count  <= '0;
        end else begin
            if (ce) begin
                cycles  <= cycles + 32'd1;
                lcd_was <= lcd_on;
                if (!lcd_on) t_off <= lcd_was || blank ? 17'd1 : t_off + 17'd1;
                if (frame_done) white_next <= 1'b0;
                if (lcd_on && !lcd_was) white_next <= !(CGB && cart_cfg[5]) || t_off > 17'd5000;
            end
            if (frame_done) frames <= frames + 32'd1;
            if (ser_tx_valid) ser_count <= ser_count + 32'd1;
        end

    // ---- The frame buffer and its CRC ----
    // One port on clk: the PPU writes it, the shell reads it between the PPU's writes, and the
    // CRC's scan reads it while the system is stopped at a limit (a shell read waits until the scan
    // is done). With VIDEO, the display reads it through the other, on pclk (gb_video).
    logic [FB_W-1:0] fb [0:W * H - 1];
    logic [14:0] fb_q;
    logic [14:0] scan_addr;
    logic        scan_take, crc_done, fb_w_d, sh_hi;
    wire  [14:0] pix_addr = 15'({pix_y, 7'd0}) + 15'({pix_y, 5'd0}) + 15'(pix_x);
    wire         fb_w     = pix_we && pix_x < 8'(W) && pix_y < 8'(H);
    wire         sh_fb    = s_req && !s_we && s_addr[31:24] == 8'h05 && s_addr[23:16] == '0;
    // Turning white: a write a clock, from the first pixel, when neither the PPU nor a shell read
    // has the port. It's done in 23,040 clocks or so, about 2,600 dots: well ahead of the PPU,
    // which starts again no sooner than the next line 0 and writes a pixel a dot at most; the CRC's
    // scan waits for it.
    logic        clearing;
    logic [14:0] clr_addr;
    wire         clr_w    = clearing && !fb_w && !(s_req && !s_ack && sh_fb);
    wire  [14:0] fb_a     = fb_w ? pix_addr : clr_w ? clr_addr : scanning ? scan_addr : s_addr[15:1];
    wire  [FB_W-1:0] white_c = CGB && cart_cfg[5] ? '1 : '0;  // the Color's white (7FFF), or shade 0
    always_ff @(posedge clk)
        if (rst) begin
            clearing <= 1'b0;
            clr_addr <= '0;
        end else if (white) begin
            clearing <= 1'b1;
            clr_addr <= '0;
        end else if (clr_w) begin
            clr_addr <= clr_addr + 15'd1;
            if (clr_addr == 15'(W * H - 1)) clearing <= 1'b0;
        end
    always_ff @(posedge clk) begin
        fb_w_d <= fb_w;
        sh_hi  <= s_addr[0];
        if (fb_w || clr_w) begin
            fb[fb_a] <= fb_w ? pix_color[FB_W-1:0] : white_c;
            fb_q     <= 15'(fb_w ? pix_color[FB_W-1:0] : white_c);
        end else
            fb_q <= 15'(fb[fb_a]);
    end

    logic [31:0] scan_crc;
    crc32 #(.W(16)) u_fcrc (.clk, .rst(rst || !scanning), .en(scan_take), .data({1'b0, fb_q}),
                            .crc(scan_crc), .st_we(1'b0), .st_wdata(32'd0));
    always_ff @(posedge clk)
        if (rst) begin
            scanning  <= 1'b0;
            scan_take <= 1'b0;
            scan_addr <= '0;
            crc_done  <= 1'b0;
            crc_frame <= '0;
            frame_crc <= '0;
        end else begin
            scan_take <= scanning && scan_addr < 15'(W * H);
            if (ce) crc_done <= 1'b0;
            if (!scanning && !clearing && at_limit && ctrl[0] && !crc_done) begin
                scanning  <= 1'b1;
                scan_addr <= '0;
            end else if (scanning) begin
                if (scan_addr < 15'(W * H)) scan_addr <= scan_addr + 15'd1;
                // The last byte's CRC is in once the take after it is.
                if (scan_addr == 15'(W * H) && !scan_take) begin
                    scanning  <= 1'b0;
                    crc_done  <= 1'b1;
                    frame_crc <= scan_crc;
                    crc_frame <= frames;
                end
            end
        end

    // ---- The sound sent to HDMI: the CRC of its sample pairs (left then right, each 16-bit
    // little-endian) and their count since reset, registers 48 and 4C (0 without VIDEO) ----
    logic        pcm_v;
    logic [31:0] pcm_lr, pcm_crc, pcm_n;
    crc32 #(.W(32)) u_pcrc (.clk, .rst, .en(pcm_v), .data(pcm_lr), .crc(pcm_crc), .st_we(1'b0), .st_wdata(32'd0));
    always_ff @(posedge clk)
        if (rst) pcm_n <= '0;
        else if (pcm_v) pcm_n <= pcm_n + 32'd1;

    // ---- Display pacing and the video CRC (a2600_sys's) ----
    logic        vid_pace, vcap_armed, vcap_wait, vcap_valid, vcap_ok, v_crc_seen, v_cap_t;
    logic [31:0] vcap_frame, vcrc;
    logic        vcap_arm;  // a write of register 34 with bit 1 set, below
    logic        v_req, v_crc_ok, v_crc_t;
    logic [31:0] v_crc;
    logic [15:0] v_shown, v_late;

    wire v_waiting = pace_wait && ctrl[0] && !rst && !scanning && !at_limit;

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

    if (VIDEO) begin : g_video
        logic [14:0] v_ra;
        logic [14:0] v_q;
        always_ff @(posedge pclk)
            v_q <= 15'(fb[v_ra]);
        // The mixes, -480 to 480, to 48 kHz: unsigned for the resampler, which centres them.
        logic        a_vl;
        logic [15:0] a_l, a_r;
        /* verilator lint_off UNUSEDSIGNAL */
        logic        a_vr, a_bl, a_br;   // the right side's resampler keeps step with the left's
        logic [31:0] a_stl, a_str;
        /* verilator lint_on UNUSEDSIGNAL */
        resampler #(.NUM(200), .DEN(4389), .SAVE_STATE(1'b0)) u_rsl (
            .clk, .rst, .ce(m_tick), .in(16'((16'(aud_l) + 16'sd512) << 6)), .valid(a_vl), .busy(a_bl), .out(a_l),
            .st_addr(2'd0), .st_rdata(a_stl), .st_we(1'b0), .st_wdata(32'd0));
        resampler #(.NUM(200), .DEN(4389), .SAVE_STATE(1'b0)) u_rsr (
            .clk, .rst, .ce(m_tick), .in(16'((16'(aud_r) + 16'sd512) << 6)), .valid(a_vr), .busy(a_br), .out(a_r),
            .st_addr(2'd0), .st_rdata(a_str), .st_we(1'b0), .st_wdata(32'd0));
        assign pcm_v  = a_vl;
        assign pcm_lr = {a_r, a_l};
        gb_video #(.CGB(CGB)) u_video (
            .clk, .rst, .ce, .frame_done, .fb_ra(v_ra), .fb_q(v_q), .cgb_hw(cart_cfg[5]),
            .a_valid(a_vl), .a_l, .a_r,
            .waiting(v_waiting), .req(v_req),
            .cap_t(v_cap_t), .crc(v_crc), .crc_ok(v_crc_ok), .crc_t(v_crc_t),
            .shown(v_shown), .late(v_late),
            .pclk, .tmds0, .tmds1, .tmds2);
    end else begin : g_no_video
        assign v_req    = 1'b0;
        assign v_crc    = '0;
        assign v_crc_ok = 1'b0;
        assign v_crc_t  = 1'b0;
        assign v_shown  = '0;
        assign pcm_v    = 1'b0;
        assign pcm_lr   = '0;
        assign v_late   = '0;
        assign tmds0    = '0;
        assign tmds1    = '0;
        assign tmds2    = '0;
        wire unused_video = &{1'b0, pclk, v_waiting, v_cap_t};
    end

    // ---- The shell's bus ----
    wire       sh_reg = s_req && s_addr[31:24] == 8'h01 && s_addr[23:7] == '0;
    wire [6:0] r = s_addr[6:0];

    function automatic logic [7:0] byte_of(input logic [31:0] v, input logic [1:0] b);
        byte_of = v[8 * b +: 8];
    endfunction

    function automatic logic [31:0] set_byte(input logic [31:0] v, input logic [1:0] b, input logic [7:0] d);
        set_byte = v;
        set_byte[8 * b +: 8] = d;
    endfunction

    logic [7:0] reg_q;
    always_comb begin
        reg_q = 8'd0;
        case (r[6:2])
            5'h00: reg_q = r[1:0] == 2'd0 ? {6'd0, ctrl} : 8'd0;
            5'h01: reg_q = byte_of(stop_cycle, r[1:0]);
            5'h02: reg_q = byte_of(cycles, r[1:0]);
            5'h03: reg_q = r[1:0] == 2'd0 ? {3'd0, vcap_valid, scanning, crc_done, running, at_limit} : 8'd0;
            5'h04: reg_q = byte_of(stop_frame, r[1:0]);
            5'h05: reg_q = byte_of(frames, r[1:0]);
            5'h06: reg_q = byte_of(frame_crc, r[1:0]);
            5'h07: reg_q = byte_of(crc_frame, r[1:0]);
            5'h08: reg_q = byte_of(ser_count, r[1:0]);
            5'h09: reg_q = byte_of({24'd0, keys}, r[1:0]);
            5'h0A: reg_q = byte_of({cpu_pc, 7'd0, boot_on, lcdc}, r[1:0]);
            5'h0B: reg_q = byte_of({15'd0, CGB, 8'(CRAM_LOG2), 8'(ROM_LOG2)}, r[1:0]);
            5'h0C: reg_q = byte_of(snd_crc, r[1:0]);
            5'h0D: reg_q = byte_of({15'd0, vcap_ok, 14'd0, vcap_armed, vid_pace}, r[1:0]);
            5'h0E: reg_q = byte_of(vcap_frame, r[1:0]);
            5'h0F: reg_q = byte_of(vcrc, r[1:0]);
            5'h10: reg_q = byte_of({v_late, v_shown}, r[1:0]);
            5'h11: reg_q = byte_of(cram_head, r[1:0]);
            5'h12: reg_q = byte_of(pcm_crc, r[1:0]);
            5'h13: reg_q = byte_of(pcm_n, r[1:0]);
            5'h14: reg_q = byte_of({11'd0, cart_cfg}, r[1:0]);
            5'h15: reg_q = byte_of(waits, r[1:0]);
            5'h16: reg_q = byte_of(cram_writes, r[1:0]);
            default: ;
        endcase
    end

    // A read of a memory takes its registered output a clock after the address came.
    logic sh_wait;
    always_ff @(posedge clk) begin
        s_ack <= 1'b0;
        if (por_rst) begin
            ctrl       <= 2'b10;
            stop_cycle <= '0;
            stop_frame <= '0;
            vid_pace   <= 1'b0;
            vcap_frame <= '0;
            keys       <= '0;
            cart_cfg   <= {5'd0, 3'd0, 5'd15, 8'd0};
            sh_wait    <= 1'b0;
        end else if (s_req && !s_ack) begin
            if (ROM_EXT && sh_rom) begin
                if (rom_sh_ack) begin
                    s_ack   <= 1'b1;
                    s_rdata <= rom_sh;
                end
            end else if (sh_rom || sh_cram || sh_rtc || sh_boot || sh_ser || sh_fb) begin
                // A frame buffer read the clock after a pixel's write (which took the port) reads
                // again; writes come at least 2 clocks apart.
                sh_wait <= sh_wait ? sh_fb && fb_w_d : !(sh_fb && scanning);
                if (sh_wait && !(sh_fb && fb_w_d)) begin
                    s_ack   <= 1'b1;
                    s_rdata <= sh_rom ? rom_sh : sh_cram || sh_rtc ? cart_sh : sh_boot ? boot_sh : sh_ser ? ser_sh :
                               sh_hi ? {1'b0, fb_q[14:8]} : fb_q[7:0];
                end
            end else begin
                s_ack   <= 1'b1;
                s_rdata <= sh_reg ? reg_q : 8'd0;
                if (sh_reg && s_we)
                    case (r[6:2])
                        5'h00: if (r[1:0] == 2'd0) ctrl <= s_wdata[1:0];
                        5'h01: stop_cycle <= set_byte(stop_cycle, r[1:0], s_wdata);
                        5'h04: stop_frame <= set_byte(stop_frame, r[1:0], s_wdata);
                        5'h09: if (r[1:0] == 2'd0) keys <= s_wdata;
                        5'h0D: if (r[1:0] == 2'd0) vid_pace <= s_wdata[0];
                        5'h0E: vcap_frame <= set_byte(vcap_frame, r[1:0], s_wdata);
                        5'h14: if (r[1:0] != 2'd3) cart_cfg <= 21'(set_byte({11'd0, cart_cfg}, r[1:0], s_wdata));
                        default: ;
                    endcase
            end
        end
    end

    assign vcap_arm = s_req && !s_ack && sh_reg && s_we && r == 7'h34 && s_wdata[1];

    // ---- LEDs ----
    logic        bad_frame, stalled;
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

    wire unused = &{1'b0, cpu_sync, rom_full, pix_color};
endmodule
