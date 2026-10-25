// SPDX-License-Identifier: Apache-2.0
#pragma once
// Host side of the test shell (components/debug/test-shell). Frames, both ways:
//   sync | cmd or status | seq | len (2, LE) | payload | CRC32 (4, LE, over cmd..payload)
// Commands start with sync byte A5, responses with 5A, so an echo or loopback
// never passes for a shell. One command at a time; every command is idempotent, so the client resends it
// after a timeout or a bad response until it gets a good one.

#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

#include "rig/link.hpp"

namespace rig::shell {

constexpr uint8_t kCommandSync = 0xA5;
constexpr uint8_t kResponseSync = 0x5A;

enum Cmd : uint8_t { kPing = 0x01, kInfo = 0x02, kPeek = 0x10, kPoke = 0x11, kCrc = 0x12 };
constexpr uint16_t kVersion = 2;  // the protocol version this client speaks
enum Status : uint8_t { kOk = 0x00, kUnknownCmd = 0x01, kBadLength = 0x02 };

struct Frame {
    uint8_t type = 0;  // command, or status in a response
    uint8_t seq = 0;
    std::vector<uint8_t> payload;
};

std::vector<uint8_t> encode(const Frame& f, uint8_t sync = kCommandSync);

// Finds frames in a byte stream with noise, losses and partial frames. A frame
// whose length isn't one of `accept_len` (or 0) is taken as a false sync byte.
class Parser {
public:
    explicit Parser(uint8_t sync = kResponseSync) : sync_(sync) {}
    void feed(std::span<const uint8_t> bytes) { buf_.insert(buf_.end(), bytes.begin(), bytes.end()); }
    std::optional<Frame> next(size_t accept_len);
    void clear() { buf_.clear(); }
    uint64_t bad_frames = 0;  // sync bytes that didn't start a valid frame

private:
    uint8_t sync_;
    std::vector<uint8_t> buf_;
};

// Thrown when the shell answers with an error status: the design rejected the command.
struct StatusError : std::runtime_error {
    StatusError(uint8_t status, const std::string& what) : std::runtime_error(what), status(status) {}
    uint8_t status;
};

struct Info {
    uint16_t version = 0;
    uint32_t build_id = 0;
    uint16_t max_payload = 0;
    uint16_t crc_errors = 0;  // command frames the shell dropped as corrupt
    uint16_t timeouts = 0;    // command frames the shell dropped as stalled
};

class Client {
public:
    struct Options {
        int max_attempts = 20;
        int shell_idle_ms = 10;  // the shell's IDLE_CLKS: a stalled frame is dropped after this
        int slack_ms = 5;        // extra wait for USB and OS latency on a real link
        int bus_byte_ns = 2000;  // longest a bus access may take: CRC waits this per byte
    };

    explicit Client(Link& link) : Client(link, Options{}) {}
    Client(Link& link, Options opt) : link_(link), opt_(opt) {}

    std::vector<uint8_t> ping(std::span<const uint8_t> data);
    Info info();
    std::vector<uint8_t> peek(uint32_t addr, uint16_t count);
    void poke(uint32_t addr, std::span<const uint8_t> data);
    // CRC-32 (as zlib) of `count` bytes from the bus, computed by the shell.
    uint32_t crc(uint32_t addr, uint32_t count);

    // Any length, split into commands that fit the shell's payload buffer.
    void write(uint32_t addr, std::span<const uint8_t> data);
    std::vector<uint8_t> read(uint32_t addr, size_t count);

    // Sends a command until a response with its sequence number arrives; throws
    // RigError when every attempt fails, StatusError on an error status.
    // `busy_ms` is how long the shell may work before it starts answering.
    Frame transact(uint8_t cmd, std::span<const uint8_t> payload, size_t response_len, int busy_ms = 0);

    struct Stats {
        uint64_t commands = 0;
        uint64_t attempts = 0;  // more than commands when some were resent
        uint64_t bad_frames = 0;
        uint64_t stale = 0;     // well-formed responses to an earlier command
    } stats;

private:
    Link& link_;
    Options opt_;
    Parser parser_;
    uint8_t seq_ = 0;
};

} // namespace rig::shell
