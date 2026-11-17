// SPDX-License-Identifier: Apache-2.0
// systems/game-boy's HDMI output (gb_video) as the Tang Nano 20K runs it (make_gb_hdmi_sim): a
// receiver decodes every pixel clock, and each display frame must have 720p's timing (DVI: no
// sound until the APU), and the frame that shows a ROM's checked frame must show it, 5 times its
// size each way, its shades grey, black around it, with the video CRC of
// harness/golden/gb_hdmi_crc32.txt. Skipped when the ROMs aren't fetched.
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <vector>

#include "rig/crc32.hpp"
#include "rig/gb.hpp"
#include "rig/shell.hpp"
#include "rig/sim_systems.hpp"
#include "tmds_model.hpp"

namespace {

// A DVI receiver for 1280x720 at 60 Hz: it decodes each pixel clock, finds the frames, and checks
// each against CEA-861's layout. With `expect` set it also checks the picture: the Game Boy's
// frame 5 times its size from (240, 0), shade 0 white to 3 black, black around it. It takes each
// frame's CRC as gb_video does.
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
    const std::vector<uint8_t>* expect = nullptr;

    void operator()(uint32_t sym) {
        auto s0 = tmds::decode(static_cast<uint16_t>(sym & 0x3ff));
        auto s1 = tmds::decode(static_cast<uint16_t>((sym >> 10) & 0x3ff));
        auto s2 = tmds::decode(static_cast<uint16_t>(sym >> 20));
        const bool video = !s0.control;
        if (idx_ < 0) {  // finding the first frame: the first picture after a vertical sync
            if (s0.control && (s0.c & 2)) seen_vsync_ = true;
            if (!seen_vsync_ || !video) return;
            idx_ = 0;
            cur_ = Result{};
            crc_ = 0xFFFFFFFFu;
        }
        for (int b = 0; b < 30; b++) {
            bool fb = (crc_ ^ (sym >> b)) & 1;
            crc_ = (crc_ >> 1) ^ (fb ? 0xEDB88320u : 0);
        }
        unsigned x = static_cast<unsigned>(idx_) % kH, y = static_cast<unsigned>(idx_) / kH;
        bool act = x < kHa && y < kVa;
        if (act != video || s1.control == act || s2.control == act) cur_.timing = false;
        if (act) {
            uint32_t rgb = static_cast<uint32_t>(s2.d) << 16 | s1.d << 8 | s0.d;
            bool pic = x >= kX0 && x < kX0 + 800 && y >= kY0 && y < kY0 + 720;
            if (!pic) {
                if (rgb != 0) cur_.timing = false;
            } else if (expect && rgb != kGrey[(*expect)[((y - kY0) / 5) * 160 + (x - kX0) / 5] & 3]) {
                cur_.picture = false;
            }
        } else {
            unsigned vline = x >= 1390 ? y : (y == 0 ? kV - 1 : y - 1);
            unsigned want = (vline >= 725 && vline < 730) << 1 | (x >= 1390 && x < 1430);
            if (s0.c != want || s1.c != 0 || s2.c != 0) cur_.timing = false;
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
    r.boot = read_file(dir + "/" + rig::gb::kDmgBoot);
    for (const auto& g : rig::gb::load_golden(RS_GB_GOLDEN)) {
        if (g.id != id) continue;
        r.g = g;
        r.rom = read_file(dir + "/" + g.path);
        if (r.rom.empty() || r.boot.empty()) return std::nullopt;
        return r;
    }
    FAIL(id << " isn't in gb_frames_crc32.txt");
    return std::nullopt;
}

// The frame buffer at frame `frame`, in the sim without a display: its CRC must be MesenCE's.
std::vector<uint8_t> frame_at(const Rom& r, uint32_t frame) {
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
    for (uint8_t v : f) two.insert(two.end(), {v, 0});
    rig::Crc32 crc;
    crc.update(two);
    if (!rig::gb::frame_not_checked().count(r.g.id)) REQUIRE(crc.value() == r.g.crc);
    return f;
}

// Runs a ROM with HDMI to its golden frame and decodes the output: the display frame whose CRC
// gb_video reports must be one the receiver saw, showing that frame, every frame must have the
// right timing, and the video CRC must be the golden list's.
void matches_golden(const std::string& id) {
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
    auto link = rig::make_gb_hdmi_sim([&rx](uint32_t s) { rx(s); });
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
}

} // namespace

TEST_CASE("Game Boy HDMI: a receiver sees dmg-acid2's frame at 720p, 5 times its size") {
    matches_golden("dmg-acid2");
}

TEST_CASE("Game Boy HDMI: a receiver sees mts-ei_sequence's pass screen at 720p") {
    matches_golden("mts-ei_sequence");
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
