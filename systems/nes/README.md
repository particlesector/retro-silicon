# nes

The NES as far as it's built: the 2A03's CPU (`cpu/6502` with `DECIMAL = 0`), 2 KB of RAM mirrored to `$1FFF`, 8 KB of PRG RAM at `$6000`, and PRG ROM through mapper 0 (NROM), read from SDRAM. The test shell loads ROMs, runs the CPU and reads results. The PPU, APU, controllers and other mappers come in later milestones; until then, reads of `$2000`–`$5FFF` give open bus (the last value on the data bus) and writes there do nothing.

Built from `common/por`, `common/crc32`, `debug/test-shell`, `memory/sdram` and `cpu/6502`. On the Tang Nano 20K, `boards/tang-nano-20k/rtl/nes_top.sv` connects the SDRAM pins. The host side is `rig::nes` in [harness](../../harness).

## Timing

The CPU runs one cycle every `CE_DIV` clocks: 1.8 MHz at 27 MHz, against the NTSC console's 1.79 MHz. Each cycle starts with its address valid:
- **PRG reads** go to SDRAM on the cycle's first clock and must be back by its last. SDRAM's worst case is 10 clocks at 27 MHz, inside the 15, so this can't miss; the sticky `late` status bit would record it if it did.
- **RAM and PRG RAM** are block RAMs shared with the shell. The CPU reads on its cycle's first clock and writes on its last; the shell uses the clocks in between, or any clock while the CPU is paused.
- **The shell** reaches SDRAM at any time, after any CPU read that is waiting.

So nothing the shell does moves the CPU's timing: the CPU's bus, and the CRC of it, are the same on any board and in the sim.

## Shell address map

| Address | What |
| --- | --- |
| `0x00000000`–`0x007FFFFF` | SDRAM, 8 MB. PRG ROM starts at 0 |
| `0x01000000`–`0x010000FF` | Registers, below |
| `0x02000000`–`0x0200FFFF` | The CPU's address space: RAM (`$0000`–`$1FFF`) and PRG RAM (`$6000`–`$7FFF`); the rest reads 0 and ignores writes |

Anything else reads 0 and ignores writes. Multi-byte registers are little-endian.

| Offset | Bytes | Register |
| --- | --- | --- |
| `00` | 1 | Control: bit 0 run, bit 1 hold the CPU in reset. Reset clears the cycle count, trace CRC and status. Starts as reset held |
| `04` | 3 | PRG mask: CPU address bits 0–14 ANDed with this give the SDRAM address. `0x3FFF` mirrors 16 KB into both halves; `0x7FFF` (the default) maps 32 KB |
| `08` | 2 | Reset vector override: CPU reads of `$FFFC` and `$FFFD` give this |
| `0A` | 1 | Bit 0: use the override |
| `0C` | 4 | Stop the CPU after this many cycles from reset; 0 never |
| `10` | 4 | CPU cycles since reset (read-only) |
| `14` | 4 | CRC-32 of the CPU's bus since reset (read-only): 4 bytes a cycle, address low, address high, data read or written, flags (bit 0 write, bit 1 opcode fetch) |
| `18` | 1 | Status (read-only): bit 0 the CPU halted (a JAM opcode), bit 1 stopped at the cycle count, bit 2 a PRG read was late, bit 3 running |

All are absolute, so a command the shell runs twice does no harm.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock |
| `uart_rx`, `uart_tx` | in, out | 1 | The test shell's serial link |
| `led` | out | 6 | Active low: `led[0]` a corrupt command frame was seen, `led[1]` a stalled one, `led[2]` SDRAM ready, `led[3]` CPU running, `led[4]` halted or late, `led[5]` heartbeat |
| `sd_*` | | | The SDRAM pins, as on `memory/sdram`'s `sdram_ctrl` |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT` | 18 | Clocks per bit; 1.5 Mbaud at 27 MHz |
| `IDLE_CLKS` | 270,000 | The shell's stall timeout; 10 ms at 27 MHz |
| `FREQ_MHZ` | 27 | Clock frequency, for the SDRAM timings |
| `CE_DIV` | 15 | Clocks per CPU cycle; at least the SDRAM's worst-case latency plus 5 |
| `BUILD_ID` | 0 | Reported by INFO; the CMake build sets it from the RTL's SHA-256 |

## Status

`rig::nes::nestest` runs nestest's automated mode from `$C000` for 26,554 cycles, the length of `nestest.log`, while the host keeps reading RAM, PRG RAM and SDRAM and checking what it reads. It passes in the simulation and on a Tang Nano 20K. Both give the bus-trace CRC `0xebba51ce`, which is also what the CPU's own bench gives, the bench that matches `nestest.log` line by line.

Planted bugs that the test catches: the shell taking the CPU's RAM slot, the CPU's read slot not reserved, and a CPU cycle too short for the SDRAM.

About 4,700 LUTs (22% of a GW2A-18C) and 6 block RAMs.
