// SPDX-License-Identifier: Apache-2.0
// systems/game-boy's gb_sys through its test shell, in the sim: a test ROM of each kind of check in
// harness/golden/gb_frames_crc32.txt (Mooneye's bytes, blargg's text over the serial port or his code
// in cartridge RAM, and a frame) ends as it does in MesenCE, the frame's CRC taken by the system
// itself, and its sound's CRC is gb_audio_crc32.txt's, as a board runs them. systems/game-boy's
// gb_roms_test runs every ROM on the bare system, and wrote gb_audio_crc32.txt. Skipped when the
// ROMs aren't fetched (testroms/fetch.py).
#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cstdlib>
#include <fstream>
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
    const auto boot = read_file(roms + "/" + rig::gb::kDmgBoot);
    if (boot.empty()) SKIP("no " << roms << "/" << rig::gb::kDmgBoot);
    const auto golden = rig::gb::load_golden(RS_GB_GOLDEN);
    const auto audio = rig::gb::load_audio_golden(RS_GB_AUDIO_GOLDEN);
    auto link = rig::make_gb_sim();
    for (const auto& id : ids) {
        auto g = std::find_if(golden.begin(), golden.end(), [&](auto& x) { return x.id == id; });
        REQUIRE(g != golden.end());
        const auto rom = read_file(roms + "/" + g->path);
        if (rom.empty()) SKIP("no " << roms << "/" << g->path);
        auto a = audio.find(id);
        REQUIRE(a != audio.end());
        auto r = rig::gb::rom_test(*link, *g, rom, boot, RS_GB_BUILD_ID, a->second);
        INFO(id << ": " << r.detail << " (" << r.notes << ")");
        CHECK(r.passed);
    }
}

void matches_mesen(const std::string& id) {
    const char* env = std::getenv("RS_TESTROMS");
    const std::string roms = env ? env : RS_TESTROMS;
    const auto boot = read_file(roms + "/" + rig::gb::kDmgBoot);
    if (boot.empty()) SKIP("no " << roms << "/" << rig::gb::kDmgBoot);
    for (const auto& g : rig::gb::load_golden(RS_GB_GOLDEN)) {
        if (g.id != id) continue;
        const auto rom = read_file(roms + "/" + g.path);
        if (rom.empty()) SKIP("no " << roms << "/" << g.path);
        const auto audio = rig::gb::load_audio_golden(RS_GB_AUDIO_GOLDEN);
        auto a = audio.find(id);
        REQUIRE(a != audio.end());
        auto link = rig::make_gb_sim();
        auto r = rig::gb::rom_test(*link, g, rom, boot, RS_GB_BUILD_ID, a->second);
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
