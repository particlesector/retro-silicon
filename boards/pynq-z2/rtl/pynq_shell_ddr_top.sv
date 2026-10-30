// SPDX-License-Identifier: Apache-2.0
// systems/shell-axi on the PYNQ-Z2, at 125 MHz: the test shell with an 8 MB
// window of the board's DDR3 (from 0x10000000), through memory/axi-bridge and
// the Zynq's HP0 port. The DDR must be set up first, over JTAG
// (boards/xilinx/zynq7/ps7_ddr3.py); until HP0 is out of reset, accesses wait.
// LEDs (active high): ld0 a corrupt command frame was seen, ld1 a stalled one
// (both sticky until reload), ld2 HP0 is ready, ld3 heartbeat.
module pynq_shell_ddr_top #(
    parameter int          CLKS_PER_BIT = 83,  // 125 MHz / 83 = 1.506 Mbaud
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [3:0] led
);
    /* verilator lint_off UNUSEDSIGNAL */
    logic [5:0] sys_led;  // 4-3 are always off
    /* verilator lint_on UNUSEDSIGNAL */
    logic        aresetn;
    logic [31:0] araddr, awaddr;
    logic        arvalid, arready, rvalid, rready, rlast, awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    logic [3:0]  arlen, awlen, arcache, awcache;
    logic [2:0]  arsize, awsize;
    logic [1:0]  arburst, awburst, rresp, bresp;
    logic [5:0]  arid, awid, wid;
    logic [63:0] rdata, wdata;
    logic [7:0]  wstrb;

    shell_axi #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(1_250_000), .BASE(32'h1000_0000), .BUILD_ID(BUILD_ID)) u_sys (
        .clk, .uart_rx, .uart_tx, .led(sys_led), .axi_ready(aresetn),
        .m_araddr(araddr), .m_arvalid(arvalid), .m_arready(arready), .m_arlen(arlen), .m_arsize(arsize),
        .m_arburst(arburst), .m_arcache(arcache), .m_arid(arid),
        .m_rdata(rdata), .m_rvalid(rvalid), .m_rready(rready), .m_rresp(rresp), .m_rlast(rlast),
        .m_awaddr(awaddr), .m_awvalid(awvalid), .m_awready(awready), .m_awlen(awlen), .m_awsize(awsize),
        .m_awburst(awburst), .m_awcache(awcache), .m_awid(awid),
        .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wid(wid), .m_wvalid(wvalid), .m_wready(wready),
        .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready));

    ps7_hp0 u_ps (
        .aclk(clk), .aresetn,
        .m_araddr(araddr), .m_arvalid(arvalid), .m_arready(arready), .m_arlen(arlen), .m_arsize(arsize),
        .m_arburst(arburst), .m_arcache(arcache), .m_arid(arid),
        .m_rdata(rdata), .m_rvalid(rvalid), .m_rready(rready), .m_rresp(rresp), .m_rlast(rlast),
        .m_awaddr(awaddr), .m_awvalid(awvalid), .m_awready(awready), .m_awlen(awlen), .m_awsize(awsize),
        .m_awburst(awburst), .m_awcache(awcache), .m_awid(awid),
        .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wid(wid), .m_wvalid(wvalid), .m_wready(wready),
        .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready));

    assign led = ~{sys_led[5], sys_led[2], sys_led[1], sys_led[0]};
endmodule
