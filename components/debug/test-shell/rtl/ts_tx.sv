// SPDX-License-Identifier: Apache-2.0
// Test-shell frame transmitter. On `start` it sends
//   5A | status | seq | len (2, LE) | payload (len) | CRC32 (4, LE, over status..payload)
// taking the payload as a stream of exactly `len` bytes, and computing the CRC
// as the bytes go out, so a response of any length needs no buffer.
module ts_tx (
    input  logic        clk,
    input  logic        rst,         // synchronous
    input  logic        start,       // taken only while idle
    input  logic [7:0]  status,
    input  logic [7:0]  seq,
    input  logic [15:0] len,
    output logic        idle,

    input  logic [7:0]  data,        // payload stream
    input  logic        data_valid,
    output logic        data_ready,

    output logic [7:0]  out_data,    // to the UART transmitter
    output logic        out_valid,
    input  logic        out_ready
);
    // Not the command sync byte (A5), so a loopback never looks like a response.
    localparam logic [7:0] SYNC = 8'h5A;

    typedef enum logic [1:0] {S_IDLE, S_HDR, S_DATA, S_CRC} state_t;

    state_t      state;
    logic [2:0]  n;       // byte within the header or the CRC
    logic [15:0] left;    // payload bytes still to send
    logic [39:0] hdr;     // sync, status, seq, len; byte 0 in [7:0]
    logic [31:0] crc;

    wire take = out_valid && out_ready;

    // The CRC covers everything after the sync byte, up to the end of the payload.
    crc32 u_crc (
        .clk, .rst(rst || (state == S_IDLE && start)),
        .en(take && (state == S_DATA || (state == S_HDR && n != 3'd0))),
        .data(out_data), .crc, .st_we(1'b0), .st_wdata('0));

    assign idle       = state == S_IDLE;
    assign data_ready = state == S_DATA && out_ready;

    always_comb
        case (state)
            S_HDR:   begin out_data = hdr[n*8 +: 8]; out_valid = 1'b1; end
            S_DATA:  begin out_data = data; out_valid = data_valid; end
            S_CRC:   begin out_data = crc[n[1:0]*8 +: 8]; out_valid = 1'b1; end
            default: begin out_data = 8'h00; out_valid = 1'b0; end
        endcase

    always_ff @(posedge clk)
        if (rst)
            state <= S_IDLE;
        else
            case (state)
                S_IDLE:
                    if (start) begin
                        hdr   <= {len, seq, status, SYNC};
                        left  <= len;
                        n     <= '0;
                        state <= S_HDR;
                    end
                S_HDR:
                    if (take) begin
                        n <= n + 1'b1;
                        if (n == 3'd4) begin
                            n     <= '0;
                            state <= left == '0 ? S_CRC : S_DATA;
                        end
                    end
                S_DATA:
                    if (take) begin
                        left <= left - 1'b1;
                        if (left == 16'd1)
                            state <= S_CRC;
                    end
                S_CRC:
                    if (take) begin
                        n <= n + 1'b1;
                        if (n == 3'd3)
                            state <= S_IDLE;
                    end
            endcase
endmodule
