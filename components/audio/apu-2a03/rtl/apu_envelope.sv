// SPDX-License-Identifier: Apache-2.0
// The 2A03's envelope, for the pulse and noise channels: a constant volume,
// or a decay from 15 that the quarter-frame clock steps through a divider of
// the volume's period, looping when the length counter's halt flag is set.
// One CPU cycle per `ce`, the cycle's writes before its tick, as in
// apu_length.
module apu_envelope (
    input  logic       clk,
    input  logic       rst,
    input  logic       ce,
    input  logic       wr_ctrl,   // $4000/$4004/$400C: constant flag and volume
    input  logic [4:0] ctrl,      // {constant, volume}
    input  logic       wr_start,  // $4003/$4007/$400F: restart
    input  logic       quarter,   // the frame counter's quarter-frame clock
    input  logic       loop,      // the length counter's halt flag
    output logic [3:0] level,     // the volume, before the length counter's gate
    // Save state: {constant, volume, start, divider, decay}
    output logic [13:0] st,
    input  logic        st_we,
    input  logic [13:0] st_wdata
);
    logic       constant, start;
    logic [3:0] vol, div, decay;

    assign level = constant ? vol : decay;
    assign st    = {constant, vol, start, div, decay};

    logic       w_constant, w_start, n_start;
    logic [3:0] w_vol, n_div, n_decay;

    always_comb begin
        {w_constant, w_vol} = wr_ctrl ? ctrl : {constant, vol};
        w_start = start || wr_start;
        n_start = w_start;
        n_div   = div;
        n_decay = decay;
        if (quarter) begin
            if (w_start) begin
                n_start = 1'b0;
                n_decay = 4'd15;
                n_div   = w_vol;
            end else if (div == '0) begin
                n_div = w_vol;
                if (decay != '0)
                    n_decay = decay - 4'd1;
                else if (loop)
                    n_decay = 4'd15;
            end else
                n_div = div - 4'd1;
        end
    end

    always_ff @(posedge clk)
        if (rst)
            {constant, vol, start, div, decay} <= '0;
        else if (st_we)
            {constant, vol, start, div, decay} <= st_wdata;
        else if (ce) begin
            constant <= w_constant;
            vol      <= w_vol;
            start    <= n_start;
            div      <= n_div;
            decay    <= n_decay;
        end
endmodule
