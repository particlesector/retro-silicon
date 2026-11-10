// SPDX-License-Identifier: Apache-2.0
// systems/atari-2600's a2600_sys through its test shell, in the sim as the Tang Nano 20K runs it:
// every cartridge in harness/golden/a2600_frames_crc32.txt to its golden frame, whose CRC the
// system computes itself, and the sound's CRC where a2600_audio_crc32.txt has one. Skipped when the
// cartridges aren't fetched (testroms/fetch.py).
#include <catch2/catch_test_macros.hpp>

#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "rig/a2600.hpp"
#include "rig/crc32.hpp"
#include "rig/shell.hpp"
#include "rig/sim_systems.hpp"

TEST_CASE("a2600_sys: the test cartridges' golden frames and sound through the shell") {
    const auto paddles = rig::a2600::load_paddles(RS_A2600_PADDLES);
    const auto sounds = rig::a2600::load_audio(RS_A2600_AUDIO_GOLDEN);
    const char* roms = std::getenv("RS_TESTROMS");
    for (const auto& g : rig::a2600::load_golden(RS_A2600_GOLDEN)) {
        const std::string path = std::string(roms ? roms : RS_TESTROMS) + "/" + g.path;
        std::ifstream f(path, std::ios::binary);
        if (!f) {
            WARN("skipped " << g.id << ": no " << path);
            continue;
        }
        std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)), {});
        auto link = rig::make_a2600_sim();
        const auto p = paddles.find(g.id);
        const auto s = sounds.find(g.id);
        auto r = rig::a2600::cart_test(*link, g.id, rom, g.frames, g.crc,
                                       p == paddles.end() ? rig::a2600::kNoPaddles : p->second,
                                       s == sounds.end() ? std::nullopt : std::make_optional(s->second),
                                       RS_A2600_BUILD_ID);
        INFO(g.id << ": " << r.detail << " (" << r.notes << ")");
        CHECK(r.passed);
    }
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
