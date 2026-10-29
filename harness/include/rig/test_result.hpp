// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <optional>
#include <string>

namespace rig {

struct TestResult {
    std::string name;
    bool passed = false;
    std::string detail;  // why it failed; empty on a pass
    std::string notes;   // what happened on the way, such as retries
    uint64_t bytes = 0;  // bytes checked
    double seconds = 0;
    uint32_t crc32 = 0;  // of the bytes received, comparable across backends
    std::optional<uint32_t> audio_crc32;  // a NES run's audio CRC, likewise
};

} // namespace rig
