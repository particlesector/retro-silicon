// SPDX-License-Identifier: Apache-2.0
#pragma once
// Just enough of an NES around the CPU to run CPU test ROMs: 2 KB of RAM
// mirrored to $1FFF, 8 KB of PRG RAM at $6000, PRG ROM through mapper 0 (NROM)
// or 1 (MMC1), and a $2002 whose VBlank bit toggles on every read so polling
// loops finish. Nothing else of the PPU or APU.

#include <cstdint>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <vector>

#include "cpu_bench.hpp"

class NesBench : public CpuBench {
public:
    // Loads an iNES file; returns an error message, or nothing on success.
    std::optional<std::string> load(const std::string& path) {
        std::ifstream f(path, std::ios::binary);
        if (!f) return "can't open " + path;
        std::vector<uint8_t> file((std::istreambuf_iterator<char>(f)), {});
        if (file.size() < 16 || file[0] != 'N' || file[1] != 'E' || file[2] != 'S' || file[3] != 0x1A)
            return path + " isn't an iNES file";
        size_t prg_size = file[4] * 16384u;
        mapper_ = (file[6] >> 4) | (file[7] & 0xF0);
        size_t offset = 16 + ((file[6] & 0x04) ? 512 : 0);
        if (file.size() < offset + prg_size) return path + " is truncated";
        prg_.assign(file.begin() + static_cast<long>(offset), file.begin() + static_cast<long>(offset + prg_size));
        if (mapper_ != 0 && mapper_ != 1) return "mapper " + std::to_string(mapper_) + " isn't supported";
        read = [this](uint16_t a) { return bus_read(a); };
        write = [this](uint16_t a, uint8_t d) { bus_write(a, d); };
        return std::nullopt;
    }

    uint8_t peek(uint16_t a) { return bus_read(a); }

    // blargg's protocol at $6000: the result once DE B0 61 is at $6001.
    std::optional<uint8_t> blargg_result() {
        if (prg_ram_[1] != 0xDE || prg_ram_[2] != 0xB0 || prg_ram_[3] != 0x61) return std::nullopt;
        if (prg_ram_[0] >= 0x80) return std::nullopt;
        return prg_ram_[0];
    }

    std::string blargg_text() {
        std::string s;
        for (size_t i = 4; i < prg_ram_.size() && prg_ram_[i]; i++) s += static_cast<char>(prg_ram_[i]);
        return s;
    }

private:
    uint8_t bus_read(uint16_t a) {
        if (a < 0x2000) return wram_[a & 0x7FF];
        if (a < 0x4000) {
            if ((a & 7) == 2) return (vbl_ ^= 0x80);
            return 0;
        }
        if (a < 0x6000) return 0;
        if (a < 0x8000) return prg_ram_[a - 0x6000];
        return prg_[prg_offset(a) % prg_.size()];
    }

    void bus_write(uint16_t a, uint8_t d) {
        if (a < 0x2000)
            wram_[a & 0x7FF] = d;
        else if (a >= 0x6000 && a < 0x8000)
            prg_ram_[a - 0x6000] = d;
        else if (a >= 0x8000 && mapper_ == 1)
            mmc1_write(a, d);
    }

    size_t prg_offset(uint16_t a) const {
        size_t banks = prg_.size() / 16384;
        if (mapper_ == 0) return a & (prg_.size() > 16384 ? 0x7FFF : 0x3FFF);
        size_t bank;
        switch ((mmc1_control_ >> 2) & 3) {
        case 0:
        case 1: bank = (mmc1_prg_ & 0x0E) + (a >= 0xC000); break;
        case 2: bank = a < 0xC000 ? 0 : mmc1_prg_ & 0x0F; break;
        default: bank = a < 0xC000 ? mmc1_prg_ & 0x0F : banks - 1; break;
        }
        return bank * 16384 + (a & 0x3FFF);
    }

    void mmc1_write(uint16_t a, uint8_t d) {
        if (d & 0x80) {
            mmc1_shift_ = 0;
            mmc1_count_ = 0;
            mmc1_control_ |= 0x0C;
            return;
        }
        mmc1_shift_ |= (d & 1) << mmc1_count_;
        if (++mmc1_count_ < 5) return;
        switch ((a >> 13) & 3) {
        case 0: mmc1_control_ = mmc1_shift_; break;
        case 3: mmc1_prg_ = mmc1_shift_; break;
        default: break;  // CHR banks: no PPU here
        }
        mmc1_shift_ = 0;
        mmc1_count_ = 0;
    }

    std::vector<uint8_t> prg_;
    std::vector<uint8_t> wram_ = std::vector<uint8_t>(2048);
    std::vector<uint8_t> prg_ram_ = std::vector<uint8_t>(8192);
    int mapper_ = 0;
    uint8_t vbl_ = 0;
    uint8_t mmc1_shift_ = 0, mmc1_count_ = 0, mmc1_control_ = 0x0C, mmc1_prg_ = 0;
};
