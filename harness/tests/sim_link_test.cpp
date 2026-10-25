// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include "golden.hpp"
#include "rig/echo_test.hpp"
#include "rig/sim_systems.hpp"

TEST_CASE("the echo test passes on the sim backend with the golden CRC") {
    auto golden = golden_crcs(RS_ECHO_GOLDEN);
    auto it = golden.find({64'000, 1});
    REQUIRE(it != golden.end());

    auto link = rig::make_uart_echo_sim();
    auto r = rig::echo_test(*link, 64'000, 1);
    INFO(r.detail);
    REQUIRE(r.passed);
    REQUIRE(r.crc32 == it->second);
    REQUIRE(link->frame_errors() == 0);
}
