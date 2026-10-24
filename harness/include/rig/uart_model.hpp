// SPDX-License-Identifier: Apache-2.0
#pragma once
// Bit-level 8N1 UART models for driving and checking RTL in Verilator, one call
// per clock. Shared by the sim tests and the harness's sim backend.

#include <cstdint>
#include <deque>
#include <vector>

namespace rig {

// Drives a line from a byte queue, `clks` clocks per bit, back to back.
class UartEncoder {
public:
    explicit UartEncoder(int clks) : clks_(clks) {}

    void push(uint8_t b) { queue_.push_back(b); }
    bool idle() const { return queue_.empty() && bit_ < 0; }

    // The line level for this clock.
    bool next() {
        if (bit_ < 0) {
            if (queue_.empty()) return true;
            frame_ = static_cast<uint16_t>(0x200 | (queue_.front() << 1));  // stop, data, start
            queue_.pop_front();
            bit_ = 0;
            count_ = 0;
        }
        bool level = (frame_ >> bit_) & 1;
        if (++count_ == clks_) {
            count_ = 0;
            if (++bit_ == 10) bit_ = -1;
        }
        return level;
    }

private:
    int clks_;
    std::deque<uint8_t> queue_;
    uint16_t frame_ = 0;
    int bit_ = -1;  // bit being sent; -1 between bytes
    int count_ = 0;
};

// Decodes a line sampled once per clock, assuming exactly `clks` clocks per bit.
class UartDecoder {
public:
    explicit UartDecoder(int clks) : clks_(clks) {}

    void sample(bool line) {
        if (wait_ < 0) {
            if (!line) {
                wait_ = clks_ + clks_ / 2 - 1;  // middle of data bit 0
                bit_ = 0;
                frame_ = 0;
            }
            return;
        }
        if (wait_-- > 0) return;
        frame_ = static_cast<uint16_t>(frame_ | (line << bit_));
        if (++bit_ == 9) {
            if (frame_ >> 8)
                bytes.push_back(static_cast<uint8_t>(frame_));
            else
                frame_errors++;
            wait_ = -1;
        } else
            wait_ = clks_ - 1;
    }

    std::vector<uint8_t> bytes;
    int frame_errors = 0;

private:
    int clks_;
    int wait_ = -1;  // clocks to the next sample; -1 while idle
    int bit_ = 0;
    uint16_t frame_ = 0;
};

} // namespace rig
