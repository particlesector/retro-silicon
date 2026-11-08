# Atari 2600 test cartridges

Our own test cartridges for the Atari 2600, which has no public test suite like the NES's. Each is a 4 KB cartridge written in ca65, that runs its test once from reset, then draws what it found as background colours, forever (`show.inc`): 32 result bytes, each on 6 picture lines, 3 in the byte's colour and 3 in the byte shifted left (the TIA ignores a colour's bit 0). So a frame is the result, and the core's frame must match Stella's.

`make` builds them (ca65 and ld65 from cc65); `testroms/fetch.py` does it into its folder and checks each against `testroms/manifest-2600.toml`, which also has what each frame shows in Stella. Their golden frames are in `harness/golden/a2600_frames_crc32.txt`.

| Cartridge | Tests |
| --- | --- |
| `tia_colours` | Every NTSC colour, one a picture line: the palette |
| `riot_ram` | The RIOT's 128 bytes of RAM through its mirrors (`$80`, `$180`, `$480`, `$D80`) and the stack at `$1FF` |
| `riot_timer` | The interval timer at each divider: counting down, underflow, one a clock after it, the divider restored by reading `INTIM`, and `TIMINT`'s flag |

The cartridges clear RAM and set the timer before reading them, so the console's random state at power-up never shows.
