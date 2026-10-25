// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include "golden.hpp"
#include "rig/sdram_test.hpp"
#include "rig/sim_systems.hpp"

TEST_CASE("the SDRAM test passes on the sim backend with the golden CRC") {
    auto golden = golden_crcs(RS_SDRAM_GOLDEN);
    auto it = golden.find({65536, 1});
    REQUIRE(it != golden.end());

    auto link = rig::make_shell_sdram_sim();
    auto r = rig::sdram_test(*link, 65536, 1, RS_SHELL_SDRAM_BUILD_ID);
    INFO(r.detail << " / " << r.notes);
    REQUIRE(r.passed);
    REQUIRE(r.bytes == 65536);
    REQUIRE(r.crc32 == it->second);
}
