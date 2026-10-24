// SPDX-License-Identifier: Apache-2.0
// The CPU against test ROMs from testroms/manifest.toml. Skipped when the ROMs
// haven't been fetched (testroms/fetch.py).
#include <catch2/catch_test_macros.hpp>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>

#include "nes_bench.hpp"

namespace {

std::string rom(const std::string& path) { return std::string(RS_TESTROMS) + "/nes-test-roms/" + path; }

void require_rom(const std::string& path) {
    if (!std::filesystem::exists(path)) SKIP(path << " not found: run testroms/fetch.py");
}

constexpr uint64_t kCyclesPerFrame = 29781;

// One line of nestest.log: PC, then A X Y P SP and the cycle count.
struct TraceLine {
    unsigned pc = 0, a = 0, x = 0, y = 0, p = 0, sp = 0;
    unsigned long cyc = 0;
};

bool parse(const std::string& line, TraceLine& t) {
    if (std::sscanf(line.c_str(), "%4x", &t.pc) != 1) return false;
    auto field = [&](const char* key, auto& out, const char* fmt) {
        auto at = line.find(key);
        return at != std::string::npos && std::sscanf(line.c_str() + at + std::strlen(key), fmt, &out) == 1;
    };
    return field("A:", t.a, "%2x") && field("X:", t.x, "%2x") && field("Y:", t.y, "%2x") &&
           field("P:", t.p, "%2x") && field("SP:", t.sp, "%2x") && field("CYC:", t.cyc, "%lu");
}

} // namespace

TEST_CASE("6502 matches nestest.log instruction by instruction, cycle counts included") {
    auto nes = rom("other/nestest.nes"), log = rom("other/nestest.log");
    require_rom(nes);
    require_rom(log);
    NesBench b;
    REQUIRE_FALSE(b.load(nes).has_value());
    // nestest's automated mode starts at $C000: point the reset vector there.
    // (The reset sequence runs on the first cycles, so it reads this.)
    auto read = b.read;
    b.read = [read](uint16_t a) -> uint8_t {
        if (a == 0xFFFC) return 0x00;
        if (a == 0xFFFD) return 0xC0;
        return read(a);
    };

    std::ifstream f(log);
    std::string line;
    int n = 0;
    while (std::getline(f, line)) {
        TraceLine want;
        REQUIRE(parse(line, want));
        REQUIRE(b.run_to(static_cast<uint16_t>(want.pc), 100));
        auto r = b.regs();
        INFO("line " << n + 1 << ": " << line);
        REQUIRE(r.pc == want.pc);
        REQUIRE(r.a == want.a);
        REQUIRE(r.x == want.x);
        REQUIRE(r.y == want.y);
        REQUIRE(r.p == want.p);
        REQUIRE(r.s == want.sp);
        REQUIRE(b.cycles == want.cyc);
        b.cycle();
        n++;
    }
    REQUIRE(n > 8900);
    // nestest leaves its error codes at $02 (official opcodes) and $03 (unofficial).
    REQUIRE(b.peek(0x02) == 0);
    REQUIRE(b.peek(0x03) == 0);
}

TEST_CASE("6502 passes blargg's instr_test official_only") {
    auto path = rom("instr_test-v5/official_only.nes");
    require_rom(path);
    NesBench run;
    REQUIRE_FALSE(run.load(path).has_value());
    std::optional<uint8_t> result;
    for (uint64_t frame = 0; frame < 3000 && !result && !run.halted(); frame++) {
        for (uint64_t i = 0; i < kCyclesPerFrame; i++) run.cycle();
        result = run.blargg_result();
    }
    INFO(run.blargg_text());
    REQUIRE_FALSE(run.halted());
    REQUIRE(result.has_value());
    REQUIRE(*result == 0);
}
