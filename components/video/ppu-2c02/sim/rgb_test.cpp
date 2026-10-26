// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>

#include "Vppu_2c02_rgb.h"

namespace {

uint32_t look(Vppu_2c02_rgb& m, unsigned pix) {
    m.pix = pix;
    m.clk = 0;
    m.eval();
    m.clk = 1;
    m.eval();
    return m.rgb;
}

unsigned r(uint32_t c) { return c >> 16; }
unsigned g(uint32_t c) { return (c >> 8) & 0xff; }
unsigned b(uint32_t c) { return c & 0xff; }

} // namespace

TEST_CASE("ppu_2c02_rgb gives the 2C02's colours a clock later") {
    Vppu_2c02_rgb m;
    CHECK(look(m, 0x0F) == 0x000000);  // black
    CHECK(look(m, 0x30) == 0xffffff);  // white
    // Greys: hue 0 of each luma, and lighter each step.
    uint32_t g0 = look(m, 0x00), g1 = look(m, 0x10), g2 = look(m, 0x20);
    CHECK((r(g0) == g(g0) && g(g0) == b(g0)));
    CHECK(r(g0) < r(g1));
    CHECK(r(g1) < r(g2));
    // Hues 13-15 of every luma but $0D are black or near it; $xE, $xF black.
    for (unsigned l = 0; l < 4; l++) {
        CHECK(look(m, l << 4 | 0xE) == 0x000000);
        CHECK(look(m, l << 4 | 0xF) == 0x000000);
    }
    // The colours everyone knows, by their strongest channel.
    uint32_t red = look(m, 0x16), green = look(m, 0x1A), blue = look(m, 0x12);
    CHECK((r(red) > g(red) && r(red) > b(red)));
    CHECK((g(green) > r(green) && g(green) > b(green)));
    CHECK((b(blue) > r(blue) && b(blue) > g(blue)));
    // Red emphasis darkens green and blue, not red.
    uint32_t w = look(m, 0x20), we = look(m, 0x40 | 0x20);
    CHECK(r(we) > g(we));
    CHECK(g(we) < g(w));
    // Registered: the output holds until the next clock.
    look(m, 0x16);
    m.pix = 0x1A;
    m.eval();
    CHECK(m.rgb == red);
}
