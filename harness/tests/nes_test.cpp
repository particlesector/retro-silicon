// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <sstream>
#include <string>
#include <variant>
#include <vector>

#include "golden.hpp"
#include "rig/ines.hpp"
#include "rig/nes.hpp"
#include "rig/shell.hpp"
#include "rig/sim_systems.hpp"

namespace {

std::vector<uint8_t> header(uint8_t prg, uint8_t chr, uint8_t f6, uint8_t f7) {
    std::vector<uint8_t> h(16 + prg * 16384u + chr * 8192u, 0xEE);
    const uint8_t start[] = {'N', 'E', 'S', 0x1A, prg, chr, f6, f7, 0, 0, 0, 0, 0, 0, 0, 0};
    std::copy(std::begin(start), std::end(start), h.begin());
    return h;
}

} // namespace

TEST_CASE("iNES headers give the mapper, mirroring, battery and sizes") {
    auto f = header(2, 1, 0x13, 0x40);  // mapper $41: low nibble from byte 6, high from 7
    f[16] = 0xAA;
    f[16 + 32768] = 0xBB;
    auto r = rig::parse_ines(f);
    REQUIRE(std::holds_alternative<rig::NesRom>(r));
    auto& rom = std::get<rig::NesRom>(r);
    CHECK(rom.mapper == 0x41);
    CHECK(rom.mirroring == rig::NesRom::Mirroring::kVertical);
    CHECK(rom.battery);
    CHECK_FALSE(rom.nes2);
    CHECK(rom.prg.size() == 32768);
    CHECK(rom.prg[0] == 0xAA);
    CHECK(rom.chr.size() == 8192);
    CHECK(rom.chr[0] == 0xBB);
}

TEST_CASE("iNES parsing skips a trainer, reads NES 2.0 mapper bits and ignores old dumps' junk") {
    auto t = header(1, 0, 0x04, 0x00);
    t.insert(t.begin() + 16, 512, 0x55);  // trainer
    t[16 + 512] = 0x77;
    auto a = std::get<rig::NesRom>(rig::parse_ines(t));
    CHECK(a.prg[0] == 0x77);
    CHECK(a.chr.empty());

    auto n2 = header(1, 0, 0x10, 0x08);
    n2[8] = 0x02;  // mapper bits 8-11
    auto b = std::get<rig::NesRom>(rig::parse_ines(n2));
    CHECK(b.nes2);
    CHECK(b.mapper == 0x201);

    auto junk = header(1, 0, 0x10, 0x44);  // "DiskDude!"-style text in bytes 7-15
    CHECK(std::get<rig::NesRom>(rig::parse_ines(junk)).mapper == 1);
}

TEST_CASE("iNES parsing rejects files that aren't ROMs or are cut short") {
    std::vector<uint8_t> none{'N', 'E', 'S'};
    CHECK(std::holds_alternative<std::string>(rig::parse_ines(none)));
    auto f = header(2, 0, 0, 0);
    f.resize(f.size() - 1);
    CHECK(std::holds_alternative<std::string>(rig::parse_ines(f)));
}

namespace {

// A ROM from harness/golden/nes_frames_crc32.txt, or a skip if the test
// ROMs haven't been fetched.
std::pair<rig::nes::GoldenRom, rig::NesRom> golden_rom(const std::string& id) {
    auto golden = rig::nes::load_golden_roms(RS_NES_FRAMES_GOLDEN);
    auto g = std::find_if(golden.begin(), golden.end(), [&](auto& x) { return x.check.id == id; });
    REQUIRE(g != golden.end());
    std::string path = std::string(RS_TESTROMS) + "/nes-test-roms/" + g->path;
    if (!std::filesystem::exists(path)) SKIP(path << " not found: run testroms/fetch.py");
    auto rom = rig::load_ines(path);
    REQUIRE(std::holds_alternative<rig::NesRom>(rom));
    return {*g, std::get<rig::NesRom>(rom)};
}

// Runs a ROM in the sim to its golden frame: it must pass its own check and
// show MesenCE's frame. `bram` runs it as the Tang Console 138K does.
void matches_mesen(const std::string& id, bool bram = false) {
    auto [g, rom] = golden_rom(id);
    auto link = bram ? rig::make_nes_bram_sim() : rig::make_nes_sim();
    auto r = rig::nes::rom_test(*link, g.check, rom, g.frames, bram ? RS_NES_BRAM_BUILD_ID : RS_NES_BUILD_ID);
    INFO(r.detail << " / " << r.notes);
    CHECK(r.passed);
    CHECK(r.crc32 == g.crc);
}

} // namespace

#define MATCHES_MESEN(id) \
    TEST_CASE(id " passes in the sim and its frame matches MesenCE's") { matches_mesen(id); }

// The same on block RAM at a 50 MHz clock's rates, as the Tang Console 138K
// runs it: a few ROMs whose timing is the most sensitive.
#define MATCHES_MESEN_BRAM(id) \
    TEST_CASE(id " matches MesenCE's frame on block RAM at 50 MHz") { matches_mesen(id, true); }

MATCHES_MESEN_BRAM("oam_read")
MATCHES_MESEN_BRAM("ppu_vbl_nmi-10")
MATCHES_MESEN_BRAM("sprite_hit-09")
MATCHES_MESEN_BRAM("nmi_sync")

TEST_CASE("a save-state round trip gives the uninterrupted run's frames, trace and cycles") {
    for (const char* id : {"nmi_sync", "sprite_overflow-3"}) {
        auto [g, rom] = golden_rom(id);
        auto link = rig::make_nes_sim();
        auto r = rig::nes::state_test(*link, rom, g.frames / 3, g.frames, RS_NES_BUILD_ID);
        INFO(id << ": " << r.detail << " / " << r.notes);
        CHECK(r.passed);
        CHECK(r.crc32 == g.crc);
    }
}

TEST_CASE("a state saved on SDRAM at 27 MHz finishes the same on block RAM at 50 MHz") {
    auto [g, rom] = golden_rom("sprite_hit-09");
    auto a = rig::make_nes_sim();
    rig::shell::Client ca(*a);
    rig::nes::Console na(ca);
    na.hold_reset();
    REQUIRE_FALSE(na.load(rom));
    na.set_vector(std::nullopt);
    na.stop_frame(g.frames / 2);
    na.run();
    na.wait_stopped();
    auto state = na.save_state();
    uint32_t trace_a = na.trace_crc();

    auto b = rig::make_nes_bram_sim();
    rig::shell::Client cb(*b);
    rig::nes::Console nb(cb);
    nb.hold_reset();
    REQUIRE_FALSE(nb.load(rom));  // PRG, CHR and the cartridge registers aren't part of a state
    nb.load_state(state);
    CHECK(nb.frames() == g.frames / 2);
    CHECK(nb.trace_crc() == trace_a);
    nb.stop_frame(g.frames);
    nb.run();
    uint8_t st = nb.wait_stopped();
    CHECK((st & (rig::nes::kHalted | rig::nes::kLate)) == 0);
    auto crc = nb.frame_crc();
    REQUIRE(crc);
    CHECK(crc->first == g.crc);
    CHECK(crc->second == g.frames - 1);
}

TEST_CASE("nestest on block RAM at 50 MHz has the CPU bench's trace CRC") {
    std::string path = std::string(RS_TESTROMS) + "/nes-test-roms/other/nestest.nes";
    if (!std::filesystem::exists(path)) SKIP(path << " not found: run testroms/fetch.py");
    auto golden = golden_crcs(RS_NES_TRACE_GOLDEN);
    auto it = golden.find({rig::nes::kNestestCycles, 0});
    REQUIRE(it != golden.end());
    auto rom = rig::load_ines(path);
    REQUIRE(std::holds_alternative<rig::NesRom>(rom));
    auto link = rig::make_nes_bram_sim();
    auto r = rig::nes::nestest(*link, std::get<rig::NesRom>(rom), rig::nes::kNestestCycles, RS_NES_BRAM_BUILD_ID);
    INFO(r.detail << " / " << r.notes);
    REQUIRE(r.passed);
    REQUIRE(r.crc32 == it->second);
}

MATCHES_MESEN("ppu_open_bus")
MATCHES_MESEN("oam_read")
MATCHES_MESEN("ppu_vbl_nmi-01")
MATCHES_MESEN("ppu_vbl_nmi-02")
MATCHES_MESEN("ppu_vbl_nmi-03")
MATCHES_MESEN("ppu_vbl_nmi-04")
MATCHES_MESEN("ppu_vbl_nmi-05")
MATCHES_MESEN("ppu_vbl_nmi-06")
MATCHES_MESEN("ppu_vbl_nmi-07")
MATCHES_MESEN("ppu_vbl_nmi-08")
MATCHES_MESEN("ppu_vbl_nmi-09")
MATCHES_MESEN("ppu_vbl_nmi-10")
MATCHES_MESEN("sprite_hit-01")
MATCHES_MESEN("sprite_hit-02")
MATCHES_MESEN("sprite_hit-03")
MATCHES_MESEN("sprite_hit-04")
MATCHES_MESEN("sprite_hit-05")
MATCHES_MESEN("sprite_hit-06")
MATCHES_MESEN("sprite_hit-07")
MATCHES_MESEN("sprite_hit-08")
MATCHES_MESEN("sprite_hit-09")
MATCHES_MESEN("sprite_hit-10")
MATCHES_MESEN("sprite_hit-11")
MATCHES_MESEN("sprite_overflow-1")
MATCHES_MESEN("sprite_overflow-2")
MATCHES_MESEN("sprite_overflow-3")
MATCHES_MESEN("sprite_overflow-4")
MATCHES_MESEN("sprite_overflow-5")
MATCHES_MESEN("vbl_nmi_timing-1")
MATCHES_MESEN("vbl_nmi_timing-2")
MATCHES_MESEN("vbl_nmi_timing-3")
MATCHES_MESEN("vbl_nmi_timing-4")
MATCHES_MESEN("vbl_nmi_timing-5")
MATCHES_MESEN("vbl_nmi_timing-6")
MATCHES_MESEN("vbl_nmi_timing-7")
MATCHES_MESEN("blargg_ppu-palette_ram")
MATCHES_MESEN("blargg_ppu-power_up_palette")
MATCHES_MESEN("blargg_ppu-sprite_ram")
MATCHES_MESEN("blargg_ppu-vbl_clear_time")
MATCHES_MESEN("blargg_ppu-vram_access")
MATCHES_MESEN("nmi_sync")
MATCHES_MESEN("full_palette")

TEST_CASE("nestest passes on the sim backend with the CPU bench's trace CRC") {
    std::string path = std::string(RS_TESTROMS) + "/nes-test-roms/other/nestest.nes";
    if (!std::filesystem::exists(path)) SKIP(path << " not found: run testroms/fetch.py");
    auto golden = golden_crcs(RS_NES_TRACE_GOLDEN);
    auto it = golden.find({rig::nes::kNestestCycles, 0});
    REQUIRE(it != golden.end());

    auto rom = rig::load_ines(path);
    REQUIRE(std::holds_alternative<rig::NesRom>(rom));
    auto link = rig::make_nes_sim();
    auto r = rig::nes::nestest(*link, std::get<rig::NesRom>(rom), rig::nes::kNestestCycles, RS_NES_BUILD_ID);
    INFO(r.detail << " / " << r.notes);
    REQUIRE(r.passed);
    REQUIRE(r.crc32 == it->second);
}

TEST_CASE("a test after nestest on the same system isn't held by the limits nestest left") {
    std::string path = std::string(RS_TESTROMS) + "/nes-test-roms/other/nestest.nes";
    if (!std::filesystem::exists(path)) SKIP(path << " not found: run testroms/fetch.py");
    auto nestest_rom = rig::load_ines(path);
    REQUIRE(std::holds_alternative<rig::NesRom>(nestest_rom));
    auto [g, rom] = golden_rom("oam_read");
    auto link = rig::make_nes_sim();  // one system for both, as on a board
    REQUIRE(rig::nes::nestest(*link, std::get<rig::NesRom>(nestest_rom), rig::nes::kNestestCycles, RS_NES_BUILD_ID).passed);
    auto r = rig::nes::rom_test(*link, g.check, rom, g.frames, RS_NES_BUILD_ID);
    INFO(r.detail << " / " << r.notes);
    CHECK(r.passed);
    CHECK(r.crc32 == g.crc);
}
