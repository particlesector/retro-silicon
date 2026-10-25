// SPDX-License-Identifier: Apache-2.0
// Controller for a 2M x 32 SDR SDRAM (4 banks, 2048 rows, 256 columns), such as
// the 64 Mbit chip inside the Tang Nano 20K's GW2AR-18. The user side is a byte
// port: hold req (with addr, we, wdata) until ack, which also marks rdata valid
// on a read. Each access opens a row and closes it again with auto-precharge, so
// every access takes the same time unless a refresh is under way.
//
// The SDRAM's clock must be the inverse of clk (the board inverts it), so the
// chip samples commands half a cycle after they're registered and its read data
// is captured on the clk edge CAS_LATENCY + 1 cycles after the READ.
module sdram_ctrl #(
    parameter int FREQ_MHZ    = 27,   // clk frequency; sets the timings below in clocks
    parameter int CAS_LATENCY = 2,
    parameter int INIT_US     = 200,  // power-up wait before the first command
    parameter int REFRESH_NS  = 15_000 // one row refresh this often (4096 rows per 64 ms is 15,625)
) (
    input  logic        clk,
    input  logic        rst,          // synchronous; restarts the power-up sequence

    input  logic        req,
    input  logic        we,
    input  logic [22:0] addr,         // byte address: bank, row, column, byte lane
    input  logic [7:0]  wdata,
    output logic        ack,          // one-cycle pulse
    output logic [7:0]  rdata,
    output logic        ready,        // the power-up sequence is done

    output logic        sd_cke,
    output logic        sd_cs_n,
    output logic        sd_ras_n,
    output logic        sd_cas_n,
    output logic        sd_we_n,
    output logic [1:0]  sd_ba,
    output logic [10:0] sd_addr,
    output logic [3:0]  sd_dqm,
    output logic [31:0] sd_dq_o,
    output logic        sd_dq_oe,
    input  logic [31:0] sd_dq_i
);
    // Nanoseconds to clocks, rounded up.
    function automatic int clocks(input int ns);
        clocks = (ns * FREQ_MHZ + 999) / 1000;
    endfunction

    function automatic int at_least(input int n, input int lo);
        at_least = n < lo ? lo : n;
    endfunction

    // Timings for a -7 speed grade or faster, with some margin.
    localparam int T_RCD  = at_least(clocks(20), 1);  // ACTIVE to READ or WRITE
    localparam int T_RP   = at_least(clocks(20), 1);  // PRECHARGE to ACTIVE
    localparam int T_RC   = at_least(clocks(70), 2);  // ACTIVE to ACTIVE, and REFRESH to anything
    localparam int T_RAS  = at_least(clocks(50), 1);  // ACTIVE to PRECHARGE
    localparam int T_WR   = at_least(clocks(15), 2);  // last write data to PRECHARGE
    localparam int T_MRD  = 2;                        // MODE to anything
    localparam int T_INIT = INIT_US * FREQ_MHZ;
    localparam int T_REFI = REFRESH_NS * FREQ_MHZ / 1000;
    localparam int INIT_REFRESHES = 8;

    // Column commands auto-precharge, so they wait until the precharge (one
    // clock after a READ, tWR after a WRITE) can't come before tRAS is met. The
    // bank is ready for the next ACTIVE once tRC has passed and the precharge
    // has finished. The gaps are counted from the column command.
    localparam int T_RD_DLY  = at_least(T_RCD, T_RAS - 1);
    localparam int T_WR_DLY  = at_least(T_RCD, T_RAS - T_WR);
    localparam int READ_GAP  = at_least(T_RC - T_RD_DLY, 1 + T_RP);
    localparam int WRITE_GAP = at_least(T_RC - T_WR_DLY, T_WR + T_RP);

    // Mode register: burst length 1, sequential, CAS latency, single-location writes.
    localparam logic [10:0] MODE = {4'b0000, 3'(CAS_LATENCY), 4'b0000};

    // {cs_n, ras_n, cas_n, we_n}
    localparam logic [3:0] C_NOP       = 4'b0111;
    localparam logic [3:0] C_ACTIVE    = 4'b0011;
    localparam logic [3:0] C_READ      = 4'b0101;
    localparam logic [3:0] C_WRITE     = 4'b0100;
    localparam logic [3:0] C_PRECHARGE = 4'b0010;
    localparam logic [3:0] C_REFRESH   = 4'b0001;
    localparam logic [3:0] C_MODE      = 4'b0000;

    localparam int CW = $clog2(T_INIT + 1) > 8 ? $clog2(T_INIT + 1) : 8;
    localparam int RW = $clog2(T_REFI + 1);

    typedef enum logic [2:0] {S_INIT, S_INIT_PRE, S_INIT_REF, S_INIT_MODE, S_IDLE, S_RCD, S_READ} state_t;

    state_t      state;
    logic [CW-1:0] wait_n;     // clocks until the next command may issue
    logic [3:0]  refs_left;
    logic [RW-1:0] refi_n;     // clocks until the next refresh is due
    logic        ref_due;
    logic [1:0]  lane;
    logic        is_write;
    logic [1:0]  cl_n;
    logic [3:0]  cmd;

    assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = cmd;

    always_ff @(posedge clk) begin
        cmd      <= C_NOP;
        sd_dq_oe <= 1'b0;
        sd_dqm   <= 4'b0000;
        ack      <= 1'b0;
        if (wait_n != '0)
            wait_n <= wait_n - 1'b1;

        if (refi_n != '0)
            refi_n <= refi_n - 1'b1;
        else begin
            refi_n  <= RW'(T_REFI - 1);
            ref_due <= 1'b1;
        end

        case (state)
            S_INIT:
                if (wait_n == '0) begin
                    cmd        <= C_PRECHARGE;
                    sd_addr    <= 11'b100_0000_0000;  // all banks
                    wait_n     <= CW'(T_RP - 1);
                    refs_left  <= 4'(INIT_REFRESHES);
                    state      <= S_INIT_PRE;
                end
            S_INIT_PRE, S_INIT_REF:
                if (wait_n == '0) begin
                    if (refs_left != '0) begin
                        cmd       <= C_REFRESH;
                        wait_n    <= CW'(T_RC - 1);
                        refs_left <= refs_left - 1'b1;
                        state     <= S_INIT_REF;
                    end else begin
                        cmd     <= C_MODE;
                        sd_ba   <= 2'b00;
                        sd_addr <= MODE;
                        wait_n  <= CW'(T_MRD - 1);
                        state   <= S_INIT_MODE;
                    end
                end
            S_INIT_MODE:
                if (wait_n == '0) begin
                    ready   <= 1'b1;
                    ref_due <= 1'b0;
                    refi_n  <= RW'(T_REFI - 1);
                    state   <= S_IDLE;
                end
            S_IDLE:
                if (wait_n == '0) begin
                    if (ref_due) begin
                        cmd     <= C_REFRESH;
                        wait_n  <= CW'(T_RC - 1);
                        ref_due <= 1'b0;
                    end else if (req) begin
                        cmd      <= C_ACTIVE;
                        sd_ba    <= addr[22:21];
                        sd_addr  <= addr[20:10];
                        lane     <= addr[1:0];
                        is_write <= we;
                        sd_dq_o  <= {4{wdata}};
                        wait_n   <= CW'((we ? T_WR_DLY : T_RD_DLY) - 1);
                        state    <= S_RCD;
                    end
                end
            S_RCD:
                if (wait_n == '0) begin
                    // Column, with A10 set for auto-precharge.
                    sd_addr <= {3'b100, addr[9:2]};
                    if (is_write) begin
                        cmd      <= C_WRITE;
                        sd_dq_oe <= 1'b1;
                        sd_dqm   <= ~(4'b0001 << lane);
                        ack      <= 1'b1;
                        wait_n   <= CW'(WRITE_GAP - 1);
                        state    <= S_IDLE;
                    end else begin
                        cmd    <= C_READ;
                        cl_n   <= 2'(CAS_LATENCY);
                        wait_n <= CW'(READ_GAP - 1);
                        state  <= S_READ;
                    end
                end
            S_READ:
                if (cl_n != '0)
                    cl_n <= cl_n - 1'b1;
                else begin
                    rdata <= sd_dq_i[lane*8 +: 8];
                    ack   <= 1'b1;
                    state <= S_IDLE;
                end
            default: state <= S_INIT;
        endcase

        if (rst) begin
            state   <= S_INIT;
            wait_n  <= CW'(T_INIT);
            ready   <= 1'b0;
            ref_due <= 1'b0;
            refi_n  <= RW'(T_REFI - 1);
            cmd     <= C_NOP;
            ack     <= 1'b0;
        end
    end

    assign sd_cke = 1'b1;
endmodule
