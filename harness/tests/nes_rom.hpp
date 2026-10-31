// SPDX-License-Identifier: Apache-2.0
#pragma once
// A ROM from harness/golden/nes_frames_crc32.txt (or another golden file) for
// a sim test, or a skip if the test ROMs haven't been fetched.

#include <catch2/catch_test_macros.hpp>

#include <algorithm>
#include <filesystem>
#include <string>
#include <utility>
#include <variant>

#include "rig/ines.hpp"
#include "rig/nes.hpp"

inline std::pair<rig::nes::GoldenRom, rig::NesRom> golden_rom(const std::string& id,
                                                              const std::string& file = RS_NES_FRAMES_GOLDEN) {
    auto golden = rig::nes::load_golden_roms(file);
    auto g = std::find_if(golden.begin(), golden.end(), [&](auto& x) { return x.check.id == id; });
    REQUIRE(g != golden.end());
    std::string path = std::string(RS_TESTROMS) + "/" + g->path;
    if (!std::filesystem::exists(path)) SKIP(path << " not found: run testroms/fetch.py");
    auto rom = rig::load_ines(path);
    REQUIRE(std::holds_alternative<rig::NesRom>(rom));
    return {*g, std::get<rig::NesRom>(rom)};
}
