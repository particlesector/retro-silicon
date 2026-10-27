# PYNQ-Z2

TUL PYNQ-Z2: AMD Zynq-7020 (XC7Z020-1CLG400C), a 125 MHz clock from the Ethernet PHY on pin H16, 512 MB of DDR3 on the processor's side, HDMI in and out, two PMOD sockets, and an FTDI FT2232 on the micro-USB port marked PROG UART for JTAG. Its USB UART goes to the processor, not the FPGA.

The library's first board outside Gowin's family, and its check that the components carry over to another vendor's FPGA with only `boards/` changed.

## Building

`build.sh` runs `../xilinx/build.sh` for this part with [openXC7](https://github.com/openXC7): Yosys's `synth_xilinx`, nextpnr-xilinx, and Project X-Ray's fasm2frames and xc7frames2bit. It needs those on PATH and two databases from the same openXC7 release: `RS_XC7_CHIPDB`, the directory holding `xc7z020clg400.bin`, and `RS_PRJXRAY_DB`, Project X-Ray's database. A missed timing constraint fails the build.

```sh
boards/pynq-z2/build.sh -t <top> -c pins.xdc -o <outdir> [-g NAME=VALUE]... <sources...>
```

The CMake build runs it for each design below when nextpnr-xilinx is on PATH; bitstreams land in `build/fpga/pynq_<name>/`. Set the boot jumper to JTAG, then load one into the FPGA's configuration SRAM:

```sh
openFPGALoader -b pynq_z2 build/fpga/pynq_uart_echo/pynq_echo_top.bit
```

## Designs

| Target | Design | Top | Notes |
| --- | --- | --- | --- |
| `pynq_uart_echo_bitstream` | `systems/uart-echo` | `rtl/pynq_echo_top.sv` | 1.506 Mbaud (`CLKS_PER_BIT=83`) |

All use `pins.xdc`.

## Clock

The designs run on the 125 MHz clock on H16, which the Ethernet PHY makes; it runs with the processor not booted. 83 clocks a bit is 1.506 Mbaud, 0.4% fast of the host's 1.5 Mbaud.

## UART

Use an external 3.3 V USB-serial adapter on PMOD A (JA): FPGA TX on JA1P (Y18, the pin nearest the Raspberry Pi header in the column of Y pins) to the adapter's RX, the adapter's TX to JA1N (Y19, the next pin), and the adapter's ground to that column's GND (the 5th pin). PMOD A shares its pins with the Raspberry Pi header, so leave that empty.

## LEDs

LD0 overflow and LD1 framing error (both sticky until reload), LD3 heartbeat, for the echo design. Active high.

## Status

UART echo passes on the board: 10 MB with no errors, and the same CRC as the Tang boards.
