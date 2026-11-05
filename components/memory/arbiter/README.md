# arbiter

Shares one byte-port memory among N clients by fixed priority, client 0 first. A system takes its memory through this, so a board can put any memory behind the one port: `memory/sdram` on the Tang Nano 20K, `memory/bram` on the Tang Console 138K.

Module `mem_arbiter`.

## Timing

- **Ports:** the clients' and the memory's all work as `memory/sdram`'s user port: hold `req` (with `addr`, `we`, `wdata`) until `ack`, a one-clock pulse that also marks `rdata` valid on a read. `req` may still be high while `ack` is.
- **Grant:** when the memory is free, the first requesting client is granted on the next clock, and its request goes straight to the memory until the memory acks. The ack goes to that client in the same clock.
- **Latency:** a client waits for the rest of any access already running, then for every client before it. Client 0 waits for at most one access, plus the grant clock and its own access; that bound is what lets a CPU fit its reads into a fixed cycle.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, which drops any grant |
| `c_req`, `c_we`, `c_ack` | in, in, out | N | Per client |
| `c_addr`, `c_wdata` | in | N×AW, N×8 | Client i in bits `[i*AW +: AW]` and `[i*8 +: 8]` |
| `c_rdata` | out | 8 | Read data, for the client being acked |
| `m_req`, `m_we`, `m_addr`, `m_wdata` | out | 1, 1, AW, 8 | To the memory |
| `m_ack`, `m_rdata` | in | 1, 8 | From the memory |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `N` | 2 | Clients |
| `AW` | 23 | Address bits |

<!-- size and speed: tools/timing/report.py --readmes writes this section -->
## Size and speed

Each top module placed alone by `tools/timing/report.py` (see `docs/timing.md` for how to read it): its fastest clock and its logic, in LUT4s and ALUs on the Gowin parts, LUT6s on the XC7Z020, and 18 Kbit block RAMs.

| Module | Tang Nano 20K (GW2A-18C) | Tang Console 138K (GW5AST-138C) | PYNQ-Z2 (XC7Z020) |
| --- | --- | --- | --- |
| `mem_arbiter` | 402 MHz, 53 LUTs | 380 MHz, 53 LUTs | 442 MHz, 52 LUTs |

<!-- end of size and speed -->

## Status

Sim test (N = 3) against a memory with a random latency of 1 to 7 clocks, with three clients each keeping requests going in its own part of the address space: 200,000 clocks in which every request is served exactly once, every read gives the byte last written, and client 0 never waits more than two accesses. In `systems/nes` it serves the CPU's PRG reads and the shell, on both boards.
