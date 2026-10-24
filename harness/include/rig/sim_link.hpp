// SPDX-License-Identifier: Apache-2.0
#pragma once

#include <cstdint>
#include <memory>

#include "rig/link.hpp"
#include "rig/uart_model.hpp"

class Vuart_echo_sim;

namespace rig {

// The systems/uart-echo design in Verilator, driven over a bit-level UART model.
// Time only advances inside read(), so a test's timeouts are simulated time.
class SimLink : public Link {
public:
    static constexpr unsigned kClockHz = 27'000'000;
    static constexpr int kClksPerBit = 18;  // must match the model's CLKS_PER_BIT

    SimLink();
    ~SimLink() override;

    void write(std::span<const uint8_t> data) override;
    size_t read(std::span<uint8_t> buf, int timeout_ms) override;
    unsigned baud() const override { return kClockHz / kClksPerBit; }

    uint64_t cycles() const { return cycles_; }
    int frame_errors() const { return rx_.frame_errors; }

private:
    void tick();

    std::unique_ptr<Vuart_echo_sim> model_;
    UartEncoder tx_{kClksPerBit};  // host -> design
    UartDecoder rx_{kClksPerBit};  // design -> host
    size_t taken_ = 0;             // decoded bytes already handed out
    uint64_t cycles_ = 0;
};

} // namespace rig
