// SPDX-License-Identifier: Apache-2.0
// SingleStepTests' SM83 cases (github.com/SingleStepTests/sm83, fetched into
// $RS_TESTROMS/sm83 by testroms/fetch.py): 1,000 for each of the 500 opcodes,
// CB-prefixed ones included. Each gives the registers and memory before one
// instruction and after it, and every M-cycle's bus access in between,
// starting with the opcode's fetch. The registers go in through the
// save-state port; then each M-cycle must make the access listed (address
// and data for reads and writes; internal cycles must make none: the tests
// give no real address for them), the instruction must end after the last
// one, and the registers, IME and memory must match.
//
// HALT and STOP: the tests run 2 more M-cycles after the fetch, from the
// emulator they were made with; here only the fetch is compared, and the
// registers after it (cpu_test.cpp checks what each then does).
#include <catch2/catch_test_macros.hpp>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "json.hpp"
#include "sm83_bench.hpp"

namespace {

std::string hex(int64_t v, int w) {
    char b[16];
    std::snprintf(b, sizeof b, "%0*llX", w, static_cast<long long>(v));
    return b;
}

// Runs one case; returns "" if it passes, else what differed.
std::string run_case(const json::Value& t) {
    const auto& in = t["initial"];
    const auto& out = t["final"];
    Sm83Bench b;
    for (const auto& kv : in["ram"].arr) b.ram[kv[0].i()] = static_cast<uint8_t>(kv[1].i());
    auto r16 = [](const json::Value& s, const char* hi, const char* lo) {
        return static_cast<uint16_t>(s[hi].i() << 8 | s[lo].i());
    };
    Sm83Regs r{static_cast<uint16_t>(in["pc"].i()), static_cast<uint16_t>(in["sp"].i()), r16(in, "a", "f"),
               r16(in, "b", "c"), r16(in, "d", "e"), r16(in, "h", "l"), in["ime"].i() != 0, false};
    b.set_regs(r, static_cast<uint8_t>(in["f"].i()));
    auto got = b.regs();
    if (got.pc != r.pc || got.sp != r.sp || got.af != (r.af & 0xFFF0) || got.bc != r.bc || got.de != r.de ||
        got.hl != r.hl)
        return "registers didn't load through the save-state port";

    const auto& cycles = t["cycles"].arr;
    size_t n = cycles.size();
    int op = static_cast<int>(b.ram[r.pc]);
    if (op == 0x76 || op == 0x10) n = 1;
    std::ostringstream err;
    for (size_t i = 0; i < n; i++) {
        const auto& c = cycles[i];
        char want = c[2].str == "r-m" ? 'r' : c[2].str == "-wm" ? 'w' : '-';
        if (i > 0 && b.boundary()) {
            err << "ended after " << i << " M-cycles, not " << n;
            return err.str();
        }
        MCycle m = b.cycle();
        bool ok = m.kind == want;
        if (ok && want != '-') ok = m.addr == c[0].i() && m.data == c[1].i();
        if (!ok) {
            err << "M-cycle " << i << ": " << m.kind << " $" << hex(m.addr, 4) << " $" << hex(m.data, 2)
                << ", expected " << want << " $" << hex(c[0].i(), 4) << " $"
                << (c[1].kind == json::Value::Null ? std::string("--") : hex(c[1].i(), 2));
            return err.str();
        }
    }
    if (!b.boundary()) {
        err << "still running after " << n << " M-cycles";
        return err.str();
    }
    got = b.regs();
    Sm83Regs want{static_cast<uint16_t>(out["pc"].i()), static_cast<uint16_t>(out["sp"].i()), r16(out, "a", "f"),
                  r16(out, "b", "c"), r16(out, "d", "e"), r16(out, "h", "l"), out["ime"].i() != 0,
                  out.has("ei") && out["ei"].i() != 0};
    auto cmp = [&](const char* name, int64_t g, int64_t w, int digits) {
        if (g != w) err << " " << name << " $" << hex(g, digits) << " (expected $" << hex(w, digits) << ")";
    };
    cmp("PC", got.pc, want.pc, 4);
    cmp("SP", got.sp, want.sp, 4);
    cmp("AF", got.af, want.af, 4);
    cmp("BC", got.bc, want.bc, 4);
    cmp("DE", got.de, want.de, 4);
    cmp("HL", got.hl, want.hl, 4);
    cmp("IME", got.ime, want.ime, 1);
    cmp("EI", got.ei, want.ei, 1);
    for (const auto& kv : out["ram"].arr)
        if (b.ram[kv[0].i()] != kv[1].i())
            err << " [$" << hex(kv[0].i(), 4) << "] $" << hex(b.ram[kv[0].i()], 2) << " (expected $"
                << hex(kv[1].i(), 2) << ")";
    return err.str();
}

} // namespace

TEST_CASE("SM83 passes SingleStepTests' 500,000 cases") {
    std::filesystem::path dir = std::filesystem::path(RS_TESTROMS) / "sm83" / "v1";
    if (!std::filesystem::exists(dir)) SKIP(dir.string() << " not found: run testroms/fetch.py");
    std::vector<std::filesystem::path> files;
    for (const auto& e : std::filesystem::directory_iterator(dir))
        if (e.path().extension() == ".json") files.push_back(e.path());
    std::sort(files.begin(), files.end());
    REQUIRE(files.size() == 500);

    size_t cases = 0, failed = 0, failed_ops = 0;
    std::string report;
    for (const auto& f : files) {
        std::ifstream in(f);
        std::stringstream ss;
        ss << in.rdbuf();
        json::Value tests = json::parse(ss.str());
        size_t bad = 0;
        std::string first;
        for (const auto& t : tests.arr) {
            cases++;
            std::string e = run_case(t);
            if (!e.empty()) {
                if (bad++ == 0) first = t["name"].str + ": " + e;
            }
        }
        if (bad) {
            failed += bad;
            failed_ops++;
            report += "\n  " + f.filename().string() + ": " + std::to_string(bad) + " of " +
                      std::to_string(tests.arr.size()) + " fail; first " + first;
        }
    }
    INFO(cases << " cases, " << failed << " failing in " << failed_ops << " opcodes" << report);
    CHECK(cases == 500000);
    CHECK(failed == 0);
}
