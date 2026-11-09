// SPDX-License-Identifier: Apache-2.0
// MOS 6532 RIOT: 128 bytes of RAM, two 8-bit I/O ports and an interval timer, as the Atari 2600 uses it.
//
// One CPU cycle per `ce`. The cycle's access (`cs`, `rs_n`, `addr`, `we`, `din`) is taken on the edge
// with `ce` high, and so are a read's side effects (reading the timer clears its flag; reading the
// interrupt flags clears PA7's). `dout` is registered: valid the clock after the address, for whatever
// is selected then, so it must be steady for a clock before the CPU takes it.
//
// The timer, cycle by cycle: a write sets the count and restarts the prescaler, so the count drops on
// the next cycle and then every 1, 8, 64 or 1024 cycles. Dropping below 0 gives $FF and sets the timer
// flag, and while the flag is set the count drops every cycle. Reading the timer or writing it clears
// the flag, except on the cycle the count wraps. The prescaler keeps its phase when the flag clears.
//
// Registers (rs_n = 1), by address bits:
//   A2 = 0:          A1-A0: 0 port A, 1 port A's direction, 2 port B, 3 port B's direction
//   A2 = 1, read:    A0 = 0 the timer (A3 enables its interrupt), A0 = 1 the interrupt flags
//                    (bit 7 the timer's, bit 6 PA7's)
//   A2 = 1, write:   A4 = 1 the timer, A1-A0 its interval (1, 8, 64, 1024 cycles), A3 enables its
//                    interrupt; A4 = 0 PA7's edge detect, A0 = 1 rising edge (else falling), A1 enables
//                    its interrupt
// Port A reads its pins (`pa_in`, which the system drives as the pins stand); port B reads its output
// register for output bits and `pb_in` for input bits.

module riot_6532 #(
    parameter bit SAVE_STATE = 1'b1  // 0 leaves out the save-state port's logic
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,

    input  logic        cs,      // the chip is selected this cycle
    input  logic        rs_n,    // 0: RAM, 1: registers
    input  logic [6:0]  addr,
    input  logic        we,
    input  logic [7:0]  din,
    output logic [7:0]  dout,

    input  logic [7:0]  pa_in,
    output logic [7:0]  pa_out,
    output logic [7:0]  pa_ddr,  // 1: output
    input  logic [7:0]  pb_in,
    output logic [7:0]  pb_out,
    output logic [7:0]  pb_ddr,
    output logic        irq_n,

    input  logic [5:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);

    // ---- State ----
    logic [31:0] ram[32];            // 4 bytes a word, byte 0 in bits 7-0
    logic [7:0]  timer;
    logic [9:0]  pre;                // the prescaler, counting up to the interval minus 1
    logic [1:0]  ival;               // 1, 8, 64 or 1024 cycles
    logic        flag_t, flag_pa7;
    logic        edge_pos, pa7_ie, t_ie;
    logic        pa7_prev;
    logic [7:0]  ora, ddra, orb, ddrb;

    function automatic logic [9:0] ival_last(input logic [1:0] sel);
        case (sel)
            2'd0: ival_last = 10'd0;
            2'd1: ival_last = 10'd7;
            2'd2: ival_last = 10'd63;
            default: ival_last = 10'd1023;
        endcase
    endfunction

    // ---- This cycle's timer, before its access ----
    wire        pre_wrap = pre == ival_last(ival);
    wire  [9:0] pre_v    = pre_wrap ? 10'd0 : pre + 10'd1;
    wire        tick     = flag_t || pre_wrap;
    wire        wrap     = tick && timer == 8'd0;
    wire  [7:0] timer_v  = tick ? timer - 8'd1 : timer;
    wire        flag_t_v = flag_t || wrap;
    wire        pa7_edge = edge_pos ? (!pa7_prev && pa_in[7]) : (pa7_prev && !pa_in[7]);

    // ---- Decode ----
    wire reg_acc   = cs && rs_n;
    wire io_sel    = reg_acc && !addr[2];
    wire rd_timer  = reg_acc && !we && addr[2] && !addr[0];
    wire rd_flags  = reg_acc && !we && addr[2] && addr[0];
    wire wr_timer  = reg_acc && we && addr[2] && addr[4];
    wire wr_edge   = reg_acc && we && addr[2] && !addr[4];

    logic [7:0] reg_rdata;
    always_comb begin
        if (!addr[2])
            case (addr[1:0])
                2'd0: reg_rdata = pa_in;
                2'd1: reg_rdata = ddra;
                2'd2: reg_rdata = (orb & ddrb) | (pb_in & ~ddrb);
                default: reg_rdata = ddrb;
            endcase
        else if (!addr[0])
            reg_rdata = timer_v;
        else
            reg_rdata = {flag_t_v, flag_pa7, 6'd0};
    end

    // ---- Bus read: registered ----
    logic [31:0] ram_q;
    logic [1:0]  byte_q;
    logic        rs_q;
    logic [7:0]  reg_q;
    always_ff @(posedge clk) begin
        ram_q  <= ram[addr[6:2]];
        byte_q <= addr[1:0];
        rs_q   <= rs_n;
        reg_q  <= reg_rdata;
    end
    assign dout = rs_q ? reg_q : ram_q[8*byte_q +: 8];

    // ---- RAM ----
    always_ff @(posedge clk) begin
        if (ce && cs && !rs_n && we) begin
            logic [31:0] wv;
            wv = ram[addr[6:2]];
            wv[8*addr[1:0] +: 8] = din;
            ram[addr[6:2]] <= wv;
        end else if (SAVE_STATE && st_we && st_addr < 6'd32)
            ram[st_addr[4:0]] <= st_wdata;
    end

    // ---- Registers, timer and flags ----
    always_ff @(posedge clk) begin
        if (rst) begin
            timer    <= 8'd0;
            pre      <= 10'd0;
            ival     <= 2'd3;
            flag_t   <= 1'b0;
            flag_pa7 <= 1'b0;
            edge_pos <= 1'b0;
            pa7_ie   <= 1'b0;
            t_ie     <= 1'b0;
            pa7_prev <= 1'b0;
            ora      <= 8'd0;
            ddra     <= 8'd0;
            orb      <= 8'd0;
            ddrb     <= 8'd0;
        end else if (ce) begin
            timer    <= timer_v;
            pre      <= pre_v;
            flag_t   <= flag_t_v;
            pa7_prev <= pa_in[7];
            if (pa7_edge)
                flag_pa7 <= 1'b1;
            else if (rd_flags)
                flag_pa7 <= 1'b0;
            if (wr_timer) begin
                timer <= din;
                ival  <= addr[1:0];
                pre   <= ival_last(addr[1:0]);
                t_ie  <= addr[3];
                if (!wrap) flag_t <= 1'b0;
            end
            if (rd_timer) begin
                t_ie <= addr[3];
                if (!wrap) flag_t <= 1'b0;
            end
            if (wr_edge) begin
                edge_pos <= addr[0];
                pa7_ie   <= addr[1];
            end
            if (io_sel && we)
                case (addr[1:0])
                    2'd0: ora  <= din;
                    2'd1: ddra <= din;
                    2'd2: orb  <= din;
                    default: ddrb <= din;
                endcase
        end else if (SAVE_STATE && st_we) begin
            if (st_addr == 6'd32)
                {pa7_prev, t_ie, pa7_ie, edge_pos, flag_pa7, flag_t, ival, pre, timer} <= st_wdata[25:0];
            else if (st_addr == 6'd33)
                {ddrb, orb, ddra, ora} <= st_wdata;
        end
    end

    // ---- Save-state reads ----
    if (SAVE_STATE) begin : g_st
        always_ff @(posedge clk) begin
            if (st_addr < 6'd32)
                st_rdata <= ram[st_addr[4:0]];
            else if (st_addr == 6'd32)
                st_rdata <= {6'd0, pa7_prev, t_ie, pa7_ie, edge_pos, flag_pa7, flag_t, ival, pre, timer};
            else if (st_addr == 6'd33)
                st_rdata <= {ddrb, orb, ddra, ora};
            else
                st_rdata <= '0;
        end
    end else begin : g_no_st
        assign st_rdata = '0;
    end

    assign pa_out = ora;
    assign pa_ddr = ddra;
    assign pb_out = orb;
    assign pb_ddr = ddrb;
    assign irq_n  = !((flag_t && t_ie) || (flag_pa7 && pa7_ie));

endmodule
