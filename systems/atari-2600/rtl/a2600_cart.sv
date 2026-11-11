// SPDX-License-Identifier: Apache-2.0
// The Atari 2600's cartridge: its ROM (and any RAM) in block RAM, banked by the scheme the shell sets,
// each as Stella 7.0 runs it. The shell writes the ROM; the system reads it. With ROM_EXT the ROM is
// in an outside memory (a byte port as memory/sdram's) instead, and the cartridge fetches each byte
// the system reads from it: see "ROM outside" below.
//
// The cartridge watches every access on the system's bus (`addr`, `we`, `data`, ending with `ce`;
// a cycle the CPU is stalled by WSYNC isn't one), as a cartridge's hotspot logic does. A hotspot in
// the cartridge's space switches on a read or a write, and a read of it gets its byte from the bank
// it selects (the new bank's byte at that address), as Stella's does. Bank numbers are from 0.
//
// `scheme`:
//   0  2 KB or 4 KB, unbanked (a 2 KB cartridge written twice)
//   1  F8: 8 KB, 4 KB banks; $1FF8, $1FF9 select bank 0, 1. Starts in bank 1
//   2  F6: 16 KB; $1FF6-$1FF9 select bank 0-3. Starts in bank 0
//   3  F4: 32 KB; $1FF4-$1FFB select bank 0-7. Starts in bank 0
//   4  FE: 8 KB (Activision); the access after one of $01FE selects bank !D5 of its data. Only
//      accesses to $01C0-$01FF and the cartridge count (Stella's view), and a read's data is what
//      the CPU read. Starts in bank 0
//   5  E0: 8 KB (Parker Brothers) in 1 KB slices: $1000, $1400 and $1800 show the slices $1FE0-7,
//      $1FE8-F and $1FF0-7 select; $1C00 always slice 7. Starts with 4, 5, 6
//   6  3F: up to 512 KB (Tigervision) in 2 KB banks: a write to $0000-$003F selects the bank at
//      $1000 by its value (modulo the banks); $1800 always the last. Starts in bank 0
//   7  FA: 12 KB (CBS RAM Plus); $1FF8-$1FFA select bank 0-2, with 256 bytes of RAM, written at
//      $1000-$10FF and read at $1100-$11FF. Starts in bank 2
//   8  E7: 16 KB (M Network) in 2 KB slices: $1000 shows the slice $1FE0-$1FE6 selects, or with
//      $1FE7 1 KB of RAM (written at $1000-$13FF, read at $1400-$17FF); $1800-$18FF writes and
//      $1900-$19FF reads one of four 256-byte RAM banks, which $1FE8-$1FEB select; $1A00-$1FFF is
//      slice 7's. Starts with slice 0 and RAM bank 0
//   9  F0: 64 KB (Dynacom Megaboy); $1FF0 steps to the next of 16 4 KB banks. Starts in bank 15
// `sc` adds the Superchip's 128 bytes of RAM to F8, F6 and F4: written at $1000-$107F, read at
// $1080-$10FF. `size_log2` is the ROM's size (3F's bank count). The RAM starts as 0s, as Stella's
// does with its RAM randomising off: after `rst` the cartridge clears it, `clearing` while it does
// (2,048 clocks), and the system must not run until it's done. A read of a RAM write port reads ROM.
//
// `q` is the byte at `addr` (in the cartridge's space) the clock after (with ROM_EXT, once `rom_wait`
// is low); the system takes it at the cycle's end.
//
// ROM outside (ROM_EXT): when an access in the cartridge's space reads ROM, the cartridge fetches that
// byte through `mem_*` and holds it, raising `rom_wait` until it has it. The access's address is there
// from the start of its cycle, so a fetch is usually done long before the cycle ends; when it isn't
// (a refresh in the way), the system must stop between colour clocks until `rom_wait` falls, which
// leaves it as if it had run on. The shell's accesses take the port between fetches.
module a2600_cart #(
    parameter int ROM_LOG2 = 16,         // the ROM: 2^ROM_LOG2 bytes
    parameter bit ROM_EXT  = 1'b0        // the ROM in an outside memory (mem_*), not block RAM
) (
    input  logic                clk,
    input  logic                por_rst, // power-on reset (ROM_EXT's memory port)
    input  logic                rst,     // the console's reset: banks to their start, RAM cleared
    input  logic [3:0]          scheme,
    input  logic                sc,
    input  logic [4:0]          size_log2,
    output logic                clearing,

    input  logic                ce,      // an access ends
    input  logic [12:0]         addr,    // the access, from the start of its cycle
    input  logic                we,
    input  logic [7:0]          data,    // a write's data, or a read's (FE)
    output logic [7:0]          q,
    output logic                rom_wait,  // ROM_EXT: the access's ROM byte isn't here yet

    // The shell's port on the ROM: hold sh_req until sh_ack (a one-clock pulse, with a read's sh_q),
    // and drop it the clock after.
    input  logic                sh_req,
    input  logic                sh_we,
    input  logic [ROM_LOG2-1:0] sh_addr,
    input  logic [7:0]          sh_wdata,
    output logic                sh_ack,
    output logic [7:0]          sh_q,

    // ROM_EXT: the outside memory, a byte port (memory/sdram's): req held until ack, which brings a
    // read's rdata; req drops the clock after
    output logic                mem_req,
    output logic                mem_we,
    output logic [ROM_LOG2-1:0] mem_addr,
    output logic [7:0]          mem_wdata,
    input  logic                mem_ack,
    input  logic [7:0]          mem_rdata
);
    localparam logic [3:0] S_F8 = 4'd1, S_F6 = 4'd2, S_F4 = 4'd3, S_FE = 4'd4,
                           S_E0 = 4'd5, S_3F = 4'd6, S_FA = 4'd7, S_E7 = 4'd8, S_F0 = 4'd9;

    wire        in_cart = addr[12];
    wire [11:0] o       = addr[11:0];

    // ---- Banks ----
    logic [3:0] bank;          // a 4 KB bank (F8, F6, F4, FE, FA, F0)
    logic [2:0] e0 [3];        // E0's slices at $1000, $1400, $1800
    logic [7:0] b3f;           // 3F's 2 KB bank
    logic [2:0] e7;            // E7's slice at $1000 (7: RAM)
    logic [1:0] e7r;           // E7's 256-byte RAM bank
    logic       fe_next;       // FE: the last access FE sees was $01FE

    // A hotspot this access hits, and the banks with it: a read of it gets the new bank's byte.
    logic       hit4;
    logic [3:0] bank_n;
    logic       hit_e0;
    logic [1:0] e0_slot;
    logic       hit_e7, hit_e7r;

    always_comb begin
        hit4   = 1'b0;
        bank_n = bank;
        if (in_cart)
            case (scheme)
                S_F8: if (o == 12'hFF8 || o == 12'hFF9) begin hit4 = 1'b1; bank_n = 4'(o[0]); end
                S_F6: if (o >= 12'hFF6 && o <= 12'hFF9) begin hit4 = 1'b1; bank_n = 4'(o - 12'hFF6); end
                S_F4: if (o >= 12'hFF4 && o <= 12'hFFB) begin hit4 = 1'b1; bank_n = 4'(o - 12'hFF4); end
                S_FA: if (o >= 12'hFF8 && o <= 12'hFFA) begin hit4 = 1'b1; bank_n = 4'(o - 12'hFF8); end
                S_F0: if (o == 12'hFF0) begin hit4 = 1'b1; bank_n = bank + 4'd1; end
                default: ;
            endcase
    end

    assign hit_e0  = in_cart && scheme == S_E0 && o >= 12'hFE0 && o <= 12'hFF7;
    assign e0_slot = o[4:3] == 2'b00 ? 2'd0 : o[4:3] == 2'b01 ? 2'd1 : 2'd2;  // FE0-7, FE8-F, FF0-7
    assign hit_e7  = in_cart && scheme == S_E7 && o >= 12'hFE0 && o <= 12'hFE7;
    assign hit_e7r = in_cart && scheme == S_E7 && o >= 12'hFE8 && o <= 12'hFEB;

    wire [3:0] bank_e = hit4 ? bank_n : bank;
    wire [2:0] e7_e   = hit_e7 ? o[2:0] : e7;
    wire [1:0] e7r_e  = hit_e7r ? o[1:0] : e7r;
    logic [2:0] e0_e [3];
    always_comb
        for (int k = 0; k < 3; k++)
            e0_e[k] = hit_e0 && e0_slot == 2'(k) ? o[2:0] : e0[k];

    // 3F's last bank and its bank mask, from the ROM's size (2 KB banks).
    wire [7:0] m3f = size_log2 >= 5'd19 ? 8'hFF : size_log2 <= 5'd11 ? 8'h00 :
                     8'((9'd1 << (size_log2 - 5'd11)) - 9'd1);

    // FE sees $01C0-$01FF and the cartridge.
    wire fe_sees = in_cart || addr[12:6] == 7'h07;

    // ---- Where the access goes ----
    logic [18:0] ra;           // a ROM byte (wider than the block RAM; the top is dropped)
    logic        ram_rd, ram_wr;
    logic [10:0] ram_a;
    always_comb begin
        ra     = {7'd0, o};
        ram_rd = 1'b0;
        ram_wr = 1'b0;
        ram_a  = {4'd0, o[6:0]};
        case (scheme)
            S_F8, S_F6, S_F4, S_FE, S_F0: begin
                ra = {3'd0, bank_e, o};
                if (sc && scheme != S_FE && scheme != S_F0 && o[11:8] == 4'h0) begin
                    ram_wr = !o[7];
                    ram_rd = o[7];
                    ram_a  = {4'd0, o[6:0]};
                end
            end
            S_FA: begin
                ra = {3'd0, bank_e, o};
                if (o[11:9] == 3'b000) begin
                    ram_wr = !o[8];
                    ram_rd = o[8];
                    ram_a  = {3'd0, o[7:0]};
                end
            end
            S_E0: ra = {6'd0, o[11:10] == 2'd3 ? 3'd7 : e0_e[o[11:10]], o[9:0]};
            S_3F: ra = {o[11] ? m3f : (b3f & m3f), o[10:0]};
            S_E7: begin
                ra = {5'd0, o[11] ? 3'd7 : e7_e, o[10:0]};
                if (!o[11] && e7_e == 3'd7) begin           // 1 KB of RAM at $1000
                    ram_wr = !o[10];
                    ram_rd = o[10];
                    ram_a  = {1'b0, o[9:0]};
                end else if (o[11:9] == 3'b100) begin       // 256 bytes at $1800
                    ram_wr = !o[8];
                    ram_rd = o[8];
                    ram_a  = {1'b1, e7r_e, o[7:0]};
                end
            end
            default: ;
        endcase
        if (!in_cart) begin
            ram_rd = 1'b0;
            ram_wr = 1'b0;
        end
    end

    // ---- The banks' state ----
    always_ff @(posedge clk)
        if (rst) begin
            bank    <= scheme == S_F8 ? 4'd1 : scheme == S_FA ? 4'd2 : scheme == S_F0 ? 4'd15 : 4'd0;
            e0[0]   <= 3'd4;
            e0[1]   <= 3'd5;
            e0[2]   <= 3'd6;
            b3f     <= '0;
            e7      <= '0;
            e7r     <= '0;
            fe_next <= 1'b0;
        end else if (ce) begin
            bank  <= bank_e;
            e0    <= e0_e;
            e7    <= e7_e;
            e7r   <= e7r_e;
            if (scheme == S_3F && we && addr <= 13'h003F)
                b3f <= data;
            if (scheme == S_FE && fe_sees) begin
                if (fe_next)
                    bank <= {3'd0, !data[5]};
                fe_next <= !fe_next && addr == 13'h01FE;
            end
        end

    // ---- ROM ----
    logic [7:0] rom_q;
    wire [ROM_LOG2-1:0] ra_r = ra[ROM_LOG2-1:0];

    if (!ROM_EXT) begin : g_rom
        logic [7:0] rom [2**ROM_LOG2];
        logic       rd_d;  // a shell read's data is out
        // One write port (the shell's) and one read port, which a shell read takes over: so the ROM
        // is a simple dual-port memory, 2 KB a block RAM on the Tang Nano 20K, where a second read
        // port doubled it. The shell reads the ROM only to check a load, with the system held in
        // reset.
        always_ff @(posedge clk)
            if (sh_req && sh_we) rom[sh_addr] <= sh_wdata;
        always_ff @(posedge clk) begin
            rom_q <= rom[sh_req && !sh_we ? sh_addr : ra_r];
            rd_d  <= sh_req && !sh_we && !rd_d;
        end
        assign sh_ack    = sh_req && (sh_we || rd_d);
        assign sh_q      = rom_q;
        assign rom_wait  = 1'b0;
        assign mem_req   = 1'b0;
        assign mem_we    = 1'b0;
        assign mem_addr  = '0;
        assign mem_wdata = '0;
        wire unused_mem = &{1'b0, por_rst, mem_ack, mem_rdata};
    end else begin : g_rom_ext
        // Reset by `por_rst` only: the shell loads the ROM with the system held in reset, and an
        // access the memory has started must finish.
        logic                busy, for_sh;  // a memory access is under way, and whose
        logic                f_valid;       // rom_q is the byte at f_ra
        logic [ROM_LOG2-1:0] f_ra;
        wire                 want = in_cart && !we && !ram_rd;  // this access reads ROM
        wire                 have = f_valid && f_ra == ra_r;

        always_ff @(posedge clk) begin
            if (!busy) begin
                if (sh_req) begin
                    busy      <= 1'b1;
                    for_sh    <= 1'b1;
                    mem_we    <= sh_we;
                    mem_addr  <= sh_addr;
                    mem_wdata <= sh_wdata;
                    if (sh_we) f_valid <= 1'b0;
                end else if (want && !have) begin
                    busy     <= 1'b1;
                    for_sh   <= 1'b0;
                    mem_we   <= 1'b0;
                    mem_addr <= ra_r;
                end
            end else if (mem_ack) begin
                busy <= 1'b0;
                if (!for_sh) begin
                    rom_q   <= mem_rdata;
                    f_ra    <= mem_addr;
                    f_valid <= 1'b1;
                end
            end
            if (por_rst) begin
                busy    <= 1'b0;
                f_valid <= 1'b0;
            end
        end
        assign mem_req  = busy;
        assign sh_ack   = busy && for_sh && mem_ack;
        assign sh_q     = mem_rdata;
        assign rom_wait = want && !have;
    end

    // ---- RAM: 2 KB, cleared after reset ----
    logic [7:0]  ram [2048];
    logic [7:0]  ram_q;
    logic        ram_rd_q;
    logic [11:0] clr;          // the next byte to clear; bit 11 set when done

    assign clearing = !clr[11];

    always_ff @(posedge clk) begin
        if (clearing)
            ram[clr[10:0]] <= 8'd0;
        else if (ce && we && ram_wr)
            ram[ram_a] <= data;
        ram_q    <= ram[ram_a];
        ram_rd_q <= ram_rd;
        if (rst)
            clr <= '0;
        else if (clearing)
            clr <= clr + 12'd1;
    end

    assign q = ram_rd_q ? ram_q : rom_q;

    wire unused = &{1'b0, ra[18:ROM_LOG2 > 18 ? 18 : ROM_LOG2]};
endmodule
