// SPDX-License-Identifier: Apache-2.0
// The Game Boy's joypad register, P1. Bit 4 low selects the direction keys
// (right, left, up, down in bits 0-3), bit 5 low the buttons (A, B, Select,
// Start); a key reads 0 while pressed in a selected group. A line of bits 3-0
// going low requests the joypad interrupt, and any of them low (`low`) is
// what wakes the CPU from STOP.
module gb_joypad (
    input  logic       clk,
    input  logic       rst,
    input  logic       m,        // the M-cycle's last T-cycle, where the CPU's writes land
    input  logic       wr,
    input  logic [1:0] wsel,     // bits 5-4 of the byte written
    input  logic [7:0] keys,     // 1 pressed: Start, Select, B, A, down, up, left, right (bit 7 to 0)
    output logic [7:0] p1,       // as read: bits 7-6 read 1
    output logic       irq,      // with m: request the joypad interrupt (at this edge)
    output logic       low       // a selected key is down
);
    logic [1:0] sel;
    logic [3:0] lines, last;

    always_comb begin
        lines = 4'hF;
        if (!sel[0]) lines = lines & ~keys[3:0];
        if (!sel[1]) lines = lines & ~keys[7:4];
    end
    assign p1  = {2'b11, sel, lines};
    assign low = lines != 4'hF;
    assign irq = m && |(last & ~lines);

    always_ff @(posedge clk) begin
        if (rst) begin
            sel  <= 2'b11;
            last <= 4'hF;
        end else if (m) begin
            if (wr) sel <= wsel;
            last <= lines;
        end
    end
endmodule
