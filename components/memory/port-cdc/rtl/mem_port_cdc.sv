// SPDX-License-Identifier: Apache-2.0
// memory/sdram's byte port across two clock domains: a user on clk, a memory
// on mclk, such as memory/axi-bridge on a faster clock than the system's.
// One access at a time, by toggles: the user side holds the access's address
// and data steady from before its request toggle until the memory side's
// answer comes back, and the memory side holds the read data steady from
// before its answer toggle until the next request, so neither side ever
// samples a bus while it changes (common/cdc's cdc_sync carries the toggles
// and `ready`). An access costs about two clocks of each domain on top of the
// memory's own time. A read's data is DW bits: a whole line for memory/cache.
module mem_port_cdc #(
    parameter int AW = 23,
    parameter int DW = 64
) (
    // The user's side.
    input  logic          clk,
    input  logic          rst,
    input  logic          req,
    input  logic          we,
    input  logic [AW-1:0] addr,
    input  logic [7:0]    wdata,
    output logic          ack,
    output logic [DW-1:0] rdata,
    output logic          ready,

    // The memory's side.
    input  logic          mclk,
    input  logic          mrst,
    output logic          m_req,
    output logic          m_we,
    output logic [AW-1:0] m_addr,
    output logic [7:0]    m_wdata,
    input  logic          m_ack,
    input  logic [DW-1:0] m_rdata,
    input  logic          m_ready
);
    // ---- The user's side ----
    logic          req_t, busy;   // the request toggle; an access is out
    logic          ack_t_s, ack_seen;
    logic [AW-1:0] h_addr;        // held for the memory side
    logic          h_we;
    logic [7:0]    h_wdata;
    logic          ready_s;
    logic          ack_t;         // from the memory side
    logic [DW-1:0] a_data;        // held by the memory side

    cdc_sync #(.W(2)) u_to_user (.clk, .d({ack_t, m_ready}), .q({ack_t_s, ready_s}));

    always_ff @(posedge clk) begin
        ack <= 1'b0;
        if (req && !ack && !busy && ready) begin
            h_addr  <= addr;
            h_we    <= we;
            h_wdata <= wdata;
            req_t   <= !req_t;
            busy    <= 1'b1;
        end
        if (busy && ack_t_s != ack_seen) begin
            ack_seen <= ack_t_s;
            rdata    <= a_data;
            ack      <= 1'b1;
            busy     <= 1'b0;
        end
        if (rst) begin
            req_t    <= 1'b0;
            busy     <= 1'b0;
            ack      <= 1'b0;
            ack_seen <= ack_t_s;
        end
    end

    assign ready = ready_s && !rst;

    // ---- The memory's side ----
    logic req_t_s, req_seen;

    cdc_sync u_to_mem (.clk(mclk), .d(req_t), .q(req_t_s));

    always_ff @(posedge mclk) begin
        if (!m_req && req_t_s != req_seen) begin
            req_seen <= req_t_s;
            m_addr   <= h_addr;
            m_we     <= h_we;
            m_wdata  <= h_wdata;
            m_req    <= 1'b1;
        end
        if (m_req && m_ack) begin
            m_req  <= 1'b0;
            a_data <= m_rdata;
            ack_t  <= !ack_t;
        end
        if (mrst) begin
            m_req    <= 1'b0;
            ack_t    <= 1'b0;
            req_seen <= req_t_s;
        end
    end
endmodule
