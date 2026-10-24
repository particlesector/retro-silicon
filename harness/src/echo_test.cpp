// SPDX-License-Identifier: Apache-2.0
#include "rig/echo_test.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <deque>
#include <random>
#include <vector>

#include "rig/crc32.hpp"

namespace rig {

TestResult echo_test(Link& link, uint64_t bytes, unsigned seed, size_t window) {
    TestResult r;
    r.name = "echo";
    std::mt19937 rng(seed);
    std::deque<uint8_t> in_flight;  // sent, not yet echoed
    std::vector<uint8_t> out, in(65536);
    Crc32 crc;
    uint64_t sent = 0;
    // Generous: four times what a full window takes on the wire, and at least 100 ms.
    int timeout_ms = std::max<int>(100, static_cast<int>(window * 10 * 4000 / link.baud()));
    auto t0 = std::chrono::steady_clock::now();

    auto fail = [&](std::string detail) {
        r.detail = std::move(detail);
        r.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        r.crc32 = crc.value();
        return r;
    };

    while (r.bytes < bytes) {
        size_t n = static_cast<size_t>(std::min<uint64_t>(window - in_flight.size(), bytes - sent));
        if (n > 0) {
            out.resize(n);
            for (auto& b : out) b = static_cast<uint8_t>(rng());
            link.write(out);
            in_flight.insert(in_flight.end(), out.begin(), out.end());
            sent += n;
        }

        size_t got = link.read(in, timeout_ms);
        if (got == 0)
            return fail("no data for " + std::to_string(timeout_ms) + " ms; " + std::to_string(r.bytes) + " of " +
                        std::to_string(sent) + " bytes echoed");
        for (size_t i = 0; i < got; i++) {
            if (in_flight.empty())
                return fail("extra byte after offset " + std::to_string(r.bytes));
            if (in[i] != in_flight.front()) {
                char msg[96];
                std::snprintf(msg, sizeof msg, "offset %llu: sent 0x%02x, got 0x%02x",
                              static_cast<unsigned long long>(r.bytes), in_flight.front(), in[i]);
                return fail(msg);
            }
            in_flight.pop_front();
            r.bytes++;
        }
        crc.update(std::span(in.data(), got));
    }

    r.passed = true;
    r.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    r.crc32 = crc.value();
    return r;
}

} // namespace rig
