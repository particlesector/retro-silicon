# Component timing

Each component's top module, placed alone on each FPGA family the boards use, by `tools/timing/report.py`: in a wrapper that keeps every timing path between registers, with the router aiming for a speed none can reach, so each figure is what that placement achieves. LUTs count Gowin's LUT4s and ALUs, or Xilinx's LUT6s; BRAM counts 18 Kbit blocks. Updated Nov 4, 2026, with the tools pinned in the rig (OSS CAD Suite 2026-10-16, openXC7 2026-09-24), and on the Gowin parts with `synth_gowin -nowidelut`, as the boards now build.

How to read it:

- A placement is one seed of many, so a speed moves by a few percent from run to run: compare a component with itself across changes, not two components to the last MHz.
- A component alone is faster than inside a system, where it shares the chip and its paths run further. The systems' clocks: the NES at 46.4 MHz on the Tang Nano 20K, 50 MHz on the Tang Console 138K and 37.125 MHz on the PYNQ-Z2, with HDMI's pixels at 74.25 MHz.
- The figures are at each component's default parameters. `cdc_sync` on the XC7Z020 is two flip-flops and no logic, which nextpnr-xilinx won't place alone (—).

| Module | Component | Tang Nano 20K (GW2A-18C) | Tang Console 138K (GW5AST-138C) | PYNQ-Z2 (XC7Z020) |
| --- | --- | --- | --- | --- |
| `apu_2a03` | `components/audio/apu-2a03` | 107 MHz, 2995 LUTs | 120 MHz, 2854 LUTs | 89 MHz, 2183 LUTs |
| `apu_mixer` | `components/audio/apu-2a03` | 216 MHz, 143 LUTs, 1 BRAM | 230 MHz, 131 LUTs, 1 BRAM | 212 MHz, 196 LUTs |
| `axi_bridge` | `components/memory/axi-bridge` | 613 MHz, 144 LUTs | 239 MHz, 146 LUTs | 265 MHz, 111 LUTs |
| `cdc_sync` | `components/common/cdc` | 3759 MHz, 0 LUTs | 3759 MHz, 0 LUTs | — |
| `clock_enable` | `components/common/clock-enable` | 1550 MHz, 2 LUTs | 2451 MHz, 2 LUTs | 1086 MHz, 2 LUTs |
| `cpu_6502` | `components/cpu/6502` | 91 MHz, 2705 LUTs | 93 MHz, 2620 LUTs | 83 MHz, 2071 LUTs |
| `crc32` | `components/common/crc32` | 420 MHz, 116 LUTs | 447 MHz, 116 LUTs | 374 MHz, 96 LUTs |
| `fifo` | `components/common/fifo` | 374 MHz, 76 LUTs, 1 BRAM | 404 MHz, 68 LUTs, 1 BRAM | 281 MHz, 63 LUTs, 1 BRAM |
| `hdmi` | `components/video/hdmi` | 152 MHz, 1573 LUTs | 154 MHz, 1457 LUTs | 116 MHz, 1226 LUTs |
| `line_scaler` | `components/video/line-scaler` | 124 MHz, 341 LUTs, 5 BRAM | 113 MHz, 312 LUTs, 5 BRAM | 129 MHz, 244 LUTs, 5 BRAM |
| `mem_arbiter` | `components/memory/arbiter` | 402 MHz, 53 LUTs | 380 MHz, 53 LUTs | 442 MHz, 52 LUTs |
| `mem_cache` | `components/memory/cache` | 120 MHz, 1172 LUTs, 19 BRAM | 170 MHz, 1214 LUTs, 19 BRAM | 152 MHz, 961 LUTs, 19 BRAM |
| `mem_port_cdc` | `components/memory/port-cdc` | 304 MHz, 47 LUTs | 626 MHz, 46 LUTs | 257 MHz, 41 LUTs |
| `por` | `components/common/por` | 622 MHz, 15 LUTs | 616 MHz, 15 LUTs | 521 MHz, 18 LUTs |
| `ppu_2c02` | `components/video/ppu-2c02` | 85 MHz, 5966 LUTs, 2 BRAM | 73 MHz, 5851 LUTs, 2 BRAM | 54 MHz, 4495 LUTs |
| `ppu_2c02_rgb` | `components/video/ppu-2c02` | 371 MHz, 9 LUTs, 1 BRAM | 371 MHz, 9 LUTs, 1 BRAM | 552 MHz, 9 LUTs, 1 BRAM |
| `resampler` | `components/audio/resampler` | 229 MHz, 561 LUTs, 1 DSP | 150 MHz, 957 LUTs | 139 MHz, 419 LUTs, 3 DSP |
| `save_state_ctrl` | `components/common/save-state` | 392 MHz, 119 LUTs | 277 MHz, 114 LUTs | 168 MHz, 103 LUTs |
| `riot_6532` | `components/io/riot-6532` | 272 MHz, 719 LUTs | 281 MHz, 707 LUTs | 241 MHz, 416 LUTs |
| `sdram_ctrl` | `components/memory/sdram` | 332 MHz, 207 LUTs | 297 MHz, 206 LUTs | 212 MHz, 188 LUTs |
| `test_shell` | `components/debug/test-shell` | 181 MHz, 1567 LUTs, 1 BRAM | 164 MHz, 1518 LUTs, 1 BRAM | 142 MHz, 1293 LUTs, 1 BRAM |
| `tmds_encoder` | `components/video/hdmi` | 168 MHz, 140 LUTs | 172 MHz, 128 LUTs | 168 MHz, 114 LUTs |
| `trace_buffer` | `components/debug/trace` | 317 MHz, 199 LUTs, 4 BRAM | 295 MHz, 195 LUTs, 4 BRAM | 222 MHz, 150 LUTs, 4 BRAM |
| `uart_rx` | `components/common/uart` | 440 MHz, 54 LUTs | 189 MHz, 50 LUTs | 324 MHz, 42 LUTs |
| `uart_tx` | `components/common/uart` | 392 MHz, 46 LUTs | 284 MHz, 38 LUTs | 316 MHz, 42 LUTs |
| `video_probe` | `components/debug/video-probe` | 286 MHz, 406 LUTs, 2 BRAM | 196 MHz, 409 LUTs, 2 BRAM | 192 MHz, 284 LUTs, 2 BRAM |

Changes this report has led to so far:

- `audio/apu-2a03`: the pulse channels' sweep targets are registered a clock behind. They were the Tang Nano 20K's NES's longest path, and now every seed tried meets its 46.4 MHz.
- `audio/resampler`: its average and high-pass take a clock each. The multiply, three DSP blocks on the XC7Z020, ran into the high-pass in one clock, at 42 MHz, against the PYNQ-Z2's 37.125. It now reaches 139 MHz there.
- `boards/gowin/build.sh` and this report: Gowin synthesis maps no wide multiplexers (`-nowidelut`). The slices' MUX2_LUT5-8 take their inputs only from LUTs, so Yosys padded each other input with a LUT1: over 700 in the PPU alone. Without them almost every component is smaller and faster on both Gowin parts (the PPU from 65 to 85 MHz and from 6,821 to 5,966 LUTs on the GW2A-18C; `mem_cache` from 2,839 to 1,172 LUTs), and the systems with them: the Tang Nano 20K's NES from 15,915 LUT4s at 53 MHz to 14,341 at 62 MHz.
- `audio/apu-2a03`: the mixer registers its pulse index on the rising edge. Both table indices were on the falling edge, which left the pulse sum half a clock and made it the Tang Nano 20K's NES's longest path; the TND index stays on the falling edge, as its block RAM address must. The mixer alone goes from 165 to 216 MHz on the GW2A-18C, and the 20K's NES from 62 to 69 MHz.

The PPU, at 54-85 MHz, is still the slowest component, and the CPU (83-93 MHz) next.
