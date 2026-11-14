// SPDX-License-Identifier: Apache-2.0
#include "rig/a2600.hpp"

#include <cctype>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <stdexcept>

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

std::optional<Cart> cart_from_name(const std::string& path) {
    auto dot = path.find_last_of('.');
    std::string ext = dot == std::string::npos ? "" : path.substr(dot + 1);
    for (auto& ch : ext) ch = static_cast<char>(std::toupper(static_cast<unsigned char>(ch)));
    static const std::map<std::string, Cart> names = {
        {"BIN", {}}, {"A26", {}}, {"2K", {}}, {"4K", {}},
        {"F8", {Scheme::F8, false}}, {"F6", {Scheme::F6, false}}, {"F4", {Scheme::F4, false}},
        {"F8SC", {Scheme::F8, true}}, {"F6SC", {Scheme::F6, true}}, {"F4SC", {Scheme::F4, true}},
        {"FE", {Scheme::FE, false}}, {"E0", {Scheme::E0, false}}, {"3F", {Scheme::F3F, false}},
        {"FA", {Scheme::FA, false}}, {"E7", {Scheme::E7, false}}, {"F0", {Scheme::F0, false}},
    };
    auto it = names.find(ext);
    if (it == names.end()) return std::nullopt;
    return it->second;
}

std::optional<std::string> Console::load(const std::vector<uint8_t>& rom, Cart cart) {
    size_t want_size = 0;
    switch (cart.scheme) {
    case Scheme::k4K: want_size = rom.size() == 2048 ? 2048 : 4096; break;
    case Scheme::F8: case Scheme::FE: case Scheme::E0: want_size = 8192; break;
    case Scheme::F6: case Scheme::E7: want_size = 16384; break;
    case Scheme::F4: want_size = 32768; break;
    case Scheme::FA: want_size = 12288; break;
    case Scheme::F0: want_size = 65536; break;
    case Scheme::F3F:
        want_size = rom.size();
        if (rom.size() < 2048 || rom.size() > 512 * 1024 || (rom.size() & (rom.size() - 1)))
            return "a 3F cartridge of " + std::to_string(rom.size()) + " bytes: 2 KB to 512 KB, a power of 2";
        break;
    }
    if (rom.size() != want_size)
        return "a cartridge of " + std::to_string(rom.size()) + " bytes for a scheme of " +
               std::to_string(want_size);
    std::vector<uint8_t> image(rom);
    if (image.size() == 2048) image.insert(image.end(), rom.begin(), rom.end());
    uint32_t room = 1u << c_.peek(kRegs + kCartRom, 1)[0];
    if (image.size() > room) return std::string(kNoRoom);
    uint32_t size_log2 = 0;
    while ((1u << size_log2) < image.size()) size_log2++;
    put32(kCartScheme, static_cast<uint32_t>(cart.scheme) | (cart.sc ? 0x10u : 0u) | size_log2 << 8, 2);
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

void Console::set_pins(uint16_t pins) {
    put32(kInputOn, 0, 1);
    put32(kJoy, static_cast<uint32_t>(pins >> 8), 1);
    put32(kSwitches, (pins & 0xCFu) | 0x30u, 1);  // bits 5-4 aren't switches: they read as 1
    put32(kFire, (pins >> 4) & 3u, 1);
}

void Console::set_input_script(const std::vector<InputEntry>& script) {
    if (script.size() > static_cast<size_t>(kInputMax))
        throw RigError("an input script holds " + std::to_string(kInputMax) + " entries at most");
    put32(kInputOn, 0, 1);
    std::vector<uint8_t> bytes;
    for (const auto& e : script)
        for (uint32_t v : {e.pins & 0xFFu, static_cast<uint32_t>(e.pins >> 8), e.frame & 0xFFu,
                           static_cast<uint32_t>(e.frame >> 8)})
            bytes.push_back(static_cast<uint8_t>(v));
    if (!bytes.empty()) c_.write(kInputScript, bytes);
    put32(kInputLen, static_cast<uint32_t>(script.size()), 1);
    put32(kInputOn, script.empty() ? 0 : 1, 1);
}

std::vector<InputEntry> parse_input(const std::string& text) {
    std::vector<InputEntry> out;
    std::istringstream s(text);
    std::string e;
    while (std::getline(s, e, ',')) {
        auto colon = e.find(':');
        size_t n1 = 0, n2 = 0;
        unsigned long f = 0, pins = 0;
        try {
            if (colon == std::string::npos || e.size() - colon - 1 != 4) throw std::invalid_argument(e);
            f = std::stoul(e.substr(0, colon), &n1, 10);
            pins = std::stoul(e.substr(colon + 1), &n2, 16);
        } catch (const std::exception&) {
            throw RigError("bad input entry " + e + " (F:JJCC, frame then the pins in hex)");
        }
        if (n1 != colon || n2 != 4 || f == 0 || f > 0xFFFF)
            throw RigError("bad input entry " + e + " (F:JJCC, frame then the pins in hex)");
        if (!out.empty() && f <= out.back().frame)
            throw RigError("input entry " + e + " isn't after the one before it");
        out.push_back({static_cast<uint16_t>(f), static_cast<uint16_t>(pins)});
    }
    return out;
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
    auto n = c_.peek(kRegs + kVideoShown, 8);
    v.shown = static_cast<uint16_t>(n[0] | n[1] << 8);
    v.late = static_cast<uint16_t>(n[2] | n[3] << 8);
    v.overrun = static_cast<uint16_t>(n[4] | n[5] << 8);
    v.gaps = static_cast<uint16_t>(n[6] | n[7] << 8);
    return v;
}

std::pair<uint32_t, uint32_t> Console::pcm() { return {get32(kPcmCrc), get32(kPcmCount)}; }

std::vector<Golden> load_golden(const std::string& file) {
    std::vector<Golden> out;
    for (const std::string& line : lines(file)) {
        std::istringstream s(line);
        Golden g;
        std::string crc, check, result;
        s >> g.id >> g.frames >> crc >> check >> result >> g.path;
        if (!s) throw RigError(file + ": bad line: " + line);
        g.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        std::string opt;
        while (s >> opt) {
            if (opt.rfind("input=", 0) != 0) throw RigError(file + ": unknown option " + opt + " in: " + line);
            g.input = parse_input(opt.substr(6));
        }
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
                     std::optional<uint32_t> build_id, Cart cart, const std::vector<InputEntry>& input) {
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
        if (auto e = vcs.load(rom, cart)) return finish(*e);
        r.bytes = rom.size();
        vcs.set_paddles(paddles);
        vcs.set_pins(kNoInput);
        vcs.set_input_script(input);
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

TestResult hdmi_test(Link& link, const std::string& name, const std::vector<uint8_t>& rom, uint32_t frames,
                     uint32_t crc, const Paddles& paddles, std::optional<uint32_t> build_id, Cart cart,
                     const std::vector<InputEntry>& input) {
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
        if (auto e = vcs.load(rom, cart)) return finish(*e);
        r.bytes = rom.size();
        vcs.set_paddles(paddles);
        vcs.set_pins(kNoInput);
        vcs.set_input_script(input);
        vcs.audio_limit(0);
        Video before = vcs.video();
        vcs.arm_video_crc(frames - 1);
        // Stopped at its end, the frame's lines are all in; the display frame showing it runs on.
        vcs.stop_frame(frames);
        vcs.run();
        vcs.wait_stopped();
        // Read on for over two display frames, so a stopped system the display still waits on
        // shows up as late lines.
        Video v = vcs.video();
        for (int i = 0; i < 64 || !v.valid; i++) {
            if (i >= 100 && !v.valid) break;
            v = vcs.video();
        }
        // The sound's FIFO (21 ms) drains after the run: one gap, when it runs dry; any more were
        // during the run.
        for (int i = 0; i < 4000 && static_cast<uint16_t>(v.gaps - before.gaps) == 0; i++)
            v = vcs.video();
        uint16_t gaps = static_cast<uint16_t>(v.gaps - before.gaps);
        r.crc32 = v.crc;
        r.notes = "shown " + std::to_string(static_cast<uint16_t>(v.shown - before.shown)) + " display frames, " +
                  std::to_string(static_cast<uint16_t>(v.late - before.late)) + " lines late, " +
                  std::to_string(gaps) + " sound gap" + (gaps == 1 ? "" : "s");
        // The frame it showed is the golden frame: the system's own CRC of it.
        auto c = vcs.frame_crc();
        if (!c || c->second != frames) return finish("no frame CRC for frame " + std::to_string(frames));
        if (c->first != crc)
            return finish("frame " + std::to_string(frames) + " has CRC " + hex(c->first, 8) + ", Stella's " +
                          hex(crc, 8));
        if (!v.valid) return finish("no video CRC for frame " + std::to_string(frames));
        if (!v.whole) return finish("the display frame showing frame " + std::to_string(frames) + " wasn't whole");
        if (v.late != before.late || v.overrun != before.overrun)
            return finish(std::to_string(static_cast<uint16_t>(v.late - before.late)) + " lines late, " +
                          std::to_string(static_cast<uint16_t>(v.overrun - before.overrun)) + " overwritten");
        if (gaps > 1)
            return finish("the sound ran dry or dropped samples " + std::to_string(gaps - 1) +
                          " times while the cartridge ran");
        return finish("");
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

} // namespace rig::a2600
