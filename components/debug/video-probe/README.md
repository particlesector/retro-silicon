# video-probe

Checks and captures a system's video for the test shell: a CRC-32 of each frame and of each line, and a capture of one chosen line at a time that holds the system until the host has read it. Holding a system's clock enables leaves its behaviour unchanged, so a frame dumped line by line is exactly the frame it would have shown, at the link's speed rather than the video's.

Module `video_probe`.

## Pixels and CRCs

Each pixel goes into the CRCs as 2 bytes, low byte first, in raster order; pixels must come at least 3 clocks apart. The frame CRC of the last whole frame is on `frame_crc`, with that frame's index (`frame` as it was during its pixels) on `crc_frame`. Line CRCs go into a table by line; each entry changes as the next frame passes that line, so read the table while the system is stopped.

## Capture

With `cap_en` high, line `cap_line` of frame `cap_frame` goes into the line buffer as it passes, and `cap_held` stays high from its last pixel until `cap_line`, `cap_frame` or `cap_en` change. The system stops its clock enables while `cap_held` is high. The host reads the buffer, sets `cap_line` to the next line, and so on: each step is an absolute write, safe for the test shell to repeat.

The capture must be armed before its line passes: stop the system at the end of the frame before, then arm it.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, which clears `crc_valid` and the capture |
| `pix_valid`, `pix`, `pix_x`, `pix_y` | in | 1, 16, 8, 8 | A pixel and its position |
| `frame` | in | 32 | The index of the frame these pixels belong to |
| `frame_crc`, `crc_frame` | out | 32 | The last whole frame's CRC and index |
| `crc_valid` | out | 1 | A whole frame has passed since reset |
| `line_raddr`, `line_rdata` | in, out | log2(H), 32 | Line CRC table, registered read |
| `cap_en`, `cap_frame`, `cap_line` | in | 1, 32, 8 | The line to capture |
| `cap_held` | out | 1 | The line is in the buffer: hold the system |
| `buf_raddr`, `buf_rdata` | in, out | log2(W), 16 | Line buffer, registered read |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `W` | 256 | Pixels a line |
| `H` | 240 | Lines a frame |

## Status

Sim tests (at 16 x 6): frame and line CRCs match a software CRC over three frames, with pixels 3 clocks apart; a whole frame captured line by line, holding after each line until the next is asked for, matches what was sent.

In `systems/nes` on a Tang Nano 20K: frame CRCs match MesenCE's for 42 test ROMs, and a frame dumped from the board matches MesenCE's pixel for pixel.
