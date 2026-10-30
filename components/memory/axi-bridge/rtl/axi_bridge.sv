// SPDX-License-Identifier: Apache-2.0
// memory/sdram's byte port onto an AXI master: a system's memory in a
// processor's DDR, through a port such as the Zynq-7000's HP ports. Each
// access is one single-beat AXI transfer of the aligned 64-bit word: a read
// fetches the word and gives the byte (and its 32-bit half, rdata_w, as
// memory/sdram does), a write sends the byte with its strobe and waits for
// the write response. One access at a time, so they complete in order.
// The transfers are valid AXI3 (WID, 4-bit lengths) and AXI4 alike.
//
// The port's byte address `addr` is at AXI address BASE + addr. `ready`
// follows `axi_ready` (the AXI port out of reset, the memory behind it set
// up): requests must wait for it.
module axi_bridge #(
    parameter int          AW   = 23,             // the port's address width
    parameter logic [31:0] BASE = 32'h1000_0000,  // where the window starts, 8-byte aligned
    parameter int          IDW  = 6               // AXI ID width
) (
    input  logic          clk,
    input  logic          rst,

    // The byte port.
    input  logic          req,
    input  logic          we,
    input  logic [AW-1:0] addr,
    input  logic [7:0]    wdata,
    output logic          ack,
    output logic [7:0]    rdata,
    output logic [31:0]   rdata_w,
    output logic          ready,
    input  logic          axi_ready,

    // AXI master: read address and data.
    output logic [31:0]   m_araddr,
    output logic          m_arvalid,
    input  logic          m_arready,
    output logic [3:0]    m_arlen,
    output logic [2:0]    m_arsize,
    output logic [1:0]    m_arburst,
    output logic [3:0]    m_arcache,
    output logic [IDW-1:0] m_arid,
    input  logic [63:0]   m_rdata,
    input  logic          m_rvalid,
    output logic          m_rready,
    input  logic [1:0]    m_rresp,
    input  logic          m_rlast,

    // Write address, data and response.
    output logic [31:0]   m_awaddr,
    output logic          m_awvalid,
    input  logic          m_awready,
    output logic [3:0]    m_awlen,
    output logic [2:0]    m_awsize,
    output logic [1:0]    m_awburst,
    output logic [3:0]    m_awcache,
    output logic [IDW-1:0] m_awid,
    output logic [63:0]   m_wdata,
    output logic [7:0]    m_wstrb,
    output logic          m_wlast,
    output logic [IDW-1:0] m_wid,
    output logic          m_wvalid,
    input  logic          m_wready,
    input  logic [1:0]    m_bresp,
    input  logic          m_bvalid,
    output logic          m_bready
);
    typedef enum logic [1:0] {S_IDLE, S_READ, S_WRITE} state_t;

    state_t     st;
    logic [2:0] lane;  // the byte's lane in the 64-bit word

    wire take = req && !ack && ready && st == S_IDLE;

    // Single beats of 8 bytes, incrementing, bufferable and modifiable.
    assign m_arlen   = '0;
    assign m_arsize  = 3'd3;
    assign m_arburst = 2'b01;
    assign m_arcache = 4'b0011;
    assign m_arid    = '0;
    assign m_awlen   = '0;
    assign m_awsize  = 3'd3;
    assign m_awburst = 2'b01;
    assign m_awcache = 4'b0011;
    assign m_awid    = '0;
    assign m_wid     = '0;
    assign m_wlast   = 1'b1;
    assign m_rready  = st == S_READ;
    assign m_bready  = st == S_WRITE;

    always_ff @(posedge clk) begin
        ack <= 1'b0;
        if (take) begin
            lane <= addr[2:0];
            if (we) begin
                m_awaddr  <= BASE + {{(32 - AW){1'b0}}, addr[AW-1:3], 3'b000};
                m_wdata   <= {8{wdata}};
                m_wstrb   <= 8'b1 << addr[2:0];
                m_awvalid <= 1'b1;
                m_wvalid  <= 1'b1;
                st        <= S_WRITE;
            end else begin
                m_araddr  <= BASE + {{(32 - AW){1'b0}}, addr[AW-1:3], 3'b000};
                m_arvalid <= 1'b1;
                st        <= S_READ;
            end
        end
        if (m_arvalid && m_arready)
            m_arvalid <= 1'b0;
        if (m_awvalid && m_awready)
            m_awvalid <= 1'b0;
        if (m_wvalid && m_wready)
            m_wvalid <= 1'b0;
        if (st == S_READ && m_rvalid) begin
            rdata   <= m_rdata[8*lane +: 8];
            rdata_w <= lane[2] ? m_rdata[63:32] : m_rdata[31:0];
            ack     <= 1'b1;
            st      <= S_IDLE;
        end
        if (st == S_WRITE && m_bvalid) begin
            ack <= 1'b1;
            st  <= S_IDLE;
        end
        ready <= axi_ready && !rst;
        if (rst) begin
            st        <= S_IDLE;
            m_arvalid <= 1'b0;
            m_awvalid <= 1'b0;
            m_wvalid  <= 1'b0;
            ack       <= 1'b0;
        end
    end

    // An error response isn't reported: the byte port has no way to say so.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{m_rresp, m_rlast, m_bresp};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
