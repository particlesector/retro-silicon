// SPDX-License-Identifier: Apache-2.0
// The Game Boy against MesenCE's results for the test ROMs of
// testroms/manifest-gb.toml (harness/golden/gb_frames_crc32.txt): every ROM
// for the Game Boy (dmg) whose `needs` the system has so far runs from
// power-up through SameBoy's DMG boot ROM. A ROM with a result of its own
// (blargg's text over the serial port or code in cartridge RAM, or Mooneye's
// bytes) must end with
// MesenCE's result (a pass, or a fail where MesenCE's is one) within twice
// the frames MesenCE took, and its frame 30 frames after the result must be
// MesenCE's (its CRC: 2 bytes a pixel, the shade then 0, row by row); a
// frame check's frame is the one MesenCE's list names. Frames end as MesenCE
// ends them (gb_sys has the rules: at VBlank, as the LCD turns off outside it,
// and every 70,224 dots while it's off), so the result comes at MesenCE's frame
// number too. The sound's
// CRC to the end of that frame (the APU's two mixes at each M-cycle's end, as
// 16-bit little-endian words, left then right: gb_sys's register 30) must be
// harness/golden/gb_audio_crc32.txt's, which RS_GB_AUDIO_OUT=<file> writes
// instead (after an intended change to the sound). Skipped when the ROMs
// aren't fetched (testroms/fetch.py).
//
// The ROMs run on up to 6 threads (RS_GB_JOBS=<n> sets how many);
// RS_GB_ONLY=<id>[,<id>...] runs just those, RS_GB_TRACE=1 prints each
// opcode fetch's PC, each frame's end and the serial bytes as they come, RS_GB_DUMP=<dir>
// writes each ROM's checked frame there as <id>.pgm, and RS_GB_AUDIO_DUMP=<dir>
// the APU's two mixes at each M-cycle's end, to the checked frame, as <id>.mix
// (two signed 16-bit little-endian words a cycle, left then right).
//
// A ROM's golden line can carry an input script (input=, the keys held from a frame on), a
// battery RAM to power up with (sav=) or `again` (run twice, the second time from the cartridge
// RAM the first left, as MesenCE keeps a battery cartridge's), and savcrc=, the CRC-32 the
// cartridge's RAM must have at the end.
#include <catch2/catch_test_macros.hpp>

#include <verilated.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "Vgb_cart_top.h"

namespace {

namespace fs = std::filesystem;

// What the system has so far (the manifest's `needs`; harness's rig::gb::system_has() is the same).
const std::set<std::string> kHas = {"cpu",     "serial", "timer", "interrupts", "boot", "ppu", "oam dma",
                                    "apu",     "cart ram", "mbc1", "mbc2",     "mbc3", "mbc5", "rtc", "cgb"};
// ROMs whose result is checked but not their frame, and why (harness's
// rig::gb::frame_not_checked() has the same list).
const std::map<std::string, std::string> kFrameNotChecked = {
    // Its fail screen (it fails through SameBoy's boot ROM, as in MesenCE) shows
    // counts that hang on the serial clock's phase from power-up, which nothing
    // settles for this boot ROM: MesenCE's differ from ours, and SameBoy's from
    // both by one, its DIV running 4 T-cycles ahead of ours and MesenCE's.
    {"mts-serial-boot_sclk_align-dmgABCmgb", "the serial clock's phase from power-up"},
};
constexpr int kTPerFrame = 70224;
constexpr int kMargin = 30;  // frames after the result to the checked frame, as gb_frames.py takes it
constexpr int kW = 160, kH = 144;

// An input script: {frame, keys}, gameboy's `keys` held from that frame on (frames ended).
using Script = std::vector<std::pair<long, uint8_t>>;

struct Rom {
    std::string id, source, path, model, check, result;
    std::set<std::string> needs;
    int frames = 0;
    long golden_frames = 0;  // the golden frame's number
    uint32_t crc = 0;        // and its CRC
    Script input;
    bool again = false;
    bool overridden = false;  // the manifest's `override`: MesenCE wrong, its result and CRC another's
    std::string sav;
    std::optional<uint32_t> savcrc;
};

struct Golden {
    std::string result;
    long frames = 0;
    uint32_t crc = 0;
    Script input;
    bool again = false;            // run twice, the second time from the battery RAM the first left
    std::string sav;               // or power up with this battery RAM (under the test-ROM directory)
    std::optional<uint32_t> savcrc;  // the cartridge RAM's CRC-32 at the end
};

uint8_t keys_at(const Script& s, long frame) {
    uint8_t k = 0;
    for (auto& [f, v] : s)
        if (f <= frame) k = v;
    return k;
}

std::string unquote(const std::string& v) {
    auto a = v.find('"'), b = v.rfind('"');
    return a == std::string::npos || b <= a ? v : v.substr(a + 1, b - a - 1);
}

// The manifest's [[rom]] and [[boot]] tables, read line by line: its keys are one to a line.
struct Manifest {
    std::vector<Rom> roms;
    std::map<std::string, std::string> sources_dir;  // [sources.X] -> X
    std::string dmg_boot, cgb_boot;                 // source/path
};

Manifest read_manifest(const std::string& file) {
    Manifest m;
    std::ifstream in(file);
    std::string line, table;
    Rom r;
    std::string boot_id, boot_src, boot_path;
    auto flush = [&] {
        if (table == "rom" && !r.id.empty()) m.roms.push_back(r);
        if (table == "boot" && boot_id == "dmg") m.dmg_boot = boot_src + "/" + boot_path;
        if (table == "boot" && boot_id == "cgb") m.cgb_boot = boot_src + "/" + boot_path;
        r = Rom{};
        boot_id.clear();
    };
    while (std::getline(in, line)) {
        if (line.rfind("[[", 0) == 0 || line.rfind("[", 0) == 0) {
            flush();
            table = line.rfind("[[rom]]", 0) == 0 ? "rom" : line.rfind("[[boot]]", 0) == 0 ? "boot" : "";
            continue;
        }
        auto eq = line.find(" = ");
        if (eq == std::string::npos || line[0] == '#') continue;
        std::string k = line.substr(0, eq), v = line.substr(eq + 3);
        if (table == "rom") {
            if (k == "id") r.id = unquote(v);
            else if (k == "source") r.source = unquote(v);
            else if (k == "path") r.path = unquote(v);
            else if (k == "model") r.model = unquote(v);
            else if (k == "check") r.check = unquote(v);
            else if (k == "frames") r.frames = std::stoi(v);
            else if (k == "override") r.overridden = true;
            else if (k == "needs") {
                std::istringstream s(unquote(v));
                std::string n;
                while (std::getline(s, n, ',')) {
                    n.erase(0, n.find_first_not_of(' '));
                    r.needs.insert(n);
                }
            }
        } else if (table == "boot") {
            if (k == "id") boot_id = unquote(v);
            else if (k == "source") boot_src = unquote(v);
            else if (k == "path") boot_path = unquote(v);
        }
    }
    flush();
    return m;
}

// The golden list for each id: id, model, frames, CRC, check, result, path.
std::map<std::string, Golden> golden_results(const std::string& file) {
    std::map<std::string, Golden> out;
    std::ifstream in(file);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream s(line);
        std::string id, model, frames, crc, check, result, path, opt;
        s >> id >> model >> frames >> crc >> check >> result >> path;
        Golden g{result, std::stol(frames), static_cast<uint32_t>(std::stoul(crc, nullptr, 16)), {}, false, {}, {}};
        while (s >> opt) {
            if (opt == "again") g.again = true;
            if (opt.rfind("sav=", 0) == 0) g.sav = opt.substr(4);
            if (opt.rfind("savcrc=", 0) == 0) g.savcrc = static_cast<uint32_t>(std::stoul(opt.substr(7), nullptr, 16));
            if (opt.rfind("input=", 0) != 0) continue;
            std::istringstream e(opt.substr(6));
            std::string entry;
            while (std::getline(e, entry, ',')) {
                auto c = entry.find(':');
                g.input.emplace_back(std::stol(entry.substr(0, c)), static_cast<uint8_t>(std::stoul(entry.substr(c + 1), nullptr, 0)));
            }
        }
        out[id] = g;
    }
    return out;
}

// The cartridge's controller and sizes from its header, as MesenCE takes them (harness's
// rig::gb::cart_config() is the same): gb_cart's `mbc` (0 none, 1 MBC1, 2 MBC1M, 3 MBC2,
// 4 MBC3, 5 MBC5), `rtc`, `rumble`, `rom_log2` and `ram_log2`. None for a controller
// gb_cart hasn't got.
struct CartConfig {
    int mbc = 0;
    bool rtc = false, rumble = false;
    int rom_log2 = 15, ram_log2 = 0;
};

std::optional<CartConfig> cart_config(const std::vector<uint8_t>& rom) {
    if (rom.size() < 0x150) return std::nullopt;
    CartConfig c;
    const uint8_t type = rom[0x147];
    while ((size_t{1} << c.rom_log2) < rom.size()) c.rom_log2++;
    static const int kRam[] = {0, 11, 13, 15, 17, 16};
    c.ram_log2 = rom[0x149] < 6 ? kRam[rom[0x149]] : 0;
    if (type == 0x00 || type == 0x08 || type == 0x09) {
        c.mbc = 0;
        if (type == 0x00) c.ram_log2 = 0;
    } else if (type >= 0x01 && type <= 0x03) {
        // A multicart (MBC1M) has the boot logo at $40104 as well as at $104.
        const bool m = rom.size() > 0x40134 && std::equal(rom.begin() + 0x104, rom.begin() + 0x134, rom.begin() + 0x40104);
        c.mbc = m ? 2 : 1;
        if (type == 0x01) c.ram_log2 = 0;
    } else if (type == 0x05 || type == 0x06) {
        c.mbc = 3;
        c.ram_log2 = 9;
    } else if (type >= 0x0F && type <= 0x13) {
        c.mbc = 4;
        c.rtc = type <= 0x10;
        if (type == 0x0F || type == 0x11) c.ram_log2 = 0;
    } else if (type >= 0x19 && type <= 0x1E) {
        c.mbc = 5;
        c.rumble = type >= 0x1C;
        if (type == 0x19 || type == 0x1C) c.ram_log2 = 0;
    } else {
        return std::nullopt;
    }
    if (c.rom_log2 > 23) return std::nullopt;
    return c;
}

// The frame as gb_frames.py takes MesenCE's: 2 bytes a pixel, little-endian (a shade, or the Color's
// 15-bit colour).
uint32_t crc32_frame(const std::vector<uint16_t>& pixels) {
    static const auto table = [] {
        std::array<uint32_t, 256> t{};
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[i] = c;
        }
        return t;
    }();
    uint32_t c = 0xFFFFFFFFu;
    for (uint16_t v : pixels) {
        c = table[(c ^ v) & 0xFF] ^ (c >> 8);
        c = table[(c ^ (v >> 8)) & 0xFF] ^ (c >> 8);
    }
    return ~c;
}

uint32_t crc32_bytes(const std::vector<uint8_t>& v) {
    uint32_t c = 0xFFFFFFFFu;
    for (uint8_t b : v) {
        c ^= b;
        for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
    }
    return ~c;
}

std::vector<uint8_t> read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    return {std::istreambuf_iterator<char>(f), {}};
}

struct Outcome {
    std::string result;  // pass, fail, timeout or (a frame check) "-"
    std::string text;    // the serial output
    long frames = 0;     // frames ended at the checked frame
    uint32_t crc = 0;    // its CRC
    uint32_t audio = 0;  // the sound's CRC to its end
    std::vector<uint16_t> frame;
    std::vector<uint8_t> ram;  // the cartridge's RAM at the end
};

// CRC-32 (zlib's), a byte at a time, kept open.
struct Crc {
    uint32_t c = 0xFFFFFFFFu;
    void add(uint8_t v) {
        c ^= v;
        for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
    }
    uint32_t value() const { return ~c; }
};

Outcome run(const Rom& rom, const std::vector<uint8_t>& image, const std::vector<uint8_t>& boot, bool trace,
            const std::vector<uint8_t>* ram_in,
            std::FILE* mix) {
    VerilatedContext ctx;
    Vgb_cart_top m{&ctx};
    const CartConfig cc = *cart_config(image);
    std::vector<uint8_t> cart = image;
    cart.resize(size_t{1} << cc.rom_log2, 0xFF);
    // The cartridge RAM's first bytes as the system wrote them, where blargg's newer ROMs report.
    std::array<uint8_t, 0x2000> cram{};

    std::vector<uint16_t> screen(kW * kH, 0);
    bool frame_ended = false;
    // Frames end as gb_sys ends them (MesenCE's frames): at VBlank, as the LCD turns off outside
    // it, and with the LCD off, every 70,226 dots (70,225 at double speed) from power-up, from
    // when it went off or from the last blank frame (MesenCE's count steps 2 dots at a time). The
    // screen turns white at a blank frame and at the first frame to end after the LCD goes on
    // (on the Color, only if it was off more than 5,000 dots).
    long t_off = 1;
    bool lcd_was = false, white_next = false;
    const bool cgb = rom.model == "cgb";
    Crc audio;
    auto tick = [&](bool ce) {
        m.ce = ce;
        m.clk = 0;
        m.eval();
        const uint16_t a = m.cart_addr;
        if (m.cart_wr && a >= 0xA000 && a < 0xC000) cram[a & 0x1FFF] = m.cart_wdata;
        const uint32_t ra = m.rom_addr;
        if (m.pix_we && m.pix_x < kW && m.pix_y < kH) screen[m.pix_y * kW + m.pix_x] = m.pix_color;
        if (ce) {
            const bool lcd_on = (m.lcdc & 0x80) != 0;
            const bool blank = !lcd_on && !lcd_was && t_off == kTPerFrame + (m.dbl_speed ? 1 : 2);
            const bool done = m.frame_end || m.frame_cut || blank;
            if (done && (blank || white_next)) std::fill(screen.begin(), screen.end(), cgb ? 0x7FFF : 0);
            if (!lcd_on) t_off = lcd_was || blank ? 1 : t_off + 1;
            if (done) white_next = false;
            if (lcd_on && !lcd_was) white_next = !cgb || t_off > 5000;
            lcd_was = lcd_on;
            if (done) frame_ended = true;
        }
        if (ce && m.m_end) {
            const uint16_t l = static_cast<uint16_t>(static_cast<int16_t>(m.aud_l << 6) >> 6);
            const uint16_t r = static_cast<uint16_t>(static_cast<int16_t>(m.aud_r << 6) >> 6);
            audio.add(l & 0xFF);
            audio.add(l >> 8);
            audio.add(r & 0xFF);
            audio.add(r >> 8);
            if (mix) {
                const uint8_t w[4] = {static_cast<uint8_t>(l), static_cast<uint8_t>(l >> 8), static_cast<uint8_t>(r),
                                      static_cast<uint8_t>(r >> 8)};
                std::fwrite(w, 1, 4, mix);
            }
        }
        m.clk = 1;
        m.eval();
        m.rom_q = cart[ra & (cart.size() - 1)];  // a clock after its address, as block RAM gives it
    };
    m.rst = 1;
    m.cgb_hw = rom.model == "cgb";
    m.keys = keys_at(rom.input, 0);
    m.mbc = cc.mbc;
    m.rtc = cc.rtc;
    m.rumble = cc.rumble;
    m.rom_log2 = cc.rom_log2;
    m.ram_log2 = cc.ram_log2;
    // The cartridge's RAM starts as `ram_in`, or zeros, as MesenCE's RAM does (its RamPowerOnState);
    // MBC2's cells with their top 4 bits set, as MesenCE sets them. The clock starts at 0.
    const uint32_t ram_size = cc.ram_log2 ? 1u << cc.ram_log2 : 0;
    m.sh_we = 1;
    m.sh_rtc = 0;
    for (uint32_t i = 0; i < ram_size; i++) {
        m.sh_addr = i;
        m.sh_wdata = (ram_in && i < ram_in->size() ? (*ram_in)[i] : 0) | (cc.mbc == 3 ? 0xF0 : 0);
        tick(false);
    }
    m.sh_wdata = 0;
    m.sh_rtc = 1;
    for (uint32_t i = 0; i < 13; i++) {
        m.sh_addr = i;
        tick(false);
    }
    m.sh_we = 0;
    m.sh_rtc = 0;
    for (size_t i = 0; i < boot.size(); i++) {
        m.boot_we = 1;
        m.boot_addr = static_cast<uint16_t>(i);
        m.boot_wdata = boot[i];
        tick(false);
    }
    m.boot_we = 0;
    tick(false);
    while (m.clearing) tick(false);  // the console zeroing its RAM, as gb_sys waits for it
    m.rst = 0;

    Outcome out;
    std::vector<uint8_t> bytes;
    const long limit = 2L * rom.frames + 60;
    long want = rom.check == "frame" ? rom.golden_frames : -1;
    const std::vector<uint8_t> pass = {3, 5, 8, 13, 21, 34};
    if (rom.check == "frame") out.result = "-";
    while (out.frames < limit) {
        if (trace) {
            m.ce = 1;
            m.eval();
            if (m.m_end && m.cpu_sync) std::printf("%s pc %04X\n", rom.id.c_str(), m.cpu_pc);
        }
        tick(true);
        if (m.ser_tx_valid) {
            bytes.push_back(m.ser_tx);
            out.text.push_back(static_cast<char>(m.ser_tx));
            if (trace) std::printf("%s serial %02X\n", rom.id.c_str(), m.ser_tx);
        }
        tick(false);
        if (!frame_ended) continue;
        frame_ended = false;
        out.frames++;
        if (trace) std::printf("%s frame %ld\n", rom.id.c_str(), out.frames);
        m.keys = keys_at(rom.input, out.frames);
        if (want < 0) {
            if (rom.check == "serial") {
                if (out.text.find("Passed") != std::string::npos) out.result = "pass";
                if (out.text.find("Failed") != std::string::npos) out.result = "fail";
            } else if (rom.check == "mooneye" && bytes.size() >= 6) {
                out.result = std::equal(pass.begin(), pass.end(), bytes.begin()) ? "pass" : "fail";
            } else if (rom.check == "blargg" && cram[1] == 0xDE && cram[2] == 0xB0 && cram[3] == 0x61 &&
                       cram[0] < 0x80) {
                // blargg's newer ROMs: the code at $A000 once $A001-$A003 hold their signature, and the text after
                out.result = cram[0] == 0 ? "pass" : "fail:" + std::to_string(cram[0]);
                for (size_t i = 4; i < cram.size() && cram[i]; i++) out.text.push_back(static_cast<char>(cram[i]));
            }
            if (!out.result.empty()) want = out.frames + kMargin;
        }
        if (out.frames == want) break;
    }
    if (out.frames != want && (want < 0 || rom.check == "frame")) out.result = "timeout";
    out.audio = audio.value();
    out.crc = crc32_frame(screen);
    out.frame = screen;
    // The cartridge's RAM, through the shell's port with the system held in reset.
    m.rst = 1;
    for (uint32_t i = 0; i < ram_size; i++) {
        m.sh_addr = i;
        tick(false);
        out.ram.push_back(m.sh_q);
    }
    return out;
}

}  // namespace

TEST_CASE("Game Boy test ROMs end as they do in MesenCE") {
    const fs::path roms_dir = RS_TESTROMS;
    Manifest man = read_manifest(RS_GB_MANIFEST);
    const auto results = golden_results(RS_GB_GOLDEN);
    const char* dump = std::getenv("RS_GB_DUMP");
    const char* audio_out = std::getenv("RS_GB_AUDIO_OUT");
    std::map<std::string, std::pair<long, uint32_t>> audio_golden;  // id: frames, CRC
    {
        std::ifstream in(RS_GB_AUDIO_GOLDEN);
        std::string line;
        while (std::getline(in, line)) {
            if (line.empty() || line[0] == '#') continue;
            std::istringstream s(line);
            std::string id, frames, crc;
            s >> id >> frames >> crc;
            audio_golden[id] = {std::stol(frames), static_cast<uint32_t>(std::stoul(crc, nullptr, 16))};
        }
    }
    std::map<std::string, std::pair<long, uint32_t>> audio_got;
    const fs::path boot_path = roms_dir / man.dmg_boot, cgb_boot_path = roms_dir / man.cgb_boot;
    if (!fs::exists(boot_path)) SKIP(boot_path.string() << " not found: run testroms/fetch.py");
    if (!fs::exists(cgb_boot_path)) SKIP(cgb_boot_path.string() << " not found: run testroms/fetch.py");
    const auto dmg_boot = read_file(boot_path), cgb_boot = read_file(cgb_boot_path);
    REQUIRE(dmg_boot.size() == 256);
    REQUIRE(cgb_boot.size() == 2304);

    std::set<std::string> only;
    if (const char* o = std::getenv("RS_GB_ONLY")) {
        std::istringstream s(o);
        std::string id;
        while (std::getline(s, id, ',')) only.insert(id);
    }
    const bool trace = std::getenv("RS_GB_TRACE") != nullptr;

    std::vector<Rom> todo;
    for (auto& r : man.roms) {
        if ((r.model != "dmg" && r.model != "cgb") ||
            (r.check != "serial" && r.check != "mooneye" && r.check != "blargg" && r.check != "frame"))
            continue;
        if (!std::all_of(r.needs.begin(), r.needs.end(), [](auto& n) { return kHas.count(n) != 0; })) continue;
        if (!only.empty() && !only.count(r.id)) continue;
        auto it = results.find(r.id);
        REQUIRE(it != results.end());
        r.result = it->second.result;
        r.golden_frames = it->second.frames;
        r.crc = it->second.crc;
        r.input = it->second.input;
        r.again = it->second.again;
        r.sav = it->second.sav;
        r.savcrc = it->second.savcrc;
        todo.push_back(r);
    }
    REQUIRE(!todo.empty());

    std::mutex mu;
    std::vector<std::string> failures;
    std::atomic<size_t> next{0};
    auto worker = [&] {
        for (size_t i; (i = next++) < todo.size();) {
            const Rom& r = todo[i];
            const fs::path p = roms_dir / r.source / r.path;
            if (!fs::exists(p)) {
                std::lock_guard<std::mutex> g(mu);
                failures.push_back(r.id + ": " + p.string() + " not found");
                continue;
            }
            std::FILE* mix = nullptr;
            if (const char* ad = std::getenv("RS_GB_AUDIO_DUMP")) mix = std::fopen((fs::path(ad) / (r.id + ".mix")).c_str(), "wb");
            const auto image = read_file(p);
            if (!cart_config(image)) {
                std::lock_guard<std::mutex> g(mu);
                failures.push_back(r.id + ": its cartridge's controller isn't in gb_cart");
                continue;
            }
            // A battery cartridge's RAM: from `sav`, or with `again` what a first run left.
            std::vector<uint8_t> ram_in;
            if (!r.sav.empty()) ram_in = read_file(roms_dir / r.sav);
            const auto& boot = r.model == "cgb" ? cgb_boot : dmg_boot;
            if (r.again) ram_in = run(r, image, boot, false, nullptr, nullptr).ram;
            Outcome o = run(r, image, boot, trace, r.again || !r.sav.empty() ? &ram_in : nullptr, mix);
            if (mix) std::fclose(mix);
            if (dump) {
                // A PPM: the Game Boy's shades as greys, the Color's 15-bit colours scaled to 8 bits.
                std::ofstream f(fs::path(dump) / (r.id + ".ppm"), std::ios::binary);
                f << "P6\n" << kW << " " << kH << "\n255\n";
                for (uint16_t v : o.frame)
                    for (int ch = 0; ch < 3; ch++) {
                        const int c5 = (v >> (5 * ch)) & 0x1F;
                        f.put(static_cast<char>(r.model == "cgb" ? (c5 << 3) | (c5 >> 2) : 255 - (v & 3) * 85));
                    }
            }
            std::lock_guard<std::mutex> g(mu);
            char crcs[64];
            std::snprintf(crcs, sizeof crcs, "0x%08x (MesenCE 0x%08x)", o.crc, r.crc);
            std::printf("%-40s %-7s (MesenCE %s) frame %ld %s\n", r.id.c_str(), o.result.c_str(),
                        r.result.c_str(), o.frames, crcs);
            audio_got[r.id] = {o.frames, o.audio};
            auto ag = audio_golden.find(r.id);
            if (o.result != r.result) {
                std::string t = o.text;
                std::replace(t.begin(), t.end(), '\n', '|');
                failures.push_back(r.id + ": " + o.result + ", MesenCE " + r.result + " [" + t + "]");
            } else if (o.frames != r.golden_frames && !r.overridden) {
                // The result, and so the checked frame, must come at MesenCE's frame number: frames
                // ending as MesenCE's do, a game's input script and checks land at the same moment.
                // (Not where the manifest overrides MesenCE: its frame number is its own wrong run's.)
                failures.push_back(r.id + ": frame " + std::to_string(o.frames) + " checked, MesenCE's " +
                                   std::to_string(r.golden_frames));
            } else if (o.crc != r.crc && !kFrameNotChecked.count(r.id)) {
                failures.push_back(r.id + ": frame " + std::to_string(o.frames) + " " + crcs);
            } else if (r.savcrc && crc32_bytes(o.ram) != *r.savcrc) {
                char c[64];
                std::snprintf(c, sizeof c, "0x%08x, MesenCE's 0x%08x", crc32_bytes(o.ram), *r.savcrc);
                failures.push_back(r.id + ": the cartridge RAM at the end has CRC " + c);
            } else if (!audio_out && (ag == audio_golden.end() || ag->second.first != o.frames ||
                                      ag->second.second != o.audio)) {
                char a[64];
                std::snprintf(a, sizeof a, "0x%08x", o.audio);
                failures.push_back(r.id + ": sound to frame " + std::to_string(o.frames) + " " + a +
                                   (ag == audio_golden.end() ? std::string(", not in the golden list")
                                                             : ", golden " + std::to_string(ag->second.first)));
            }
        }
    };
    unsigned n = std::min<unsigned>(std::max(1u, std::thread::hardware_concurrency() / 2), 6);
    if (const char* j = std::getenv("RS_GB_JOBS")) n = std::max(1, std::atoi(j));
    std::vector<std::thread> threads;
    for (unsigned i = 0; i < n; i++) threads.emplace_back(worker);
    for (auto& th : threads) th.join();

    if (audio_out) {
        // Every ROM run, in the manifest's order; with RS_GB_ONLY, the others' lines kept.
        for (auto& [id, v] : audio_got) audio_golden[id] = v;
        std::ofstream f(audio_out);
        f << "# The sound's CRC (gb_sys's register 30: the APU's two mixes at each M-cycle's end, as\n"
             "# 16-bit little-endian words, left then right, from reset) at each ROM's checked frame of\n"
             "# gb_frames_crc32.txt, from the sim (gb_roms_test, RS_GB_AUDIO_OUT). Boards must match it;\n"
             "# MesenCE has no equivalent. Regenerate after an intended change to the sound.\n"
             "# id  frames  crc32\n";
        for (auto& r : man.roms) {
            auto it = audio_golden.find(r.id);
            if (it == audio_golden.end()) continue;
            char c[16];
            std::snprintf(c, sizeof c, "0x%08x", it->second.second);
            f << r.id << " " << it->second.first << " " << c << "\n";
        }
    }
    std::sort(failures.begin(), failures.end());
    std::string report;
    for (auto& f : failures) report += "\n  " + f;
    INFO(todo.size() << " ROMs, " << failures.size() << " differ from MesenCE" << report);
    CHECK(failures.empty());
}
