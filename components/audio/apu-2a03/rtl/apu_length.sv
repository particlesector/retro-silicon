// SPDX-License-Identifier: Apache-2.0
// The 2A03's length counter, for the pulse, triangle and noise channels.
// One CPU cycle per `ce`: the cycle's register writes first, then its tick
// (the frame counter's half-frame clock, then a pending reload).
//
// A load ($4003 and so on) takes effect in the next cycle's tick, after that
// cycle's half-frame clock, and only if the clock didn't change the counter:
// a load that lands on a clock that decrements the counter is lost. A halt
// write also takes effect in the next tick, after the clock. Both as on the
// 2A03 and in MesenCE (blargg's len_reload_timing and len_halt_timing).
module apu_length (
    input  logic       clk,
    input  logic       rst,
    input  logic       soft_rst, // the reset button: only the enable clears (the triangle's; the others reset)
    input  logic       ce,       // one CPU cycle
    // This cycle's writes
    input  logic       wr_halt,  // the channel's halt bit is written
    input  logic       halt_val,
    input  logic       wr_load,  // the length load is written
    input  logic [7:0] load_val, // the length table's value for it (apu_2a03 looks it up)
    input  logic       wr_en,    // $4015 is written
    input  logic       en_val,
    // This cycle's tick
    input  logic       half,     // the frame counter's half-frame clock
    output logic       active,   // the counter is nonzero ($4015 status, the output gate)
    output logic       active_next,  // nonzero after this cycle's tick: what the triangle's sequencer sees
    output logic       halt,     // the halt flag in force (the envelope's loop flag too)
    // Save state: {en, halt, new halt, counter, reload value, previous value}
    output logic [26:0] st,
    input  logic        st_we,
    input  logic [26:0] st_wdata
);
    logic       en, new_halt;
    logic [7:0] cnt, reload, prev;

    assign active      = cnt != '0;
    assign active_next = n_cnt != '0;
    assign st     = {en, halt, new_halt, cnt, reload, prev};

    // Writes, then the tick.
    logic       w_en, w_new_halt;
    logic [7:0] w_cnt, w_reload, w_prev, n_cnt, n_reload;

    always_comb begin
        w_en       = en;
        w_new_halt = wr_halt ? halt_val : new_halt;
        w_cnt      = cnt;
        w_reload   = reload;
        w_prev     = prev;
        if (wr_load && en) begin
            w_reload = load_val;
            w_prev   = cnt;
        end
        if (wr_en) begin
            w_en = en_val;
            if (!en_val)
                w_cnt = '0;
        end
        n_cnt    = w_cnt;
        n_reload = w_reload;
        if (half && n_cnt != '0 && !halt)
            n_cnt = n_cnt - 8'd1;
        if (n_reload != '0) begin
            if (n_cnt == w_prev)
                n_cnt = n_reload;
            n_reload = '0;
        end
    end

    always_ff @(posedge clk)
        if (rst)
            {en, halt, new_halt, cnt, reload, prev} <= '0;
        else if (soft_rst)
            en <= 1'b0;
        else if (st_we)
            {en, halt, new_halt, cnt, reload, prev} <= st_wdata;
        else if (ce) begin
            en       <= w_en;
            new_halt <= w_new_halt;
            halt     <= w_new_halt;
            cnt      <= n_cnt;
            reload   <= n_reload;
            prev     <= w_prev;
        end
endmodule
