// SPDX-License-Identifier: Apache-2.0
// The Game Boy (DMG): the SM83 (`cpu/sm83`) on the console's memory map, with
// the boot ROM, video RAM, work RAM, OAM, high RAM, the timer, the serial
// port, the joypad, OAM DMA and the interrupt registers; the cartridge is
// outside, and the picture comes out a pixel at a time (`pix_*`) from the PPU
// (`gb_ppu`), and the sound as the APU's (`audio/apu-gb`) two mixes, left and
// right, each M-cycle (`aud_*`).
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
//
// The Game Boy Color (`cgb_hw`, with CGB set; G7): its 2,304-byte boot ROM at $0000-$00FF and $0200-$08FF, which
// sets the Color's own mode or its Game Boy mode with KEY0 ($FF4C) before it unmaps itself; 32 KB
// of work RAM in 8 banks (SVBK, $FF70) and 16 KB of video RAM in 2 (VBK, $FF4F); the colour
// palettes (in gb_ppu); the DMA to video RAM ($FF51-$FF55): a general one, which stops the CPU until
// it's done, or 16 bytes each HBlank, which stops it for each block. A block takes 4 T-cycles to
// set up, then 2 a byte, and starts at an M-cycle's end, so the CPU's next M-cycle waits for it.
// The registers read and write as SameBoy has them (the hardware, where MesenCE differs: Mooneye's
// boot_hwio-C and unused_hwio-C).
//
// Double speed (KEY1, $FF4D, then STOP): the CPU, the timer, the serial port and OAM DMA run an
// M-cycle every 2 T-cycles (`phase` steps by 2), while the PPU, the APU and the DMA to video RAM
// keep their rate (dots). The switch stops the CPU for 33,941 M-cycles at the old speed, DIV held
// at 0, as MesenCE times it, then the speed changes at an M-cycle's end.
//
// With CGB clear the Color isn't built: the memories are the Game Boy's (8 KB of work RAM, one bank
// of video RAM, a 256-byte boot ROM), and `cgb_hw` is ignored.
module gameboy #(
    parameter bit CGB = 1'b1     // build the Game Boy Color too
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,          // one T-cycle
    input  logic        cgb_hw_in,   // the Game Boy Color (steady from reset; with CGB)

    output logic [15:0] cart_addr,
    output logic        cart_rd,     // this M-cycle reads the cartridge
    output logic        cart_wr,     // write cart_wdata at cart_addr at this clock
    output logic [7:0]  cart_wdata,
    input  logic [7:0]  cart_rdata,

    input  logic        boot_we,     // write the boot ROM
    input  logic [11:0] boot_addr,   // ...and in reset, read it here (boot_q, a clock later)
    input  logic [7:0]  boot_wdata,
    output logic [7:0]  boot_q,

    input  logic [7:0]  keys,        // 1 pressed: Start, Select, B, A, down, up, left, right (bit 7 to 0)

    output logic [7:0]  ser_tx,      // a serial transfer of this byte starts
    output logic        ser_tx_valid,

    output logic        m_end,       // the clock that ends an M-cycle
    output logic        m_last,      // the next T-cycle ends an external access: an M-cycle's last, or an HDMA byte's
    output logic        cpu_sync,    // this M-cycle fetches an opcode
    output logic [15:0] cpu_pc,
    output logic        boot_on,     // the boot ROM is mapped
    output logic [7:0]  lcdc,

    output logic        pix_we,      // a pixel at (pix_x, pix_y): the Color's 15-bit colour, or shade 0 (white) to 3
    output logic [7:0]  pix_x,
    output logic [7:0]  pix_y,
    output logic [14:0] pix_color,
    output logic        frame_end,   // VBlank starts: the frame is out

    output logic signed [9:0] aud_l, // the APU's mixes (audio/apu-gb), held from an M-cycle's end
    output logic signed [9:0] aud_r
);
    // ---- T-cycles and M-cycles ----
    wire        cgb_hw = CGB && cgb_hw_in;
    localparam int WRAM_AW = CGB ? 15 : 13;
    localparam int BOOT_AW = CGB ? 12 : 8;
    wire unused_boot = &{1'b0, boot_addr};  // its top bits, without the Color

    logic [1:0] phase;
    wire        m = ce && phase == 2'd3;
    assign m_end = m;

    // ---- the Color's double speed ----
    logic        dbl;          // double speed
    logic        sw_on;        // switching: the CPU waits in STOP
    logic [15:0] sw_cnt;       // ...M-cycles left
    wire         sw_end = sw_on && sw_cnt == 16'd0;
    logic [1:0]  aph;          // the dot in the APU's M-cycle (phase, in single speed)

    // ---- the Color's DMA to video RAM: a block (blk) stops the CPU for its 36 T-cycles ----
    logic        blk, hd_run, hd_pend, hd_trig, gd_act;
    logic [5:0]  blk_cnt;      // the block's T-cycle: 0-3 setup, then byte (n - 4) / 2
    logic [11:0] hd_src;       // the source's bits 15-4
    logic [11:0] hd_dst;       // the destination's bits 15-4 (video RAM takes 12-4)
    logic [6:0]  hd_len;       // blocks left, less 1
    wire  [3:0]  blk_byte = 4'((blk_cnt - 6'd4) >> 1);
    wire         blk_xfer = blk && blk_cnt >= 6'd4;
    wire  [15:0] hd_addr  = {hd_src, blk_byte};
    wire         hd_bad   = hd_addr[15:13] == 3'b100 || hd_addr[15:13] == 3'b111;
    wire         blk_wr   = ce && blk_xfer && blk_cnt[0];  // a byte lands in video RAM
    wire         cm       = m && !blk;                      // an M-cycle the CPU runs
    assign m_last = blk ? blk_xfer && blk_cnt[0] : phase == 2'd3;
    always_ff @(posedge clk)
        if (rst) begin
            phase <= '0;
            aph   <= '0;
        end else if (ce) begin
            // At a switch the new speed's M-cycle starts: 0 1 2 3, or 1 3 in double speed.
            if (m && sw_end) phase <= dbl ? 2'd0 : 2'd1;
            else phase <= dbl ? {~phase[1], 1'b1} : phase + 2'd1;
            aph <= m && sw_end ? 2'd0 : aph + 2'd1;
        end

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
        .clk, .rst, .ce(cm),
        .addr(a), .rd, .wr, .dout, .din,
        .int_req(ie[4:0] & int_seen), .int_ack, .stop_exit(sw_on ? sw_end : joy_low),
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
        if (boot_on && (a[15:8] == 8'h00 || cgb_hw && a[15:12] == 4'h0 && a[11:8] >= 4'h2 && a[11:8] <= 4'h8))
            reg_a = R_BOOT;
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
    wire cpu_wr   = cm && wr && !conflict;
    wire io_wr    = cpu_wr && reg_a == R_IO;
    wire cpu_w    = wr && !blk;          // the CPU writes this M-cycle (it isn't stopped)

    // ---- the Color's registers ----
    logic       cgb_en;      // the Color's own mode: KEY0 written by the boot ROM
    logic       key0_b3;     // KEY0's bit 3 (OPRI stays writable)
    logic       vbk, key1_arm, opri;
    logic [2:0] svbk;
    logic [7:0] r72, r73, r74, r75;
    logic [7:0] rp;
    wire        cgb_pal_ok = cgb_en || boot_on;  // the palettes' data can be written (SameBoy)
    wire  [2:0] wbank = cgb_en && svbk != 3'd0 ? svbk : 3'd1;

    // ---- the external bus: the cartridge and work RAM ----
    // (the Color's DMA to video RAM reads it while a block runs)
    wire [15:0] ext_addr = blk ? hd_addr : dma_ext ? dma_addr : a;
    wire        ext_wram = ext_addr[15:14] == 2'b11;
    assign cart_addr  = ext_addr;
    assign cart_rd    = blk ? blk_xfer && !ext_wram && !hd_bad : dma_ext ? !ext_wram : rd && reg_a == R_CART;
    assign cart_wr    = cpu_wr && reg_a == R_CART;
    assign cart_wdata = dout;

    // 32 KB: $C000-$CFFF bank 0, $D000-$DFFF the bank SVBK picks (1 on the Game Boy)
    logic [7:0] wram [0:(1 << WRAM_AW) - 1];
    logic [7:0] wram_q;
    wire [WRAM_AW-1:0] wram_wa = WRAM_AW'({a[12] ? wbank : 3'd0, a[11:0]});
    wire [WRAM_AW-1:0] wram_ra = WRAM_AW'({ext_addr[12] ? wbank : 3'd0, ext_addr[11:0]});
    always_ff @(posedge clk) begin
        if (cpu_wr && reg_a == R_WRAM) wram[wram_wa] <= dout;
        wram_q <= wram[wram_ra];
    end
    wire [7:0] ext_q = ext_wram ? wram_q : cart_rdata;

    // ---- video RAM, two banks (the Color's): the CPU's (and DMAs') port, and the PPU's, which
    // reads both banks at once ----
    logic [7:0]  vram0 [0:8191];
    logic [7:0]  vram_q0, vram_q1, ppu_vq0, ppu_vq1;
    logic        vbk_q;
    logic [12:0] ppu_vaddr;
    logic        vram_rd_blk, vram_wr_blk, oam_rd_blk, oam_wr_blk;
    // The CPU's writes and reads share a port: a write never comes while the DMA reads video RAM
    // (that's a conflict), so its address is vram_a. A write gives its own byte on the port (block
    // RAM's write-first mode, which the Gowin parts' dual-port RAM has), which nothing reads.
    wire [12:0] vram_a  = blk ? {hd_dst[8:0], blk_byte} : dma_vram ? dma_addr[12:0] : a[12:0];
    wire        vram_we = (cpu_wr && reg_a == R_VRAM || blk_wr) && !vram_wr_blk;
    wire [7:0]  vram_wd = blk ? (hd_bad ? 8'hFF : ext_q) : dout;
    always_ff @(posedge clk) begin
        vbk_q <= vbk;
        if (vram_we && !vbk) begin
            vram0[vram_a] <= vram_wd;
            vram_q0       <= vram_wd;
        end else
            vram_q0 <= vram0[vram_a];
    end
    always_ff @(posedge clk) ppu_vq0 <= vram0[ppu_vaddr];
    if (CGB) begin : g_vram1
        logic [7:0] vram1 [0:8191];
        always_ff @(posedge clk) begin
            if (vram_we && vbk) begin
                vram1[vram_a] <= vram_wd;
                vram_q1       <= vram_wd;
            end else
                vram_q1 <= vram1[vram_a];
            ppu_vq1 <= vram1[ppu_vaddr];
        end
    end else begin : g_no_vram1
        assign vram_q1 = 8'hFF;
        assign ppu_vq1 = 8'h00;
    end
    wire [7:0] vram_q   = vbk_q ? vram_q1 : vram_q0;
    wire [7:0] dma_byte = dma_vram ? vram_q : ext_q;

    // ---- OAM (its even and odd bytes, so the PPU reads 16 bits), high RAM, the boot ROM ----
    logic [7:0]  oam_e [0:79];
    logic [7:0]  oam_o [0:79];
    logic [7:0]  oam_q, hram_q;
    logic [15:0] ppu_oq;
    logic [6:0]  ppu_oaddr;
    logic [7:0]  hram [0:127];
    logic [7:0]  boot [0:(1 << BOOT_AW) - 1];
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
        if (boot_we) boot[boot_addr[BOOT_AW-1:0]] <= boot_wdata;
        boot_q <= boot[rst ? boot_addr[BOOT_AW-1:0] : a[BOOT_AW-1:0]];
    end

    // ---- I/O ----
    /* verilator lint_off UNUSEDSIGNAL */
    logic [13:0] counter;    // the system counter's bits 15-2: DIV is bits 13-6
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  tima, tma, tac, sb, sc, p1, lcd_q, apu_q;
    logic        fall7, fall12, rise12;

    wire  [7:0]  io = a[7:0];
    wire  [7:0]  div = counter[13:6];
    wire  [5:0]  apu_sel = io[5:0] - 6'h10;

    gb_timer timer (
        .clk, .rst, .dbl, .tick(ce && phase == (dbl ? 2'd1 : 2'd2)), .m,
        .wr_div(io_wr && io == 8'h04 || cm && stop_pulse || m && sw_on), .wr_tima(io_wr && io == 8'h05),
        .wr_tma(io_wr && io == 8'h06), .wr_tac(io_wr && io == 8'h07), .wdata(dout),
        .counter, .tima, .tma, .tac, .irq(irq_timer), .fall7, .fall12, .rise12
    );
    gb_serial serial (
        .clk, .rst, .cgb_hw(cgb_en), .m, .fall7,
        .wr_sb(io_wr && io == 8'h01), .wr_sc(io_wr && io == 8'h02), .wdata(dout),
        .sb, .sc, .irq(irq_serial), .tx(ser_tx), .tx_valid(ser_tx_valid)
    );
    gb_joypad joypad (
        .clk, .rst, .m, .wr(io_wr && io == 8'h00), .wsel(dout[5:4]), .keys,
        .p1, .irq(irq_joy), .low(joy_low)
    );
    logic [7:0] pal_q;
    logic [1:0] ppu_mode;
    // The CPU's access to the PPU's registers, registered as the APU's is (below): the address and
    // data are steady from the clock after an M-cycle starts, and the PPU takes a write no sooner
    // than the M-cycle's second T-cycle, so this is exact and keeps the CPU's address decode off the
    // PPU's paths (the PYNQ-Z2's system clock had 1% of margin with it there).
    logic       ppu_wr_q, ppu_pwr_q;
    logic [3:0] ppu_sel_q;
    logic [7:0] ppu_wd_q;
    always_ff @(posedge clk) begin
        ppu_wr_q  <= cpu_w && !conflict && reg_a == R_IO && io[7:4] == 4'h4;
        ppu_pwr_q <= cpu_w && !conflict && reg_a == R_IO && io >= 8'h68 && io <= 8'h6B && cgb_pal_ok && cgb_hw;
        ppu_sel_q <= io[3:0];
        ppu_wd_q  <= dout;
    end
    gb_ppu ppu (
        .clk, .rst, .ce, .phase,
        .wr(ppu_wr_q), .reg_sel(ppu_sel_q), .wdata(ppu_wd_q),
        .rdata(lcd_q), .dma_on, .halted(cpu_halted),
        .cgb_hw, .cgb_en, .obj_x_pri(opri),
        .pwr(ppu_pwr_q),
        .pal_sel(ppu_sel_q[1:0]), .pal_q,
        .vaddr(ppu_vaddr), .vq({ppu_vq1, ppu_vq0}), .oaddr(ppu_oaddr), .oq(ppu_oq),
        .vram_rd_blk, .vram_wr_blk, .oam_rd_blk, .oam_wr_blk,
        .irq_vblank, .irq_stat,
        .pix_we, .pix_x, .pix_y, .pix_color, .frame_end, .mode(ppu_mode), .lcdc
    );
    // The APU's 2 MHz ticks are the M-cycle's first and third T-cycles, so the
    // CPU's reads (in the last) and writes (at its end) come between them. A
    // write's address and data are steady from the clock before it lands (the
    // CPU and the DMA change only on T-cycles, at least 2 clocks apart), so the
    // APU takes them registered, off the CPU's paths.
    logic       apu_wr_q;
    logic [5:0] apu_sel_q;
    logic [7:0] apu_wd_q;
    always_ff @(posedge clk) begin
        apu_wr_q  <= cpu_w && !conflict && reg_a == R_IO && io >= 8'h10 && io < 8'h40;
        apu_sel_q <= apu_sel;
        apu_wd_q  <= dout;
    end
    logic [15:0] apu_levels;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [3:0]  apu_dac;
    logic [7:0]  apu_nr50, apu_nr51;
    /* verilator lint_on UNUSEDSIGNAL */
    apu_gb apu (
        .clk, .rst, .cgb(cgb_hw), .t2(ce && !aph[0]), .fs(fall12), .fs_rise(rise12), .div_b12(dbl ? counter[11] : counter[10]),
        .wr(m && apu_wr_q), .sel(apu_sel_q), .wdata(apu_wd_q), .rsel(apu_sel), .rdata(apu_q),
        .levels(apu_levels), .dac(apu_dac), .nr50(apu_nr50), .nr51(apu_nr51), .mix_l(aud_l), .mix_r(aud_r)
    );

    logic [7:0] io_q;
    always_comb begin
        if (io >= 8'h10 && io < 8'h40) io_q = apu_q;
        else if (io == 8'h46) io_q = dma_reg;
        else if (io >= 8'h40 && io < 8'h4C) io_q = lcd_q;
        else if (cgb_hw && io >= 8'h4C) case (io)
            // the Color's, as SameBoy reads them (its CGB-E)
            8'h4D: io_q = cgb_en ? {dbl, 6'h3F, key1_arm} : 8'hFF;
            8'h4F: io_q = {7'h7F, vbk};
            8'h55: io_q = cgb_en ? {!hd_run, hd_len} : 8'hFF;
            8'h56: io_q = cgb_en ? (rp & 8'hC1) | 8'h2E : 8'hFF;
            8'h68, 8'h6A: io_q = pal_q;
            8'h69, 8'h6B: io_q = cgb_pal_ok ? pal_q : 8'hFF;
            8'h6C: io_q = {7'h7F, opri};
            8'h70: io_q = cgb_en ? {5'h1F, svbk} : 8'hFF;
            8'h72: io_q = r72;
            8'h73: io_q = r73;
            8'h74: io_q = cgb_en ? r74 : 8'hFF;
            8'h75: io_q = r75 | 8'h8F;
            8'h76: io_q = apu_levels[7:0];   // PCM12: channels 2 and 1's levels
            8'h77: io_q = apu_levels[15:8];  // PCM34: 4 and 3's
            default: io_q = 8'hFF;
        endcase
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
        if (cm) if_n = io_wr && io == 8'h0F ? dout[4:0] : if_r & ~int_ack;
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

    // ---- the Color's registers' writes, and its DMA to video RAM ----
    wire hd_hbl = hd_run && ppu_mode == 2'd0;  // HBlank (or the LCD off) with an HBlank DMA on
    always_ff @(posedge clk) begin
        if (rst) begin
            cgb_en   <= cgb_hw;
            key0_b3  <= 1'b0;
            vbk      <= 1'b0;
            opri     <= 1'b0;
            svbk     <= '0;
            key1_arm <= 1'b0;
            r72 <= '0; r73 <= '0; r74 <= '0; r75 <= '0;
            rp       <= '0;
            blk      <= 1'b0;
            blk_cnt  <= '0;
            dbl      <= 1'b0;
            sw_on    <= 1'b0;
            sw_cnt   <= '0;
            hd_run   <= 1'b0;
            hd_pend  <= 1'b0;
            hd_trig  <= 1'b0;
            gd_act   <= 1'b0;
            hd_src   <= '0;
            hd_dst   <= '0;
            hd_len   <= '0;
        end else begin
            if (cgb_hw && io_wr) begin
                case (io)
                    8'h4C: if (boot_on) begin
                        cgb_en <= dout[3:2] == 2'b00;
                        key0_b3 <= dout[3];
                    end
                    8'h4D: if (cgb_en) key1_arm <= dout[0];
                    8'h4F: if (cgb_en) vbk <= dout[0];
                    8'h6C: if (boot_on || key0_b3 || cgb_en) opri <= dout[0];
                    8'h51: if (cgb_en) hd_src[11:4] <= dout;
                    8'h52: if (cgb_en) hd_src[3:0] <= dout[7:4];
                    8'h53: if (cgb_en) hd_dst[11:4] <= dout;
                    8'h54: if (cgb_en) hd_dst[3:0] <= dout[7:4];
                    8'h56: rp <= dout;
                    8'h70: if (cgb_en || boot_on) svbk <= dout[2:0];
                    8'h72: r72 <= dout;
                    8'h73: r73 <= dout;
                    8'h74: if (cgb_en) r74 <= dout;
                    8'h75: r75 <= dout;
                    default: ;
                endcase
            end

            // STOP with KEY1 armed switches the speed (the CPU stops for its M-cycles; then KEY1 clears).
            if (cm && stop_pulse && cgb_en && key1_arm) begin
                sw_on  <= 1'b1;
                sw_cnt <= 16'd33940;
            end else if (m && sw_on) begin
                if (sw_end) begin
                    sw_on    <= 1'b0;
                    dbl      <= !dbl;
                    key1_arm <= 1'b0;
                end else
                    sw_cnt <= sw_cnt - 16'd1;
            end

            // HBlank's start (as the PPU's mode becomes 0, or as the DMA starts in it) asks for a block.
            if (ce) begin
                hd_trig <= hd_hbl;
                if (hd_hbl && !hd_trig) hd_pend <= 1'b1;
            end

            // FF55: bit 7 clear starts a general DMA, or stops an HBlank one; set, starts an HBlank one.
            if (cgb_en && io_wr && io == 8'h55) begin
                hd_len <= dout[6:0];
                if (dout[7]) begin
                    hd_run <= 1'b1;
                end else if (hd_run) begin
                    hd_run  <= 1'b0;
                    hd_pend <= 1'b0;
                    hd_trig <= 1'b0;
                end else begin
                    gd_act  <= 1'b1;
                    blk     <= 1'b1;
                    blk_cnt <= dbl ? 6'd2 : 6'd0;  // its setup is 2 dots in double speed
                end
            end else if (m && !blk && hd_pend && hd_run && !cpu_halted) begin
                // an HBlank block, at an M-cycle's end
                hd_pend <= 1'b0;
                blk     <= 1'b1;
                blk_cnt <= dbl ? 6'd2 : 6'd0;
            end

            if (ce && blk) begin
                blk_cnt <= blk_cnt + 6'd1;
                if (blk_cnt == 6'd35) begin
                    // the block's 16 bytes are done; an HBlank DMA stops after its last, or as the
                    // destination wraps past $FFF0 (MesenCE)
                    hd_src <= hd_src + 12'd1;
                    hd_dst <= hd_dst + 12'd1;
                    hd_len <= hd_len - 7'd1;
                    if (hd_len == 7'd0 || hd_dst == 12'hFFF) hd_run <= 1'b0;
                    if (gd_act && hd_len != 7'd0) begin
                        blk_cnt <= 6'd4;  // the next block, without the setup
                    end else begin
                        blk    <= 1'b0;
                        gd_act <= 1'b0;
                    end
                end
            end
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
