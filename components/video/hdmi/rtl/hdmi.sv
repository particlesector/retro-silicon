// SPDX-License-Identifier: Apache-2.0
// Video timing and TMDS encoding for an HDMI output: the three 10-bit symbols
// to send each pixel clock, for a board's serializers. Defaults are CEA-861's
// 1280x720 at 60 Hz (74.25 MHz pixel clock).
//
// Each line is H_ACTIVE pixels of picture, then the front porch, the sync
// pulse and the back porch; each frame is V_ACTIVE such lines, then the
// vertical porches and sync. The vertical sync starts and ends with the line's
// horizontal sync, as CEA-861 has it for progressive modes.
//
// The pixel source sees the position to draw (x, y, with `act` inside the
// picture) and returns that pixel's colour LATENCY clocks later; the sync
// and blanking go through the same delay to meet it. `frame` pulses with the
// position of the first pixel of a frame, `line` with the first of each line.
// The symbols come out two clocks after the colour, through the encoders'
// two register stages.
//
// With AUDIO clear the output is DVI: picture, syncs and control symbols.
// With AUDIO set it's HDMI (1.4, section 5.2): each picture line has the
// video preamble and guard band before it, and every line has a data island
// right after the picture (4 control clocks, the preamble, a guard band, two
// packets, a guard band). The first packet carries the audio samples waiting
// (up to 4), or is a null packet; the second is the AVI InfoFrame on line 0,
// the audio InfoFrame on line 1, and audio clock regeneration on the others.
// Audio is 2-channel 16-bit L-PCM at 48 kHz: aud_valid pushes a sample pair
// into a 16-deep queue (one arriving to a full queue is dropped).
module hdmi #(
    parameter int H_ACTIVE = 1280,
    parameter int H_FRONT  = 110,
    parameter int H_SYNC   = 40,
    parameter int H_BACK   = 220,
    parameter int V_ACTIVE = 720,
    parameter int V_FRONT  = 5,
    parameter int V_SYNC   = 5,
    parameter int V_BACK   = 20,
    parameter bit H_POS    = 1'b1,  // sync pulses active high
    parameter bit V_POS    = 1'b1,
    parameter int LATENCY  = 2,     // clocks from x, y to rgb, 1 or more
    parameter bit AUDIO    = 1'b0,  // HDMI with audio and InfoFrames, not DVI
    parameter int VIC      = 4,     // the AVI InfoFrame's video format: 720p60
    parameter int ACR_N    = 6144,  // audio clock regeneration for 48 kHz:
    parameter int ACR_CTS  = 74250  //   N = 128 fs / 1 kHz, CTS = pixel clock / 1 kHz
) (
    input  logic        clk,  // the pixel clock
    input  logic        rst,

    output logic [11:0] x,
    output logic [11:0] y,
    output logic        act,
    output logic        frame,
    output logic        line,
    input  logic [23:0] rgb,  // {red, green, blue}

    input  logic        aud_valid,  // a sample pair, with AUDIO
    input  logic [15:0] aud_l,      // signed
    input  logic [15:0] aud_r,

    output logic [9:0]  tmds0,  // blue, with the syncs
    output logic [9:0]  tmds1,  // green
    output logic [9:0]  tmds2,  // red
    output logic        packet  // the symbols are a data island's packets
);
    localparam int H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
    localparam int V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;
    localparam int HS_ON   = H_ACTIVE + H_FRONT;
    localparam int VS_ON   = V_ACTIVE + V_FRONT;
    // The data island, in clocks from the end of the picture (`ic`).
    localparam int I_PRE   = 4;              // preamble, 8 clocks
    localparam int I_GB    = I_PRE + 8;      // guard band, 2
    localparam int I_PK    = I_GB + 2;       // two packets, 32 each
    localparam int I_GB2   = I_PK + 64;      // guard band, 2
    localparam int I_END   = I_GB2 + 2;
    localparam int V_PRE   = H_TOTAL - 10;   // the video preamble, 8, and guard band, 2

    logic [11:0] hc, vc;  // position; vertical sync counts lines from hsync
    logic [11:0] vs_line;

    always_ff @(posedge clk)
        if (rst) begin
            hc <= '0;
            vc <= '0;
        end else if (hc == 12'(H_TOTAL - 1)) begin
            hc <= '0;
            vc <= vc == 12'(V_TOTAL - 1) ? '0 : vc + 1'b1;
        end else
            hc <= hc + 1'b1;

    assign x       = hc;
    assign y       = vc;
    assign act     = hc < 12'(H_ACTIVE) && vc < 12'(V_ACTIVE);
    assign frame   = hc == '0 && vc == '0;
    assign line    = hc == '0;
    assign vs_line = hc >= 12'(HS_ON) ? vc : (vc == '0 ? 12'(V_TOTAL - 1) : vc - 1'b1);

    wire hs = hc >= 12'(HS_ON) && hc < 12'(HS_ON + H_SYNC);
    wire vs = vs_line >= 12'(VS_ON) && vs_line < 12'(VS_ON + V_SYNC);

    // ---- What each clock sends, by position ----
    typedef enum logic [2:0] {K_CTL, K_VPRE, K_DPRE, K_VGB, K_DGB, K_DATA, K_VID} kind_t;

    // Where the line stands after its picture: `ic` counts from the picture's
    // end through the island, and `vpre` covers the video preamble and guard
    // band before a picture line. Set on equalities, as counters compare
    // cheaper than positions.
    kind_t      kind;
    logic [6:0] ic;
    logic       in_isl, vpre;

    always_ff @(posedge clk) begin
        if (hc == 12'(H_ACTIVE - 1)) begin
            ic     <= '0;
            in_isl <= AUDIO;
        end else if (in_isl) begin
            ic <= ic + 1'b1;
            if (ic == 7'(I_END - 1))
                in_isl <= 1'b0;
        end
        if (hc == 12'(V_PRE - 1))
            vpre <= AUDIO && (vc < 12'(V_ACTIVE - 1) || vc == 12'(V_TOTAL - 1));
        else if (hc == 12'(H_TOTAL - 1))
            vpre <= 1'b0;
        if (rst) begin
            in_isl <= 1'b0;
            vpre   <= 1'b0;
        end
    end

    always_comb begin
        kind = K_CTL;
        if (act)
            kind = K_VID;
        else if (in_isl && ic >= 7'(I_PRE)) begin
            if (ic < 7'(I_GB))
                kind = K_DPRE;
            else if (ic < 7'(I_PK) || ic >= 7'(I_GB2))
                kind = K_DGB;
            else
                kind = K_DATA;
        end else if (vpre)
            kind = hc >= 12'(H_TOTAL - 2) ? K_VGB : K_VPRE;
    end

    // ---- Audio samples ----
    logic [31:0] aq[16];
    logic [3:0]  aq_w, aq_r;
    logic [4:0]  aq_n;
    logic [31:0] smp[4];   // the samples for this line's island
    logic [2:0]  smp_n;
    logic [7:0]  iec;      // the IEC 60958 frame of the next sample, 0-191
    logic        pop;

    assign pop = in_isl && ic < 7'(I_PRE) && aq_n != '0;

    always_ff @(posedge clk) begin
        if (aud_valid && aq_n != 5'd16) begin
            aq[aq_w] <= {aud_r, aud_l};
            aq_w     <= aq_w + 1'b1;
        end
        if (pop) begin
            smp[smp_n[1:0]] <= aq[aq_r];
            smp_n           <= smp_n + 1'b1;
            aq_r            <= aq_r + 1'b1;
        end
        aq_n <= aq_n + 5'(aud_valid && aq_n != 5'd16) - 5'(pop);
        if (hc == 12'(H_TOTAL - 1))
            smp_n <= '0;
        if (rst) begin
            aq_w  <= '0;
            aq_r  <= '0;
            aq_n  <= '0;
            smp_n <= '0;
        end
    end

    // ---- Packets ----
    // A packet is a 24-bit header and four 56-bit subpackets, each followed
    // by its BCH ECC; byte 0 of each goes first, bit 0 first.
    // A sample's subpacket: the two 24-bit samples (16 bits in the top),
    // then {P, C, U, V} for each, P even parity over the sample, V, U and C.
    // Channel status: copying allowed (bit 2) and 48 kHz (bits 24-27, 0100).
    function automatic logic [55:0] sample_sub(input logic [31:0] lr, input logic [7:0] fr);
        logic c;
        c = fr == 8'd2 || fr == 8'd25;
        sample_sub = {^lr[31:16] ^ c, c, 2'b00, ^lr[15:0] ^ c, c, 2'b00,
                      lr[31:16], 8'h00, lr[15:0], 8'h00};
    endfunction

    function automatic logic [7:0] frame_plus(input logic [7:0] f, input logic [2:0] n);
        frame_plus = 9'(f) + 9'(n) >= 9'd192 ? f + 8'(n) - 8'd192 : f + 8'(n);
    endfunction

    logic [23:0]  hdr0, hdr1;
    logic [223:0] sub0, sub1;  // four subpackets, subpacket 0 in bits 55-0
    logic [7:0]   sum_avi, sum_aud;

    assign sum_avi = 8'h82 + 8'h02 + 8'd13 + 8'h10 + 8'h28 + 8'h08 + 8'(VIC);
    assign sum_aud = 8'h84 + 8'h01 + 8'd10 + 8'h01;

    always_comb begin
        // Slot 0: the audio sample packet, or a null packet.
        hdr0 = '0;
        sub0 = '0;
        if (smp_n != '0) begin
            hdr0[7:0] = 8'h02;
            for (int k = 0; k < 4; k++)
                if (3'(k) < smp_n) begin
                    hdr0[8 + k]  = 1'b1;                                  // sample present
                    hdr0[20 + k] = frame_plus(iec, 3'(k)) == 8'd0;        // B: the block's first frame
                    sub0[56*k +: 56] = sample_sub(smp[k], frame_plus(iec, 3'(k)));
                end
        end
        // Slot 1: InfoFrames on lines 0 and 1, clock regeneration otherwise.
        sub1 = '0;
        if (vc == '0) begin
            // AVI InfoFrame, version 2: RGB, active format present, 16:9,
            // full-range RGB, the video format, no repetition.
            hdr1 = {8'd13, 8'h02, 8'h82};
            sub1[55:0] = {16'h0000, 8'(VIC), 8'h08, 8'h28, 8'h10, 8'(-sum_avi)};
        end else if (vc == 12'd1) begin
            // Audio InfoFrame, version 1: 2 channels, the rest from the stream.
            hdr1 = {8'd10, 8'h01, 8'h84};
            sub1[55:0] = {40'h0, 8'h01, 8'(-sum_aud)};
        end else begin
            hdr1 = 24'h000001;
            for (int k = 0; k < 4; k++)
                sub1[56*k +: 56] = {8'(ACR_N), 8'(ACR_N >> 8), 8'(ACR_N >> 16),
                                    8'(ACR_CTS), 8'(ACR_CTS >> 8), 8'(ACR_CTS >> 16), 8'h00};
        end
    end

    // The packet being sent: shift registers, with the ECC after the data.
    function automatic logic [7:0] ecc_next(input logic [7:0] e, input logic b);
        ecc_next = {1'b0, e[7:1]} ^ ((e[0] ^ b) ? 8'h83 : 8'h00);
    endfunction

    logic [23:0]  hsr;
    logic [223:0] ssr;
    logic [7:0]   hecc, secc[4];
    logic [4:0]   pp;       // the clock within the packet
    logic         first;    // the island's first packet clock
    logic         hbit;
    logic [3:0]   n1, n2;   // channel 1's and 2's nibbles

    wire load = in_isl && (ic == 7'(I_PK - 1) || ic == 7'(I_PK + 31));

    always_comb begin
        hbit = pp < 5'd24 ? hsr[0] : hecc[0];
        for (int k = 0; k < 4; k++) begin
            n1[k] = pp < 5'd28 ? ssr[56*k]     : secc[k][0];
            n2[k] = pp < 5'd28 ? ssr[56*k + 1] : secc[k][1];
        end
    end

    always_ff @(posedge clk) begin
        if (load) begin
            hsr  <= ic == 7'(I_PK - 1) ? hdr0 : hdr1;
            ssr  <= ic == 7'(I_PK - 1) ? sub0 : sub1;
            hecc <= '0;
            for (int k = 0; k < 4; k++)
                secc[k] <= '0;
            pp   <= '0;
        end else if (kind == K_DATA) begin
            pp <= pp + 1'b1;
            if (pp < 5'd24) begin
                hecc <= ecc_next(hecc, hsr[0]);
                hsr  <= hsr >> 1;
            end else
                hecc <= hecc >> 1;
            for (int k = 0; k < 4; k++)
                if (pp < 5'd28) begin
                    secc[k] <= ecc_next(ecc_next(secc[k], ssr[56*k]), ssr[56*k + 1]);
                    ssr[56*k +: 56] <= ssr[56*k +: 56] >> 2;
                end else
                    secc[k] <= secc[k] >> 2;
        end
        // The samples sent go out of the queue's count of IEC frames.
        if (in_isl && ic == 7'(I_PK - 1))
            iec <= frame_plus(iec, smp_n);
        if (rst)
            iec <= '0;
    end
    assign first = in_isl && ic == 7'(I_PK);

    // ---- The delay to meet the pixel source ----
    // {kind, first, header bit, ch1, ch2 nibbles, vsync, hsync}, from blanking
    // at reset.
    localparam int DW = 3 + 1 + 1 + 4 + 4 + 2;
    logic [LATENCY-1:0][DW-1:0] dly;

    always_ff @(posedge clk)
        if (rst)
            dly <= {LATENCY{3'(K_CTL), 10'b0, !V_POS, !H_POS}};
        else begin
            dly[0] <= {3'(kind), first, hbit, n1, n2, vs ~^ V_POS, hs ~^ H_POS};
            for (int i = 1; i < LATENCY; i++)
                dly[i] <= dly[i-1];
        end

    kind_t k_d;
    assign k_d = kind_t'(dly[LATENCY-1][DW-1 -: 3]);
    wire        f_d = dly[LATENCY-1][11];
    wire        h_d = dly[LATENCY-1][10];
    wire [3:0] n1_d = dly[LATENCY-1][9:6];
    wire [3:0] n2_d = dly[LATENCY-1][5:2];
    wire [1:0] sync = dly[LATENCY-1][1:0];
    wire        de  = k_d == K_VID;

    wire [1:0] c1 = k_d == K_VPRE || k_d == K_DPRE ? 2'b01 : 2'b00;  // {CTL1, CTL0}
    wire [1:0] c2 = k_d == K_DPRE ? 2'b01 : 2'b00;                   // {CTL3, CTL2}

    logic [9:0] e0, e1, e2;
    tmds_encoder u_enc0 (.clk, .rst, .de, .d(rgb[7:0]),   .c(sync), .q(e0));
    tmds_encoder u_enc1 (.clk, .rst, .de, .d(rgb[15:8]),  .c(c1),   .q(e1));
    tmds_encoder u_enc2 (.clk, .rst, .de, .d(rgb[23:16]), .c(c2),   .q(e2));

    // ---- Guard bands and TERC4, two clocks behind to meet the encoders ----
    function automatic logic [9:0] terc4(input logic [3:0] d);
        case (d)
            4'h0: terc4 = 10'b1010011100; 4'h1: terc4 = 10'b1001100011;
            4'h2: terc4 = 10'b1011100100; 4'h3: terc4 = 10'b1011100010;
            4'h4: terc4 = 10'b0101110001; 4'h5: terc4 = 10'b0100011110;
            4'h6: terc4 = 10'b0110001110; 4'h7: terc4 = 10'b0100111100;
            4'h8: terc4 = 10'b1011001100; 4'h9: terc4 = 10'b0100111001;
            4'hA: terc4 = 10'b0110011100; 4'hB: terc4 = 10'b1011000110;
            4'hC: terc4 = 10'b1010001110; 4'hD: terc4 = 10'b1001110001;
            4'hE: terc4 = 10'b0101100011; default: terc4 = 10'b1011000011;
        endcase
    endfunction

    localparam logic [9:0] GB_VID0 = 10'b1011001100, GB_VID1 = 10'b0100110011, GB_DATA = 10'b0100110011;

    logic       own_q, own_qq;   // a guard band or data island: these symbols, not the encoders'
    logic       pk_q, pk_qq;
    logic [29:0] sym_q, sym_qq;

    always_ff @(posedge clk) begin
        own_q  <= k_d == K_VGB || k_d == K_DGB || k_d == K_DATA;
        own_qq <= own_q;
        pk_q   <= k_d == K_DATA;
        pk_qq  <= pk_q;
        sym_qq <= sym_q;
        case (k_d)
            K_VGB:   sym_q <= {GB_VID0, GB_VID1, GB_VID0};
            K_DGB:   sym_q <= {GB_DATA, GB_DATA, terc4({2'b11, sync})};
            default: sym_q <= {terc4(n2_d), terc4(n1_d), terc4({!f_d, h_d, sync})};
        endcase
        if (rst) begin
            own_q  <= 1'b0;
            own_qq <= 1'b0;
            pk_q   <= 1'b0;
            pk_qq  <= 1'b0;
        end
    end

    assign tmds0 = own_qq ? sym_qq[9:0]   : e0;
    assign tmds1 = own_qq ? sym_qq[19:10] : e1;
    assign tmds2 = own_qq ? sym_qq[29:20] : e2;
    assign packet = pk_qq;

    initial begin
        if (LATENCY < 1)
            $error("hdmi: LATENCY must be 1 or more");
        if (H_TOTAL > 4096 || V_TOTAL > 4096)
            $error("hdmi: a line or frame longer than 4096");
        if (AUDIO && H_ACTIVE + I_END + 4 > V_PRE)
            $error("hdmi: the horizontal blanking is too short for a data island");
    end
endmodule
