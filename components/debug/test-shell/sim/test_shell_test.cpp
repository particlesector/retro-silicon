// SPDX-License-Identifier: Apache-2.0
#include <catch2/catch_test_macros.hpp>

#include <cstdint>
#include <random>
#include <unordered_map>
#include <vector>

#include "Vtest_shell.h"
#include "rig/crc32.hpp"
#include "rig/faulty_link.hpp"
#include "rig/shell.hpp"
#include "rig/sim_link.hpp"

namespace {

constexpr int kClksPerBit = 4;  // matches the CMake PARAMS
using rig::shell::Client;
using rig::shell::StatusError;

// test_shell with a 32-bit sparse memory on its bus that acknowledges after a
// random 0-4 clocks. Untouched bytes read as a pattern of their address.
struct Bench : rig::SimModel {
    Vtest_shell m;
    std::unordered_map<uint32_t, uint8_t> mem;
    std::mt19937 rng{9};
    int wait = -1;
    int resets = 4;
    uint64_t reads = 0, writes = 0;

    static uint8_t pattern(uint32_t a) { return static_cast<uint8_t>(a * 7 + (a >> 16) + 3); }

    uint8_t read(uint32_t a) const {
        auto it = mem.find(a);
        return it == mem.end() ? pattern(a) : it->second;
    }

    bool tick(bool rx) override {
        m.rst = resets > 0;
        if (resets > 0) resets--;
        m.uart_rx = rx;
        m.clk = 0;
        m.eval();
        // Bus inputs for the coming edge, from the shell's registered outputs.
        if (m.bus_ack) {
            m.bus_ack = 0;  // acknowledge lasts one clock
        } else if (m.bus_req) {
            if (wait < 0) wait = static_cast<int>(rng() % 5);
            if (wait-- == 0) {
                if (m.bus_we) {
                    mem[m.bus_addr] = m.bus_wdata;
                    writes++;
                } else {
                    m.bus_rdata = read(m.bus_addr);
                    reads++;
                }
                m.bus_ack = 1;
                wait = -1;
            }
        }
        m.eval();
        m.clk = 1;
        m.eval();
        return m.uart_tx;
    }
};

struct Fixture {
    Bench* bench;
    std::unique_ptr<rig::SimLink> link;

    Fixture() {
        auto b = std::make_unique<Bench>();
        bench = b.get();
        link = std::make_unique<rig::SimLink>(std::move(b), kClksPerBit);
    }

    // The bench's IDLE_CLKS is 2,700 clocks, 0.1 ms.
    Client client() { return Client(*link, Client::Options{.max_attempts = 20, .shell_idle_ms = 1, .slack_ms = 0}); }

    // Sends raw bytes and returns whatever comes back within `ms`.
    std::vector<uint8_t> raw(const std::vector<uint8_t>& bytes, int ms) {
        link->write(bytes);
        std::vector<uint8_t> out, buf(4096);
        while (size_t n = link->read(buf, ms)) out.insert(out.end(), buf.begin(), buf.begin() + static_cast<long>(n));
        return out;
    }
};

std::vector<uint8_t> random_bytes(std::mt19937& rng, size_t n) {
    std::vector<uint8_t> v(n);
    for (auto& b : v) b = static_cast<uint8_t>(rng());
    return v;
}

uint8_t status_of(Client& c, uint8_t cmd, std::vector<uint8_t> payload) {
    try {
        c.transact(cmd, payload, 0);
    } catch (const StatusError& e) {
        return e.status;
    }
    return rig::shell::kOk;
}

} // namespace

TEST_CASE("test_shell INFO reports the magic, version, build ID and payload limit") {
    Fixture f;
    auto c = f.client();
    auto i = c.info();
    REQUIRE(i.version == rig::shell::kVersion);
    REQUIRE(i.build_id == 0x12345678u);
    REQUIRE(i.max_payload == 2048);
    REQUIRE(i.crc_errors == 0);
    REQUIRE(i.timeouts == 0);
    REQUIRE(c.stats.attempts == 1);
}

TEST_CASE("test_shell PING echoes payloads from empty to the full buffer") {
    Fixture f;
    auto c = f.client();
    std::mt19937 rng(1);
    for (size_t n : {0, 1, 2, 255, 2047, 2048}) {
        auto data = random_bytes(rng, n);
        CAPTURE(n);
        REQUIRE(c.ping(data) == data);
    }
    REQUIRE(c.stats.attempts == c.stats.commands);
}

TEST_CASE("test_shell POKE and PEEK reach the whole 32-bit bus") {
    Fixture f;
    auto c = f.client();
    std::mt19937 rng(2);
    for (uint32_t addr : {0x0u, 0x1234u, 0x80000000u, 0xFFFFFF00u}) {
        auto data = random_bytes(rng, 200);
        c.poke(addr, data);
        CAPTURE(addr);
        REQUIRE(c.peek(addr, 200) == data);
    }
    // Untouched memory reads as the bench's pattern.
    auto got = c.peek(0x40000000u, 64);
    for (uint32_t k = 0; k < 64; k++) REQUIRE(got[k] == Bench::pattern(0x40000000u + k));
    // A POKE with no data is fine and writes nothing.
    uint64_t writes = f.bench->writes;
    c.poke(0x10, {});
    REQUIRE(f.bench->writes == writes);
}

TEST_CASE("test_shell CRC matches the bytes on the bus") {
    Fixture f;
    auto c = f.client();
    std::mt19937 rng(3);
    auto data = random_bytes(rng, 5000);
    c.write(0x00100000u, data);  // three POKEs
    REQUIRE(c.read(0x00100000u, data.size()) == data);
    for (size_t n : {size_t{0}, size_t{1}, size_t{9}, data.size()}) {
        rig::Crc32 want;
        want.update(std::span(data).first(n));
        CAPTURE(n);
        REQUIRE(c.crc(0x00100000u, static_cast<uint32_t>(n)) == want.value());
    }
    REQUIRE(c.crc(0, 0) == 0u);
    // A count that runs past the top of the address space wraps to 0.
    c.poke(0xFFFFFFFFu, std::vector<uint8_t>{0x31});
    c.poke(0, std::vector<uint8_t>{0x32});
    rig::Crc32 want;
    want.update(std::vector<uint8_t>{0x31, 0x32});
    REQUIRE(c.crc(0xFFFFFFFFu, 2) == want.value());
}

TEST_CASE("test_shell answers unknown commands and bad lengths with an error status") {
    Fixture f;
    auto c = f.client();
    REQUIRE(status_of(c, 0x7F, {}) == rig::shell::kUnknownCmd);
    REQUIRE(status_of(c, rig::shell::kInfo, {0}) == rig::shell::kBadLength);
    REQUIRE(status_of(c, rig::shell::kPeek, {0, 0, 0, 0, 1}) == rig::shell::kBadLength);
    REQUIRE(status_of(c, rig::shell::kPoke, {0, 0, 0}) == rig::shell::kBadLength);
    REQUIRE(status_of(c, rig::shell::kCrc, {0, 0, 0, 0, 1, 0, 0}) == rig::shell::kBadLength);
    REQUIRE(f.bench->reads + f.bench->writes == 0);
    REQUIRE(c.info().version == rig::shell::kVersion);  // still answering
}

TEST_CASE("test_shell drops a corrupt frame without answering, and counts it") {
    Fixture f;
    auto frame = rig::shell::encode({rig::shell::kPing, 0, {1, 2, 3}});
    frame[6] ^= 0x01;  // a payload bit
    REQUIRE(f.raw(frame, 2).empty());
    auto c = f.client();
    REQUIRE(c.info().crc_errors == 1);
}

TEST_CASE("test_shell drops a frame that stalls, and counts it") {
    Fixture f;
    auto frame = rig::shell::encode({rig::shell::kPing, 0, {1, 2, 3, 4}});
    frame.resize(7);  // stop mid-payload
    REQUIRE(f.raw(frame, 2).empty());
    auto c = f.client();
    auto i = c.info();
    REQUIRE(i.timeouts == 1);
    REQUIRE(i.crc_errors == 0);
}

TEST_CASE("test_shell responses start with 5A, so an echo of a command never passes for one") {
    Fixture f;
    auto reply = f.raw(rig::shell::encode({rig::shell::kInfo, 3, {}}), 2);
    REQUIRE(reply.size() == 5 + 16 + 4);
    REQUIRE(reply[0] == rig::shell::kResponseSync);
    // The command itself, parsed as a response, is ignored.
    rig::shell::Parser p;
    p.feed(rig::shell::encode({rig::shell::kInfo, 3, {}}));
    REQUIRE_FALSE(p.next(16).has_value());
}

TEST_CASE("test_shell resyncs at once after a length over its buffer") {
    Fixture f;
    // A header claiming 65,535 bytes, then straight away a good INFO.
    std::vector<uint8_t> bytes{rig::shell::kCommandSync, rig::shell::kPing, 0, 0xFF, 0xFF};
    auto info = rig::shell::encode({rig::shell::kInfo, 7, {}});
    bytes.insert(bytes.end(), info.begin(), info.end());
    auto reply = f.raw(bytes, 2);
    rig::shell::Parser p;
    p.feed(reply);
    auto r = p.next(16);
    REQUIRE(r.has_value());
    REQUIRE(r->seq == 7);
    REQUIRE(r->payload[12] == 1);  // crc_errors: the bad header
}

TEST_CASE("test_shell commands all succeed over a damaged link") {
    Fixture f;
    rig::FaultyLink faulty(*f.link, 0.002, 3);
    Client c(faulty, Client::Options{.max_attempts = 20, .shell_idle_ms = 1, .slack_ms = 0});
    std::mt19937 rng(4);
    std::unordered_map<uint32_t, uint8_t> model;
    for (int i = 0; i < 300; i++) {
        uint32_t addr = rng() % 4096;
        switch (rng() % 3) {
        case 0: {
            auto data = random_bytes(rng, rng() % 200);
            REQUIRE(c.ping(data) == data);
            break;
        }
        case 1: {
            auto data = random_bytes(rng, 1 + rng() % 100);
            c.poke(addr, data);
            for (size_t k = 0; k < data.size(); k++) model[addr + static_cast<uint32_t>(k)] = data[k];
            break;
        }
        default: {
            auto got = c.peek(addr, 100);
            for (uint32_t k = 0; k < 100; k++) {
                auto it = model.find(addr + k);
                REQUIRE(got[k] == (it == model.end() ? Bench::pattern(addr + k) : it->second));
            }
        }
        }
    }
    INFO(faulty.faults << " faults, " << c.stats.attempts << " attempts");
    REQUIRE(faulty.faults > 20);
    REQUIRE(c.stats.attempts > c.stats.commands);
}
