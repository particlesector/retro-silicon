// SPDX-License-Identifier: Apache-2.0
// Test-shell test system: the shell with a 4 KB scratch RAM on its bus, mirrored
// through the whole address space. The harness exercises PING, INFO, PEEK and
// POKE against it.
// LEDs (active low): led[0] a corrupt command frame was seen, led[1] a stalled
// one (both sticky until reload), led[5] heartbeat.
module shell_ram #(
    parameter int          CLKS_PER_BIT = 18,       // 27 MHz / 18 = 1.5 Mbaud
    parameter int          IDLE_CLKS    = 270_000,  // 10 ms at 27 MHz
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic       clk,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [5:0] led
);
    logic        rst;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] bus_addr;  // only [11:0] is decoded: the RAM mirrors through the address space
    /* verilator lint_on UNUSEDSIGNAL */
    logic        bus_req, bus_we, bus_ack;
    logic [7:0]  bus_wdata, bus_rdata;
    logic        crc_error, timeout;
    logic        saw_crc_error, saw_timeout;
    logic [24:0] beat;

    por u_por (.clk, .rst);

    test_shell #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .BUILD_ID(BUILD_ID)) u_shell (
        .clk, .rst, .uart_rx, .uart_tx,
        .bus_addr, .bus_req, .bus_we, .bus_wdata, .bus_ack, .bus_rdata,
        .crc_error, .timeout);

    // 4 KB of block RAM; acknowledges every access one clock after the request.
    logic [7:0] ram[4096];
    wire [11:0] ram_addr = bus_addr[11:0];

    always_ff @(posedge clk) begin
        if (bus_req && bus_we && !bus_ack)
            ram[ram_addr] <= bus_wdata;
        bus_rdata <= ram[ram_addr];
    end

    always_ff @(posedge clk)
        if (rst) begin
            bus_ack       <= 1'b0;
            saw_crc_error <= 1'b0;
            saw_timeout   <= 1'b0;
            beat          <= '0;
        end else begin
            bus_ack <= bus_req && !bus_ack;
            if (crc_error)
                saw_crc_error <= 1'b1;
            if (timeout)
                saw_timeout <= 1'b1;
            beat <= beat + 1'b1;
        end

    assign led = ~{beat[24], 3'b000, saw_timeout, saw_crc_error};
endmodule
