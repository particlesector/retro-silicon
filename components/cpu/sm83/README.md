# SM83

The Sharp SM83, the Game Boy's and the Game Boy Color's CPU, exact to the machine cycle: each M-cycle makes the bus access the chip makes then, or none, so memory-mapped hardware sees what it would on the real chip. It runs every opcode and every CB-prefixed one, interrupts, HALT with its bug, STOP, and EI's delay.

Module `cpu_sm83`.

## Timing

- **Clock enable:** the CPU advances one M-cycle (4 of the Game Boy's T-cycles) on each clock with `ce` high.
- **Bus:** during an M-cycle, `addr`, `rd`, `wr` and `dout` describe its access, combinationally from the CPU's state. A read's data must be on `din` by the clock edge that ends the M-cycle, and a write takes effect on that edge. An internal M-cycle has `rd` and `wr` low. Where in its four T-cycles the chip reads or writes is the system's to place, by where it puts the edge.
- **Overlap:** as on the chip, an instruction's last step (an ALU result, or a register loaded from memory) lands during the M-cycle that fetches the next opcode. So an instruction takes as many M-cycles as the chip's documented count (a NOP 1, `LD A,(BC)` 2, `CALL` 6), the fetch counted first.
- **Interrupts:** `int_req` is the system's IE & IF, combinational from its registers, so a write to either is seen in the next M-cycle. Before each opcode fetch, if IME is set and `int_req` isn't 0, the CPU dispatches instead, in 5 M-cycles: the fetch made and its opcode dropped, two internal M-cycles, PC's high byte pushed, then its low byte. During that last one it picks the lowest bit of `int_req` and pulses `int_ack` with it, for the system to clear in IF at the edge, and jumps to its vector (`$40` + 8 × bit). If the high byte's push wrote IE and no enabled interrupt is left, PC goes to `$0000` and nothing is acked.
- **EI, DI, RETI:** EI enables interrupts after the next instruction; DI and RETI act at once.
- **HALT:** the CPU reads the byte after HALT (and drops it), then idles with no bus accesses until `int_req` isn't 0; the M-cycle that sees it idles too, then the CPU dispatches (IME set) or fetches the next opcode (IME clear). With IME clear and an interrupt already pending, HALT doesn't halt and the next opcode byte is read twice (the HALT bug). With EI just before HALT and an interrupt pending, the interrupt returns to the HALT.
- **STOP:** with no interrupt pending, the CPU reads the byte after STOP, skips it, pulses `stop_pulse` (the system resets DIV) and stops, `stopped` high, until `stop_exit`. With one pending, that byte runs as the next opcode. Leaving STOP on a joypad press, and the Color's speed switch, are the system's: it raises `stop_exit`.
- **Illegal opcodes** (`$D3 $DB $DD $E3 $E4 $EB $EC $ED $F4 $FC $FD`) lock the CPU up, `locked` high, until reset.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, after which the CPU fetches from `$0000` (the boot ROM) with every register 0 |
| `ce` | in | 1 | One M-cycle per clock with `ce` high |
| `addr` | out | 16 | This M-cycle's address |
| `rd`, `wr` | out | 1 | This M-cycle reads `din`, or writes `dout`; neither on an internal M-cycle |
| `dout` | out | 8 | Data written |
| `din` | in | 8 | Data read, needed by the edge that ends the M-cycle |
| `int_req` | in | 5 | IE & IF: VBlank, STAT, timer, serial, joypad |
| `int_ack` | out | 5 | One-hot, in a dispatch's last M-cycle: the IF bit to clear at its edge |
| `stop_exit` | in | 1 | Leaves STOP |
| `sync` | out | 1 | This M-cycle fetches an opcode |
| `halted`, `stopped`, `locked` | out | 1 | In HALT, in STOP, locked up by an illegal opcode |
| `stop_pulse` | out | 1 | The M-cycle that enters STOP |
| `dbg_pc`, `dbg_sp`, `dbg_af`, `dbg_bc`, `dbg_de`, `dbg_hl` | out | 16 | Registers, with any pending last step applied: between instructions, the registers as the last one left them |
| `dbg_ime`, `dbg_ei` | out | 1 | IME (DI's effect included); an EI's enable pending |
| `dbg_boundary` | out | 1 | Between instructions: the next M-cycle fetches, dispatches or idles |
| `st_addr`, `st_rdata`, `st_we`, `st_wdata` | | 2, 32, 1, 32 | Save-state port (below) |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `SAVE_STATE` | 1 | 0 leaves out the save-state port's logic: writes do nothing and reads give 0. For a board short of logic |

## Save state

The port follows [docs/conventions.md](../../../docs/conventions.md): four words, readable and writable while `ce` is low, mid-instruction included.

| Word | Holds |
| --- | --- |
| 0 | A, B, C, D (A in bits 31-24) |
| 1 | E, H, L, then the flags Z N H C, the M-cycle step (3 bits), the CB prefix |
| 2 | SP, PC |
| 3 | Opcode, the data latches low and high, then in bits 7-2: last step pending, IME, halted, stopped, locked, dispatching |

<!-- size and speed: tools/timing/report.py --readmes writes this section -->
## Size and speed

Each top module placed alone by `tools/timing/report.py` (see `docs/timing.md` for how to read it): its fastest clock and its logic, in LUT4s and ALUs on the Gowin parts, LUT6s on the XC7Z020, and 18 Kbit block RAMs.

| Module | Tang Nano 20K (GW2A-18C) | Tang Console 138K (GW5AST-138C) | PYNQ-Z2 (XC7Z020) |
| --- | --- | --- | --- |
| `cpu_sm83` | 83 MHz, 3118 LUTs | 91 MHz, 3101 LUTs | 76 MHz, 2217 LUTs |

<!-- end of size and speed -->

## Status

Sim tests:
- **SingleStepTests:** all 500,000 of [SingleStepTests' SM83 cases](https://github.com/SingleStepTests/sm83) pass, 1,000 for each opcode and each CB-prefixed one: the registers, flags, IME and memory after one instruction, and every M-cycle's access (the address and data of each read and write, and no access on internal M-cycles). Each case's registers go in through the save-state port. For HALT and STOP only the fetch is compared: the cases then run 2 more M-cycles from the emulator they were made with, which the unit tests cover instead.
- **Unit tests:** interrupt dispatch (EI's delay, 5 M-cycles, the vector, IF cleared, priority), IE written by the push cancelling the interrupt, HALT with IME clear and set, the HALT bug, EI then HALT, DI and RETI acting at once, STOP and `stop_exit`, and the illegal opcodes' lock-up.
- **Save state:** 200 runs of random memory with random interrupts, saved at a random M-cycle, restored into another CPU and run on: the same 300 M-cycles each. Leaving out the last-step flag, the dispatch flag or a data latch fails it.

Settled in the Game Boy system (`systems/game-boy`, G2): when, in an M-cycle's four T-cycles, an interrupt is seen and a read or write lands. Mooneye's timer, interrupt and per-instruction timing tests pass there.

Still to come, neither of which games depend on:
- **Internal M-cycles' address (the OAM bug, with the PPU):** the chip puts an address on the bus during some internal M-cycles (the register pair for `INC rr` and `DEC rr`, SP before a push). The CPU already drives these, but SingleStepTests give no real address for them, so they aren't checked yet. They will be against blargg's `oam_bug` ROMs once the PPU scans OAM.
- **The Color's speed switch (with the Color):** it is the system's, through `stop_exit`.

## References

- Gekkio, *Game Boy: Complete Technical Reference*: each instruction's M-cycles and the interrupt dispatch.
- [Pan Docs](https://gbdev.io/pandocs/): the CPU's instructions, flags, interrupts, HALT and its bug.
- [SingleStepTests/sm83](https://github.com/SingleStepTests/sm83): per-instruction tests with every M-cycle's bus access.
- [SameBoy](https://github.com/LIJI32/SameBoy): its HALT, EI and dispatch behaviour, read for facts.
