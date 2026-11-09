# Atari 2600 test cartridges

Our own test cartridges for the Atari 2600, which has no public test suite like the NES's. Each is a 4 KB cartridge written in ca65, that runs its test once from reset, then draws what it found as background colours, forever (`show.inc`): 32 result bytes, each on 6 picture lines, 3 in the byte's colour and 3 in the byte shifted left (the TIA ignores a colour's bit 0). So a frame is the result, and the core's frame must match the golden one: Stella's, except where Stella is known to part from the chip (`tia_missiles_ball`, `tia_resmp`; see `video/tia`'s README).

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

`vcs.inc` has `DELAY n`, exactly n cycles (12 at a time by calling an RTS, `wait12`, which a cartridge using it defines).

The cartridges clear RAM and set the timer before reading them, so the console's random state at power-up never shows.
| `tia_resmp` | RESMP held for 15 colour clocks, a cycle later on each pair of lines, across player 1's main copy, at each width and with two copies; the line after shows whether it moved missile 1 onto the player or left it parked on the right |
| `tia_audio` | The TIA's sound, checked as Stella's samples (`harness/golden/a2600_audio_crc32.txt`): each frame, channel 0 plays the next AUDC mode (all 16 in 16 frames) at an AUDF and AUDV that change every 16 and 4 frames; channel 1's AUDV, AUDF and AUDC are toggled on every line of three bands, and one line writes RSYNC, all at a cycle that moves one later each frame (19 to 72), so the samples show the colour clock each write lands on and whether RSYNC moves the sound's clocks |
