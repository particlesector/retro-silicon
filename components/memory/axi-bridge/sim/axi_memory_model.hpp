// SPDX-License-Identifier: Apache-2.0
#pragma once
// An AXI slave with memory behind it, for sim tests of a design with
// memory/axi-bridge's master ports (m_ar*, m_r*, m_aw*, m_w*, m_b*): it
// withholds ready on every channel at random, answers after random delays,
// takes one transfer at a time, and checks AXI's rules as it goes: a payload
// holds while its valid is up, transfers are single 8-byte beats inside the
// window, a write's strobe is one byte. A broken rule throws.

#include <cstdint>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

namespace rs {

class AxiMemoryModel {
public:
    AxiMemoryModel(uint32_t base, uint32_t bytes, uint32_t seed) : base_(base), mem_(bytes, 0), rng_(seed) {}

    // Before the clock edge: drive the slave's outputs for this cycle.
    template <class M> void drive(M& m) {
        m.m_arready = coin();
        m.m_awready = coin();
        m.m_wready = coin();
        m.m_rvalid = r_pending_ && r_wait_ == 0;
        m.m_rdata = r_data_;
        m.m_rresp = 0;
        m.m_rlast = 1;
        m.m_bvalid = b_pending_ && b_wait_ == 0;
        m.m_bresp = 0;
    }

    // With the inputs settled, before the edge: this cycle's handshakes.
    template <class M> void sample(M& m) {
        if (ar_held_ && (!m.m_arvalid || m.m_araddr != ar_addr_)) fail("read address changed before it was taken");
        if (aw_held_ && (!m.m_awvalid || m.m_awaddr != aw_addr_)) fail("write address changed before it was taken");
        if (w_held_ && (!m.m_wvalid || m.m_wdata != w_data_ || m.m_wstrb != w_strb_))
            fail("write data changed before it was taken");
        bool ar = m.m_arvalid && m.m_arready, aw = m.m_awvalid && m.m_awready, w = m.m_wvalid && m.m_wready;
        ar_held_ = m.m_arvalid && !m.m_arready;
        ar_addr_ = m.m_araddr;
        aw_held_ = m.m_awvalid && !m.m_awready;
        aw_addr_ = m.m_awaddr;
        w_held_ = m.m_wvalid && !m.m_wready;
        w_data_ = m.m_wdata;
        w_strb_ = m.m_wstrb;
        if (ar) {
            uint32_t o = check(m.m_araddr, m.m_arsize, m.m_arlen, m.m_arburst);
            if (r_pending_) fail("a second read before the first's data");
            r_pending_ = true;
            r_wait_ = static_cast<int>(rng_() % 12);
            r_data_ = 0;
            for (int i = 7; i >= 0; i--) r_data_ = r_data_ << 8 | mem_[o + i];
            reads++;
        }
        if (aw) {
            if (have_aw_) fail("a second write address before the first's response");
            have_aw_ = true;
            waddr_ = check(m.m_awaddr, m.m_awsize, m.m_awlen, m.m_awburst);
        }
        if (w) {
            uint8_t s = m.m_wstrb;
            if (!m.m_wlast) fail("a write beat without WLAST");
            if (s == 0 || (s & (s - 1))) fail("a write strobe of more or less than one byte");
            if (have_w_) fail("a second write beat before the first's response");
            have_w_ = true;
            wdata_ = m.m_wdata;
            wstrb_ = s;
        }
        if (have_aw_ && have_w_) {
            for (int i = 0; i < 8; i++)
                if (wstrb_ >> i & 1) mem_[waddr_ + i] = static_cast<uint8_t>(wdata_ >> (8 * i));
            have_aw_ = have_w_ = false;
            if (b_pending_) fail("a write before the last one's response");
            b_pending_ = true;
            b_wait_ = static_cast<int>(rng_() % 12);
            writes++;
        }
        if (m.m_rvalid && m.m_rready) r_pending_ = false;
        if (m.m_bvalid && m.m_bready) b_pending_ = false;
    }

    // After the edge.
    void after_edge() {
        if (r_wait_ > 0) r_wait_--;
        if (b_wait_ > 0) b_wait_--;
    }

    std::vector<uint8_t>& memory() { return mem_; }
    int reads = 0, writes = 0;

private:
    bool coin() { return rng_() % 3 != 0; }
    [[noreturn]] static void fail(const std::string& what) { throw std::runtime_error("AXI memory model: " + what); }
    uint32_t check(uint32_t a, unsigned size, unsigned len, unsigned burst) {
        if (a < base_ || a - base_ >= mem_.size()) fail("an address outside the window");
        if (a % 8) fail("an address not 8-byte aligned");
        if (size != 3 || len != 0 || burst != 1) fail("not a single incrementing 8-byte beat");
        return a - base_;
    }

    uint32_t base_;
    std::vector<uint8_t> mem_;
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

} // namespace rs
