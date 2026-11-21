// SPDX-License-Identifier: Apache-2.0
// Hand-written checks of what SingleStepTests can't show: interrupt dispatch,
// HALT and its bug, EI's delay, DI, RETI, STOP, illegal opcodes and the
// save-state port. The behaviour follows Pan Docs and Gekkio's "Game Boy:
// Complete Technical Reference", as SameBoy and Mooneye's tests confirm it.
#include <catch2/catch_test_macros.hpp>

#include <initializer_list>
#include <random>
#include <vector>

#include "sm83_bench.hpp"

namespace {

constexpr uint16_t kStart = 0x0200;
constexpr uint16_t kStack = 0xD000;

// A bench with interrupts on, `code` at kStart and the registers set there.
struct Program : Sm83Bench {
    explicit Program(std::initializer_list<uint8_t> code, bool ime = false) {
        irqs = true;
        load(kStart, code);
        set_regs({kStart, kStack, 0x0000, 0, 0, 0, ime, false}, 0);
    }
    void load(uint16_t at, std::initializer_list<uint8_t> bytes) {
        for (uint8_t b : bytes) ram[at++] = b;
    }
    // Runs one instruction (or dispatch, or idle M-cycle), from one boundary to the next.
    std::vector<MCycle> step() {
        std::vector<MCycle> cs;
        do cs.push_back(cycle());
        while (!boundary() && cs.size() < 16);
        return cs;
    }
};

std::vector<char> kinds(const std::vector<MCycle>& cs) {
    std::vector<char> v;
    for (auto& c : cs) v.push_back(c.kind);
    return v;
}

bool illegal(uint8_t v) {
    switch (v) {
    case 0xD3: case 0xDB: case 0xDD: case 0xE3: case 0xE4: case 0xEB:
    case 0xEC: case 0xED: case 0xF4: case 0xFC: case 0xFD: return true;
    default: return false;
    }
}

} // namespace

TEST_CASE("SM83 starts at $0000 after reset") {
    Sm83Bench b;
    REQUIRE(b.fetching());
    REQUIRE(b.regs().pc == 0x0000);
}

TEST_CASE("SM83 interrupt dispatch: EI's delay, 5 M-cycles, the vector and IF cleared") {
    // EI; NOP; NOP, with the timer interrupt enabled and requested.
    Program p({0xFB, 0x00, 0x00});
    p.ram[0xFFFF] = 0x04;
    p.ram[0xFF0F] = 0x04;
    p.step();                         // EI
    REQUIRE_FALSE(p.regs().ime);
    REQUIRE(p.regs().ei);
    auto nop = p.step();              // the NOP after EI still runs
    REQUIRE(nop.size() == 1);
    REQUIRE(nop[0].addr == kStart + 1);
    REQUIRE(p.regs().ime);
    auto d = p.step();                // then the dispatch
    REQUIRE(kinds(d) == std::vector<char>{'r', '-', '-', 'w', 'w'});
    REQUIRE(d[0].addr == kStart + 2);  // the opcode fetch, dropped
    REQUIRE(d[3] == MCycle{kStack - 1, 'w', 0x02});
    REQUIRE(d[4] == MCycle{kStack - 2, 'w', 0x02});
    auto r = p.regs();
    REQUIRE(r.pc == 0x0050);
    REQUIRE(r.sp == kStack - 2);
    REQUIRE_FALSE(r.ime);
    REQUIRE(p.ram[0xFF0F] == 0x00);
    REQUIRE(p.fetching());
}

TEST_CASE("SM83 takes the lowest pending interrupt bit first") {
    Program p({0x00, 0x00}, true);
    p.ram[0xFFFF] = 0x1F;
    p.ram[0xFF0F] = 0x1A;  // STAT, serial, joypad
    auto d = p.step();
    REQUIRE(d.size() == 5);
    REQUIRE(p.regs().pc == 0x0048);
    REQUIRE(p.ram[0xFF0F] == 0x18);
}

TEST_CASE("SM83 dispatch: pushing PC's high byte into IE can cancel the interrupt") {
    SECTION("IE loses the bit: PC goes to $0000 and IF keeps it") {
        Program p({0x00}, true);
        p.set_regs({0x0100, 0x0000, 0, 0, 0, 0, true, false}, 0);  // SP $0000: the high byte lands in $FFFF
        p.ram[0x0100] = 0x00;
        p.ram[0xFFFF] = 0x04;
        p.ram[0xFF0F] = 0x04;
        auto d = p.step();
        REQUIRE(d[3] == MCycle{0xFFFF, 'w', 0x01});
        REQUIRE(p.regs().pc == 0x0000);
        REQUIRE(p.ram[0xFF0F] == 0x04);
    }
    SECTION("IE keeps the bit: the interrupt goes ahead") {
        Program p({0x00}, true);
        p.set_regs({0x0400, 0x0000, 0, 0, 0, 0, true, false}, 0);
        p.ram[0x0400] = 0x00;
        p.ram[0xFFFF] = 0x04;
        p.ram[0xFF0F] = 0x04;
        p.step();
        REQUIRE(p.regs().pc == 0x0050);
        REQUIRE(p.ram[0xFF0F] == 0x00);
    }
}

TEST_CASE("SM83 HALT idles without bus accesses until an interrupt is pending, then fetches or dispatches") {
    SECTION("IME clear: it wakes and carries on after the HALT") {
        Program p({0x76, 0x3C, 0x00});  // HALT; INC A
        p.ram[0xFFFF] = 0x01;
        p.step();                        // HALT
        auto in = p.step();              // the next byte read and dropped, then halted
        REQUIRE(kinds(in) == std::vector<char>{'r'});
        REQUIRE(p.halted());
        for (int i = 0; i < 10; i++) REQUIRE(p.cycle().kind == '-');
        p.ram[0xFF0F] = 0x01;
        auto c = p.cycle();              // the M-cycle that sees it fetches INC A
        REQUIRE(c.kind == 'r');
        REQUIRE(c.addr == kStart + 1);
        REQUIRE_FALSE(p.halted());
        REQUIRE(p.regs().af >> 8 == 0x01);
        REQUIRE(p.regs().pc == kStart + 2);
        REQUIRE(p.ram[0xFF0F] == 0x01);  // not taken
    }
    SECTION("IME set: it wakes into the interrupt, returning after the HALT") {
        Program p({0x76, 0x00}, true);
        p.ram[0xFFFF] = 0x01;
        p.step();
        p.step();
        REQUIRE(p.halted());
        p.ram[0xFF0F] = 0x01;
        auto d = p.step();               // the M-cycle that sees it is the dispatch's first
        REQUIRE(kinds(d) == std::vector<char>{'r', '-', '-', 'w', 'w'});
        REQUIRE(d[0].addr == kStart + 1);  // the opcode fetch, dropped
        REQUIRE(p.regs().pc == 0x0040);
        REQUIRE(p.ram[kStack - 2] == ((kStart + 1) & 0xFF));
    }
}

TEST_CASE("SM83 HALT bug: IME clear with an interrupt pending reads the next byte twice") {
    Program p({0x76, 0x3C, 0x00});  // HALT; INC A; NOP
    p.ram[0xFFFF] = 0x01;
    p.ram[0xFF0F] = 0x01;
    p.step();                       // HALT: doesn't halt
    REQUIRE_FALSE(p.halted());
    auto a = p.step();              // INC A, PC not advanced
    REQUIRE(a[0].addr == kStart + 1);
    REQUIRE(p.regs().pc == kStart + 1);
    auto b = p.step();              // INC A again
    REQUIRE(b[0].addr == kStart + 1);
    REQUIRE(p.regs().af >> 8 == 0x02);
    REQUIRE(p.regs().pc == kStart + 2);
}

TEST_CASE("SM83 EI then HALT with an interrupt pending returns to the HALT") {
    Program p({0xFB, 0x76, 0x00});
    p.ram[0xFFFF] = 0x01;
    p.ram[0xFF0F] = 0x01;
    p.step();  // EI
    p.step();  // HALT
    auto d = p.step();
    REQUIRE(d.size() == 5);
    REQUIRE(p.regs().pc == 0x0040);
    uint16_t ret = static_cast<uint16_t>(p.ram[kStack - 1] << 8 | p.ram[kStack - 2]);
    REQUIRE(ret == kStart + 1);
}

TEST_CASE("SM83 DI acts at once: EI; DI lets no interrupt in") {
    Program p({0xFB, 0xF3, 0x00, 0x00, 0x00});
    p.ram[0xFFFF] = 0x01;
    p.ram[0xFF0F] = 0x01;
    for (int i = 0; i < 5; i++) REQUIRE(p.step().size() == 1);
    REQUIRE(p.regs().pc == kStart + 5);
    REQUIRE_FALSE(p.regs().ime);
}

TEST_CASE("SM83 RETI enables interrupts at once") {
    Program p({0xD9});  // RETI to $0300
    p.set_regs({kStart, kStack - 2, 0, 0, 0, 0, false, false}, 0);
    p.ram[kStack - 2] = 0x00;
    p.ram[kStack - 1] = 0x03;
    p.ram[0xFFFF] = 0x02;
    p.ram[0xFF0F] = 0x02;
    REQUIRE(p.step().size() == 4);
    REQUIRE(p.regs().ime);
    auto d = p.step();  // straight into the interrupt
    REQUIRE(d.size() == 5);
    REQUIRE(d[0].addr == 0x0300);
    REQUIRE(p.regs().pc == 0x0048);
}

TEST_CASE("SM83 STOP reads its second byte, then waits for stop_exit") {
    Program p({0x10, 0x00, 0x3C});
    p.step();
    auto s = p.step();
    REQUIRE(kinds(s) == std::vector<char>{'r'});
    REQUIRE(s[0].addr == kStart + 1);
    REQUIRE(p.stopped());
    for (int i = 0; i < 5; i++) REQUIRE(p.cycle().kind == '-');
    p.stop_exit = true;
    p.cycle();
    p.stop_exit = false;
    REQUIRE_FALSE(p.stopped());
    p.step();  // INC A
    REQUIRE(p.regs().af >> 8 == 0x01);
}

TEST_CASE("SM83 STOP with an interrupt pending: nothing, unless stop_switch (a speed switch armed)") {
    for (bool sw : {false, true}) {
        INFO("stop_switch " << sw);
        Program p({0x10, 0x00, 0x3C});
        p.ram[0xFFFF] = 0x04;
        p.ram[0xFF0F] = 0x04;  // the timer's, pending, IME clear
        p.stop_switch = sw;
        p.step();
        p.step();
        REQUIRE(p.stopped() == sw);
        if (!sw) {
            REQUIRE(p.regs().pc == kStart + 2);  // its second byte ran as a NOP
            continue;
        }
        for (int i = 0; i < 5; i++) REQUIRE(p.cycle().kind == '-');
        p.stop_exit = true;
        p.cycle();
        p.stop_exit = false;
        REQUIRE_FALSE(p.stopped());
        p.step();  // INC A
        REQUIRE(p.regs().af >> 8 == 0x01);
    }
}

TEST_CASE("SM83 locks up on an illegal opcode, interrupts or not") {
    for (uint8_t op : {0xD3, 0xDB, 0xDD, 0xE3, 0xE4, 0xEB, 0xEC, 0xED, 0xF4, 0xFC, 0xFD}) {
        Program p({op, 0x00}, true);
        p.step();
        p.ram[0xFFFF] = 0x01;
        p.ram[0xFF0F] = 0x01;
        for (int i = 0; i < 20; i++) REQUIRE(p.cycle().kind == '-');
        REQUIRE(p.locked());
        REQUIRE(p.regs().pc == kStart + 1);
    }
}

TEST_CASE("SM83 save state: restored mid-instruction, it carries on the same") {
    std::mt19937 rng(83);
    auto r16 = [&] { return static_cast<uint16_t>(rng()); };
    for (int run = 0; run < 200; run++) {
        Sm83Bench a;
        a.irqs = true;
        for (auto& v : a.ram) {
            v = static_cast<uint8_t>(rng());
            if (illegal(v)) v = 0x00;  // a lock-up would end the run's interest
        }
        a.set_regs({r16(), r16(), r16(), r16(), r16(), r16(), (rng() & 1) != 0, false},
                   static_cast<uint8_t>(rng()));
        int before = 1 + static_cast<int>(rng() % 200);
        for (int i = 0; i < before; i++) a.cycle();

        std::vector<uint32_t> words;
        for (uint8_t w = 0; w < 4; w++) words.push_back(a.get(w));
        Sm83Bench b;
        b.irqs = true;
        b.ram = a.ram;
        for (uint8_t w = 0; w < 4; w++) b.put(w, words[w]);
        for (uint8_t w = 0; w < 4; w++) REQUIRE(b.get(w) == words[w]);

        for (int i = 0; i < 300; i++) {
            MCycle x = a.cycle(), y = b.cycle();
            INFO("run " << run << ", M-cycle " << i << " after the restore");
            REQUIRE(x == y);
        }
        auto ra = a.regs(), rb = b.regs();
        REQUIRE(ra.pc == rb.pc);
        REQUIRE(ra.af == rb.af);
        REQUIRE(ra.sp == rb.sp);
    }
}
