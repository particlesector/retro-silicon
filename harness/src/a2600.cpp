// SPDX-License-Identifier: Apache-2.0
#include "rig/a2600.hpp"

#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>

#include "rig/crc32.hpp"

namespace rig::a2600 {

namespace {

std::string hex(uint32_t x, int digits) {
    char s[16];
    std::snprintf(s, sizeof s, "0x%0*x", digits, x);
    return s;
}

// The lines of a golden file, without comments and blank lines.
std::vector<std::string> lines(const std::string& file) {
    std::ifstream f(file);
    if (!f) throw RigError("can't read " + file);
    std::vector<std::string> out;
    std::string line;
    while (std::getline(f, line))
        if (!line.empty() && line[0] != '#') out.push_back(line);
    return out;
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

std::optional<std::string> Console::load(const std::vector<uint8_t>& rom) {
    if (rom.size() != 2048 && rom.size() != 4096)
        return "a cartridge of " + std::to_string(rom.size()) + " bytes: only 2 and 4 KB ones run yet";
    std::vector<uint8_t> image(rom);
    if (image.size() == 2048) image.insert(image.end(), rom.begin(), rom.end());
    c_.write(kCart, image);
    Crc32 want;
    want.update(image);
    uint32_t got = c_.crc(kCart, static_cast<uint32_t>(image.size()));
    if (got != want.value())
        return "the uploaded cartridge has CRC " + hex(got, 8) + ", expected " + hex(want.value(), 8);
    return std::nullopt;
}

void Console::set_paddles(const Paddles& p) {
    uint32_t on = 0, pos = 0;
    for (int i = 0; i < 4; i++)
        if (p[i] >= 0) {
            on |= 1u << i;
            pos |= static_cast<uint32_t>(p[i] & 0xFF) << (8 * i);
        }
    put32(kPaddleOn, on, 1);
    put32(kPaddlePos, pos);
}

void Console::stop_frame(uint32_t n) { put32(kStopFrame, n); }
void Console::audio_limit(uint32_t samples) { put32(kAudioLimit, samples); }
void Console::run() { put32(kCtrl, 1, 1); }
uint8_t Console::status() { return c_.peek(kRegs + kStatus, 1)[0]; }
uint32_t Console::frames() { return get32(kFrames); }
uint32_t Console::cycles() { return get32(kCycles); }
uint32_t Console::audio_crc() { return get32(kAudioCrc); }
uint32_t Console::samples() { return get32(kSamples); }

std::optional<std::pair<uint32_t, uint32_t>> Console::frame_crc() {
    auto b = c_.peek(kRegs + kFrameCrc, 8);
    uint32_t crc = b[0] | b[1] << 8 | b[2] << 16 | static_cast<uint32_t>(b[3]) << 24;
    uint32_t n = b[4] | b[5] << 8 | b[6] << 16 | static_cast<uint32_t>(b[7]) << 24;
    if (n == 0) return std::nullopt;
    return std::make_pair(crc, n);
}

void Console::wait_stopped() {
    uint32_t last = 0;
    int still = 0;
    for (;;) {
        uint8_t st = status();
        if (st & kStopped) {
            // The CRC of the frame it stopped on comes about 9,000 clocks after the frame ends.
            uint32_t n = frames();
            for (int i = 0; i < 100; i++) {
                auto c = frame_crc();
                if (n == 0 || (c && c->second == n)) return;
            }
            throw RigError("no CRC for frame " + std::to_string(n));
        }
        uint32_t now = cycles();
        still = now == last ? still + 1 : 0;
        last = now;
        if (still > 50) throw RigError("the CPU stopped counting cycles at " + std::to_string(now));
    }
}

std::vector<uint8_t> Console::frame() { return c_.read(kFrameBuffer, kWidth * kHeight); }

std::vector<Golden> load_golden(const std::string& file) {
    std::vector<Golden> out;
    for (const std::string& line : lines(file)) {
        std::istringstream s(line);
        Golden g;
        std::string crc, check, result;
        s >> g.id >> g.frames >> crc >> check >> result >> g.path;
        if (!s) throw RigError(file + ": bad line: " + line);
        g.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        out.push_back(g);
    }
    return out;
}

std::map<std::string, Paddles> load_paddles(const std::string& file) {
    std::map<std::string, Paddles> out;
    for (const std::string& line : lines(file)) {
        std::istringstream s(line);
        std::string id, p;
        Paddles pads = kNoPaddles;
        s >> id;
        for (int& pos : pads) {
            if (!(s >> p)) throw RigError(file + ": bad line: " + line);
            pos = p == "-" ? -1 : std::stoi(p);
        }
        out[id] = pads;
    }
    return out;
}

std::map<std::string, AudioGolden> load_audio(const std::string& file) {
    std::map<std::string, AudioGolden> out;
    for (const std::string& line : lines(file)) {
        std::istringstream s(line);
        std::string id, crc;
        AudioGolden a;
        s >> id >> a.samples >> crc;
        if (!s) throw RigError(file + ": bad line: " + line);
        a.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        out[id] = a;
    }
    return out;
}

TestResult cart_test(Link& link, const std::string& name, const std::vector<uint8_t>& rom, uint32_t frames,
                     uint32_t crc, const Paddles& paddles, std::optional<AudioGolden> audio,
                     std::optional<uint32_t> build_id) {
    TestResult r;
    r.name = name;
    auto t0 = std::chrono::steady_clock::now();
    shell::Client client(link);
    Console vcs(client);

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
        vcs.hold_reset();
        if (auto e = vcs.load(rom)) return finish(*e);
        r.bytes = rom.size();
        vcs.set_paddles(paddles);
        vcs.stop_frame(frames);
        vcs.audio_limit(audio ? audio->samples : 0);
        vcs.run();
        vcs.wait_stopped();
        auto got = vcs.frame_crc();
        if (got) r.crc32 = got->first;
        r.audio_crc32 = vcs.audio_crc();
        uint32_t samples = vcs.samples();
        r.notes = std::to_string(vcs.frames()) + " frames, " + std::to_string(vcs.cycles()) + " CPU cycles, " +
                  std::to_string(samples) + " samples";
        if (!got || got->second != frames) return finish("no CRC for frame " + std::to_string(frames));
        if (got->first != crc)
            return finish("frame " + std::to_string(frames) + " has CRC " + hex(got->first, 8) + ", Stella's " +
                          hex(crc, 8));
        if (audio) {
            if (samples < audio->samples)
                return finish(std::to_string(samples) + " samples by frame " + std::to_string(frames) + ", " +
                              std::to_string(audio->samples) + " wanted");
            if (*r.audio_crc32 != audio->crc)
                return finish("sound CRC " + hex(*r.audio_crc32, 8) + ", Stella's " + hex(audio->crc, 8));
        }
        return finish("");
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

} // namespace rig::a2600
