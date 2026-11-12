// SPDX-License-Identifier: Apache-2.0
// systems/atari-2600's a2600_sys through its test shell, in the sim: every cartridge in
// harness/golden/a2600_frames_crc32.txt to its golden frame, whose CRC the system computes itself,
// and the sound's CRC where a2600_audio_crc32.txt has one; and the bank-switching cartridges again as
// the Tang Nano 20K runs them, their ROM in the SDRAM (make_a2600_ext_sim); and every cartridge again
// as the Tang Console 138K runs it (make_a2600_console_sim). Skipped when the
// cartridges aren't fetched (testroms/fetch.py).
#include <catch2/catch_test_macros.hpp>

#include <cstdlib>
#include <fstream>
#include <functional>
#include <memory>
#include <iterator>
#include <string>
#include <vector>

#include "rig/a2600.hpp"
#include "rig/crc32.hpp"
#include "rig/shell.hpp"
#include "rig/sim_systems.hpp"

namespace {

// One cartridge of a2600_frames_crc32.txt through the shell, as rig-run --test a2600 runs it.
void matches_stella(const std::string& id,
                    const std::function<std::unique_ptr<rig::SimLink>()>& make = rig::make_a2600_sim) {
    const auto paddles = rig::a2600::load_paddles(RS_A2600_PADDLES);
    const auto sounds = rig::a2600::load_audio(RS_A2600_AUDIO_GOLDEN);
    const char* roms = std::getenv("RS_TESTROMS");
    for (const auto& g : rig::a2600::load_golden(RS_A2600_GOLDEN)) {
        if (g.id != id) continue;
        const std::string path = std::string(roms ? roms : RS_TESTROMS) + "/" + g.path;
        std::ifstream f(path, std::ios::binary);
        if (!f) {
            SKIP("no " << path);
        }
        std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)), {});
        auto cart = rig::a2600::cart_from_name(g.path);
        REQUIRE(cart);
        auto link = make();
        const auto p = paddles.find(g.id);
        const auto s = sounds.find(g.id);
        auto r = rig::a2600::cart_test(*link, g.id, rom, g.frames, g.crc,
                                       p == paddles.end() ? rig::a2600::kNoPaddles : p->second,
                                       s == sounds.end() ? std::nullopt : std::make_optional(s->second),
                                       RS_A2600_BUILD_ID, *cart);
        INFO(r.detail << " (" << r.notes << ")");
        CHECK(r.passed);
        return;
    }
    FAIL(id << " isn't in a2600_frames_crc32.txt");
}

const std::vector<std::string> kCarts = {
    "tia_colours", "riot_ram", "riot_timer", "tia_playfield", "tia_players", "tia_missiles_ball",
    "tia_hmove", "tia_collisions", "tia_rsync", "tia_resmp", "tia_audio", "tia_paddles",
    "bank_f8", "bank_f6", "bank_f4", "bank_f8sc", "bank_f6sc", "bank_f4sc", "bank_fa", "bank_f0",
    "bank_fe", "bank_e0", "bank_3f", "bank_e7",
};

} // namespace

#define MATCHES_STELLA(id) \
    TEST_CASE(id " passes in the sim and its frame matches Stella's") { matches_stella(id); }
#define MATCHES_STELLA_SDRAM(id) \
    TEST_CASE(id " passes from the SDRAM as the Tang Nano 20K runs it") { matches_stella(id, rig::make_a2600_ext_sim); }
#define MATCHES_STELLA_CONSOLE(id)                                                     \
    TEST_CASE(id " passes as the Tang Console 138K runs it") {                         \
        matches_stella(id, [] { return rig::make_a2600_console_sim(); });              \
    }

MATCHES_STELLA("tia_colours")
MATCHES_STELLA("riot_ram")
MATCHES_STELLA("riot_timer")
MATCHES_STELLA("tia_playfield")
MATCHES_STELLA("tia_players")
MATCHES_STELLA("tia_missiles_ball")
MATCHES_STELLA("tia_hmove")
MATCHES_STELLA("tia_collisions")
MATCHES_STELLA("tia_rsync")
MATCHES_STELLA("tia_resmp")
MATCHES_STELLA("tia_audio")
MATCHES_STELLA("tia_paddles")
MATCHES_STELLA("bank_f8")
MATCHES_STELLA("bank_f6")
MATCHES_STELLA("bank_f4")
MATCHES_STELLA("bank_f8sc")
MATCHES_STELLA("bank_f6sc")
MATCHES_STELLA("bank_f4sc")
MATCHES_STELLA("bank_fa")
MATCHES_STELLA("bank_f0")
MATCHES_STELLA("bank_fe")
MATCHES_STELLA("bank_e0")
MATCHES_STELLA("bank_3f")
MATCHES_STELLA("bank_e7")

MATCHES_STELLA_SDRAM("bank_f8")
MATCHES_STELLA_SDRAM("bank_f6")
MATCHES_STELLA_SDRAM("bank_f4")
MATCHES_STELLA_SDRAM("bank_f8sc")
MATCHES_STELLA_SDRAM("bank_f6sc")
MATCHES_STELLA_SDRAM("bank_f4sc")
MATCHES_STELLA_SDRAM("bank_fa")
MATCHES_STELLA_SDRAM("bank_f0")
MATCHES_STELLA_SDRAM("bank_fe")
MATCHES_STELLA_SDRAM("bank_e0")
MATCHES_STELLA_SDRAM("bank_3f")
MATCHES_STELLA_SDRAM("bank_e7")

MATCHES_STELLA_CONSOLE("tia_colours")
MATCHES_STELLA_CONSOLE("riot_ram")
MATCHES_STELLA_CONSOLE("riot_timer")
MATCHES_STELLA_CONSOLE("tia_playfield")
MATCHES_STELLA_CONSOLE("tia_players")
MATCHES_STELLA_CONSOLE("tia_missiles_ball")
MATCHES_STELLA_CONSOLE("tia_hmove")
MATCHES_STELLA_CONSOLE("tia_collisions")
MATCHES_STELLA_CONSOLE("tia_rsync")
MATCHES_STELLA_CONSOLE("tia_resmp")
MATCHES_STELLA_CONSOLE("tia_audio")
MATCHES_STELLA_CONSOLE("tia_paddles")
MATCHES_STELLA_CONSOLE("bank_f8")
MATCHES_STELLA_CONSOLE("bank_f6")
MATCHES_STELLA_CONSOLE("bank_f4")
MATCHES_STELLA_CONSOLE("bank_f8sc")
MATCHES_STELLA_CONSOLE("bank_f6sc")
MATCHES_STELLA_CONSOLE("bank_f4sc")
MATCHES_STELLA_CONSOLE("bank_fa")
MATCHES_STELLA_CONSOLE("bank_f0")
MATCHES_STELLA_CONSOLE("bank_fe")
MATCHES_STELLA_CONSOLE("bank_e0")
MATCHES_STELLA_CONSOLE("bank_3f")
MATCHES_STELLA_CONSOLE("bank_e7")

TEST_CASE("a2600_sys: every cartridge of a2600_frames_crc32.txt has its test case") {
    std::vector<std::string> ids;
    for (const auto& g : rig::a2600::load_golden(RS_A2600_GOLDEN)) ids.push_back(g.id);
    CHECK(ids == kCarts);
}

TEST_CASE("a2600_sys: the frame buffer holds the golden frame, and a reset clears it") {
    const std::string id = "tia_colours";
    std::string path;
    uint32_t frames = 0, crc = 0;
    const char* roms = std::getenv("RS_TESTROMS");
    for (const auto& g : rig::a2600::load_golden(RS_A2600_GOLDEN))
        if (g.id == id) path = std::string(roms ? roms : RS_TESTROMS) + "/" + g.path, frames = g.frames, crc = g.crc;
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        WARN("skipped: no " << path);
        return;
    }
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)), {});
    auto link = rig::make_a2600_sim();
    rig::shell::Client client(*link);
    rig::a2600::Console vcs(client);
    vcs.hold_reset();
    REQUIRE_FALSE(vcs.load(rom));
    vcs.stop_frame(frames);
    vcs.run();
    vcs.wait_stopped();
    auto fb = vcs.frame();
    rig::Crc32 c;
    c.update(fb);
    CHECK(c.value() == crc);
    // Held in reset and let go, it clears the buffer before its first colour clock: stopped after
    // one CPU cycle, the buffer is all 0.
    vcs.hold_reset();
    vcs.stop_frame(0);
    const uint8_t one[4] = {1, 0, 0, 0};
    client.poke(rig::a2600::kRegs + rig::a2600::kStopCycle, one);
    vcs.run();
    for (int i = 0; !(vcs.status() & rig::a2600::kStopped); i++) REQUIRE(i < 100);
    CHECK(vcs.cycles() == 1);
    CHECK(vcs.frame() == std::vector<uint8_t>(rig::a2600::kWidth * rig::a2600::kHeight, 0));
}
