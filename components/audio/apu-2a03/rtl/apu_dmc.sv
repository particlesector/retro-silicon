// SPDX-License-Identifier: Apache-2.0
// The 2A03's delta modulation channel (NTSC): a 7-bit output level that a
// timer steps up or down by 2 for each bit of a sample, read a byte at a
// time from memory by DMA ($C000 + 64A, 16L + 1 bytes), with loop and IRQ.
// One CPU cycle per `ce`, the cycle's writes before its tick.
//
// The DMA itself is the system's (it halts the CPU): dma_req asks for a
// byte at dma_addr, dma_cancel withdraws the request, and dma_done hands the
// byte back in the cycle the DMA reads it. Starting and stopping the
// channel through $4015 take effect 2 or 3 cycles later, by the parity of
// the write's cycle, as on the 2A03 and in MesenCE; so does the corner case
// where a 1-byte sample's DMA ends just before the bit counter reloads.
// MesenCE's optional sample-duplication glitch (later CPU revisions) is off,
// as it is there by default.
module apu_dmc (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,
    input  logic        odd,       // this CPU cycle's count is odd
    input  logic        wr,        // a write to $4010-$4013 this cycle
    input  logic [1:0]  wreg,
    input  logic [7:0]  wdata,
    input  logic        wr_en,     // $4015 written
    input  logic        en_val,    // its bit 4
    input  logic        dma_done,  // the DMA read a byte this cycle
    input  logic [7:0]  dma_data,
    output logic        dma_req,   // with ce: start a DMA
    output logic        dma_cancel,// with ce: abort it, if it hasn't really started
    output logic [15:0] dma_addr,
    output logic        active,    // bytes remain ($4015 bit 4)
    output logic        irq,       // the DMC's IRQ ($4015 bit 7)
    output logic [6:0]  out,
    // Save state: 4 words
    input  logic [1:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    logic        irq_en, loop, buf_empty, silence;
    logic [8:0]  period, timer;     // the rate table's value - 1
    logic [6:0]  level;
    logic [7:0]  addr_reg, len_reg, rbuf, shift;
    logic [15:0] cur;
    logic [11:0] remain;
    logic [3:0]  bits;
    logic [1:0]  start_wait, stop_wait;

    function automatic logic [8:0] period_of(input logic [3:0] i);
        case (i)
            4'd0:  period_of = 9'd427; 4'd1:  period_of = 9'd379; 4'd2:  period_of = 9'd339; 4'd3:  period_of = 9'd319;
            4'd4:  period_of = 9'd285; 4'd5:  period_of = 9'd253; 4'd6:  period_of = 9'd225; 4'd7:  period_of = 9'd213;
            4'd8:  period_of = 9'd189; 4'd9:  period_of = 9'd159; 4'd10: period_of = 9'd141; 4'd11: period_of = 9'd127;
            4'd12: period_of = 9'd105; 4'd13: period_of = 9'd83;  4'd14: period_of = 9'd71;  default: period_of = 9'd53;
        endcase
    endfunction

    assign dma_addr = cur;
    assign active   = remain != '0;
    assign out      = level;

    always_comb
        case (st_addr)
            2'd0:    st_rdata = {3'b0, irq_en, loop, buf_empty, silence, irq, period, level, addr_reg};
            2'd1:    st_rdata = {len_reg, rbuf, shift, bits, start_wait, stop_wait};
            2'd2:    st_rdata = {cur, remain, 4'b0};
            default: st_rdata = {23'b0, timer};
        endcase

    // Writes (registers, $4015, the DMA's byte), then the tick.
    logic        w_irq_en, w_loop, w_irq, w_buf_empty, w_silence;
    logic [8:0]  w_period, n_timer;
    logic [6:0]  w_level, n_level;
    logic [7:0]  w_addr_reg, w_len_reg, w_rbuf, w_shift, n_shift;
    logic [15:0] w_cur, n_cur;
    logic [11:0] w_remain, n_remain;
    logic [3:0]  n_bits;
    logic [1:0]  w_start_wait, w_stop_wait, n_start_wait, n_stop_wait;
    logic        n_buf_empty, n_silence, req, cancel;

    always_comb begin
        w_irq_en     = irq_en;
        w_loop       = loop;
        w_irq        = irq;
        w_period     = period;
        w_level      = level;
        w_addr_reg   = addr_reg;
        w_len_reg    = len_reg;
        w_cur        = cur;
        w_remain     = remain;
        w_rbuf       = rbuf;
        w_buf_empty  = buf_empty;
        w_shift      = shift;
        w_silence    = silence;
        w_start_wait = start_wait;
        w_stop_wait  = stop_wait;
        if (wr)
            case (wreg)
                2'd0: begin
                    w_irq_en = wdata[7];
                    w_loop   = wdata[6];
                    w_period = period_of(wdata[3:0]);
                    if (!wdata[7])
                        w_irq = 1'b0;
                end
                2'd1: w_level = wdata[6:0];
                2'd2: w_addr_reg = wdata;
                default: w_len_reg = wdata;
            endcase
        if (wr_en) begin
            w_irq = 1'b0;
            if (!en_val) begin
                if (stop_wait == '0)
                    w_stop_wait = odd ? 2'd3 : 2'd2;
            end else if (remain == '0) begin
                w_cur        = {2'b11, addr_reg, 6'b0};
                w_remain     = {len_reg, 4'b0001};
                w_start_wait = odd ? 2'd3 : 2'd2;
            end
        end
        if (dma_done) begin
            if (remain != '0) begin
                w_rbuf      = dma_data;
                w_buf_empty = 1'b0;
                w_cur       = cur == 16'hFFFF ? 16'h8000 : cur + 16'd1;
                w_remain    = remain - 12'd1;
                if (remain == 12'd1) begin
                    if (loop) begin
                        w_cur    = {2'b11, addr_reg, 6'b0};
                        w_remain = {len_reg, 4'b0001};
                    end else if (irq_en)
                        w_irq = 1'b1;
                end
            end
            // A 1-byte sample whose DMA ends the APU cycle before the bit
            // counter reloads: the byte goes straight to the shifter and the
            // sample restarts, then stops 3 cycles later.
            if (len_reg == '0 && !loop && bits == 4'd1 && timer < 9'd2) begin
                w_shift      = w_rbuf;
                w_buf_empty  = 1'b0;
                w_cur        = {2'b11, addr_reg, 6'b0};
                w_remain     = {len_reg, 4'b0001};
                w_stop_wait  = 2'd3;
            end
        end

        // The tick: the $4015 waits first, then the timer.
        req          = 1'b0;
        cancel       = 1'b0;
        n_cur        = w_cur;
        n_remain     = w_remain;
        n_stop_wait  = w_stop_wait;
        n_start_wait = w_start_wait;
        if (w_stop_wait != '0) begin
            n_stop_wait = w_stop_wait - 2'd1;
            if (n_stop_wait == '0) begin
                n_remain = '0;
                cancel   = 1'b1;
            end
        end
        if (w_start_wait != '0) begin
            n_start_wait = w_start_wait - 2'd1;
            if (n_start_wait == '0 && w_buf_empty && n_remain != '0)
                req = 1'b1;
        end
        n_level     = w_level;
        n_shift     = w_shift;
        n_bits      = bits;
        n_buf_empty = w_buf_empty;
        n_silence   = w_silence;
        if (timer == '0) begin
            n_timer = w_period;
            if (!w_silence) begin
                if (w_shift[0]) begin
                    if (w_level <= 7'd125)
                        n_level = w_level + 7'd2;
                end else if (w_level >= 7'd2)
                    n_level = w_level - 7'd2;
                n_shift = {1'b0, w_shift[7:1]};
            end
            n_bits = bits - 4'd1;
            if (n_bits == '0) begin
                n_bits = 4'd8;
                if (w_buf_empty)
                    n_silence = 1'b1;
                else begin
                    n_silence   = 1'b0;
                    n_shift     = w_rbuf;
                    n_buf_empty = 1'b1;
                    if (n_start_wait == '0 && n_remain != '0)
                        req = 1'b1;
                end
            end
        end else
            n_timer = timer - 9'd1;
    end

    always_ff @(posedge clk) begin
        dma_req    <= 1'b0;
        dma_cancel <= 1'b0;
        if (rst) begin
            {irq_en, loop, irq, level, addr_reg, len_reg, cur, remain, rbuf, shift, start_wait, stop_wait} <= '0;
            buf_empty <= 1'b1;
            silence   <= 1'b1;
            bits      <= 4'd8;
            period    <= 9'd427;
            timer     <= 9'd427;  // so it doesn't step on its first cycle, as in MesenCE
        end else if (st_we) begin
            case (st_addr)
                2'd0:    {irq_en, loop, buf_empty, silence, irq, period, level, addr_reg} <= st_wdata[28:0];
                2'd1:    {len_reg, rbuf, shift, bits, start_wait, stop_wait} <= st_wdata;
                2'd2:    {cur, remain} <= st_wdata[31:4];
                default: timer <= st_wdata[8:0];
            endcase
        end else if (ce) begin
            irq_en     <= w_irq_en;
            loop       <= w_loop;
            irq        <= w_irq;
            period     <= w_period;
            timer      <= n_timer;
            level      <= n_level;
            addr_reg   <= w_addr_reg;
            len_reg    <= w_len_reg;
            cur        <= n_cur;
            remain     <= n_remain;
            rbuf       <= w_rbuf;
            buf_empty  <= n_buf_empty;
            shift      <= n_shift;
            bits       <= n_bits;
            silence    <= n_silence;
            start_wait <= n_start_wait;
            stop_wait  <= n_stop_wait;
            dma_req    <= req;
            dma_cancel <= cancel;
        end
    end
endmodule
