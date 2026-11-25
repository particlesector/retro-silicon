// SPDX-License-Identifier: Apache-2.0
// systems/game-boy's gb_sys through its test shell, in the sim: a test ROM of each kind of check in
// harness/golden/gb_frames_crc32.txt (Mooneye's bytes, blargg's text over the serial port or his code
// in cartridge RAM, and a frame) ends as it does in MesenCE, the frame's CRC taken by the system
// itself, and its sound's CRC is gb_audio_crc32.txt's, as a board runs them; and a cartridge with
// an MBC, on each board's build of the ROM's memory (block RAM, the 20K's SDRAM, the 138K's SDRAM
// module, the PYNQ-Z2's DDR3 through AXI). systems/game-boy's
// gb_roms_test runs every ROM on the bare system, and wrote gb_audio_crc32.txt. Skipped when the
// ROMs aren't fetched (testroms/fetch.py).
#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <memory>
#include <iterator>
#include <string>
#include <vector>

#include "rig/gb.hpp"
#include "rig/sim_systems.hpp"

namespace {

std::vector<uint8_t> read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(f), {}};
}

// Each ROM through one gb_sys in turn, as a board runs them: each must match as if it ran alone.
void match_in_turn(const std::vector<std::string>& ids) {
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto golden = rig::gb::load_golden(RS_GB_GOLDEN);
    const auto audio = rig::gb::load_audio_golden(RS_GB_AUDIO_GOLDEN);
    auto link = rig::make_gb_sim();
    for (const auto& id : ids) {
        auto g = std::find_if(golden.begin(), golden.end(), [&](auto& x) { return x.id == id; });
        REQUIRE(g != golden.end());
        const auto rom = read_file(roms + "/" + g->path);
        if (rom.empty()) SKIP("no " << roms << "/" << g->path);
        const auto boot = read_file(roms + "/" + rig::gb::boot_for(g->model));
        if (boot.empty()) SKIP("no " << roms << "/" << rig::gb::boot_for(g->model));
        auto a = audio.find(id);
        REQUIRE(a != audio.end());
        auto r = rig::gb::rom_test(*link, *g, rom, boot, RS_GB_BUILD_ID, a->second);
        INFO(id << ": " << r.detail << " (" << r.notes << ")");
        CHECK(r.passed);
    }
}

using MakeSim = std::function<std::unique_ptr<rig::SimLink>()>;

void matches_mesen(const std::string& id, const MakeSim& make = [] { return rig::make_gb_sim(); },
                   uint32_t build_id = RS_GB_BUILD_ID) {
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    for (const auto& g : rig::gb::load_golden(RS_GB_GOLDEN)) {
        if (g.id != id) continue;
        const auto rom = read_file(roms + "/" + g.path);
        if (rom.empty()) SKIP("no " << roms << "/" << g.path);
        const auto boot = read_file(roms + "/" + rig::gb::boot_for(g.model));
        if (boot.empty()) SKIP("no " << roms << "/" << rig::gb::boot_for(g.model));
        const auto audio = rig::gb::load_audio_golden(RS_GB_AUDIO_GOLDEN);
        auto a = audio.find(id);
        REQUIRE(a != audio.end());
        auto link = make();
        auto r = rig::gb::rom_test(*link, g, rom, boot, build_id, a->second);
        INFO(g.id << ": " << r.detail << " (" << r.notes << ")");
        CHECK(r.passed);
        return;
    }
    FAIL(id << " isn't in gb_frames_crc32.txt");
}

} // namespace

TEST_CASE("Game Boy through the shell: mts-ei_sequence passes (Mooneye's bytes) and its frame matches MesenCE's") {
    matches_mesen("mts-ei_sequence");
}

TEST_CASE("Game Boy through the shell: instr_timing passes (blargg's text) and its frame matches MesenCE's") {
    matches_mesen("instr_timing");
}

TEST_CASE("Game Boy through the shell: dmg-acid2's frame 300 matches MesenCE's") { matches_mesen("dmg-acid2"); }

TEST_CASE("Game Boy through the shell: dmg_sound-01 passes (blargg's code in cartridge RAM) and its frame matches MesenCE's") {
    matches_mesen("dmg_sound-01");
}

TEST_CASE("Game Boy through the shell: a ROM's sound doesn't depend on the ROM before it (wave RAM resets)") {
    // dmg_sound-10 leaves wave RAM written; dmg_sound-11 plays it before writing its own.
    match_in_turn({"dmg_sound-10", "dmg_sound-11"});
}

TEST_CASE("Game Boy through the shell: a RAM cartridge's setup doesn't carry over to the ROM after it") {
    // mts-mbc1-ram_64kb sets its MBC1's RAM up and writes it; dmg_sound-01's MBC1 has 8 KB of RAM.
    match_in_turn({"mts-mbc1-ram_64kb", "dmg_sound-01"});
}

TEST_CASE("Game Boy through the shell: MBC2's RAM (mts-mbc2-ram) matches MesenCE") { matches_mesen("mts-mbc2-ram"); }

TEST_CASE("Game Boy through the shell: an MBC5 cartridge (mts-mbc5-rom_512kb) on each board's ROM memory") {
    SECTION("block RAM") { matches_mesen("mts-mbc5-rom_512kb"); }
    SECTION("the Tang Nano 20K's SDRAM") {
        matches_mesen("mts-mbc5-rom_512kb", [] { return rig::make_gb_hdmi_sim(); });
    }
    SECTION("the Tang Console 138K's SDRAM module") {
        matches_mesen("mts-mbc5-rom_512kb", [] { return rig::make_gb_console_sim(); });
    }
    SECTION("the PYNQ-Z2's DDR3, through AXI and the read cache") {
        matches_mesen("mts-mbc5-rom_512kb", [] { return rig::make_gb_axi_sim(); }, RS_GB_AXI_BUILD_ID);
    }
}

TEST_CASE("Game Boy Color through the shell: cgb-acid2's frame 300 matches MesenCE's") {
    SECTION("block RAM") { matches_mesen("cgb-acid2"); }
    SECTION("the PYNQ-Z2's DDR3, through AXI and the read cache") {
        matches_mesen("cgb-acid2", [] { return rig::make_gb_axi_sim(); }, RS_GB_AXI_BUILD_ID);
    }
}

TEST_CASE("Game Boy Color through the shell: interrupt_time (double speed) matches MesenCE's frame") {
    matches_mesen("interrupt_time");
}

TEST_CASE("Game Boy Color through the shell: the model changes with each ROM's boot ROM") {
    // A Game Boy ROM, a Color ROM, then the Game Boy again: register 50's bit 5 each time.
    match_in_turn({"dmg-acid2", "cgb-acid2", "dmg-acid2"});
}

namespace {

// A 32 KB ROM of our own (no Nintendo logo; SameBoy's boot ROMs don't check it): it clears
// $C100-$C19F, starts an OAM DMA from $C100, and while it runs reads $0200 ($5A) from the ROM and
// sends it over the serial port. A ROM read that conflicts with the DMA reads the DMA's byte ($00, a
// NOP) instead, the fetches too: the CPU runs on through NOPs into a part that sends $EE.
std::vector<uint8_t> dma_bus_rom() {
    std::vector<uint8_t> rom(0x8000, 0x00);
    const uint8_t entry[] = {0x00, 0xC3, 0x50, 0x01};  // NOP; JP $0150
    std::copy(std::begin(entry), std::end(entry), rom.begin() + 0x100);
    rom[0x143] = 0x80;  // for the Color, and the Game Boy too
    uint8_t x = 0;
    for (int i = 0x134; i <= 0x14C; i++) x = static_cast<uint8_t>(x - rom[i] - 1);
    rom[0x14D] = x;
    const uint8_t code[] = {
        0x31, 0xFE, 0xFF,  // LD SP,$FFFE
        0x21, 0x00, 0xC1,  // LD HL,$C100
        0xAF,              // XOR A
        0x06, 0xA0,        // LD B,160
        0x22,              // .clear: LD (HL+),A
        0x05,              //         DEC B
        0x20, 0xFC,        //         JR NZ,.clear
        0x3E, 0xC1,        // LD A,$C1
        0xE0, 0x46,        // LDH ($46),A: the DMA, from $C100
        0xFA, 0x00, 0x02,  // LD A,($0200), from the ROM, as the DMA runs
        0xE0, 0x01,        // LDH ($01),A
        0x3E, 0x81,        // LD A,$81
        0xE0, 0x02,        // LDH ($02),A: send it
        0x18, 0xFE,        // JR @
    };
    std::copy(std::begin(code), std::end(code), rom.begin() + 0x150);
    const uint8_t fail[] = {0x3E, 0xEE, 0xE0, 0x01, 0x3E, 0x81, 0xE0, 0x02, 0x18, 0xFE};  // send $EE
    std::copy(std::begin(fail), std::end(fail), rom.begin() + 0x150 + sizeof code + 256);
    rom[0x200] = 0x5A;
    return rom;
}

// A 32 KB ROM of our own: it arms a speed switch (KEY1 bit 0) with the timer's interrupt pending
// (IE and IF bit 2, IME off), runs STOP, and sends KEY1 over the serial port.
std::vector<uint8_t> speed_switch_pending_rom() {
    std::vector<uint8_t> rom(0x8000, 0x00);
    const uint8_t entry[] = {0x00, 0xC3, 0x50, 0x01};  // NOP; JP $0150
    std::copy(std::begin(entry), std::end(entry), rom.begin() + 0x100);
    rom[0x143] = 0x80;
    uint8_t x = 0;
    for (int i = 0x134; i <= 0x14C; i++) x = static_cast<uint8_t>(x - rom[i] - 1);
    rom[0x14D] = x;
    const uint8_t code[] = {
        0x31, 0xFE, 0xFF,  // LD SP,$FFFE
        0xF3,              // DI
        0x3E, 0x04,        // LD A,$04
        0xE0, 0xFF,        // LDH ($FF),A: IE, the timer
        0xE0, 0x0F,        // LDH ($0F),A: IF, the timer's pending
        0x3E, 0x01,        // LD A,1
        0xE0, 0x4D,        // LDH ($4D),A: KEY1, a switch armed
        0x10, 0x00,        // STOP
        0xF0, 0x4D,        // LDH A,($4D)
        0xE0, 0x01,        // LDH ($01),A
        0x3E, 0x81,        // LD A,$81
        0xE0, 0x02,        // LDH ($02),A: send it
        0x18, 0xFE,        // JR @
    };
    std::copy(std::begin(code), std::end(code), rom.begin() + 0x150);
    return rom;
}

// A 32 KB ROM of our own for the Color: at line 140 it starts an HBlank DMA of 8 blocks, which
// moves one in each HBlank, 140 to 143 and, after VBlank, 0 to 3; once it's done it sends LY.
std::vector<uint8_t> hdma_vblank_rom() {
    std::vector<uint8_t> rom(0x8000, 0x00);
    const uint8_t entry[] = {0x00, 0xC3, 0x50, 0x01};  // NOP; JP $0150
    std::copy(std::begin(entry), std::end(entry), rom.begin() + 0x100);
    rom[0x143] = 0x80;
    uint8_t x = 0;
    for (int i = 0x134; i <= 0x14C; i++) x = static_cast<uint8_t>(x - rom[i] - 1);
    rom[0x14D] = x;
    const uint8_t code[] = {
        0x31, 0xFE, 0xFF,                    // LD SP,$FFFE
        0xF3,                                // DI
        0xF0, 0x44, 0xFE, 0x8C, 0x20, 0xFA,  // .w: LDH A,($44); CP 140; JR NZ,.w
        0x3E, 0x40, 0xE0, 0x51,              // LD A,$40; LDH ($51),A: from $4000
        0xAF, 0xE0, 0x52,                    // XOR A; LDH ($52),A
        0x3E, 0x80, 0xE0, 0x53,              // LD A,$80; LDH ($53),A: to $8000
        0xAF, 0xE0, 0x54,                    // XOR A; LDH ($54),A
        0x3E, 0x87, 0xE0, 0x55,              // LD A,$87; LDH ($55),A: an HBlank DMA of 8 blocks
        0xF0, 0x55, 0xCB, 0x7F, 0x28, 0xFA,  // .p: LDH A,($55); BIT 7,A; JR Z,.p: until it's done
        0xF0, 0x44, 0xE0, 0x01,              // LDH A,($44); LDH ($01),A
        0x3E, 0x81, 0xE0, 0x02,              // LD A,$81; LDH ($02),A: send LY
        0x18, 0xFE,                          // JR @
    };
    std::copy(std::begin(code), std::end(code), rom.begin() + 0x150);
    return rom;
}

// A 32 KB ROM of our own for the Game Boy: the LCD off at VBlank, then a loop.
std::vector<uint8_t> lcd_off_rom() {
    std::vector<uint8_t> rom(0x8000, 0x00);
    const uint8_t entry[] = {0x00, 0xC3, 0x50, 0x01};  // NOP; JP $0150
    std::copy(std::begin(entry), std::end(entry), rom.begin() + 0x100);
    uint8_t x = 0;
    for (int i = 0x134; i <= 0x14C; i++) x = static_cast<uint8_t>(x - rom[i] - 1);
    rom[0x14D] = x;
    const uint8_t code[] = {
        0x31, 0xFE, 0xFF,                    // LD SP,$FFFE
        0xF0, 0x44, 0xFE, 0x90, 0x20, 0xFA,  // .v: LDH A,($44); CP 144; JR NZ,.v
        0xAF, 0xE0, 0x40,                    // XOR A; LDH ($40),A: the LCD off
        0x18, 0xFE,                          // JR @
    };
    std::copy(std::begin(code), std::end(code), rom.begin() + 0x150);
    return rom;
}

// A 32 KB ROM of our own for the Game Boy: ten times over it turns the LCD off at VBlank and on
// again, waits `skip` NOPs and 0 to 4 more, and reads STAT 16 times, one every 5 M-cycles, into work
// RAM: STAT at every M-cycle of two stretches from the LCD's start, `kLcdOnSamples` bytes, which it
// then sends over the serial port. The first stretch is line 0's (its mode 3), the second the end of
// line 0 and line 1's mode 2 and mode 3.
constexpr int kLcdOnSamples = 2 * 5 * 16;
std::vector<uint8_t> lcd_on_stat_rom() {
    std::vector<uint8_t> rom(0x8000, 0x00);
    const uint8_t entry[] = {0x00, 0xC3, 0x50, 0x01};  // NOP; JP $0150
    std::copy(std::begin(entry), std::end(entry), rom.begin() + 0x100);
    uint8_t x = 0;
    for (int i = 0x134; i <= 0x14C; i++) x = static_cast<uint8_t>(x - rom[i] - 1);
    rom[0x14D] = x;
    std::vector<uint8_t> c = {
        0x31, 0xFE, 0xFF,  // LD SP,$FFFE
        0xF3,              // DI
        0x21, 0x00, 0xC0,  // LD HL,$C000
    };
    for (int skip : {0, 100})
        for (int p = 0; p < 5; p++) {
            c.insert(c.end(), {0xF0, 0x44, 0xFE, 0x90, 0x20, 0xFA});  // .v: LDH A,($44); CP 144; JR NZ,.v
            c.insert(c.end(), {0xAF, 0xE0, 0x40});                    // XOR A; LDH ($40),A: the LCD off
            c.insert(c.end(), {0x3E, 0x91, 0xE0, 0x40});              // LD A,$91; LDH ($40),A: on
            c.insert(c.end(), static_cast<size_t>(skip + p), 0x00);    // NOPs
            for (int i = 0; i < 16; i++) c.insert(c.end(), {0xF0, 0x41, 0x22});  // LDH A,($41); LD (HL+),A
        }
    c.insert(c.end(), {
        0x21, 0x00, 0xC0,  // LD HL,$C000
        0x06, static_cast<uint8_t>(kLcdOnSamples),  // LD B,n
        0x2A, 0xE0, 0x01,  // .s: LD A,(HL+); LDH ($01),A
        0x3E, 0x81, 0xE0, 0x02,  // LD A,$81; LDH ($02),A: send it
        0xF0, 0x02, 0xCB, 0x7F, 0x20, 0xFA,  // .w: LDH A,($02); BIT 7,A; JR NZ,.w
        0x05, 0x20, 0xF0,  // DEC B; JR NZ,.s
        0x18, 0xFE,        // JR @
    });
    std::copy(c.begin(), c.end(), rom.begin() + 0x150);
    return rom;
}

// A 32 KB ROM of our own for the Color: the background white (tile 0, colour 0) and the window
// black (tile 1, colour 3), from WY = 0 with WX = 166, the window's left edge at x = 159.
std::vector<uint8_t> wx166_rom() {
    std::vector<uint8_t> rom(0x8000, 0x00);
    const uint8_t entry[] = {0x00, 0xC3, 0x50, 0x01};  // NOP; JP $0150
    std::copy(std::begin(entry), std::end(entry), rom.begin() + 0x100);
    rom[0x143] = 0x80;
    uint8_t x = 0;
    for (int i = 0x134; i <= 0x14C; i++) x = static_cast<uint8_t>(x - rom[i] - 1);
    rom[0x14D] = x;
    const uint8_t code[] = {
        0x31, 0xFE, 0xFF,                    // LD SP,$FFFE
        0xF0, 0x44, 0xFE, 0x90, 0x20, 0xFA,  // .v: LDH A,($44); CP 144; JR NZ,.v
        0xAF, 0xE0, 0x40,                    // XOR A; LDH ($40),A: the LCD off
        0x21, 0x10, 0x80, 0x06, 0x10,        // LD HL,$8010; LD B,16
        0x3E, 0xFF, 0x22, 0x05, 0x20, 0xFA,  // .t: LD A,$FF; LD (HL+),A; DEC B; JR NZ,.t: tile 1, colour 3
        0x21, 0x00, 0x9C, 0x01, 0x00, 0x04,  // LD HL,$9C00; LD BC,$0400
        0x3E, 0x01, 0x22, 0x0B, 0x78, 0xB1, 0x20, 0xF8,  // .w: LD A,1; LD (HL+),A; DEC BC; LD A,B; OR C; JR NZ,.w
        0x3E, 0x80, 0xE0, 0x68,              // LD A,$80; LDH ($68),A: palette 0, stepping
        0x3E, 0xFF, 0xE0, 0x69, 0x3E, 0x7F, 0xE0, 0x69,  // colour 0 white
        0xAF, 0xE0, 0x69, 0xE0, 0x69, 0xE0, 0x69, 0xE0, 0x69, 0xE0, 0x69, 0xE0, 0x69,  // colours 1-3 black
        0xE0, 0x4A,                          // LDH ($4A),A: WY 0
        0x3E, 0xA6, 0xE0, 0x4B,              // LD A,166; LDH ($4B),A: WX
        0x3E, 0xF1, 0xE0, 0x40,              // LD A,$F1; LDH ($40),A: LCD, window (map $9C00), tiles $8000, background
        0x18, 0xFE,                          // JR @
    };
    std::copy(std::begin(code), std::end(code), rom.begin() + 0x150);
    return rom;
}

// The first byte `rom` sends over the serial port, through `boot`.
uint8_t serial_byte(const std::vector<uint8_t>& rom, const std::vector<uint8_t>& boot) {
    auto link = rig::make_gb_sim();
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    gb.hold_reset();
    REQUIRE_FALSE(gb.load(rom, boot));
    for (uint32_t f = 20; f <= 600 && gb.serial_count() == 0; f += 20) {
        gb.stop_frame(f);
        gb.run();
        gb.wait_stopped();
    }
    REQUIRE(gb.serial_count() == 1);
    return gb.serial(0)[0];
}

// A 32 KB ROM of our own: with the LCD off, it sums every RAM a game sees (high RAM below the stack,
// OAM, work RAM's banks 0-7, video RAM's banks 0 and 1, the Color's two palette RAMs; on the Game
// Boy the bank registers do nothing) into 16 bits and sends the sum over the serial port (high byte
// first), then fills them all with $A5 and stops.
std::vector<uint8_t> ram_sum_rom() {
    std::vector<uint8_t> rom(0x8000, 0x00);
    const uint8_t entry[] = {0x00, 0xC3, 0x50, 0x01};  // NOP; JP $0150
    std::copy(std::begin(entry), std::end(entry), rom.begin() + 0x100);
    rom[0x143] = 0x80;
    uint8_t x = 0;
    for (int i = 0x134; i <= 0x14C; i++) x = static_cast<uint8_t>(x - rom[i] - 1);
    rom[0x14D] = x;

    std::vector<uint8_t> c;  // the code, from $0150
    auto op = [&](std::initializer_list<uint8_t> b) { c.insert(c.end(), b); };
    auto here = [&] { return static_cast<int>(c.size()); };
    auto jr_back = [&](uint8_t opcode, int to) {  // JR (cc) back to `to`
        c.push_back(opcode);
        c.push_back(static_cast<uint8_t>(to - (here() + 1)));
    };
    auto ld16 = [&](uint8_t opcode, int v) {
        op({opcode, static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8)});
    };
    enum Sub { SUM, FILL, PORT_SUM, PORT_FILL, SEND, N_SUB };
    int sub[N_SUB] = {};
    std::vector<std::pair<int, Sub>> calls;  // CALLs' operands, patched at the end
    auto call = [&](Sub s) {
        calls.push_back({here() + 1, s});
        op({0xCD, 0x00, 0x00});
    };
    auto region = [&](int start, int len, Sub s) {  // HL the start, BC the length
        ld16(0x21, start);
        ld16(0x01, len);
        call(s);
    };
    auto banked = [&](Sub s) {  // work RAM's banks 1-7, then video RAM's banks 0 and 1
        op({0x3E, 0x01});              // LD A,1: the bank, kept at $FF80
        int b = here();
        op({0xE0, 0x80, 0xE0, 0x70});  // .b: LDH ($80),A; LDH ($70),A (SVBK)
        region(0xD000, 0x1000, s);
        op({0xF0, 0x80, 0x3C, 0xFE, 0x08});  // LDH A,($80); INC A; CP 8
        jr_back(0x20, b);                    // JR NZ,.b
        op({0xAF, 0xE0, 0x4F});              // XOR A; LDH ($4F),A (VBK 0)
        region(0x8000, 0x2000, s);
        op({0x3E, 0x01, 0xE0, 0x4F});        // LD A,1; LDH ($4F),A (VBK 1)
        region(0x8000, 0x2000, s);
    };
    auto palettes = [&](Sub s) {  // the background's and the objects' palette RAM, 64 bytes each
        for (uint8_t idx : {uint8_t{0x68}, uint8_t{0x6A}}) {
            op({0x3E, 0x80, 0xE0, idx});                                // LD A,$80; LDH (idx),A: from 0, stepping
            op({0x0E, static_cast<uint8_t>(idx + 1), 0x06, 0x40});      // LD C,idx+1; LD B,64
            call(s);
        }
    };

    op({0x31, 0xFE, 0xFF});        // LD SP,$FFFE
    int w = here();
    op({0xF0, 0x44, 0xFE, 0x90});  // .w: LDH A,($44); CP 144
    jr_back(0x20, w);              //     JR NZ,.w
    op({0xAF, 0xE0, 0x40});        // XOR A; LDH ($40),A: the LCD off, so video RAM and OAM can be reached
    ld16(0x11, 0);                 // LD DE,0: the sum
    region(0xFF80, 0x7C, SUM);     // high RAM up to $FFFB: the stack is above
    region(0xFE00, 0xA0, SUM);
    region(0xC000, 0x1000, SUM);
    banked(SUM);
    palettes(PORT_SUM);
    op({0x7A});
    call(SEND);  // LD A,D; CALL send
    op({0x7B});
    call(SEND);  // LD A,E; CALL send
    banked(FILL);
    region(0xFF80, 0x7C, FILL);
    region(0xFE00, 0xA0, FILL);
    region(0xC000, 0x1000, FILL);
    palettes(PORT_FILL);
    int stop = here();
    jr_back(0x18, stop);  // JR @

    sub[SUM] = here();  // sum: DE += the BC bytes from HL
    int s = here();
    op({0x2A, 0x83, 0x5F, 0x30, 0x01, 0x14});  // .s: LD A,(HL+); ADD E; LD E,A; JR NC,+1; INC D
    op({0x0B, 0x78, 0xB1});                    //     DEC BC; LD A,B; OR C
    jr_back(0x20, s);                          //     JR NZ,.s
    op({0xC9});                                // RET
    sub[FILL] = here();  // fill: the BC bytes from HL with $A5
    int f = here();
    op({0x3E, 0xA5, 0x22, 0x0B, 0x78, 0xB1});  // .f: LD A,$A5; LD (HL+),A; DEC BC; LD A,B; OR C
    jr_back(0x20, f);
    op({0xC9});
    sub[PORT_SUM] = here();  // port_sum: DE += B reads of the port at $FF00+C
    int ps = here();
    op({0xF2, 0x83, 0x5F, 0x30, 0x01, 0x14, 0x05});  // .p: LD A,($FF00+C); ADD E; LD E,A; JR NC,+1; INC D; DEC B
    jr_back(0x20, ps);
    op({0xC9});
    sub[PORT_FILL] = here();  // port_fill: B writes of $A5 to the port at $FF00+C
    int pf = here();
    op({0x3E, 0xA5, 0xE2, 0x05});  // .q: LD A,$A5; LD ($FF00+C),A; DEC B
    jr_back(0x20, pf);
    op({0xC9});
    sub[SEND] = here();  // send: A over the serial port, then wait for it to go
    op({0xE0, 0x01, 0x3E, 0x81, 0xE0, 0x02});  // LDH ($01),A; LD A,$81; LDH ($02),A
    int sw = here();
    op({0xF0, 0x02, 0xCB, 0x7F});  // .w: LDH A,($02); BIT 7,A
    jr_back(0x20, sw);
    op({0xC9});

    for (auto [at, which] : calls) {
        const int addr = 0x150 + sub[which];
        c[static_cast<size_t>(at)] = static_cast<uint8_t>(addr);
        c[static_cast<size_t>(at) + 1] = static_cast<uint8_t>(addr >> 8);
    }
    std::copy(c.begin(), c.end(), rom.begin() + 0x150);
    return rom;
}

// The sums ram_sum_rom() sends, run `times` times in one system through `boot`, the host holding it
// in reset and loading the ROM again between runs, as rig-run does from game to game.
std::vector<uint16_t> ram_sums(const std::vector<uint8_t>& boot, int times) {
    auto link = rig::make_gb_sim();
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    std::vector<uint16_t> sums;
    for (int t = 0; t < times; t++) {
        gb.hold_reset();
        REQUIRE_FALSE(gb.load(ram_sum_rom(), boot));
        const uint32_t from = gb.serial_count();
        for (uint32_t f = 20; f <= 600 && gb.serial_count() < from + 2; f += 20) {
            gb.stop_frame(f);
            gb.run();
            gb.wait_stopped();
        }
        REQUIRE(gb.serial_count() == from + 2);
        const auto b = gb.serial(from);
        sums.push_back(static_cast<uint16_t>(b[0] << 8 | b[1]));
    }
    return sums;
}

}  // namespace

TEST_CASE("Game Boy Color through the shell: each ROM starts from the RAM MesenCE powers up with, whatever ran before") {
    // MesenCE (RamPowerOnState AllZeros) starts every game with its RAM zeroed, so a game the host
    // loads after another mustn't see what the other left.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    for (const char* model : {"cgb", "dmg"}) {
        const auto boot = read_file(roms + "/" + rig::gb::boot_for(model));
        if (boot.empty()) SKIP("the boot ROMs aren't fetched");
        INFO(model);
        const auto sums = ram_sums(boot, 2);
        CHECK(sums[0] == sums[1]);
    }
}

TEST_CASE("Game Boy Color through the shell: with the LCD off, blank frames end at MesenCE's dots") {
    // MesenCE ends a blank frame once its dot count is more than 70,224 past the last frame, the
    // count stepping 2 at a time at normal speed: 70,226 dots apart, from 0 at power-up. Every Color
    // game's first two frames come so, in the boot ROM, at MesenCE's 70,226 and 140,452.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto boot = read_file(roms + "/" + rig::gb::boot_for("cgb"));
    if (boot.empty()) SKIP("the boot ROMs aren't fetched");
    auto link = rig::make_gb_sim();
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    gb.hold_reset();
    REQUIRE_FALSE(gb.load(ram_sum_rom(), boot));
    gb.stop_frame(1);
    gb.run();
    gb.wait_stopped();
    CHECK(gb.cycles() == 70226);
    gb.stop_frame(2);
    gb.run();
    gb.wait_stopped();
    CHECK(gb.cycles() == 140452);
}

TEST_CASE("Game Boy Color through the shell: an OAM DMA from work RAM leaves the ROM's bus free, as MesenCE has it") {
    // The Color's work RAM has its own bus: a DMA from it conflicts with $A000-$FDFF only (MesenCE's
    // three buses; SameBoy's agree here). The Game Boy's work RAM and cartridge share one bus.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto cgb = read_file(roms + "/" + rig::gb::boot_for("cgb"));
    const auto dmg = read_file(roms + "/" + rig::gb::boot_for("dmg"));
    if (cgb.empty() || dmg.empty()) SKIP("the boot ROMs aren't fetched");
    CHECK(serial_byte(dma_bus_rom(), cgb) == 0x5A);
    CHECK(serial_byte(dma_bus_rom(), dmg) == 0xEE);
}

TEST_CASE("Game Boy Color through the shell: STOP switches the speed with an interrupt pending, as MesenCE and SameBoy do") {
    // With a switch armed, STOP switches the speed whether or not IE & IF has a bit set (MesenCE's
    // STOP doesn't look; SameBoy's switches and only skips the pause). Turok: Rage Wars switches with
    // one pending and waits for KEY1 bit 7. KEY1 then reads $FE: double speed, nothing armed.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto cgb = read_file(roms + "/" + rig::gb::boot_for("cgb"));
    if (cgb.empty()) SKIP("the boot ROMs aren't fetched");
    CHECK(serial_byte(speed_switch_pending_rom(), cgb) == 0xFE);
}

TEST_CASE("Game Boy Color through the shell: WX = 166 shows the window's first pixel at x = 159, as MesenCE and SameBoy do") {
    // On the Color, WX = 166 is like any other WX: the window starts at x = WX - 7, and doesn't carry
    // on into the next line (that's the Game Boy's, in SameBoy). Bionic Commando: Elite Forces sets
    // WY = 143 and WX = 166 on its title screen.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto cgb = read_file(roms + "/" + rig::gb::boot_for("cgb"));
    if (cgb.empty()) SKIP("the boot ROMs aren't fetched");
    auto link = rig::make_gb_sim();
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    gb.hold_reset();
    REQUIRE_FALSE(gb.load(wx166_rom(), cgb));
    gb.stop_frame(300);
    gb.run();
    gb.wait_stopped();
    const auto f = gb.frame();
    for (int y : {0, 1, 72, 143}) {
        INFO("line " << y);
        CHECK(f[static_cast<size_t>(y) * 160 + 0] == 0x7FFF);
        CHECK(f[static_cast<size_t>(y) * 160 + 158] == 0x7FFF);
        CHECK(f[static_cast<size_t>(y) * 160 + 159] == 0x0000);
    }
}

TEST_CASE("Game Boy through the shell: a game's cartridge RAM reads back while it's stopped at a frame, and it runs on") {
    // rig-run play keeps a battery game's saves as it plays: it sees the game write its RAM
    // (cart_writes), stops it at a frame's end, reads the RAM and lets it run on.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto golden = rig::gb::load_golden(RS_GB_GOLDEN);
    auto g = std::find_if(golden.begin(), golden.end(), [](auto& x) { return x.id == "dmg_sound-01"; });
    REQUIRE(g != golden.end());
    const auto rom = read_file(roms + "/" + g->path);
    if (rom.empty()) SKIP("no " << roms << "/" << g->path);
    const auto boot = read_file(roms + "/" + rig::gb::boot_for(g->model));
    if (boot.empty()) SKIP("the boot ROMs aren't fetched");
    auto link = rig::make_gb_sim();
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    gb.hold_reset();
    REQUIRE_FALSE(gb.load(rom, boot));
    CHECK(gb.cart_writes() == 0);
    // blargg's ROM writes its signature, DE B0 61 at $A001, as it starts.
    uint32_t f = 0;
    for (f = 10; f <= 300 && (gb.cart_head() >> 8) != 0x61B0DE; f += 10) {
        gb.stop_frame(f);
        gb.run();
        gb.wait_stopped();
    }
    REQUIRE((gb.cart_head() >> 8) == 0x61B0DE);
    const uint32_t w = gb.cart_writes();
    CHECK(w > 0);
    const auto live = gb.cart_ram_stopped(rom);
    REQUIRE(live.size() == 8192);
    CHECK(live[1] == 0xDE);
    CHECK(live[2] == 0xB0);
    CHECK(live[3] == 0x61);
    CHECK(gb.cart_writes() == w);  // stopped, nothing counts
    // It runs on from there, its RAM as the read left it.
    gb.stop_frame(f + 20);
    gb.wait_stopped();
    CHECK(gb.frames() == f + 20);
    const auto later = gb.cart_ram_stopped(rom);
    CHECK((gb.cart_head() >> 8) == 0x61B0DE);
    // And what it reads stopped is what it reads held in reset.
    CHECK(gb.cart_ram(rom) == later);
}

TEST_CASE("Game Boy Color through the shell: an HBlank DMA moves no block as line 0 starts after VBlank, as MesenCE has it") {
    // The PPU's STAT reads mode 0 for a dot as each line starts (SameBoy's timing); after VBlank
    // that isn't an HBlank, and the DMA mustn't take it for one. A Bug's Life's HBlank DMAs across
    // VBlank ended a line early, and the game a frame ahead of MesenCE.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto cgb = read_file(roms + "/" + rig::gb::boot_for("cgb"));
    if (cgb.empty()) SKIP("the boot ROMs aren't fetched");
    CHECK(serial_byte(hdma_vblank_rom(), cgb) == 3);
}

TEST_CASE("Game Boy through the shell: with the LCD off, the frame is the screen's blank white (31), not shade 0, as MesenCE has it") {
    // MesenCE draws a frame with the LCD off in pure white, outside the four shades (its blue channel,
    // which the CRC takes on the Game Boy, at 31); a real Game Boy's blank screen is lighter than shade
    // 0 too. Q*bert, Primal Rage, Pocahontas and others turn the LCD off at their frame 600.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto boot = read_file(roms + "/" + rig::gb::boot_for("dmg"));
    if (boot.empty()) SKIP("the boot ROMs aren't fetched");
    auto link = rig::make_gb_sim();
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    gb.hold_reset();
    REQUIRE_FALSE(gb.load(lcd_off_rom(), boot));
    gb.stop_frame(300);
    gb.run();
    gb.wait_stopped();
    const auto f = gb.frame();
    CHECK(std::count(f.begin(), f.end(), uint16_t{31}) == 160 * 144);
    const auto crc = gb.frame_crc();
    REQUIRE(crc);
    CHECK(crc->first == 0xf31b3bd0u);  // MesenCE's, 23,040 pixels of 31
}

namespace {
std::vector<uint8_t> serial_bytes(const std::vector<uint8_t>& rom, const std::vector<uint8_t>& boot, uint32_t n) {
    auto link = rig::make_gb_sim();
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    gb.hold_reset();
    REQUIRE_FALSE(gb.load(rom, boot));
    for (uint32_t f = 20; f <= 600 && gb.serial_count() < n; f += 20) {
        gb.stop_frame(f);
        gb.run();
        gb.wait_stopped();
    }
    REQUIRE(gb.serial_count() == n);
    return gb.serial(0);
}
}  // namespace

TEST_CASE("Game Boy Color through the shell: the LCD starts at the same dot against the CPU as on the Game Boy") {
    // The Color's LCDC write lands a dot later than the Game Boy's (as the M-cycle ends), and the
    // Game Boy's PPU waits a dot more as the LCD turns on (SameBoy's timing): either way the first line
    // starts at the same dot, so STAT reads alike, M-cycle by M-cycle, on both (MesenCE too). Started
    // a dot late, the Color's mode 2 interrupt came an M-cycle late, and every mid-line register write
    // after it (Mealybug Tearoom's m3_ tests) landed 4 dots late.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto cgb = read_file(roms + "/" + rig::gb::boot_for("cgb"));
    const auto dmg = read_file(roms + "/" + rig::gb::boot_for("dmg"));
    if (cgb.empty() || dmg.empty()) SKIP("the boot ROMs aren't fetched");
    const auto on_dmg = serial_bytes(lcd_on_stat_rom(), dmg, kLcdOnSamples);
    const auto on_cgb = serial_bytes(lcd_on_stat_rom(), cgb, kLcdOnSamples);
    CHECK(on_cgb == on_dmg);
}
