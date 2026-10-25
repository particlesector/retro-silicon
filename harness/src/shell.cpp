// SPDX-License-Identifier: Apache-2.0
#include "rig/shell.hpp"

#include <algorithm>
#include <cstdio>

#include "rig/crc32.hpp"

namespace rig::shell {

namespace {

constexpr size_t kHeader = 5;  // sync, type, seq, len
constexpr size_t kTrailer = 4;  // CRC32

void put16(std::vector<uint8_t>& v, uint16_t x) {
    v.push_back(static_cast<uint8_t>(x));
    v.push_back(static_cast<uint8_t>(x >> 8));
}

void put32(std::vector<uint8_t>& v, uint32_t x) {
    put16(v, static_cast<uint16_t>(x));
    put16(v, static_cast<uint16_t>(x >> 16));
}

uint16_t get16(std::span<const uint8_t> b, size_t i) { return static_cast<uint16_t>(b[i] | b[i + 1] << 8); }
uint32_t get32(std::span<const uint8_t> b, size_t i) { return get16(b, i) | static_cast<uint32_t>(get16(b, i + 2)) << 16; }

std::string hex(unsigned x) {
    char s[16];
    std::snprintf(s, sizeof s, "0x%02x", x);
    return s;
}

} // namespace

std::vector<uint8_t> encode(const Frame& f, uint8_t sync) {
    std::vector<uint8_t> out{sync, f.type, f.seq};
    put16(out, static_cast<uint16_t>(f.payload.size()));
    out.insert(out.end(), f.payload.begin(), f.payload.end());
    Crc32 crc;
    crc.update(std::span(out).subspan(1));
    put32(out, crc.value());
    return out;
}

std::optional<Frame> Parser::next(size_t accept_len) {
    for (;;) {
        auto sync = std::find(buf_.begin(), buf_.end(), sync_);
        buf_.erase(buf_.begin(), sync);
        if (buf_.size() < kHeader) return std::nullopt;
        size_t len = get16(buf_, 3);
        bool plausible = len == 0 || len == accept_len;
        if (plausible && buf_.size() < kHeader + len + kTrailer) return std::nullopt;
        if (plausible) {
            Crc32 crc;
            crc.update(std::span(buf_).subspan(1, kHeader - 1 + len));
            if (crc.value() == get32(buf_, kHeader + len)) {
                Frame f;
                f.type = buf_[1];
                f.seq = buf_[2];
                f.payload.assign(buf_.begin() + kHeader, buf_.begin() + static_cast<std::ptrdiff_t>(kHeader + len));
                buf_.erase(buf_.begin(), buf_.begin() + static_cast<std::ptrdiff_t>(kHeader + len + kTrailer));
                return f;
            }
        }
        bad_frames++;
        buf_.erase(buf_.begin());  // not a frame start: look for the next sync byte
    }
}

Frame Client::transact(uint8_t cmd, std::span<const uint8_t> payload, size_t response_len, int busy_ms) {
    Frame req{cmd, seq_, {payload.begin(), payload.end()}};
    auto wire = encode(req);
    // Wait long enough for the command to go out and the response to start, and
    // longer than the shell's stall timeout, so after a lost byte the shell has
    // dropped the broken frame before the retry arrives.
    int frame_ms = static_cast<int>((wire.size() * 10 * 1000) / link_.baud()) + 1;
    int silence_ms = opt_.shell_idle_ms + 2 * frame_ms + opt_.slack_ms + busy_ms;
    std::vector<uint8_t> buf(4096);
    stats.commands++;

    for (int attempt = 0; attempt < opt_.max_attempts; attempt++) {
        stats.attempts++;
        parser_.clear();
        link_.write(wire);
        for (;;) {
            size_t n = link_.read(buf, silence_ms);
            if (n == 0) break;  // silence: resend
            parser_.feed(std::span(buf.data(), n));
            uint64_t bad_before = parser_.bad_frames;
            while (auto f = parser_.next(response_len)) {
                if (f->seq != seq_) {
                    stats.stale++;
                    continue;
                }
                stats.bad_frames += parser_.bad_frames - bad_before;
                seq_++;
                if (f->type != kOk)
                    throw StatusError(f->type, "shell command " + hex(cmd) + " failed with status " + hex(f->type));
                if (f->payload.size() != response_len)
                    throw StatusError(kOk, "shell response has " + std::to_string(f->payload.size()) +
                                               " bytes, expected " + std::to_string(response_len));
                return *f;
            }
            stats.bad_frames += parser_.bad_frames - bad_before;
        }
    }
    throw RigError("test shell: no valid response to command " + hex(cmd) + " after " +
                   std::to_string(opt_.max_attempts) + " attempts; is a test shell loaded and answering?");
}

std::vector<uint8_t> Client::ping(std::span<const uint8_t> data) { return transact(kPing, data, data.size()).payload; }

Info Client::info() {
    auto p = transact(kInfo, {}, 16).payload;
    if (!std::equal(p.begin(), p.begin() + 4, "RSTS"))
        throw StatusError(kOk, "INFO response doesn't start with RSTS: not a test shell");
    Info i;
    i.version = get16(p, 4);
    i.build_id = get32(p, 6);
    i.max_payload = get16(p, 10);
    i.crc_errors = get16(p, 12);
    i.timeouts = get16(p, 14);
    return i;
}

std::vector<uint8_t> Client::peek(uint32_t addr, uint16_t count) {
    std::vector<uint8_t> args;
    put32(args, addr);
    put16(args, count);
    return transact(kPeek, args, count).payload;
}

void Client::poke(uint32_t addr, std::span<const uint8_t> data) {
    std::vector<uint8_t> args;
    put32(args, addr);
    args.insert(args.end(), data.begin(), data.end());
    transact(kPoke, args, 0);
}

uint32_t Client::crc(uint32_t addr, uint32_t count) {
    std::vector<uint8_t> args;
    put32(args, addr);
    put32(args, count);
    int busy_ms = static_cast<int>(uint64_t{count} * static_cast<uint64_t>(opt_.bus_byte_ns) / 1'000'000) + 1;
    return get32(transact(kCrc, args, 4, busy_ms).payload, 0);
}

namespace {
constexpr size_t kChunk = 2048 - 4;  // the smallest payload buffer, less POKE's address
} // namespace

void Client::write(uint32_t addr, std::span<const uint8_t> data) {
    for (size_t i = 0; i < data.size(); i += kChunk)
        poke(addr + static_cast<uint32_t>(i), data.subspan(i, std::min(kChunk, data.size() - i)));
}

std::vector<uint8_t> Client::read(uint32_t addr, size_t count) {
    std::vector<uint8_t> out;
    out.reserve(count);
    for (size_t i = 0; i < count; i += kChunk) {
        auto part = peek(addr + static_cast<uint32_t>(i), static_cast<uint16_t>(std::min(kChunk, count - i)));
        out.insert(out.end(), part.begin(), part.end());
    }
    return out;
}

} // namespace rig::shell
