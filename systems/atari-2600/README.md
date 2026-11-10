# Atari 2600

The Atari 2600 (NTSC), being built: the 6507 (`cpu/6502` with decimal mode on and 13 address lines), the TIA (`video/tia`) and the RIOT (`io/riot-6532`) on one bus, with the cartridge outside the core.

Module `atari2600`. **In progress** (the rig's milestone A4): the TIA has its line, sync, background, playfield, players, missiles, ball, HMOVE, collisions, the fire buttons and RSYNC so far, and the core runs only in the sim. The test shell, the boards, HDMI and sound come later.

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
| `aud0`, `aud1`, `aud_tick` | out | 4, 4, 1 | The TIA's sound: each channel's level, and Stella's sample points (its README) |
| `cpu_sync`, `cpu_pc` | out | 1, 16 | For traces |
| `bus_ce`, `bus_addr`, `bus_we`, `bus_data` | out | 1, 13, 1, 8 | For traces: the clock that ends a CPU cycle, and its access |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `TIA_SCORE_GLITCH` | 0 | `video/tia`'s `SCORE_GLITCH`: score mode's right colour from pixel 79, as on some TIA revisions |

## Tests

`a2600_frames_test` runs each cartridge in `harness/golden/a2600_frames_crc32.txt` from power-up, cuts its frames from the TIA's picture as Stella's frame manager does (a frame ends when VSYNC goes off, or after 50 lines more than a frame's without it; the picture starts 23 lines later and runs 228 lines; a line's columns the TIA doesn't draw are black), and checks frame N's CRC against Stella's. A cartridge in `harness/golden/a2600_audio_crc32.txt` must also match Stella's sound: each sample is the two channels' levels summed over the colour clocks since the last `aud_tick`, as two little-endian 16-bit words, and the CRC-32 of the first N from power-up must match (with `RS_A2600_DUMP`, written as `<id>.aud`, with every colour clock's levels as `<id>.lvl`, a byte each, `aud0 | aud1 << 4`, and VSYNC as `<id>.vs`, to compare with a transistor-level TIA). `a2600_score_glitch_test` is the same test with `TIA_SCORE_GLITCH` on, against `harness/golden/a2600_score_glitch_crc32.txt`. `RS_A2600_DUMP=DIR` writes each frame as `<id>.tia`, as `stella-frames --dump` does, to compare them; `RS_A2600_TRACE=DIR` writes every TIA write as `<colour clock> <register> <value>` in `<id>.trace`.

## Status

In the sim, all eleven test cartridges match their golden frames, and `tia_audio` its golden sound (Stella's, but for `tia_missiles_ball` and `tia_resmp`: see `video/tia`'s README), with `TIA_SCORE_GLITCH` off and on: `tia_colours`, `riot_ram`, `riot_timer`, `tia_playfield`, `tia_players`, `tia_missiles_ball`, `tia_hmove`, `tia_collisions`, `tia_rsync`, `tia_resmp` and `tia_audio`.
