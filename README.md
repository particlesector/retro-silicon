# retro-silicon

Reusable FPGA components for recreating retro consoles and computers, written in plain SystemVerilog and verified in Verilator against software models and real-hardware test ROMs. The NES comes first; the CPU, CRC, UART and test blocks are built to carry over to the Atari 2600, C64 and others.

Every component builds with the open-source flow (Yosys, nextpnr, Verilator) and ships with a FuseSoC manifest, so it can be pulled into another project by name.

## Status

| Component | What it is | Sim tests | Board run |
| --- | --- | --- | --- |
| [cpu/6502](components/cpu/6502) | NMOS 6502, cycle-exact on the bus; decimal mode optional (off for the NES); save-state port | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in nes |
| [video/ppu-2c02](components/video/ppu-2c02) | The NES's 2C02 PPU (NTSC), dot-exact; frames match MesenCE's; save-state port | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in nes |
| [video/hdmi](components/video/hdmi) | Video timing and TMDS encoding for HDMI (DVI mode), 720p60 by default | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in nes |
| [video/line-scaler](components/video/line-scaler) | A source's frames on a display of another clock, scaled up through a ring of lines, the source kept in step | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in nes |
| [common/cdc](components/common/cdc) | Flip-flop synchronizer between clock domains | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in nes |
| [common/clock-enable](components/common/clock-enable) | Clock enable at NUM/DEN of the clock rate, exact on average | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in nes |
| [debug/video-probe](components/debug/video-probe) | Frame and line CRCs of a video stream, and line-by-line frame capture | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in nes |
| [common/crc32](components/common/crc32) | CRC-32 (IEEE, as zlib), one byte per clock | ✅ | ✅ Tang Nano 20K, in shell-sdram and nes; PYNQ-Z2, in nes |
| [memory/sdram](components/memory/sdram) | Byte-port controller for a 2M × 32 SDR SDRAM, such as the Tang Nano 20K's | ✅ | ✅ Tang Nano 20K, in shell-sdram and nes |
| [memory/arbiter](components/memory/arbiter) | Fixed-priority sharing of one byte-port memory | ✅ | ✅ all three boards, in nes |
| [memory/bram](components/memory/bram) | Block RAM behind the same byte port | ✅ | ✅ Tang Console 138K and PYNQ-Z2, in nes |
| [common/save-state](components/common/save-state) | Saves and loads a system's whole state through its bus | ✅ | ✅ all three boards, in nes |
| [common/uart](components/common/uart) | 8N1 receiver and transmitter | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in uart-echo |
| [common/fifo](components/common/fifo) | Synchronous FIFO in block RAM | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in uart-echo |
| [common/por](components/common/por) | Power-on reset | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in uart-echo |
| [debug/test-shell](components/debug/test-shell) | UART command engine: CRC-checked frames, retries, bus access, build ID | ✅ | ✅ Tang Nano 20K and PYNQ-Z2, in shell-ram |
| [systems/uart-echo](systems/uart-echo) | UART link test: echoes every byte | ✅ | ✅ Tang Nano 20K: 100 MB at 1.5 Mbaud, no errors; PYNQ-Z2 (openXC7): 10 MB |
| [systems/shell-ram](systems/shell-ram) | Test shell with a scratch RAM | ✅ | ✅ Tang Nano 20K: 1,000 commands with faults injected, same CRC as the sim; PYNQ-Z2 (openXC7): the same |
| [systems/shell-sdram](systems/shell-sdram) | Test shell with the SDRAM | ✅ | ✅ Tang Nano 20K: 8 MB written and checked, same CRC as the sim |
| [systems/nes](systems/nes) | The NES so far: CPU, PPU, OAM DMA, RAM, PRG RAM, an NROM cartridge; save states | ✅ | ✅ Tang Nano 20K and Tang Console 138K: nestest's bus-trace CRC, and 42 PPU test ROMs pass with MesenCE's frame CRCs; save states round-trip, and move between the boards; on the 20K, HDMI at 720p whose video CRCs match the sim's. PYNQ-Z2 (openXC7): the same, with HDMI |

A board run means the same test, with the same data, passed on real hardware with the same result as the simulation.

## Quick start

Needs CMake 3.28+, Ninja, a C++20 compiler, Catch2 3, and [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) on PATH (Verilator, Yosys, nextpnr-himbaechel, Apicula). FuseSoC is optional.

```sh
cmake --preset default
cmake --build --preset default    # also builds the boards' bitstreams when nextpnr is found (nextpnr-xilinx for the PYNQ-Z2)
ctest --preset default

testroms/fetch.py                 # test ROMs into ~/.cache/retro-silicon/testroms
tools/mesen/check.py              # check they pass in MesenCE, the reference
```

Use a component from another FuseSoC project:

```sh
fusesoc library add retro-silicon https://github.com/particlesector/retro-silicon
```

then depend on it by name, for example `retro-silicon:common:uart`.

## Layout

| Path | Holds |
| --- | --- |
| `components/` | Reusable blocks, grouped by function, one folder each |
| `systems/` | Top levels that wire components together |
| `boards/` | Pins, clocks and the bitstream build for each board |
| `harness/` | C++ test harness core: the link interface, UART models, test-shell client, tests and the Verilator backend |
| `testroms/` | Test-ROM manifest (sources, SHA-256 sums, expected results) and fetch script; the ROMs themselves aren't committed |
| `cmake/` | Shared CMake helpers |
| `tools/` | Host tools: the MesenCE test-ROM runner and golden-frame generator, and `frame.py` (frame to PNG, frame diff) |
| `docs/` | Conventions and design decisions |

See [CONTRIBUTING.md](CONTRIBUTING.md) for what each component folder holds and how to add one.

## Tested with

Verilator 5.053, Yosys 0.70, nextpnr-himbaechel 0.11.1, Apicula 0.35, openFPGALoader 1.1.1 (all OSS CAD Suite 2026-10-16), Catch2 3.7.1, FuseSoC 2.4.7, GCC 15.

## License

[Apache-2.0](LICENSE).
