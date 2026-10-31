# trace

A trace buffer for the test shell: the last 2^`AW` entries a system records, such as one for each CPU cycle, kept in block RAM to read back after the system stops. A test that fails shows what the system did just before it stopped, cycle by cycle, where a trace CRC only shows that something differed.

Module `trace_buffer`.

- **Entries** of `W` bits go in on `en`, one a clock at most, at ring index `count[AW-1:0]`, and `count` goes up. Entry i since the last `set` (or reset) is at ring index i mod 2^`AW` while it's among the last 2^`AW`. `filled` says how many of those are valid, so the oldest is at (`count` - `filled`) mod 2^`AW`.
- **`set`** loads `count` and empties the buffer. When a system loads a save state, it sets `count` to the cycle it resumes at, so entry numbers stay cycle numbers.
- **The memory** is `W`/8 byte-wide memories, which every toolchain maps without parity bits.
- **Reading:** read it while nothing records. `rdata` is the entry at `raddr` a clock later.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, which empties it and sets `count` to 0 |
| `en`, `data` | in | 1, W | Record an entry |
| `set`, `set_count` | in | 1, 32 | Load `count` and empty it |
| `count` | out | 32 | The next entry's number |
| `filled` | out | AW+1 | Valid entries, up to 2^AW |
| `raddr`, `rdata` | in, out | AW, W | Ring index; the entry there, a clock later |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `W` | 32 | Entry width, a multiple of 8 |
| `AW` | 10 | 2^AW entries |

## Status

Sim test (`AW` = 4), against a software model: bursts of entries, some far longer than the buffer, with `set`s and resets between. After each burst every valid entry reads back at its ring index, and `count` and `filled` match. The test caught two planted bugs: a `set` that leaves old entries valid, and `filled` counting past the depth.

In `systems/nes`, it holds each CPU cycle's bus (4 bytes, the same as the trace CRC). In the sim, the last 1024 cycles of nestest, stopped at cycle 5,000 and at 26,554, match nestest.log: an opcode fetch at each instruction's PC and cycle, and no others.
