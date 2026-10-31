// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <vector>

#include "Vmem_cache.h"
#include "Vmem_cache_nopf.h"

namespace {

constexpr uint32_t kBytes = 1 << 16;  // AW = 16; IDX = 6: 64 lines, 512 bytes

// The memory behind the cache: answers after 2 to 15 clocks; a read gives the
// whole 8-byte line, a write sets one byte. The address, write enable and data
// must hold from the request to its ack, as memory/axi-bridge takes them at
// the request.
struct Memory {
    std::vector<uint8_t> bytes = std::vector<uint8_t>(kBytes);
    std::mt19937 rng{5};
    int wait = -1;
    uint32_t held_addr = 0;
    bool held_we = false;
    uint8_t held_wdata = 0;
    uint64_t reads = 0, writes = 0;

    template <class M> void drive(M& m) {
        m.d_ready = 1;
        m.d_ack = 0;
        if (!m.d_req) {
            wait = -1;
            return;
        }
        if (wait < 0) {
            wait = 2 + static_cast<int>(rng() % 14);
            held_addr = m.d_addr;
            held_we = m.d_we;
            held_wdata = m.d_wdata;
        }
        REQUIRE(m.d_addr == held_addr);
        REQUIRE(static_cast<bool>(m.d_we) == held_we);
        if (held_we) REQUIRE(m.d_wdata == held_wdata);
        if (wait-- > 0) return;
        uint32_t a = m.d_addr;
        if (m.d_we) {
            bytes[a] = m.d_wdata;
            writes++;
        } else {
            REQUIRE(a % 8 == 0);  // the line's first byte
            uint64_t line = 0;
            for (int i = 7; i >= 0; i--) line = line << 8 | bytes[a + i];
            m.d_rdata = line;
            reads++;
        }
        m.d_ack = 1;
        wait = -2;  // one access a request
    }
};

template <class M> void tick(M& m, Memory& mem) {
    mem.drive(m);
    m.clk = 0;
    m.eval();
    m.clk = 1;
    m.eval();
    if (mem.wait == -2 && m.d_req) mem.wait = -3;  // held until the cache drops it
}


template <class M> void start(M& m, Memory& mem) {
    m.rst = 1;
    m.req = 0;
    tick(m, mem);
    m.rst = 0;
    int n = 0;
    while (!m.ready) {
        tick(m, mem);
        REQUIRE(++n < 200);  // the valid bits: 64 clocks
    }
}

// One access, to its ack, then the clock after with req still high (a
// registered requester's): no second access may start.
template <class M> uint8_t access(M& m, Memory& mem, uint32_t addr, bool we, uint8_t data) {
    m.req = 1;
    m.we = we;
    m.addr = addr;
    m.wdata = data;
    int waited = 0;
    do {
        tick(m, mem);
        REQUIRE(++waited < 80);
    } while (!m.ack);
    uint8_t r = m.rdata;
    tick(m, mem);
    CHECK(m.ack == 0);
    m.req = 0;
    return r;
}

template <class M> void random_access() {
    M m;
    Memory mem;
    for (auto& b : mem.bytes) b = static_cast<uint8_t>(mem.rng());
    std::vector<uint8_t> ref = mem.bytes;
    start(m, mem);

    std::mt19937 rng(9);
    uint32_t loop = 0;
    for (int i = 0; i < 30'000; i++) {
        // As code runs: mostly a loop over 256 bytes (half the cache) that
        // moves now and then, and 1 in 20 accesses anywhere.
        if (i % 2000 == 0) loop = rng() % (kBytes - 256);
        uint32_t addr = rng() % 20 != 0 ? loop + rng() % 256 : rng() % kBytes;
        bool we = rng() % 10 == 0;
        uint8_t data = static_cast<uint8_t>(rng());
        m.req = 1;
        m.we = we;
        m.addr = addr;
        m.wdata = data;
        int waited = 0;
        do {
            tick(m, mem);
            REQUIRE(++waited < 60);
        } while (!m.ack);
        if (we) ref[addr] = data;
        else {
            REQUIRE(m.rdata == ref[addr]);
            uint32_t base = addr & ~3u, w = 0;
            for (int b = 3; b >= 0; b--) w = w << 8 | ref[base + b];
            REQUIRE(m.rdata_w == w);
        }
        tick(m, mem);  // req still high the clock after ack: no second access
        CHECK(m.ack == 0);
        m.req = 0;
        for (int g = static_cast<int>(rng() % 3); g > 0; g--) tick(m, mem);
    }
    CHECK(mem.bytes == ref);  // every write went through
    // A line read is a miss's or a prefetch's.
    CHECK(mem.reads <= m.misses + m.prefetches);
    CHECK(mem.reads >= m.prefetches);
    CHECK(m.hits + m.misses > 25'000);
    // Each scattered read misses and evicts a loop line half the time, about
    // 2,300 misses in all; the rest hit.
    CHECK(m.hits > 8 * m.misses);
}

} // namespace

TEST_CASE("mem_cache: random reads and writes, looping and scattered, match a byte array; hits answer from the cache") {
    random_access<Vmem_cache>();
}

TEST_CASE("mem_cache without prefetch: the same") {
    random_access<Vmem_cache_nopf>();
}

namespace {

// Straight-line code: every byte of 4 KB in order, a few clocks apart.
template <class M> uint32_t sequential_misses() {
    M m;
    Memory mem;
    for (auto& b : mem.bytes) b = static_cast<uint8_t>(mem.rng());
    start(m, mem);
    for (uint32_t a = 0x2000; a < 0x3000; a++) {
        REQUIRE(access(m, mem, a, false, 0) == mem.bytes[a]);
        for (int g = 0; g < 4; g++) tick(m, mem);
    }
    return m.misses;
}

} // namespace

TEST_CASE("mem_cache: prefetch streams straight-line code, where without it every line misses") {
    uint32_t without = sequential_misses<Vmem_cache_nopf>();
    uint32_t with = sequential_misses<Vmem_cache>();
    CHECK(without == 512);  // 4 KB in 8-byte lines
    CHECK(with < 16);       // the first line, and a prefetch that comes too late now and then
}

TEST_CASE("mem_cache: two straight-line runs far apart, taken in turns, read right") {
    // As a loop calling a distant subroutine: a few bytes of one run, then of
    // the other, so one run's next-line prefetch is often still out when the
    // other's first read of a prefetched line asks for the line after it.
    Vmem_cache m;
    Memory mem;
    for (auto& b : mem.bytes) b = static_cast<uint8_t>(mem.rng());
    start(m, mem);
    std::mt19937 rng(23);
    uint32_t a = 0x1000, b = 0x9000;
    for (int i = 0; i < 6000; i++) {
        uint32_t& p = (i / 3) % 2 ? b : a;
        REQUIRE(access(m, mem, p, false, 0) == mem.bytes[p]);
        p += 1 + rng() % 3;
        if (p >= kBytes) p -= kBytes - 0x100;
        for (int g = static_cast<int>(rng() % 6); g > 0; g--) tick(m, mem);
    }
}
