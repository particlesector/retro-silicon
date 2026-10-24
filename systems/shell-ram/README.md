# shell-ram

The test shell with a 4 KB scratch RAM on its bus, mirrored through the whole 32-bit address space. It exists to test the shell itself: the harness's shell test sends it random PING, PEEK, POKE and INFO commands and checks every answer against a model of the RAM.

Built from `common/por` and `debug/test-shell`.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `uart_rx` | in | 1 | Serial input |
| `uart_tx` | out | 1 | Serial output |
| `led` | out | 6 | Active low: `led[0]` a corrupt command frame was seen, `led[1]` a stalled one (both sticky until reload), `led[5]` heartbeat |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT` | 18 | Clocks per bit; 1.5 Mbaud at 27 MHz |
| `IDLE_CLKS` | 270,000 | The shell's stall timeout; 10 ms at 27 MHz |
| `BUILD_ID` | 0 | Reported by INFO; the CMake build sets it from the RTL's SHA-256 |

## Status

1,000 random commands with 0.02% of bytes damaged on purpose in both directions: all succeed, in the simulation and on a Tang Nano 20K, with the same CRC32 (`harness/golden/shell_crc32.txt`). 20,000 commands over the clean board link needed no retries.
