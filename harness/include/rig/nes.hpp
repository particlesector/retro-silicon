// SPDX-License-Identifier: Apache-2.0
#pragma once
// Host side of systems/nes: its shell address map and registers, ROM upload,
// and the nestest run.

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "rig/ines.hpp"
#include "rig/link.hpp"
#include "rig/shell.hpp"
#include "rig/test_result.hpp"

namespace rig::nes {

constexpr uint32_t kSdram = 0x00000000;  // PRG ROM from here
constexpr uint32_t kRegs = 0x01000000;
constexpr uint32_t kCpu = 0x02000000;    // the CPU's address space: RAM and PRG RAM

enum Reg : uint32_t {
    kCtrl = 0x00,      // bit 0 run, bit 1 hold the CPU in reset
    kPrgMask = 0x04,   // 3 bytes: SDRAM address mask for PRG reads (PRG size - 1)
    kVector = 0x08,    // 2 bytes: reset vector override
    kVectorEn = 0x0A,  // bit 0: use it
    kStopAt = 0x0C,    // 4 bytes: stop after this many CPU cycles; 0 never
    kCycles = 0x10,    // 4 bytes, read-only: CPU cycles since reset
    kTraceCrc = 0x14,  // 4 bytes, read-only: CRC-32 of the CPU's bus since reset
    kStatus = 0x18,    // read-only, see Status
};

enum Status : uint8_t { kHalted = 1, kStopped = 2, kLate = 4, kRunning = 8 };

// systems/nes through its test shell. Every call is an absolute register write
// or read, so the shell's retries are safe.
class Console {
public:
    explicit Console(shell::Client& c) : c_(c) {}

    // Holds the CPU in reset, which clears its cycle count, trace CRC and status.
    void hold_reset();
    // Uploads the ROM's PRG to SDRAM and checks it with the shell's CRC.
    // Returns an error message, or nothing. Mapper 0 only, for now.
    std::optional<std::string> load(const NesRom& rom);
    void set_vector(std::optional<uint16_t> pc);
    void stop_at(uint32_t cycles);
    void run();  // releases reset and runs

    uint8_t status();
    uint32_t cycles();
    uint32_t trace_crc();
    std::vector<uint8_t> peek(uint16_t addr, uint16_t count);  // CPU space: RAM and PRG RAM

private:
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

} // namespace rig::nes
