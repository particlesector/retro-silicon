// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <vector>

#include "Vls_nes.h"
#include "Vls_late.h"
#include "Vls_small.h"

namespace {

// The NES on a Tang Nano 20K into 720p: the source clock at 46.40625 MHz and
// the display's at 74.25 MHz, both from one PLL, so 5 source clocks take as
// long as 8 display clocks. Time here is in units of 1/40 of that.
constexpr int kSrcPeriod = 8, kDispPeriod = 5;
constexpr unsigned kHTotal = 1650, kVTotal = 750;
constexpr unsigned kX0 = 256, kScale = 3;

// A pixel's value: which frame, line and column it came from.
uint16_t value(unsigned frame, unsigned x, unsigned y) { return (frame * 97 + x * 5 + y * 23) & 0x1ff; }

// The source: the 2C02's timing, 341 dots by 262 lines, a dot each time a
// 14/121 phase accumulator fires, pixel x of line y (< 240) two dots after
// it's drawn. It stops at line 240 dot 0 and waits for s_req; on odd frames
// the pre-render line is a dot short, as with rendering on.
struct Source {
    unsigned acc = 0, line = 0, dot = 0, frame = 0;
    bool waiting = false;
    long stop_for = 0;   // a test can stop it for this many clocks, mid-frame
    long stop_at_frame = -1;
    unsigned started = 0;  // frames started on request

    struct Out {
        bool valid;
        unsigned x, y;
    };

    // One source clock; `req` is s_req from the clock before.
    Out step(bool req) {
        if (req && waiting) {
            waiting = false;
            frame++;
            started++;
        }
        if (waiting) return {false, 0, 0};
        if (stop_for > 0 && static_cast<long>(frame) == stop_at_frame && line == 100) {
            stop_for--;
            return {false, 0, 0};
        }
        acc += 14;
        if (acc < 121) return {false, 0, 0};
        acc -= 121;
        Out o{false, 0, 0};
        if (line < 240 && dot >= 2 && dot < 258) o = {true, dot - 2, line};
        unsigned len = line == 261 && frame % 2 == 1 ? 340 : 341;
        if (++dot == len) {
            dot = 0;
            line = line == 261 ? 0 : line + 1;
            if (line == 240) waiting = true;
        }
        return o;
    }
};

struct Stats {
    long late = 0, overrun = 0;
    std::vector<int> frame_ok;      // per display frame
    std::vector<long> shown;        // picture pixels drawn, per display frame
    std::vector<long> wrong;        // of those, ones with the wrong value
};

template <class V> Stats run(V& m, int disp_frames, Source& src, unsigned lines_log2 = 5) {
    m.s_rst = 1;
    m.d_rst = 1;
    m.s_clk = m.d_clk = 0;
    m.eval();
    m.s_clk = m.d_clk = 1;
    m.eval();
    m.s_rst = 0;
    m.d_rst = 0;
    Stats st;
    long t_s = 0, t_d = 0;
    unsigned dx = 0, dy = 0;  // display position
    int frames_done = 0;
    unsigned shown_frame = 0;  // the source frame the current display frame shows
    unsigned next_shown = 0;
    bool req = false;
    while (frames_done < disp_frames + 1) {
        bool do_s = t_s <= t_d, do_d = t_d <= t_s;
        if (do_s) {
            auto o = src.step(req);
            m.s_valid = o.valid;
            m.s_x = o.x;
            m.s_y = o.y & ((1u << lines_log2) - 1);
            m.s_pix = value(src.frame, o.x, o.y);
            m.s_waiting = src.waiting;
        }
        if (do_d) {
            m.d_x = dx;
            m.d_y = dy;
            if (dx == 0 && dy == 0) {
                frames_done++;
                st.frame_ok.push_back(0);
                st.shown.push_back(0);
                st.wrong.push_back(0);
            }
        }
        if (do_s) m.s_clk = 0;
        if (do_d) m.d_clk = 0;
        m.eval();
        if (do_s) m.s_clk = 1;
        if (do_d) m.d_clk = 1;
        m.eval();
        if (do_s) {
            req = m.s_req;
            if (req && src.waiting) next_shown = src.frame + 1;
            t_s += kSrcPeriod;
        }
        if (do_d) {
            st.late += m.d_late;
            st.overrun += m.d_overrun;
            if (dx == 0 && dy == 0) shown_frame = next_shown;
            // The registered outputs are now for the position just presented.
            if (!st.shown.empty()) {
                bool pic = dx >= kX0 && dx < kX0 + 256 * kScale && dy < 240 * kScale;
                if (m.d_on) {
                    INFO("at " << dx << "," << dy);
                    REQUIRE(pic);
                    st.shown.back()++;
                    if (m.d_pix != value(shown_frame, (dx - kX0) / kScale, dy / kScale)) st.wrong.back()++;
                }
                if (pic && dx == kX0 + 1) st.frame_ok.back() = m.d_frame_ok;
            }
            if (++dx == kHTotal) {
                dx = 0;
                if (++dy == kVTotal) dy = 0;
            }
            t_d += kDispPeriod;
        }
    }
    return st;
}

} // namespace

TEST_CASE("line_scaler shows each NES frame whole at 720p, three times its size") {
    Vls_nes m;
    Source src;
    auto st = run(m, 10, src);
    CHECK(st.late == 0);
    CHECK(st.overrun == 0);
    // From the third display frame the source is in step: every frame whole.
    for (size_t f = 2; f < st.shown.size() - 1; f++) {
        INFO("display frame " << f);
        CHECK(st.frame_ok[f] == 1);
        CHECK(st.shown[f] == 768L * 720);
        CHECK(st.wrong[f] == 0);
    }
    CHECK(src.started >= 9);
}

TEST_CASE("line_scaler blanks lines that don't arrive and gets back in step") {
    Vls_nes m;
    Source src;
    src.stop_at_frame = 4;
    src.stop_for = 400'000;  // over half a frame, from line 100
    auto st = run(m, 12, src);
    CHECK(st.overrun == 0);
    CHECK(st.late > 0);  // the stopped frame's later lines
    int bad = 0;
    for (size_t f = 2; f < st.shown.size() - 1; f++) {
        CHECK(st.wrong[f] == 0);  // never the wrong pixels: black instead
        if (st.shown[f] != 768L * 720) bad++;
    }
    CHECK(bad >= 1);
    CHECK(bad <= 3);
    // Whole again at the end.
    size_t last = st.shown.size() - 2;
    CHECK(st.shown[last] == 768L * 720);
    CHECK(st.shown[last - 1] == 768L * 720);
}

TEST_CASE("line_scaler flags a request sent too late for the first line") {
    Vls_late m;  // REQ_Y 700: the source's line 0 can't arrive in time
    Source src;
    auto st = run(m, 6, src);
    CHECK(st.late > 0);
}

TEST_CASE("line_scaler flags a ring too small for the source's lead") {
    Vls_small m;  // 8 lines: the NES gets 13 ahead by the frame's end
    Source src;
    auto st = run(m, 6, src, 3);
    CHECK(st.overrun > 0);
}
