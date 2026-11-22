// SPDX-License-Identifier: Apache-2.0
// The Game Boy's picture and sound as HDMI at 720p. Each of the 160 x 144
// pixels is 5 display pixels each way, 800 x 720, in the middle of the display, its shade grey: 0
// white, 1 $AA, 2 $55, 3 black; on the Game Boy Color (`cgb_hw`), its 15-bit colour corrected as
// SameBoy's is (gb_color).
//
// The picture is gb_sys's frame buffer, read on the pixel clock through a port of its own (`fb_ra`,
// its shade in `fb_q` the clock after), not a ring of lines as a2600_video's: the Game Boy can turn
// its LCD off, and then draws no lines while its frames go on, so the frame shown is the buffer as
// the PPU last left it, as the golden frames are.
//
// The system keeps pace with the display as the 2600's does: it waits at each frame's end
// (`waiting`) until the display asks for the next (`req`, at the start of line REQ_Y). A frame
// starts as VBlank does, so a frame's first picture line is drawn 10 lines after the request, and
// its line y is whole 11 + y lines (of 456 T-cycles) after it. Running 2% fast of the console's
// 4.194304 MHz, a line takes 4.8 display lines, so with REQ_Y 690 line 0 is whole 53 display lines
// on, 7 before the display shows it (line 0 of the next display frame), and each line after comes a
// little sooner than its turn. The next frame's first picture line comes 10 lines after the next
// request, after the display has shown the last.
//
// The display checks each line as it starts showing it, as a2600_video does: it has come (a count
// of lines whole, from the T-cycles: 144 a frame, the ones a short frame leaves out counted at its
// end). A display frame whose system wasn't waiting for its request (it was stopped, or late) is
// drawn black, as a2600_video's is, so the last picture a capture sees lit is the frame the system
// stopped on; a line that hasn't come counts in `late` (and shows the buffer as it is). In a
// working system `late` never moves.
//
// The video CRC, for the test shell, is a2600_video's: a toggle of `cap_t` asks for the CRC of the
// display frame that the next request starts (its TMDS symbols, the data islands' packets as 0:
// which line's island carries a sample depends on when it crossed to pclk), which comes with a toggle of
// `crc_t` and `crc_ok`, whether that frame showed its Game Boy frame whole. `shown` counts display
// frames whose Game Boy frame started on request.
//
// The sound comes as 48 kHz sample pairs (`a_valid`, `a_l`, `a_r`, signed, from gb_sys's
// resamplers) and goes out in the HDMI audio packets (`video/hdmi`, AUDIO set), as nes_video's.
//
// The pixel side resets itself at configuration (common/por on pclk).
module gb_video #(
    parameter bit CGB   = 1'b1, // the Game Boy Color's colours too
    parameter int X0    = 240,  // the picture's left edge
    parameter int Y0    = 0,    // ...and top line
    parameter int REQ_Y = 690
) (
    // The system's clock
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,          // a T-cycle
    input  logic        frame_done,  // with ce: a frame ends
    input  logic        waiting,
    output logic        req,
    input  logic        cap_t,
    output logic [31:0] crc,
    output logic        crc_ok,
    output logic        crc_t,
    output logic [15:0] shown,
    output logic [15:0] late,
    input  logic        a_valid,     // a sound sample pair
    input  logic [15:0] a_l,
    input  logic [15:0] a_r,

    // The pixel clock
    input  logic        pclk,
    output logic [14:0] fb_ra,       // the frame buffer: y x 160 + x
    input  logic [14:0] fb_q,        // ...its shade or colour, the clock after
    input  logic        cgb_hw,      // the Game Boy Color: colours
    output logic [9:0]  tmds0,
    output logic [9:0]  tmds1,
    output logic [9:0]  tmds2
);
    localparam int W = 160, H = 144, S = 5, LATENCY = 2;
    localparam int T_LINE = 456, LEAD = 11;  // a line whole LEAD + y lines into its frame

    logic prst;
    por u_ppor (.clk(pclk), .rst(prst));

    // ---- Lines whole, counted from the T-cycles ----
    // A frame's line y is whole LEAD + y lines after it starts; at a frame's end the lines it left
    // out are owed, and counted one a clock (a Gray-coded count steps by one), long before the next
    // frame's first.
    logic [8:0]  lt;         // T-cycles into the line
    logic [7:0]  ln;         // lines into the frame
    logic [7:0]  frame_rows; // lines of this frame counted or owed
    logic [7:0]  owe;
    logic [15:0] n_rows, g_rows, p_rows;
    logic        p_waiting, req_t, req_seen, req_last;
    wire         line_due = ce && !frame_done && lt == 9'(T_LINE - 1) && ln + 8'd1 >= 8'(LEAD) &&
                            frame_rows < 8'(H);
    always_ff @(posedge clk)
        if (rst) begin
            lt         <= '0;
            ln         <= '0;
            frame_rows <= '0;
            owe        <= '0;
            n_rows     <= '0;
            g_rows     <= '0;
        end else begin
            if (frame_done) begin
                lt         <= '0;
                ln         <= '0;
                frame_rows <= '0;
            end else if (ce) begin
                lt <= lt == 9'(T_LINE - 1) ? '0 : lt + 9'd1;
                if (lt == 9'(T_LINE - 1) && ln != '1) ln <= ln + 8'd1;
                if (line_due) frame_rows <= frame_rows + 8'd1;
            end
            owe <= owe - 8'(owe != 0) + 8'(line_due) + (frame_done ? 8'(H) - frame_rows : 8'd0);
            if (owe != 0) begin
                n_rows <= n_rows + 1'b1;
                g_rows <= (n_rows + 1'b1) ^ ((n_rows + 1'b1) >> 1);
            end
        end

    cdc_sync #(.W(16)) u_rows (.clk(pclk), .d(g_rows), .q(p_rows));
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

    logic [15:0] rows_now;
    always_ff @(posedge pclk)
        rows_now <= from_gray(p_rows);

    // ---- Display ----
    logic [11:0] hx, hy;
    logic        hframe, hline;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        hact;
    /* verilator lint_on UNUSEDSIGNAL */

    // Where the display is: the picture's column and its pixel within (for hx), its line and its
    // display line within (for hy, set as each display line starts).
    logic       x_on, y_on, line_d;
    logic [7:0] col, row;
    logic [2:0] sx, sy;
    // The frame the request starts (pend_*), taken at the request, and the one being shown (cur_*).
    logic        pend_ok, cur_ok;
    logic [15:0] pend_base, cur_base;
    logic        slate;

    wire [15:0] got     = rows_now - cur_base;  // the frame's lines whole
    wire        arrived = got > 16'(row);

    always_ff @(posedge pclk) begin
        slate  <= 1'b0;
        line_d <= hline;
        if (hx == 12'(X0 - 1)) begin
            x_on <= 1'b1;
            col  <= '0;
            sx   <= '0;
        end else if (x_on) begin
            if (sx == 3'(S - 1)) begin
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
                if (sy == 3'(S - 1)) begin
                    sy <= '0;
                    if (row == 8'(H - 1)) y_on <= 1'b0;
                    else row <= row + 8'd1;
                end else
                    sy <= sy + 3'd1;
            end
            if (hy == 12'(REQ_Y)) begin
                req_t     <= !req_t;
                pend_ok   <= p_waiting;
                pend_base <= rows_now;
            end
        end
        if (hframe) begin
            cur_ok   <= pend_ok;
            cur_base <= pend_base;
        end
        // The line's check, as its first display line starts (row and sy are set by now).
        if (line_d && y_on && sy == 3'd0 && cur_ok)
            slate <= !arrived;
        if (prst) begin
            x_on    <= 1'b0;
            y_on    <= 1'b0;
            req_t   <= 1'b0;
            pend_ok <= 1'b0;
            cur_ok  <= 1'b0;
        end
    end

    // The buffer's shade for this position the clock after; its colour the clock after that.
    assign fb_ra = 15'({row, 7'd0}) + 15'({row, 5'd0}) + 15'(col);
    logic [1:0] on_d;
    logic [23:0] grey, crgb;
    always_ff @(posedge pclk) begin
        on_d <= {on_d[0], x_on && y_on && cur_ok};
        case (fb_q[1:0])
            2'd0: grey <= 24'hFFFFFF;
            2'd1: grey <= 24'hAAAAAA;
            2'd2: grey <= 24'h555555;
            default: grey <= 24'h000000;
        endcase
    end
    if (CGB) begin : g_color
        gb_color u_color (.clk(pclk), .c(fb_q), .rgb(crgb));
    end else begin : g_no_color
        assign crgb = 24'd0;
        wire unused_c = &{1'b0, fb_q[14:2]};
    end
    wire [23:0] rgb = CGB && cgb_hw ? crgb : grey;

    logic packet;
    // ---- Sound: each pair crosses to pclk with a toggle, held until the next ----
    logic [31:0] a_hold, a_p;
    logic        a_t, a_seen, a_last, a_new;
    always_ff @(posedge clk)
        if (rst)
            a_t <= 1'b0;
        else if (a_valid) begin
            a_hold <= {a_r, a_l};
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

    hdmi #(.LATENCY(LATENCY), .AUDIO(1'b1)) u_hdmi (
        .clk(pclk), .rst(prst), .x(hx), .y(hy), .act(hact), .frame(hframe), .line(hline),
        .rgb(on_d[1] ? rgb : 24'h000000), .aud_valid(a_new), .aud_l(a_p[15:0]), .aud_r(a_p[31:16]),
        .tmds0, .tmds1, .tmds2, .packet);

    // ---- Frame CRC (a2600_video's) ----
    // `start` is high while a frame's first symbol is out, LATENCY + 2 clocks after its position;
    // the CRC takes each symbol the clock after it's out. A captured frame's CRC restarts at its
    // start and runs through the next frame's start, and is ready the clock after. A frame is bad if
    // its Game Boy frame didn't start on request or a line came late.
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
            bad       <= !cur_ok || slate;
        end else if (slate)
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
    logic [15:0] n_shown, g_shown, s_shown, n_late, g_late, s_late;

    always_ff @(posedge pclk)
        if (prst) begin
            n_shown <= '0;
            n_late  <= '0;
            g_shown <= '0;
            g_late  <= '0;
        end else begin
            if (start && cur_ok) begin
                n_shown <= n_shown + 1'b1;
                g_shown <= (n_shown + 1'b1) ^ ((n_shown + 1'b1) >> 1);
            end
            if (slate) begin
                n_late <= n_late + 1'b1;
                g_late <= (n_late + 1'b1) ^ ((n_late + 1'b1) >> 1);
            end
        end

    cdc_sync #(.W(16)) u_shown (.clk, .d(g_shown), .q(s_shown));
    cdc_sync #(.W(16)) u_late (.clk, .d(g_late), .q(s_late));

    assign shown = from_gray(s_shown);
    assign late  = from_gray(s_late);

    // The CRC and its flag hold from before res_t toggles until the next frame's, so they cross
    // with it.
    cdc_sync #(.W(33)) u_res (.clk, .d({res_ok, res}), .q({crc_ok, crc}));
    cdc_sync u_res_t (.clk, .d(res_t), .q(crc_t));

    initial begin
        if (X0 < 1 || X0 + W * S > 1280 || Y0 + H * S > 720) $error("gb_video: the picture must fit");
    end
endmodule
