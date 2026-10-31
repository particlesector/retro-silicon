# port-cdc

`memory/sdram`'s byte port across two clock domains: a user on `clk` and a memory on `mclk`. For example, `memory/axi-bridge` can run on a faster clock than the system it serves, as on the PYNQ-Z2, where a DDR read through the Zynq's HP0 port takes fewer nanoseconds on a faster clock.

Module `mem_port_cdc`.

- **One access at a time, by toggles.** The user side holds the access's address and data steady from before its request toggle until the memory side's answer comes back. The memory side holds the read data steady from before its answer toggle until the next request. Neither side ever samples a bus while it changes. `common/cdc`'s `cdc_sync` carries the toggles and the memory's `ready`.
- **Cost:** about two clocks of each domain on top of the memory's own time.
- **A read's data is `DW` bits**, such as a whole 8-byte line for `memory/cache`.
- The clocks may be unrelated, and either may be the faster.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | The user's clock and synchronous reset |
| `req`, `we`, `addr`, `wdata` | in | 1, 1, AW, 8 | The user's access, held until `ack` |
| `ack`, `rdata` | out | 1, DW | One-clock pulse when it's done; a read's data |
| `ready` | out | 1 | The memory's `ready`, in the user's domain |
| `mclk`, `mrst` | in | 1 | The memory's clock and synchronous reset (in its own domain) |
| `m_req`, `m_we`, `m_addr`, `m_wdata` | out | 1, 1, AW, 8 | The memory's access, held until `m_ack` |
| `m_ack`, `m_rdata`, `m_ready` | in | 1, DW, 1 | The memory's acknowledge, read data and ready |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `AW` | 23 | Byte address width |
| `DW` | 64 | Read data width |

## Status

Sim tests: random reads and writes cross to a memory on an unrelated clock four times as fast, and to one on a slower clock, and match a byte array. The bench caught three bugs planted in it.

In `systems/nes` (`nes_axi`, `ASYNC`) on the PYNQ-Z2, it carries the cache's misses and prefetches from the 37.125 MHz system clock to HP0 on the 74.25 MHz pixel clock. All 103 golden ROMs and both HDMI ROMs pass.
