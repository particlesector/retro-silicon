// SPDX-License-Identifier: Apache-2.0
// CRC-32 (IEEE 802.3, reflected, as used by zlib), one byte per enabled clock.
module crc32 (
    input  logic        clk,
    input  logic        rst,   // synchronous; restarts the CRC
    input  logic        en,    // consume `data` this cycle
    input  logic [7:0]  data,
    output logic [31:0] crc    // CRC of every byte since reset, final XOR applied
);
    localparam logic [31:0] POLY = 32'hEDB88320;

    logic [31:0] state;

    function automatic logic [31:0] next_state(input logic [31:0] s, input logic [7:0] d);
        logic [31:0] c;
        c = s ^ {24'b0, d};
        for (int i = 0; i < 8; i++)
            c = c[0] ? (c >> 1) ^ POLY : c >> 1;
        next_state = c;  // Yosys doesn't support `return`
    endfunction

    always_ff @(posedge clk)
        if (rst)
            state <= '1;
        else if (en)
            state <= next_state(state, data);

    assign crc = ~state;
endmodule
