// SPDX-License-Identifier: Apache-2.0
#include "rig/gb.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <tuple>

#include "rig/crc32.hpp"

namespace rig::gb {

namespace {

std::string hex(uint32_t x, int digits) {
    char s[16];
    std::snprintf(s, sizeof s, "0x%0*x", digits, x);
    return s;
}

std::string spaces(std::string p) {
    for (size_t i; (i = p.find("%20")) != std::string::npos;) p.replace(i, 3, " ");
    return p;
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

std::optional<std::string> Console::load(const std::vector<uint8_t>& rom, const std::vector<uint8_t>& boot) {
    if (boot.size() != 256) return "a boot ROM of " + std::to_string(boot.size()) + " bytes, not 256";
    const uint32_t room = 1u << c_.peek(kRegs + kRomRoom, 1)[0];
    if (rom.size() > room) return std::string(kNoRoom);
    std::vector<uint8_t> image(rom);
    image.resize(room, 0xFF);
    const std::vector<uint8_t>& cart = image;
    const std::vector<uint8_t> ram(kCartRamSize, 0xFF);
    for (auto [addr, data, what] : {std::tuple{kBoot, &boot, "boot ROM"}, std::tuple{kCart, &cart, "cartridge"},
                                    std::tuple{kCartRam, &ram, "cartridge RAM"}}) {
        c_.write(addr, *data);
        Crc32 want;
        want.update(*data);
        uint32_t got = c_.crc(addr, static_cast<uint32_t>(data->size()));
        if (got != want.value())
            return std::string("the uploaded ") + what + " has CRC " + hex(got, 8) + ", expected " +
                   hex(want.value(), 8);
    }
    return std::nullopt;
}

void Console::set_keys(uint8_t keys) { put32(kKeys, keys, 1); }
void Console::stop_frame(uint32_t n) { put32(kStopFrame, n); }
void Console::run() { put32(kCtrl, 1, 1); }
uint8_t Console::status() { return c_.peek(kRegs + kStatus, 1)[0]; }
uint32_t Console::frames() { return get32(kFrames); }
uint32_t Console::cycles() { return get32(kCycles); }
uint32_t Console::serial_count() { return get32(kSerialCount); }

std::optional<std::pair<uint32_t, uint32_t>> Console::frame_crc() {
    if (!(status() & kCrcValid)) return std::nullopt;
    auto b = c_.peek(kRegs + kFrameCrc, 8);
    uint32_t crc = b[0] | b[1] << 8 | b[2] << 16 | static_cast<uint32_t>(b[3]) << 24;
    uint32_t n = b[4] | b[5] << 8 | b[6] << 16 | static_cast<uint32_t>(b[7]) << 24;
    return std::make_pair(crc, n);
}

std::vector<uint8_t> Console::serial(uint32_t from) {
    const uint32_t end = serial_count();
    from = std::max(from, end > kSerialSize ? end - kSerialSize : 0u);
    std::vector<uint8_t> out;
    while (from < end) {
        const uint32_t at = from % kSerialSize, n = std::min(end - from, kSerialSize - at);
        auto part = c_.read(kSerial + at, n);
        out.insert(out.end(), part.begin(), part.end());
        from += n;
    }
    return out;
}

void Console::wait_stopped() {
    uint32_t last = 0;
    int still = 0;
    for (;;) {
        const uint8_t st = status();
        // The CRC comes about 23,000 clocks after the stop.
        if ((st & (kStopped | kCrcValid)) == (kStopped | kCrcValid)) return;
        if (!(st & kStopped)) {
            uint32_t now = cycles();
            still = now == last ? still + 1 : 0;
            last = now;
            if (still > 50) throw RigError("the system stopped counting T-cycles at " + std::to_string(now));
        }
    }
}

std::vector<uint8_t> Console::frame() { return c_.read(kFrameBuffer, kWidth * kHeight); }
uint32_t Console::sound_crc() { return get32(kSoundCrc); }
uint32_t Console::cart_head() { return get32(kCartHead); }
std::pair<uint32_t, uint32_t> Console::pcm() { return {get32(kPcmCrc), get32(kPcmCount)}; }

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
    auto n = c_.peek(kRegs + kVideoShown, 4);
    v.shown = static_cast<uint16_t>(n[0] | n[1] << 8);
    v.late = static_cast<uint16_t>(n[2] | n[3] << 8);
    return v;
}

std::map<std::string, HdmiGolden> load_hdmi_golden(const std::string& file) {
    std::ifstream f(file);
    if (!f) throw RigError("can't read " + file);
    std::map<std::string, HdmiGolden> out;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        std::string id, crc;
        HdmiGolden g;
        s >> id >> g.frame >> crc;
        if (!s) throw RigError(file + ": bad line: " + line);
        g.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        out[id] = g;
    }
    return out;
}

std::vector<Golden> load_golden(const std::string& file) {
    std::ifstream f(file);
    if (!f) throw RigError("can't read " + file);
    std::vector<Golden> out;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        Golden g;
        std::string crc;
        s >> g.id >> g.model >> g.frames >> crc >> g.check >> g.result >> g.path;
        if (!s) throw RigError(file + ": bad line: " + line);
        g.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        g.path = spaces(g.path);
        out.push_back(g);
    }
    return out;
}

std::map<std::string, std::set<std::string>> load_needs(const std::string& manifest) {
    std::ifstream f(manifest);
    if (!f) throw RigError("can't read " + manifest);
    std::map<std::string, std::set<std::string>> out;
    std::string line, id;
    bool rom = false;
    auto unquote = [](const std::string& v) {
        auto a = v.find('"'), b = v.rfind('"');
        return a == std::string::npos || b <= a ? v : v.substr(a + 1, b - a - 1);
    };
    while (std::getline(f, line)) {
        if (!line.empty() && line[0] == '[') {
            rom = line.rfind("[[rom]]", 0) == 0;
            id.clear();
            continue;
        }
        auto eq = line.find(" = ");
        if (!rom || eq == std::string::npos) continue;
        std::string k = line.substr(0, eq), v = line.substr(eq + 3);
        if (k == "id") {
            id = unquote(v);
            out[id];
        } else if (k == "needs" && !id.empty()) {
            std::istringstream s(unquote(v));
            std::string n;
            while (std::getline(s, n, ',')) {
                n.erase(0, n.find_first_not_of(' '));
                out[id].insert(n);
            }
        }
    }
    return out;
}

const std::set<std::string>& system_has() {
    static const std::set<std::string> has = {"cpu", "serial", "timer", "interrupts", "boot",
                                              "ppu", "oam dma", "apu",   "cart ram"};
    return has;
}

std::map<std::string, AudioGolden> load_audio_golden(const std::string& file) {
    std::ifstream f(file);
    if (!f) throw RigError("can't read " + file);
    std::map<std::string, AudioGolden> out;
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        std::string id, crc;
        AudioGolden g;
        s >> id >> g.frames >> crc;
        if (!s) throw RigError(file + ": bad line: " + line);
        g.crc = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
        out[id] = g;
    }
    return out;
}

const std::map<std::string, std::string>& frame_not_checked() {
    static const std::map<std::string, std::string> m = {
        {"mts-serial-boot_sclk_align-dmgABCmgb", "the serial clock's phase from power-up"},
    };
    return m;
}

TestResult rom_test(Link& link, const Golden& g, const std::vector<uint8_t>& rom, const std::vector<uint8_t>& boot,
                    std::optional<uint32_t> build_id, std::optional<AudioGolden> audio) {
    TestResult r;
    r.name = g.id;
    auto t0 = std::chrono::steady_clock::now();
    shell::Client client(link);
    Console gb(client);

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
        if (g.model != "dmg") return finish("a ROM for the " + g.model + ": the system is a Game Boy (dmg)");
        if (g.check != "serial" && g.check != "mooneye" && g.check != "blargg" && g.check != "frame")
            return finish("the " + g.check + " check isn't supported");
        auto info = client.info();
        if (info.version != shell::kVersion)
            return finish("shell protocol version " + std::to_string(info.version) + ", expected " +
                          std::to_string(shell::kVersion));
        if (build_id && info.build_id != *build_id)
            return finish("build ID " + hex(info.build_id, 8) + ", expected " + hex(*build_id, 8) +
                          ": the wrong bitstream is loaded");
        gb.hold_reset();
        if (auto e = gb.load(rom, boot)) return finish(*e);
        r.bytes = rom.size();
        gb.set_keys(0);

        // The result, as gb_roms_test reads it at each frame's end; then the frame 30 on.
        std::string result = g.check == "frame" ? "-" : "";
        uint32_t want = g.check == "frame" ? g.frames : 0;
        const uint32_t limit = 2 * g.frames + 60;
        std::vector<uint8_t> bytes;
        const std::vector<uint8_t> pass = {3, 5, 8, 13, 21, 34};
        uint32_t at = want ? want : 1;
        for (bool started = false;; started = true) {
            gb.stop_frame(at);
            if (!started) gb.run();
            gb.wait_stopped();
            if (want) break;
            auto more = gb.serial(static_cast<uint32_t>(bytes.size()));
            bytes.insert(bytes.end(), more.begin(), more.end());
            if (g.check == "serial") {
                std::string text(bytes.begin(), bytes.end());
                if (text.find("Passed") != std::string::npos) result = "pass";
                if (text.find("Failed") != std::string::npos) result = "fail";
            } else if (g.check == "blargg") {
                // blargg's newer ROMs: the code at $A000 once $A001-$A003 hold DE B0 61
                const uint32_t h = gb.cart_head();
                const unsigned code = h & 0xFF;
                if ((h >> 8) == 0x61B0DE && code < 0x80) result = code == 0 ? "pass" : "fail:" + std::to_string(code);
            } else if (bytes.size() >= 6) {
                result = std::equal(pass.begin(), pass.end(), bytes.begin()) ? "pass" : "fail";
            }
            if (!result.empty()) {
                want = at + 30;
                at = want;
            } else if (at >= limit) {
                break;
            } else {
                at++;
            }
        }
        auto got = gb.frame_crc();
        if (got) r.crc32 = got->first;
        r.notes = std::to_string(gb.frames()) + " frames, " + std::to_string(gb.cycles()) + " T-cycles, " +
                  std::to_string(gb.serial_count()) + " serial bytes";
        if (result.empty()) return finish("no result in " + std::to_string(limit) + " frames");
        if (result != g.result) {
            std::string text(bytes.begin(), bytes.end());
            std::replace(text.begin(), text.end(), '\n', '|');
            return finish(result + ", MesenCE " + g.result + " [" + text + "]");
        }
        if (!got || got->second != want) return finish("no CRC for frame " + std::to_string(want));
        if (got->first != g.crc && !frame_not_checked().count(g.id))
            return finish("frame " + std::to_string(want) + " has CRC " + hex(got->first, 8) + ", MesenCE's " +
                          hex(g.crc, 8));
        const uint32_t sound = gb.sound_crc();
        r.audio_crc32 = sound;
        if (audio && (audio->frames != want || audio->crc != sound))
            return finish("the sound to frame " + std::to_string(want) + " has CRC " + hex(sound, 8) +
                          ", the sim's " + hex(audio->crc, 8) + " (to frame " + std::to_string(audio->frames) + ")");
        return finish("");
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

TestResult hdmi_test(Link& link, const Golden& g, const std::vector<uint8_t>& rom, const std::vector<uint8_t>& boot,
                     uint32_t frame, std::optional<uint32_t> build_id) {
    TestResult r;
    r.name = g.id;
    auto t0 = std::chrono::steady_clock::now();
    shell::Client client(link);
    Console gb(client);

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
        gb.hold_reset();
        if (auto e = gb.load(rom, boot)) return finish(*e);
        r.bytes = rom.size();
        gb.set_keys(0);
        Video before = gb.video();
        gb.arm_video_crc(frame - 1);
        // Stopped at its end, the frame is all drawn; the display frame showing it runs on.
        gb.stop_frame(frame);
        gb.run();
        gb.wait_stopped();
        // Read on for over two display frames, so a stopped system the display still waits on
        // shows up as late lines.
        Video v = gb.video();
        for (int i = 0; i < 64 || !v.valid; i++) {
            if (i >= 100 && !v.valid) break;
            v = gb.video();
        }
        r.crc32 = v.crc;
        r.notes = "shown " + std::to_string(static_cast<uint16_t>(v.shown - before.shown)) + " display frames, " +
                  std::to_string(static_cast<uint16_t>(v.late - before.late)) + " lines late";
        auto c = gb.frame_crc();
        if (!c || c->second != frame) return finish("no frame CRC for frame " + std::to_string(frame));
        if (c->first != g.crc && !frame_not_checked().count(g.id))
            return finish("frame " + std::to_string(frame) + " has CRC " + hex(c->first, 8) + ", MesenCE's " +
                          hex(g.crc, 8));
        if (!v.valid) return finish("no video CRC for frame " + std::to_string(frame));
        if (!v.whole) return finish("the display frame showing frame " + std::to_string(frame) + " wasn't whole");
        if (v.late != before.late)
            return finish(std::to_string(static_cast<uint16_t>(v.late - before.late)) + " lines late");
        return finish("");
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

} // namespace rig::gb
