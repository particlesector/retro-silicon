// SPDX-License-Identifier: Apache-2.0
// The Atari 2600 core against Stella's golden frames (harness/golden/a2600_frames_crc32.txt): each test
// cartridge runs from power-up, its frames are cut from the TIA's picture as Stella's frame manager cuts
// them, and frame N's CRC must match. A cartridge in harness/golden/a2600_audio_crc32.txt must also
// match Stella's sound: each sample's two channel sums (each channel's level summed over the colour
// clocks since the last sample, a sample at each of the TIA's phase 1 clocks, as Stella takes them),
// as two little-endian 16-bit words, and the CRC of the first N samples from power-up. Skipped when
// the cartridges aren't fetched (testroms/fetch.py).
#include <catch2/catch_test_macros.hpp>
#include <zlib.h>

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "Va2600.h"
#include "frame_cutter.hpp"

namespace {

using a2600_sim::FrameCutter;
using a2600_sim::kHeight;
using a2600_sim::kWidth;

struct Golden {
    std::string id, path;
    int frames;
    uint32_t crc;
};

struct AudioGolden {
    std::string id;
    size_t samples;
    uint32_t crc;
};

// harness/golden/a2600_audio_crc32.txt: id, samples, CRC-32 of their sums, path.
std::vector<AudioGolden> audio_golden() {
    std::ifstream f(RS_A2600_AUDIO_GOLDEN);
    std::vector<AudioGolden> out;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        AudioGolden g;
        std::string crc, path;
        s >> g.id >> g.samples >> crc >> path;
        g.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        out.push_back(g);
    }
    return out;
}

// harness/golden/a2600_paddles.txt: id, then INPT0-3's paddles, each a knob position (a pot of
// n / 256 Mohm) or - for none. A cartridge not listed has none.
using Paddles = std::array<int, 4>;
std::map<std::string, Paddles> paddles_golden() {
    std::ifstream f(RS_A2600_PADDLES);
    std::map<std::string, Paddles> out;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        std::string id, p;
        Paddles pads{};
        s >> id;
        for (int& pos : pads) {
            s >> p;
            pos = p == "-" ? -1 : std::stoi(p);
        }
        out[id] = pads;
    }
    return out;
}

std::vector<Golden> golden() {
    std::ifstream f(RS_A2600_GOLDEN);
    std::vector<Golden> out;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        Golden g;
        std::string crc, check, result;
        s >> g.id >> g.frames >> crc >> check >> result >> g.path;
        g.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        out.push_back(g);
    }
    return out;
}

// Runs the cartridge to frame `frames` and returns that frame's CRC, and in `sound` the samples'
// sums. With RS_A2600_DUMP set to a folder, also writes the frame there as <dump_name>.tia (160 x 228
// colour values, as stella-frames --dump writes them) and the sound as <dump_name>.aud, and every
// colour clock's levels as <dump_name>.lvl (a byte each: aud0 | aud1 << 4) and VSYNC as <dump_name>.vs
// (a byte each), to compare with a transistor-level TIA's pins.
uint32_t run(const std::vector<uint8_t>& rom, int frames, std::vector<uint8_t>& sound,
             const Paddles& paddles, const std::string& dump_name = "") {
    Va2600 m;
    FrameCutter cut;
    m.joy = 0xFF;
    m.switches = 0xFF;
    m.fire_n = 3;
    m.paddle_on = 0;
    m.paddle_pos = 0;
    for (int i = 0; i < 4; i++)
        if (paddles[i] >= 0) {
            m.paddle_on |= 1u << i;
            m.paddle_pos |= uint32_t(paddles[i]) << 8 * i;
        }
    m.cart_data = 0;
    m.clk = 0;
    m.cc = 0;
    m.rst = 1;
    for (int i = 0; i < 4; i++) {
        m.clk = !m.clk;
        m.eval();
    }
    m.rst = 0;
    const size_t mask = rom.size() - 1;
    uint32_t crc = 0;
    // RS_A2600_TRACE=DIR: every TIA write as "<colour clock> <register> <value>", in <dump_name>.trace.
    std::ofstream trace;
    if (const char* dir = std::getenv("RS_A2600_TRACE"); dir && !dump_name.empty())
        trace.open(std::string(dir) + "/" + dump_name + ".trace");
    uint64_t colour_clock = 0;
    uint32_t sum0 = 0, sum1 = 0;
    std::vector<uint8_t> levels, vsyncs;
    const char* dump_dir = std::getenv("RS_A2600_DUMP");
    // A colour clock every 6 clocks, the least io/paddles takes.
    for (uint64_t clock = 0; cut.frames < frames; clock++) {
        const bool cc = clock % 6 == 5;
        m.cc = cc;
        m.clk = 0;
        m.eval();
        // The access this colour clock ends, as the rising edge will take it.
        if (cc && trace.is_open() && m.bus_ce && m.bus_we && !(m.bus_addr & 0x1080))
            trace << colour_clock << ' ' << (m.bus_addr & 0x3F) << ' ' << int(m.bus_data) << '\n';
        m.clk = 1;
        m.eval();
        m.cart_data = rom[m.cart_addr & mask];
        m.eval();
        if (!cc) continue;
        ++colour_clock;
        // The colour clock just drawn, then the line's end, then a VSYNC write (as Stella orders them).
        // A frame ends at VSYNC, or at a line's end when VSYNC is overdue.
        const int before = cut.frames;
        if (dump_dir) levels.push_back(static_cast<uint8_t>(m.aud0 | m.aud1 << 4)), vsyncs.push_back(m.vsync);
        sum0 += m.aud0;
        sum1 += m.aud1;
        if (m.aud_tick) {
            for (uint32_t v : {sum0, sum1}) {
                sound.push_back(static_cast<uint8_t>(v));
                sound.push_back(static_cast<uint8_t>(v >> 8));
            }
            sum0 = sum1 = 0;
        }
        if (m.pix_on) cut.pixel(m.pix_x, m.pix);
        if (m.line_end) cut.line_end();
        cut.vsync(m.vsync);
        if (cut.frames != before && cut.frames == frames) {
            crc = static_cast<uint32_t>(crc32(crc32(0, nullptr, 0), cut.buffer.data(), cut.buffer.size()));
            if (const char* dir = std::getenv("RS_A2600_DUMP"); dir && !dump_name.empty()) {
                std::ofstream out(std::string(dir) + "/" + dump_name + ".tia", std::ios::binary);
                out.write(reinterpret_cast<const char*>(cut.buffer.data()), static_cast<std::streamsize>(cut.buffer.size()));
                std::ofstream aud(std::string(dir) + "/" + dump_name + ".aud", std::ios::binary);
                aud.write(reinterpret_cast<const char*>(sound.data()), static_cast<std::streamsize>(sound.size()));
                std::ofstream lvl(std::string(dir) + "/" + dump_name + ".lvl", std::ios::binary);
                lvl.write(reinterpret_cast<const char*>(levels.data()), static_cast<std::streamsize>(levels.size()));
                std::ofstream vs(std::string(dir) + "/" + dump_name + ".vs", std::ios::binary);
                vs.write(reinterpret_cast<const char*>(vsyncs.data()), static_cast<std::streamsize>(vsyncs.size()));
            }
        }
        REQUIRE(clock < 4000000000ULL);
    }
    return crc;
}

}  // namespace

TEST_CASE("atari2600 test cartridges match Stella's frames and sound") {
    const std::vector<AudioGolden> sounds = audio_golden();
    const std::map<std::string, Paddles> pads = paddles_golden();
    for (const Golden& g : golden()) {
        const char* roms = std::getenv("RS_TESTROMS");
        const std::string path = std::string(roms ? roms : RS_TESTROMS) + "/" + g.path;
        std::ifstream f(path, std::ios::binary);
        if (!f) {
            WARN("skipped " << g.id << ": no " << path);
            continue;
        }
        std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)), {});
        INFO(g.id);
        REQUIRE((rom.size() == 2048 || rom.size() == 4096));
        std::vector<uint8_t> sound;
        const auto pad = pads.find(g.id);
        CHECK(run(rom, g.frames, sound, pad == pads.end() ? Paddles{-1, -1, -1, -1} : pad->second, g.id) == g.crc);
        for (const AudioGolden& a : sounds) {
            if (a.id != g.id) continue;
            INFO("sound, " << sound.size() / 4 << " samples");
            REQUIRE(sound.size() >= 4 * a.samples);
            const auto n = static_cast<uInt>(4 * a.samples);
            CHECK(static_cast<uint32_t>(crc32(crc32(0, nullptr, 0), sound.data(), n)) == a.crc);
        }
    }
}
