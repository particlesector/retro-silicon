// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>

#include "rig/link.hpp"
#include "rig/test_result.hpp"

namespace rig {

// Streams `bytes` seeded random bytes through an echo design and checks each one
// comes back in order. At most `window` bytes are in flight, which must not
// exceed the design's FIFO depth. Throws RigError if the link itself fails.
TestResult echo_test(Link& link, uint64_t bytes, unsigned seed, size_t window = 2048);

} // namespace rig
