// SPDX-License-Identifier: Apache-2.0
// CRC-32 (IEEE 802.3, reflected, as used by zlib), W bits per enabled clock,
// bit 0 first: with the default 8, one byte. Its save state is one word, the
// CRC itself: read it from `crc`, and write it back with st_we to carry on
// from there.
module crc32 #(
    parameter int W = 8
) (
    input  logic        clk,
    input  logic        rst,      // synchronous; restarts the CRC
    input  logic        en,       // consume `data` this cycle
    input  logic [W-1:0] data,
    output logic [31:0] crc,      // CRC of every byte since reset, final XOR applied
    input  logic        st_we,    // set the CRC to st_wdata, as if those bytes had gone in
    input  logic [31:0] st_wdata
);
    localparam logic [31:0] POLY = 32'hEDB88320;

    logic [31:0] state;

    function automatic logic [31:0] next_state(input logic [31:0] s, input logic [W-1:0] d);
        logic [31:0] c;
        c = s;
        for (int i = 0; i < W; i++)
            c = c[0] ^ d[i] ? (c >> 1) ^ POLY : c >> 1;
        next_state = c;  // Yosys doesn't support `return`
    endfunction

    always_ff @(posedge clk)
        if (rst)
            state <= '1;
        else if (st_we)
            state <= ~st_wdata;
        else if (en)
            state <= next_state(state, data);

    assign crc = ~state;
endmodule
