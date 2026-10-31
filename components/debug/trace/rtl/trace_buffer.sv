// SPDX-License-Identifier: Apache-2.0
// A trace buffer for the test shell: the last 2^AW entries of W bits a system
// records (one a CPU cycle, say), in block RAM, to read back after it stops.
//
// Each entry recorded (`en`) goes in at ring index count[AW-1:0], and `count`
// goes up: entry i of the run, counting from the last `set`, is at ring index
// i mod 2^AW while it's among the last 2^AW. `filled` says how many of those
// are valid. `set` loads `count` (with a state loaded, the cycle it resumes
// at) and empties the buffer. The memory is W/8 byte-wide memories, which
// every toolchain maps without parity bits. Read it while nothing records:
// `rdata` is the entry at `raddr` a clock later.
module trace_buffer #(
    parameter int W  = 32,  // entry width, a multiple of 8
    parameter int AW = 10   // 2^AW entries
) (
    input  logic          clk,
    input  logic          rst,       // empties it; count to 0
    input  logic          en,        // record `data`
    input  logic [W-1:0]  data,
    input  logic          set,       // load count, and empty it
    input  logic [31:0]   set_count,
    output logic [31:0]   count,     // entries recorded since the last set or reset
    output logic [AW:0]   filled,    // how many of the last 2^AW are valid
    input  logic [AW-1:0] raddr,     // ring index
    output logic [W-1:0]  rdata
);
    localparam int NB = W / 8;

    for (genvar i = 0; i < NB; i++) begin : g_byte
        logic [7:0] mem[2**AW];
        always_ff @(posedge clk) begin
            if (en)
                mem[count[AW-1:0]] <= data[8*i +: 8];
            rdata[8*i +: 8] <= mem[raddr];
        end
    end

    always_ff @(posedge clk) begin
        if (en) begin
            count <= count + 1'b1;
            if (!filled[AW])
                filled <= filled + 1'b1;
        end
        if (set) begin
            count  <= set_count;
            filled <= '0;
        end
        if (rst) begin
            count  <= '0;
            filled <= '0;
        end
    end
endmodule
