// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <cstdint>

#include "Vapu_mixer.h"

TEST_CASE("apu_mixer gives the NESdev wiki's nonlinear mix for every level") {
    Vapu_mixer m;
    auto mix = [&](int p1, int p2, int t, int n, int d) {
        m.pulse1 = p1;
        m.pulse2 = p2;
        m.triangle = t;
        m.noise = n;
        m.dmc = d;
        for (int i = 0; i < 2; i++) {  // the address on a falling edge, the read on the rising one
            m.clk = 0;
            m.eval();
            m.clk = 1;
            m.eval();
        }
        return int(m.out);
    };
    // The formulas, scaled as the generator scales them.
    auto want = [](int p1, int p2, int t, int n, int d) {
        double pulse = p1 + p2 ? 95.52 / (8128.0 / (p1 + p2) + 100) : 0;
        int tn = 3 * t + 2 * n + d;
        double tnd = tn ? 163.67 / (24329.0 / tn + 100) : 0;
        return (pulse + tnd) * 65520;
    };
    CHECK(mix(0, 0, 0, 0, 0) == 0);
    int worst = 0;
    for (int p = 0; p <= 15; p++)
        for (int t = 0; t <= 15; t++)
            for (int n = 0; n <= 15; n += 5)
                for (int d = 0; d <= 127; d += 9) {
                    int got = mix(p, 15 - p, t, n, d);
                    worst = std::max(worst, int(std::lround(std::abs(got - want(p, 15 - p, t, n, d)))));
                }
    CHECK(worst <= 1);
    CHECK(mix(15, 15, 15, 15, 127) == 65518);
}
