// SPDX-License-Identifier: Apache-2.0
// The LCD's registers and line timing, without pixels: G2's stand-in for the
// PPU (G3 replaces it). LCDC, STAT, SCY, SCX, LY, LYC, BGP, OBP0, OBP1, WY
// and WX read and write as on the chip; with the LCD on, a line takes 456
// T-cycles (mode 2 for 80, mode 3 for 172, mode 0 for the rest: mode 3's
// length doesn't yet vary), lines 144-153 are VBlank (mode 1), and LY=144
// requests the VBlank interrupt. STAT's interrupt is requested when the OR of
// its enabled conditions (LY=LYC, mode 0, 1 or 2) rises. With the LCD off, LY
// and the mode read 0 and the line restarts when it's turned on.
module gb_lcd_timing (
    input  logic       clk,
    input  logic       rst,
    input  logic       t,          // one T-cycle (a dot)
    input  logic       m,          // with t: the M-cycle's last T-cycle, where the CPU's writes land
    input  logic       wr,
    input  logic [3:0] reg_sel,    // FF40 + reg_sel
    input  logic [7:0] wdata,
    output logic [7:0] rdata,      // register reg_sel, as read
    output logic       irq_vblank, // with t: request the interrupt (at this edge)
    output logic       irq_stat,   // with t
    output logic [7:0] lcdc
);
    logic [7:0] scy, scx, ly, lyc, bgp, obp0, obp1, wy, wx;
    logic [3:0] stat_en;           // STAT bits 6-3
    logic [8:0] dot;
    logic       line_irq;          // the OR of STAT's enabled conditions, last T-cycle

    logic [1:0] mode;
    always_comb begin
        if (!lcdc[7]) mode = 2'd0;
        else if (ly >= 8'd144) mode = 2'd1;
        else if (dot < 9'd80) mode = 2'd2;
        else if (dot < 9'd252) mode = 2'd3;
        else mode = 2'd0;
    end
    wire coinc = ly == lyc;
    assign irq_vblank = t && lcdc[7] && dot == 9'd455 && ly == 8'd143;
    wire line_now = lcdc[7] && (coinc && stat_en[3] || mode == 2'd0 && stat_en[0] ||
                                mode == 2'd1 && stat_en[1] || mode == 2'd2 && stat_en[2]);
    assign irq_stat = t && line_now && !line_irq;

    always_comb begin
        case (reg_sel)
            4'h0: rdata = lcdc;
            4'h1: rdata = {1'b1, stat_en, coinc && lcdc[7], mode};
            4'h2: rdata = scy;
            4'h3: rdata = scx;
            4'h4: rdata = ly;
            4'h5: rdata = lyc;
            4'h7: rdata = bgp;
            4'h8: rdata = obp0;
            4'h9: rdata = obp1;
            4'hA: rdata = wy;
            4'hB: rdata = wx;
            default: rdata = 8'hFF;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            lcdc <= '0;  scy <= '0;  scx <= '0;  lyc <= '0;
            bgp  <= '0;  obp0 <= '0; obp1 <= '0; wy <= '0; wx <= '0;
            stat_en  <= '0;
            ly       <= '0;
            dot      <= '0;
            line_irq <= 1'b0;
        end else if (t) begin
            line_irq <= line_now;
            if (lcdc[7]) begin
                if (dot == 9'd455) begin
                    dot <= '0;
                    ly  <= ly == 8'd153 ? 8'd0 : ly + 8'd1;
                end else begin
                    dot <= dot + 9'd1;
                end
            end
            if (m && wr) begin
                case (reg_sel)
                    4'h0: begin
                        lcdc <= wdata;
                        if (!wdata[7]) begin
                            ly  <= '0;
                            dot <= '0;
                        end
                    end
                    4'h1: stat_en <= wdata[6:3];
                    4'h2: scy  <= wdata;
                    4'h3: scx  <= wdata;
                    4'h5: lyc  <= wdata;
                    4'h7: bgp  <= wdata;
                    4'h8: obp0 <= wdata;
                    4'h9: obp1 <= wdata;
                    4'hA: wy   <= wdata;
                    4'hB: wx   <= wdata;
                    default: ;
                endcase
            end
        end
    end
endmodule
