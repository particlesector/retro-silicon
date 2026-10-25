// SPDX-License-Identifier: Apache-2.0
#pragma once
// Drives the Verilated cpu_6502 one CPU cycle at a time against a memory
// model, recording each cycle's bus access.

#include <array>
#include <cstdint>
#include <functional>
#include <vector>

#include "Vcpu_6502.h"

struct BusCycle {
    uint16_t addr;
    bool write;
    uint8_t data;  // read: what memory returned; write: what the CPU wrote
    bool sync;
    bool operator==(const BusCycle&) const = default;
};

struct Regs {
    uint16_t pc;
    uint8_t a, x, y, s, p;
};

class CpuBench {
public:
    // Reads go through `read`, writes through `write`; both default to a flat 64 KB.
    std::function<uint8_t(uint16_t)> read = [this](uint16_t a) { return ram[a]; };
    std::function<void(uint16_t, uint8_t)> write = [this](uint16_t a, uint8_t d) { ram[a] = d; };
    std::array<uint8_t, 65536> ram{};

    bool irq_n = true, nmi_n = true, rdy = true;
    uint64_t cycles = 0;

    CpuBench() {
        m.ce = 1;
        m.rdy = 1;
        m.irq_n = 1;
        m.nmi_n = 1;
        m.rst = 1;
        clock();
        m.rst = 0;
        m.eval();
    }

    // Runs one CPU cycle and returns its bus access.
    BusCycle cycle() {
        m.irq_n = irq_n;
        m.nmi_n = nmi_n;
        m.rdy = rdy;
        m.eval();
        BusCycle c{m.addr, m.we != 0, 0, m.sync != 0};
        if (c.write)
            c.data = m.dout;
        else {
            c.data = read(c.addr);
            m.din = c.data;
        }
        m.eval();
        clock();
        if (c.write) write(c.addr, c.data);
        cycles++;
        return c;
    }

    // Runs to the start of the next instruction: the next opcode fetch.
    std::vector<BusCycle> instruction() {
        std::vector<BusCycle> out{cycle()};
        while (!at_fetch() && !halted()) out.push_back(cycle());
        return out;
    }

    bool at_fetch() {
        m.eval();
        return m.sync;
    }

    bool halted() const { return m.halted; }
    Regs regs() const { return {m.dbg_pc, m.dbg_a, m.dbg_x, m.dbg_y, m.dbg_s, m.dbg_p}; }

    // Runs cycles until the CPU is about to fetch from `pc`, or `limit` cycles pass.
    bool run_to(uint16_t pc, uint64_t limit) {
        for (uint64_t i = 0; i < limit; i++) {
            m.eval();
            if (m.sync && m.addr == pc) return true;
            cycle();
        }
        return false;
    }

private:
    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }

    Vcpu_6502 m;
};
