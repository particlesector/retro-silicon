# hdmi

Video timing and TMDS encoding for an HDMI output: in DVI mode, picture and syncs, which every HDMI sink accepts; or with `AUDIO` set, HDMI with 48 kHz stereo audio and InfoFrames. Each pixel clock it gives the three 10-bit symbols to send; a board's serializers send them at ten times the pixel rate, bit 0 first. The defaults are CEA-861's 1280x720 at 60 Hz, a 74.25 MHz pixel clock.

Modules `hdmi` (the timing and three encoders) and `tmds_encoder` (one channel, DVI 1.0 section 3.2.2).

## Timing

Each line is `H_ACTIVE` pixels of picture, then the front porch, the sync pulse and the back porch; each frame is `V_ACTIVE` such lines, then the vertical porches and sync. Vertical sync starts and ends with a line's horizontal sync, as CEA-861 has it for progressive modes.

The pixel source sees the position to draw (`x`, `y`, and `act` inside the picture) and returns that pixel's colour `LATENCY` clocks later; the syncs and blanking go through the same delay to meet it. The symbols come out two clocks after the colour, through the encoder's two register stages (one per step of the spec's algorithm, so 74.25 MHz has room). During blanking each encoder sends control symbols (channel 0 carries {vsync, hsync}) and its running disparity restarts from zero, so a line's symbols depend only on its pixels.

## Audio (`AUDIO = 1`)

HDMI 1.4, section 5.2, with these additions to the DVI stream:

- **Video preamble:** each picture line has 8 clocks of video preamble and a 2-clock video guard band before it.
- **Data island:** every line has one right after its picture. It takes 80 clocks of the blanking: 4 control clocks, 8 of preamble, a 2-clock guard band, two 32-clock packets, and a guard band. Channel 0 carries the syncs through it in TERC4.
- **First packet:** the audio sample packet, with the samples waiting (up to 4), or a null packet.
- **Second packet:**
  - line 0: the AVI InfoFrame (version 2: RGB, 16:9, full-range RGB, video format `VIC`);
  - line 1: the audio InfoFrame (2 channels, the rest from the stream);
  - other lines: audio clock regeneration (`ACR_N`, `ACR_CTS`: 6144 and 74250 for 48 kHz at 74.25 MHz).
- **Packet coding:** each header and subpacket ends with its BCH code (G(x) = 1 + x^6 + x^7 + x^8).
- **Samples:** 16-bit L-PCM in 24-bit slots, with the IEC 60958 channel status saying 48 kHz and copying allowed, the block start flag every 192 frames, and even parity.

`aud_valid` pushes a sample pair into a 16-deep queue; a pair arriving to a full queue is dropped. Each line's island takes up to 4 pairs, at the end of its picture. At 48 kHz and 45,000 lines a second, that's 1 or 2 a line. `packet` is high while the symbols out are a packet's, for a CRC that should leave the samples out.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Pixel clock; synchronous reset to the frame's first pixel |
| `x`, `y` | out | 12 | Position to draw this clock |
| `act` | out | 1 | `x`, `y` is inside the picture |
| `frame`, `line` | out | 1 | High at a frame's first position, and at each line's |
| `rgb` | in | 24 | {red, green, blue} for the position `LATENCY` clocks ago |
| `aud_valid`, `aud_l`, `aud_r` | in | 1, 16, 16 | A sample pair, signed (with `AUDIO`) |
| `tmds0`, `tmds1`, `tmds2` | out | 10 | Symbols for blue (with the syncs), green and red |
| `packet` | out | 1 | The symbols out are a data island's packets |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `H_ACTIVE`, `H_FRONT`, `H_SYNC`, `H_BACK` | 1280, 110, 40, 220 | Line: picture, front porch, sync, back porch, in pixels |
| `V_ACTIVE`, `V_FRONT`, `V_SYNC`, `V_BACK` | 720, 5, 5, 20 | Frame, the same in lines |
| `H_POS`, `V_POS` | 1, 1 | Sync pulses active high |
| `LATENCY` | 2 | Clocks from `x`, `y` to `rgb`, 1 or more |
| `AUDIO` | 0 | HDMI with audio and InfoFrames, not DVI |
| `VIC` | 4 | The AVI InfoFrame's video format (4 is 720p60) |
| `ACR_N`, `ACR_CTS` | 6144, 74250 | Audio clock regeneration: 128 × 48 kHz / 1 kHz, and the pixel clock / 1 kHz |

## Status

Sim tests (`sim/tmds_model.hpp` holds a TMDS encoder written from the DVI spec, a receiver's decoder, and an HDMI sink's decoder that follows preambles into data islands, rebuilds packets and checks their BCH codes, checksums and sample parity; the harness uses them too):
- `tmds_encoder` gives the spec encoder's symbol for 2 million random inputs, every one decodes back to its input, and the running disparity stays within ±10.
- Two whole 720p frames decode to the test pattern, with control symbols everywhere else, 750 hsync pulses of 40 pixels at pixel 1390, and vsync for 5 lines from line 725, starting with that line's hsync.
- A 16x8 mode with negative syncs and a latency of 4 does the same for 20 frames.
- A planted encoder bug (dropping the balanced-byte case of the disparity rule) fails all three.
- With `AUDIO`: three 720p frames decode with every picture pixel and sync in place, each picture line's preamble and guard band, a data island on every line, no packet errors, clock regeneration 6144/74250, the AVI InfoFrame's format and full range, and every sample pair fed at 48 kHz back in order.

On the board: in `systems/nes` on a Tang Nano 20K, the CRC of a whole display frame's symbols matches the sim's for `oam_read` and `full_palette`, frame after frame. With `AUDIO`, the same holds on the Tang Nano 20K and the PYNQ-Z2 (the packets counted as 0), a capture dongle shows the picture, and a monitor plays the sound.

## References

- DVI 1.0, section 3.2: TMDS encoding.
- HDMI 1.4a, section 5.2 (data islands, TERC4, packets) and 8.2 (InfoFrames); CEA-861-D for the InfoFrames' fields; IEC 60958-3 for channel status.
- CEA-861: the 1280x720p60 timing (format 4).
