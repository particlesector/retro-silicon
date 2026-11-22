// SPDX-License-Identifier: Apache-2.0
// systems/game-boy's HDMI output (gb_video) as the Tang Nano 20K runs it (make_gb_hdmi_sim): a
// receiver decodes every pixel clock as a sink does, and each display frame must have 720p's
// timing, the frame that shows a ROM's checked frame must show it, 5 times its size each way, its
// shades grey, black around it, with the video CRC of harness/golden/gb_hdmi_crc32.txt, and the
// sound's samples must all arrive, in order: the ones gb_sys counted and took the CRC of. Skipped
// when the ROMs aren't fetched.
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <iterator>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "rig/crc32.hpp"
#include "rig/gb.hpp"
#include "rig/shell.hpp"
#include "rig/sim_systems.hpp"
#include "tmds_model.hpp"

namespace {

// An HDMI receiver for 1280x720 at 60 Hz: it decodes each pixel clock (tmds::HdmiDecoder, which
// keeps the audio and checks every packet), finds the frames, and checks each against CEA-861's
// layout. With `expect` set it also checks the picture: the Game Boy's frame 5 times its size from
// (240, 0), shade 0 white to 3 black (or the Color's colours, corrected), black around it. It takes each frame's CRC as gb_video does,
// the data islands' packets as 0.
class Receiver {
public:
    static constexpr unsigned kH = 1650, kV = 750, kHa = 1280, kVa = 720, kX0 = 240, kY0 = 0;
    static constexpr uint32_t kGrey[4] = {0xFFFFFF, 0xAAAAAA, 0x555555, 0x000000};

    struct Result {
        uint32_t crc = 0;
        bool timing = true;   // syncs, blanking and the black border where they belong
        bool picture = true;  // the picture is `expect`'s
    };
    std::vector<Result> frames;
    const std::vector<uint32_t>* expect = nullptr;  // each Game Boy pixel's colour, 0xRRGGBB
    tmds::HdmiDecoder dec;

    void operator()(uint32_t sym) {
        auto px = dec(static_cast<uint16_t>(sym & 0x3ff), static_cast<uint16_t>((sym >> 10) & 0x3ff),
                      static_cast<uint16_t>(sym >> 20));
        using tmds::Period;
        if (idx_ < 0) {  // finding the first frame: the first picture after a vertical sync
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
            uint32_t rgb = static_cast<uint32_t>(px.d[2]) << 16 | px.d[1] << 8 | px.d[0];
            bool pic = x >= kX0 && x < kX0 + 800 && y >= kY0 && y < kY0 + 720;
            if (!pic) {
                if (rgb != 0) cur_.timing = false;
            } else if (expect && rgb != (*expect)[((y - kY0) / 5) * 160 + (x - kX0) / 5]) {
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

std::vector<uint8_t> read_file(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(f), {}};
}

struct Rom {
    rig::gb::Golden g;
    std::vector<uint8_t> rom, boot;
};

std::optional<Rom> rom(const std::string& id) {
    const char* env = std::getenv("RS_TESTROMS");
    const std::string dir = env ? env : RS_TESTROMS;
    Rom r;
    for (const auto& g : rig::gb::load_golden(RS_GB_GOLDEN)) {
        if (g.id != id) continue;
        r.g = g;
        r.boot = read_file(dir + "/" + rig::gb::boot_for(g.model));
        r.rom = read_file(dir + "/" + g.path);
        if (r.rom.empty() || r.boot.empty()) return std::nullopt;
        return r;
    }
    FAIL(id << " isn't in gb_frames_crc32.txt");
    return std::nullopt;
}

// The frame buffer at frame `frame`, in the sim without a display (its CRC must be MesenCE's), as
// each pixel's colour on HDMI (0xRRGGBB).
std::vector<uint32_t> frame_at(const Rom& r, uint32_t frame) {
    auto link = rig::make_gb_sim();
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    gb.hold_reset();
    REQUIRE_FALSE(gb.load(r.rom, r.boot));
    gb.stop_frame(frame);
    gb.run();
    gb.wait_stopped();
    auto f = gb.frame();
    REQUIRE(f.size() == 160u * 144u);
    std::vector<uint8_t> two;
    std::vector<uint32_t> rgb;
    for (uint16_t v : f) {
        two.insert(two.end(), {static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8)});
        rgb.push_back(r.g.model == "cgb" ? rig::gb::color_rgb(v) : Receiver::kGrey[v & 3]);
    }
    rig::Crc32 crc;
    crc.update(two);
    if (!rig::gb::frame_not_checked().count(r.g.id)) REQUIRE(crc.value() == r.g.crc);
    return rgb;
}

// Runs a ROM with HDMI to its golden frame and decodes the output: the display frame whose CRC
// gb_video reports must be one the receiver saw, showing that frame, every frame must have the
// right timing, and the video CRC must be the golden list's.
using MakeHdmi = std::function<std::unique_ptr<rig::SimLink>(std::function<void(uint32_t)>)>;

void matches_golden(const std::string& id, const MakeHdmi& make = rig::make_gb_hdmi_sim) {
    auto r = rom(id);
    if (!r) {
        WARN("skipped: " << id << " isn't fetched");
        return;
    }
    const auto golden = rig::gb::load_hdmi_golden(RS_GB_HDMI_GOLDEN);
    REQUIRE(golden.count(id));
    const auto want = golden.at(id);
    auto frame = frame_at(*r, want.frame);
    Receiver rx;
    rx.expect = &frame;
    auto link = make([&rx](uint32_t s) { rx(s); });
    auto res = rig::gb::hdmi_test(*link, r->g, r->rom, r->boot, want.frame, RS_GB_BUILD_ID);
    INFO(res.detail << " / " << res.notes);
    REQUIRE(res.passed);
    REQUIRE(rx.frames.size() > 2);
    int matched = 0;
    for (size_t i = 0; i < rx.frames.size(); i++) {
        INFO("display frame " << i);
        CHECK(rx.frames[i].timing);
        if (rx.frames[i].crc == res.crc32) {
            matched++;
            CHECK(rx.frames[i].picture);
        }
    }
    CHECK(matched >= 1);
    INFO("video CRC 0x" << std::hex << res.crc32);
    CHECK(res.crc32 == want.crc);
    // The sound: every sample pair gb_sys sent, in order.
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    auto [pcm_crc, pcm_n] = gb.pcm();
    INFO((rx.dec.errors.empty() ? std::string("no HDMI errors") : rx.dec.errors[0]));
    CHECK(rx.dec.errors.empty());
    CHECK(rx.dec.n == 6144);
    CHECK(pcm_n > 800 * (want.frame - 2));
    REQUIRE(rx.dec.samples.size() == pcm_n);
    rig::Crc32 c;
    for (auto [l, rr] : rx.dec.samples) {
        const uint16_t ul = static_cast<uint16_t>(l), ur = static_cast<uint16_t>(rr);
        c.update(std::vector<uint8_t>{static_cast<uint8_t>(ul), static_cast<uint8_t>(ul >> 8),
                                      static_cast<uint8_t>(ur), static_cast<uint8_t>(ur >> 8)});
    }
    CHECK(c.value() == pcm_crc);
}

} // namespace

TEST_CASE("Game Boy HDMI: a receiver sees dmg-acid2's frame at 720p, 5 times its size") {
    matches_golden("dmg-acid2");
}

TEST_CASE("Game Boy HDMI: a receiver sees mts-ei_sequence's pass screen at 720p") {
    matches_golden("mts-ei_sequence");
}

TEST_CASE("Game Boy Color HDMI: a receiver sees cgb-acid2's frame at 720p in corrected colours") {
    matches_golden("cgb-acid2", rig::make_gb_console_sim);
}

TEST_CASE("Game Boy HDMI on the Tang Console 138K and the PYNQ-Z2: mts-ei_sequence with the 20K's video CRC") {
    matches_golden("mts-ei_sequence", rig::make_gb_console_sim);
}

TEST_CASE("Game Boy HDMI: the Game Boy makes a frame in at most 98.7% of a display frame") {
    // Keeping pace, each frame has to be ready within a display frame, or it waits for the next and
    // the display shows the last one twice. At the console's rate a frame of 70,224 T-cycles takes
    // 100.5% of a 60 Hz display frame, so the T-cycles run 1.9% fast. Measured with pacing off.
    auto r = rom("dmg-acid2");
    if (!r) {
        WARN("skipped: dmg-acid2 isn't fetched");
        return;
    }
    uint64_t pix = 0;
    auto link = rig::make_gb_hdmi_sim([&pix](uint32_t) { pix++; });
    rig::shell::Client client(*link);
    rig::gb::Console gb(client);
    gb.hold_reset();
    REQUIRE_FALSE(gb.load(r->rom, r->boot));
    gb.pace(false);
    gb.run();
    // Past the boot ROM and dmg-acid2's setup, where a frame that ends as the LCD turns on or off can
    // be short: from frame 60 its frames are 70,224 T-cycles each.
    while (gb.frames() < 60) {
    }
    uint32_t f0 = gb.frames();
    uint64_t p0 = pix;
    while (gb.frames() < f0 + 4) {
    }
    uint32_t frames = gb.frames() - f0;
    double shown = static_cast<double>(pix - p0) / (1650.0 * 750.0);
    INFO(frames << " frames in " << shown << " display frames");
    CHECK(shown <= 0.987 * frames + 0.03);  // + the last frame's part, read late
    CHECK(shown >= 0.98 * frames);
}
