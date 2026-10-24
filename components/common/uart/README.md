# uart

8N1 UART: a receiver (`uart_rx`) and a transmitter (`uart_tx`), each set to a rate by `CLKS_PER_BIT` (clock frequency divided by baud rate).

## uart_rx

Synchronises `rx` through three flops, samples each bit at its middle, and goes back to idle in the middle of the stop bit, so a sender running slightly fast never loses sync. A low pulse shorter than half a bit is ignored as a glitch.

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset |
| `rx` | in | 1 | Serial input, idle high |
| `data` | out | 8 | The received byte, while `valid` is high |
| `valid` | out | 1 | One-cycle pulse: a byte arrived |
| `frame_err` | out | 1 | One-cycle pulse: the stop bit was low, and the byte was dropped |

## uart_tx

Takes a byte on `valid && ready`. `ready` rises on the last clock of the stop bit, so back-to-back bytes take exactly 10 bit times each and an echo keeps pace with its sender. `tx` comes straight from a flop and never glitches.

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset |
| `data` | in | 8 | Byte to send |
| `valid` | in | 1 | `data` is ready to send |
| `ready` | out | 1 | A byte is taken on `valid && ready` |
| `tx` | out | 1 | Serial output, idle high |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT` | 9 | Clocks per bit; 27 MHz / 9 = 3 Mbaud, 27 MHz / 18 = 1.5 Mbaud |

## Status

Sim tests at 9 and 234 clocks per bit: the receiver takes back-to-back streams from a sender 2% fast or slow, drops a byte with a low stop bit and recovers, and ignores a glitch; the transmitter sends back-to-back frames with no gap between them, and idles high and ready. On a Tang Nano 20K, inside `systems/uart-echo`, it echoed 100 MB at 1.5 Mbaud with no errors.
