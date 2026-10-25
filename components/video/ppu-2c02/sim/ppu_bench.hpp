// SPDX-License-Identifier: Apache-2.0
#pragma once
// Drives the Verilated ppu_2c02 a dot at a time, with video memory as a flat
// 16 KB array (pattern tables, then 2 KB of nametables mirrored as NROM's
// vertical mirroring). Register accesses go between dots.

#include <array>
#include <cstdint>
#include <vector>

#include "Vppu_2c02.h"

struct Pixel {
    uint8_t x, y;
    uint16_t value;
    bool operator==(const Pixel&) const = default;
};

class PpuBench {
public:
    std::array<uint8_t, 0x2000> chr{};
    std::array<uint8_t, 0x800> nt{};
    std::vector<Pixel> pixels;  // everything output since the last clear
    uint64_t dots = 0, frames = 0;
    bool record = false;

    PpuBench() {
        m.rst = 1;
        clock();
        m.rst = 0;
        m.eval();
    }

    // One dot: the memory answers the address the PPU presented, then ce.
    void dot() {
        mem_slot();
        m.ce = 1;
        clock();
        m.ce = 0;
        dots++;
        // The outputs registered on the ce edge.
        if (m.frame_end) frames++;
        if (record && m.pix_valid) pixels.push_back({m.pix_x, m.pix_y, static_cast<uint16_t>(m.pix)});
    }

    void dots_n(uint64_t n) {
        for (uint64_t i = 0; i < n; i++) dot();
    }

    uint8_t read(int reg) {
        m.reg_addr = reg;
        m.reg_we = 0;
        m.reg_ce = 1;
        clock();
        m.reg_ce = 0;
        m.eval();
        return m.reg_rdata;
    }

    void write(int reg, uint8_t v) {
        m.reg_addr = reg;
        m.reg_we = 1;
        m.reg_wdata = v;
        m.reg_ce = 1;
        clock();
        m.reg_ce = 0;
        m.reg_we = 0;
    }

    // Runs to the given position (the dot just executed).
    void run_to(int line, int dot_) {
        for (int i = 0; i < 400'000; i++) {
            if (m.dbg_line == line && m.dbg_dot == dot_) return;
            dot();
        }
    }

    int line() const { return m.dbg_line; }
    int dot_pos() const { return m.dbg_dot; }
    bool nmi() const { return !m.nmi_n; }

    uint32_t state_read(int i) {
        m.st_addr = i;
        clock();
        return m.st_rdata;
    }
    void state_write(int i, uint32_t v) {
        m.st_addr = i;
        m.st_wdata = v;
        m.st_we = 1;
        clock();
        m.st_we = 0;
    }
    static constexpr int kStateWords = 101;

    uint8_t& vram(uint16_t a) {
        a &= 0x3FFF;
        if (a < 0x2000) return chr[a];
        return nt[(a & 0x3FF) | ((a & 0x400) ? 0x400 : 0)];  // vertical mirroring
    }

private:
    void mem_slot() {
        m.eval();
        if (m.vwe) vram(m.vaddr) = m.vwdata;
        m.vrdata = vram(m.vaddr);
    }
    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }

    Vppu_2c02 m;
};
