# Component timing

Each component's top module, placed alone on each FPGA family the boards use, by `tools/timing/report.py`: in a wrapper that keeps every timing path between registers, with the router aiming for a speed none can reach, so each figure is what that placement achieves. LUTs count Gowin's LUT4s and ALUs, or Xilinx's LUT6s; BRAM counts 18 Kbit blocks. Updated Oct 29, 2026, with the tools pinned in the rig (OSS CAD Suite 2026-10-16, openXC7 2026-09-24).

How to read it:

- A placement is one seed of many, so a speed moves by a few percent from run to run: compare a component with itself across changes, not two components to the last MHz.
- A component alone is faster than inside a system, where it shares the chip and its paths run further. The systems' clocks: the NES at 46.4 MHz on the Tang Nano 20K, 50 MHz on the Tang Console 138K and 37.125 MHz on the PYNQ-Z2, with HDMI's pixels at 74.25 MHz.
- The figures are at each component's default parameters. `bram_mem`'s default, 256 KB, needs 128 block RAMs, more than the GW2A-18C or the XC7Z020 can give it as one memory (—). `cdc_sync` on the XC7Z020 is two flip-flops and no logic, which nextpnr-xilinx won't place alone (—).

| Module | Component | Tang Nano 20K (GW2A-18C) | Tang Console 138K (GW5AST-138C) | PYNQ-Z2 (XC7Z020) |
| --- | --- | --- | --- | --- |
| `apu_2a03` | `components/audio/apu-2a03` | 87 MHz, 3344 LUTs | 87 MHz, 3244 LUTs | 93 MHz, 2134 LUTs |
| `apu_mixer` | `components/audio/apu-2a03` | 172 MHz, 130 LUTs, 1 BRAM | 184 MHz, 119 LUTs, 1 BRAM | 208 MHz, 196 LUTs |
| `bram_mem` | `components/memory/bram` | — | 69 MHz, 309 LUTs, 128 BRAM | — |
| `cdc_sync` | `components/common/cdc` | 3759 MHz, 0 LUTs | 3759 MHz, 0 LUTs | — |
| `clock_enable` | `components/common/clock-enable` | 1550 MHz, 2 LUTs | 2451 MHz, 2 LUTs | 1086 MHz, 2 LUTs |
| `cpu_6502` | `components/cpu/6502` | 114 MHz, 3063 LUTs | 94 MHz, 2910 LUTs | 82 MHz, 1924 LUTs |
| `crc32` | `components/common/crc32` | 404 MHz, 124 LUTs | 394 MHz, 124 LUTs | 374 MHz, 96 LUTs |
| `fifo` | `components/common/fifo` | 262 MHz, 164 LUTs, 1 BRAM | 280 MHz, 156 LUTs, 1 BRAM | 281 MHz, 63 LUTs, 1 BRAM |
| `hdmi` | `components/video/hdmi` | 153 MHz, 1575 LUTs | 153 MHz, 1455 LUTs | 116 MHz, 1226 LUTs |
| `line_scaler` | `components/video/line-scaler` | 122 MHz, 413 LUTs, 5 BRAM | 116 MHz, 385 LUTs, 5 BRAM | 129 MHz, 244 LUTs, 5 BRAM |
| `mem_arbiter` | `components/memory/arbiter` | 436 MHz, 55 LUTs | 394 MHz, 55 LUTs | 442 MHz, 52 LUTs |
| `por` | `components/common/por` | 474 MHz, 15 LUTs | 437 MHz, 15 LUTs | 521 MHz, 18 LUTs |
| `ppu_2c02` | `components/video/ppu-2c02` | 53 MHz, 7126 LUTs, 2 BRAM | 67 MHz, 6740 LUTs, 2 BRAM | 54 MHz, 4486 LUTs |
| `ppu_2c02_rgb` | `components/video/ppu-2c02` | 323 MHz, 38 LUTs, 1 BRAM | 304 MHz, 38 LUTs, 1 BRAM | 552 MHz, 9 LUTs, 1 BRAM |
| `resampler` | `components/audio/resampler` | 178 MHz, 546 LUTs, 1 DSP | 124 MHz, 1532 LUTs | 139 MHz, 419 LUTs, 3 DSP |
| `save_state_ctrl` | `components/common/save-state` | 198 MHz, 124 LUTs | 200 MHz, 119 LUTs | 168 MHz, 103 LUTs |
| `sdram_ctrl` | `components/memory/sdram` | 252 MHz, 248 LUTs | 258 MHz, 218 LUTs | 218 MHz, 183 LUTs |
| `test_shell` | `components/debug/test-shell` | 175 MHz, 1666 LUTs, 1 BRAM | 178 MHz, 1651 LUTs, 1 BRAM | 130 MHz, 1297 LUTs, 1 BRAM |
| `tmds_encoder` | `components/video/hdmi` | 170 MHz, 130 LUTs | 169 MHz, 118 LUTs | 168 MHz, 114 LUTs |
| `uart_rx` | `components/common/uart` | 401 MHz, 69 LUTs | 424 MHz, 65 LUTs | 324 MHz, 42 LUTs |
| `uart_tx` | `components/common/uart` | 306 MHz, 61 LUTs | 236 MHz, 53 LUTs | 316 MHz, 42 LUTs |
| `video_probe` | `components/debug/video-probe` | 206 MHz, 456 LUTs, 2 BRAM | 278 MHz, 445 LUTs, 2 BRAM | 192 MHz, 284 LUTs, 2 BRAM |

Changes this report has led to so far:

- `audio/apu-2a03`: the pulse channels' sweep targets are registered a clock behind. They were the Tang Nano 20K's NES's longest path, and now every seed tried meets its 46.4 MHz.
- `audio/resampler`: its average and high-pass take a clock each. The multiply, three DSP blocks on the XC7Z020, ran into the high-pass in one clock, at 42 MHz, against the PYNQ-Z2's 37.125. It now reaches 139 MHz there.

The PPU, at 53-67 MHz, is now the slowest component, and the CPU next.
