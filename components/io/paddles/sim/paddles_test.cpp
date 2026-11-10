// SPDX-License-Identifier: Apache-2.0
// paddles: each colour clock's `hi` against the paddle circuit's equations as Stella 7.0 has them,
// computed here in double precision, across positions, full and partial dumps, unplugged paddles,
// and the save-state port.
#include <catch2/catch_test_macros.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <random>

#include "Vpaddles.h"
#include "Vpaddles_nost.h"

namespace {

constexpr double kR0 = 1.8e3, kC = 68e-9, kRPot = 1e6, kRDump = 50;
constexpr double kF = 60.0 * 228 * 262;

// The fraction of the way to its target a capacitor goes in a colour clock through r ohm.
double step(double r) { return -std::expm1(-1 / (r * kC * kF)); }
const double kUth = -std::expm1(-379.0 * 228 / ((kRPot + kR0) * kC * kF));

struct Model {
    std::array<double, 4> u{};
    std::array<int, 4> pos{};
    std::array<bool, 4> on{};
    void cc(bool dump) {
        for (int i = 0; i < 4; i++) {
            if (dump)
                u[i] -= u[i] * step(kRDump);
            else if (on[i])
                u[i] += (1 - u[i]) * step(kRPot * pos[i] / 256 + kR0);
        }
    }
};

template <class V>
struct Bench {
    V m;
    Model model;
    // Colour clocks where `hi` differed from the model, and those where the model was within 1e-9
    // of the threshold (too close for either to be sure).
    long wrong = 0, close = 0, ccs = 0;
    Bench() {
        m.clk = 0;
        m.cc = 0;
        m.dump = 0;
        m.on = 0;
        m.pos = 0;
        m.st_addr = 0;
        m.st_we = 0;
        m.st_wdata = 0;
        m.rst = 1;
        clocks(2);
        m.rst = 0;
        clocks(8);  // the rates' lookups
    }
    void clock() {
        m.clk = 0;
        m.eval();
        m.clk = 1;
        m.eval();
    }
    void clocks(int n) {
        for (int i = 0; i < n; i++) clock();
    }
    void set(int i, bool on, int pos) {
        model.on[i] = on;
        model.pos[i] = pos;
        m.on = (m.on & ~(1u << i)) | (on ? 1u << i : 0u);
        m.pos = (m.pos & ~(0xFFu << 8 * i)) | uint32_t(pos) << 8 * i;
    }
    // n colour clocks, a colour clock every 6 clocks (the least it takes), checking `hi` after each:
    // `dump` changes with the colour clock edge, as the TIA's register does.
    void run(long n, bool dump) {
        for (long k = 0; k < n; k++) {
            m.cc = 1;
            clock();
            m.dump = dump;
            m.cc = 0;
            clocks(5);
            model.cc(dump);
            ccs++;
            for (int i = 0; i < 4; i++) {
                const bool want = model.u[i] > kUth;
                if (std::abs(model.u[i] - kUth) < 1e-9)
                    close++;
                else if (bool((m.hi >> i) & 1) != want)
                    wrong++;
            }
        }
    }
};

}  // namespace

TEST_CASE("paddles: a dump then a charge crosses the threshold when Stella's equations do") {
    Bench<Vpaddles> b;
    const std::array<int, 7> positions = {0, 1, 7, 64, 128, 200, 255};
    for (size_t k = 0; k < positions.size(); k += 4) {
        for (int i = 0; i < 4; i++) b.set(i, true, positions[(k + i) % positions.size()]);
        b.clocks(8);
        b.run(400, true);
        b.run(90000, false);
    }
    CHECK(b.wrong == 0);
    CHECK(b.close == 0);
    // The middle position, from empty: Stella's 43,283.6 colour clocks.
    Bench<Vpaddles> m;
    m.set(0, true, 128);
    m.clocks(8);
    m.run(400, true);
    m.run(43283, false);
    CHECK((m.m.hi & 1) == 0);
    m.run(1, false);
    CHECK((m.m.hi & 1) == 1);
}

TEST_CASE("paddles: partial dumps, position changes and unplugged paddles follow the equations") {
    Bench<Vpaddles> b;
    std::mt19937 rng(2600);
    for (int i = 0; i < 4; i++) b.set(i, true, 128);
    b.clocks(8);
    for (int round = 0; round < 300; round++) {
        // A new position (or none) for each, while dumped: the dump hides when the rate changes.
        b.run(1 + rng() % 3, true);
        for (int i = 0; i < 4; i++) b.set(i, rng() % 8 != 0, rng() % 256);
        b.run(4, true);
        b.run(rng() % 40, true);
        b.run(rng() % (round % 3 == 0 ? 60000 : 3000), false);
    }
    INFO("colour clocks " << b.ccs);
    CHECK(b.wrong == 0);
    CHECK(b.close == 0);
}

TEST_CASE("paddles: save state round trip") {
    Bench<Vpaddles> a;
    for (int i = 0; i < 4; i++) a.set(i, true, 40 * i + 10);
    a.clocks(8);
    a.run(400, true);
    a.run(12345, false);
    a.run(7, true);
    a.run(333, false);
    std::array<uint32_t, 5> words{};
    for (int w = 0; w < 5; w++) {
        a.m.st_addr = w;
        a.clock();
        words[w] = a.m.st_rdata;
    }
    Bench<Vpaddles> b;
    for (int i = 0; i < 4; i++) b.set(i, true, 40 * i + 10);
    b.clocks(8);
    for (int w = 0; w < 5; w++) {
        b.m.st_addr = w;
        b.m.st_wdata = words[w];
        b.m.st_we = 1;
        b.clock();
    }
    b.m.st_we = 0;
    b.model = a.model;
    a.run(40000, false);
    b.run(40000, false);
    CHECK(a.m.hi == b.m.hi);
    CHECK(b.wrong == 0);
}

TEST_CASE("paddles: SAVE_STATE=0 charges the same") {
    Bench<Vpaddles_nost> b;
    for (int i = 0; i < 4; i++) b.set(i, true, 64 * i + 3);
    b.clocks(8);
    b.run(400, true);
    b.run(90000, false);
    CHECK(b.wrong == 0);
    CHECK(b.m.st_rdata == 0);
}
