# retro-silicon

Classic consoles and computers rebuilt chip by chip in FPGA logic: reusable SystemVerilog cores, verified against reference emulators in simulation and on real boards. Two systems are complete, the NES and the Atari 2600, each on three boards (Sipeed's Tang Nano 20K and Tang Console 138K, and TUL's PYNQ-Z2); their CPU, video, memory and test blocks carry over to the systems after them.

**[retro-silicon.particlesector.com](https://retro-silicon.particlesector.com)** has the rest: each [system](https://retro-silicon.particlesector.com/systems/)'s history and specifications, the live status of every [component](https://retro-silicon.particlesector.com/components/) on every [board](https://retro-silicon.particlesector.com/boards/), the build log, and [how the cores are verified](https://retro-silicon.particlesector.com/about/).

Every component builds with the open-source flow (Yosys, nextpnr, Verilator) and ships with a FuseSoC manifest, so it can be pulled into another project by name. Only `boards/` depends on a vendor's tools: the Tang Console 138K builds with Gowin EDA's free Education edition, as the open flow has no PLL for its chip.

## Status

retro-silicon is built one system at a time. The NES (`systems/nes`) and the Atari 2600 (`systems/atari-2600`) are complete: every test ROM in their golden lists matches the reference emulator's frames and sound (MesenCE's for the NES, Stella's for the 2600) in the sim and on all three boards, and so do the commercial games they've been checked with. The site shows where every part stands, generated from the latest simulation and board runs: see [Components](https://retro-silicon.particlesector.com/components/) and [Boards](https://retro-silicon.particlesector.com/boards/), and each component's own README.

## Quick start

Needs CMake 3.28+, Ninja, a C++20 compiler, Catch2 3, and [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) on PATH (Verilator, Yosys, nextpnr-himbaechel, Apicula). FuseSoC is optional.

```sh
cmake --preset default
cmake --build --preset default    # also builds the boards' bitstreams when nextpnr is found (nextpnr-xilinx for the PYNQ-Z2)
ctest --preset default

testroms/fetch.py                 # test ROMs into ~/.cache/retro-silicon/testroms; homebrew is
                                  #   built from source (needs cc65's ca65 and Python's Pillow), and so
                                  #   are our own Atari 2600 test cartridges (testroms/a2600), and the
                                  #   Game Boy's boot ROMs, SameBoy's (needs rgbds 1.0.4 and a C compiler)
tools/mesen/check.py              # check they pass in MesenCE, the NES's reference
tools/mesen/gb_frames.py          # the Game Boy's results and golden frames from MesenCE
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
| `testroms/` | Test-ROM manifests (the NES's `manifest.toml`, the Atari 2600's `manifest-2600.toml`, the Game Boy's `manifest-gb.toml`, with its boot ROMs and the SM83's per-instruction tests: sources, SHA-256 sums, expected results), the fetch script, and the source of our own 2600 test cartridges (`a2600/`); the ROMs themselves aren't committed |
| `cmake/` | Shared CMake helpers |
| `tools/` | Host tools: the MesenCE test-ROM runner and golden-frame generator, Stella's for the Atari 2600 (`stella-frames`), and `frame.py` (frame to PNG, frame diff) |
| `docs/` | Conventions and design decisions |

See [CONTRIBUTING.md](CONTRIBUTING.md) for what each component folder holds and how to add one.

## Tested with

Verilator 5.053, Yosys 0.70, nextpnr-himbaechel 0.11.1, Apicula 0.35, openFPGALoader 1.1.1 (all OSS CAD Suite 2026-10-16), openXC7 2026-09-24 (nextpnr-xilinx, Project X-Ray) for the PYNQ-Z2, Gowin EDA Education 1.9.11.03 for the Tang Console 138K, Catch2 3.7.1, FuseSoC 2.4.7, GCC 15. References: MesenCE 2.2.1 (the NES) and Stella 7.0's libretro core (the Atari 2600).

## License

Code: [Apache-2.0](LICENSE). The website's text and images: CC BY 4.0.
