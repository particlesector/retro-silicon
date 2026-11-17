// SPDX-License-Identifier: Apache-2.0
// The Game Boy against MesenCE's results for the test ROMs of
// testroms/manifest-gb.toml (harness/golden/gb_frames_crc32.txt): every ROM
// for the Game Boy (dmg) whose `needs` the system has so far runs from
// power-up through SameBoy's DMG boot ROM. A ROM with a result of its own
// (blargg's text over the serial port, or Mooneye's bytes) must end with
// MesenCE's result (a pass, or a fail where MesenCE's is one) within twice
// the frames MesenCE took, and its frame 30 frames after the result must be
// MesenCE's (its CRC: 2 bytes a pixel, the shade then 0, row by row); a
// frame check's frame is the one MesenCE's list names. A frame ends as
// VBlank starts, or every 70,224 T-cycles while the LCD is off. Skipped when
// the ROMs aren't fetched (testroms/fetch.py).
//
// The ROMs run on up to 6 threads (RS_GB_JOBS=<n> sets how many);
// RS_GB_ONLY=<id>[,<id>...] runs just those, RS_GB_TRACE=1 prints each
// opcode fetch's PC and the serial bytes as they come, and RS_GB_DUMP=<dir>
// writes each ROM's checked frame there as <id>.pgm.
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
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "Vgameboy.h"

namespace {

namespace fs = std::filesystem;

// What the system has so far (the manifest's `needs`).
const std::set<std::string> kHas = {"cpu", "serial", "timer", "interrupts", "boot", "ppu", "oam dma"};
// ROMs whose result is checked but not their frame, and why.
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

struct Rom {
    std::string id, source, path, model, check, result;
    std::set<std::string> needs;
    int frames = 0;
    long golden_frames = 0;  // the golden frame's number
    uint32_t crc = 0;        // and its CRC
};

struct Golden {
    std::string result;
    long frames = 0;
    uint32_t crc = 0;
};

std::string unquote(const std::string& v) {
    auto a = v.find('"'), b = v.rfind('"');
    return a == std::string::npos || b <= a ? v : v.substr(a + 1, b - a - 1);
}

// The manifest's [[rom]] and [[boot]] tables, read line by line: its keys are one to a line.
struct Manifest {
    std::vector<Rom> roms;
    std::map<std::string, std::string> sources_dir;  // [sources.X] -> X
    std::string dmg_boot;                           // source/path
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
        std::string id, model, frames, crc, check, result;
        s >> id >> model >> frames >> crc >> check >> result;
        out[id] = {result, std::stol(frames), static_cast<uint32_t>(std::stoul(crc, nullptr, 16))};
    }
    return out;
}

uint32_t crc32_frame(const std::vector<uint8_t>& shades) {
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
    for (uint8_t v : shades) {
        c = table[(c ^ v) & 0xFF] ^ (c >> 8);
        c = table[c & 0xFF] ^ (c >> 8);
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
    std::vector<uint8_t> frame;
};

Outcome run(const Rom& rom, const std::vector<uint8_t>& image, const std::vector<uint8_t>& boot, bool trace) {
    VerilatedContext ctx;
    Vgameboy m{&ctx};
    std::vector<uint8_t> cart = image;
    cart.resize(std::max<size_t>(cart.size(), 0x8000), 0xFF);
    std::array<uint8_t, 0x2000> cram{};
    cram.fill(0xFF);

    std::vector<uint8_t> screen(kW * kH, 0);
    bool frame_ended = false;
    auto tick = [&](bool ce) {
        m.ce = ce;
        m.clk = 0;
        m.eval();
        const uint16_t a = m.cart_addr;
        if (m.cart_wr && a >= 0xA000 && a < 0xC000) cram[a & 0x1FFF] = m.cart_wdata;
        m.cart_rdata = a < 0x8000 ? cart[a] : (a >= 0xA000 && a < 0xC000) ? cram[a & 0x1FFF] : 0xFF;
        m.eval();
        if (ce && m.pix_we && m.pix_x < kW && m.pix_y < kH) screen[m.pix_y * kW + m.pix_x] = m.pix_shade;
        if (ce && m.frame_end) frame_ended = true;
        m.clk = 1;
        m.eval();
    };
    m.rst = 1;
    m.keys = 0;
    for (size_t i = 0; i < boot.size(); i++) {
        m.boot_we = 1;
        m.boot_addr = static_cast<uint8_t>(i);
        m.boot_wdata = boot[i];
        tick(false);
    }
    m.boot_we = 0;
    tick(false);
    m.rst = 0;

    Outcome out;
    std::vector<uint8_t> bytes;
    const long limit = 2L * rom.frames + 60;
    long t = 0, want = rom.check == "frame" ? rom.golden_frames : -1;
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
        if (++t == kTPerFrame) frame_ended = true;
        if (!frame_ended) continue;
        frame_ended = false;
        t = 0;
        out.frames++;
        if (want < 0) {
            if (rom.check == "serial") {
                if (out.text.find("Passed") != std::string::npos) out.result = "pass";
                if (out.text.find("Failed") != std::string::npos) out.result = "fail";
            } else if (rom.check == "mooneye" && bytes.size() >= 6) {
                out.result = std::equal(pass.begin(), pass.end(), bytes.begin()) ? "pass" : "fail";
            }
            if (!out.result.empty()) want = out.frames + kMargin;
        }
        if (out.frames == want) {
            out.crc = crc32_frame(screen);
            out.frame = screen;
            return out;
        }
    }
    if (want < 0 || rom.check == "frame") out.result = "timeout";
    out.crc = crc32_frame(screen);
    out.frame = screen;
    return out;
}

}  // namespace

TEST_CASE("Game Boy test ROMs end as they do in MesenCE") {
    const fs::path roms_dir = RS_TESTROMS;
    Manifest man = read_manifest(RS_GB_MANIFEST);
    const auto results = golden_results(RS_GB_GOLDEN);
    const char* dump = std::getenv("RS_GB_DUMP");
    const fs::path boot_path = roms_dir / man.dmg_boot;
    if (!fs::exists(boot_path)) SKIP(boot_path.string() << " not found: run testroms/fetch.py");
    const auto boot = read_file(boot_path);
    REQUIRE(boot.size() == 256);

    std::set<std::string> only;
    if (const char* o = std::getenv("RS_GB_ONLY")) {
        std::istringstream s(o);
        std::string id;
        while (std::getline(s, id, ',')) only.insert(id);
    }
    const bool trace = std::getenv("RS_GB_TRACE") != nullptr;

    std::vector<Rom> todo;
    for (auto& r : man.roms) {
        if (r.model != "dmg" || (r.check != "serial" && r.check != "mooneye" && r.check != "frame")) continue;
        if (!std::all_of(r.needs.begin(), r.needs.end(), [](auto& n) { return kHas.count(n) != 0; })) continue;
        if (!only.empty() && !only.count(r.id)) continue;
        auto it = results.find(r.id);
        REQUIRE(it != results.end());
        r.result = it->second.result;
        r.golden_frames = it->second.frames;
        r.crc = it->second.crc;
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
            Outcome o = run(r, read_file(p), boot, trace);
            if (dump) {
                std::ofstream f(fs::path(dump) / (r.id + ".pgm"), std::ios::binary);
                f << "P5\n" << kW << " " << kH << "\n255\n";
                for (uint8_t v : o.frame) f.put(static_cast<char>(255 - v * 85));
            }
            std::lock_guard<std::mutex> g(mu);
            char crcs[64];
            std::snprintf(crcs, sizeof crcs, "0x%08x (MesenCE 0x%08x)", o.crc, r.crc);
            std::printf("%-40s %-7s (MesenCE %s) frame %ld %s\n", r.id.c_str(), o.result.c_str(),
                        r.result.c_str(), o.frames, crcs);
            if (o.result != r.result) {
                std::string t = o.text;
                std::replace(t.begin(), t.end(), '\n', '|');
                failures.push_back(r.id + ": " + o.result + ", MesenCE " + r.result + " [" + t + "]");
            } else if (o.crc != r.crc && !kFrameNotChecked.count(r.id)) {
                failures.push_back(r.id + ": frame " + std::to_string(o.frames) + " " + crcs);
            }
        }
    };
    unsigned n = std::min<unsigned>(std::max(1u, std::thread::hardware_concurrency() / 2), 6);
    if (const char* j = std::getenv("RS_GB_JOBS")) n = std::max(1, std::atoi(j));
    std::vector<std::thread> threads;
    for (unsigned i = 0; i < n; i++) threads.emplace_back(worker);
    for (auto& th : threads) th.join();

    std::sort(failures.begin(), failures.end());
    std::string report;
    for (auto& f : failures) report += "\n  " + f;
    INFO(todo.size() << " ROMs, " << failures.size() << " differ from MesenCE" << report);
    CHECK(failures.empty());
}
