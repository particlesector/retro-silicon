// SPDX-License-Identifier: Apache-2.0
// Video timing and TMDS encoding for a DVI-compatible HDMI output: the three
// 10-bit symbols to send each pixel clock, for a board's serializers.
// Defaults are CEA-861's 1280x720 at 60 Hz (74.25 MHz pixel clock).
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
    parameter int LATENCY  = 2      // clocks from x, y to rgb, 1 or more
) (
    input  logic        clk,  // the pixel clock
    input  logic        rst,

    output logic [11:0] x,
    output logic [11:0] y,
    output logic        act,
    output logic        frame,
    output logic        line,
    input  logic [23:0] rgb,  // {red, green, blue}

    output logic [9:0]  tmds0,  // blue, with the syncs
    output logic [9:0]  tmds1,  // green
    output logic [9:0]  tmds2   // red
);
    localparam int H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
    localparam int V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;
    localparam int HS_ON   = H_ACTIVE + H_FRONT;
    localparam int VS_ON   = V_ACTIVE + V_FRONT;

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

    // The delay to meet the pixel source: {de, vsync, hsync}, from blanking
    // at reset.
    logic [LATENCY-1:0][2:0] dly;

    always_ff @(posedge clk)
        if (rst)
            dly <= {LATENCY{1'b0, !V_POS, !H_POS}};
        else begin
            dly[0] <= {act, vs ~^ V_POS, hs ~^ H_POS};
            for (int i = 1; i < LATENCY; i++)
                dly[i] <= dly[i-1];
        end

    wire de = dly[LATENCY-1][2];
    wire [1:0] sync = dly[LATENCY-1][1:0];

    tmds_encoder u_enc0 (.clk, .rst, .de, .d(rgb[7:0]),   .c(sync),  .q(tmds0));
    tmds_encoder u_enc1 (.clk, .rst, .de, .d(rgb[15:8]),  .c(2'b00), .q(tmds1));
    tmds_encoder u_enc2 (.clk, .rst, .de, .d(rgb[23:16]), .c(2'b00), .q(tmds2));

    initial begin
        if (LATENCY < 1)
            $error("hdmi: LATENCY must be 1 or more");
        if (H_TOTAL > 4096 || V_TOTAL > 4096)
            $error("hdmi: a line or frame longer than 4096");
    end
endmodule
