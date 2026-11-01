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
constexpr uint32_t kInputScript = 0x07000000;  // the input player's script, 512 entries of 4 bytes
constexpr uint32_t kChr = 0x08000000;    // all of CHR in block RAM, unbanked
constexpr uint32_t kTrace = 0x09000000;  // the trace buffer's ring, 4 bytes an entry
// CHR ROM too big for CHR's block RAM, on a board that can (kChrExt): in the
// board's memory from here, up to 256 KB, laid out by chr_ext_offset.
constexpr size_t kChrExtBase = 0x400000;
constexpr size_t kChrExtMax = 0x40000;
constexpr size_t kSaveStateBytes = 21052;   // what the save-state controller walks

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
    kCart = 0x2C,       // bit 0 vertical mirroring, bit 1 CHR is RAM, bit 2 there's PRG RAM,
                        // bit 3 CHR ROM is in the board's memory
    kMapper = 0x2D,     // the iNES mapper number
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
    kInputOn = 0x60,    // bit 0: the input player drives the controllers
    kInputLen = 0x61,   // 2 bytes: entries in the script
    kLive1 = 0x64,      // controller 1's buttons when the player is off
    kLive2 = 0x65,      // controller 2's
    kPads = 0x68,       // 2 bytes, read-only: the buttons the console sees
    kChrMask = 0x70,    // 3 bytes: CHR address mask (CHR size - 1)
    kChrBits = 0x74,    // read-only: CHR holds 2^this bytes
    kMemBits = 0x75,    // read-only: the board's memory, for PRG ROM, holds 2^this bytes
    kChrExt = 0x76,     // read-only: bit 0, CHR ROM can come from the board's memory
    kMemWaits = 0x78,   // 4 bytes, read-only: clocks the dots waited for memory since reset
    kCacheHits = 0x7C,  // 4 bytes each, read-only: a memory cache's hits, misses and prefetches (0 without one)
    kCacheMisses = 0x80,
    kCachePrefetches = 0x84,
    kTraceCount = 0x88,   // 4 bytes, read-only: the trace buffer's next entry number (cycle n at ring index n mod depth)
    kTraceFilled = 0x8C,  // 2 bytes, read-only: valid entries, up to its depth
    kTraceBits = 0x8E,    // read-only: it holds 2^this entries
    kLeadDots = 0x8F,     // PPU dots before the CPU's first cycle after a reset: the CPU/PPU alignment
    kResetAt = 0x90,      // 2 x 4 bytes: frames ended when the reset button is pressed; 0 never
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

// Where CHR ROM byte `a` goes from kChrExtBase: each 16-byte tile's planes
// interleaved, row r of plane p at 2r + p, so a 32-bit word holds two rows.
size_t chr_ext_offset(size_t a);

// How the console powers up: its memories' fill (RAM, PRG RAM, CHR RAM, the
// nametables and OAM, as MesenCE fills them) and its CPU/PPU alignment.
//
// The alignment is the PPU dots before the CPU's first cycle. 5, the default,
// is MesenCE's own (its PPU offset 1, CPU offset 0, in master clocks); 6 and 7
// put the CPU a dot and two later, as MesenCE's random alignments do when its
// CPU offset less its PPU offset is 3 or 7 master clocks. Its other random
// alignments put the CPU part of a dot off, which this core can't (or, at 11,
// a whole cycle later).
struct PowerUp {
    enum Fill { kZeros, kOnes, kRandom };
    Fill fill = kZeros;
    uint32_t seed = 0;  // for kRandom
    uint8_t lead_dots = 5;
};

// MesenCE's alignment (its log's "PPU: p/3 CPU: c/11") as lead dots; nothing
// if the core can't run it.
std::optional<uint8_t> lead_dots_for(int ppu_offset, int cpu_offset);

// One CPU cycle from the trace buffer: its number since reset, and the bus.
struct TraceEntry {
    uint32_t cycle;
    uint16_t addr;
    uint8_t data;  // read or written
    bool write, sync;  // sync: an opcode fetch
};

// A frame as the PPU outputs it: 256 x 240 values, {emphasis BGR, colour}.
using Frame = std::vector<uint16_t>;

// CRC-32 of a frame as the video probe computes it: 2 bytes a pixel, low first.
uint32_t frame_crc(const Frame& f);

// Controller buttons as a byte: bit 0 A, then B, Select, Start, Up, Down,
// Left, and bit 7 Right, the order the console reads them.
enum Button : uint8_t { kA = 1, kB = 2, kSelect = 4, kStart = 8, kUp = 16, kDown = 32, kLeft = 64, kRight = 128 };

// An input script entry: from frame `frame` on (counting frames ended since
// reset), controller 1 holds `pad1` and controller 2 `pad2`.
struct InputEntry {
    uint16_t frame;
    uint8_t pad1, pad2 = 0;
};

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
    // powers up. Returns an error message, or nothing.
    // CHR ROM goes in the board's memory if it's too big for CHR's block RAM,
    // or with `chr_ext` set, if the system can take it from there.
    std::optional<std::string> load(const NesRom& rom, bool chr_ext = false);
    // How the next load() powers the console up (from then on, until changed).
    void set_power_up(const PowerUp& p) { power_up_ = p; }
    // Why this system can't run the ROM (an unsupported mapper or a size it
    // has no room for), or nothing if it can.
    std::optional<std::string> unsupported(const NesRom& rom);
    // The system can take CHR ROM from the board's memory.
    bool chr_ext();
    void set_vector(std::optional<uint16_t> pc);
    // The input player: plays `script` (frames in order, one entry a frame at
    // most, 512 at most) from reset; an empty one turns the player off.
    void set_input_script(const std::vector<InputEntry>& script);
    // The buttons while the player is off, taken at each frame's end.
    void set_live_input(uint8_t pad1, uint8_t pad2 = 0);
    // The reset button: pressed as each of these frames ends (counting from
    // power-up; two at most), as tools/mesen/frames.py presses it in MesenCE.
    void set_reset_presses(const std::vector<uint32_t>& frames);
    void stop_at(uint32_t cycles);
    void stop_frame(uint32_t frames);
    void run();  // releases reset and runs

    uint8_t status();
    uint32_t cycles();
    uint32_t frames();
    uint32_t trace_crc();
    // The trace buffer's cycles, oldest first: the last ones before it
    // stopped (as many as it holds). Read while stopped.
    std::vector<TraceEntry> trace();
    uint32_t audio_crc();
    // Clocks the dots have waited for memory since reset (register 78).
    uint32_t mem_waits();
    // A memory cache's reads answered, reads that went to memory, and lines
    // prefetched, since reset (all 0 without a cache).
    struct CacheStats { uint32_t hits, misses, prefetches; };
    CacheStats cache_stats();
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
    PowerUp power_up_;
};

inline constexpr uint32_t kNestestCycles = 26554;  // the last line of nestest.log

// nestest's automated mode (from $C000) for `cycles` CPU cycles, as nestest.log
// covers, while the host keeps reading RAM, SDRAM and status the whole time.
// Passes when the CPU stopped on time, was never late, and nestest's error
// codes at $02 and $03 are 0. The result's CRC32 is the CPU's bus trace CRC,
// which must match the CPU bench's. Throws RigError if the link fails.
// With `log` (nestest.log's path), the trace buffer's cycles must also match
// it: an opcode fetch at each instruction's PC and cycle, with its opcode,
// and no other.
TestResult nestest(Link& link, const NesRom& rom, uint32_t cycles = kNestestCycles,
                   std::optional<uint32_t> build_id = std::nullopt, const std::string& log = "");

// Where `trace` differs from nestest.log (at `log`) over the cycles it
// covers: each instruction's opcode fetch at its PC and CYC, with its first
// byte, and no other opcode fetches. Nothing if they match.
std::optional<std::string> compare_nestest_log(const std::vector<TraceEntry>& trace, const std::string& log);

// How a test ROM reports (testroms/manifest.toml's `check`).
struct RomCheck {
    enum Kind { kBlargg, kZeroPage, kFrame };
    std::string id;
    Kind kind = kBlargg;
    uint16_t result = 0;  // kZeroPage: where the ROM leaves 1 for a pass
    std::vector<InputEntry> input;  // played from reset, if any
    std::vector<uint32_t> reset;    // frames ended when the reset button is pressed, if any
};

// A test ROM run from power-up until `frames` frames have ended. Passes when
// by then the ROM reports success: kBlargg at $6000, kZeroPage at its result
// address; a kFrame ROM passes if it runs. The result's CRC32 is the CRC of
// the last frame, which must match the other backend's and MesenCE's for the
// same frame; its audio CRC32 (the APU's levels through to that point) must
// match the other backend's. Its notes carry the ROM's text report, if it has one.
// `power` sets the memories' fill and the CPU/PPU alignment it powers up with.
TestResult rom_test(Link& link, const RomCheck& check, const NesRom& rom, uint32_t frames,
                    std::optional<uint32_t> build_id = std::nullopt, bool chr_ext = false,
                    const PowerUp& power = {});

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
    std::string path;  // under the test-ROM directory: its source, then its path
};
std::vector<GoldenRom> load_golden_roms(const std::string& file);

// harness/golden/nes_audio_crc32.txt: each ROM's audio CRC at its golden
// frame (id, frames, CRC), from the sim, for the boards to match. There is
// no MesenCE reference for it: MesenCE catches its APU up lazily.
std::map<std::string, uint32_t> load_golden_audio(const std::string& file);

} // namespace rig::nes
