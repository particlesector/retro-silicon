# ppu-2c02

The NES's 2C02 picture processing unit (NTSC), dot-exact: 341 dots by 262 lines, with background and sprite rendering, scrolling, the palette, VBL and NMI, sprite 0 hit, and sprite overflow with its hardware bug. Its timing follows the 2C02 as [MesenCE](https://github.com/nesdev-org/MesenCE) models it, so its frames match MesenCE's pixel for pixel; that is how it's tested.

Module `ppu_2c02` (the folder name can't start a module name), and `ppu_2c02_rgb`, the 2C02's 512 colours ({emphasis, colour}) as 24-bit RGB, registered: a ROM that `tools/gen_rgb.py` generates by simulating the 2C02's composite signal (its measured voltage levels, 12 phases of the colour subcarrier, and the emphasis bits' attenuation) and decoding it as an NTSC TV does. It's the PPU's colours, not any emulator's palette; a test checks the RTL matches the script, and `gen_rgb.py --png` draws it.

## Timing

- **Dots:** one per clock with `ce` high. After reset the PPU sits at line 261, dot 340, so its first dot is line 0, dot 0. Lines 0-239 are visible, 240 is post-render, 241-260 vertical blank, 261 pre-render. With rendering on, odd frames skip the pre-render line's last dot.
- **The next dot, registered:** the PPU computes everything the next dot changes on every clock and registers it, and `ce` commits that copy. So the dot logic gets the clocks between dots, not one: `ce` must come at least 2 clocks apart, with the PPU's inputs settled on the clock before each `ce` (no `reg_ce` or `st_we` on it or on the `ce` clock, and `vrdata` already as it will be).
- **CPU registers:** one access per `reg_ce` strobe, between dots (never on a `ce` clock or the clock before). A read's data is on `reg_rdata` from the clock after the strobe. In a CPU cycle of three dots, MesenCE puts the access after the second dot; `systems/nes` does the same.
- **Video memory:** `vaddr`, `vwe` and `vwdata` change only on `ce` clocks and hold until the next. The memory must answer the address presented since the last dot on `vrdata` from the clock before the next `ce` through that `ce`, and perform a write once, before then. The PPU presents each fetch's address a dot early, so every read of a dot lands. At dot 0 of a visible line (not line 0 after the odd frame's skipped dot) the address is the pattern address of the nametable byte fetched at dot 339, as MesenCE's PPU puts on its bus: a mapper watching A12, like the MMC3, sees it rise there when the background is at `$1000`.
- **Pixels:** pixel x of a line comes out two dots after it's drawn, on a one-clock `pix_valid` pulse. That's when grayscale and emphasis apply, so a $2001 write changes the two pixels before it, as on the 2C02. `pix` is {emphasis blue, green, red, colour}: the index into a 512-entry palette.
- **Register effects, as on the 2C02:** $2006's second write reaches the address 3 dots later; a $2007 read fills the read buffer, and a $2007 write lands, 5 dots after the access, and the address increments a dot after that. A $2007 read within 6 dots of the last one is ignored. Rendering turns on and off 1 dot after a $2001 write for fetching, and 2 dots after for the scroll counters. Reading $2002 one dot before VBL sets suppresses that frame's VBL flag and NMI.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset to the power-up state |
| `ce` | in | 1 | One dot |
| `reg_ce`, `reg_we`, `reg_addr`, `reg_wdata` | in | 1, 1, 3, 8 | A register access ($2000 + `reg_addr`) |
| `reg_rdata` | out | 8 | The last read's data |
| `nmi_n` | out | 1 | NMI, active low: VBL and PPUCTRL bit 7 |
| `vaddr`, `vwe`, `vwdata` | out | 14, 1, 8 | Video memory address ($0000-$3FFF) and write |
| `vaddr_next` | out | 14 | The address `vaddr` takes at the next `ce`; final for a pattern fetch or $2007 read from the second clock after a `ce` |
| `vread_next` | out | 1 | The next dot's read is a pattern fetch or a $2007 read: the only reads of $0000-$1FFF whose data the PPU uses |
| `vrdata` | in | 8 | Video memory read data |
| `pix_valid`, `pix`, `pix_x`, `pix_y` | out | 1, 9, 8, 8 | A pixel |
| `frame_end` | out | 1 | One-clock pulse at line 240, dot 0 |
| `dbg_line`, `dbg_dot` | out | 9 | The position: the dot last run |
| `st_addr`, `st_rdata`, `st_we`, `st_wdata` | | 7, 32, 1, 32 | Save-state port (below) |

The palette, OAM and secondary OAM are inside the PPU; the pattern tables and nametables are outside, on the video memory port.

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `OPEN_BUS_DECAY` | 3 | Frames before an open-bus bit that nothing refreshes reads 0 (1-6). MesenCE uses 3; real 2C02s are said to decay faster |
| `SAVE_STATE` | 1 | 0 leaves out the save-state port's logic, all but OAM's writes (a system clears OAM through them at power-up): other writes do nothing and reads give 0. For a board short of logic: the port costs about 2,000 LUTs on a GW2A |

## Save state

The port follows [docs/conventions.md](../../../docs/conventions.md): 101 words, every register, pipeline stage and internal memory.

| Words | Holds |
| --- | --- |
| 0-63 | OAM, 4 bytes a word, byte 0 in bits 7-0 |
| 64-71 | Palette RAM, likewise |
| 72-79 | Secondary OAM, likewise |
| 80-87 | The 8 sprite units: pattern low, pattern high, X, then valid, priority and palette |
| 88-100 | Registers and pipeline, packed as listed at the end of the RTL |

OAM has no reset, as on the chip: a system clears it through this port at power-up if it wants it clear.

## Status

Unit tests: frame length with and without rendering (the odd frame's skipped dot), VBL set and clear times, NMI and its suppression, $2007's buffer, palette mirrors and increment, a background tile with fine X scroll, sprite 0 hit's first dot, and a save-state round trip mid-frame with rendering and register writes going on.

In `systems/nes`, 42 test ROMs pass and their frames match MesenCE's (`harness/golden/nes_frames_crc32.txt`), in the sim and on a Tang Nano 20K: blargg's `ppu_vbl_nmi` (all 10), `ppu_open_bus`, `oam_read`, the 2005 sprite hit (11), sprite overflow (5), VBL/NMI timing (7) and PPU (5) tests, `nmi_sync`'s demo and `full_palette`.

Planted bugs the ROMs catch: sprite 0 hit allowed at X = 255, VBL set a dot late, no odd-frame skipped dot, sprite overflow evaluation without its hardware bug, and palette writes to `$3F10` that don't reach `$3F00`.

Not modelled yet: OAM decay and the row-corruption glitches MesenCE has off by default; the 2C02E's OAM corruption at the pre-render line when OAMADDR isn't 0; sprites on line 0 after an odd frame's skipped dot (MesenCE shifts them a pixel); and sprite units that pause when rendering is turned off mid-line (here they're compared by X). PAL and the arcade PPUs aren't parameters yet.

About 5,800 LUTs, 450 ALU cells and 1,170 flip-flops on a GW2A-18C by Yosys's count, plus 337 flip-flops for the registered next dot; OAM in 66 LUT RAMs. Registering the next dot took the Tang Console 138K's NES build from 49 MHz to 65-72 MHz, and the Tang Nano 20K's from 45 to 70 MHz. Not optimised yet.

In `systems/nes` on a Tang Console 138K at 50 MHz, too, the same 42 test ROMs pass with MesenCE's frames. Planted bug the ROMs catch: `ce` a clock after the memory read instead of two, so the next dot settles on the byte before.

## References

- NESdev wiki: *PPU rendering*, *PPU scrolling*, *PPU sprite evaluation*, *PPU registers*, *PPU frame timing*.
- [MesenCE](https://github.com/nesdev-org/MesenCE)'s `NesPpu.cpp`: the timing it reproduces, read for behaviour; no code is taken from it.
