// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <array>
#include <cstdint>
#include <random>

#include "Vaxi_bridge.h"
#include "axi_memory_model.hpp"

namespace {

constexpr uint32_t kBase = 0x10000000;
constexpr int kBytes = 1 << 12;

void tick(Vaxi_bridge& m, rs::AxiMemoryModel& s) {
    s.drive(m);
    m.clk = 0;
    m.eval();
    s.sample(m);
    m.clk = 1;
    m.eval();
    s.after_edge();
}

} // namespace

TEST_CASE("axi_bridge: random byte reads and writes match a byte array through a slow, stalling AXI slave") {
    Vaxi_bridge m;
    rs::AxiMemoryModel s(kBase, kBytes, 7);
    m.rst = 1;
    m.req = 0;
    m.axi_ready = 0;
    tick(m, s);
    m.rst = 0;
    tick(m, s);
    CHECK(m.ready == 0);  // not until the AXI side is
    m.axi_ready = 1;
    tick(m, s);
    CHECK(m.ready == 1);

    std::array<int, kBytes> ref;
    ref.fill(-1);
    std::mt19937 rng(11);
    int checked = 0;
    for (int i = 0; i < 20'000; i++) {
        bool we = rng() % 2 == 0;
        uint32_t addr = rng() % kBytes;
        uint8_t data = static_cast<uint8_t>(rng());
        m.req = 1;
        m.we = we;
        m.addr = addr;
        m.wdata = data;
        int waited = 0;
        do {
            tick(m, s);
            REQUIRE(++waited < 100);
        } while (!m.ack);
        if (we) ref[addr] = data;
        else {
            CHECK(static_cast<int>(m.rdata) == (ref[addr] >= 0 ? ref[addr] : 0));
            uint32_t w = 0;
            uint32_t base = addr & ~3u;
            for (int b = 3; b >= 0; b--) w = w << 8 | static_cast<uint32_t>(ref[base + b] >= 0 ? ref[base + b] : 0);
            CHECK(m.rdata_w == w);  // the 32-bit word the byte is in
            checked++;
        }
        // req stays high the clock after ack, as a registered requester's would: no second access.
        int r = s.reads, w = s.writes;
        tick(m, s);
        CHECK(m.ack == 0);
        m.req = 0;
        for (int g = static_cast<int>(rng() % 3); g > 0; g--) tick(m, s);
        CHECK(s.reads == r);
        CHECK(s.writes == w);
    }
    CHECK(checked > 8'000);
    CHECK(s.reads + s.writes == 20'000);
}
