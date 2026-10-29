// SPDX-License-Identifier: Apache-2.0
// One of the 2A03's pulse channels: a duty sequencer stepped by an 11-bit
// timer every 2(t + 1) CPU cycles, with an envelope, a length counter and a
// sweep. CH1 selects pulse 1's sweep, whose negate subtracts one more (ones'
// complement). One CPU cycle per `ce`, the cycle's writes before its tick.
module apu_pulse #(
    parameter bit CH1 = 1'b1
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       ce,
    input  logic       wr,       // a write to this channel's registers this cycle
    input  logic [1:0] wreg,     // which: $4000-$4003 (or $4004-$4007)
    input  logic [7:0] wdata,
    input  logic       wr_en,    // $4015 written
    input  logic       en_val,   // its bit for this channel
    input  logic       quarter,
    input  logic       half,
    output logic       active,   // length counter nonzero
    output logic [3:0] out,
    // Save state: 3 words
    input  logic [1:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    logic [1:0]  duty;
    logic [2:0]  pos;
    logic [10:0] period;
    logic [11:0] timer;
    logic        sw_en, sw_neg, sw_reload;
    logic [2:0]  sw_shift;
    logic [3:0]  sw_per;   // the divider's period, P + 1
    logic [7:0]  sw_div;   // 8 bits: from 0 it wraps, as in MesenCE
    logic        pset;     // the period has been written: until then the timer reloads 0, as in MesenCE

    // Envelope and length counter
    logic        halt, len_active;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        len_next;  // only the triangle's sequencer needs it
    /* verilator lint_on UNUSEDSIGNAL */
    logic [3:0]  level;
    logic [26:0] len_st;
    logic [13:0] env_st;

    apu_length u_len (
        .clk, .rst, .ce,
        .wr_halt(wr && wreg == 2'd0), .halt_val(wdata[5]),
        .wr_load(wr && wreg == 2'd3), .load_idx(wdata[7:3]),
        .wr_en, .en_val, .half, .active(len_active), .active_next(len_next), .halt,
        .st(len_st), .st_we(st_we && st_addr == 2'd2), .st_wdata(st_wdata[26:0]));

    apu_envelope u_env (
        .clk, .rst, .ce,
        .wr_ctrl(wr && wreg == 2'd0), .ctrl(wdata[4:0]), .wr_start(wr && wreg == 2'd3),
        .quarter, .loop(halt), .level,
        .st(env_st), .st_we(st_we && st_addr == 2'd1), .st_wdata(st_wdata[13:0]));

    function automatic logic [11:0] target_of(input logic [10:0] p, input logic neg, input logic [2:0] shift);
        logic [11:0] d;
        d = {1'b0, p >> shift};
        if (neg)
            target_of = {1'b0, p} - d - (CH1 ? 12'd1 : 12'd0);
        else
            target_of = {1'b0, p} + d;
    endfunction

    function automatic logic duty_bit(input logic [1:0] d, input logic [2:0] p);
        case (d)
            2'd0:    duty_bit = p == 3'd7;
            2'd1:    duty_bit = p >= 3'd6;
            2'd2:    duty_bit = p >= 3'd4;
            default: duty_bit = p <= 3'd5;
        endcase
    endfunction

    logic [11:0] target;
    logic        muted;

    assign target   = target_of(period, sw_neg, sw_shift);
    assign muted    = period < 11'd8 || (!sw_neg && target > 12'h7FF);
    assign active   = len_active;
    assign out      = (!muted && len_active && duty_bit(duty, pos)) ? level : 4'd0;

    always_comb
        case (st_addr)
            2'd0:    st_rdata = {duty, pos, period, sw_en, sw_neg, sw_reload, sw_shift, sw_per, sw_div[3:0], pset, 1'b0};
            2'd1:    st_rdata = {sw_div[7:4], timer, 2'b0, env_st};
            default: st_rdata = {5'b0, len_st};
        endcase

    // Writes, then the tick.
    logic [1:0]  w_duty;
    logic [2:0]  w_pos, n_pos;
    logic [10:0] w_period, n_period;
    logic        w_sw_en, w_sw_neg, w_sw_reload, n_sw_reload, w_pset;
    logic [2:0]  w_sw_shift;
    logic [3:0]  w_sw_per;
    logic [7:0]  n_sw_div;
    logic [11:0] n_timer, w_target;

    always_comb begin
        w_duty      = duty;
        w_pos       = pos;
        w_period    = period;
        w_sw_en     = sw_en;
        w_sw_neg    = sw_neg;
        w_sw_reload = sw_reload;
        w_sw_shift  = sw_shift;
        w_sw_per    = sw_per;
        w_pset      = pset || (wr && wreg[1]);
        if (wr)
            case (wreg)
                2'd0: w_duty = wdata[7:6];
                2'd1: begin
                    w_sw_en     = wdata[7];
                    w_sw_per    = {1'b0, wdata[6:4]} + 4'd1;
                    w_sw_neg    = wdata[3];
                    w_sw_shift  = wdata[2:0];
                    w_sw_reload = 1'b1;
                end
                2'd2: w_period = {period[10:8], wdata};
                default: begin
                    w_period = {wdata[2:0], period[7:0]};
                    w_pos    = '0;
                end
            endcase
        w_target = target_of(w_period, w_sw_neg, w_sw_shift);

        // The half-frame clock's sweep.
        n_period    = w_period;
        n_sw_div    = sw_div;
        n_sw_reload = w_sw_reload;
        if (half) begin
            n_sw_div = sw_div - 8'd1;
            if (n_sw_div == '0) begin
                if (w_sw_shift != '0 && w_sw_en && w_period >= 11'd8 && w_target <= 12'h7FF)
                    n_period = w_target[10:0];
                n_sw_div = {4'b0, w_sw_per};
            end
            if (w_sw_reload) begin
                n_sw_div    = {4'b0, w_sw_per};
                n_sw_reload = 1'b0;
            end
        end

        // The timer: down to 0, then reload from 2t + 1 and step the sequencer.
        n_pos = w_pos;
        if (timer == '0) begin
            n_timer = w_pset ? {n_period, 1'b1} : 12'd0;
            n_pos   = w_pos - 3'd1;
        end else
            n_timer = timer - 12'd1;
    end

    always_ff @(posedge clk)
        if (rst) begin
            {duty, pos, period, timer, sw_en, sw_neg, sw_reload, sw_shift, sw_per, sw_div, pset} <= '0;
        end else if (st_we) begin
            if (st_addr == 2'd0)
                {duty, pos, period, sw_en, sw_neg, sw_reload, sw_shift, sw_per, sw_div[3:0], pset} <= st_wdata[31:1];
            if (st_addr == 2'd1)
                {sw_div[7:4], timer} <= st_wdata[31:16];
        end else if (ce) begin
            duty      <= w_duty;
            pos       <= n_pos;
            period    <= n_period;
            timer     <= n_timer;
            sw_en     <= w_sw_en;
            sw_neg    <= w_sw_neg;
            sw_reload <= n_sw_reload;
            sw_shift  <= w_sw_shift;
            sw_per    <= w_sw_per;
            sw_div    <= n_sw_div;
            pset      <= w_pset;
        end
endmodule
