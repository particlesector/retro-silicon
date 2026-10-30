// SPDX-License-Identifier: Apache-2.0
// Memory test system for memory behind a processor: the test shell with an
// 8 MB window of an AXI slave's memory on its bus (memory/axi-bridge, from
// AXI address BASE), mirrored through the whole address space. The harness's
// SDRAM test writes, CRCs and reads back the window through it. The board top
// connects the AXI master to the memory, such as a Zynq-7000's HP port.
// LEDs (active low): led[0] a corrupt command frame was seen, led[1] a stalled
// one (both sticky until reload), led[2] the memory is ready, led[5] heartbeat.
module shell_axi #(
    parameter int          CLKS_PER_BIT = 18,       // 27 MHz / 18 = 1.5 Mbaud
    parameter int          IDLE_CLKS    = 270_000,  // 10 ms at 27 MHz
    parameter logic [31:0] BASE         = 32'h1000_0000,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic        clk,
    input  logic        uart_rx,
    output logic        uart_tx,
    output logic [5:0]  led,
    input  logic        axi_ready,  // the AXI port is out of reset and its memory set up

    output logic [31:0] m_araddr,
    output logic        m_arvalid,
    input  logic        m_arready,
    output logic [3:0]  m_arlen,
    output logic [2:0]  m_arsize,
    output logic [1:0]  m_arburst,
    output logic [3:0]  m_arcache,
    output logic [5:0]  m_arid,
    input  logic [63:0] m_rdata,
    input  logic        m_rvalid,
    output logic        m_rready,
    input  logic [1:0]  m_rresp,
    input  logic        m_rlast,
    output logic [31:0] m_awaddr,
    output logic        m_awvalid,
    input  logic        m_awready,
    output logic [3:0]  m_awlen,
    output logic [2:0]  m_awsize,
    output logic [1:0]  m_awburst,
    output logic [3:0]  m_awcache,
    output logic [5:0]  m_awid,
    output logic [63:0] m_wdata,
    output logic [7:0]  m_wstrb,
    output logic        m_wlast,
    output logic [5:0]  m_wid,
    output logic        m_wvalid,
    input  logic        m_wready,
    input  logic [1:0]  m_bresp,
    input  logic        m_bvalid,
    output logic        m_bready
);
    logic        rst;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] bus_addr;  // only [22:0] is decoded: the window mirrors through the address space
    logic [31:0] rdata_w;   // the shell reads bytes
    /* verilator lint_on UNUSEDSIGNAL */
    logic        bus_req, bus_we, bus_ack;
    logic [7:0]  bus_wdata, bus_rdata;
    logic        crc_error, timeout;
    logic        saw_crc_error, saw_timeout;
    logic        ready;
    logic [24:0] beat;

    por u_por (.clk, .rst);

    test_shell #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .BUILD_ID(BUILD_ID)) u_shell (
        .clk, .rst, .uart_rx, .uart_tx,
        .bus_addr, .bus_req, .bus_we, .bus_wdata, .bus_ack, .bus_rdata,
        .crc_error, .timeout);

    // An access before the memory is ready waits for it.
    axi_bridge #(.AW(23), .BASE(BASE)) u_bridge (
        .clk, .rst,
        .req(bus_req), .we(bus_we), .addr(bus_addr[22:0]), .wdata(bus_wdata),
        .ack(bus_ack), .rdata(bus_rdata), .rdata_w, .ready, .axi_ready,
        .m_araddr, .m_arvalid, .m_arready, .m_arlen, .m_arsize, .m_arburst, .m_arcache, .m_arid,
        .m_rdata, .m_rvalid, .m_rready, .m_rresp, .m_rlast,
        .m_awaddr, .m_awvalid, .m_awready, .m_awlen, .m_awsize, .m_awburst, .m_awcache, .m_awid,
        .m_wdata, .m_wstrb, .m_wlast, .m_wid, .m_wvalid, .m_wready,
        .m_bresp, .m_bvalid, .m_bready);

    always_ff @(posedge clk)
        if (rst) begin
            saw_crc_error <= 1'b0;
            saw_timeout   <= 1'b0;
            beat          <= '0;
        end else begin
            if (crc_error)
                saw_crc_error <= 1'b1;
            if (timeout)
                saw_timeout <= 1'b1;
            beat <= beat + 1'b1;
        end

    assign led = ~{beat[24], 2'b00, ready, saw_timeout, saw_crc_error};
endmodule
