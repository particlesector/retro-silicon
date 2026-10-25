// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <vector>

#include "Vce_all.h"
#include "Vce_half.h"
#include "Vce_nes.h"

namespace {

// Clocks the model with `en` from `gate` and returns, per enabled clock,
// whether ce fired; checks ce never fires with en low.
template <class V>
std::vector<bool> run(V& m, int clocks, std::mt19937* gate = nullptr) {
    m.rst = 1;
    m.en = 0;
    m.clk = 0;
    m.eval();
    m.clk = 1;
    m.eval();
    m.rst = 0;
    std::vector<bool> fired;
    for (int i = 0; i < clocks; i++) {
        m.en = gate ? (*gate)() % 3 != 0 : 1;
        m.clk = 0;
        m.eval();
        if (!m.en) REQUIRE(m.ce == 0);
        else fired.push_back(m.ce != 0);
        m.clk = 1;
        m.eval();
    }
    return fired;
}

} // namespace

TEST_CASE("clock_enable gives exactly NUM pulses per DEN clocks, evenly spaced") {
    Vce_nes m;
    auto f = run(m, 176 * 100);
    int count = 0, last = -1, gap_min = 1 << 30, gap_max = 0;
    for (int i = 0; i < static_cast<int>(f.size()); i++) {
        if (!f[i]) continue;
        count++;
        if (last >= 0) {
            gap_min = std::min(gap_min, i - last);
            gap_max = std::max(gap_max, i - last);
        }
        last = i;
        if ((i + 1) % 176 == 0) CHECK(count == 35 * (i + 1) / 176);
    }
    CHECK(count == 3500);
    CHECK(gap_min == 5);  // 176/35 = 5.03
    CHECK(gap_max == 6);
}

TEST_CASE("clock_enable holds its phase while en is low") {
    Vce_nes a, b;
    std::mt19937 rng(5);
    auto gated = run(a, 30'000, &rng);
    auto steady = run(b, static_cast<int>(gated.size()));
    CHECK(gated == steady);
}

TEST_CASE("clock_enable handles the edge ratios 1/2 and 1/1") {
    Vce_half h;
    auto f = run(h, 10);
    CHECK(f == std::vector<bool>{false, true, false, true, false, true, false, true, false, true});
    Vce_all all;
    for (bool x : run(all, 10)) CHECK(x);
}
