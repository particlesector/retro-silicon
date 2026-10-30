// SPDX-License-Identifier: Apache-2.0
#pragma once
// iNES and NES 2.0 ROM files: the header's mapper, sizes and flags, and the
// PRG and CHR data.

#include <cstdint>
#include <span>
#include <string>
#include <variant>
#include <vector>

namespace rig {

struct NesRom {
    enum class Mirroring { kHorizontal, kVertical, kFourScreen };

    unsigned mapper = 0;
    bool nes2 = false;        // the header is NES 2.0
    Mirroring mirroring = Mirroring::kHorizontal;
    bool battery = false;     // PRG RAM is battery-backed
    // NES 2.0 only (0 in an iNES 1.0 header, which doesn't say): bytes of
    // PRG RAM, battery-backed PRG RAM and CHR RAM.
    size_t prg_ram = 0, prg_nvram = 0, chr_ram = 0;
    std::vector<uint8_t> prg;
    std::vector<uint8_t> chr; // empty when the board has CHR RAM
};

// Parses a whole .nes file; returns the ROM or an error message.
std::variant<NesRom, std::string> parse_ines(std::span<const uint8_t> file);

// Reads and parses a .nes file.
std::variant<NesRom, std::string> load_ines(const std::string& path);

} // namespace rig
