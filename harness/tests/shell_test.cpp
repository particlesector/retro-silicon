// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <vector>

#include "golden.hpp"
#include "rig/shell.hpp"
#include "rig/shell_test.hpp"
#include "rig/sim_systems.hpp"

using rig::shell::Frame;
using rig::shell::Parser;

TEST_CASE("shell frames round-trip through the parser") {
    Frame f{0x10, 42, {1, 2, 3, 4, 5, 6}};
    auto wire = rig::shell::encode(f, rig::shell::kResponseSync);
    REQUIRE(wire.size() == 5 + 6 + 4);
    REQUIRE(wire[0] == rig::shell::kResponseSync);
    Parser p;
    p.feed(wire);
    auto got = p.next(6);
    REQUIRE(got.has_value());
    REQUIRE(got->type == f.type);
    REQUIRE(got->seq == f.seq);
    REQUIRE(got->payload == f.payload);
    REQUIRE_FALSE(p.next(6).has_value());
}

TEST_CASE("shell parser skips noise, false syncs and bad CRCs") {
    auto good = rig::shell::encode({0x00, 7, {9, 9, 9}}, rig::shell::kResponseSync);
    auto bad = good;
    bad[6] ^= 0x40;
    // Noise with sync bytes in it, a damaged frame, then the good one.
    std::vector<uint8_t> stream{0x00, 0x5A, 0x13, 0x5A, 0x5A, 0x01, 0x02};
    stream.insert(stream.end(), bad.begin(), bad.end());
    stream.insert(stream.end(), good.begin(), good.end());
    Parser p;
    // Byte by byte, as a slow link would deliver it.
    std::optional<Frame> got;
    for (uint8_t b : stream) {
        p.feed(std::span(&b, 1));
        if (auto f = p.next(3)) got = f;
    }
    REQUIRE(got.has_value());
    REQUIRE(got->payload == std::vector<uint8_t>{9, 9, 9});
    REQUIRE(p.bad_frames >= 4);
}

TEST_CASE("shell parser waits for the rest of a partial frame") {
    auto wire = rig::shell::encode({0x00, 1, std::vector<uint8_t>(100, 0x55)}, rig::shell::kResponseSync);
    Parser p;
    p.feed(std::span(wire).first(50));
    REQUIRE_FALSE(p.next(100).has_value());
    p.feed(std::span(wire).subspan(50));
    REQUIRE(p.next(100).has_value());
}

TEST_CASE("1000 shell commands succeed on the sim backend with faults injected, with the golden CRC") {
    auto golden = golden_crcs(RS_SHELL_GOLDEN);
    auto it = golden.find({1000, 1});
    REQUIRE(it != golden.end());

    auto link = rig::make_shell_ram_sim();
    auto r = rig::shell_test(*link, 1000, 1, 0.0002, RS_SHELL_RAM_BUILD_ID);
    INFO(r.detail << " / " << r.notes);
    REQUIRE(r.passed);
    REQUIRE(r.crc32 == it->second);
}

TEST_CASE("the shell test's CRC depends on the seed, not on injected faults") {
    auto clean = rig::make_shell_ram_sim();
    auto damaged = rig::make_shell_ram_sim();
    auto a = rig::shell_test(*clean, 100, 2, 0.0, RS_SHELL_RAM_BUILD_ID);
    auto b = rig::shell_test(*damaged, 100, 2, 0.0002, RS_SHELL_RAM_BUILD_ID);
    INFO(a.detail << b.detail << " / " << b.notes);
    REQUIRE(a.passed);
    REQUIRE(b.passed);
    REQUIRE(a.crc32 == b.crc32);
    REQUIRE(a.bytes == b.bytes);
}
