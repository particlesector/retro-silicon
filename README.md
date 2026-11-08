# retro-silicon

Classic consoles and computers rebuilt chip by chip in FPGA logic: reusable SystemVerilog cores, verified against reference emulators in simulation and on real boards. The NES comes first; its CPU, video and test blocks are built to carry over to the Atari 2600, the C64 and the systems after them.

**[retro-silicon.particlesector.com](https://retro-silicon.particlesector.com)** has the rest: each [system](https://retro-silicon.particlesector.com/systems/)'s history and specifications, the live status of every [component](https://retro-silicon.particlesector.com/components/) on every [board](https://retro-silicon.particlesector.com/boards/), the build log, and [how the cores are verified](https://retro-silicon.particlesector.com/about/).

Every component builds with the open-source flow (Yosys, nextpnr, Verilator) and ships with a FuseSoC manifest, so it can be pulled into another project by name.

## Status

retro-silicon is built one system at a time, starting with the NES. The site shows where every part stands, generated from the latest simulation and board runs: see [Components](https://retro-silicon.particlesector.com/components/) and [Boards](https://retro-silicon.particlesector.com/boards/), and each component's own README.

## Quick start

Needs CMake 3.28+, Ninja, a C++20 compiler, Catch2 3, and [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) on PATH (Verilator, Yosys, nextpnr-himbaechel, Apicula). FuseSoC is optional.

```sh
cmake --preset default
cmake --build --preset default    # also builds the boards' bitstreams when nextpnr is found (nextpnr-xilinx for the PYNQ-Z2)
ctest --preset default

testroms/fetch.py                 # test ROMs into ~/.cache/retro-silicon/testroms; homebrew is
                                  #   built from source (needs cc65's ca65 and Python's Pillow), and so
                                  #   are our own Atari 2600 test cartridges (testroms/a2600)
tools/mesen/check.py              # check they pass in MesenCE, the NES's reference
tools/stella/frames.py            # the Atari 2600's golden frames from Stella (tools/stella/README.md)
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
| `testroms/` | Test-ROM manifests (the NES's `manifest.toml`, the Atari 2600's `manifest-2600.toml`: sources, SHA-256 sums, expected results), the fetch script, and the source of our own 2600 test cartridges (`a2600/`); the ROMs themselves aren't committed |
| `cmake/` | Shared CMake helpers |
| `tools/` | Host tools: the MesenCE test-ROM runner and golden-frame generator, Stella's for the Atari 2600 (`stella-frames`), and `frame.py` (frame to PNG, frame diff) |
| `docs/` | Conventions and design decisions |

See [CONTRIBUTING.md](CONTRIBUTING.md) for what each component folder holds and how to add one.

## Tested with

Verilator 5.053, Yosys 0.70, nextpnr-himbaechel 0.11.1, Apicula 0.35, openFPGALoader 1.1.1 (all OSS CAD Suite 2026-10-16), openXC7 2026-09-24 (nextpnr-xilinx, Project X-Ray) for the PYNQ-Z2, Catch2 3.7.1, FuseSoC 2.4.7, GCC 15.

## License

Code: [Apache-2.0](LICENSE). The website's text and images: CC BY 4.0.
