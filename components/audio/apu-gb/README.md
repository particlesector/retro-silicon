# apu-gb

The Game Boy's audio processing unit, the DMG's by default: two pulse channels (the first with a frequency sweep), the wave channel playing 32 4-bit samples from wave RAM, the noise channel's LFSR, their length counters and volume envelopes, the frame sequencer that clocks those, and the registers at `$FF10-$FF3F`. It outputs each channel's 4-bit level and its DAC's state, and the two mixes NR50 and NR51 make of them. Its timing follows [SameBoy](https://github.com/LIJI32/SameBoy)'s model of the DMG (read for facts), checked M-cycle by M-cycle against SameBoy's own (below). The Game Boy Advance has the same four channels, so it can use this too.

Module `apu_gb`.

## Timing

- **Ticks:** the APU runs on 2 MHz ticks (`t2`, every other T-cycle). A pulse channel's frequency timer counts two ticks a duty step, so a step every 4 x (2048 - frequency) T-cycles; the wave channel's one a sample, every 2 x (2048 - frequency); the noise channel's counter counts its divisor in ticks (2 for divisor 0, else 4 x the divisor) and the LFSR shifts as NR43's bit of the counter rises.
- **Frame sequencer:** steps on `fs`, the system counter's bit 12 falling (512 Hz, or sooner when a DIV write clears it). The lengths count on its odd steps, the sweep on steps 3 and 7. An envelope counts its period on step 7; one whose count has run out reloads it on `fs_rise` (the same bit rising, half a step on) and changes its volume on the next step. Powering on while the bit is set skips the next `fs`.
- **Writes:** `wr` lands on its own clock, never with `t2` or `fs`. In `systems/game-boy` the ticks are each M-cycle's first and third T-cycles, the CPU's reads its last, and its writes its end.
- **Trigger delays:** a pulse channel's timer starts late by 3 M-cycles on a trigger (2 if it was playing), the wave channel's by 3 ticks; a noise trigger off the 1 MHz phase waits 6 ticks, and the noise counter's first step depends on its divisor and whether it was counting, as SameBoy has it.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset (the APU off, its registers and wave RAM 0) |
| `cgb` | in | 1 | Steady from reset. 0, the DMG's quirks: the length counters take writes while the APU is off and keep them through power-on; wave RAM is reachable while the wave channel plays only in the tick it read a byte (else reads give `$FF` and writes are lost); retriggering the wave channel as it reads copies the bytes it was about to read over wave RAM's first; a pulse channel's timer runs on after its length or sweep stops it, until its DAC goes off; the noise counter counts on after its channel stops, and its LFSR takes its feedback as the counter's bit falls; a noise trigger off the 1 MHz phase waits. 1, the Game Boy Color's: none of those (a port since 0.2.0, the `CGB` parameter before, so one build can be either) |
| `t2` | in | 1 | A 2 MHz tick |
| `fs`, `fs_rise` | in | 1 | The system counter's bit 12 falls, or rises |
| `div_b12` | in | 1 | That bit now |
| `wr`, `sel`, `wdata` | in | 1, 6, 8 | A CPU write to `$FF10 + sel` lands |
| `rsel`, `rdata` | in, out | 6, 8 | The register at `$FF10 + rsel` as the CPU reads it now: unreadable bits as 1, NR52's channel bits whether each plays |
| `levels` | out | 16 | Each channel's digital level, channel 4 in the top nibble; 0 when it isn't playing |
| `dac` | out | 4 | Each channel's DAC is on |
| `nr50`, `nr51` | out | 8 | The volume and panning registers |
| `mix_l`, `mix_r` | out | 10 | The mixes, signed: each DAC's output (15 - 2 x level when on, else 0: Pan Docs has digital 0 as analog 1, 15 as -1) where NR51 pans it, times NR50's volume plus 1. -480 to 480 |

## Board notes

- **Tang Nano 20K: no DSP multiply.** The mixes were first `sum x (volume + 1)`, which Yosys mapped to two of the GW2A's `MULT9X9` blocks, signed. On the chip one product came out wrong in `dmg_sound-01`: -1 x 7 gave 505, -7 with its bit 9 lost, while -15 x 8 elsewhere was right, so its sound's CRC wasn't the sim's. The netlist looked right (both operands signed, the low 10 bits taken), so the fault is in the open toolchain's packing of the block's signed mode, or the block itself. The volume is 1 to 8, so the product is now the sum plus up to three shifted copies of it: adders only, on every board. Found by stopping the 20K at T-cycles a binary search chose, comparing its sound's CRC with the sim's, then finding the pair of mixes that gave its CRC at the first M-cycle that differed.

## What it leaves out

SameBoy models more of the DMG than this does, none of it needed by blargg's `dmg_sound` or, so far, any test here:

- the "zombie mode" volume changes when NRx2 is written while a channel plays;
- the sweep's calculation delay and the NR10 write glitches around it;
- NR43 writes as the noise counter reloads, and the noise LFSR's other glitches;
- the analogue side: the DACs' discharge when turned off, and the high-pass filter (the system's `audio/resampler` has its own);
- the Color's PCM12 and PCM34 registers and its double speed.

<!-- size and speed: tools/timing/report.py --readmes writes this section -->
## Size and speed

Each top module placed alone by `tools/timing/report.py` (see `docs/timing.md` for how to read it): its fastest clock and its logic, in LUT4s and ALUs on the Gowin parts, LUT6s on the XC7Z020, and 18 Kbit block RAMs.

| Module | Tang Nano 20K (GW2A-18C) | Tang Console 138K (GW5AST-138C) | PYNQ-Z2 (XC7Z020) |
| --- | --- | --- | --- |
| `apu_gb` | 118 MHz, 2292 LUTs, 2 DSP | 163 MHz, 2303 LUTs | 97 MHz, 1770 LUTs, 2 DSP |

Measured with the mixes multiplied; they're now added (see Board notes), so the DSP blocks are gone and the counts above are a little low. The next `report.py` run will update them.

<!-- end of size and speed -->

## Status

Sim tests (`sim/apu_gb_test.cpp`):

- each register reads back with its unreadable bits as 1, and `$FF27-$FF2F` read `$FF`;
- powering off clears every register but wave RAM, and writes are lost while off;
- a pulse channel's period is 4 x (2048 - frequency) x 8 T-cycles;
- a length counter stops its channel after its count;
- the wave channel plays wave RAM's nibbles from the first byte's low one, and reads `$FF` from wave RAM between its reads;
- the noise LFSR repeats every 32,767 steps, or 127 narrow.

In `systems/game-boy`, all 12 of blargg's `dmg_sound` ROMs pass with MesenCE's frames, and every ROM's sound has the sim's CRC (`harness/golden/gb_audio_crc32.txt`).

Against SameBoy 1.0.5 (the rig's `tools/gb/audio.py`, the two mixes compared at each M-cycle's end, for the 98 Game Boy test ROMs the system runs, 2 to 20 million M-cycles each): every M-cycle agrees but where a change comes one M-cycle apart. SameBoy's DIV runs 4 T-cycles ahead of ours and MesenCE's from power-up, so its frame sequencer steps an M-cycle sooner: the boot ROM's chime changes volume 8 times, each an M-cycle sooner in SameBoy, and in 95 ROMs that's all. In five `dmg_sound` ROMs, which wait on the length counters by polling NR52, the offset also moves some of the CPU's later writes, so a channel starts an M-cycle or two apart (in `dmg_sound-02`, two noise passages of about 4,000 M-cycles each, otherwise the same) and once a write comes a poll loop (13 M-cycles) apart. Before the comparison, the envelopes changed volume half a step sooner and the noise channel started at a guessed time; both now follow SameBoy.

## References

- Pan Docs, "Audio" and "Audio Registers", gbdev.io: <https://gbdev.io/pandocs/Audio.html>
- SameBoy's `Core/apu.c` (Lior Halphon, Expat licence), read for facts: <https://github.com/LIJI32/SameBoy>
- blargg's `dmg_sound` test ROMs, in `testroms/manifest-gb.toml`
