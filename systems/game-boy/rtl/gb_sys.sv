// SPDX-License-Identifier: Apache-2.0
// The Game Boy (gameboy) under the test shell: a 32 KB cartridge with 8 KB of
// RAM in block RAM, the boot ROM loaded by the host, run and stop by
// register, and what a board can give the host to check: the serial port's
// bytes (where blargg's and Mooneye's ROMs report) and the CRC of the frame it
// stopped on, as gb_frames.py takes MesenCE's, so the host compares it with
// the golden list without taking the picture over the link.
//
// T-cycles come at T_NUM/T_DEN of the clock (clock_enable), at least 2
// clocks apart, while the system runs. It stops between T-cycles, so stopping
// and starting leave it exactly as if it had run on: the same on any board and
// in the sim.
//
// A frame ends as VBlank starts (the PPU's frame_end), or after 70,224
// T-cycles without one (the LCD off), as gb_roms_test counts them. The frame
// buffer holds each pixel's shade as the PPU last drew it. When the system
// stops at a limit, it takes the CRC of the frame buffer (2 bytes a pixel:
// the shade, then 0, row by row), about 23,000 clocks, and starts no T-cycle
// until that's done.
//
// Shell address map (README.md has the registers):
//   0x00000000-0x00007FFF  the cartridge's ROM, read while held in reset
//   0x01000000-0x0100007F  control and status registers
//   0x02000000-0x02001FFF  the cartridge's RAM ($A000-$BFFF), written and read while held in reset
//   0x03000000-0x030000FF  the boot ROM
//   0x04000000-0x040007FF  the serial port's bytes: byte n at n mod 2048
//   0x05000000-0x050059FF  the frame buffer: y x 160 + x, a shade (0 white to 3) a byte
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
    output logic [9:0] tmds2
);
    localparam int ROM_LOG2 = 15;
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

    wire rst = por_rst || ctrl[1];

    logic [31:0] cycles, frames, frame_crc, crc_frame, ser_count;
    logic        scanning, pace_wait;
    wire at_limit = (stop_cycle != 0 && cycles >= stop_cycle) || (stop_frame != 0 && frames >= stop_frame);
    wire running  = ctrl[0] && !rst && !scanning && !at_limit && !pace_wait;

    // ---- T-cycles ----
    logic ce;
    /* verilator lint_off UNUSEDSIGNAL */
    logic ce_held;
    /* verilator lint_on UNUSEDSIGNAL */
    clock_enable #(.NUM(T_NUM), .DEN(T_DEN)) u_ce (.clk, .rst, .en(running), .hold(1'b0), .ce, .held(ce_held));

    // ---- The system ----
    logic [15:0] cart_addr, cpu_pc;
    logic        cart_rd, cart_wr, m_end, cpu_sync, boot_on;
    logic [7:0]  cart_wdata, cart_rdata, ser_tx, lcdc;
    logic        ser_tx_valid;
    logic        boot_we;
    logic [7:0]  boot_addr, boot_wdata;
    logic        pix_we, frame_end;
    logic [7:0]  pix_x, pix_y;
    logic [1:0]  pix_shade;
    gameboy u_gb (
        .clk, .rst, .ce,
        .cart_addr, .cart_rd, .cart_wr, .cart_wdata, .cart_rdata,
        .boot_we, .boot_addr, .boot_wdata,
        .keys, .ser_tx, .ser_tx_valid,
        .m_end, .cpu_sync, .cpu_pc, .boot_on, .lcdc,
        .pix_we, .pix_x, .pix_y, .pix_shade, .frame_end);

    // ---- The cartridge: 32 KB of ROM and 8 KB of RAM. The system reads both every clock and takes
    // the one its address held. The shell writes the ROM through a port of its own, and the RAM
    // through the RAM's one write port while the system is held in reset; it reads both through the
    // system's port, which it takes while the system is held in reset (when the host loads and
    // checks them). A port that writes only: with Yosys, an 8-bit memory whose writing port also
    // reads takes twice the Gowin parts' block RAM.
    wire sh_rom  = s_req && s_addr[31:24] == 8'h00 && s_addr[23:ROM_LOG2] == '0;
    wire sh_cram = s_req && s_addr[31:24] == 8'h02 && s_addr[23:13] == '0;
    logic [7:0]  rom [0:(1 << ROM_LOG2) - 1];
    logic [7:0]  cram [0:8191];
    logic [7:0]  rom_q, cram_q, rom_sh, cram_sh;
    logic        cart_ram_d, cart_hi_d;
    wire         cart_ram = cart_addr[15:13] == 3'b101;
    wire [ROM_LOG2-1:0] rom_a = rst ? s_addr[ROM_LOG2-1:0] : cart_addr[ROM_LOG2-1:0];
    always_ff @(posedge clk) begin
        rom_q      <= rom[rom_a];
        cart_ram_d <= cart_ram;
        cart_hi_d  <= cart_addr[15];
    end
    // The RAM's write port is the shell's while the system is held in reset, the system's
    // otherwise: the shell writes nothing to it while the system runs.
    wire        cram_we = rst ? sh_cram && s_we && !s_ack : cart_wr && cart_ram;
    wire [12:0] cram_a  = rst ? s_addr[12:0] : cart_addr[12:0];
    wire [7:0]  cram_d  = rst ? s_wdata : cart_wdata;
    always_ff @(posedge clk) begin
        if (cram_we) cram[cram_a] <= cram_d;
        cram_q <= cram[cram_a];
    end
    assign cart_rdata = cart_ram_d ? cram_q : cart_hi_d ? 8'hFF : rom_q;

    always_ff @(posedge clk)
        if (sh_rom && s_we && !s_ack) rom[s_addr[ROM_LOG2-1:0]] <= s_wdata;
    assign rom_sh  = rom_q;
    assign cram_sh = cram_q;

    // ---- The boot ROM: written into the system, and kept here for the host to read back ----
    logic [7:0] boot [0:255];
    logic [7:0] boot_sh;
    wire        sh_boot = s_req && s_addr[31:24] == 8'h03 && s_addr[23:8] == '0;
    assign boot_we    = sh_boot && s_we && !s_ack;
    assign boot_addr  = s_addr[7:0];
    assign boot_wdata = s_wdata;
    always_ff @(posedge clk)
        if (boot_we) begin
            boot[s_addr[7:0]] <= s_wdata;
            boot_sh           <= s_wdata;
        end else
            boot_sh <= boot[s_addr[7:0]];

    // ---- The serial port's bytes ----
    logic [7:0] ser_buf [0:2047];
    logic [7:0] ser_sh;
    wire        sh_ser = s_req && s_addr[31:24] == 8'h04 && s_addr[23:11] == '0;
    always_ff @(posedge clk) begin
        if (ser_tx_valid) ser_buf[ser_count[10:0]] <= ser_tx;
        ser_sh <= ser_buf[s_addr[10:0]];
    end

    // ---- Counts and frames ----
    logic [16:0] t_in_frame;
    wire         frame_done = ce && (frame_end || t_in_frame == 17'(T_PER_FRAME - 1));
    always_ff @(posedge clk)
        if (rst) begin
            cycles     <= '0;
            frames     <= '0;
            t_in_frame <= '0;
            ser_count  <= '0;
        end else begin
            if (ce) cycles <= cycles + 32'd1;
            if (ce) t_in_frame <= frame_done ? '0 : t_in_frame + 17'd1;
            if (frame_done) frames <= frames + 32'd1;
            if (ser_tx_valid) ser_count <= ser_count + 32'd1;
        end

    // ---- The frame buffer and its CRC ----
    // One port on clk: the PPU writes it, the shell reads it between the PPU's writes, and the
    // CRC's scan reads it while the system is stopped at a limit (a shell read waits until the scan
    // is done). With VIDEO, the display reads it through the other, on pclk (gb_video).
    logic [1:0]  fb [0:W * H - 1];
    logic [1:0]  fb_q;
    logic [14:0] scan_addr;
    logic        scan_take, crc_done, fb_w_d;
    wire  [14:0] pix_addr = 15'({pix_y, 7'd0}) + 15'({pix_y, 5'd0}) + 15'(pix_x);
    wire         fb_w     = ce && pix_we && pix_x < 8'(W) && pix_y < 8'(H);
    wire         sh_fb    = s_req && !s_we && s_addr[31:24] == 8'h05 && s_addr[23:15] == '0;
    wire  [14:0] fb_a     = fb_w ? pix_addr : scanning ? scan_addr : s_addr[14:0];
    always_ff @(posedge clk) begin
        fb_w_d <= fb_w;
        if (fb_w) begin
            fb[fb_a] <= pix_shade;
            fb_q     <= pix_shade;
        end else
            fb_q <= fb[fb_a];
    end

    logic [31:0] scan_crc;
    crc32 #(.W(16)) u_fcrc (.clk, .rst(rst || !scanning), .en(scan_take), .data({14'd0, fb_q}),
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
            if (!scanning && at_limit && ctrl[0] && !crc_done) begin
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
        logic [1:0]  v_q;
        always_ff @(posedge pclk)
            v_q <= fb[v_ra];
        gb_video u_video (
            .clk, .rst, .ce, .frame_done, .fb_ra(v_ra), .fb_q(v_q),
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
            5'h0B: reg_q = byte_of(32'(ROM_LOG2), r[1:0]);
            5'h0D: reg_q = byte_of({15'd0, vcap_ok, 14'd0, vcap_armed, vid_pace}, r[1:0]);
            5'h0E: reg_q = byte_of(vcap_frame, r[1:0]);
            5'h0F: reg_q = byte_of(vcrc, r[1:0]);
            5'h10: reg_q = byte_of({v_late, v_shown}, r[1:0]);
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
            sh_wait    <= 1'b0;
        end else if (s_req && !s_ack) begin
            if (sh_rom || sh_cram || sh_boot || sh_ser || sh_fb) begin
                // A frame buffer read the clock after a pixel's write (which took the port) reads
                // again; writes come at least 2 clocks apart.
                sh_wait <= sh_wait ? sh_fb && fb_w_d : !(sh_fb && scanning);
                if (sh_wait && !(sh_fb && fb_w_d)) begin
                    s_ack   <= 1'b1;
                    s_rdata <= sh_rom ? rom_sh : sh_cram ? cram_sh : sh_boot ? boot_sh : sh_ser ? ser_sh :
                               {6'd0, fb_q};
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

    wire unused = &{1'b0, cart_rd, m_end, cpu_sync};
endmodule
