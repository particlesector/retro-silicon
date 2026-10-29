# nes

The NES as far as it's built:
- the 2A03's CPU (`cpu/6502` with `DECIMAL = 0`), its APU (`audio/apu-2a03`), and its DMC and OAM DMA;
- the 2C02 PPU (`video/ppu-2c02`);
- 2 KB of RAM mirrored to `$1FFF`, and 8 KB of PRG RAM at `$6000`;
- an NROM cartridge (mapper 0): PRG ROM in the board's memory, 8 KB of CHR ROM or CHR RAM in block RAM, and horizontal or vertical nametable mirroring.

The test shell loads ROMs, runs the system and reads results, frame CRCs and whole frames. A save-state controller saves and loads the whole system. The picture goes out as HDMI at 720p. The controllers and other mappers come in later milestones; until then, reads of `$4000`-`$5FFF` other than `$4015` give open bus (the last value on the data bus), and writes there other than the APU's and `$4014` do nothing.

**Sound.** The APU's channel levels go into the audio CRC each CPU cycle, and through `apu_mixer` and `audio/resampler` to 48 kHz PCM. That's 800 samples per 29,780.5 cycles, the average NES frame with rendering on, so 48 kHz against the 60 Hz display the NES keeps pace with. The samples come out on `a_valid` and `a_pcm`, and `nes_video` sends them as HDMI audio, the same on both channels.

Built from `common/por`, `common/clock-enable`, `common/crc32`, `common/save-state`, `common/cdc`, `debug/test-shell`, `debug/video-probe`, `memory/arbiter`, `cpu/6502`, `audio/apu-2a03`, `audio/resampler`, `video/ppu-2c02`, `video/line-scaler` and `video/hdmi`. The host side is `rig::nes` in [harness](../../harness).

## Memory

`nes` takes the board's memory as a byte port, `memory/sdram`'s user port, which `memory/arbiter` shares between the CPU's PRG reads, first, and the shell. Two wrappers put memory behind it:

| Module | Memory | Used by |
| --- | --- | --- |
| `nes_sdram` | `memory/sdram`, 8 MB | The Tang Nano 20K (`boards/tang-nano-20k/rtl/nes_top.sv`), and the sim |
| `nes_bram` | `memory/bram`, 256 KB (`MEM_AW`) mirrored through the 8 MB window | The Tang Console 138K (`boards/tang-console-138k/rtl/nes_top.sv`), and its sim |

Both also hold `nes_video`, the HDMI output (below), with a pixel-clock input and the TMDS symbols out for the board's serializers.

The system's behaviour doesn't depend on which, or on the clock: a PRG read only has to be back by the end of its CPU cycle.

## Timing

- **The PPU** runs one dot per pulse of `common/clock-enable` at `DOT_NUM`/`DOT_DEN` of the clock: 35/176 of 27 MHz is the NTSC dot rate exactly, on average. The pulses are 5 or 6 clocks apart.
- **A CPU cycle** is three dots. The CPU's PPU register access falls after the second dot, and its NMI sample after the third, as MesenCE runs them. After reset the PPU runs `LEAD_DOTS` dots before the CPU's first cycle, which lines its first opcode fetch up with MesenCE's.
- **Each CPU cycle** starts the clock after the last one ended, with its address valid:
  - **PRG reads** go to the memory on that first clock and must be back by the cycle's end, at least 14 clocks later at 27 MHz. SDRAM's worst case is 10 clocks and the arbiter's grant 1 more, so this can't miss; the sticky `late` status bit would record it if it did.
  - **RAM and PRG RAM** are block RAMs shared with the shell. The CPU reads on its cycle's first clock and writes on its last; the shell uses the clocks in between.
  - **CHR and the nametables** are block RAMs shared the same way: the PPU has them for the two clocks before each dot (it reads on both, so the byte holds for its next-dot logic, and writes on the first), and the shell uses the others.
- **The shell** reaches the memory at any time, after any CPU read that is waiting.
- **The APU** takes each CPU cycle's access at the cycle's end, then runs the next cycle's tick, with the cycle's parity (`cycles` bit 0) for its odd/even delays. Its IRQ is the CPU's `irq_n`, as it stands after the cycle's access. A `$4015` read doesn't change open bus, which gives its bit 5, as on the 2A03.
- **DMA**, as MesenCE runs it. A `$4014` write or a DMC request halts the CPU on its next read cycle. Then each cycle is one of these, until both DMAs are done:
  - on an even CPU cycle (counted from reset), the DMC's read, once it has had a halt cycle and a dummy cycle;
  - otherwise on an even cycle, OAM DMA's read;
  - on an odd cycle, OAM DMA's write to `$2004` if it has a byte;
  - otherwise a dummy cycle that repeats the CPU's read.

  OAM DMA's cycles count as the DMC's halt and dummy cycles, and OAM DMA alone takes 513 or 514 cycles. A DMC request cancelled before its halt cycle never starts; one cancelled during its halt cycle stops after it. Not modelled: MesenCE's DMA reads of `$4000`-`$401F` while the CPU's address is there, and the restart of OAM DMA's count when a DMC request comes during a DMC read.

The system stops and starts only between CPU cycles, so stopping it changes nothing it does. That holds whether the shell, a cycle or frame limit, the frame capture or a save state stops it. The CPU's bus, the trace CRC and every frame are the same on any board, at any clock, and in the sim.

## Save states

`common/save-state` walks 21,016 bytes: the CPU's 4 state words, the PPU's 101, the system's own 12 (below), the APU's 17, RAM, PRG RAM, CHR and the nametable RAM, in that order, between the bus and its buffer at `0x06000000`. PRG ROM and the cartridge registers aren't part of it: load the ROM, then the state.

- **Save:** write register `38` with op 1 and a new sequence number; once `39` reads the same, the buffer holds the state. If the system is running, it stops at its next frame boundary for the walk, then runs on.
- **Load:** write the buffer, release reset, and write `38` with op 2. The system is left stopped where the state was saved; set the limits and run.

Display pacing isn't part of a state: after a load, the system falls back in step with the display at its next frame boundary.

## Video

`nes_video` turns the PPU's pixels into HDMI at 1280x720, 60 Hz, on a 74.25 MHz pixel clock from the board:
- `video/line-scaler` takes them from the system's clock to the pixel clock through a ring of 32 lines in block RAM, three times their size, 768x720 in the middle of the line;
- `ppu_2c02_rgb` gives the 2C02's colours, generated from a simulation of its composite signal (`video/ppu-2c02/tools/gen_rgb.py`);
- `video/hdmi` times and encodes them, as HDMI with the NES's sound and the AVI and audio InfoFrames.

**Pacing.** A 720p frame (16.667 ms) is a little longer than an NES frame (16.639 ms), so with pacing on (register `3C` bit 0; the default where `PACE` is set, as on the Tang Nano 20K) the system stops at each frame's end, line 240, until the display asks for the next frame, at the start of its line 680. The NES's first picture line then arrives four display lines before it's due, and over the frame it gets up to 14 lines ahead, which the ring holds. It waits about 28 µs a frame. It waits on the display only while nothing else holds it (run off, reset, a stop at a limit, a capture or a save state): a request that comes then is left for the next, so a system stopped at its frame's end isn't taken for one that's late. The stop falls between CPU cycles, like every other, so it changes nothing the system does. With pacing off, the system runs at its own rate and the display shows black. The sim's `make_nes_sim()` runs unpaced, with no pixel clock.

**Video CRC.** For the test shell, `nes_video` takes the CRC of one display frame's TMDS symbols: all 1650 x 750 pixel clocks, 30 bits each, bit 0 first (blue's symbol in bits 9-0, green's 19-10, red's 29-20), so it covers the timing and encoding as well as the picture. The data islands' packet symbols count as 0. Which line's island carries a sample depends on when it crosses from the NES's clock to the pixel clock, which differs by a clock or two from board to board. The sim checks the packets instead: every sample against the system's PCM count and CRC. Write the frame's index to `40`, then `3C` with bit 1 set; the CRC is of the display frame that shows that frame. The status's bit 7 says it has come, and `3D` whether that display frame showed the frame whole. `48`-`4D` count display frames whose frame started on request, and lines that came late or were overwritten before they were shown: those two stay 0 in a working system.

The system's own state words, at `0x04002000`:

| Word | Holds |
| --- | --- |
| 0 | CPU cycles since reset |
| 1 | Frames ended |
| 2 | The trace CRC |
| 3 | OAM DMA's page, its count's bits 7-0, its byte, open bus (bits 31-24, 23-16, 15-8, 7-0) |
| 4 | OAM DMA's count bit 8 (14); the APU's DMC cancel (13) and request (12) waiting for the cycle's end; in DMA (11); the DMC's dummy cycle needed (10) and abort (9); lead dots (8-6); the cycle state (5-4); late (3); DMC DMA on (2); OAM DMA on (1); halt needed (0) |
| 5 | The audio CRC |
| 6-9 | The resampler's 4 words |
| 10 | The PCM CRC |
| 11 | The PCM sample count |

The clock-enable's phase isn't state: it only sets how many clocks pass before the next dot.

## Shell address map

| Address | What |
| --- | --- |
| `0x00000000`–`0x007FFFFF` | The board's memory, 8 MB (a smaller memory mirrors). PRG ROM starts at 0 |
| `0x01000000`–`0x010000FF` | Registers, below |
| `0x02000000`–`0x0200FFFF` | The CPU's address space: RAM (`$0000`–`$1FFF`) and PRG RAM (`$6000`–`$7FFF`); the rest reads 0 and ignores writes |
| `0x03000000`–`0x03003FFF` | The PPU's: CHR (`$0000`–`$1FFF`, writable from here even when it's ROM) and the nametables (`$2000`–`$3FFF`, mirrored as the cartridge says) |
| `0x03004000`–`0x030047FF` | The nametable RAM as it is, unmirrored |
| `0x04000000`–`0x0400000F` | CPU save state, 4 words, little-endian |
| `0x04001000`–`0x04001193` | PPU save state, 101 words (OAM is words 0-63) |
| `0x04002000`–`0x0400202F` | The system's own state, 12 words (above) |
| `0x04003000`–`0x04003043` | APU save state, 17 words |
| `0x05000000`–`0x050003BF` | CRC of each line of the last frame, 4 bytes a line; read while stopped |
| `0x05001000`–`0x050011FF` | The captured line, 2 bytes a pixel |
| `0x06000000`–`0x06007FFF` | The save-state buffer; while no command runs |

Anything else reads 0 and ignores writes. Multi-byte registers are little-endian. A save-state word is written when its byte 3 is written, using bytes 0-2 written before it. State writes count only while the system is held in reset or stopped between cycles, and the system's own words only out of reset.

| Offset | Bytes | Register |
| --- | --- | --- |
| `00` | 1 | Control: bit 0 run, bit 1 hold the system in reset. Reset clears the cycle and frame counts, the CRCs and the status. Starts as reset held |
| `04` | 3 | PRG mask: CPU address bits 0–14 ANDed with this give the SDRAM address. `0x3FFF` mirrors 16 KB into both halves; `0x7FFF` (the default) maps 32 KB |
| `08` | 2 | Reset vector override: CPU reads of `$FFFC` and `$FFFD` give this |
| `0A` | 1 | Bit 0: use the override |
| `0C` | 4 | Stop once this many CPU cycles have run since reset; 0 never |
| `10` | 4 | CPU cycles since reset (read-only) |
| `14` | 4 | CRC-32 of the CPU's bus since reset (read-only): 4 bytes a cycle, address low, address high, data read or written, flags (bit 0 write, bit 1 opcode fetch). DMA cycles count, with the DMA's address |
| `18` | 1 | Status (read-only): bit 0 the CPU halted (a JAM opcode), bit 1 stopped at a limit, bit 2 a PRG read was late, bit 3 running, bit 4 the capture is holding the system, bit 5 a frame CRC is valid, bit 6 waiting for the display, bit 7 the video CRC asked for has come |
| `1C` | 4 | Stop once this many frames have ended since reset; 0 never |
| `20` | 4 | Frames ended since reset (read-only): a frame ends at line 240 |
| `24` | 4 | CRC-32 of the last whole frame (read-only): 2 bytes a pixel, low first, the PPU's {emphasis, colour} |
| `28` | 4 | Which frame that is (read-only), counting from 0 |
| `2C` | 1 | Cartridge: bit 0 vertical mirroring, bit 1 CHR is RAM |
| `30` | 4 | The frame to capture |
| `34` | 1 | The line to capture |
| `35` | 1 | Bit 0: capture |
| `38` | 1 | Save-state command: op in bits 7-6 (1 save, 2 load), a sequence number in 5-0; runs when it changes |
| `39` | 1 | The last save-state command finished (read-only) |
| `3C` | 1 | Video: bit 0 keep pace with the display (from `PACE` at power-up); write bit 1 to take the video CRC of frame `40`'s display frame (reads 1 until it's taken) |
| `3D` | 1 | Bit 0: the video CRC's display frame showed its frame whole (read-only) |
| `40` | 4 | The frame whose display frame the video CRC is of |
| `44` | 4 | The video CRC (read-only) |
| `48` | 2 | Display frames whose frame started on request (read-only) |
| `4A` | 2 | Lines that came to the display late (read-only) |
| `4C` | 2 | Lines overwritten before the display showed them (read-only) |
| `50` | 4 | The audio CRC (read-only): CRC-32 of the APU's channel levels in every CPU cycle since reset, 3 bytes a cycle: {pulse 2, pulse 1}, {noise, triangle}, the DMC's level |
| `54` | 4 | The PCM CRC (read-only): CRC-32 of the 48 kHz samples since reset, 2 bytes each, low first |
| `58` | 4 | How many 48 kHz samples since reset (read-only) |

The limits are levels: raising one lets the system run on from where it stopped. All registers are absolute, so a command the shell runs twice does no harm.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `uart_rx`, `uart_tx` | in, out | 1 | The test shell's serial link |
| `led` | out | 6 | Active low: `led[0]` a corrupt command frame was seen, `led[1]` a stalled one, `led[2]` SDRAM ready, `led[3]` running, `led[4]` halted or late, `led[5]` heartbeat |
| `mem_req`, `mem_we`, `mem_addr`, `mem_wdata` | out | 1, 1, 23, 8 | The board's memory, as `memory/sdram`'s user port |
| `mem_ack`, `mem_rdata`, `mem_ready` | in | 1, 8, 1 | |
| `pix_valid`, `pix`, `pix_x`, `pix_y` | out | 1, 9, 8, 8 | The PPU's pixels, to `nes_video` |
| `v_waiting`, `v_req` | out, in | 1 | Pacing: stopped for the display and nothing else; the display's request for the next frame |
| `v_cap_t`, `v_crc`, `v_crc_ok`, `v_crc_t`, `v_shown`, `v_late`, `v_overrun` | | | The video CRC and counts, from `nes_video` |
| `a_valid`, `a_pcm` | out | 1, 16 | The sound: a one-clock pulse with each 48 kHz sample, signed |

`nes_sdram` has the SDRAM pins instead, as on `sdram_ctrl`, and `nes_bram` no memory ports; both have `pclk` in and `tmds0`-`tmds2` out in place of the video ports.

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT` | 18 | Clocks per bit; 1.5 Mbaud at 27 MHz |
| `IDLE_CLKS` | 270,000 | The shell's stall timeout; 10 ms at 27 MHz |
| `DOT_NUM`, `DOT_DEN` | 35, 176 | PPU dots per clocks: 189, 1760 at 50 MHz. Dots must come at least 5 clocks apart, so a CPU cycle leaves SDRAM its 10 |
| `LEAD_DOTS` | 5 | PPU dots after reset before the CPU's first cycle |
| `PACE` | 0 | Keep pace with the display from power-up (register `3C` bit 0) |
| `BUILD_ID` | 0 | Reported by INFO; the CMake build sets it from the RTL's SHA-256 |

## Status

`rig::nes::nestest` runs nestest's automated mode for 26,554 cycles while the host reads memory; the trace CRC is still `0xebba51ce`, in the sim (both memories) and on both boards.

`rig::nes::rom_test` runs each test ROM in `harness/golden/nes_frames_crc32.txt` from power-up to a set frame. Each ROM must pass its own check, and its last frame's CRC must match MesenCE's (`tools/mesen/frames.py`). All 42 pass in the sim and on both boards, a Tang Nano 20K at 46.40625 MHz on SDRAM, keeping pace with its HDMI output, and a Tang Console 138K at 50 MHz on block RAM:
- blargg's `ppu_vbl_nmi` singles, `ppu_open_bus` and `oam_read`;
- the 2005 sprite hit, sprite overflow, VBL/NMI timing and PPU tests;
- `nmi_sync`'s demo and `full_palette`.

A frame captured from the board line by line matches MesenCE's pixel for pixel.

Save states (`rig::nes::state_test`): nmi_sync saved at a frame boundary while it runs, run on, reset, reloaded and restored ends on the same frame, line CRCs, trace CRC and cycle count as an uninterrupted run, in the sim and on both boards; so does sprite_overflow-3 in the sim. A state saved halfway on either board finishes on the other with MesenCE's frame (nmi_sync, sprite_overflow-3, ppu_vbl_nmi-10), and in the sim a state saved on the SDRAM model finishes the same on the block-RAM one (sprite_hit-09).

Before the PPU, the nestest run caught three planted bugs: the shell taking the CPU's RAM slot, the CPU's read slot not reserved, and a CPU cycle too short for the SDRAM. The planted PPU bugs the ROMs catch are listed in the PPU's README.

HDMI (`rig::nes::hdmi_test`): `oam_read` and `full_palette` run paced, and the CRC of the display frame showing each one's golden frame matches the sim's (`harness/golden/nes_hdmi_crc32.txt`), where a TMDS receiver model checks that frame's every pixel and sync; on the Tang Nano 20K the CRCs match, with every display frame whole and no late or overwritten lines.

On the Tang Nano 20K, with HDMI: 14,300 LUTs (69% of a GW2A-18C), 4,300 flip-flops and 35 of 46 block RAMs (16 of them the save-state buffer, 5 the line ring, 1 the colours), with fmax 72 MHz against the 46.4 MHz system clock and 140 MHz against the 74.25 MHz pixel clock. On the Tang Console 138K: 12,600 LUTs (9%) and 157 of 340 block RAMs (128 of them the 256 KB memory), with fmax 65 MHz against 50.
