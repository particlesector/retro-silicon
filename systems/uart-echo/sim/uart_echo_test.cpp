// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_template_test_macros.hpp>
#include <catch2/generators/catch_generators.hpp>
#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <cstdint>
#include <random>
#include <vector>

#include "Vuart_echo_115k.h"
#include "Vuart_echo_3m.h"
#include "rig/uart_model.hpp"

namespace {

template <class T> constexpr int clks_per_bit = 0;
template <> constexpr int clks_per_bit<Vuart_echo_3m> = 9;
template <> constexpr int clks_per_bit<Vuart_echo_115k> = 234;

// Line levels, one per clock, for a sender whose bit lasts `period` clocks
// (fractional, so a fast or slow sender can be modelled).
struct Line {
    std::vector<uint8_t> level;

    void idle(int clocks) { level.insert(level.end(), clocks, 1); }

    void byte(uint8_t b, double period, bool stop_bit = true) {
        uint16_t frame = (stop_bit ? 0x200 : 0) | (b << 1);  // start bit is 0
        double t0 = static_cast<double>(level.size());
        for (int i = 0; i < 10; i++) {
            auto end = static_cast<size_t>(std::llround(t0 + (i + 1) * period));
            level.resize(end, (frame >> i) & 1);
        }
    }
};

using Decoder = rig::UartDecoder;

template <class M> struct Echo {
    M m;
    Decoder dec{clks_per_bit<M>};

    Echo() {
        m.uart_rx = 1;
        for (int i = 0; i < 10; i++) tick();
    }

    void tick() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
        dec.sample(m.uart_tx);
    }

    // Plays the line, then idles long enough for the FIFO to drain.
    void play(const Line& line, size_t bytes) {
        for (uint8_t level : line.level) {
            m.uart_rx = level;
            tick();
        }
        m.uart_rx = 1;
        for (size_t i = 0; i < (bytes + 4) * 10 * clks_per_bit<M>; i++) tick();
    }

    bool overflow() const { return !(m.led & 1); }
    bool frame_err() const { return !(m.led & 2); }
};

std::vector<uint8_t> random_bytes(size_t n, unsigned seed) {
    std::mt19937 rng(seed);
    std::vector<uint8_t> v(n);
    for (auto& b : v) b = static_cast<uint8_t>(rng());
    return v;
}

} // namespace

TEMPLATE_TEST_CASE("echoes a back-to-back stream", "", Vuart_echo_3m, Vuart_echo_115k) {
    constexpr int clks = clks_per_bit<TestType>;
    // 0.98 and 1.02: the sender's bit is 2% short (fast) or 2% long (slow).
    double scale = GENERATE(1.0, 0.98, 1.02);
    size_t n = clks == 9 ? 3000 : 200;
    auto data = random_bytes(n, 7);

    Line line;
    line.idle(clks * 2);
    for (uint8_t b : data) line.byte(b, clks * scale);

    Echo<TestType> e;
    e.play(line, n);
    CAPTURE(scale);
    REQUIRE(e.dec.bytes == data);
    REQUIRE(e.dec.frame_errors == 0);
    REQUIRE_FALSE(e.overflow());
    REQUIRE_FALSE(e.frame_err());
}

TEMPLATE_TEST_CASE("drops a byte with a low stop bit and recovers", "", Vuart_echo_3m, Vuart_echo_115k) {
    constexpr int clks = clks_per_bit<TestType>;
    Line line;
    line.idle(clks * 2);
    line.byte(0x5A, clks, false);
    line.idle(clks * 3);  // back to idle so the receiver can resync
    line.byte(0xC3, clks);

    Echo<TestType> e;
    e.play(line, 2);
    REQUIRE(e.dec.bytes == std::vector<uint8_t>{0xC3});
    REQUIRE(e.frame_err());
}

TEMPLATE_TEST_CASE("ignores a glitch shorter than half a bit", "", Vuart_echo_3m, Vuart_echo_115k) {
    constexpr int clks = clks_per_bit<TestType>;
    Line line;
    line.idle(clks * 2);
    line.level.insert(line.level.end(), clks / 3, 0);
    line.idle(clks * 12);

    Echo<TestType> e;
    e.play(line, 1);
    REQUIRE(e.dec.bytes.empty());
    REQUIRE_FALSE(e.frame_err());
}

TEST_CASE("sets the overflow LED when the FIFO fills") {
    // A sender 2.5% fast gains a byte on the echo every 40 bytes: about 2,500 over
    // 100,000 bytes, past the 2,048-entry FIFO. (Much faster and the receiver loses
    // bit sync before the FIFO fills.)
    constexpr int clks = 9;
    auto data = random_bytes(100000, 3);
    Line line;
    line.idle(clks * 2);
    for (uint8_t b : data) line.byte(b, clks * 0.975);

    Echo<Vuart_echo_3m> e;
    e.play(line, data.size());
    REQUIRE(e.overflow());
}
