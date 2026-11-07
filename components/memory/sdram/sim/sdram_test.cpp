// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <cstdint>
#include <random>
#include <vector>

#include "Vsdram_ctrl.h"
#include "sdram_model.hpp"

namespace {

constexpr int kMhz = RS_SDRAM_MHZ;  // the FREQ_MHZ the controller was built with
// Its geometry: DQ_W, ROW_W and COL_W (the defaults are the Tang Nano 20K's chip).
#ifndef RS_SDRAM_DQ
#define RS_SDRAM_DQ 32
#define RS_SDRAM_ROW 11
#define RS_SDRAM_COL 8
#endif
// RANKS: 2 is two chips on the pins, the second on CS high, as on MiSTer's
// dual-chip boards.
#ifndef RS_SDRAM_RANKS
#define RS_SDRAM_RANKS 1
#endif
constexpr SdramModel::Geometry kGeometry{RS_SDRAM_DQ / 8, RS_SDRAM_ROW, RS_SDRAM_COL};
constexpr int kLaneBits = RS_SDRAM_DQ == 16 ? 1 : 2;
constexpr int kRanks = RS_SDRAM_RANKS;
constexpr int kChipBits = 2 + RS_SDRAM_ROW + RS_SDRAM_COL + kLaneBits;
constexpr int kAddrBits = kChipBits + (kRanks > 1 ? 1 : 0);
constexpr uint32_t kBytes = 1u << kAddrBits;

#define RS_STR2(x) #x
#define RS_STR(x) RS_STR2(x)
#define NAME(what) "sdram_ctrl x" RS_STR(RS_SDRAM_DQ) " (" RS_STR(RS_SDRAM_RANKS) " chip) at " RS_STR(RS_SDRAM_MHZ) " MHz " what

struct Dut {
    Vsdram_ctrl m;
    std::vector<SdramModel> chips;
    uint64_t clocks = 0, acks = 0;
    bool registered = false;  // drop req a clock after ack, as a registered requester does

    Dut() : chips(kRanks, SdramModel(kMhz, kGeometry)) {
        // The controller puts a 16-bit chip's byte mask on A11 and A12 too
        // (memory/sdram), so take it from there, as a MiSTer board's chip does.
        for (auto& c : chips) c.dqm_on_addr = RS_SDRAM_DQ == 16 && RS_SDRAM_ROW >= 13;
        m.rst = 1;
        m.req = 0;
        tick();
        m.rst = 0;
    }

    void tick() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
        // The second chip's CS is the first's inverted. Only a chip with read
        // data drives DQ; with none, the first's garbage stands for a floating bus.
        uint32_t dq = 0;
        int driving = 0;
        for (int r = 0; r < kRanks; r++) {
            uint32_t v = chips[r].step({(m.sd_cs_n != 0) != (r == 1), m.sd_ras_n != 0, m.sd_cas_n != 0,
                                        m.sd_we_n != 0, m.sd_ba, m.sd_addr, m.sd_dqm, m.sd_dq_o,
                                        m.sd_dq_oe != 0});
            if (r == 0 || chips[r].drove) dq = v;
            driving += chips[r].drove;
        }
        if (driving > 1) chips[0].errors.push_back("both chips drive DQ");
        m.sd_dq_i = dq;
        clocks++;
        acks += m.ack;
    }

    uint8_t byte(uint32_t a) const { return chips[a >> kChipBits].byte(a & ((1u << kChipBits) - 1)); }
    bool initialised() const {
        return std::all_of(chips.begin(), chips.end(), [](const SdramModel& c) { return c.initialised(); });
    }
    uint64_t refreshes() const {  // the fewest any chip had
        uint64_t n = UINT64_MAX;
        for (auto& c : chips) n = std::min(n, c.refreshes);
        return n;
    }

    void wait_ready() {
        while (!m.ready) {
            tick();
            REQUIRE(clocks < 300 * kMhz);
        }
    }

    // One access; returns the read data and the clocks from request to ack.
    std::pair<uint8_t, int> access(bool we, uint32_t addr, uint8_t wdata = 0) {
        m.req = 1;
        m.we = we;
        m.addr = addr;
        m.wdata = wdata;
        int n = 0;
        do {
            tick();
            n++;
            REQUIRE(n < 100);
        } while (!m.ack);
        uint8_t data = m.rdata;
        if (registered) tick();
        m.req = 0;
        return {data, n};
    }
};

void require_clean(const Dut& d) {
    for (auto& c : d.chips) {
        for (auto& e : c.errors) UNSCOPED_INFO(e);
        REQUIRE(c.errors.empty());
    }
}

} // namespace

TEST_CASE(NAME("runs the power-up sequence within the chip's limits")) {
    Dut d;
    d.wait_ready();
    CHECK(d.initialised());
    CHECK(d.clocks >= 200 * kMhz);
    require_clean(d);
}

TEST_CASE(NAME("writes and reads back single bytes in every lane and bank")) {
    Dut d;
    d.wait_ready();
    // Every lane, both sides of a row and of a bank, each bank, and the top.
    // With two chips, the second's first byte too.
    constexpr uint32_t row = 1u << (RS_SDRAM_COL + kLaneBits), bank = (1u << kChipBits) / 4;
    const uint32_t addrs[] = {0,        1,         2,          3,           row - 1,    row,
                              bank - 1, bank,      2 * bank,   3 * bank,    kBytes / 2, kBytes - 1};
    for (uint32_t a : addrs) d.access(true, a, static_cast<uint8_t>(a * 7 + 1));
    for (uint32_t a : addrs) {
        CAPTURE(a);
        CHECK(d.access(false, a).first == static_cast<uint8_t>(a * 7 + 1));
        CHECK(d.byte(a) == static_cast<uint8_t>(a * 7 + 1));
    }
    // A byte write leaves its word's other lanes alone.
    CHECK(d.byte(4) == 0);
    require_clean(d);
}

TEST_CASE(NAME("matches a byte array over random accesses, refreshes included")) {
    Dut d;
    d.wait_ready();
    std::mt19937 rng(7);
    std::vector<uint8_t> ref(kBytes, 0);
    int worst = 0;
    // Mostly a small window so reads hit written bytes, with some far accesses.
    for (int i = 0; i < 40'000; i++) {
        uint32_t a = (rng() % 4 == 0) ? rng() & (kBytes - 1) : rng() & 0x3FFF;
        if (rng() % 2) {
            uint8_t v = static_cast<uint8_t>(rng());
            ref[a] = v;
            worst = std::max(worst, d.access(true, a, v).second);
        } else {
            auto [v, n] = d.access(false, a);
            CAPTURE(i, a);
            REQUIRE(v == ref[a]);
            worst = std::max(worst, n);
        }
        // Idle gaps of varying length, so refreshes land at every point of an access.
        for (int g = rng() % 4; g > 0; g--) d.tick();
    }
    CHECK(d.refreshes() > 100);
    // At 27 MHz a read takes 5 clocks from idle; the tail of the access before
    // and a refresh can add 5 more. Systems budget this bound.
    if (kMhz == 27 && RS_SDRAM_DQ == 32) CHECK(worst <= 10);
    require_clean(d);
}

TEST_CASE(NAME("takes each request once when req drops a clock after ack")) {
    Dut d;
    d.wait_ready();
    d.registered = true;
    std::mt19937 rng(3);
    uint64_t accesses = 0;
    for (int i = 0; i < 2'000; i++, accesses++) {
        uint32_t a = rng() & 0xFFF;
        uint8_t v = static_cast<uint8_t>(rng());
        d.access(true, a, v);
        accesses++;
        CAPTURE(i);
        REQUIRE(d.access(false, a).first == v);
    }
    for (int i = 0; i < 20; i++) d.tick();
    CHECK(d.acks == accesses);
    require_clean(d);
}

TEST_CASE(NAME("refreshes on time with a request held the whole time")) {
    Dut d;
    d.wait_ready();
    for (int i = 0; i < 20'000; i++) d.access(false, static_cast<uint32_t>(i));
    CHECK(d.refreshes() > 60);
    require_clean(d);
}
