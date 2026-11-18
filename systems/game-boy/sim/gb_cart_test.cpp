// SPDX-License-Identifier: Apache-2.0
// gb_cart on its own: the controllers' banking where Mooneye's MBC tests don't reach (MBC3, MBC30,
// MBC5's ninth bank bit, MBC1M), and MBC3's clock as MesenCE and SameBoy count it: a second every
// 4,194,304 T-cycles from a write to the seconds, held while halted, the carries, the registers'
// bits and the latch. The ROM's address is checked as gb_cart gives it (`rom_addr`); the bus's reads
// a clock after their address, as the console takes them.
#include <catch2/catch_test_macros.hpp>

#include <verilated.h>

#include <cstdint>
#include <memory>

#include "Vgb_cart.h"

namespace {

constexpr uint64_t kSecond = 4'194'304;  // T-cycles

enum Mbc { kNone = 0, kMbc1 = 1, kMbc1m = 2, kMbc2 = 3, kMbc3 = 4, kMbc5 = 5 };

struct Cart {
    VerilatedContext ctx;
    std::unique_ptr<Vgb_cart> m = std::make_unique<Vgb_cart>(&ctx);

    Cart(int mbc, int rom_log2, int ram_log2, bool rtc = false, bool rumble = false) {
        m->mbc = mbc;
        m->rom_log2 = rom_log2;
        m->ram_log2 = ram_log2;
        m->rtc = rtc;
        m->rumble = rumble;
        m->rst = 1;
        // The clock's state, as the host loads it: all 0.
        m->sh_we = 1;
        m->sh_rtc = 1;
        m->sh_wdata = 0;
        for (int i = 0; i < 13; i++) {
            m->sh_addr = i;
            clock();
        }
        m->sh_we = 0;
        m->sh_rtc = 0;
        clock();
        m->rst = 0;
        clock();
    }

    void clock(bool ce = false) {
        m->ce = ce;
        m->clk = 0;
        m->eval();
        m->clk = 1;
        m->eval();
        m->ce = 0;
        m->wr = 0;
    }
    // T-cycles, one every other clock.
    void run(uint64_t t) {
        for (uint64_t i = 0; i < t; i++) {
            clock(true);
            clock();
        }
    }
    void write(uint16_t a, uint8_t v) {
        m->addr = a;
        m->wdata = v;
        m->wr = 1;
        clock();
    }
    uint8_t read(uint16_t a) {
        m->addr = a;
        clock();
        clock();
        m->eval();
        return m->rdata;
    }
    // The ROM address a read of `a` gives.
    uint32_t rom(uint16_t a) {
        m->addr = a;
        m->eval();
        return m->rom_addr;
    }
    // MBC3's clock: S M H DL DH as the bus reads them after a latch.
    struct Time {
        uint8_t s, m, h, dl, dh;
    };
    Time latched() {
        write(0x6000, 0);
        write(0x6000, 1);
        Time t{};
        uint8_t* f[] = {&t.s, &t.m, &t.h, &t.dl, &t.dh};
        for (int r = 0; r < 5; r++) {
            write(0x4000, 0x08 + r);
            *f[r] = read(0xA000);
        }
        return t;
    }
    void set(uint8_t reg, uint8_t v) {
        write(0x4000, reg);
        write(0xA000, v);
    }
};

}  // namespace

TEST_CASE("MBC1: BANK1 0 reads as 1, and mode 1 banks $0000-$3FFF and the RAM by BANK2") {
    Cart c(kMbc1, 21, 15);  // 2 MB, 32 KB RAM
    CHECK(c.rom(0x4000) == 0x4000);
    c.write(0x2000, 0x00);
    CHECK(c.rom(0x4123) == 0x4123);
    c.write(0x2000, 0x20);  // only 5 bits: 0 again
    CHECK(c.rom(0x4000) == 0x4000);
    c.write(0x2000, 0x05);
    c.write(0x4000, 0x02);
    CHECK(c.rom(0x4000) == ((0x45u << 14) & 0x1FFFFF));
    CHECK(c.rom(0x0000) == 0);
    c.write(0x6000, 1);
    CHECK(c.rom(0x0010) == (0x40u << 14) + 0x10);
    // RAM: enabled by $xA, in bank 2 in mode 1.
    CHECK(c.read(0xA000) == 0xFF);
    c.write(0x0000, 0x3A);
    c.write(0xA001, 0x5C);
    CHECK(c.read(0xA001) == 0x5C);
    c.write(0x4000, 0x00);
    CHECK(c.read(0xA001) != 0x5C);  // RAM bank 0 is another 8 KB
    c.write(0x4000, 0x02);
    CHECK(c.read(0xA001) == 0x5C);
    c.write(0x0000, 0x00);
    CHECK(c.read(0xA001) == 0xFF);
}

TEST_CASE("MBC1M: BANK2 comes in at bank bit 4, and BANK1's top bit is left out") {
    Cart c(kMbc1m, 20, 0);  // 1 MB
    c.write(0x2000, 0x13);
    c.write(0x4000, 0x01);
    CHECK(c.rom(0x4000) == (0x13u << 14));  // 0x10 | 3
    c.write(0x2000, 0x10);                  // 0x10 isn't 0, so no +1: bank 0x10 + 0
    CHECK(c.rom(0x4000) == (0x10u << 14));
    c.write(0x6000, 1);
    CHECK(c.rom(0x0000) == (0x10u << 14));
}

TEST_CASE("MBC2: the bank from address bit 8, and 4-bit RAM cells read with the top 4 bits set") {
    Cart c(kMbc2, 18, 9);  // 256 KB
    c.write(0x2100, 0x07);
    CHECK(c.rom(0x4000) == (7u << 14));
    c.write(0x2100, 0x00);
    CHECK(c.rom(0x4000) == (1u << 14));
    c.write(0x0000, 0x0A);  // address bit 8 low: RAM enable
    c.write(0xA005, 0x3C);
    CHECK(c.read(0xA005) == 0xFC);
    CHECK(c.read(0xA205) == 0xFC);  // repeated every 512 bytes
    c.write(0x0100, 0x0A);         // bit 8 high: a bank write, not RAM enable
    CHECK(c.rom(0x4000) == (0xAu << 14));
}

TEST_CASE("MBC3: 7-bit banks, 8 on the MBC30, 0 read as 1; RAM banks; the clock's registers by bank") {
    Cart c(kMbc3, 22, 15);  // 4 MB: only 7 bits reach
    c.write(0x2000, 0x85);
    CHECK(c.rom(0x4000) == (0x05u << 14));
    c.write(0x2000, 0x80);
    CHECK(c.rom(0x4000) == (1u << 14));
    Cart c30(kMbc3, 22, 16);  // 64 KB of RAM: an MBC30
    c30.write(0x2000, 0x85);
    CHECK(c30.rom(0x4000) == (0x85u << 14));
    // Without the clock, banks 8-$C read $FF.
    c.write(0x0000, 0x0A);
    c.write(0x4000, 0x08);
    CHECK(c.read(0xA000) == 0xFF);
    c.write(0x4000, 0x03);
    c.write(0xA010, 0x99);
    CHECK(c.read(0xA010) == 0x99);
}

TEST_CASE("MBC5: 9-bit banks, bank 0 allowed; RAM enable needs exactly $0A; with rumble, 3-bit RAM banks") {
    Cart c(kMbc5, 23, 15);  // 8 MB, 32 KB of RAM (the model's room)
    c.write(0x2000, 0x00);
    CHECK(c.rom(0x4000) == 0);
    c.write(0x2000, 0x34);
    c.write(0x3000, 0x01);
    CHECK(c.rom(0x4000) == (0x134u << 14));
    c.write(0x0000, 0x1A);
    CHECK(c.read(0xA000) == 0xFF);
    c.write(0x0000, 0x0A);
    c.write(0x4000, 0x03);
    c.write(0xA000, 0x42);
    CHECK(c.read(0xA000) == 0x42);
    c.write(0x4000, 0x02);
    CHECK(c.read(0xA000) != 0x42);
    c.write(0x4000, 0x07);  // past the RAM's 4 banks: wraps to bank 3
    CHECK(c.read(0xA000) == 0x42);
    Cart r(kMbc5, 20, 15, false, true);
    r.write(0x0000, 0x0A);
    r.write(0x4000, 0x09);  // bank 1 with the motor on
    r.write(0xA000, 0x77);
    r.write(0x4000, 0x01);
    CHECK(r.read(0xA000) == 0x77);
}

TEST_CASE("MBC3's clock counts a second per 4,194,304 T-cycles from a write to the seconds") {
    Cart c(kMbc3, 21, 15, true);
    c.write(0x0000, 0x0A);
    c.set(0x08, 10);
    c.run(kSecond - 1);
    CHECK(c.latched().s == 10);
    c.run(1);
    CHECK(c.latched().s == 11);
    // A write to the seconds starts the second again.
    c.run(kSecond / 2);
    c.set(0x08, 20);
    c.run(kSecond - 1);
    CHECK(c.latched().s == 20);
    c.run(1);
    CHECK(c.latched().s == 21);
}

TEST_CASE("MBC3's clock: halted, it doesn't count; its carries and its registers' bits") {
    Cart c(kMbc3, 21, 15, true);
    c.write(0x0000, 0x0A);
    c.set(0x08, 0);
    c.set(0x0C, 0x40);  // halt
    c.run(2 * kSecond);
    CHECK(c.latched().s == 0);
    // 511 days 23:59:59 rolls to 0 days, the carry set; it stays.
    c.set(0x08, 59);
    c.set(0x09, 59);
    c.set(0x0A, 23);
    c.set(0x0B, 0xFF);
    c.set(0x0C, 0x01);  // running, day bit 8
    c.run(kSecond);
    auto t = c.latched();
    CHECK(t.s == 0);
    CHECK(t.m == 0);
    CHECK(t.h == 0);
    CHECK(t.dl == 0);
    CHECK(t.dh == 0x80);
    c.run(kSecond);
    CHECK(c.latched().dh == 0x80);
    // Out-of-range values: 63 seconds wraps without a carry; 60 minutes with 59 seconds counts on.
    c.set(0x08, 63);
    c.set(0x09, 5);
    c.run(kSecond);
    t = c.latched();
    CHECK(t.s == 0);
    CHECK(t.m == 5);
    c.set(0x08, 59);
    c.set(0x09, 60);
    c.run(kSecond);
    t = c.latched();
    CHECK(t.s == 0);
    CHECK(t.m == 61);
    // Only the registers' bits are kept.
    c.set(0x0C, 0xFF);
    c.set(0x0A, 0xFF);
    c.set(0x09, 0xFF);
    t = c.latched();
    CHECK(t.dh == 0xC1);
    CHECK(t.h == 0x1F);
    CHECK(t.m == 0x3F);
}

TEST_CASE("MBC3's clock: reads give the latched copy, taken at any write to $6000-$7FFF") {
    Cart c(kMbc3, 21, 15, true);
    c.write(0x0000, 0x0A);
    c.set(0x08, 30);
    c.write(0x6000, 0x00);
    c.write(0x4000, 0x08);
    CHECK(c.read(0xA000) == 30);
    c.run(kSecond);
    CHECK(c.read(0xA000) == 30);  // still the latched value
    c.write(0x7FFF, 0x55);        // any value latches
    c.write(0x4000, 0x08);
    CHECK(c.read(0xA000) == 31);
}
