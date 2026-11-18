// SPDX-License-Identifier: Apache-2.0
// A Game Boy cartridge's memory controller (its MBC) and RAM: none, MBC1 (and the
// multicart wiring of MBC1M), MBC2 with its 512 x 4-bit RAM, MBC3 with its real-time
// clock, and MBC5. The host picks the controller and the sizes from the cartridge's
// header (`mbc`, `rom_log2`, `ram_log2`), as MesenCE does; they're held while the
// system runs. The ROM is outside: the cartridge gives the address in it that the bus
// reads (`rom_addr`) and takes its byte (`rom_q`) back. The RAM is in block RAM.
//
// Behaviour, as MesenCE and SameBoy have it (Pan Docs agreeing):
// - RAM enable: a write to $0000-$1FFF of $xA (MBC5: exactly $0A); MBC2 decodes it
//   from $0000-$3FFF with address bit 8 low. Disabled RAM reads $FF.
// - MBC1: BANK1 (5 bits, $2000), BANK2 (2 bits, $4000), MODE ($6000). $4000-$7FFF is
//   bank BANK2:BANK1, BANK1 0 read as 1; in mode 1, $0000-$3FFF is bank BANK2:0 and
//   the RAM's bank is BANK2. MBC1M (multicart) leaves out BANK1's top bit: BANK2
//   comes in at bank bit 4.
// - MBC2: the bank (4 bits, 0 read as 1) from $0000-$3FFF with address bit 8 high; its
//   RAM is 512 4-bit cells at $A000-$A1FF, repeated to $BFFF, read with the top 4 bits 1.
// - MBC3: the bank (7 bits; 8 on the MBC30, a cartridge with 64 KB of RAM or more), 0
//   read as 1; RAM banks 0-3 (MBC30: 0-7) or, with the clock, its registers 8-$C. Any
//   write to $6000-$7FFF latches the clock's registers for reading, as both emulators
//   have it.
// - MBC5: the bank (9 bits: $2000 the low 8, $3000 bit 8), bank 0 allowed; RAM banks
//   0-15 (with rumble, 0-7: bit 3 runs the motor, which isn't here).
// Banks past the ROM's or RAM's size wrap around them.
//
// The clock (MBC3's, with `rtc`): seconds, minutes, hours and a 9-bit day count with
// halt and carry bits, counting emulated time as MesenCE's does: a prescaler of 128
// T-cycles (32,768 Hz from the console's 4,194,304) that always counts, and a count
// of its ticks, held while the clock is halted, that adds a second at 32,768. A write
// to the seconds clears both. A register at its bits' limit wraps to 0 without a
// carry (seconds 63, for one); 59 seconds, 59 minutes and 23 hours carry; the day
// count past 511 wraps and sets the carry bit, which stays until written. The clock
// and RAM aren't cleared by `rst` (they'd keep a battery's charge): the host loads both.
//
// Timing: `rdata` is the byte at `addr` as of the clock before (the ROM's, RAM's and
// clock's reads are registered), as gameboy's `cart_rdata` must be. A write lands on
// the clock `wr` is high.
//
// The shell's port (while the system is held in reset, when it has the RAM's port):
// with `sh_rtc` low, the RAM's byte `sh_addr`; high, the clock's state: bytes 0-4
// the registers (seconds, minutes, hours, days' low 8, days' high: bit 0 day bit 8,
// 6 halt, 7 carry), 5-9 the latched copy, 10-12 the tick count (bits 0-14) and the
// prescaler (bits 15-21). `sh_q` is the byte a clock after its address.
module gb_cart #(
    parameter int ROM_AW = 23,  // the ROM's address bits the system has room for
    parameter int RAM_AW = 15   // the RAM in block RAM: 2^RAM_AW bytes
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              ce,        // a T-cycle (the clock counts them)

    input  logic [2:0]        mbc,       // 0 none, 1 MBC1, 2 MBC1M, 3 MBC2, 4 MBC3, 5 MBC5
    input  logic              rtc,       // MBC3: the clock is there
    input  logic              rumble,    // MBC5: the motor is there
    input  logic [4:0]        rom_log2,  // the ROM's size: 15 (32 KB) to 23 (8 MB)
    input  logic [4:0]        ram_log2,  // the RAM's: 0 none, 9 (MBC2's 512), 11 to 17

    input  logic [15:0]       addr,
    input  logic              wr,
    input  logic [7:0]        wdata,
    output logic [7:0]        rdata,

    output logic [ROM_AW-1:0] rom_addr,
    input  logic [7:0]        rom_q,

    input  logic              sh_we,
    input  logic              sh_rtc,
    input  logic [16:0]       sh_addr,
    input  logic [7:0]        sh_wdata,
    output logic [7:0]        sh_q
);
    localparam logic [2:0] M_NONE = 3'd0, M_MBC1 = 3'd1, M_MBC1M = 3'd2, M_MBC2 = 3'd3, M_MBC3 = 3'd4,
                           M_MBC5 = 3'd5;

    // ---- The controller's registers ----
    logic       ram_en, mode;
    logic [4:0] bank1;      // MBC1's BANK1
    logic [1:0] bank2;      // MBC1's BANK2
    logic [8:0] rbank;      // MBC2's, MBC3's and MBC5's ROM bank
    logic [3:0] xbank;      // MBC3's and MBC5's RAM (or clock) bank

    wire mbc30  = ram_log2 >= 5'd16;
    wire lo     = !addr[15] && !addr[14] && !addr[13];  // $0000-$1FFF
    wire is_ram = addr[15:13] == 3'b101;                 // $A000-$BFFF

    always_ff @(posedge clk)
        if (rst) begin
            ram_en <= 1'b0;
            mode   <= 1'b0;
            bank1  <= 5'd1;
            bank2  <= '0;
            rbank  <= 9'd1;
            xbank  <= '0;
        end else if (wr && !addr[15])
            case (mbc)
                M_MBC1, M_MBC1M:
                    case (addr[14:13])
                        2'd0: ram_en <= wdata[3:0] == 4'hA;
                        2'd1: bank1  <= wdata[4:0];
                        2'd2: bank2  <= wdata[1:0];
                        default: mode <= wdata[0];
                    endcase
                M_MBC2:
                    if (!addr[14]) begin
                        if (addr[8]) rbank  <= {5'd0, wdata[3:0]};
                        else         ram_en <= wdata[3:0] == 4'hA;
                    end
                M_MBC3:
                    case (addr[14:13])
                        2'd0: ram_en <= wdata[3:0] == 4'hA;
                        2'd1: rbank  <= {1'b0, wdata};
                        2'd2: xbank  <= wdata[3:0];
                        default: ;  // the clock's latch, below
                    endcase
                M_MBC5:
                    if (lo) ram_en <= wdata == 8'h0A;
                    else if (addr[14:12] == 3'b010) rbank[7:0] <= wdata;
                    else if (addr[14:12] == 3'b011) rbank[8]   <= wdata[0];
                    else if (!addr[13]) xbank <= rumble ? {1'b0, wdata[2:0]} : wdata[3:0];
                default: ;
            endcase

    // ---- The ROM's address ----
    logic [8:0] bank;  // the bank the address reads, before its wrap to the ROM's size
    wire  [7:0] bank3 = mbc30 ? rbank[7:0] : {1'b0, rbank[6:0]};
    always_comb begin
        bank = 9'd0;
        case (mbc)
            M_MBC1:  bank = addr[14] ? {2'd0, bank2, bank1 == 5'd0 ? 5'd1 : bank1} :
                            mode ? {2'd0, bank2, 5'd0} : 9'd0;
            M_MBC1M: bank = addr[14] ? {3'd0, bank2, bank1 == 5'd0 ? 4'd1 : bank1[3:0]} :
                            mode ? {3'd0, bank2, 4'd0} : 9'd0;
            M_MBC2:  bank = addr[14] ? (rbank[3:0] == 4'd0 ? 9'd1 : {5'd0, rbank[3:0]}) : 9'd0;
            M_MBC3:  bank = !addr[14] ? 9'd0 : bank3 == 8'd0 ? 9'd1 : {1'b0, bank3};
            M_MBC5:  bank = addr[14] ? rbank : 9'd0;
            default: bank = {8'd0, addr[14]};
        endcase
    end
    wire [22:0] rom_full = {bank, addr[13:0]};
    wire [22:0] rom_mask = 23'((24'd1 << rom_log2) - 24'd1);
    assign rom_addr = ROM_AW'(rom_full & rom_mask);

    // ---- The RAM ----
    // MBC2's 4-bit cells are kept as bytes with the top 4 bits set, as MesenCE keeps them.
    logic [7:0]  ram [0:(1 << RAM_AW) - 1];
    logic [7:0]  ram_q;
    logic [3:0]  ram_bank;
    always_comb
        case (mbc)
            M_MBC1:  ram_bank = mode ? {2'd0, bank2} : 4'd0;
            M_MBC1M: ram_bank = mode ? {2'd0, bank2} : 4'd0;
            M_MBC3:  ram_bank = xbank;
            M_MBC5:  ram_bank = xbank;
            default: ram_bank = 4'd0;
        endcase
    wire [16:0] ram_full = mbc == M_MBC2 ? {8'd0, addr[8:0]} : {ram_bank, addr[12:0]};
    wire [16:0] ram_mask = 17'((18'd1 << ram_log2) - 18'd1);
    wire        has_ram  = ram_log2 != 5'd0;
    // The RAM answers while enabled, and on MBC3 only for its RAM banks; a cartridge without a
    // controller has its RAM always there.
    wire ram_on = has_ram && (mbc == M_NONE || ram_en && (mbc != M_MBC3 || xbank <= (mbc30 ? 4'd7 : 4'd3)));
    wire rtc_on = mbc == M_MBC3 && rtc && ram_en && xbank >= 4'd8 && xbank <= 4'hC;

    wire [RAM_AW-1:0] ram_a  = rst ? sh_addr[RAM_AW-1:0] : RAM_AW'(ram_full & ram_mask);
    wire              ram_we = rst ? sh_we && !sh_rtc : wr && is_ram && ram_on;
    wire [7:0]        ram_d  = rst ? sh_wdata : mbc == M_MBC2 ? {4'hF, wdata[3:0]} : wdata;
    always_ff @(posedge clk) begin
        if (ram_we) ram[ram_a] <= ram_d;
        ram_q <= ram[ram_a];
    end

    // ---- The clock ----
    logic [5:0]  sec, min, l_sec, l_min;
    logic [4:0]  hr, l_hr;
    logic [7:0]  dl, l_dl;
    logic [2:0]  dh, l_dh;    // {carry, halt, day bit 8}
    logic [6:0]  pre;
    logic [14:0] ticks;
    wire         rtc_wr = wr && is_ram && rtc_on;
    wire         halt   = dh[1];
    wire         second = ce && pre == 7'd127 && !halt && ticks == 15'h7FFF;

    // A second's count, carrying as the chip does.
    logic [5:0] sec_n, min_n;
    logic [4:0] hr_n;
    logic [8:0] day_n;
    logic       cy_n;
    always_comb begin
        sec_n = sec + 6'd1;
        min_n = min;
        hr_n  = hr;
        day_n = {dh[0], dl};
        cy_n  = dh[2];
        if (sec == 6'd59) begin
            sec_n = '0;
            min_n = min + 6'd1;
            if (min == 6'd59) begin
                min_n = '0;
                hr_n  = hr + 5'd1;
                if (hr == 5'd23) begin
                    hr_n  = '0;
                    day_n = {dh[0], dl} + 9'd1;
                    if ({dh[0], dl} == 9'h1FF) cy_n = 1'b1;
                end
            end
        end
    end

    wire [3:0] sh_r = sh_addr[3:0];
    always_ff @(posedge clk) begin
        if (rst) begin
            // The shell's writes, while held in reset.
            if (sh_we && sh_rtc)
                case (sh_r)
                    4'd0:  sec   <= sh_wdata[5:0];
                    4'd1:  min   <= sh_wdata[5:0];
                    4'd2:  hr    <= sh_wdata[4:0];
                    4'd3:  dl    <= sh_wdata;
                    4'd4:  dh    <= {sh_wdata[7:6], sh_wdata[0]};
                    4'd5:  l_sec <= sh_wdata[5:0];
                    4'd6:  l_min <= sh_wdata[5:0];
                    4'd7:  l_hr  <= sh_wdata[4:0];
                    4'd8:  l_dl  <= sh_wdata;
                    4'd9:  l_dh  <= {sh_wdata[7:6], sh_wdata[0]};
                    4'd10: ticks[7:0]  <= sh_wdata;
                    4'd11: begin ticks[14:8] <= sh_wdata[6:0]; pre[0] <= sh_wdata[7]; end
                    4'd12: pre[6:1] <= sh_wdata[5:0];
                    default: ;
                endcase
        end else begin
            if (ce) begin
                pre <= pre + 7'd1;
                if (pre == 7'd127 && !halt) ticks <= ticks + 15'd1;
            end
            if (second) begin
                sec <= sec_n;
                min <= min_n;
                hr  <= hr_n;
                {dh[0], dl} <= day_n;
                dh[2] <= cy_n;
            end
            // A write lands after the clock's count, as MesenCE brings the clock up to date first.
            if (rtc_wr)
                case (xbank)
                    4'h8: begin
                        sec   <= wdata[5:0];
                        pre   <= '0;
                        ticks <= '0;
                    end
                    4'h9: min <= wdata[5:0];
                    4'hA: hr  <= wdata[4:0];
                    4'hB: dl  <= wdata;
                    default: dh <= {wdata[7:6], wdata[0]};
                endcase
            if (wr && mbc == M_MBC3 && rtc && addr[15:13] == 3'b011) begin
                l_sec <= sec;
                l_min <= min;
                l_hr  <= hr;
                l_dl  <= dl;
                l_dh  <= dh;
            end
        end
    end

    logic [7:0] rtc_q;  // the latched register the bus reads
    always_ff @(posedge clk)
        case (xbank)
            4'h8:    rtc_q <= {2'd0, l_sec};
            4'h9:    rtc_q <= {2'd0, l_min};
            4'hA:    rtc_q <= {3'd0, l_hr};
            4'hB:    rtc_q <= l_dl;
            default: rtc_q <= {l_dh[2:1], 5'd0, l_dh[0]};
        endcase

    logic [7:0] sh_rq;  // the clock's byte the shell reads
    always_ff @(posedge clk)
        case (sh_r)
            4'd0:  sh_rq <= {2'd0, sec};
            4'd1:  sh_rq <= {2'd0, min};
            4'd2:  sh_rq <= {3'd0, hr};
            4'd3:  sh_rq <= dl;
            4'd4:  sh_rq <= {dh[2:1], 5'd0, dh[0]};
            4'd5:  sh_rq <= {2'd0, l_sec};
            4'd6:  sh_rq <= {2'd0, l_min};
            4'd7:  sh_rq <= {3'd0, l_hr};
            4'd8:  sh_rq <= l_dl;
            4'd9:  sh_rq <= {l_dh[2:1], 5'd0, l_dh[0]};
            4'd10: sh_rq <= ticks[7:0];
            4'd11: sh_rq <= {pre[0], ticks[14:8]};
            4'd12: sh_rq <= {2'd0, pre[6:1]};
            default: sh_rq <= 8'd0;
        endcase
    logic sh_rtc_d;
    always_ff @(posedge clk) sh_rtc_d <= sh_rtc;
    assign sh_q = sh_rtc_d ? sh_rq : ram_q;

    // ---- What the bus reads, a clock after its address ----
    typedef enum logic [1:0] { S_ROM, S_RAM, S_RTC, S_FF } src_t;
    src_t src, src_d;
    always_comb
        if (!addr[15])                src = S_ROM;
        else if (is_ram && rtc_on)    src = S_RTC;
        else if (is_ram && ram_on)    src = S_RAM;
        else                          src = S_FF;
    always_ff @(posedge clk) src_d <= src;
    always_comb
        case (src_d)
            S_ROM:   rdata = rom_q;
            S_RAM:   rdata = mbc == M_MBC2 ? {4'hF, ram_q[3:0]} : ram_q;
            S_RTC:   rdata = rtc_q;
            default: rdata = 8'hFF;
        endcase

    wire unused = &{1'b0, sh_addr};
endmodule
