// SPDX-License-Identifier: Apache-2.0
// SDRAM test system: the test shell with the 8 MB SDRAM on its bus, mirrored
// through the whole address space. The harness writes, CRCs and reads back
// SDRAM through it, which is how ROMs will be uploaded.
// LEDs (active low): led[0] a corrupt command frame was seen, led[1] a stalled
// one (both sticky until reload), led[2] the SDRAM is ready, led[5] heartbeat.
module shell_sdram #(
    parameter int          CLKS_PER_BIT = 18,       // 27 MHz / 18 = 1.5 Mbaud
    parameter int          IDLE_CLKS    = 270_000,  // 10 ms at 27 MHz
    parameter int          FREQ_MHZ     = 27,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic        clk,
    input  logic        uart_rx,
    output logic        uart_tx,
    output logic [5:0]  led,

    output logic        sd_cke,
    output logic        sd_cs_n,
    output logic        sd_ras_n,
    output logic        sd_cas_n,
    output logic        sd_we_n,
    output logic [1:0]  sd_ba,
    output logic [10:0] sd_addr,
    output logic [3:0]  sd_dqm,
    output logic [31:0] sd_dq_o,
    output logic        sd_dq_oe,
    input  logic [31:0] sd_dq_i
);
    logic        rst;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] bus_addr;  // only [22:0] is decoded: the SDRAM mirrors through the address space
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

    // The controller ignores req until its power-up sequence is done.
    sdram_ctrl #(.FREQ_MHZ(FREQ_MHZ)) u_sdram (
        .clk, .rst,
        .req(bus_req), .we(bus_we), .addr(bus_addr[22:0]), .wdata(bus_wdata),
        .ack(bus_ack), .rdata(bus_rdata), .ready,
        .sd_cke, .sd_cs_n, .sd_ras_n, .sd_cas_n, .sd_we_n, .sd_ba, .sd_addr, .sd_dqm,
        .sd_dq_o, .sd_dq_oe, .sd_dq_i);

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
