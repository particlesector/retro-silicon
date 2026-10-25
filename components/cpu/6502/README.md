# 6502

An NMOS 6502 that is cycle-exact on the bus: one access per CPU cycle, including the original's dummy reads and writes, so memory-mapped hardware sees what it would on the real chip. The NES's 2A03 is this CPU with `DECIMAL = 0`; the Atari 2600's 6507 and the C64's 6510 keep decimal mode.

Module `cpu_6502` (the folder name can't start a module name).

## Timing

- **Clock enable:** the CPU advances one cycle on each clock with `ce` high.
- **Bus:** during a cycle, `addr`, `we` and `dout` describe its access, combinationally from the CPU's state. A read's data must be on `din` by the clock edge that ends the cycle, and a write takes effect on that edge.
- **Inputs:** `irq_n`, `nmi_n` and `rdy` are sampled at the clock edge before the cycle they apply to. That is the real chip's pin timing, moved half a cycle to the single clock edge.
- **Interrupts:** polled before each instruction's last cycle. Branches follow the chip's exceptions: a taken branch that stays on its page doesn't poll before its last cycle. An NMI edge arriving before the end of an NMI sequence merges into it, and one arriving later waits for the handler's first instruction. An NMI arriving by the fourth cycle of a BRK or IRQ sequence takes over its vector.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk`, `rst` | in | 1 | Clock; synchronous reset, after which the CPU runs its reset sequence (three dummy stack reads, then the vector at `$FFFC`) |
| `ce` | in | 1 | One CPU cycle per clock with `ce` high |
| `addr` | out | 16 | This cycle's address |
| `we` | out | 1 | This cycle writes `dout` |
| `dout` | out | 8 | Data written |
| `din` | in | 8 | Data read, needed by the edge that ends the cycle |
| `rdy` | in | 1 | Low stalls the CPU on read cycles; writes always complete |
| `irq_n` | in | 1 | Interrupt request, level-sensitive, active low |
| `nmi_n` | in | 1 | Non-maskable interrupt, falling-edge-sensitive |
| `sync` | out | 1 | This cycle fetches an opcode |
| `halted` | out | 1 | A JAM or unsupported opcode stopped the CPU; only reset restarts it |
| `dbg_pc`, `dbg_a`, `dbg_x`, `dbg_y`, `dbg_s`, `dbg_p` | out | 16, 8 | Registers, for traces; P as PHP pushes it but with B clear |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `DECIMAL` | 1 | NMOS decimal mode, including its flag quirks (ADC: N and V from an intermediate result, Z from the binary sum; SBC: binary flags). 0 for the NES's 2A03, where ADC and SBC are binary whatever D says |

## Opcodes

Every official opcode, and the stable unofficial ones: LAX, SAX, DCP, ISC, SLO, RLA, SRE, RRA, ANC, ALR, ARR, AXS, SBC `$EB` and the NOPs. The JAM opcodes, and the unstable ones (XAA, LAX `#imm`, AHX, SHX, SHY, TAS, LAS), stop the CPU with `halted` set.

## Status

Sim tests:
- **perfect6502 lockstep:** every cycle's bus access matches perfect6502, a transistor-level simulation of the chip, on random code with random IRQs and NMIs (2 million cycles), and on 1,500 decimal-mode ADC and SBC cases, invalid BCD digits included.
- **nestest:** all 8,991 lines of `nestest.log` match: registers, flags and cycle counts.
- **blargg:** `instr_test-v5/official_only` passes.
- **Unit tests:** hand-written checks of the documented bus patterns (indexed addressing, read-modify-write, JMP's page-wrap bug, branches, JSR and RTS, BRK and RTI, reset), interrupt timing, RDY and JAM.

Not on a board yet: that comes with the NES's memory and ROM loading.

Gaps:
- **RDY:** stalls are modelled as repeating the stalled read, which is right for straightforward cases but not every pipeline stage. It's left out of the lockstep for now and will be matched exactly when the NES's DMA needs it.
- **Unstable opcodes:** not implemented. Because of them, blargg's `all_instrs` stops at its first unstable opcode.
- **ARR with D set:** binary on this core; the NMOS chip adjusts it. The NES never sees it.
- **perfect6502's ANC, ALR and ARR** leave out the AND with the operand, which real chips do (perfect6502 issue #13). Those three are checked by unit tests instead of the lockstep.

About 2,500 LUTs and 110 flip-flops on a GW2A-18C with `DECIMAL = 0`; not optimised yet.

## References

- *6502.txt* by John West and Marko Mäkelä: cycle-by-cycle bus behaviour.
- Bruce Clark, *Decimal Mode*, 6502.org: the NMOS decimal algorithm and flags.
- NESdev wiki, *CPU interrupts*: polling, branch and hijacking behaviour.
- [perfect6502](https://github.com/mist64/perfect6502) and [visual6502.org](http://www.visual6502.org/): the transistor-level reference.
