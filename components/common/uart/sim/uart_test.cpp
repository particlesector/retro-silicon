// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_template_test_macros.hpp>
#include <catch2/catch_test_macros.hpp>
#include <catch2/generators/catch_generators.hpp>

#include <cmath>
#include <cstdint>
#include <random>
#include <vector>

#include "Vuart_rx_234.h"
#include "Vuart_rx_9.h"
#include "Vuart_tx_234.h"
#include "Vuart_tx_9.h"
#include "rig/uart_model.hpp"

namespace {

template <class T> constexpr int clks_per_bit = 0;
template <> constexpr int clks_per_bit<Vuart_rx_9> = 9;
template <> constexpr int clks_per_bit<Vuart_rx_234> = 234;
template <> constexpr int clks_per_bit<Vuart_tx_9> = 9;
template <> constexpr int clks_per_bit<Vuart_tx_234> = 234;

template <class M> void tick(M& m) {
    m.clk = 0;
    m.eval();
    m.clk = 1;
    m.eval();
}

template <class M> void reset(M& m) {
    m.rst = 1;
    tick(m);
    m.rst = 0;
    m.eval();
}

std::vector<uint8_t> random_bytes(size_t n, unsigned seed) {
    std::mt19937 rng(seed);
    std::vector<uint8_t> v(n);
    for (auto& b : v) b = static_cast<uint8_t>(rng());
    return v;
}

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

// Plays a line into a receiver and collects what it reports.
template <class M> struct Received {
    std::vector<uint8_t> bytes;
    int frame_errors = 0;

    Received(const Line& line) {
        M m;
        m.rx = 1;
        reset(m);
        auto sample = [&] {
            // valid and frame_err are one-cycle pulses.
            if (m.valid) bytes.push_back(m.data);
            if (m.frame_err) frame_errors++;
        };
        for (uint8_t level : line.level) {
            m.rx = level;
            tick(m);
            sample();
        }
        m.rx = 1;
        for (int i = 0; i < 12 * clks_per_bit<M>; i++) {
            tick(m);
            sample();
        }
    }
};

} // namespace

TEMPLATE_TEST_CASE("uart_rx receives a back-to-back stream from a fast or slow sender", "", Vuart_rx_9,
                   Vuart_rx_234) {
    constexpr int clks = clks_per_bit<TestType>;
    double scale = GENERATE(1.0, 0.98, 1.02);
    auto data = random_bytes(clks == 9 ? 2000 : 100, 11);
    Line line;
    line.idle(clks * 2);
    for (uint8_t b : data) line.byte(b, clks * scale);

    Received<TestType> r(line);
    CAPTURE(scale);
    REQUIRE(r.bytes == data);
    REQUIRE(r.frame_errors == 0);
}

TEMPLATE_TEST_CASE("uart_rx drops a byte with a low stop bit and recovers", "", Vuart_rx_9, Vuart_rx_234) {
    constexpr int clks = clks_per_bit<TestType>;
    Line line;
    line.idle(clks * 2);
    line.byte(0x5A, clks, false);
    line.idle(clks * 3);  // back to idle so the receiver can resync
    line.byte(0xC3, clks);

    Received<TestType> r(line);
    REQUIRE(r.bytes == std::vector<uint8_t>{0xC3});
    REQUIRE(r.frame_errors == 1);
}

TEMPLATE_TEST_CASE("uart_rx ignores a glitch shorter than half a bit", "", Vuart_rx_9, Vuart_rx_234) {
    constexpr int clks = clks_per_bit<TestType>;
    Line line;
    line.idle(clks * 2);
    line.level.insert(line.level.end(), clks / 3, 0);
    line.idle(clks * 12);

    Received<TestType> r(line);
    REQUIRE(r.bytes.empty());
    REQUIRE(r.frame_errors == 0);
}

TEMPLATE_TEST_CASE("uart_tx sends 8N1 frames back to back, exactly 10 bits each", "", Vuart_tx_9, Vuart_tx_234) {
    constexpr int clks = clks_per_bit<TestType>;
    auto data = random_bytes(clks == 9 ? 2000 : 100, 13);
    TestType m;
    reset(m);
    REQUIRE(m.tx);
    REQUIRE(m.ready);

    rig::UartDecoder dec(clks);
    size_t next = 0;
    uint64_t first_start = 0, cycle = 0;
    // The sender keeps valid high, so every byte goes the moment ready allows.
    while (dec.bytes.size() < data.size()) {
        m.valid = next < data.size();
        if (m.valid) m.data = data[next];
        bool taken = m.valid && m.ready;
        tick(m);
        cycle++;
        if (taken && next++ == 0) first_start = cycle;
        dec.sample(m.tx);
        REQUIRE(cycle < first_start + (data.size() + 2) * 10 * clks);
    }
    REQUIRE(dec.bytes == data);
    REQUIRE(dec.frame_errors == 0);
    // The stop bit of the last byte started at first_start + (10n - 1) bits and
    // is sampled at its middle; anything later means a gap between frames.
    uint64_t last_stop_mid = first_start + (10 * data.size() - 1) * clks + clks / 2;
    REQUIRE(cycle <= last_stop_mid + 1);
}

TEMPLATE_TEST_CASE("uart_tx holds the line high and ready when idle", "", Vuart_tx_9, Vuart_tx_234) {
    TestType m;
    reset(m);
    m.valid = 0;
    for (int i = 0; i < 30 * clks_per_bit<TestType>; i++) {
        tick(m);
        REQUIRE(m.tx);
        REQUIRE(m.ready);
    }
}
