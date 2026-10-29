// SPDX-License-Identifier: Apache-2.0
#pragma once
// Host side of systems/nes: its shell address map and registers, ROM upload,
// frames and their CRCs, and the test runs.

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "rig/ines.hpp"
#include "rig/link.hpp"
#include "rig/shell.hpp"
#include "rig/test_result.hpp"

namespace rig::nes {

constexpr uint32_t kSdram = 0x00000000;  // the board's memory: PRG ROM from here
constexpr uint32_t kRegs = 0x01000000;
constexpr uint32_t kCpu = 0x02000000;    // the CPU's address space: RAM and PRG RAM
constexpr uint32_t kPpu = 0x03000000;    // the PPU's: CHR and nametables
constexpr uint32_t kCpuState = 0x04000000;
constexpr uint32_t kPpuState = 0x04001000;
constexpr uint32_t kSysState = 0x04002000;  // the system's own state words
constexpr uint32_t kApuState = 0x04003000;
constexpr uint32_t kLineCrcs = 0x05000000;
constexpr uint32_t kCapture = 0x05001000;
constexpr uint32_t kSaveBuffer = 0x06000000;
constexpr size_t kSaveStateBytes = 21016;   // what the save-state controller walks

constexpr int kWidth = 256, kHeight = 240;
constexpr int kPpuStateWords = 101;

enum Reg : uint32_t {
    kCtrl = 0x00,       // bit 0 run, bit 1 hold the system in reset
    kPrgMask = 0x04,    // 3 bytes: SDRAM address mask for PRG reads (PRG size - 1)
    kVector = 0x08,     // 2 bytes: reset vector override
    kVectorEn = 0x0A,   // bit 0: use it
    kStopAt = 0x0C,     // 4 bytes: stop after this many CPU cycles; 0 never
    kCycles = 0x10,     // 4 bytes, read-only: CPU cycles since reset
    kTraceCrc = 0x14,   // 4 bytes, read-only: CRC-32 of the CPU's bus since reset
    kStatus = 0x18,     // read-only, see Status
    kStopFrame = 0x1C,  // 4 bytes: stop once this many frames have ended; 0 never
    kFrames = 0x20,     // 4 bytes, read-only: frames ended since reset
    kFrameCrc = 0x24,   // 4 bytes, read-only: CRC-32 of the last whole frame
    kCrcFrame = 0x28,   // 4 bytes, read-only: ...and its index
    kCart = 0x2C,       // bit 0 vertical mirroring, bit 1 CHR is RAM
    kCapFrame = 0x30,   // 4 bytes: the frame to capture
    kCapLine = 0x34,    // the line to capture
    kCapEn = 0x35,      // bit 0: capture
    kSaveCmd = 0x38,    // {op (1 save, 2 load), sequence}: runs when it changes
    kSaveDone = 0x39,   // read-only: the last command finished
    kVideo = 0x3C,      // bit 0 keep pace with the display; write bit 1 to take the video CRC
    kVideoWhole = 0x3D, // read-only: bit 0 the video CRC's display frame showed its frame whole
    kVcapFrame = 0x40,  // 4 bytes: the frame whose display frame the video CRC is of
    kVideoCrc = 0x44,   // 4 bytes, read-only: the video CRC
    kVideoShown = 0x48, // 2 bytes, read-only: display frames whose frame started on request
    kVideoLate = 0x4A,  // 2 bytes, read-only: lines that came late to the display
    kVideoOver = 0x4C,  // 2 bytes, read-only: lines overwritten before they were shown
    kAudioCrc = 0x50,   // 4 bytes, read-only: CRC-32 of the APU's channel levels, every CPU cycle since reset
    kPcmCrc = 0x54,     // 4 bytes, read-only: CRC-32 of the 48 kHz samples since reset, 2 bytes each, low first
    kPcmCount = 0x58,   // 4 bytes, read-only: how many samples
};

enum Status : uint8_t {
    kHalted = 1, kStopped = 2, kLate = 4, kRunning = 8, kCapHeld = 16, kCrcValid = 32,
    kPaceWait = 64,     // waiting for the display to ask for the next frame
    kVideoCrcValid = 128,
};

// The video side's results (nes_video): the video CRC, of the TMDS symbols of
// a whole display frame (1650 x 750 pixel clocks, 30 bits each, bit 0 first:
// blue's symbol in bits 9-0, green's 19-10, red's 29-20), and the pacing's
// counts.
struct Video {
    bool valid = false;  // the CRC asked for has come
    bool whole = false;  // ...and its display frame showed its frame whole
    uint32_t crc = 0;
    uint16_t shown = 0, late = 0, overrun = 0;
};

// A frame as the PPU outputs it: 256 x 240 values, {emphasis BGR, colour}.
using Frame = std::vector<uint16_t>;

// CRC-32 of a frame as the video probe computes it: 2 bytes a pixel, low first.
uint32_t frame_crc(const Frame& f);

// systems/nes through its test shell. Every call is an absolute register write
// or read, so the shell's retries are safe.
class Console {
public:
    explicit Console(shell::Client& c) : c_(c) {}

    // Holds the system in reset, which clears its counts, CRCs and status.
    void hold_reset();
    // With the system held in reset: clears the stop limits, the vector
    // override and the capture; uploads the ROM (PRG to the board's memory,
    // checked with the shell's CRC; CHR, or clears CHR RAM), sets the
    // mirroring, and clears RAM, PRG RAM, nametables and OAM, as MesenCE
    // powers up. Returns
    // an error message, or nothing. Mapper 0 only, for now.
    std::optional<std::string> load(const NesRom& rom);
    void set_vector(std::optional<uint16_t> pc);
    void stop_at(uint32_t cycles);
    void stop_frame(uint32_t frames);
    void run();  // releases reset and runs

    uint8_t status();
    uint32_t cycles();
    uint32_t frames();
    uint32_t trace_crc();
    uint32_t audio_crc();
    // The 48 kHz sound since reset: its samples' CRC and count.
    std::pair<uint32_t, uint32_t> pcm();
    // The last whole frame's CRC and index; nothing if no frame has ended.
    std::optional<std::pair<uint32_t, uint32_t>> frame_crc();
    std::vector<uint32_t> line_crcs();  // of the last frame; read while stopped
    std::vector<uint8_t> peek(uint16_t addr, uint16_t count);  // CPU space: RAM and PRG RAM
    // With the system stopped at the end of frame `index - 1`: runs through
    // frame `index`, capturing it line by line, and stops again after it.
    Frame capture(uint32_t index);
    // Keeps pace with the display (the default on a board with HDMI) or not.
    void pace(bool on);
    // Asks for the video CRC of the display frame that shows frame `index`.
    // Pacing must be on.
    void arm_video_crc(uint32_t index);
    Video video();

    // Polls until the system stops at a limit or halts; returns the status.
    // Throws RigError if its cycle count stops moving first.
    uint8_t wait_stopped();

    // Saves the system's whole state and returns it: if it's running, at its
    // next frame boundary, after which it runs on. Not while held in reset.
    std::vector<uint8_t> save_state();
    // Loads a state from save_state(), from this board or any other running
    // the same system, and leaves the system stopped there; run() continues.
    // Releases reset first, if it's held.
    void load_state(const std::vector<uint8_t>& state);

private:
    void save_cmd(uint8_t op);
    void put32(uint32_t reg, uint32_t v, int bytes = 4);
    uint32_t get32(uint32_t reg);
    shell::Client& c_;
};

inline constexpr uint32_t kNestestCycles = 26554;  // the last line of nestest.log

// nestest's automated mode (from $C000) for `cycles` CPU cycles, as nestest.log
// covers, while the host keeps reading RAM, SDRAM and status the whole time.
// Passes when the CPU stopped on time, was never late, and nestest's error
// codes at $02 and $03 are 0. The result's CRC32 is the CPU's bus trace CRC,
// which must match the CPU bench's. Throws RigError if the link fails.
TestResult nestest(Link& link, const NesRom& rom, uint32_t cycles = kNestestCycles,
                   std::optional<uint32_t> build_id = std::nullopt);

// How a test ROM reports (testroms/manifest.toml's `check`).
struct RomCheck {
    enum Kind { kBlargg, kZeroPage, kFrame };
    std::string id;
    Kind kind = kBlargg;
    uint16_t result = 0;  // kZeroPage: where the ROM leaves 1 for a pass
};

// A test ROM run from power-up until `frames` frames have ended. Passes when
// by then the ROM reports success: kBlargg at $6000, kZeroPage at its result
// address; a kFrame ROM passes if it runs. The result's CRC32 is the CRC of
// the last frame, which must match the other backend's and MesenCE's for the
// same frame; its audio CRC32 (the APU's levels through to that point) must
// match the other backend's. Its notes carry the ROM's text report, if it has one.
TestResult rom_test(Link& link, const RomCheck& check, const NesRom& rom, uint32_t frames,
                    std::optional<uint32_t> build_id = std::nullopt);

// A save-state round trip. The ROM runs uninterrupted from power-up to frame
// `frames`; then again, saved at the first frame boundary after
// `save_after` frames while it runs, run on, reset and reloaded, restored from
// the saved state and run to frame `frames`. Passes when both runs end with
// the same frame CRC, line CRCs, trace CRC, audio CRC and cycle count. The
// result's CRC32 is the last frame's.
TestResult state_test(Link& link, const NesRom& rom, uint32_t save_after, uint32_t frames,
                      std::optional<uint32_t> build_id = std::nullopt);

// The ROM on HDMI: runs it, keeping pace with the display, to frame
// `frames` and returns the video CRC of the display frame that shows frame
// `frames - 1` (the frame nes_frames_crc32.txt's CRC is of). Passes when that
// display frame showed it whole and no line came late or was overwritten.
// Needs a system with nes_video's pixel clock running: the board, or
// make_nes_hdmi_sim().
TestResult hdmi_test(Link& link, const std::string& name, const NesRom& rom, uint32_t frames,
                     std::optional<uint32_t> build_id = std::nullopt);

// A line of harness/golden/nes_frames_crc32.txt (tools/mesen/frames.py): a
// ROM, how it reports, and MesenCE's CRC of frame `frames - 1`.
struct GoldenRom {
    RomCheck check;
    uint32_t frames = 0;
    uint32_t crc = 0;
    std::string path;  // under the test-ROM directory's nes-test-roms/
};
std::vector<GoldenRom> load_golden_roms(const std::string& file);

// harness/golden/nes_audio_crc32.txt: each ROM's audio CRC at its golden
// frame (id, frames, CRC), from the sim, for the boards to match. There is
// no MesenCE reference for it: MesenCE catches its APU up lazily.
std::map<std::string, uint32_t> load_golden_audio(const std::string& file);

} // namespace rig::nes
