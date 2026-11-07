// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <optional>

#include "rig/link.hpp"
#include "rig/test_result.hpp"

namespace rig {

// The memory a shell-sdram build has: its size, and how many regions the test
// spreads over it, one in each equal part (one per bank: 4 for one chip, 8 for
// two). The default is the Tang Nano 20K's 8 MB chip.
struct SdramLayout {
    uint32_t size = 8u << 20;
    uint32_t regions = 4;
};

// Tests systems/shell-sdram: writes `bytes` of seeded random data in
// layout.regions regions, one in each part of the SDRAM (so every bank is used), then
// checks each region with the shell's CRC command and reads samples back. That
// is the path a ROM upload takes. The result's CRC32 covers the shell's CRCs and
// the samples, so it depends only on the seed, size and layout. If build_id is
// given, the shell's INFO must report it. Throws RigError if the link fails.
TestResult sdram_test(Link& link, uint32_t bytes, unsigned seed, std::optional<uint32_t> build_id = std::nullopt,
                      SdramLayout layout = {});

} // namespace rig
