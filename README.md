# retro-silicon

Classic consoles and computers rebuilt chip by chip in FPGA logic: reusable SystemVerilog cores, verified against reference emulators in simulation and on real boards. The NES comes first; its CPU, video and test blocks are built to carry over to the Atari 2600, the C64 and the systems after them.

**[retro-silicon.particlesector.com](https://retro-silicon.particlesector.com)** has the rest: each [system](https://retro-silicon.particlesector.com/systems/)'s history and specifications, the live status of every [component](https://retro-silicon.particlesector.com/components/) on every [board](https://retro-silicon.particlesector.com/boards/), the build log, and [how the cores are verified](https://retro-silicon.particlesector.com/about/).

Every component builds with the open-source flow (Yosys, nextpnr, Verilator) and ships with a FuseSoC manifest, so it can be pulled into another project by name.

## Status

The NES runs on three boards from two FPGA families, the Sipeed Tang Nano 20K and Tang Console 138K (Gowin) and the TUL PYNQ-Z2 (AMD), with its CPU, PPU and HDMI output giving the same results as the simulation and the MesenCE emulator. Its APU is next. The site generates each part's status from the latest simulation and board runs: see [Components](https://retro-silicon.particlesector.com/components/), and each component's own README.

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
| `components/` | Reusable blocks, grouped by function, one folder each, each with its README |
| `systems/` | Top levels that wire components together |
| `boards/` | Pins, clocks and the bitstream build for each board |
| `harness/` | C++ test harness core: the link interface, UART models, test-shell client, tests and the Verilator backend |
| `testroms/` | Test-ROM manifest (sources, SHA-256 sums, expected results) and fetch script; the ROMs themselves aren't committed |
| `cmake/` | Shared CMake helpers |
| `tools/` | Host tools: the MesenCE test-ROM runner and golden-frame generator, and `frame.py` (frame to PNG, frame diff) |
| `docs/` | Conventions and design decisions |

See [CONTRIBUTING.md](CONTRIBUTING.md) for what each component folder holds and how to add one.

## Tested with

Verilator 5.053, Yosys 0.70, nextpnr-himbaechel 0.11.1, Apicula 0.35, openFPGALoader 1.1.1 (all OSS CAD Suite 2026-10-16), openXC7 2026-09-24 (nextpnr-xilinx, Project X-Ray) for the PYNQ-Z2, Catch2 3.7.1, FuseSoC 2.4.7, GCC 15.

## License

Code: [Apache-2.0](LICENSE). The website's text and images: CC BY 4.0.
