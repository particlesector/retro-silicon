# RIOT 6532

The MOS 6532 RAM-I/O-Timer (RIOT): 128 bytes of RAM, two 8-bit I/O ports with direction registers, an edge detector on PA7, and an interval timer, cycle-exact. The Atari 2600 keeps all its RAM here, reads its joysticks on port A and its console switches on port B, and times its frames with the timer.

Module `riot_6532`.

## Timing

- **Clock enable:** one CPU cycle per clock with `ce` high. The cycle's access is taken on that edge, and so are a read's side effects.
- **Read data:** `dout` is registered: valid the clock after the address and select, for whatever is selected then. A CPU taking its read data at the cycle's end needs 2 clocks a cycle; one with `cpu/6502`'s `DIN_REG` needs 3.
- **The timer:** a write sets the count and restarts the prescaler, so the count drops on the next cycle and then every 1, 8, 64 or 1024 cycles. Dropping below 0 gives `$FF` and sets the timer flag, and while the flag is set the count drops every cycle. Reading the timer or writing it clears the flag, except on the cycle the count wraps; the prescaler keeps its phase when it clears. A read returns the count as that cycle leaves it. This is the timer as Stella runs it, which the `riot_timer` test cartridge shows.
- **PA7:** sampled each cycle; an edge in the chosen direction sets PA7's flag, which reading the interrupt flags clears (a new edge on the same cycle wins).

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset: ports as inputs, outputs 0, flags clear, interrupts off, the timer at 0 on its 1024-cycle interval (the chip leaves the timer as it was; nothing should read it before setting it) |
| `ce` | in | 1 | One CPU cycle per clock with `ce` high |
| `cs` | in | 1 | The chip is selected this cycle (the 2600: A7 high, A12 low) |
| `rs_n` | in | 1 | 0 selects RAM, 1 the registers (the 2600: A9) |
| `addr` | in | 7 | A6-A0 |
| `we` | in | 1 | This cycle writes `din` |
| `din` | in | 8 | Data written |
| `dout` | out | 8 | Data read, registered (above) |
| `pa_in` | in | 8 | Port A's pins as they stand: the system combines the RIOT's outputs with what drives them |
| `pa_out`, `pa_ddr` | out | 8 | Port A's output register and direction (1: output) |
| `pb_in` | in | 8 | Port B's inputs |
| `pb_out`, `pb_ddr` | out | 8 | Port B's output register and direction |
| `irq_n` | out | 1 | Interrupt, active low: the timer's flag if enabled, or PA7's if enabled (the 2600 leaves it unconnected) |
| `st_addr`, `st_rdata`, `st_we`, `st_wdata` | | 6, 32, 1, 32 | Save-state port (below) |

## Registers

With `rs_n` high, by address bit:

| A4 | A3 | A2 | A1-A0 | Read | Write |
| --- | --- | --- | --- | --- | --- |
| - | - | 0 | 0 | Port A's pins | Port A's output |
| - | - | 0 | 1 | Port A's direction | Port A's direction |
| - | - | 0 | 2 | Port B: outputs from its register, inputs from `pb_in` | Port B's output |
| - | - | 0 | 3 | Port B's direction | Port B's direction |
| - | IE | 1 | A0 = 0 | The timer (A3 enables its interrupt; clears its flag) | |
| - | - | 1 | A0 = 1 | Interrupt flags: bit 7 the timer's, bit 6 PA7's (clears PA7's) | |
| 1 | IE | 1 | interval | | The timer: interval 1, 8, 64, 1024 cycles (A1-A0); A3 enables its interrupt |
| 0 | - | 1 | edge | | PA7's edge detect: A0 = 1 rising, 0 falling; A1 enables its interrupt |

The Atari 2600's names: `SWCHA` `$280`, `SWACNT` `$281`, `SWCHB` `$282`, `SWBCNT` `$283`, `INTIM` `$284`, `TIMINT` `$285`, `TIM1T`-`T1024T` `$294`-`$297`.

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `SAVE_STATE` | 1 | 0 leaves out the save-state port's logic: writes do nothing and reads give 0 |

## Save state

The port follows [docs/conventions.md](../../../docs/conventions.md): 34 words.

| Words | Holds |
| --- | --- |
| 0-31 | RAM, 4 bytes a word, byte 0 in bits 7-0 |
| 32 | Bits 7-0 the timer, 17-8 the prescaler, 19-18 the interval, 20 the timer's flag, 21 PA7's flag, 22 rising-edge select, 23 PA7's interrupt enable, 24 the timer's interrupt enable, 25 PA7 as last sampled |
| 33 | Port A's output and direction, port B's output and direction, from bit 0 |

<!-- size and speed: tools/timing/report.py --readmes writes this section -->
## Size and speed

Each top module placed alone by `tools/timing/report.py` (see `docs/timing.md` for how to read it): its fastest clock and its logic, in LUT4s and ALUs on the Gowin parts, LUT6s on the XC7Z020, and 18 Kbit block RAMs.

| Module | Tang Nano 20K (GW2A-18C) | Tang Console 138K (GW5AST-138C) | PYNQ-Z2 (XC7Z020) |
| --- | --- | --- | --- |
| `riot_6532` | 272 MHz, 719 LUTs | 281 MHz, 707 LUTs | 241 MHz, 416 LUTs |

<!-- end of size and speed -->

## Status

Sim tests:
- **RAM:** all 128 bytes written and read back.
- **The timer:** the `riot_timer` cartridge's five runs, cycle for cycle, give the values Stella shows for it; every interval's first ticks, its wrap and the count at one a cycle after it; a read on the wrap cycle keeping the flag.
- **Ports and PA7:** direction registers, port B reading back its outputs, the edge detector both ways, its flag, and both interrupts.
- **Save state:** 40 random runs of random accesses, saved at a random cycle, restored into another RIOT and run on: the same reads, outputs and interrupt for 400 cycles each. Without save states (`SAVE_STATE = 0`) it runs the same.

Not yet in a system or on a board: `systems/atari-2600` (milestone A4) will run the `riot_ram` and `riot_timer` cartridges against Stella's frames.

## References

- MOS Technology, *MCS6530 / MCS6532* data sheet: the registers, the timer and the edge detector.
- Steve Wright, *Stella Programmer's Guide* (1979): the 2600's addresses for it.
- Stella 7.0 (`src/emucore/M6532.cxx`), read for the timer's behaviour cycle by cycle; nothing copied.
