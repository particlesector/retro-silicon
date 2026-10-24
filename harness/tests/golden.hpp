// SPDX-License-Identifier: Apache-2.0
#pragma once
// Reads harness/golden/echo_crc32.txt: `bytes seed crc32` per line, # comments.

#include <cstdint>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <utility>

inline std::map<std::pair<uint64_t, unsigned>, uint32_t> golden_crcs() {
    std::map<std::pair<uint64_t, unsigned>, uint32_t> out;
    std::ifstream f(RS_ECHO_GOLDEN);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        uint64_t bytes;
        unsigned seed;
        std::string crc;
        ss >> bytes >> seed >> crc;
        out[{bytes, seed}] = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
    }
    return out;
}
