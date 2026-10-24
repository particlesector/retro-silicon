// SPDX-License-Identifier: Apache-2.0
// Test-shell frame receiver. Parses
//   A5 | cmd | seq | len (2, LE) | payload (len) | CRC32 (4, LE, over cmd..payload)
// from a byte stream, writes the payload to a buffer, and reports a frame only
// when its CRC checks. Bad frames are dropped silently; the host retries.
// The parser resyncs on a length over the buffer size, or when no byte has
// arrived for IDLE_CLKS clocks mid-frame. A frame that starts while `busy` is
// checked but dropped: the host only sends one command at a time, so it's a
// retry the host has already given up on.
module ts_rx #(
    parameter int MAX_PAYLOAD_LOG2 = 11,  // payload buffer of 2**MAX_PAYLOAD_LOG2 bytes
    parameter int IDLE_CLKS = 270_000     // 10 ms at 27 MHz
) (
    input  logic                        clk,
    input  logic                        rst,          // synchronous
    input  logic [7:0]                  in_data,
    input  logic                        in_valid,     // one-cycle pulse per received byte
    input  logic                        busy,         // a command is executing: drop new frames

    output logic                        buf_we,       // payload buffer write port
    output logic [MAX_PAYLOAD_LOG2-1:0] buf_waddr,
    output logic [7:0]                  buf_wdata,

    output logic                        frame_valid,  // one-cycle pulse: a good frame arrived
    output logic [7:0]                  cmd,
    output logic [7:0]                  seq,
    output logic [15:0]                 len,
    output logic [47:0]                 args,         // first 6 payload bytes, byte 0 in [7:0]

    output logic                        crc_error,    // one-cycle pulse: a frame failed its CRC or length check
    output logic                        timeout       // one-cycle pulse: a frame stalled and was dropped
);
    localparam logic [7:0]  SYNC    = 8'hA5;
    // CRC32 over a message followed by its own CRC (LE) always gives this value.
    localparam logic [31:0] RESIDUE = 32'h2144DF1C;
    localparam int          IW      = $clog2(IDLE_CLKS + 1);

    typedef enum logic [2:0] {S_SYNC, S_CMD, S_SEQ, S_LEN0, S_LEN1, S_DATA, S_CRC, S_CHECK} state_t;

    state_t      state;
    logic [15:0] idx;      // payload bytes so far
    logic [1:0]  crc_n;    // CRC bytes so far
    logic        discard;  // busy when the frame started: check the CRC but drop the frame
    logic [IW-1:0] idle;
    logic [31:0] crc;

    wire restart = state == S_SYNC && in_valid && in_data == SYNC;

    crc32 u_crc (
        .clk, .rst(rst || restart), .en(in_valid && state != S_SYNC && state != S_CHECK),
        .data(in_data), .crc);

    assign buf_waddr = idx[MAX_PAYLOAD_LOG2-1:0];
    assign buf_wdata = in_data;
    assign buf_we    = state == S_DATA && in_valid && !discard;

    always_ff @(posedge clk) begin
        frame_valid <= 1'b0;
        crc_error   <= 1'b0;
        timeout     <= 1'b0;

        if (in_valid || state == S_SYNC)
            idle <= '0;
        else
            idle <= idle + 1'b1;

        case (state)
            S_SYNC:
                if (restart) begin
                    state   <= S_CMD;
                    discard <= busy;
                    args    <= '0;
                end
            S_CMD:  if (in_valid) begin cmd <= in_data; state <= S_SEQ; end
            S_SEQ:  if (in_valid) begin seq <= in_data; state <= S_LEN0; end
            S_LEN0: if (in_valid) begin len[7:0] <= in_data; state <= S_LEN1; end
            S_LEN1:
                if (in_valid) begin
                    len[15:8] <= in_data;
                    idx       <= '0;
                    crc_n     <= '0;
                    if ({in_data, len[7:0]} > 16'(2 ** MAX_PAYLOAD_LOG2)) begin
                        state     <= S_SYNC;  // corrupt header: don't wait for a payload
                        crc_error <= 1'b1;
                    end else
                        state <= {in_data, len[7:0]} == '0 ? S_CRC : S_DATA;
                end
            S_DATA:
                if (in_valid) begin
                    if (idx < 16'd6)
                        args[idx[2:0]*8 +: 8] <= in_data;
                    idx <= idx + 1'b1;
                    if (idx + 1'b1 == len)
                        state <= S_CRC;
                end
            S_CRC:
                if (in_valid) begin
                    crc_n <= crc_n + 1'b1;
                    if (crc_n == 2'd3)
                        state <= S_CHECK;
                end
            S_CHECK: begin
                // u_crc took the last CRC byte on the previous edge.
                state <= S_SYNC;
                if (crc != RESIDUE)
                    crc_error <= 1'b1;
                else if (!discard)
                    frame_valid <= 1'b1;
            end
            default: state <= S_SYNC;
        endcase

        if (state != S_SYNC && state != S_CHECK && idle == IW'(IDLE_CLKS - 1)) begin
            state   <= S_SYNC;
            timeout <= 1'b1;
        end

        if (rst) begin
            state       <= S_SYNC;
            idle        <= '0;
            frame_valid <= 1'b0;
            crc_error   <= 1'b0;
            timeout     <= 1'b0;
        end
    end
endmodule
