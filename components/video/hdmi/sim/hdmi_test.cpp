// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <cstdlib>
#include <random>
#include <vector>

#include "Vhdmi_720p.h"
#include "Vhdmi_small.h"
#include "Vtmds_encoder.h"
#include "tmds_model.hpp"

namespace {

template <class V> void clock(V& m) {
    m.clk = 0;
    m.eval();
    m.clk = 1;
    m.eval();
}

// A test pattern that differs in every channel at every pixel.
uint32_t pattern(unsigned x, unsigned y) {
    uint32_t h = x * 0x9E3779B1u ^ y * 0x85EBCA77u;
    h ^= h >> 15;
    return h & 0xffffffu;
}

struct Mode {
    unsigned ha, hf, hs, hb, va, vf, vs, vb;
    bool hpos, vpos;
    int latency;
    unsigned htotal() const { return ha + hf + hs + hb; }
    unsigned vtotal() const { return va + vf + vs + vb; }
};

// One decoded pixel clock, at its position in the frame.
struct Px {
    tmds::Symbol s[3];
};

// Runs `frames` whole frames after the first frame pulse and returns each
// frame's decoded symbols by position, checking that the RTL's symbols are
// the spec encoder's for the same inputs.
template <class V> std::vector<std::vector<Px>> run(V& m, const Mode& md, int frames) {
    m.rst = 1;
    clock(m);
    m.rst = 0;
    struct Pos {
        unsigned x, y;
        bool act;
    };
    std::vector<Pos> hist;          // position of each period
    tmds::Encoder enc[3];
    std::vector<std::vector<Px>> out;
    long first = -1;                // period of the first frame pulse
    uint16_t prev_want[3] = {0, 0, 0};
    long prev_src = 0;
    bool have_prev = false;
    const unsigned total = md.htotal() * md.vtotal();
    for (long p = 0;; p++) {
        Pos now{m.x, m.y, m.act != 0};
        hist.push_back(now);
        if (m.frame && first < 0) first = p;
        // The colour for the position LATENCY periods ago.
        long src = p - md.latency;
        uint32_t rgb = src >= 0 && hist[src].act ? pattern(hist[src].x, hist[src].y) : 0;
        m.rgb = rgb;
        bool de = src >= 0 && hist[src].act;
        // The syncs the encoder sees with that pixel, recomputed from CEA-861's layout.
        clock(m);
        if (src < 0) continue;
        unsigned hc = hist[src].x, vc = hist[src].y;
        unsigned hs_on = md.ha + md.hf, vs_on = md.va + md.vf;
        unsigned vline = hc >= hs_on ? vc : (vc == 0 ? md.vtotal() - 1 : vc - 1);
        bool hs = hc >= hs_on && hc < hs_on + md.hs;
        bool vs = vline >= vs_on && vline < vs_on + md.vs;
        unsigned c0 = (unsigned(vs == md.vpos) << 1) | unsigned(hs == md.hpos);
        uint16_t want[3] = {enc[0].encode(de, rgb & 0xff, c0), enc[1].encode(de, (rgb >> 8) & 0xff, 0),
                            enc[2].encode(de, rgb >> 16, 0)};
        // The encoders' two stages: the symbols now are the ones for the
        // period before.
        bool have = have_prev;
        uint16_t expect[3] = {prev_want[0], prev_want[1], prev_want[2]};
        long at = prev_src;
        for (int ch = 0; ch < 3; ch++) prev_want[ch] = want[ch];
        prev_src = src;
        have_prev = true;
        if (!have) continue;
        uint16_t got[3] = {m.tmds0, m.tmds1, m.tmds2};
        for (int ch = 0; ch < 3; ch++) REQUIRE(got[ch] == expect[ch]);
        if (first < 0 || at < first) continue;
        long idx = at - first;
        if (idx % total == 0) {
            if (static_cast<int>(out.size()) == frames) break;
            out.emplace_back(total);
        }
        for (int ch = 0; ch < 3; ch++) out.back()[idx % total].s[ch] = tmds::decode(got[ch]);
    }
    return out;
}

// Checks a decoded frame: the picture where it belongs, control symbols
// everywhere else, and the sync pulses where CEA-861 puts them.
void check_frame(const std::vector<Px>& f, const Mode& md) {
    const unsigned ht = md.htotal(), vt = md.vtotal();
    int hs_pulses = 0;
    long vs_rise = -1, vs_fall = -1;
    bool hs_prev = false, vs_prev = false;  // in a pulse
    long hs_rise_at = -1;
    for (unsigned y = 0; y < vt; y++)
        for (unsigned x = 0; x < ht; x++) {
            const Px& p = f[y * ht + x];
            bool act = x < md.ha && y < md.va;
            for (int ch = 0; ch < 3; ch++) REQUIRE(p.s[ch].control == !act);
            if (act) {
                uint32_t want = pattern(x, y);
                REQUIRE(p.s[0].d == (want & 0xff));
                REQUIRE(p.s[1].d == ((want >> 8) & 0xff));
                REQUIRE(p.s[2].d == (want >> 16));
                continue;
            }
            REQUIRE(p.s[1].c == 0);
            REQUIRE(p.s[2].c == 0);
            bool hs = (p.s[0].c & 1) == md.hpos, vs = ((p.s[0].c >> 1) & 1) == md.vpos;
            long at = static_cast<long>(y) * ht + x;
            if (hs && !hs_prev) {
                hs_pulses++;
                hs_rise_at = at;
                REQUIRE(x == md.ha + md.hf);
            }
            if (!hs && hs_prev) REQUIRE(at - hs_rise_at == md.hs);
            if (vs && !vs_prev) vs_rise = at;
            if (!vs && vs_prev) vs_fall = at;
            hs_prev = hs;
            vs_prev = vs;
        }
    CHECK(hs_pulses == static_cast<int>(vt));
    // Vertical sync: V_SYNC lines, starting and ending with a line's hsync.
    CHECK(vs_rise == static_cast<long>(md.va + md.vf) * ht + md.ha + md.hf);
    CHECK(vs_fall - vs_rise == static_cast<long>(md.vs) * ht);
}

} // namespace

TEST_CASE("tmds_encoder gives the DVI spec's symbols, which decode to the input") {
    Vtmds_encoder m;
    m.rst = 1;
    clock(m);
    m.rst = 0;
    tmds::Encoder ref;
    std::mt19937 rng(1);
    int worst = 0;
    bool de = false;
    uint8_t d = 0;
    unsigned c = 0;
    struct In {
        bool de;
        uint8_t d;
        unsigned c;
    } prev{false, 0, 0};
    for (int i = 0; i < 2'000'000; i++) {
        // Long video runs with short blanking, and every byte value often.
        if (rng() % 200 == 0) de = !de;
        d = rng() % 4 == 0 ? d : static_cast<uint8_t>(rng());
        c = rng() % 4;
        m.de = de;
        m.d = d;
        m.c = c;
        clock(m);
        // Two stages: the symbol now is for the inputs of the clock before.
        In in = prev;
        prev = {de, d, c};
        if (i == 0) continue;
        uint16_t want = ref.encode(in.de, in.d, in.c);
        REQUIRE(m.q == want);
        tmds::Symbol s = tmds::decode(m.q);
        REQUIRE(s.control == !in.de);
        if (in.de) REQUIRE(s.d == in.d);
        else REQUIRE(s.c == in.c);
        worst = std::max(worst, std::abs(ref.disparity()));
    }
    // The disparity stays within a symbol's worth of zero.
    CHECK(worst <= 10);
}

TEST_CASE("hdmi gives CEA-861 1280x720 frames with the picture in place") {
    Vhdmi_720p m;
    Mode md{1280, 110, 40, 220, 720, 5, 5, 20, true, true, 2};
    auto frames = run(m, md, 2);
    REQUIRE(frames.size() == 2);
    for (auto& f : frames) check_frame(f, md);
}

TEST_CASE("hdmi follows its parameters: a small mode, negative syncs, a longer latency") {
    Vhdmi_small m;
    Mode md{16, 2, 3, 4, 8, 1, 2, 3, false, false, 4};
    auto frames = run(m, md, 20);
    REQUIRE(frames.size() == 20);
    for (auto& f : frames) check_frame(f, md);
}
