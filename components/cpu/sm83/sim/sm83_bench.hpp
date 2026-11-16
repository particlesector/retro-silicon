// SPDX-License-Identifier: Apache-2.0
#pragma once
// Drives the Verilated cpu_sm83 one M-cycle at a time against a flat 64 KB
// memory, recording each M-cycle's bus access. With `irqs`, IE ($FFFF) and IF
// ($FF0F) in that memory are the interrupt registers: int_req is IE & IF, and
// an acknowledged interrupt clears its IF bit.

#include <array>
#include <cstdint>

#include "Vcpu_sm83.h"

struct MCycle {
    uint16_t addr;
    char kind;     // 'r' read, 'w' write, '-' internal (no access)
    uint8_t data;  // read: what memory returned; write: what the CPU wrote
    bool operator==(const MCycle&) const = default;
};

struct Sm83Regs {
    uint16_t pc, sp, af, bc, de, hl;
    bool ime, ei;
};

class Sm83Bench {
public:
    std::array<uint8_t, 65536> ram{};
    bool irqs = false;
    bool stop_exit = false;
    uint64_t cycles = 0;
    uint8_t last_ack = 0;

    Sm83Bench() {
        m.ce = 0;
        m.rst = 1;
        clock();
        m.rst = 0;
        m.eval();
    }

    // Loads registers through the save-state port, between instructions.
    void set_regs(const Sm83Regs& r, uint8_t f) {
        auto a = static_cast<uint32_t>(r.af >> 8);
        put(0, a << 24 | static_cast<uint32_t>(r.bc) << 8 | (r.de >> 8));
        put(1, static_cast<uint32_t>(r.de & 0xFF) << 24 | static_cast<uint32_t>(r.hl) << 8 |
                   static_cast<uint32_t>(f >> 4) << 4);
        put(2, static_cast<uint32_t>(r.sp) << 16 | r.pc);
        put(3, static_cast<uint32_t>(r.ime) << 6);
    }

    uint32_t get(uint8_t word) {
        m.st_addr = word;
        clock();
        return m.st_rdata;
    }
    void put(uint8_t word, uint32_t v) {
        m.st_addr = word;
        m.st_wdata = v;
        m.st_we = 1;
        clock();
        m.st_we = 0;
    }

    // Runs one M-cycle and returns its access.
    MCycle cycle() {
        drive();
        MCycle c{m.addr, '-', 0};
        if (m.wr) {
            c.kind = 'w';
            c.data = m.dout;
        } else if (m.rd) {
            c.kind = 'r';
            c.data = ram[c.addr];
            m.din = c.data;
            m.eval();
        }
        last_ack = m.int_ack;
        m.ce = 1;
        clock();
        m.ce = 0;
        if (c.kind == 'w') ram[c.addr] = c.data;
        if (irqs && last_ack) ram[0xFF0F] &= static_cast<uint8_t>(~last_ack);
        cycles++;
        return c;
    }

    Sm83Regs regs() {
        drive();
        return {m.dbg_pc, m.dbg_sp, m.dbg_af, m.dbg_bc, m.dbg_de, m.dbg_hl, m.dbg_ime != 0, m.dbg_ei != 0};
    }
    bool boundary() { drive(); return m.dbg_boundary; }
    bool fetching() { drive(); return m.sync; }
    bool halted() { drive(); return m.halted; }
    bool stopped() { drive(); return m.stopped; }
    bool locked() { drive(); return m.locked; }

    // Runs to the next opcode fetch (at most `limit` M-cycles); false if none.
    bool to_fetch(int limit = 100) {
        for (int i = 0; i < limit; i++) {
            if (fetching()) return true;
            cycle();
        }
        return fetching();
    }

    Vcpu_sm83 m;

private:
    void drive() {
        m.int_req = irqs ? (ram[0xFFFF] & ram[0xFF0F] & 0x1F) : 0;
        m.stop_exit = stop_exit;
        m.eval();
    }
    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }
};
