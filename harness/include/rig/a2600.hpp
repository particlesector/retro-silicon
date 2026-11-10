// SPDX-License-Identifier: Apache-2.0
#pragma once
// Host side of systems/atari-2600's a2600_sys: its shell address map and registers, loading a
// cartridge, and the golden-frame test.

#include <array>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "rig/link.hpp"
#include "rig/shell.hpp"
#include "rig/test_result.hpp"

namespace rig::a2600 {

constexpr uint32_t kCart = 0x00000000;   // the cartridge, 4 KB
constexpr uint32_t kRegs = 0x01000000;
constexpr uint32_t kFrameBuffer = 0x05000000;  // y x 160 + x
constexpr int kWidth = 160, kHeight = 228;

enum Reg : uint32_t {
    kCtrl = 0x00,        // bit 0 run, bit 1 hold the system in reset
    kStopCycle = 0x04,   // 4 bytes: stop once this many CPU cycles have run since reset; 0 never
    kCycles = 0x08,      // 4 bytes, read-only: CPU cycles since reset
    kStatus = 0x0C,      // read-only, see Status
    kStopFrame = 0x10,   // 4 bytes: stop once this many frames have ended since reset; 0 never
    kFrames = 0x14,      // 4 bytes, read-only: frames ended since reset
    kFrameCrc = 0x18,    // 4 bytes, read-only: CRC-32 of frame kCrcFrame
    kCrcFrame = 0x1C,    // 4 bytes, read-only: which frame (counting from 1); 0 none yet
    kAudioCrc = 0x20,    // 4 bytes, read-only: CRC-32 of the sound's first kAudioLimit samples
    kSamples = 0x24,     // 4 bytes, read-only: samples since reset
    kAudioLimit = 0x28,  // 4 bytes: samples the audio CRC takes; 0 all
    kJoy = 0x2C,         // SWCHA's pins (0 pressed)
    kSwitches = 0x2D,    // SWCHB's pins
    kFire = 0x2E,        // bits 1-0: INPT5, INPT4 (0 pressed)
    kPaddleOn = 0x2F,    // bits 3-0: a paddle in INPT3-0
    kPaddlePos = 0x30,   // 4 bytes: paddle i's knob in bits 8i+7:8i
    // With a display (a2600_sys's VIDEO):
    kVideo = 0x34,       // bit 0 keep pace with the display; write bit 1 to take the video CRC
    kVideoWhole = 0x36,  // bit 0: the video CRC's display frame showed its frame whole
    kVcapFrame = 0x38,   // 4 bytes: the video CRC is of the display frame showing frame kVcapFrame + 1
    kVideoCrc = 0x3C,    // 4 bytes, read-only
    kVideoShown = 0x40,  // 2 bytes, read-only: display frames whose frame started on request
    kVideoLate = 0x42,   // 2 bytes, read-only: lines late
    kVideoOverrun = 0x44,  // 2 bytes, read-only: lines overwritten before they were shown
    kVideoGaps = 0x46,     // 2 bytes, read-only: the HDMI sound ran dry while playing, or dropped a sample
    kPcmCrc = 0x48,      // 4 bytes, read-only: CRC-32 of every 48 kHz sample (16 bits, little-endian)
    kPcmCount = 0x4C,    // 4 bytes, read-only: how many
};

enum Status : uint8_t { kStopped = 1, kRunning = 2, kCrcValid = 4, kBusy = 8, kVideoCrcValid = 16 };

// The display's counts and the video CRC asked for.
struct Video {
    bool valid = false;  // the CRC asked for has come
    bool whole = false;  // ...and its display frame showed its frame whole
    uint32_t crc = 0;
    uint16_t shown = 0, late = 0, overrun = 0;
    uint16_t gaps = 0;   // the HDMI sound ran dry while playing, or dropped a sample
};

// Paddles in INPT0-3, each a knob position (a pot of n / 256 Mohm), or -1 for none.
using Paddles = std::array<int, 4>;
inline constexpr Paddles kNoPaddles{-1, -1, -1, -1};

// a2600_sys through its test shell. Every call is an absolute register write or read.
class Console {
public:
    explicit Console(shell::Client& c) : c_(c) {}

    void hold_reset();
    // Writes the cartridge (2 or 4 KB; a 2 KB one twice) and checks it reads back; an error message
    // if it doesn't.
    std::optional<std::string> load(const std::vector<uint8_t>& rom);
    void set_paddles(const Paddles& p);
    void stop_frame(uint32_t n);
    void audio_limit(uint32_t samples);
    void run();  // out of reset, running
    // Waits until the system stops at a limit and the CRC of the frame it stopped on is taken.
    void wait_stopped();

    uint8_t status();
    uint32_t frames();
    uint32_t cycles();
    std::optional<std::pair<uint32_t, uint32_t>> frame_crc();  // {CRC, frame}
    uint32_t audio_crc();
    uint32_t samples();
    std::vector<uint8_t> frame();  // the frame buffer: 160 x 228 colour values

    // With a display:
    void pace(bool on);
    // Keeps pace and takes the video CRC of the display frame showing frame `index` + 1.
    void arm_video_crc(uint32_t index);
    Video video();
    std::pair<uint32_t, uint32_t> pcm();  // {CRC, count} of the 48 kHz samples

private:
    shell::Client& c_;
    void put32(uint32_t reg, uint32_t v, int bytes = 4);
    uint32_t get32(uint32_t reg);
};

// A line of harness/golden/a2600_frames_crc32.txt (tools/stella/frames.py): a cartridge, and Stella's
// CRC of frame `frames`.
struct Golden {
    std::string id;
    uint32_t frames = 0;
    uint32_t crc = 0;
    std::string path;  // under the test-ROM directory
};
std::vector<Golden> load_golden(const std::string& file);
// harness/golden/a2600_paddles.txt: the paddles Stella plugs in for each cartridge listed.
std::map<std::string, Paddles> load_paddles(const std::string& file);
// harness/golden/a2600_audio_crc32.txt: each cartridge's samples and their CRC.
struct AudioGolden {
    uint32_t samples = 0;
    uint32_t crc = 0;
};
std::map<std::string, AudioGolden> load_audio(const std::string& file);

// A cartridge run from power-up until `frames` frames have ended. Passes when frame `frames`'s CRC
// is `crc`, and, given `audio`, the CRC of its first samples is audio->crc. The result's CRC32 is
// the frame's, its audio CRC32 the sound's.
TestResult cart_test(Link& link, const std::string& name, const std::vector<uint8_t>& rom, uint32_t frames,
                     uint32_t crc, const Paddles& paddles = kNoPaddles,
                     std::optional<AudioGolden> audio = std::nullopt,
                     std::optional<uint32_t> build_id = std::nullopt);

// The cartridge on HDMI: runs it, keeping pace with the display, to frame `frames` and returns the
// video CRC of the display frame that shows it (the frame a2600_frames_crc32.txt's CRC is of).
// Passes when that frame's CRC is `crc`, its display frame showed it whole, and no line came late
// or was overwritten. Needs a system with a display: the board, or make_a2600_hdmi_sim().
TestResult hdmi_test(Link& link, const std::string& name, const std::vector<uint8_t>& rom, uint32_t frames,
                     uint32_t crc, const Paddles& paddles = kNoPaddles,
                     std::optional<uint32_t> build_id = std::nullopt);

} // namespace rig::a2600
