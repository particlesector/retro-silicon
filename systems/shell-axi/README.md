# shell-axi

The test shell with an 8 MB window of an AXI slave's memory on its bus, through `memory/axi-bridge`, mirrored through the whole 32-bit address space. It's `shell-sdram` for memory behind a processor: the harness's SDRAM test writes seeded random data, checks it with the shell's CRC command and reads samples back, through the bridge and whatever the board connects its AXI master to.

Built from `common/por`, `debug/test-shell` and `memory/axi-bridge`. On the PYNQ-Z2, `boards/pynq-z2/rtl/pynq_shell_ddr_top.sv` connects it to the Zynq's HP0 port, and so to the board's DDR3, once `boards/xilinx/zynq7/ps7_ddr3.py`'s bring-up has run.

## Ports

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | Clock, for the shell and the AXI master |
| `uart_rx` | in | 1 | Serial input |
| `uart_tx` | out | 1 | Serial output |
| `led` | out | 6 | Active low: `led[0]` a corrupt command frame was seen, `led[1]` a stalled one (both sticky until reload), `led[2]` the memory is ready, `led[5]` heartbeat |
| `axi_ready` | in | 1 | The AXI port is out of reset and its memory is set up; accesses wait for it |
| `m_*` | | | The AXI master, as on `memory/axi-bridge` |

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `CLKS_PER_BIT` | 18 | Clocks per bit; 1.5 Mbaud at 27 MHz |
| `IDLE_CLKS` | 270,000 | The shell's stall timeout; 10 ms at 27 MHz |
| `BASE` | `0x10000000` | The AXI address of the window's first byte |
| `BUILD_ID` | 0 | Reported by INFO; the CMake build sets it from the RTL's SHA-256 |

## Status

In the sim, against `memory/axi-bridge`'s AXI memory model (which stalls every channel at random and checks the protocol), the harness's SDRAM test passes with the same CRC32 as `shell-sdram`'s.

On the PYNQ-Z2 (Oct 30), through HP0 to the board's DDR3 at 125 MHz, after `ps7_ddr3.py`'s bring-up over JTAG: 64 KB with the golden CRC (`0xa06577e4`, as in the sim and on the Tang Nano 20K's SDRAM), and the whole 8 MB window with `0x7c9aebe4`, the same as the 20K's SDRAM gives for 8 MB.
