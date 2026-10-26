// SPDX-License-Identifier: Apache-2.0
#pragma once
// TMDS as DVI 1.0 section 3.2 gives it: the encoder, written from the spec
// independently of the RTL, and the decoder a receiver runs. Header-only, so
// the harness's system tests can decode a sim's HDMI output with it too.

#include <array>
#include <bit>
#include <cstdint>
#include <optional>

namespace tmds {

// The four control symbols, for {c1, c0} = 0..3.
inline constexpr std::array<uint16_t, 4> kControl = {0b1101010100, 0b0010101011, 0b0101010100, 0b1010101011};

class Encoder {
public:
    // One pixel clock: video (de) or a control period.
    uint16_t encode(bool de, uint8_t d, unsigned c) {
        if (!de) {
            cnt_ = 0;
            return kControl[c & 3];
        }
        int n1d = std::popcount(d);
        bool xnor = n1d > 4 || (n1d == 4 && !(d & 1));
        unsigned qm = d & 1;
        for (int i = 1; i < 8; i++) {
            unsigned prev = (qm >> (i - 1)) & 1, di = (d >> i) & 1;
            qm |= (xnor ? !(prev ^ di) : (prev ^ di)) << i;
        }
        if (!xnor) qm |= 1u << 8;
        bool q8 = (qm >> 8) & 1;
        int n1 = std::popcount(qm & 0xffu), n0 = 8 - n1;
        uint16_t q;
        if (cnt_ == 0 || n1 == n0) {
            q = static_cast<uint16_t>((q8 ? 0 : 1u << 9) | (qm & 0x100u) | (q8 ? qm & 0xffu : ~qm & 0xffu));
            cnt_ += q8 ? n1 - n0 : n0 - n1;
        } else if ((cnt_ > 0 && n1 > n0) || (cnt_ < 0 && n0 > n1)) {
            q = static_cast<uint16_t>((1u << 9) | (qm & 0x100u) | (~qm & 0xffu));
            cnt_ += 2 * q8 + n0 - n1;
        } else {
            q = static_cast<uint16_t>((qm & 0x100u) | (qm & 0xffu));
            cnt_ += -2 * !q8 + n1 - n0;
        }
        return q;
    }
    int disparity() const { return cnt_; }

private:
    int cnt_ = 0;
};

// A received symbol: a control period's two bits, or a video byte.
struct Symbol {
    bool control;
    unsigned c;  // when control
    uint8_t d;   // when video
};

// Decodes a symbol as a DVI receiver does once it's in the video period or
// blanking. Every 10-bit value that isn't a control symbol decodes as video.
inline Symbol decode(uint16_t q) {
    for (unsigned c = 0; c < 4; c++)
        if (q == kControl[c]) return {true, c, 0};
    unsigned v = (q >> 9) & 1 ? ~q & 0xffu : q & 0xffu;
    bool xor_ = (q >> 8) & 1;
    unsigned d = v & 1;
    for (int i = 1; i < 8; i++) {
        unsigned b = ((v >> i) ^ (v >> (i - 1))) & 1;
        d |= (xor_ ? b : !b) << i;
    }
    return {false, 0, static_cast<uint8_t>(d)};
}

} // namespace tmds
