// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_template_test_macros.hpp>
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <deque>
#include <random>

#include "Vfifo_16.h"
#include "Vfifo_2k.h"

namespace {

template <class T> constexpr int depth = 0;
template <> constexpr int depth<Vfifo_16> = 16;
template <> constexpr int depth<Vfifo_2k> = 2048;

template <class M> struct Dut {
    M m;

    Dut() {
        m.rst = 1;
        tick();
        m.rst = 0;
        m.eval();
    }

    void tick() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }

    void push(uint8_t b) {
        m.wdata = b;
        m.wen = 1;
        tick();
        m.wen = 0;
        m.eval();
    }

    // rdata is registered: it holds the byte the cycle after the read.
    uint8_t pop() {
        m.ren = 1;
        tick();
        m.ren = 0;
        m.eval();
        return m.rdata;
    }
};

} // namespace

TEMPLATE_TEST_CASE("fifo fills to its depth and reads back in order", "", Vfifo_16, Vfifo_2k) {
    Dut<TestType> d;
    REQUIRE(d.m.empty);
    for (int i = 0; i < depth<TestType>; i++) {
        REQUIRE_FALSE(d.m.full);
        d.push(static_cast<uint8_t>(i * 7));
    }
    REQUIRE(d.m.full);
    d.push(0xEE);  // ignored when full
    for (int i = 0; i < depth<TestType>; i++) {
        REQUIRE_FALSE(d.m.empty);
        REQUIRE(d.pop() == static_cast<uint8_t>(i * 7));
    }
    REQUIRE(d.m.empty);
}

TEST_CASE("fifo ignores a read when empty") {
    Dut<Vfifo_16> d;
    d.push(0x42);
    REQUIRE(d.pop() == 0x42);
    d.pop();
    REQUIRE(d.m.rdata == 0x42);  // unchanged
    REQUIRE(d.m.empty);
    d.push(0x43);
    REQUIRE(d.pop() == 0x43);
}

TEST_CASE("fifo matches a queue under random reads and writes") {
    Dut<Vfifo_16> d;
    std::deque<uint8_t> model;
    std::mt19937 rng(5);
    for (int cycle = 0; cycle < 100'000; cycle++) {
        // Bias towards writes for the first half and reads for the second, so
        // the FIFO spends time both full and empty.
        bool wen = rng() % 100 < (cycle < 50'000 ? 60u : 40u);
        bool ren = rng() % 100 < 50;
        auto wdata = static_cast<uint8_t>(rng());
        REQUIRE(bool(d.m.empty) == model.empty());
        REQUIRE(bool(d.m.full) == (model.size() == 16));
        // Both flags are decided by the state before the clock edge.
        bool did_read = ren && !model.empty();
        bool did_write = wen && model.size() < 16;
        uint8_t expected = did_read ? model.front() : 0;
        if (did_read) model.pop_front();
        if (did_write) model.push_back(wdata);

        d.m.wen = wen;
        d.m.ren = ren;
        d.m.wdata = wdata;
        d.tick();
        if (did_read) REQUIRE(d.m.rdata == expected);
    }
}

TEST_CASE("fifo empties on reset") {
    Dut<Vfifo_16> d;
    for (int i = 0; i < 5; i++) d.push(static_cast<uint8_t>(i));
    d.m.rst = 1;
    d.tick();
    d.m.rst = 0;
    d.m.eval();
    REQUIRE(d.m.empty);
    REQUIRE_FALSE(d.m.full);
}
