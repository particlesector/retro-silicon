// SPDX-License-Identifier: Apache-2.0
// The Zynq-7000's processing system (PS7) with only its HP0 port in use, as an
// AXI3 slave for the fabric: 64-bit data, 6-bit IDs, clocked by the fabric's
// aclk. Its port names match memory/axi-bridge's master. The DDR behind it
// must be set up first, by the processing system (boards/xilinx/zynq7).
module ps7_hp0 (
    input  logic        aclk,
    output logic        aresetn,   // HP0's reset, from the processing system

    input  logic [31:0] m_araddr,
    input  logic        m_arvalid,
    output logic        m_arready,
    input  logic [3:0]  m_arlen,
    input  logic [2:0]  m_arsize,
    input  logic [1:0]  m_arburst,
    input  logic [3:0]  m_arcache,
    input  logic [5:0]  m_arid,
    output logic [63:0] m_rdata,
    output logic        m_rvalid,
    input  logic        m_rready,
    output logic [1:0]  m_rresp,
    output logic        m_rlast,
    input  logic [31:0] m_awaddr,
    input  logic        m_awvalid,
    output logic        m_awready,
    input  logic [3:0]  m_awlen,
    input  logic [2:0]  m_awsize,
    input  logic [1:0]  m_awburst,
    input  logic [3:0]  m_awcache,
    input  logic [5:0]  m_awid,
    input  logic [63:0] m_wdata,
    input  logic [7:0]  m_wstrb,
    input  logic        m_wlast,
    input  logic [5:0]  m_wid,
    input  logic        m_wvalid,
    output logic        m_wready,
    output logic [1:0]  m_bresp,
    output logic        m_bvalid,
    input  logic        m_bready
);
    // The port's IDs back and its FIFO levels: one transfer is out at a time.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] rid, bid, wacount;
    logic [7:0] rcount, wcount;
    logic [2:0] racount;
    /* verilator lint_on UNUSEDSIGNAL */

    PS7 u_ps7 (
        .SAXIHP0ACLK(aclk), .SAXIHP0ARESETN(aresetn),
        .SAXIHP0ARADDR(m_araddr), .SAXIHP0ARVALID(m_arvalid), .SAXIHP0ARREADY(m_arready),
        .SAXIHP0ARLEN(m_arlen), .SAXIHP0ARSIZE(m_arsize[1:0]), .SAXIHP0ARBURST(m_arburst),
        .SAXIHP0ARCACHE(m_arcache), .SAXIHP0ARID(m_arid), .SAXIHP0ARLOCK(2'b00), .SAXIHP0ARPROT(3'b000),
        .SAXIHP0ARQOS(4'd0),
        .SAXIHP0RDATA(m_rdata), .SAXIHP0RVALID(m_rvalid), .SAXIHP0RREADY(m_rready), .SAXIHP0RRESP(m_rresp),
        .SAXIHP0RLAST(m_rlast), .SAXIHP0RID(rid), .SAXIHP0RCOUNT(rcount), .SAXIHP0RACOUNT(racount), .SAXIHP0RDISSUECAP1EN(1'b0),
        .SAXIHP0AWADDR(m_awaddr), .SAXIHP0AWVALID(m_awvalid), .SAXIHP0AWREADY(m_awready),
        .SAXIHP0AWLEN(m_awlen), .SAXIHP0AWSIZE(m_awsize[1:0]), .SAXIHP0AWBURST(m_awburst),
        .SAXIHP0AWCACHE(m_awcache), .SAXIHP0AWID(m_awid), .SAXIHP0AWLOCK(2'b00), .SAXIHP0AWPROT(3'b000),
        .SAXIHP0AWQOS(4'd0),
        .SAXIHP0WDATA(m_wdata), .SAXIHP0WSTRB(m_wstrb), .SAXIHP0WLAST(m_wlast), .SAXIHP0WID(m_wid),
        .SAXIHP0WVALID(m_wvalid), .SAXIHP0WREADY(m_wready), .SAXIHP0WCOUNT(wcount), .SAXIHP0WACOUNT(wacount),
        .SAXIHP0WRISSUECAP1EN(1'b0),
        .SAXIHP0BRESP(m_bresp), .SAXIHP0BVALID(m_bvalid), .SAXIHP0BREADY(m_bready), .SAXIHP0BID(bid));

    // AXI3's size field is 3 bits, the HP port's 2: sizes over 8 bytes don't exist on a 64-bit port.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = m_arsize[2] ^ m_awsize[2];
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
