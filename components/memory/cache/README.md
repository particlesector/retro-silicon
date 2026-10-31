# cache

A read cache for `memory/sdram`'s byte port, in front of a memory that reads whole 8-byte lines, such as `memory/axi-bridge` (its `rdata_d`). For memory far slower to answer than a system's cycle: DDR behind a processor, where one read through the Zynq-7000's HP port takes longer than an NES CPU cycle can wait.

Module `mem_cache`.

- **Direct-mapped**, 2^`IDX` lines of 8 bytes, in block RAM. The data is eight byte-wide memories, the tags byte-wide memories and the valid bits a one-bit memory: nothing wider than 8 bits, which every toolchain maps without parity bits (openXC7 loses a 9-bit memory's ninth bit).
- **A read that hits** answers in three clocks. One that misses reads its line from the memory, fills it and answers with it.
- **A write** goes through to the memory and updates the line if the cache holds its address, so the cache never holds stale data: a ROM uploaded through it reads back right.
- **Prefetch** (`PREFETCH`): a miss on line L, or the first read of the line the last prefetch brought, also fetches line L+1 if it isn't cached, in the background. Straight-line code then streams: each line is fetched while the one before it runs. The line lands in a one-line buffer and goes into the cache on a clock the user leaves free. Reads that hit, the buffer included, are answered meanwhile; a read that misses, or a write, waits for it, as the memory takes one access at a time.
- **After reset**, `ready` stays low while the valid bits are cleared (2^`IDX` clocks) and until the memory is ready.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset (the cache empties) |
| `req`, `we`, `addr`, `wdata` | in | 1, 1, AW, 8 | The user's access, held until `ack`; `req` may still be high while `ack` is |
| `ack`, `rdata`, `rdata_w` | out | 1, 8, 32 | One-clock pulse when it's done; a read's byte, and the 32-bit half of its line, with it |
| `ready` | out | 1 | Accesses may start |
| `d_req`, `d_we`, `d_addr`, `d_wdata` | out | 1, 1, AW, 8 | The memory's access: a line's first byte for a read, the byte for a write |
| `d_ack`, `d_rdata`, `d_ready` | in | 1, 64, 1 | The memory's acknowledge, a read's whole line (byte 0 in bits 7-0), and its ready |
| `hits`, `misses`, `prefetches` | out | 32 each | Since reset: reads answered from the cache (or the prefetch buffer), reads that went to the memory, lines prefetched |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `AW` | 23 | Byte address width |
| `IDX` | 12 | 2^IDX lines: 32 KB |
| `PREFETCH` | 1 | Fetch the next line after a miss, and after the first read of a prefetched line |

## Status

Sim tests (`AW` = 16, `IDX` = 6), with and without prefetch, behind a memory that answers in 2 to 15 clocks and checks that each access's address, write enable and data hold from its request to its ack:
- 30,000 random reads and writes, mostly in a loop over half the cache that moves now and then: every read matches a byte array, every write reaches the memory, and the loops hit;
- straight-line code over 4 KB: without prefetch every one of its 512 lines misses; with it, fewer than 16;
- two straight-line runs far apart, read in turns, as a loop calling a distant subroutine.

The bench caught four bugs planted in it: a hit that ignores the tag, a write that leaves the cached line stale, a write that leaves the prefetch buffer stale, and the buffer going in under the wrong line. It also caught one real bug: the first read of a prefetched line could start the next prefetch while one was still out, changing the address of the read in flight. A 256 KB MMC1 ROM in the NES's AXI sim then hung, as on the PYNQ-Z2.

In `systems/nes` (`nes_axi`), in front of the PYNQ-Z2's DDR3: without prefetch, the NES waits no clocks for memory in its HDMI runs, where without the cache it waited 117,000 a frame.
