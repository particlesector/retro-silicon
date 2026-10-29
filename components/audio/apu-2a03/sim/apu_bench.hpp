// SPDX-License-Identifier: Apache-2.0
#pragma once
// Drives the Verilated apu_2a03 a CPU cycle at a time, and apu_model::Apu
// alongside it with the same inputs. The bench stands in for the system's
// DMA unit: a DMC request is answered from a 64 KB memory a few cycles
// later, unless it is cancelled first.

#include <array>
#include <cstdio>
#include <cstdint>
#include <random>
#include <string>

#include "Vapu_2a03.h"
#include "apu_model.hpp"

struct ApuOut {
    uint8_t status, pulse1, pulse2, triangle, noise, dmc;
    bool irq, dma_req, dma_cancel;
    uint16_t dma_addr;
    bool operator==(const ApuOut&) const = default;
};

inline std::string describe(const ApuOut& o) {
    char b[160];
    std::snprintf(b, sizeof b,
                  "status %02X p1 %u p2 %u tri %u noise %u dmc %u irq %d req %d cancel %d addr %04X",
                  o.status, o.pulse1, o.pulse2, o.triangle, o.noise, o.dmc, o.irq, o.dma_req,
                  o.dma_cancel, o.dma_addr);
    return b;
}

class ApuBench {
public:
    Vapu_2a03 m;
    apu_model::Apu model;
    std::array<uint8_t, 0x10000> mem{};
    uint64_t cycles = 0;
    int dma_wait = -1;        // cycles until the pending DMA's byte arrives
    int dma_latency_max = 4;  // the DMA's wait is 1 to this many cycles
    std::mt19937 rng{1};

    ApuBench() {
        m.rst = 1;
        clock();
        m.rst = 0;
        m.eval();
        for (size_t i = 0; i < mem.size(); i++) mem[i] = static_cast<uint8_t>(i * 7 + (i >> 8));
    }

    // One CPU cycle, with this cycle's access. Both sides see it; the DMA
    // byte arrives in the cycle its wait runs out.
    void cycle(bool wr = false, uint8_t addr = 0, uint8_t v = 0, bool rd_status = false) {
        apu_model::Inputs in;
        in.odd = cycles & 1;
        in.wr = wr;
        in.addr = addr;
        in.wdata = v;
        in.rd_status = rd_status;
        if (dma_wait == 0) {
            in.dma_done = true;
            in.dma_data = mem[m.dma_addr];
            dma_wait = -1;
        } else if (dma_wait > 0) {
            dma_wait--;
        }
        m.odd = in.odd;
        m.wr = in.wr;
        m.addr = in.addr;
        m.wdata = in.wdata;
        m.rd_status = in.rd_status;
        m.dma_done = in.dma_done;
        m.dma_data = in.dma_data;
        m.ce = 1;
        clock();
        m.ce = 0;
        m.wr = m.rd_status = m.dma_done = 0;
        model.cycle(in);
        cycles++;
        if (m.dma_cancel) dma_wait = -1;
        if (m.dma_req) dma_wait = std::uniform_int_distribution<int>(0, dma_latency_max - 1)(rng);
    }

    void write(uint16_t addr, uint8_t v) { cycle(true, static_cast<uint8_t>(addr & 0x1F), v); }
    uint8_t read_status() {
        uint8_t s = m.status;
        cycle(false, 0x15, 0, true);
        return s;
    }
    void run(uint64_t n) {
        for (uint64_t i = 0; i < n; i++) cycle();
    }

    // The RTL's outputs after the last cycle (the DMA pulses are registered
    // on its ce and last one clock).
    ApuOut rtl() const {
        return {m.status, m.pulse1, m.pulse2, m.triangle, m.noise, m.dmc,
                !m.irq_n, static_cast<bool>(m.dma_req), static_cast<bool>(m.dma_cancel),
                m.dma_addr};
    }
    ApuOut ref() const {
        return {model.status(), model.pulse1.out(), model.pulse2.out(), model.triangle.out(),
                model.noise.out(), model.dmc.level, model.irq(), model.dmc.request,
                model.dmc.cancel, model.dmc.address};
    }

    uint32_t st_read(int a) {
        m.st_addr = a;
        clock();
        return m.st_rdata;
    }
    void st_write(int a, uint32_t v) {
        m.st_addr = a;
        m.st_wdata = v;
        m.st_we = 1;
        clock();
        m.st_we = 0;
    }

private:
    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }
};
