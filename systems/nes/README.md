# nes

The NES as far as it's built:
- the 2A03's CPU (`cpu/6502` with `DECIMAL = 0`), its APU (`audio/apu-2a03`), and its DMC and OAM DMA;
- the 2C02 PPU (`video/ppu-2c02`);
- 2 KB of RAM mirrored to `$1FFF`;
- a cartridge (below): PRG ROM in the board's memory; CHR ROM in block RAM, or on the Tang Nano 20K in its SDRAM; 8 KB of CHR RAM; 8 KB of PRG RAM at `$6000` if the ROM has any; and the mappers NROM, UxROM, CNROM, AxROM, MMC1 and MMC3 (`nes_cart`);
- two standard controllers, driven by an input player (a script of buttons by frame) or by registers, for live input.

The test shell loads ROMs, runs the system and reads results, frame CRCs and whole frames. A save-state controller saves and loads the whole system. The picture goes out as HDMI at 720p. Reads of `$4000`-`$5FFF` other than `$4015`, `$4016` and `$4017` give open bus (the last value on the data bus), and writes there other than the APU's, `$4014` and `$4016` do nothing.

**The cartridge.** The harness sets it up from the ROM's header (registers `2C`, `2D`, `04` and `70`), and one bitstream runs every mapper `nes_cart` knows, by iNES number:

| Mapper | Boards | Banking |
| --- | --- | --- |
| 0 | NROM | 16 or 32 KB of PRG, 8 KB of CHR; mirroring from the header |
| 2 | UxROM | A 16 KB PRG bank at `$8000`, the last at `$C000` |
| 3 | CNROM | 8 KB CHR banks |
| 7 | AxROM | 32 KB PRG banks; one-screen mirroring, either page |
| 1 | MMC1 (SxROM) | Its serial port, 16 or 32 KB PRG modes, 4 or 8 KB CHR modes, its mirroring, PRG RAM off by `$E000` bit 4, and SUROM's 512 KB of PRG |
| 4 | MMC3 (TxROM) | 8 KB PRG and 1 or 2 KB CHR banks in both modes, its mirroring, PRG RAM enable and write protect, and its scanline IRQ (revision B) |

They behave as MesenCE's do, for the golden frames: MMC1 ignores a write in the cycle after another (the second write of a read-modify-write instruction) unless bit 7 is set, and powers up with one-screen mirroring and its last bank at `$C000`; MMC3 powers up with R0-R7 = 0, 2, 4, 5, 6, 7, 0, 1, vertical mirroring and PRG RAM off, and counts a rise of the PPU's A12 after it has been low for 3 CPU cycles. A bank number past the end wraps; for MMC1's ROMs whose size isn't a power of 2 (blargg's 80 KB ones), the harness lays PRG out as 256 KB, each bank a copy of the bank MesenCE's modulo gives. No bus conflicts. A ROM with no PRG RAM, by its NES 2.0 header, has open bus at `$6000`; an iNES 1.0 ROM gets 8 KB, as MesenCE gives it.

A mapper write takes effect where the CPU's PPU register access falls in its cycle, after the second dot, and the PPU's fetches see the banks as they stand at each dot's start: so a bank switch lands on the same dot as in MesenCE.

**Controllers.** Two standard pads, as MesenCE models them:
- While `$4016`'s bit 0, the strobe, is set, they keep loading their buttons.
- Each read of `$4016` or `$4017` then gives the next button in bit 0, in the order A, B, Select, Start, Up, Down, Left, Right, and 1s after the eighth.
- Bits 4-1 read 0 and bits 7-5 open bus.
- Every CPU read cycle counts, and a DMA's halt cycle, but not its dummy cycles after: on an NES (not a Famicom), `/OE` stays low through them, so a read a DMA halts clocks the pads once more, as MesenCE runs it.

The buttons the pads hold change only at a frame's end, line 240, so a run's input is the same on any board and in the sim. With the input player on (register `60`), they come from the input script at `0x07000000`:
- 512 entries of 4 bytes, {pad 1, pad 2, frame low, frame high}, in frame order;
- at each frame's end, the next entry applies if the new frame count has reached its frame, one entry a frame at most.

With it off, they come from registers `64` and `65`, for live input. The script is configuration, like the ROM: load it, then a state.

**Sound.** The APU's channel levels go into the audio CRC each CPU cycle, and through `apu_mixer` and `audio/resampler` to 48 kHz PCM. That's 800 samples per 29,780.5 cycles, the average NES frame with rendering on, so 48 kHz against the 60 Hz display the NES keeps pace with. The samples come out on `a_valid` and `a_pcm`, and `nes_video` sends them as HDMI audio, the same on both channels.

Built from `common/por`, `common/clock-enable`, `common/crc32`, `common/save-state`, `common/cdc`, `debug/test-shell`, `debug/video-probe`, `memory/arbiter`, `cpu/6502`, `audio/apu-2a03`, `audio/resampler`, `video/ppu-2c02`, `video/line-scaler` and `video/hdmi`. The host side is `rig::nes` in [harness](../../harness).

## Memory

`nes` takes the board's memory as a byte port, `memory/sdram`'s user port, which `memory/arbiter` shares between the CPU's PRG reads, first, and the shell. Three wrappers put memory behind it:

| Module | Memory | Used by |
| --- | --- | --- |
| `nes_sdram` | `memory/sdram`, 8 MB; with `CHR_EXT`, CHR ROM too | The Tang Nano 20K (`boards/tang-nano-20k/rtl/nes_top.sv`, `CHR_EXT = 1`), and the sim |
| `nes_bram` | `memory/bram`, 256 KB (`MEM_AW`) mirrored through the 8 MB window, and `CHR_AW` of CHR, both in banks of 2^`BANK_AW` | The Tang Console 138K (`boards/tang-console-138k/rtl/nes_top.sv`: 128 KB of CHR) and its sim |
| `nes_axi` | An AXI memory's 8 MB from `BASE`, through `memory/cache` (32 KB, `CACHE_IDX`, with next-line prefetch), `memory/port-cdc` when `ASYNC` puts the AXI side on its own clock `aclk`, and `memory/axi-bridge`; `CHR_AW` of CHR in block RAM | The PYNQ-Z2 (`boards/pynq-z2/rtl/pynq_nes_top.sv`: the DDR3 through HP0 at 74.25 MHz, 256 KB of CHR in 32 KB banks), and the sim (`make_nes_axi_sim`, synchronous) |

All three also hold `nes_video`, the HDMI output (below), with a pixel-clock input and the TMDS symbols out for the board's serializers.

The system's behaviour doesn't depend on which, or on the clock: a CPU cycle's last dot waits for its PRG read, if it isn't back.

**CHR ROM from the board's memory** (`CHR_EXT`, for the Tang Nano 20K, whose block RAM has no room for it): the harness puts CHR ROM bigger than CHR's block RAM in the board's memory from `0x400000`, each 16-byte tile with its planes interleaved (row r of plane p at byte 2r + p), so one 32-bit word (`mem_rdata_w`) holds two rows of a tile, both planes. The PPU says a dot ahead which address it will read and whether it uses the data (`vaddr_next`, `vread_next`: pattern fetches and `$2007` reads); that address goes through the mapper and, if its word isn't one of the two cached, it's read first of all the memory's users. The others start nothing in the two clocks after a dot starts (three when a register access may still change the address), and refreshes wait while a CHR read does, so a CHR read waits for one other access at most: about 13 clocks in all, within the 8 or more clocks to a dot plus the dot itself. A dot whose word still isn't there waits for it before it starts. The refresh comes every 7.8 µs, so a due one can wait. While rendering, the PPU needs at most a word every 8 dots, and `$2007` reads one each; a read during rendering can need three words in three dots, and the dots wait a few clocks.

## Timing

- **The PPU** runs one dot per pulse of `common/clock-enable` at `DOT_NUM`/`DOT_DEN` of the clock: 35/176 of 27 MHz is the NTSC dot rate exactly, on average. The pulses are 5 or 6 clocks apart.
- **A CPU cycle** is three dots. The CPU's PPU register access falls after the second dot, and its NMI sample after the third, as MesenCE runs them. After reset the PPU runs `LEAD_DOTS` dots before the CPU's first cycle, which lines its first opcode fetch up with MesenCE's.
- **Each CPU cycle** starts the clock after the last one ended, with its address valid:
  - **PRG reads** go to the memory on that first clock and must be back by the cycle's end, at least 14 clocks later at 27 MHz. SDRAM's worst case is 10 clocks and the arbiter's grant 1 more; with CHR in the SDRAM, a CHR read may come first, and then the cycle's last dot waits. The sticky `late` status bit would record data that still came too late.
  - **RAM and PRG RAM** are block RAMs shared with the shell. The CPU reads on its cycle's first clock and writes on its last; the shell uses the clocks in between.
  - **CHR and the nametables** are block RAMs shared the same way: the PPU has them for the two clocks before each dot (it reads on both, so the byte holds for its next-dot logic, and writes on the first), and the shell uses the others.
- **The shell** reaches the memory at any time, after any CPU read that is waiting.
- **The APU** takes each CPU cycle's access at the cycle's end, then runs the next cycle's tick, with the cycle's parity (`cycles` bit 0) for its odd/even delays. Its IRQ is the CPU's `irq_n`, as it stands after the cycle's access. A `$4015` read doesn't change open bus, which gives its bit 5, as on the 2A03.
- **DMA**, as MesenCE runs it. A `$4014` write or a DMC request halts the CPU on its next read cycle. Then each cycle is one of these, until both DMAs are done:
  - on an even CPU cycle (counted from reset), the DMC's read, once it has had a halt cycle and a dummy cycle;
  - otherwise on an even cycle, OAM DMA's read;
  - on an odd cycle, OAM DMA's write to `$2004` if it has a byte;
  - otherwise a dummy cycle that repeats the CPU's read (the pads don't see it: above).

  OAM DMA's cycles count as the DMC's halt and dummy cycles, and OAM DMA alone takes 513 or 514 cycles. A DMC request cancelled before its halt cycle never starts; one cancelled during its halt cycle stops after it. Not modelled: MesenCE's DMA reads of `$4000`-`$401F` while the CPU's address is there, and the restart of OAM DMA's count when a DMC request comes during a DMC read.

The system stops and starts only between CPU cycles, so stopping it changes nothing it does. That holds whether the shell, a cycle or frame limit, the frame capture or a save state stops it. The CPU's bus, the trace CRC and every frame are the same on any board, at any clock, and in the sim.

## Save states

`common/save-state` walks 21,052 bytes: the CPU's 4 state words, the PPU's 101, the system's own 21 (below; words 14 and 15 are 0), the APU's 17, RAM, PRG RAM, CHR's first 8 KB (CHR RAM) and the nametable RAM, in that order, between the bus and its buffer at `0x06000000`. PRG ROM, CHR ROM and the cartridge registers aren't part of it: load the ROM, then the state.

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
| 12 | The buttons the pads hold (pad 2's in 31-24, pad 1's in 23-16), then controller 2's and 1's shift registers |
| 13 | The input script's position (9-1), the strobe (0) |
| 16, 17 | MMC3's R3-R0 and R7-R4, R0 in the low byte |
| 18 | MMC3's `$8000` (28-21), IRQ latch (20-13) and counter (12-5), `$A000` bit 0 (4), `$A001` bits 7-6 (3-2), reload (1), IRQ on (0) |
| 19 | MMC1's last CHR register written was `$C000`'s (29), it wrote last cycle (28), bits shifted (27-25), shift register (24-20), control (19-15), CHR 0 (14-10), CHR 1 (9-5), PRG (4-0) |
| 20 | MMC3's IRQ (11), A12 seen low (10), CPU cycles since (9-8, up to 3); the UxROM, CNROM and AxROM latch (7-0) |

The clock-enable's phase isn't state: it only sets how many clocks pass before the next dot.

## Shell address map

| Address | What |
| --- | --- |
| `0x00000000`–`0x007FFFFF` | The board's memory, 8 MB (a smaller memory mirrors). PRG ROM starts at 0 |
| `0x01000000`–`0x010000FF` | Registers, below |
| `0x02000000`–`0x0200FFFF` | The CPU's address space: RAM (`$0000`–`$1FFF`) and PRG RAM (`$6000`–`$7FFF`); the rest reads 0 and ignores writes |
| `0x03000000`–`0x03003FFF` | The PPU's: CHR's first 8 KB, unbanked (`$0000`–`$1FFF`, writable from here even when it's ROM) and the nametables (`$2000`–`$3FFF`, mirrored as the cartridge says) |
| `0x03004000`–`0x030047FF` | The nametable RAM as it is, unmirrored |
| `0x04000000`–`0x0400000F` | CPU save state, 4 words, little-endian |
| `0x04001000`–`0x04001193` | PPU save state, 101 words (OAM is words 0-63) |
| `0x04002000`–`0x04002053` | The system's own state, 21 words (above) |
| `0x04003000`–`0x04003043` | APU save state, 17 words |
| `0x05000000`–`0x050003BF` | CRC of each line of the last frame, 4 bytes a line; read while stopped |
| `0x05001000`–`0x050011FF` | The captured line, 2 bytes a pixel |
| `0x06000000`–`0x06007FFF` | The save-state buffer; while no command runs |
| `0x07000000`–`0x070007FF` | The input script, 512 entries of 4 bytes; write-only (reads give 0). An entry is written when its byte 3 is |
| `0x08000000`– | All of CHR's block RAM, unbanked: 2^`CHR_AW` bytes, mirrored |
| `0x09000000`– | The trace buffer's ring (`debug/trace`): 2^`TRACE_AW` entries of 4 bytes, the trace CRC's bytes for one CPU cycle; cycle n is at entry n mod 2^`TRACE_AW`. Read while stopped |

Anything else reads 0 and ignores writes. Multi-byte registers are little-endian. A save-state word is written when its byte 3 is written, using bytes 0-2 written before it. State writes count only while the system is held in reset or stopped between cycles, and the system's own words only out of reset.

| Offset | Bytes | Register |
| --- | --- | --- |
| `00` | 1 | Control: bit 0 run, bit 1 hold the system in reset. Reset clears the cycle and frame counts, the CRCs and the status. Starts as reset held |
| `04` | 3 | PRG mask: the mapper's PRG address ANDed with this gives the board-memory address: PRG ROM's size - 1. `0x3FFF` mirrors 16 KB into both halves; `0x7FFF` (the default) maps 32 KB |
| `08` | 2 | Reset vector override: CPU reads of `$FFFC` and `$FFFD` give this |
| `0A` | 1 | Bit 0: use the override |
| `0C` | 4 | Stop once this many CPU cycles have run since reset; 0 never |
| `10` | 4 | CPU cycles since reset (read-only) |
| `14` | 4 | CRC-32 of the CPU's bus since reset (read-only): 4 bytes a cycle, address low, address high, data read or written, flags (bit 0 write, bit 1 opcode fetch). DMA cycles count, with the DMA's address |
| `18` | 1 | Status (read-only): bit 0 the CPU halted (a JAM opcode), bit 1 stopped at a limit, bit 2 a PRG or CHR read was late, bit 3 running, bit 4 the capture is holding the system, bit 5 a frame CRC is valid, bit 6 waiting for the display, bit 7 the video CRC asked for has come |
| `1C` | 4 | Stop once this many frames have ended since reset; 0 never |
| `20` | 4 | Frames ended since reset (read-only): a frame ends at line 240 |
| `24` | 4 | CRC-32 of the last whole frame (read-only): 2 bytes a pixel, low first, the PPU's {emphasis, colour} |
| `28` | 4 | Which frame that is (read-only), counting from 0 |
| `2C` | 1 | Cartridge: bit 0 vertical mirroring (for mappers that don't set it), bit 1 CHR is RAM, bit 2 there's PRG RAM (power-up: set), bit 3 CHR ROM is in the board's memory (with `CHR_EXT`) |
| `2D` | 1 | The mapper, by iNES number (unknown ones behave as NROM) |
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
| `60` | 1 | Bit 0: the input player drives the controllers |
| `61` | 2 | Entries in the input script, 0-512 |
| `64` | 1 | Controller 1's buttons while the player is off (bit 0 A, B, Select, Start, Up, Down, Left, bit 7 Right) |
| `65` | 1 | Controller 2's |
| `66` | 2 | The input script's next entry (read-only) |
| `68` | 2 | The buttons the pads hold, pad 1 then pad 2 (read-only) |
| `70` | 3 | CHR mask: the mapper's CHR address ANDed with this: CHR's size - 1 (power-up `0x1FFF`) |
| `74` | 1 | CHR's block RAM holds 2^this bytes (read-only: `CHR_AW`) |
| `75` | 1 | The board's memory holds 2^this bytes (read-only: `MEM_AW`) |
| `76` | 1 | Bit 0: CHR ROM can come from the board's memory (read-only: `CHR_EXT`) |
| `78` | 4 | Clocks the dots have waited for memory since reset (read-only): a PRG read or CHR word not back in time. They change nothing the system does, but too many keep it from keeping pace with a display |
| `7C` | 12 | A memory cache's counts since reset, 4 bytes each (read-only; 0 without one): reads it answered, reads that went to memory, lines it prefetched (`nes_axi`'s `memory/cache`) |
| `88` | 4 | The trace buffer's count (read-only): the number of the cycle it records next; a state loaded sets it to the state's cycle |
| `8C` | 2 | How many of the trace buffer's entries are valid (read-only), up to 2^`TRACE_AW`: cycles `88` - this to `88` - 1 |
| `8E` | 1 | The trace buffer holds 2^this cycles (read-only: `TRACE_AW`) |
| `8F` | 1 | The CPU/PPU alignment: PPU dots after a reset before the CPU's first cycle, 1-7 (power-up `LEAD_DOTS`), taken as the system leaves reset. 5 is MesenCE's default alignment; 6 and 7 put the CPU a dot and two later, as two of MesenCE's random ones do |

The limits are levels: raising one lets the system run on from where it stopped. All registers are absolute, so a command the shell runs twice does no harm.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `uart_rx`, `uart_tx` | in, out | 1 | The test shell's serial link |
| `led` | out | 6 | Active low: `led[0]` a corrupt command frame was seen, `led[1]` a stalled one, `led[2]` SDRAM ready, `led[3]` running, `led[4]` halted or late, `led[5]` heartbeat |
| `mem_req`, `mem_we`, `mem_addr`, `mem_wdata` | out | 1, 1, 23, 8 | The board's memory, as `memory/sdram`'s user port |
| `mem_ack`, `mem_rdata`, `mem_ready` | in | 1, 8, 1 | |
| `mem_rdata_w` | in | 32 | With `CHR_EXT`: a read's whole word, byte lanes in address order |
| `mem_ref_hold` | out | 1 | With `CHR_EXT`: a refresh should wait now |
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
| `LEAD_DOTS` | 5 | PPU dots after reset before the CPU's first cycle, register `8F`'s power-up value |
| `PACE` | 0 | Keep pace with the display from power-up (register `3C` bit 0) |
| `CHR_AW`, `CHR_BANK_AW` | 13, `CHR_AW` | CHR's block RAM: 2^`CHR_AW` bytes, in banks of 2^`CHR_BANK_AW` (`nes_bram`'s `CHR_AW` and `BANK_AW`) |
| `MEM_AW` | 23 | The board's memory's size, for the harness (`nes_bram` passes its own) |
| `CHR_EXT` | 0 | CHR ROM can come from the board's memory (`nes_sdram`'s too); needs 8 or more clocks a dot |
| `TRACE_AW` | 10 | The trace buffer keeps the last 2^`TRACE_AW` CPU cycles (4 bytes each, in byte-wide block RAM) |
| `SAVE_STATE` | 1 | 0 builds the system without save states (the CPU's, PPU's, APU's and resampler's ports do nothing; OAM can still be cleared): the Tang Nano 20K's NES, which fits only so with the APU and HDMI audio |
| `BUILD_ID` | 0 | Reported by INFO; the CMake build sets it from the RTL's SHA-256 |

## Status

`rig::nes::nestest` runs nestest's automated mode for 26,554 cycles while the host reads memory; the trace CRC is still `0xebba51ce`, in the sim (both memories) and on both boards, and the trace buffer's last 1024 cycles match nestest.log, instruction by instruction.

**The sweep (Oct 31).** The golden list has 175 ROMs: the 103 before and 72 more from nes-test-roms (every ROM there for these mappers with a result MesenCE gives automatically). 165 match MesenCE in the sim, on the Tang Nano 20K and on the PYNQ-Z2, with the same CRCs. The same 10 fail on all three, to be fixed in milestone 10b:
- eight instruction tests that use the unstable unofficial opcodes (XAA, LAX `#imm`, AHX, SHX, SHY, TAS, LAS), which halt `cpu/6502` (`instr_test-03` and `-07`, `instr_test_v3-02`, `-06` and `-all`, `nes_instr_test-02` and `-06`, `cpu_test5-cpu`);
- `dmc_dma-4016_read`: the extra controller reads a DMC DMA makes during a `$4016` read;
- `mmc3_test_v1-4`: the older MMC3 test's IRQ timing within a scanline.

**Other power-ups.** With RAM powered up all `0xFF`, and at the CPU/PPU alignments of 6 and 7 lead dots (register `8F`), the 103 earlier ROMs match MesenCE's frames at the same settings on both boards (`tools/mesen/frames.py --ram`, `--lead`); in the sim, the ROMs whose frames those change (blargg's APU tests, `full_palette`).

`rig::nes::rom_test` runs each test ROM in `harness/golden/nes_frames_crc32.txt` from power-up to a set frame. Each ROM must pass its own check, and its last frame's CRC must match MesenCE's (`tools/mesen/frames.py`). All 42 pass in the sim and on both boards, a Tang Nano 20K at 46.40625 MHz on SDRAM, keeping pace with its HDMI output, and a Tang Console 138K at 50 MHz on block RAM:
- blargg's `ppu_vbl_nmi` singles, `ppu_open_bus` and `oam_read`;
- the 2005 sprite hit, sprite overflow, VBL/NMI timing and PPU tests;
- `nmi_sync`'s demo and `full_palette`.

A frame captured from the board line by line matches MesenCE's pixel for pixel.

Save states (`rig::nes::state_test`): nmi_sync saved at a frame boundary while it runs, run on, reset, reloaded and restored ends on the same frame, line CRCs, trace CRC and cycle count as an uninterrupted run, in the sim and on both boards; so does sprite_overflow-3 in the sim. A state saved halfway on either board finishes on the other with MesenCE's frame (nmi_sync, sprite_overflow-3, ppu_vbl_nmi-10), and in the sim a state saved on the SDRAM model finishes the same on the block-RAM one (sprite_hit-09).

Before the PPU, the nestest run caught three planted bugs: the shell taking the CPU's RAM slot, the CPU's read slot not reserved, and a CPU cycle too short for the SDRAM. The planted PPU bugs the ROMs catch are listed in the PPU's README.

Mappers: Holy Mapperel's check of each mapper (NROM, UxROM, CNROM, AxROM, MMC1 with CHR RAM, 32 KB and 128 KB of CHR ROM and SUROM's 512 KB, MMC3 with CHR RAM and with 256 KB of CHR ROM), blargg's MMC3 IRQ tests (`mmc3_irq_tests` 1-4 and 6, `mmc3_test_2` 1, 2, 3 and 5) and his all-in-one MMC1 ROMs (`instr_test-v5` official, `cpu_interrupts`, `ppu_vbl_nmi`, `apu_test`) match MesenCE's frames in the sim and on both boards: all 103 golden ROMs on the Tang Nano 20K (CHR ROM over 8 KB from its SDRAM), and all 103 on the PYNQ-Z2 (PRG ROM from its DDR3 through the cache, which keeps the NES from waiting for memory: none in its HDMI runs, at most 26,000 clocks across a ROM's whole run). Seven of them, among them the 256 KB MMC1 and MMC3 ROMs, also match with their PRG ROM behind the sim's AXI memory. In the sim, 8 KB CHR ROMs read from the SDRAM give the same frames as from block RAM, and save states keep MMC3's IRQ and MMC1's state.

Sound: the 34 APU and timing ROMs in the golden list pass in the sim and on both boards, each with the sim's audio CRC (`harness/golden/nes_audio_crc32.txt`). Through HDMI, the sim's receiver gets every 48 kHz sample the system made, and a monitor plays the 20K's sound.

HDMI (`rig::nes::hdmi_test`): `oam_read` and `full_palette` run paced, and the CRC of the display frame showing each one's golden frame matches the sim's (`harness/golden/nes_hdmi_crc32.txt`), where a TMDS receiver model checks that frame's every pixel and sync; on the Tang Nano 20K the CRCs match, with every display frame whole and no late or overwritten lines.

On the Tang Nano 20K, with HDMI, the APU and the mappers (`SAVE_STATE=0`): 15,800 LUTs and 2,700 ALUs (89% of a GW2A-18C's slots), 5,700 flip-flops and 38 of 46 block RAMs, with fmax 51 MHz against the 46.4 MHz system clock (seed 8). On the PYNQ-Z2: 16,300 LUTs (15%) and 85 of 140 36 Kb block RAMs, 42.4 MHz against 37.1 (and 90 MHz for HP0's side against 74.25). On the Tang Console 138K: 12,600 LUTs (9%) and 157 of 340 block RAMs (128 of them the 256 KB memory), with fmax 65 MHz against 50.
