// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <memory>

#include "rig/link.hpp"
#include "rig/uart_model.hpp"

namespace rig {

// One clock of a design with a UART: drive its RX line, return its TX line.
class SimModel {
public:
    virtual ~SimModel() = default;
    virtual bool tick(bool rx) = 0;
};

// A Verilated design driven over a bit-level UART model, so the same tests run
// against it as against a board. Time only advances inside read(), so a test's
// timeouts are simulated time.
class SimLink : public Link {
public:
    static constexpr unsigned kClockHz = 27'000'000;
    static constexpr int kClksPerBit = 18;  // 1.5 Mbaud, the board link's rate

    // clks_per_bit must match the design's CLKS_PER_BIT. With jitter_clks > 0,
    // each write starts after a seeded random 0 to jitter_clks - 1 idle clocks,
    // as a board's host is never in step with the FPGA clock; without it, every
    // command arrives at the same phase of anything the design divides its
    // clock by, which hides phase-dependent bugs. clock_hz is the design's
    // clock, for the timeouts and the baud rate.
    explicit SimLink(std::unique_ptr<SimModel> model, int clks_per_bit = kClksPerBit, int jitter_clks = 0,
                     unsigned clock_hz = kClockHz);
    ~SimLink() override;

    void write(std::span<const uint8_t> data) override;
    size_t read(std::span<uint8_t> buf, int timeout_ms) override;
    unsigned baud() const override { return clock_hz_ / static_cast<unsigned>(clks_per_bit_); }

    uint64_t cycles() const { return cycles_; }
    int frame_errors() const { return rx_.frame_errors; }

private:
    void tick();

    std::unique_ptr<SimModel> model_;
    int clks_per_bit_;
    unsigned clock_hz_;
    UartEncoder tx_;  // host -> design
    UartDecoder rx_;  // design -> host
    size_t taken_ = 0;             // decoded bytes already handed out
    uint64_t cycles_ = 0;
    int jitter_clks_;
    uint64_t jitter_state_ = 0x9E3779B97F4A7C15ull;
};

} // namespace rig
