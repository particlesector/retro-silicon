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

// The byte dma_bus_rom() sends, through `boot`.
uint8_t dma_bus_byte(const std::vector<uint8_t>& boot) {
    auto link = rig::make_gb_sim();
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    gb.hold_reset();
    REQUIRE_FALSE(gb.load(dma_bus_rom(), boot));
    for (uint32_t f = 20; f <= 600 && gb.serial_count() == 0; f += 20) {
        gb.stop_frame(f);
        gb.run();
        gb.wait_stopped();
    }
    REQUIRE(gb.serial_count() == 1);
    return gb.serial(0)[0];
}

}  // namespace

TEST_CASE("Game Boy Color through the shell: an OAM DMA from work RAM leaves the ROM's bus free, as MesenCE has it") {
    // The Color's work RAM has its own bus: a DMA from it conflicts with $A000-$FDFF only (MesenCE's
    // three buses; SameBoy's agree here). The Game Boy's work RAM and cartridge share one bus.
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto cgb = read_file(roms + "/" + rig::gb::boot_for("cgb"));
    const auto dmg = read_file(roms + "/" + rig::gb::boot_for("dmg"));
    if (cgb.empty() || dmg.empty()) SKIP("the boot ROMs aren't fetched");
    CHECK(dma_bus_byte(cgb) == 0x5A);
    CHECK(dma_bus_byte(dmg) == 0xEE);
}
