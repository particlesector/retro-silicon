// SPDX-License-Identifier: Apache-2.0
#pragma once
// Host side of systems/game-boy's gb_sys: its shell address map and registers, loading a cartridge
// and the boot ROM, and the test ROMs' check against MesenCE (harness/golden/gb_frames_crc32.txt).

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "rig/link.hpp"
#include "rig/shell.hpp"
#include "rig/test_result.hpp"

namespace rig::gb {

constexpr uint32_t kCart = 0x00000000;      // the cartridge's ROM, 2^kRomLog2 bytes
constexpr uint32_t kRegs = 0x01000000;
constexpr uint32_t kCartRam = 0x02000000;   // 8 KB, $A000-$BFFF
constexpr uint32_t kBoot = 0x03000000;      // 256 bytes
constexpr uint32_t kSerial = 0x04000000;    // the serial port's bytes: byte n at n mod kSerialSize
constexpr uint32_t kFrameBuffer = 0x05000000;  // y x 160 + x, a shade a byte
constexpr uint32_t kSerialSize = 2048;
constexpr uint32_t kCartRamSize = 8192;
constexpr int kWidth = 160, kHeight = 144;

enum Reg : uint32_t {
    kCtrl = 0x00,       // bit 0 run, bit 1 hold the system in reset
    kStopCycle = 0x04,  // 4 bytes: stop once this many T-cycles have run since reset; 0 never
    kCycles = 0x08,     // 4 bytes, read-only: T-cycles since reset
    kStatus = 0x0C,     // read-only, see Status
    kStopFrame = 0x10,  // 4 bytes: stop once this many frames have ended since reset; 0 never
    kFrames = 0x14,     // 4 bytes, read-only: frames ended since reset
    kFrameCrc = 0x18,   // 4 bytes, read-only: CRC-32 of the frame buffer at the last stop
    kCrcFrame = 0x1C,   // 4 bytes, read-only: frames ended at that stop
    kSerialCount = 0x20,  // 4 bytes, read-only: bytes the serial port sent since reset
    kKeys = 0x24,       // 1 pressed: Start, Select, B, A, down, up, left, right (bit 7 to 0)
    kLcdc = 0x28,       // read-only: LCDC
    kBootOn = 0x29,     // read-only: bit 0, the boot ROM is mapped
    kPc = 0x2A,         // 2 bytes, read-only: the CPU's PC
    kRomRoom = 0x2C,    // read-only: the room for ROM, log2
    // With a display (gb_sys's VIDEO):
    kVideo = 0x34,      // bit 0 keep pace with the display; write bit 1 to take the video CRC
    kVideoWhole = 0x36,  // bit 0: the video CRC's display frame showed its frame whole
    kVcapFrame = 0x38,  // 4 bytes: the video CRC is of the display frame showing frame kVcapFrame + 1
    kVideoCrc = 0x3C,   // 4 bytes, read-only
    kVideoShown = 0x40,  // 2 bytes, read-only: display frames whose frame started on request
    kVideoLate = 0x42,  // 2 bytes, read-only: lines late
};

enum Status : uint8_t { kStopped = 1, kRunning = 2, kCrcValid = 4, kScanning = 8, kVideoCrcValid = 16 };

// The display's counts and the video CRC asked for.
struct Video {
    bool valid = false;  // the CRC asked for has come
    bool whole = false;  // ...and its display frame showed its frame whole
    uint32_t crc = 0;
    uint16_t shown = 0, late = 0;
};

// The boot ROM gb_frames.py runs through, SameBoy's for the Game Boy (testroms/manifest-gb.toml's
// [[boot]] dmg), under the test-ROM directory.
inline constexpr const char* kDmgBoot = "sameboy/build/bin/BootROMs/dmg_boot.bin";

// gb_sys through its test shell. Every call is an absolute register write or read.
class Console {
public:
    explicit Console(shell::Client& c) : c_(c) {}

    void hold_reset();
    // Writes the boot ROM (256 bytes), the cartridge's ROM (filled with $FF to the room's size) and
    // its RAM ($FF), and checks they read back; an error message if they don't. A ROM bigger than
    // the room gives kNoRoom.
    std::optional<std::string> load(const std::vector<uint8_t>& rom, const std::vector<uint8_t>& boot);
    static constexpr const char* kNoRoom = "the system has no room for this cartridge";
    void set_keys(uint8_t keys);
    void stop_frame(uint32_t n);
    void run();  // out of reset, running
    // Waits until the system stops at a limit and the CRC of its frame buffer is taken.
    void wait_stopped();

    uint8_t status();
    uint32_t frames();
    uint32_t cycles();
    std::optional<std::pair<uint32_t, uint32_t>> frame_crc();  // {CRC, frames}
    uint32_t serial_count();
    // The serial port's bytes from byte `from` (the last kSerialSize at most).
    std::vector<uint8_t> serial(uint32_t from);
    std::vector<uint8_t> frame();  // the frame buffer: 160 x 144 shades

    // With a display:
    void pace(bool on);
    // Keeps pace and takes the video CRC of the display frame showing frame `index` + 1.
    void arm_video_crc(uint32_t index);
    Video video();

private:
    shell::Client& c_;
    void put32(uint32_t reg, uint32_t v, int bytes = 4);
    uint32_t get32(uint32_t reg);
};

// A line of harness/golden/gb_frames_crc32.txt (tools/mesen/gb_frames.py): a test ROM, the model,
// MesenCE's frame and its CRC, how its result is read and MesenCE's result.
struct Golden {
    std::string id;
    std::string model;   // dmg or cgb
    uint32_t frames = 0;  // MesenCE's frame: for a frame check, the one checked
    uint32_t crc = 0;
    std::string check;   // serial (blargg's text), mooneye (its bytes), blargg (in cartridge RAM) or frame
    std::string result;  // pass, fail or (a frame check) -
    std::string path;    // under the test-ROM directory, %20 as a space
};
std::vector<Golden> load_golden(const std::string& file);

// testroms/manifest-gb.toml's `needs` for each ROM id, and what the system has of them so far
// (systems/game-boy's gb_roms_test runs the dmg ROMs whose needs it has: the same list).
std::map<std::string, std::set<std::string>> load_needs(const std::string& manifest);
const std::set<std::string>& system_has();

// ROMs whose result is checked but not their frame, and why: systems/game-boy's gb_roms_test has
// the same list.
const std::map<std::string, std::string>& frame_not_checked();

// A test ROM run from power-up through `boot`, as gb_roms_test runs it. A ROM with a result of its
// own (check serial or mooneye) must end with MesenCE's within twice the frames MesenCE took (and
// 60), and its frame 30 frames after the result must have MesenCE's CRC; a frame check's frame is
// MesenCE's. The result's CRC32 is the checked frame's.
TestResult rom_test(Link& link, const Golden& g, const std::vector<uint8_t>& rom, const std::vector<uint8_t>& boot,
                    std::optional<uint32_t> build_id = std::nullopt);

// The ROM on HDMI: runs it from power-up, keeping pace with the display, to frame `frame` (where
// rom_test checks it, from gb_hdmi_crc32.txt) and returns the video CRC of the display frame that
// shows it. Passes when the frame's CRC is MesenCE's (g.crc, unless frame_not_checked() has it), its
// display frame showed it whole, and no line came late. Needs a system with a display: the board, or
// make_gb_hdmi_sim().
TestResult hdmi_test(Link& link, const Golden& g, const std::vector<uint8_t>& rom, const std::vector<uint8_t>& boot,
                     uint32_t frame, std::optional<uint32_t> build_id = std::nullopt);

// harness/golden/gb_hdmi_crc32.txt: id, the frame rom_test checks, and the video CRC of the display
// frame showing it.
struct HdmiGolden {
    uint32_t frame = 0;
    uint32_t crc = 0;
};
std::map<std::string, HdmiGolden> load_hdmi_golden(const std::string& file);

} // namespace rig::gb
