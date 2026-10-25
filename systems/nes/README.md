# nes

The NES as far as it's built:
- the 2A03's CPU (`cpu/6502` with `DECIMAL = 0`) and its OAM DMA;
- the 2C02 PPU (`video/ppu-2c02`);
- 2 KB of RAM mirrored to `$1FFF`, and 8 KB of PRG RAM at `$6000`;
- an NROM cartridge (mapper 0): PRG ROM in SDRAM, 8 KB of CHR ROM or CHR RAM in block RAM, and horizontal or vertical nametable mirroring.

The test shell loads ROMs, runs the system and reads results, frame CRCs and whole frames. The APU, controllers and other mappers come in later milestones; until then, reads of `$4000`-`$5FFF` give open bus (the last value on the data bus) and writes there do nothing, except `$4014`.

Built from `common/por`, `common/clock-enable`, `common/crc32`, `debug/test-shell`, `debug/video-probe`, `memory/sdram`, `cpu/6502` and `video/ppu-2c02`. On the Tang Nano 20K, `boards/tang-nano-20k/rtl/nes_top.sv` connects the SDRAM pins. The host side is `rig::nes` in [harness](../../harness).

## Timing

- **The PPU** runs one dot per pulse of `common/clock-enable` at `DOT_NUM`/`DOT_DEN` of the clock: 35/176 of 27 MHz is the NTSC dot rate exactly, on average. The pulses are 5 or 6 clocks apart.
- **A CPU cycle** is three dots. The CPU's PPU register access falls after the second dot, and its NMI sample after the third, as MesenCE runs them. After reset the PPU runs `LEAD_DOTS` dots before the CPU's first cycle, which lines its first opcode fetch up with MesenCE's.
- **Each CPU cycle** starts the clock after the last one ended, with its address valid:
  - **PRG reads** go to SDRAM on that first clock and must be back by the cycle's end, at least 14 clocks later at 27 MHz. SDRAM's worst case is 10 clocks, so this can't miss; the sticky `late` status bit would record it if it did.
  - **RAM and PRG RAM** are block RAMs shared with the shell. The CPU reads on its cycle's first clock and writes on its last; the shell uses the clocks in between.
  - **CHR and the nametables** are block RAMs shared the same way: the PPU reads on the clock before each dot, and the shell uses the others.
- **The shell** reaches SDRAM at any time, after any CPU read that is waiting.
- **OAM DMA:** a `$4014` write halts the CPU on its next read cycle. The DMA then copies the page to `$2004`: a read on even CPU cycles (counted from reset), a write on odd, with a dummy cycle to align when needed. That makes 513 or 514 cycles, as in MesenCE.

The system stops and starts only between CPU cycles, so stopping it changes nothing it does. That holds whether the shell, a cycle or frame limit, or the frame capture stops it. The CPU's bus, the trace CRC and every frame are the same on any board and in the sim.

## Shell address map

| Address | What |
| --- | --- |
| `0x00000000`–`0x007FFFFF` | SDRAM, 8 MB. PRG ROM starts at 0 |
| `0x01000000`–`0x010000FF` | Registers, below |
| `0x02000000`–`0x0200FFFF` | The CPU's address space: RAM (`$0000`–`$1FFF`) and PRG RAM (`$6000`–`$7FFF`); the rest reads 0 and ignores writes |
| `0x03000000`–`0x03003FFF` | The PPU's: CHR (`$0000`–`$1FFF`, writable from here even when it's ROM) and the nametables (`$2000`–`$3FFF`, mirrored as the cartridge says) |
| `0x04000000`–`0x0400000F` | CPU save state, 4 words, little-endian |
| `0x04001000`–`0x04001193` | PPU save state, 101 words (OAM is words 0-63) |
| `0x05000000`–`0x050003BF` | CRC of each line of the last frame, 4 bytes a line; read while stopped |
| `0x05001000`–`0x050011FF` | The captured line, 2 bytes a pixel |

Anything else reads 0 and ignores writes. Multi-byte registers are little-endian. A save-state word is written when its byte 3 is written, using bytes 0-2 written before it. State writes count only while the system is held in reset or stopped between cycles.

| Offset | Bytes | Register |
| --- | --- | --- |
| `00` | 1 | Control: bit 0 run, bit 1 hold the system in reset. Reset clears the cycle and frame counts, the CRCs and the status. Starts as reset held |
| `04` | 3 | PRG mask: CPU address bits 0–14 ANDed with this give the SDRAM address. `0x3FFF` mirrors 16 KB into both halves; `0x7FFF` (the default) maps 32 KB |
| `08` | 2 | Reset vector override: CPU reads of `$FFFC` and `$FFFD` give this |
| `0A` | 1 | Bit 0: use the override |
| `0C` | 4 | Stop once this many CPU cycles have run since reset; 0 never |
| `10` | 4 | CPU cycles since reset (read-only) |
| `14` | 4 | CRC-32 of the CPU's bus since reset (read-only): 4 bytes a cycle, address low, address high, data read or written, flags (bit 0 write, bit 1 opcode fetch). DMA cycles count, with the DMA's address |
| `18` | 1 | Status (read-only): bit 0 the CPU halted (a JAM opcode), bit 1 stopped at a limit, bit 2 a PRG read was late, bit 3 running, bit 4 the capture is holding the system, bit 5 a frame CRC is valid |
| `1C` | 4 | Stop once this many frames have ended since reset; 0 never |
| `20` | 4 | Frames ended since reset (read-only): a frame ends at line 240 |
| `24` | 4 | CRC-32 of the last whole frame (read-only): 2 bytes a pixel, low first, the PPU's {emphasis, colour} |
| `28` | 4 | Which frame that is (read-only), counting from 0 |
| `2C` | 1 | Cartridge: bit 0 vertical mirroring, bit 1 CHR is RAM |
| `30` | 4 | The frame to capture |
| `34` | 1 | The line to capture |
| `35` | 1 | Bit 0: capture |

The limits are levels: raising one lets the system run on from where it stopped. All registers are absolute, so a command the shell runs twice does no harm.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `uart_rx`, `uart_tx` | in, out | 1 | The test shell's serial link |
| `led` | out | 6 | Active low: `led[0]` a corrupt command frame was seen, `led[1]` a stalled one, `led[2]` SDRAM ready, `led[3]` running, `led[4]` halted or late, `led[5]` heartbeat |
| `sd_*` | | | The SDRAM pins, as on `memory/sdram`'s `sdram_ctrl` |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT` | 18 | Clocks per bit; 1.5 Mbaud at 27 MHz |
| `IDLE_CLKS` | 270,000 | The shell's stall timeout; 10 ms at 27 MHz |
| `FREQ_MHZ` | 27 | Clock frequency, for the SDRAM timings |
| `DOT_NUM`, `DOT_DEN` | 35, 176 | PPU dots per clocks. Dots must come at least 5 clocks apart, so a CPU cycle leaves SDRAM its 10 |
| `LEAD_DOTS` | 5 | PPU dots after reset before the CPU's first cycle |
| `BUILD_ID` | 0 | Reported by INFO; the CMake build sets it from the RTL's SHA-256 |

## Status

`rig::nes::nestest` runs nestest's automated mode for 26,554 cycles while the host reads memory; the trace CRC is still `0xebba51ce`, in the sim and on a Tang Nano 20K.

`rig::nes::rom_test` runs each test ROM in `harness/golden/nes_frames_crc32.txt` from power-up to a set frame. Each ROM must pass its own check, and its last frame's CRC must match MesenCE's (`tools/mesen/frames.py`). All 42 pass in the sim and on a Tang Nano 20K:
- blargg's `ppu_vbl_nmi` singles, `ppu_open_bus` and `oam_read`;
- the 2005 sprite hit, sprite overflow, VBL/NMI timing and PPU tests;
- `nmi_sync`'s demo and `full_palette`.

A frame captured from the board line by line matches MesenCE's pixel for pixel.

Before the PPU, the nestest run caught three planted bugs: the shell taking the CPU's RAM slot, the CPU's read slot not reserved, and a CPU cycle too short for the SDRAM. The planted PPU bugs the ROMs catch are listed in the PPU's README.

About 11,800 LUTs (56% of a GW2A-18C), 2,800 flip-flops and 15 block RAMs; fmax 45 MHz against the 27 MHz clock.
