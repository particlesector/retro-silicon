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
- `cpu/6502`: NMOS 6502, cycle-exact on the bus, with the stable unofficial opcodes and optional NMOS decimal mode; checked against perfect6502 in lockstep, nestest and blargg's instr_test.
- `cmake/Perfect6502.cmake`: fetches perfect6502 at a pinned commit, with SHA-256 checks, for the CPU's lockstep test.
- `memory/sdram`: byte-port controller for a 2M x 32 SDR SDRAM such as the Tang Nano 20K's, with a timing-checking chip model for sim tests.
- `systems/shell-sdram`: the test shell with the SDRAM, with a Tang Nano 20K build and the harness's SDRAM test.
- `systems/nes`: the CPU with RAM, PRG RAM and NROM PRG from SDRAM, run control, a reset-vector override, a stop-at-cycle register and a CRC of the CPU's bus; a Tang Nano 20K build; nestest passes on it with the CPU bench's trace CRC.
- `harness`: iNES parsing, the NES console client and nestest runner, and optional host timing jitter in `SimLink`.
- `debug/test-shell`: CRC command (protocol version 2), so the host can check an upload without reading it back; `Client::crc`, and `write` and `read` for any length.
- `video/ppu-2c02`: the NES's 2C02 PPU (NTSC), dot-exact, with MesenCE's timing, and a save-state port.
- `common/clock-enable`: a clock enable at NUM/DEN of the clock rate, exact on average.
- `debug/video-probe`: frame and line CRCs of a video stream, and line-by-line capture that holds the system.
- `cpu/6502`: a save-state port; `docs/conventions.md` describes the port every component with state gets.
- `systems/nes`: the PPU, OAM DMA, CHR ROM or RAM and nametable mirroring; the NTSC dot rate from 27 MHz with MesenCE's CPU/PPU alignment; stop at a frame count; frame and line CRCs; frame capture; CPU and PPU save-state access.
- `harness`: `nes::rom_test` and the golden frame CRCs from MesenCE (`golden/nes_frames_crc32.txt`) for 42 PPU test ROMs; CHR upload, frame CRCs and frame capture in `nes::Console`.
- `testroms/`: 40 more PPU test ROMs, and the `zeropage` and `frame` checks.
- `tools/mesen/frames.py`: golden frame CRCs and frame dumps from MesenCE; `tools/frame.py`: frame to PNG and frame diff.

### Changed

- The Yosys lint stops before technology mapping and adds Yosys's design checks, so it runs in under a second.
