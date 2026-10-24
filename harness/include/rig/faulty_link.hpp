// SPDX-License-Identifier: Apache-2.0
#pragma once
// Wraps a Link and damages bytes in both directions at a seeded random rate:
// each byte is dropped, corrupted or followed by a stray byte, each with
// probability rate / 3. Used to prove a protocol recovers from a bad link.

#include <cstdint>
#include <deque>
#include <random>
#include <vector>

#include "rig/link.hpp"

namespace rig {

class FaultyLink : public Link {
public:
    FaultyLink(Link& inner, double rate, unsigned seed) : inner_(inner), p_(rate / 3), rng_(seed) {}

    void write(std::span<const uint8_t> data) override {
        std::deque<uint8_t> out;
        damage(data, out);
        std::vector<uint8_t> v(out.begin(), out.end());
        inner_.write(v);
    }

    size_t read(std::span<uint8_t> buf, int timeout_ms) override {
        std::vector<uint8_t> tmp(buf.size());
        while (pending_.empty()) {
            size_t n = inner_.read(tmp, timeout_ms);
            if (n == 0) return 0;
            damage(std::span(tmp.data(), n), pending_);
        }
        size_t n = 0;
        while (n < buf.size() && !pending_.empty()) {
            buf[n++] = pending_.front();
            pending_.pop_front();
        }
        return n;
    }

    unsigned baud() const override { return inner_.baud(); }

    uint64_t faults = 0;

private:
    void damage(std::span<const uint8_t> in, std::deque<uint8_t>& out) {
        std::uniform_real_distribution<double> u(0, 1);
        for (uint8_t b : in) {
            double r = u(rng_);
            if (r < p_) {
                faults++;  // dropped
            } else if (r < 2 * p_) {
                faults++;
                out.push_back(static_cast<uint8_t>(b ^ (1 + rng_() % 255)));
            } else if (r < 3 * p_) {
                faults++;
                out.push_back(b);
                out.push_back(static_cast<uint8_t>(rng_()));
            } else
                out.push_back(b);
        }
    }

    Link& inner_;
    double p_;
    std::mt19937 rng_;
    std::deque<uint8_t> pending_;
};

} // namespace rig
