// SPDX-License-Identifier: Apache-2.0
// apu_gb on its own: the registers as the CPU reads them, power off and on,
// and each channel's timing, measured from its level output.
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <vector>

#include "Vapu_gb.h"

namespace {

// The bench: T-cycles 2 clocks apart, a 2 MHz tick on every other one, and
// the frame sequencer's clock every 8192 T-cycles (512 Hz) unless held off,
// with the counter's bit rising halfway between.
struct Bench {
    Vapu_gb m;
    long t = 0;          // T-cycles run
    bool fs_on = true;

    Bench() {
        m.rst = 1;
        clock();
        m.rst = 0;
        clock();
    }
    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
        m.t2 = 0;
        m.fs = 0;
        m.fs_rise = 0;
        m.wr = 0;
    }
    // One T-cycle: a tick on even ones, the frame sequencer every 8192.
    void tcycle() {
        m.t2 = (t & 1) == 0;
        m.fs = fs_on && t % 8192 == 8191;
        m.fs_rise = fs_on && t % 8192 == 4095;
        clock();
        clock();
        t++;
    }
    void run(long n) {
        for (long i = 0; i < n; i++) tcycle();
    }
    void write(uint8_t reg, uint8_t v) {
        m.wr = 1;
        m.sel = reg - 0x10;
        m.wdata = v;
        clock();
    }
    uint8_t read(uint8_t reg) {
        m.rsel = reg - 0x10;
        m.eval();
        return m.rdata;
    }
    unsigned level(int ch) const { return (m.levels >> (4 * ch)) & 0xF; }
};

}  // namespace

TEST_CASE("The registers read back with their unreadable bits as 1") {
    Bench b;
    b.write(0x26, 0x80);
    // Each written as 0, then as FF: what reads back (blargg's dmg_sound 01's masks).
    const uint8_t mask[0x17] = {0x80, 0x3F, 0x00, 0xFF, 0xBF, 0xFF, 0x3F, 0x00, 0xFF, 0xBF, 0x7F, 0xFF,
                                0x9F, 0xFF, 0xBF, 0xFF, 0xFF, 0x00, 0x00, 0xBF, 0x00, 0x00, 0x70};
    for (uint8_t r = 0x10; r < 0x26; r++) {
        if (r == 0x14 || r == 0x19 || r == 0x1E || r == 0x23) continue;  // a trigger would start the channel
        b.write(r, 0x00);
        CHECK(int(b.read(r)) == int(mask[r - 0x10]));
        b.write(r, 0xFF);
        CHECK(int(b.read(r)) == int(mask[r - 0x10] | 0xFF));
        b.write(r, 0x00);
    }
    CHECK(int(b.read(0x26)) == 0xF0);
    for (uint8_t r = 0x27; r < 0x30; r++) CHECK(int(b.read(r)) == 0xFF);
}

TEST_CASE("Power off clears the registers but wave RAM, and ignores writes while off") {
    Bench b;
    b.write(0x26, 0x80);
    b.write(0x30, 0x12);
    b.write(0x24, 0x77);
    b.write(0x12, 0xF0);
    b.write(0x26, 0x00);
    CHECK(int(b.read(0x24)) == 0x00);
    CHECK(int(b.read(0x12)) == 0x00);
    CHECK(int(b.read(0x26)) == 0x70);
    CHECK(int(b.read(0x30)) == 0x12);
    b.write(0x24, 0x55);
    CHECK(int(b.read(0x24)) == 0x00);
    b.write(0x30, 0x34);
    CHECK(int(b.read(0x30)) == 0x34);
}

TEST_CASE("A pulse channel steps every 4 x (2048 - frequency) T-cycles") {
    Bench b;
    b.write(0x26, 0x80);
    b.write(0x11, 0x80);  // 50% duty
    b.write(0x12, 0xF0);  // volume 15, DAC on
    b.write(0x13, 0x00);
    b.write(0x14, 0x87);  // frequency 0x700: a step every 1024 T-cycles, a period of 8192
    // Find the rising edges of the level and time them.
    std::vector<long> rises;
    unsigned last = b.level(0);
    while (rises.size() < 4 && b.t < 60000) {
        b.tcycle();
        unsigned now = b.level(0);
        if (now && !last) rises.push_back(b.t);
        last = now;
    }
    REQUIRE(rises.size() == 4);
    CHECK(rises[2] - rises[1] == 8192);
    CHECK(rises[3] - rises[2] == 8192);
    CHECK(int(b.read(0x26)) == 0xF1);
}

TEST_CASE("A length counter stops its channel after its count of 256 Hz clocks") {
    Bench b;
    b.write(0x26, 0x80);
    b.write(0x16, 0x3E);  // NR21: length 2
    b.write(0x17, 0xF0);
    b.write(0x19, 0xC0);  // trigger, length enabled
    CHECK((b.read(0x26) & 2) != 0);
    b.run(4 * 8192);  // four frame-sequencer steps: two length clocks
    CHECK((b.read(0x26) & 2) == 0);
}

TEST_CASE("The wave channel plays wave RAM's nibbles, and reads it only as it plays") {
    Bench b;
    b.write(0x26, 0x80);
    for (uint8_t i = 0; i < 16; i++) b.write(0x30 + i, static_cast<uint8_t>(i * 0x11));
    b.write(0x1A, 0x80);
    b.write(0x1C, 0x20);  // full volume
    b.write(0x1D, 0x00);
    b.write(0x1E, 0x87);  // frequency 0x700: a sample every 512 T-cycles
    CHECK(int(b.read(0x30)) == 0xFF);  // between its reads
    std::vector<unsigned> seen;
    unsigned last = 99;
    while (seen.size() < 6 && b.t < 20000) {
        b.tcycle();
        if (b.level(2) != last) seen.push_back(last = b.level(2));
    }
    // The first sample played is the first byte's low nibble (0); then 1, 1, 2, 2...: changes only.
    REQUIRE(seen.size() == 6);
    CHECK(seen[1] == 1);
    CHECK(seen[2] == 2);
    CHECK(seen[3] == 3);
}

TEST_CASE("The noise LFSR repeats every 32767 steps, or 127 narrow") {
    for (bool narrow : {false, true}) {
        Bench b;
        b.fs_on = false;
        b.write(0x26, 0x80);
        b.write(0x21, 0xF0);
        b.write(0x22, narrow ? 0x08 : 0x00);  // divisor 8 T-cycles: a step every 16
        b.write(0x23, 0x80);
        // Sample the level every 16 T-cycles from step 64 on, and find the period.
        b.run(16 * 64);
        std::vector<uint8_t> bits;
        const size_t n = narrow ? 600 : 70000;
        for (size_t i = 0; i < n; i++) {
            b.run(16);
            bits.push_back(b.level(3) ? 1 : 0);
        }
        const size_t p = narrow ? 127 : 32767;
        bool ok = true;
        for (size_t i = 0; i + p < bits.size(); i++) ok = ok && bits[i] == bits[i + p];
        CHECK(ok);
    }
}
