// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <vector>

#include "Vtrace_buffer.h"

namespace {

constexpr unsigned kDepth = 16;  // AW = 4

void tick(Vtrace_buffer& m) {
    m.clk = 0;
    m.eval();
    m.clk = 1;
    m.eval();
}

// The software model: every entry since the last set, and the count it began at.
struct Model {
    uint32_t base = 0;
    std::vector<uint32_t> entries;
    uint32_t count() const { return base + static_cast<uint32_t>(entries.size()); }
    unsigned filled() const { return entries.size() < kDepth ? static_cast<unsigned>(entries.size()) : kDepth; }
};

// Every valid entry reads back at its ring index, and count and filled match.
void check(Vtrace_buffer& m, const Model& s) {
    REQUIRE(m.count == s.count());
    REQUIRE(m.filled == s.filled());
    for (unsigned k = 0; k < s.filled(); k++) {
        uint32_t i = s.count() - s.filled() + k;  // the run's entry number
        m.raddr = i % kDepth;
        tick(m);
        REQUIRE(m.rdata == s.entries[s.entries.size() - s.filled() + k]);
    }
}

} // namespace

TEST_CASE("trace_buffer: keeps the last 2^AW entries at their ring index, through wraps, sets and resets") {
    Vtrace_buffer m;
    std::mt19937 rng(9);
    m.en = 0;
    m.set = 0;
    m.rst = 1;
    tick(m);
    m.rst = 0;
    Model s;
    check(m, s);

    for (int round = 0; round < 40; round++) {
        // A burst of entries, with idle clocks between some: fewer than the
        // depth, or enough to wrap several times.
        int n = static_cast<int>(rng() % (round % 3 ? 12 : 70));
        for (int k = 0; k < n; k++) {
            m.en = 1;
            m.data = rng();
            s.entries.push_back(m.data);
            tick(m);
            m.en = 0;
            for (int g = static_cast<int>(rng() % 3); g > 0; g--) tick(m);
        }
        check(m, s);
        if (round % 7 == 3) {  // a state loaded: count from there, empty
            m.set = 1;
            m.set_count = rng();
            tick(m);
            m.set = 0;
            s = Model{m.set_count, {}};
            check(m, s);
        }
        if (round % 11 == 10) {
            m.rst = 1;
            tick(m);
            m.rst = 0;
            s = Model{};
            check(m, s);
        }
    }
}
