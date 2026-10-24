# retro-silicon

Reusable FPGA components for recreating retro consoles and computers, written in plain SystemVerilog and verified in Verilator against software models and real-hardware test ROMs. The NES comes first; the CPU, CRC, UART and test blocks are built to carry over to the Atari 2600, C64 and others.

Every component builds with the open-source flow (Yosys, nextpnr, Verilator) and ships with a FuseSoC manifest, so it can be pulled into another project by name.

## Status

| Component | What it is | Sim tests | Board run |
| --- | --- | --- | --- |
| [common/crc32](components/common/crc32) | CRC-32 (IEEE, as zlib), one byte per clock | ✅ | — |
| [common/uart](components/common/uart) | 8N1 receiver and transmitter | ✅ | ✅ Tang Nano 20K, in uart-echo |
| [common/fifo](components/common/fifo) | Synchronous FIFO in block RAM | ✅ | ✅ Tang Nano 20K, in uart-echo |
| [common/por](components/common/por) | Power-on reset | ✅ | ✅ Tang Nano 20K, in uart-echo |
| [debug/test-shell](components/debug/test-shell) | UART command engine: CRC-checked frames, retries, bus access, build ID | ✅ | ✅ Tang Nano 20K, in shell-ram |
| [systems/uart-echo](systems/uart-echo) | UART link test: echoes every byte | ✅ | ✅ Tang Nano 20K: 100 MB at 1.5 Mbaud, no errors |
| [systems/shell-ram](systems/shell-ram) | Test shell with a scratch RAM | ✅ | ✅ Tang Nano 20K: 1,000 commands with faults injected, same CRC as the sim |

A board run means the same test, with the same data, passed on real hardware with the same result as the simulation.

## Quick start

Needs CMake 3.28+, Ninja, a C++20 compiler, Catch2 3, and [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) on PATH (Verilator, Yosys, nextpnr-himbaechel, Apicula). FuseSoC is optional.

```sh
cmake --preset default
cmake --build --preset default    # also builds Tang Nano 20K bitstreams when nextpnr is found
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
| `tools/` | Host tools, such as the MesenCE test-ROM runner |
| `docs/` | Conventions and design decisions |

See [CONTRIBUTING.md](CONTRIBUTING.md) for what each component folder holds and how to add one.

## Tested with

Verilator 5.053, Yosys 0.70, nextpnr-himbaechel 0.11.1, Apicula 0.35, openFPGALoader 1.1.1 (all OSS CAD Suite 2026-10-16), Catch2 3.7.1, FuseSoC 2.4.7, GCC 15.

## License

[Apache-2.0](LICENSE).
