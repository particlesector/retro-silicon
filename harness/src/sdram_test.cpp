// SPDX-License-Identifier: Apache-2.0
#include "rig/sdram_test.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "rig/crc32.hpp"
#include "rig/shell.hpp"

namespace rig {

namespace {

constexpr uint32_t kSdramSize = 8u << 20;
constexpr uint32_t kQuarter = kSdramSize / 4;
constexpr uint32_t kSample = 512;  // bytes read back from the start, middle and end of each region

std::string hex32(uint32_t x) {
    char s[16];
    std::snprintf(s, sizeof s, "0x%08x", x);
    return s;
}

} // namespace

TestResult sdram_test(Link& link, uint32_t bytes, unsigned seed, std::optional<uint32_t> build_id) {
    TestResult r;
    r.name = "sdram";
    auto t0 = std::chrono::steady_clock::now();
    shell::Client client(link);
    std::mt19937 rng(seed);
    Crc32 crc;

    auto finish = [&](std::string detail) {
        r.passed = detail.empty();
        r.detail = std::move(detail);
        r.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        r.crc32 = crc.value();
        r.notes = std::to_string(client.stats.commands) + " commands in " + std::to_string(client.stats.attempts) +
                  " attempts";
        return r;
    };

    try {
        auto info = client.info();
        if (info.version != shell::kVersion)
            return finish("shell protocol version " + std::to_string(info.version) + ", expected " +
                          std::to_string(shell::kVersion));
        if (build_id && info.build_id != *build_id)
            return finish("build ID " + hex32(info.build_id) + ", expected " + hex32(*build_id) +
                          ": the wrong bitstream is loaded");

        const uint32_t size = std::clamp<uint32_t>(bytes / 4, 1, kQuarter);
        struct Region {
            uint32_t base;
            std::vector<uint8_t> data;
        };
        std::vector<Region> regions;
        for (uint32_t q = 0; q < 4; q++) {
            Region g{q * kQuarter + static_cast<uint32_t>(rng() % (kQuarter - size + 1)), std::vector<uint8_t>(size)};
            for (auto& b : g.data) b = static_cast<uint8_t>(rng());
            client.write(g.base, g.data);
            regions.push_back(std::move(g));
        }
        // Check after all the writes, so a write that lands in the wrong place shows up.
        for (auto& g : regions) {
            Crc32 want;
            want.update(g.data);
            uint32_t got = client.crc(g.base, size);
            if (got != want.value())
                return finish("CRC of " + std::to_string(size) + " bytes at " + hex32(g.base) + " is " + hex32(got) +
                              ", expected " + hex32(want.value()));
            uint8_t le[4] = {static_cast<uint8_t>(got), static_cast<uint8_t>(got >> 8), static_cast<uint8_t>(got >> 16),
                             static_cast<uint8_t>(got >> 24)};
            crc.update(le);
            r.bytes += size;
            const uint32_t n = std::min(kSample, size);
            for (uint32_t at : {0u, (size - n) / 2, size - n}) {
                auto back = client.read(g.base + at, n);
                for (uint32_t k = 0; k < n; k++)
                    if (back[k] != g.data[at + k])
                        return finish("byte at " + hex32(g.base + at + k) + " reads back wrong");
                crc.update(back);
            }
        }
        return finish("");
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

} // namespace rig
