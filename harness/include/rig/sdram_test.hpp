// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <optional>

#include "rig/link.hpp"
#include "rig/test_result.hpp"

namespace rig {

// Tests systems/shell-sdram: writes `bytes` of seeded random data in four
// regions, one in each quarter of the 8 MB SDRAM (so every bank is used), then
// checks each region with the shell's CRC command and reads samples back. That
// is the path a ROM upload takes. The result's CRC32 covers the shell's CRCs and
// the samples, so it depends only on the seed and size. If build_id is given,
// the shell's INFO must report it. Throws RigError if the link fails.
TestResult sdram_test(Link& link, uint32_t bytes, unsigned seed, std::optional<uint32_t> build_id = std::nullopt);

} // namespace rig
