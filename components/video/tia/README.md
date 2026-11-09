# TIA

The Atari 2600's Television Interface Adaptor (NTSC), colour-clock exact: it draws each line from its registers as the beam sweeps, with no frame buffer.

Modules `tia`, `tia_player` (each of the two players), `tia_missile` (each of the two missiles) and `tia_ball`. **In progress:** so far the line, VSYNC, VBLANK, WSYNC, the background, the playfield, the players, the missiles, the ball, HMOVE, collisions, the fire buttons' input ports and RSYNC. The paddles' ports and sound come next, each with a test cartridge.

## What it draws, and why the names sound like one game

The TIA has no frame buffer: the 2600 has 128 bytes of RAM in all, far too little to hold a picture. Instead the chip draws each line as the TV's beam crosses the screen, from a handful of registers, and it can draw only six things: a playfield and five small movable objects. Their names, players, missiles and a ball, come from the games the chip was built for. In 1975-76 Atari wanted one console that could run home versions of its arcade *Tank* (two tanks, each firing shells) and *Pong* (two paddles and a ball), instead of one custom chip per game as its earlier home *Pong* had used. Joe Decuir designed the system around it, and Jay Miner led the design of the TIA. Two tanks, two shells and a ball became two players, two missiles and a ball, and *Tank* grew into *Combat*, the console's first pack-in game.

The names stuck in Atari's own documentation, Steve Wright's *Stella Programmer's Guide*, but the objects aren't tied to any game. Each is general-purpose drawing hardware: a shape, a position on the line, a width and a colour. A game is free to use any of them for anything, or not at all, and it can change them on every line as the beam goes down. So this component models them as the chip has them, under the chip's names, and every game uses the same objects in its own way.

| Object | What the chip gives it | What games use it for |
| --- | --- | --- |
| Playfield | 40 blocks across the line (20 bits, repeated or mirrored on the right half), in one colour, rewritable each line | Walls, mazes, ground and sky, large blocky shapes; in score mode each half takes a player's colour, for two scores side by side |
| Players (2) | 8 pixels of graphics, each 1, 2 or 4 pixels wide, mirrorable, in up to three copies spaced across the line; vertical delay to update both players on alternate lines | Any character or sprite: a hero, an enemy, a car, a letter. Copies give rows of enemies from one object; both players' copies side by side, rewritten mid-line, make 48-pixel-wide text and scores |
| Missiles (2) | A line 1, 2, 4 or 8 pixels wide, in its player's colour, following its player's copies; RESMP centres it on its player | Bullets and shells, but also any thin bar or detail drawn in a player's colour |
| Ball | Like a missile, but in the playfield's colour, with vertical delay | A ball, or anything else that should match the playfield: a cursor, a wall piece, an extra bullet |
| Background | One colour behind everything | Sky, floor or space; changed per line for colour bands |

Beyond that the chip finds, for every pair of the six, whether they ever drew the same pixel (the 15 collision latches), so a game can tell a shell hit a tank or a ball hit a wall without working it out itself. A game that needs more moving things than five draws different ones on alternate frames, which is the flicker many 2600 games show, or moves the same object to a new place further down the screen.

## Timing

As Stella 7.0 runs it:

- **The line:** 228 colour clocks, one per `cc`: 68 of horizontal blank, then 160 pixels. A CPU cycle is 3 colour clocks; `ce` marks the one that ends it.
- **Writes** are taken with `ce` and land after that colour clock, so the next one sees them, except where the chip delays them: VBLANK, GRP0, GRP1, REFP0, REFP1, ENAM0, ENAM1 and ENABL by 1 colour clock, PF0-PF2 and HMP0-HMCLR by 2, HMOVE by 6. A second write to the playfield before the first lands replaces it.
- **WSYNC** holds `rdy` low from the write to the line's end, so the CPU's next read cycle completes as the next line's first cycle. A write in the cycle that ends a line doesn't hold it.
- **The playfield** takes a new bit every 4 pixels, and CTRLPF's reflection only at pixels 0 and 79.
- **Players:** each has a position counter, 0-159, that steps once a pixel. RESP sets it to 157 (159 in horizontal blank). A copy starts when it reaches 156, and for NUSIZ's extra copies 12, 28 or 60; the graphics follow 5 steps later, one bit a pixel, or every 2 or 4 pixels when stretched. NUSIZ or RESP during the start of a copy changes it as Andrew Towers' notes describe and Stella models. Writing GRP0 also copies player 1's graphics into its vertically delayed set, and GRP1 player 0's; VDELP picks which set a player draws.
- **Missiles and the ball:** each has its own position counter, set by RESM or RESBL as RESP sets a player's, and starts at 156 (a missile also at its player's extra copies' decodes), showing 4 steps later for 1, 2, 4 or 8 pixels (NUSIZ bits 5-4 for a missile, CTRLPF bits 5-4 for the ball). RESM during a missile's draw shifts or ends it by its width; RESBL starts the ball wherever it is; a narrower NUSIZ ends a missile already drawn that wide. RESMP hides a missile; while it's set, each time its player's main copy reaches its sixth pixel (double width: the fourth pixel's second half; quad: the third's last quarter) the missile is put where its player's RESP would have, and clearing it leaves the missile where that last put it. The missile's copies still start and run while it's hidden, so a copy that started under RESMP shows the pixels drawn after the release. Writing GRP1 also copies ENABL into the ball's vertically delayed enable, which VDELBL picks.
- **HMOVE** starts a movement clock that steps every 4 colour clocks (on those 0 mod 4 in the line). Each object keeps moving until the step count equals its HM value's count ((HM >> 4) XOR 8, so 0-15, which is why HM 0 means no move), with an extra tick on each step while the TIA is in horizontal blank; a count it has already passed (an HM write during the movement) keeps it moving, a tick in every blank, until the next HMOVE. An HMOVE landing in the blank before colour clock 68 extends the blank to 76: those 8 pixels (the "comb") are colour 0 and the objects don't tick on them. While a missile or the ball is still moving, its pixel ticks change its start and width by the colour clock's phase, as Stella's "starfield" model has it.
- **Collisions:** checked on every picture colour clock, and in horizontal blank only on HMOVE's movement steps (while something still moves) or on the colour clock after an object's graphics or enable changed, never under VBLANK. Each check uses the objects' collision states as Stella keeps them: from their last tick, worked out again at each line's end, and when their graphics or enable change; the playfield's ends with each line. So two objects drawn across a line's end collide in the next line's blank if an HMOVE runs there. A read sees its own colour clock's check; CXCLR clears the latches after it.
- **RSYNC** sets the line's counter to 225, so the line ends 3 colour clocks after the write. If those are in the picture they draw on from the column the line had reached (the objects tick on them), and the line's other columns stay undrawn: a line's undrawn columns are black, as Stella clears them. The objects miss the rest of the line's ticks.
- **Input ports:** INPT4 and INPT5 read the fire buttons' pins (`fire_n`, 0 pressed). With VBLANK bit 6 set they latch: a press reads 0 until bit 6 is cleared. The latch catches every press, as the chip's does (Stella's catches a press only when the port is read; with a button held still the two agree). INPT0-INPT3 read 0, the paddles' ports with nothing connected, as Stella's joystick leaves them; VBLANK bit 7's dump comes with the paddles.
- **Priority:** each missile takes its player's colour and place, the ball the playfield's colour (COLUPF, even in score mode) and place just after it: player 0, player 1, the playfield, the ball, the background. Score mode (CTRLPF bit 1, priority off) colours the playfield with COLUP0 on the left half and COLUP1 on the right and puts it between the players, with the ball after player 1; priority (bit 2) puts the playfield and ball first.
- **VBLANK** blanks the picture to colour 0.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset: the line at colour clock 0, registers 0 |
| `cc` | in | 1 | One colour clock |
| `ce` | in | 1 | This colour clock ends a CPU cycle (with `cc`) |
| `cs`, `addr`, `we`, `din` | in | 1, 6, 1, 8 | The cycle's access: writes by A5-A0 |
| `dout` | out | 8 | Read data by A3-A0 (below), in bits 7-6; a system keeps its bus's last value in bits 5-0 |
| `rdy` | out | 1 | Low while WSYNC holds the CPU |
| `fire_n` | in | 2 | INPT4's and INPT5's pins: player 0's and player 1's fire buttons, 0 pressed |
| `pix` | out | 8 | The colour clock's colour value (bit 0 clear); 0 in horizontal blank and VBLANK |
| `pix_on`, `x` | out | 1, 8 | It draws one of the 160 pixels, and its column. Every line draws all 160 (the HMOVE comb's as colour 0), except one RSYNC cuts short, whose undrawn columns are black |
| `line_end` | out | 1 | It was the line's last colour clock |
| `vsync`, `vblank` | out | 1 | VSYNC's bit 1; VBLANK's bit 1 as the picture sees it |
| `st_addr`, `st_rdata`, `st_we`, `st_wdata` | | 4, 32, 1, 32 | Save-state port (below) |

The picture outputs are registered: each describes the colour clock before.

## Registers so far

| Address | Name | |
| --- | --- | --- |
| `$00` | VSYNC | Bit 1 |
| `$01` | VBLANK | Bit 1, a colour clock late; bit 6 latches INPT4 and INPT5 |
| `$02` | WSYNC | Holds the CPU to the line's end |
| `$03` | RSYNC | Ends the line 3 colour clocks later |
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
| `$28`, `$29` | RESMP0, RESMP1 | Bit 1 hides the missile and keeps putting it on its player as the player's main copy passes its middle; clearing it leaves the missile there |
| `$20`-`$24` | HMP0, HMP1, HMM0, HMM1, HMBL | Bits 7-4: the object's next move, -8 to 7 pixels right; 2 colour clocks late |
| `$2A` | HMOVE | Moves the objects; 6 colour clocks late |
| `$2B` | HMCLR | Sets every HM to 0; 2 colour clocks late |
| `$2C` | CXCLR | Clears the collision latches |

Reads, by A3-A0, in bits 7 and 6:

| Address | Name | Bit 7, bit 6 |
| --- | --- | --- |
| `$0` | CXM0P | M0-P1, M0-P0 |
| `$1` | CXM1P | M1-P0, M1-P1 |
| `$2` | CXP0FB | P0-PF, P0-BL |
| `$3` | CXP1FB | P1-PF, P1-BL |
| `$4` | CXM0FB | M0-PF, M0-BL |
| `$5` | CXM1FB | M1-PF, M1-BL |
| `$6` | CXBLPF | BL-PF, 0 |
| `$7` | CXPPMM | P0-P1, M0-M1 |
| `$8`-`$B` | INPT0-INPT3 | 0 (no paddles yet), 0 |
| `$C`, `$D` | INPT4, INPT5 | The fire button (1 up), 0 |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `SAVE_STATE` | 1 | 0 leaves out the save-state port's logic: writes do nothing and reads give 0 |

## Save state

The port follows [docs/conventions.md](../../../docs/conventions.md): 13 words so far, as packed at the end of the RTL: 0-4 the line counter, registers, the playfield's writes waiting to land, the registered picture outputs and RSYNC's jump; 5-6 player 0 and 7-8 player 1 (`tia_player`'s two words); 9 the GRP, REFP, ENAM and ENABL writes waiting to land; 10 missile 0, 11 missile 1 and 12 the ball (a word each); 13 the blank, HMOVE and HM writes on their way and the movement clock; 14 the HM values and which objects are moving; 15 the collision latches, the playfield's collision state and the fire buttons' latch. The words will change as the other objects arrive.

## Status

In `systems/atari-2600`'s sim, its frames match the golden frames of the `tia_colours`, `riot_ram`, `riot_timer`, `tia_playfield`, `tia_players`, `tia_missiles_ball`, `tia_hmove`, `tia_collisions`, `tia_rsync` and `tia_resmp` test cartridges: Stella's, but for `tia_missiles_ball` and `tia_resmp` (below). `tia_playfield` moves writes to PF2, COLUBK, VBLANK and CTRLPF's reflection a cycle at a time, so it checks the colour clock each lands on; `tia_players` does the same with RESP0 for every NUSIZ, `tia_missiles_ball` with RESM0 and RESBL for every missile and ball width, in each priority mode, `tia_hmove` with HMOVE itself, at every cycle of the line, `tia_collisions` reads the latches and input ports after drawing chosen overlaps, and `tia_rsync` cuts lines short at every cycle; `tia_resmp` holds RESMP for 15 colour clocks at every cycle across a player's main copy, at each width.

**Where Stella and the chip part:**

- **RESMP:** Stella moves the missile onto its player when RESMP is cleared, and doesn't start its copies while it's set. The chip resets the missile's position from the player's main copy, at the point above, for as long as RESMP is set, and only hides its pixels. They agree when RESMP is held through that point, as games hold it, and part when it's held briefly. The TIA's transistor-level netlist (Visual6502.org's, of the 10444D die) and Gopher2600 both do what the chip does, and so does this core: the golden frames of `tia_missiles_ball` (band 2's brief RESMP1) and `tia_resmp` are Gopher2600's, which match Stella's everywhere else (`testroms/manifest-2600.toml` keeps Stella's CRC beside each, and `tools/stella/frames.py` checks it still holds).
- **Lines without writes:** Stella skips drawing a line that follows two lines with no TIA writes that change anything (WSYNC doesn't count): it copies the line before and doesn't step the objects. A copy straddling the start of such a line then shows where it was on the line before, while the chip, and this core, step it on. A Python port of Stella's player logic, fed the core's writes, matches the core on such lines and Stella everywhere else. The core follows the chip, and the test cartridges write the TIA on every line they draw.

## References

- Steve Wright, *Stella Programmer's Guide* (1979): the registers and what they do, and the objects' names.
- Joe Decuir and others, ["Inventing the Atari 2600"](https://spectrum.ieee.org/atari-2600), IEEE Spectrum: the console built to run *Tank* and *Pong*.
- Stella 7.0 (`src/emucore/tia`), read for the timing of each write, the playfield and the frame; nothing copied.
- Gopher2600 0.57.2 (`hardware/tia/video`), read for RESMP's reset point; nothing copied.
- The TIA's transistor-level netlist from Visual6502.org (in Greg James's Sim2600), simulated as a second check of the test cartridges.
