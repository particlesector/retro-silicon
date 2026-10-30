// SPDX-License-Identifier: Apache-2.0
// The cartridge's mapper: which banks of PRG ROM, CHR and PRG RAM the CPU and
// PPU see, the nametable mirroring, and the mapper's IRQ. One design covers
// every mapper it knows, picked at load time by `mapper` (the iNES number):
//   0 NROM, 2 UxROM, 3 CNROM, 7 AxROM, 1 MMC1 (SxROM), 4 MMC3 (TxROM).
// Any other number behaves as NROM. Behaviour follows MesenCE's mappers, as
// the golden frames come from it: MMC1 ignores a write in the CPU cycle after
// another (the second write of a read-modify-write instruction) unless bit 7
// is set; MMC1 powers up with one-screen mirroring and the last bank fixed at
// $C000; MMC3 with R0-R7 = 0, 2, 4, 5, 6, 7, 0, 1, vertical mirroring and
// PRG RAM off. No bus conflicts.
//
// The CPU side: its cycle's address goes to prg_addr and wram_rd/wram_wr at
// once (combinational); a write to $8000-$FFFF takes effect on wr_ce, which
// the system gives at the point in the cycle where MesenCE's write falls
// (where the PPU's registers take theirs), and ce ends the cycle. The PPU
// side: va goes to chr_addr and mirror at once. Addresses
// come out unmasked: the system masks them to the ROM's sizes, which also
// makes the "last bank" (all ones) the last bank of any size.
//
// mirror: 0 one-screen, lower bank; 1 one-screen, upper; 2 vertical; 3 horizontal.
//
// MMC3's IRQ counts rises of the PPU's A12 (a12, sampled on a12_ce, after
// each dot's address) that come after A12 has been low for 3 CPU cycles
// (counted on ce), as MesenCE's MMC3 (revision B) counts them.
//
// Save state: words 0-4, as listed at the end.
module nes_cart #(
    parameter bit SAVE_STATE = 1'b1
) (
    input  logic        clk,
    input  logic        rst,

    // Configuration, from the ROM's header.
    input  logic [7:0]  mapper,
    input  logic        hdr_vertical,  // the header's mirroring, for mappers that don't set it
    input  logic        prg_512k,      // 512 KB of PRG ROM: MMC1's SUROM, its 256 KB halves picked by the CHR registers

    // The CPU's cycle.
    input  logic        wr_ce,         // a write to the mapper takes effect
    input  logic        ce,            // the cycle ends
    input  logic [15:0] addr,
    input  logic        we,
    input  logic [7:0]  wdata,
    output logic [22:0] prg_addr,
    output logic        wram_rd,       // PRG RAM at $6000-$7FFF answers reads...
    output logic        wram_wr,       // ...and takes writes (when the cartridge has it)
    output logic        irq_n,

    // Two PPU addresses (its address and the next, for a prefetch) through
    // the same banks.
    input  logic [1:0][12:0] va,
    input  logic        a12,
    input  logic        a12_ce,
    output logic [1:0][17:0] chr_addr,
    output logic [1:0]  mirror,

    // Save state.
    input  logic [2:0]  st_addr,
    output logic [31:0] st_rdata,
    input  logic        st_we,
    input  logic [31:0] st_wdata
);
    wire is_ux   = mapper == 8'd2;
    wire is_cn   = mapper == 8'd3;
    wire is_ax   = mapper == 8'd7;
    wire is_mmc1 = mapper == 8'd1;
    wire is_mmc3 = mapper == 8'd4;

    wire reg_wr = wr_ce && we && addr[15];

    // ---- UxROM, CNROM and AxROM: one latch ----
    logic [7:0] latch;

    // ---- MMC1 ----
    logic [4:0] m1_sr;         // the shift register, filled from bit 4 down
    logic [2:0] m1_n;          // bits shifted in
    logic [4:0] m1_ctrl;       // {CHR mode, PRG mode, slot, mirroring}
    logic [4:0] m1_chr0, m1_chr1, m1_prg;  // m1_prg[4]: PRG RAM off
    logic       m1_last_c;     // the last CHR register written was $C000's
    logic       m1_wrote;      // the last CPU cycle wrote $8000-$FFFF

    wire [4:0] m1_full = {wdata[0], m1_sr[4:1]};

    // ---- MMC3 ----
    logic [7:0][7:0] m3_r;  // R7-R0
    logic [7:0] m3_sel;        // $8000: {CHR mode, PRG mode, -, -, -, register}
    logic       m3_hmirror;    // $A000 bit 0
    logic [1:0] m3_ram;        // $A001: {enabled, write-protected}
    logic [7:0] m3_latch, m3_count;
    logic       m3_reload, m3_irq_on, m3_irq;
    logic       a12_low;           // A12 has been seen low since it was last high
    logic [1:0] a12_n;             // CPU cycles since then, up to 3

    // A12's rise, counted.
    wire       a12_rise = is_mmc3 && a12_ce && a12 && a12_low && a12_n == 2'd3;

    always_ff @(posedge clk) begin
        if (ce)
            m1_wrote <= we && addr[15];
        // A12 first: MesenCE's PPU fetches before the CPU's write in the dot.
        if (ce && a12_low && a12_n != 2'd3)
            a12_n <= a12_n + 2'd1;
        if (a12_ce) begin
            if (a12)
                a12_low <= 1'b0;
            else if (!a12_low) begin
                a12_low <= 1'b1;
                a12_n   <= {1'b0, ce};  // seen in a cycle that ends now: it counts
            end
        end
        if (a12_rise) begin
            m3_reload <= 1'b0;
            if (m3_count == '0 || m3_reload) begin
                m3_count <= m3_latch;
                if (m3_latch == '0 && m3_irq_on)
                    m3_irq <= 1'b1;
            end else begin
                m3_count <= m3_count - 8'd1;
                if (m3_count == 8'd1 && m3_irq_on)
                    m3_irq <= 1'b1;
            end
        end
        if (reg_wr) begin
            latch <= wdata;
            if (is_mmc1 && (wdata[7] || !m1_wrote)) begin
                if (wdata[7]) begin
                    m1_sr   <= '0;
                    m1_n    <= '0;
                    m1_ctrl <= m1_ctrl | 5'h0C;
                end else if (m1_n == 3'd4) begin
                    m1_sr <= '0;
                    m1_n  <= '0;
                    case (addr[14:13])
                        2'd0: m1_ctrl <= m1_full;
                        2'd1: begin m1_chr0 <= m1_full; m1_last_c <= 1'b0; end
                        2'd2: begin m1_chr1 <= m1_full; m1_last_c <= 1'b1; end
                        default: m1_prg <= m1_full;
                    endcase
                end else begin
                    m1_sr <= m1_full;
                    m1_n  <= m1_n + 3'd1;
                end
            end
            if (is_mmc3)
                case ({addr[14:13], addr[0]})
                    3'b000: m3_sel <= wdata;
                    3'b001: m3_r[m3_sel[2:0]] <= m3_sel[2:1] == 2'b00 ? {wdata[7:1], 1'b0} : wdata;
                    3'b010: m3_hmirror <= wdata[0];
                    3'b011: m3_ram <= wdata[7:6];
                    3'b100: m3_latch <= wdata;
                    3'b101: begin m3_count <= '0; m3_reload <= 1'b1; end
                    3'b110: begin m3_irq_on <= 1'b0; m3_irq <= 1'b0; end
                    default: m3_irq_on <= 1'b1;
                endcase
        end
        if (SAVE_STATE && st_we)
            case (st_addr)
                3'd0: m3_r[3:0] <= st_wdata;
                3'd1: m3_r[7:4] <= st_wdata;
                3'd2: {m3_sel, m3_latch, m3_count, m3_hmirror, m3_ram, m3_reload, m3_irq_on} <= st_wdata[28:0];
                3'd3: {m1_last_c, m1_wrote, m1_n, m1_sr, m1_ctrl, m1_chr0, m1_chr1, m1_prg} <= st_wdata[29:0];
                3'd4: {m3_irq, a12_low, a12_n, latch} <= st_wdata[11:0];
                default: ;
            endcase
        if (rst) begin
            latch      <= '0;
            m1_sr      <= '0;
            m1_n       <= '0;
            m1_ctrl    <= 5'h0C;
            m1_chr0    <= '0;
            m1_chr1    <= '0;
            m1_prg     <= '0;
            m1_last_c  <= 1'b0;
            m1_wrote   <= 1'b0;
            m3_r       <= {8'd1, 8'd0, 8'd7, 8'd6, 8'd5, 8'd4, 8'd2, 8'd0};
            m3_sel     <= '0;
            m3_hmirror <= 1'b0;
            m3_ram     <= '0;
            m3_latch   <= '0;
            m3_count   <= '0;
            m3_reload  <= 1'b0;
            m3_irq_on  <= 1'b0;
            m3_irq     <= 1'b0;
            a12_low    <= 1'b0;
            a12_n      <= '0;
        end
    end

    assign irq_n = !m3_irq;

    // ---- PRG: 8 KB banks ----
    // MMC1's SUROM bit: bit 4 of the CHR register in use ($C000's only in
    // 4 KB CHR mode, when it was the last written).
    wire        m1_hi = prg_512k && (m1_last_c && m1_ctrl[4] ? m1_chr1[4] : m1_chr0[4]);
    logic [3:0] m1_page;  // MMC1's 16 KB page within the 256 KB half
    logic [9:0] bank;

    always_comb begin
        if (!m1_ctrl[3])
            m1_page = {m1_prg[3:1], addr[14]};
        else if (m1_ctrl[2])
            m1_page = addr[14] ? 4'hF : m1_prg[3:0];
        else
            m1_page = addr[14] ? m1_prg[3:0] : 4'h0;
        if (is_ux)
            bank = addr[14] ? {9'h1FF, addr[13]} : {1'b0, latch, addr[13]};  // $C000: the last 16 KB
        else if (is_ax)
            bank = {4'b0, latch[3:0], addr[14:13]};
        else if (is_mmc1)
            bank = {4'b0, m1_hi, m1_page, addr[13]};
        else if (is_mmc3)
            case ({addr[14] ^ (m3_sel[6] && !addr[13]), addr[13]})  // mode 1 swaps $8000 and $C000
                2'd0:    bank = {2'b0, m3_r[6]};
                2'd1:    bank = {2'b0, m3_r[7]};
                2'd2:    bank = 10'h3FE;
                default: bank = 10'h3FF;
            endcase
        else
            bank = {8'b0, addr[14:13]};
    end

    assign prg_addr = {bank, addr[12:0]};
    assign wram_rd  = is_mmc1 ? !m1_prg[4] : is_mmc3 ? m3_ram[1] : 1'b1;
    assign wram_wr  = is_mmc3 ? m3_ram == 2'b10 : wram_rd;

    // ---- CHR: 1 KB banks, for each of the two PPU addresses ----
    for (genvar i = 0; i < 2; i++) begin : g_chr
        logic [7:0] cbank;
        wire        m3_half = va[i][12] ^ m3_sel[7];

        always_comb
            if (is_cn)
                cbank = {latch[4:0], va[i][12:10]};
            else if (is_mmc1)
                cbank = m1_ctrl[4] ? {1'b0, va[i][12] ? m1_chr1 : m1_chr0, va[i][11:10]}
                                   : {1'b0, m1_chr0[4:1], va[i][12:10]};
            else if (is_mmc3)
                cbank = !m3_half ? {m3_r[{2'b0, va[i][11]}][7:1], va[i][10]} : m3_r[{1'b0, va[i][11:10]} + 3'd2];
            else
                cbank = {5'b0, va[i][12:10]};

        assign chr_addr[i] = {cbank, va[i][9:0]};
    end

    always_comb
        if (is_ax)
            mirror = {1'b0, latch[4]};
        else if (is_mmc1)
            mirror = m1_ctrl[1:0];
        else if (is_mmc3)
            mirror = m3_hmirror ? 2'd3 : 2'd2;
        else
            mirror = hdr_vertical ? 2'd2 : 2'd3;

    // ---- Save state ----
    //   0 MMC3's R3-R0, 1 R7-R4 (R0 in the low byte),
    //   2 {MMC3 $8000, IRQ latch, IRQ counter, $A000 bit 0, $A001 bits 7-6, reload, IRQ on} in bits 28-0,
    //   3 {MMC1 last CHR register $C000, wrote last cycle, bits shifted, shift register,
    //      control, CHR 0, CHR 1, PRG} in bits 29-0,
    //   4 {MMC3's IRQ, A12 seen low, CPU cycles since (to 3)} in bits 11-8, the
    //     UxROM, CNROM and AxROM latch in 7-0.
    always_comb
        if (!SAVE_STATE)
            st_rdata = '0;
        else
            case (st_addr)
                3'd0:    st_rdata = m3_r[3:0];
                3'd1:    st_rdata = m3_r[7:4];
                3'd2:    st_rdata = {3'b0, m3_sel, m3_latch, m3_count, m3_hmirror, m3_ram, m3_reload, m3_irq_on};
                3'd3:    st_rdata = {2'b0, m1_last_c, m1_wrote, m1_n, m1_sr, m1_ctrl, m1_chr0, m1_chr1, m1_prg};
                3'd4:    st_rdata = {20'b0, m3_irq, a12_low, a12_n, latch};
                default: st_rdata = '0;
            endcase
endmodule
