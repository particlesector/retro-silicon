// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <vector>

#include "apu_bench.hpp"

namespace {

// Runs until the output's level changes, at most `limit` cycles; returns
// the cycles that took, or 0.
uint64_t cycles_to_change(ApuBench& b, uint8_t (*level)(const ApuOut&), uint64_t limit) {
    uint8_t start = level(b.rtl());
    for (uint64_t i = 1; i <= limit; i++) {
        b.cycle();
        if (level(b.rtl()) != start) return i;
    }
    return 0;
}

uint8_t pulse1_of(const ApuOut& o) { return o.pulse1; }
uint8_t triangle_of(const ApuOut& o) { return o.triangle; }

// Random register traffic: what the lockstep tests drive both sides with.
void random_traffic(ApuBench& b, uint32_t seed, uint64_t n) {
    std::mt19937 r(seed);
    b.rng.seed(seed);
    static const uint8_t regs[] = {0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0A,
                                   0x0B, 0x0C, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x15, 0x17};
    for (uint64_t i = 0; i < n; i++) {
        uint32_t x = r();
        if (x % 64 == 0) {
            uint8_t reg = regs[(x >> 8) % std::size(regs)];
            uint8_t v = static_cast<uint8_t>(x >> 16);
            if (reg == 0x13) v &= 0x03;                 // short samples, so they end
            if (reg == 0x15 && (x >> 24) % 4) v |= 0x0F; // mostly keep the channels on
            if (reg == 0x17 && (x >> 24) % 8) continue;  // and the frame counter running
            b.write(reg, v);
        } else if (x % 64 == 1) {
            b.read_status();
        } else {
            b.cycle();
        }
        auto rtl = b.rtl(), ref = b.ref();
        if (!b.irq_at_end_ok) {
            INFO("cycle " << b.cycles << ": irq_n at the cycle's end");
            REQUIRE(b.irq_at_end_ok);
        }
        if (!(rtl == ref)) {
            INFO("cycle " << b.cycles);
            INFO("rtl   " << describe(rtl));
            INFO("model " << describe(ref));
            REQUIRE(rtl == ref);
        }
    }
}

} // namespace

TEST_CASE("apu_2a03 starts silent with no IRQ and nothing to play") {
    ApuBench b;
    b.run(10);
    auto o = b.rtl();
    CHECK(o.status == 0);
    CHECK_FALSE(o.irq);
    CHECK(o.pulse1 + o.pulse2 + o.noise + o.dmc == 0);
    CHECK(o == b.ref());
}

TEST_CASE("apu_2a03 pulse 1 steps its duty every 2(t + 1) cycles") {
    ApuBench b;
    b.write(0x4015, 0x01);
    b.write(0x4000, 0xBF);  // 50% duty, halt, constant volume 15
    b.write(0x4002, 0xFD);  // t = 0x0FD
    b.write(0x4003, 0x00);
    // 50% duty: 4 steps high, 4 low; each 2 * 0xFE cycles.
    cycles_to_change(b, pulse1_of, 10'000);
    for (int i = 0; i < 4; i++)
        CHECK(cycles_to_change(b, pulse1_of, 10'000) == 4 * 2 * 0xFE);
}

TEST_CASE("apu_2a03 pulse mutes below period 8 and on a sweep target over $7FF") {
    ApuBench b;
    b.write(0x4015, 0x01);
    b.write(0x4000, 0xBF);
    b.write(0x4002, 0x07);
    b.write(0x4003, 0x00);
    b.run(200);
    CHECK(cycles_to_change(b, pulse1_of, 2000) == 0);
    CHECK(b.rtl().pulse1 == 0);
    b.write(0x4002, 0x00);
    b.write(0x4003, 0x04);  // t = $400; shift 0 adds itself: $800
    b.write(0x4001, 0x00);
    CHECK(cycles_to_change(b, pulse1_of, 10'000) == 0);
    b.write(0x4001, 0x01);  // shift 1: $600, sounds
    CHECK(cycles_to_change(b, pulse1_of, 10'000) != 0);
}

TEST_CASE("apu_2a03 triangle steps every t + 1 cycles, 32 steps a period") {
    ApuBench b;
    b.write(0x4015, 0x04);
    b.write(0x4008, 0xFF);  // control: the linear counter holds
    b.write(0x400A, 0x63);
    b.write(0x400B, 0x00);
    b.run(30'000);          // a quarter frame loads the linear counter
    // The sequence repeats 0 and 15 where it turns, so they hold two steps.
    cycles_to_change(b, triangle_of, 1000);
    for (int i = 0; i < 40; i++) {
        uint8_t level = b.rtl().triangle;
        CHECK(cycles_to_change(b, triangle_of, 1000) == (level == 0 || level == 15 ? 2 : 1) * 0x64);
    }
}

TEST_CASE("apu_2a03 length counter: a load of 2 lasts two half frames") {
    ApuBench b;
    b.write(0x4015, 0x01);
    b.write(0x4000, 0x1F);  // no halt
    b.write(0x4003, 0x18);  // index 3: 2
    CHECK((b.read_status() & 1) == 1);
    uint64_t start = b.cycles, gone = 0;
    for (int i = 0; i < 40'000 && !gone; i++)
        if ((b.read_status() & 1) == 0) gone = b.cycles;
    // The half frames come at 14913 and 29829 into the sequence.
    CHECK(gone - start > 25'000);
    CHECK(gone - start < 32'000);
}

TEST_CASE("apu_2a03 frame IRQ in 4-step mode, inhibit and $4015 clear it") {
    ApuBench b;
    b.run(29'840);
    CHECK(b.rtl().irq);
    CHECK((b.read_status() & 0x40) != 0);
    CHECK_FALSE(b.rtl().irq);
    b.run(2);
    CHECK((b.rtl().status & 0x40) == 0);
    b.write(0x4017, 0x40);
    b.run(40'000);
    CHECK_FALSE(b.rtl().irq);
    b.write(0x4017, 0x80);
    b.run(80'000);
    CHECK_FALSE(b.rtl().irq);
}

TEST_CASE("apu_2a03 DMC plays a sample by DMA, wraps $FFFF to $8000 and raises its IRQ") {
    ApuBench b;
    b.write(0x4010, 0x8F);  // IRQ, fastest rate
    b.write(0x4012, 0xFF);  // $FFC0
    b.write(0x4013, 0x04);  // 65 bytes
    b.write(0x4015, 0x10);
    std::vector<uint16_t> addrs;
    for (int i = 0; i < 65 * 8 * 54 + 2000 && !b.rtl().irq; i++) {
        b.cycle();
        if (b.rtl().dma_req) addrs.push_back(b.rtl().dma_addr);
    }
    REQUIRE(addrs.size() == 65);
    CHECK(addrs[0] == 0xFFC0);
    CHECK(addrs[63] == 0xFFFF);
    CHECK(addrs[64] == 0x8000);
    CHECK(b.rtl().irq);
    CHECK((b.rtl().status & 0x90) == 0x80);
    b.write(0x4015, 0x00);
    CHECK_FALSE(b.rtl().irq);
}

TEST_CASE("apu_2a03 matches the model cycle for cycle under random register traffic") {
    for (uint32_t seed = 1; seed <= 8; seed++) {
        INFO("seed " << seed);
        ApuBench b;
        random_traffic(b, seed, 300'000);
    }
}

TEST_CASE("apu_2a03 save state: a restored APU runs on as the original") {
    ApuBench a;
    random_traffic(a, 11, 100'000);
    while (a.dma_wait >= 0) a.cycle();  // no DMA in flight: the bench's own state
    std::vector<uint32_t> words;
    for (int i = 0; i < 17; i++) words.push_back(a.st_read(i));

    ApuBench b;
    random_traffic(b, 12, 5'000);
    while (b.dma_wait >= 0) b.cycle();
    for (int i = 0; i < 17; i++) b.st_write(i, words[i]);
    for (int i = 0; i < 17; i++) CHECK(b.st_read(i) == words[i]);
    b.cycles = a.cycles;
    b.mem = a.mem;

    std::mt19937 r(5);
    for (int i = 0; i < 200'000; i++) {
        uint32_t x = r();
        bool wr = x % 50 == 0;
        uint8_t reg = static_cast<uint8_t>((x >> 8) % 0x18);
        if (reg == 0x14 || reg == 0x16) wr = false;
        uint8_t v = static_cast<uint8_t>(x >> 16);
        a.cycle(wr, reg, v, x % 50 == 1);
        b.cycle(wr, reg, v, x % 50 == 1);
        if (a.dma_wait != b.dma_wait) b.dma_wait = a.dma_wait;  // the benches' own random waits
        REQUIRE(describe(a.rtl()) == describe(b.rtl()));
    }
}
