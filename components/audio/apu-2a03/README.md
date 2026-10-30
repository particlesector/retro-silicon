# apu-2a03

The NES's 2A03 audio processing unit (NTSC), cycle-exact: two pulse channels with sweeps, the triangle, noise, the delta modulation channel (DMC) with its DMA requests, and the frame counter with its IRQ. Its timing follows the 2A03 as [MesenCE](https://github.com/nesdev-org/MesenCE) models it. It outputs each channel's raw level; mixing them is the system's job.

Module `apu_2a03` (the folder name can't start a module name), built from `apu_frame`, `apu_pulse`, `apu_triangle`, `apu_noise`, `apu_dmc`, `apu_length` and `apu_envelope`.

Module `apu_mixer` mixes the levels as the 2A03's output does, nonlinearly, with the NESdev wiki's formulas: `95.52 / (8128 / (p1 + p2) + 100)` for the pulses and `163.67 / (24329 / (3t + 2n + d) + 100)` for the rest. It's two tables that `tools/gen_mixer.py` generates, as block RAM ROMs whose addresses are taken on the falling edge (on the GW2AR-18 a block RAM's address needs more hold than a short path from a register gives). The 16-bit unsigned sum, 0 for silence and 65,518 at most, follows the levels by one to two clocks. A test checks the RTL is the script's, and another checks it against the formulas, computed separately, to within 1.

## Timing

- **Settling:** a cycle's access inputs must be steady from the clock before its `ce`, and the outputs settle the clock after it. The pulse channels' sweep targets, the APU's longest path, are registered a clock behind. In `systems/nes` the inputs are steady from the cycle's start, several clocks before its end.
- **CPU cycles:** one per clock with `ce` high. On each `ce` the APU takes that cycle's register access, then runs the next cycle's tick, so its outputs and `status` after a `ce` are the state a read in the following cycle sees, as on the 2A03.
- **Reset:** the clock after reset runs the first cycle's tick, with no access, as MesenCE ticks the APU at the start of every cycle. So `ce` must not come on that clock. The noise period starts at the table's first entry, as in MesenCE.
- **IRQ:** the access inputs are the cycle's whether or not `ce` is high, and `irq_n` follows them. It is the IRQ as the CPU samples it at the cycle's end: after the access (a `$4015` read clears the frame IRQ) and before the tick and any DMA byte.
- **Cycle parity:** `odd` says whether the cycle's count is odd. Some register effects wait 1 cycle more on odd cycles. A `$4017` write takes effect 3 cycles after an even cycle and 4 after an odd one. A `$4015` write that starts the DMC requests its first byte 2 or 3 cycles later; one that stops it waits the same 2 or 3. A `$4015` read clears the frame IRQ flag 1 or 2 cycles later.
- **The frame counter:** in 4-step mode it clocks at 7457, 14913, 22371 and 29829 cycles into its sequence, with the IRQ flag raised at 29828-29830. In 5-step mode it clocks at 7457, 14913, 22371 and 37281 and raises no IRQ. A `$4017` write with bit 7 set clocks a half frame as it takes effect. No clock comes within 2 cycles of the last. After reset it acts as if `$4017` had been written with 0, 3 cycles before.
- **Length counters:** a load lands in the tick after the frame counter's clock, and only if that clock left the counter alone. A halt write likewise takes effect after the clock (blargg's `len_reload_timing` and `len_halt_timing`).
- **DMC DMA:** the system owns the bus and halts the CPU. `dma_req` (a one-clock pulse after `ce`) asks for the byte at `dma_addr`. `dma_cancel` withdraws a request that hasn't started (a `$4015` disable landing first). The system returns the byte on `dma_data` with `dma_done`, during the `ce` of the cycle it reads it.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset to the power-up state |
| `ce` | in | 1 | One CPU cycle |
| `odd` | in | 1 | This cycle's count is odd |
| `wr`, `addr`, `wdata` | in | 1, 5, 8 | A write to `$4000 + addr` this cycle (`$4014` and `$4016` are ignored) |
| `rd_status` | in | 1 | A read of `$4015` this cycle |
| `status` | out | 8 | `$4015`: DMC IRQ, frame IRQ, 0 (open bus, the system's), DMC active, then the length counters of noise, triangle, pulse 2, pulse 1 |
| `irq_n` | out | 1 | The frame counter's or DMC's IRQ after this cycle's access, active low |
| `dma_req`, `dma_cancel`, `dma_addr` | out | 1, 1, 16 | The DMC's DMA request |
| `dma_done`, `dma_data` | in | 1, 8 | The DMA's byte |
| `pulse1`, `pulse2`, `triangle`, `noise` | out | 4 | Channel levels, 0-15 |
| `dmc` | out | 7 | The DMC's level, 0-127 |
| `st_addr`, `st_rdata`, `st_we`, `st_wdata` | | 5, 32, 1, 32 | Save-state port (below) |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `SAVE_STATE` | 1 | 0 leaves out the save-state port's logic: writes do nothing and reads give 0. For a board short of logic: the port costs about 800 LUTs on a GW2A |

## Save state

The port follows [docs/conventions.md](../../../docs/conventions.md): 17 words, every register.

| Words | Holds |
| --- | --- |
| 0 | Frame counter |
| 1-3 | Pulse 1: timer, sequencer and sweep; envelope; length counter |
| 4-6 | Pulse 2, likewise |
| 7-9 | Triangle: timer and sequencer; linear counter; length counter |
| 10-12 | Noise: shift register and period; timer and envelope; length counter |
| 13-16 | DMC |

The fields within each word are packed as listed by each module's `st_rdata`.

## Status

Unit tests check:

- pulse duty timing and muting (period below 8, sweep target above `$7FF`);
- the triangle's step rate;
- length counter expiry;
- the frame IRQ and its clearing by `$4015`, inhibit and 5-step mode;
- a DMC sample by DMA wrapping from `$FFFF` to `$8000`, with its IRQ;
- a save-state round trip in the middle of random register traffic.

`sim/apu_model.hpp` is a C++ model written in MesenCE's style, unit by unit. The RTL matches it cycle for cycle, on every output and on `irq_n` at each cycle's end, through 2.4 million cycles of random register traffic.

In `systems/nes`, these ROMs pass in the sim, with MesenCE's frames:

- blargg's `apu_test` (8);
- his 2005 APU tests (11);
- `cpu_interrupts_v2` (5);
- `instr_misc` 1-3 and `instr_timing`'s branch test;
- `sprdma_and_dmc_dma` and its 512-byte version;
- `apu_mixer`'s four (which only play sound: their audio CRCs are the check).

`instr_misc-04` and `instr_timing-1` need the CPU's unstable unofficial opcodes. Not modelled: PAL timing, the DMC sample-duplication glitch of later 2A03 revisions (MesenCE has it off by default), and the `$4015` reads and writes of test mode.

## References

- NESdev wiki: *APU*, *APU Frame Counter*, *APU Length Counter*, *APU Envelope*, *APU Sweep*, *APU DMC*, *DMA*.
- [MesenCE](https://github.com/nesdev-org/MesenCE)'s `NesApu`, `ApuFrameCounter`, `SquareChannel`, `TriangleChannel`, `NoiseChannel` and `DeltaModulationChannel`: the timing it reproduces, read for behaviour; no code is taken from it.
