# Contributing

## Running the tests

```sh
cmake --preset default && cmake --build --preset default && ctest --preset default
```

`ctest` runs every component's Catch2 tests, plus lint checks: Verilator `-Wall` and Yosys synthesis on each top module, and a FuseSoC lint of each system when FuseSoC is on PATH. A change is ready when all of them pass with no compiler or Verilator warnings.

## Component folders

Each component lives in `components/<group>/<name>/` and carries the same files:

| Path | Holds |
| --- | --- |
| `README.md` | What it models, its ports and parameters (with defaults), accuracy status, test results, references |
| `CMakeLists.txt` | `rs_component(...)`: registers the RTL and its dependencies, and adds the lint tests |
| `rtl/` | SystemVerilog sources; the top module is named after the folder; no pins, PLLs or vendor primitives |
| `sim/` | Catch2 tests driving the Verilated RTL, with their `CMakeLists.txt` |
| `golden/` | Golden CRCs and short traces the tests compare against, as small text files (when there are any) |
| `docs/` | Timing notes and diagrams (when there are any) |
| `<name>.core` | FuseSoC CAPI2 manifest: name `retro-silicon:<group>:<name>:<version>`, file sets, top module, dependencies |

Folder and core names use hyphens (`ppu-2c02`); module names use underscores (`ppu_2c02`). A folder named for a chip number gets its group as a prefix, since a module name can't start with a digit (`cpu/6502` holds `cpu_6502`). A folder holding more than one top module (like `uart`) lists them in `rs_component(... TOPS ...)`.

`systems/` folders follow the same layout. Board files (pins, timing, build script) and wrappers for vendor primitives go in `boards/<board>/`.

## CMake helpers

From `cmake/RetroSilicon.cmake`:

- `rs_component(<name> RTL <files> [DEPENDS <components>] [TOPS <modules>])`: register RTL; dependencies must be added first in the top-level `CMakeLists.txt`.
- `rs_sim_test(<target> SOURCES <files>)`: a Catch2 test executable; ctest runs each test case separately.
- `rs_verilate(<target> COMPONENT <name> [TOP <module>] [PREFIX <class>] [PARAMS <NAME=VALUE>...])`: Verilate a component into a test with `-Wall`. Use one `PREFIX` per parameter set to test several in one executable.

## Before a component reaches main

- Its RTL follows [docs/conventions.md](docs/conventions.md): the SystemVerilog both Yosys and Verilator accept, clock enables rather than extra clocks, synchronous resets.
- Every quirk is a parameter whose default matches the original chip, listed in the README.
- Its sim tests pass, and any golden data is committed.
- The README's status line records a board run, if there has been one.
- No ROMs, generated files (bitstreams, Verilator output), machine-specific paths or rig-only code.
- Every source file starts with `SPDX-License-Identifier: Apache-2.0` in its comment syntax (after the `CAPI=2:` line in `.core` files).

## Commits and pull requests

One logical change per commit, with a message that says what changed and why. Pull requests target `main` and need the tests passing; add a line to `CHANGELOG.md` under Unreleased.
