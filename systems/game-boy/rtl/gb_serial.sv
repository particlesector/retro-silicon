// SPDX-License-Identifier: Apache-2.0
// The Game Boy's serial port, SB and SC, with nothing on the other end of the
// link: each bit shifted in is 1. With the internal clock (SC bit 0), the
// serial clock is a flip-flop that toggles on each falling edge of the system
// counter's bit 7 (`fall7`), so it keeps the counter's phase from reset, not
// the SC write's; each time it falls, a running transfer shifts a bit out and
// in, and after 8 clears SC bit 7 and requests the serial interrupt (8,192
// bits a second). A write to SC first gives the clock its falling edge if it
// is high (shifting with SC as it was), then starts the bit count again. With
// the external clock, a transfer waits forever, as it does with no cable.
// This is SameBoy's model of the DMG's serial clock.
//
// On the Game Boy Color in its own mode (`cgb_hw`), SC's bit 1 (the fast clock) is kept and read back; the
// clock's speed doesn't follow it yet.
//
// `tx`/`tx_valid`: the byte in SB when a write to SC sets bits 7 and 0, the
// stream blargg's and Mooneye's test ROMs report on (as MesenCE's test
// script takes it).
module gb_serial (
    input  logic        clk,
    input  logic        rst,
    input  logic        cgb_hw,     // the Game Boy Color in its own mode: SC bit 1 is there
    input  logic        m,          // the M-cycle's last T-cycle, where the CPU's writes land
    input  logic        fall7,      // the system counter's bit 7 falls at this edge
    input  logic        wr_sb,      // with m
    input  logic        wr_sc,
    input  logic [7:0]  wdata,
    output logic [7:0]  sb,
    output logic [7:0]  sc,         // as read: bits 6-1 read 1
    output logic        irq,        // request the serial interrupt (at this edge)
    output logic [7:0]  tx,
    output logic        tx_valid    // a transfer of `tx` starts (the clock after the write)
);
    logic       busy, int_clk, sclk, fast;
    logic [2:0] bits;

    // The clock's falling edge, and whether it shifts a bit.
    wire wr_sc_m = m && wr_sc;
    wire fall    = sclk && (fall7 || wr_sc_m);
    wire shift   = fall && busy && int_clk;

    assign sc  = {busy, 5'b11111, fast || !cgb_hw, int_clk};
    assign irq = shift && !wr_sc_m && bits == 3'd7;

    always_ff @(posedge clk) begin
        tx_valid <= 1'b0;
        if (rst) begin
            sb      <= '0;
            busy    <= 1'b0;
            int_clk <= 1'b0;
            fast    <= 1'b0;
            bits    <= '0;
            sclk    <= 1'b0;
        end else begin
            if (fall7 || wr_sc_m) sclk <= fall7 ? !sclk : 1'b0;
            if (shift) sb <= {sb[6:0], 1'b1};
            if (wr_sc_m) begin
                busy    <= wdata[7];
                int_clk <= wdata[0];
                fast    <= wdata[1] && cgb_hw;
                bits    <= shift ? 3'd1 : 3'd0;
                if (wdata[7] && wdata[0]) begin
                    tx       <= wr_sb ? wdata : sb;
                    tx_valid <= 1'b1;
                end
            end else if (shift) begin
                bits <= bits + 3'd1;
                if (bits == 3'd7) busy <= 1'b0;
            end
            if (m && wr_sb) sb <= wdata;
        end
    end
endmodule
