// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <deque>
#include <optional>

#include "golden.hpp"
#include "rig/echo_test.hpp"

namespace {

// An in-memory echo that can corrupt, drop or duplicate one byte.
struct FakeLink : rig::Link {
    std::deque<uint8_t> pending;
    uint64_t written = 0;
    std::optional<uint64_t> corrupt_at, drop_at, extra_at;

    void write(std::span<const uint8_t> data) override {
        for (uint8_t b : data) {
            uint64_t i = written++;
            if (drop_at == i) continue;
            pending.push_back(corrupt_at == i ? static_cast<uint8_t>(b ^ 0x10) : b);
            if (extra_at == i) pending.push_back(0xAA);
        }
    }

    size_t read(std::span<uint8_t> buf, int) override {
        size_t n = 0;
        while (n < buf.size() && !pending.empty()) {
            buf[n++] = pending.front();
            pending.pop_front();
        }
        return n;
    }

    unsigned baud() const override { return 1'500'000; }
};

} // namespace

TEST_CASE("echo passes on a perfect link, with a CRC that depends only on the data") {
    FakeLink a, b;
    auto ra = rig::echo_test(a, 100'000, 1);
    auto rb = rig::echo_test(b, 100'000, 1);
    REQUIRE(ra.passed);
    REQUIRE(ra.bytes == 100'000);
    REQUIRE(ra.crc32 == rb.crc32);
    REQUIRE(rig::echo_test(b, 100'000, 2).crc32 != ra.crc32);
}

TEST_CASE("echo reports a corrupted byte at its offset") {
    FakeLink link;
    link.corrupt_at = 5000;
    auto r = rig::echo_test(link, 10'000, 1);
    REQUIRE_FALSE(r.passed);
    REQUIRE(r.bytes == 5000);
    REQUIRE(r.detail.starts_with("offset 5000:"));
}

TEST_CASE("echo reports a dropped byte") {
    FakeLink link;
    link.drop_at = 3000;
    auto r = rig::echo_test(link, 10'000, 1);
    REQUIRE_FALSE(r.passed);
    REQUIRE(r.bytes == 3000);  // the next byte arrives where the dropped one should be
}

TEST_CASE("echo reports an extra byte") {
    FakeLink link;
    link.extra_at = 9999;
    auto r = rig::echo_test(link, 10'000, 1);
    REQUIRE_FALSE(r.passed);
    REQUIRE(r.detail.starts_with("extra byte"));
}

TEST_CASE("echo CRCs match the golden values") {
    auto golden = golden_crcs(RS_ECHO_GOLDEN);
    REQUIRE_FALSE(golden.empty());
    for (auto [key, crc] : golden) {
        auto [bytes, seed] = key;
        CAPTURE(bytes, seed);
        FakeLink link;
        auto r = rig::echo_test(link, bytes, seed);
        REQUIRE(r.passed);
        REQUIRE(r.crc32 == crc);
    }
}
