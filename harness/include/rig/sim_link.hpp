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

    // clks_per_bit must match the design's CLKS_PER_BIT.
    explicit SimLink(std::unique_ptr<SimModel> model, int clks_per_bit = kClksPerBit);
    ~SimLink() override;

    void write(std::span<const uint8_t> data) override;
    size_t read(std::span<uint8_t> buf, int timeout_ms) override;
    unsigned baud() const override { return kClockHz / static_cast<unsigned>(clks_per_bit_); }

    uint64_t cycles() const { return cycles_; }
    int frame_errors() const { return rx_.frame_errors; }

private:
    void tick();

    std::unique_ptr<SimModel> model_;
    int clks_per_bit_;
    UartEncoder tx_;  // host -> design
    UartDecoder rx_;  // design -> host
    size_t taken_ = 0;             // decoded bytes already handed out
    uint64_t cycles_ = 0;
};

} // namespace rig
