# hdmi

Video timing and TMDS encoding for an HDMI output in DVI mode: picture and syncs, no data islands yet (audio and InfoFrames come with the APU). Every HDMI sink accepts DVI. Each pixel clock it gives the three 10-bit symbols to send; a board's serializers send them at ten times the pixel rate, bit 0 first. The defaults are CEA-861's 1280x720 at 60 Hz, a 74.25 MHz pixel clock.

Modules `hdmi` (the timing and three encoders) and `tmds_encoder` (one channel, DVI 1.0 section 3.2.2).

## Timing

Each line is `H_ACTIVE` pixels of picture, then the front porch, the sync pulse and the back porch; each frame is `V_ACTIVE` such lines, then the vertical porches and sync. Vertical sync starts and ends with a line's horizontal sync, as CEA-861 has it for progressive modes.

The pixel source sees the position to draw (`x`, `y`, and `act` inside the picture) and returns that pixel's colour `LATENCY` clocks later; the syncs and blanking go through the same delay to meet it. The symbols come out two clocks after the colour, through the encoder's two register stages (one per step of the spec's algorithm, so 74.25 MHz has room). During blanking each encoder sends control symbols (channel 0 carries {vsync, hsync}) and its running disparity restarts from zero, so a line's symbols depend only on its pixels.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Pixel clock; synchronous reset to the frame's first pixel |
| `x`, `y` | out | 12 | Position to draw this clock |
| `act` | out | 1 | `x`, `y` is inside the picture |
| `frame`, `line` | out | 1 | High at a frame's first position, and at each line's |
| `rgb` | in | 24 | {red, green, blue} for the position `LATENCY` clocks ago |
| `tmds0`, `tmds1`, `tmds2` | out | 10 | Symbols for blue (with the syncs), green and red |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `H_ACTIVE`, `H_FRONT`, `H_SYNC`, `H_BACK` | 1280, 110, 40, 220 | Line: picture, front porch, sync, back porch, in pixels |
| `V_ACTIVE`, `V_FRONT`, `V_SYNC`, `V_BACK` | 720, 5, 5, 20 | Frame, the same in lines |
| `H_POS`, `V_POS` | 1, 1 | Sync pulses active high |
| `LATENCY` | 2 | Clocks from `x`, `y` to `rgb`, 1 or more |

## Status

Sim tests (`sim/tmds_model.hpp` holds a TMDS encoder written from the DVI spec and a receiver's decoder, which the harness uses too):
- `tmds_encoder` gives the spec encoder's symbol for 2 million random inputs, every one decodes back to its input, and the running disparity stays within ±10.
- Two whole 720p frames decode to the test pattern, with control symbols everywhere else, 750 hsync pulses of 40 pixels at pixel 1390, and vsync for 5 lines from line 725, starting with that line's hsync.
- A 16x8 mode with negative syncs and a latency of 4 does the same for 20 frames.
- A planted encoder bug (dropping the balanced-byte case of the disparity rule) fails all three.

On the board: in `systems/nes` on a Tang Nano 20K, the CRC of a whole display frame's symbols matches the sim's for `oam_read` and `full_palette`, frame after frame.

## References

- DVI 1.0, section 3.2: TMDS encoding.
- CEA-861: the 1280x720p60 timing (format 4).
