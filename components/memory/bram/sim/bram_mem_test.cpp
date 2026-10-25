// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <array>
#include <cstdint>
#include <random>

#include "Vbram_mem.h"

namespace {

void tick(Vbram_mem& m) {
    m.clk = 0;
    m.eval();
    m.clk = 1;
    m.eval();
}

} // namespace

TEST_CASE("bram_mem: random reads and writes match a byte array, one clock each, wrapping at 2^AW") {
    Vbram_mem m;
    m.rst = 1;
    m.req = 0;
    tick(m);
    m.rst = 0;
    CHECK(m.ready == 1);

    std::array<int, 1 << 10> ref;
    ref.fill(-1);
    std::mt19937 rng(3);
    int reads = 0;
    for (int i = 0; i < 40'000; i++) {
        bool we = rng() % 2 == 0;
        uint32_t addr = rng() & 0xFFF;  // 12-bit port, 10-bit memory: mirrors
        uint8_t data = static_cast<uint8_t>(rng());
        m.req = 1;
        m.we = we;
        m.addr = addr;
        m.wdata = data;
        tick(m);
        REQUIRE(m.ack == 1);  // one clock
        if (we) ref[addr & 0x3FF] = data;
        else if (ref[addr & 0x3FF] >= 0) {
            CHECK(m.rdata == ref[addr & 0x3FF]);
            reads++;
        }
        // req stays high while ack is, as a registered requester's would: no second access.
        m.wdata = static_cast<uint8_t>(data ^ 0xFF);
        tick(m);
        CHECK(m.ack == 0);
        m.req = 0;
        for (int g = static_cast<int>(rng() % 3); g > 0; g--) tick(m);
    }
    CHECK(reads > 10'000);
}
