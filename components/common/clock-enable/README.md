# clock-enable

A clock enable at NUM/DEN of the clock rate, exact on average: a phase accumulator gains NUM each enabled clock and fires when it reaches DEN, so pulses come floor(DEN/NUM) or ceil(DEN/NUM) clocks apart and never drift. It's how a system on one fast clock runs a chip at its original rate: the NES's PPU dot rate, 236.25/44 MHz, is NUM = 35, DEN = 176 from 27 MHz.

While `en` is low the accumulator holds, so stopping the enables and starting them again leaves the pulse pattern as if no time had passed: a system can pause between cycles without changing what it does.

While `hold` is high, only a pulse that's due waits: the accumulator holds on that clock until `hold` falls, and clocks with no pulse due advance as usual. A system waiting on something its next pulse needs (`systems/atari-2600`'s cartridge fetching a ROM byte from the SDRAM) loses time only when the pulse has to wait, and pulses stay at least floor(DEN/NUM) clocks apart.

Module `clock_enable`.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, which restarts the phase from 0 |
| `en` | in | 1 | Advance this clock |
| `hold` | in | 1 | Keep a pulse that's due this clock waiting (the accumulator holds); 0 when unused |
| `ce` | out | 1 | One-clock pulse, NUM per DEN enabled clocks |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `NUM` | 1 | Pulses per DEN clocks, 1 to DEN |
| `DEN` | 2 | Clocks per NUM pulses |

<!-- size and speed: tools/timing/report.py --readmes writes this section -->
## Size and speed

Each top module placed alone by `tools/timing/report.py` (see `docs/timing.md` for how to read it): its fastest clock and its logic, in LUT4s and ALUs on the Gowin parts, LUT6s on the XC7Z020, and 18 Kbit block RAMs.

| Module | Tang Nano 20K (GW2A-18C) | Tang Console 138K (GW5AST-138C) | PYNQ-Z2 (XC7Z020) |
| --- | --- | --- | --- |
| `clock_enable` | 1550 MHz, 2 LUTs | 2451 MHz, 2 LUTs | 1086 MHz, 2 LUTs |

<!-- end of size and speed -->

## Status

Sim tests: 35/176 gives exactly 35 pulses every 176 clocks, 5 or 6 clocks apart; a randomly gated `en` gives the same pulse sequence over the enabled clocks as a steady one; bursts of `hold` hold back only the pulses due in them, clock for clock as the rule above, losing only those clocks; 1/2 and 7/7 behave at the edges.

In `systems/nes` on a Tang Nano 20K, as the PPU's dot clock, and in `systems/atari-2600` as the colour clock.
