# TIA

The Atari 2600's Television Interface Adaptor (NTSC), colour-clock exact: it draws each line from its registers as the beam sweeps, with no frame buffer.

Modules `tia`, `tia_player` (each of the two players), `tia_missile` (each of the two missiles) and `tia_ball`. **In progress:** so far the line, VSYNC, VBLANK, WSYNC, the background, the playfield, the players, the missiles and the ball. HMOVE, collisions, the input ports, RSYNC and sound come next, each with a test cartridge.

## Timing

As Stella 7.0 runs it:

- **The line:** 228 colour clocks, one per `cc`: 68 of horizontal blank, then 160 pixels. A CPU cycle is 3 colour clocks; `ce` marks the one that ends it.
- **Writes** are taken with `ce` and land after that colour clock, so the next one sees them, except where the chip delays them: VBLANK, GRP0, GRP1, REFP0, REFP1, ENAM0, ENAM1 and ENABL by 1 colour clock, PF0-PF2 by 2. A second write to the playfield before the first lands replaces it.
- **WSYNC** holds `rdy` low from the write to the line's end, so the CPU's next read cycle completes as the next line's first cycle. A write in the cycle that ends a line doesn't hold it.
- **The playfield** takes a new bit every 4 pixels, and CTRLPF's reflection only at pixels 0 and 79.
- **Players:** each has a position counter, 0-159, that steps once a pixel. RESP sets it to 157 (159 in horizontal blank). A copy starts when it reaches 156, and for NUSIZ's extra copies 12, 28 or 60; the graphics follow 5 steps later, one bit a pixel, or every 2 or 4 pixels when stretched. NUSIZ or RESP during the start of a copy changes it as Andrew Towers' notes describe and Stella models. Writing GRP0 also copies player 1's graphics into its vertically delayed set, and GRP1 player 0's; VDELP picks which set a player draws.
- **Missiles and the ball:** each has its own position counter, set by RESM or RESBL as RESP sets a player's, and starts at 156 (a missile also at its player's extra copies' decodes), showing 4 steps later for 1, 2, 4 or 8 pixels (NUSIZ bits 5-4 for a missile, CTRLPF bits 5-4 for the ball). RESM during a missile's draw shifts or ends it by its width; RESBL starts the ball wherever it is; a narrower NUSIZ ends a missile already drawn that wide. RESMP hides a missile and holds it unstarted; clearing it puts the missile where its player's RESP would have. Writing GRP1 also copies ENABL into the ball's vertically delayed enable, which VDELBL picks.
- **Priority:** each missile takes its player's colour and place, the ball the playfield's colour (COLUPF, even in score mode) and place just after it: player 0, player 1, the playfield, the ball, the background. Score mode (CTRLPF bit 1, priority off) colours the playfield with COLUP0 on the left half and COLUP1 on the right and puts it between the players, with the ball after player 1; priority (bit 2) puts the playfield and ball first.
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
| `st_addr`, `st_rdata`, `st_we`, `st_wdata` | | 4, 32, 1, 32 | Save-state port (below) |

The picture outputs are registered: each describes the colour clock before.

## Registers so far

| Address | Name | |
| --- | --- | --- |
| `$00` | VSYNC | Bit 1 |
| `$01` | VBLANK | Bit 1, a colour clock late |
| `$02` | WSYNC | Holds the CPU to the line's end |
| `$06`-`$09` | COLUP0, COLUP1, COLUPF, COLUBK | Colours, bits 7-1 |
| `$0A` | CTRLPF | Bit 0 reflection, 1 score, 2 priority; bits 5-4 the ball's width |
| `$0D`-`$0F` | PF0, PF1, PF2 | The playfield: PF0 bits 7-4, PF1 bits 7-0, PF2 bits 0-7, left to right; 2 colour clocks late |
| `$04`, `$05` | NUSIZ0, NUSIZ1 | Bits 2-0: the player's and missile's copies, and the player's width; bits 5-4 the missile's width |
| `$0B`, `$0C` | REFP0, REFP1 | Bit 3 reflects the player; a colour clock late |
| `$10`, `$11` | RESP0, RESP1 | Places the player here |
| `$12`, `$13`, `$14` | RESM0, RESM1, RESBL | Places the missile or the ball here |
| `$1B`, `$1C` | GRP0, GRP1 | The players' graphics, bit 7 drawn first; a colour clock late |
| `$1D`, `$1E`, `$1F` | ENAM0, ENAM1, ENABL | Bit 1 shows the missile or the ball; a colour clock late |
| `$25`, `$26` | VDELP0, VDELP1 | Bit 0: draw the vertically delayed graphics |
| `$27` | VDELBL | Bit 0: the ball takes its vertically delayed enable |
| `$28`, `$29` | RESMP0, RESMP1 | Bit 1 hides the missile and holds it on its player; clearing it places the missile there |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `SAVE_STATE` | 1 | 0 leaves out the save-state port's logic: writes do nothing and reads give 0 |

## Save state

The port follows [docs/conventions.md](../../../docs/conventions.md): 13 words so far, as packed at the end of the RTL: 0-4 the line counter, registers, the playfield's writes waiting to land and the registered picture outputs; 5-6 player 0 and 7-8 player 1 (`tia_player`'s two words); 9 the GRP, REFP, ENAM and ENABL writes waiting to land; 10 missile 0, 11 missile 1 and 12 the ball (a word each). The words will change as the other objects arrive.

## Status

In `systems/atari-2600`'s sim, its frames match Stella's for the `tia_colours`, `riot_ram`, `riot_timer`, `tia_playfield`, `tia_players` and `tia_missiles_ball` test cartridges. `tia_playfield` moves writes to PF2, COLUBK, VBLANK and CTRLPF's reflection a cycle at a time, so it checks the colour clock each lands on; `tia_players` does the same with RESP0 for every NUSIZ, and `tia_missiles_ball` with RESM0 and RESBL for every missile and ball width, in each priority mode.

**Where Stella and the chip part:** Stella skips drawing a line that follows two lines with no TIA writes that change anything (WSYNC doesn't count): it copies the line before and doesn't step the objects. A copy straddling the start of such a line then shows where it was on the line before, while the chip, and this core, step it on. A Python port of Stella's player logic, fed the core's writes, matches the core on such lines and Stella everywhere else. The core follows the chip, and the test cartridges write the TIA on every line they draw.

## References

- Steve Wright, *Stella Programmer's Guide* (1979): the registers and what they do.
- Stella 7.0 (`src/emucore/tia`), read for the timing of each write, the playfield and the frame; nothing copied.
