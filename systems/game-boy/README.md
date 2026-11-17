# Game Boy

The Game Boy (DMG): the SM83 (`cpu/sm83`) on the console's memory map, with its boot ROM, video RAM, work RAM, OAM, high RAM, timer, serial port, joypad, OAM DMA and interrupt registers, and the cartridge outside the core.

Module `gameboy`. **In progress** (G3 of the rig's Game Boy roadmap): it draws its picture with the PPU (`gb_ppu`), a pixel at a time; the sound is, until G5, its registers only (`gb_apu_regs`), so nothing is heard yet; the cartridge is a plain 32 KB ROM in the tests, with no MBC. It runs from power-up through [SameBoy](https://github.com/LIJI32/SameBoy)'s open DMG boot ROM, and runs blargg's CPU and timing ROMs, Mooneye's CPU, timer, interrupt, OAM DMA and PPU tests and dmg-acid2 to MesenCE's result and frame in the sim (below).

## Timing

The system steps one T-cycle per `ce` (4.194304 MHz on the console). An M-cycle is 4 of them, and the CPU takes one M-cycle per 4 T-cycles. Within an M-cycle, in order:

1. **The third T-cycle:** the timer's counter steps, along with TIMA's count and its reload.
2. **The fourth T-cycle:** the CPU's read sees everything as it stands then, the timer's step included.
3. **The M-cycle's end:** the CPU's write lands, with everything else that changes once an M-cycle (IF and IE, the serial port, the joypad, OAM DMA).

This order is what the hardware's tests measure. It is also what M-cycle emulators that pass them do: they step the timer, then make the access. With the timer stepping at the M-cycle's end instead, blargg's `instr_timing` measured opcodes one M-cycle off, and Mooneye's `tim00` and `intr_timing` failed.

An interrupt request lands in IF at the edge that makes it (`irq` outputs are combinational with their strobes), so a read of IF in the same M-cycle as a register's change sees both, at any clock ratio.

The CPU decides on an interrupt at an instruction's end, from IF as it is then. Halted, it sees a request made at an M-cycle's second or third T-cycle an M-cycle late, as SameBoy's DMG, which looks two T-cycles into each halted M-cycle, does; the M-cycle that sees a request is the dispatch's first, or the next opcode's fetch (`cpu/sm83`). Mooneye's HALT tests and its PPU interrupt tests (`intr_1_2_timing`, `vblank_stat_intr`, `hblank_ly_scx_timing`) need both: the VBlank request comes at an M-cycle's first T-cycle, mode 2's at its third, mode 0's anywhere.

`ce` must come at least 2 clocks apart. The read mux is registered, so a read's data is taken a clock before the M-cycle's last T-cycle ends: on any clock ratio, it is what the address held during that T-cycle.

## The memory map

| Address | Holds |
| --- | --- |
| `$0000-$00FF` | The boot ROM, until a non-zero write to `$FF50` (`boot_*` loads it) |
| `$0000-$7FFF`, `$A000-$BFFF` | The cartridge (`cart_*`) |
| `$8000-$9FFF` | Video RAM, 8 KB |
| `$C000-$DFFF` | Work RAM, 8 KB, echoed at `$E000-$FDFF` |
| `$FE00-$FE9F` | OAM; `$FEA0-$FEFF` read 0 |
| `$FF00-$FF7F` | I/O; unused registers read `$FF` |
| `$FF80-$FFFE` | High RAM |
| `$FFFF` | IE |

The cartridge and work RAM share the external bus; video RAM has its own.

## The parts

- **Timer (`gb_timer`):** DIV is the system counter's upper byte. TIMA counts the falling edges of TAC's enable ANDed with the counter bit TAC selects, so a write to DIV or TAC can add a count, as on the chip.
  - When TIMA overflows, it reads 0 for one M-cycle; it then takes TMA and requests the interrupt.
  - A write to TIMA during that M-cycle cancels both.
  - In the M-cycle after, a write to TIMA is lost, and a write to TMA goes to TIMA as well.
- **Serial port (`gb_serial`):** there is no cable, so each bit shifted in is 1.
  - The internal clock is SameBoy's model of the DMG's: a flip-flop that toggles on each falling edge of the system counter's bit 7, and shifts a bit when it falls (8,192 bits a second). It keeps the counter's phase from reset, not the SC write's.
  - A write to SC first gives the flip-flop its falling edge if it is high, then restarts the bit count.
  - With the external clock, a transfer never ends.
  - `ser_tx` is the byte in SB when SC is written with bits 7 and 0 set. This is the stream blargg's and Mooneye's ROMs report on, taken as MesenCE's test script takes it.
  - Why this model: with the clock on the counter's bit 8 instead, a byte of Mooneye's report sometimes got a running transfer's shift between its SB and SC writes. Mooneye's send loop gives up before a transfer's 8 bits are done, so its transfers overlap.
- **Joypad (`gb_joypad`):** P1 selects the direction keys (bit 4 low) or the buttons (bit 5 low). A selected line going low requests the joypad interrupt, and any selected key down wakes the CPU from STOP.
- **OAM DMA:** a write to `$FF46` starts a copy after one setup M-cycle: 160 bytes from `$XX00`, one an M-cycle, with `$E000` and above coming from work RAM.
  - While the copy runs, the CPU reads OAM as `$FF` and can't write it.
  - A CPU access on the bus the DMA reads from gets the DMA's byte if it reads; if it writes, the write is lost.
  - A write to `$FF46` during a copy restarts it.
  - Mooneye's per-instruction timing tests (`call_timing`, `ret_timing` and the others) place a read one M-cycle either side of the copy's end, so they fix its length to the M-cycle.
- **PPU (`gb_ppu`):** the LCD's registers and its picture, dot by dot, as SameBoy models the DMG's (read for facts).
  - A line is 456 dots: mode 2 (the OAM scan, up to 10 objects) for 80, mode 3 for 172 or more, then mode 0. Lines 144-153 are VBlank; LY reads 153 for only the first dots of line 153, then 0. The first line after the LCD is turned on has no mode 2 and is 7 dots shorter.
  - Mode 3 runs the fetcher a step a dot into an 8-pixel background FIFO, and the object FIFO beside it, so its length comes out as on the chip: longer by SCX's low 3 bits, by the window's start and by each object's fetch.
  - The window starts where WX says on lines from WY's, with its own line counter. Objects are 8x8 or 8x16, flipped either way, the one with the lower X (then the lower OAM index) in front, behind the background's colours 1-3 when their priority bit says.
  - STAT's interrupt is requested when the OR of its enabled conditions rises, at the dots SameBoy updates it (mode 2's a dot before STAT shows it, except on line 0). Writing STAT on the DMG sets every condition for a dot first, which can request it.
  - Video RAM reads $FF and takes no writes in mode 3; OAM in modes 2 and 3 (on the DMG, from just before mode 2).
  - A write to SCX, SCY, LCDC, the palettes, LYC, WY, WX or STAT lands at the dot SameBoy's access conflicts put it at, which Mooneye's lcdon tests pin down.
  - It reads video RAM and OAM through ports of their own (OAM 16 bits wide).
- **Sound, for now (`gb_apu_regs`):** its registers only.
  - They read back with the DMG's unreadable bits set, and NR52's power bit clears them.
  - The wave RAM reads and writes.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst`, `ce` | in | 1 | Clock, synchronous reset, one T-cycle |
| `cart_addr` | out | 16 | The external bus's address: the CPU's, or the DMA's while it copies from there |
| `cart_rd` | out | 1 | This M-cycle reads the cartridge |
| `cart_wr`, `cart_wdata` | out | 1, 8 | Write `cart_wdata` at `cart_addr` at this clock |
| `cart_rdata` | in | 8 | The cartridge's data, needed a clock before the M-cycle's last T-cycle ends |
| `boot_we`, `boot_addr`, `boot_wdata` | in | 1, 8, 8 | Write the boot ROM |
| `keys` | in | 8 | Keys down (1 pressed): Start, Select, B, A, down, up, left, right (bit 7 to 0) |
| `ser_tx`, `ser_tx_valid` | out | 8, 1 | A serial transfer of `ser_tx` starts |
| `m_end` | out | 1 | The clock that ends an M-cycle |
| `cpu_sync`, `cpu_pc` | out | 1, 16 | This M-cycle fetches an opcode, at this PC (for traces) |
| `boot_on` | out | 1 | The boot ROM is mapped |
| `lcdc` | out | 8 | LCDC |
| `pix_we`, `pix_x`, `pix_y`, `pix_shade` | out | 1, 8, 8, 2 | A pixel of the picture, shade 0 (white) to 3 |
| `frame_end` | out | 1 | VBlank starts: the frame is out |

## gb_sys, under the test shell

`gb_sys` puts the Game Boy behind `debug/test-shell`, as `systems/atari-2600`'s `a2600_sys` does the 2600, so the host (`harness`'s `rig::gb`) can run a test ROM on a board or in the sim and check it over the link.

- **Cartridge:** 32 KB of ROM and 8 KB of RAM at `$A000-$BFFF`, in block RAM; no MBC yet (G6).
- **Boot ROM:** the host writes it, as it does the cartridge.
- **T-cycles:** at `T_NUM`/`T_DEN` of the clock (the console's 4.194304 MHz from 27 MHz is 65,536/421,875), only while it runs. It stops between T-cycles, so a run stopped and started again is the same as one left to run, on any board and in the sim.
- **Frames:** a frame ends as VBlank starts, or after 70,224 T-cycles without one (the LCD off), as `gb_roms_test` counts them. The frame buffer holds each pixel's shade as the PPU last drew it.
- **Frame CRC:** when the system stops at a limit, it takes the CRC of the frame buffer (2 bytes a pixel, the shade then 0, as `gb_frames.py` takes MesenCE's), in about 23,000 clocks, before it runs again.
- **Serial port:** every byte the game sends is kept (the last 4,096), with a count, for blargg's and Mooneye's reports.

| Address | What |
| --- | --- |
| `0x00000000-0x00007FFF` | The cartridge's ROM |
| `0x01000000-0x0100007F` | Registers, below |
| `0x02000000-0x02001FFF` | The cartridge's RAM |
| `0x03000000-0x030000FF` | The boot ROM |
| `0x04000000-0x04000FFF` | The serial port's bytes: byte n at n mod 4,096 |
| `0x05000000-0x050059FF` | The frame buffer: y × 160 + x, a shade (0 white to 3) a byte |

| Register | Bytes | Meaning |
| --- | --- | --- |
| `00` | 1 | Bit 0 run, bit 1 hold the system in reset (set at power-up) |
| `04` | 4 | Stop once this many T-cycles have run since reset; 0 never |
| `08` | 4 | T-cycles since reset (read-only) |
| `0C` | 1 | Status (read-only): bit 0 stopped at a limit, 1 running, 2 the frame CRC is taken, 3 taking it |
| `10` | 4 | Stop once this many frames have ended since reset; 0 never |
| `14` | 4 | Frames ended since reset (read-only) |
| `18` | 4 | The frame CRC (read-only) |
| `1C` | 4 | Frames ended when it was taken (read-only) |
| `20` | 4 | Bytes the serial port has sent since reset (read-only) |
| `24` | 1 | Keys down, as `keys` |
| `28` | 1 | LCDC (read-only) |
| `29` | 1 | Bit 0: the boot ROM is mapped (read-only) |
| `2A` | 2 | The CPU's PC (read-only) |
| `2C` | 1 | The room for ROM, log2 (read-only) |

## Tests

`gb_roms_test` runs the test ROMs of `testroms/manifest-gb.toml` that the system has the parts for, through SameBoy's DMG boot ROM. These are the ROMs for the Game Boy (dmg) whose `needs` are among cpu, serial, timer, interrupts, boot, ppu and oam dma.

- **Results:** a ROM with a result of its own (blargg's text over the serial port, or Mooneye's bytes) must end with MesenCE's (`harness/golden/gb_frames_crc32.txt`) within twice MesenCE's frames.
- **Frames:** its frame 30 frames after the result must be MesenCE's too, by CRC (2 bytes a pixel, the shade then 0, row by row, as `tools/mesen/gb_frames.py` takes it). A frame check (dmg-acid2) has its frame at the number the list gives. A frame ends as VBlank starts, or every 70,224 T-cycles while the LCD is off.
- **Expected fails:** MesenCE fails three Mooneye tests through SameBoy's boot ROM, which takes a different time from Nintendo's (`boot_div`, `boot_hwio` and `serial-boot_sclk_align`). The system must fail them too.
- **One frame not compared:** `serial-boot_sclk_align`'s fail screen shows counts that depend on the serial clock's phase from power-up, which nothing settles for this boot ROM. Ours differ from MesenCE's, and SameBoy's from ours by one (its DIV runs 4 T-cycles ahead).
- **Options:** `RS_GB_ONLY=<id>,...` runs some of them, `RS_GB_JOBS=<n>` sets the threads (default up to 6), `RS_GB_TRACE=1` prints each opcode fetch and serial byte, and `RS_GB_DUMP=<dir>` writes each ROM's checked frame there as a PGM.

`harness`'s `harness_test` runs three of them through `gb_sys`'s shell in the sim, as a board will (`rig::gb::rom_test`): `ei_sequence` (Mooneye's bytes), `instr_timing` (blargg's text) and dmg-acid2 (a frame). The host steps the system a frame at a time, reading the serial port's bytes at each frame's end as `gb_roms_test` does, until the result; then it runs to the frame 30 on and checks the CRC the system took.

## Status

- **Passing:** 83 test ROMs end as they do in MesenCE, with its frame (one frame not compared, above).
  - blargg's `cpu_instrs` (all 11), `instr_timing` and `mem_timing` (all 3).
  - Mooneye's CPU, interrupt, HALT, EI and DI tests, its per-instruction timing tests, all 13 of its timer tests, `bits` and `boot_regs`.
  - Mooneye's 12 PPU tests and 6 OAM DMA tests, `di_timing` and `halt_ime1_timing2`.
  - dmg-acid2.
- **Gaps:**
  - The sound (G5).
  - MBCs and cartridge RAM (G6), and with MBC1, blargg's `oam_bug` ROMs: the OAM bug (`cpu/sm83`'s README).
  - The PPU's rarer edges: the window's pixel-insertion glitch, WX=166, writes to LCDC's object bit during an object's fetch, and OAM DMA's effect on the OAM scan beyond its bus.

## References

- Pan Docs (gbdev.io/pandocs): the memory map, I/O registers, timer, serial port, joypad and OAM DMA.
- Gekkio, *Game Boy: Complete Technical Reference*: the timer's overflow and reload.
- [SameBoy](https://github.com/LIJI32/SameBoy): the serial clock's flip-flop, the PPU's dot-by-dot timing (its `display.c`), the access conflicts on the PPU's registers and when a halted CPU sees an interrupt, read for facts; its traces, run beside the sim's, found where the timing parted.
- [dmg-acid2](https://github.com/mattcurrie/dmg-acid2): the PPU's rendering, against MesenCE's frame.
- [Mooneye's test suite](https://github.com/Gekkio/mooneye-test-suite): what each test measures, read for facts.
