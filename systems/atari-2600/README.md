# Atari 2600

The Atari 2600 (NTSC), being built: the 6507 (`cpu/6502` with decimal mode on and 13 address lines), the TIA (`video/tia`) and the RIOT (`io/riot-6532`) on one bus, with the cartridge outside the core.

Module `atari2600`. **In progress** (the rig's milestone A4): the TIA has its line, sync, background and playfield so far, and the core runs only in the sim. The test shell, the boards, HDMI and sound come later.

## The bus

| Address (A12-A0) | Chip |
| --- | --- |
| A12 high | The cartridge (`cart_addr` is A11-A0) |
| A12 low, A7 low | The TIA: writes by A5-A0, reads by A3-A0, which drive bits 7-6 only; bits 5-0 keep the bus's last value |
| A12 low, A7 high, A9 low | The RIOT's RAM |
| A12 low, A7 high, A9 high | The RIOT's registers |

A CPU cycle is 3 colour clocks (`cc`), so `cc` must come at least 2 clocks apart, for the RIOT's registered read. WSYNC holds the CPU through the TIA's `rdy`. Port A's pins are wired-AND: a bit reads low if the joystick pulls it low or the RIOT drives it low as an output.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst`, `cc` | in | 1 | Clock, reset, one colour clock |
| `cart_addr`, `cart_sel`, `cart_we`, `cart_wdata` | out | 12, 1, 1, 8 | The cartridge's cycle (with `cart_sel` high) |
| `cart_data` | in | 8 | The cartridge's data, by the clock that ends the cycle |
| `joy`, `switches`, `fire_n` | in | 8, 8, 2 | SWCHA's and SWCHB's pins, the fire buttons (0 pressed) |
| `pix`, `pix_on`, `pix_x`, `line_end`, `vsync`, `vblank` | out | | The TIA's picture (its README) |
| `cpu_sync`, `cpu_pc` | out | 1, 16 | For traces |

## Tests

`a2600_frames_test` runs each cartridge in `harness/golden/a2600_frames_crc32.txt` from power-up, cuts its frames from the TIA's picture as Stella's frame manager does (a frame ends when VSYNC goes off; the picture starts 23 lines later and runs 228 lines; with no VSYNC for 50 lines it runs on), and checks frame N's CRC against Stella's. `RS_A2600_DUMP=DIR` writes each frame as `<id>.tia`, as `stella-frames --dump` does, to compare them.

## Status

In the sim, all four test cartridges match Stella's frames: `tia_colours`, `riot_ram`, `riot_timer` and `tia_playfield`.
