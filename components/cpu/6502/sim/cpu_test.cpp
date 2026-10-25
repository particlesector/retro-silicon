// SPDX-License-Identifier: Apache-2.0
// Hand-written checks of the bus behaviour documented for the NMOS 6502 (as in
// "6502.txt" by John West and Marko Mäkelä). perfect6502_test.cpp then
// compares everything against a transistor-level simulation.
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <initializer_list>
#include <vector>

#include "cpu_bench.hpp"

namespace {

constexpr uint16_t kStart = 0x0400;

// A bench whose reset vector points at kStart, with `code` there, run up to
// the first opcode fetch.
struct Program : CpuBench {
    explicit Program(std::initializer_list<uint8_t> code) {
        ram[0xFFFC] = kStart & 0xFF;
        ram[0xFFFD] = kStart >> 8;
        load(kStart, code);
        REQUIRE(run_to(kStart, 20));
    }
    void load(uint16_t at, std::initializer_list<uint8_t> bytes) {
        for (uint8_t b : bytes) ram[at++] = b;
    }
};

std::vector<uint16_t> addrs(const std::vector<BusCycle>& cs) {
    std::vector<uint16_t> v;
    for (auto& c : cs) v.push_back(c.addr);
    return v;
}

} // namespace

TEST_CASE("6502 reset reads the stack three times, then the vector, leaving S at $FD") {
    CpuBench b;
    b.ram[0xFFFC] = 0x34;
    b.ram[0xFFFD] = 0x12;
    std::vector<BusCycle> cs;
    for (int i = 0; i < 7; i++) cs.push_back(b.cycle());
    for (auto& c : cs) REQUIRE_FALSE(c.write);
    REQUIRE(addrs(cs) == std::vector<uint16_t>{0x0000, 0x0000, 0x0100, 0x01FF, 0x01FE, 0xFFFC, 0xFFFD});
    REQUIRE(b.at_fetch());
    auto r = b.regs();
    REQUIRE(r.pc == 0x1234);
    REQUIRE(r.s == 0xFD);
    REQUIRE((r.p & 0x04) != 0);  // I set
}

TEST_CASE("6502 runs a short program: loads, stores, ADC flags, a loop") {
    // LDX #5; loop: TXA; CLC; ADC #$7E; STA $0200,X; DEX; BNE loop; BRK-free stop: JMP *
    Program p({0xA2, 0x05, 0x8A, 0x18, 0x69, 0x7E, 0x9D, 0x00, 0x02, 0xCA, 0xD0, 0xF6, 0x4C, 0x0C, 0x04});
    REQUIRE(p.run_to(0x040C, 1000));
    for (int x = 1; x <= 5; x++) REQUIRE(p.ram[0x0200 + x] == static_cast<uint8_t>(x + 0x7E));
    auto r = p.regs();
    REQUIRE(r.x == 0);
    REQUIRE(r.a == 0x7F);
    REQUIRE((r.p & 0x02) != 0);  // Z from DEX
}

TEST_CASE("6502 cycle counts and bus addresses follow the documented tables") {
    SECTION("LDA abs,X without and with a page cross: 4 cycles, then 5 with a dummy read") {
        Program p({0xA2, 0x10, 0xBD, 0x00, 0x30, 0xBD, 0xF8, 0x30});
        p.instruction();  // LDX #$10
        auto a = p.instruction();
        REQUIRE(addrs(a) == std::vector<uint16_t>{0x0402, 0x0403, 0x0404, 0x3010});
        auto b = p.instruction();
        REQUIRE(addrs(b) == std::vector<uint16_t>{0x0405, 0x0406, 0x0407, 0x3008, 0x3108});
    }
    SECTION("STA abs,X always takes 5 cycles, reading the unfixed address first") {
        Program p({0xA2, 0x01, 0x9D, 0x00, 0x30});
        p.instruction();
        auto c = p.instruction();
        REQUIRE(addrs(c) == std::vector<uint16_t>{0x0402, 0x0403, 0x0404, 0x3001, 0x3001});
        REQUIRE_FALSE(c[3].write);
        REQUIRE(c[4].write);
    }
    SECTION("INC abs reads, writes the old value back, then writes the new one") {
        Program p({0xEE, 0x00, 0x30});
        p.ram[0x3000] = 0x41;
        auto c = p.instruction();
        REQUIRE(c.size() == 6);
        REQUIRE(c[3] == BusCycle{0x3000, false, 0x41, false});
        REQUIRE(c[4] == BusCycle{0x3000, true, 0x41, false});
        REQUIRE(c[5] == BusCycle{0x3000, true, 0x42, false});
    }
    SECTION("(zp),Y wraps its pointer within the zero page") {
        Program p({0xA0, 0x02, 0xB1, 0xFF});
        p.ram[0x00FF] = 0x00;
        p.ram[0x0000] = 0x30;  // pointer high byte from $00, not $100
        p.ram[0x3002] = 0x99;
        p.instruction();
        auto c = p.instruction();
        REQUIRE(addrs(c) == std::vector<uint16_t>{0x0402, 0x0403, 0x00FF, 0x0000, 0x3002});
        REQUIRE(p.regs().a == 0x99);
    }
    SECTION("JMP ($30FF) takes its high byte from $3000: the page-wrap bug") {
        Program p({0x6C, 0xFF, 0x30});
        p.ram[0x30FF] = 0x00;
        p.ram[0x3000] = 0x50;
        p.ram[0x3100] = 0x60;
        auto c = p.instruction();
        REQUIRE(addrs(c) == std::vector<uint16_t>{0x0400, 0x0401, 0x0402, 0x30FF, 0x3000});
        REQUIRE(p.regs().pc == 0x5000);
    }
    SECTION("a taken branch: 3 cycles, 4 across a page, with dummy reads") {
        // At $04F0: BNE +$7F (to $0571, another page); at $0400: BNE +2 (same page).
        Program p({0xD0, 0x02});
        p.load(0x0404, {0x4C, 0xF0, 0x04});
        p.load(0x04F0, {0xD0, 0x7F});
        auto same = p.instruction();
        REQUIRE(addrs(same) == std::vector<uint16_t>{0x0400, 0x0401, 0x0402});
        p.instruction();  // JMP $04F0
        auto far = p.instruction();
        REQUIRE(addrs(far) == std::vector<uint16_t>{0x04F0, 0x04F1, 0x04F2, 0x0471});
        REQUIRE(p.regs().pc == 0x0571);
    }
    SECTION("JSR and RTS push and pull the return address minus one") {
        Program p({0x20, 0x00, 0x30});
        p.ram[0x3000] = 0x60;  // RTS
        auto jsr = p.instruction();
        REQUIRE(addrs(jsr) == std::vector<uint16_t>{0x0400, 0x0401, 0x01FD, 0x01FD, 0x01FC, 0x0402});
        REQUIRE(jsr[3] == BusCycle{0x01FD, true, 0x04, false});
        REQUIRE(jsr[4] == BusCycle{0x01FC, true, 0x02, false});
        auto rts = p.instruction();
        REQUIRE(addrs(rts) == std::vector<uint16_t>{0x3000, 0x3001, 0x01FB, 0x01FC, 0x01FD, 0x0402});
        REQUIRE(p.regs().pc == 0x0403);
    }
}

TEST_CASE("6502 BRK pushes PC+2 and P with B set; RTI returns") {
    Program p({0x00, 0xEA, 0xEA});
    p.ram[0xFFFE] = 0x00;
    p.ram[0xFFFF] = 0x30;
    p.ram[0x3000] = 0x40;  // RTI
    auto brk = p.instruction();
    REQUIRE(brk.size() == 7);
    REQUIRE(brk[2] == BusCycle{0x01FD, true, 0x04, false});
    REQUIRE(brk[3] == BusCycle{0x01FC, true, 0x02, false});
    REQUIRE(brk[4].data == 0x34);  // I from reset, bit 5, B
    REQUIRE(p.regs().pc == 0x3000);
    p.instruction();
    REQUIRE(p.regs().pc == 0x0402);
}

TEST_CASE("6502 IRQ waits for CLI plus one instruction, and pushes B clear") {
    // CLI; NOP; NOP; NOP
    Program p({0x58, 0xEA, 0xEA, 0xEA});
    p.ram[0xFFFE] = 0x00;
    p.ram[0xFFFF] = 0x30;
    p.irq_n = false;
    p.instruction();                    // CLI: I was set when the IRQ was polled
    REQUIRE(p.regs().pc == 0x0401);
    p.instruction();                    // the NOP after CLI still runs
    REQUIRE(p.regs().pc == 0x0402);
    auto irq = p.instruction();         // then the IRQ sequence
    REQUIRE(irq.size() == 7);
    REQUIRE(irq[0].addr == 0x0402);     // the opcode fetched here is dropped
    REQUIRE(irq[1].addr == 0x0402);
    REQUIRE(irq[4].data == 0x20);       // B clear
    REQUIRE(p.regs().pc == 0x3000);
}

TEST_CASE("6502 NMI is taken once per falling edge, even with I set") {
    Program p({0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA});
    p.ram[0xFFFA] = 0x00;
    p.ram[0xFFFB] = 0x30;
    p.load(0x3000, {0xEA, 0xEA, 0xEA, 0xEA, 0xEA});
    p.nmi_n = false;
    p.instruction();
    auto nmi = p.instruction();
    REQUIRE(nmi.size() == 7);
    REQUIRE(p.regs().pc == 0x3000);
    // Held low, it doesn't fire again.
    for (int i = 0; i < 4; i++) p.instruction();
    REQUIRE(p.regs().pc == 0x3004);
}

TEST_CASE("6502 merges NMI edges up to the end of the NMI sequence; a later one waits one instruction") {
    // Measured on perfect6502: the first edge starts a sequence whose vector
    // reads are its last two cycles. A second edge seen by then is part of the
    // same NMI; one after it is taken after the handler's first instruction.
    for (int gap = 1; gap <= 9; gap++) {
        Program p({0xEA, 0xEA, 0xEA, 0xEA});
        p.ram[0xFFFA] = 0x00;
        p.ram[0xFFFB] = 0x30;
        for (int i = 0; i < 16; i++) p.ram[0x3000 + i] = 0xEA;
        p.ram[0xFFFE] = 0x00;
        p.ram[0xFFFF] = 0x40;  // a second NMI must not look like an IRQ either
        std::vector<BusCycle> cs;
        // NMI low from the first cycle; at cycle 1 + gap it goes high for a cycle.
        // (cpu_6502 samples inputs at the edge before the cycle they apply to.)
        for (int c = 0; c < 40; c++) {
            p.nmi_n = c == 1 + gap;
            cs.push_back(p.cycle());
        }
        int vectors = 0;
        for (auto& c : cs) vectors += c.addr == 0xFFFA;
        CAPTURE(gap);
        // The first sequence runs cycles 2-8, reading the vector in 7 and 8. The
        // second fall is sampled at the edge ending cycle 2+gap: up to the edge
        // ending cycle 7 it merges (gap <= 5); at the edge ending 8, the
        // sequence's last, it's kept for later.
        REQUIRE(vectors == (gap <= 5 ? 1 : 2));
    }
}

TEST_CASE("6502 RDY low stalls read cycles but lets writes finish") {
    Program p({0xA9, 0x55, 0x8D, 0x00, 0x30});
    p.instruction();
    p.cycle();  // STA: opcode
    p.cycle();  // low byte
    p.cycle();  // high byte; the next cycle is the write
    p.rdy = false;
    auto w = p.cycle();
    REQUIRE(w.write);  // writes ignore RDY
    auto r1 = p.cycle();
    auto r2 = p.cycle();
    REQUIRE_FALSE(r1.write);
    REQUIRE(r1 == r2);  // the next read repeats while RDY is low
    p.rdy = true;
    REQUIRE(p.ram[0x3000] == 0x55);
}

TEST_CASE("6502 ANC, ALR and ARR AND with the operand first, as on real chips") {
    // Each: SEC or CLC; LDA #a; op #imm; PHP. Then the result and the pushed flags.
    struct Case {
        uint8_t op, a, imm;
        bool c;
        uint8_t result, flags;  // N V - B D I Z C as pushed by PHP (B and bit 5 set)
    };
    const Case cases[] = {
        {0x0B, 0xF0, 0x8F, false, 0x80, 0xB1},  // ANC: N and C from bit 7
        {0x2B, 0x0F, 0x0F, true, 0x0F, 0x30},   // ANC: carry cleared
        {0x4B, 0x0F, 0xF3, false, 0x01, 0x31},  // ALR: (0F & F3) >> 1, C from bit 0
        {0x4B, 0x0F, 0xF0, false, 0x00, 0x32},  // ALR: zero
        {0x6B, 0x0F, 0xF0, false, 0x00, 0x32},  // ARR: (0F & F0) ror, zero
        {0x6B, 0xF1, 0x3F, true, 0x98, 0xB0},   // ARR: carry in to bit 7; C = bit 6, V = bit 6 ^ bit 5
        {0x6B, 0xFF, 0xFF, false, 0x7F, 0x31},  // ARR: bits 6 and 5 both set: C, no V
        {0x6B, 0x40, 0xFF, false, 0x20, 0x70},  // ARR: bit 5 only: V, no C
    };
    for (auto& c : cases) {
        Program p({static_cast<uint8_t>(c.c ? 0x38 : 0x18), 0xA9, c.a, c.op, c.imm, 0x08});
        for (int i = 0; i < 4; i++) p.instruction();
        CAPTURE(int(c.op), int(c.a), int(c.imm));
        REQUIRE(p.regs().a == c.result);
        REQUIRE(p.ram[0x01FD] == (c.flags | 0x04));  // I is still set from reset
    }
}

TEST_CASE("6502 stops on a JAM opcode until reset") {
    Program p({0xEA, 0x02, 0xEA});
    p.instruction();
    for (int i = 0; i < 10; i++) p.cycle();
    REQUIRE(p.halted());
}

TEST_CASE("6502 save state restores mid-instruction, interrupts included") {
    // Memory is all opcodes that keep running, so any byte the CPU fetches as
    // an opcode is one; IRQ and NMI toggle at random.
    std::vector<uint8_t> safe;
    for (int op = 0; op < 256; op++) {
        bool jam = (op & 0x0F) == 0x02 && op != 0x82 && op != 0xA2 && op != 0xC2 && op != 0xE2;
        bool unstable = op == 0x8B || op == 0xAB || op == 0x93 || op == 0x9F || op == 0x9E || op == 0x9C ||
                        op == 0x9B || op == 0xBB;
        if (!jam && !unstable) safe.push_back(static_cast<uint8_t>(op));
    }
    for (unsigned seed = 1; seed <= 40; seed++) {
        std::mt19937 rng(seed);
        CpuBench a, b;
        for (auto& v : a.ram) v = safe[rng() % safe.size()];
        auto inputs = [](CpuBench& c, std::mt19937& r) {
            uint32_t x = r();
            c.irq_n = (x & 7) != 0;
            c.nmi_n = (x & 0x30) != 0;
        };
        for (int i = 0, n = 100 + static_cast<int>(rng() % 400); i < n; i++) {
            inputs(a, rng);
            a.cycle();
        }
        uint32_t st[4];
        for (int i = 0; i < 4; i++) st[i] = a.state_read(i);
        b.ram = a.ram;
        for (int i = 0; i < 50; i++) b.cycle();  // somewhere else entirely
        b.ram = a.ram;
        for (int i = 0; i < 4; i++) b.state_write(i, st[i]);
        b.irq_n = a.irq_n;
        b.nmi_n = a.nmi_n;
        std::mt19937 ra(seed * 77), rb(seed * 77);
        for (int i = 0; i < 400; i++) {
            inputs(a, ra);
            inputs(b, rb);
            CAPTURE(seed, i);
            REQUIRE(a.cycle() == b.cycle());
        }
        for (int i = 0; i < 4; i++) REQUIRE(a.state_read(i) == b.state_read(i));
    }
}
