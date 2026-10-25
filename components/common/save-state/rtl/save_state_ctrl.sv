// SPDX-License-Identifier: Apache-2.0
// Saves a system's whole state into a block-RAM buffer, and loads it back, by
// walking a list of byte regions on the system's own bus: the regions where
// it maps its components' save-state ports and its memories.
//
// A command runs when `cmd` changes to a value whose op is save (1) or load
// (2); `done` then takes cmd's value once it's finished. Sending the same
// command again does nothing, which keeps it safe for a host to repeat.
//
// While a command runs, `hold` asks the system to stop: a save at its next
// frame boundary (or where it already stands, if it's stopped), a load at
// once. The walk starts once `ready` says it has. On the bus, as on the test
// shell's: hold b_req (with b_addr, b_we, b_wdata) until b_ack, which marks
// b_rdata valid on a read; b_req may still be high while b_ack is.
//
// The host side reads and writes the buffer while no command runs: h_rdata is
// registered, valid the clock after h_addr.
module save_state_ctrl #(
    parameter int                 NREG  = 1,
    parameter logic [NREG*32-1:0] BASES = '0,   // region r's first byte in bits [r*32 +: 32]
    parameter logic [NREG*32-1:0] LENS  = '0,   // and its length in bytes
    parameter int                 AW    = 15    // buffer: 2^AW bytes, at least the regions' total
) (
    input  logic          clk,
    input  logic          rst,

    input  logic [7:0]    cmd,         // {op, sequence}: op in bits 7:6
    output logic [7:0]    done,        // the last command finished
    output logic          busy,

    output logic          hold,        // stop the system: busy, with
    output logic          hold_frame,  //   at a frame boundary (a save)
    input  logic          ready,       // the system has stopped as asked

    output logic          b_req,
    output logic          b_we,
    output logic [31:0]   b_addr,
    output logic [7:0]    b_wdata,
    input  logic          b_ack,
    input  logic [7:0]    b_rdata,

    input  logic [AW-1:0] h_addr,
    input  logic          h_we,
    input  logic [7:0]    h_wdata,
    output logic [7:0]    h_rdata
);
    localparam int RW = NREG > 1 ? $clog2(NREG) : 1;

    localparam logic [1:0] OP_SAVE = 2'd1;
    localparam logic [1:0] OP_LOAD = 2'd2;

    typedef enum logic [2:0] {S_IDLE, S_WAIT, S_FETCH, S_BUS, S_NEXT} state_t;

    state_t      st;
    logic [7:0]  cur;      // the command running
    logic        is_load;
    logic [RW-1:0] r;      // region
    logic [31:0] i;        // byte within it
    logic [AW-1:0] p;      // buffer position

    // ---- Buffer: the walk's while busy, the host's otherwise ----
    logic [7:0]    buf_mem[2**AW];
    logic [AW-1:0] ba;
    logic          bwe;
    logic [7:0]    bwd, bq;

    always_comb
        if (busy) begin
            ba  = p;
            bwe = st == S_BUS && b_ack && !is_load;
            bwd = b_rdata;
        end else begin
            ba  = h_addr;
            bwe = h_we;
            bwd = h_wdata;
        end

    always_ff @(posedge clk) begin
        if (bwe)
            buf_mem[ba] <= bwd;
        bq <= buf_mem[ba];
    end

    assign h_rdata = bq;

    // ---- The walk ----
    wire [31:0] base = BASES[r*32 +: 32];
    wire [31:0] len  = LENS[r*32 +: 32];

    assign busy       = st != S_IDLE;
    assign hold       = busy;
    assign hold_frame = !is_load;
    assign b_req      = st == S_BUS;
    assign b_we       = is_load;
    assign b_addr     = base + i;

    always_ff @(posedge clk) begin
        case (st)
            S_IDLE:
                if (cmd != done && (cmd[7:6] == OP_SAVE || cmd[7:6] == OP_LOAD)) begin
                    st      <= S_WAIT;
                    cur     <= cmd;
                    is_load <= cmd[7:6] == OP_LOAD;
                    r       <= '0;
                    i       <= '0;
                    p       <= '0;
                end else
                    done <= cmd;  // anything else is acknowledged as it is
            S_WAIT:
                if (ready)
                    st <= is_load ? S_FETCH : S_BUS;
            S_FETCH:  // the buffer read of p lands in bq
                st <= S_BUS;
            S_BUS:
                if (b_ack)
                    st <= S_NEXT;
            default: begin  // S_NEXT: the bus has seen b_req drop for a clock
                p <= p + 1'b1;
                if (i + 1 == len) begin
                    i <= '0;
                    if (r == RW'(NREG - 1)) begin
                        st   <= S_IDLE;
                        done <= cur;
                    end else begin
                        r  <= r + 1'b1;
                        st <= is_load ? S_FETCH : S_BUS;
                    end
                end else begin
                    i  <= i + 1;
                    st <= is_load ? S_FETCH : S_BUS;
                end
            end
        endcase
        if (rst) begin
            st   <= S_IDLE;
            done <= '0;
        end
    end

    // A load writes the byte fetched; bq holds it until p moves.
    assign b_wdata = bq;
endmodule
