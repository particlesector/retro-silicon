// SPDX-License-Identifier: Apache-2.0
#pragma once
// Cycle model of an SDR SDRAM with 4 banks (burst length 1) that checks the controller's command timing against the chip's
// limits. Its geometry defaults to the 2M x 32 chip in the Tang Nano 20K's
// GW2AR-18 (2048 rows, 256 columns); Geometry{2, 13, 9} is a 16M x 16 such as
// the W9825G6KH. The SDRAM's clock is the controller's inverted, so the chip samples
// each command half a cycle after the controller registers it.
//
// Call step() once per controller clock, after the rising edge has settled,
// with the pins that edge registered; it returns the data the controller will
// see on its DQ inputs at the next edge. Read data is valid only at the edge
// CAS latency + 1 cycles after the READ; at every other edge the bus carries
// a scrambled value, so an off-by-one capture reads garbage.
//
// With dqm_on_addr set, the chip is wired as on MiSTer's SDRAM boards: its
// DQML and DQMH are A11 and A12, so a WRITE takes its byte mask from them
// and the DQM pins aren't connected.

#include <array>
#include <cstdint>
#include <string>
#include <vector>

struct SdramPins {
    bool cs_n, ras_n, cas_n, we_n;
    uint8_t ba;
    uint16_t addr;
    uint8_t dqm;
    uint32_t dq;  // what the controller drives (the low 16 bits of a 16-bit chip)
    bool dq_oe;
};

// Bytes per word (2 or 4), and row and column address bits.
struct SdramGeometry {
    int bytes = 4, row_bits = 11, col_bits = 8;
};

class SdramModel {
public:
    // Chip limits, in ns.
    struct Timing {
        double rcd = 18, rp = 18, rc = 60, ras = 42, wr = 12, refi = 15625, init = 100000;
        int mrd = 2;  // clocks
    };

    using Geometry = SdramGeometry;

    SdramModel(double clk_mhz, Timing t, Geometry g = {})
        : ns_per_clk_(1000.0 / clk_mhz), t_(t), g_(g),
          lane_bits_(g.bytes == 2 ? 1 : 2),
          data_mask_(g.bytes == 2 ? 0xFFFFu : 0xFFFFFFFFu) {
        mem_.assign(size_t{4} << (g.row_bits + g.col_bits), 0);
    }
    explicit SdramModel(double clk_mhz, Geometry g = {}) : SdramModel(clk_mhz, timing_for(g), g) {}

    // The default timing, with tREFI for the chip: 4096 refreshes per 64 ms
    // up to 4096 rows (the 20K's 2048-row chip asks for 4096 too), else one
    // per row.
    static Timing timing_for(const Geometry& g) {
        Timing t;
        t.refi = 64e6 / (g.row_bits <= 12 ? 4096 : 1 << g.row_bits);
        return t;
    }

    // Bytes the chip holds.
    uint64_t size() const { return uint64_t{mem_.size()} * g_.bytes; }

    std::vector<std::string> errors;
    uint64_t refreshes = 0;
    bool dqm_on_addr = false;
    bool drove = false;  // the last step's value is read data, driven by the chip

    uint32_t step(const SdramPins& p) {
        const double now = static_cast<double>(clk_) * ns_per_clk_;
        update_precharges(now);
        drove = false;
        if (!p.cs_n) command(p, now);
        uint32_t out = scramble(clk_) & data_mask_;
        if (pending_valid_ && pending_at_ == clk_) {
            out = pending_data_;
            pending_valid_ = false;
            drove = true;
        }
        clk_++;
        return out;
    }

    // Direct access for test setup and checks: byte address as the controller sees it.
    uint8_t byte(uint32_t a) const {
        return static_cast<uint8_t>(mem_[a >> lane_bits_] >> ((a & (g_.bytes - 1)) * 8));
    }
    void set_byte(uint32_t a, uint8_t v) {
        uint32_t& w = mem_[a >> lane_bits_];
        const int sh = (a & (g_.bytes - 1)) * 8;
        w = (w & ~(0xFFu << sh)) | (uint32_t{v} << sh);
    }

    bool initialised() const { return mode_set_; }

private:
    struct Bank {
        bool open = false;
        int row = 0;
        double act_at = -1e18;     // last ACTIVE
        double idle_at = -1e18;    // precharge finished: ACTIVE allowed from here
        bool ap_pending = false;   // auto-precharge started by a column command
        double ap_at = 0;          // when that precharge begins
    };

    void error(const std::string& what) {
        if (errors.size() < 20) errors.push_back("clock " + std::to_string(clk_) + ": " + what);
    }

    void update_precharges(double now) {
        for (auto& b : banks_)
            if (b.ap_pending && now >= b.ap_at) {
                b.ap_pending = false;
                b.open = false;
                b.idle_at = b.ap_at + t_.rp;
            }
    }

    void precharge(Bank& b, double now) {
        if (b.open && now < b.act_at + t_.ras) error("PRECHARGE before tRAS");
        b.open = false;
        b.ap_pending = false;
        b.idle_at = now + t_.rp;
    }

    void command(const SdramPins& p, double now) {
        const int c = (p.ras_n << 2) | (p.cas_n << 1) | p.we_n;
        if (c == 7) return;  // NOP
        if (now < busy_until_) error("command during tRC after REFRESH, or tMRD after MODE");
        if (now < t_.init) error("command before the power-up wait");
        Bank& b = banks_[p.ba & 3];
        switch (c) {
        case 2:  // PRECHARGE
            if (p.addr & 0x400) {
                for (auto& x : banks_) precharge(x, now);
                precharged_all_ = true;
            } else
                precharge(b, now);
            break;
        case 1:  // REFRESH
            for (auto& x : banks_)
                if (x.open || x.ap_pending || now < x.idle_at) error("REFRESH with a bank not idle");
            if (!precharged_all_) error("REFRESH before the first PRECHARGE ALL");
            if (mode_set_ && last_refresh_ >= 0 && now - last_refresh_ > t_.refi)
                error("refresh interval " + std::to_string(now - last_refresh_) + " ns over tREFI");
            if (mode_set_) refreshes++;
            last_refresh_ = now;
            init_refreshes_ += !mode_set_;
            busy_until_ = now + t_.rc;
            break;
        case 0:  // MODE
            for (auto& x : banks_)
                if (x.open || now < x.idle_at) error("MODE with a bank not idle");
            if (init_refreshes_ < 2) error("MODE before two refreshes");
            if ((p.addr & 7) != 0) error("burst length isn't 1");
            cas_latency_ = (p.addr >> 4) & 7;
            if (cas_latency_ != 2 && cas_latency_ != 3) error("unsupported CAS latency");
            mode_set_ = true;
            busy_until_ = now + t_.mrd * ns_per_clk_ - 0.001;
            break;
        case 3:  // ACTIVE
            if (!mode_set_) error("ACTIVE before MODE");
            if (b.open || b.ap_pending) error("ACTIVE to an open bank");
            if (now < b.idle_at) error("ACTIVE before tRP");
            if (now < b.act_at + t_.rc) error("ACTIVE before tRC");
            b.open = true;
            b.row = p.addr & ((1 << g_.row_bits) - 1);
            b.act_at = now;
            break;
        case 5:  // READ
        case 4: {  // WRITE
            if (!b.open || b.ap_pending) {
                error("column command to a closed bank");
                break;
            }
            if (now < b.act_at + t_.rcd) error("column command before tRCD");
            const uint32_t word = (uint32_t{p.ba & 3u} << (g_.row_bits + g_.col_bits)) |
                                  (uint32_t(b.row) << g_.col_bits) | (p.addr & ((1u << g_.col_bits) - 1));
            const uint32_t dqm_bits = dqm_on_addr ? 0x1800u : 0u;
            if (p.addr & ~((1u << g_.col_bits) - 1) & ~0x400u & ~dqm_bits) error("column address bits above the chip's");
            const uint8_t dqm = dqm_on_addr ? static_cast<uint8_t>(p.addr >> 11 & 3) : p.dqm;
            if (c == 5) {
                pending_valid_ = true;
                pending_at_ = clk_ + cas_latency_;
                pending_data_ = mem_[word];
            } else {
                if (!p.dq_oe) error("WRITE without driving DQ");
                uint32_t mask = 0;
                for (int i = 0; i < g_.bytes; i++)
                    if (!(dqm >> i & 1)) mask |= 0xFFu << (8 * i);
                mem_[word] = (mem_[word] & ~mask) | (p.dq & mask & data_mask_);
            }
            if (p.addr & 0x400) {
                // Auto-precharge: after the data for a read, after tWR for a write.
                b.ap_pending = true;
                b.ap_at = c == 5 ? now + ns_per_clk_ : now + t_.wr;
                if (b.ap_at < b.act_at + t_.ras) error("auto-precharge before tRAS");
            }
            break;
        }
        default:
            error("unsupported command " + std::to_string(c));
        }
    }

    static uint32_t scramble(uint64_t x) {
        x = (x ^ (x >> 31)) * 0x7FB5D329728EA185ull;
        return static_cast<uint32_t>(x >> 27);
    }

    double ns_per_clk_;
    Timing t_;
    Geometry g_;
    int lane_bits_;
    uint32_t data_mask_;
    std::vector<uint32_t> mem_;
    std::array<Bank, 4> banks_{};
    uint64_t clk_ = 0;
    double busy_until_ = 0;
    double last_refresh_ = -1;
    bool precharged_all_ = false, mode_set_ = false;
    int init_refreshes_ = 0, cas_latency_ = 2;
    bool pending_valid_ = false;
    uint64_t pending_at_ = 0;
    uint32_t pending_data_ = 0;
};
