# line-scaler

Shows a source's frames on a display that runs on another clock, scaled up by a whole number, through a ring of `2^LINES_LOG2` source lines in block RAM instead of a frame buffer. It's how the NES (256x240) reaches 720p: three times its size, 768x720, in the middle of the 1280-pixel line, with 32 lines of block RAM (four of the GW2AR-18's) rather than a whole frame.

Module `line_scaler`.

## How it keeps the source in step

The source keeps pace with the display: after each frame it stops (`s_waiting`) until `s_req` starts the next. The display sends that request at the start of its line `REQ_Y`, early enough that the source's first picture line arrives before the display starts drawing it. A console stops at a frame boundary without changing anything it does, so it still runs at its own rate within each frame; only the pause between frames sets the frame rate to the display's.

A source that draws its lines a little faster than the display shows them, as the NES does into 720p (a line every 63.5 µs, shown over three 22.2 µs lines), runs ahead over the frame by a few lines, which the ring holds. The NES gets 14 lines ahead by its last line.

The display checks each source line as it starts drawing it:
- the line has arrived;
- it hasn't been overwritten by the line `2^LINES_LOG2` later, with 3 lines spare for the count's delay across the clocks.

The source tells the display how many lines it has finished as a Gray-coded count. At the request the display takes that count as the frame's start, along with whether the source was waiting for it. A frame whose source didn't start on request (it was stopped, or late) is drawn black. A frame that did, but has a line missing or overwritten, is drawn black for that line, and `d_late` or `d_overrun` pulses. In a working system neither ever pulses.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `s_clk`, `s_rst` | in | 1 | Source clock and reset |
| `s_valid`, `s_x`, `s_pix` | in | 1, log2 `SRC_W`, `PW` | A pixel; lines come in order, each from x = 0 |
| `s_y` | in | `LINES_LOG2` | Its line number, mod the ring |
| `s_waiting` | in | 1 | The source is stopped, waiting for `s_req` |
| `s_req` | out | 1 | One-clock pulse: start the next frame |
| `d_clk`, `d_rst` | in | 1 | Display clock and reset |
| `d_x`, `d_y` | in | 12 | Position to draw this clock; it advances by one a clock along a line |
| `d_pix` | out | `PW` | The pixel for the position of the clock before |
| `d_on` | out | 1 | ...which is in the picture, from a line that's there |
| `d_late`, `d_overrun` | out | 1 | Pulse: a line hadn't arrived when due; a line was overwritten before it was shown |
| `d_frame_ok` | out | 1 | This frame's source started on request |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `SRC_W`, `SRC_H` | 256, 240 | Source frame, in pixels; `SRC_W` a power of 2 |
| `PW` | 9 | Pixel bits |
| `SCALE` | 3 | Display pixels per source pixel, each way |
| `X0`, `Y0` | 256, 0 | The picture's top-left on the display; `X0` at least 1 |
| `REQ_Y` | 680 | The display line whose start asks for the next frame |
| `LINES_LOG2` | 5 | Source lines in the ring, log 2 |

`REQ_Y` suits a source like the NES. The NES stops at line 240, so its first picture line arrives 22 lines and 259 dots after the request (1.45 ms, 65 display lines). With the NES into 720p, the sim finds that requests up to line 684 work, so 680 leaves four display lines (90 µs) of margin.

## Status

Sim tests, with both clocks at the Tang Nano 20K's rates (46.40625 and 74.25 MHz, from one PLL) and a source with the 2C02's exact timing (341 dots by 262 lines, pixels two dots after they're drawn, the odd-frame dot skip):
- From the third display frame on, every frame shows the source's frame whole, each pixel from the right frame, line and column, with no late or overwritten lines.
- A source stopped for over half a frame gives black lines and `d_late`, never wrong pixels, and is whole again within three frames.
- A request sent at line 700 is flagged late; a ring of 8 lines is flagged overrun.

On the board: in `systems/nes` on a Tang Nano 20K, every display frame shows its NES frame whole, with no late or overwritten lines, and the video CRCs match the sim's.
