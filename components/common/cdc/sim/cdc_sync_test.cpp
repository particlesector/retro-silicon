// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <deque>
#include <random>

#include "Vcdc_sync3.h"

TEST_CASE("cdc_sync delays its input by STAGES clocks") {
    Vcdc_sync3 m;
    std::mt19937 rng(7);
    std::deque<uint16_t> sent;
    for (int i = 0; i < 1000; i++) {
        uint16_t d = rng() & 0x1ff;
        m.d = d;
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
        sent.push_back(d);
        if (sent.size() > 3) sent.pop_front();
        if (i >= 2) REQUIRE(m.q == sent.front());
    }
}
