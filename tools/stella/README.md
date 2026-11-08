# Stella tools

The Atari 2600's reference is [Stella](https://github.com/stella-emu/stella), run headless through its libretro core, as the NES's is MesenCE.

- `stella-frames` (`stella_frames.cpp`) runs a cartridge from power-up and prints each chosen frame's CRC-32 as TIA colour values: 160 x 228 bytes, from the 23rd line after VSYNC ends (Stella's NTSC window), each the colour register's value. It learns the core's palette from a colour-bar cartridge of its own, so no palette is copied here. `--dump DIR` writes the frame's bytes (`.tia`) and a picture (`.ppm`).
- `frames.py` runs every cartridge in `testroms/manifest-2600.toml` with `check = "frame"` and writes `harness/golden/a2600_frames_crc32.txt`.

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
