// SPDX-License-Identifier: Apache-2.0
// Shares one byte-port memory among N clients by fixed priority: client 0
// first. Every port, the clients' and the memory's, works as memory/sdram's:
// hold req (with addr, we, wdata) until ack, a one-clock pulse that also marks
// rdata valid on a read; req may still be high while ack is.
//
// A grant takes a clock, then the access runs to the memory's ack with the
// client's request passed straight through. A client that requests while
// another's access is running waits for it to finish and for any client before
// it, so client 0's worst wait is one access plus the grant clock.
module mem_arbiter #(
    parameter int N  = 2,   // clients
    parameter int AW = 23   // address bits
) (
    input  logic            clk,
    input  logic            rst,           // synchronous; drops any grant

    input  logic [N-1:0]    c_req,
    input  logic [N-1:0]    c_we,
    input  logic [N*AW-1:0] c_addr,        // client i in bits [i*AW +: AW]
    input  logic [N*8-1:0]  c_wdata,
    output logic [N-1:0]    c_ack,
    output logic [7:0]      c_rdata,       // shared: valid for the client being acked

    output logic            m_req,
    output logic            m_we,
    output logic [AW-1:0]   m_addr,
    output logic [7:0]      m_wdata,
    input  logic            m_ack,
    input  logic [7:0]      m_rdata
);
    localparam int GW = N > 1 ? $clog2(N) : 1;

    logic          busy;
    logic [GW-1:0] g;

    // The first requesting client.
    logic          any;
    logic [GW-1:0] pick;

    always_comb begin
        any  = 1'b0;
        pick = '0;
        for (int i = N - 1; i >= 0; i--)
            if (c_req[i]) begin
                any  = 1'b1;
                pick = GW'(i);
            end
    end

    always_ff @(posedge clk) begin
        if (!busy && any) begin
            busy <= 1'b1;
            g    <= pick;
        end else if (m_ack)
            busy <= 1'b0;
        if (rst)
            busy <= 1'b0;
    end

    assign m_req   = busy;
    assign m_we    = c_we[g];
    assign m_addr  = c_addr[g*AW +: AW];
    assign m_wdata = c_wdata[g*8 +: 8];
    assign c_rdata = m_rdata;

    always_comb
        for (int i = 0; i < N; i++)
            c_ack[i] = m_ack && busy && g == GW'(i);
endmodule
