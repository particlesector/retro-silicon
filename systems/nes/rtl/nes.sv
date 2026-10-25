// SPDX-License-Identifier: Apache-2.0
// The NES, as far as it's built: the 2A03's CPU and OAM DMA, the 2C02 PPU,
// 2 KB of RAM, 8 KB of PRG RAM at $6000, and an NROM cartridge (PRG ROM in the
// board's memory, 8 KB of CHR ROM or RAM in block RAM, nametable mirroring by
// a register), under the test shell, with a save-state controller. The APU and
// controllers come later; their registers read as open bus.
//
// The board's memory is a byte port, as memory/sdram's: the board puts SDRAM,
// block RAM or anything else behind it. memory/arbiter shares it between the
// CPU's PRG reads, first, and the shell.
//
// Timing. The PPU runs one dot per pulse of a phase accumulator at DOT_NUM/
// DOT_DEN of the clock: the NTSC rate exactly, on average. Each CPU cycle is
// three dots; the CPU's PPU register access falls after the second and its
// NMI sample after the third, as in MesenCE, and after reset the PPU runs
// LEAD_DOTS dots before the CPU's first cycle, which lines its first opcode
// fetch up with MesenCE's. A CPU cycle starts the clock after the last one
// ended: its address is valid then, a PRG read goes to memory at once and must
// be back by the cycle's end (the sticky `late` status bit records a miss),
// and RAM is read on that first clock and written on the last.
//
// The system stops and starts only between CPU cycles, so stopping (by the
// shell, a cycle or frame count, the video probe's capture or a save state) leaves the
// CPU's bus and the PPU's output exactly as they would have been: the same on
// any board and in the sim.
//
// Shell address map (see README.md for the registers):
//   0x00000000-0x007FFFFF  the board's memory: PRG ROM from 0
//   0x01000000-0x010000FF  control and status registers
//   0x02000000-0x0200FFFF  the CPU's address space: RAM and PRG RAM; the rest reads 0
//   0x03000000-0x03003FFF  the PPU's: CHR ($0000-$1FFF) and nametables ($2000-$3FFF);
//                          0x03004000-0x030047FF the nametable RAM as it is, unmirrored
//   0x04000000-0x0400000F  CPU save state; 0x04001000-0x04001193 PPU save state;
//                          0x04002000-0x04002013 the system's own
//   0x05000000-0x050003BF  line CRCs of the last frame; 0x05001000-0x050011FF the captured line
//   0x06000000-0x06007FFF  the save-state buffer
// LEDs (active low): led[0] a corrupt command frame, led[1] a stalled one,
// led[2] memory ready, led[3] running, led[4] halted or late, led[5] heartbeat.
module nes #(
    parameter int          CLKS_PER_BIT = 18,       // 27 MHz / 18 = 1.5 Mbaud
    parameter int          IDLE_CLKS    = 270_000,  // 10 ms at 27 MHz
    parameter int          DOT_NUM      = 35,       // PPU dots per DOT_DEN clocks:
    parameter int          DOT_DEN      = 176,      //   5.369318 MHz from 27 MHz
    parameter int          LEAD_DOTS    = 5,
    parameter logic [31:0] BUILD_ID     = '0
) (
    input  logic        clk,
    input  logic        uart_rx,
    output logic        uart_tx,
    output logic [5:0]  led,

    // The board's memory, as memory/sdram's user port.
    output logic        mem_req,
    output logic        mem_we,
    output logic [22:0] mem_addr,
    output logic [7:0]  mem_wdata,
    input  logic        mem_ack,
    input  logic [7:0]  mem_rdata,
    input  logic        mem_ready
);
    logic rst;
    por u_por (.clk, .rst);

    // ---- Test shell, and the save-state controller ----
    // Both master the system's bus (s_*); the controller takes it for a
    // command's walk once the shell has no access in flight, and the shell's
    // next access waits until the walk is done.
    logic [31:0] t_addr, s_addr;
    logic        t_req, t_we, t_ack, s_req, s_we, s_ack;
    logic [7:0]  t_wdata, t_rdata, s_wdata, s_rdata;
    logic        crc_error, timeout;

    test_shell #(.CLKS_PER_BIT(CLKS_PER_BIT), .IDLE_CLKS(IDLE_CLKS), .BUILD_ID(BUILD_ID)) u_shell (
        .clk, .rst, .uart_rx, .uart_tx,
        .bus_addr(t_addr), .bus_req(t_req), .bus_we(t_we), .bus_wdata(t_wdata),
        .bus_ack(t_ack), .bus_rdata(t_rdata),
        .crc_error, .timeout);

    // The regions a save state walks, in order: the CPU's, PPU's and system's
    // state words, RAM, PRG RAM, CHR and the nametable RAM. 20,920 bytes.
    localparam int SS_REGIONS = 7;
    localparam logic [SS_REGIONS*32-1:0] SS_BASES = {
        32'h03004000, 32'h03000000, 32'h02006000, 32'h02000000, 32'h04002000, 32'h04001000, 32'h04000000};
    localparam logic [SS_REGIONS*32-1:0] SS_LENS = {
        32'd2048, 32'd8192, 32'd8192, 32'd2048, 32'd20, 32'd404, 32'd16};

    logic [7:0]  ss_cmd, ss_done, ss_hq;
    logic        ss_busy, ss_hold_req, ss_hold_frame, ss_ready, ss_own;
    logic        b_req, b_we, b_ack;
    logic [31:0] b_addr;
    logic [7:0]  b_wdata;
    wire         sel_ssbuf;
    wire         ss_hwe;

    save_state_ctrl #(.NREG(SS_REGIONS), .BASES(SS_BASES), .LENS(SS_LENS), .AW(15)) u_ss (
        .clk, .rst,
        .cmd(ss_cmd), .done(ss_done), .busy(ss_busy),
        .hold(ss_hold_req), .hold_frame(ss_hold_frame), .ready(ss_ready),
        .b_req, .b_we, .b_addr, .b_wdata, .b_ack, .b_rdata(s_rdata),
        .h_addr(s_addr[14:0]), .h_we(ss_hwe), .h_wdata(s_wdata), .h_rdata(ss_hq));

    always_ff @(posedge clk)
        ss_own <= !rst && ss_busy && (ss_own || !t_req);

    assign s_addr  = ss_own ? b_addr : t_addr;
    assign s_req   = ss_own ? b_req : t_req;
    assign s_we    = ss_own ? b_we : t_we;
    assign s_wdata = ss_own ? b_wdata : t_wdata;
    assign b_ack   = ss_own && s_ack;
    assign t_ack   = !ss_own && s_ack;
    assign t_rdata = s_rdata;

    wire s_new     = s_req && !s_ack;
    wire sel_sdram = s_addr[31:23] == 9'h000;
    wire sel_reg   = s_addr[31:24] == 8'h01;
    wire sel_mem   = s_addr[31:24] == 8'h02;
    wire sel_vram  = s_addr[31:24] == 8'h03;
    wire sel_state = s_addr[31:24] == 8'h04;
    wire sel_probe = s_addr[31:24] == 8'h05;
    assign sel_ssbuf = s_addr[31:24] == 8'h06;

    // ---- Control registers ----
    logic        ctrl_run, ctrl_reset, mirror_v, chr_ram;
    logic [22:0] prg_mask;
    logic [15:0] vec;
    logic        vec_en;
    logic [31:0] stop_at, stop_frame, cycles, frames;
    logic        stopped, late;
    logic [31:0] trace_crc;
    logic        cap_en;
    logic [31:0] cap_frame;
    logic [7:0]  cap_line;

    // ---- Clock enables ----
    // dot_slot, then v_hold: the two clocks before a dot, when the PPU has its
    // video memory: it reads on dot_slot and the data holds through the dot,
    // so the PPU's next-dot logic gets a clock to settle on it.
    // ppu_ce: the dot. reg_ce: the PPU register access, the clock after the
    // CPU cycle's second dot. ce (state C_END): the CPU cycle's end, the clock
    // after its third dot. C_START: the next cycle's first clock, or the
    // clocks it waits while the system is stopped.
    typedef enum logic [1:0] {C_LEAD, C_START, C_RUN, C_END} cstate_t;

    cstate_t    cs;
    logic       go, sys_rst, halted, cap_held, ss_hold;
    logic       dot_slot, v_hold, ppu_ce, reg_ce, ce, cyc_start;
    logic [1:0] dn;    // dots so far in this CPU cycle
    logic [2:0] lead;

    // Stops are levels, so raising a limit runs on from where it stopped.
    assign stopped   = (stop_at != '0 && cycles >= stop_at) || (stop_frame != '0 && frames >= stop_frame);
    assign sys_rst   = rst || ctrl_reset;
    assign go        = ctrl_run && !ctrl_reset && !stopped && mem_ready && !cap_held && !ss_hold;
    assign cyc_start = cs == C_START && go;
    assign ce        = cs == C_END;

    clock_enable #(.NUM(DOT_NUM), .DEN(DOT_DEN)) u_dot (
        .clk, .rst(sys_rst), .en(cs == C_RUN || cs == C_END || go), .ce(dot_slot));

    logic        st_we_cpu, st_we_ppu, st_we_sys;  // save-state writes, below
    logic [2:0]  st_sys_w;
    logic [31:0] st_wdata;

    always_ff @(posedge clk) begin
        v_hold <= dot_slot;
        ppu_ce <= v_hold;
        reg_ce <= ppu_ce && cs == C_RUN && dn == 2'd1;
        case (cs)
            C_LEAD:
                if (ppu_ce) begin
                    lead <= lead - 3'd1;
                    if (lead == 3'd1)
                        cs <= C_START;
                end
            C_START:
                if (go) begin
                    cs <= C_RUN;
                    dn <= '0;
                end
            C_RUN:
                if (ppu_ce) begin
                    dn <= dn + 2'd1;
                    if (dn == 2'd2)
                        cs <= C_END;
                end
            default:
                cs <= C_START;
        endcase
        if (st_we_sys && st_sys_w == 3'd4) begin
            cs   <= cstate_t'(st_wdata[5:4]);
            lead <= st_wdata[8:6];
        end
        if (sys_rst) begin
            v_hold <= 1'b0;
            ppu_ce <= 1'b0;
            reg_ce <= 1'b0;
            cs     <= LEAD_DOTS == 0 ? C_START : C_LEAD;
            lead   <= 3'(LEAD_DOTS);
            dn     <= '0;
        end
    end

    // ---- CPU ----
    logic [15:0] cpu_addr;
    logic        cpu_we, cpu_sync, cpu_rdy, nmi_n;
    logic [7:0]  cpu_dout, cpu_din;
    logic [31:0] cpu_st_rdata;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] dbg_pc;
    logic [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p;
    /* verilator lint_on UNUSEDSIGNAL */

    cpu_6502 #(.DECIMAL(0)) u_cpu (
        .clk, .rst(sys_rst), .ce,
        .addr(cpu_addr), .we(cpu_we), .dout(cpu_dout), .din(cpu_din),
        .rdy(cpu_rdy), .irq_n(1'b1), .nmi_n,
        .sync(cpu_sync), .halted,
        .dbg_pc, .dbg_a, .dbg_x, .dbg_y, .dbg_s, .dbg_p,
        .st_addr(s_addr[3:2]), .st_rdata(cpu_st_rdata), .st_we(st_we_cpu), .st_wdata);

    // ---- OAM DMA ----
    // A write to $4014 halts the CPU on its next read cycle, then copies a
    // page to $2004 a byte per two cycles: reads on even cycles (counted from
    // reset), writes on odd, with a dummy cycle to align when needed. The
    // halt and alignment cycles repeat the CPU's read on the bus.
    typedef enum logic [1:0] {D_NONE, D_DUMMY, D_GET, D_PUT} dcyc_t;

    logic        dma_req;       // $4014 written, not yet started
    logic        dma_on;        // the halt cycle is done; transferring
    logic [7:0]  dma_page, dma_idx, dma_data;
    logic        dma_have;      // a byte read, waiting to be written
    dcyc_t       dkind, dkind_q, dk;
    logic [15:0] bus_addr;
    logic        bus_we, bus_sync, dma_cycle;
    logic [7:0]  bus_wdata;

    // A cycle's kind comes from the DMA state at its start, and holds: the
    // CPU's own address doesn't change while it's stalled.
    always_comb begin
        dkind = D_NONE;
        if (dma_on)
            dkind = cycles[0] == 1'b0 ? D_GET : dma_have ? D_PUT : D_DUMMY;
        else if (dma_req && !cpu_we)
            dkind = D_DUMMY;  // the halt cycle
    end

    assign dk        = cs == C_RUN || cs == C_END ? dkind_q : dkind;
    assign dma_cycle = dk != D_NONE;
    assign cpu_rdy   = !dma_cycle;
    assign bus_addr  = dk == D_GET ? {dma_page, dma_idx} : dk == D_PUT ? 16'h2004 : cpu_addr;
    assign bus_we    = dk == D_PUT || (!dma_cycle && cpu_we);
    assign bus_wdata = dk == D_PUT ? dma_data : cpu_dout;
    assign bus_sync  = !dma_cycle && cpu_sync;

    always_ff @(posedge clk) begin
        if (cyc_start)
            dkind_q <= dkind;
        if (ce) begin
            case (dkind_q)
                D_GET: begin
                    dma_data <= cpu_din;
                    dma_have <= 1'b1;
                end
                D_PUT: begin
                    dma_have <= 1'b0;
                    dma_idx  <= dma_idx + 8'd1;
                    if (dma_idx == 8'hFF)
                        dma_on <= 1'b0;
                end
                D_DUMMY:
                    if (!dma_on) begin
                        dma_req <= 1'b0;  // the halt cycle: transfer from the next
                        dma_on  <= 1'b1;
                    end
                default: ;
            endcase
            if (bus_we && bus_addr == 16'h4014) begin
                dma_req  <= 1'b1;
                dma_page <= bus_wdata;
                dma_idx  <= '0;
                dma_have <= 1'b0;
            end
        end
        if (st_we_sys && st_sys_w == 3'd3)
            {dma_page, dma_idx, dma_data} <= st_wdata[31:8];
        if (st_we_sys && st_sys_w == 3'd4)
            {dma_have, dma_on, dma_req} <= st_wdata[2:0];
        if (sys_rst) begin
            dma_req  <= 1'b0;
            dma_on   <= 1'b0;
            dma_have <= 1'b0;
            dkind_q  <= D_NONE;
        end
    end

    // CPU-bus decode.
    wire c_ram  = bus_addr[15:13] == 3'b000;  // $0000-$1FFF, 2 KB mirrored
    wire c_ppu  = bus_addr[15:13] == 3'b001;  // $2000-$3FFF, 8 registers mirrored
    wire c_wram = bus_addr[15:13] == 3'b011;  // $6000-$7FFF
    wire c_prg  = bus_addr[15];               // $8000-$FFFF
    wire c_vec  = vec_en && bus_addr[15:1] == 15'h7FFE;

    // ---- PPU ----
    logic [13:0] vaddr;
    logic        vwe;
    logic [7:0]  vwdata, vrdata, ppu_rdata;
    logic        pix_valid, frame_end;
    logic [8:0]  pix;
    logic [7:0]  pix_x, pix_y;
    logic [31:0] ppu_st_rdata;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [8:0]  ppu_line, ppu_dot;
    /* verilator lint_on UNUSEDSIGNAL */

    ppu_2c02 u_ppu (
        .clk, .rst(sys_rst), .ce(ppu_ce),
        .reg_ce(reg_ce && c_ppu), .reg_we(bus_we), .reg_addr(bus_addr[2:0]), .reg_wdata(bus_wdata),
        .reg_rdata(ppu_rdata), .nmi_n,
        .vaddr, .vwe, .vwdata, .vrdata,
        .pix_valid, .pix, .pix_x, .pix_y, .frame_end,
        .dbg_line(ppu_line), .dbg_dot(ppu_dot),
        .st_addr(s_addr[8:2]), .st_rdata(ppu_st_rdata), .st_we(st_we_ppu), .st_wdata);

    // ---- CHR and nametables, shared with the shell ----
    // The PPU has the port on each dot_slot and v_hold clock, reading on both
    // so the data holds, and writing on dot_slot; the shell has the others.
    logic [7:0]  chr[8192];
    logic [7:0]  ciram[2048];
    logic [7:0]  chr_q, ciram_q, sh_v_data;
    logic [13:0] va;
    logic        va_we, va_ci_q;
    logic [7:0]  va_wdata;
    logic        sh_v_issue, sh_v_wait, sh_v_ack;

    assign sh_v_issue = !dot_slot && !v_hold && s_new && sel_vram && !sh_v_wait && !sh_v_ack;

    logic va_raw;  // the shell's view of the nametable RAM as it is, unmirrored

    always_comb
        if (dot_slot || v_hold) begin
            va       = vaddr;
            va_raw   = 1'b0;
            va_we    = dot_slot && vwe && (vaddr[13] || chr_ram);
            va_wdata = vwdata;
        end else begin
            va       = s_addr[13:0];
            va_raw   = s_addr[14];
            va_we    = sh_v_issue && s_we;
            va_wdata = s_wdata;
        end

    wire        va_ci = va[13] || va_raw;
    wire [10:0] ci_a  = va_raw ? va[10:0] : {mirror_v ? va[10] : va[11], va[9:0]};

    always_ff @(posedge clk) begin
        if (va_we && !va_ci)
            chr[va[12:0]] <= va_wdata;
        if (va_we && va_ci)
            ciram[ci_a] <= va_wdata;
        chr_q   <= chr[va[12:0]];
        ciram_q <= ciram[ci_a];
        va_ci_q <= va_ci;
    end

    assign vrdata = va_ci_q ? ciram_q : chr_q;

    always_ff @(posedge clk) begin
        sh_v_ack <= 1'b0;
        if (sh_v_issue)
            sh_v_wait <= 1'b1;
        // The shell's read is in chr_q/ciram_q for one clock only: hold it.
        if (sh_v_wait) begin
            sh_v_wait <= 1'b0;
            sh_v_ack  <= 1'b1;
            sh_v_data <= vrdata;
        end
        if (rst) begin
            sh_v_wait <= 1'b0;
            sh_v_ack  <= 1'b0;
        end
    end

    // ---- The board's memory: the CPU's PRG reads first, then the shell ----
    logic        cpu_sd_pend;   // this cycle's PRG read is waiting for memory
    logic [7:0]  cpu_sd_data;
    logic        sh_sd_ack;     // the shell's access is done: acknowledge it a clock later
    logic [7:0]  sd_rdata_q;    // with its read data, held
    logic [14:0] prg_a;
    logic [1:0]  a_ack;
    logic [7:0]  a_rdata;

    mem_arbiter #(.N(2), .AW(23)) u_arb (
        .clk, .rst,
        .c_req({s_new && sel_sdram, cpu_sd_pend}), .c_we({s_we, 1'b0}),
        .c_addr({s_addr[22:0], {8'b0, prg_a} & prg_mask}), .c_wdata({s_wdata, 8'h00}),
        .c_ack(a_ack), .c_rdata(a_rdata),
        .m_req(mem_req), .m_we(mem_we), .m_addr(mem_addr), .m_wdata(mem_wdata),
        .m_ack(mem_ack), .m_rdata(mem_rdata));

    always_ff @(posedge clk) begin
        sh_sd_ack <= a_ack[1];
        if (a_ack[1])
            sd_rdata_q <= a_rdata;
        if (cyc_start && !bus_we && c_prg && !c_vec) begin
            cpu_sd_pend <= 1'b1;
            prg_a       <= bus_addr[14:0];
        end
        if (a_ack[0]) begin
            cpu_sd_data <= a_rdata;
            cpu_sd_pend <= 1'b0;
        end
        if (rst) begin
            sh_sd_ack   <= 1'b0;
            cpu_sd_pend <= 1'b0;
        end
    end

    // ---- RAM and PRG RAM, shared with the shell ----
    // The CPU uses the port on its cycle's first clock (read) and last (write);
    // the shell gets the other clocks.
    logic [7:0] ram[2048];
    logic [7:0] wram[8192];
    logic [7:0] ram_q, wram_q, cpu_mem_data;
    logic [12:0] m_addr;
    logic       m_ram, m_wram, m_we;
    logic [7:0] m_wdata;
    logic       cpu_slot, cpu_rd_q, sh_m_issue, sh_m_wait, sh_m_ack, sh_m_wram, sh_m_mapped;
    logic [7:0] sh_m_data;

    assign cpu_slot   = cyc_start || ce;
    assign sh_m_issue = !cpu_slot && s_new && sel_mem && !sh_m_wait && !sh_m_ack;

    always_comb begin
        m_we    = 1'b0;
        m_wdata = bus_wdata;
        if (cpu_slot) begin
            m_addr = bus_addr[12:0];
            m_ram  = c_ram;
            m_wram = c_wram;
            m_we   = ce && bus_we;
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
        cpu_rd_q <= cyc_start;
        if (cpu_rd_q)
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
            cpu_din = bus_addr[0] ? vec[15:8] : vec[7:0];
        else if (c_prg)
            cpu_din = cpu_sd_data;
        else if (c_ram || c_wram)
            cpu_din = cpu_mem_data;
        else if (c_ppu)
            cpu_din = ppu_rdata;
        else
            cpu_din = open_bus;  // APU and I/O registers, and $4020-$5FFF, until they exist

    // Each CPU cycle goes into the trace CRC as 4 bytes: address low, address
    // high, data (read or written), flags (bit 0 write, bit 1 opcode fetch).
    logic [31:0] tr;
    logic [2:0]  tr_n;

    crc32 u_trace (.clk, .rst(sys_rst), .en(tr_n != '0), .data(tr[7:0]), .crc(trace_crc),
                   .st_we(st_we_sys && st_sys_w == 3'd2), .st_wdata);

    always_ff @(posedge clk) begin
        if (tr_n != '0) begin
            tr   <= tr >> 8;
            tr_n <= tr_n - 1'b1;
        end
        if (ce) begin
            open_bus <= bus_we ? bus_wdata : cpu_din;
            tr       <= {6'b0, bus_sync, bus_we, bus_we ? bus_wdata : cpu_din, bus_addr};
            tr_n     <= 3'd4;
            cycles   <= cycles + 1'b1;
            if (cpu_sd_pend)
                late <= 1'b1;
        end
        if (frame_end)
            frames <= frames + 1'b1;
        if (st_we_sys)
            case (st_sys_w)
                3'd0: cycles   <= st_wdata;
                3'd1: frames   <= st_wdata;
                3'd3: open_bus <= st_wdata[7:0];
                3'd4: late     <= st_wdata[3];
                default: ;
            endcase
        if (sys_rst) begin
            tr_n     <= '0;
            cycles   <= '0;
            frames   <= '0;
            late     <= 1'b0;
            open_bus <= '0;
        end
    end

    // ---- Video probe ----
    logic [31:0] frame_crc, crc_frame, line_rdata;
    logic        crc_valid;
    logic [15:0] buf_rdata;

    video_probe u_probe (
        .clk, .rst(sys_rst),
        .pix_valid, .pix({7'b0, pix}), .pix_x, .pix_y, .frame(frames),
        .frame_crc, .crc_frame, .crc_valid,
        .line_raddr(s_addr[9:2]), .line_rdata,
        .cap_en, .cap_frame, .cap_line, .cap_held,
        .buf_raddr(s_addr[8:1]), .buf_rdata);

    // ---- Save state, probe and save-state buffer reads: registered, so three clocks ----
    // A state word goes through a register of its own before its byte is
    // picked: the PPU's word is a wide mux, and this keeps it off 50 MHz's
    // critical path.
    // A state word is written when its byte 3 is: bytes 0-2 go to a staging
    // word first. Writes count only while the system is held in reset or
    // stopped between cycles; the system's own words only out of reset.
    //
    // The system's own state words (0x04002000):
    //   0 CPU cycles, 1 frames, 2 the trace CRC,
    //   3 {DMA page, DMA index, DMA byte, open bus},
    //   4 {lead dots [8:6], cycle state [5:4], late, DMA byte held, DMA on, DMA requested}.
    // Pipelines that drain within a few clocks of a stop (the trace CRC's
    // bytes) have drained before a save state's walk starts.
    logic [23:0] st_stage;
    logic [1:0]  sp_wait;
    logic [7:0]  sp_q;
    logic        sp_ack;
    logic [31:0] sys_st, st_q;
    wire         sp_issue = s_new && (sel_state || sel_probe || sel_ssbuf) && sp_wait == '0 && !sp_ack;
    wire         paused   = ctrl_reset || ((cs == C_START || cs == C_LEAD) && !go);
    wire  [1:0]  st_sel   = s_addr[13:12];  // CPU, PPU, the system's
    wire         st_commit = sp_issue && sel_state && s_we && paused && s_addr[1:0] == 2'd3;

    assign st_wdata  = {s_wdata, st_stage};
    assign st_we_cpu = st_commit && st_sel == 2'd0 && s_addr[11:4] == '0;
    assign st_we_ppu = st_commit && st_sel == 2'd1 && s_addr[11:9] == '0;
    assign st_we_sys = st_commit && st_sel == 2'd2 && s_addr[11:5] == '0 && s_addr[4:2] <= 3'd4;
    assign st_sys_w  = s_addr[4:2];
    assign ss_hwe    = sp_issue && sel_ssbuf && s_we && !ss_busy;

    always_comb
        case (s_addr[4:2])
            3'd0:    sys_st = cycles;
            3'd1:    sys_st = frames;
            3'd2:    sys_st = trace_crc;
            3'd3:    sys_st = {dma_page, dma_idx, dma_data, open_bus};
            3'd4:    sys_st = {23'b0, lead, cs, late, dma_have, dma_on, dma_req};
            default: sys_st = '0;
        endcase

    // A save state stops the system at its next frame boundary, or where it
    // stands if it's already stopped; a load stops it at once.
    always_ff @(posedge clk)
        if (rst || !ss_hold_req)
            ss_hold <= 1'b0;
        else if (!ss_hold_frame || frame_end || paused)
            ss_hold <= 1'b1;

    assign ss_ready = ss_hold && paused && !ctrl_reset && tr_n == '0;

    always_ff @(posedge clk) begin
        sp_ack <= sp_wait == 2'd1 && !rst;
        if (sp_issue)
            sp_wait <= 2'd3;
        else if (sp_wait != '0)
            sp_wait <= sp_wait - 2'd1;
        if (sp_issue && sel_state && s_we)
            case (s_addr[1:0])
                2'd0: st_stage[7:0]   <= s_wdata;
                2'd1: st_stage[15:8]  <= s_wdata;
                2'd2: st_stage[23:16] <= s_wdata;
                default: ;
            endcase
        if (sp_wait == 2'd2)
            case (st_sel)
                2'd0:    st_q <= s_addr[11:4] == '0 ? cpu_st_rdata : '0;
                2'd1:    st_q <= s_addr[11:9] == '0 ? ppu_st_rdata : '0;
                2'd2:    st_q <= s_addr[11:5] == '0 ? sys_st : '0;
                default: st_q <= '0;
            endcase
        if (sp_wait == 2'd1) begin
            if (sel_ssbuf)
                sp_q <= s_addr[23:15] == '0 ? ss_hq : '0;
            else if (sel_state)
                sp_q <= st_q[8*s_addr[1:0] +: 8];
            else if (!s_addr[12])
                sp_q <= s_addr[11:10] == '0 ? line_rdata[8*s_addr[1:0] +: 8] : '0;
            else
                sp_q <= s_addr[11:9] == '0 ? buf_rdata[8*s_addr[0] +: 8] : '0;
        end
        if (rst) begin
            sp_wait <= '0;
            sp_ack  <= 1'b0;
        end
    end

    // ---- Register file ----
    logic       reg_ack;
    logic [7:0] reg_q;
    wire  [7:0] r = s_addr[7:0];
    wire        running = go || cs == C_RUN || cs == C_END;

    always_ff @(posedge clk) begin
        reg_ack <= s_new && sel_reg && !reg_ack;
        if (s_new && sel_reg && s_we && !reg_ack)
            case (r)
                8'h00: {ctrl_reset, ctrl_run} <= s_wdata[1:0];
                8'h04: prg_mask[7:0]     <= s_wdata;
                8'h05: prg_mask[15:8]    <= s_wdata;
                8'h06: prg_mask[22:16]   <= s_wdata[6:0];
                8'h08: vec[7:0]          <= s_wdata;
                8'h09: vec[15:8]         <= s_wdata;
                8'h0A: vec_en            <= s_wdata[0];
                8'h0C: stop_at[7:0]      <= s_wdata;
                8'h0D: stop_at[15:8]     <= s_wdata;
                8'h0E: stop_at[23:16]    <= s_wdata;
                8'h0F: stop_at[31:24]    <= s_wdata;
                8'h1C: stop_frame[7:0]   <= s_wdata;
                8'h1D: stop_frame[15:8]  <= s_wdata;
                8'h1E: stop_frame[23:16] <= s_wdata;
                8'h1F: stop_frame[31:24] <= s_wdata;
                8'h2C: {chr_ram, mirror_v} <= s_wdata[1:0];
                8'h30: cap_frame[7:0]    <= s_wdata;
                8'h31: cap_frame[15:8]   <= s_wdata;
                8'h32: cap_frame[23:16]  <= s_wdata;
                8'h33: cap_frame[31:24]  <= s_wdata;
                8'h34: cap_line          <= s_wdata;
                8'h35: cap_en            <= s_wdata[0];
                8'h38: ss_cmd            <= s_wdata;
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
            8'h18:   reg_q <= {2'b0, crc_valid, cap_held, running, late, stopped, halted};
            8'h1C:   reg_q <= stop_frame[7:0];
            8'h1D:   reg_q <= stop_frame[15:8];
            8'h1E:   reg_q <= stop_frame[23:16];
            8'h1F:   reg_q <= stop_frame[31:24];
            8'h20:   reg_q <= frames[7:0];
            8'h21:   reg_q <= frames[15:8];
            8'h22:   reg_q <= frames[23:16];
            8'h23:   reg_q <= frames[31:24];
            8'h24:   reg_q <= frame_crc[7:0];
            8'h25:   reg_q <= frame_crc[15:8];
            8'h26:   reg_q <= frame_crc[23:16];
            8'h27:   reg_q <= frame_crc[31:24];
            8'h28:   reg_q <= crc_frame[7:0];
            8'h29:   reg_q <= crc_frame[15:8];
            8'h2A:   reg_q <= crc_frame[23:16];
            8'h2B:   reg_q <= crc_frame[31:24];
            8'h2C:   reg_q <= {6'b0, chr_ram, mirror_v};
            8'h30:   reg_q <= cap_frame[7:0];
            8'h31:   reg_q <= cap_frame[15:8];
            8'h32:   reg_q <= cap_frame[23:16];
            8'h33:   reg_q <= cap_frame[31:24];
            8'h34:   reg_q <= cap_line;
            8'h35:   reg_q <= {7'b0, cap_en};
            8'h38:   reg_q <= ss_cmd;
            8'h39:   reg_q <= ss_done;
            default: reg_q <= '0;
        endcase
        if (rst) begin
            reg_ack    <= 1'b0;
            ctrl_reset <= 1'b1;
            ctrl_run   <= 1'b0;
            prg_mask   <= 23'h7FFF;
            vec_en     <= 1'b0;
            stop_at    <= '0;
            stop_frame <= '0;
            mirror_v   <= 1'b0;
            chr_ram    <= 1'b0;
            cap_en     <= 1'b0;
            ss_cmd     <= '0;
        end
    end

    // Accesses outside the map are acknowledged at once: writes vanish, reads give 0.
    logic       none_ack;

    always_ff @(posedge clk)
        none_ack <= s_new && !(sel_sdram || sel_reg || sel_mem || sel_vram || sel_state || sel_probe || sel_ssbuf)
                    && !none_ack && !rst;

    assign s_ack = sh_sd_ack || sh_m_ack || sh_v_ack || sp_ack || reg_ack || none_ack;
    always_comb
        if (sh_sd_ack)
            s_rdata = sd_rdata_q;
        else if (sh_m_ack)
            s_rdata = sh_m_data;
        else if (sh_v_ack)
            s_rdata = sh_v_data;
        else if (sp_ack)
            s_rdata = sp_q;
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

    assign led = ~{beat[24], halted || late, running, mem_ready, saw_timeout, saw_crc_error};
endmodule
