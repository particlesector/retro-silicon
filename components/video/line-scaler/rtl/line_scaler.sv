// SPDX-License-Identifier: Apache-2.0
// Shows a source's frames on a display of another clock, scaled up by a
// whole number, through a ring of 2^LINES_LOG2 source lines in block RAM
// rather than a frame buffer. The source keeps pace with the display: it
// stops after each frame (s_waiting) until s_req starts the next, which the
// display sends at the start of line REQ_Y, early enough for the source's
// first line to arrive before the picture starts. A source that draws its
// lines a little faster than the display shows them, as a console with an
// HDMI output does, then runs ahead by a few lines over the frame, which
// the ring holds.
//
// The display's side checks each source line as it starts drawing it: it
// must have arrived, and not been overwritten by a line 2^LINES_LOG2 later.
// The source tells it how many lines it has finished, as a Gray-coded count;
// at the request the display takes that count as the frame's start, and
// whether the source was waiting for it. A frame whose source didn't start on
// request (it was stopped, or late) is drawn black; one that did but whose
// line is missing or overwritten is drawn black for that line and pulses
// d_late or d_overrun, which in a working system never happens.
//
// Source lines come in order, each SRC_W pixels from x = 0. The picture must
// fit the display's 4096 positions a line and lines a frame. Display
// positions advance by one each clock along a line, and the picture's
// top-left is at (X0, Y0), X0 at least 1. d_pix is for the position of the
// clock before.
module line_scaler #(
    parameter int SRC_W      = 256,
    parameter int SRC_H      = 240,
    parameter int PW         = 9,    // pixel bits
    parameter int SCALE      = 3,
    parameter int X0         = 256,
    parameter int Y0         = 0,
    parameter int REQ_Y      = 680,  // display line whose start asks for the next frame
    parameter int LINES_LOG2 = 5
) (
    input  logic               s_clk,
    input  logic               s_rst,
    input  logic               s_valid,
    input  logic [XW-1:0]      s_x,
    input  logic [LINES_LOG2-1:0] s_y,  // the line number, mod the ring
    input  logic [PW-1:0]      s_pix,
    input  logic               s_waiting,
    output logic               s_req,      // one-clock pulse: start the next frame

    input  logic               d_clk,
    input  logic               d_rst,
    input  logic [11:0]        d_x,
    input  logic [11:0]        d_y,
    output logic [PW-1:0]      d_pix,
    output logic               d_on,       // d_pix is in the picture, from a line that's there
    output logic               d_late,     // pulse: a line hadn't arrived when due
    output logic               d_overrun,  // pulse: a line was overwritten before it was shown
    output logic               d_frame_ok  // this frame's source started on request
);
    localparam int XW = $clog2(SRC_W);
    localparam int YW = $clog2(SRC_H);
    localparam int L  = LINES_LOG2;
    localparam int CW = $clog2(SRC_H + 1) + 1;  // finished-line count, mod 2^CW
    localparam int SLACK = 3;                   // lines of the ring kept free, for the count's delay

    logic [PW-1:0] mem [2**L * 2**XW];

    // ---- Source side ----
    logic [CW-1:0] s_cnt, s_gray;
    logic          s_req_t, s_req_q;

    always_ff @(posedge s_clk) begin
        if (s_valid)
            mem[{s_y, s_x}] <= s_pix;
        if (s_rst) begin
            s_cnt  <= '0;
            s_gray <= '0;
        end else if (s_valid && s_x == XW'(SRC_W - 1)) begin
            s_cnt  <= s_cnt + 1'b1;
            s_gray <= (s_cnt + 1'b1) ^ ((s_cnt + 1'b1) >> 1);
        end
    end

    logic d_req_t;

    cdc_sync u_req (.clk(s_clk), .d(d_req_t), .q(s_req_t));

    always_ff @(posedge s_clk)
        s_req_q <= s_req_t;

    assign s_req = !s_rst && s_req_t != s_req_q;

    // ---- Display side ----
    logic [CW-1:0] d_gray, d_cnt;
    logic          d_wait;

    cdc_sync #(.W(CW)) u_cnt (.clk(d_clk), .d(s_gray), .q(d_gray));
    cdc_sync u_wait (.clk(d_clk), .d(s_waiting), .q(d_wait));

    always_comb begin
        d_cnt[CW-1] = d_gray[CW-1];
        for (int i = CW - 2; i >= 0; i--)
            d_cnt[i] = d_cnt[i+1] ^ d_gray[i];
    end

    // The request, and the frame it starts: its count and whether the source
    // was waiting, taken on at the picture's first line.
    logic [CW-1:0] base_next, base;
    logic          ok_next;
    wire           line0 = d_x == '0;
    wire           req_now = line0 && d_y == 12'(REQ_Y);
    wire           top_now = line0 && d_y == 12'(Y0);

    always_ff @(posedge d_clk)
        if (d_rst) begin
            d_req_t    <= 1'b0;
            ok_next    <= 1'b0;
            d_frame_ok <= 1'b0;
        end else begin
            if (req_now) begin
                d_req_t   <= !d_req_t;
                base_next <= d_cnt;
                ok_next   <= d_wait;
            end
            if (top_now) begin
                base       <= base_next;
                d_frame_ok <= ok_next;
            end
        end

    // Source line and its repeat, per display line.
    logic [YW-1:0] sy, sy_q;
    logic [7:0]    syr, syr_q;
    wire           row = d_y - 12'(Y0) < 12'(SRC_H * SCALE);

    always_comb begin
        sy  = sy_q;
        syr = syr_q;
        if (top_now) begin
            sy  = '0;
            syr = '0;
        end else if (line0) begin
            if (syr_q == 8'(SCALE - 1)) begin
                sy  = sy_q + 1'b1;
                syr = '0;
            end else
                syr = syr_q + 1'b1;
        end
    end

    // Check the line as it starts: arrived, and not overwritten before this
    // display line ends (the source finishes at most one more meanwhile).
    wire [CW-1:0] fbase = top_now ? base_next : base;
    wire          fok   = top_now ? ok_next : d_frame_ok;
    wire [CW-1:0] done  = d_cnt - fbase;
    wire [CW-1:0] ahead = done - CW'(sy);
    wire          here  = done > CW'(sy);
    wire          safe  = ahead <= CW'(2**L - SLACK);
    logic         line_ok;

    always_ff @(posedge d_clk) begin
        sy_q  <= sy;
        syr_q <= syr;
        if (d_rst) begin
            line_ok   <= 1'b0;
            d_late    <= 1'b0;
            d_overrun <= 1'b0;
        end else begin
            d_late    <= line0 && row && fok && !here;
            d_overrun <= line0 && row && fok && here && !safe;
            if (line0)
                line_ok <= row && fok && here && safe;
        end
    end

    // Source pixel and its repeat, per display pixel.
    logic [XW-1:0] sx, sx_q;
    logic [7:0]    sxr, sxr_q;
    wire           col = d_x - 12'(X0) < 12'(SRC_W * SCALE);

    always_comb begin
        sx  = sx_q;
        sxr = sxr_q;
        if (d_x == 12'(X0)) begin
            sx  = '0;
            sxr = '0;
        end else if (sxr_q == 8'(SCALE - 1)) begin
            sx  = sx_q + 1'b1;
            sxr = '0;
        end else
            sxr = sxr_q + 1'b1;
    end

    always_ff @(posedge d_clk) begin
        sx_q  <= sx;
        sxr_q <= sxr;
        d_pix <= mem[{sy[L-1:0], sx}];
        d_on  <= col && row && line_ok;
    end

    initial begin
        if (X0 < 1)
            $error("line_scaler: X0 must be 1 or more");
        if (SCALE < 1 || SCALE > 255)
            $error("line_scaler: SCALE must be 1 to 255");
        if (2**L <= SLACK + 1 || L > YW)
            $error("line_scaler: LINES_LOG2 out of range");
        if (SRC_W != 2**XW)
            $error("line_scaler: SRC_W must be a power of 2");
    end
endmodule
