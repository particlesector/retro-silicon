# bram

2^AW bytes of block RAM behind `memory/sdram`'s byte port, for a board whose own memory a system can't use yet, such as the Tang Console 138K's DDR3. Every access takes one clock. Addresses wrap at 2^AW, so a wider port mirrors it.

Module `bram_mem`.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset (the contents stay) |
| `req`, `we`, `addr`, `wdata` | in | 1, 1, IW, 8 | An access, held until `ack`; `req` may still be high while `ack` is |
| `ack`, `rdata` | out | 1, 8 | One-clock pulse a clock after `req`; read data with it |
| `ready` | out | 1 | Always high: block RAM needs no power-up sequence |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `AW` | 18 | Bytes: 2^AW (256 KB) |
| `IW` | 23 | The port's address width; bits above AW are ignored |

## Status

Sim test (AW = 10, IW = 12): 40,000 random reads and writes, through the mirror, against a byte array, each acked in one clock, with `req` left high during the ack. In `systems/nes` (`nes_bram`) it holds PRG ROM on the Tang Console 138K.
