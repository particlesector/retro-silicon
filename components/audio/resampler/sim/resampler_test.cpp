// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <cstdint>
#include <random>
#include <vector>

#include "Vresampler.h"

namespace {

constexpr int kNum = 1600, kDen = 59561, kHpf = 9;

// The filters as the README states them, in plain integers.
struct Model {
    int64_t sum = 0, n = 0, y = 0;
    int64_t acc = 0, v_prev = 0;
    // One input; returns true and sets out when it makes a sample.
    bool step(uint16_t x, int16_t& out) {
        sum += x;
        n++;
        acc += kNum;
        if (acc < kDen) return false;
        acc -= kDen;
        int64_t recip = 65536 / n;            // 2^16 / n, rounded down
        int64_t v = (sum * recip) >> 17;      // the average, halved
        sum = 0;
        n = 0;
        y = (v - v_prev) * 32768 + y - (y >> kHpf);
        v_prev = v;
        int64_t whole = y >> 15;
        out = static_cast<int16_t>(whole > 32767 ? 32767 : whole < -32768 ? -32768 : whole);
        return true;
    }
};

struct Bench {
    Vresampler m;
    Bench() {
        m.rst = 1;
        clock();
        m.rst = 0;
    }
    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }
    // One input and three idle clocks; returns whether it made a sample
    // (valid pulses three clocks after the ce).
    bool step(uint16_t x) {
        m.in = x;
        m.ce = 1;
        clock();
        m.ce = 0;
        bool v = false;
        for (int i = 0; i < 3; i++) {
            clock();
            v = v || m.valid;
        }
        return v;
    }
};

} // namespace

TEST_CASE("resampler gives NUM samples per DEN inputs, evenly") {
    Bench b;
    int n = 0, gap = 0, min_gap = 1 << 30, max_gap = 0;
    for (int i = 0; i < 2 * kDen; i++) {
        gap++;
        if (b.step(0)) {
            n++;
            if (n > 1) {
                min_gap = std::min(min_gap, gap);
                max_gap = std::max(max_gap, gap);
            }
            gap = 0;
        }
    }
    CHECK(n == 2 * kNum);
    CHECK(min_gap == kDen / kNum);
    CHECK(max_gap == kDen / kNum + 1);
}

TEST_CASE("resampler matches its model sample for sample") {
    Bench b;
    Model ref;
    std::mt19937 r(1);
    int samples = 0;
    uint16_t x = 0;
    for (int i = 0; i < 2'000'000; i++) {
        if (r() % 50 == 0) x = static_cast<uint16_t>(r());  // a held level, as the APU's
        int16_t want = 0;
        bool got = b.step(x);
        bool exp = ref.step(x, want);
        REQUIRE(got == exp);
        if (got) {
            REQUIRE(static_cast<int16_t>(b.m.out) == want);
            samples++;
        }
    }
    CHECK(samples > 50'000);
}

TEST_CASE("resampler blocks DC and passes a 1 kHz square wave") {
    Bench b;
    // A constant level settles to 0.
    for (int i = 0; i < 1'000'000; i++) b.step(40000);
    CHECK(std::abs(static_cast<int16_t>(b.m.out)) < 64);
    // A 1 kHz square between 0 and 32768 swings about +-8192 at the output.
    int16_t lo = 0, hi = 0;
    const double cycles_per_half = 1789772.7 / 2000;
    for (int i = 0; i < 1'789'773; i++) {
        bool high = std::fmod(i, 2 * cycles_per_half) < cycles_per_half;
        if (b.step(high ? 32768 : 0) && i > 900'000) {
            lo = std::min(lo, static_cast<int16_t>(b.m.out));
            hi = std::max(hi, static_cast<int16_t>(b.m.out));
        }
    }
    CHECK(hi > 7000);
    CHECK(hi < 9500);
    CHECK(lo < -7000);
    CHECK(lo > -9500);
}

TEST_CASE("resampler save state: a restored one runs on as the original") {
    Bench a, b;
    std::mt19937 r(7);
    for (int i = 0; i < 100'000; i++) a.step(static_cast<uint16_t>(r()));
    for (int i = 0; i < 4; i++) {
        a.m.st_addr = i;
        a.m.eval();
        b.m.st_addr = i;
        b.m.st_wdata = a.m.st_rdata;
        b.m.st_we = 1;
        b.clock();
        b.m.st_we = 0;
    }
    for (int i = 0; i < 200'000; i++) {
        uint16_t x = static_cast<uint16_t>(r());
        REQUIRE(a.step(x) == b.step(x));
        REQUIRE(a.m.out == b.m.out);
    }
}
