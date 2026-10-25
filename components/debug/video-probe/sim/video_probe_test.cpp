// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <vector>

#include "Vvideo_probe.h"
#include "rig/crc32.hpp"

namespace {

constexpr int W = 16, H = 6;  // the CMake PARAMS

struct Probe {
    Vvideo_probe m;
    uint32_t frame = 0;

    Probe() {
        m.rst = 1;
        clock();
        m.rst = 0;
    }
    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }
    // Sends one frame of pixels `gap` clocks apart; false if the probe held the stream.
    bool send(const std::vector<uint16_t>& px, int gap) {
        for (int i = 0; i < W * H; i++) {
            if (m.cap_held) return false;
            m.pix_valid = 1;
            m.pix = px[i];
            m.pix_x = i % W;
            m.pix_y = i / W;
            m.frame = frame;
            clock();
            m.pix_valid = 0;
            for (int g = 1; g < gap; g++) clock();
        }
        for (int g = 0; g < 4; g++) clock();
        frame++;
        return true;
    }
    uint32_t line_crc(int y) {
        m.line_raddr = y;
        clock();
        return m.line_rdata;
    }
    uint16_t buf(int x) {
        m.buf_raddr = x;
        clock();
        return m.buf_rdata;
    }
};

uint32_t crc_of(const std::vector<uint16_t>& px, int from, int n) {
    rig::Crc32 c;
    for (int i = from; i < from + n; i++) {
        uint8_t b[2] = {static_cast<uint8_t>(px[i]), static_cast<uint8_t>(px[i] >> 8)};
        c.update(b);
    }
    return c.value();
}

std::vector<uint16_t> random_frame(std::mt19937& rng) {
    std::vector<uint16_t> px(W * H);
    for (auto& p : px) p = static_cast<uint16_t>(rng() & 0x1FF);
    return px;
}

} // namespace

TEST_CASE("video_probe CRCs each frame and each line, with pixels 3 clocks apart") {
    Probe p;
    std::mt19937 rng(1);
    CHECK_FALSE(p.m.crc_valid);
    for (int f = 0; f < 3; f++) {
        auto px = random_frame(rng);
        REQUIRE(p.send(px, 3));
        CHECK(p.m.crc_valid);
        CHECK(p.m.crc_frame == static_cast<uint32_t>(f));
        CHECK(p.m.frame_crc == crc_of(px, 0, W * H));
        for (int y = 0; y < H; y++) CHECK(p.line_crc(y) == crc_of(px, y * W, W));
    }
}

TEST_CASE("video_probe captures the chosen line and holds until the host moves on") {
    Probe p;
    std::mt19937 rng(2);
    auto f0 = random_frame(rng);
    REQUIRE(p.send(f0, 5));
    auto f1 = random_frame(rng);
    p.m.cap_en = 1;
    p.m.cap_frame = 1;
    p.m.cap_line = 0;
    std::vector<uint16_t> got;
    int pos = 0;
    // The stream stops after each captured line; read it, then ask for the next.
    for (int y = 0; y < H; y++) {
        int held_at = -1;
        for (int i = pos; i < W * H; i++) {
            if (p.m.cap_held) {
                held_at = i;
                break;
            }
            p.m.pix_valid = 1;
            p.m.pix = f1[i];
            p.m.pix_x = i % W;
            p.m.pix_y = i / W;
            p.m.frame = 1;
            p.clock();
            p.m.pix_valid = 0;
            for (int g = 1; g < 5; g++) p.clock();
        }
        if (y < H - 1) REQUIRE(held_at == (y + 1) * W);
        REQUIRE(p.m.cap_held);
        for (int x = 0; x < W; x++) got.push_back(p.buf(x));
        pos = held_at < 0 ? W * H : held_at;
        p.m.cap_line = static_cast<uint8_t>(y + 1);
        p.clock();
        if (y < H - 1) CHECK_FALSE(p.m.cap_held);
    }
    CHECK(got == f1);
    p.m.cap_en = 0;
    p.clock();
    CHECK_FALSE(p.m.cap_held);
}
