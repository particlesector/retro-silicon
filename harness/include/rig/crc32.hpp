// SPDX-License-Identifier: Apache-2.0
#pragma once
// CRC-32 (IEEE 802.3, reflected, as used by zlib), matching components/common/crc32.

#include <array>
#include <cstdint>
#include <span>

namespace rig {

class Crc32 {
public:
    void update(std::span<const uint8_t> bytes) {
        for (uint8_t b : bytes) state_ = table()[(state_ ^ b) & 0xFF] ^ (state_ >> 8);
    }
    uint32_t value() const { return ~state_; }

private:
    static const std::array<uint32_t, 256>& table() {
        static const std::array<uint32_t, 256> t = [] {
            std::array<uint32_t, 256> t{};
            for (uint32_t i = 0; i < 256; i++) {
                uint32_t c = i;
                for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
                t[i] = c;
            }
            return t;
        }();
        return t;
    }

    uint32_t state_ = 0xFFFFFFFFu;
};

} // namespace rig
