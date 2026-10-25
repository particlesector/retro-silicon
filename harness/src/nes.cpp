// SPDX-License-Identifier: Apache-2.0
#include "rig/nes.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>

#include "rig/crc32.hpp"

namespace rig::nes {

namespace {

std::string hex(uint32_t x, int digits) {
    char s[16];
    std::snprintf(s, sizeof s, "0x%0*x", digits, x);
    return s;
}

} // namespace

void Console::put32(uint32_t reg, uint32_t v, int bytes) {
    std::vector<uint8_t> b;
    for (int i = 0; i < bytes; i++) b.push_back(static_cast<uint8_t>(v >> (8 * i)));
    c_.poke(kRegs + reg, b);
}

uint32_t Console::get32(uint32_t reg) {
    auto b = c_.peek(kRegs + reg, 4);
    return b[0] | b[1] << 8 | b[2] << 16 | static_cast<uint32_t>(b[3]) << 24;
}

void Console::hold_reset() { put32(kCtrl, 2, 1); }

std::optional<std::string> Console::load(const NesRom& rom) {
    if (rom.mapper != 0) return "mapper " + std::to_string(rom.mapper) + " isn't supported yet";
    if (rom.prg.size() != 16384 && rom.prg.size() != 32768)
        return "NROM needs 16 or 32 KB of PRG, not " + std::to_string(rom.prg.size());
    c_.write(kSdram, rom.prg);
    Crc32 want;
    want.update(rom.prg);
    uint32_t got = c_.crc(kSdram, static_cast<uint32_t>(rom.prg.size()));
    if (got != want.value())
        return "uploaded PRG has CRC " + hex(got, 8) + ", expected " + hex(want.value(), 8);
    put32(kPrgMask, static_cast<uint32_t>(rom.prg.size() - 1), 3);  // 16 KB mirrors into both halves
    return std::nullopt;
}

void Console::set_vector(std::optional<uint16_t> pc) {
    if (pc) put32(kVector, *pc, 2);
    put32(kVectorEn, pc ? 1 : 0, 1);
}

void Console::stop_at(uint32_t cycles) { put32(kStopAt, cycles); }
void Console::run() { put32(kCtrl, 1, 1); }
uint8_t Console::status() { return c_.peek(kRegs + kStatus, 1)[0]; }
uint32_t Console::cycles() { return get32(kCycles); }
uint32_t Console::trace_crc() { return get32(kTraceCrc); }
std::vector<uint8_t> Console::peek(uint16_t addr, uint16_t count) { return c_.peek(kCpu + addr, count); }

TestResult nestest(Link& link, const NesRom& rom, uint32_t cycles, std::optional<uint32_t> build_id) {
    TestResult r;
    r.name = "nestest";
    auto t0 = std::chrono::steady_clock::now();
    shell::Client client(link);
    Console nes(client);

    auto finish = [&](std::string detail) {
        r.passed = detail.empty();
        r.detail = std::move(detail);
        r.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        if (!r.notes.empty()) r.notes += "; ";
        r.notes += std::to_string(client.stats.commands) + " commands in " + std::to_string(client.stats.attempts) +
                   " attempts";
        return r;
    };

    try {
        auto info = client.info();
        if (info.version != shell::kVersion)
            return finish("shell protocol version " + std::to_string(info.version) + ", expected " +
                          std::to_string(shell::kVersion));
        if (build_id && info.build_id != *build_id)
            return finish("build ID " + hex(info.build_id, 8) + ", expected " + hex(*build_id, 8) +
                          ": the wrong bitstream is loaded");

        nes.hold_reset();
        if (auto e = nes.load(rom)) return finish(*e);
        r.bytes = rom.prg.size();  // uploaded and checked
        // A pattern in PRG RAM, which nestest doesn't use, to read back while it runs.
        std::vector<uint8_t> pattern(16);
        for (size_t i = 0; i < pattern.size(); i++) pattern[i] = static_cast<uint8_t>(0x5A ^ (i * 37));
        client.poke(kCpu + 0x7FF0, pattern);
        nes.set_vector(0xC000);  // the automated mode
        nes.stop_at(cycles);
        nes.run();

        // Poll until it stops, reading RAM and SDRAM in between: the CPU's
        // timing, and so its trace, mustn't depend on what the shell does, and
        // the shell must read the right bytes while the CPU runs.
        uint8_t st = 0;
        uint32_t last = 0;
        int still = 0;
        for (;;) {
            st = nes.status();
            if (st & (kStopped | kHalted)) break;
            nes.peek(0x0000, 16);
            if (nes.peek(0x7FF0, 16) != pattern) return finish("PRG RAM read wrong while the CPU ran");
            auto prg = client.peek(kSdram + 0x3FF0, 16);
            if (!std::equal(prg.begin(), prg.end(), rom.prg.begin() + 0x3FF0))
                return finish("SDRAM read wrong while the CPU ran");
            uint32_t now = nes.cycles();
            still = now == last ? still + 1 : 0;
            last = now;
            if (still > 50) return finish("the CPU stopped counting cycles at " + std::to_string(now));
        }
        uint32_t ran = nes.cycles();
        r.crc32 = nes.trace_crc();
        auto codes = nes.peek(0x0002, 2);
        r.notes = std::to_string(ran) + " CPU cycles; $02=" + hex(codes[0], 2) + " $03=" + hex(codes[1], 2);
        if (st & kLate) return finish("a PRG read missed its CPU cycle (status " + hex(st, 2) + ")");
        if (st & kHalted) return finish("the CPU halted at cycle " + std::to_string(ran));
        if (ran != cycles) return finish("stopped after " + std::to_string(ran) + " cycles, not " + std::to_string(cycles));
        if (codes[0] != 0 || codes[1] != 0) return finish("nestest reports errors");
        return finish("");
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

} // namespace rig::nes
