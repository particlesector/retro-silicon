// SPDX-License-Identifier: Apache-2.0
// The NES's picture and sound as HDMI at 720p: video/line-scaler takes the
// PPU's pixels from the NES's clock to the pixel clock, three times their size
// in the middle of the line; the 2C02's colours make them RGB; video/hdmi
// times and encodes them, with the NES's 48 kHz samples as 2-channel audio
// (the same on both). A sample crosses to the pixel clock by a toggle: they
// come hundreds of clocks apart, so the held sample has long settled when the
// toggle is seen. The NES keeps pace with the display: it waits at each
// frame's end (`waiting`) for `req`, so each display frame shows one NES
// frame whole.
//
// For the test shell it also takes a CRC of one display frame's TMDS
// symbols, the whole frame's (1650 x 750 clocks, 30 bits each, bit 0 first:
// blue's symbol in bits 9-0, green's 19-10, red's 29-20), with the data
// islands' packet symbols as 0: which line's island carries a sample depends
// on when it crosses clocks, which differs from board to board by a clock or
// two, while everything else is the same everywhere. A toggle of `cap_t`
// asks for the display frame that the next request starts; `crc_t` toggles
// when its CRC is in `crc`, with `crc_ok` saying whether that frame showed
// its NES frame whole. Its counts say how the pacing goes: display frames
// whose NES frame started on request, and lines that came late or were
// overwritten before they were shown (both 0 in a working system).
//
// The pixel side resets itself at configuration (common/por on pclk).
module nes_video #(
    parameter int X0    = 256,
    parameter int SCALE = 3,
    parameter int REQ_Y = 680
) (
    // The NES's clock
    input  logic        clk,
    input  logic        rst,
    input  logic        pix_valid,
    input  logic [8:0]  pix,
    input  logic [7:0]  pix_x,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [7:0]  pix_y,  // the scaler takes the line mod 32
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        waiting,
    input  logic        a_valid,
    input  logic [15:0] a_pcm,
    output logic        req,
    input  logic        cap_t,
    output logic [31:0] crc,
    output logic        crc_ok,
    output logic        crc_t,
    output logic [15:0] shown,
    output logic [15:0] late,
    output logic [15:0] overrun,

    // The pixel clock
    input  logic        pclk,
    output logic [9:0]  tmds0,
    output logic [9:0]  tmds1,
    output logic [9:0]  tmds2
);
    localparam int LATENCY = 2;  // scaler 1, colours 1

    logic prst;
    por u_ppor (.clk(pclk), .rst(prst));

    // ---- Picture ----
    logic [11:0] hx, hy;
    logic        hframe;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        hact, hline;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [8:0]  spix;
    logic        son, slate, sover, sok, on_q;
    logic [23:0] rgb;
    logic        packet;

    line_scaler #(.X0(X0), .SCALE(SCALE), .REQ_Y(REQ_Y)) u_scaler (
        .s_clk(clk), .s_rst(rst), .s_valid(pix_valid), .s_x(pix_x), .s_y(pix_y[4:0]), .s_pix(pix),
        .s_waiting(waiting), .s_req(req),
        .d_clk(pclk), .d_rst(prst), .d_x(hx), .d_y(hy), .d_pix(spix), .d_on(son),
        .d_late(slate), .d_overrun(sover), .d_frame_ok(sok));

    // The colours are a block RAM, which takes its address on the falling
    // edge before the clock that reads it: on the GW2AR-18 a block RAM's
    // address needs more hold than a short path from a register gives, and
    // nextpnr doesn't lengthen one. (In logic instead, the 512 colours pass
    // nextpnr's timing but come out wrong on the board.)
    logic [8:0] spix_n;

    always_ff @(negedge pclk)
        spix_n <= spix;

    ppu_2c02_rgb u_rgb (.clk(pclk), .pix(spix_n), .rgb);

    always_ff @(posedge pclk)
        on_q <= son;

    // ---- Sound ----
    logic [15:0] a_hold, a_p;
    logic        a_t, a_seen, a_last, a_new;

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

    hdmi #(.LATENCY(LATENCY), .AUDIO(1'b1)) u_hdmi (
        .clk(pclk), .rst(prst), .x(hx), .y(hy), .act(hact), .frame(hframe), .line(hline),
        .rgb(on_q ? rgb : 24'h000000), .aud_valid(a_new), .aud_l(a_p), .aud_r(a_p),
        .tmds0, .tmds1, .tmds2, .packet);

    // ---- Frame CRC ----
    // `start` is high while a frame's first symbol is out, LATENCY + 2 clocks
    // after its position; the CRC takes each symbol the clock after it's out.
    // A captured frame's CRC restarts at its start and runs through the next
    // frame's start, and is ready the clock after. A frame is bad if its NES
    // frame didn't start on request or a line came late or overwritten: the
    // scaler's flags for a frame come from the clock after its first position
    // (fd[0]) to the next frame's.
    logic [LATENCY+1:0] fd;
    logic [29:0]      sym_q;
    logic             cap_seen, cap_last, armed, running, bad, frame_bad, publish;
    logic [31:0]      vcrc, res;
    logic             res_ok, res_t;

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
            bad       <= !sok || slate || sover;
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

    always_ff @(posedge pclk)
        if (prst) begin
            n_shown <= '0;
            n_late  <= '0;
            n_over  <= '0;
            g_shown <= '0;
            g_late  <= '0;
            g_over  <= '0;
        end else begin
            if (start && sok) begin
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

    function automatic logic [15:0] from_gray(input logic [15:0] g);
        logic [15:0] b;
        b = g;
        for (int i = 1; i < 16; i++)
            b = b ^ (g >> i);
        from_gray = b;
    endfunction

    assign shown   = from_gray(s_shown);
    assign late    = from_gray(s_late);
    assign overrun = from_gray(s_over);

    // The CRC and its flag hold from before res_t toggles until the next
    // frame's, so they cross with it.
    cdc_sync #(.W(33)) u_res (.clk, .d({res_ok, res}), .q({crc_ok, crc}));
    cdc_sync u_res_t (.clk, .d(res_t), .q(crc_t));
endmodule
