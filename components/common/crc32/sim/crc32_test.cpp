// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <span>
#include <string_view>
#include <vector>

#include "Vcrc32.h"
#include "Vcrc32_w30.h"

namespace {

// Bitwise software model of the same CRC, the reference the RTL must match.
uint32_t crc32_ref(std::span<const uint8_t> bytes) {
    uint32_t c = 0xFFFFFFFFu;
    for (uint8_t b : bytes) {
        c ^= b;
        for (int i = 0; i < 8; i++)
            c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : c >> 1;
    }
    return ~c;
}

struct Dut {
    Vcrc32 m;

    void tick() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }

    void reset() {
        m.rst = 1;
        m.en = 0;
        tick();
        m.rst = 0;
    }

    uint32_t run(std::span<const uint8_t> bytes) {
        reset();
        m.en = 1;
        for (uint8_t b : bytes) {
            m.data = b;
            tick();
        }
        m.en = 0;
        m.eval();
        return m.crc;
    }
};

std::vector<uint8_t> as_bytes(std::string_view s) { return {s.begin(), s.end()}; }

} // namespace

TEST_CASE("crc32 matches the standard check value") {
    Dut dut;
    REQUIRE(dut.run(as_bytes("123456789")) == 0xCBF43926u);
}

TEST_CASE("crc32 of no bytes is zero") {
    Dut dut;
    REQUIRE(dut.run({}) == 0u);
}

TEST_CASE("crc32 matches the software model on random data") {
    Dut dut;
    std::mt19937 rng(1);
    for (int len : {1, 2, 61440, 4097}) {
        std::vector<uint8_t> data(len);
        for (auto& b : data) b = static_cast<uint8_t>(rng());
        CAPTURE(len);
        REQUIRE(dut.run(data) == crc32_ref(data));
    }
}

TEST_CASE("crc32 holds its value while en is low") {
    Dut dut;
    auto data = as_bytes("123456789");
    dut.run(data);
    dut.m.data = 0xA5;
    for (int i = 0; i < 4; i++) dut.tick();
    REQUIRE(dut.m.crc == 0xCBF43926u);
}

TEST_CASE("crc32 restored from its save state carries on as if the earlier bytes had gone in") {
    std::mt19937 rng(2);
    std::vector<uint8_t> data(1000);
    for (auto& b : data) b = static_cast<uint8_t>(rng());
    auto first = std::span<const uint8_t>(data).first(400);
    auto rest = std::span<const uint8_t>(data).subspan(400);

    Dut a;
    uint32_t saved = a.run(first);

    Dut b;
    b.run(as_bytes("something else"));
    b.m.st_wdata = saved;
    b.m.st_we = 1;
    b.m.en = 1;  // a write wins over a byte in the same clock
    b.tick();
    b.m.st_we = 0;
    REQUIRE(b.m.crc == saved);
    for (uint8_t x : rest) {
        b.m.data = x;
        b.tick();
    }
    b.m.en = 0;
    b.m.eval();
    REQUIRE(b.m.crc == crc32_ref(data));
}

TEST_CASE("crc32 with W = 30 takes 30 bits a clock, bit 0 first") {
    Vcrc32_w30 m;
    m.rst = 1;
    m.en = 0;
    m.clk = 0;
    m.eval();
    m.clk = 1;
    m.eval();
    m.rst = 0;
    std::mt19937 rng(30);
    uint32_t c = 0xFFFFFFFFu;
    for (int i = 0; i < 5000; i++) {
        uint32_t d = rng() & 0x3fffffffu;
        m.en = rng() % 4 != 0;
        m.data = d;
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
        if (m.en)
            for (int b = 0; b < 30; b++) {
                bool fb = (c ^ (d >> b)) & 1;
                c = (c >> 1) ^ (fb ? 0xEDB88320u : 0);
            }
        REQUIRE(m.crc == ~c);
    }
}
