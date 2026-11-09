// SPDX-License-Identifier: Apache-2.0
// The Atari 2600 core against Stella's golden frames (harness/golden/a2600_frames_crc32.txt): each test
// cartridge runs from power-up, its frames are cut from the TIA's picture as Stella's frame manager cuts
// them, and frame N's CRC must match. Skipped when the cartridges aren't fetched (testroms/fetch.py).
#include <catch2/catch_test_macros.hpp>
#include <zlib.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "Va2600.h"

namespace {

constexpr int kWidth = 160, kHeight = 228;

// Stella 7.0's NTSC frame manager, as it decides which lines make a frame: a frame ends when VSYNC
// goes off; the picture starts 23 line ends later and runs 228 lines; with no VSYNC for 50 lines it
// runs on regardless.
class FrameCutter {
public:
    std::vector<uint8_t> buffer = std::vector<uint8_t>(kWidth * kHeight, 0);
    int frames = 0;  // frames completed

    // A pixel of the line being drawn.
    void pixel(int x, uint8_t colour) {
        if (state_ == State::frame && x < kWidth) buffer[y_ * kWidth + x] = colour;
    }

    void line_end() {
        ++total_lines_;
        const State before = state_;
        ++line_in_state_;
        switch (state_) {
        case State::wait_vsync_start:
            if (total_lines_ > kFrameLines - 3 || frames == 0) ++vsync_lines_;
            if (vsync_lines_ > kMaxVsyncLines) set(State::wait_frame_start);
            break;
        case State::wait_vsync_end:
            if (++vsync_lines_ > kMaxVsyncLines) set(State::wait_frame_start);
            break;
        case State::wait_frame_start:
            if (line_in_state_ >= kYStart) set(State::frame);
            break;
        case State::frame:
            if (line_in_state_ >= kHeight) {
                last_y_ = kYStart + y_;
                set(State::wait_vsync_start);
            }
            break;
        }
        if (state_ == State::frame && before == State::frame) ++y_;
    }

    void vsync(bool on) {
        if (on == vsync_) return;
        vsync_ = on;
        set(state_ == State::wait_vsync_end ? State::wait_frame_start : State::wait_vsync_end);
    }

private:
    enum class State { wait_vsync_start, wait_vsync_end, wait_frame_start, frame };
    static constexpr int kFrameLines = 262, kMaxVsyncLines = 50, kYStart = 23;
    State state_ = State::wait_vsync_start;
    int line_in_state_ = 0, vsync_lines_ = 0, y_ = 0, last_y_ = 0, total_lines_ = 0;
    bool vsync_ = false;

    void set(State s) {
        if (s == state_) return;
        state_ = s;
        line_in_state_ = 0;
        if (s == State::wait_frame_start) {
            // The frame is complete: lines it didn't draw are black.
            if (last_y_ != kYStart + y_)
                std::fill(buffer.begin() + y_ * kWidth, buffer.end(), 0);
            total_lines_ = 0;
            ++frames;
            vsync_lines_ = 0;
        } else if (s == State::frame) {
            vsync_lines_ = 0;
            y_ = 0;
        }
    }
};

struct Golden {
    std::string id, path;
    int frames;
    uint32_t crc;
};

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

// Runs the cartridge to frame `frames` and returns that frame's CRC. With RS_A2600_DUMP set to a
// folder, also writes the frame there as <dump_name>.tia (160 x 228 colour values, as stella-frames
// --dump writes them).
uint32_t run(const std::vector<uint8_t>& rom, int frames, const std::string& dump_name = "") {
    Va2600 m;
    FrameCutter cut;
    m.joy = 0xFF;
    m.switches = 0xFF;
    m.fire_n = 3;
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
    // A colour clock every 2 clocks.
    for (uint64_t clock = 0; cut.frames < frames; clock++) {
        const bool cc = clock & 1;
        m.cc = cc;
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
        m.cart_data = rom[m.cart_addr & mask];
        m.eval();
        if (!cc) continue;
        // The colour clock just drawn, then the line's end, then a VSYNC write (as Stella orders them).
        if (m.pix_on) cut.pixel(m.pix_x, m.pix);
        if (m.line_end) cut.line_end();
        const int before = cut.frames;
        cut.vsync(m.vsync);
        if (cut.frames != before && cut.frames == frames) {
            crc = static_cast<uint32_t>(crc32(crc32(0, nullptr, 0), cut.buffer.data(), cut.buffer.size()));
            if (const char* dir = std::getenv("RS_A2600_DUMP"); dir && !dump_name.empty()) {
                std::ofstream out(std::string(dir) + "/" + dump_name + ".tia", std::ios::binary);
                out.write(reinterpret_cast<const char*>(cut.buffer.data()), static_cast<std::streamsize>(cut.buffer.size()));
            }
        }
        REQUIRE(clock < 4000000000ULL);
    }
    return crc;
}

}  // namespace

TEST_CASE("atari2600 test cartridges match Stella's frames") {
    for (const Golden& g : golden()) {
        const std::string path = std::string(RS_TESTROMS) + "/" + g.path;
        std::ifstream f(path, std::ios::binary);
        if (!f) {
            WARN("skipped " << g.id << ": no " << path);
            continue;
        }
        std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)), {});
        INFO(g.id);
        REQUIRE((rom.size() == 2048 || rom.size() == 4096));
        CHECK(run(rom, g.frames, g.id) == g.crc);
    }
}
