// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <optional>

#include "rig/link.hpp"
#include "rig/test_result.hpp"

namespace rig {

// Runs `commands` seeded random PING, PEEK, POKE and INFO commands against
// systems/shell-ram (the test shell with a 4 KB scratch RAM), checking every
// response against a model of the RAM. With fault_rate > 0, bytes are damaged
// in both directions at that rate per byte, and every command must still
// succeed through retries. The CRC32 covers the PING and PEEK responses, so it
// depends only on the seed and command count, not on the faults. If build_id
// is given, the shell's INFO must report it. Throws RigError if the link fails.
TestResult shell_test(Link& link, unsigned commands, unsigned seed, double fault_rate,
                      std::optional<uint32_t> build_id = std::nullopt);

} // namespace rig
