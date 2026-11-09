// SPDX-License-Identifier: Apache-2.0
// Atari TIA (NTSC): the 2600's video, one colour clock per `cc`.
//
// This first part has the line (228 colour clocks: 68 of horizontal blank, then 160 pixels), VSYNC,
// VBLANK, WSYNC, the background, and the playfield with its colours, reflection, score mode and
// priority. Players, missiles, the ball, HMOVE, collisions, the input ports and sound come next.
//
// Timing, as Stella 7.0 runs it:
// - Each CPU cycle is 3 colour clocks; `ce` marks the colour clock that ends one, and the cycle's access
//   (`cs`, `addr`, `we`, `din`) is taken then. A write lands after that clock, so the next colour clock
//   sees it, except those the chip delays: VBLANK by 1 clock, PF0-PF2 by 2.
// - WSYNC holds `rdy` low from the write to the line's end, so the CPU's next read cycle completes as
//   the first cycle of the next line (`cpu/6502` repeats a read cycle that ends with rdy low). A write
//   in the cycle that ends the line doesn't hold it.
// - The playfield takes a new bit every 4 pixels, and its reflection only at pixels 0 and 79.
// - VBLANK blanks the picture to colour 0.
// `pix` is each colour clock's colour value (bit 0 clear), `pix_on` whether it's one of the 160 pixels
// (`x` its column), registered: they describe the colour clock before.

module tia #(
    parameter bit SAVE_STATE = 1'b1  // 0 leaves out the save-state port's logic
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        cc,      // one colour clock
    input  logic        ce,      // this colour clock ends a CPU cycle (with cc)

    input  logic        cs,
    input  logic [5:0]  addr,
    input  logic        we,
    input  logic [7:0]  din,
    output logic [7:0]  dout,    // bits 7-6; the bus keeps its last value in bits 5-0
    output logic        rdy,

    output logic [7:0]  pix,
    output logic        pix_on,
    output logic [7:0]  x,
    output logic        line_end,  // the colour clock before was the line's last
    output logic        vsync,     // VSYNC's bit 1
    output logic        vblank,    // VBLANK's bit 1, as the picture sees it

    input  logic [4:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);

    localparam logic [5:0] VSYNC = 6'h00, VBLANK = 6'h01, WSYNC = 6'h02,
                           COLUP0 = 6'h06, COLUP1 = 6'h07, COLUPF = 6'h08, COLUBK = 6'h09,
                           CTRLPF = 6'h0A, PF0 = 6'h0D, PF1 = 6'h0E, PF2 = 6'h0F;

    // ---- State ----
    logic [7:0]  hctr;                   // colour clock in the line, 0-227
    logic        wsync;                  // WSYNC is holding the CPU
    logic        vsync_r;
    logic        vblank_r;               // as the picture sees it
    logic        vblank_new;             // a VBLANK write waiting its clock
    logic        vblank_pend;
    logic [6:0]  colup0, colup1, colupf, colubk;  // colour values' bits 7-1
    logic        reflect, score, pfp;    // CTRLPF bits 0, 1, 2
    logic        reflect_l;              // the reflection as the playfield uses it
    logic [19:0] pf;                     // playfield bits, left to right: PF0 7-4, PF1 7-0, PF2 0-7 ...
    logic [19:0] pf_new;                 // a PF write waiting
    logic [1:0]  pf_cnt;                 // clocks until it lands
    logic        pf_bit;                 // the playfield bit being drawn

    // ---- This colour clock ----
    wire        in_pic = hctr >= 8'd68;
    wire  [7:0] xc     = hctr - 8'd68;
    wire        last   = hctr == 8'd227;

    // The playfield's 20 bits, by column: bit n of `pf` is the playfield's nth 4-pixel pf_cell.
    wire        refl_now = (xc == 8'd0 || xc == 8'd79) ? reflect : reflect_l;
    logic [4:0] pf_cell;
    always_comb begin
        if (xc < 8'd79)
            pf_cell = xc[6:2];
        else if (refl_now)
            pf_cell = 5'(8'd39 - {2'd0, xc[7:2]});
        else
            pf_cell = 5'({2'd0, xc[7:2]} - 8'd20);
    end
    wire        pf_bit_now = (in_pic && xc[1:0] == 2'd0) ? pf[pf_cell] : pf_bit;

    // The colour, by priority (without objects yet: the playfield over the background). Score mode's
    // colours (COLUP0's on the left half, COLUP1's on the right) need priority off.
    wire  [6:0] pf_col = (score && !pfp) ? (xc < 8'd80 ? colup0 : colup1) : colupf;
    wire  [6:0] col    = pf_bit_now ? pf_col : colubk;
    wire  [3:0] unused_st  = st_wdata[31:28];

    // The playfield's bits from PF0, PF1, PF2 as written.
    function automatic logic [19:0] pf_with(input logic [19:0] cur, input logic [5:0] a, input logic [7:0] v);
        logic [19:0] r;
        r = cur;
        case (a)
            PF0: r[3:0] = v[7:4];
            PF1: for (int i = 0; i < 8; i++) r[4 + i] = v[7 - i];
            default: r[19:12] = v;
        endcase
        pf_with = r;
    endfunction

    wire wr = ce && cs && we;

    always_ff @(posedge clk) begin
        if (rst) begin
            hctr        <= 8'd0;
            wsync       <= 1'b0;
            vsync_r     <= 1'b0;
            vblank_r    <= 1'b0;
            vblank_new  <= 1'b0;
            vblank_pend <= 1'b0;
            colup0      <= 7'd0;
            colup1      <= 7'd0;
            colupf      <= 7'd0;
            colubk      <= 7'd0;
            reflect     <= 1'b0;
            score       <= 1'b0;
            pfp         <= 1'b0;
            reflect_l   <= 1'b0;
            pf          <= 20'd0;
            pf_new      <= 20'd0;
            pf_cnt      <= 2'd0;
            pf_bit      <= 1'b0;
            pix         <= 8'd0;
            pix_on      <= 1'b0;
            x           <= 8'd0;
            line_end    <= 1'b0;
        end else if (cc) begin
            // Draw this colour clock.
            pix      <= {(in_pic && !vblank_r) ? col : 7'd0, 1'b0};
            pix_on   <= in_pic;
            x        <= xc;
            line_end <= last;
            if (in_pic) begin
                pf_bit    <= pf_bit_now;
                reflect_l <= refl_now;
            end
            hctr <= last ? 8'd0 : hctr + 8'd1;
            if (last) wsync <= 1'b0;

            // Writes waiting their clock land after it.
            if (vblank_pend) begin
                vblank_r    <= vblank_new;
                vblank_pend <= 1'b0;
            end
            if (pf_cnt != 2'd0) begin
                if (pf_cnt == 2'd1) pf <= pf_new;
                pf_cnt <= pf_cnt - 2'd1;
            end

            // This cycle's write.
            if (wr)
                case (addr)
                    VSYNC:  vsync_r <= din[1];
                    VBLANK: begin vblank_new <= din[1]; vblank_pend <= 1'b1; end
                    WSYNC:  if (!last) wsync <= 1'b1;
                    COLUP0: colup0 <= din[7:1];
                    COLUP1: colup1 <= din[7:1];
                    COLUPF: colupf <= din[7:1];
                    COLUBK: colubk <= din[7:1];
                    CTRLPF: {pfp, score, reflect} <= din[2:0];
                    PF0, PF1, PF2: begin
                        // A second write before the first lands replaces it.
                        pf_new <= pf_with(pf_cnt != 2'd0 ? pf_new : pf, addr, din);
                        pf_cnt <= 2'd2;
                    end
                    default: ;
                endcase
        end else if (SAVE_STATE && st_we) begin
            case (st_addr)
                5'd0: {pf_cnt, vblank_pend, vblank_new, vblank_r, vsync_r, wsync, pf_bit, reflect_l,
                       pfp, score, reflect, hctr} <= st_wdata[19:0];
                5'd1: {colubk, colupf, colup1, colup0} <= st_wdata[27:0];
                5'd2: pf <= st_wdata[19:0];
                5'd3: pf_new <= st_wdata[19:0];
                5'd4: {line_end, x, pix_on, pix} <= st_wdata[17:0];
                default: ;
            endcase
        end
    end

    // The CPU repeats a read cycle that ends with rdy low, so the one that starts the next line is the
    // first to complete.
    assign rdy    = !wsync;
    assign dout   = 8'd0;  // collisions and inputs come with the objects
    assign vsync  = vsync_r;
    assign vblank = vblank_r;

    if (SAVE_STATE) begin : g_st
        always_ff @(posedge clk)
            case (st_addr)
                5'd0: st_rdata <= {12'd0, pf_cnt, vblank_pend, vblank_new, vblank_r, vsync_r, wsync, pf_bit,
                                   reflect_l, pfp, score, reflect, hctr};
                5'd1: st_rdata <= {4'd0, colubk, colupf, colup1, colup0};
                5'd2: st_rdata <= {12'd0, pf};
                5'd3: st_rdata <= {12'd0, pf_new};
                5'd4: st_rdata <= {14'd0, line_end, x, pix_on, pix};
                default: st_rdata <= '0;
            endcase
    end else begin : g_no_st
        assign st_rdata = '0;
    end

endmodule
