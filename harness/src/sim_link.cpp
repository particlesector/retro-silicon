// SPDX-License-Identifier: Apache-2.0
#include "rig/sim_link.hpp"

#include <algorithm>

namespace rig {

SimLink::SimLink(std::unique_ptr<SimModel> model, int clks_per_bit)
    : model_(std::move(model)), clks_per_bit_(clks_per_bit), tx_(clks_per_bit), rx_(clks_per_bit) {
    for (int i = 0; i < 32; i++) tick();  // through power-on reset, line idle
}

SimLink::~SimLink() = default;

void SimLink::tick() {
    rx_.sample(model_->tick(tx_.next()));
    cycles_++;
}

void SimLink::write(std::span<const uint8_t> data) {
    for (uint8_t b : data) tx_.push(b);
}

size_t SimLink::read(std::span<uint8_t> buf, int timeout_ms) {
    uint64_t limit = cycles_ + static_cast<uint64_t>(timeout_ms) * (kClockHz / 1000);
    while (rx_.bytes.size() == taken_ && cycles_ < limit) tick();
    // Keep running while bytes are still arriving back to back, so reads come in
    // useful chunks rather than one byte each.
    while (rx_.bytes.size() - taken_ < buf.size() && !tx_.idle()) tick();
    size_t n = std::min(buf.size(), rx_.bytes.size() - taken_);
    std::copy_n(rx_.bytes.begin() + static_cast<std::ptrdiff_t>(taken_), n, buf.begin());
    taken_ += n;
    if (taken_ == rx_.bytes.size()) {
        rx_.bytes.clear();
        taken_ = 0;
    }
    return n;
}

} // namespace rig
