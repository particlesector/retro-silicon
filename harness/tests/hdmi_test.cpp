// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <array>
#include <cstdint>
#include <fstream>
#include <map>
#include <optional>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

#include "nes_rom.hpp"
#include "rig/nes.hpp"
#include "rig/shell.hpp"
#include "rig/sim_systems.hpp"
#include "tmds_model.hpp"

namespace {

// The 2C02's colours as the RTL has them (components/video/ppu-2c02/rtl/ppu_2c02_rgb.sv).
std::array<uint32_t, 512> palette() {
    std::array<uint32_t, 512> pal{};
    std::ifstream f(RS_PPU_RGB_SV);
    std::regex entry(R"(9'h([0-9a-f]{3}): rgb <= 24'h([0-9a-f]{6});)");
    std::string line;
    int n = 0;
    while (std::getline(f, line)) {
        std::smatch m;
        if (std::regex_search(line, m, entry)) {
            pal[std::stoul(m[1], nullptr, 16)] = static_cast<uint32_t>(std::stoul(m[2], nullptr, 16));
            n++;
        }
    }
    REQUIRE(n == 512);
    return pal;
}

// harness/golden/nes_hdmi_crc32.txt: id, frames, the video CRC of the display
// frame showing frame `frames - 1`.
std::map<std::string, uint32_t> golden_video() {
    std::map<std::string, uint32_t> out;
    std::ifstream f(RS_NES_HDMI_GOLDEN);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        std::string id, crc;
        uint32_t frames;
        ss >> id >> frames >> crc;
        out[id] = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
    }
    return out;
}

// An HDMI receiver for 1280x720 at 60 Hz: decodes each pixel clock as a sink
// does (tmds::HdmiDecoder, which keeps the audio and checks every packet),
// finds the frames (the first picture pixel after a vertical sync), and
// checks every frame against CEA-861's layout and nes_video's HDMI: the
// syncs where they belong, a data island after each line's picture, the
// video preamble and guard band before each picture line, control symbols
// elsewhere. With `expect` set it also checks the picture: the NES frame
// three times its size from x = 256, through `pal`, black around it. It takes
// each frame's CRC as nes_video does, the data islands' packets as 0.
class Receiver {
public:
    static constexpr unsigned kH = 1650, kV = 750, kHa = 1280, kVa = 720, kX0 = 256;

    struct Result {
        uint32_t crc = 0;
        bool timing = true;   // syncs, blanking and the black border as CEA-861 and nes_video put them
        bool picture = true;  // the picture is `expect`'s
        bool black = true;    // the picture is all black
    };
    std::vector<Result> frames;
    const rig::nes::Frame* expect = nullptr;
    std::array<uint32_t, 512> pal{};
    tmds::HdmiDecoder dec;

    void operator()(uint32_t sym) {
        auto px = dec(static_cast<uint16_t>(sym & 0x3ff), static_cast<uint16_t>((sym >> 10) & 0x3ff),
                      static_cast<uint16_t>(sym >> 20));
        using tmds::Period;
        if (idx_ < 0) {  // finding the first frame
            bool vs = px.period != Period::Video && px.period != Period::VideoGuard && (px.sync & 2);
            if (vs) seen_vsync_ = true;
            if (!seen_vsync_ || px.period != Period::Video) return;
            idx_ = 0;
            cur_ = Result{};
            crc_ = 0xFFFFFFFFu;
        }
        uint32_t csym = px.period == Period::Island ? 0 : sym;  // nes_video's CRC leaves the packets out
        for (int b = 0; b < 30; b++) {
            bool fb = (crc_ ^ (csym >> b)) & 1;
            crc_ = (crc_ >> 1) ^ (fb ? 0xEDB88320u : 0);
        }
        unsigned x = static_cast<unsigned>(idx_) % kH, y = static_cast<unsigned>(idx_) / kH;
        bool act = x < kHa && y < kVa;
        if (act != (px.period == Period::Video)) cur_.timing = false;
        if (act) {
            uint32_t rgb = px.d[2] << 16 | px.d[1] << 8 | px.d[0];
            bool pic = x >= kX0 && x < kX0 + 768;
            if (!pic) {
                if (rgb != 0) cur_.timing = false;
            } else {
                if (rgb != 0) cur_.black = false;
                if (expect && rgb != pal[(*expect)[(y / 3) * 256 + (x - kX0) / 3]]) cur_.picture = false;
            }
        } else {
            unsigned vline = x >= 1390 ? y : (y == 0 ? kV - 1 : y - 1);
            unsigned want = (vline >= 725 && vline < 730) << 1 | (x >= 1390 && x < 1430);
            if (px.period != Period::VideoGuard && px.sync != want) cur_.timing = false;
            bool next_pic = y + 1 < kVa || y == kV - 1;
            Period p = x >= 1284 && x < 1292   ? Period::IslandPreamble
                       : x >= 1292 && x < 1294 ? Period::IslandGuard
                       : x >= 1294 && x < 1358 ? Period::Island
                       : x >= 1358 && x < 1360 ? Period::IslandGuard
                       : next_pic && x >= kH - 10 && x < kH - 2 ? Period::VideoPreamble
                       : next_pic && x >= kH - 2               ? Period::VideoGuard
                                                                : Period::Control;
            if (px.period != p) cur_.timing = false;
        }
        if (++idx_ == static_cast<long>(kH * kV)) {
            cur_.crc = ~crc_;
            frames.push_back(cur_);
            idx_ = 0;
            cur_ = Result{};
            crc_ = 0xFFFFFFFFu;
        }
    }

private:
    long idx_ = -1;
    bool seen_vsync_ = false;
    Result cur_;
    uint32_t crc_ = 0xFFFFFFFFu;
};

// A ROM's golden frame, captured line by line in the fast sim: its CRC must
// be MesenCE's.
rig::nes::Frame golden_frame(const rig::nes::GoldenRom& g, const rig::NesRom& rom) {
    auto link = rig::make_nes_sim();
    rig::shell::Client client(*link);
    rig::nes::Console nes(client);
    nes.hold_reset();
    REQUIRE_FALSE(nes.load(rom));
    nes.set_vector(std::nullopt);
    nes.stop_frame(g.frames - 1);
    nes.run();
    nes.wait_stopped();
    auto f = nes.capture(g.frames - 1);
    REQUIRE(rig::nes::frame_crc(f) == g.crc);
    return f;
}

// Runs a ROM on the NES with HDMI and decodes its output: the display frame
// whose CRC nes_video reports must be one the receiver saw, showing the
// ROM's golden frame, and every frame the receiver saw must have the right
// timing. Returns the video CRC.
uint32_t on_hdmi(const std::string& id) {
    auto [g, rom] = golden_rom(id);
    auto frame = golden_frame(g, rom);
    Receiver rx;
    rx.expect = &frame;
    rx.pal = palette();
    auto link = rig::make_nes_hdmi_sim([&rx](uint32_t s) { rx(s); });
    auto r = rig::nes::hdmi_test(*link, id, rom, g.frames, RS_NES_BUILD_ID);
    INFO(r.detail << " / " << r.notes);
    REQUIRE(r.passed);
    // The sound: every sample the system made, in order, on both channels.
    rig::shell::Client client(*link);
    rig::nes::Console nes(client);
    auto [pcm_crc, pcm_n] = nes.pcm();
    INFO((rx.dec.errors.empty() ? std::string("no HDMI errors") : rx.dec.errors[0]));
    CHECK(rx.dec.errors.empty());
    CHECK(rx.dec.n == 6144);
    CHECK(rx.dec.cts == 74250);
    CHECK(pcm_n > 800 * (g.frames - 2));
    REQUIRE(rx.dec.samples.size() == pcm_n);
    uint32_t c = 0xFFFFFFFFu;
    bool same = true;
    for (auto [l, rr] : rx.dec.samples) {
        same = same && l == rr;
        for (uint8_t b : {static_cast<uint8_t>(l), static_cast<uint8_t>(static_cast<uint16_t>(l) >> 8)}) {
            c ^= b;
            for (int k = 0; k < 8; k++) c = (c >> 1) ^ (c & 1 ? 0xEDB88320u : 0);
        }
    }
    CHECK(same);
    CHECK(~c == pcm_crc);
    REQUIRE(rx.frames.size() > 2);
    int matched = 0;
    for (size_t i = 0; i < rx.frames.size(); i++) {
        INFO("display frame " << i);
        CHECK(rx.frames[i].timing);
        if (rx.frames[i].crc == r.crc32) {
            matched++;
            CHECK(rx.frames[i].picture);
            CHECK_FALSE(rx.frames[i].black);
        }
    }
    CHECK(matched >= 1);
    return r.crc32;
}

} // namespace

TEST_CASE("HDMI: a receiver sees oam_read's frame at 720p, three times its size, with nes_video's CRC") {
    uint32_t crc = on_hdmi("oam_read");
    auto golden = golden_video();
    INFO("video CRC 0x" << std::hex << crc);
    REQUIRE(golden.count("oam_read"));
    CHECK(crc == golden["oam_read"]);
}

TEST_CASE("HDMI: a receiver sees full_palette's every colour as the 2C02 palette has it") {
    uint32_t crc = on_hdmi("full_palette");
    auto golden = golden_video();
    INFO("video CRC 0x" << std::hex << crc);
    REQUIRE(golden.count("full_palette"));
    CHECK(crc == golden["full_palette"]);
}
