// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <array>
#include <cstdint>
#include <random>

#include "Vaxi_bridge.h"

namespace {

constexpr uint32_t kBase = 0x10000000;
constexpr int kBytes = 1 << 12;

// An AXI slave with a byte array behind it: ready withheld at random on every
// channel, read data and write responses after random delays, one transfer
// at a time, and the protocol's rules checked as it goes.
class Slave {
public:
    explicit Slave(uint32_t seed) : rng_(seed) { mem_.fill(0); }

    // Before the clock edge: drive the inputs from this cycle's state.
    void drive(Vaxi_bridge& m) {
        m.m_arready = coin();
        m.m_awready = coin();
        m.m_wready = coin();
        m.m_rvalid = r_wait_ == 0 && r_pending_;
        m.m_rdata = r_data_;
        m.m_rresp = 0;
        m.m_rlast = 1;
        m.m_bvalid = b_wait_ == 0 && b_pending_;
        m.m_bresp = 0;
    }

    // After driving, before the edge: what the handshakes do this cycle.
    void sample(Vaxi_bridge& m) {
        // A valid that was up stays up with the same payload until taken.
        if (ar_held_) {
            REQUIRE(m.m_arvalid);
            REQUIRE(m.m_araddr == ar_addr_);
        }
        if (aw_held_) {
            REQUIRE(m.m_awvalid);
            REQUIRE(m.m_awaddr == aw_addr_);
        }
        if (w_held_) {
            REQUIRE(m.m_wvalid);
            REQUIRE(m.m_wdata == w_data_);
            REQUIRE(m.m_wstrb == w_strb_);
        }
        bool ar = m.m_arvalid && m.m_arready, aw = m.m_awvalid && m.m_awready, w = m.m_wvalid && m.m_wready;
        ar_held_ = m.m_arvalid && !m.m_arready;
        ar_addr_ = m.m_araddr;
        aw_held_ = m.m_awvalid && !m.m_awready;
        aw_addr_ = m.m_awaddr;
        w_held_ = m.m_wvalid && !m.m_wready;
        w_data_ = m.m_wdata;
        w_strb_ = m.m_wstrb;
        if (ar) {
            check_addr(m.m_araddr, m.m_arsize, m.m_arlen, m.m_arburst);
            REQUIRE_FALSE(r_pending_);
            r_pending_ = true;
            r_wait_ = static_cast<int>(rng_() % 12);
            uint32_t o = m.m_araddr - kBase;
            r_data_ = 0;
            for (int i = 7; i >= 0; i--) r_data_ = r_data_ << 8 | mem_[o + i];
            reads++;
        }
        if (aw) {
            check_addr(m.m_awaddr, m.m_awsize, m.m_awlen, m.m_awburst);
            REQUIRE_FALSE(have_aw_);
            have_aw_ = true;
            waddr_ = m.m_awaddr - kBase;
        }
        if (w) {
            REQUIRE(m.m_wlast);
            REQUIRE_FALSE(have_w_);
            uint8_t s = m.m_wstrb;
            REQUIRE(s != 0);
            REQUIRE((s & (s - 1)) == 0);  // one byte
            have_w_ = true;
            wdata_ = m.m_wdata;
            wstrb_ = s;
        }
        if (have_aw_ && have_w_) {  // both halves in: write, then respond
            for (int i = 0; i < 8; i++)
                if (wstrb_ >> i & 1) mem_[waddr_ + i] = static_cast<uint8_t>(wdata_ >> (8 * i));
            have_aw_ = have_w_ = false;
            REQUIRE_FALSE(b_pending_);
            b_pending_ = true;
            b_wait_ = static_cast<int>(rng_() % 12);
            writes++;
        }
        if (m.m_rvalid && m.m_rready) r_pending_ = false;
        if (m.m_bvalid && m.m_bready) b_pending_ = false;
    }

    void after_edge() {
        if (r_wait_ > 0) r_wait_--;
        if (b_wait_ > 0) b_wait_--;
    }

    std::array<uint8_t, kBytes> mem_;
    int reads = 0, writes = 0;

private:
    bool coin() { return rng_() % 3 != 0; }
    static void check_addr(uint32_t a, uint8_t size, uint8_t len, uint8_t burst) {
        REQUIRE(a >= kBase);
        REQUIRE(a < kBase + kBytes);
        REQUIRE(a % 8 == 0);
        REQUIRE(size == 3);
        REQUIRE(len == 0);
        REQUIRE(burst == 1);
    }

    std::mt19937 rng_;
    bool ar_held_ = false, aw_held_ = false, w_held_ = false;
    uint32_t ar_addr_ = 0, aw_addr_ = 0;
    uint64_t w_data_ = 0;
    uint8_t w_strb_ = 0;
    bool r_pending_ = false, b_pending_ = false, have_aw_ = false, have_w_ = false;
    int r_wait_ = 0, b_wait_ = 0;
    uint64_t r_data_ = 0, wdata_ = 0;
    uint32_t waddr_ = 0;
    uint8_t wstrb_ = 0;
};

void tick(Vaxi_bridge& m, Slave& s) {
    s.drive(m);
    m.clk = 0;
    m.eval();
    s.sample(m);
    m.clk = 1;
    m.eval();
    s.after_edge();
}

} // namespace

TEST_CASE("axi_bridge: random byte reads and writes match a byte array through a slow, stalling AXI slave") {
    Vaxi_bridge m;
    Slave s(7);
    m.rst = 1;
    m.req = 0;
    m.axi_ready = 0;
    tick(m, s);
    m.rst = 0;
    tick(m, s);
    CHECK(m.ready == 0);  // not until the AXI side is
    m.axi_ready = 1;
    tick(m, s);
    CHECK(m.ready == 1);

    std::array<int, kBytes> ref;
    ref.fill(-1);
    std::mt19937 rng(11);
    int checked = 0;
    for (int i = 0; i < 20'000; i++) {
        bool we = rng() % 2 == 0;
        uint32_t addr = rng() % kBytes;
        uint8_t data = static_cast<uint8_t>(rng());
        m.req = 1;
        m.we = we;
        m.addr = addr;
        m.wdata = data;
        int waited = 0;
        do {
            tick(m, s);
            REQUIRE(++waited < 100);
        } while (!m.ack);
        if (we) ref[addr] = data;
        else {
            CHECK(static_cast<int>(m.rdata) == (ref[addr] >= 0 ? ref[addr] : 0));
            uint32_t w = 0;
            uint32_t base = addr & ~3u;
            for (int b = 3; b >= 0; b--) w = w << 8 | static_cast<uint32_t>(ref[base + b] >= 0 ? ref[base + b] : 0);
            CHECK(m.rdata_w == w);  // the 32-bit word the byte is in
            checked++;
        }
        // req stays high the clock after ack, as a registered requester's would: no second access.
        int r = s.reads, w = s.writes;
        tick(m, s);
        CHECK(m.ack == 0);
        m.req = 0;
        for (int g = static_cast<int>(rng() % 3); g > 0; g--) tick(m, s);
        CHECK(s.reads == r);
        CHECK(s.writes == w);
    }
    CHECK(checked > 8'000);
    CHECK(s.reads + s.writes == 20'000);
}
