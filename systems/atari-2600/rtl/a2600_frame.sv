// SPDX-License-Identifier: Apache-2.0
// The 2600's frames as Stella 7.0's NTSC frame manager cuts them from the TIA's picture, in a frame
// buffer, with each whole frame's CRC: the golden frame's (harness/golden/a2600_frames_crc32.txt).
//
// The frame manager: a frame ends when VSYNC goes off (or, with VSYNC overdue, 50 lines later); its
// picture starts 23 line ends later and runs 228 lines of 160 pixels. A line's pixels the TIA doesn't
// draw (RSYNC cut it short) are black, and when a frame ends prev its 228 lines the rest are black,
// unless its last line was the one the frame prev ended on, when that line keeps what it had: the
// buffer is one, as Stella's is, so this keeps Stella's frame in that case too.
//
// Each colour clock, as `step` comes (the clock after the TIA's colour clock, with its outputs), the
// pixel it drew, then the line's end, then a change of VSYNC, as Stella orders them. The buffer is 4
// byte lanes of 9,120 (a pixel's lane is x mod 4, its word y x 40 + x / 4). After a line's end its
// undrawn pixels are cleared, 4 a clock (40 clocks, held off by a pixel's write); after a frame's end
// the buffer is read through, 4 pixels a clock into the CRC, clearing the lines after its last
// (9,120 clocks, done prev the next frame's first line, 23 lines later). A reset clears all of it.
//
// `rd_*` reads a byte of the buffer, y x 160 + x, once no pass is running (its data the clock after
// `rd_ack`).
//
// For a display (a2600_video), `vw_*` repeats the buffer's writes of the picture: each pixel drawn
// and each line's clearing, by line and word (not the frame pass's). `row_done` pulses as a line's
// clearing ends, when the line is whole; `line_busy` is high from the line's end until then.

module a2600_frame (
    input  logic        clk,
    input  logic        rst,
    input  logic        step,        // the clock after a colour clock: the TIA's outputs are its
    input  logic        pix_on,
    input  logic [7:0]  pix_x,
    input  logic [7:0]  pix,
    input  logic        line_end,
    input  logic        vsync,

    output logic [31:0] frames,      // frames ended since reset
    output logic [31:0] crc,         // the CRC of frame `crc_frame` (its 160 x 228 bytes, line by line)
    output logic [31:0] crc_frame,   // 0: none yet
    output logic        busy,        // the reset's clear is running (no colour clock may come)

    input  logic        rd_req,
    input  logic [15:0] rd_addr,
    output logic        rd_ack,
    output logic [7:0]  rd_data,

    output logic [3:0]  vw_we,       // the lanes written
    output logic [7:0]  vw_y,        // line
    output logic [5:0]  vw_w,        // word within the line
    output logic [7:0]  vw_d,        // every lane's byte
    output logic        row_done,
    output logic        line_busy,
    output logic        frame_done   // a pulse as a frame ends
);
    localparam int W = 160, H = 228, Y_START = 23, FRAME_LINES = 262, MAX_VSYNC_LINES = 50;
    localparam int WORDS = W * H / 4;  // 9,120

    // ---- The buffer: 4 lanes, one write port and one read port ----
    logic [7:0]  mem0 [WORDS], mem1 [WORDS], mem2 [WORDS], mem3 [WORDS];
    logic [13:0] wa, ra;
    logic [3:0]  we;
    logic [31:0] wd;
    logic [31:0] q;
    always_ff @(posedge clk) begin
        if (we[0]) mem0[wa] <= wd[7:0];
        if (we[1]) mem1[wa] <= wd[15:8];
        if (we[2]) mem2[wa] <= wd[23:16];
        if (we[3]) mem3[wa] <= wd[31:24];
        q <= {mem3[ra], mem2[ra], mem1[ra], mem0[ra]};
    end

    // ---- The frame manager ----
    typedef enum logic [1:0] { WAIT_VS_START, WAIT_VS_END, WAIT_FRAME, FRAME } state_t;
    state_t      state;
    logic [15:0] line_in_state, total_lines;
    logic [6:0]  vsync_lines;       // saturates past MAX_VSYNC_LINES
    logic [7:0]  y;                 // the frame's line being drawn
    logic [8:0]  last_y;            // Y_START + the last line of the last frame to run its 228 lines
    logic        vs;
    logic [W-1:0] drawn;            // the line's pixels drawn

    // Passes over the buffer: a line's undrawn pixels; a frame's CRC (and the clearing of the lines
    // after its last); the reset's clear.
    logic         line_go, line_on;
    logic [7:0]   line_y;
    logic [W-1:0] line_mask;        // pixels to clear
    logic [5:0]   line_w;           // word within the line
    logic         frame_go, frame_on, frame_crc_on, frame_pend, clear_pend;
    logic [7:0]   fill_from;        // lines from here are cleared
    logic [13:0]  fw;               // the frame pass's word
    logic [7:0]   fy;               // ...its line
    logic [5:0]   fx;               // ...and word within the line
    logic         rd_v, rd_zero, rd_last;  // a read's data comes next clock: for the CRC, as 0, the last
    logic [31:0]  frame_index;      // the frame that ended last
    logic [7:0]   pass_fill;        // the pass's: lines from here are cleared
    logic [31:0]  pass_index;       // ...and the frame it's the CRC of

    // The pixel this colour clock draws.
    wire        px_we = step && pix_on && state == FRAME && pix_x < 8'(W);
    wire [13:0] px_w  = 14'(y) * 14'd40 + 14'(pix_x[7:2]);

    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= WAIT_VS_START;
            line_in_state <= '0;
            total_lines   <= '0;
            vsync_lines   <= '0;
            y             <= '0;
            last_y        <= '0;
            vs            <= 1'b0;
            drawn         <= '0;
            frames        <= '0;
            line_go       <= 1'b0;
            frame_go      <= 1'b0;
        end else begin
            line_go  <= 1'b0;
            frame_go <= 1'b0;
            if (step) begin : manage
                state_t      s, prev;
                logic [15:0] lis, tl;
                logic [6:0]  vl;
                logic [7:0]  yy;
                logic [8:0]  ly;
                logic [31:0] fr;
                logic        done;
                s = state; lis = line_in_state; tl = total_lines; vl = vsync_lines; yy = y; ly = last_y;
                fr = frames; done = 1'b0;

                if (px_we) drawn[pix_x] <= 1'b1;

                if (line_end) begin
                    if (s == FRAME) begin
                        line_go   <= 1'b1;
                        line_y    <= yy;
                        line_mask <= ~(drawn | (px_we ? W'(1) << pix_x : '0));
                    end
                    drawn  <= '0;
                    tl     = tl + 16'd1;
                    prev = s;
                    lis    = lis + 16'd1;
                    case (s)
                        WAIT_VS_START: begin
                            if (tl > 16'(FRAME_LINES - 3) || fr == 0) vl = vl == 7'h7F ? vl : vl + 7'd1;
                            if (vl > 7'(MAX_VSYNC_LINES)) begin s = WAIT_FRAME; done = 1'b1; end
                        end
                        WAIT_VS_END: begin
                            vl = vl == 7'h7F ? vl : vl + 7'd1;
                            if (vl > 7'(MAX_VSYNC_LINES)) begin s = WAIT_FRAME; done = 1'b1; end
                        end
                        WAIT_FRAME:
                            if (lis >= 16'(Y_START)) begin s = FRAME; vl = '0; yy = '0; end
                        FRAME:
                            if (lis >= 16'(H)) begin ly = 9'(Y_START) + 9'(yy); s = WAIT_VS_START; end
                    endcase
                    if (s != prev) lis = '0;
                    if (s == FRAME && prev == FRAME) yy = yy + 8'd1;
                end

                if (vsync != vs) begin
                    vs <= vsync;
                    prev = s;
                    s = s == WAIT_VS_END ? WAIT_FRAME : WAIT_VS_END;
                    if (s != prev) lis = '0;
                    if (s == WAIT_FRAME) done = 1'b1;
                end

                if (done) begin
                    // The frame is whole: lines it didn't draw are black.
                    fill_from <= ly != 9'(Y_START) + 9'(yy) ? yy : 8'(H);
                    tl = '0;
                    fr = fr + 32'd1;
                    vl = '0;
                    frame_go    <= 1'b1;
                    frame_index <= fr;
                end

                state <= s; line_in_state <= lis; total_lines <= tl; vsync_lines <= vl; y <= yy;
                last_y <= ly; frames <= fr;
            end
        end
    end

    // ---- The passes ----
    wire       rd_idle = !line_on && !frame_on && !line_go && !frame_go && !frame_pend && !clear_pend;
    wire [3:0] line_lanes = line_mask[4 * line_w +: 4];

    always_comb begin
        we = '0;
        wa = px_w;
        wd = {4{pix}};
        ra = fw;
        if (px_we) begin
            we[pix_x[1:0]] = 1'b1;
        end else if (line_on) begin
            wa = 14'(line_y) * 14'd40 + 14'(line_w);
            wd = '0;
            we = line_lanes;
        end else if (frame_on && (!frame_crc_on || fy >= pass_fill)) begin
            wa = fw;
            wd = '0;
            we = 4'hF;
        end
        if (!frame_on) ra = rd_addr[15:2];
    end

    always_comb begin
        vw_we = '0;
        vw_y  = y;
        vw_w  = pix_x[7:2];
        vw_d  = pix;
        if (px_we) begin
            vw_we[pix_x[1:0]] = 1'b1;
        end else if (line_on) begin
            vw_y  = line_y;
            vw_w  = line_w;
            vw_d  = '0;
            vw_we = line_lanes;
        end
    end
    assign line_busy  = line_go || line_on;
    assign frame_done = frame_go;

    logic       crc_rst, crc_en;
    logic [31:0] crc_now;
    crc32 #(.W(32)) u_crc (.clk, .rst(crc_rst), .en(crc_en), .data(rd_zero ? 32'd0 : q), .crc(crc_now),
                           .st_we(1'b0), .st_wdata(32'd0));

    logic [1:0] rd_lane;
    logic       rd_pend;
    always_ff @(posedge clk) begin
        crc_rst  <= 1'b0;
        row_done <= 1'b0;
        rd_v    <= 1'b0;
        rd_last <= 1'b0;
        rd_ack  <= 1'b0;
        if (rst) begin
            line_on    <= 1'b0;
            frame_on   <= 1'b0;
            frame_pend <= 1'b0;
            clear_pend <= 1'b1;
            rd_pend    <= 1'b0;
        end else begin
            // A line's undrawn pixels.
            if (line_go) begin
                line_on <= 1'b1;
                line_w  <= '0;
            end else if (line_on && !px_we) begin
                line_w <= line_w + 6'd1;
                if (line_w == 6'd39) begin
                    line_on  <= 1'b0;
                    row_done <= 1'b1;
                end
            end
            // A frame's CRC, or the reset's clear: every word, in order.
            if (frame_go) frame_pend <= 1'b1;
            if ((frame_go || frame_pend || clear_pend) && !line_on && !line_go && !frame_on) begin
                frame_on     <= 1'b1;
                frame_crc_on <= !clear_pend;
                frame_pend   <= 1'b0;
                pass_fill    <= fill_from;
                pass_index   <= frame_index;
                clear_pend   <= 1'b0;
                fw <= '0; fy <= '0; fx <= '0;
                crc_rst <= 1'b1;
            end else if (frame_on) begin
                rd_v    <= frame_crc_on;
                rd_zero <= fy >= pass_fill;
                rd_last <= fw == 14'(WORDS - 1);
                fw <= fw + 14'd1;
                if (fx == 6'd39) begin fx <= '0; fy <= fy + 8'd1; end
                else fx <= fx + 6'd1;
                if (fw == 14'(WORDS - 1)) frame_on <= 1'b0;
            end
            // A byte for the shell.
            if (rd_req && !rd_pend && rd_idle) begin
                rd_pend <= 1'b1;
                rd_lane <= rd_addr[1:0];
            end else if (rd_pend) begin
                rd_pend <= 1'b0;
                rd_ack  <= 1'b1;
            end
        end
    end
    assign crc_en = rd_v;
    // The CRC's last word goes in with rd_last; it's whole the clock after.
    logic crc_done;
    always_ff @(posedge clk)
        if (rst) begin
            crc_done  <= 1'b0;
            crc       <= '0;
            crc_frame <= '0;
        end else begin
            crc_done <= rd_last && frame_crc_on;
            if (crc_done) begin
                crc       <= crc_now;
                crc_frame <= pass_index;
            end
        end

    assign rd_data = q[8 * rd_lane +: 8];
    assign busy    = clear_pend || (frame_on && !frame_crc_on);

    initial begin
        if (FRAME_LINES != 262) $error("a2600_frame: NTSC only");
    end
endmodule
