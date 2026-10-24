# uart-echo

UART link test: echoes every received byte through a 2 KB FIFO. The harness's echo test streams seeded random data through it with at most 2,048 bytes in flight, and checks each byte comes back in order; the CRC32 of what comes back is the same whether the design runs in Verilator or on a board.

Built from `common/por`, `common/uart` and `common/fifo`.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `uart_rx` | in | 1 | Serial input |
| `uart_tx` | out | 1 | Serial output |
| `led` | out | 6 | Active low: `led[0]` FIFO overflow and `led[1]` framing error (both sticky until reload), `led[5]` heartbeat |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT` | 9 | Clocks per bit; the Tang Nano 20K build uses 18 (1.5 Mbaud at 27 MHz) |

## Status

Sim tests at 9 and 234 clocks per bit: back-to-back echo from a sender 2% fast or slow, the framing-error LED on a low stop bit, glitch rejection, and the overflow LED when a fast sender fills the FIFO. On a Tang Nano 20K at 1.5 Mbaud, through an FT232RL clone: 100 MB echoed with no errors, and the same CRC32 as the simulation for 256,000- and 1,000,000-byte runs.
