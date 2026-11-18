# harness

The C++ core of the test harness. Tests talk to a design through `rig::Link`, a byte pipe, so the same test runs against a Verilator model or a real board and gives directly comparable results.

| Header | Provides |
| --- | --- |
| `rig/link.hpp` | `Link`: `write`, `read` with a timeout, `baud`; and `RigError` for failures of the rig itself rather than the design |
| `rig/sim_link.hpp` | `SimLink`: any Verilated design with a UART (`SimModel`), driven bit by bit; timeouts are simulated time. Optional seeded jitter delays each write by a few clocks, as a real host is never in step with the FPGA's clock |
| `rig/sim_systems.hpp` | `make_uart_echo_sim()`, `make_shell_ram_sim()`, `make_shell_sdram_sim()`, `make_nes_sim()`, `make_a2600_sim()`, `make_a2600_hdmi_sim()`, `make_gb_sim()`, `make_gb_hdmi_sim()` and `make_gb_axi_sim()`, among others: this repo's systems at 1.5 Mbaud, with the same build IDs as their bitstreams; the SDRAM systems run with `memory/sdram`'s chip model and with jitter on the host's timing |
| `rig/shell.hpp` | The test-shell protocol: frame encoder, a parser that survives noise, and `Client` (PING, INFO, PEEK, POKE, CRC, with retries; `write` and `read` for any length) |
| `rig/sdram_test.hpp` | `sdram_test`: seeded data written to all four quarters of the SDRAM through `systems/shell-sdram`, checked with the shell's CRC and sampled back |
| `rig/ines.hpp` | `parse_ines` and `load_ines`: iNES and NES 2.0 headers (mapper, mirroring, battery, trainer) and the PRG and CHR data |
| `rig/nes.hpp` | `nes::Console` for `systems/nes` (reset, ROM upload checked by CRC, power-up memory, reset-vector override, cycle and frame limits, status, trace and frame CRCs, line CRCs, frame capture, CPU-space peeks), `nes::nestest`, `nes::rom_test` and `nes::load_golden_roms` |
| `rig/a2600.hpp` | `a2600::Console` for `systems/atari-2600`'s `a2600_sys` (reset, cartridge upload checked by CRC, paddles and keypads, the input pins and the input player's script, frame and cycle limits, frame and sound CRCs, the frame buffer, pacing and the video CRC), `a2600::cart_test`, `a2600::hdmi_test` and the golden lists' loaders (`a2600_frames_crc32.txt`, `a2600_paddles.txt`, `a2600_keypads.txt`, `a2600_audio_crc32.txt`) |
| `rig/gb.hpp` | `gb::Console` for `systems/game-boy`'s `gb_sys` (reset, the cartridge's controller from its header (`gb::cart_config()`), its ROM, RAM, clock and the boot ROM uploaded and checked by CRC, keys, frame and T-cycle limits, the frame CRC, the serial port's bytes, cartridge RAM's first bytes, the sound's CRC, the frame buffer, pacing, the video CRC and the HDMI samples' CRC), `gb::rom_test` (which plays a ROM's input script, runs an `again` ROM twice from the cartridge RAM it left, checks `savcrc=`, and with `RS_GB_SAV_OUT=DIR` writes each ROM's RAM at the end to `DIR/<id>.sav`), `gb::hdmi_test`, and the loaders of `gb_frames_crc32.txt` (with the input scripts), `gb_audio_crc32.txt`, `gb_hdmi_crc32.txt` and the manifest's `needs` |
| `rig/shell_test.hpp` | `shell_test`: random commands against `systems/shell-ram`, checked against a model of its RAM, optionally over a `FaultyLink` |
| `rig/faulty_link.hpp` | `FaultyLink`: wraps a `Link` and drops, corrupts or adds bytes at a seeded rate, to prove a protocol recovers |
| `rig/echo_test.hpp` | `echo_test`: streams seeded random data through an echo design and checks every byte, returning a `TestResult` with the CRC32 of what came back |
| `rig/uart_model.hpp` | Bit-level 8N1 `UartEncoder` and `UartDecoder` for driving and checking RTL one clock at a time |
| `rig/crc32.hpp` | Software CRC-32, matching `components/common/crc32` |
| `rig/test_result.hpp` | `TestResult`: pass or fail, the reason, notes, bytes checked, time and CRC32 |

CMake targets: `rs_harness` (everything but this repo's Verilated systems) and `rs_sim_link` (adds them). A board backend implements `Link` over a serial port; it isn't in this repo because it depends on the machine it runs on.

`golden/echo_crc32.txt`, `golden/shell_crc32.txt` and `golden/sdram_crc32.txt` hold the tests' CRC32 for given sizes and seeds, `golden/nes_trace_crc32.txt` the CPU's bus-trace CRC for nestest, which the CPU's own bench must also give, and `golden/nes_frames_crc32.txt` MesenCE's CRC of a frame of each test ROM, from `tools/mesen/frames.py`, and `golden/gb_frames_crc32.txt` the Game Boy's: each test ROM's result and MesenCE's CRC of a frame after it, from `tools/mesen/gb_frames.py` (its pixels the shade on the Game Boy, the 15-bit colour on the Color), and `golden/gb_audio_crc32.txt` each one's sound's CRC at that frame, from the sim (`systems/game-boy`'s `gb_roms_test`). Every backend that passes must give these values; the shell test's CRC doesn't depend on injected faults.
