// SPDX-License-Identifier: Apache-2.0
#include "rig/nes.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>

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

uint32_t frame_crc(const Frame& f) {
    Crc32 c;
    for (uint16_t p : f) {
        uint8_t b[2] = {static_cast<uint8_t>(p), static_cast<uint8_t>(p >> 8)};
        c.update(b);
    }
    return c.value();
}

void Console::hold_reset() { put32(kCtrl, 2, 1); }

std::optional<std::string> Console::load(const NesRom& rom) {
    if (rom.mapper != 0) return "mapper " + std::to_string(rom.mapper) + " isn't supported yet";
    if (rom.prg.size() != 16384 && rom.prg.size() != 32768)
        return "NROM needs 16 or 32 KB of PRG, not " + std::to_string(rom.prg.size());
    if (!rom.chr.empty() && rom.chr.size() != 8192)
        return "NROM needs 8 KB of CHR, not " + std::to_string(rom.chr.size());
    if (rom.mirroring == NesRom::Mirroring::kFourScreen) return "four-screen mirroring isn't supported";
    c_.write(kSdram, rom.prg);
    Crc32 want;
    want.update(rom.prg);
    uint32_t got = c_.crc(kSdram, static_cast<uint32_t>(rom.prg.size()));
    if (got != want.value())
        return "uploaded PRG has CRC " + hex(got, 8) + ", expected " + hex(want.value(), 8);
    put32(kPrgMask, static_cast<uint32_t>(rom.prg.size() - 1), 3);  // 16 KB mirrors into both halves

    bool chr_ram = rom.chr.empty();
    put32(kCart, (rom.mirroring == NesRom::Mirroring::kVertical ? 1 : 0) | (chr_ram ? 2 : 0), 1);
    std::vector<uint8_t> zeros(8192, 0);
    const std::vector<uint8_t>& chr = chr_ram ? zeros : rom.chr;
    c_.write(kPpu, chr);
    if (c_.crc(kPpu, 8192) != [&] { Crc32 c; c.update(chr); return c.value(); }())
        return "uploaded CHR doesn't read back";
    // Power-up memory, all zeros: nametables, RAM, PRG RAM and OAM.
    c_.write(kPpu + 0x2000, std::vector<uint8_t>(0x1000, 0));
    c_.write(kCpu + 0x0000, std::vector<uint8_t>(0x800, 0));
    c_.write(kCpu + 0x6000, zeros);
    c_.write(kPpuState, std::vector<uint8_t>(256, 0));  // state words 0-63
    return std::nullopt;
}

void Console::set_vector(std::optional<uint16_t> pc) {
    if (pc) put32(kVector, *pc, 2);
    put32(kVectorEn, pc ? 1 : 0, 1);
}

void Console::stop_at(uint32_t cycles) { put32(kStopAt, cycles); }
void Console::stop_frame(uint32_t frames) { put32(kStopFrame, frames); }
void Console::run() { put32(kCtrl, 1, 1); }
uint8_t Console::status() { return c_.peek(kRegs + kStatus, 1)[0]; }
uint32_t Console::cycles() { return get32(kCycles); }
uint32_t Console::frames() { return get32(kFrames); }
uint32_t Console::trace_crc() { return get32(kTraceCrc); }
std::vector<uint8_t> Console::peek(uint16_t addr, uint16_t count) { return c_.peek(kCpu + addr, count); }

std::optional<std::pair<uint32_t, uint32_t>> Console::frame_crc() {
    if (!(status() & kCrcValid)) return std::nullopt;
    return std::pair{get32(kFrameCrc), get32(kCrcFrame)};
}

std::vector<uint32_t> Console::line_crcs() {
    auto b = c_.read(kLineCrcs, kHeight * 4);
    std::vector<uint32_t> out(kHeight);
    for (int y = 0; y < kHeight; y++)
        out[y] = b[4 * y] | b[4 * y + 1] << 8 | b[4 * y + 2] << 16 | static_cast<uint32_t>(b[4 * y + 3]) << 24;
    return out;
}

Frame Console::capture(uint32_t index) {
    Frame f(kWidth * kHeight);
    put32(kCapFrame, index);
    put32(kCapLine, 0, 1);
    put32(kCapEn, 1, 1);
    stop_frame(index + 1);
    for (int y = 0; y < kHeight; y++) {
        put32(kCapLine, static_cast<uint32_t>(y), 1);
        int waits = 0;
        while (!(status() & kCapHeld))
            if (++waits > 1000) throw RigError("the capture of line " + std::to_string(y) + " never arrived");
        auto b = c_.read(kCapture, kWidth * 2);
        for (int x = 0; x < kWidth; x++) f[y * kWidth + x] = static_cast<uint16_t>(b[2 * x] | b[2 * x + 1] << 8);
    }
    put32(kCapEn, 0, 1);
    return f;
}

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

TestResult rom_test(Link& link, const RomCheck& check, const NesRom& rom, uint32_t frames,
                    std::optional<uint32_t> build_id) {
    TestResult r;
    r.name = check.id;
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
        r.bytes = rom.prg.size() + rom.chr.size();
        nes.set_vector(std::nullopt);
        nes.stop_frame(frames);
        nes.run();

        uint8_t st = 0;
        uint32_t last = 0;
        int still = 0;
        for (;;) {
            st = nes.status();
            if (st & (kStopped | kHalted)) break;
            uint32_t now = nes.cycles();
            still = now == last ? still + 1 : 0;
            last = now;
            if (still > 50) return finish("the CPU stopped counting cycles at " + std::to_string(now));
        }
        auto crc = nes.frame_crc();
        if (crc) r.crc32 = crc->first;
        r.notes = std::to_string(nes.frames()) + " frames, " + std::to_string(nes.cycles()) + " CPU cycles";
        std::optional<std::string> fail;
        if (check.kind == RomCheck::kBlargg) {
            // Status at $6000, DE B0 61 once it's valid, a text report from $6004.
            auto head = nes.peek(0x6000, 4);
            auto text = nes.peek(0x6004, 1024);
            std::string report;
            for (uint8_t c : text) {
                if (c == 0) break;
                report += c == '\n' ? ' ' : static_cast<char>(c);
            }
            while (!report.empty() && report.back() == ' ') report.pop_back();
            if (!report.empty()) r.notes += "; " + report;
            bool valid = head[1] == 0xDE && head[2] == 0xB0 && head[3] == 0x61;
            if (!valid || head[0] >= 0x80) fail = "no result by frame " + std::to_string(frames);
            else if (head[0] != 0) fail = "the ROM reports error " + std::to_string(head[0]);
        } else if (check.kind == RomCheck::kZeroPage) {
            uint8_t v = nes.peek(check.result, 1)[0];
            r.notes += "; result " + std::to_string(v);
            if (v == 0) fail = "no result by frame " + std::to_string(frames);
            else if (v != 1) fail = "the ROM reports error " + std::to_string(v);
        }
        if (st & kLate) return finish("a PRG read missed its CPU cycle (status " + hex(st, 2) + ")");
        if (st & kHalted) return finish("the CPU halted at cycle " + std::to_string(nes.cycles()));
        if (!crc || crc->second != frames - 1)
            return finish("no CRC for frame " + std::to_string(frames - 1));
        return finish(fail.value_or(""));
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

std::vector<GoldenRom> load_golden_roms(const std::string& file) {
    std::vector<GoldenRom> out;
    std::ifstream f(file);
    if (!f) throw RigError("can't read " + file);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        GoldenRom g;
        std::string crc, kind, result;
        ss >> g.check.id >> g.frames >> crc >> kind >> result >> g.path;
        if (!ss) throw RigError("bad line in " + file + ": " + line);
        g.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        g.check.kind = kind == "zeropage" ? RomCheck::kZeroPage : kind == "frame" ? RomCheck::kFrame : RomCheck::kBlargg;
        if (g.check.kind == RomCheck::kZeroPage) g.check.result = static_cast<uint16_t>(std::stoul(result, nullptr, 16));
        out.push_back(std::move(g));
    }
    return out;
}

} // namespace rig::nes
