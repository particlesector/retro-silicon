// SPDX-License-Identifier: Apache-2.0
// The Game Boy (DMG): the SM83 (`cpu/sm83`) on the console's memory map, with
// the boot ROM, video RAM, work RAM, OAM, high RAM, the timer, the serial
// port, the joypad, OAM DMA and the interrupt registers; the cartridge is
// outside, and the picture comes out a pixel at a time (`pix_*`) from the PPU
// (`gb_ppu`). The sound (`gb_apu_regs`) is, until G5, its registers only.
//
// One T-cycle per `ce` (4.194304 MHz on the console); an M-cycle is 4. `ce`
// must come at least 2 clocks apart: a read's data is taken registered, a
// clock before the M-cycle's last T-cycle ends, so it is what the read's
// address held during that T-cycle. The CPU's writes land as the M-cycle
// ends, with everything else that changes on M-cycles.
//
// Memory map: $0000-$00FF the boot ROM until a write to $FF50 (`boot_*`
// loads it), $0000-$7FFF and $A000-$BFFF the cartridge, $8000-$9FFF video
// RAM, $C000-$DFFF work RAM (echoed at $E000-$FDFF), $FE00-$FE9F OAM
// ($FEA0-$FEFF read 0), $FF00-$FF7F I/O, $FF80-$FFFE high RAM, $FFFF IE.
// Unused I/O reads $FF.
//
// The cartridge and work RAM share the external bus, video RAM has its own.
// The PPU reads video RAM and OAM through ports of their own, and blocks the
// CPU's accesses to them in its busy modes (video RAM reads $FF, OAM $FF).
// OAM DMA (a write to $FF46) starts after one M-cycle and copies 160 bytes
// from $XX00, one an M-cycle ($E000 and above from work RAM); while it runs,
// the CPU reads OAM as $FF and can't write it, and a CPU access on the bus
// the DMA reads from gets the DMA's byte (a read) or is lost (a write). A
// write to $FF46 during a DMA restarts it.
//
// The cartridge sees `cart_addr` (the DMA's address while it reads there),
// and must have `cart_rdata` there a clock before the M-cycle's last T-cycle
// ends; `cart_wr` is a write landing at this clock.
module gameboy (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,          // one T-cycle

    output logic [15:0] cart_addr,
    output logic        cart_rd,     // this M-cycle reads the cartridge
    output logic        cart_wr,     // write cart_wdata at cart_addr at this clock
    output logic [7:0]  cart_wdata,
    input  logic [7:0]  cart_rdata,

    input  logic        boot_we,     // write the boot ROM
    input  logic [7:0]  boot_addr,
    input  logic [7:0]  boot_wdata,

    input  logic [7:0]  keys,        // 1 pressed: Start, Select, B, A, down, up, left, right (bit 7 to 0)

    output logic [7:0]  ser_tx,      // a serial transfer of this byte starts
    output logic        ser_tx_valid,

    output logic        m_end,       // the clock that ends an M-cycle
    output logic        cpu_sync,    // this M-cycle fetches an opcode
    output logic [15:0] cpu_pc,
    output logic        boot_on,     // the boot ROM is mapped
    output logic [7:0]  lcdc,

    output logic        pix_we,      // a pixel at (pix_x, pix_y), shade 0 (white) to 3
    output logic [7:0]  pix_x,
    output logic [7:0]  pix_y,
    output logic [1:0]  pix_shade,
    output logic        frame_end    // VBlank starts: the frame is out
);
    // ---- T-cycles and M-cycles ----
    logic [1:0] phase;
    wire        m = ce && phase == 2'd3;
    assign m_end = m;
    always_ff @(posedge clk)
        if (rst) phase <= '0;
        else if (ce) phase <= phase + 2'd1;

    // ---- the CPU ----
    logic [15:0] a;
    logic        rd, wr, stop_pulse;
    logic [7:0]  dout, din;
    logic [4:0]  int_ack;
    logic [7:0]  ie;
    logic [4:0]  if_r, int_seen;
    logic        joy_low;
    logic        irq_timer, irq_serial, irq_joy, irq_vblank, irq_stat;

    /* verilator lint_off UNUSEDSIGNAL */
    logic        cpu_halted;
    logic        cpu_stopped, cpu_locked, cpu_ime, cpu_ei, cpu_boundary;
    logic [15:0] cpu_sp, cpu_af, cpu_bc, cpu_de, cpu_hl;
    logic [31:0] cpu_st;
    /* verilator lint_on UNUSEDSIGNAL */
    cpu_sm83 #(.SAVE_STATE(1'b0)) cpu (
        .clk, .rst, .ce(m),
        .addr(a), .rd, .wr, .dout, .din,
        .int_req(ie[4:0] & int_seen), .int_ack, .stop_exit(joy_low),
        .sync(cpu_sync), .halted(cpu_halted), .stopped(cpu_stopped), .stop_pulse, .locked(cpu_locked),
        .dbg_pc(cpu_pc), .dbg_sp(cpu_sp), .dbg_af(cpu_af), .dbg_bc(cpu_bc), .dbg_de(cpu_de), .dbg_hl(cpu_hl),
        .dbg_ime(cpu_ime), .dbg_ei(cpu_ei), .dbg_boundary(cpu_boundary),
        .st_addr(2'd0), .st_rdata(cpu_st), .st_we(1'b0), .st_wdata(32'd0)
    );

    // ---- OAM DMA ----
    logic       dma_on, dma_ext, dma_vram;  // copying, from the external bus, from video RAM
    logic [7:0] dma_reg, dma_hi, dma_idx;
    logic       dma_start;                  // this M-cycle is a (re)start's setup: the copy starts after it
    logic [7:0] dma_next;                   // its source page
    wire [15:0] dma_addr = {dma_hi[7:5] == 3'b111 ? {3'b110, dma_hi[4:0]} : dma_hi, dma_idx};
    assign dma_vram = dma_on && dma_hi[7:5] == 3'b100;
    assign dma_ext  = dma_on && !dma_vram;

    // ---- address decode ----
    typedef enum logic [3:0] { R_BOOT, R_CART, R_VRAM, R_WRAM, R_OAM, R_NONE, R_IO, R_HRAM, R_IE } region_t;
    region_t reg_a;
    always_comb begin
        if (boot_on && a[15:8] == 8'h00) reg_a = R_BOOT;
        else if (!a[15]) reg_a = R_CART;
        else if (a[15:13] == 3'b100) reg_a = R_VRAM;
        else if (a[15:13] == 3'b101) reg_a = R_CART;
        else if (a < 16'hFE00) reg_a = R_WRAM;
        else if (a < 16'hFEA0) reg_a = R_OAM;
        else if (a < 16'hFF00) reg_a = R_NONE;
        else if (a < 16'hFF80) reg_a = R_IO;
        else if (a != 16'hFFFF) reg_a = R_HRAM;
        else reg_a = R_IE;
    end
    wire on_ext   = reg_a == R_CART || reg_a == R_WRAM;
    wire conflict = on_ext && dma_ext || reg_a == R_VRAM && dma_vram;
    wire oam_busy = dma_on;
    wire cpu_wr   = m && wr && !conflict;
    wire io_wr    = cpu_wr && reg_a == R_IO;

    // ---- the external bus: the cartridge and work RAM ----
    wire [15:0] ext_addr = dma_ext ? dma_addr : a;
    wire        ext_wram = ext_addr[15:14] == 2'b11;
    assign cart_addr  = ext_addr;
    assign cart_rd    = dma_ext ? !ext_wram : rd && reg_a == R_CART;
    assign cart_wr    = cpu_wr && reg_a == R_CART;
    assign cart_wdata = dout;

    logic [7:0] wram [0:8191];
    logic [7:0] wram_q;
    always_ff @(posedge clk) begin
        if (cpu_wr && reg_a == R_WRAM) wram[a[12:0]] <= dout;
        wram_q <= wram[ext_addr[12:0]];
    end
    wire [7:0] ext_q = ext_wram ? wram_q : cart_rdata;

    // ---- video RAM: the CPU's (and DMA's) port, and the PPU's ----
    logic [7:0]  vram [0:8191];
    logic [7:0]  vram_q, ppu_vq;
    logic [12:0] ppu_vaddr;
    logic        vram_rd_blk, vram_wr_blk, oam_rd_blk, oam_wr_blk;
    // The CPU's writes and reads share a port: a write never comes while the DMA reads video RAM
    // (that's a conflict), so its address is vram_a. A write gives its own byte on the port (block
    // RAM's write-first mode, which the Gowin parts' dual-port RAM has), which nothing reads.
    wire [12:0] vram_a = dma_vram ? dma_addr[12:0] : a[12:0];
    always_ff @(posedge clk)
        if (cpu_wr && reg_a == R_VRAM && !vram_wr_blk) begin
            vram[vram_a] <= dout;
            vram_q       <= dout;
        end else
            vram_q <= vram[vram_a];
    always_ff @(posedge clk) ppu_vq <= vram[ppu_vaddr];
    wire [7:0] dma_byte = dma_vram ? vram_q : ext_q;

    // ---- OAM (its even and odd bytes, so the PPU reads 16 bits), high RAM, the boot ROM ----
    logic [7:0]  oam_e [0:79];
    logic [7:0]  oam_o [0:79];
    logic [7:0]  oam_q, hram_q, boot_q;
    logic [15:0] ppu_oq;
    logic [6:0]  ppu_oaddr;
    logic [7:0]  hram [0:127];
    logic [7:0]  boot [0:255];
    wire  [7:0]  oam_wa = dma_on ? dma_idx : a[7:0];
    wire         oam_we = m && dma_on || cpu_wr && reg_a == R_OAM && !oam_busy && !oam_wr_blk;
    wire  [7:0]  oam_wd = dma_on ? dma_byte : dout;
    always_ff @(posedge clk) begin
        if (oam_we && !oam_wa[0]) oam_e[oam_wa[7:1]] <= oam_wd;
        if (oam_we && oam_wa[0])  oam_o[oam_wa[7:1]] <= oam_wd;
        oam_q <= a[7:0] >= 8'd160 ? 8'h00 : a[0] ? oam_o[a[7:1]] : oam_e[a[7:1]];
        ppu_oq <= {oam_o[ppu_oaddr], oam_e[ppu_oaddr]};
        if (cpu_wr && reg_a == R_HRAM) hram[a[6:0]] <= dout;
        hram_q <= hram[a[6:0]];
        if (boot_we) boot[boot_addr] <= boot_wdata;
        boot_q <= boot[a[7:0]];
    end

    // ---- I/O ----
    /* verilator lint_off UNUSEDSIGNAL */
    logic [13:0] counter;    // the system counter's bits 15-2: DIV is bits 13-6
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  tima, tma, tac, sb, sc, p1, lcd_q, apu_q;
    logic        fall7;

    wire  [7:0]  io = a[7:0];
    wire  [7:0]  div = counter[13:6];
    wire  [5:0]  apu_sel = io[5:0] - 6'h10;

    gb_timer timer (
        .clk, .rst, .tick(ce && phase == 2'd2), .m,
        .wr_div(io_wr && io == 8'h04 || m && stop_pulse), .wr_tima(io_wr && io == 8'h05),
        .wr_tma(io_wr && io == 8'h06), .wr_tac(io_wr && io == 8'h07), .wdata(dout),
        .counter, .tima, .tma, .tac, .irq(irq_timer), .fall7
    );
    gb_serial serial (
        .clk, .rst, .m, .fall7,
        .wr_sb(io_wr && io == 8'h01), .wr_sc(io_wr && io == 8'h02), .wdata(dout),
        .sb, .sc, .irq(irq_serial), .tx(ser_tx), .tx_valid(ser_tx_valid)
    );
    gb_joypad joypad (
        .clk, .rst, .m, .wr(io_wr && io == 8'h00), .wsel(dout[5:4]), .keys,
        .p1, .irq(irq_joy), .low(joy_low)
    );
    gb_ppu ppu (
        .clk, .rst, .ce, .phase,
        .wr(wr && !conflict && reg_a == R_IO && io[7:4] == 4'h4), .reg_sel(io[3:0]), .wdata(dout),
        .rdata(lcd_q), .dma_on, .halted(cpu_halted),
        .vaddr(ppu_vaddr), .vq(ppu_vq), .oaddr(ppu_oaddr), .oq(ppu_oq),
        .vram_rd_blk, .vram_wr_blk, .oam_rd_blk, .oam_wr_blk,
        .irq_vblank, .irq_stat,
        .pix_we, .pix_x, .pix_y, .pix_shade, .frame_end, .lcdc
    );
    gb_apu_regs apu (
        .clk, .rst, .m, .wr(io_wr && io >= 8'h10 && io < 8'h40), .reg_sel(apu_sel),
        .wdata(dout), .rdata(apu_q)
    );

    logic [7:0] io_q;
    always_comb begin
        if (io >= 8'h10 && io < 8'h40) io_q = apu_q;
        else if (io == 8'h46) io_q = dma_reg;
        else if (io >= 8'h40 && io < 8'h4C) io_q = lcd_q;
        else case (io)
            8'h00: io_q = p1;
            8'h01: io_q = sb;
            8'h02: io_q = sc;
            8'h04: io_q = div;
            8'h05: io_q = tima;
            8'h06: io_q = tma;
            8'h07: io_q = tac;
            8'h0F: io_q = {3'b111, if_r};
            default: io_q = 8'hFF;
        endcase
    end

    // ---- IF, and the interrupts the CPU sees ----
    // A request sets its bit at the edge that makes it; the CPU's write and
    // a dispatch's acknowledgement land with the M-cycle's end.
    logic [4:0] if_n;
    wire  [4:0] irq_now = {irq_joy, irq_serial, irq_timer, irq_stat, irq_vblank};
    always_comb begin
        if_n = if_r;
        if (m) if_n = io_wr && io == 8'h0F ? dout[4:0] : if_r & ~int_ack;
        if_n = if_n | irq_now;
    end
    // Halted, the CPU sees a request made at an M-cycle's second or third dot
    // an M-cycle later than one made at its first or last (SameBoy's DMG
    // looks two dots into each halted M-cycle), and the M-cycle that sees
    // one is its dispatch's first, or the fetch (`cpu/sm83`).
    logic [4:0] new_mid;  // set at this M-cycle's second or third dot
    always_ff @(posedge clk)
        if (rst) new_mid <= '0;
        else if (ce) begin
            if (phase == 2'd3) new_mid <= '0;
            else if (phase != 2'd0) new_mid <= new_mid | (irq_now & ~if_r);
        end
    assign int_seen = cpu_halted ? if_r & ~new_mid : if_r;

    // ---- interrupts, the boot ROM's switch, DMA ----
    always_ff @(posedge clk) begin
        if (rst) begin
            if_r      <= '0;
            ie        <= '0;
            boot_on   <= 1'b1;
            dma_on    <= 1'b0;
            dma_start <= 1'b0;
            dma_reg   <= 8'hFF;
            dma_hi    <= '0;
            dma_idx   <= '0;
            dma_next  <= '0;
        end else begin
            if (m) begin
                if (cpu_wr && reg_a == R_IE) ie <= dout;
                if (io_wr && io == 8'h50 && dout != 8'h00) boot_on <= 1'b0;

                if (dma_on) begin
                    dma_idx <= dma_idx + 8'd1;
                    if (dma_idx == 8'd159) dma_on <= 1'b0;
                end
                dma_start <= 1'b0;
                if (dma_start) begin
                    dma_on  <= 1'b1;
                    dma_hi  <= dma_next;
                    dma_idx <= '0;
                end
                if (io_wr && io == 8'h46) begin
                    dma_reg   <= dout;
                    dma_next  <= dout;
                    dma_start <= 1'b1;
                end
            end
            if_r <= if_n;
        end
    end

    // ---- the read mux, registered ----
    always_ff @(posedge clk) begin
        if (conflict) din <= dma_byte;
        else case (reg_a)
            R_BOOT: din <= boot_q;
            R_CART, R_WRAM: din <= ext_q;
            R_VRAM: din <= vram_rd_blk ? 8'hFF : vram_q;
            R_OAM:  din <= oam_busy || oam_rd_blk || oam_wr_blk ? 8'hFF : oam_q;
            R_NONE: din <= oam_busy || oam_rd_blk || oam_wr_blk ? 8'hFF : 8'h00;
            R_IO:   din <= io_q;
            R_HRAM: din <= hram_q;
            default: din <= ie;
        endcase
    end
endmodule
