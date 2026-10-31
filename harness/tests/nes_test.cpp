// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <map>
#include <sstream>
#include <string>
#include <variant>
#include <vector>

#include "golden.hpp"
#include "nes_rom.hpp"
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

// Runs a ROM in the sim to its golden frame: it must pass its own check and
// show MesenCE's frame. `bram` runs it as the Tang Console 138K does.
enum class Sim { kDefault, kBram, kExt, kAxi };

void matches_mesen(const std::string& id, Sim sim = Sim::kDefault) {
    auto [g, rom] = golden_rom(id);
    bool bram = sim == Sim::kBram;
    auto link = bram ? rig::make_nes_bram_sim()
                : sim == Sim::kExt ? rig::make_nes_ext_sim()
                : sim == Sim::kAxi ? rig::make_nes_axi_sim()
                                   : rig::make_nes_sim();
    uint32_t build_id = bram ? RS_NES_BRAM_BUILD_ID : sim == Sim::kAxi ? RS_NES_AXI_BUILD_ID : RS_NES_BUILD_ID;
    auto r = rig::nes::rom_test(*link, g.check, rom, g.frames, build_id);
    INFO(r.detail << " / " << r.notes);
    CHECK(r.passed);
    CHECK(r.crc32 == g.crc);
    // The APU's levels through to that frame: the board's must match.
    auto audio = rig::nes::load_golden_audio(RS_NES_AUDIO_GOLDEN);
    if (!audio.count(id) && r.audio_crc32)
        FAIL("no audio CRC for " << id << " in nes_audio_crc32.txt; the sim's: " << id << " " << g.frames << " 0x"
                                 << std::hex << std::setw(8) << std::setfill('0') << *r.audio_crc32);
    CHECK(r.audio_crc32 == audio[id]);
}

} // namespace

#define MATCHES_MESEN(id) \
    TEST_CASE(id " passes in the sim and its frame matches MesenCE's") { matches_mesen(id); }

// The same on block RAM at a 50 MHz clock's rates, as the Tang Console 138K
// runs it: a few ROMs whose timing is the most sensitive.
#define MATCHES_MESEN_BRAM(id) \
    TEST_CASE(id " matches MesenCE's frame on block RAM at 50 MHz") { matches_mesen(id, Sim::kBram); }

// The same as the Tang Nano 20K runs it, with CHR ROM bigger than CHR's
// block RAM in the SDRAM.
#define MATCHES_MESEN_EXT(id) \
    TEST_CASE(id " matches MesenCE's frame with its CHR ROM in the SDRAM") { matches_mesen(id, Sim::kExt); }

// Another power-up: RAM all 0xFF, or another CPU/PPU alignment, against
// MesenCE's frame at the same (tools/mesen/frames.py --ram, --lead). These are
// ROMs whose frame changes with it.
namespace {

void matches_mesen_power(const std::string& id, const std::string& file, const rig::nes::PowerUp& p) {
    auto [g, rom] = golden_rom(id, file);
    auto link = rig::make_nes_sim();
    auto r = rig::nes::rom_test(*link, g.check, rom, g.frames, RS_NES_BUILD_ID, false, p);
    INFO(r.detail << " / " << r.notes);
    CHECK(r.passed);
    CHECK(r.crc32 == g.crc);
}

rig::nes::PowerUp ones() { rig::nes::PowerUp p; p.fill = rig::nes::PowerUp::kOnes; return p; }
rig::nes::PowerUp lead(int dots) { rig::nes::PowerUp p; p.lead_dots = static_cast<uint8_t>(dots); return p; }

} // namespace

#define MATCHES_MESEN_ONES(id) \
    TEST_CASE(id " matches MesenCE's frame with RAM powered up all 0xFF") { \
        matches_mesen_power(id, RS_NES_FRAMES_ONES_GOLDEN, ones()); \
    }
#define MATCHES_MESEN_LEAD(id, dots) \
    TEST_CASE(id " matches MesenCE's frame at the CPU/PPU alignment of " #dots " lead dots") { \
        matches_mesen_power(id, RS_NES_FRAMES_LEAD##dots##_GOLDEN, lead(dots)); \
    }

MATCHES_MESEN_ONES("blargg_apu-01")
MATCHES_MESEN_ONES("blargg_apu-07")
MATCHES_MESEN_LEAD("full_palette", 6)
MATCHES_MESEN_LEAD("full_palette", 7)

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

TEST_CASE("a save-state round trip keeps the mapper's state: MMC3 mid-IRQ test, MMC1 mid-probe") {
    // mmc3_irq-4 times IRQs to the scanline; Holy Mapperel probes MMC1's
    // banks in its first frames.
    for (auto [id, at] : {std::pair{"mmc3_irq-4", 40u}, std::pair{"mapperel-mmc1-cr8k", 30u}}) {
        auto [g, rom] = golden_rom(id);
        auto link = rig::make_nes_sim();
        auto r = rig::nes::state_test(*link, rom, at, g.frames, RS_NES_BUILD_ID);
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
MATCHES_MESEN("apu_test-1")
MATCHES_MESEN("apu_test-2")
MATCHES_MESEN("apu_test-3")
MATCHES_MESEN("apu_test-4")
MATCHES_MESEN("apu_test-5")
MATCHES_MESEN("apu_test-6")
MATCHES_MESEN("apu_test-7")
MATCHES_MESEN("apu_test-8")
MATCHES_MESEN("cpu_interrupts-1")
MATCHES_MESEN("cpu_interrupts-2")
MATCHES_MESEN("cpu_interrupts-3")
MATCHES_MESEN("cpu_interrupts-4")
MATCHES_MESEN("cpu_interrupts-5")
MATCHES_MESEN("instr_misc-01")
MATCHES_MESEN("instr_misc-02")
MATCHES_MESEN("instr_misc-03")
MATCHES_MESEN("instr_timing-2")
MATCHES_MESEN("sprdma_and_dmc_dma")
MATCHES_MESEN("sprdma_and_dmc_dma-512")
MATCHES_MESEN("apu_mixer-square")
MATCHES_MESEN("apu_mixer-triangle")
MATCHES_MESEN("apu_mixer-noise")
MATCHES_MESEN("apu_mixer-dmc")
MATCHES_MESEN("thwaite")
MATCHES_MESEN("croom")
MATCHES_MESEN("thwaite-play")
MATCHES_MESEN("croom-play")
MATCHES_MESEN("blargg_apu-01")
MATCHES_MESEN("blargg_apu-02")
MATCHES_MESEN("blargg_apu-03")
MATCHES_MESEN("blargg_apu-04")
MATCHES_MESEN("blargg_apu-05")
MATCHES_MESEN("blargg_apu-06")
MATCHES_MESEN("blargg_apu-07")
MATCHES_MESEN("blargg_apu-08")
MATCHES_MESEN("blargg_apu-09")
MATCHES_MESEN("blargg_apu-10")
MATCHES_MESEN("blargg_apu-11")

// The all-in-one blargg ROMs, on MMC1, and Holy Mapperel's mapper checks on
// the cartridges whose CHR fits this system's 8 KB of CHR block RAM.
MATCHES_MESEN("instr_test-official")
MATCHES_MESEN("cpu_interrupts")
MATCHES_MESEN("ppu_vbl_nmi")
MATCHES_MESEN("apu_test")
MATCHES_MESEN("mapperel-nrom")
MATCHES_MESEN("mapperel-unrom")
MATCHES_MESEN("mapperel-aorom")
MATCHES_MESEN("mapperel-mmc1-cr8k")
MATCHES_MESEN("mapperel-mmc1-p512k")
MATCHES_MESEN("mapperel-mmc3-cr8k")
// blargg's MMC3 IRQ tests, the older and the newer, for revision B.
MATCHES_MESEN("mmc3_irq-1")
MATCHES_MESEN("mmc3_irq-2")
MATCHES_MESEN("mmc3_irq-3")
MATCHES_MESEN("mmc3_irq-4")
MATCHES_MESEN("mmc3_irq-6")
MATCHES_MESEN("mmc3_test-1")
MATCHES_MESEN("mmc3_test-2")
MATCHES_MESEN("mmc3_test-3")
MATCHES_MESEN("mmc3_test-5")
MATCHES_MESEN_EXT("mapperel-cnrom")
MATCHES_MESEN_EXT("mapperel-mmc1-c32k")
MATCHES_MESEN_EXT("mapperel-mmc1-c128k")
MATCHES_MESEN_EXT("mapperel-mmc3-c256k")
// As the PYNQ-Z2 runs it, PRG ROM in its DDR3 (an AXI memory model that
// stalls at random): the largest ROMs, and timing-sensitive ones.
#define MATCHES_MESEN_AXI(id) \
    TEST_CASE(id " matches MesenCE's frame with its PRG ROM behind AXI, as in the PYNQ-Z2's DDR3") { \
        matches_mesen(id, Sim::kAxi); \
    }
MATCHES_MESEN_AXI("mapperel-mmc1-p512k")
MATCHES_MESEN_AXI("mapperel-mmc3-c256k")
MATCHES_MESEN_AXI("mmc3_irq-4")
MATCHES_MESEN_AXI("oam_read")
MATCHES_MESEN_AXI("cpu_interrupts-5")
// 256 KB MMC1 ROMs, whose bank switches the cache and its prefetch have to follow.
MATCHES_MESEN_AXI("ppu_vbl_nmi")
MATCHES_MESEN_AXI("instr_test-official")

// And ROMs with 8 KB of CHR ROM put there on purpose: the same frames as
// from block RAM.
#define MATCHES_MESEN_IN_SDRAM(id) \
    TEST_CASE(id " matches MesenCE's frame with its 8 KB of CHR ROM read from the SDRAM") { \
        auto [g, rom] = golden_rom(id); \
        auto link = rig::make_nes_ext_sim(); \
        auto r = rig::nes::rom_test(*link, g.check, rom, g.frames, RS_NES_BUILD_ID, true); \
        INFO(r.detail << " / " << r.notes); \
        CHECK(r.passed); \
        CHECK(r.crc32 == g.crc); \
    }
MATCHES_MESEN_IN_SDRAM("oam_read")
MATCHES_MESEN_IN_SDRAM("thwaite-play")
MATCHES_MESEN_IN_SDRAM("ppu_open_bus")
MATCHES_MESEN_IN_SDRAM("mapperel-nrom")

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

TEST_CASE("the trace buffer holds nestest's last cycles as nestest.log has them") {
    std::string path = std::string(RS_TESTROMS) + "/nes-test-roms/other/nestest.nes";
    std::string log = std::string(RS_TESTROMS) + "/nes-test-roms/other/nestest.log";
    if (!std::filesystem::exists(path)) SKIP(path << " not found: run testroms/fetch.py");
    auto rom = rig::load_ines(path);
    REQUIRE(std::holds_alternative<rig::NesRom>(rom));
    auto link = rig::make_nes_sim();
    // Stopped twice: early, and at the log's end.
    for (uint32_t cycles : {5000u, rig::nes::kNestestCycles}) {
        auto r = rig::nes::nestest(*link, std::get<rig::NesRom>(rom), cycles, RS_NES_BUILD_ID, log);
        INFO(cycles << ": " << r.detail << " / " << r.notes);
        REQUIRE(r.passed);
        REQUIRE(r.notes.find("cycles match nestest.log") != std::string::npos);
    }
}

TEST_CASE("compare_nestest_log finds a trace that differs from nestest.log") {
    std::string log = std::string(RS_TESTROMS) + "/nes-test-roms/other/nestest.log";
    if (!std::filesystem::exists(log)) SKIP(log << " not found: run testroms/fetch.py");
    // nestest.log's first instructions: JMP $C5F5 at cycle 7, then LDX #$00 at 10.
    using E = rig::nes::TraceEntry;
    std::vector<E> t = {{7, 0xC000, 0x4C, false, true}, {8, 0xC001, 0xF5, false, false},
                        {9, 0xC002, 0xC5, false, false}, {10, 0xC5F5, 0xA2, false, true}};
    CHECK_FALSE(rig::nes::compare_nestest_log(t, log).has_value());
    auto bad = t;
    bad[3].addr = 0xC5F6;  // the wrong PC
    CHECK(rig::nes::compare_nestest_log(bad, log).has_value());
    bad = t;
    bad[1].sync = true;  // a fetch where there's none
    CHECK(rig::nes::compare_nestest_log(bad, log).has_value());
    bad = t;
    bad[3].sync = false;  // an instruction missed
    CHECK(rig::nes::compare_nestest_log(bad, log).has_value());
    CHECK(rig::nes::compare_nestest_log({}, log).has_value());
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


TEST_CASE("the controllers shift out their buttons, then 1s, and give A while strobed") {
    // A 16 KB NROM program at $C000: strobe, read $4016 and $4017 ten times
    // each into $0300 and $0310, then two reads of $4016 with the strobe held
    // into $0320, and again.
    std::vector<uint8_t> code = {
        0x78, 0xD8,                                      // sei; cld
        0xA9, 0x01, 0x8D, 0x16, 0x40,                    // loop: lda #1; sta $4016
        0xA9, 0x00, 0x8D, 0x16, 0x40, 0xA2, 0x00,        //   lda #0; sta $4016; ldx #0
        0xAD, 0x16, 0x40, 0x9D, 0x00, 0x03,              // rd: lda $4016; sta $0300,x
        0xAD, 0x17, 0x40, 0x9D, 0x10, 0x03,              //   lda $4017; sta $0310,x
        0xE8, 0xE0, 0x0A, 0xD0, 0xEF,                    //   inx; cpx #10; bne rd
        0xA9, 0x01, 0x8D, 0x16, 0x40,                    //   lda #1; sta $4016
        0xAD, 0x16, 0x40, 0x8D, 0x20, 0x03,              //   lda $4016; sta $0320
        0xAD, 0x16, 0x40, 0x8D, 0x21, 0x03,              //   lda $4016; sta $0321
        0xA9, 0x00, 0x8D, 0x16, 0x40,                    //   lda #0; sta $4016
        0x4C, 0x02, 0xC0};                               //   jmp loop
    rig::NesRom rom;
    rom.prg.assign(16384, 0xEA);
    std::copy(code.begin(), code.end(), rom.prg.begin());
    for (int v : {0x3FFA, 0x3FFC, 0x3FFE}) {
        rom.prg[v] = 0x00;
        rom.prg[v + 1] = 0xC0;
    }
    auto link = rig::make_nes_sim();
    rig::shell::Client c(*link);
    rig::nes::Console nes(c);
    nes.hold_reset();
    REQUIRE_FALSE(nes.load(rom));
    const uint8_t p1 = rig::nes::kA | rig::nes::kStart | rig::nes::kDown | rig::nes::kRight;  // 0xA9
    const uint8_t p2 = rig::nes::kB | rig::nes::kSelect | rig::nes::kLeft;                   // 0x46
    nes.set_live_input(p1, p2);
    nes.stop_frame(3);  // the buttons apply at a frame's end
    nes.run();
    nes.wait_stopped();
    auto ram = nes.peek(0x0300, 0x22);
    for (int i = 0; i < 10; i++) {
        INFO("read " << i);
        // Bits 7-5 are open bus: the address's high byte, $40.
        CHECK(ram[i] == (0x40 | (i < 8 ? (p1 >> i) & 1 : 1)));
        CHECK(ram[0x10 + i] == (0x40 | (i < 8 ? (p2 >> i) & 1 : 1)));
    }
    CHECK(ram[0x20] == 0x41);  // strobed: A, again and again
    CHECK(ram[0x21] == 0x41);
}


