// SPDX-License-Identifier: Apache-2.0
// The NES, as far as it's built: the 2A03's CPU with 2 KB of RAM, 8 KB of PRG
// RAM at $6000 and PRG ROM through mapper 0 (NROM), read from SDRAM, under the
// test shell. The PPU and APU come later; their registers read as open bus.
//
// The CPU runs one cycle every CE_DIV clocks. Each cycle starts with its address
// valid; a PRG read goes to SDRAM at once and must be back by the cycle's last
// clock (the sticky `late` status bit records a miss, which the SDRAM's latency
// bound rules out). The shell reaches SDRAM at any time and the CPU's RAM in the
// clocks of each cycle the CPU doesn't use, so neither ever moves CPU timing:
// the CPU's bus, and the CRC of it, are the same on any board and in the sim.
//
// Shell address map (see README.md for the registers):
//   0x00000000-0x007FFFFF  SDRAM: PRG ROM from 0
//   0x01000000-0x010000FF  control and status registers
//   0x02000000-0x0200FFFF  the CPU's address space: RAM and PRG RAM; the rest reads 0
// LEDs (active low): led[0] a corrupt command frame, led[1] a stalled one,
// led[2] SDRAM ready, led[3] CPU running, led[4] halted or late, led[5] heartbeat.
module nes #(
    parameter int          CLKS_PER_BIT = 18,       // 27 MHz / 18 = 1.5 Mbaud
    parameter int          IDLE_CLKS    = 270_000,  // 10 ms at 27 MHz
    parameter int          FREQ_MHZ     = 27,
    parameter int          CE_DIV       = 15,       // clocks per CPU cycle: 1.8 MHz at 27 MHz
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
    localparam int PW = $clog2(CE_DIV);

    logic rst;
    por u_por (.clk, .rst);

    // ---- Test shell ----
    logic [31:0] s_addr;
    logic        s_req, s_we, s_ack;
    logic [7:0]  s_wdata, s_rdata;
    logic        crc_error, timeout;

    test_shell #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .BUILD_ID(BUILD_ID)) u_shell (
        .clk, .rst, .uart_rx, .uart_tx,
        .bus_addr(s_addr), .bus_req(s_req), .bus_we(s_we), .bus_wdata(s_wdata),
        .bus_ack(s_ack), .bus_rdata(s_rdata),
        .crc_error, .timeout);

    wire sel_sdram = s_addr[31:23] == 9'h000;
    wire sel_reg   = s_addr[31:24] == 8'h01;
    wire sel_mem   = s_addr[31:24] == 8'h02;

    // ---- Control registers ----
    logic        ctrl_run, ctrl_reset;
    logic [22:0] prg_mask;
    logic [15:0] vec;
    logic        vec_en;
    logic [31:0] stop_at, cycles;
    logic        stopped, late;
    logic [31:0] trace_crc;

    // ---- CPU and its clock enable ----
    logic [PW-1:0] ph;
    logic          ce, cpu_rst, running, sd_ready, halted;
    logic [15:0]   cpu_addr;
    logic          cpu_we, cpu_sync;
    logic [7:0]    cpu_dout, cpu_din;

    assign cpu_rst = rst || ctrl_reset;
    assign running = ctrl_run && !ctrl_reset && !stopped && sd_ready;
    assign ce      = running && ph == PW'(CE_DIV - 1);

    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] dbg_pc;
    logic [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p;
    /* verilator lint_on UNUSEDSIGNAL */

    cpu_6502 #(.DECIMAL(0)) u_cpu (
        .clk, .rst(cpu_rst), .ce,
        .addr(cpu_addr), .we(cpu_we), .dout(cpu_dout), .din(cpu_din),
        .rdy(1'b1), .irq_n(1'b1), .nmi_n(1'b1),
        .sync(cpu_sync), .halted,
        .dbg_pc, .dbg_a, .dbg_x, .dbg_y, .dbg_s, .dbg_p);

    always_ff @(posedge clk)
        if (cpu_rst || !running)
            ph <= '0;  // a paused cycle restarts from its first clock; nothing has happened yet
        else
            ph <= ph == PW'(CE_DIV - 1) ? '0 : ph + 1'b1;

    // CPU address decode.
    wire c_ram  = cpu_addr[15:13] == 3'b000;  // $0000-$1FFF, 2 KB mirrored
    wire c_wram = cpu_addr[15:13] == 3'b011;  // $6000-$7FFF
    wire c_prg  = cpu_addr[15];               // $8000-$FFFF
    wire c_vec  = vec_en && cpu_addr[15:1] == 15'h7FFE;

    // ---- SDRAM: the CPU's PRG reads first, then the shell ----
    logic        sd_req, sd_we, sd_ack;
    logic [22:0] sd_a;
    logic [7:0]  sd_wdata, sd_rdata;
    logic        cpu_sd_pend;   // this cycle's PRG read is waiting for SDRAM
    logic [7:0]  cpu_sd_data;
    logic [1:0]  grant;         // 0 none, 1 CPU, 2 shell: held until ack
    logic        sh_sd_ack;

    sdram_ctrl #(.FREQ_MHZ(FREQ_MHZ)) u_sdram (
        .clk, .rst,
        .req(sd_req), .we(sd_we), .addr(sd_a), .wdata(sd_wdata),
        .ack(sd_ack), .rdata(sd_rdata), .ready(sd_ready),
        .sd_cke, .sd_cs_n, .sd_ras_n, .sd_cas_n, .sd_we_n, .sd_ba, .sd_addr, .sd_dqm,
        .sd_dq_o, .sd_dq_oe, .sd_dq_i);

    assign sd_req   = grant != 2'd0;
    assign sd_we    = grant == 2'd2 && s_we;
    assign sd_a     = grant == 2'd1 ? {8'b0, cpu_addr[14:0]} & prg_mask : s_addr[22:0];
    assign sd_wdata = s_wdata;

    always_ff @(posedge clk) begin
        sh_sd_ack <= 1'b0;
        if (running && ph == '0 && !cpu_we && c_prg && !c_vec)
            cpu_sd_pend <= 1'b1;
        if (grant == 2'd0 && !sd_ack) begin
            if (cpu_sd_pend)
                grant <= 2'd1;
            else if (s_req && sel_sdram && !s_ack)
                grant <= 2'd2;
        end else if (sd_ack) begin
            grant <= 2'd0;
            if (grant == 2'd1) begin
                cpu_sd_data <= sd_rdata;
                cpu_sd_pend <= 1'b0;
            end else
                sh_sd_ack <= 1'b1;
        end
        if (rst) begin
            grant       <= 2'd0;
            cpu_sd_pend <= 1'b0;
        end
    end

    // ---- RAM and PRG RAM, shared with the shell ----
    // The CPU uses the port on its cycle's first clock (read) and last (write);
    // the shell gets the clocks between, or any clock while the CPU is paused.
    logic [7:0] ram[2048];
    logic [7:0] wram[8192];
    logic [7:0] ram_q, wram_q, cpu_mem_data;
    logic [12:0] m_addr;
    logic       m_ram, m_wram, m_we;
    logic [7:0] m_wdata;
    logic       cpu_slot, sh_m_issue, sh_m_wait, sh_m_ack, sh_m_wram, sh_m_mapped;
    logic [7:0] sh_m_data;

    assign cpu_slot   = running && (ph == '0 || ce);
    assign sh_m_issue = !cpu_slot && s_req && sel_mem && !s_ack && !sh_m_wait && !sh_m_ack;

    always_comb begin
        m_we    = 1'b0;
        m_wdata = cpu_dout;
        if (cpu_slot) begin
            m_addr = cpu_addr[12:0];
            m_ram  = c_ram;
            m_wram = c_wram;
            m_we   = ce && cpu_we;
        end else begin
            m_addr  = s_addr[12:0];
            m_ram   = s_addr[15:13] == 3'b000;
            m_wram  = s_addr[15:13] == 3'b011;
            m_we    = sh_m_issue && s_we;
            m_wdata = s_wdata;
        end
    end

    always_ff @(posedge clk) begin
        if (m_we && m_ram)
            ram[m_addr[10:0]] <= m_wdata;
        if (m_we && m_wram)
            wram[m_addr] <= m_wdata;
        ram_q  <= ram[m_addr[10:0]];
        wram_q <= wram[m_addr];
    end

    always_ff @(posedge clk) begin
        sh_m_ack <= 1'b0;
        // The CPU read issued on the first clock is in ram_q/wram_q on the second.
        if (running && ph == PW'(1))
            cpu_mem_data <= c_wram ? wram_q : ram_q;
        if (sh_m_issue) begin
            sh_m_wait   <= 1'b1;
            sh_m_wram   <= m_wram;
            sh_m_mapped <= m_ram || m_wram;
        end
        // The shell's read is in ram_q/wram_q for one clock only: hold it.
        if (sh_m_wait) begin
            sh_m_wait <= 1'b0;
            sh_m_ack  <= 1'b1;
            sh_m_data <= !sh_m_mapped ? 8'h00 : sh_m_wram ? wram_q : ram_q;
        end
        if (rst) begin
            sh_m_wait <= 1'b0;
            sh_m_ack  <= 1'b0;
        end
    end

    // ---- CPU data in, open bus and the trace CRC ----
    logic [7:0] open_bus;

    always_comb
        if (c_vec)
            cpu_din = cpu_addr[0] ? vec[15:8] : vec[7:0];
        else if (c_prg)
            cpu_din = cpu_sd_data;
        else if (c_ram || c_wram)
            cpu_din = cpu_mem_data;
        else
            cpu_din = open_bus;  // PPU and APU registers, and $4020-$5FFF, until they exist

    // Each CPU cycle goes into the trace CRC as 4 bytes: address low, address
    // high, data (read or written), flags (bit 0 write, bit 1 opcode fetch).
    logic [31:0] tr;
    logic [2:0]  tr_n;

    crc32 u_trace (.clk, .rst(cpu_rst), .en(tr_n != '0), .data(tr[7:0]), .crc(trace_crc));

    always_ff @(posedge clk) begin
        if (tr_n != '0) begin
            tr   <= tr >> 8;
            tr_n <= tr_n - 1'b1;
        end
        if (ce) begin
            open_bus <= cpu_we ? cpu_dout : cpu_din;
            tr       <= {6'b0, cpu_sync, cpu_we, cpu_we ? cpu_dout : cpu_din, cpu_addr};
            tr_n     <= 3'd4;
            cycles   <= cycles + 1'b1;
            if (stop_at != '0 && cycles + 1'b1 == stop_at)
                stopped <= 1'b1;
            if (cpu_sd_pend)
                late <= 1'b1;
        end
        if (cpu_rst) begin
            tr_n     <= '0;
            cycles   <= '0;
            stopped  <= 1'b0;
            late     <= 1'b0;
            open_bus <= '0;
        end
    end

    // ---- Register file ----
    logic       reg_ack;
    logic [7:0] reg_q;
    wire  [7:0] r = s_addr[7:0];

    always_ff @(posedge clk) begin
        reg_ack <= s_req && sel_reg && !s_ack && !reg_ack;
        if (s_req && sel_reg && s_we && !s_ack && !reg_ack)
            case (r)
                8'h00: {ctrl_reset, ctrl_run} <= s_wdata[1:0];
                8'h04: prg_mask[7:0]   <= s_wdata;
                8'h05: prg_mask[15:8]  <= s_wdata;
                8'h06: prg_mask[22:16] <= s_wdata[6:0];
                8'h08: vec[7:0]        <= s_wdata;
                8'h09: vec[15:8]       <= s_wdata;
                8'h0A: vec_en          <= s_wdata[0];
                8'h0C: stop_at[7:0]    <= s_wdata;
                8'h0D: stop_at[15:8]   <= s_wdata;
                8'h0E: stop_at[23:16]  <= s_wdata;
                8'h0F: stop_at[31:24]  <= s_wdata;
                default: ;
            endcase
        case (r)
            8'h00:   reg_q <= {6'b0, ctrl_reset, ctrl_run};
            8'h04:   reg_q <= prg_mask[7:0];
            8'h05:   reg_q <= prg_mask[15:8];
            8'h06:   reg_q <= {1'b0, prg_mask[22:16]};
            8'h08:   reg_q <= vec[7:0];
            8'h09:   reg_q <= vec[15:8];
            8'h0A:   reg_q <= {7'b0, vec_en};
            8'h0C:   reg_q <= stop_at[7:0];
            8'h0D:   reg_q <= stop_at[15:8];
            8'h0E:   reg_q <= stop_at[23:16];
            8'h0F:   reg_q <= stop_at[31:24];
            8'h10:   reg_q <= cycles[7:0];
            8'h11:   reg_q <= cycles[15:8];
            8'h12:   reg_q <= cycles[23:16];
            8'h13:   reg_q <= cycles[31:24];
            8'h14:   reg_q <= trace_crc[7:0];
            8'h15:   reg_q <= trace_crc[15:8];
            8'h16:   reg_q <= trace_crc[23:16];
            8'h17:   reg_q <= trace_crc[31:24];
            8'h18:   reg_q <= {4'b0, running, late, stopped, halted};
            default: reg_q <= '0;
        endcase
        if (rst) begin
            reg_ack    <= 1'b0;
            ctrl_reset <= 1'b1;
            ctrl_run   <= 1'b0;
            prg_mask   <= 23'h7FFF;
            vec_en     <= 1'b0;
            stop_at    <= '0;
        end
    end

    // Accesses outside the map are acknowledged at once: writes vanish, reads give 0.
    logic       none_ack;
    logic [7:0] sd_rdata_q;  // the SDRAM's read data, held for the shell's acknowledge a clock later

    always_ff @(posedge clk)
        if (sd_ack)
            sd_rdata_q <= sd_rdata;

    always_ff @(posedge clk)
        none_ack <= s_req && !(sel_sdram || sel_reg || sel_mem) && !s_ack && !none_ack && !rst;

    assign s_ack   = sh_sd_ack || sh_m_ack || reg_ack || none_ack;
    always_comb
        if (sh_sd_ack)
            s_rdata = sd_rdata_q;
        else if (sh_m_ack)
            s_rdata = sh_m_data;
        else if (reg_ack)
            s_rdata = reg_q;
        else
            s_rdata = 8'h00;

    // ---- LEDs ----
    logic        saw_crc_error, saw_timeout;
    logic [24:0] beat;

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

    assign led = ~{beat[24], halted || late, running, sd_ready, saw_timeout, saw_crc_error};
endmodule
