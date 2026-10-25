# save-state

Saves a system's whole state into a block-RAM buffer and loads it back, by walking a list of byte regions on the system's own bus: the regions where the system maps its components' save-state ports ([docs/conventions.md](../../../docs/conventions.md)) and its memories. A save taken on one board loads on any other board running the same system, at any clock.

Module `save_state_ctrl`.

## Commands

- **Start:** write `cmd` with op 1 (save) or 2 (load) in bits 7:6 and a sequence number in bits 5:0. A command runs when `cmd` changes; `done` takes `cmd`'s value when it has finished. Writing the same command again does nothing, so a host can repeat it safely. Any other op is taken as done at once.
- **Stopping the system:** while a command runs, `hold` asks the system to stop, at its next frame boundary for a save (`hold_frame`), or at once for a load; if it's already stopped, where it stands. The walk starts when the system raises `ready`.
- **The walk:** each region's bytes in order, one bus access at a time. A save reads them into the buffer from address 0; a load writes the buffer's bytes back the same way.
- **The buffer:** the host side reads and writes it while no command runs, with a registered read.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, which stops any walk and clears `done` |
| `cmd`, `done` | in, out | 8 | Command and the last finished, as above |
| `busy` | out | 1 | A command is running |
| `hold`, `hold_frame` | out | 1 | Stop the system; at a frame boundary |
| `ready` | in | 1 | The system has stopped as asked |
| `b_req`, `b_we`, `b_addr`, `b_wdata` | out | 1, 1, 32, 8 | The bus: hold `b_req` until `b_ack`, as on the test shell's bus; it drops for a clock between accesses |
| `b_ack`, `b_rdata` | in | 1, 8 | |
| `h_addr`, `h_we`, `h_wdata` | in | AW, 1, 8 | The host's access to the buffer, while not busy |
| `h_rdata` | out | 8 | Registered: the byte at `h_addr` the clock before |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `NREG` | 1 | Regions |
| `BASES`, `LENS` | 0 | Each region's first address and length in bytes, region r in bits `[r*32 +: 32]` |
| `AW` | 15 | Buffer: 2^AW bytes, at least the regions' total |

## Status

Sim tests, with two regions behind a bus of random latency and a stop that takes up to 20 clocks: a save fills the buffer with the regions in order, touching nothing else; a repeated command does nothing; a load after the system is scrambled restores every byte; nothing reaches the bus before `ready`; and a buffer the host wrote loads. Planted bug caught: a load that doesn't wait for its buffer read.

In `systems/nes`, sim and both boards: a state saved mid-run and restored after a reset finishes with the uninterrupted run's frames, trace CRC and cycle count, and a state saved at 27 MHz on SDRAM finishes the same at 50 MHz on block RAM.
