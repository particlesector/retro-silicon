// SPDX-License-Identifier: Apache-2.0
#include "rig/shell_test.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "rig/crc32.hpp"
#include "rig/faulty_link.hpp"
#include "rig/shell.hpp"

namespace rig {

namespace {

constexpr uint32_t kRamSize = 4096;  // systems/shell-ram; mirrored through the address space

std::string hex32(uint32_t x) {
    char s[16];
    std::snprintf(s, sizeof s, "0x%08x", x);
    return s;
}

} // namespace

TestResult shell_test(Link& link, unsigned commands, unsigned seed, double fault_rate,
                      std::optional<uint32_t> build_id) {
    TestResult r;
    r.name = "shell";
    auto t0 = std::chrono::steady_clock::now();
    FaultyLink faulty(link, fault_rate, seed ^ 0x5eed);
    shell::Client client(faulty);
    std::mt19937 rng(seed);
    std::vector<uint8_t> ram(kRamSize);
    Crc32 crc;

    auto finish = [&](std::string detail) {
        r.passed = detail.empty();
        r.detail = std::move(detail);
        r.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        r.crc32 = crc.value();
        r.notes = std::to_string(client.stats.commands) + " commands in " + std::to_string(client.stats.attempts) +
                  " attempts; " + std::to_string(faulty.faults) + " bytes damaged on purpose";
        return r;
    };
    auto random_bytes = [&](size_t n) {
        std::vector<uint8_t> v(n);
        for (auto& b : v) b = static_cast<uint8_t>(rng());
        return v;
    };

    try {
        auto info = client.info();
        if (info.version != 1) return finish("shell protocol version " + std::to_string(info.version) + ", expected 1");
        if (build_id && info.build_id != *build_id)
            return finish("build ID " + hex32(info.build_id) + ", expected " + hex32(*build_id) +
                          ": the wrong bitstream is loaded");
        size_t max_poke = info.max_payload - 4u;

        // Fill the RAM first, so every later PEEK has a known answer.
        ram = random_bytes(kRamSize);
        for (uint32_t a = 0; a < kRamSize; a += static_cast<uint32_t>(max_poke)) {
            size_t n = std::min<size_t>(max_poke, kRamSize - a);
            client.poke(a, std::span(ram).subspan(a, n));
        }

        for (unsigned i = 0; i < commands; i++) {
            unsigned op = rng() % 100;
            if (op < 30) {
                // PING: mostly short, sometimes a full buffer.
                size_t n = rng() % 10 == 0 ? info.max_payload : rng() % 300;
                auto data = random_bytes(n);
                auto echo = client.ping(data);
                if (echo != data) return finish("command " + std::to_string(i) + ": PING echoed different data");
                crc.update(echo);
                r.bytes += n;
            } else if (op < 65) {
                // POKE anywhere: the address wraps into the RAM.
                uint32_t addr = static_cast<uint32_t>(rng());
                auto data = random_bytes(1 + rng() % 256);
                client.poke(addr, data);
                for (size_t k = 0; k < data.size(); k++) ram[(addr + k) % kRamSize] = data[k];
            } else if (op < 95) {
                uint32_t addr = static_cast<uint32_t>(rng());
                auto count = static_cast<uint16_t>(1 + rng() % 512);
                auto got = client.peek(addr, count);
                for (size_t k = 0; k < count; k++)
                    if (got[k] != ram[(addr + k) % kRamSize])
                        return finish("command " + std::to_string(i) + ": PEEK " + hex32(addr) + " byte " +
                                      std::to_string(k) + " is wrong");
                crc.update(got);
                r.bytes += count;
            } else {
                auto again = client.info();
                if (again.build_id != info.build_id) return finish("build ID changed mid-run");
            }
        }
        auto end = client.info();
        finish("");
        r.notes += "; the shell dropped " + std::to_string(end.crc_errors) + " corrupt and " +
                   std::to_string(end.timeouts) + " stalled frames";
        return r;
    } catch (const shell::StatusError& e) {
        return finish(e.what());
    }
}

} // namespace rig
