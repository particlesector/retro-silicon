// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cstdint>
#include <random>
#include <vector>

#include "Vsdram_ctrl.h"
#include "sdram_model.hpp"

namespace {

constexpr int kMhz = RS_SDRAM_MHZ;  // the FREQ_MHZ the controller was built with

#define RS_STR2(x) #x
#define RS_STR(x) RS_STR2(x)
#define NAME(what) "sdram_ctrl at " RS_STR(RS_SDRAM_MHZ) " MHz " what

struct Dut {
    Vsdram_ctrl m;
    SdramModel sdram{kMhz};
    uint64_t clocks = 0;

    Dut() {
        m.rst = 1;
        m.req = 0;
        tick();
        m.rst = 0;
    }

    void tick() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
        m.sd_dq_i = sdram.step({m.sd_cs_n != 0, m.sd_ras_n != 0, m.sd_cas_n != 0, m.sd_we_n != 0,
                                m.sd_ba, m.sd_addr, m.sd_dqm, m.sd_dq_o, m.sd_dq_oe != 0});
        clocks++;
    }

    void wait_ready() {
        while (!m.ready) {
            tick();
            REQUIRE(clocks < 300 * kMhz);
        }
    }

    // One access; returns the read data and the clocks from request to ack.
    std::pair<uint8_t, int> access(bool we, uint32_t addr, uint8_t wdata = 0) {
        m.req = 1;
        m.we = we;
        m.addr = addr;
        m.wdata = wdata;
        int n = 0;
        do {
            tick();
            n++;
            REQUIRE(n < 100);
        } while (!m.ack);
        m.req = 0;
        return {m.rdata, n};
    }
};

void require_clean(const Dut& d) {
    for (auto& e : d.sdram.errors) UNSCOPED_INFO(e);
    REQUIRE(d.sdram.errors.empty());
}

} // namespace

TEST_CASE(NAME("runs the power-up sequence within the chip's limits")) {
    Dut d;
    d.wait_ready();
    CHECK(d.sdram.initialised());
    CHECK(d.clocks >= 200 * kMhz);
    require_clean(d);
}

TEST_CASE(NAME("writes and reads back single bytes in every lane and bank")) {
    Dut d;
    d.wait_ready();
    const uint32_t addrs[] = {0x000000, 0x000001, 0x000002, 0x000003, 0x0003FF, 0x000400,
                              0x1FFFFF, 0x200000, 0x400000, 0x600000, 0x7FFFFF};
    for (uint32_t a : addrs) d.access(true, a, static_cast<uint8_t>(a * 7 + 1));
    for (uint32_t a : addrs) {
        CAPTURE(a);
        CHECK(d.access(false, a).first == static_cast<uint8_t>(a * 7 + 1));
        CHECK(d.sdram.byte(a) == static_cast<uint8_t>(a * 7 + 1));
    }
    // A byte write leaves its word's other lanes alone.
    CHECK(d.sdram.byte(0x000004) == 0);
    require_clean(d);
}

TEST_CASE(NAME("matches a byte array over random accesses, refreshes included")) {
    Dut d;
    d.wait_ready();
    std::mt19937 rng(7);
    std::vector<uint8_t> ref(1 << 23, 0);
    int worst = 0;
    // Mostly a small window so reads hit written bytes, with some far accesses.
    for (int i = 0; i < 40'000; i++) {
        uint32_t a = (rng() % 4 == 0) ? rng() & 0x7FFFFF : rng() & 0x3FFF;
        if (rng() % 2) {
            uint8_t v = static_cast<uint8_t>(rng());
            ref[a] = v;
            worst = std::max(worst, d.access(true, a, v).second);
        } else {
            auto [v, n] = d.access(false, a);
            CAPTURE(i, a);
            REQUIRE(v == ref[a]);
            worst = std::max(worst, n);
        }
        // Idle gaps of varying length, so refreshes land at every point of an access.
        for (int g = rng() % 4; g > 0; g--) d.tick();
    }
    CHECK(d.sdram.refreshes > 100);
    // At 27 MHz a read takes 5 clocks from idle; the tail of the access before
    // and a refresh can add 5 more. Systems budget this bound.
    if (kMhz == 27) CHECK(worst <= 10);
    require_clean(d);
}

TEST_CASE(NAME("refreshes on time with a request held the whole time")) {
    Dut d;
    d.wait_ready();
    for (int i = 0; i < 20'000; i++) d.access(false, static_cast<uint32_t>(i));
    CHECK(d.sdram.refreshes > 60);
    require_clean(d);
}
