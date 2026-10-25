// SPDX-License-Identifier: Apache-2.0
// Test shell: a UART command engine that gives the host access to a core.
// The host sends one framed command at a time and waits for its response (see
// README.md for the frame format and commands). Commands start with A5,
// responses with 5A, so a loopback or echo never looks like a working shell. Every command is idempotent,
// so the host can resend after a timeout or a bad CRC.
//
// The bus is a byte bus with a request/acknowledge handshake: the shell holds
// bus_req (with bus_addr, bus_we, bus_wdata) until bus_ack, which also marks
// bus_rdata valid on a read. The system decides what the 32-bit address space
// maps to.
module test_shell #(
    parameter int          CLKS_PER_BIT     = 18,       // 27 MHz / 18 = 1.5 Mbaud
    parameter int          MAX_PAYLOAD_LOG2 = 11,       // command payloads up to 2 KB
    parameter int          IDLE_CLKS        = 270_000,  // drop a frame stalled for 10 ms at 27 MHz
    parameter logic [31:0] BUILD_ID         = '0        // reported by INFO; ties results to a build
) (
    input  logic        clk,
    input  logic        rst,        // synchronous
    input  logic        uart_rx,
    output logic        uart_tx,

    output logic [31:0] bus_addr,
    output logic        bus_req,
    output logic        bus_we,
    output logic [7:0]  bus_wdata,
    input  logic        bus_ack,
    input  logic [7:0]  bus_rdata,

    output logic        crc_error,  // one-cycle pulse: a command frame was dropped as corrupt
    output logic        timeout     // one-cycle pulse: a command frame stalled and was dropped
);
    localparam logic [7:0] CMD_PING = 8'h01;  // echo the payload
    localparam logic [7:0] CMD_INFO = 8'h02;  // 16 bytes: magic, version, build ID, limits, error counts
    localparam logic [7:0] CMD_PEEK = 8'h10;  // addr (4), count (2) -> count bytes from the bus
    localparam logic [7:0] CMD_POKE = 8'h11;  // addr (4), data... -> writes data to the bus
    localparam logic [7:0] CMD_CRC  = 8'h12;  // addr (4), count (4) -> CRC-32 of count bytes from the bus

    localparam logic [7:0] ST_OK          = 8'h00;
    localparam logic [7:0] ST_UNKNOWN_CMD = 8'h01;
    localparam logic [7:0] ST_BAD_LENGTH  = 8'h02;

    localparam logic [15:0] VERSION = 16'd2;
    localparam int          AW      = MAX_PAYLOAD_LOG2;

    // ---- UART and framing ----
    logic [7:0]  rx_data, tx_data;
    logic        rx_valid, tx_valid, tx_ready;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        rx_frame_err;  // a bad stop bit also fails the frame CRC, so it needs no handling
    /* verilator lint_on UNUSEDSIGNAL */

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_rx (
        .clk, .rst, .rx(uart_rx), .data(rx_data), .valid(rx_valid), .frame_err(rx_frame_err));

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart_tx (
        .clk, .rst, .data(tx_data), .valid(tx_valid), .ready(tx_ready), .tx(uart_tx));

    logic          busy;
    logic          buf_we;
    logic [AW-1:0] buf_waddr, buf_raddr;
    logic [7:0]    buf_wdata, buf_rdata;
    logic          frame_valid;
    logic [7:0]    f_cmd, f_seq;
    logic [15:0]   f_len;
    logic [63:0]   f_args;

    ts_rx #(.MAX_PAYLOAD_LOG2(MAX_PAYLOAD_LOG2), .IDLE_CLKS(IDLE_CLKS)) u_rx (
        .clk, .rst, .in_data(rx_data), .in_valid(rx_valid), .busy,
        .buf_we, .buf_waddr, .buf_wdata,
        .frame_valid, .cmd(f_cmd), .seq(f_seq), .len(f_len), .args(f_args),
        .crc_error, .timeout);

    logic        tx_start, tx_idle;
    logic [7:0]  r_status, r_seq;
    logic [15:0] r_len;
    logic [7:0]  stage_data;
    logic        stage_valid, stage_ready;

    ts_tx u_tx (
        .clk, .rst, .start(tx_start), .status(r_status), .seq(r_seq), .len(r_len), .idle(tx_idle),
        .data(stage_data), .data_valid(stage_valid), .data_ready(stage_ready),
        .out_data(tx_data), .out_valid(tx_valid), .out_ready(tx_ready));

    // ---- Payload buffer (block RAM, registered read) ----
    logic [7:0] mem[2**AW];

    always_ff @(posedge clk) begin
        if (buf_we)
            mem[buf_waddr] <= buf_wdata;
        buf_rdata <= mem[buf_raddr];
    end

    // ---- Error counters, saturating ----
    logic [15:0] crc_errors, timeouts;

    always_ff @(posedge clk)
        if (rst) begin
            crc_errors <= '0;
            timeouts   <= '0;
        end else begin
            if (crc_error && crc_errors != '1)
                crc_errors <= crc_errors + 1'b1;
            if (timeout && timeouts != '1)
                timeouts <= timeouts + 1'b1;
        end

    // INFO response, byte 0 in [7:0].
    wire [127:0] info = {timeouts, crc_errors, 16'(2 ** AW), BUILD_ID, VERSION, "STSR"};

    // ---- Dispatcher ----
    typedef enum logic [2:0] {D_IDLE, D_POKE, D_POKE_RD, D_POKE_WR, D_CRC, D_START, D_SEND, D_WAIT} dstate_t;
    typedef enum logic [2:0] {SRC_NONE, SRC_BUF, SRC_INFO, SRC_BUS, SRC_CRC} src_t;

    dstate_t     dstate;
    src_t        src;
    logic [31:0] base;      // PEEK/POKE start address
    logic [15:0] fetch_n;   // response bytes fetched so far
    logic        pending;   // a fetch is waiting on the buffer or the bus
    logic [15:0] j;         // POKE: payload byte being written
    logic [31:0] crc_left;  // CRC: bytes still to read
    logic        crc_rst, crc_en;
    logic [31:0] crc_val;

    crc32 u_crc (.clk, .rst(crc_rst), .en(crc_en), .data(bus_rdata), .crc(crc_val));

    assign crc_rst = dstate == D_IDLE;
    assign crc_en  = dstate == D_CRC && bus_req && bus_ack;

    assign busy      = dstate != D_IDLE;
    assign tx_start  = dstate == D_START;
    assign buf_raddr = dstate == D_POKE ? j[AW-1:0] : fetch_n[AW-1:0];

    always_ff @(posedge clk) begin
        case (dstate)
            D_IDLE:
                if (frame_valid) begin
                    r_seq   <= f_seq;
                    r_status <= ST_OK;
                    r_len   <= '0;
                    src     <= SRC_NONE;
                    dstate  <= D_START;
                    case (f_cmd)
                        CMD_PING: begin
                            r_len <= f_len;
                            src   <= SRC_BUF;
                        end
                        CMD_INFO:
                            if (f_len != '0)
                                r_status <= ST_BAD_LENGTH;
                            else begin
                                r_len <= 16'd16;
                                src   <= SRC_INFO;
                            end
                        CMD_PEEK:
                            if (f_len != 16'd6)
                                r_status <= ST_BAD_LENGTH;
                            else begin
                                base  <= f_args[31:0];
                                r_len <= f_args[47:32];
                                src   <= SRC_BUS;
                            end
                        CMD_POKE:
                            if (f_len < 16'd4)
                                r_status <= ST_BAD_LENGTH;
                            else begin
                                base   <= f_args[31:0];
                                j      <= 16'd4;
                                dstate <= D_POKE;
                            end
                        CMD_CRC:
                            if (f_len != 16'd8)
                                r_status <= ST_BAD_LENGTH;
                            else begin
                                bus_addr <= f_args[31:0];
                                bus_we   <= 1'b0;
                                crc_left <= f_args[63:32];
                                r_len    <= 16'd4;
                                src      <= SRC_CRC;
                                dstate   <= D_CRC;
                            end
                        default: r_status <= ST_UNKNOWN_CMD;
                    endcase
                end
            D_POKE:
                // buf_raddr is j this cycle, so buf_rdata holds byte j on the next.
                if (j == f_len)
                    dstate <= D_START;
                else
                    dstate <= D_POKE_RD;
            D_POKE_RD: begin
                bus_addr  <= base + 32'(j - 16'd4);
                bus_we    <= 1'b1;
                bus_wdata <= buf_rdata;
                bus_req   <= 1'b1;
                dstate    <= D_POKE_WR;
            end
            D_POKE_WR:
                if (bus_ack) begin
                    bus_req <= 1'b0;
                    j       <= j + 1'b1;
                    dstate  <= D_POKE;
                end
            D_CRC:
                // One read at a time; each acknowledged byte goes into u_crc.
                if (bus_req) begin
                    if (bus_ack) begin
                        bus_req  <= 1'b0;
                        bus_addr <= bus_addr + 1'b1;
                        crc_left <= crc_left - 1'b1;
                    end
                end else if (crc_left == '0)
                    dstate <= D_START;
                else
                    bus_req <= 1'b1;
            D_START: begin
                fetch_n     <= '0;
                pending     <= 1'b0;
                stage_valid <= 1'b0;
                dstate      <= D_SEND;
            end
            D_SEND: begin
                if (stage_valid && stage_ready)
                    stage_valid <= 1'b0;
                if (pending) begin
                    // A buffer read completes after one clock; a bus read on bus_ack.
                    if (src == SRC_BUF) begin
                        stage_data  <= buf_rdata;
                        stage_valid <= 1'b1;
                        pending     <= 1'b0;
                    end else if (bus_ack) begin
                        stage_data  <= bus_rdata;
                        stage_valid <= 1'b1;
                        pending     <= 1'b0;
                        bus_req     <= 1'b0;
                    end
                end else if (!stage_valid && fetch_n != r_len) begin
                    fetch_n <= fetch_n + 1'b1;
                    case (src)
                        SRC_INFO: begin
                            stage_data  <= info[fetch_n[3:0]*8 +: 8];
                            stage_valid <= 1'b1;
                        end
                        SRC_CRC: begin
                            stage_data  <= crc_val[fetch_n[1:0]*8 +: 8];
                            stage_valid <= 1'b1;
                        end
                        SRC_BUS: begin
                            bus_addr <= base + 32'(fetch_n);
                            bus_we   <= 1'b0;
                            bus_req  <= 1'b1;
                            pending  <= 1'b1;
                        end
                        default: pending <= 1'b1;  // SRC_BUF: buf_raddr is fetch_n this cycle
                    endcase
                end else if (!stage_valid && fetch_n == r_len)
                    dstate <= D_WAIT;
            end
            D_WAIT:
                if (tx_idle)
                    dstate <= D_IDLE;
            default: dstate <= D_IDLE;
        endcase

        if (rst) begin
            dstate      <= D_IDLE;
            bus_req     <= 1'b0;
            stage_valid <= 1'b0;
            pending     <= 1'b0;
        end
    end
endmodule
