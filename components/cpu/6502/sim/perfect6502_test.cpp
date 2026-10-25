// SPDX-License-Identifier: Apache-2.0
// cpu_6502 in lockstep with perfect6502, a transistor-level simulation of the
// NMOS 6502 (github.com/mist64/perfect6502, fetched by cmake/Perfect6502.cmake).
// Both run random code from the same memory with the same random IRQ and NMI
// activity, and every cycle's bus access must match. RDY is left out for now:
// which internal updates a stall blocks depends on the pipeline stage, and the
// exact behaviour will be matched when the NES's DMA needs it.
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <cstdlib>
#include <deque>
#include <random>
#include <sstream>
#include <vector>

#include "cpu_bench.hpp"

extern "C" {
// perfect6502's C interface; the types match its definitions (BOOL is unsigned char).
void* initAndResetChip(void);
void destroyChip(void* state);
void step(void* state);
unsigned short readAddressBus(void* state);
unsigned char readDataBus(void* state);
unsigned char readRW(void* state);
void setNode(void* state, unsigned short node, unsigned char value);
extern unsigned char memory[65536];
}

namespace {

// Pin node numbers, from perfect6502's netlist_6502.h.
constexpr unsigned short kIrq = 103, kNmi = 1297, kRdy = 89;

class Perfect6502 {
public:
    Perfect6502() : s_(initAndResetChip()) {}
    ~Perfect6502() { destroyChip(s_); }
    Perfect6502(const Perfect6502&) = delete;
    Perfect6502& operator=(const Perfect6502&) = delete;

    // One CPU cycle: phase 1, then phase 2, when memory is read or written.
    BusCycle cycle(bool irq_n, bool nmi_n, bool rdy) {
        setNode(s_, kIrq, irq_n);
        setNode(s_, kNmi, nmi_n);
        setNode(s_, kRdy, rdy);
        step(s_);
        step(s_);
        uint16_t a = readAddressBus(s_);
        bool write = !readRW(s_);
        return {a, write, write ? readDataBus(s_) : memory[a], false};
    }

private:
    void* s_;
};

// Opcodes compared in lockstep: everything cpu_6502 runs (all but the JAMs and
// the unstable unofficial ones) except ANC, ALR and ARR. perfect6502 leaves
// out their AND with the operand, which real chips do (blargg's instr_test
// checks it); cpu_test.cpp pins those three down instead.
std::vector<uint8_t> lockstep_opcodes() {
    std::vector<uint8_t> v;
    for (int op = 0; op < 256; op++) {
        bool jam = (op & 0x1F) == 0x12 || op == 0x02 || op == 0x22 || op == 0x42 || op == 0x62;
        bool unstable = op == 0x8B || op == 0xAB || op == 0x93 || op == 0x9F || op == 0x9B || op == 0xBB ||
                        op == 0x9C || op == 0x9E;
        bool and_imm = op == 0x0B || op == 0x2B || op == 0x4B || op == 0x6B;
        if (!jam && !unstable && !and_imm) v.push_back(static_cast<uint8_t>(op));
    }
    return v;
}

std::string show(const BusCycle& c) {
    std::ostringstream s;
    s << std::hex << (c.write ? "W " : "R ") << c.addr << "=" << unsigned(c.data);
    return s.str();
}

struct Totals {
    uint64_t cycles = 0, runs = 0, irqs = 0, nmis = 0;
};

// One run from a fresh reset; returns an empty string, or what diverged.
// `program`, if given, replaces the random code after the prologue's JMP.
std::string run(unsigned seed, uint64_t max_cycles, Totals& totals, const std::vector<uint8_t>* program = nullptr) {
    static const auto ops = lockstep_opcodes();
    static const std::vector<bool> ok = [] {
        std::vector<bool> v(256);
        for (uint8_t op : lockstep_opcodes()) v[op] = true;
        return v;
    }();
    std::mt19937 rng(seed);
    CpuBench mine;
    for (auto& b : mine.ram) b = ops[rng() % ops.size()];

    // A prologue that sets every register and flag, so both CPUs agree from the
    // start whatever their power-up state: LDX #s; TXS; LDA #0; PHA; PLP;
    // LDA #a; LDX #x; LDY #y; JMP random.
    constexpr uint16_t kStart = 0xF000;
    uint8_t pro[] = {0xA2, static_cast<uint8_t>(rng()), 0x9A, 0xA9, 0x00, 0x48, 0x28,
                     0xA9, static_cast<uint8_t>(rng()), 0xA2, static_cast<uint8_t>(rng()),
                     0xA0, static_cast<uint8_t>(rng()), 0x4C, static_cast<uint8_t>(rng()),
                     static_cast<uint8_t>(rng() % 0xF0)};
    if (program) {
        // Straight-line code at $0400, entered by the prologue's JMP, ending in JMP *.
        pro[14] = 0x00;
        pro[15] = 0x04;
        uint16_t at = 0x0400;
        for (uint8_t byte : *program) mine.ram[at++] = byte;
        mine.ram[at] = 0x4C;
        mine.ram[at + 1] = static_cast<uint8_t>(at);
        mine.ram[at + 2] = static_cast<uint8_t>(at >> 8);
    }
    for (size_t i = 0; i < sizeof pro; i++) mine.ram[kStart + i] = pro[i];
    mine.ram[0xFFFC] = kStart & 0xFF;
    mine.ram[0xFFFD] = kStart >> 8;
    std::copy(mine.ram.begin(), mine.ram.end(), memory);

    Perfect6502 ref;
    if (!mine.run_to(kStart, 20)) return "cpu_6502 didn't reach the reset vector";
    int guard = 0;
    for (;;) {
        auto c = ref.cycle(true, true, true);
        if (!c.write && c.addr == kStart) break;
        if (++guard > 50) return "perfect6502 didn't reach the reset vector";
    }
    // perfect6502 has fetched the first opcode; catch cpu_6502 up by that cycle.
    auto first = mine.cycle();
    if (first.addr != kStart) return "first fetch differs";

    // Pin levels for each cycle as perfect6502 sees them. cpu_6502 samples its
    // inputs at the clock edge before the cycle they apply to, so it gets each
    // level a cycle ahead.
    struct Pins {
        bool irq_n = true, nmi_n = true, rdy = true;
    };
    Pins now, next;
    int nmi_low = 0;
    uint64_t prologue = 40;  // no interrupts until the prologue is done
    std::deque<std::string> recent;
    // RS_LOCKSTEP_HISTORY: how many cycles to show before a divergence.
    size_t history = 24;
    if (const char* env = std::getenv("RS_LOCKSTEP_HISTORY")) history = std::strtoull(env, nullptr, 10);
    auto advance = [&](uint64_t i) {
        Pins p = next;
        if (i > prologue && !program) {
            if (rng() % 500 == 0) {
                p.irq_n = !p.irq_n;
                if (!p.irq_n) totals.irqs++;
            }
            if (nmi_low > 0 && --nmi_low == 0) p.nmi_n = true;
            if (p.nmi_n && rng() % 2000 == 0) {
                p.nmi_n = false;
                nmi_low = 1 + static_cast<int>(rng() % 10);
                totals.nmis++;
            }
        }
        return p;
    };
    next = advance(0);

    for (uint64_t i = 0; i < max_cycles; i++) {
        if (mine.at_fetch() && !ok[mine.ram[mine.regs().pc]] && !mine.halted()) break;
        now = next;
        next = advance(i + 1);
        mine.irq_n = next.irq_n;
        mine.nmi_n = next.nmi_n;
        mine.rdy = next.rdy;
        auto a = mine.cycle();
        auto b = ref.cycle(now.irq_n, now.nmi_n, now.rdy);
        bool irq_n = now.irq_n, nmi_n = now.nmi_n, rdy = now.rdy;
        totals.cycles++;
        std::ostringstream line;
        line << "cycle " << i << ": cpu_6502 " << show(a) << ", perfect6502 " << show(b) << " (irq " << irq_n
             << " nmi " << nmi_n << " rdy " << rdy << ")";
        if (a.sync) {
            auto r = mine.regs();
            line << std::hex << "  [A " << unsigned(r.a) << " X " << unsigned(r.x) << " Y " << unsigned(r.y) << " S "
                 << unsigned(r.s) << " P " << unsigned(r.p) << "]";
        }
        recent.push_back(line.str());
        if (recent.size() > history) recent.pop_front();
        if (a.addr != b.addr || a.write != b.write || a.data != b.data) {
            std::string out = "seed " + std::to_string(seed) + " diverged:\n";
            for (auto& l : recent) out += "  " + l + "\n";
            return out;
        }
    }
    totals.runs++;
    return "";
}

} // namespace

TEST_CASE("6502 matches perfect6502 cycle for cycle on random code with interrupts") {
    // RS_LOCKSTEP_CYCLES sets the total; the default keeps ctest under a minute.
    uint64_t budget = 400'000;
    if (const char* env = std::getenv("RS_LOCKSTEP_CYCLES")) budget = std::strtoull(env, nullptr, 10);
    Totals totals;
    for (unsigned seed = 1; totals.cycles < budget; seed++) {
        auto err = run(seed, 20'000, totals);
        INFO(err);
        REQUIRE(err.empty());
    }
    INFO(totals.runs << " runs, " << totals.cycles << " cycles, " << totals.irqs << " IRQs, " << totals.nmis << " NMIs");
    REQUIRE(totals.irqs > 0);
    REQUIRE(totals.nmis > 0);
}

TEST_CASE("6502 decimal ADC and SBC match perfect6502, invalid BCD digits included") {
    // Per case: SED or CLD; SEC or CLC; LDA #a; ADC or SBC #b; PHP; STA $10.
    // The pushed flags and the stored result are bus writes, so lockstep
    // compares them.
    std::mt19937 rng(42);
    std::vector<uint8_t> prog;
    for (int i = 0; i < 1500; i++) {
        prog.push_back(rng() % 8 ? 0xF8 : 0xD8);
        prog.push_back(rng() % 2 ? 0x38 : 0x18);
        prog.insert(prog.end(), {0xA9, static_cast<uint8_t>(rng()), static_cast<uint8_t>(rng() % 2 ? 0x69 : 0xE9),
                                 static_cast<uint8_t>(rng()), 0x08, 0x85, 0x10});
    }
    Totals totals;
    auto err = run(1, 1500 * 20, totals, &prog);
    INFO(err);
    REQUIRE(err.empty());
    REQUIRE(totals.cycles > 1500 * 14);
}
