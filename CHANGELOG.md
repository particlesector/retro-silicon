# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and component versions follow [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- `common/crc32`: CRC-32 (IEEE 802.3, as zlib), one byte per enabled clock.
- `common/uart`: 8N1 receiver and transmitter; back-to-back bytes take exactly 10 bit times.
- `common/fifo`: synchronous FIFO with a registered read port, inferred as block RAM.
- `common/por`: power-on reset.
- `systems/uart-echo`: UART link test, with a Tang Nano 20K build at 1.5 Mbaud.
- `harness`: link interface, bit-level UART models, CRC32, the echo test and its Verilator backend.
- CMake helpers, FuseSoC manifests for every component, and lint tests (Verilator, Yosys, FuseSoC).
- `debug/test-shell`: UART command engine with CRC-checked frames, retries, build ID, PING, INFO, PEEK and POKE.
- `systems/shell-ram`: the test shell with a scratch RAM, with a Tang Nano 20K build.
- `harness`: test-shell client, `FaultyLink` for fault injection, the shell test, and `SimLink` for any Verilated UART design.
- `testroms/`: manifest of NES test ROMs with SHA-256 sums and expected results, and a fetch script.
- `tools/mesen`: MesenCE Lua runner and checker for blargg-style test ROMs.
- `rs_build_id`: a build ID derived from a system's RTL.

### Changed

- The Yosys lint stops before technology mapping and adds Yosys's design checks, so it runs in under a second.
