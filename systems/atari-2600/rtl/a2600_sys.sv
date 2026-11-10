// SPDX-License-Identifier: Apache-2.0
// The Atari 2600 (atari2600) under the test shell: its cartridge in block RAM, run and stop by
// register, and the checks a board can give the host: each whole frame's CRC as Stella cuts frames
// (a2600_frame) and the sound's CRC as Stella samples it, so the host compares them with the golden
// lists without taking the picture over the link.
//
// Colour clocks come at CC_NUM/CC_DEN of the clock (clock_enable), at least 6 clocks apart, while the
// system runs. The system stops between colour clocks, so stopping and starting leave it exactly as
// if it had run on: the same on any board and in the sim. A reset clears the frame buffer first
// (about 9,000 clocks) and starts no colour clock until that's done.
//
// Shell address map (README.md has the registers):
//   0x00000000-0x00000FFF  the cartridge, 4 KB (a 2 KB one written twice)
//   0x01000000-0x0100003F  control and status registers
//   0x05000000-0x05008E7F  the frame buffer: y x 160 + x, the last frame as Stella would show it
// LEDs (active low): led[0] a corrupt command frame, led[1] a stalled one, led[3] running, led[4]
// stopped at a limit, led[5] heartbeat.

module a2600_sys #(
    parameter int          CLKS_PER_BIT     = 18,       // 27 MHz / 18 = 1.5 Mbaud
    parameter int          IDLE_CLKS        = 270_000,  // 10 ms at 27 MHz
    parameter int          CC_NUM           = 35,       // colour clocks per CC_DEN clocks: NTSC's
    parameter int          CC_DEN           = 264,      //   3.579545 MHz from 27 MHz
    parameter bit          TIA_SCORE_GLITCH = 1'b0,
    parameter logic [31:0] BUILD_ID         = '0
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [5:0] led
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

    wire rst = por_rst || ctrl[1];

    logic [31:0] cycles, samples, audio_crc, frames, frame_crc, crc_frame;
    logic        busy;
    wire at_limit = (stop_cycle != 0 && cycles >= stop_cycle) || (stop_frame != 0 && frames >= stop_frame);
    wire running  = ctrl[0] && !rst && !busy && !at_limit;

    // ---- Colour clocks ----
    logic cc, step;
    clock_enable #(.NUM(CC_NUM), .DEN(CC_DEN)) u_cc (.clk, .rst, .en(running), .ce(cc));
    always_ff @(posedge clk) step <= cc && !rst;

    // ---- The system ----
    logic [11:0] cart_addr;
    logic        cart_sel, cart_we;
    logic [7:0]  cart_wdata, cart_data;
    logic [7:0]  pix, pix_x;
    logic        pix_on, line_end, vsync, vblank, aud_tick;
    logic [3:0]  aud0, aud1;
    logic        cpu_sync, bus_ce, bus_we;
    logic [15:0] cpu_pc;
    logic [12:0] bus_addr;
    logic [7:0]  bus_data;
    atari2600 #(.TIA_SCORE_GLITCH(TIA_SCORE_GLITCH)) u_sys (
        .clk, .rst, .cc,
        .cart_addr, .cart_sel, .cart_we, .cart_wdata, .cart_data,
        .joy, .switches, .fire_n, .paddle_on, .paddle_pos,
        .pix, .pix_on, .pix_x, .line_end, .vsync, .vblank, .aud0, .aud1, .aud_tick,
        .cpu_sync, .cpu_pc, .bus_ce, .bus_addr, .bus_we, .bus_data);

    // The cartridge: 4 KB of block RAM, read every clock (a CPU cycle is at least 18), written by the
    // shell. A 2600 cartridge is ROM: the system's writes to it go nowhere.
    logic [7:0] cart [4096];
    logic [7:0] cart_sh;
    wire        sh_cart = s_req && s_addr[31:24] == 8'h00 && s_addr[23:12] == '0;
    always_ff @(posedge clk) begin
        if (sh_cart && s_we) cart[s_addr[11:0]] <= s_wdata;
        cart_data <= cart[cart_addr];
        cart_sh   <= cart[s_addr[11:0]];
    end

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
    wire        sh_fb = s_req && !s_we && s_addr[31:24] == 8'h05 && s_addr[23:16] == '0;
    assign fb_req = sh_fb && !s_ack;
    a2600_frame u_frame (
        .clk, .rst, .step, .pix_on, .pix_x, .pix, .line_end, .vsync,
        .frames, .crc(frame_crc), .crc_frame, .busy,
        .rd_req(fb_req), .rd_addr(s_addr[15:0]), .rd_ack(fb_ack), .rd_data(fb_data));

    // ---- The shell's bus ----
    wire       sh_reg = s_req && s_addr[31:24] == 8'h01 && s_addr[23:6] == '0;
    wire [5:0] r = s_addr[5:0];

    function automatic logic [7:0] byte_of(input logic [31:0] v, input logic [1:0] b);
        byte_of = v[8 * b +: 8];
    endfunction

    logic [7:0] reg_q;
    always_comb begin
        reg_q = 8'd0;
        case (r[5:2])
            4'h0: reg_q = r[1:0] == 2'd0 ? {6'd0, ctrl} : 8'd0;
            4'h1: reg_q = byte_of(stop_cycle, r[1:0]);
            4'h2: reg_q = byte_of(cycles, r[1:0]);
            4'h3: reg_q = r[1:0] == 2'd0 ? {4'd0, busy, crc_frame != 0, running, at_limit} : 8'd0;
            4'h4: reg_q = byte_of(stop_frame, r[1:0]);
            4'h5: reg_q = byte_of(frames, r[1:0]);
            4'h6: reg_q = byte_of(frame_crc, r[1:0]);
            4'h7: reg_q = byte_of(crc_frame, r[1:0]);
            4'h8: reg_q = byte_of(audio_crc, r[1:0]);
            4'h9: reg_q = byte_of(samples, r[1:0]);
            4'hA: reg_q = byte_of(audio_limit, r[1:0]);
            4'hB: reg_q = byte_of({4'd0, paddle_on, 6'd0, fire_n, switches, joy}, r[1:0]);
            4'hC: reg_q = byte_of(paddle_pos, r[1:0]);
            default: ;
        endcase
    end

    function automatic logic [31:0] set_byte(input logic [31:0] v, input logic [1:0] b, input logic [7:0] d);
        set_byte = v;
        set_byte[8 * b +: 8] = d;
    endfunction

    logic       sh_cart_d;
    always_ff @(posedge clk) begin
        s_ack     <= 1'b0;
        sh_cart_d <= 1'b0;
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
        end else if (s_req && !s_ack) begin
            if (sh_fb) begin
                if (fb_ack) begin
                    s_ack   <= 1'b1;
                    s_rdata <= fb_data;
                end
            end else if (sh_cart) begin
                // A read's data is the clock after its address.
                sh_cart_d <= !s_we && !sh_cart_d;
                if (s_we || sh_cart_d) begin
                    s_ack   <= 1'b1;
                    s_rdata <= cart_sh;
                end
            end else begin
                s_ack   <= 1'b1;
                s_rdata <= sh_reg ? reg_q : 8'd0;
                if (sh_reg && s_we)
                    case (r[5:2])
                        4'h0: if (r[1:0] == 2'd0) ctrl <= s_wdata[1:0];
                        4'h1: stop_cycle  <= set_byte(stop_cycle, r[1:0], s_wdata);
                        4'h4: stop_frame  <= set_byte(stop_frame, r[1:0], s_wdata);
                        4'hA: audio_limit <= set_byte(audio_limit, r[1:0], s_wdata);
                        4'hB: case (r[1:0])
                                  2'd0: joy       <= s_wdata;
                                  2'd1: switches  <= s_wdata;
                                  2'd2: fire_n    <= s_wdata[1:0];
                                  2'd3: paddle_on <= s_wdata[3:0];
                              endcase
                        4'hC: paddle_pos <= set_byte(paddle_pos, r[1:0], s_wdata);
                        default: ;
                    endcase
            end
        end
    end

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

    wire unused = &{1'b0, cart_sel, cart_we, cart_wdata, vblank, cpu_sync, cpu_pc, bus_addr, bus_we, bus_data,
                    s_addr[23:16]};
endmodule
