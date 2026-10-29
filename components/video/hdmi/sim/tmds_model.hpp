// SPDX-License-Identifier: Apache-2.0
#pragma once
// TMDS as DVI 1.0 section 3.2 gives it: the encoder, written from the spec
// independently of the RTL, and the decoder a receiver runs. Then HDMI 1.4's
// additions (section 5.2): preambles, guard bands and data islands, TERC4,
// packets and their BCH codes, decoded as a sink does. Header-only, so the
// harness's system tests can decode a sim's HDMI output with it too.

#include <array>
#include <bit>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

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

// ---- HDMI ----

// TERC4: the 16 symbols a data island's 4-bit values become (HDMI 1.4
// table 5-11, bit 0 sent first).
inline constexpr std::array<uint16_t, 16> kTerc4 = {
    0b1010011100, 0b1001100011, 0b1011100100, 0b1011100010, 0b0101110001, 0b0100011110,
    0b0110001110, 0b0100111100, 0b1011001100, 0b0100111001, 0b0110011100, 0b1011000110,
    0b1010001110, 0b1001110001, 0b0101100011, 0b1011000011};
inline constexpr uint16_t kGuardVideo02 = 0b1011001100, kGuardVideo1 = 0b0100110011, kGuardData = 0b0100110011;

inline std::optional<unsigned> terc4(uint16_t q) {
    for (unsigned d = 0; d < 16; d++)
        if (kTerc4[d] == q) return d;
    return std::nullopt;
}

// The packets' BCH codes: G(x) = 1 + x^6 + x^7 + x^8 over the bits in the
// order sent, as a reflected CRC-8 with no initial value.
inline uint8_t bch(const std::vector<bool>& bits) {
    uint8_t e = 0;
    for (bool b : bits) e = static_cast<uint8_t>((e >> 1) ^ (((e ^ b) & 1) ? 0x83 : 0));
    return e;
}

// What a pixel clock carried, as a sink sees it.
enum class Period { Control, VideoPreamble, IslandPreamble, VideoGuard, IslandGuard, Island, Video };

struct HdmiPixel {
    Period period = Period::Control;
    unsigned sync = 0;          // {vsync, hsync} on channel 0, outside video
    uint8_t d[3] = {0, 0, 0};   // video bytes: blue, green, red
};

// An HDMI sink's decoder: one call per pixel clock. It follows preambles
// into video and data islands, checks guard bands, rebuilds each packet and
// checks its BCH codes, InfoFrame checksums and audio sample parity, and
// keeps the audio samples, clock regeneration values and InfoFrames.
// Anything out of place goes in `errors` (the first 20).
class HdmiDecoder {
public:
    std::vector<std::pair<int16_t, int16_t>> samples;
    std::vector<std::string> errors;
    int packets = 0, nulls = 0, acr = 0, sample_packets = 0, islands = 0, video_periods = 0;
    uint32_t n = 0, cts = 0;
    std::vector<uint8_t> avi, audio_if;  // the last InfoFrames: header, then PB0-PBn
    bool dvi_video = false;              // a video period came without a preamble

    HdmiPixel operator()(uint16_t q0, uint16_t q1, uint16_t q2) {
        HdmiPixel px;
        Symbol s0 = decode(q0), s1 = decode(q1), s2 = decode(q2);
        switch (state_) {
        case State::Control:
            if (s0.control && s1.control && s2.control) {
                px.sync = s0.c;
                unsigned kind = s1.c == 1 && s2.c == 0 ? 1 : s1.c == 1 && s2.c == 1 ? 2 : 0;
                if (kind != 0 && kind == pre_kind_) pre_n_++;
                else if (kind != 0) pre_kind_ = kind, pre_n_ = 1;
                else {
                    if (s1.c != 0 || s2.c != 0) error("control symbols with CTL bits that make no preamble");
                    pre_kind_ = 0, pre_n_ = 0;
                }
                px.period = kind == 1 ? Period::VideoPreamble : kind == 2 ? Period::IslandPreamble : Period::Control;
                return px;
            }
            if (pre_kind_ != 0 && pre_n_ != 8) error("a preamble of " + std::to_string(pre_n_) + " clocks");
            if (pre_kind_ == 1) state_ = State::VideoGuard, guard_n_ = 0;
            else if (pre_kind_ == 2) state_ = State::IslandGuard, guard_n_ = 0, islands++;
            else {
                state_ = State::Video;
                dvi_video = true;
                video_periods++;
            }
            pre_kind_ = 0, pre_n_ = 0;
            return (*this)(q0, q1, q2);
        case State::VideoGuard:
            px.period = Period::VideoGuard;
            if (q0 != kGuardVideo02 || q1 != kGuardVideo1 || q2 != kGuardVideo02) error("a bad video guard band");
            if (++guard_n_ == 2) state_ = State::Video, video_periods++;
            return px;
        case State::Video:
            if (s0.control || s1.control || s2.control) {
                if (!(s0.control && s1.control && s2.control)) error("video ending on some channels only");
                state_ = State::Control;
                return (*this)(q0, q1, q2);
            }
            px.period = Period::Video;
            px.d[0] = s0.d, px.d[1] = s1.d, px.d[2] = s2.d;
            return px;
        case State::IslandGuard:
        case State::TrailingGuard: {
            px.period = Period::IslandGuard;
            auto g = terc4(q0);
            if (q1 != kGuardData || q2 != kGuardData || !g || (*g & 0xC) != 0xC) error("a bad data island guard band");
            px.sync = g ? *g & 3 : 0;
            if (++guard_n_ == 2) {
                if (state_ == State::IslandGuard) state_ = State::Island, pkt_i_ = 0, first_ = true;
                else state_ = State::Control;
            }
            return px;
        }
        case State::Island: {
            if (pkt_i_ == 0 && q1 == kGuardData && q2 == kGuardData) {
                state_ = State::TrailingGuard, guard_n_ = 0;
                return (*this)(q0, q1, q2);
            }
            px.period = Period::Island;
            auto a = terc4(q0), b = terc4(q1), c = terc4(q2);
            if (!a || !b || !c) {
                error("a symbol in a data island that isn't TERC4");
                state_ = State::Control;
                return px;
            }
            px.sync = *a & 3;
            if (((*a >> 3) & 1) == first_) error("channel 0 bit 3 wrong on a packet clock");
            first_ = false;
            if (pkt_i_ == 0) hdr_.assign(32, false), sub_.assign(4, std::vector<bool>(64, false));
            hdr_[pkt_i_] = (*a >> 2) & 1;
            for (int k = 0; k < 4; k++) {
                sub_[k][2 * pkt_i_] = (*b >> k) & 1;
                sub_[k][2 * pkt_i_ + 1] = (*c >> k) & 1;
            }
            if (++pkt_i_ == 32) {
                packet();
                pkt_i_ = 0;
            }
            return px;
        }
        }
        return px;
    }

private:
    enum class State { Control, VideoGuard, Video, IslandGuard, Island, TrailingGuard };
    State state_ = State::Control;
    unsigned pre_kind_ = 0, pre_n_ = 0, guard_n_ = 0, pkt_i_ = 0;
    bool first_ = false;
    std::vector<bool> hdr_;
    std::vector<std::vector<bool>> sub_;
    unsigned iec_ = 0;    // the IEC 60958 frame of the next sample
    bool iec_known_ = false;

    void error(const std::string& e) {
        if (errors.size() < 20) errors.push_back(e);
    }
    static std::vector<uint8_t> bytes(const std::vector<bool>& bits, int n) {
        std::vector<uint8_t> out(n);
        for (int i = 0; i < n * 8; i++) out[i / 8] |= static_cast<uint8_t>(bits[i] << (i % 8));
        return out;
    }
    void packet() {
        packets++;
        std::vector<bool> h(hdr_.begin(), hdr_.begin() + 24);
        if (bch(h) != bytes(std::vector<bool>(hdr_.begin() + 24, hdr_.end()), 1)[0]) error("a header's BCH code is wrong");
        std::vector<std::vector<uint8_t>> sb;
        for (auto& s : sub_) {
            std::vector<bool> d(s.begin(), s.begin() + 56);
            if (bch(d) != bytes(std::vector<bool>(s.begin() + 56, s.end()), 1)[0]) error("a subpacket's BCH code is wrong");
            sb.push_back(bytes(d, 7));
        }
        auto hb = bytes(h, 3);
        if (hb[0] == 0x00) {
            nulls++;
            for (auto& s : sb)
                for (auto v : s)
                    if (v) error("a null packet with data");
        } else if (hb[0] == 0x01) {
            acr++;
            for (auto& s : sb) {
                uint32_t c = (s[1] & 0xF) << 16 | s[2] << 8 | s[3], nn = (s[4] & 0xF) << 16 | s[5] << 8 | s[6];
                if (s != sb[0]) error("clock regeneration subpackets differ");
                cts = c, n = nn;
            }
        } else if (hb[0] == 0x02) {
            sample_packets++;
            if (hb[1] & 0x10) error("an audio sample packet in layout 1");
            for (int k = 0; k < 4; k++) {
                if (!((hb[1] >> k) & 1)) continue;
                auto& s = sb[k];
                if (s[0] || s[3]) error("audio samples with more than 16 bits");
                int16_t l = static_cast<int16_t>(s[2] << 8 | s[1]), r = static_cast<int16_t>(s[5] << 8 | s[4]);
                bool block = (hb[2] >> (4 + k)) & 1;
                if (block) iec_ = 0, iec_known_ = true;
                bool cs = iec_ == 2 || iec_ == 25;
                bool cl = (s[6] >> 2) & 1, cr = (s[6] >> 6) & 1;
                if (iec_known_ && (cl != cs || cr != cs)) error("a channel status bit is wrong");
                if (iec_known_ && block != (iec_ == 0)) error("the block start flag is wrong");
                if (std::popcount(static_cast<unsigned>(s[1] | s[2] << 8)) % 2 != (((s[6] >> 3) ^ (s[6] >> 2)) & 1) ||
                    std::popcount(static_cast<unsigned>(s[4] | s[5] << 8)) % 2 != (((s[6] >> 7) ^ (s[6] >> 6)) & 1))
                    error("an audio sample's parity is wrong");
                if (s[6] & 0x33) error("an audio sample's V or U bit is set");
                iec_ = (iec_ + 1) % 192;
                samples.push_back({l, r});
            }
        } else if (hb[0] & 0x80) {
            unsigned len = hb[2];
            std::vector<uint8_t> pb;
            for (auto& s : sb) pb.insert(pb.end(), s.begin(), s.end());
            uint8_t sum = hb[0] + hb[1] + hb[2];
            for (unsigned i = 0; i <= len && i < pb.size(); i++) sum += pb[i];
            if (sum != 0) error("an InfoFrame's checksum is wrong");
            std::vector<uint8_t> all{hb[0], hb[1], hb[2]};
            all.insert(all.end(), pb.begin(), pb.begin() + std::min<size_t>(len + 1, pb.size()));
            if (hb[0] == 0x82) avi = all;
            else if (hb[0] == 0x84) audio_if = all;
            else error("an unknown InfoFrame");
        } else
            error("a packet of unknown type");
    }
};

} // namespace tmds
