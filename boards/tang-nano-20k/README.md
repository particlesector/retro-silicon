# Tang Nano 20K

Sipeed Tang Nano 20K: Gowin GW2AR-LV18QN88C8/I7 (family GW2A-18C), 27 MHz oscillator on pin 4, six LEDs on pins 15–20 (active low), and an onboard BL616 USB bridge for JTAG and a UART.

## Building

`build.sh` runs Yosys, nextpnr-himbaechel and gowin_pack with OSS CAD Suite on PATH. A missed timing constraint fails the build.

```sh
boards/tang-nano-20k/build.sh -t <top> -c <pins.cst> -o <outdir> [-f <MHz>] [-g NAME=VALUE]... <sources...>
```

The CMake build runs it for each design below when nextpnr-himbaechel is on PATH (turn that off with `-DRS_BITSTREAMS=OFF`); bitstreams land in `build/fpga/<name>/`.

Load a bitstream into the FPGA's configuration SRAM, which is lost at power-off but doesn't wear the flash:

```sh
openFPGALoader -b tangnano20k build/fpga/uart_echo/uart_echo.fs
```

## Designs

| Target | Design | Pins file | Notes |
| --- | --- | --- | --- |
| `uart_echo_bitstream` | `systems/uart-echo` | `uart_echo.cst` | 1.5 Mbaud (`CLKS_PER_BIT=18`) |
| `shell_ram_bitstream` | `systems/shell-ram` | `uart_echo.cst` | 1.5 Mbaud; `BUILD_ID` from the RTL's SHA-256 |

## UART

Use an external 3.3 V USB-serial adapter for anything beyond short exchanges: FPGA pin 42 (TX) to the adapter's RX, the adapter's TX to FPGA pin 41 (RX), and a ground. The onboard BL616's UART drops data in host-to-FPGA bursts over about 65 bytes, and corrupts sustained FPGA-to-host streams, after which it stops passing data until the board is power-cycled. See [docs/decisions/0002-uart-link.md](../../docs/decisions/0002-uart-link.md).
