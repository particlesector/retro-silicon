// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include "Vtmds_phy_xc7.h"

// With the stand-in serializers, each pair carries its symbol's bit 0: the
// clock pair the clock pattern's (1), each data pair its channel's.
TEST_CASE("tmds_phy_xc7: each channel on its own pair", "[tmds_phy_xc7]") {
    Vtmds_phy_xc7 m;
    m.rst = 0;
    m.pclk = m.fclk = 0;
    for (int ch = 0; ch < 3; ch++) {
        m.tmds0 = ch == 0 ? 1 : 0;
        m.tmds1 = ch == 1 ? 1 : 0;
        m.tmds2 = ch == 2 ? 1 : 0;
        m.eval();
        INFO("channel " << ch);
        CHECK(m.tmds_clk_p == 1);
        CHECK(m.tmds_clk_n == 0);
        CHECK(m.tmds_d_p == (1u << ch));
        CHECK(m.tmds_d_n == (7u & ~(1u << ch)));
    }
}
