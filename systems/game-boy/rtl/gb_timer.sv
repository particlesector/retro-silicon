// SPDX-License-Identifier: Apache-2.0
// The Game Boy's timer: DIV, TIMA, TMA and TAC, on the system counter.
//
// The system counter counts T-cycles; DIV is its upper byte. TIMA counts
// falling edges of TAC's enable ANDed with one of the counter's bits (TAC 0:
// bit 9, 1: bit 3, 2: bit 5, 3: bit 7), so writing DIV (the counter goes to
// 0) or TAC can make an edge, and an extra count, as on the chip.
//
// Every such edge comes once an M-cycle at most, so the counter is kept in
// M-cycles (its bits 15-2) and steps on `tick`, the M-cycle's third T-cycle:
// before the CPU's read in the last one, which sees the step, and before its
// write at the end of it (`wr_*`, with `m`), which comes after it.
//
// TIMA's overflow: TIMA reads 0 for one M-cycle (cycle A, to the next tick);
// then TIMA takes TMA and `irq` pulses, unless the CPU wrote TIMA during
// cycle A, which cancels both. In the next M-cycle (cycle B) a write to TIMA
// is lost and a write to TMA goes to TIMA as well.
//
// In the Game Boy Color's double speed (`dbl`) the counter runs twice as fast with the CPU, and the
// APU's frame sequencer follows bit 13 rather than 12, so it keeps its rate.
module gb_timer (
    input  logic        clk,
    input  logic        rst,
    input  logic        dbl,        // the Color's double speed
    input  logic        tick,       // the M-cycle's third T-cycle
    input  logic        m,          // its last: the CPU's writes land
    input  logic        wr_div,     // with m: the CPU writes these
    input  logic        wr_tima,
    input  logic        wr_tma,
    input  logic        wr_tac,
    input  logic [7:0]  wdata,
    output logic [13:0] counter,    // the system counter's bits 15-2; DIV is bits 13-6
    output logic [7:0]  tima,
    output logic [7:0]  tma,
    output logic [7:0]  tac,        // as read: bits 7-3 read 1
    output logic        irq,        // with tick: request the timer interrupt (at this edge)
    output logic        fall7,      // the counter's T-cycle bit 7 falls at this edge (the serial clock)
    output logic        fall12,     // its bit 12 (13 in double speed) falls at this edge (the APU's frame sequencer)
    output logic        rise12      // ...or rises (the APU's envelopes)
);
    logic [2:0] tac_r;
    logic       ovf;   // cycle A
    logic       rld;   // cycle B

    // TAC's enable ANDed with the counter bit it selects: b is the counter's T-cycle bits 7, 5, 3 and 9.
    function automatic logic tbit(input logic [2:0] c, input logic [3:0] b);
        tbit = b[c[1:0]] & c[2];
    endfunction

    // A count, from the tick or a write.
    logic [13:0] cnt_n;
    logic [2:0]  tac_n;
    logic        inc;
    always_comb begin
        if (tick) begin
            cnt_n = counter + 14'd1;
            tac_n = tac_r;
        end else begin
            cnt_n = wr_div ? 14'd0 : counter;
            tac_n = wr_tac ? wdata[2:0] : tac_r;
        end
        inc = tbit(tac_r, {counter[5], counter[3], counter[1], counter[7]}) &
              ~tbit(tac_n, {cnt_n[5], cnt_n[3], cnt_n[1], cnt_n[7]});
    end

    assign tac = {5'b11111, tac_r};
    assign irq = tick && ovf;
    assign fall7  = (tick || m) && counter[5] && !cnt_n[5];
    wire fs_o = dbl ? counter[11] : counter[10];
    wire fs_n = dbl ? cnt_n[11] : cnt_n[10];
    assign fall12 = (tick || m) && fs_o && !fs_n;
    assign rise12 = (tick || m) && !fs_o && fs_n;

    always_ff @(posedge clk) begin
        if (rst) begin
            counter <= '0;
            tima    <= '0;
            tma     <= '0;
            tac_r   <= '0;
            ovf     <= 1'b0;
            rld     <= 1'b0;
        end else if (tick) begin
            counter <= cnt_n;
            rld     <= 1'b0;
            if (ovf) begin
                ovf  <= 1'b0;
                tima <= tma;
                rld  <= 1'b1;
            end else if (inc) begin
                tima <= tima + 8'd1;
                ovf  <= tima == 8'hFF;
            end
        end else if (m) begin
            counter <= cnt_n;
            tac_r   <= tac_n;
            if (wr_tma) tma <= wdata;
            if (rld) begin
                if (wr_tma) tima <= wdata;
            end else if (wr_tima) begin
                tima <= wdata;
                ovf  <= 1'b0;
            end else if (inc) begin
                tima <= tima + 8'd1;
                ovf  <= tima == 8'hFF;
            end
        end
    end
endmodule
