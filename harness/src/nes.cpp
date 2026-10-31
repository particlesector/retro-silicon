// SPDX-License-Identifier: Apache-2.0
#include "rig/nes.hpp"

#include <algorithm>
#include <chrono>
#include <iterator>
#include <map>
#include <cstdio>
#include <fstream>
#include <sstream>

#include "rig/crc32.hpp"

namespace rig::nes {

namespace {

// The memory cache's counts, for a result's notes; nothing without a cache.
std::string cache_note(Console& nes) {
    auto c = nes.cache_stats();
    if (c.hits + c.misses == 0) return "";
    return "; cache " + std::to_string(c.hits) + " hits, " + std::to_string(c.misses) + " misses, " +
           std::to_string(c.prefetches) + " prefetches";
}

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

namespace {

bool pow2(size_t n) { return n && !(n & (n - 1)); }

// The PRG RAM the cartridge has: what a NES 2.0 header says, or 8 KB, as
// MesenCE gives a ROM whose iNES 1.0 header can't say.
size_t prg_ram_size(const NesRom& rom) { return rom.nes2 ? rom.prg_ram + rom.prg_nvram : 8192; }

// PRG ROM as the board's memory holds it. MesenCE takes a bank number modulo
// the ROM's bank count, which for a size that isn't a power of 2 a mask can't
// do: so an MMC1 ROM of such a size (blargg's 80 KB ones) goes in as 256 KB,
// all MMC1's 16 KB banks, bank b a copy of bank b mod count. MMC1 never asks
// for a bank counted from the end, as the other mappers' fixed banks do.
std::vector<uint8_t> prg_image(const NesRom& rom) {
    size_t n = rom.prg.size();
    if (!(n & (n - 1))) return rom.prg;
    std::vector<uint8_t> img(256 * 1024);
    for (size_t a = 0; a < img.size(); a++) img[a] = rom.prg[(a / 16384) % (n / 16384) * 16384 + a % 16384];
    return img;
}

} // namespace

std::optional<std::string> Console::unsupported(const NesRom& rom) {
    static const unsigned kMappers[] = {0, 1, 2, 3, 4, 7};
    if (std::find(std::begin(kMappers), std::end(kMappers), rom.mapper) == std::end(kMappers))
        return "mapper " + std::to_string(rom.mapper) + " isn't supported";
    if (rom.mirroring == NesRom::Mirroring::kFourScreen) return "four-screen mirroring isn't supported";
    if (rom.prg.size() < 16384 || rom.prg.size() % 16384 ||
        (!pow2(rom.prg.size()) && (rom.mapper != 1 || rom.prg.size() > 256 * 1024)))
        return "PRG ROM must be a power of 2 from 16 KB (or for MMC1, 16 KB banks up to 256 KB), not " +
               std::to_string(rom.prg.size()) + " bytes";
    if (rom.mapper == 0 && rom.prg.size() > 32768) return "NROM has 16 or 32 KB of PRG ROM";
    if (!rom.chr.empty() && (!pow2(rom.chr.size()) || rom.chr.size() < 8192))
        return "CHR ROM must be a power of 2 from 8 KB, not " + std::to_string(rom.chr.size()) + " bytes";
    if (rom.chr.empty() && rom.chr_ram > 8192) return "CHR RAM over 8 KB isn't supported";
    if (prg_ram_size(rom) > 8192) return "PRG RAM over 8 KB isn't supported";
    size_t mem = size_t{1} << c_.peek(kRegs + kMemBits, 1)[0];
    size_t chr = size_t{1} << c_.peek(kRegs + kChrBits, 1)[0];
    bool ext = rom.chr.size() > chr && chr_ext();
    size_t prg = prg_image(rom).size();
    if (prg > (ext ? std::min(mem, kChrExtBase) : mem))
        return std::to_string(prg / 1024) + " KB of PRG ROM doesn't fit this board's " +
               std::to_string(mem / 1024) + " KB";
    if (rom.chr.size() > (ext ? kChrExtMax : chr))
        return std::to_string(rom.chr.size() / 1024) + " KB of CHR ROM doesn't fit this board's " +
               std::to_string(chr / 1024) + " KB";
    return std::nullopt;
}

bool Console::chr_ext() { return c_.peek(kRegs + kChrExt, 1)[0] & 1; }

size_t chr_ext_offset(size_t a) {
    return (a & ~size_t{0xF}) | (a & 7) << 1 | (a >> 3 & 1);
}

std::optional<uint8_t> lead_dots_for(int ppu_offset, int cpu_offset) {
    // The default, PPU 1 and CPU 0, is 5 dots; each 4 master clocks more of
    // CPU offset than PPU is a dot later.
    int d = cpu_offset - ppu_offset + 1;
    if (d < 0 || d % 4 != 0 || d / 4 > 2) return std::nullopt;
    return static_cast<uint8_t>(5 + d / 4);
}

namespace {

// The bytes a memory powers up with.
std::vector<uint8_t> power_up_fill(const PowerUp& p, size_t n, uint32_t salt) {
    std::vector<uint8_t> v(n, p.fill == PowerUp::kOnes ? 0xFF : 0x00);
    if (p.fill == PowerUp::kRandom) {
        uint32_t x = p.seed * 2654435761u ^ salt;  // xorshift32, a stream for each memory
        for (auto& b : v) {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            if (x == 0) x = 1;
            b = static_cast<uint8_t>(x >> 24);
        }
    }
    return v;
}

} // namespace

std::optional<std::string> Console::load(const NesRom& rom, bool want_ext) {
    if (auto e = unsupported(rom)) return e;
    // Whatever ran before may have left limits, the vector override or a
    // capture set: start from none.
    stop_at(0);
    stop_frame(0);
    set_vector(std::nullopt);
    put32(kCapEn, 0, 1);
    set_input_script({});
    set_live_input(0, 0);
    auto prg = prg_image(rom);
    c_.write(kSdram, prg);
    Crc32 want;
    want.update(prg);
    uint32_t got = c_.crc(kSdram, static_cast<uint32_t>(prg.size()));
    if (got != want.value())
        return "uploaded PRG has CRC " + hex(got, 8) + ", expected " + hex(want.value(), 8);
    put32(kPrgMask, static_cast<uint32_t>(prg.size() - 1), 3);  // 16 KB mirrors into both halves

    bool chr_ram = rom.chr.empty();
    // CHR ROM bigger than CHR's block RAM goes in the board's memory, interleaved.
    bool ext = !chr_ram && (rom.chr.size() > (size_t{1} << c_.peek(kRegs + kChrBits, 1)[0]) || (want_ext && chr_ext()));
    put32(kMapper, rom.mapper, 1);
    put32(kCart, (rom.mirroring == NesRom::Mirroring::kVertical ? 1 : 0) | (chr_ram ? 2 : 0) |
                     (prg_ram_size(rom) ? 4 : 0) | (ext ? 8 : 0), 1);
    std::vector<uint8_t> chr_ram_fill = power_up_fill(power_up_, 8192, 1);
    const std::vector<uint8_t>& chr = chr_ram ? chr_ram_fill : rom.chr;
    put32(kChrMask, static_cast<uint32_t>(chr.size() - 1), 3);
    if (ext) {
        std::vector<uint8_t> laid(chr.size());
        for (size_t a = 0; a < chr.size(); a++) laid[chr_ext_offset(a)] = chr[a];
        c_.write(kSdram + kChrExtBase, laid);
        Crc32 want_chr;
        want_chr.update(laid);
        if (c_.crc(kSdram + kChrExtBase, static_cast<uint32_t>(laid.size())) != want_chr.value())
            return "uploaded CHR doesn't read back";
    } else {
        c_.write(kChr, chr);
        if (c_.crc(kChr, static_cast<uint32_t>(chr.size())) != [&] { Crc32 c; c.update(chr); return c.value(); }())
            return "uploaded CHR doesn't read back";
    }
    // Power-up memory, as power_up_ says: nametables, RAM, PRG RAM and OAM.
    // Then the CPU/PPU alignment, taken as the system leaves reset.
    c_.write(kPpu + 0x2000, power_up_fill(power_up_, 0x1000, 2));
    c_.write(kCpu + 0x0000, power_up_fill(power_up_, 0x800, 3));
    c_.write(kCpu + 0x6000, power_up_fill(power_up_, 0x2000, 4));
    c_.write(kPpuState, power_up_fill(power_up_, 256, 5));  // state words 0-63
    put32(kLeadDots, power_up_.lead_dots, 1);
    return std::nullopt;
}

void Console::set_vector(std::optional<uint16_t> pc) {
    if (pc) put32(kVector, *pc, 2);
    put32(kVectorEn, pc ? 1 : 0, 1);
}

void Console::set_input_script(const std::vector<InputEntry>& script) {
    if (script.size() > 512) throw RigError("an input script holds 512 entries at most");
    put32(kInputOn, 0, 1);
    std::vector<uint8_t> bytes;
    for (auto& e : script)
        bytes.insert(bytes.end(), {e.pad1, e.pad2, static_cast<uint8_t>(e.frame), static_cast<uint8_t>(e.frame >> 8)});
    if (!bytes.empty()) c_.write(kInputScript, bytes);
    put32(kInputLen, static_cast<uint32_t>(script.size()), 2);
    put32(kInputOn, script.empty() ? 0 : 1, 1);
}

void Console::set_live_input(uint8_t pad1, uint8_t pad2) {
    put32(kLive1, pad1, 1);
    put32(kLive2, pad2, 1);
}

void Console::stop_at(uint32_t cycles) { put32(kStopAt, cycles); }
void Console::stop_frame(uint32_t frames) { put32(kStopFrame, frames); }
void Console::run() { put32(kCtrl, 1, 1); }
uint8_t Console::status() { return c_.peek(kRegs + kStatus, 1)[0]; }
uint32_t Console::cycles() { return get32(kCycles); }
uint32_t Console::frames() { return get32(kFrames); }
uint32_t Console::trace_crc() { return get32(kTraceCrc); }
uint32_t Console::audio_crc() { return get32(kAudioCrc); }

std::vector<TraceEntry> Console::trace() {
    uint32_t depth = 1u << c_.read(kRegs + kTraceBits, 1)[0];
    uint32_t count = get32(kTraceCount);
    uint32_t filled = get32(kTraceFilled) & 0xFFFF;
    // Oldest first: from ring index (count - filled) mod depth, wrapping once.
    uint32_t first = (count - filled) % depth;
    std::vector<uint8_t> raw;
    uint32_t head = std::min(filled, depth - first);
    if (head) raw = c_.read(kTrace + 4 * first, 4 * head);
    if (filled > head) {
        auto tail = c_.read(kTrace, 4 * (filled - head));
        raw.insert(raw.end(), tail.begin(), tail.end());
    }
    std::vector<TraceEntry> t(filled);
    for (uint32_t k = 0; k < filled; k++) {
        const uint8_t* e = &raw[4 * k];
        t[k] = {count - filled + k, static_cast<uint16_t>(e[0] | e[1] << 8), e[2], (e[3] & 1) != 0, (e[3] & 2) != 0};
    }
    return t;
}
uint32_t Console::mem_waits() { return get32(kMemWaits); }
Console::CacheStats Console::cache_stats() { return {get32(kCacheHits), get32(kCacheMisses), get32(kCachePrefetches)}; }
std::pair<uint32_t, uint32_t> Console::pcm() { return {get32(kPcmCrc), get32(kPcmCount)}; }
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

void Console::pace(bool on) { put32(kVideo, on ? 1 : 0, 1); }

void Console::arm_video_crc(uint32_t index) {
    put32(kVcapFrame, index);
    put32(kVideo, 3, 1);  // pacing on, and take the CRC
}

Video Console::video() {
    Video v;
    v.valid = status() & kVideoCrcValid;
    v.whole = c_.peek(kRegs + kVideoWhole, 1)[0] & 1;
    v.crc = get32(kVideoCrc);
    auto n = c_.peek(kRegs + kVideoShown, 6);
    v.shown = static_cast<uint16_t>(n[0] | n[1] << 8);
    v.late = static_cast<uint16_t>(n[2] | n[3] << 8);
    v.overrun = static_cast<uint16_t>(n[4] | n[5] << 8);
    return v;
}

uint8_t Console::wait_stopped() {
    uint32_t last = 0;
    int still = 0;
    for (;;) {
        uint8_t st = status();
        if (st & (kStopped | kHalted)) return st;
        uint32_t now = cycles();
        still = now == last ? still + 1 : 0;
        last = now;
        if (still > 50) throw RigError("the CPU stopped counting cycles at " + std::to_string(now));
    }
}

void Console::save_cmd(uint8_t op) {
    // The next sequence number: the shell may resend the write, which repeats
    // the same command, which the controller ignores.
    uint8_t prev = c_.peek(kRegs + kSaveCmd, 1)[0];
    uint8_t cmd = static_cast<uint8_t>(op << 6 | ((prev + 1) & 0x3F));
    put32(kSaveCmd, cmd, 1);
    for (int n = 0; c_.peek(kRegs + kSaveDone, 1)[0] != cmd; n++)
        if (n > 1000) throw RigError("the save-state controller never finished");
}

std::vector<uint8_t> Console::save_state() {
    if (c_.peek(kRegs + kCtrl, 1)[0] & 2) throw RigError("save_state with the system held in reset");
    save_cmd(1);
    return c_.read(kSaveBuffer, kSaveStateBytes);
}

void Console::load_state(const std::vector<uint8_t>& state) {
    if (state.size() != kSaveStateBytes)
        throw RigError("a save state is " + std::to_string(kSaveStateBytes) + " bytes, not " +
                       std::to_string(state.size()));
    put32(kCtrl, 0, 1);  // out of reset, and stopped where the state leaves it
    c_.write(kSaveBuffer, state);
    save_cmd(2);
}

std::optional<std::string> compare_nestest_log(const std::vector<TraceEntry>& trace, const std::string& log) {
    std::ifstream f(log);
    if (!f) return "can't read " + log;
    // Each instruction's cycle -> {PC, opcode}: a line starts "C000  4C F5 C5  JMP"
    // and has "CYC:7" at its end.
    std::map<uint32_t, std::pair<unsigned, unsigned>> ins;
    std::string line;
    while (std::getline(f, line)) {
        unsigned pc = 0, op = 0;
        unsigned long cyc = 0;
        auto at = line.find("CYC:");
        if (at == std::string::npos || std::sscanf(line.c_str(), "%4x %2x", &pc, &op) != 2 ||
            std::sscanf(line.c_str() + at + 4, "%lu", &cyc) != 1)
            continue;
        ins[static_cast<uint32_t>(cyc)] = {pc, op};
    }
    if (trace.empty()) return "the trace buffer is empty";
    uint32_t first = trace.front().cycle, last = trace.back().cycle;
    size_t matched = 0;
    for (const auto& e : trace) {
        auto it = ins.find(e.cycle);
        std::string at = "cycle " + std::to_string(e.cycle) + ": ";
        if (it == ins.end()) {
            if (e.sync) return at + "an opcode fetch at " + hex(e.addr, 4) + ", where nestest.log has none";
            continue;
        }
        auto [pc, op] = it->second;
        if (!e.sync || e.write || e.addr != pc || e.data != op)
            return at + "nestest.log fetches " + hex(op, 2) + " at " + hex(pc, 4) + "; the trace has " +
                   (e.write ? "a write of " : e.sync ? "a fetch of " : "a read of ") + hex(e.data, 2) + " at " +
                   hex(e.addr, 4);
        matched++;
    }
    // Every instruction in the covered cycles was in the trace (checked above), so
    // the count must match too.
    size_t want = static_cast<size_t>(std::distance(ins.lower_bound(first), ins.upper_bound(last)));
    if (matched != want || matched == 0)
        return "the trace's cycles " + std::to_string(first) + "-" + std::to_string(last) + " match " +
               std::to_string(matched) + " of nestest.log's " + std::to_string(want) + " instructions there";
    return std::nullopt;
}

TestResult nestest(Link& link, const NesRom& rom, uint32_t cycles, std::optional<uint32_t> build_id,
                   const std::string& log) {
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
        if (!log.empty()) {
            auto t = nes.trace();
            if (auto e = compare_nestest_log(t, log)) return finish("the trace buffer: " + *e);
            r.notes += "; the trace buffer's last " + std::to_string(t.size()) + " cycles match nestest.log";
        }
        return finish("");
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

TestResult rom_test(Link& link, const RomCheck& check, const NesRom& rom, uint32_t frames,
                    std::optional<uint32_t> build_id, bool chr_ext, const PowerUp& power) {
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
        nes.set_power_up(power);
        if (auto e = nes.load(rom, chr_ext)) return finish(*e);
        r.bytes = rom.prg.size() + rom.chr.size();
        nes.set_vector(std::nullopt);
        nes.set_input_script(check.input);
        nes.stop_frame(frames);
        nes.run();
        uint8_t st = nes.wait_stopped();
        auto crc = nes.frame_crc();
        if (crc) r.crc32 = crc->first;
        r.audio_crc32 = nes.audio_crc();
        r.notes = std::to_string(nes.frames()) + " frames, " + std::to_string(nes.cycles()) + " CPU cycles, " +
                  std::to_string(nes.mem_waits()) + " clocks waiting for memory" + cache_note(nes);
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

TestResult state_test(Link& link, const NesRom& rom, uint32_t save_after, uint32_t frames,
                      std::optional<uint32_t> build_id) {
    TestResult r;
    r.name = "savestate";
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

    struct End {
        uint32_t crc, trace, audio, cycles;
        std::vector<uint32_t> lines;
    };
    auto end = [&]() -> std::optional<End> {
        uint8_t st = nes.wait_stopped();
        auto crc = nes.frame_crc();
        if ((st & (kHalted | kLate)) || !crc || crc->second != frames - 1) return std::nullopt;
        return End{crc->first, nes.trace_crc(), nes.audio_crc(), nes.cycles(), nes.line_crcs()};
    };

    try {
        auto info = client.info();
        if (info.version != shell::kVersion)
            return finish("shell protocol version " + std::to_string(info.version) + ", expected " +
                          std::to_string(shell::kVersion));
        if (build_id && info.build_id != *build_id)
            return finish("build ID " + hex(info.build_id, 8) + ", expected " + hex(*build_id, 8) +
                          ": the wrong bitstream is loaded");

        // Uninterrupted.
        nes.hold_reset();
        if (auto e = nes.load(rom)) return finish(*e);
        nes.set_vector(std::nullopt);
        nes.stop_frame(frames);
        nes.run();
        auto a = end();
        if (!a) return finish("the uninterrupted run didn't reach frame " + std::to_string(frames - 1) + " cleanly");

        // Saved while running, run on, power-cycled, restored.
        nes.hold_reset();
        if (auto e = nes.load(rom)) return finish(*e);
        nes.stop_frame(0);
        nes.run();
        for (int n = 0; nes.frames() < save_after; n++)
            if (n > 100'000) return finish("never reached frame " + std::to_string(save_after));
        auto state = nes.save_state();
        uint32_t at = state[16 + 404 + 4] | state[16 + 404 + 5] << 8 | state[16 + 404 + 6] << 16 |
                      static_cast<uint32_t>(state[16 + 404 + 7]) << 24;  // the system's word 1: frames
        if (at >= frames) return finish("saved at frame " + std::to_string(at) + ", past the end");
        for (int n = 0; nes.frames() < at + 3; n++)  // run on past it
            if (n > 100'000) return finish("stopped running after the save");
        nes.hold_reset();
        if (auto e = nes.load(rom)) return finish(*e);
        nes.load_state(state);
        if (nes.frames() != at) return finish("restored to frame " + std::to_string(nes.frames()) + ", not " + std::to_string(at));
        nes.stop_frame(frames);
        nes.run();
        auto b = end();
        if (!b) return finish("the restored run didn't reach frame " + std::to_string(frames - 1) + " cleanly");

        r.crc32 = b->crc;
        r.audio_crc32 = b->audio;
        r.bytes = state.size();
        r.notes = "saved at frame " + std::to_string(at) + " of " + std::to_string(frames) + ", " +
                  std::to_string(b->cycles) + " CPU cycles; trace " + hex(b->trace, 8);
        if (b->crc != a->crc) return finish("last frame CRC " + hex(b->crc, 8) + ", uninterrupted " + hex(a->crc, 8));
        if (b->lines != a->lines) return finish("line CRCs differ from the uninterrupted run's");
        if (b->trace != a->trace) return finish("trace CRC " + hex(b->trace, 8) + ", uninterrupted " + hex(a->trace, 8));
        if (b->audio != a->audio) return finish("audio CRC " + hex(b->audio, 8) + ", uninterrupted " + hex(a->audio, 8));
        if (b->cycles != a->cycles)
            return finish(std::to_string(b->cycles) + " cycles, uninterrupted " + std::to_string(a->cycles));
        return finish("");
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

TestResult hdmi_test(Link& link, const std::string& name, const NesRom& rom, uint32_t frames,
                     std::optional<uint32_t> build_id) {
    TestResult r;
    r.name = name;
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
        Video before = nes.video();
        nes.arm_video_crc(frames - 1);
        // One frame more, so the display frame showing frame - 1 has ended
        // by the time the system stops.
        nes.stop_frame(frames + 1);
        nes.run();
        nes.wait_stopped();
        // Read on for over two display frames (a read is four peeks, about
        // 0.6 ms on the sim's link, the fastest), so a stopped system the
        // display still waits on shows up as late lines.
        Video v = nes.video();
        for (int i = 0; i < 64 || !v.valid; i++) {
            if (i >= 100 && !v.valid) break;
            v = nes.video();
        }
        r.crc32 = v.crc;
        r.notes = "shown " + std::to_string(static_cast<uint16_t>(v.shown - before.shown)) + " display frames, " +
                  std::to_string(v.late - before.late) + " lines late; " + std::to_string(nes.mem_waits()) +
                  " clocks waiting for memory" + cache_note(nes);
        if (!v.valid) return finish("no video CRC for frame " + std::to_string(frames - 1));
        if (!v.whole) return finish("the display frame showing frame " + std::to_string(frames - 1) + " wasn't whole");
        if (v.late != before.late || v.overrun != before.overrun)
            return finish(std::to_string(v.late - before.late) + " lines late, " +
                          std::to_string(v.overrun - before.overrun) + " overwritten");
        return finish("");
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
        // Optional: input=frame:pad1,frame:pad1,...
        std::string input;
        if (ss >> input) {
            if (input.rfind("input=", 0) != 0) throw RigError("bad line in " + file + ": " + line);
            std::istringstream es(input.substr(6));
            std::string e;
            while (std::getline(es, e, ',')) {
                auto colon = e.find(':');
                if (colon == std::string::npos) throw RigError("bad input entry " + e + " in " + file);
                g.check.input.push_back({static_cast<uint16_t>(std::stoul(e.substr(0, colon))),
                                         static_cast<uint8_t>(std::stoul(e.substr(colon + 1), nullptr, 0))});
            }
        }
        g.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        g.check.kind = kind == "zeropage" ? RomCheck::kZeroPage : kind == "frame" ? RomCheck::kFrame : RomCheck::kBlargg;
        if (g.check.kind == RomCheck::kZeroPage) g.check.result = static_cast<uint16_t>(std::stoul(result, nullptr, 16));
        out.push_back(std::move(g));
    }
    return out;
}

std::map<std::string, uint32_t> load_golden_audio(const std::string& file) {
    std::map<std::string, uint32_t> out;
    std::ifstream f(file);
    if (!f) throw RigError("can't read " + file);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        std::string id, crc;
        uint32_t frames;
        ss >> id >> frames >> crc;
        if (!ss) throw RigError("bad line in " + file + ": " + line);
        out[id] = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
    }
    return out;
}

} // namespace rig::nes
