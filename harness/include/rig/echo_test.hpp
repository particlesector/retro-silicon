// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <string>

#include "rig/link.hpp"

namespace rig {

struct TestResult {
    std::string name;
    bool passed = false;
    std::string detail;  // why it failed; empty on a pass
    uint64_t bytes = 0;  // bytes checked
    double seconds = 0;
    uint32_t crc32 = 0;  // of the bytes received, comparable across backends
};

// Streams `bytes` seeded random bytes through an echo design and checks each one
// comes back in order. At most `window` bytes are in flight, which must not
// exceed the design's FIFO depth. Throws RigError if the link itself fails.
TestResult echo_test(Link& link, uint64_t bytes, unsigned seed, size_t window = 2048);

} // namespace rig
