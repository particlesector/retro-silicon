// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <array>
#include <cstdint>
#include <random>
#include <vector>

#include "Vmem_arbiter.h"

namespace {

constexpr int kClients = 3;
constexpr int kAw = 10;

// A memory with a random latency per access, on the byte port: it takes a
// request when req is high and it isn't acking, and acks 0-6 clocks later.
// Every access it takes is counted, so a request taken twice shows.
struct Memory {
    std::array<uint8_t, 1 << kAw> bytes{};
    std::mt19937 rng{7};
    int wait = -1;  // clocks until the ack, -1 idle
    bool ack = false;
    uint8_t rdata = 0;
    long taken = 0;

    // Called each clock with the arbiter's outputs as they are before the edge;
    // returns what the memory drives after it.
    void step(const Vmem_arbiter& m) {
        bool was_ack = ack;
        ack = false;
        if (wait < 0 && m.m_req && !was_ack) {
            wait = static_cast<int>(rng() % 7);
            taken++;
        }
        if (wait == 0) {
            if (m.m_we) bytes[m.m_addr] = static_cast<uint8_t>(m.m_wdata);
            else rdata = bytes[m.m_addr];
            ack = true;
        }
        if (wait >= 0) wait--;
    }
};

// A client that holds each request until its ack, in its own quarter of the
// address space, and checks each read against what it wrote.
struct Client {
    int id;
    std::mt19937 rng;
    std::array<int, 256> mine{};  // -1 unwritten
    bool req = false, we = false;
    uint32_t addr = 0;
    uint8_t wdata = 0;
    long done = 0, issued = 0;
    int waited = 0, worst_wait = 0;
    int gap = 0;

    explicit Client(int i) : id(i), rng(100 + i) { mine.fill(-1); }

    void step(bool ack, uint8_t rdata, bool keep_going) {
        if (req && ack) {
            if (!we && mine[addr & 0xFF] >= 0) CHECK(rdata == mine[addr & 0xFF]);
            if (we) mine[addr & 0xFF] = wdata;
            done++;
            worst_wait = std::max(worst_wait, waited);
            req = false;
            gap = static_cast<int>(rng() % 4);
            return;
        }
        if (req) {
            waited++;
            return;
        }
        if (gap > 0) {
            gap--;
            return;
        }
        if (!keep_going) return;
        req = true;
        we = rng() % 2 == 0;
        addr = static_cast<uint32_t>(id << 8 | (rng() & 0xFF));
        wdata = static_cast<uint8_t>(rng());
        waited = 0;
        issued++;
    }
};

void drive(Vmem_arbiter& m, const std::vector<Client>& cs, const Memory& mem) {
    m.c_req = 0;
    m.c_we = 0;
    m.c_addr = 0;
    m.c_wdata = 0;
    for (const auto& c : cs) {
        m.c_req |= c.req << c.id;
        m.c_we |= c.we << c.id;
        m.c_addr |= c.addr << (c.id * kAw);
        m.c_wdata |= static_cast<uint32_t>(c.wdata) << (c.id * 8);
    }
    m.m_ack = mem.ack;
    m.m_rdata = mem.rdata;
    m.eval();
}

} // namespace

TEST_CASE("mem_arbiter serves every request once, with the right data, client 0 first") {
    Vmem_arbiter m;
    Memory mem;
    std::vector<Client> cs;
    for (int i = 0; i < kClients; i++) cs.emplace_back(i);

    m.rst = 1;
    m.clk = 0;
    drive(m, cs, mem);
    m.clk = 1;
    m.eval();
    m.rst = 0;

    long cycles = 0;
    auto busy = [&] {
        for (const auto& c : cs)
            if (c.req) return true;
        return false;
    };
    while (cycles < 200'000 || busy()) {
        m.clk = 0;
        drive(m, cs, mem);
        // Sample before the edge: acks are combinational from the memory's.
        uint32_t ack = m.c_ack;
        uint8_t rdata = static_cast<uint8_t>(m.c_rdata);
        for (int i = 0; i < kClients; i++)
            if (ack >> i & 1) REQUIRE(cs[i].req);
        mem.step(m);
        m.clk = 1;
        m.eval();
        for (auto& c : cs) c.step(ack >> c.id & 1, rdata, cycles < 200'000);
        cycles++;
        REQUIRE(cycles < 400'000);
    }

    long total = 0;
    for (const auto& c : cs) {
        CHECK(c.done == c.issued);
        CHECK(c.done > 500);  // fixed priority: the last client gets what's left
        total += c.done;
    }
    CHECK(mem.taken == total);
    // Client 0 waits for at most the rest of an access already running, then
    // its grant and its own access: each access is 8 clocks at most here.
    CHECK(cs[0].worst_wait <= 8 + 8);
    CHECK(cs[2].worst_wait > cs[0].worst_wait);
}
