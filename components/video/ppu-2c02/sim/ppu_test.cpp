// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <vector>

#include "ppu_bench.hpp"

namespace {

// Waits the dots a $2007 access takes to land.
void settle(PpuBench& p) { p.dots_n(8); }

void set_addr(PpuBench& p, uint16_t a) {
    p.write(6, a >> 8);
    p.write(6, a & 0xFF);
    p.dots_n(4);
}

void poke(PpuBench& p, uint16_t a, uint8_t v) {
    set_addr(p, a);
    p.write(7, v);
    settle(p);
}

// Runs to the next frame end and returns the dot count there.
uint64_t next_frame_end(PpuBench& p) {
    uint64_t f = p.frames;
    while (p.frames == f) p.dot();
    return p.dots;
}

} // namespace

TEST_CASE("ppu_2c02 starts at line 0 dot 0 and frames are 341 x 262 dots with rendering off") {
    PpuBench p;
    p.dot();
    CHECK(p.line() == 0);
    CHECK(p.dot_pos() == 0);
    uint64_t e1 = next_frame_end(p), e2 = next_frame_end(p), e3 = next_frame_end(p);
    CHECK(e2 - e1 == 341 * 262);
    CHECK(e3 - e2 == 341 * 262);
}

TEST_CASE("ppu_2c02 skips a dot on odd frames with rendering on") {
    PpuBench p;
    p.write(1, 0x08);
    uint64_t e1 = next_frame_end(p), e2 = next_frame_end(p), e3 = next_frame_end(p);
    uint64_t a = e2 - e1, b = e3 - e2;
    CHECK(a + b == 2 * 341 * 262 - 1);
    CHECK((a == 341 * 262 - 1 || b == 341 * 262 - 1));
}

TEST_CASE("ppu_2c02 sets VBL at line 241 dot 1 and clears it at line 261 dot 1, with NMI") {
    PpuBench p;
    p.write(0, 0x80);
    p.run_to(241, 0);
    CHECK_FALSE(p.nmi());
    p.dot();
    CHECK(p.nmi());
    p.run_to(261, 0);
    CHECK(p.nmi());
    p.dot();
    CHECK_FALSE(p.nmi());
    // A read after dot 1 sees the flag, clears it and drops NMI.
    p.run_to(241, 1);
    CHECK((p.read(2) & 0x80) != 0);
    CHECK_FALSE(p.nmi());
    CHECK((p.read(2) & 0x80) == 0);
}

TEST_CASE("ppu_2c02 reading $2002 one dot before VBL suppresses it for the frame") {
    PpuBench p;
    p.write(0, 0x80);
    p.run_to(241, 0);
    CHECK((p.read(2) & 0x80) == 0);
    p.dots_n(5);
    CHECK_FALSE(p.nmi());
    CHECK((p.read(2) & 0x80) == 0);
    // The next frame is normal again.
    p.run_to(241, 1);
    CHECK(p.nmi());
}

TEST_CASE("ppu_2c02 $2007 reads are buffered except for the palette, which mirrors $3F10") {
    PpuBench p;
    poke(p, 0x2005, 0x11);
    poke(p, 0x2006, 0x22);
    set_addr(p, 0x2005);
    p.read(7);  // the buffer's old contents
    settle(p);
    CHECK(p.read(7) == 0x11);
    settle(p);
    CHECK(p.read(7) == 0x22);
    settle(p);
    CHECK(p.vram(0x2005) == 0x11);

    poke(p, 0x3F10, 0x2A);
    set_addr(p, 0x3F00);
    CHECK((p.read(7) & 0x3F) == 0x2A);
    settle(p);
    poke(p, 0x3F01, 0x15);
    set_addr(p, 0x3F11);
    CHECK((p.read(7) & 0x3F) != 0x15);  // $3F11 isn't a mirror
}

TEST_CASE("ppu_2c02 $2007 increments by 32 with PPUCTRL bit 2") {
    PpuBench p;
    p.write(0, 0x04);
    set_addr(p, 0x2000);
    for (int i = 0; i < 4; i++) {
        p.write(7, static_cast<uint8_t>(0x40 + i));
        settle(p);
    }
    for (int i = 0; i < 4; i++) CHECK(p.vram(static_cast<uint16_t>(0x2000 + 32 * i)) == 0x40 + i);
}

TEST_CASE("ppu_2c02 draws a background tile with fine X scroll") {
    PpuBench p;
    // Tile 1: row 0 is pattern 10000001 low, 00000001 high.
    p.chr[0x10] = 0x81;
    p.chr[0x18] = 0x01;
    p.nt[0] = 1;  // top-left tile
    poke(p, 0x3F00, 0x0F);
    poke(p, 0x3F01, 0x16);
    poke(p, 0x3F03, 0x30);
    p.run_to(241, 1);
    p.write(5, 3);  // fine X 3
    p.write(5, 0);
    p.write(6, 0);
    p.write(6, 0);
    p.write(1, 0x0A);  // background on, left column shown
    p.run_to(261, 340);
    p.record = true;
    p.run_to(0, 300);
    std::vector<uint16_t> row(256, 0xFFFF);
    for (auto& px : p.pixels)
        if (px.y == 0) row[px.x] = px.value;
    // With fine X 3, the tile's pixel 7 (colour 3) lands at x = 4 and pixel 0 (colour 1) is scrolled off.
    CHECK(row[4] == 0x30);
    CHECK(row[3] == 0x0F);
    CHECK(row[5] == 0x0F);
    CHECK(row[0] == 0x0F);
}

TEST_CASE("ppu_2c02 sprite 0 hit sets on the first overlapping opaque pixel") {
    PpuBench p;
    // Background: tile 1 solid colour 1 everywhere.
    for (int r = 0; r < 8; r++) p.chr[0x10 + r] = 0xFF;
    for (auto& b : p.nt) b = 1;
    for (int i = 0x3C0; i < 0x400; i++) p.nt[i] = 0;
    // Sprite 0 at (100, 50+1), tile 1.
    p.run_to(241, 1);
    p.write(3, 0);
    p.write(4, 50);
    p.write(4, 1);
    p.write(4, 0);
    p.write(4, 100);
    p.write(6, 0);
    p.write(6, 0);
    p.write(1, 0x1E);
    p.run_to(51, 100);
    CHECK((p.read(2) & 0x40) == 0);
    p.dot();  // dot 101 draws pixel 100
    CHECK((p.read(2) & 0x40) != 0);
    p.run_to(261, 1);
    CHECK((p.read(2) & 0x40) == 0);
}

TEST_CASE("ppu_2c02 save state restores mid-frame, rendering and register writes included") {
    for (unsigned seed = 1; seed <= 6; seed++) {
        std::mt19937 rng(seed);
        PpuBench a;
        for (auto& b : a.chr) b = static_cast<uint8_t>(rng());
        for (auto& b : a.nt) b = static_cast<uint8_t>(rng());
        a.run_to(241, 5);
        a.write(3, 0);
        for (int i = 0; i < 256; i++) a.write(4, static_cast<uint8_t>(rng()));
        set_addr(a, 0x3F00);
        for (int i = 0; i < 32; i++) {
            a.write(7, static_cast<uint8_t>(rng()));
            settle(a);
        }
        a.write(0, static_cast<uint8_t>(0x80 | (rng() & 0x3B)));
        a.write(1, 0x1E);
        // Random scroll and mask writes while it renders.
        auto poke_some = [](PpuBench& p, std::mt19937& r) {
            uint32_t x = r();
            if (x % 97 == 0) p.write(5, static_cast<uint8_t>(r()));
            if (x % 89 == 0) p.write(1, static_cast<uint8_t>(0x18 | (r() & 0xE7)));
            if (x % 211 == 0) p.read(2);
            if (x % 173 == 0) p.read(7);
        };
        a.dots_n(rng() % 100'000);
        for (int i = 0; i < 2000; i++) {
            poke_some(a, rng);
            a.dot();
        }
        std::vector<uint32_t> st(PpuBench::kStateWords);
        for (int i = 0; i < PpuBench::kStateWords; i++) st[i] = a.state_read(i);
        PpuBench b;
        b.chr = a.chr;
        b.nt = a.nt;
        b.dots_n(12345);
        for (int i = 0; i < PpuBench::kStateWords; i++) b.state_write(i, st[i]);
        a.record = b.record = true;
        std::mt19937 ra(seed * 3), rb(seed * 3);
        for (int i = 0; i < 100'000; i++) {
            poke_some(a, ra);
            poke_some(b, rb);
            a.dot();
            b.dot();
            if (a.nmi() != b.nmi() || a.pixels.size() != b.pixels.size()) {
                CAPTURE(seed, i);
                FAIL("diverged");
            }
        }
        CAPTURE(seed);
        REQUIRE(a.pixels.size() > 50'000);
        REQUIRE(a.pixels == b.pixels);
        for (int i = 0; i < PpuBench::kStateWords; i++) {
            CAPTURE(i);
            REQUIRE(a.state_read(i) == b.state_read(i));
        }
    }
}
