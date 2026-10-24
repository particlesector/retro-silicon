# RTL conventions

## Language

- SystemVerilog that both Verilator (`-Wall`, no waivers except where noted below) and Yosys (`read_verilog -sv`) accept. The lint tests check both.
- `logic` for every signal; `always_ff` for registers, `always_comb` or `assign` for logic.
- Yosys doesn't support `return` in functions: assign the result to the function name.
- Size every constant that meets a sized signal (`CW'(CYCLES)`, `4'd10`), so `-Wall` stays quiet about widths.
- Name instances `u_<name>`; an instance named like a port hides it and Verilator warns.

## Clocks and resets

- One clock per clock domain. A block that runs slower takes a clock enable, never a derived clock.
- Resets are synchronous and active high, on a port named `rst`. Only registers that need a known value reset.
- No initial values on registers: Verilator warns, and ASICs and some FPGAs ignore them. The one exception is `common/por`, which turns the FPGA's configuration-time initial value into `rst` for everything else, with the warning waived there only.

## Interfaces

- Streams use valid/ready: a transfer happens on a clock edge where both are high.
- One-cycle event outputs (such as `valid` on `uart_rx`) are pulses; sticky flags belong to the system that uses them.

## Parameters

- Rates and sizes are parameters (`CLKS_PER_BIT`, `DEPTH_LOG2`), so the same RTL serves every board and test.
- A chip's quirks are parameters too, with defaults that match the original chip. Each one is listed in the component README.

## Portability

- Components have no pins, PLLs or vendor primitives. Those go in `boards/` and `platform/`.
- Write memories as plain arrays with a registered read, so synthesis infers block RAM.
