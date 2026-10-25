// SPDX-License-Identifier: Apache-2.0
// Clock enable at NUM/DEN of the clock rate, exactly on average: a phase
// accumulator gains NUM each enabled clock and fires when it reaches DEN, so
// pulses are floor(DEN/NUM) or ceil(DEN/NUM) clocks apart and never drift.
// The NES's PPU dot rate (236.25/44 MHz) from 27 MHz is NUM = 35, DEN = 176.
//
// While `en` is low the accumulator holds, so stopping and restarting the
// enables leaves the pulse pattern as if no time had passed.
module clock_enable #(
    parameter int NUM = 1,
    parameter int DEN = 2
) (
    input  logic clk,
    input  logic rst,  // synchronous; restarts the phase from 0
    input  logic en,   // advance this clock
    output logic ce    // one-clock pulse, NUM per DEN enabled clocks
);
    localparam int W = $clog2(DEN + NUM + 1);

    logic [W-1:0] acc;
    wire  [W-1:0] sum  = acc + W'(NUM);
    wire          fire = sum >= W'(DEN);

    assign ce = en && fire;

    always_ff @(posedge clk)
        if (rst)
            acc <= '0;
        else if (en)
            acc <= fire ? sum - W'(DEN) : sum;

    initial begin
        if (NUM < 1 || NUM > DEN)
            $error("clock_enable: NUM must be 1 to DEN");
    end
endmodule
