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
    input  logic       ce,       // one CPU cycle
    // This cycle's writes
    input  logic       wr_halt,  // the channel's halt bit is written
    input  logic       halt_val,
    input  logic       wr_load,  // the length load is written
    input  logic [4:0] load_idx,
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

    function automatic logic [7:0] table_val(input logic [4:0] i);
        case (i)
            5'h00: table_val = 8'd10;  5'h01: table_val = 8'd254; 5'h02: table_val = 8'd20;  5'h03: table_val = 8'd2;
            5'h04: table_val = 8'd40;  5'h05: table_val = 8'd4;   5'h06: table_val = 8'd80;  5'h07: table_val = 8'd6;
            5'h08: table_val = 8'd160; 5'h09: table_val = 8'd8;   5'h0A: table_val = 8'd60;  5'h0B: table_val = 8'd10;
            5'h0C: table_val = 8'd14;  5'h0D: table_val = 8'd12;  5'h0E: table_val = 8'd26;  5'h0F: table_val = 8'd14;
            5'h10: table_val = 8'd12;  5'h11: table_val = 8'd16;  5'h12: table_val = 8'd24;  5'h13: table_val = 8'd18;
            5'h14: table_val = 8'd48;  5'h15: table_val = 8'd20;  5'h16: table_val = 8'd96;  5'h17: table_val = 8'd22;
            5'h18: table_val = 8'd192; 5'h19: table_val = 8'd24;  5'h1A: table_val = 8'd72;  5'h1B: table_val = 8'd26;
            5'h1C: table_val = 8'd16;  5'h1D: table_val = 8'd28;  5'h1E: table_val = 8'd32;  default: table_val = 8'd30;
        endcase
    endfunction

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
            w_reload = table_val(load_idx);
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
