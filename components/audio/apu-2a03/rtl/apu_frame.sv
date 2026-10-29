// SPDX-License-Identifier: Apache-2.0
// The 2A03's frame counter (NTSC): quarter- and half-frame clocks for the
// envelopes, linear counter, length counters and sweeps, and the frame IRQ.
// One CPU cycle per `ce`, the cycle's writes before its tick.
//
// It counts CPU cycles from the start of its sequence and acts at these
// counts, as the 2A03 does and MesenCE models it:
//   4-step mode: 7457 quarter, 14913 half, 22371 quarter, 29828 IRQ,
//                29829 half and IRQ, 29830 IRQ, then from 0 again;
//   5-step mode: 7457 quarter, 14913 half, 22371 quarter, 29829 nothing,
//                37281 half, 37282, then from 0 again.
// A $4017 write takes effect 3 CPU cycles later if it lands on an even
// cycle (`odd` low), 4 if odd, restarting the sequence, and in 5-step mode
// clocking a half frame at once. For 2 cycles after any clock, a $4017
// write can't clock another. Its interrupt-inhibit bit acts at once,
// clearing the flag. Reading $4015 clears the IRQ line at once and the flag
// at the start of the next APU cycle (2 CPU cycles). After reset the counter
// acts as if $4017 had been written with 0, 3 cycles before.
module apu_frame (
    input  logic       clk,
    input  logic       rst,
    input  logic       ce,
    input  logic       odd,       // this CPU cycle's count is odd
    input  logic       wr,        // $4017 written this cycle
    input  logic [1:0] wdata,     // {mode, inhibit}: bits 7 and 6
    input  logic       rd_status, // $4015 read this cycle
    output logic       quarter,   // clocks this cycle's tick (with ce)
    output logic       half,
    output logic       irq_flag,  // $4015 bit 6
    output logic       irq,       // the frame IRQ to the CPU
    // Save state: {count, step, mode, inhibit, flag, line, clear wait, pending, pending mode, delay, block}
    output logic [31:0] st,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    logic [15:0] count;
    logic [2:0]  step, delay;
    logic [1:0]  clr, block;
    logic        mode, inhibit, line, pend, pend_mode;

    assign irq = line;
    assign st  = {count, step, mode, inhibit, irq_flag, line, clr, pend, pend_mode, delay, block};

    function automatic logic [15:0] step_at(input logic m, input logic [2:0] s);
        case (s)
            3'd0:    step_at = 16'd7457;
            3'd1:    step_at = 16'd14913;
            3'd2:    step_at = 16'd22371;
            3'd3:    step_at = m ? 16'd29829 : 16'd29828;
            3'd4:    step_at = m ? 16'd37281 : 16'd29829;
            default: step_at = m ? 16'd37282 : 16'd29830;
        endcase
    endfunction

    // Writes, then the tick.
    logic        w_inhibit, w_flag, w_line, w_pend, w_pend_mode;
    logic [2:0]  w_delay;
    logic [1:0]  w_clr;
    logic [15:0] n_count;
    logic [2:0]  n_step, n_delay;
    logic [1:0]  n_clr, n_block;
    logic        n_mode, n_flag, n_line, n_pend, at;

    always_comb begin
        w_inhibit   = inhibit;
        w_flag      = irq_flag;
        w_line      = line;
        w_pend      = pend;
        w_pend_mode = pend_mode;
        w_delay     = delay;
        w_clr       = clr;
        if (rd_status) begin
            w_line = 1'b0;
            if (irq_flag && clr == '0)
                w_clr = odd ? 2'd2 : 2'd1;
        end
        if (wr) begin
            w_pend      = 1'b1;
            w_pend_mode = wdata[1];
            w_delay     = odd ? 3'd4 : 3'd3;
            w_inhibit   = wdata[0];
            if (wdata[0]) begin
                w_line = 1'b0;
                w_flag = 1'b0;
                w_clr  = '0;
            end
        end

        // The tick.
        quarter = 1'b0;
        half    = 1'b0;
        n_mode  = mode;
        n_step  = step;
        n_count = count + 16'd1;
        n_flag  = w_flag;
        n_line  = w_line;
        n_clr   = w_clr;
        n_pend  = w_pend;
        n_delay = w_delay;
        n_block = block;
        if (n_clr != '0) begin
            n_clr = n_clr - 2'd1;
            if (n_clr == '0)
                n_flag = 1'b0;
        end
        at = n_count >= step_at(mode, step);
        if (at) begin
            if (!mode && step >= 3'd3) begin
                n_flag = 1'b1;
                n_clr  = '0;
                if (!w_inhibit)
                    n_line = 1'b1;
                else if (step == 3'd5)
                    n_flag = 1'b0;
            end
            if ((step == 3'd0 || step == 3'd1 || step == 3'd2 || step == 3'd4) && block == '0) begin
                quarter = 1'b1;
                half    = step == 3'd1 || step == 3'd4;
                n_block = 2'd2;
            end
            if (step == 3'd5) begin
                n_step  = '0;
                n_count = '0;
            end else
                n_step = step + 3'd1;
        end
        if (w_pend) begin
            n_delay = w_delay - 3'd1;
            if (n_delay == '0) begin
                n_mode  = w_pend_mode;
                n_pend  = 1'b0;
                n_step  = '0;
                n_count = '0;
                if (w_pend_mode && n_block == '0) begin
                    quarter = 1'b1;
                    half    = 1'b1;
                    n_block = 2'd2;
                end
            end
        end
        if (n_block != '0)
            n_block = n_block - 2'd1;
    end

    always_ff @(posedge clk)
        if (rst) begin
            // As if $4017 were written with 0, 3 cycles before.
            {count, step, mode, inhibit, irq_flag, line, clr, block} <= '0;
            pend      <= 1'b1;
            pend_mode <= 1'b0;
            delay     <= 3'd3;
        end else if (st_we)
            {count, step, mode, inhibit, irq_flag, line, clr, pend, pend_mode, delay, block} <= st_wdata;
        else if (ce) begin
            count     <= n_count;
            step      <= n_step;
            mode      <= n_mode;
            inhibit   <= w_inhibit;
            irq_flag  <= n_flag;
            line      <= n_line;
            clr       <= n_clr;
            pend      <= n_pend;
            pend_mode <= w_pend_mode;
            delay     <= n_delay;
            block     <= n_block;
        end
endmodule
