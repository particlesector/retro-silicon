# por

Power-on reset: holds `rst` high for `CYCLES` clocks after the FPGA is configured, then low for good. It's the one block that relies on a register's initial value, which FPGAs load at configuration; everything else resets from its `rst`. It won't work on an ASIC or an FPGA that ignores initial values; use a reset pin there instead.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `rst` | out | 1 | High for the first `CYCLES` clocks |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CYCLES` | 16 | Clocks that `rst` stays high |

<!-- size and speed: tools/timing/report.py --readmes writes this section -->
## Size and speed

Each top module placed alone by `tools/timing/report.py` (see `docs/timing.md` for how to read it): its fastest clock and its logic, in LUT4s and ALUs on the Gowin parts, LUT6s on the XC7Z020, and 18 Kbit block RAMs.

| Module | Tang Nano 20K (GW2A-18C) | Tang Console 138K (GW5AST-138C) | PYNQ-Z2 (XC7Z020) |
| --- | --- | --- | --- |
| `por` | 622 MHz, 15 LUTs | 616 MHz, 15 LUTs | 521 MHz, 18 LUTs |

<!-- end of size and speed -->

## Status

Sim tests at 16 and 1 cycles: `rst` is high for exactly `CYCLES` rising edges, then stays low. Runs in `systems/uart-echo` on a Tang Nano 20K.
