// SPDX-License-Identifier: Apache-2.0
// A read cache for memory/sdram's byte port, in front of a memory that reads
// whole 8-byte lines (memory/axi-bridge's d_rdata): for memory far slower to
// answer than a system's cycle, such as DDR behind a processor.
//
// Direct-mapped, 2^IDX lines of 8 bytes, in block RAM: eight byte-wide data
// memories, the tags in byte-wide memories, the valid bits in a one-bit one
// (nothing wider than 8 bits, which every toolchain maps without parity
// bits). A read that hits answers in three clocks; one that misses reads its
// line from the memory, fills it and answers with it. A write goes through to
// the memory and updates the line if it holds the address, so the cache never
// holds stale data. After reset `ready` stays low while the valid bits are
// cleared, 2^IDX clocks, and until the memory is ready.
//
// With PREFETCH, a miss on line L, or the first read of the line the last
// prefetch brought, also fetches line L+1 if it isn't cached, in the
// background, as code runs on in order: it lands in a one-line buffer
// and goes into the cache on a clock the user leaves free. Reads that hit (the
// buffer included) are answered meanwhile; a read that misses, or a write,
// waits for it (the memory takes one access at a time).
module mem_cache #(
    parameter int AW       = 23,   // byte address width
    parameter int IDX      = 12,   // 2^IDX lines: 32 KB
    parameter bit PREFETCH = 1'b1  // fetch the next line after a miss
) (
    input  logic          clk,
    input  logic          rst,

    // The user's byte port.
    input  logic          req,
    input  logic          we,
    input  logic [AW-1:0] addr,
    input  logic [7:0]    wdata,
    output logic          ack,
    output logic [7:0]    rdata,
    output logic [31:0]   rdata_w,   // the 32-bit half of the line the byte is in
    output logic          ready,

    // The memory: a byte port whose reads give the whole line.
    output logic          d_req,
    output logic          d_we,
    output logic [AW-1:0] d_addr,
    output logic [7:0]    d_wdata,
    input  logic          d_ack,
    input  logic [63:0]   d_rdata,   // the 8-byte line a read's address is in
    input  logic          d_ready,

    output logic [31:0]   hits,       // reads answered from the cache (or the prefetch buffer), since reset
    output logic [31:0]   misses,     // reads that went to the memory
    output logic [31:0]   prefetches  // lines prefetched
);
    localparam int LW = AW - 3;         // line address bits
    localparam int TW = AW - 3 - IDX;   // tag bits
    localparam int TB = (TW + 7) / 8;   // tag bytes

    typedef enum logic [3:0] {S_CLEAR, S_IDLE, S_READ, S_LOOK, S_PWAIT, S_FILL, S_WRITE, S_PREAD, S_PLOOK} state_t;

    state_t          st;
    logic [AW-1:0]   a;        // the user's access being served
    logic            a_we;
    logic [7:0]      a_wdata;
    logic [IDX-1:0]  clr;      // the valid bit being cleared after reset

    // The prefetch: the line wanted, the one in flight, and the buffer.
    logic            pf_want, pf_pend, pf_full;
    logic [LW-1:0]   pf_line, buf_line;
    logic [63:0]     buf_data;
    logic            own_pf;   // the memory's access in flight is the prefetch's
    logic            lp_valid; // the last line prefetched, until a read first uses it
    logic [LW-1:0]   lp_line;

    wire  [LW-1:0]   a_line = a[AW-1:3];

    // A line's tag, padded to the tag memories' bytes (its index bits aren't used).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [TB*8-1:0] tag_of(input logic [LW-1:0] line);
        tag_of = {{(TB * 8 - TW){1'b0}}, line[LW-1:IDX]};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- The memories ----
    logic [7:0]      dq[8];
    logic [TB*8-1:0] tq;
    logic            vq;
    logic            line_we, tag_we;
    logic [7:0]      line_wd[8];
    logic [7:0]      line_wmask;
    logic [IDX-1:0]  m_idx;
    logic [LW-1:0]   m_line;   // the line written, for its tag

    // The buffer goes in on a clock the user leaves free.
    wire take    = req && !ack && ready && st == S_IDLE;
    wire buf_put = pf_full && st == S_IDLE && !take;

    always_comb begin
        m_line     = a_line;
        line_we    = 1'b0;
        tag_we     = 1'b0;
        line_wmask = '0;
        for (int i = 0; i < 8; i++)
            line_wd[i] = d_rdata[8*i +: 8];
        if (st == S_PREAD || st == S_PLOOK)
            m_line = pf_line;
        if (buf_put) begin
            m_line     = buf_line;
            line_we    = 1'b1;
            tag_we     = 1'b1;
            line_wmask = '1;
            for (int i = 0; i < 8; i++)
                line_wd[i] = buf_data[8*i +: 8];
        end
        if (st == S_FILL && d_ack && !own_pf) begin
            line_we    = 1'b1;
            tag_we     = 1'b1;
            line_wmask = '1;
        end
        if (st == S_WRITE && d_ack && !own_pf && vq && tq == tag_of(a_line)) begin
            line_we          = 1'b1;
            line_wmask       = 8'b1 << a[2:0];
            line_wd[a[2:0]]  = a_wdata;
        end
        m_idx = st == S_CLEAR ? clr : m_line[IDX-1:0];
    end

    for (genvar i = 0; i < 8; i++) begin : g_data
        logic [7:0] mem[2**IDX];
        always_ff @(posedge clk) begin
            if (line_we && line_wmask[i])
                mem[m_idx] <= line_wd[i];
            dq[i] <= mem[m_idx];
        end
    end

    for (genvar i = 0; i < TB; i++) begin : g_tag
        logic [7:0]      mem[2**IDX];
        wire  [TB*8-1:0] t = tag_of(m_line);
        always_ff @(posedge clk) begin
            if (tag_we)
                mem[m_idx] <= t[8*i +: 8];
            tq[8*i +: 8] <= mem[m_idx];
        end
    end

    // The valid bits: cleared after reset, set by a fill.
    logic vmem[2**IDX];
    always_ff @(posedge clk) begin
        if (st == S_CLEAR || tag_we)
            vmem[m_idx] <= st != S_CLEAR;
        vq <= vmem[m_idx];
    end

    // ---- Control ----
    wire hit_mem = vq && tq == tag_of(a_line);
    wire hit_buf = pf_full && buf_line == a_line;
    wire pf_ack  = d_ack && own_pf;

    assign d_we    = !own_pf && a_we;
    assign d_wdata = a_wdata;
    assign d_addr  = own_pf ? {pf_line, 3'b000} : {a_line, a_we ? a[2:0] : 3'b000};

    logic [63:0] dline;
    always_comb
        for (int i = 0; i < 8; i++)
            dline[8*i +: 8] = dq[i];

    always_ff @(posedge clk) begin
        ack <= 1'b0;
        if (buf_put)
            pf_full <= 1'b0;
        // The prefetch lands in the buffer.
        if (pf_ack) begin
            d_req    <= 1'b0;
            own_pf   <= 1'b0;
            pf_pend  <= 1'b0;
            pf_full  <= 1'b1;
            buf_line <= pf_line;
            buf_data <= d_rdata;
            lp_valid <= 1'b1;
            lp_line  <= pf_line;
        end
        case (st)
            S_CLEAR: begin
                clr <= clr + 1'b1;
                if (clr == '1)
                    st <= S_IDLE;
            end
            S_IDLE:
                if (take) begin
                    a       <= addr;
                    a_we    <= we;
                    a_wdata <= wdata;
                    st      <= we ? S_WRITE : S_READ;
                end else if (PREFETCH && pf_want && !pf_pend && !pf_full)
                    st <= S_PREAD;
            S_READ:          // the memories read the line's index
                st <= S_LOOK;
            S_LOOK: begin
                // The first read of a prefetched line: the next one, so code streams;
                // not while a prefetch is out, whose address must hold (a later read asks).
                if (PREFETCH && lp_valid && a_line == lp_line && !pf_pend && (hit_buf || hit_mem)) begin
                    lp_valid <= 1'b0;
                    pf_want  <= 1'b1;
                    pf_line  <= a_line + 1'b1;
                end
                if (hit_buf) begin
                    rdata   <= buf_data[8*a[2:0] +: 8];
                    rdata_w <= a[2] ? buf_data[63:32] : buf_data[31:0];
                    ack     <= 1'b1;
                    hits <= hits + 1'b1;
                    st   <= S_IDLE;
                end else if (hit_mem) begin
                    rdata   <= dline[8*a[2:0] +: 8];
                    rdata_w <= a[2] ? dline[63:32] : dline[31:0];
                    ack     <= 1'b1;
                    hits <= hits + 1'b1;
                    st   <= S_IDLE;
                end else begin
                    misses <= misses + 1'b1;
                    st     <= S_PWAIT;
                end
            end
            S_PWAIT:         // a miss: once the prefetch is in, from it or from the memory
                if (!pf_pend && !pf_ack) begin
                    if (hit_buf) begin
                        rdata   <= buf_data[8*a[2:0] +: 8];
                    rdata_w <= a[2] ? buf_data[63:32] : buf_data[31:0];
                    ack     <= 1'b1;
                        st <= S_IDLE;
                    end else begin
                        d_req <= 1'b1;
                        st    <= S_FILL;
                    end
                end
            S_FILL:
                if (d_ack && !own_pf) begin
                    d_req <= 1'b0;
                    rdata   <= d_rdata[8*a[2:0] +: 8];
                    rdata_w <= a[2] ? d_rdata[63:32] : d_rdata[31:0];
                    ack     <= 1'b1;
                    st    <= S_IDLE;
                    if (PREFETCH) begin
                        pf_want <= 1'b1;
                        pf_line <= a_line + 1'b1;
                    end
                end
            S_WRITE:         // through to the memory, once the prefetch is in; the line was read meanwhile
                if (!d_req && !pf_pend && !pf_ack)
                    d_req <= 1'b1;
                else if (d_req && d_ack && !own_pf) begin
                    d_req <= 1'b0;
                    ack   <= 1'b1;
                    if (hit_buf)
                        buf_data[8*a[2:0] +: 8] <= a_wdata;
                    st    <= S_IDLE;
                end
            S_PREAD:         // the memories read the next line's index
                st <= S_PLOOK;
            S_PLOOK: begin   // fetch it unless it's here
                pf_want <= 1'b0;
                if (!(vq && tq == tag_of(pf_line))) begin
                    d_req      <= 1'b1;
                    own_pf     <= 1'b1;
                    pf_pend    <= 1'b1;
                    prefetches <= prefetches + 1'b1;
                end
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
        if (rst) begin
            st         <= S_CLEAR;
            clr        <= '0;
            d_req      <= 1'b0;
            own_pf     <= 1'b0;
            ack        <= 1'b0;
            pf_want    <= 1'b0;
            pf_pend    <= 1'b0;
            pf_full    <= 1'b0;
            lp_valid   <= 1'b0;
            hits       <= '0;
            misses     <= '0;
            prefetches <= '0;
        end
    end

    assign ready = st != S_CLEAR && d_ready;
endmodule
