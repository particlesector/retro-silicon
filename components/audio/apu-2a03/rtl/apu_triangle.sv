// SPDX-License-Identifier: Apache-2.0
// The 2A03's triangle channel: a 32-step sequencer (15 down to 0, then up to
// 15) stepped by an 11-bit timer every t + 1 CPU cycles while both its
// linear counter and its length counter are nonzero. Its output is the
// sequencer's value whether or not it steps, ultrasonic periods included, as
// on the 2A03. One CPU cycle per `ce`, the cycle's writes before its tick.
module apu_triangle (
    input  logic       clk,
    input  logic       rst,
    input  logic       ce,
    input  logic       wr,       // a write to $4008-$400B this cycle
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
    logic [10:0] period, timer;
    logic [4:0]  pos;
    logic [6:0]  lin, lin_load;
    logic        lin_reload, control;

    logic        len_active, len_next;
    logic [26:0] len_st;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        halt;  // the triangle has no envelope to loop
    /* verilator lint_on UNUSEDSIGNAL */

    // The control flag is also the length counter's halt.
    apu_length u_len (
        .clk, .rst, .ce,
        .wr_halt(wr && wreg == 2'd0), .halt_val(wdata[7]),
        .wr_load(wr && wreg == 2'd3), .load_idx(wdata[7:3]),
        .wr_en, .en_val, .half, .active(len_active), .active_next(len_next), .halt,
        .st(len_st), .st_we(st_we && st_addr == 2'd2), .st_wdata(st_wdata[26:0]));

    assign active   = len_active;
    assign out      = pos[4] ? pos[3:0] : ~pos[3:0];
    always_comb
        case (st_addr)
            2'd0:    st_rdata = {period, timer, pos, lin_reload, control, 3'b0};
            2'd1:    st_rdata = {lin, lin_load, 18'b0};
            default: st_rdata = {5'b0, len_st};
        endcase

    logic [10:0] w_period, n_timer;
    logic [6:0]  w_lin_load, n_lin;
    logic        w_lin_reload, w_control, n_lin_reload;
    logic [4:0]  n_pos;

    always_comb begin
        w_period     = period;
        w_lin_load   = lin_load;
        w_lin_reload = lin_reload;
        w_control    = control;
        if (wr)
            case (wreg)
                2'd0: {w_control, w_lin_load} = wdata;
                2'd2: w_period = {period[10:8], wdata};
                2'd3: begin
                    w_period     = {wdata[2:0], period[7:0]};
                    w_lin_reload = 1'b1;
                end
                default: ;
            endcase
        n_lin        = lin;
        n_lin_reload = w_lin_reload;
        if (quarter) begin
            if (w_lin_reload)
                n_lin = w_lin_load;
            else if (lin != '0)
                n_lin = lin - 7'd1;
            if (!w_control)
                n_lin_reload = 1'b0;
        end
        // The sequencer steps with the length and linear counters as they
        // stand after this tick's clocks, as in MesenCE.
        n_pos = pos;
        if (timer == '0) begin
            n_timer = w_period;
            if (len_next && n_lin != '0)
                n_pos = pos + 5'd1;
        end else
            n_timer = timer - 11'd1;
    end

    always_ff @(posedge clk)
        if (rst)
            {period, timer, pos, lin, lin_load, lin_reload, control} <= '0;
        else if (st_we) begin
            if (st_addr == 2'd0)
                {period, timer, pos, lin_reload, control} <= st_wdata[31:3];
            if (st_addr == 2'd1)
                {lin, lin_load} <= st_wdata[31:18];
        end else if (ce) begin
            period     <= w_period;
            timer      <= n_timer;
            pos        <= n_pos;
            lin        <= n_lin;
            lin_load   <= w_lin_load;
            lin_reload <= n_lin_reload;
            control    <= w_control;
        end
endmodule
