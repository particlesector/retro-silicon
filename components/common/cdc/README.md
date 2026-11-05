# cdc

A flip-flop synchronizer: brings a signal from another clock domain into this one through `STAGES` flip-flops, so a value that changes near the clock edge settles before anything uses it.

Module `cdc_sync`. It's safe only for signals whose bits can be taken in any mix of old and new without harm:
- a level;
- a toggle, one bit that flips once per event;
- a Gray-coded count, which changes one bit per step;
- a value the sending side holds steady from before a toggle it sends until after the toggle is seen here.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | This domain's clock |
| `d` | in | `W` | From the other domain |
| `q` | out | `W` | `d`, `STAGES` clocks later |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `W` | 1 | Bits |
| `STAGES` | 2 | Flip-flops in the chain, 2 or more |

<!-- size and speed: tools/timing/report.py --readmes writes this section -->
## Size and speed

Each top module placed alone by `tools/timing/report.py` (see `docs/timing.md` for how to read it): its fastest clock and its logic, in LUT4s and ALUs on the Gowin parts, LUT6s on the XC7Z020, and 18 Kbit block RAMs.

| Module | Tang Nano 20K (GW2A-18C) | Tang Console 138K (GW5AST-138C) | PYNQ-Z2 (XC7Z020) |
| --- | --- | --- | --- |
| `cdc_sync` | 3759 MHz, 0 LUTs | 3759 MHz, 0 LUTs | — |

<!-- end of size and speed -->

## Status

Sim test: the output is the input `STAGES` clocks later. In `video/line-scaler` and `systems/nes`, between the NES's clock and the HDMI pixel clock, on a Tang Nano 20K.
