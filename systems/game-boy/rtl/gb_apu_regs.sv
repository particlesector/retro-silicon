// SPDX-License-Identifier: Apache-2.0
// The sound registers without the sound: G2's stand-in for the APU (G5
// replaces it). FF10-FF26 read back with their unreadable bits as 1, as on
// the Game Boy; NR52's power bit clears FF10-FF25 and ignores writes to them
// while off; its channel bits read 0 (no channel plays). FF27-FF2F read FF,
// and the wave RAM (FF30-FF3F) reads and writes freely.
module gb_apu_regs (
    input  logic       clk,
    input  logic       rst,
    input  logic       m,        // the M-cycle's last T-cycle, where the CPU's writes land
    input  logic       wr,
    input  logic [5:0] reg_sel,  // FF10 + reg_sel
    input  logic [7:0] wdata,
    output logic [7:0] rdata
);
    logic [7:0] r [0:22];        // FF10-FF26 (NR52's power in bit 7)
    logic [7:0] wave [0:15];

    function automatic logic [7:0] mask(input logic [4:0] i);
        case (i)
            5'h00: mask = 8'h80;
            5'h01, 5'h06: mask = 8'h3F;
            5'h04, 5'h09, 5'h0E, 5'h13: mask = 8'hBF;
            5'h0A: mask = 8'h7F;
            5'h0C: mask = 8'h9F;
            5'h02, 5'h07, 5'h11, 5'h12, 5'h14, 5'h15: mask = 8'h00;
            5'h16: mask = 8'h70;
            default: mask = 8'hFF;   // write-only: NR13, NR23, NR31, NR33, NR41, and FF15, FF1F
        endcase
    endfunction

    always_comb begin
        if (reg_sel < 6'h17) rdata = r[reg_sel[4:0]] | mask(reg_sel[4:0]);
        else if (reg_sel < 6'h20) rdata = 8'hFF;
        else rdata = wave[reg_sel[3:0]];
    end

    wire on = r[22][7];
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 23; i++) r[i] <= '0;
        end else if (m && wr) begin
            if (reg_sel == 6'h16) begin
                r[22] <= {wdata[7], 7'd0};
                if (!wdata[7]) for (int i = 0; i < 22; i++) r[i] <= '0;
            end else if (reg_sel < 6'h16) begin
                if (on) r[reg_sel[4:0]] <= wdata;
            end else if (reg_sel >= 6'h20) begin
                wave[reg_sel[3:0]] <= wdata;
            end
        end
    end
endmodule
