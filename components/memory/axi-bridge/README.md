# axi-bridge

`memory/sdram`'s byte port onto an AXI master: a system's memory in a processor's DDR, such as the Zynq-7000's, through one of its high-performance (HP) ports. A system keeps its simple memory port; this is the only place that speaks AXI.

Module `axi_bridge`.

Each access is one single-beat transfer of the aligned 64-bit word, so the transfers are valid AXI3 (the Zynq-7000's HP ports) and AXI4 alike:
- **A read** fetches the word and gives its byte on `rdata`, and the 32-bit half the byte is in on `rdata_w`, as `memory/sdram` does.
- **A write** sends the byte in its lane with a one-byte strobe, and waits for the write response.

One access is out at a time, so they complete in order. How long one takes is up to the memory behind the port: a system on it has to wait for `ack` (as `systems/nes` does) rather than count on a fixed time.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock, for the byte port and the AXI port alike; synchronous reset |
| `req`, `we`, `addr`, `wdata` | in | 1, 1, AW, 8 | An access, held until `ack`; `req` may still be high while `ack` is |
| `ack`, `rdata`, `rdata_w`, `rdata_d` | out | 1, 8, 32, 64 | One-clock pulse when the access is done; a read's byte, the 32-bit word it's in and the whole 8-byte word (for `memory/cache`), with it |
| `ready` | out | 1 | Accesses may start: `axi_ready`, registered |
| `axi_ready` | in | 1 | The AXI side is out of reset and the memory behind it is set up |
| `m_ar*`, `m_r*` | | | AXI read address and data: `araddr`, `arvalid`, `arready`, `arlen`, `arsize`, `arburst`, `arcache`, `arid`; `rdata`, `rvalid`, `rready`, `rresp`, `rlast` |
| `m_aw*`, `m_w*`, `m_b*` | | | AXI write address, data and response: `awaddr`, `awvalid`, `awready`, `awlen`, `awsize`, `awburst`, `awcache`, `awid`; `wdata`, `wstrb`, `wlast`, `wid`, `wvalid`, `wready`; `bresp`, `bvalid`, `bready` |

The AXI data bus is 64 bits wide. Error responses aren't reported: the byte port has no way to say so.

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `AW` | 23 | The byte port's address width |
| `BASE` | `0x10000000` | The AXI address of byte 0: the window is `BASE` to `BASE + 2^AW - 1`, 8-byte aligned |
| `IDW` | 6 | AXI ID width (6 for the Zynq-7000's HP ports); IDs are 0 |

## Status

Sim test (`AW` = 12): 20,000 random byte reads and writes against a byte array, through an AXI slave model that withholds ready on every channel at random and answers after 0 to 11 clocks. The model checks AXI's rules as it goes: payloads hold while valid is up, one transfer at a time, single 8-byte beats inside the window, a one-byte strobe. `req` is held high the clock after each `ack` without starting a second access. The bench caught both bugs planted in it, a read's byte from the wrong lane and a write's strobe on the wrong byte.

Not yet on a board: the PYNQ-Z2's HP0 is next (milestone 9.5).
