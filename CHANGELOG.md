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
- `memory/arbiter`: fixed-priority sharing of one byte-port memory among N clients.
- `memory/bram`: block RAM behind `memory/sdram`'s byte port.
- `common/save-state`: saves and loads a system's state by walking byte regions of its bus into a buffer.
- `common/crc32`: a save-state write, so a restored CRC carries on.
- `systems/nes`: save states (save at the next frame boundary, load, and the buffer through the shell), the system's own state words, and an unmirrored view of the nametable RAM; `nes_sdram` and `nes_bram` put memory behind it.
- `boards/tang-console-138k`: the Tang Console 138K, at 50 MHz, with uart-echo, shell-ram and the NES on block RAM.
- `harness`: `nes::Console::save_state` and `load_state`, `nes::state_test`, and the NES model on block RAM at 50 MHz (`make_nes_bram_sim`); `SimLink` takes the model's clock rate.

### Changed

- The Yosys lint stops before technology mapping and adds Yosys's design checks, so it runs in under a second.
- `systems/nes` takes its memory as a byte port, through `memory/arbiter`, instead of driving the SDRAM itself; its `FREQ_MHZ` moved to `nes_sdram`.
- `video/ppu-2c02` registers its next dot every clock and commits it on `ce`, so its dot logic has the clocks between dots: `ce` must now come at least 2 clocks apart, with `vrdata` and the register and state writes settled the clock before. `systems/nes` gives the PPU its video memory for the two clocks before each dot. The Tang Console 138K's NES build goes from 49 MHz to 72 MHz.
- `boards/gowin/build.sh` holds the Gowin open-flow build; each board's `build.sh` calls it with its part. `rs_board_bitstream` replaces `rs_tang_bitstream`.
