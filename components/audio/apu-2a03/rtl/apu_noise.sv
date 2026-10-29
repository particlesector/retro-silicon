// SPDX-License-Identifier: Apache-2.0
// The 2A03's noise channel (NTSC): a 15-bit linear-feedback shift register,
// starting at 1, stepped by a timer whose period comes from a table of CPU
// cycles; feedback is bit 0 XOR bit 1, or bit 6 in mode 1. The envelope's
// volume goes out while bit 0 is clear and the length counter is nonzero.
// One CPU cycle per `ce`, the cycle's writes before its tick.
module apu_noise (
    input  logic       clk,
    input  logic       rst,
    input  logic       ce,
    input  logic       wr,       // a write to $400C-$400F this cycle
    input  logic [1:0] wreg,
    input  logic [7:0] wdata,
    input  logic       wr_en,    // $4015 written
    input  logic       en_val,
    input  logic       quarter,
    input  logic       half,
    output logic       active,
    output logic [3:0] out,
    // Save state: 3 words
    input  logic [1:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    logic [14:0] lfsr;
    logic        mode;
    logic [11:0] period, timer;  // the table's value - 1, and the count down

    logic        halt, len_active;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        len_next;
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

    function automatic logic [11:0] period_of(input logic [3:0] i);
        case (i)
            4'd0:  period_of = 12'd3;    4'd1:  period_of = 12'd7;    4'd2:  period_of = 12'd15;   4'd3:  period_of = 12'd31;
            4'd4:  period_of = 12'd63;   4'd5:  period_of = 12'd95;   4'd6:  period_of = 12'd127;  4'd7:  period_of = 12'd159;
            4'd8:  period_of = 12'd201;  4'd9:  period_of = 12'd253;  4'd10: period_of = 12'd379;  4'd11: period_of = 12'd507;
            4'd12: period_of = 12'd761;  4'd13: period_of = 12'd1015; 4'd14: period_of = 12'd2033; default: period_of = 12'd4067;
        endcase
    endfunction

    assign active = len_active;
    assign out    = (!lfsr[0] && len_active) ? level : 4'd0;

    always_comb
        case (st_addr)
            2'd0:    st_rdata = {lfsr, mode, period[11:0], 4'b0};
            2'd1:    st_rdata = {timer, 6'b0, env_st};
            default: st_rdata = {5'b0, len_st};
        endcase

    logic [11:0] w_period, n_timer;
    logic        w_mode;
    logic [14:0] n_lfsr;

    always_comb begin
        w_period = period;
        w_mode   = mode;
        if (wr && wreg == 2'd2) begin
            w_mode   = wdata[7];
            w_period = period_of(wdata[3:0]);
        end
        n_lfsr = lfsr;
        if (timer == '0) begin
            n_timer = w_period;
            n_lfsr  = {lfsr[0] ^ (w_mode ? lfsr[6] : lfsr[1]), lfsr[14:1]};
        end else
            n_timer = timer - 12'd1;
    end

    always_ff @(posedge clk)
        if (rst) begin
            lfsr   <= 15'd1;
            mode   <= 1'b0;
            period <= '0;
            timer  <= '0;
        end else if (st_we) begin
            if (st_addr == 2'd0)
                {lfsr, mode, period} <= st_wdata[31:4];
            if (st_addr == 2'd1)
                timer <= st_wdata[31:20];
        end else if (ce) begin
            lfsr   <= n_lfsr;
            mode   <= w_mode;
            period <= w_period;
            timer  <= n_timer;
        end
endmodule
