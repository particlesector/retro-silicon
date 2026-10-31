// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <vector>

#include "Vmem_port_cdc.h"

namespace {

constexpr uint32_t kBytes = 1 << 12;

// Two free-running clocks, in picoseconds, and a memory on the m side that
// answers after 1 to 10 of its clocks: a read gives the 8-byte line.
struct Bench {
    Vmem_port_cdc m;
    uint64_t t = 0, next_u = 0, next_m = 0, up, mp;
    std::vector<uint8_t> mem = std::vector<uint8_t>(kBytes);
    std::mt19937 rng{3};
    int wait = -1;
    uint64_t user_clocks = 0;

    Bench(uint64_t user_ps, uint64_t mem_ps) : up(user_ps), mp(mem_ps) {
        for (auto& b : mem) b = static_cast<uint8_t>(rng());
        m.clk = m.mclk = 0;
        m.rst = m.mrst = 1;
        m.req = 0;
        m.m_ready = 1;
        m.m_ack = 0;
        for (int i = 0; i < 20; i++) user_edge();
        m.rst = m.mrst = 0;
    }

    void mem_edge() {
        // The memory's outputs for this clock, from what it saw.
        m.m_ack = 0;
        if (m.m_req) {
            if (wait < 0) wait = 1 + static_cast<int>(rng() % 10);
            if (wait-- == 0) {
                uint32_t a = m.m_addr;
                if (m.m_we) mem[a] = m.m_wdata;
                else {
                    uint64_t line = 0;
                    for (int i = 7; i >= 0; i--) line = line << 8 | mem[(a & ~7u) + i];
                    m.m_rdata = line;
                }
                m.m_ack = 1;
                wait = -1;
            }
        }
        m.mclk = 1;
        m.eval();
        m.mclk = 0;
        m.eval();
    }

    // Runs both clocks until the user's next rising edge.
    void user_edge() {
        for (;;) {
            if (next_m <= next_u) {
                t = next_m;
                next_m += mp;
                mem_edge();
            } else {
                t = next_u;
                next_u += up;
                m.clk = 1;
                m.eval();
                m.clk = 0;
                m.eval();
                user_clocks++;
                return;
            }
        }
    }
};

void run(uint64_t user_ps, uint64_t mem_ps) {
    Bench b(user_ps, mem_ps);
    int n = 0;
    while (!b.m.ready) {
        b.user_edge();
        REQUIRE(++n < 20);
    }
    std::vector<uint8_t> ref = b.mem;
    std::mt19937 rng(17);
    for (int i = 0; i < 5000; i++) {
        uint32_t addr = rng() % kBytes;
        bool we = rng() % 3 == 0;
        uint8_t data = static_cast<uint8_t>(rng());
        b.m.req = 1;
        b.m.we = we;
        b.m.addr = addr;
        b.m.wdata = data;
        int waited = 0;
        do {
            b.user_edge();
            REQUIRE(++waited < 200);
        } while (!b.m.ack);
        if (we) ref[addr] = data;
        else {
            uint64_t line = 0;
            for (int j = 7; j >= 0; j--) line = line << 8 | ref[(addr & ~7u) + j];
            REQUIRE(b.m.rdata == line);
        }
        b.user_edge();  // req still high the clock after ack: no second access
        CHECK(b.m.ack == 0);
        b.m.req = 0;
        for (int g = static_cast<int>(rng() % 3); g > 0; g--) b.user_edge();
    }
    CHECK(b.mem == ref);
}

} // namespace

TEST_CASE("mem_port_cdc: reads and writes cross to a memory on a clock four times as fast, unrelated") {
    run(26'936, 6'734 - 1);  // about 37.125 and 148.5 MHz, drifting
}

TEST_CASE("mem_port_cdc: and to a memory on a slower clock") {
    run(10'000, 23'456);
}
