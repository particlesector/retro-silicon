# retro-silicon

Public library of reusable FPGA components for retro systems. Read CONTRIBUTING.md (folder layout, CMake helpers, the checklist before main) and docs/conventions.md (RTL rules) before adding or changing a component.

## Commands

- Build and test: `cmake --preset default && cmake --build --preset default && ctest --preset default`. Tools must be on PATH (OSS CAD Suite; FuseSoC for the FuseSoC lint).
- One test: `ctest --preset default -R <regex>`; ctest names are the Catch2 test-case names, plus `lint verilator <module>`, `lint yosys <module>` and `fusesoc lint <system>`.
- Test ROMs: `testroms/fetch.py [--dest DIR]` downloads and checks them; `tools/mesen/check.py --mesen <path> --roms DIR` confirms each passes in MesenCE. Add a ROM to `testroms/manifest.toml` only with its SHA-256 and a result confirmed in MesenCE.
- Tang Nano 20K bitstream: `boards/tang-nano-20k/build.sh -t <top> -c <pins.cst> -o <dir> [-g NAME=VALUE]... <sources...>`, or the `<name>_bitstream` CMake targets. A missed timing constraint fails the build; never pass `--timing-allow-fail`.

## Rules

- Every RTL change must pass Verilator `-Wall` and Yosys; the lint tests check both. Fix warnings rather than waiving them.
- Write a failing sim test before fixing an RTL bug, and test new RTL against a software model where one exists.
- Keep each component's README (ports, parameters, status) and its `.core` file list in step with the RTL and CMakeLists.txt.
- Parameters go on a `.core` file's `lint` target, never `default`: FuseSoC passes a dependency's default-target parameters to the top level that uses it.
- Never commit ROMs, bitstreams, Verilator output, machine-specific paths or rig-only code (serial ports, board backends, run results).
- Every source file starts with an `SPDX-License-Identifier: Apache-2.0` line.
- Test-shell commands must stay idempotent (absolute addresses, no "run N more"), because the host resends on any doubt. A protocol change bumps the INFO version and updates the shell's README.
- Add a line to CHANGELOG.md under Unreleased for every user-visible change.
- Work on a branch; changes reach main only by pull request.
