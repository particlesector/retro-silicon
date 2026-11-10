// SPDX-License-Identifier: Apache-2.0
// systems/atari-2600's HDMI output (a2600_video) as the Tang Nano 20K runs it (make_a2600_hdmi_sim):
// a receiver decodes every pixel clock, and each display frame must have 720p's timing, the frame
// that shows a cartridge's golden frame must show it (6 x 3 times its size through the TIA's
// colours, black around it), and the sound must be every sample the system made. Skipped when the
// cartridges aren't fetched.
#include <catch2/catch_test_macros.hpp>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

#include "rig/a2600.hpp"
#include "rig/crc32.hpp"
#include "rig/shell.hpp"
#include "rig/sim_systems.hpp"
#include "tmds_model.hpp"

namespace {

// The TIA's colours as the RTL has them (components/video/tia/rtl/tia_rgb.sv), by {hue, luma}.
std::array<uint32_t, 128> palette() {
    std::array<uint32_t, 128> pal{};
    std::ifstream f(RS_TIA_RGB_SV);
    std::regex entry(R"(7'h([0-9a-f]{2}): rgb <= 24'h([0-9a-f]{6});)");
    std::string line;
    int n = 0;
    while (std::getline(f, line)) {
        std::smatch m;
        if (std::regex_search(line, m, entry)) {
            pal[std::stoul(m[1], nullptr, 16)] = static_cast<uint32_t>(std::stoul(m[2], nullptr, 16));
            n++;
        }
    }
    REQUIRE(n == 128);
    return pal;
}

// harness/golden/a2600_hdmi_crc32.txt: id, frames, the video CRC of the display frame showing
// frame `frames`.
std::map<std::string, uint32_t> golden_video() {
    std::map<std::string, uint32_t> out;
    std::ifstream f(RS_A2600_HDMI_GOLDEN);
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

// An HDMI receiver for 1280x720 at 60 Hz, as harness/tests/hdmi_test.cpp's for the NES: it decodes
// each pixel clock (tmds::HdmiDecoder, which keeps the audio and checks every packet), finds the
// frames, and checks each against CEA-861's layout and video/hdmi's islands and preambles. With
// `expect` set it also checks the picture: the 2600 frame 6 x 3 times its size from (160, 18),
// through `pal`, black around it. It takes each frame's CRC as a2600_video does, the data islands'
// packets as 0.
class Receiver {
public:
    static constexpr unsigned kH = 1650, kV = 750, kHa = 1280, kVa = 720, kX0 = 160, kY0 = 18;

    struct Result {
        uint32_t crc = 0;
        bool timing = true;   // syncs, blanking and the black border where they belong
        bool picture = true;  // the picture is `expect`'s
        bool black = true;    // the picture is all black
        size_t samples = 0;   // the sound's samples received by the frame's end
    };
    std::vector<Result> frames;
    const std::vector<uint8_t>* expect = nullptr;
    std::array<uint32_t, 128> pal{};
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
        uint32_t csym = px.period == Period::Island ? 0 : sym;
        for (int b = 0; b < 30; b++) {
            bool fb = (crc_ ^ (csym >> b)) & 1;
            crc_ = (crc_ >> 1) ^ (fb ? 0xEDB88320u : 0);
        }
        unsigned x = static_cast<unsigned>(idx_) % kH, y = static_cast<unsigned>(idx_) / kH;
        bool act = x < kHa && y < kVa;
        if (act != (px.period == Period::Video)) cur_.timing = false;
        if (act) {
            uint32_t rgb = px.d[2] << 16 | px.d[1] << 8 | px.d[0];
            bool pic = x >= kX0 && x < kX0 + 960 && y >= kY0 && y < kY0 + 684;
            if (!pic) {
                if (rgb != 0) cur_.timing = false;
            } else {
                if (rgb != 0) cur_.black = false;
                if (expect && rgb != pal[(*expect)[((y - kY0) / 3) * 160 + (x - kX0) / 6] >> 1])
                    cur_.picture = false;
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
            cur_.samples = dec.samples.size();
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

struct Cart {
    rig::a2600::Golden g;
    std::vector<uint8_t> rom;
    rig::a2600::Paddles paddles = rig::a2600::kNoPaddles;
};

// A cartridge of a2600_frames_crc32.txt, or nothing if it isn't fetched.
std::optional<Cart> cart(const std::string& id) {
    const char* roms = std::getenv("RS_TESTROMS");
    const auto paddles = rig::a2600::load_paddles(RS_A2600_PADDLES);
    for (const auto& g : rig::a2600::load_golden(RS_A2600_GOLDEN)) {
        if (g.id != id) continue;
        std::ifstream f(std::string(roms ? roms : RS_TESTROMS) + "/" + g.path, std::ios::binary);
        if (!f) return std::nullopt;
        Cart c{g, std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), {})};
        if (auto p = paddles.find(id); p != paddles.end()) c.paddles = p->second;
        return c;
    }
    FAIL(id << " isn't in a2600_frames_crc32.txt");
    return std::nullopt;
}

// The golden frame from the frame buffer, in the sim without a display: its CRC must be Stella's.
std::vector<uint8_t> golden_frame(const Cart& c) {
    auto link = rig::make_a2600_sim();
    rig::shell::Client client(*link);
    rig::a2600::Console vcs(client);
    vcs.hold_reset();
    REQUIRE_FALSE(vcs.load(c.rom));
    vcs.set_paddles(c.paddles);
    vcs.stop_frame(c.g.frames);
    vcs.run();
    vcs.wait_stopped();
    auto f = vcs.frame();
    rig::Crc32 crc;
    crc.update(f);
    REQUIRE(crc.value() == c.g.crc);
    return f;
}

// Runs a cartridge with HDMI and decodes its output: the display frame whose CRC a2600_video
// reports must be one the receiver saw, showing the golden frame, every frame must have the
// right timing, and the sound must be the system's samples. Returns the video CRC.
std::optional<uint32_t> on_hdmi(const std::string& id) {
    auto c = cart(id);
    if (!c) {
        WARN("skipped: " << id << " isn't fetched");
        return std::nullopt;
    }
    auto frame = golden_frame(*c);
    Receiver rx;
    rx.expect = &frame;
    rx.pal = palette();
    auto link = rig::make_a2600_hdmi_sim([&rx](uint32_t s) { rx(s); });
    auto r = rig::a2600::hdmi_test(*link, id, c->rom, c->g.frames, c->g.crc, c->paddles, RS_A2600_BUILD_ID);
    INFO(r.detail << " / " << r.notes);
    REQUIRE(r.passed);
    rig::shell::Client client(*link);
    rig::a2600::Console vcs(client);
    auto [pcm_crc, pcm_n] = vcs.pcm();
    INFO((rx.dec.errors.empty() ? std::string("no HDMI errors") : rx.dec.errors[0]));
    CHECK(rx.dec.errors.empty());
    CHECK(rx.dec.n == 6144);
    CHECK(rx.dec.cts == 74250);
    CHECK(pcm_n > 790 * (c->g.frames - 1));
    // The system's samples, every one in order, among those the receiver heard: after the FIFO's
    // start (repeats of the last sample, 0 from reset) and before its end (it ran dry when the run
    // stopped, which hdmi_test waited for). The system's run starts with samples of 0 too, so each
    // start up to the first sample that isn't is tried.
    const auto& hs = rx.dec.samples;
    bool same = true;
    for (auto [l, rr] : hs) same = same && l == rr;
    CHECK(same);
    std::array<uint32_t, 256> tab{};
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t v = i;
        for (int k = 0; k < 8; k++) v = (v >> 1) ^ (v & 1 ? 0xEDB88320u : 0);
        tab[i] = v;
    }
    auto crc_of = [&](size_t from) {
        uint32_t crc = 0xFFFFFFFFu;
        for (size_t i = from; i < from + pcm_n; i++) {
            auto u = static_cast<uint16_t>(hs[i].first);
            crc = (crc >> 8) ^ tab[(crc ^ u) & 0xFF];
            crc = (crc >> 8) ^ tab[(crc ^ (u >> 8)) & 0xFF];
        }
        return ~crc;
    };
    size_t first = 0;
    while (first < hs.size() && hs[first].first == 0) first++;
    bool found = false;
    for (size_t from = 0; from <= first && from + pcm_n <= hs.size() && !found; from++)
        found = crc_of(from) == pcm_crc;
    CHECK(found);
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
    // The sound comes at 48 kHz, 800 samples in every display frame, whatever the 2600's frames'
    // length, or a receiver's buffer fills or runs dry and it mutes.
    for (size_t i = 1; i < rx.frames.size(); i++) {
        INFO("display frame " << i);
        CHECK(rx.frames[i].samples - rx.frames[i - 1].samples == 800);
    }
    return r.crc32;
}

void matches_golden(const std::string& id) {
    auto crc = on_hdmi(id);
    if (!crc) return;
    auto golden = golden_video();
    INFO("video CRC 0x" << std::hex << *crc);
    REQUIRE(golden.count(id));
    CHECK(*crc == golden[id]);
}

} // namespace

TEST_CASE("a2600 HDMI: a receiver sees tia_colours's frame at 720p, every colour as tia_rgb has it") {
    matches_golden("tia_colours");
}

TEST_CASE("a2600 HDMI: a receiver sees tia_playfield's frame and hears its sound") {
    matches_golden("tia_playfield");
}

TEST_CASE("a2600 HDMI: a receiver hears tia_audio's sound as the system made it") {
    matches_golden("tia_audio");
}

TEST_CASE("a2600 HDMI: the 2600 makes a frame of 262 lines in at most 98.5% of a display frame") {
    // Keeping pace, each frame has to be ready within a display frame, or it waits for the next and
    // the display shows the last one twice. At NTSC's rate a frame of 262 lines takes 100.1% of a
    // 60 Hz display frame, so the colour clock runs 2% fast. Measured with pacing off.
    auto c = cart("tia_colours");
    if (!c) {
        WARN("skipped: tia_colours isn't fetched");
        return;
    }
    uint64_t pix = 0;
    auto link = rig::make_a2600_hdmi_sim([&pix](uint32_t) { pix++; });
    rig::shell::Client client(*link);
    rig::a2600::Console vcs(client);
    vcs.hold_reset();
    REQUIRE_FALSE(vcs.load(c->rom));
    vcs.pace(false);
    vcs.run();
    while (vcs.frames() < 3) {
    }
    uint32_t f0 = vcs.frames();
    uint64_t p0 = pix;
    while (vcs.frames() < f0 + 4) {
    }
    uint32_t frames = vcs.frames() - f0;
    double shown = static_cast<double>(pix - p0) / (1650.0 * 750.0);
    INFO(frames << " frames in " << shown << " display frames");
    CHECK(shown <= 0.985 * frames + 0.03);  // + the last frame's part, read late
    CHECK(shown >= 0.97 * frames);
}
