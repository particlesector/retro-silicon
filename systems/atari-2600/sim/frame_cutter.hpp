// SPDX-License-Identifier: Apache-2.0
#pragma once
// Stella 7.0's NTSC frame manager, as it decides which lines make a frame, for the sim tests: the
// model a2600_frame is checked against.

#include <algorithm>
#include <array>
#include <cstdint>
#include <vector>

namespace a2600_sim {

constexpr int kWidth = 160, kHeight = 228;

// Stella 7.0's NTSC frame manager, as it decides which lines make a frame: a frame ends when VSYNC
// goes off; the picture starts 23 line ends later and runs 228 lines; with no VSYNC for 50 lines it
// runs on regardless. A line's columns the TIA doesn't draw (after RSYNC cuts it short) are black, as
// Stella clears them.
class FrameCutter {
public:
    std::vector<uint8_t> buffer = std::vector<uint8_t>(kWidth * kHeight, 0);
    int frames = 0;  // frames completed

    // A pixel of the line being drawn.
    void pixel(int x, uint8_t colour) {
        if (state_ == State::frame && x < kWidth) {
            buffer[y_ * kWidth + x] = colour;
            drawn_[x] = true;
        }
    }

    void line_end() {
        if (state_ == State::frame)
            for (int x = 0; x < kWidth; ++x)
                if (!drawn_[x]) buffer[y_ * kWidth + x] = 0;
        drawn_.fill(false);
        ++total_lines_;
        const State before = state_;
        ++line_in_state_;
        switch (state_) {
        case State::wait_vsync_start:
            if (total_lines_ > kFrameLines - 3 || frames == 0) ++vsync_lines_;
            if (vsync_lines_ > kMaxVsyncLines) set(State::wait_frame_start);
            break;
        case State::wait_vsync_end:
            if (++vsync_lines_ > kMaxVsyncLines) set(State::wait_frame_start);
            break;
        case State::wait_frame_start:
            if (line_in_state_ >= kYStart) set(State::frame);
            break;
        case State::frame:
            if (line_in_state_ >= kHeight) {
                last_y_ = kYStart + y_;
                set(State::wait_vsync_start);
            }
            break;
        }
        if (state_ == State::frame && before == State::frame) ++y_;
    }

    void vsync(bool on) {
        if (on == vsync_) return;
        vsync_ = on;
        set(state_ == State::wait_vsync_end ? State::wait_frame_start : State::wait_vsync_end);
    }

private:
    enum class State { wait_vsync_start, wait_vsync_end, wait_frame_start, frame };
    static constexpr int kFrameLines = 262, kMaxVsyncLines = 50, kYStart = 23;
    State state_ = State::wait_vsync_start;
    int line_in_state_ = 0, vsync_lines_ = 0, y_ = 0, last_y_ = 0, total_lines_ = 0;
    bool vsync_ = false;
    std::array<bool, kWidth> drawn_{};

    void set(State s) {
        if (s == state_) return;
        state_ = s;
        line_in_state_ = 0;
        if (s == State::wait_frame_start) {
            // The frame is complete: lines it didn't draw are black.
            if (last_y_ != kYStart + y_)
                std::fill(buffer.begin() + y_ * kWidth, buffer.end(), 0);
            total_lines_ = 0;
            ++frames;
            vsync_lines_ = 0;
        } else if (s == State::frame) {
            vsync_lines_ = 0;
            y_ = 0;
        }
    }
};

}  // namespace a2600_sim
