# RTL conventions

## Language

- SystemVerilog that both Verilator (`-Wall`, no waivers except where noted below) and Yosys (`read_verilog -sv`) accept. The lint tests check both.
- `logic` for every signal; `always_ff` for registers, `always_comb` or `assign` for logic.
- Yosys doesn't support `return` in functions: assign the result to the function name.
- Size every constant that meets a sized signal (`CW'(CYCLES)`, `4'd10`), so `-Wall` stays quiet about widths.
- Name instances `u_<name>`; an instance named like a port hides it and Verilator warns.

## Clocks and resets

- One clock per clock domain. A block that runs slower takes a clock enable, never a derived clock.
- A signal crosses into another clock domain only through `common/cdc` (a level, a toggle, a Gray-coded count, or a value held steady around a toggle), or through a block RAM with a port in each domain. Name each side's ports by its domain (`s_`, `d_`) when a block has two.
- Resets are synchronous and active high, on a port named `rst`. Only registers that need a known value reset.
- No initial values on registers: Verilator warns, and ASICs and some FPGAs ignore them. The one exception is `common/por`, which turns the FPGA's configuration-time initial value into `rst` for everything else, with the warning waived there only.

## Interfaces

- Streams use valid/ready: a transfer happens on a clock edge where both are high.
- One-cycle event outputs (such as `valid` on `uart_rx`) are pulses; sticky flags belong to the system that uses them.

## Save states

Every component with state has a save-state port, so a system can save and restore itself (save states, rewind, and tests that start from a saved point instead of a cold boot):

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `st_addr` | in | as needed | Word index |
| `st_rdata` | out | 32 | Word `st_addr`, registered: valid the clock after the address |
| `st_we` | in | 1 | Write `st_wdata` to word `st_addr` this clock |
| `st_wdata` | in | 32 | The word to write |

- The port is used only while the component's clock enables are low. Reading every word, then writing them back after any reset or run, leaves the component in a state from which it continues exactly as it would have.
- A component's state covers every register and internal memory that affects its behaviour, mid-operation included (the CPU saves mid-instruction). Memories outside it, such as a console's RAM, belong to the system that owns them.
- Unused bits read 0. Each component's README lists its words.
- Registered reads keep the port on block RAM, so a memory can be part of the state.

## Parameters

- Rates and sizes are parameters (`CLKS_PER_BIT`, `DEPTH_LOG2`), so the same RTL serves every board and test.
- A chip's quirks are parameters too, with defaults that match the original chip. Each one is listed in the component README.

## Portability

- Components have no pins, PLLs or vendor primitives. Those go in `boards/`.
- Write memories as plain arrays with a registered read, so synthesis infers block RAM.
