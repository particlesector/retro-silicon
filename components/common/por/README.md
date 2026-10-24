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

## Status

Sim tests at 16 and 1 cycles: `rst` is high for exactly `CYCLES` rising edges, then stays low. Runs in `systems/uart-echo` on a Tang Nano 20K.
