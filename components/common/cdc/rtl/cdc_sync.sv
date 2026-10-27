// SPDX-License-Identifier: Apache-2.0
// Brings a signal from another clock domain into this one through STAGES
// flip-flops, so a value that changes near the clock edge settles before
// anything uses it. Safe only for signals whose bits can be taken in any
// mix of old and new without harm: a level, a toggle (one bit that flips per
// event), a Gray-coded count (one bit changes per step), or a value the other
// side holds steady from before a toggle it sends until after it's seen.
module cdc_sync #(
    parameter int W      = 1,
    parameter int STAGES = 2
) (
    input  logic         clk,  // this domain's clock
    input  logic [W-1:0] d,    // from the other domain
    output logic [W-1:0] q
);
    logic [STAGES-1:0][W-1:0] s;

    always_ff @(posedge clk) begin
        s[0] <= d;
        for (int i = 1; i < STAGES; i++)
            s[i] <= s[i-1];
    end

    assign q = s[STAGES-1];

    initial begin
        if (STAGES < 2)
            $error("cdc_sync: STAGES must be 2 or more");
    end
endmodule
