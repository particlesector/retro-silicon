# TIA

The Atari 2600's Television Interface Adaptor (NTSC), colour-clock exact: it draws each line from its registers as the beam sweeps, with no frame buffer.

Module `tia`. **In progress:** this first part has the line, VSYNC, VBLANK, WSYNC, the background and the playfield. Players, missiles, the ball, HMOVE, collisions, the input ports, RSYNC and sound come next, each with a test cartridge.

## Timing

As Stella 7.0 runs it:

- **The line:** 228 colour clocks, one per `cc`: 68 of horizontal blank, then 160 pixels. A CPU cycle is 3 colour clocks; `ce` marks the one that ends it.
- **Writes** are taken with `ce` and land after that colour clock, so the next one sees them, except where the chip delays them: VBLANK by 1 colour clock, PF0-PF2 by 2. A second write to the playfield before the first lands replaces it.
- **WSYNC** holds `rdy` low from the write to the line's end, so the CPU's next read cycle completes as the next line's first cycle. A write in the cycle that ends a line doesn't hold it.
- **The playfield** takes a new bit every 4 pixels, and CTRLPF's reflection only at pixels 0 and 79.
- **Score mode** (CTRLPF bit 1) colours the playfield with COLUP0 on the left half and COLUP1 on the right, unless priority (bit 2) is on.
- **VBLANK** blanks the picture to colour 0.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset: the line at colour clock 0, registers 0 |
| `cc` | in | 1 | One colour clock |
| `ce` | in | 1 | This colour clock ends a CPU cycle (with `cc`) |
| `cs`, `addr`, `we`, `din` | in | 1, 6, 1, 8 | The cycle's access: writes by A5-A0 |
| `dout` | out | 8 | Read data in bits 7-6 (0 so far); a system keeps its bus's last value in bits 5-0 |
| `rdy` | out | 1 | Low while WSYNC holds the CPU |
| `pix` | out | 8 | The colour clock's colour value (bit 0 clear); 0 in horizontal blank and VBLANK |
| `pix_on`, `x` | out | 1, 8 | It's one of the 160 pixels, and its column |
| `line_end` | out | 1 | It was the line's last colour clock |
| `vsync`, `vblank` | out | 1 | VSYNC's bit 1; VBLANK's bit 1 as the picture sees it |
| `st_addr`, `st_rdata`, `st_we`, `st_wdata` | | 5, 32, 1, 32 | Save-state port (below) |

The picture outputs are registered: each describes the colour clock before.

## Registers so far

| Address | Name | |
| --- | --- | --- |
| `$00` | VSYNC | Bit 1 |
| `$01` | VBLANK | Bit 1, a colour clock late |
| `$02` | WSYNC | Holds the CPU to the line's end |
| `$06`-`$09` | COLUP0, COLUP1, COLUPF, COLUBK | Colours, bits 7-1 |
| `$0A` | CTRLPF | Bit 0 reflection, 1 score, 2 priority |
| `$0D`-`$0F` | PF0, PF1, PF2 | The playfield: PF0 bits 7-4, PF1 bits 7-0, PF2 bits 0-7, left to right; 2 colour clocks late |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `SAVE_STATE` | 1 | 0 leaves out the save-state port's logic: writes do nothing and reads give 0 |

## Save state

The port follows [docs/conventions.md](../../../docs/conventions.md): 5 words so far, the line counter, registers, writes waiting to land and the registered picture outputs, as packed at the end of the RTL. The words will change as the objects arrive.

## Status

In `systems/atari-2600`'s sim, its frames match Stella's for the `tia_colours`, `riot_ram`, `riot_timer` and `tia_playfield` test cartridges. `tia_playfield` moves writes to PF2, COLUBK, VBLANK and CTRLPF's reflection a cycle at a time, so it checks the colour clock each lands on.

## References

- Steve Wright, *Stella Programmer's Guide* (1979): the registers and what they do.
- Stella 7.0 (`src/emucore/tia`), read for the timing of each write, the playfield and the frame; nothing copied.
