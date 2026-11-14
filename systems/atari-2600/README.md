# Atari 2600

The Atari 2600 (NTSC), being built: the 6507 (`cpu/6502` with decimal mode on and 13 address lines), the TIA (`video/tia`) and the RIOT (`io/riot-6532`) on one bus, with the paddles' inputs (`io/paddles`), and the cartridge outside the core.

Module `atari2600`, and `a2600_sys`, the system under the test shell (below). **In progress** (the rig's milestones A4 and A5): the TIA has its picture, its sound and its input ports (the fire buttons and the paddles), and `a2600_sys` runs on the Tang Nano 20K and the Tang Console 138K, its frames' and sound's CRCs checked over the link, with its picture and sound on HDMI at 720p.

## The bus

| Address (A12-A0) | Chip |
| --- | --- |
| A12 high | The cartridge (`cart_addr` is A11-A0) |
| A12 low, A7 low | The TIA: writes by A5-A0, reads by A3-A0, which drive bits 7-6 only; bits 5-0 keep the bus's last value |
| A12 low, A7 high, A9 low | The RIOT's RAM |
| A12 low, A7 high, A9 high | The RIOT's registers |

A CPU cycle is 3 colour clocks (`cc`), and `cc` must come at least 7 clocks apart: `io/paddles` steps its four capacitors in turn in the 5 clocks after a colour clock, and the CPU takes a read's data a clock before its cycle ends (the RIOT's registered read needs 2). The CPU takes its read data registered (`cpu/6502`'s `DIN_REG`), which keeps the read mux and the cartridge out of its paths into its registers: a read's data is needed a clock before the cycle ends. The TIA and the RIOT change only on colour clocks and a cycle ends on one, so theirs is there; the paddles' last step lands 2 clocks before the next colour clock. WSYNC holds the CPU through the TIA's `rdy`. Port A's pins are wired-AND: a bit reads low if the joystick pulls it low or the RIOT drives it low as an output.

Paddles plug into the joystick ports in pairs: paddles 0 and 1 into player 0's (INPT0, INPT1), 2 and 3 into player 1's (INPT2, INPT3). Their fire buttons are joystick lines, as Stella maps them: paddle 0's is P0 right (`joy` bit 7), paddle 1's P0 left (bit 6), paddle 2's P1 right (bit 3), paddle 3's P1 left (bit 2).

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst`, `cc` | in | 1 | Clock, reset, one colour clock |
| `cart_addr`, `cart_sel`, `cart_we`, `cart_wdata` | out | 12, 1, 1, 8 | The cartridge's cycle (with `cart_sel` high) |
| `cart_data` | in | 8 | The cartridge's data, a clock before the one that ends the cycle (the CPU registers it) |
| `joy`, `switches`, `fire_n` | in | 8, 8, 2 | SWCHA's and SWCHB's pins, the fire buttons (0 pressed) |
| `paddle_on`, `paddle_pos` | in | 4, 32 | Paddle i plugged in, and its knob in bits 8i+7:8i (a pot of `pos / 256` Mohm; `io/paddles`); unplugged, its input reads 0 |
| `pix`, `pix_on`, `pix_x`, `line_end`, `vsync`, `vblank` | out | | The TIA's picture (its README) |
| `aud0`, `aud1`, `aud_tick` | out | 4, 4, 1 | The TIA's sound: each channel's level, and Stella's sample points (its README) |
| `cpu_sync`, `cpu_pc` | out | 1, 16 | For traces |
| `bus_ce`, `bus_addr`, `bus_we`, `bus_data` | out | 1, 13, 1, 8 | The clock that ends a CPU cycle, and its access (a read's data is what the CPU read), for traces and a cartridge's bank switching |
| `bus_stall` | out | 1 | This cycle is a read WSYNC stalls, which the CPU makes again: not an access to a cartridge |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `TIA_SCORE_GLITCH` | 0 | `video/tia`'s `SCORE_GLITCH`: score mode's right colour from pixel 79, as on some TIA revisions |

## Under the test shell: `a2600_sys`

`a2600_sys` puts `atari2600` under `debug/test-shell` with its cartridge (`a2600_cart`, below) in block RAM (or its ROM in an SDRAM: `a2600_sdram`, below), so the host can load a cartridge, run it to a frame and check what it drew, on a board as in the sim. It takes the checks the golden lists hold itself, so nothing but CRCs crosses the link:

- **Frames:** `a2600_frame` cuts frames from the TIA's picture as Stella 7.0's frame manager does (as `a2600_frames_test` does, `sim/frame_cutter.hpp`) into a frame buffer of 160 x 228 colour values (four byte lanes of 9,120), and after each frame reads it through into a CRC-32, 4 pixels a clock. The buffer is one, as Stella's is, so a frame that ends on the line its last frame did keeps that line's old pixels, as Stella's does.
- **Sound:** the CRC-32 of the first `audio_limit` samples, each as the golden sound's (two little-endian 16-bit channel sums).

Colour clocks come at `CC_NUM`/`CC_DEN` of the clock (`common/clock-enable`), NTSC's 3.579545 MHz from 27 MHz by default, while the system runs; it stops between colour clocks, so a run stopped and restarted is the same as one that wasn't, on any board and in the sim. A reset clears the frame buffer (9,120 clocks) before the first colour clock.

| Shell address | Bytes | Meaning |
| --- | --- | --- |
| `0x00000000` | 2^`ROM_LOG2` | The cartridge's ROM: a 2 KB one written twice |
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
| `50` | 1 | The cartridge's scheme (bits 3-0) and the Superchip's RAM (bit 4): `a2600_cart` (below); power-up 0 |
| `51` | 1 | The cartridge's ROM size, log2 |
| `52` | 1 | The board's room for cartridge ROM, log2 (`ROM_LOG2`; read-only) |
| `53` | 1 | Bit 0: the ROM is in an outside memory (`ROM_EXT`; read-only) |
| `0x05000000` | 36,480 | The frame buffer (read-only): y x 160 + x |

LEDs (active low): `led[0]` a corrupt command frame, `led[1]` a stalled one, `led[3]` running, `led[4]` stopped at a limit, `led[5]` the heartbeat.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT`, `IDLE_CLKS`, `BUILD_ID` | 18, 270,000, 0 | The test shell's |
| `CC_NUM`, `CC_DEN` | 35, 264 | Colour clocks per `CC_DEN` clocks: at most 1 in 7 |
| `TIA_SCORE_GLITCH` | 0 | `atari2600`'s |
| `VIDEO` | 0 | 1: the picture and sound on HDMI (`a2600_video`), on `pclk` |
| `ROM_LOG2` | 16 | The cartridge's ROM: 2^`ROM_LOG2` bytes (of block RAM, or with `ROM_EXT` of the outside memory) |
| `ROM_BANK_LOG2` | `ROM_LOG2` | The ROM's block RAM built from memories of 2^`ROM_BANK_LOG2` bytes, if less than its size (openXC7 places none deeper than 32 KB) |
| `ROM_EXT` | 0 | 1: the ROM in an outside memory on `mem_*` (below), not block RAM |

### The ROM in an SDRAM: `a2600_sdram`

With `ROM_EXT`, `a2600_cart` keeps no ROM of its own: when an access in the cartridge's space reads ROM, it fetches that byte through `mem_*`, a byte port as `memory/sdram`'s (request held until acknowledged), from address 0, and holds it. The access's address is there from the start of its CPU cycle, so the fetch is usually done long before the cycle ends; a colour clock that falls due while it isn't waits for it (`common/clock-enable`'s `hold`), a stop between colour clocks like the others, so only a fetch not done in time costs time and nothing the system does changes. The address changes as a cycle ends, so the colour clock that waits is the cycle's first: the byte is there two colour clocks before the CPU takes it, as `DIN_REG` needs. The shell's reads and writes of the ROM take the port between fetches. Register `53` bit 0 reads `ROM_EXT`.

`a2600_sdram` is `a2600_sys` with `ROM_EXT` on `memory/sdram`'s controller, by default for the Tang Nano 20K's 2M x 32 chip, with `ROM_LOG2` 19: up to 512 KB, 3F's largest. Its parameters are `a2600_sys`'s and the controller's (`FREQ_MHZ`, `DQ_W`, `ROW_W`, `COL_W`, `RANKS`, `REFRESH_NS`).

The Tang Nano 20K's `a2600` bitstream (`boards/tang-nano-20k`) is `a2600_sdram` with `VIDEO` (`rtl/a2600_top.sv`), on the NES's clocks: 46.40625 MHz, 31 clocks a bit, colour clocks at 7/89 of it (3.64986 MHz, 2% fast of NTSC's), and 74.25 MHz pixels; the SDRAM is wired as the NES's. At 46.40625 MHz a fetch takes about 8 clocks of a CPU cycle's 38, and a refresh in its way a few more, so with pacing on a frame still takes 98.2% of a display frame. `make_a2600_hdmi_sim` runs it on the SDRAM model, and `make_a2600_ext_sim` the same without the display.

The Tang Console 138K's `console_a2600` (`boards/tang-console-138k/rtl/a2600_top.sv`) is `a2600_sys` with `VIDEO` and `ROM_LOG2` 19, its 512 KB of ROM in block RAM, on that board's NES clocks: 37.1875 MHz, 25 clocks a bit, colour clocks at 35/356 of it (3.65625 MHz) and 74.375 MHz pixels, the 20K's ratio of colour clock to pixel clock, so it keeps pace with its display as the 20K's does. `make_a2600_console_sim` runs it, with its display.

The PYNQ-Z2's `pynq_a2600` (`boards/pynq-z2/rtl/pynq_a2600_top.sv`) is `a2600_sys` with `VIDEO`, `ROM_LOG2` 18 and `ROM_BANK_LOG2` 15, its 256 KB of ROM in block RAM in 32 KB memories, on that board's NES clocks: 37.125 MHz, 25 clocks a bit, colour clocks at 35/356 and 74.25 MHz pixels, the system clock half the pixel clock as on the 138K, so it too keeps pace with its display as the 20K's does. `make_a2600_pynq_sim` runs it, with its display.

## The cartridge: `a2600_cart`

`a2600_cart` holds the cartridge's ROM (the shell writes it) and any RAM, and banks them by the scheme register `50` sets, as Stella 7.0 runs each. It watches every access on the bus (`bus_*`, but for the reads WSYNC stalls, which Stella doesn't make either), as a cartridge's hotspot logic does: a hotspot switches on a read or a write, and a read of it gets its byte from the bank it selects (FE's aside). The RAM starts as 0s, as Stella's does with its RAM randomising off: after a reset the cartridge clears it, 2,048 clocks within the frame buffer's clear.

| Scheme (register `50`) | ROM | Banking | Starts in |
| --- | --- | --- | --- |
| 0 | 2 or 4 KB | None (2 KB written twice) | |
| 1 F8 | 8 KB | 4 KB banks: `$1FF8`, `$1FF9` | Bank 1 |
| 2 F6 | 16 KB | `$1FF6`-`$1FF9` | Bank 0 |
| 3 F4 | 32 KB | `$1FF4`-`$1FFB` | Bank 0 |
| 4 FE | 8 KB | The access after one of `$01FE` (seeing only `$01C0`-`$01FF` and the cartridge) selects bank !D5 of its data: a JSR or RTS with S = `$FF` | Bank 0 |
| 5 E0 | 8 KB | 1 KB slices: `$1000`, `$1400`, `$1800` by `$1FE0`-7, `$1FE8`-F, `$1FF0`-7; `$1C00` slice 7 | Slices 4, 5, 6 |
| 6 3F | 2-512 KB | 2 KB banks: a write to `$0000`-`$003F` selects `$1000`'s by its value (modulo the banks); `$1800` the last | Bank 0 |
| 7 FA | 12 KB | `$1FF8`-`$1FFA`, and 256 bytes of RAM: written at `$1000`-`$10FF`, read at `$1100`-`$11FF` | Bank 2 |
| 8 E7 | 16 KB | 2 KB slices: `$1000` by `$1FE0`-6, or with `$1FE7` 1 KB of RAM (written at `$1000`, read at `$1400`); 256 bytes of RAM in four banks (`$1FE8`-B) written at `$1800`, read at `$1900`; `$1A00`-`$1FFF` slice 7 | Slice 0, RAM bank 0 |
| 9 F0 | 64 KB | `$1FF0` steps to the next of 16 4 KB banks | Bank 15 |

Register `50` bit 4 adds the Superchip's 128 bytes of RAM to F8, F6 and F4 (Stella's F8SC, F6SC, F4SC): written at `$1000`-`$107F`, read at `$1080`-`$10FF`. Register `51` is the ROM's size (log2; 3F's bank count comes from it), and `52` (read-only) the board's room for ROM, `ROM_LOG2`. The harness takes a cartridge's scheme from its file's extension, as Stella does (`bank_f8.F8`; `.bin` and `.a26` are unbanked), and a ROM bigger than the board's room isn't run.

One place it parts from Stella: Stella's 3F takes all of `$0000`-`$003F`, so writes there don't reach the TIA and reads there come from the cartridge. On the console the TIA still sees them, and so it does here; Tigervision's games write the TIA through its mirror at `$0040`, so none depends on it.

## HDMI: `a2600_video`

With `VIDEO`, `a2600_sys` shows the frames on HDMI at 720p with their sound, as `systems/nes`'s `nes_video` does the NES's:

- **The picture** is the frame as Stella cuts it, each of its 160 x 228 pixels 6 display pixels wide and 3 lines high (960 x 684, the shape a pixel has on a TV), from (160, 18), black around it. The colours are `video/tia`'s `tia_rgb`, from a model of the TIA's NTSC signal (its README).
- **The lines** come through a ring of 32 in block RAM, written as `a2600_frame` writes its frame buffer (the pixels drawn and the line's clearing), so a line is in the ring as it is in the buffer when `a2600_frame` finishes it. A frame that ends before its 228 lines shows the rest black, where the frame buffer could keep a line's old pixels (above): the golden cartridges' frames don't.
- **Pacing:** with pacing on (register `34`) the system waits at each frame's end until the display asks for the next, at the start of its line 690, so each display frame shows one frame whole. The wait is a stop between colour clocks, so it changes nothing the system does. At 2% fast, a frame of 262 lines takes 98.2% of a display frame and draws its lines a little faster than the display shows them, at most 19 ahead, which the ring holds; a frame over 266 lines misses its request, and the display shows black for one frame. The display checks each line as it starts showing it: a line that hasn't come is late, one 28 or more behind the system's is overwritten; both are drawn black and counted (registers `42` and `44`), and neither moves in a working system. A frame whose system wasn't waiting for the request is drawn black.
- **The sound:** the two channels' levels, summed, go into `audio/resampler`, 800 samples per 19,912 inputs, to 16-bit PCM, the same on both HDMI channels. HDMI plays 800 samples a display frame (48 kHz), so each frame's sound must be 800 for each display frame it takes, whatever its length. Each frame makes T = 800 x N + (2,048 - the FIFO's level) / 2 samples, N being the display frames the frame before took (1 more for each request it missed), at an even rate over the CPU cycles by the frame before's count of them (at least 16,384): frames of a steady length make exactly 800 a display frame, and the FIFO's level takes up and steers out a change (the level, which crosses from the pixel clock, is a few clocks old: T for each N is kept ready in registers, and the frame's end picks one). The samples go to HDMI from a 4,096-sample FIFO at exactly 48 kHz, starting once 2,048 are waiting, so the sound is 43 ms behind the picture; that's the room `tia_audio` needs, whose frames alternate between two display frames and part of one. One that runs dry repeats its last sample until 2,048 are waiting again. Register `46` counts the times it ran dry or dropped a sample while playing: none while a cartridge runs, and one as it drains after a stop.
- **The video CRC** is `nes_video`'s: the TMDS symbols of a whole display frame, the data islands' packet symbols as 0 (which line carries a sample depends on its crossing between clocks).

## Tests

`a2600_frames_test` runs each cartridge in `harness/golden/a2600_frames_crc32.txt` from power-up, cuts its frames from the TIA's picture as Stella's frame manager does (a frame ends when VSYNC goes off, or after 50 lines more than a frame's without it; the picture starts 23 lines later and runs 228 lines; a line's columns the TIA doesn't draw are black), and checks frame N's CRC against Stella's. A cartridge in `harness/golden/a2600_audio_crc32.txt` must also match Stella's sound: each sample is the two channels' levels summed over the colour clocks since the last `aud_tick`, as two little-endian 16-bit words, and the CRC-32 of the first N from power-up must match (with `RS_A2600_DUMP`, written as `<id>.aud`, with every colour clock's levels as `<id>.lvl`, a byte each, `aud0 | aud1 << 4`, and VSYNC as `<id>.vs`, to compare with a transistor-level TIA). A cartridge in `harness/golden/a2600_paddles.txt` gets the paddles Stella plugs in for it, each knob where Stella has it; the others have none, as Stella gives a joystick game. `a2600_score_glitch_test` is the same test with `TIA_SCORE_GLITCH` on, against `harness/golden/a2600_score_glitch_crc32.txt`. `RS_A2600_DUMP=DIR` writes each frame as `<id>.tia`, as `stella-frames --dump` does, to compare them; `RS_A2600_TRACE=DIR` writes every TIA write as `<colour clock> <register> <value>` in `<id>.trace`.

`a2600_frame_test` checks `a2600_frame` against the frame manager's model with random pictures, lines cut short as RSYNC does, and VSYNC on time, early, mid-line and overdue, a colour clock every 6 clocks: every frame's CRC and, at the end, the frame buffer. The harness's `a2600_sys` tests (`harness/tests/a2600_test.cpp`, on `make_a2600_sim`) run each golden cartridge through the test shell, as `rig-run --test a2600` does on a board, and check that a reset clears the frame buffer. `harness/tests/a2600_hdmi_test.cpp` runs `tia_colours`, `tia_playfield` and `tia_audio` on `make_a2600_hdmi_sim` (the 20K's build) as `rig-run --test a2600-hdmi` does, with an HDMI receiver on the symbols: every display frame has 720p's timing, the one with the reported video CRC shows the golden frame pixel for pixel through `tia_rgb`, every display frame carries 800 sound samples, the sound has every sample the system made, in order, and the video CRC is `harness/golden/a2600_hdmi_crc32.txt`'s; and with pacing off, a frame of 262 lines takes at most 98.5% of a display frame; the three cartridges and the pace again on `make_a2600_console_sim` (the Tang Console 138K's build) and `make_a2600_pynq_sim` (the PYNQ-Z2's), with the 20K's video CRCs. `a2600_test.cpp` runs every cartridge again on `make_a2600_console_sim` and `make_a2600_pynq_sim`, and the bank-switching ones on `make_a2600_ext_sim` and on `make_a2600_ext_wait_sim`, the same with a colour clock every 7 clocks, so the SDRAM's reads hold the CPU often.

## Status

On the Tang Nano 20K, with the cartridge's ROM in its SDRAM (`a2600_sdram`), every cartridge matches its golden frame and sound, all twelve bank-switching ones included, and on HDMI `tia_colours`, `tia_playfield` and `tia_audio` give the sim's video CRCs, with no line late, and the capture dongle sees each golden frame at 720p. On the Tang Console 138K, with the ROM in block RAM, every cartridge matches too, and on HDMI the three give the 20K's video and sound CRCs.

In the sim, every bank-switching cartridge matches its golden frame through `a2600_sys` (`bank_f8`, `bank_f6`, `bank_f4`, their Superchip versions, `bank_fa`, `bank_f0`, `bank_fe`, `bank_e0`, `bank_3f` and `bank_e7`), and all twelve other test cartridges match their golden frames, and `tia_audio` its golden sound (Stella's, but for `tia_missiles_ball` and `tia_resmp`: see `video/tia`'s README), with `TIA_SCORE_GLITCH` off and on: `tia_colours`, `riot_ram`, `riot_timer`, `tia_playfield`, `tia_players`, `tia_missiles_ball`, `tia_hmove`, `tia_collisions`, `tia_rsync`, `tia_resmp`, `tia_audio` and `tia_paddles`.
