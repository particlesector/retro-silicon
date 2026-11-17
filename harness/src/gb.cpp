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

const std::map<std::string, std::string>& frame_not_checked() {
    static const std::map<std::string, std::string> m = {
        {"mts-serial-boot_sclk_align-dmgABCmgb", "the serial clock's phase from power-up"},
    };
    return m;
}

TestResult rom_test(Link& link, const Golden& g, const std::vector<uint8_t>& rom, const std::vector<uint8_t>& boot,
                    std::optional<uint32_t> build_id) {
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
        if (g.check != "serial" && g.check != "mooneye" && g.check != "frame")
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
        return finish("");
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

} // namespace rig::gb
