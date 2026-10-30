// SPDX-License-Identifier: Apache-2.0
#include "rig/ines.hpp"

#include <fstream>
#include <iterator>

namespace rig {

std::variant<NesRom, std::string> parse_ines(std::span<const uint8_t> file) {
    if (file.size() < 16 || file[0] != 'N' || file[1] != 'E' || file[2] != 'S' || file[3] != 0x1A)
        return std::string("not an iNES file");
    NesRom rom;
    rom.nes2 = (file[7] & 0x0C) == 0x08;
    size_t prg_units = file[4], chr_units = file[5];
    rom.mapper = (file[6] >> 4) | (file[7] & 0xF0);
    if (rom.nes2) {
        // NES 2.0 adds high bits to the mapper and sizes; the exponent size form isn't supported.
        if ((file[9] & 0x0F) == 0x0F || (file[9] & 0xF0) == 0xF0) return std::string("NES 2.0 exponent sizes aren't supported");
        rom.mapper |= (file[8] & 0x0Fu) << 8;
        prg_units |= (file[9] & 0x0Fu) << 8;
        chr_units |= (file[9] & 0xF0u) << 4;
        auto shift = [](unsigned n) -> size_t { return n ? size_t{64} << n : 0; };
        rom.prg_ram = shift(file[10] & 0x0F);
        rom.prg_nvram = shift(file[10] >> 4);
        rom.chr_ram = shift(file[11] & 0x0F);
    } else if (file[7] & 0x0C) {
        // Old dumps put text in bytes 7-15; only the low mapper nibble is trustworthy.
        rom.mapper &= 0x0F;
    }
    rom.mirroring = (file[6] & 0x08) ? NesRom::Mirroring::kFourScreen
                    : (file[6] & 0x01) ? NesRom::Mirroring::kVertical
                                       : NesRom::Mirroring::kHorizontal;
    rom.battery = file[6] & 0x02;
    size_t at = 16 + ((file[6] & 0x04) ? 512 : 0);  // skip a trainer
    size_t prg = prg_units * 16384, chr = chr_units * 8192;
    if (prg == 0) return std::string("no PRG ROM");
    if (file.size() < at + prg + chr) return std::string("truncated: the header promises more data than the file has");
    rom.prg.assign(file.begin() + static_cast<std::ptrdiff_t>(at), file.begin() + static_cast<std::ptrdiff_t>(at + prg));
    rom.chr.assign(file.begin() + static_cast<std::ptrdiff_t>(at + prg),
                   file.begin() + static_cast<std::ptrdiff_t>(at + prg + chr));
    return rom;
}

std::variant<NesRom, std::string> load_ines(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return "can't open " + path;
    std::vector<uint8_t> file((std::istreambuf_iterator<char>(f)), {});
    auto r = parse_ines(file);
    if (auto* e = std::get_if<std::string>(&r)) return path + ": " + *e;
    return r;
}

} // namespace rig
