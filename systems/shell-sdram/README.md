# shell-sdram

The test shell with the 8 MB SDRAM on its bus, mirrored through the whole 32-bit address space. It tests the SDRAM controller on real hardware and the upload path that systems use for ROMs: the harness's SDRAM test writes seeded random data, checks it with the shell's CRC command and reads samples back.

Built from `common/por`, `debug/test-shell` and `memory/sdram`. On the Tang Nano 20K, `boards/tang-nano-20k/rtl/shell_sdram_top.sv` connects the SDRAM pins.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `uart_rx` | in | 1 | Serial input |
| `uart_tx` | out | 1 | Serial output |
| `led` | out | 6 | Active low: `led[0]` a corrupt command frame was seen, `led[1]` a stalled one (both sticky until reload), `led[2]` the SDRAM is ready, `led[5]` heartbeat |
| `sd_*` | | | The SDRAM pins, as on `memory/sdram`'s `sdram_ctrl` |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT` | 18 | Clocks per bit; 1.5 Mbaud at 27 MHz |
| `IDLE_CLKS` | 270,000 | The shell's stall timeout; 10 ms at 27 MHz |
| `FREQ_MHZ` | 27 | Clock frequency, for the SDRAM timings |
| `BUILD_ID` | 0 | Reported by INFO; the CMake build sets it from the RTL's SHA-256 |

## Status

The harness's SDRAM test (`rig::sdram_test`) passes in the simulation, with the chip model, and on a Tang Nano 20K, with the same CRC32: 64 KB (`harness/golden/sdram_crc32.txt`), 1 MB and the whole 8 MB.
