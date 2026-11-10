// SPDX-License-Identifier: Apache-2.0
// a2600_frame against the frame manager's model (frame_cutter.hpp, Stella 7.0's): random pictures,
// lines cut short as RSYNC cuts them, VSYNC on time, early, mid-line and overdue, a colour clock every
// 6 clocks (the least the system gives it). Every frame's CRC must be the model's, and the frame buffer
// the model's at the end.
#include <catch2/catch_test_macros.hpp>
#include <zlib.h>

#include <cstdint>
#include <map>
#include <random>
#include <vector>

#include "Va2600_frame.h"
#include "frame_cutter.hpp"

namespace {

struct Bench {
    Va2600_frame m;
    a2600_sim::FrameCutter cut;
    std::map<uint32_t, uint32_t> want;  // frame -> the model's CRC
    std::map<uint32_t, uint32_t> got;   // frame -> the CRC a2600_frame gave
    long mismatched_frames = 0;

    Bench() {
        m.clk = 0;
        m.rst = 1;
        m.step = 0;
        m.pix_on = 0;
        m.pix_x = 0;
        m.pix = 0;
        m.line_end = 0;
        m.vsync = 0;
        m.rd_req = 0;
        m.rd_addr = 0;
        clock();
        clock();
        m.rst = 0;
        for (int i = 0; i < 10000; i++) clock();  // the reset's clear
        REQUIRE_FALSE(m.busy);
    }

    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
        if (m.crc_frame != 0) got[m.crc_frame] = m.crc;
    }

    // One colour clock: its pixel (if any), the line's end, VSYNC; then 5 clocks more.
    void cc(bool on, int x, uint8_t pix, bool line_end, bool vsync) {
        m.step = 1;
        m.pix_on = on;
        m.pix_x = static_cast<uint8_t>(x);
        m.pix = pix;
        m.line_end = line_end;
        m.vsync = vsync;
        clock();
        m.step = 0;
        for (int i = 0; i < 5; i++) clock();
        const int before = cut.frames;
        if (on) cut.pixel(x, pix);
        if (line_end) cut.line_end();
        cut.vsync(vsync);
        if (cut.frames != before)
            want[static_cast<uint32_t>(cut.frames)] =
                static_cast<uint32_t>(crc32(crc32(0, nullptr, 0), cut.buffer.data(), static_cast<uInt>(cut.buffer.size())));
        if (m.frames != static_cast<uint32_t>(cut.frames)) mismatched_frames++;
    }
};

}  // namespace

TEST_CASE("a2600_frame: frames and their CRCs as Stella's frame manager cuts them") {
    Bench b;
    std::mt19937 rng(2600);
    bool vsync = false;
    // Lines in the frame so far, and when the next frame's VSYNC comes: on time (262), early (a
    // short frame), late (past the frame manager's 50 lines of grace), or not at all for a while.
    int line = 0, frame_len = 262;
    for (int lines = 0; lines < 262 * 40; lines++) {
        const int len = rng() % 10 == 0 ? 80 + static_cast<int>(rng() % 148) : 228;  // RSYNC cuts some short
        // VSYNC's writes land at random colour clocks of their lines.
        const int vs_on_at = static_cast<int>(rng() % static_cast<unsigned>(len));
        const int vs_off_at = static_cast<int>(rng() % static_cast<unsigned>(len));
        for (int c = 0; c < len; c++) {
            const int x = c - 68;
            const bool on = x >= 0 && x < 160 && rng() % 50 != 0;
            if (line == frame_len && c == vs_on_at) vsync = true;
            if (line == frame_len + 3 && c == vs_off_at) {
                vsync = false;
                line = 0;
                const unsigned k = rng() % 8;
                frame_len = k == 0 ? 100 + static_cast<int>(rng() % 150) : k == 1 ? 300 + static_cast<int>(rng() % 100) : 259;
            }
            b.cc(on, on ? x : 0, static_cast<uint8_t>(rng() & 0xFE), c == len - 1, vsync);
        }
        line++;
    }
    for (int i = 0; i < 10000; i++) b.clock();
    INFO(b.want.size() << " frames");
    CHECK(b.mismatched_frames == 0);
    REQUIRE(b.want.size() > 30);
    long wrong = 0, missing = 0;
    for (auto [n, crc] : b.want) {
        auto it = b.got.find(n);
        if (it == b.got.end()) missing++;
        else if (it->second != crc) wrong++;
    }
    CHECK(missing == 0);
    CHECK(wrong == 0);
    // The buffer holds the last frame as the model has it.
    std::vector<uint8_t> fb;
    for (int a = 0; a < a2600_sim::kWidth * a2600_sim::kHeight; a++) {
        b.m.rd_addr = static_cast<uint16_t>(a);
        b.m.rd_req = 1;
        int n = 0;
        do {
            b.clock();
            REQUIRE(++n < 100);
        } while (!b.m.rd_ack);
        b.m.rd_req = 0;
        b.clock();
        fb.push_back(b.m.rd_data);
    }
    CHECK(fb == b.cut.buffer);
}
