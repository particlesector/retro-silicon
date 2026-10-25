# clock-enable

A clock enable at NUM/DEN of the clock rate, exact on average: a phase accumulator gains NUM each enabled clock and fires when it reaches DEN, so pulses come floor(DEN/NUM) or ceil(DEN/NUM) clocks apart and never drift. It's how a system on one fast clock runs a chip at its original rate: the NES's PPU dot rate, 236.25/44 MHz, is NUM = 35, DEN = 176 from 27 MHz.

While `en` is low the accumulator holds, so stopping the enables and starting them again leaves the pulse pattern as if no time had passed: a system can pause between cycles without changing what it does.

Module `clock_enable`.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, which restarts the phase from 0 |
| `en` | in | 1 | Advance this clock |
| `ce` | out | 1 | One-clock pulse, NUM per DEN enabled clocks |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `NUM` | 1 | Pulses per DEN clocks, 1 to DEN |
| `DEN` | 2 | Clocks per NUM pulses |

## Status

Sim tests: 35/176 gives exactly 35 pulses every 176 clocks, 5 or 6 clocks apart; a randomly gated `en` gives the same pulse sequence over the enabled clocks as a steady one; 1/2 and 7/7 behave at the edges.

In `systems/nes` on a Tang Nano 20K, as the PPU's dot clock.
