// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <map>
#include <random>
#include <vector>

#include "Vsave_state_ctrl.h"

namespace {

constexpr uint32_t kBase0 = 0x10, kLen0 = 300;
constexpr uint32_t kBase1 = 0x01000200, kLen1 = 5;

// The system's side: a byte bus with a random latency, the two regions
// behind it, and a stop that takes a few clocks to arrive.
struct System {
    Vsave_state_ctrl m;
    std::map<uint32_t, uint8_t> mem;
    std::mt19937 rng{5};
    int wait = -1;
    bool ack = false;
    uint8_t rdata = 0;
    int stop_in = -1;  // clocks until stopped, after hold rises
    bool stopped = false;
    long accesses = 0, outside = 0;
    bool req_seen_last = false;

    void tick() {
        m.b_ack = ack;
        m.b_rdata = rdata;
        m.ready = stopped;
        m.clk = 0;
        m.eval();
        // Before the edge: the bus takes a request unless it's acking.
        bool was_ack = ack;
        ack = false;
        if (m.b_req) {
            // The walk never presents a new request the clock after an ack.
            if (!was_ack && wait < 0) {
                REQUIRE(!req_seen_last);
                wait = static_cast<int>(rng() % 4);
                accesses++;
                uint32_t a = m.b_addr;
                bool in = (a >= kBase0 && a < kBase0 + kLen0) || (a >= kBase1 && a < kBase1 + kLen1);
                if (!in) outside++;
            }
        }
        if (wait == 0) {
            if (m.b_we) mem[m.b_addr] = static_cast<uint8_t>(m.b_wdata);
            else rdata = mem[m.b_addr];
            ack = true;
        }
        if (wait >= 0) wait--;
        req_seen_last = m.b_req && was_ack;
        // The stop.
        if (m.hold) {
            if (stop_in < 0 && !stopped) stop_in = static_cast<int>(rng() % 20);
            if (stop_in == 0) stopped = true;
            if (stop_in >= 0) stop_in--;
        } else {
            stopped = false;
            stop_in = -1;
        }
        m.clk = 1;
        m.eval();
    }

    void run_cmd(uint8_t cmd) {
        m.cmd = cmd;
        for (int n = 0; n < 100'000 && m.done != cmd; n++) tick();
        REQUIRE(m.done == cmd);
        tick();
        CHECK(m.busy == 0);
        CHECK(m.hold == 0);
    }

    std::vector<uint8_t> regions() {
        std::vector<uint8_t> v;
        for (uint32_t a = 0; a < kLen0; a++) v.push_back(mem[kBase0 + a]);
        for (uint32_t a = 0; a < kLen1; a++) v.push_back(mem[kBase1 + a]);
        return v;
    }

    void fill(unsigned seed) {
        std::mt19937 r(seed);
        for (uint32_t a = 0; a < kLen0; a++) mem[kBase0 + a] = static_cast<uint8_t>(r());
        for (uint32_t a = 0; a < kLen1; a++) mem[kBase1 + a] = static_cast<uint8_t>(r());
    }

    uint8_t host_read(uint32_t a) {
        m.h_addr = a;
        m.h_we = 0;
        tick();
        m.eval();
        return static_cast<uint8_t>(m.h_rdata);
    }
};

} // namespace

TEST_CASE("save_state_ctrl saves the regions into its buffer and loads them back") {
    System s;
    s.m.rst = 1;
    s.m.cmd = 0;
    s.tick();
    s.m.rst = 0;
    s.tick();
    CHECK(s.m.done == 0);

    s.fill(1);
    auto saved = s.regions();
    s.run_cmd(0x40 | 1);  // save, sequence 1
    CHECK(s.m.hold_frame == 1);
    CHECK(s.accesses == kLen0 + kLen1);
    CHECK(s.outside == 0);

    // The buffer holds the regions in order.
    for (uint32_t a = 0; a < kLen0 + kLen1; a++) REQUIRE(s.host_read(a) == saved[a]);

    // The same command again does nothing.
    long before = s.accesses;
    for (int n = 0; n < 200; n++) s.tick();
    CHECK(s.accesses == before);
    CHECK(s.m.hold == 0);

    // Scramble the system, then load: every byte comes back.
    s.fill(2);
    REQUIRE(s.regions() != saved);
    s.run_cmd(0x80 | 2);
    CHECK(s.regions() == saved);
    CHECK(s.accesses == before + kLen0 + kLen1);
}

TEST_CASE("save_state_ctrl waits for the system to stop before it touches the bus") {
    System s;
    s.m.rst = 1;
    s.tick();
    s.m.rst = 0;
    s.fill(3);
    s.m.cmd = 0x40 | 5;
    s.tick();
    for (int n = 0; n < 50 && !s.stopped; n++) {
        CHECK(s.m.hold == 1);
        CHECK(s.m.b_req == 0);
        s.tick();
    }
    s.run_cmd(0x40 | 5);
    CHECK(s.accesses == kLen0 + kLen1);
}

TEST_CASE("save_state_ctrl: a host-written buffer loads, so a state can come from elsewhere") {
    System s;
    s.m.rst = 1;
    s.tick();
    s.m.rst = 0;
    std::vector<uint8_t> want(kLen0 + kLen1);
    std::mt19937 r(9);
    for (uint32_t a = 0; a < want.size(); a++) {
        want[a] = static_cast<uint8_t>(r());
        s.m.h_addr = a;
        s.m.h_wdata = want[a];
        s.m.h_we = 1;
        s.tick();
    }
    s.m.h_we = 0;
    s.run_cmd(0x80 | 7);
    CHECK(s.regions() == want);
}
