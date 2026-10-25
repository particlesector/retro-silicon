# test-shell

A UART command engine that gives a host framed, CRC-checked access to a core: it reads and writes the core's bus, and reports a build ID so every result ties to the exact RTL that produced it. Later blocks (ROM loader, run control, video and audio CRCs, frame dump, trace buffer) are reached through the same commands and bus.

The host side is `rig::shell::Client` in [harness](../../../harness).

## Protocol

The host sends one command and waits for its response before sending the next. Frames in both directions:

| Bytes | Field |
| --- | --- |
| 1 | Sync: `A5` for a command, `5A` for a response |
| 1 | Command code, or the response's status |
| 1 | Sequence number, copied into the response |
| 2 | Payload length, little-endian |
| length | Payload |
| 4 | CRC-32 (as zlib) of everything after the sync byte, little-endian |

All multi-byte values are little-endian.

**Versions:** 1 had PING, INFO, PEEK and POKE; 2 adds CRC.

**Recovery:** the shell drops a command frame without answering when its CRC fails, when its length is over the payload buffer (it resyncs straight away), or when no byte arrives for `IDLE_CLKS` clocks in the middle of it (10 ms by default). The host resends after a silence longer than that, with the same sequence number. Every command is idempotent (addresses are absolute), so running one twice is harmless. The host ignores responses with another sequence number. Because commands and responses use different sync bytes, an echo or loopback never passes for a shell.

### Commands

| Code | Command | Payload | Response payload |
| --- | --- | --- | --- |
| `01` | PING | Any bytes, up to the payload limit | The same bytes |
| `02` | INFO | None | 16 bytes: `"RSTS"`, then the protocol version (2 bytes, now 2), `BUILD_ID` (4 bytes), the payload limit (2 bytes), and counts of corrupt and of stalled frames dropped (2 bytes each, saturating) |
| `10` | PEEK | Address (4), count (2) | `count` bytes read from the bus, from the address up |
| `11` | POKE | Address (4), then the data | None; writes the data to the bus, from the address up |
| `12` | CRC | Address (4), count (4) | CRC-32 (as zlib, 4 bytes) of `count` bytes read from the bus, from the address up; the address wraps at the top. The response comes once every byte is read, so the host waits longer for a big count |

### Status codes

| Code | Meaning |
| --- | --- |
| `00` | OK |
| `01` | Unknown command |
| `02` | Wrong payload length for the command |

An error response has no payload.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset |
| `uart_rx` | in | 1 | Serial input from the host, idle high |
| `uart_tx` | out | 1 | Serial output to the host |
| `bus_addr` | out | 32 | Byte address; the system decides what it maps to |
| `bus_req` | out | 1 | Held high, with the address and data, until `bus_ack` |
| `bus_we` | out | 1 | Write when high, read when low |
| `bus_wdata` | out | 8 | Byte to write |
| `bus_ack` | in | 1 | One-cycle pulse: the access is done, and on a read `bus_rdata` is valid |
| `bus_rdata` | in | 8 | Byte read |
| `crc_error` | out | 1 | One-cycle pulse: a command frame was dropped as corrupt |
| `timeout` | out | 1 | One-cycle pulse: a command frame stalled and was dropped |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT` | 18 | Clocks per bit; 27 MHz / 18 = 1.5 Mbaud |
| `MAX_PAYLOAD_LOG2` | 11 | Command payloads up to 2 KB, buffered in one block RAM |
| `IDLE_CLKS` | 270,000 | Clocks of silence that drop a partial frame; 10 ms at 27 MHz |
| `BUILD_ID` | 0 | Reported by INFO; CMake's `rs_build_id` derives it from the RTL |

Built from `rtl/ts_rx.sv` (frame receiver), `rtl/ts_tx.sv` (frame transmitter, CRC computed as bytes go out, so a response of any length needs no buffer) and `rtl/test_shell.sv` (dispatcher), with `common/uart` and `common/crc32`. About 900 LUTs and one block RAM on a GW2A-18C.

## Status

Sim tests against a bus model with a random 0-4 clock acknowledge delay:
- INFO fields and PING from 0 to 2,048 bytes.
- PEEK and POKE across the 32-bit address space.
- CRC against the host's CRC-32, for 0 to 5,000 bytes and across the top of the address space.
- Error statuses for unknown commands and bad lengths.
- Dropping and counting corrupt and stalled frames, and resyncing after an impossible length.
- 300 commands over a link that damages 0.2% of bytes.

In `systems/shell-ram` on a Tang Nano 20K at 1.5 Mbaud:
- 1,000 commands with 0.02% of bytes damaged on purpose all succeeded, with the same CRC as the simulation.
- 20,000 commands on the clean link needed no retries, again with the same CRC as the simulation.
