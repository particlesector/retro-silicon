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
| `0C` | 1 | Status (read-only): bit 0 stopped at a limit, bit 1 running, bit 2 a frame's CRC is valid, bit 3 the reset's clear is running, bit 4 the video CRC asked for has come |
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
| `34` | 1 | Video: bit 0 keep pace with the display; write bit 1 to take the video CRC (read: bit 1 still armed) |
| `36` | 1 | Bit 0: the video CRC's display frame showed its frame whole (read-only) |
| `38` | 4 | The video CRC is of the display frame showing frame `38` + 1 |
| `3C` | 4 | The video CRC (read-only); status bit 4 says it has come |
| `40`, `42`, `44` | 2 each | Display frames whose frame started on request, lines late, lines overwritten before they were shown (read-only) |
| `46` | 2 | Times the HDMI sound ran dry while playing or dropped a sample (read-only) |
| `48` | 4 | CRC-32 of every 48 kHz sample made since reset, 16 bits little-endian (read-only) |
| `4C` | 4 | How many (read-only) |
| `0x05000000` | 36,480 | The frame buffer (read-only): y x 160 + x |

LEDs (active low): `led[0]` a corrupt command frame, `led[1]` a stalled one, `led[3]` running, `led[4]` stopped at a limit, `led[5]` the heartbeat.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT`, `IDLE_CLKS`, `BUILD_ID` | 18, 270,000, 0 | The test shell's |
| `CC_NUM`, `CC_DEN` | 35, 264 | Colour clocks per `CC_DEN` clocks: at most 1 in 6 |
| `TIA_SCORE_GLITCH` | 0 | `atari2600`'s |
| `VIDEO` | 0 | 1: the picture and sound on HDMI (`a2600_video`), on `pclk` |

The Tang Nano 20K's `a2600` bitstream (`boards/tang-nano-20k`) is `a2600_sys` with `VIDEO` (`rtl/a2600_top.sv`), on the NES's clocks: 46.40625 MHz, 31 clocks a bit, colour clocks at 7/89 of it (3.64986 MHz, 2% fast of NTSC's), and 74.25 MHz pixels.

## HDMI: `a2600_video`

With `VIDEO`, `a2600_sys` shows the frames on HDMI at 720p with their sound, as `systems/nes`'s `nes_video` does the NES's:

- **The picture** is the frame as Stella cuts it, each of its 160 x 228 pixels 6 display pixels wide and 3 lines high (960 x 684, the shape a pixel has on a TV), from (160, 18), black around it. The colours are `video/tia`'s `tia_rgb`, from a model of the TIA's NTSC signal (its README).
- **The lines** come through a ring of 32 in block RAM, written as `a2600_frame` writes its frame buffer (the pixels drawn and the line's clearing), so a line is in the ring as it is in the buffer when `a2600_frame` finishes it. A frame that ends before its 228 lines shows the rest black, where the frame buffer could keep a line's old pixels (above): the golden cartridges' frames don't.
- **Pacing:** with pacing on (register `34`) the system waits at each frame's end until the display asks for the next, at the start of its line 690, so each display frame shows one frame whole. The wait is a stop between colour clocks, so it changes nothing the system does. At 2% fast, a frame of 262 lines takes 98.2% of a display frame and draws its lines a little faster than the display shows them, at most 19 ahead, which the ring holds; a frame over 266 lines misses its request, and the display shows black for one frame. The display checks each line as it starts showing it: a line that hasn't come is late, one 28 or more behind the system's is overwritten; both are drawn black and counted (registers `42` and `44`), and neither moves in a working system. A frame whose system wasn't waiting for the request is drawn black.
- **The sound:** the two channels' levels, summed, go into `audio/resampler`, 800 samples per 19,912 inputs, to 16-bit PCM, the same on both HDMI channels. HDMI plays 800 samples a display frame (48 kHz), so each frame's sound must be 800 for each display frame it takes, whatever its length. Each frame makes T = 800 x N + (2,048 - the FIFO's level) / 2 samples, N being the display frames the frame before took (1 more for each request it missed), at an even rate over the CPU cycles by the frame before's count of them (at least 16,384): frames of a steady length make exactly 800 a display frame, and the FIFO's level takes up and steers out a change. The samples go to HDMI from a 4,096-sample FIFO at exactly 48 kHz, starting once 2,048 are waiting, so the sound is 43 ms behind the picture; that's the room `tia_audio` needs, whose frames alternate between two display frames and part of one. One that runs dry repeats its last sample until 2,048 are waiting again. Register `46` counts the times it ran dry or dropped a sample while playing: none while a cartridge runs, and one as it drains after a stop.
- **The video CRC** is `nes_video`'s: the TMDS symbols of a whole display frame, the data islands' packet symbols as 0 (which line carries a sample depends on its crossing between clocks).

## Tests

`a2600_frames_test` runs each cartridge in `harness/golden/a2600_frames_crc32.txt` from power-up, cuts its frames from the TIA's picture as Stella's frame manager does (a frame ends when VSYNC goes off, or after 50 lines more than a frame's without it; the picture starts 23 lines later and runs 228 lines; a line's columns the TIA doesn't draw are black), and checks frame N's CRC against Stella's. A cartridge in `harness/golden/a2600_audio_crc32.txt` must also match Stella's sound: each sample is the two channels' levels summed over the colour clocks since the last `aud_tick`, as two little-endian 16-bit words, and the CRC-32 of the first N from power-up must match (with `RS_A2600_DUMP`, written as `<id>.aud`, with every colour clock's levels as `<id>.lvl`, a byte each, `aud0 | aud1 << 4`, and VSYNC as `<id>.vs`, to compare with a transistor-level TIA). A cartridge in `harness/golden/a2600_paddles.txt` gets the paddles Stella plugs in for it, each knob where Stella has it; the others have none, as Stella gives a joystick game. `a2600_score_glitch_test` is the same test with `TIA_SCORE_GLITCH` on, against `harness/golden/a2600_score_glitch_crc32.txt`. `RS_A2600_DUMP=DIR` writes each frame as `<id>.tia`, as `stella-frames --dump` does, to compare them; `RS_A2600_TRACE=DIR` writes every TIA write as `<colour clock> <register> <value>` in `<id>.trace`.

`a2600_frame_test` checks `a2600_frame` against the frame manager's model with random pictures, lines cut short as RSYNC does, and VSYNC on time, early, mid-line and overdue, a colour clock every 6 clocks: every frame's CRC and, at the end, the frame buffer. The harness's `a2600_sys` tests (`harness/tests/a2600_test.cpp`, on `make_a2600_sim`) run each golden cartridge through the test shell, as `rig-run --test a2600` does on a board, and check that a reset clears the frame buffer. `harness/tests/a2600_hdmi_test.cpp` runs `tia_colours`, `tia_playfield` and `tia_audio` on `make_a2600_hdmi_sim` (the 20K's build) as `rig-run --test a2600-hdmi` does, with an HDMI receiver on the symbols: every display frame has 720p's timing, the one with the reported video CRC shows the golden frame pixel for pixel through `tia_rgb`, every display frame carries 800 sound samples, the sound has every sample the system made, in order, and the video CRC is `harness/golden/a2600_hdmi_crc32.txt`'s; and with pacing off, a frame of 262 lines takes at most 98.5% of a display frame.

## Status

On the Tang Nano 20K, every cartridge matches its golden frame and sound, and on HDMI `tia_colours`, `tia_playfield` and `tia_audio` give the sim's video CRCs, with no line late, and the capture dongle sees each golden frame at 720p.

In the sim, all twelve test cartridges match their golden frames, and `tia_audio` its golden sound (Stella's, but for `tia_missiles_ball` and `tia_resmp`: see `video/tia`'s README), with `TIA_SCORE_GLITCH` off and on: `tia_colours`, `riot_ram`, `riot_timer`, `tia_playfield`, `tia_players`, `tia_missiles_ball`, `tia_hmove`, `tia_collisions`, `tia_rsync`, `tia_resmp`, `tia_audio` and `tia_paddles`.
