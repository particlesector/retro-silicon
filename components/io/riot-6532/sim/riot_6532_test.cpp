// SPDX-License-Identifier: Apache-2.0
// riot_6532: RAM, ports, PA7's edge detect, the interval timer cycle by cycle (the values Stella gives
// the riot_timer test cartridge), interrupts and the save-state port.
#include <catch2/catch_test_macros.hpp>

#include <array>
#include <cstdint>
#include <random>
#include <vector>

#include "Vriot.h"
#include "Vriot_nost.h"

namespace {

// RIOT register addresses (A6-A0, rs_n = 1), as the Atari 2600 maps them.
constexpr int kOra = 0x00, kDdra = 0x01, kOrb = 0x02, kDdrb = 0x03;
constexpr int kIntim = 0x04, kTimint = 0x05;
constexpr int kTim1t = 0x14, kTim8t = 0x15, kTim64t = 0x16, kT1024t = 0x17;

template <class V>
struct Bench {
    V m;
    Bench() {
        m.clk = 0;
        m.ce = 0;
        m.cs = 0;
        m.rs_n = 1;
        m.addr = 0;
        m.we = 0;
        m.din = 0;
        m.pa_in = 0xFF;
        m.pb_in = 0xFF;
        m.st_we = 0;
        m.st_addr = 0;
        m.st_wdata = 0;
        m.rst = 1;
        clock();
        m.rst = 0;
    }
    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }
    // One CPU cycle: the access is set up for a clock (dout settles), then taken with ce.
    // Returns dout as the CPU would take it.
    uint8_t cycle(bool cs = false, bool rs_n = true, int addr = 0, bool we = false, uint8_t din = 0) {
        m.cs = cs;
        m.rs_n = rs_n;
        m.addr = addr;
        m.we = we;
        m.din = din;
        m.ce = 0;
        clock();
        const uint8_t d = m.dout;
        m.ce = 1;
        clock();
        m.ce = 0;
        m.cs = 0;
        return d;
    }
    uint8_t read(int addr, bool ram = false) { return cycle(true, !ram, addr); }
    void write(int addr, uint8_t v, bool ram = false) { cycle(true, !ram, addr, true, v); }
    void idle(int n) {
        for (int i = 0; i < n; i++) cycle();
    }
};

// Writes `value` to timer register `reg`, then reads `regs[i]` 4 + 7i cycles later (LDA abs, STA zp),
// as the riot_timer cartridge does.
template <class B>
std::vector<int> timer_run(B& b, int reg, uint8_t value, const std::vector<int>& regs) {
    b.write(reg, value);
    std::vector<int> got;
    for (size_t i = 0; i < regs.size(); i++) {
        b.idle(i == 0 ? 3 : 6);
        got.push_back(b.read(regs[i]));
    }
    return got;
}

} // namespace

TEST_CASE("riot_6532 RAM holds all 128 bytes") {
    Bench<Vriot> b;
    for (int a = 0; a < 128; a++) b.write(a, uint8_t(a * 37 + 11), true);
    for (int a = 0; a < 128; a++) REQUIRE(b.read(a, true) == uint8_t(a * 37 + 11));
    // A register write doesn't touch RAM.
    b.write(kOra, 0x5A);
    REQUIRE(b.read(0, true) == 11);
}

TEST_CASE("riot_6532 timer counts as Stella runs the riot_timer cartridge") {
    Bench<Vriot> b;
    const std::vector<int> intim8(8, kIntim), intim4(4, kIntim);
    CHECK(timer_run(b, kTim1t, 3, intim8) == std::vector<int>{0xff, 0xf8, 0xf1, 0xea, 0xe3, 0xdc, 0xd5, 0xce});
    CHECK(timer_run(b, kTim8t, 2, intim8) == std::vector<int>{0x01, 0x00, 0xfe, 0xfd, 0xfd, 0xfc, 0xfb, 0xfa});
    CHECK(timer_run(b, kTim64t, 0, intim4) == std::vector<int>{0xfc, 0xfc, 0xfc, 0xfc});
    CHECK(timer_run(b, kT1024t, 0, intim4) == std::vector<int>{0xfc, 0xfc, 0xfc, 0xfc});
    CHECK(timer_run(b, kTim1t, 1, {kTimint, kIntim, kTimint, kIntim, kTimint, kIntim, kTimint, kIntim}) ==
          std::vector<int>{0x80, 0xf6, 0x00, 0xe8, 0x00, 0xda, 0x00, 0xcc});
}

TEST_CASE("riot_6532 timer ticks every interval, then every cycle after it wraps") {
    for (int sel = 0; sel < 4; sel++) {
        Bench<Vriot> b;
        const int ival = std::array{1, 8, 64, 1024}[sel];
        b.write(kTim1t + sel, 3);
        // Cycle k after the write has had 1 + (k - 1) / ival ticks: the count drops on the next cycle.
        for (int k = 1; k <= 3 * ival; k++) REQUIRE(b.read(kIntim) == 3 - (1 + (k - 1) / ival));
        CHECK(b.read(kTimint) == 0x80);  // cycle 3 * ival + 1: wraps to $FF, the flag set
        b.idle(4);                        // then one a cycle
        CHECK(b.read(kIntim) == 0xFF - 5);
        CHECK((b.read(kTimint) & 0x80) == 0);  // that read cleared the flag
    }
}

TEST_CASE("riot_6532 reading the timer on the cycle it wraps keeps the flag") {
    Bench<Vriot> b;
    b.write(kTim8t, 1);
    b.idle(8);                        // ticks on cycles 1 (to 0) and 9 (wraps)
    CHECK(b.read(kIntim) == 0xFF);    // cycle 9: the wrap
    CHECK((b.read(kTimint) & 0x80) == 0x80);
    CHECK(b.read(kIntim) == 0xFD);    // cycle 11: ticks on cycles 10 and 11 at one a cycle
    CHECK((b.read(kTimint) & 0x80) == 0);
}

TEST_CASE("riot_6532 ports: direction registers, port B reads back its outputs") {
    Bench<Vriot> b;
    b.m.pa_in = 0xA5;
    b.m.pb_in = 0x3C;
    CHECK(b.read(kOra) == 0xA5);
    CHECK(b.read(kOrb) == 0x3C);
    b.write(kDdra, 0xF0);
    b.write(kOra, 0x12);
    CHECK(b.m.pa_out == 0x12);
    CHECK(b.m.pa_ddr == 0xF0);
    CHECK(b.read(kDdra) == 0xF0);
    CHECK(b.read(kOra) == 0xA5);  // port A reads the pins as the system gives them
    b.write(kDdrb, 0x0F);
    b.write(kOrb, 0x96);
    CHECK(b.m.pb_out == 0x96);
    CHECK(b.read(kDdrb) == 0x0F);
    CHECK(b.read(kOrb) == ((0x96 & 0x0F) | (0x3C & 0xF0)));
}

TEST_CASE("riot_6532 PA7 edge detect, its flag and interrupts") {
    Bench<Vriot> b;
    b.m.pa_in = 0x80;
    b.idle(2);
    CHECK(b.m.irq_n == 1);
    b.write(0x06, 0);   // A4 = 0, A2 = 1: falling edge (A0 = 0), interrupt enabled (A1 = 1)
    b.m.pa_in = 0x00;   // falling edge
    b.idle(1);
    CHECK(b.m.irq_n == 0);
    CHECK(b.read(kTimint) == 0x40);  // reading the flags clears PA7's
    CHECK(b.m.irq_n == 1);
    CHECK(b.read(kTimint) == 0x00);
    b.m.pa_in = 0x80;   // a rising edge doesn't count while falling edges are chosen
    b.idle(1);
    CHECK(b.read(kTimint) == 0x00);
    b.write(0x05, 0);   // rising edge, interrupt disabled
    b.m.pa_in = 0x00;
    b.idle(1);
    b.m.pa_in = 0x80;
    b.idle(1);
    CHECK(b.m.irq_n == 1);
    CHECK(b.read(kTimint) == 0x40);

    // The timer's interrupt: enabled by A3 on the write.
    b.write(kTim1t | 0x08, 2);
    b.idle(2);
    CHECK(b.m.irq_n == 1);
    b.idle(1);          // wraps
    CHECK(b.m.irq_n == 0);
    b.read(kIntim);     // clears the flag
    CHECK(b.m.irq_n == 1);
}

TEST_CASE("riot_6532 save state: a restored copy runs on the same") {
    std::mt19937 rng(6532);
    for (int round = 0; round < 40; round++) {
        Bench<Vriot> a, c;
        auto random_cycle = [&](Bench<Vriot>& x, uint32_t r, uint8_t pa) {
            x.m.pa_in = pa;
            x.m.pb_in = uint8_t(r >> 24);
            const bool cs = r & 1, rs_n = r & 2, we = r & 4;
            int addr = (r >> 3) & 0x7F;
            if (rs_n) addr &= 0x1F;
            return x.cycle(cs, rs_n, addr, we, uint8_t(r >> 16));
        };
        const int before = int(rng() % 3000);
        for (int i = 0; i < before; i++) random_cycle(a, rng(), uint8_t(rng()));
        // Save a, restore into c.
        std::array<uint32_t, 34> words{};
        for (int w = 0; w < 34; w++) {
            a.m.st_addr = w;
            a.clock();
            words[w] = a.m.st_rdata;
        }
        for (int w = 0; w < 34; w++) {
            c.m.st_addr = w;
            c.m.st_wdata = words[w];
            c.m.st_we = 1;
            c.clock();
        }
        c.m.st_we = 0;
        for (int i = 0; i < 400; i++) {
            const uint32_t r = rng();
            const uint8_t pa = uint8_t(rng());
            REQUIRE(random_cycle(a, r, pa) == random_cycle(c, r, pa));
            REQUIRE(a.m.irq_n == c.m.irq_n);
            REQUIRE(a.m.pa_out == c.m.pa_out);
            REQUIRE(a.m.pb_ddr == c.m.pb_ddr);
        }
    }
}

TEST_CASE("riot_6532 without save states runs the same and reads 0 from the port") {
    Bench<Vriot> a;
    Bench<Vriot_nost> n;
    std::mt19937 rng(7);
    for (int i = 0; i < 2000; i++) {
        const uint32_t r = rng();
        const bool cs = r & 1, rs_n = r & 2, we = r & 4;
        int addr = (r >> 3) & 0x7F;
        if (rs_n) addr &= 0x1F;
        REQUIRE(a.cycle(cs, rs_n, addr, we, uint8_t(r >> 16)) == n.cycle(cs, rs_n, addr, we, uint8_t(r >> 16)));
    }
    n.m.st_addr = 32;
    n.clock();
    CHECK(n.m.st_rdata == 0);
}
