# sdram

Controller for a 2M × 32 SDR SDRAM (8 MB: 4 banks, 2048 rows, 256 columns), such as the 64 Mbit chip inside the Tang Nano 20K's GW2AR-18. The user side is a byte port. Each access opens its row and closes it with auto-precharge, so every access takes the same number of clocks except when a refresh gets there first; that fixed bound is what lets a system fit an access into a CPU cycle.

Module `sdram_ctrl`.

## Timing

- **Port:** hold `req` with `addr`, `we` and `wdata` until `ack`, a one-cycle pulse that also marks `rdata` valid on a read. `req` may still be high the clock after `ack` (a registered requester can't drop it sooner) without starting a second access. `req` must stay low until `ready`.
- **SDRAM clock:** the board drives the chip's clock with the inverse of `clk`, so the chip samples each command half a cycle after it's registered, and read data is captured on the `clk` edge `CAS_LATENCY + 1` cycles after the READ. That half cycle is the I/O timing margin, which is plenty at 27 MHz.
- **Latency at 27 MHz:** from idle, 5 clocks from `req` to `ack` for a read and 2 for a write. The tail of the access before and a refresh can add up to 5 more, so budget 10 (the random test's worst was 9). At 100 MHz: 8 and 4 from idle, 18 at worst.
- **Refresh:** one auto-refresh every `REFRESH_NS`, ahead of any waiting request.
- **Chip timings:** tRCD 20 ns, tRP 20 ns, tRC and tRFC 70 ns, tRAS 50 ns, tWR 15 ns (at least 2 clocks), tMRD 2 clocks: a -7 speed grade with margin. A column command waits until its auto-precharge can't come before tRAS: a READ's precharge comes a clock after it, but a WRITE's can come under a clock after it, so a WRITE waits the whole of tRAS after its ACTIVE.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, which restarts the power-up sequence |
| `req` | in | 1 | Access request, held until `ack` |
| `we` | in | 1 | The access is a write |
| `addr` | in | 23 | Byte address: bank `[22:21]`, row `[20:10]`, column `[9:2]`, byte lane `[1:0]` |
| `wdata` | in | 8 | Byte to write |
| `ack` | out | 1 | One-cycle pulse: the access is done |
| `rdata` | out | 8 | Byte read, valid with `ack` |
| `rdata_w` | out | 32 | The whole word the byte was read from, byte lanes in address order, valid with `ack` |
| `ready` | out | 1 | The power-up sequence is done |
| `ref_hold` | in | 1 | While high, a due refresh waits (for a user with a deadline; let it through often enough) |
| `sd_cke`, `sd_cs_n`, `sd_ras_n`, `sd_cas_n`, `sd_we_n` | out | 1 | SDRAM control |
| `sd_ba`, `sd_addr`, `sd_dqm` | out | 2, 11, 4 | SDRAM bank, address, byte masks |
| `sd_dq_o`, `sd_dq_oe`, `sd_dq_i` | out, out, in | 32, 1, 32 | SDRAM data, split for the board's tristate buffer |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `FREQ_MHZ` | 27 | `clk` frequency; the chip timings are converted to clocks from it |
| `CAS_LATENCY` | 2 | 2 or 3 |
| `INIT_US` | 200 | Power-up wait before the first command |
| `REFRESH_NS` | 15000 | One refresh this often; 4096 rows in 64 ms needs 15,625 or less |

## Status

Sim tests, at 27, 47 and 100 MHz, against `sim/sdram_model.hpp`, a model of the chip that checks every command against its timing limits (power-up sequence, tRCD, tRP, tRC, tRAS, tWR, refresh interval) and puts read data on the bus only at the cycle the CAS latency allows:
- the power-up sequence;
- single bytes in every lane and bank;
- 40,000 random reads and writes against a byte array, with idle gaps so refreshes land everywhere;
- each request taken once when `req` drops a clock after `ack`;
- refreshes on time while a request is held continuously.

Planted bugs (capture one cycle late, no refresh, wrong byte lane, tRCD of 0, no wait after a refresh) are each caught.

Fixed: up to milestone 5 a WRITE waited only tRAS less its own tWR, so from about 40 MHz the chip's auto-precharge could start before tRAS. At 27 MHz it was 49 ns after the ACTIVE against tRAS's 42; at the Tang Nano 20K's 46.4 MHz the NES's HDMI sim caught it at 33.5 ns, and the 47 MHz tests fail without the fix.

On a Tang Nano 20K at 27 MHz, through `systems/shell-sdram`: 8 MB of random data written, checked by the shell's CRC command and sampled back, with the same CRC32 as the sim (`0x0e8da31c`).
