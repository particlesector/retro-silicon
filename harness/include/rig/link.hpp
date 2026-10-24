// SPDX-License-Identifier: Apache-2.0
#pragma once
// A byte pipe to a design under test. The sim and board backends both provide
// one, so a test runs unchanged against either.

#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string>

namespace rig {

// Thrown when the rig itself fails (port gone, model stuck), as opposed to the
// design giving a wrong answer. The runner maps it to exit code 2.
struct RigError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

class Link {
public:
    virtual ~Link() = default;

    // Queues all of `data` for sending.
    virtual void write(std::span<const uint8_t> data) = 0;

    // Reads up to `buf.size()` bytes, waiting at most `timeout_ms` for the first
    // one; returns 0 on timeout. For the sim, the timeout is simulated time.
    virtual size_t read(std::span<uint8_t> buf, int timeout_ms) = 0;

    // The link's bit rate, so tests can size timeouts.
    virtual unsigned baud() const = 0;
};

} // namespace rig
