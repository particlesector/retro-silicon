// SPDX-License-Identifier: Apache-2.0
#pragma once
// Reads a harness/golden/*_crc32.txt file: `size seed crc32` per line, # comments.

#include <cstdint>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <utility>

inline std::map<std::pair<uint64_t, unsigned>, uint32_t> golden_crcs(const char* path = RS_ECHO_GOLDEN) {
    std::map<std::pair<uint64_t, unsigned>, uint32_t> out;
    std::ifstream f(path);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        uint64_t size;
        unsigned seed;
        std::string crc;
        ss >> size >> seed >> crc;
        out[{size, seed}] = static_cast<uint32_t>(std::stoul(crc, nullptr, 16));
    }
    return out;
}
