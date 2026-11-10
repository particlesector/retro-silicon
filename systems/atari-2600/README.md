# Atari 2600

The Atari 2600 (NTSC), being built: the 6507 (`cpu/6502` with decimal mode on and 13 address lines), the TIA (`video/tia`) and the RIOT (`io/riot-6532`) on one bus, with the paddles' inputs (`io/paddles`), and the cartridge outside the core.

Module `atari2600`, and `a2600_sys`, the system under the test shell (below). **In progress** (the rig's milestones A4 and A5): the TIA has its picture, its sound and its input ports (the fire buttons and the paddles), and `a2600_sys` runs on the Tang Nano 20K, its frames' and sound's CRCs checked over the link. HDMI (with the sound) comes next.

## The bus

| Address (A12-A0) | Chip |
| --- | --- |
| A12 high | The cartridge (`cart_addr` is A11-A0) |
| A12 low, A7 low | The TIA: writes by A5-A0, reads by A3-A0, which drive bits 7-6 only; bits 5-0 keep the bus's last value |
| A12 low, A7 high, A9 low | The RIOT's RAM |
| A12 low, A7 high, A9 high | The RIOT's registers |

A CPU cycle is 3 colour clocks (`cc`), and `cc` must come at least 6 clocks apart: `io/paddles` steps its four capacitors in turn between colour clocks (the RIOT's registered read needs 2). WSYNC holds the CPU through the TIA's `rdy`. Port A's pins are wired-AND: a bit reads low if the joystick pulls it low or the RIOT drives it low as an output.

Paddles plug into the joystick ports in pairs: paddles 0 and 1 into player 0's (INPT0, INPT1), 2 and 3 into player 1's (INPT2, INPT3). Their fire buttons are joystick lines, as Stella maps them: paddle 0's is P0 right (`joy` bit 7), paddle 1's P0 left (bit 6), paddle 2's P1 right (bit 3), paddle 3's P1 left (bit 2).

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst`, `cc` | in | 1 | Clock, reset, one colour clock |
| `cart_addr`, `cart_sel`, `cart_we`, `cart_wdata` | out | 12, 1, 1, 8 | The cartridge's cycle (with `cart_sel` high) |
| `cart_data` | in | 8 | The cartridge's data, by the clock that ends the cycle |
| `joy`, `switches`, `fire_n` | in | 8, 8, 2 | SWCHA's and SWCHB's pins, the fire buttons (0 pressed) |
| `paddle_on`, `paddle_pos` | in | 4, 32 | Paddle i plugged in, and its knob in bits 8i+7:8i (a pot of `pos / 256` Mohm; `io/paddles`); unplugged, its input reads 0 |
| `pix`, `pix_on`, `pix_x`, `line_end`, `vsync`, `vblank` | out | | The TIA's picture (its README) |
| `aud0`, `aud1`, `aud_tick` | out | 4, 4, 1 | The TIA's sound: each channel's level, and Stella's sample points (its README) |
| `cpu_sync`, `cpu_pc` | out | 1, 16 | For traces |
| `bus_ce`, `bus_addr`, `bus_we`, `bus_data` | out | 1, 13, 1, 8 | For traces: the clock that ends a CPU cycle, and its access |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `TIA_SCORE_GLITCH` | 0 | `video/tia`'s `SCORE_GLITCH`: score mode's right colour from pixel 79, as on some TIA revisions |

## Under the test shell: `a2600_sys`

`a2600_sys` puts `atari2600` under `debug/test-shell` with its cartridge in 4 KB of block RAM, so the host can load a cartridge, run it to a frame and check what it drew, on a board as in the sim. It takes the checks the golden lists hold itself, so nothing but CRCs crosses the link:

- **Frames:** `a2600_frame` cuts frames from the TIA's picture as Stella 7.0's frame manager does (as `a2600_frames_test` does, `sim/frame_cutter.hpp`) into a frame buffer of 160 x 228 colour values (four byte lanes of 9,120), and after each frame reads it through into a CRC-32, 4 pixels a clock. The buffer is one, as Stella's is, so a frame that ends on the line its last frame did keeps that line's old pixels, as Stella's does.
- **Sound:** the CRC-32 of the first `audio_limit` samples, each as the golden sound's (two little-endian 16-bit channel sums).

Colour clocks come at `CC_NUM`/`CC_DEN` of the clock (`common/clock-enable`), NTSC's 3.579545 MHz from 27 MHz by default, while the system runs; it stops between colour clocks, so a run stopped and restarted is the same as one that wasn't, on any board and in the sim. A reset clears the frame buffer (9,120 clocks) before the first colour clock.

| Shell address | Bytes | Meaning |
| --- | --- | --- |
| `0x00000000` | 4,096 | The cartridge: a 2 KB one written twice |
| `0x01000000` + `00` | 1 | Control: bit 0 run, bit 1 hold the system in reset (power-up: reset held) |
| `04` | 4 | Stop once this many CPU cycles have run since reset; 0 never |
| `08` | 4 | CPU cycles since reset (read-only) |
| `0C` | 1 | Status (read-only): bit 0 stopped at a limit, bit 1 running, bit 2 a frame's CRC is valid, bit 3 the reset's clear is running |
| `10` | 4 | Stop once this many frames have ended since reset; 0 never |
| `14` | 4 | Frames ended since reset (read-only) |
| `18` | 4 | CRC-32 of frame `1C` (read-only): its 160 x 228 colour values, line by line |
| `1C` | 4 | Which frame that is, counting from 1 (read-only); 0 none yet. It comes about 9,000 clocks after the frame ends |
| `20` | 4 | The sound's CRC-32 (read-only) |
| `24` | 4 | Samples since reset (read-only) |
| `28` | 4 | Samples the sound's CRC takes; 0 all |
| `2C`, `2D` | 1 each | SWCHA's and SWCHB's pins (0 pressed; power-up `FF`) |
| `2E` | 1 | Bits 1-0: the fire buttons, INPT5 and INPT4 (0 pressed; power-up `3`) |
| `2F` | 1 | Bits 3-0: a paddle in INPT3-0 |
| `30` | 4 | Paddle i's knob in bits 8i+7:8i |
| `0x05000000` | 36,480 | The frame buffer (read-only): y x 160 + x |

LEDs (active low): `led[0]` a corrupt command frame, `led[1]` a stalled one, `led[3]` running, `led[4]` stopped at a limit, `led[5]` the heartbeat.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT`, `IDLE_CLKS`, `BUILD_ID` | 18, 270,000, 0 | The test shell's |
| `CC_NUM`, `CC_DEN` | 35, 264 | Colour clocks per `CC_DEN` clocks: at most 1 in 6 |
| `TIA_SCORE_GLITCH` | 0 | `atari2600`'s |

The Tang Nano 20K's `a2600` bitstream (`boards/tang-nano-20k`) is `a2600_sys` on its 27 MHz oscillator and the UART pins of `uart_echo.cst`.

## Tests

`a2600_frames_test` runs each cartridge in `harness/golden/a2600_frames_crc32.txt` from power-up, cuts its frames from the TIA's picture as Stella's frame manager does (a frame ends when VSYNC goes off, or after 50 lines more than a frame's without it; the picture starts 23 lines later and runs 228 lines; a line's columns the TIA doesn't draw are black), and checks frame N's CRC against Stella's. A cartridge in `harness/golden/a2600_audio_crc32.txt` must also match Stella's sound: each sample is the two channels' levels summed over the colour clocks since the last `aud_tick`, as two little-endian 16-bit words, and the CRC-32 of the first N from power-up must match (with `RS_A2600_DUMP`, written as `<id>.aud`, with every colour clock's levels as `<id>.lvl`, a byte each, `aud0 | aud1 << 4`, and VSYNC as `<id>.vs`, to compare with a transistor-level TIA). A cartridge in `harness/golden/a2600_paddles.txt` gets the paddles Stella plugs in for it, each knob where Stella has it; the others have none, as Stella gives a joystick game. `a2600_score_glitch_test` is the same test with `TIA_SCORE_GLITCH` on, against `harness/golden/a2600_score_glitch_crc32.txt`. `RS_A2600_DUMP=DIR` writes each frame as `<id>.tia`, as `stella-frames --dump` does, to compare them; `RS_A2600_TRACE=DIR` writes every TIA write as `<colour clock> <register> <value>` in `<id>.trace`.

`a2600_frame_test` checks `a2600_frame` against the frame manager's model with random pictures, lines cut short as RSYNC does, and VSYNC on time, early, mid-line and overdue, a colour clock every 6 clocks: every frame's CRC and, at the end, the frame buffer. The harness's `a2600_sys` tests (`harness/tests/a2600_test.cpp`, on `make_a2600_sim`) run each golden cartridge through the test shell, as `rig-run --test a2600` does on a board, and check that a reset clears the frame buffer.

## Status

In the sim, all twelve test cartridges match their golden frames, and `tia_audio` its golden sound (Stella's, but for `tia_missiles_ball` and `tia_resmp`: see `video/tia`'s README), with `TIA_SCORE_GLITCH` off and on: `tia_colours`, `riot_ram`, `riot_timer`, `tia_playfield`, `tia_players`, `tia_missiles_ball`, `tia_hmove`, `tia_collisions`, `tia_rsync`, `tia_resmp`, `tia_audio` and `tia_paddles`.
