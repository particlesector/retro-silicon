# Atari 2600 test cartridges

Our own test cartridges for the Atari 2600, which has no public test suite like the NES's. Each is a 4 KB cartridge written in ca65 (the `bank_*` ones larger, banked by their scheme), that runs its test once from reset, then draws what it found as background colours, forever (`show.inc`): 32 result bytes, each on 6 picture lines, 3 in the byte's colour and 3 in the byte shifted left (the TIA ignores a colour's bit 0). So a frame is the result, and the core's frame must match the golden one: Stella's, except where Stella is known to part from the chip (`tia_missiles_ball`, `tia_resmp`; see `video/tia`'s README).

`make` builds them (ca65 and ld65 from cc65); `testroms/fetch.py` does it into its folder and checks each against `testroms/manifest-2600.toml`, which also has what each frame shows in Stella. Their golden frames are in `harness/golden/a2600_frames_crc32.txt` (and `tia_audio`'s sound in `harness/golden/a2600_audio_crc32.txt`), and with `video/tia`'s `SCORE_GLITCH` on in `harness/golden/a2600_score_glitch_crc32.txt`.

| Cartridge | Tests |
| --- | --- |
| `tia_colours` | Every NTSC colour, one a picture line: the palette |
| `riot_ram` | The RIOT's 128 bytes of RAM through its mirrors (`$80`, `$180`, `$480`, `$D80`) and the stack at `$1FF` |
| `riot_timer` | The interval timer at each divider: counting down, underflow, one a clock after it, the divider restored by reading `INTIM`, and `TIMINT`'s flag |
| `tia_playfield` | The playfield (normal, reflected, score, score with priority), the background and VBLANK; then writes to PF2, COLUBK, VBLANK and CTRLPF's reflection, a cycle later on each line, so each lands at every pixel phase. It draws its result rather than measuring it, so it uses neither `show.inc` nor RAM |
| `tia_players` | The players: a band per NUSIZ value (copies, double and quad width), with RESP0 landing a cycle later on each line from the blank into the picture, player 0 reflected in odd bands, and player 1 with vertical delay in bands 4-7 |
| `tia_missiles_ball` | The missiles and the ball: a band per NUSIZ value, each with its own missile and ball widths and CTRLPF priority mode, over the playfield and the players; RESM0 and RESBL land a cycle later on each line from the blank into the picture, missile 1 is placed by RESM1 or locked to player 1 by RESMP1, and the ball's vertical delay hides it in bands 5 and 7 |
| `tia_hmove` | HMOVE: the five objects in eight bands; early HMOVEs stepping each object through all 16 HM values, HMOVE written a cycle later each line from the line's start to its end, HMOVE near the line's end running on into the next, and HMCLR during the movement |
| `tia_collisions` | The collision latches and CXCLR: every pair at once, a chosen few, and the players colliding only in the horizontal blank by HMOVE; then INPT0-INPT5 and the fire buttons' latch. Results drawn by `show.inc` |
| `tia_rsync` | RSYNC written at every cycle of the line, from the blank to its last colour clock, cutting every third line short over the playfield and all five objects; its 351-line frames also have Stella's frame manager end some frames (frame 30 among them) by its line count, without VSYNC |
| `tia_resmp` | RESMP held for 15 colour clocks, a cycle later on each pair of lines, across player 1's main copy, at each width and with two copies; the line after shows whether it moved missile 1 onto the player or left it parked on the right |
| `tia_audio` | The TIA's sound, checked as Stella's samples (`harness/golden/a2600_audio_crc32.txt`): each frame, channel 0 plays the next AUDC mode (all 16 in 16 frames) at an AUDF and AUDV that change every 16 and 4 frames; channel 1's AUDV, AUDF and AUDC are toggled on every line of three bands, and one line writes RSYNC, all at a cycle that moves one later each frame (19 to 72), so the samples show the colour clock each write lands on and whether RSYNC moves the sound's clocks |
| `tia_paddles` | The paddles' inputs (INPT0-3) and VBLANK bit 7's dump, with four paddles at Stella's default knob (500 kohm): 128 frames in groups of 4, each group dumping for 27 to 58 cycles (which leaves a trace of charge that moves the crossing by a fraction of a cycle) and reading one input the 2 cycles before Stella's capacitor crosses the threshold and the 2 after, so a colour clock either way shows; and each frame reads the input before and in the dump. `tia_paddles_plan.py` plans the reads from the circuit's equations. Stella plugs in paddles because the cartridge reads an input as paddle games do (`harness/golden/a2600_paddles.txt`) |

The bank-switching cartridges are named for their scheme, as Stella takes it from the extension (`bank_f8.F8`), and the harness does too. A whole-bank one is `bank_f.s` assembled once per 4 KB bank (`-D BANK=k`, the scheme's `NB`, `HOT` and `RAM` from the Makefile), so every bank holds the same program and it runs on through a switch; only each bank's ID (`$FE00`, `$40` + its number) and the bytes at the hotspots (`$FFF0`-`$FFFB`: the bank x `$10` + the address's low nibble) differ. A sliced one (E0, 3F, E7) runs from its fixed slice and reads each other slice's ID, its first byte (`bank_id.s`). Each one's results are in its source's header and its manifest entry.

| Cartridge | Tests |
| --- | --- |
| `bank_f8`, `bank_f6`, `bank_f4` | Atari's F8, F6, F4: the bank each starts in (F8: 1), each hotspot read (getting the new bank's byte) and written |
| `bank_f8sc`, `bank_f6sc`, `bank_f4sc` | The same with the Superchip's 128 bytes of RAM: its start as 0s, written and read back, through a switch, and a write to its read port going nowhere |
| `bank_fa` | CBS's FA: 12 KB, starting in bank 2, and its 256 bytes of RAM as the Superchip's |
| `bank_f0` | Dynacom's F0: 16 banks, starting in 15, each access to `$1FF0` stepping to the next, round to 15 again |
| `bank_fe` | Activision's FE: a JSR to `$Dxxx` and an RTS with S = `$FF` switching through `$01FE`, and calls with S lower not |
| `bank_e0` | Parker Brothers' E0: every 1 KB slice into each switched slot, starting with 4, 5, 6 |
| `bank_3f` | Tigervision's 3F (16 KB): writes to `$3F` and `$3E` selecting the bank by their value modulo 8, a write to `$40` and a read of `$3F` not. It draws through the TIA's mirror at `$40`, as Tigervision's games do: Stella's 3F takes `$00`-`$3F` from the TIA |
| `bank_e7` | M Network's E7: each slice, the 1 KB RAM and the four 256-byte RAM banks, their start as 0s and a write to a read port going nowhere |

`vcs.inc` has `DELAY n`, exactly n cycles (12 at a time by calling an RTS, `wait12`, which a cartridge using it defines).

The cartridges clear RAM and set the timer before reading them, so the console's random state at power-up never shows.
