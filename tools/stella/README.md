# Stella tools

The Atari 2600's reference is [Stella](https://github.com/stella-emu/stella), run headless through its libretro core, as the NES's is MesenCE.

- `stella-frames` (`stella_frames.cpp`) runs a cartridge from power-up and prints each chosen frame's CRC-32 as TIA colour values: 160 x 228 bytes, from the 23rd line after VSYNC ends (Stella's NTSC window), each the colour register's value. It learns the core's palette from a colour-bar cartridge of its own, so no palette is copied here. `--dump DIR` writes the frame's bytes (`.tia`) and a picture (`.ppm`). Phosphor blending is off for every cartridge, including those Stella's database turns it on for: the core applies the option only when it changes after the game is loaded, so `stella-frames` changes it then.
- `stella-frames --input F:JJCC,...` plays an input script, as the harness's 2600 input player does: from frame F on, SWCHA's pins JJ and SWCHB's CC, with the fire buttons in CC's bits 4 and 5, in hex (0 pressed). Stella takes input once a frame, before running it, from the libretro joypads: each player's joystick on its port, fire on B, and the console's switches on port 0's Start, Select, L/L2, R/R2 and L3/R3. Its joystick can't press opposite directions at once, so a script shouldn't either.
- `frames.py` runs every cartridge in `testroms/manifest-2600.toml` with `check = "frame"` and writes `harness/golden/a2600_frames_crc32.txt`; with them `a2600_score_glitch_crc32.txt`, `a2600_audio_crc32.txt` (Stella's sound, from a core with the rig's audio hook) and `a2600_paddles.txt` (the paddles Stella plugs in, from each cartridge's `paddles`).

## Building the core

Stella 7.0's source (the `7.0` tag), then:

```sh
make -C src/os/libretro
mkdir -p $RS_STELLA_DIR/lib $RS_STELLA_DIR/include
cp src/os/libretro/stella_libretro.so $RS_STELLA_DIR/lib/
cp src/os/libretro/libretro.h $RS_STELLA_DIR/include/
```

With `RS_STELLA_DIR` set (in the environment or CMake's cache), the CMake build makes `stella-frames`.

Stella starts RAM, the CPU's registers and the RIOT's timer at random, seeded from the clock. The test cartridges set everything they read, so their frames don't depend on it, and an unmodified core gives the golden frames. A core patched to start from zeros and to seed the rest from `RS_STELLA_SEED` (`stella-frames --seed`) makes any cartridge repeatable.
